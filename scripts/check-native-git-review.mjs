import { spawnSync } from 'node:child_process';
import { cp, mkdir, mkdtemp, readFile, readdir, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import os from 'node:os';
import path from 'node:path';

const root = fileURLToPath(new URL('../', import.meta.url));
const output = await mkdtemp(path.join(os.tmpdir(), 'bluefatfish-git-review-'));
await mkdir(path.join(output, 'shared-home'), { recursive: true });
const live = process.argv.includes('--live-agent'), hold = process.argv.includes('--hold-ui');
const hash = data => createHash('sha256').update(data).digest('hex');
const profile = path.join(os.homedir(), 'Library/Application Support/BlueFatFish');
const names = ['settings.json', 'history.json', 'agent/index.json', 'agent/A7A38353-CBA2-431C-84F1-4903E73EA373.json', 'automations/definitions.json', 'models/catalog.json', 'extensions/mcp.json', 'extensions/hooks.json', 'extensions/hook-settings.json'];
const hashes = () => Promise.all(names.map(async name => [name, await readFile(path.join(profile, name)).then(hash).catch(error => { if (error.code === 'ENOENT') return null; throw error; })])).then(Object.fromEntries);
const before = await hashes(); await writeFile(path.join(output, 'production-before.json'), JSON.stringify(before, null, 2));
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const executable = spawnSync('/usr/bin/xcrun', ['--find', 'git'], { encoding: 'utf8' }).stdout.trim();
const env = { PATH: '/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin', HOME: os.homedir(), LANG: 'en_US.UTF-8', GIT_CONFIG_GLOBAL: '/dev/null', GIT_CONFIG_SYSTEM: '/dev/null', GIT_OPTIONAL_LOCKS: '0', GIT_TERMINAL_PROMPT: '0' };
const git = (directory, args, binary = false) => {
  const result = spawnSync(executable, ['-C', directory, ...args], { ...(binary ? {} : { encoding: 'utf8' }), env });
  if (result.status !== 0) throw new Error(String(result.stderr)); return result.stdout;
};
const records = async () => Promise.all((await readdir(path.join(output, 'profile/agent'))).filter(name => name.endsWith('.json') && name !== 'index.json').map(async name => JSON.parse(await readFile(path.join(output, 'profile/agent', name), 'utf8'))));
const usage = tasks => tasks.map(task => ({ id: task.id, input: task.inputTokens ?? 0, output: task.outputTokens ?? 0, receipts: task.modelReceipts ?? [], messages: task.messages.map(message => message.id) }));
let report;
console.log(JSON.stringify({ output, live, hold }));
try {
  const launch = spawnSync('/usr/bin/open', ['-n', path.join(root, 'build/蓝色大肥鱼.app'), '--args', '--check', output, '--git-review-check', ...(live ? ['--live-agent'] : []), ...(hold ? ['--hold-ui'] : [])], { encoding: 'utf8' });
  if (launch.status !== 0) throw new Error(launch.stderr || 'Review acceptance did not launch');
  const deadline = Date.now() + (live ? 360_000 : 180_000);
  while (Date.now() < deadline) { try { report = JSON.parse(await readFile(path.join(output, 'git-review-report.json'), 'utf8')); break; } catch {} await sleep(250); }
  if (!report) throw new Error('No terminal Git review report: ' + output);
  console.log(JSON.stringify({ success: report.success, checks: Object.keys(report.checks ?? {}).length, failed: Object.entries(report.checks ?? {}).filter(([, pass]) => !pass).map(([name]) => name), error: report.error }));
  if (report.success) {
    const beforeUI = usage(await records()), originalIndex = hash(await readFile(path.join(report.workspace, '.git/index')));
    await writeFile(path.join(output, 'model-usage-before-ui.json'), JSON.stringify(beforeUI, null, 2));
    if (hold) {
      const deadline = Date.now() + 1220_000;
      while (Date.now() < deadline) { try { await readFile(path.join(output, 'finish-ui')); break; } catch {} await sleep(500); }
    }
    const workspace = report.workspace, tasks = await records();
    report.independentGitReadback = {
      nativeCommitHasStagedVersion: git(workspace, ['show', `${report.nativeCommit}:layered.txt`]) === 'staged-selected\n',
      nativeCommitExcludesOtherUserStaging: git(workspace, ['show', `${report.nativeCommit}:other.txt`]) === 'base-other.txt\n',
      nativeCommitHasActualBinaryBytes: git(workspace, ['show', `${report.nativeCommit}:binary.dat`], true).equals(Buffer.from([0, 8, 9, 10, 11])),
      otherUserStagingPreserved: git(workspace, ['show', ':other.txt']) === 'other-user-staged\n',
      otherUserWorkingPreserved: await readFile(path.join(workspace, 'other.txt'), 'utf8') === 'other-user-working\n',
      layeredWorkingPreserved: await readFile(path.join(workspace, 'layered.txt'), 'utf8') === 'working-final-preserved\n',
      uiAddedNoModelRequests: JSON.stringify(beforeUI) === JSON.stringify(usage(tasks)),
      originalIndexBytesPreservedDuringUI: originalIndex === hash(await readFile(path.join(workspace, '.git/index'))),
    };
    if (live) {
      const result = JSON.parse(await readFile(path.join(workspace, 'review-result.json'), 'utf8'));
      report.independentGitReadback.realModelCommitHasOnlyChosenFile = git(workspace, ['diff-tree', '--no-commit-id', '--name-only', '-r', report.live.commit]) === 'live.txt\n';
      report.independentGitReadback.realModelUsedStagedVersionAndPreservedWorktree = git(workspace, ['show', `${report.live.commit}:live.txt`]) === 'live-staged-selected\n' && await readFile(path.join(workspace, 'live.txt'), 'utf8') === 'live-working-preserved\n';
      report.independentGitReadback.realModelReportMatchesActualGit = Object.keys(result).length === 4 && result.commit === report.live.commit && result.source === 'staged' && result.committedText === 'live-staged-selected' && result.workingText === 'live-working-preserved';
    } else report.noModelRequests = tasks.every(task => !task.inputTokens && !task.outputTokens && !(task.modelReceipts ?? []).length);
    if (hold) {
      const head = git(workspace, ['rev-parse', 'HEAD']).trim(), task = tasks.find(task => task.id === report.taskID), receipt = task?.gitPushReceipt;
      report.independentGitReadback.uiStagedCommitIncludesOnlyChosenFile = head !== report.beforeUIHead && git(workspace, ['diff-tree', '--no-commit-id', '--name-only', '-r', head]) === 'ui.txt\n';
      report.independentGitReadback.uiCommitUsesStagedVersionAndKeepsWorkingVersion = git(workspace, ['show', 'HEAD:ui.txt']) === 'ui-staged-selected\n' && await readFile(path.join(workspace, 'ui.txt'), 'utf8') === 'ui-working-preserved\n';
      report.independentGitReadback.uiStagedCommitAndPushMatchesActualReceiver = Boolean(receipt?.verified && receipt.sourceHead === head && git(report.receiver, ['rev-parse', `refs/heads/${receipt.branch}`]).trim() === head);
      report.uiReceipt = receipt;
    }
    report.productionAfter = await hashes(); report.productionProfileUnchanged = JSON.stringify(before) === JSON.stringify(report.productionAfter);
    report.success &&= Object.values(report.independentGitReadback).every(Boolean) && report.productionProfileUnchanged && (live || report.noModelRequests);
  }
} catch (error) { report = { ...(report ?? {}), success: false, error: error.message }; }
finally {
  await writeFile(path.join(output, 'finish-ui'), 'finished\n');
  await writeFile(path.join(output, 'git-review-report.json'), JSON.stringify(report, null, 2) + '\n');
  const archive = path.join(root, 'evidence/agent', path.basename(output).replace('bluefatfish-', ''));
  await mkdir(path.dirname(archive), { recursive: true }); await cp(output, archive, { recursive: true });
  console.log(JSON.stringify({ success: report?.success, output, archive, independentChecks: report?.independentGitReadback, error: report?.error }));
}
if (!report?.success) process.exitCode = 1;

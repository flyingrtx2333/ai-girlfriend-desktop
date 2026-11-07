import { spawnSync } from 'node:child_process';
import { cp, mkdir, mkdtemp, readFile, readdir, readlink, stat, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import os from 'node:os';
import path from 'node:path';

const root = fileURLToPath(new URL('../', import.meta.url)), output = await mkdtemp(path.join(os.tmpdir(), 'bluefatfish-worktree-creation-'));
await mkdir(path.join(output, 'shared-home'));
const live = process.argv.includes('--live-agent'), hold = process.argv.includes('--hold-ui'), sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const hash = value => createHash('sha256').update(value).digest('hex'), profile = path.join(os.homedir(), 'Library/Application Support/BlueFatFish');
const names = ['settings.json', 'history.json', 'agent/index.json', 'agent/A7A38353-CBA2-431C-84F1-4903E73EA373.json', 'automations/definitions.json', 'models/catalog.json', 'extensions/mcp.json', 'extensions/hooks.json', 'extensions/hook-settings.json'];
const hashes = () => Promise.all(names.map(async n => [n, await readFile(path.join(profile, n)).then(hash).catch(e => { if (e.code === 'ENOENT') return null; throw e; })])).then(Object.fromEntries);
const before = await hashes(); await writeFile(path.join(output, 'production-before.json'), JSON.stringify(before, null, 2));
const executable = spawnSync('/usr/bin/xcrun', ['--find', 'git'], { encoding: 'utf8' }).stdout.trim();
const git = (directory, args) => { const r = spawnSync(executable, ['-C', directory, ...args], { encoding: 'utf8', env: { PATH: '/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin', HOME: os.homedir(), GIT_CONFIG_GLOBAL: '/dev/null', GIT_CONFIG_SYSTEM: '/dev/null', GIT_OPTIONAL_LOCKS: '0' } }); if (r.status !== 0) throw new Error(r.stderr); return r.stdout; };
const tasks = async () => Promise.all((await readdir(path.join(output, 'profile/agent'))).filter(n => n.endsWith('.json') && n !== 'index.json').map(n => readFile(path.join(output, 'profile/agent', n), 'utf8').then(JSON.parse)));
const usage = records => records.filter(t => (t.modelReceipts ?? []).length).map(t => ({ id: t.id, receipts: t.modelReceipts, input: t.inputTokens, output: t.outputTokens })).sort((a, b) => a.id.localeCompare(b.id));
let report;
console.log(JSON.stringify({ output, live, hold }));
try {
  const launch = spawnSync('/usr/bin/open', ['-n', path.join(root, 'build/蓝色大肥鱼.app'), '--args', '--check', output, '--worktree-creation-check', ...(live ? ['--live-agent'] : []), ...(hold ? ['--hold-ui'] : [])], { encoding: 'utf8' });
  if (launch.status !== 0) throw new Error(launch.stderr || 'Creation check did not launch');
  const deadline = Date.now() + (live ? 420_000 : 180_000);
  while (Date.now() < deadline) { try { report = JSON.parse(await readFile(path.join(output, 'creation-report.json'), 'utf8')); break; } catch {} await sleep(250); }
  if (!report) throw new Error('No terminal creation report: ' + output);
  console.log(JSON.stringify({ success: report.success, checks: Object.keys(report.checks ?? {}).length, failed: Object.entries(report.checks ?? {}).filter(([, value]) => !value).map(([name]) => name), error: report.error }));
  if (report.success) {
    const previousTasks = await tasks(), previousUsage = usage(previousTasks);
    if (hold) { const deadline = Date.now() + 1220_000; while (Date.now() < deadline) { try { await readFile(path.join(output, 'finish-ui')); break; } catch {} await sleep(500); } }
    const records = await tasks(), carried = report.carriedWorkspace;
    report.independent = {
      actualSourceIndexUnchanged: hash(await readFile(path.join(report.workspace, '.git/index'))) === report.sourceIndexSHA256,
      actualSourceHeadAndBranchUnchanged: git(report.workspace, ['rev-parse', 'HEAD']).trim() === report.mainHead && git(report.workspace, ['symbolic-ref', 'HEAD']).trim() === 'refs/heads/main',
      originalStagedAndWorkingVersionsPreserved: git(report.workspace, ['show', ':public.txt']) === 'staged-public\n' && await readFile(path.join(report.workspace, 'public.txt'), 'utf8') === 'working-public\n',
      selectedReleaseBaseReallyUsed: git(carried, ['rev-parse', 'HEAD']).trim() === report.releaseHead && await readFile(path.join(carried, 'release-only.txt'), 'utf8') === 'release-marker\n',
      copiedContentIsActuallyUnstaged: git(carried, ['diff', '--cached', '--name-only']) === '' && git(carried, ['show', ':public.txt']) === 'base-public\n' && await readFile(path.join(carried, 'public.txt'), 'utf8') === 'working-public\n',
      binaryLinkAndExecutablePreserved: (await readFile(path.join(carried, 'untracked.bin'))).equals(Buffer.from([0, 1, 200, 255])) && await readlink(path.join(carried, 'relative-link')) === 'public.txt' && ((await stat(path.join(carried, 'executable.sh'))).mode & 0o777) === 0o755,
      uiAddedNoModelRequests: JSON.stringify(previousUsage) === JSON.stringify(usage(records)),
    };
    if (hold) {
      const ui = records.find(t => !previousTasks.some(old => old.id === t.id) && t.parentID === report.taskID && t.worktreeOrigin && git(t.workspace, ['branch', '--show-current']).trim() === 'ui-from-release');
      report.independent.actualComposerCreatedReviewedTask = Boolean(ui) && git(ui.workspace, ['rev-parse', 'HEAD']).trim() === report.releaseHead && git(ui.workspace, ['diff', '--cached', '--name-only']) === '' && await readFile(path.join(ui.workspace, 'public.txt'), 'utf8') === 'working-public\n';
      const original = records.find(t => t.id === report.taskID);
      report.independent.actualUiDraftAndAttachmentsCopied = Boolean(ui) && ui.draft === original.draft && JSON.stringify(ui.draftAttachmentIDs) === JSON.stringify(original.draftAttachmentIDs) && ui.modelOverride === original.modelOverride;
    }
    if (live) {
      const result = JSON.parse(await readFile(path.join(report.workspace, 'creation-result.json'), 'utf8')), task = records.find(t => t.id === report.live.taskID), child = records.find(t => t.id === report.live.childTaskID);
      const calls = task.messages.flatMap(m => m.toolCalls ?? []), writes = calls.filter(c => ['write_file', 'edit_file'].includes(c.name));
      report.independent.realModelReportMatchesActualCheckout = Object.keys(result).length === 4 && result.workspace === report.live.workspace && result.branch === 'model-from-release' && result.baseCommit === report.releaseHead && result.workingText === 'working-public' && git(result.workspace, ['rev-parse', 'HEAD']).trim() === report.releaseHead;
      report.independent.modelCreatedExactlyOneScopedCheckout = calls.filter(c => c.name === 'git_create_worktree').length === 1 && calls.filter(c => c.name === 'git_prepare_worktree').length === 1 && calls.every(c => ['load_tools', 'git_worktree_branches', 'git_prepare_worktree', 'git_create_worktree', 'read_file', 'write_file', 'edit_file', 'read_task_history'].includes(c.name)) && writes.every(c => path.resolve(report.workspace, JSON.parse(c.arguments).path) === path.join(report.workspace, 'creation-result.json'));
      const actual = JSON.parse(await readFile(path.join(child.workspace, 'child-result.json'), 'utf8'));
      report.independent.actualChildTaskRunsInNewCheckout = Object.keys(actual).length === 2 && actual.workingText === 'working-public' && actual.releaseText === 'release-marker' && child.status === 'completed' && git(child.workspace, ['diff', '--cached', '--name-only']) === '';
    } else report.noModelRequests = usage(records).length === 0;
    report.productionAfter = await hashes(); report.productionProfileUnchanged = JSON.stringify(before) === JSON.stringify(report.productionAfter);
    report.success &&= Object.values(report.independent).every(Boolean) && report.productionProfileUnchanged && (live || report.noModelRequests);
  }
} catch (e) { report = { ...(report ?? {}), success: false, error: e.message }; }
finally {
  await writeFile(path.join(output, 'finish-ui'), 'finished\n'); await writeFile(path.join(output, 'creation-report.json'), JSON.stringify(report, null, 2) + '\n');
  const archive = path.join(root, 'evidence/agent', path.basename(output).replace('bluefatfish-', '')); await mkdir(path.dirname(archive), { recursive: true }); await cp(output, archive, { recursive: true });
  console.log(JSON.stringify({ success: report?.success, output, archive, independent: report?.independent, error: report?.error }));
}
if (!report?.success) process.exitCode = 1;

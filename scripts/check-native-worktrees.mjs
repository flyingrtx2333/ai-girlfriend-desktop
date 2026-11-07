import { spawnSync } from 'node:child_process';
import { cp, mkdir, mkdtemp, readFile, readdir, readlink, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import os from 'node:os';
import path from 'node:path';

const root = fileURLToPath(new URL('../', import.meta.url));
const output = await mkdtemp(path.join(os.tmpdir(), 'bluefatfish-worktrees-'));
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
const git = (directory, args) => { const result = spawnSync(executable, ['-C', directory, ...args], { encoding: 'utf8', env }); if (result.status !== 0) throw new Error(result.stderr); return result.stdout; };
const tasks = async () => Promise.all((await readdir(path.join(output, 'profile/agent'))).filter(name => name.endsWith('.json') && name !== 'index.json').map(async name => JSON.parse(await readFile(path.join(output, 'profile/agent', name), 'utf8'))));
const usage = records => records.map(task => ({ id: task.id, input: task.inputTokens ?? 0, output: task.outputTokens ?? 0, receipts: task.modelReceipts ?? [] }));
const stagingHash = worktree => readFile(git(worktree, ['rev-parse', '--git-path', 'index']).trim()).then(hash);
const backups = async () => {
  const directory = path.join(output, 'profile/agent/worktrees');
  return Promise.all((await readdir(directory)).filter(name => /^[A-F0-9-]{36}$/i.test(name)).map(name => readFile(path.join(directory, name, 'record.json'), 'utf8').then(JSON.parse).catch(() => null))).then(records => records.filter(Boolean));
};
let report;
console.log(JSON.stringify({ output, live, hold }));
try {
  const launch = spawnSync('/usr/bin/open', ['-n', path.join(root, 'build/蓝色大肥鱼.app'), '--args', '--check', output, '--worktree-check', ...(live ? ['--live-agent'] : []), ...(hold ? ['--hold-ui'] : [])], { encoding: 'utf8' });
  if (launch.status !== 0) throw new Error(launch.stderr || 'Worktree acceptance did not launch');
  const deadline = Date.now() + (live ? 300_000 : 180_000);
  while (Date.now() < deadline) { try { report = JSON.parse(await readFile(path.join(output, 'worktree-report.json'), 'utf8')); break; } catch {} await sleep(250); }
  if (!report) throw new Error('No terminal worktree report: ' + output);
  console.log(JSON.stringify({ success: report.success, checks: Object.keys(report.checks ?? {}).length, failed: Object.entries(report.checks ?? {}).filter(([, pass]) => !pass).map(([name]) => name), error: report.error }));
  if (report.success) {
    const beforeTasks = usage(await tasks()), beforeIndex = await stagingHash(report.worktree), beforeBackups = await backups();
    if (hold) { const deadline = Date.now() + 1220_000; while (Date.now() < deadline) { try { await readFile(path.join(output, 'finish-ui')); break; } catch {} await sleep(500); } }
    const records = await tasks();
    report.independent = {
      originalProjectHeadPreserved: git(report.workspace, ['rev-parse', 'HEAD']).trim() === report.mainHead,
      childActualStagedVersion: git(report.worktree, ['show', ':public.txt']) === 'staged-public\n',
      childActualWorkingVersion: await readFile(path.join(report.worktree, 'public.txt'), 'utf8') === 'working-public\n',
      actualIgnoredFileRestored: await readFile(path.join(report.worktree, 'local-only.txt'), 'utf8') === 'ignored-public-marker\n',
      actualBinaryAndSymlinkRestored: (await readFile(path.join(report.worktree, 'untracked.bin'))).equals(Buffer.from([0, 1, 200, 255])) && await readlink(path.join(report.worktree, 'relative-link')) === 'public.txt',
      actualForeignWorktreeStillExists: git(report.foreign, ['rev-parse', '--abbrev-ref', 'HEAD']).trim() === 'external-native',
      uiAddedNoModelRequests: JSON.stringify(beforeTasks) === JSON.stringify(usage(records)),
      uiPreservedRawIndexBytes: beforeIndex === await stagingHash(report.worktree),
    };
    if (hold) report.independent.actualUIRecycleAndRestoreRecord = (await backups()).some(item => !beforeBackups.some(old => old.id === item.id) && item.origin.path === report.worktree && item.state === 'restored');
    if (live) {
      const result = JSON.parse(await readFile(path.join(report.live.workspace, 'worktree-result.json'), 'utf8'));
      const task = records.find(task => task.id === report.live.taskID), calls = task.messages.flatMap(message => message.toolCalls ?? []);
      report.independent.realModelReportMatchesActualRecovery = Object.keys(result).length === 4 && result.backup_id === report.live.backupID && result.state === 'restored' && result.path === report.live.worktree && result.workingText === 'working-public' && git(result.path, ['show', ':public.txt']) === 'staged-public\n';
      report.independent.realModelOnlyMutatedRecoveryAndReport = calls.every(call => ['load_tools', 'git_worktrees', 'git_prepare_worktree_recycle', 'git_recycle_worktree', 'git_restore_worktree', 'read_file', 'write_file', 'edit_file', 'read_task_history'].includes(call.name)) && calls.filter(call => ['write_file', 'edit_file'].includes(call.name)).every(call => path.resolve(report.live.workspace, JSON.parse(call.arguments).path) === path.join(report.live.workspace, 'worktree-result.json'));
    } else report.noModelRequests = records.every(task => !task.inputTokens && !task.outputTokens && !(task.modelReceipts ?? []).length);
    report.productionAfter = await hashes(); report.productionProfileUnchanged = JSON.stringify(before) === JSON.stringify(report.productionAfter);
    report.success &&= Object.values(report.independent).every(Boolean) && report.productionProfileUnchanged && (live || report.noModelRequests);
  }
} catch (error) { report = { ...(report ?? {}), success: false, error: error.message }; }
finally {
  await writeFile(path.join(output, 'finish-ui'), 'finished\n');
  await writeFile(path.join(output, 'worktree-report.json'), JSON.stringify(report, null, 2) + '\n');
  const archive = path.join(root, 'evidence/agent', path.basename(output).replace('bluefatfish-', ''));
  await mkdir(path.dirname(archive), { recursive: true }); await cp(output, archive, { recursive: true });
  console.log(JSON.stringify({ success: report?.success, output, archive, independent: report?.independent, error: report?.error }));
}
if (!report?.success) process.exitCode = 1;

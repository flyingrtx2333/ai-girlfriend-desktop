import { spawnSync } from 'node:child_process';
import { cp, mkdir, mkdtemp, readFile, readdir, readlink, lstat, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import os from 'node:os';
import path from 'node:path';

const root = fileURLToPath(new URL('../', import.meta.url)), output = await mkdtemp(path.join(os.tmpdir(), 'bluefatfish-worktree-retention-'));
const workspace = path.join(output, 'repo'); await mkdir(workspace); await mkdir(path.join(output, 'shared-home'));
for (const name of ['source.json', 'character.png']) await cp(path.join(root, 'public/portraits/whale-maid', name), path.join(workspace, name));
const source = JSON.parse(await readFile(path.join(workspace, 'source.json'), 'utf8'));
const live = process.argv.includes('--live-agent'), hold = process.argv.includes('--hold-ui'), sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const hash = data => createHash('sha256').update(data).digest('hex'), production = path.join(os.homedir(), 'Library/Application Support/BlueFatFish');
const names = ['settings.json', 'history.json', 'agent/index.json', 'agent/A7A38353-CBA2-431C-84F1-4903E73EA373.json', 'automations/definitions.json', 'models/catalog.json', 'extensions/mcp.json', 'extensions/hooks.json', 'extensions/hook-settings.json', 'worktrees/policy.json', 'worktrees/history.json', 'worktrees/scheduler.lock'];
const hashes = () => Promise.all(names.map(async n => [n, await readFile(path.join(production, n)).then(hash).catch(e => { if (e.code === 'ENOENT') return null; throw e; })])).then(Object.fromEntries);
const before = await hashes(); await writeFile(path.join(output, 'production-before.json'), JSON.stringify(before, null, 2));
const gitPath = spawnSync('/usr/bin/xcrun', ['--find', 'git'], { encoding: 'utf8' }).stdout.trim();
const git = args => { const r = spawnSync(gitPath, ['-C', workspace, ...args], { encoding: 'utf8', env: { PATH: '/usr/bin:/bin:/opt/homebrew/bin', HOME: os.homedir(), GIT_CONFIG_GLOBAL: '/dev/null', GIT_CONFIG_SYSTEM: '/dev/null', GIT_OPTIONAL_LOCKS: '0' } }); if (r.status !== 0) throw new Error(r.stderr); return r.stdout; };
const taskRecords = async () => Promise.all((await readdir(path.join(output, 'profile/agent'))).filter(n => n.endsWith('.json') && n !== 'index.json').map(n => readFile(path.join(output, 'profile/agent', n), 'utf8').then(JSON.parse)));
const usage = tasks => tasks.filter(t => (t.modelReceipts ?? []).length).map(t => ({ id: t.id, receipts: t.modelReceipts, input: t.inputTokens, output: t.outputTokens })).sort((a, b) => a.id.localeCompare(b.id));
async function fileInventory(directory, prefix = '') {
  const result = [];
  for (const name of (await readdir(path.join(directory, prefix))).sort()) {
    if (!prefix && name === '.git') continue;
    const relative = path.join(prefix, name), target = path.join(directory, relative), info = await lstat(target);
    if (info.isSymbolicLink()) result.push({ path: relative, mode: info.mode & 0o777, kind: 'link', value: await readlink(target) });
    else if (info.isDirectory()) { result.push({ path: relative, mode: info.mode & 0o777, kind: 'directory' }); result.push(...await fileInventory(directory, relative)); }
    else result.push({ path: relative, mode: info.mode & 0o777, kind: 'file', sha256: hash(await readFile(target)) });
  }
  return result;
}
let report;
console.log(JSON.stringify({ output, live, hold }));
try {
  const launch = spawnSync('/usr/bin/open', ['-n', path.join(root, 'build/蓝色大肥鱼.app'), '--args', '--check', output, '--worktree-check', '--retention-check', ...(live ? ['--live-agent'] : []), ...(hold ? ['--hold-ui'] : [])], { encoding: 'utf8' });
  if (launch.status !== 0) throw new Error(launch.stderr || 'Retention check did not launch');
  const deadline = Date.now() + (live ? 420_000 : 180_000);
  while (Date.now() < deadline) { try { report = JSON.parse(await readFile(path.join(output, 'worktree-report.json'), 'utf8')); break; } catch {} await sleep(250); }
  if (!report) throw new Error('No terminal retention report: ' + output);
  console.log(JSON.stringify({ success: report.success, checks: Object.keys(report.checks ?? {}).length, failed: Object.entries(report.checks ?? {}).filter(([, value]) => !value).map(([name]) => name), error: report.error }));
  if (report.success) {
    const previousUsage = usage(await taskRecords()), backup = path.join(output, 'profile/agent/worktrees', report.retention.backupID);
    const expectedFiles = await fileInventory(path.join(backup, 'files')), indexHash = hash(await readFile(path.join(backup, 'metadata/index')));
    if (hold) { const deadline = Date.now() + 1220_000; while (Date.now() < deadline) { try { await readFile(path.join(output, 'finish-ui')); break; } catch {} await sleep(500); } }
    const tasks = await taskRecords(), record = JSON.parse(await readFile(path.join(backup, 'record.json'), 'utf8')), policy = JSON.parse(await readFile(report.retention.policyFile, 'utf8'));
    report.independent = {
      actualMainHeadPreserved: git(['rev-parse', 'HEAD']).trim() === report.mainHead,
      actualMainRawIndexPreserved: hash(await readFile(path.join(workspace, '.git/index'))) === report.retention.mainIndexSHA256,
      actualLockedAndForeignCheckoutsRetained: git(['worktree', 'list', '--porcelain']).includes('locked') && git(['worktree', 'list', '--porcelain']).includes('external-native'),
      actualPrivateBackupRefsStillExist: record.objectRefs.length === 2 && record.objectRefs.every(ref => git(['rev-parse', ref]).trim().length >= 40),
      uiAddedNoModelRequests: JSON.stringify(previousUsage) === JSON.stringify(usage(tasks)),
      finalPolicyDisabled: policy.enabled === false,
    };
    if (hold) {
      report.independent.actualUiRestoreHasExactFilesModesAndLinks = JSON.stringify(expectedFiles) === JSON.stringify(await fileInventory(report.retention.restorePath));
      const restoredIndex = spawnSync(gitPath, ['-C', report.retention.restorePath, 'rev-parse', '--git-path', 'index'], { encoding: 'utf8' }); if (restoredIndex.status !== 0) throw new Error(restoredIndex.stderr);
      report.independent.actualUiRestorePreservedRawIndexAndTaskState = hash(await readFile(restoredIndex.stdout.trim())) === indexHash && record.state === 'restored' && tasks.find(t => t.id === report.retention.taskID)?.archived === false;
    }
    if (live) {
      const artifact = await readFile(path.join(backup, 'files/asset-report.json')), actual = JSON.parse(artifact), task = tasks.find(t => t.id === report.live.taskID), calls = task.messages.flatMap(m => m.toolCalls ?? []), writes = calls.filter(c => ['write_file', 'edit_file'].includes(c.name));
      report.independent.actualModelArtifactMatchesSourceAndAnswer = Object.keys(actual).length === 4 && ['edition', 'width', 'height'].every(k => actual[k] === source[k]) && actual.reviewer === '海盐-7319' && hash(artifact) === report.live.artifactSHA256;
      report.independent.modelOnlyUsesScopedFilesAndQuestion = calls.every(c => ['load_tools', 'read_file', 'write_file', 'edit_file', 'ask_user', 'read_task_history', 'list_directory'].includes(c.name)) && calls.filter(c => c.name === 'ask_user').length === 1 && writes.every(c => path.resolve(report.live.workspace, JSON.parse(c.arguments).path) === path.join(report.live.workspace, 'asset-report.json'));
      report.independent.realModelUsageAccounted = task.inputTokens === task.modelReceipts.reduce((n, r) => n + r.inputTokens, 0) && task.outputTokens === task.modelReceipts.reduce((n, r) => n + r.outputTokens, 0) && task.status === 'completed';
    } else report.noModelRequests = usage(tasks).length === 0;
    report.productionAfter = await hashes(); report.productionProfileUnchanged = JSON.stringify(before) === JSON.stringify(report.productionAfter);
    report.success &&= Object.values(report.independent).every(Boolean) && report.productionProfileUnchanged && (live || report.noModelRequests);
  }
} catch (error) { report = { ...(report ?? {}), success: false, error: error.message }; }
finally {
  await writeFile(path.join(output, 'finish-ui'), 'finished\n'); await writeFile(path.join(output, 'worktree-report.json'), JSON.stringify(report, null, 2) + '\n');
  const archive = path.join(root, 'evidence/agent', path.basename(output).replace('bluefatfish-', '')); await mkdir(path.dirname(archive), { recursive: true }); await cp(output, archive, { recursive: true });
  console.log(JSON.stringify({ success: report?.success, output, archive, independent: report?.independent, error: report?.error }));
}
if (!report?.success) process.exitCode = 1;

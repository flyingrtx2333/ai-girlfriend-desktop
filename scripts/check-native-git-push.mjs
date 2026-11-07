import { spawn, spawnSync } from 'node:child_process';
import { cp, mkdir, mkdtemp, readFile, readdir, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { createConnection, createServer } from 'node:net';
import { fileURLToPath } from 'node:url';
import os from 'node:os';
import path from 'node:path';

const root = fileURLToPath(new URL('../', import.meta.url));
const output = await mkdtemp(path.join(os.tmpdir(), 'bluefatfish-git-push-'));
const receiver = path.join(output, 'remotes/remote.git');
await mkdir(path.join(output, 'shared-home'), { recursive: true });
await mkdir(path.dirname(receiver), { recursive: true });
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const hash = data => createHash('sha256').update(data).digest('hex');
const profile = path.join(os.homedir(), 'Library/Application Support/BlueFatFish');
const names = ['settings.json', 'history.json', 'agent/index.json', 'agent/A7A38353-CBA2-431C-84F1-4903E73EA373.json', 'automations/definitions.json', 'models/catalog.json', 'extensions/mcp.json', 'extensions/hooks.json', 'extensions/hook-settings.json'];
const hashes = () => Promise.all(names.map(async name => [name, await readFile(path.join(profile, name)).then(hash).catch(error => { if (error.code === 'ENOENT') return null; throw error; })])).then(Object.fromEntries);
const before = await hashes();
await writeFile(path.join(output, 'production-before.json'), JSON.stringify(before, null, 2));
const executable = spawnSync('/usr/bin/xcrun', ['--find', 'git'], { encoding: 'utf8' }).stdout.trim();
if (!executable) throw new Error('Git executable unavailable');
const gitEnv = { PATH: '/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin', HOME: os.homedir(), LANG: 'en_US.UTF-8', GIT_CONFIG_GLOBAL: '/dev/null', GIT_CONFIG_SYSTEM: '/dev/null', GIT_OPTIONAL_LOCKS: '0', GIT_TERMINAL_PROMPT: '0' };
const git = (directory, args) => {
  const result = spawnSync(executable, ['-C', directory, ...args], { encoding: 'utf8', env: gitEnv });
  if (result.status !== 0) throw new Error(result.stderr || `Git exited ${result.status}`);
  return result.stdout;
};
git(path.dirname(receiver), ['init', '--bare', '--initial-branch=main', receiver]);
git(receiver, ['config', 'receive.denyNonFastForwards', 'true']);
const reserve = createServer();
await new Promise((resolve, reject) => reserve.once('error', reject).listen(0, '127.0.0.1', resolve));
const port = reserve.address().port;
await new Promise(resolve => reserve.close(resolve));
const daemon = spawn(executable, ['daemon', '--reuseaddr', '--export-all', '--enable=receive-pack', `--base-path=${path.dirname(receiver)}`, '--listen=127.0.0.1', `--port=${port}`], { env: gitEnv, detached: true, stdio: ['ignore', 'pipe', 'pipe'] });
let logs = '', report;
daemon.stdout.on('data', data => { logs = (logs + data).slice(-100_000); });
daemon.stderr.on('data', data => { logs = (logs + data).slice(-100_000); });
daemon.on('error', error => { logs += error.message; });
const hold = process.argv.includes('--hold-ui'), live = process.argv.includes('--live-agent'), ssh = process.argv.includes('--probe-ssh');
console.log(JSON.stringify({ output, hold, live, ssh, serverPID: daemon.pid, port }));
try {
  let ready = false;
  for (let attempt = 0; attempt < 40 && !ready; attempt++) {
    if (daemon.exitCode !== null) throw new Error('Git daemon exited: ' + logs);
    ready = await new Promise(resolve => { const socket = createConnection({ host: '127.0.0.1', port }); socket.once('connect', () => { socket.destroy(); resolve(true); }); socket.once('error', () => resolve(false)); });
    if (!ready) await sleep(100);
  }
  if (!ready) throw new Error('Actual Git daemon did not start');
  await writeFile(path.join(output, 'server.json'), JSON.stringify({ url: `git://127.0.0.1:${port}/remote.git`, repository: receiver, pid: daemon.pid }, null, 2));
  const launch = spawnSync('/usr/bin/open', ['-n', path.join(root, 'build/蓝色大肥鱼.app'), '--args', '--check', output, '--git-push-check', ...(live ? ['--live-agent'] : []), ...(ssh ? ['--probe-ssh'] : []), ...(hold ? ['--hold-ui'] : [])], { encoding: 'utf8' });
  if (launch.status !== 0) throw new Error(launch.stderr || 'Git push acceptance did not launch');
  const deadline = Date.now() + (live ? 360_000 : 180_000);
  while (Date.now() < deadline) { try { report = JSON.parse(await readFile(path.join(output, 'git-push-report.json'), 'utf8')); break; } catch {} await sleep(250); }
  if (!report) throw new Error('No terminal native Git push report: ' + output);
  console.log(JSON.stringify({ success: report.success, checks: Object.keys(report.checks ?? {}).length, failed: Object.entries(report.checks ?? {}).filter(([, pass]) => !pass).map(([name]) => name), error: report.error }));
  const taskRecords = async () => Promise.all((await readdir(path.join(output, 'profile/agent'))).filter(name => name.endsWith('.json') && name !== 'index.json').map(async name => JSON.parse(await readFile(path.join(output, 'profile/agent', name), 'utf8'))));
  const beforeUI = await taskRecords();
  const usage = records => records.map(task => ({ id: task.id, input: task.inputTokens ?? 0, output: task.outputTokens ?? 0, receipts: task.modelReceipts ?? [], messages: task.messages.map(message => message.id) }));
  await writeFile(path.join(output, 'model-usage-before-ui.json'), JSON.stringify(usage(beforeUI), null, 2));
  if (hold && report.success) {
    const limit = Date.now() + 1220_000;
    while (Date.now() < limit) { try { await readFile(path.join(output, 'finish-ui')); break; } catch {} await sleep(500); }
  }
  await writeFile(path.join(output, 'finish-ui'), 'finished\n');
  if (report.success) {
    const workspace = report.workspace;
    const tasks = await taskRecords(), task = tasks.find(item => item.id === report.taskID);
    report.independentGitReadback = {
      originalReviewedCommitActuallyReceived: git(receiver, ['rev-parse', 'refs/heads/main']).trim() === report.sourceHead,
      workingBytesPreserved: await readFile(path.join(workspace, 'user.txt'), 'utf8') === 'user-working-preserved\n',
      otherUserStagingPreserved: git(workspace, ['show', ':user.txt']) === 'user-staged-preserved\n',
      uiAddedNoModelRequests: JSON.stringify(usage(beforeUI)) === JSON.stringify(usage(tasks)),
    };
    if (live) {
      const result = JSON.parse(await readFile(path.join(workspace, 'push-result.json'), 'utf8'));
      const remoteHead = git(receiver, ['rev-parse', `refs/heads/${report.live.branch}`]).trim();
      report.independentGitReadback.realModelRemoteHeadMatches = remoteHead === report.live.sourceHead;
      report.independentGitReadback.realModelReportMatchesIndependentGit = Object.keys(result).length === 4 && result.branch === report.live.branch && result.sourceHead === remoteHead && result.remoteHead === remoteHead && result.verified === true;
    } else report.noModelRequests = tasks.every(item => !item.inputTokens && !item.outputTokens && !(item.modelReceipts ?? []).length);
    if (task?.gitPushReceipt?.branch?.startsWith('ui-')) {
      const receipt = task.gitPushReceipt, actual = git(receiver, ['rev-parse', `refs/heads/${receipt.branch}`]).trim();
      report.independentGitReadback.uiPushMatchesActualRemote = receipt.verified && actual === receipt.sourceHead && git(workspace, ['rev-parse', 'HEAD']).trim() === actual;
      report.independentGitReadback.uiCommitIncludesOnlyChosenFile = git(workspace, ['diff-tree', '--no-commit-id', '--name-only', '-r', actual]) === 'ui.txt\n';
      report.uiReceipt = receipt;
    }
    report.productionAfter = await hashes(); report.productionProfileUnchanged = JSON.stringify(before) === JSON.stringify(report.productionAfter);
    report.success &&= Object.values(report.independentGitReadback).every(Boolean) && report.productionProfileUnchanged && (live || report.noModelRequests);
  }
} catch (error) {
  report = { ...(report ?? {}), success: false, error: error.message };
} finally {
  await writeFile(path.join(output, 'finish-ui'), 'finished\n');
  if (daemon.pid && daemon.exitCode === null) { try { process.kill(-daemon.pid, 'SIGTERM'); } catch {} }
  await writeFile(path.join(output, 'git-server.log'), logs);
  await writeFile(path.join(output, 'git-push-report.json'), JSON.stringify(report, null, 2) + '\n');
  const archive = path.join(root, 'evidence/agent', path.basename(output).replace('bluefatfish-', ''));
  await mkdir(path.dirname(archive), { recursive: true }); await cp(output, archive, { recursive: true });
  console.log(JSON.stringify({ success: report?.success, output, archive, independentReadbacks: report?.independentGitReadback, error: report?.error }));
}
if (!report?.success) process.exitCode = 1;

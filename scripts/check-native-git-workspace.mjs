import { spawn, spawnSync } from 'node:child_process';
import { mkdir, mkdtemp, readFile, readdir, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { createConnection, createServer } from 'node:net';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import os from 'node:os';

const root = fileURLToPath(new URL('../', import.meta.url));
const reopenIndex = process.argv.indexOf('--reopen');
const reopening = reopenIndex >= 0;
const manual = reopening || process.argv.includes('--manual-ui');
await mkdir(path.join(root, 'evidence/agent'), { recursive: true });
const output = reopening ? path.resolve(process.argv[reopenIndex + 1]) : await mkdtemp(path.join(root, 'evidence/agent/git-workspace-command-'));
const receiver = path.join(output, 'remotes/remote.git');
await mkdir(path.dirname(receiver), { recursive: true });
await mkdir(path.join(output, 'tmp'), { recursive: true });
const executable = spawnSync('/usr/bin/xcrun', ['--find', 'git'], { encoding: 'utf8' }).stdout.trim();
if (!executable) throw new Error('Git unavailable');
const gitEnvironment = { ...process.env, GIT_CONFIG_GLOBAL: '/dev/null', GIT_CONFIG_SYSTEM: '/dev/null', GIT_TERMINAL_PROMPT: '0' };
const git = (directory, args) => {
  const result = spawnSync(executable, ['-C', directory, ...args], { encoding: 'utf8', env: gitEnvironment });
  if (result.status !== 0) throw new Error(result.stderr || `Git exited ${result.status}`);
  return result.stdout;
};
const hash = data => createHash('sha256').update(data).digest('hex');
const profile = path.join(os.homedir(), 'Library/Application Support/BlueFatFish');
const names = ['settings.json', 'history.json', 'agent/index.json', 'agent/A7A38353-CBA2-431C-84F1-4903E73EA373.json', 'automations/definitions.json', 'models/catalog.json', 'extensions/mcp.json', 'extensions/hooks.json', 'extensions/hook-settings.json'];
const hashes = async () => Object.fromEntries(await Promise.all(names.map(async name => [name, await readFile(path.join(profile, name)).then(hash).catch(error => { if (error.code === 'ENOENT') return null; throw error; })])));
const before = await hashes();
const phase = reopening ? `restart-${Date.now()}` : 'initial';
await writeFile(path.join(output, `production-before-${phase}.json`), JSON.stringify(before, null, 2));
if (!reopening) {
  git(path.dirname(receiver), ['init', '--bare', '--initial-branch=main', receiver]);
  git(receiver, ['config', 'receive.denyNonFastForwards', 'true']);
}
const reserve = createServer();
const previous = reopening ? JSON.parse(await readFile(path.join(output, 'server.json'), 'utf8')) : null;
await new Promise((resolve, reject) => reserve.once('error', reject).listen(previous ? Number(new URL(previous.url).port) : 0, '127.0.0.1', resolve));
const port = reserve.address().port;
await new Promise(resolve => reserve.close(resolve));
const serverLog = [];
const daemon = spawn(executable, ['daemon', '--reuseaddr', '--export-all', '--enable=receive-pack', `--base-path=${path.dirname(receiver)}`, '--listen=127.0.0.1', `--port=${port}`], { env: gitEnvironment, detached: true, stdio: ['ignore', 'pipe', 'pipe'] });
daemon.stdout.on('data', data => serverLog.push(data)); daemon.stderr.on('data', data => serverLog.push(data));
let app, report;
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
try {
  let ready = false;
  for (let attempt = 0; attempt < 40 && !ready; attempt++) {
    if (daemon.exitCode !== null) throw new Error('Local Git receiver exited');
    ready = await new Promise(resolve => { const socket = createConnection({ host: '127.0.0.1', port }); socket.once('connect', () => { socket.destroy(); resolve(true); }); socket.once('error', () => resolve(false)); });
    if (!ready) await pause(100);
  }
  if (!ready) throw new Error('Local Git receiver not ready');
  await writeFile(path.join(output, 'server.json'), JSON.stringify({ url: `git://127.0.0.1:${port}/remote.git`, repository: receiver, pid: daemon.pid }, null, 2));
  const application = process.env.BLUEFATFISH_APP ?? path.join(root, 'build/蓝色大肥鱼.app');
  const binary = path.join(application, 'Contents/MacOS/BlueFatFish');
  const binaryHash = hash(await readFile(binary));
  const args = ['--check', output, ...(manual ? ['--manual-ui', reopening ? '--git-workspace-reopen' : '--git-workspace-fixtures'] : ['--git-workspace-check'])];
  const launchLog = [];
  app = spawn(binary, args, { env: { ...process.env, TMPDIR: path.join(output, 'tmp') + '/' }, stdio: ['ignore', 'pipe', 'pipe'] });
  app.stdout.on('data', data => launchLog.push(data)); app.stderr.on('data', data => launchLog.push(data));
  await writeFile(path.join(output, `launch-${phase}.json`), JSON.stringify({ pid: app.pid, serverPID: daemon.pid, application, binaryHash, args }, null, 2));
  console.log(JSON.stringify({ output, appPID: app.pid, serverPID: daemon.pid, manual, reopening, binaryHash }));
  const result = await new Promise((resolve, reject) => {
    const timer = setTimeout(() => { app.kill('SIGTERM'); reject(new Error('Native Git workspace check timed out')); }, manual ? 3_650_000 : 240_000);
    app.once('error', error => { clearTimeout(timer); reject(error); });
    app.once('exit', (code, signal) => { clearTimeout(timer); resolve({ code, signal }); });
  });
  await writeFile(path.join(output, `launch-${phase}.log`), Buffer.concat(launchLog));
  report = manual ? JSON.parse(await readFile(path.join(output, `manual-ui-result-${app.pid}.json`), 'utf8')) : JSON.parse(await readFile(path.join(output, 'git-workspace-report.json'), 'utf8'));
  const fixture = JSON.parse(await readFile(path.join(output, 'git-workspace-fixtures.json'), 'utf8'));
  const taskFiles = (await readdir(path.join(output, 'profile/agent'))).filter(name => name.endsWith('.json') && name !== 'index.json');
  const tasks = await Promise.all(taskFiles.map(name => readFile(path.join(output, 'profile/agent', name), 'utf8').then(JSON.parse)));
  const task = tasks.find(item => item.id === fixture.taskID), workspace = fixture.workspace;
  const head = git(workspace, ['rev-parse', 'HEAD']).trim(), remoteHead = git(receiver, ['rev-parse', 'refs/heads/main']).trim();
  const independent = {
    committedReviewedStagedBytes: git(workspace, ['show', 'HEAD:review.txt']) === 'selected-staged\n',
    selectedWorkingBytesPreserved: await readFile(path.join(workspace, 'review.txt'), 'utf8') === 'selected-working-preserved\n',
    otherUserStagingPreserved: git(workspace, ['show', ':other.txt']) === 'other-staged-preserved\n',
    otherUserWorkingBytesPreserved: await readFile(path.join(workspace, 'other.txt'), 'utf8') === 'other-working-preserved\n',
    commitExcludesOtherStaging: git(workspace, ['show', 'HEAD:other.txt']) === 'original-other\n',
    noModelRequests: tasks.every(item => !item.inputTokens && !item.outputTokens && !(item.modelReceipts ?? []).length) && (report.modelRequests ?? 0) === 0,
    originalProfileUnchanged: JSON.stringify(before) === JSON.stringify(await hashes()),
    receiverMatchesExpectedPhase: manual ? task?.gitPushReceipt?.verified === true && task.gitPushReceipt.sourceHead === head && remoteHead === head : remoteHead !== head && report.head === head,
  };
  report = { ...report, success: result.code === 0 && (manual || report.success === true) && Object.values(independent).every(Boolean), phase, binaryHash, independent, head, remoteHead };
} catch (error) { report = { ...(report ?? {}), success: false, error: error.message }; }
finally {
  if (app && app.exitCode === null && app.signalCode === null) app.kill('SIGTERM');
  if (daemon.pid && daemon.exitCode === null) { try { process.kill(-daemon.pid, 'SIGTERM'); } catch {} }
  await writeFile(path.join(output, `git-server-${phase}.log`), Buffer.concat(serverLog));
  await writeFile(path.join(output, `independent-${phase}.json`), JSON.stringify(report, null, 2) + '\n');
  console.log(JSON.stringify({ output, success: report?.success, checks: Object.keys(report?.checks ?? {}).length, failures: Object.entries(report?.checks ?? {}).filter(([, pass]) => !pass).map(([name]) => name), independent: report?.independent, error: report?.error }));
}
if (!report?.success) process.exitCode = 1;

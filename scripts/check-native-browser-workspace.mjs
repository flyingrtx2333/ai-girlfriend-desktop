import { spawn, spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { createWriteStream } from 'node:fs';
import { mkdir, mkdtemp, readFile, readdir, writeFile, copyFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../', import.meta.url));
const option = name => { const i = process.argv.indexOf(name); return i < 0 ? undefined : process.argv[i + 1]; };
if (process.argv.includes('--live-agent')) throw Error('Browser workspace acceptance does not call models');
const app = process.env.BLUEFATFISH_APP;
if (!app) throw Error('Set BLUEFATFISH_APP to an independent acceptance application');
const command = (file, args) => { const p = spawnSync(file, args, { encoding: 'utf8' }); if (p.status !== 0) throw Error(p.stderr || file); return p.stdout; };
command('/usr/bin/codesign', ['--verify', '--deep', '--strict', app]);
const metadata = JSON.parse(command('/usr/bin/plutil', ['-convert', 'json', '-o', '-', path.join(app, 'Contents/Info.plist')]));
if (metadata.BlueFatFishAcceptanceOnly !== true) throw Error('Use an acceptance-only application');
const reopen = option('--reopen'), manual = !!reopen || process.argv.includes('--manual-ui'), hash = bytes => createHash('sha256').update(bytes).digest('hex');
await mkdir(path.join(root, 'evidence/agent'), { recursive: true });
const output = reopen ? path.resolve(reopen) : await mkdtemp(path.join(root, 'evidence/agent/browser-workspace-command-'));
for (const name of ['tmp', 'shared-home', 'workspace']) await mkdir(path.join(output, name), { recursive: true });
if (!reopen) {
  await copyFile(path.join(root, 'README.md'), path.join(output, 'workspace/README.md'));
  await writeFile(path.join(output, 'browser-input.json'), JSON.stringify({ url: 'http://127.0.0.1:4179/', readmeSHA256: hash(await readFile(path.join(output, 'workspace/README.md'))) }, null, 2) + '\n');
}
if (await fetch('http://127.0.0.1:4179/').then(() => true).catch(() => false)) throw Error('Port 4179 is occupied; existing process preserved');
const env = { ...process.env, TMPDIR: path.join(output, 'tmp') + '/' };
const server = spawn(process.execPath, [path.join(root, 'node_modules/vite/bin/vite.js'), '--host', '127.0.0.1', '--port', '4179', '--strictPort'], { cwd: root, env, stdio: ['ignore', 'pipe', 'pipe'] });
const serverLog = createWriteStream(path.join(output, `server-${Date.now()}.log`)); server.stdout.pipe(serverLog, { end: false }); server.stderr.pipe(serverLog, { end: false });
try {
  let ready = false;
  for (let i = 0; i < 100; i++) {
    if (server.exitCode !== null) throw Error('Project preview exited');
    if (await fetch('http://127.0.0.1:4179/').then(r => r.ok).catch(() => false)) { ready = true; break; }
    await new Promise(resolve => setTimeout(resolve, 100));
  }
  if (!ready) throw Error('Actual project preview is not ready');
  const binary = path.join(app, 'Contents/MacOS/BlueFatFish'), binaryHash = hash(await readFile(binary));
  const phase = reopen ? `restart-${Date.now()}` : 'initial';
  const args = ['--check', output, ...(manual ? ['--manual-ui', reopen ? '--browser-workspace-reopen' : '--browser-workspace-fixtures'] : ['--browser-workspace-check'])];
  const child = spawn(binary, args, { cwd: root, env, stdio: ['ignore', 'pipe', 'pipe'] });
  const finished = new Promise((resolve, reject) => { child.once('error', reject); child.once('close', (code, signal) => resolve({ code, signal })); });
  const log = createWriteStream(path.join(output, `launch-${phase}.log`)); child.stdout.pipe(log, { end: false }); child.stderr.pipe(log, { end: false });
  await writeFile(path.join(output, `launch-${phase}.json`), JSON.stringify({ app, appPID: child.pid, binaryHash, serverPID: server.pid, args }, null, 2) + '\n');
  console.log(JSON.stringify({ output, appPID: child.pid, binaryHash, manual }));
  const status = await finished; log.end();
  const report = JSON.parse(await readFile(path.join(output, manual ? `manual-ui-result-${child.pid}.json` : 'browser-workspace-report.json'), 'utf8'));
  const fixture = JSON.parse(await readFile(path.join(output, 'browser-workspace-fixtures.json'), 'utf8'));
  const tasks = await Promise.all((await readdir(path.join(output, 'profile/agent'))).filter(n => /^[0-9a-f-]{36}\.json$/i.test(n)).map(n => readFile(path.join(output, 'profile/agent', n), 'utf8').then(JSON.parse)));
  const input = JSON.parse(await readFile(path.join(output, 'browser-input.json'), 'utf8'));
  const independent = { sameApplication: report.appPID === child.pid && report.binaryHash === binaryHash && hash(await readFile(binary)) === binaryHash,
    noModelRequests: report.modelRequests === 0 && tasks.every(t => !t.inputTokens && !t.outputTokens && !(t.modelReceipts ?? []).length && !t.messages.length),
    firstInputPreserved: tasks.find(t => t.id === fixture.taskID)?.draft?.startsWith('保留浏览器任务输入。') === true,
    otherInputPreserved: tasks.find(t => t.id === fixture.otherID)?.draft === '保留另一浏览器任务输入。',
    publicReadmeBytesPreserved: hash(await readFile(path.join(output, 'workspace/README.md'))) === input.readmeSHA256 };
  if (!manual && report.attachment) independent.actualAttachmentHashMatches = hash(await readFile(report.attachment.path)) === report.attachment.sha256;
  const success = status.code === 0 && (manual || report.success === true) && Object.values(independent).every(Boolean);
  await writeFile(path.join(output, `independent-${phase}.json`), JSON.stringify({ ...report, independent, status, success }, null, 2) + '\n');
  console.log(JSON.stringify({ output, success, checks: Object.keys(report.checks ?? {}).length, failed: Object.keys(report.checks ?? {}).filter(k => !report.checks[k]), independent, error: report.error })); process.exitCode = success ? 0 : 1;
} finally {
  if (server.exitCode === null && server.signalCode === null) { server.kill('SIGTERM'); await new Promise(resolve => server.once('close', resolve)); } serverLog.end();
}

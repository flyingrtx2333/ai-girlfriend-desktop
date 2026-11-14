import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { createWriteStream } from 'node:fs';
import { mkdir, mkdtemp, readFile, readdir, writeFile } from 'node:fs/promises';
import { setTimeout as delay } from 'node:timers/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { verifyNativeCandidate } from './native-signing.mjs';

const root = fileURLToPath(new URL('../', import.meta.url));
if (!process.env.BLUEFATFISH_APP || process.argv.length !== 2) throw Error('Use BLUEFATFISH_APP to select the independent local acceptance application; this check does not call models.');
const app = path.resolve(process.env.BLUEFATFISH_APP);
if (verifyNativeCandidate(app).kind !== 'isolated-local') throw Error('Use the independent local acceptance application.');
const output = await mkdtemp(path.join(root, 'evidence/agent/mcp-sse-command-'));
for (const name of ['server', 'shared-home', 'tmp']) await mkdir(path.join(output, name));
const binary = path.join(app, 'Contents/MacOS/BlueFatFish'), hash = data => createHash('sha256').update(data).digest('hex'), binaryHash = hash(await readFile(binary));
const log = createWriteStream(path.join(output, 'launch.log'));
const server = spawn(process.execPath, [path.join(root, 'native-mcp/Tests/BlueFatFishMCPTests/legacy-sse.mjs'), path.join(output, 'server')], { stdio: ['ignore', 'pipe', 'pipe'] });
server.stdout.pipe(log, { end: false }); server.stderr.pipe(log, { end: false });
const exited = child => new Promise((resolve, reject) => { child.once('error', reject); child.once('close', (code, signal) => resolve({ code, signal })); });
const serverExit = exited(server); let child, timer;
try {
  let ready;
  for (let i = 0; i < 100; i++) { try { ready = JSON.parse(await readFile(path.join(output, 'server/ready.json'), 'utf8')); break; } catch { await delay(25); } }
  if (ready?.pid !== server.pid) throw Error('The actual local SSE service did not become ready.');
  const args = ['--check', output, '--mcp-sse-check'];
  child = spawn(binary, args, { stdio: ['ignore', 'pipe', 'pipe'], env: { ...process.env, TMPDIR: path.join(output, 'tmp') + '/' } });
  child.stdout.pipe(log, { end: false }); child.stderr.pipe(log, { end: false });
  await writeFile(path.join(output, 'process.json'), JSON.stringify({ app, appPID: child.pid, serverPID: server.pid, binaryHash, args }, null, 2) + '\n');
  timer = setTimeout(() => child.kill('SIGTERM'), 60_000);
  const status = await exited(child); clearTimeout(timer);
  const report = JSON.parse(await readFile(path.join(output, 'mcp-sse-report.json'), 'utf8'));
  await delay(150);
  const records = (await readFile(path.join(output, 'server/requests.jsonl'), 'utf8')).trim().split('\n').map(JSON.parse);
  const rpc = records.filter(value => value.kind === 'rpc');
  const profile = path.join(output, 'profile/agent');
  const tasks = await Promise.all((await readdir(profile)).filter(name => name.endsWith('.json') && name !== 'index.json').map(name => readFile(path.join(profile, name), 'utf8').then(JSON.parse)));
  const independent = {
    sameApplication: report.appPID === child.pid && hash(await readFile(binary)) === binaryHash,
    sameActualServer: report.fixtureServerPID === server.pid,
    actualSSEToolRequestAndAnswer: rpc.some(value => value.mode === 'split' && value.message.method === 'tools/call' && value.message.params.arguments.value === '应用实际 SSE 原文 🧭') && report.actualResult?.includes('应用实际 SSE 原文 🧭') === true,
    actualHTTPRemainsSeparate: records.some(value => value.kind === 'http-rpc' && value.message.method === 'tools/call' && value.message.params.arguments.value === 'HTTP 公开回归'),
    unapprovedAddressesNeverContacted: !records.some(value => value.kind === 'unapproved'),
    allStreamsClosed: records.filter(value => value.kind === 'opened').length === records.filter(value => value.kind === 'closed').length,
    noModels: report.modelRequests === 0 && tasks.every(task => !task.inputTokens && !task.outputTokens && !(task.modelReceipts ?? []).length)
  };
  const success = status.code === 0 && report.success && Object.values(report.checks).every(Boolean) && Object.values(independent).every(Boolean);
  server.kill('SIGTERM'); const serverStatus = await serverExit;
  const proof = { ...report, output, binaryHash, independent, status, serverStatus, success: success && serverStatus.code === 0 };
  await writeFile(path.join(output, 'independent-initial.json'), JSON.stringify(proof, null, 2) + '\n');
  console.log(JSON.stringify({ output, binaryHash, appPID: child.pid, success: proof.success, checks: Object.keys(report.checks).length, failed: Object.keys(report.checks).filter(key => !report.checks[key]), independent, error: report.error }));
  process.exitCode = proof.success ? 0 : 1;
} finally {
  clearTimeout(timer);
  if (child?.exitCode === null && child.signalCode === null) child.kill('SIGTERM');
  if (server.exitCode === null && server.signalCode === null) { server.kill('SIGTERM'); await serverExit; }
  log.end();
}

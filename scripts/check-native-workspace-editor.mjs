import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdir, mkdtemp, readFile, readdir, writeFile } from 'node:fs/promises';
import { createWriteStream } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { verifyNativeCandidate } from './native-signing.mjs';

const root = fileURLToPath(new URL('../', import.meta.url));
const index = process.argv.indexOf('--reopen'), reopen = index < 0 ? undefined : process.argv[index + 1];
const manual = !!reopen || process.argv.includes('--manual-ui');
if (process.argv.includes('--live-agent')) throw Error('Workspace editor native acceptance does not call models');
if (index >= 0 && !reopen) throw Error('--reopen needs the existing independent profile');
const evidence = path.join(root, 'evidence/agent'); await mkdir(evidence, { recursive: true });
const output = reopen ? path.resolve(reopen) : await mkdtemp(path.join(evidence, 'workspace-editor-command-'));
if (!output.startsWith(evidence + path.sep)) throw Error('Use the external repository evidence directory');
for (const name of ['shared-home', 'tmp']) await mkdir(path.join(output, name), { recursive: true });
if (reopen) await readFile(path.join(output, 'workspace-editor-fixtures.json'));
if (!process.env.BLUEFATFISH_APP) throw Error('Specify the independent acceptance app');
const app = path.resolve(process.env.BLUEFATFISH_APP), binary = path.join(app, 'Contents/MacOS/BlueFatFish');
if (verifyNativeCandidate(app).kind !== 'isolated-local') throw Error('Use the isolated local acceptance app');
const hash = bytes => createHash('sha256').update(bytes).digest('hex'), binaryHash = hash(await readFile(binary));
const phase = reopen ? 'restart-' + Date.now() : 'initial';
const args = ['--check', output, ...(manual ? ['--manual-ui', reopen ? '--workspace-editor-reopen' : '--workspace-editor-fixtures'] : ['--workspace-editor-check'])];
const child = spawn(binary, args, { stdio: ['ignore', 'pipe', 'pipe'], env: { ...process.env, TMPDIR: path.join(output, 'tmp') + '/' } });
const log = createWriteStream(path.join(output, 'launch-' + phase + '.log')); child.stdout.pipe(log, { end: false }); child.stderr.pipe(log, { end: false });
await writeFile(path.join(output, 'launch-' + phase + '.json'), JSON.stringify({ app, appPID: child.pid, binaryHash, args }, null, 2) + '\n');
console.log(JSON.stringify({ output, appPID: child.pid, binaryHash, manual }));
try {
  const status = await new Promise((resolve, reject) => { child.once('error', reject); child.once('close', (code, signal) => resolve({ code, signal })); });
  const report = JSON.parse(await readFile(path.join(output, manual ? 'manual-ui-result-' + child.pid + '.json' : 'workspace-editor-report.json'), 'utf8'));
  const directory = path.join(output, manual ? 'profile/agent' : 'profile/agent');
  const names = (await readdir(directory)).filter(name => name.endsWith('.json') && name !== 'index.json');
  const tasks = await Promise.all(names.map(name => readFile(path.join(directory, name), 'utf8').then(JSON.parse)));
  const independent = { sameApplication: report.appPID === child.pid && hash(await readFile(binary)) === binaryHash,
    noModelRequests: report.modelRequests === 0 && (report.blockedModelAttempts ?? 0) === 0 && tasks.every(task => !task.inputTokens && !task.outputTokens && !(task.modelReceipts ?? []).length) };
  const success = status.code === 0 && (manual || report.success === true && Object.values(report.checks).every(Boolean)) && Object.values(independent).every(Boolean);
  await writeFile(path.join(output, 'independent-' + phase + '.json'), JSON.stringify({ ...report, binaryHash, independent, status, success }, null, 2) + '\n');
  console.log(JSON.stringify({ output, binaryHash, appPID: child.pid, success, checks: Object.keys(report.checks ?? {}).length, failed: Object.keys(report.checks ?? {}).filter(key => !report.checks[key]), independent, error: report.error }));
  process.exitCode = success ? 0 : 1;
} finally { log.end(); }

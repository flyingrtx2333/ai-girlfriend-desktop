import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdir, mkdtemp, readFile, readdir, realpath, writeFile } from 'node:fs/promises';
import { createWriteStream } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { verifyNativeCandidate } from './native-signing.mjs';

const root = fileURLToPath(new URL('../', import.meta.url));
const index = process.argv.indexOf('--reopen'), reopen = index < 0 ? undefined : process.argv[index + 1];
const manual = !!reopen || process.argv.includes('--manual-ui');
if (process.argv.includes('--live-agent')) throw Error('Connector menu acceptance does not call models');
if (index >= 0 && !reopen) throw Error('--reopen needs the existing independent profile');
if (!process.env.BLUEFATFISH_APP) throw Error('Specify the independent acceptance application with BLUEFATFISH_APP');
const app = path.resolve(process.env.BLUEFATFISH_APP), signature = verifyNativeCandidate(app);
if (signature.kind !== 'isolated-local') throw Error('Use the independent local acceptance application');
const evidence = path.join(root, 'evidence/agent'); await mkdir(evidence, { recursive: true });
const output = reopen ? path.resolve(reopen) : await mkdtemp(path.join(evidence, 'slash-connectors-command-'));
if (!output.startsWith(evidence + path.sep)) throw Error('Use the external repository evidence directory');
for (const name of ['shared-home', 'tmp']) await mkdir(path.join(output, name), { recursive: true });
if (reopen) await readFile(path.join(output, 'slash-connectors-fixtures.json'));
else {
  if (!process.env.BLUEFATFISH_MCP_FILESYSTEM_ENTRY) throw Error('Specify an installed official filesystem server; this check does not download dependencies');
  const entry = await realpath(process.env.BLUEFATFISH_MCP_FILESYSTEM_ENTRY);
  if (!entry.startsWith(root) || !entry.endsWith('/@modelcontextprotocol/server-filesystem/dist/index.js')) throw Error('Use the actual official server installed on the external project volume');
  const pkg = JSON.parse(await readFile(path.resolve(entry, '../../package.json'), 'utf8'));
  await writeFile(path.join(output, 'dependencies.json'), JSON.stringify({ node: await realpath(process.execPath), serverEntry: entry, package: pkg.name, version: pkg.version }, null, 2) + '\n');
}
const binary = path.join(app, 'Contents/MacOS/BlueFatFish'), hash = bytes => createHash('sha256').update(bytes).digest('hex'), binaryHash = hash(await readFile(binary));
const phase = reopen ? 'restart-' + Date.now() : 'initial';
const args = ['--check', output, ...(manual ? ['--manual-ui', reopen ? '--slash-connectors-reopen' : '--slash-connectors-fixtures'] : ['--general-settings-check', '--slash-connectors-check'])];
const child = spawn(binary, args, { stdio: ['ignore', 'pipe', 'pipe'], env: { ...process.env, TMPDIR: path.join(output, 'tmp') + '/' } });
const log = createWriteStream(path.join(output, 'launch-' + phase + '.log')); child.stdout.pipe(log, { end: false }); child.stderr.pipe(log, { end: false });
await writeFile(path.join(output, 'launch-' + phase + '.json'), JSON.stringify({ app, appPID: child.pid, binaryHash, args }, null, 2) + '\n');
console.log(JSON.stringify({ output, appPID: child.pid, binaryHash, manual }));
try {
  const status = await new Promise((resolve, reject) => { child.once('error', reject); child.once('close', (code, signal) => resolve({ code, signal })); });
  const report = JSON.parse(await readFile(path.join(output, manual ? 'manual-ui-result-' + child.pid + '.json' : 'slash-connectors-report.json'), 'utf8'));
  const directory = path.join(output, 'profile/agent');
  const names = (await readdir(directory)).filter(name => name.endsWith('.json') && name !== 'index.json');
  const tasks = await Promise.all(names.map(name => readFile(path.join(directory, name), 'utf8').then(JSON.parse)));
  const independent = { sameApplication: report.appPID === child.pid && hash(await readFile(binary)) === binaryHash,
    noModelRequests: report.modelRequests === 0 && (report.blockedModelAttempts ?? 0) === 0 && tasks.every(task => !task.inputTokens && !task.outputTokens && !(task.modelReceipts ?? []).length) };
  if (!manual && report.actualRead) {
    const actual = report.actualRead, source = await readFile(actual.source);
    independent.actualPublicSource = hash(source) === actual.sourceHash && actual.result.includes(source.toString('utf8').trim());
  }
  const success = status.code === 0 && (manual || report.success === true && Object.values(report.checks).every(Boolean) && independent.actualPublicSource === true) && Object.values(independent).every(Boolean);
  await writeFile(path.join(output, 'independent-' + phase + '.json'), JSON.stringify({ ...report, binaryHash, independent, status, success }, null, 2) + '\n');
  console.log(JSON.stringify({ output, binaryHash, appPID: child.pid, success, checks: Object.keys(report.checks ?? {}).length, failed: Object.keys(report.checks ?? {}).filter(key => !report.checks[key]), independent, error: report.error }));
  process.exitCode = success ? 0 : 1;
} finally { log.end(); }

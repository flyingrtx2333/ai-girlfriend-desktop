import { spawn, spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { createWriteStream } from 'node:fs';
import { mkdir, mkdtemp, readFile, readdir, writeFile, copyFile, realpath } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../', import.meta.url));
const option = name => { const i = process.argv.indexOf(name); return i < 0 ? undefined : process.argv[i + 1]; };
if (process.argv.includes('--live-agent')) throw Error('Knowledge review acceptance does not call models');
const app = process.env.BLUEFATFISH_APP;
if (!app) throw Error('Set BLUEFATFISH_APP to an independent acceptance application');
function command(file, args) { const p = spawnSync(file, args, { encoding: 'utf8' }); if (p.status !== 0) throw Error(p.stderr || file); return p.stdout; }
command('/usr/bin/codesign', ['--verify', '--deep', '--strict', app]);
const metadata = JSON.parse(command('/usr/bin/plutil', ['-convert', 'json', '-o', '-', path.join(app, 'Contents/Info.plist')]));
if (metadata.BlueFatFishAcceptanceOnly !== true) throw Error('Use an acceptance-only application');
const reopen = option('--reopen'), manual = !!reopen || process.argv.includes('--manual-ui'), hash = bytes => createHash('sha256').update(bytes).digest('hex');
await mkdir(path.join(root, 'evidence/agent'), { recursive: true });
const output = reopen ? path.resolve(reopen) : await mkdtemp(path.join(root, 'evidence/agent/knowledge-review-command-'));
if (!output.startsWith(path.join(root, 'evidence/agent/knowledge-review-command-'))) throw Error('Preserve the original knowledge review acceptance directory');
if (await realpath(output) !== output) throw Error('Use the original acceptance directory without a symbolic link');
for (const name of ['tmp', 'shared-home', 'source']) await mkdir(path.join(output, name), { recursive: true });
const source = path.join(output, 'source/README.md');
if (!reopen) { await copyFile(path.join(root, 'README.md'), source); await writeFile(path.join(output, 'source-input.json'), JSON.stringify({ sha256: hash(await readFile(source)) }, null, 2) + '\n'); }
const binary = path.join(app, 'Contents/MacOS/BlueFatFish'), binaryHash = hash(await readFile(binary)), phase = reopen ? `restart-${Date.now()}` : 'initial';
const args = ['--check', output, '--knowledge-page-source', source, ...(manual ? ['--manual-ui', reopen ? '--knowledge-review-reopen' : '--knowledge-review-fixtures'] : ['--knowledge-review-check'])];
const child = spawn(binary, args, { cwd: root, env: { ...process.env, TMPDIR: path.join(output, 'tmp') + '/' }, stdio: ['ignore', 'pipe', 'pipe'] });
const finished = new Promise((resolve, reject) => { child.once('error', reject); child.once('close', (code, signal) => resolve({ code, signal })); });
const log = createWriteStream(path.join(output, `launch-${phase}.log`)); child.stdout.pipe(log, { end: false }); child.stderr.pipe(log, { end: false });
await writeFile(path.join(output, `launch-${phase}.json`), JSON.stringify({ app, appPID: child.pid, binaryHash, args }, null, 2) + '\n');
console.log(JSON.stringify({ output, appPID: child.pid, binaryHash, manual }));
const status = await finished; log.end();
const report = await readFile(path.join(output, manual ? `manual-ui-result-${child.pid}.json` : 'knowledge-review-report.json'), 'utf8').then(JSON.parse).catch(async error => {
  if (error.code !== 'ENOENT' || !manual) throw error;
  return JSON.parse(await readFile(path.join(output, `manual-ui-error-${child.pid}.json`), 'utf8'));
});
const fixture = await readFile(path.join(output, 'knowledge-review-fixtures.json'), 'utf8').then(JSON.parse).catch(error => { if (error.code !== 'ENOENT') throw error; return null; });
const tasks = await Promise.all((await readdir(path.join(output, 'profile/agent'))).filter(n => /^[0-9a-f-]{36}\.json$/i.test(n)).map(n => readFile(path.join(output, 'profile/agent', n), 'utf8').then(JSON.parse)));
const input = JSON.parse(await readFile(path.join(output, 'source-input.json'), 'utf8'));
const independent = { sameApplication: report.appPID === child.pid && report.binaryHash === binaryHash && hash(await readFile(binary)) === binaryHash,
  noModelRequests: report.modelRequests === 0 && tasks.every(t => !t.inputTokens && !t.outputTokens && !(t.modelReceipts ?? []).length && !t.messages.length),
  projectInputPreserved: !!fixture && tasks.find(t => t.id === fixture.taskID)?.draft === '项目任务未发送的草稿。',
  standaloneInputPreserved: !!fixture && tasks.find(t => t.id === fixture.standaloneID)?.draft === '无工作区任务未发送的草稿。',
  publicReadmeBytesPreserved: !!fixture && hash(await readFile(source)) === input.sha256 && hash(await readFile(path.join(fixture.workspace, 'README.md'))) === input.sha256 };
const success = status.code === 0 && (manual || report.success === true) && Object.values(independent).every(Boolean);
await writeFile(path.join(output, `independent-${phase}.json`), JSON.stringify({ ...report, independent, status, success }, null, 2) + '\n');
console.log(JSON.stringify({ output, success, checks: Object.keys(report.checks ?? {}).length, failed: Object.keys(report.checks ?? {}).filter(k => !report.checks[k]), independent, error: report.error })); process.exitCode = success ? 0 : 1;

import { spawn, spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdir, mkdtemp, readFile, readdir, writeFile } from 'node:fs/promises';
import { createWriteStream } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const root = fileURLToPath(new URL('../', import.meta.url));
const option = name => { const index = process.argv.indexOf(name); return index < 0 ? undefined : process.argv[index + 1]; };
if (process.argv.includes('--live-agent')) throw Error('Artifact workspace acceptance does not call models');
const reopen = option('--reopen'), manual = !!reopen || process.argv.includes('--manual-ui');
await mkdir(path.join(root, 'evidence/agent'), { recursive: true });
const output = reopen ? path.resolve(reopen) : await mkdtemp(path.join(root, 'evidence/agent/artifact-workspace-command-'));
for (const directory of ['shared-home', 'tmp']) await mkdir(path.join(output, directory), { recursive: true });
const python = option('--python') ?? '/usr/bin/python3';
if (!reopen) {
  await mkdir(path.join(output, 'originals'));
  const fixture = spawnSync(python, [path.join(root, 'scripts/fixtures/office-documents.py'), path.join(output, 'originals')], { encoding: 'utf8', env: { ...process.env, TMPDIR: path.join(output, 'tmp') + '/' } });
  if (fixture.status !== 0) throw Error(fixture.stderr || 'Prepare python-docx, openpyxl, python-pptx and Pillow in the selected Python environment');
}
const app = process.env.BLUEFATFISH_APP ?? path.join(root, 'build/蓝色大肥鱼.app'), binary = path.join(app, 'Contents/MacOS/BlueFatFish');
const hash = bytes => createHash('sha256').update(bytes).digest('hex'), binaryHash = hash(await readFile(binary));
const phase = reopen ? `restart-${Date.now()}` : 'initial';
const args = ['--check', output, ...(manual ? ['--manual-ui', reopen ? '--artifact-workspace-reopen' : '--artifact-workspace-fixtures'] : ['--artifact-workspace-check'])];
const child = spawn(binary, args, { stdio: ['ignore', 'pipe', 'pipe'], env: { ...process.env, TMPDIR: path.join(output, 'tmp') + '/' } });
const log = createWriteStream(path.join(output, `launch-${phase}.log`)); child.stdout.pipe(log, { end: false }); child.stderr.pipe(log, { end: false });
await writeFile(path.join(output, `launch-${phase}.json`), JSON.stringify({ app, appPID: child.pid, binaryHash, args }, null, 2) + '\n');
console.log(JSON.stringify({ output, appPID: child.pid, binaryHash, manual }));
try {
  const status = await new Promise((resolve, reject) => { child.once('error', reject); child.once('close', (code, signal) => resolve({ code, signal })); });
  const report = JSON.parse(await readFile(path.join(output, manual ? `manual-ui-result-${child.pid}.json` : 'artifact-workspace-report.json'), 'utf8'));
  const directory = path.join(output, 'profile/agent'), names = (await readdir(directory)).filter(name => name.endsWith('.json') && name !== 'index.json');
  const tasks = await Promise.all(names.map(name => readFile(path.join(directory, name), 'utf8').then(JSON.parse)));
  const originalHashes = JSON.parse(await readFile(path.join(output, 'originals/source-sha256.json'), 'utf8'));
  const independent = { sameApplication: report.appPID === child.pid && report.binaryHash === binaryHash && hash(await readFile(binary)) === binaryHash,
    noModelRequests: report.modelRequests === 0 && tasks.every(task => !task.inputTokens && !task.outputTokens && !(task.modelReceipts ?? []).length),
    originalsUnchanged: (await Promise.all(Object.entries(originalHashes).map(async ([name, expected]) => hash(await readFile(path.join(output, 'originals', name))) === expected))).every(Boolean) };
  let documents;
  if (!manual && report.workspace) {
    const result = spawnSync(python, [path.join(root, 'scripts/fixtures/verify-office-documents.py'), path.join(output, 'originals'), report.workspace, '审阅人：工作区验收'], { encoding: 'utf8' });
    try { documents = JSON.parse(result.stdout); } catch { throw Error(result.stderr || result.stdout); }
    independent.actualOfficeFilesVerifiedIndependently = result.status === 0 && documents.success === true;
  } else if (!manual) independent.actualOfficeFilesVerifiedIndependently = false;
  const success = status.code === 0 && (manual || report.success === true && Object.values(report.checks).every(Boolean)) && Object.values(independent).every(Boolean);
  await writeFile(path.join(output, `independent-${phase}.json`), JSON.stringify({ ...report, independent, documents, status, success }, null, 2) + '\n');
  console.log(JSON.stringify({ output, success, checks: Object.keys(report.checks ?? {}).length, failed: Object.keys(report.checks ?? {}).filter(key => !report.checks[key]), independent, error: report.error }));
  process.exitCode = success ? 0 : 1;
} finally { log.end(); }

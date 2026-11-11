import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdir, mkdtemp, readFile, readdir, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const root = fileURLToPath(new URL('../', import.meta.url));
const reopen = process.argv.indexOf('--reopen'), manual = reopen >= 0 || process.argv.includes('--manual-ui');
await mkdir(path.join(root, 'evidence/agent'), { recursive: true });
const output = reopen >= 0 ? path.resolve(process.argv[reopen + 1]) : await mkdtemp(path.join(root, 'evidence/agent/task-workspace-command-'));
for (const directory of ['shared-home', 'tmp']) await mkdir(path.join(output, directory), { recursive: true });
const app = process.env.BLUEFATFISH_APP ?? path.join(root, 'build/蓝色大肥鱼.app');
const binary = path.join(app, 'Contents/MacOS/BlueFatFish');
const hash = data => createHash('sha256').update(data).digest('hex');
const binaryHash = hash(await readFile(binary)), phase = reopen >= 0 ? `restart-${Date.now()}` : 'initial';
const args = ['--check', output, ...(manual ? ['--manual-ui', reopen >= 0 ? '--task-workspace-reopen' : '--task-workspace-fixtures'] : ['--task-workspace-check']), '--task-workspace-source', root];
const logs = [], child = spawn(binary, args, { env: { ...process.env, TMPDIR: path.join(output, 'tmp') + '/' }, stdio: ['ignore', 'pipe', 'pipe'] });
child.stdout.on('data', data => logs.push(data)); child.stderr.on('data', data => logs.push(data));
await writeFile(path.join(output, `launch-${phase}.json`), JSON.stringify({ app, binaryHash, appPID: child.pid, args }, null, 2) + '\n');
console.log(JSON.stringify({ output, appPID: child.pid, binaryHash, manual }));
try {
  const status = await new Promise((resolve, reject) => {
    const timer = setTimeout(() => { child.kill('SIGTERM'); reject(Error('Task workspace acceptance timed out')); }, manual ? 3650000 : 180000);
    child.once('error', error => { clearTimeout(timer); reject(error); });
    child.once('exit', (code, signal) => { clearTimeout(timer); resolve({ code, signal }); });
  });
  const report = JSON.parse(await readFile(path.join(output, manual ? `manual-ui-result-${child.pid}.json` : 'task-workspace-report.json'), 'utf8'));
  const names = (await readdir(path.join(output, 'profile/agent'))).filter(name => name.endsWith('.json') && name !== 'index.json');
  const tasks = await Promise.all(names.map(name => readFile(path.join(output, 'profile/agent', name), 'utf8').then(JSON.parse)));
  const fixture = JSON.parse(await readFile(path.join(output, 'task-workspace-fixtures.json'), 'utf8'));
  const independent = { sameApplication: hash(await readFile(binary)) === binaryHash && report.binaryHash === binaryHash && report.appPID === child.pid,
    noModelRequests: report.modelRequests === 0 && tasks.every(task => !task.inputTokens && !task.outputTokens && !(task.modelReceipts ?? []).length),
    publicSourceUnchanged: hash(await readFile(path.join(root, 'docs/AGENT-READING.md'))) === fixture.originalSourceSHA256 };
  if (!manual) independent.savedDraftMatchesActualFile = !!report.retainedConflictDraft && (await readFile(fixture.guide)).equals(Buffer.from(report.retainedConflictDraft.encodedDraftBase64, 'base64'));
  const success = status.code === 0 && (manual || report.success === true && Object.keys(report.checks).length > 0 && Object.values(report.checks).every(Boolean)) && Object.values(independent).every(Boolean);
  await writeFile(path.join(output, `independent-${phase}.json`), JSON.stringify({ ...report, success, independent, status }, null, 2) + '\n');
  console.log(JSON.stringify({ output, success, checks: Object.keys(report.checks ?? {}).length, failed: Object.keys(report.checks ?? {}).filter(key => !report.checks[key]), independent, error: report.error }));
  process.exitCode = success ? 0 : 1;
} finally {
  await writeFile(path.join(output, `launch-${phase}.log`), Buffer.concat(logs));
  if (child.exitCode === null && child.signalCode === null) child.kill('SIGTERM');
}

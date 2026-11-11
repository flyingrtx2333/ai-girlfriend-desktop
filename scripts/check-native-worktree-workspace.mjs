import { spawn, spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdir, mkdtemp, readFile, readdir, writeFile } from 'node:fs/promises';
import { createWriteStream } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const root = fileURLToPath(new URL('../', import.meta.url));
const option = name => { const index = process.argv.indexOf(name); return index < 0 ? undefined : process.argv[index + 1]; };
if (process.argv.includes('--live-agent')) throw Error('Worktree workspace acceptance does not call models');
const reopen = option('--reopen'), manual = !!reopen || process.argv.includes('--manual-ui');
await mkdir(path.join(root, 'evidence/agent'), { recursive: true });
const output = reopen ? path.resolve(reopen) : await mkdtemp(path.join(root, 'evidence/agent/worktree-workspace-command-'));
for (const name of ['tmp', 'shared-home']) await mkdir(path.join(output, name), { recursive: true });
const app = process.env.BLUEFATFISH_APP ?? path.join(root, 'build/蓝色大肥鱼.app'), binary = path.join(app, 'Contents/MacOS/BlueFatFish');
const hash = bytes => createHash('sha256').update(bytes).digest('hex'), binaryHash = hash(await readFile(binary)), phase = reopen ? `restart-${Date.now()}` : 'initial';
const args = ['--check', output, ...(manual ? ['--manual-ui', reopen ? '--worktree-workspace-reopen' : '--worktree-workspace-fixtures'] : ['--worktree-workspace-check'])];
const child = spawn(binary, args, { stdio: ['ignore', 'pipe', 'pipe'], env: { ...process.env, TMPDIR: path.join(output, 'tmp') + '/' } });
const log = createWriteStream(path.join(output, `launch-${phase}.log`)); child.stdout.pipe(log, { end: false }); child.stderr.pipe(log, { end: false });
await writeFile(path.join(output, `launch-${phase}.json`), JSON.stringify({ app, appPID: child.pid, binaryHash, args }, null, 2) + '\n');
console.log(JSON.stringify({ output, appPID: child.pid, binaryHash, manual }));
try {
  const status = await new Promise((resolve, reject) => { child.once('error', reject); child.once('close', (code, signal) => resolve({ code, signal })); });
  const report = JSON.parse(await readFile(path.join(output, manual ? `manual-ui-result-${child.pid}.json` : 'worktree-workspace-report.json'), 'utf8'));
  const fixture = JSON.parse(await readFile(path.join(output, 'worktree-workspace-fixtures.json'), 'utf8'));
  const directory = path.join(output, 'profile/agent'), names = (await readdir(directory)).filter(name => name.endsWith('.json') && name !== 'index.json');
  const tasks = await Promise.all(names.map(name => readFile(path.join(directory, name), 'utf8').then(JSON.parse)));
  const git = (cwd, args) => { const value = spawnSync('git', ['-C', cwd, ...args], { encoding: 'utf8' }); if (value.status !== 0) throw Error(value.stderr); return value.stdout; };
  const independent = { sameApplication: report.appPID === child.pid && report.binaryHash === binaryHash && hash(await readFile(binary)) === binaryHash,
    noModelRequests: report.modelRequests === 0 && tasks.every(task => !task.inputTokens && !task.outputTokens && !(task.modelReceipts ?? []).length),
    sourceRawIndexPreserved: hash(await readFile(path.join(fixture.workspace, '.git/index'))) === fixture.sourceIndexSHA256,
    sourceStagingAndWorkingRemainSeparate: git(fixture.workspace, ['show', ':public.txt']) === 'staged-public\n' && await readFile(path.join(fixture.workspace, 'public.txt'), 'utf8') === 'working-public\n',
    externalCheckoutPreserved: git(fixture.foreign, ['symbolic-ref', 'HEAD']).trim() === 'refs/heads/acceptance/external' };
  if (!manual && report.createdWorkspace && report.backupID) {
    const backup = JSON.parse(await readFile(path.join(directory, 'worktrees', report.backupID, 'record.json'), 'utf8'));
    independent.actualCreatedCheckoutUsesReviewedBase = git(report.createdWorkspace, ['rev-parse', 'HEAD']).trim() === fixture.releaseHead && git(report.createdWorkspace, ['show', ':public.txt']) === 'base-public\n' && await readFile(path.join(report.createdWorkspace, 'public.txt'), 'utf8') === 'working-public\n';
    independent.actualBackupRestoredOriginalCheckout = backup.state === 'restored' && backup.origin.path === fixture.child && git(fixture.child, ['show', ':public.txt']) === 'child-staged\n' && await readFile(path.join(fixture.child, 'public.txt'), 'utf8') === 'child-working\n' && await readFile(path.join(fixture.child, 'local-only.txt'), 'utf8') === 'child-ignored\n';
    const actualMetadata = git(fixture.child, ['rev-parse', '--absolute-git-dir']).trim();
    independent.actualChildRawIndexBytesRestored = hash(await readFile(path.join(actualMetadata, 'index'))) === report.childIndexBeforeSHA256 && report.childIndexBeforeSHA256 === backup.indexHash;
  } else if (!manual) independent.actualArtifactsExist = false;
  const success = status.code === 0 && (manual || report.success === true && Object.values(report.checks).every(Boolean)) && Object.values(independent).every(Boolean);
  await writeFile(path.join(output, `independent-${phase}.json`), JSON.stringify({ ...report, independent, status, success }, null, 2) + '\n');
  console.log(JSON.stringify({ output, success, checks: Object.keys(report.checks ?? {}).length, failed: Object.keys(report.checks ?? {}).filter(key => !report.checks[key]), independent, error: report.error }));
  process.exitCode = success ? 0 : 1;
} finally { log.end(); }

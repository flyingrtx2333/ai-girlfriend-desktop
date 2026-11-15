import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdir, mkdtemp, readFile, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const root = fileURLToPath(new URL('../', import.meta.url));
const app = process.env.BLUEFATFISH_APP;
const lifecycle = process.argv.length === 3 && process.argv[2] === '--lifecycle';
if (!app || (!lifecycle && process.argv.length !== 2)) throw Error('请指定独立验收应用，不调用模型。');
const info = spawnSync('/usr/bin/plutil', ['-convert', 'json', '-o', '-', path.join(app, 'Contents/Info.plist')], { encoding: 'utf8' });
if (info.status !== 0 || JSON.parse(info.stdout).BlueFatFishAcceptanceOnly !== true) throw Error('工作区恢复检查只能使用独立验收应用。');
await mkdir(path.join(root, 'evidence/agent'), { recursive: true });
const output = await mkdtemp(path.join(root, 'evidence/agent/workspace-recovery-command-'));
await mkdir(path.join(output, 'tmp'));
const binary = path.join(app, 'Contents/MacOS/BlueFatFish');
const hash = async () => createHash('sha256').update(await readFile(binary)).digest('hex');
const binaryHash = await hash();
const results = [];
for (const stage of lifecycle ? ['seed', 'reopen'] : ['storage']) {
  const flag = lifecycle ? '--workspace-recovery-lifecycle-check' : '--workspace-recovery-check';
  const run = spawnSync(binary, ['--check', output, flag, ...(lifecycle ? ['--recovery-stage', stage] : [])], { encoding: 'utf8', timeout: 180000, env: { ...process.env, TMPDIR: path.join(output, 'tmp') + '/' } });
  await writeFile(path.join(output, `${stage}-stdout.log`), run.stdout ?? '');
  await writeFile(path.join(output, `${stage}-stderr.log`), run.stderr ?? '');
  await writeFile(path.join(output, `${stage}-process.json`), JSON.stringify({ app, appPID: run.pid, binaryHash, exit: run.status, signal: run.signal }, null, 2) + '\n');
  if (run.error || run.status !== 0) throw run.error ?? Error(run.stderr || '工作区恢复检查未完成');
  const bytes = await readFile(path.join(output, lifecycle ? 'workspace-recovery-lifecycle-report.json' : 'workspace-recovery-report.json'));
  await writeFile(path.join(output, `${stage}-report.json`), bytes);
  const report = JSON.parse(bytes);
  const sameApplication = report.appPID === run.pid && report.binaryHash === binaryHash && await hash() === binaryHash;
  const success = sameApplication && report.success === true && report.modelRequests === 0 && Object.keys(report.checks).length > 0 && Object.values(report.checks).every(Boolean);
  const result = { stage, appPID: run.pid, binaryHash, sameApplication, success, checks: Object.keys(report.checks).length, failed: Object.keys(report.checks).filter(key => !report.checks[key]), error: report.error, modelRequests: report.modelRequests };
  results.push(result);
  console.log(JSON.stringify({ output, ...result }));
  if (!success) { process.exitCode = 1; break; }
}
await writeFile(path.join(output, 'results.json'), JSON.stringify(results, null, 2) + '\n');

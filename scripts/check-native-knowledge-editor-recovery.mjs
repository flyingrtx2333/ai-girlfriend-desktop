import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdir, mkdtemp, readFile, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const root = fileURLToPath(new URL('../', import.meta.url));
const app = process.env.BLUEFATFISH_APP;
if (!app || process.argv.length !== 2) throw Error('请指定独立验收应用，不调用模型。');
const info = spawnSync('/usr/bin/plutil', ['-convert', 'json', '-o', '-', path.join(app, 'Contents/Info.plist')], { encoding: 'utf8' });
if (info.status !== 0 || JSON.parse(info.stdout).BlueFatFishAcceptanceOnly !== true) throw Error('知识编辑恢复检查仅使用独立验收应用。');
await mkdir(path.join(root, 'evidence/agent'), { recursive: true });
const output = await mkdtemp(path.join(root, 'evidence/agent/knowledge-editor-recovery-command-'));
for (const name of ['tmp', 'shared-home']) await mkdir(path.join(output, name));
const binary = path.join(app, 'Contents/MacOS/BlueFatFish');
const hash = async () => createHash('sha256').update(await readFile(binary)).digest('hex');
const binaryHash = await hash(), results = [];
for (const stage of ['seed', 'reopen', 'closed']) {
  const run = spawnSync(binary, ['--check', output, '--knowledge-editor-recovery-check', '--recovery-stage', stage], { encoding: 'utf8', timeout: 120000, env: { ...process.env, TMPDIR: path.join(output, 'tmp') + '/' } });
  await writeFile(path.join(output, `${stage}-stdout.log`), run.stdout ?? '');
  await writeFile(path.join(output, `${stage}-stderr.log`), run.stderr ?? '');
  await writeFile(path.join(output, `${stage}-process.json`), JSON.stringify({ app, appPID: run.pid, binaryHash, exit: run.status, signal: run.signal }, null, 2) + '\n');
  if (run.error || run.status !== 0) throw run.error ?? Error(run.stderr || '知识编辑恢复检查未完成');
  const report = JSON.parse(await readFile(path.join(output, `knowledge-editor-${stage}-report.json`), 'utf8'));
  const sameApplication = report.appPID === run.pid && await hash() === binaryHash;
  const success = sameApplication && report.success === true && report.modelRequests === 0 && Object.keys(report.checks).length > 0 && Object.values(report.checks).every(Boolean);
  const result = { stage, appPID: run.pid, binaryHash, sameApplication, success, checks: Object.keys(report.checks).length, failed: Object.keys(report.checks).filter(key => !report.checks[key]), error: report.error, modelRequests: report.modelRequests };
  results.push(result); console.log(JSON.stringify({ output, ...result }));
  if (!success) { process.exitCode = 1; break; }
}
await writeFile(path.join(output, 'results.json'), JSON.stringify(results, null, 2) + '\n');

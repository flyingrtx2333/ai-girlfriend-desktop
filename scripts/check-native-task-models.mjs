import { spawnSync } from 'node:child_process';
import { cp, mkdir, mkdtemp, readFile, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import os from 'node:os';
import path from 'node:path';

const root = fileURLToPath(new URL('../', import.meta.url));
const output = await mkdtemp(path.join(os.tmpdir(), 'bluefatfish-task-models-'));
const workspace = path.join(output, 'workspace');
await mkdir(workspace); await mkdir(path.join(output, 'shared-home'));
for (const name of ['source.json', 'character.png']) await cp(path.join(root, 'public/portraits/whale-maid', name), path.join(workspace, name));
const reuseIndex = process.argv.indexOf('--reuse-real-task'), reuse = reuseIndex >= 0 ? process.argv[reuseIndex + 1] : null;
const contextIndex = process.argv.indexOf('--context-source'), contextSource = contextIndex >= 0 ? process.argv[contextIndex + 1] : null;
if (reuseIndex >= 0 && !reuse) throw new Error('Missing real task path');
if (contextIndex >= 0 && !contextSource) throw new Error('Missing real context source');
if (reuse) {
  const previous = JSON.parse(await readFile(reuse, 'utf8'));
  await cp(path.join(previous.workspace, 'cross-model-report.json'), path.join(workspace, 'cross-model-report.json'));
}
const hash = value => createHash('sha256').update(value).digest('hex');
const sourceBytes = await readFile(path.join(workspace, 'source.json')), image = await readFile(path.join(workspace, 'character.png')), source = JSON.parse(sourceBytes);
const production = path.join(os.homedir(), 'Library/Application Support/BlueFatFish');
const productionHashes = async () => Object.fromEntries(await Promise.all(['settings.json', 'history.json', 'agent/index.json', 'agent/A7A38353-CBA2-431C-84F1-4903E73EA373.json', 'automations/definitions.json', 'models/catalog.json'].map(async name => {
  try { return [name, hash(await readFile(path.join(production, name)))]; } catch (error) { if (error.code === 'ENOENT') return [name, null]; throw error; }
})));
const before = await productionHashes(); await writeFile(path.join(output, 'production-before.json'), JSON.stringify(before, null, 2));
const live = process.argv.includes('--live-agent'), hold = process.argv.includes('--hold-ui'), sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
console.log(JSON.stringify({ output, live, hold }));
const launch = spawnSync('/usr/bin/open', ['-n', path.join(root, 'build/蓝色大肥鱼.app'), '--args', '--check', output, '--task-model-check', ...(live ? ['--live-agent'] : []), ...(hold ? ['--task-model-ui-hold'] : []), ...(reuse ? ['--reuse-real-task', path.resolve(reuse)] : []), ...(contextSource ? ['--context-source', path.resolve(contextSource)] : [])], { encoding: 'utf8' });
if (launch.status !== 0) throw new Error(launch.stderr || 'Task model check did not launch');
let report;
for (let i = 0; i < (live ? 2400 : 160); i++) {
  try { report = JSON.parse(await readFile(path.join(output, 'task-model-report.json'), 'utf8')); break; } catch {}
  await sleep(250);
}
if (!report) throw new Error(`No task model report: ${output}`);
try {
  if (live && report.success) {
    const actual = JSON.parse(await readFile(path.join(workspace, 'cross-model-report.json'), 'utf8'));
    report.independentArtifactVerification = Object.keys(actual).length === 4 && actual.format === 'crossmodel-v1' && ['edition', 'width', 'height'].every(key => actual[key] === source[key]);
    const task = JSON.parse(await readFile(path.join(output, 'profile/agent', report.taskID + '.json'), 'utf8'));
    const added = task.modelReceipts.slice(report.baselineReceiptCount);
    report.independentUsageVerification = task.inputTokens === report.baselineInputTokens + added.reduce((sum, receipt) => sum + (receipt.inputTokens ?? 0), 0) && task.outputTokens === report.baselineOutputTokens + added.reduce((sum, receipt) => sum + (receipt.outputTokens ?? 0), 0);
    const dualTask = report.dualModelTaskID ? JSON.parse(await readFile(path.join(output, 'profile/agent', report.dualModelTaskID + '.json'), 'utf8')) : task;
    report.independentRequestedModels = new Set(dualTask.modelReceipts.filter(receipt => receipt.purpose === 'conversation').map(receipt => receipt.requestedModel)).size === 2;
    report.success &&= report.independentArtifactVerification && report.independentUsageVerification && report.independentRequestedModels;
  }
  report.inputsUnchanged = hash(await readFile(path.join(workspace, 'source.json'))) === hash(sourceBytes) && hash(await readFile(path.join(workspace, 'character.png'))) === hash(image);
  report.success &&= report.inputsUnchanged;
  console.log(JSON.stringify({ output, success: report.success, failed: Object.entries(report.checks ?? {}).filter(([, pass]) => !pass).map(([name]) => name), error: report.error, defaultModel: report.defaultModel, alternativeModel: report.alternativeModel, returnedModels: report.returnedModels, receiptCount: report.receiptCount }));
  if (hold && report.success) {
    console.log(JSON.stringify({ uiReady: true, output }));
    for (let i = 0; i < 2400; i++) { try { await readFile(path.join(output, 'finish-ui')); break; } catch {} await sleep(500); }
  }
} catch (error) { report.success = false; report.acceptanceError = error.message; }
await writeFile(path.join(output, 'finish-ui'), 'finished\n');
for (let i = 0; i < 50; i++) { try { if ((await readFile(path.join(output, 'phase'), 'utf8')) === 'finished') break; } catch {} await sleep(100); }
const after = await productionHashes(); report.productionFilesUnchanged = JSON.stringify(before) === JSON.stringify(after); report.success &&= report.productionFilesUnchanged;
await writeFile(path.join(output, 'task-model-report.json'), JSON.stringify(report, null, 2) + '\n');
const archive = path.join(root, 'evidence/agent', path.basename(output).replace('bluefatfish-', '')); await mkdir(path.dirname(archive), { recursive: true }); await cp(output, archive, { recursive: true });
console.log(JSON.stringify({ success: report.success, archive, checks: Object.keys(report.checks ?? {}).length, error: report.error ?? report.acceptanceError }));
process.exitCode = report.success ? 0 : 1;

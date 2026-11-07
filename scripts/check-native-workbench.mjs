import { spawnSync } from 'node:child_process';
import { cp, mkdir, mkdtemp, readFile, readdir, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import os from 'node:os';
import path from 'node:path';

const root = fileURLToPath(new URL('../', import.meta.url));
const option = name => { const i = process.argv.indexOf(name); return i >= 0 ? process.argv[i + 1] : undefined; };
const source = option('--fixtures');
if (!source) throw new Error('Provide --fixtures with a verified completed real-model check directory');
let originalReport, reportFile;
for (const name of ['custom-agent-report.json', 'hook-report.json']) {
  try { originalReport = JSON.parse(await readFile(path.join(source, name), 'utf8')); reportFile = name; break; }
  catch (error) { if (error.code !== 'ENOENT') throw error; }
}
const parentID = originalReport?.live?.parentID ?? originalReport?.live?.taskID;
if (!originalReport?.success || !originalReport.independentNodeVerification || !parentID) throw new Error('A verified real-model record is required');
const prior = { ...originalReport, live: { ...originalReport.live, parentID }, contextLimit: originalReport.contextLimit ?? originalReport.live.contextLimit, outputLimit: originalReport.outputLimit ?? originalReport.live.outputLimit, originalReportFile: reportFile };
const primary = JSON.parse(await readFile(path.join(source, 'profile/agent', parentID + '.json'), 'utf8'));
if (primary.status !== 'completed' || !primary.artifacts?.length) throw new Error('The actual source task must be completed with artifacts');
const output = await mkdtemp(path.join(os.tmpdir(), 'bluefatfish-workbench-'));
await cp(path.join(source, 'profile'), path.join(output, 'profile'), { recursive: true });
await mkdir(path.join(output, 'shared-home'), { recursive: true });
await writeFile(path.join(output, 'actual-source-report.json'), JSON.stringify(prior, null, 2));
await writeFile(path.join(output, 'actual-source-original-report.json'), JSON.stringify(originalReport, null, 2));
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const usage = async () => Object.fromEntries(await Promise.all((await readdir(path.join(output, 'profile/agent'))).filter(name => name.endsWith('.json') && name !== 'index.json').map(async name => {
  const task = JSON.parse(await readFile(path.join(output, 'profile/agent', name), 'utf8'));
  return [name, { input: task.inputTokens ?? 0, output: task.outputTokens ?? 0, receipts: JSON.stringify(task.modelReceipts ?? []) }];
})));
const usageBefore = await usage(), primaryMessages = hash(JSON.stringify(primary.messages));
const inputs = [...['source.json', 'character.png'].map(name => path.join(primary.workspace, name)), ...primary.artifacts];
const inputHashes = async () => Object.fromEntries(await Promise.all(inputs.map(async file => [file, hash(await readFile(file))])));
const inputsBefore = await inputHashes();
const production = path.join(os.homedir(), 'Library/Application Support/BlueFatFish');
const productionFiles = ['settings.json', 'history.json', 'agent/index.json', 'agent/A7A38353-CBA2-431C-84F1-4903E73EA373.json', 'automations/definitions.json', 'models/catalog.json', 'extensions/mcp.json', 'extensions/hooks.json', 'extensions/hook-settings.json'];
const hashes = async () => Object.fromEntries(await Promise.all(productionFiles.map(async name => [name, await readFile(path.join(production, name)).then(hash).catch(error => { if (error.code === 'ENOENT') return null; throw error; })])));
const before = await hashes(); await writeFile(path.join(output, 'production-before.json'), JSON.stringify(before, null, 2));
const hold = process.argv.includes('--hold-ui'), sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
console.log(JSON.stringify({ output, source, hold }));
try {
  const launch = spawnSync('/usr/bin/open', ['-n', path.join(root, 'build/蓝色大肥鱼.app'), '--args', '--check', output, '--workbench-check', ...(hold ? ['--workbench-ui-hold'] : [])], { encoding: 'utf8' });
  if (launch.status !== 0) throw new Error(launch.stderr || 'Application did not launch');
  let report;
  const deadline = Date.now() + 60_000;
  while (Date.now() < deadline) { try { report = JSON.parse(await readFile(path.join(output, 'workbench-report.json'), 'utf8')); break; } catch {} await sleep(200); }
  if (!report) throw new Error(`No terminal layout report: ${output}`);
  console.log(JSON.stringify({ output, success: report.success, failed: Object.entries(report.checks ?? {}).filter(([, pass]) => !pass).map(([name]) => name), error: report.error }));
  if (hold) {
    const limit = Date.now() + 1220_000;
    while (Date.now() < limit) { try { await readFile(path.join(output, 'finish-ui')); break; } catch {} await sleep(500); }
  }
  await writeFile(path.join(output, 'finish-ui'), 'finished\n');
  const after = await hashes(); report.productionProfileUnchanged = JSON.stringify(after) === JSON.stringify(before); report.productionAfter = after;
  const usageAfter = await usage();
  report.modelUsageUnchanged = Object.entries(usageBefore).every(([id, value]) => JSON.stringify(usageAfter[id]) === JSON.stringify(value)) && Object.entries(usageAfter).filter(([id]) => !usageBefore[id]).every(([, value]) => value.input === 0 && value.output === 0 && value.receipts === '[]');
  report.actualSourceMessagesUnchanged = hash(JSON.stringify(JSON.parse(await readFile(path.join(output, 'profile/agent', parentID + '.json'), 'utf8')).messages)) === primaryMessages;
  report.actualInputsAndArtifactsUnchanged = JSON.stringify(await inputHashes()) === JSON.stringify(inputsBefore);
  report.motionReports = await Promise.all((await readdir(output)).filter(name => /^workbench-motion-\d+\.json$/.test(name)).sort().map(async name => ({ file: name, ...JSON.parse(await readFile(path.join(output, name), 'utf8')) })));
  report.motionSystemCoverage = { observedFalse: report.motionReports.some(item => item.systemReduceMotion === false && item.success), observedTrue: report.motionReports.some(item => item.systemReduceMotion === true && item.success), allObservedChecksPass: report.motionReports.length > 0 && report.motionReports.every(item => item.success) };
  report.success &&= report.modelUsageUnchanged && report.actualSourceMessagesUnchanged && report.actualInputsAndArtifactsUnchanged && report.motionSystemCoverage.allObservedChecksPass;
  await writeFile(path.join(output, 'workbench-report.json'), JSON.stringify(report, null, 2) + '\n');
  const archive = path.join(root, 'evidence/agent', path.basename(output).replace('bluefatfish-', '')); await mkdir(path.dirname(archive), { recursive: true }); await cp(output, archive, { recursive: true });
  if (!report.success || !report.productionProfileUnchanged) throw new Error(`Workbench acceptance failed: ${archive}`);
  console.log(JSON.stringify({ success: true, output, archive, checks: Object.keys(report.checks).length, noNewModelCalls: true }));
} catch (error) { await writeFile(path.join(output, 'finish-ui'), 'failed\n'); throw error; }

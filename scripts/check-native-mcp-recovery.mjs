import { spawn, spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { createWriteStream } from 'node:fs';
import { finished } from 'node:stream/promises';
import { mkdir, mkdtemp, readFile, writeFile, stat } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { verifyNativeCandidate } from './native-signing.mjs';

const root = fileURLToPath(new URL('../', import.meta.url)), app = process.env.BLUEFATFISH_APP;
if (!app || process.argv.length !== 4 || process.argv[2] !== '--server-root') throw Error('请明确指定独立验收应用及 --server-root；参数恢复检查不调用模型。');
verifyNativeCandidate(app);
const info = spawnSync('/usr/bin/plutil', ['-convert', 'json', '-o', '-', path.join(app, 'Contents/Info.plist')], { encoding: 'utf8' });
if (info.status !== 0 || JSON.parse(info.stdout).BlueFatFishAcceptanceOnly !== true) throw Error('参数恢复检查只能使用独立验收应用。');
const serverRoot = path.resolve(process.argv[3]), serverEntry = path.join(serverRoot, 'dist/index.js');
const serverPackage = JSON.parse(await readFile(path.join(serverRoot, 'package.json'), 'utf8'));
if (serverPackage.version !== '2.2.1') throw Error('请使用现有的官方 server-everything 2.2.1。');
await stat(serverEntry);
const output = await mkdtemp(path.join(root, 'evidence/agent/mcp-recovery-command-'));
for (const name of ['tmp', 'shared-home']) await mkdir(path.join(output, name));
await writeFile(path.join(output, 'fixtures.json'), JSON.stringify({ node: process.execPath, serverEntry, serverVersion: serverPackage.version }, null, 2) + '\n');
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const json = async file => JSON.parse(await readFile(file, 'utf8'));
const binary = path.join(app, 'Contents/MacOS/BlueFatFish'), binaryHash = hash(await readFile(binary)), results = [];
let originalConfig, originalTasks;
for (const stage of ['seed', 'unavailable', 'reopen']) {
  const configFile = path.join(output, 'profile/extensions/mcp.json');
  if (stage === 'unavailable') {
    const fixture = await json(path.join(output, 'mcp-recovery-fixture.json'));
    originalConfig = await readFile(configFile);
    await writeFile(path.join(output, 'seed-original-mcp.json'), originalConfig);
    originalTasks = await Promise.all([fixture.first, fixture.second].map(id => readFile(path.join(output, 'profile/agent', id + '.json'))));
    const disabled = JSON.parse(originalConfig), target = disabled.find(value => value.id === fixture.serverB);
    if (!target) throw Error('缺少独立验收连接器。');
    target.enabled = false;
    await writeFile(configFile, JSON.stringify(disabled) + '\n');
    await writeFile(path.join(output, 'unavailable-fixture.json'), JSON.stringify({ serverID: target.id, originalSHA256: hash(originalConfig), disabledSHA256: hash(await readFile(configFile)), onlyEnabledFieldChanged: true }, null, 2) + '\n');
  } else if (stage === 'reopen') {
    await writeFile(configFile, originalConfig);
  }
  const args = ['--check', output, '--workspace-mcp-recovery-check', '--recovery-stage', stage];
  const child = spawn(binary, args, { cwd: root, env: { ...process.env, TMPDIR: path.join(output, 'tmp') + '/' }, stdio: ['ignore', 'pipe', 'pipe'] });
  const stdout = createWriteStream(path.join(output, stage + '-stdout.log')), stderr = createWriteStream(path.join(output, stage + '-stderr.log'));
  child.stdout.pipe(stdout); child.stderr.pipe(stderr);
  await writeFile(path.join(output, stage + '-process.json'), JSON.stringify({ app, appPID: child.pid, binaryHash, args }, null, 2) + '\n');
  console.log(JSON.stringify({ output, stage, appPID: child.pid, binaryHash }));
  const status = await new Promise((resolve, reject) => { child.once('error', reject); child.once('exit', (exit, signal) => resolve({ exit, signal })); });
  await Promise.all([finished(stdout), finished(stderr)]);
  const bytes = await readFile(path.join(output, 'mcp-recovery-report.json'));
  await writeFile(path.join(output, stage + '-report.json'), bytes);
  const report = JSON.parse(bytes), sameApplication = report.appPID === child.pid && report.binaryHash === binaryHash && hash(await readFile(binary)) === binaryHash;
  const success = status.exit === 0 && sameApplication && report.success === true && report.modelRequests === 0 && Object.keys(report.checks).length > 0 && Object.values(report.checks).every(Boolean);
  const result = { output, stage, ...status, sameApplication, success, checks: Object.keys(report.checks).length, failed: Object.keys(report.checks).filter(key => !report.checks[key]), error: report.error, modelRequests: report.modelRequests };
  results.push(result); console.log(JSON.stringify(result));
  await writeFile(path.join(output, stage + '-result.json'), JSON.stringify(result, null, 2) + '\n');
  if (!success) { process.exitCode = 1; break; }
  const fixture = await json(path.join(output, 'mcp-recovery-fixture.json')), independent = {};
  for (const [label, windowID, owner, serverID, resourceId, count] of [
    ['main', fixture.mainWindow, fixture.first, fixture.serverA, '2', 3],
    ['second', fixture.mainWindow, fixture.second, fixture.serverB, '4', 1],
    ['child', fixture.childWindow, fixture.first, fixture.serverA, '6', 1],
  ]) {
    const layout = await json(path.join(output, 'profile/workspace-recovery', windowID, 'layout.json'));
    const tab = layout.tasks.find(value => value.taskID === owner).tabs.find(value => value.root === 'mcp');
    const file = path.join(output, 'profile/workspace-recovery', windowID, 'pages', tab.id + '.json'), page = await json(file);
    const state = JSON.parse(Buffer.from(page.state, 'base64')), selected = JSON.parse(Buffer.from(state.selected, 'base64'));
    const key = [serverID, state.serverRevision, 'prompts', 'resource-prompt'].join('\n');
    independent[label + 'ActualPrivateDraftAndOwnership'] = page.kind === 'mcp-content' && page.taskID === owner && page.dirty === true && page.asset == null && state.taskID === owner && state.serverID === serverID && state.kind === 'prompts' && selected.name === 'resource-prompt' && state.drafts[key].fields.resourceId === resourceId && state.drafts[key].fields.resourceType === 'Text' && Object.keys(state.drafts).length === count;
    independent[label + 'PrivateFilePermission'] = (await stat(file)).mode % 0o1000 === 0o600;
    independent[label + 'NoPersistedConnectionOrPreview'] = Object.keys(state).every(key => ['version', 'taskID', 'serverID', 'serverRevision', 'kind', 'query', 'selected', 'drafts', 'dirty'].includes(key));
    if (stage === 'unavailable' && label === 'second') independent.disabledSourcePageBytesExact = hash(await readFile(file)) === fixture.secondPageHash;
  }
  const tasks = await Promise.all([fixture.first, fixture.second].map(id => readFile(path.join(output, 'profile/agent', id + '.json'))));
  if (stage === 'seed') originalTasks = tasks;
  independent.fullTasksBytesExact = tasks.every((bytes, index) => bytes.equals(originalTasks[index]));
  independent.publicProjectBytesExact = await readFile(path.join(fixture.project, 'README.md'), 'utf8') === 'PUBLIC_MCP_RECOVERY_SOURCE_592\n';
  if (stage === 'reopen') independent.originalConnectorConfigBytesExact = (await readFile(configFile)).equals(originalConfig);
  const proof = { success: Object.values(independent).every(Boolean), checks: independent };
  await writeFile(path.join(output, stage + '-independent.json'), JSON.stringify(proof, null, 2) + '\n');
  if (!proof.success) throw Error('参数恢复文件独立核对失败：' + Object.keys(independent).filter(key => !independent[key]).join(', '));
}
await writeFile(path.join(output, 'results.json'), JSON.stringify(results, null, 2) + '\n');

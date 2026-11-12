import { spawn, spawnSync } from 'node:child_process';
import { createWriteStream } from 'node:fs';
import { cp, mkdir, mkdtemp, readFile, writeFile, stat } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import os from 'node:os';
import path from 'node:path';

const root = fileURLToPath(new URL('../', import.meta.url));
const value = name => { const index = process.argv.indexOf(name); if (index < 0) return null; if (!process.argv[index + 1] || process.argv[index + 1].startsWith('--')) throw new Error(`${name} requires a path`); return process.argv[index + 1]; };
const candidate = value('--candidate-app');
if (!candidate) throw new Error('请用 --candidate-app 明确指定已签名验收应用；不会默认启动日常应用。');
const app = path.resolve(candidate), binary = path.join(app, 'Contents/MacOS/BlueFatFish');
const signature = spawnSync('/usr/bin/codesign', ['--verify', '--deep', '--strict', app], { encoding: 'utf8' });
if (signature.status !== 0) throw new Error(signature.stderr || '候选签名无效');
const serverRoot = path.resolve(value('--server-root') ?? path.join(os.homedir(), 'Library/Caches/bluefatfish-mcp-everything-real/node_modules/@modelcontextprotocol/server-everything'));
const serverEntry = path.join(serverRoot, 'dist/index.js'), documentFile = path.join(serverRoot, 'dist/docs/architecture.md');
const serverPackage = JSON.parse(await readFile(path.join(serverRoot, 'package.json'), 'utf8'));
await stat(serverEntry);
if (serverPackage.version !== '2.2.1') throw new Error('Install the explicit official server-everything 2.2.1 acceptance version');
await mkdir(path.join(root, 'evidence/agent'), { recursive: true });
const output = await mkdtemp(path.join(root, 'evidence/agent/mcp-content-')), workspace = path.join(output, 'workspace');
await mkdir(workspace); await mkdir(path.join(output, 'shared-home')); await mkdir(path.join(output, 'tmp')); process.env.TMPDIR = path.join(output, 'tmp') + '/';
for (const name of ['source.json', 'character.png']) await cp(path.join(root, 'public/portraits/whale-maid', name), path.join(workspace, name));
const hash = value => createHash('sha256').update(value).digest('hex');
const binaryHash = hash(await readFile(binary));
const originalFiles = Object.fromEntries(await Promise.all(['source.json', 'character.png'].map(async name => [name, hash(await readFile(path.join(workspace, name)))])));
const production = path.join(os.homedir(), 'Library/Application Support/BlueFatFish');
const productionHashes = async () => Object.fromEntries(await Promise.all(['settings.json', 'history.json', 'agent/index.json', 'agent/A7A38353-CBA2-431C-84F1-4903E73EA373.json', 'automations/definitions.json', 'models/catalog.json', 'extensions/mcp.json'].map(async name => {
  try { return [name, hash(await readFile(path.join(production, name)))]; } catch (error) { if (error.code === 'ENOENT') return [name, null]; throw error; }
})));
const before = await productionHashes(); await writeFile(path.join(output, 'production-before.json'), JSON.stringify(before, null, 2));
await writeFile(path.join(output, 'fixtures.json'), JSON.stringify({ node: process.execPath, serverEntry, documentFile, serverVersion: serverPackage.version }, null, 2));
const live = process.argv.includes('--live-agent'), hold = process.argv.includes('--hold-ui'), imageOnly = process.argv.includes('--image-only'), workspaceCheck = process.argv.includes('--workspace'), sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
if (workspaceCheck && live) throw new Error('工作区验收不调用模型。');
if (imageOnly && !live) throw new Error('--image-only requires --live-agent');
console.log(JSON.stringify({ output, live, hold, imageOnly }));
const args = ['--check', output, '--mcp-content-check', ...(workspaceCheck ? ['--mcp-workspace-check'] : []), ...(live ? ['--live-agent'] : []), ...(imageOnly ? ['--mcp-content-image-only'] : []), ...(hold ? ['--mcp-content-ui-hold'] : [])];
const child = spawn(binary, args, { cwd: root, stdio: ['ignore', 'pipe', 'pipe'] });
const completion = new Promise((resolve, reject) => { child.once('error', reject); child.once('close', (code, signal) => resolve({ code, signal })); });
const log = createWriteStream(path.join(output, 'launch.log')); child.stdout.pipe(log, { end: false }); child.stderr.pipe(log, { end: false });
await writeFile(path.join(output, 'launch.json'), JSON.stringify({ app, appPID: child.pid, binaryHash, args }, null, 2) + '\n');
let report;
for (let i = 0; i < (live ? 2400 : 480); i++) {
  try { report = JSON.parse(await readFile(path.join(output, 'mcp-content-report.json'), 'utf8')); break; } catch {}
  await sleep(250);
}
if (!report) throw new Error(`MCP check did not finish: ${output}`);
try {
  report.sameApplication = report.binaryHash === binaryHash && hash(await readFile(binary)) === binaryHash;
  report.success &&= report.sameApplication;
  const document = await readFile(documentFile), heading = document.toString('utf8').split('\n').find(line => line.startsWith('# ')).slice(2);
  report.independentResourceVerification = report.resourceSHA256 === hash(document) && report.resourceBytes === document.length;
  report.success &&= report.independentResourceVerification;
  if (live && report.success && !imageOnly) {
    const actual = JSON.parse(await readFile(path.join(workspace, 'mcp-content-report.json'), 'utf8'));
    report.independentArtifactVerification = Object.keys(actual).length === 5 && actual.documentTitle === heading && actual.documentSHA256 === hash(document) && actual.documentBytes === document.length && actual.promptResource === 'demo://resource/dynamic/text/2' && actual.promptText === report.selectedPromptText && /^Resource 2: This is a plaintext resource created at /.test(actual.promptText);
    const task = JSON.parse(await readFile(path.join(output, 'profile/agent', report.liveTaskID + '.json'), 'utf8'));
    const attachment = task.attachments.find(file => file.mcpSource?.uri === actual.promptResource);
    report.independentPromptCopyVerification = attachment && (await readFile(path.join(output, 'profile/agent', task.id, 'attachments', attachment.id, 'source.' + attachment.fileExtension), 'utf8')) === actual.promptText;
    report.success &&= report.independentArtifactVerification && report.independentPromptCopyVerification === true;
  }
  report.inputsUnchanged = (await Promise.all(Object.entries(originalFiles).map(async ([name, expected]) => hash(await readFile(path.join(workspace, name))) === expected))).every(Boolean);
  report.success &&= report.inputsUnchanged;
  console.log(JSON.stringify({ output, success: report.success, checks: Object.keys(report.checks ?? {}).length, failed: Object.entries(report.checks ?? {}).filter(([, pass]) => !pass).map(([name]) => name), error: report.error, imageAnswer: report.imageAnswer, approvals: report.approvals }));
  if (hold && report.success) {
    console.log(JSON.stringify({ uiReady: true, output }));
    for (let i = 0; i < 2400; i++) { try { await readFile(path.join(output, 'finish-ui')); break; } catch {} await sleep(500); }
  }
} catch (error) { report.success = false; report.acceptanceError = error.message; }
await writeFile(path.join(output, 'finish-ui'), 'finished\n');
const status = await completion; log.end(); report.processExitedNormally = status.code === 0; report.success &&= report.processExitedNormally;
const after = await productionHashes(); report.productionFilesUnchanged = JSON.stringify(before) === JSON.stringify(after); report.success &&= report.productionFilesUnchanged;
await writeFile(path.join(output, 'mcp-content-report.json'), JSON.stringify(report, null, 2) + '\n');
const archive = output;
console.log(JSON.stringify({ success: report.success, archive, error: report.error ?? report.acceptanceError }));
process.exitCode = report.success ? 0 : 1;

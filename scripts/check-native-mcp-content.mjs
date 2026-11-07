import { spawnSync } from 'node:child_process';
import { cp, mkdir, mkdtemp, readFile, writeFile, stat } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import os from 'node:os';
import path from 'node:path';

const root = fileURLToPath(new URL('../', import.meta.url));
const serverRoot = path.join(os.homedir(), 'Library/Caches/bluefatfish-mcp-everything-real/node_modules/@modelcontextprotocol/server-everything');
const serverEntry = path.join(serverRoot, 'dist/index.js'), documentFile = path.join(serverRoot, 'dist/docs/architecture.md');
const serverPackage = JSON.parse(await readFile(path.join(serverRoot, 'package.json'), 'utf8'));
await stat(serverEntry);
if (serverPackage.version !== '2.2.1') throw new Error('Install the explicit official server-everything 2.2.1 acceptance version');
const output = await mkdtemp(path.join(os.tmpdir(), 'bluefatfish-mcp-content-')), workspace = path.join(output, 'workspace');
await mkdir(workspace); await mkdir(path.join(output, 'shared-home'));
for (const name of ['source.json', 'character.png']) await cp(path.join(root, 'public/portraits/whale-maid', name), path.join(workspace, name));
const hash = value => createHash('sha256').update(value).digest('hex');
const originalFiles = Object.fromEntries(await Promise.all(['source.json', 'character.png'].map(async name => [name, hash(await readFile(path.join(workspace, name)))])));
const production = path.join(os.homedir(), 'Library/Application Support/BlueFatFish');
const productionHashes = async () => Object.fromEntries(await Promise.all(['settings.json', 'history.json', 'agent/index.json', 'agent/A7A38353-CBA2-431C-84F1-4903E73EA373.json', 'automations/definitions.json', 'models/catalog.json', 'extensions/mcp.json'].map(async name => {
  try { return [name, hash(await readFile(path.join(production, name)))]; } catch (error) { if (error.code === 'ENOENT') return [name, null]; throw error; }
})));
const before = await productionHashes(); await writeFile(path.join(output, 'production-before.json'), JSON.stringify(before, null, 2));
await writeFile(path.join(output, 'fixtures.json'), JSON.stringify({ node: process.execPath, serverEntry, documentFile, serverVersion: serverPackage.version }, null, 2));
const live = process.argv.includes('--live-agent'), hold = process.argv.includes('--hold-ui'), imageOnly = process.argv.includes('--image-only'), sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
if (imageOnly && !live) throw new Error('--image-only requires --live-agent');
console.log(JSON.stringify({ output, live, hold, imageOnly }));
const launched = spawnSync('/usr/bin/open', ['-n', path.join(root, 'build/蓝色大肥鱼.app'), '--args', '--check', output, '--mcp-content-check', ...(live ? ['--live-agent'] : []), ...(imageOnly ? ['--mcp-content-image-only'] : []), ...(hold ? ['--mcp-content-ui-hold'] : [])], { encoding: 'utf8' });
if (launched.status !== 0) throw new Error(launched.stderr || 'MCP content check did not launch');
let report;
for (let i = 0; i < (live ? 2400 : 480); i++) {
  try { report = JSON.parse(await readFile(path.join(output, 'mcp-content-report.json'), 'utf8')); break; } catch {}
  await sleep(250);
}
if (!report) throw new Error(`MCP check did not finish: ${output}`);
try {
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
for (let i = 0; i < 50; i++) { try { if ((await readFile(path.join(output, 'phase'), 'utf8')) === 'finished') break; } catch {} await sleep(100); }
const after = await productionHashes(); report.productionFilesUnchanged = JSON.stringify(before) === JSON.stringify(after); report.success &&= report.productionFilesUnchanged;
await writeFile(path.join(output, 'mcp-content-report.json'), JSON.stringify(report, null, 2) + '\n');
const archive = path.join(root, 'evidence/agent', path.basename(output).replace('bluefatfish-', '')); await mkdir(path.dirname(archive), { recursive: true }); await cp(output, archive, { recursive: true });
console.log(JSON.stringify({ success: report.success, archive, error: report.error ?? report.acceptanceError }));
process.exitCode = report.success ? 0 : 1;

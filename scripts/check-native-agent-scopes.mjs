import { spawnSync } from 'node:child_process';
import { cp, mkdir, mkdtemp, readFile, stat, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import os from 'node:os';
import path from 'node:path';

const root = fileURLToPath(new URL('../', import.meta.url));
const serverEntry = path.join(os.homedir(), 'Library/Caches/bluefatfish-mcp-real/node_modules/@modelcontextprotocol/server-filesystem/dist/index.js');
await stat(serverEntry);
const output = await mkdtemp(path.join(os.tmpdir(), 'bluefatfish-agent-scopes-')), workspace = path.join(output, 'workspace');
await mkdir(workspace); await mkdir(path.join(output, 'shared-home'));
for (const name of ['source.json', 'character.png']) await cp(path.join(root, 'public/portraits/whale-maid', name), path.join(workspace, name));
const factFlag = process.argv.indexOf('--facts-source'), factsSource = factFlag >= 0 ? process.argv[factFlag + 1] : undefined;
if (factsSource) await stat(factsSource);
await writeFile(path.join(output, 'fixtures.json'), JSON.stringify({ node: process.execPath, serverEntry, factsSource }));
const hash = data => createHash('sha256').update(data).digest('hex');
const sourceBytes = await readFile(path.join(workspace, 'source.json')), image = await readFile(path.join(workspace, 'character.png')), source = JSON.parse(sourceBytes);
const production = path.join(os.homedir(), 'Library/Application Support/BlueFatFish');
const productionHashes = async () => Object.fromEntries(await Promise.all(['settings.json', 'history.json', 'agent/index.json', 'agent/A7A38353-CBA2-431C-84F1-4903E73EA373.json'].map(async name => [name, hash(await readFile(path.join(production, name)))])));
const before = await productionHashes(); await writeFile(path.join(output, 'production-before.json'), JSON.stringify(before, null, 2));
const live = process.argv.includes('--live-agent'), hold = process.argv.includes('--hold-ui'), sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
console.log(JSON.stringify({ output, live, hold }));
const launch = spawnSync('/usr/bin/open', ['-n', path.join(root, 'build/蓝色大肥鱼.app'), '--args', '--check', output, '--custom-agent-check', '--scopes-only', ...(live ? ['--live-agent'] : []), ...(hold ? ['--custom-agent-ui-hold'] : [])], { encoding: 'utf8' });
if (launch.status !== 0) throw new Error(launch.stderr || 'Agent scope check did not launch');
let report;
for (let i = 0; i < 1100; i++) {
  try { report = JSON.parse(await readFile(path.join(output, 'agent-scope-report.json'), 'utf8')); break; } catch {}
  await sleep(250);
}
if (!report) throw new Error(`No scope report: ${output}`);
try {
  if (live && report.success) {
    const expected = { edition: source.edition, width: source.width, height: source.height, sha256: hash(image), imageBytes: image.length, format: 'scoped-skill-v1' };
    const actual = JSON.parse(await readFile(path.join(workspace, 'scoped-agent-report.json'), 'utf8'));
    report.independentNodeVerification = Object.keys(actual).length === 6 && Object.entries(expected).every(([key, value]) => actual[key] === value);
    report.success &&= report.independentNodeVerification;
  }
  report.inputsUnchanged = hash(await readFile(path.join(workspace, 'source.json'))) === hash(sourceBytes) && hash(await readFile(path.join(workspace, 'character.png'))) === hash(image);
  report.success &&= report.inputsUnchanged;
  console.log(JSON.stringify({ output, success: report.success, failed: Object.entries(report.checks ?? {}).filter(([, pass]) => !pass).map(([name]) => name), error: report.error, independentNodeVerification: report.independentNodeVerification }));
  if (hold && report.success) {
    const imported = structuredClone(report.configurationAtAcceptance.agents[0]); imported.name = '导入权限配置';
    await writeFile(path.join(output, 'import-agent-scopes.json'), JSON.stringify({ agents: [imported] }, null, 2));
    console.log(JSON.stringify({ uiReady: true, output }));
    for (let i = 0; i < 2440; i++) { try { await readFile(path.join(output, 'finish-ui')); break; } catch {} await sleep(500); }
  }
} catch (error) { report.success = false; report.acceptanceError = error.message; }
await writeFile(path.join(output, 'finish-ui'), 'finished\n');
for (let i = 0; i < 40; i++) { try { if ((await readFile(path.join(output, 'phase'), 'utf8')) === 'finished') break; } catch {} await sleep(100); }
const after = await productionHashes(); report.productionFilesUnchanged = JSON.stringify(before) === JSON.stringify(after); report.success &&= report.productionFilesUnchanged;
await writeFile(path.join(output, 'agent-scope-report.json'), JSON.stringify(report, null, 2) + '\n');
const archive = path.join(root, 'evidence/agent', path.basename(output).replace('bluefatfish-', '')); await mkdir(path.dirname(archive), { recursive: true }); await cp(output, archive, { recursive: true });
console.log(JSON.stringify({ success: report.success, archive, checks: Object.keys(report.checks ?? {}).length, error: report.error ?? report.acceptanceError }));
process.exitCode = report.success ? 0 : 1;

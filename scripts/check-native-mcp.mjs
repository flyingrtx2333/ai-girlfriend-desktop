import { spawnSync } from 'node:child_process';
import { cp, mkdir, mkdtemp, readFile, stat, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import os from 'node:os';
import path from 'node:path';

const root = fileURLToPath(new URL('../', import.meta.url));
const serverEntry = process.env.BLUEFATFISH_MCP_CHECK_SERVER || path.join(os.homedir(), 'Library/Caches/bluefatfish-mcp-real/node_modules/@modelcontextprotocol/server-filesystem/dist/index.js');
await stat(serverEntry); // Install the real official server explicitly; never fetch on app launch.
const output = await mkdtemp(path.join(os.tmpdir(), 'bluefatfish-mcp-'));
const workspace = path.join(output, 'workspace'); await mkdir(workspace);
for (const name of ['source.json', 'character.png']) await cp(path.join(root, 'public/portraits/whale-maid', name), path.join(workspace, name));
await writeFile(path.join(output, 'outside.txt'), 'public-outside-marker');
const expectedSource = JSON.parse(await readFile(path.join(workspace, 'source.json'), 'utf8'));
const picture = await readFile(path.join(workspace, 'character.png'));
const expected = { edition: expectedSource.edition, width: expectedSource.width, height: expectedSource.height, sha256: createHash('sha256').update(picture).digest('hex'), imageBytes: picture.length };
const sourceHash = createHash('sha256').update(await readFile(path.join(workspace, 'source.json'))).digest('hex');
await writeFile(path.join(output, 'independent-expected.json'), JSON.stringify(expected, null, 2));
await writeFile(path.join(output, 'fixtures.json'), JSON.stringify({ node: process.execPath, serverEntry }, null, 2));
const limitFlag = process.argv.indexOf('--output-limit'), limit = limitFlag >= 0 ? Number(process.argv[limitFlag + 1]) : null;
if (limit !== null && (!Number.isInteger(limit) || limit < 512 || limit > 8192)) throw Error('验收回复上限范围为 512 至 8192');
const launch = spawnSync('/usr/bin/open', ['-n', path.join(root, 'build/蓝色大肥鱼.app'), '--args', '--check', output, '--mcp-check', ...(process.argv.includes('--live-agent') ? ['--live-agent'] : []), ...(process.argv.includes('--hold-ui') ? ['--mcp-ui-hold'] : []), ...(limit !== null ? ['--mcp-output-limit', String(limit)] : [])], { encoding: 'utf8' });
if (launch.status !== 0) throw Error(launch.stderr || 'MCP 检查未启动');
let report;
for (let i = 0; i < 840; i++) {
  report = await readFile(path.join(output, 'mcp-report.json'), 'utf8').then(JSON.parse).catch(() => null);
  if (report) break; await new Promise(resolve => setTimeout(resolve, 500));
}
if (!report) throw Error(`MCP 检查未完成：${output}`);
if (report.live) {
  const actual = await readFile(path.join(workspace, 'asset-report.json'), 'utf8').then(JSON.parse).catch(() => null);
  report.independentNodeVerification = actual && Object.entries(expected).every(([key, value]) => actual[key] === value) && createHash('sha256').update(await readFile(path.join(workspace, 'character.png'))).digest('hex') === expected.sha256 && createHash('sha256').update(await readFile(path.join(workspace, 'source.json'))).digest('hex') === sourceHash;
  report.success &&= report.independentNodeVerification === true;
  await writeFile(path.join(output, 'mcp-report.json'), JSON.stringify(report, null, 2));
}
const archived = path.join(root, 'evidence/agent', path.basename(output).replace('bluefatfish-', '')); await mkdir(path.dirname(archived), { recursive: true }); await cp(output, archived, { recursive: true });
console.log(JSON.stringify({ ...report, live: report.live && { ...report.live, events: undefined, approvals: report.live.approvals?.length }, report: path.join(archived, 'mcp-report.json'), ...(process.argv.includes('--hold-ui') ? { uiHoldDirectory: output } : {}) }, null, 2));
process.exitCode = report.success ? 0 : 1;

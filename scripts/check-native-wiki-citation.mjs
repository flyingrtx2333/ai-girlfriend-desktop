import { spawnSync } from 'node:child_process';
import { readFile, writeFile, readdir, mkdir, mkdtemp } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { isDeepStrictEqual } from 'node:util';
import { fileURLToPath } from 'node:url';
import os from 'node:os';
import path from 'node:path';

const root = fileURLToPath(new URL('../', import.meta.url)), index = process.argv.indexOf('--candidate-app');
if (index < 0 || !process.argv[index + 1]) throw Error('Use --candidate-app <strictly signed candidate.app>');
const app = path.resolve(process.argv[index + 1]), hash = bytes => createHash('sha256').update(bytes).digest('hex');
const output = await mkdtemp(path.join(os.tmpdir(), 'bluefatfish-wiki-citation-')), workspace = path.join(output, 'workspace');
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
function command(file, args) { const r = spawnSync(file, args, { encoding: 'utf8' }); if (r.status !== 0) throw Error(r.stderr || file); return r.stdout; }
async function production() {
  const base = path.join(os.homedir(), 'Library/Application Support/BlueFatFish'), names = ['settings.json', 'history.json', 'agent/index.json', 'organization.json', 'automations/definitions.json', 'models/catalog.json', 'extensions/mcp.json', 'extensions/hooks.json', 'extensions/hook-settings.json', 'extensions/settings.json', 'extensions/agents.json', 'extensions/teams.json', 'worktrees/policy.json', 'worktrees/history.json', 'worktrees/scheduler.lock', 'computer-use/settings.json', 'imports/batch.json', 'knowledge/catalog.json', 'knowledge-cards/settings.json', 'wiki/settings.json'];
  for (const name of await readdir(path.join(base, 'agent'))) if (/^[0-9a-f-]{36}\.json$/i.test(name)) names.push('agent/' + name);
  return Object.fromEntries(await Promise.all(names.sort().map(async name => [name, await readFile(path.join(base, name)).then(hash).catch(e => { if (e.code === 'ENOENT') return null; throw e; })])));
}
const before = await production(), files = {};
await writeFile(path.join(output, 'production-before.json'), JSON.stringify(before, null, 2));
async function copySource(name, relative) {
  const bytes = await readFile(path.join(root, name)); files[relative] = hash(bytes); await mkdir(path.dirname(path.join(workspace, relative)), { recursive: true }); await writeFile(path.join(workspace, relative), bytes);
}
await copySource('README.md', 'source/README.md'); await copySource('native/AgentWiki.swift', 'source/AgentWiki.swift');
await copySource('README.md', '.bluefatfish/wiki/project/README.md'); await copySource('docs/REPO-WIKI.md', '.bluefatfish/wiki/project/docs/REPO-WIKI.md');
for (const item of await readdir(path.join(root, 'docs/media'), { withFileTypes: true })) if (item.isFile()) await copySource('docs/media/' + item.name, '.bluefatfish/wiki/project/docs/media/' + item.name);
await writeFile(path.join(workspace, '.bluefatfish/wiki/index.md'), '# Wiki 资料\n\n[项目文档](project/README.md)\n\n[实际源码](../../source/AgentWiki.swift#L1)\n\n本目录是实际项目文件的人工导航，仅用于引用设置检查，并非模型生成结果。\n');
files['.bluefatfish/wiki/index.md'] = hash(await readFile(path.join(workspace, '.bluefatfish/wiki/index.md')));
await mkdir(path.join(output, 'other-workspace'), { recursive: true }); await writeFile(path.join(output, 'other-workspace/README.md'), await readFile(path.join(root, 'README.md')));
const binaryHash = hash(await readFile(path.join(app, 'Contents/MacOS/BlueFatFish'))); command('/usr/bin/codesign', ['--verify', '--deep', '--strict', app]);
await writeFile(path.join(output, 'wiki-citation-origin.json'), JSON.stringify({ repository: root, app, binaryHash, files, modelsCalled: false }, null, 2));
console.log(JSON.stringify({ output, binaryHash })); command('/usr/bin/open', ['-n', app, '--args', '--check', output, '--wiki-plan-check', '--wiki-citation-check']);
let ready;
for (let i = 0; i < 480; i++) {
  try { ready = JSON.parse(await readFile(path.join(output, 'wiki-citation-ui-ready.json'), 'utf8')); break; } catch (e) { if (e.code !== 'ENOENT') throw e; }
  try { const failure = JSON.parse(await readFile(path.join(output, 'wiki-citation-report.json'), 'utf8')); throw Error(JSON.stringify(failure)); } catch (e) { if (e.code !== 'ENOENT') throw e; }
  await pause(250);
}
if (!ready || ready.binaryHash !== binaryHash) throw Error('Actual candidate did not reach the citation window');
console.log(JSON.stringify({ ready: true, output, appPID: ready.appPID, checks: ready.checks }));
let report;
for (let i = 0; i < 7200; i++) { try { report = JSON.parse(await readFile(path.join(output, 'wiki-citation-report.json'), 'utf8')); break; } catch (e) { if (e.code !== 'ENOENT') throw e; } await pause(500); }
if (!report) throw Error('Retain the unfinished actual window run');
const after = await production(); await writeFile(path.join(output, 'production-after.json'), JSON.stringify(after, null, 2));
const independent = { productionIncludingWikiSettingsUnchanged: isDeepStrictEqual(before, after), actualCandidate: report.binaryHash === binaryHash && report.appPID === ready.appPID, noModelCalls: report.modelsCalled === false };
for (const [name, expected] of Object.entries(files)) independent['source:' + name] = hash(await readFile(path.join(workspace, name))) === expected;
report.independent = independent; report.success &&= Object.values(independent).every(Boolean);
await writeFile(path.join(output, 'wiki-citation-report.json'), JSON.stringify(report, null, 2));
console.log(JSON.stringify({ success: report.success, output, nativeChecks: Object.keys(report.checks).length, independentChecks: Object.keys(independent).length })); if (!report.success) process.exitCode = 1;

import { spawnSync } from 'node:child_process';
import { readFile, writeFile, readdir, mkdtemp, mkdir } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { isDeepStrictEqual } from 'node:util';
import { fileURLToPath } from 'node:url';
import os from 'node:os';
import path from 'node:path';

const root = fileURLToPath(new URL('../', import.meta.url)), index = process.argv.indexOf('--candidate-app');
if (index < 0 || !process.argv[index + 1]) throw Error('Use --candidate-app <signed application>');
const app = path.resolve(process.argv[index + 1]), hash = bytes => createHash('sha256').update(bytes).digest('hex');
const output = await mkdtemp(path.join(os.tmpdir(), 'bluefatfish-wiki-plan-')), workspace = path.join(output, 'workspace');
function command(file, args) { const r = spawnSync(file, args, { encoding: 'utf8' }); if (r.status !== 0) throw Error(r.stderr || file); return r.stdout; }
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
async function snapshot() {
  const base = path.join(os.homedir(), 'Library/Application Support/BlueFatFish');
  const names = ['settings.json', 'history.json', 'agent/index.json', 'organization.json', 'automations/definitions.json', 'models/catalog.json', 'extensions/mcp.json', 'extensions/hooks.json', 'extensions/hook-settings.json', 'extensions/settings.json', 'extensions/agents.json', 'extensions/teams.json', 'worktrees/policy.json', 'worktrees/history.json', 'worktrees/scheduler.lock', 'computer-use/settings.json', 'imports/batch.json', 'knowledge/catalog.json', 'knowledge-cards/settings.json'];
  for (const name of await readdir(path.join(base, 'agent'))) if (/^[0-9a-f-]{36}\.json$/i.test(name)) names.push('agent/' + name);
  return Object.fromEntries(await Promise.all(names.sort().map(async name => [name, await readFile(path.join(base, name)).then(hash).catch(e => { if (e.code === 'ENOENT') return null; throw e; })])));
}
const before = await snapshot(); await writeFile(path.join(output, 'production-before.json'), JSON.stringify(before, null, 2));
const sourceHashes = {};
for (const name of ['README.md', 'docs/DEVELOPMENT.md', 'native/AgentWiki.swift', 'package.json']) {
  const data = await readFile(path.join(root, name)); sourceHashes[name] = hash(data); await mkdir(path.dirname(path.join(workspace, name)), { recursive: true }); await writeFile(path.join(workspace, name), data);
}
command('/usr/bin/git', ['init', '--quiet', '--initial-branch=wiki-one', workspace]);
command('/usr/bin/git', ['-C', workspace, 'add', 'README.md', 'docs/DEVELOPMENT.md', 'native/AgentWiki.swift', 'package.json']);
command('/usr/bin/git', ['-C', workspace, '-c', 'user.name=Wiki Acceptance', '-c', 'user.email=wiki-acceptance@localhost', 'commit', '--quiet', '-m', 'Actual source snapshot for local Wiki acceptance']);
command('/usr/bin/git', ['-C', workspace, 'branch', 'wiki-two']);
const yaml = 'version: 1\nrepowiki:\n  template: architecture\n  notes:\n    - text: |\n        核对实际项目文件。\n        使用来源引用。\n  documents:\n    - title: 项目总览\n      goal: 说明实际项目入口\n      hints: [README.md]\n    - title: 开发与版本\n      goal: 说明实际开发流程\n      parent: 项目总览\n      hints: docs/DEVELOPMENT.md\nknowledgecard:\n  notes:\n    - text: 保留兼容配置，不改写原文件\n';
await mkdir(path.join(workspace, '.qoder/repowiki'), { recursive: true }); await writeFile(path.join(workspace, '.qoder/repowiki/wiki_plan.yaml'), yaml);
await mkdir(path.join(workspace, '.bluefatfish/wiki'), { recursive: true }); await writeFile(path.join(workspace, '.bluefatfish/wiki/index.md'), await readFile(path.join(workspace, 'README.md')));
const vectors = {
  duplicateYAMLKeysRejected: 'version: 1\nversion: 1\nrepowiki: {}\n',
  booleanVersionRejected: 'version: true\nrepowiki: {}\n',
  multipleYAMLDocumentsRejected: 'version: 1\nrepowiki: {}\n---\nversion: 1\nrepowiki: {}\n',
  unknownRootFieldsRejected: 'version: 1\nrepowiki: {}\nunsupported: true\n',
  unknownTemplateRejected: 'version: 1\nrepowiki:\n  template: unsupported\n',
  cyclicParentsRejected: 'version: 1\nrepowiki:\n  documents:\n    - {title: Root, goal: actual source}\n    - {title: A, goal: actual source, parent: B}\n    - {title: B, goal: actual source, parent: A}\n',
  missingParentRejected: 'version: 1\nrepowiki:\n  documents:\n    - {title: Root, goal: actual source}\n    - {title: A, goal: actual source, parent: Missing}\n',
  repeatedTitlesRejected: 'version: 1\nrepowiki:\n  documents:\n    - {title: A, goal: actual source}\n    - {title: A, goal: actual source}\n',
  excessiveYAMLAliasExpansionRejected: 'version: 1\nrepowiki:\n  notes: &a [x,x,x,x,x,x,x,x,x,x]\nknowledgecard:\n  a: &b [*a,*a,*a,*a,*a,*a,*a,*a,*a,*a]\n  b: [*b,*b,*b,*b,*b,*b,*b,*b,*b,*b]\n'
};
await writeFile(path.join(output, 'wiki-plan-vectors.json'), JSON.stringify(vectors, null, 2));
const binaryHash = hash(await readFile(path.join(app, 'Contents/MacOS/BlueFatFish')));
await writeFile(path.join(output, 'wiki-plan-origin.json'), JSON.stringify({ source: root, app, binaryHash, files: sourceHashes, modelsCalled: false, importedDocuments: 'Actual repository documents manually imported for file and UI checks; not model-generated acceptance' }, null, 2));
command('/usr/bin/codesign', ['--verify', '--deep', '--strict', app]);
console.log(JSON.stringify({ output, app, binaryHash }));
command('/usr/bin/open', ['-n', app, '--args', '--check', output, '--wiki-plan-check']);
let ready;
for (let i = 0; i < 360; i++) {
  try { ready = JSON.parse(await readFile(path.join(output, 'wiki-plan-ui-ready.json'), 'utf8')); break; } catch (e) { if (e.code !== 'ENOENT') throw e; }
  try { const failure = JSON.parse(await readFile(path.join(output, 'wiki-plan-report.json'), 'utf8')); throw Error(JSON.stringify(failure)); } catch (e) { if (e.code !== 'ENOENT') throw e; }
  await pause(250);
}
if (!ready || ready.binaryHash !== binaryHash || ready.modelsCalled !== false) throw Error('Actual candidate did not finish native checks; retain this run');
console.log(JSON.stringify({ ready: true, appPID: ready.appPID, output, checks: ready.checks }));
let report;
for (let i = 0; i < 7200; i++) {
  try { report = JSON.parse(await readFile(path.join(output, 'wiki-plan-report.json'), 'utf8')); break; } catch (e) { if (e.code !== 'ENOENT') throw e; }
  await pause(500);
}
if (!report) throw Error('UI acceptance remains unfinished; retain this run');
const after = await snapshot(); await writeFile(path.join(output, 'production-after.json'), JSON.stringify(after, null, 2));
const independent = { productionProfileUnchanged: isDeepStrictEqual(before, after), actualCandidate: report.binaryHash === binaryHash && report.appPID === ready.appPID, noModelCalls: report.modelsCalled === false };
for (const [name, expected] of Object.entries(sourceHashes)) independent['sourceUnchanged:' + name] = hash(await readFile(path.join(workspace, name))) === expected;
independent.compatiblePlanUnchanged = (await readFile(path.join(workspace, '.qoder/repowiki/wiki_plan.yaml'), 'utf8')) === yaml;
report.independent = independent; report.success &&= Object.values(independent).every(Boolean);
await writeFile(path.join(output, 'wiki-plan-report.json'), JSON.stringify(report, null, 2));
console.log(JSON.stringify({ success: report.success, output, nativeChecks: Object.keys(report.checks).length, independent }));
if (!report.success) process.exitCode = 1;

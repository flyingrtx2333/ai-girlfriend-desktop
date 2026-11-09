import { spawnSync } from 'node:child_process';
import { readFile, writeFile, readdir, mkdir, mkdtemp, cp } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { isDeepStrictEqual } from 'node:util';
import { fileURLToPath } from 'node:url';
import os from 'node:os';
import path from 'node:path';

const root = fileURLToPath(new URL('../', import.meta.url)), index = process.argv.indexOf('--candidate-app');
if (index < 0 || !process.argv[index + 1]) throw Error('Use --candidate-app <strictly signed candidate.app>');
const app = path.resolve(process.argv[index + 1]), hash = bytes => createHash('sha256').update(bytes).digest('hex');
const actualIndex = process.argv.indexOf('--actual-run');
if (actualIndex < 0 || !process.argv[actualIndex + 1]) throw Error('Use --actual-run <retained real Wiki round>');
const actual = path.resolve(process.argv[actualIndex + 1]);
const output = await mkdtemp(path.join(os.tmpdir(), 'bluefatfish-wiki-generation-')), workspace = path.join(output, 'workspace');
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
function command(file, args) { const r = spawnSync(file, args, { encoding: 'utf8' }); if (r.status !== 0) throw Error(r.stderr || file); return r.stdout; }
async function production() {
  const base = path.join(os.homedir(), 'Library/Application Support/BlueFatFish'), names = ['settings.json', 'history.json', 'agent/index.json', 'organization.json', 'automations/definitions.json', 'models/catalog.json', 'extensions/mcp.json', 'extensions/hooks.json', 'extensions/hook-settings.json', 'extensions/settings.json', 'extensions/agents.json', 'extensions/teams.json', 'worktrees/policy.json', 'worktrees/history.json', 'worktrees/scheduler.lock', 'computer-use/settings.json', 'imports/batch.json', 'knowledge/catalog.json', 'knowledge-cards/settings.json', 'wiki/settings.json'];
  for (const name of await readdir(path.join(base, 'agent'))) if (/^[0-9a-f-]{36}\.json$/i.test(name)) names.push('agent/' + name);
  return Object.fromEntries(await Promise.all(names.sort().map(async name => [name, await readFile(path.join(base, name)).then(hash).catch(e => { if (e.code === 'ENOENT') return null; throw e; })])));
}
const before = await production(), files = {};
await writeFile(path.join(output, 'production-before.json'), JSON.stringify(before, null, 2));
const marker = JSON.parse(await readFile(path.join(actual, 'wiki-live-zh-task.json'), 'utf8'));
const source = path.join(actual, 'profile/agent', marker.id + '.json'), sourceBytes = await readFile(source), historical = JSON.parse(sourceBytes);
const ledger = await readFile(path.join(actual, 'wiki-request-ledger.json'));
const grant = await readFile(path.join(actual, 'wiki-budget-authorization.json'));
if (historical.messages?.length !== 51 || historical.modelReceipts?.length !== 30 || !historical.wikiJob || historical.status !== 'failed') throw Error('Expected the actual retained 30-request failed Wiki task');
await cp(path.join(actual, 'profile'), path.join(output, 'profile'), { recursive: true });
await cp(path.join(actual, 'workspace'), workspace, { recursive: true });
for (const name of await readdir(path.join(output, 'profile/agent'))) {
  if (!/^(?:index|[0-9a-f-]{36})\.json$/i.test(name)) continue;
  const file = path.join(output, 'profile/agent', name), value = JSON.parse(await readFile(file, 'utf8'));
  const records = Array.isArray(value) ? value : value.tasks ?? [value];
  for (const record of records) if (record.workspace === historical.workspace) record.workspace = workspace;
  await writeFile(file, JSON.stringify(value));
}
for (const name of ['README.md', 'docs/DEVELOPMENT.md', 'native/AgentWiki.swift', 'package.json']) files[name] = hash(await readFile(path.join(workspace, name)));
await mkdir(path.join(workspace, '.bluefatfish/wiki'), { recursive: true });
await writeFile(path.join(workspace, '.bluefatfish/wiki/index.md'), await readFile(path.join(workspace, 'README.md')));
files['.bluefatfish/wiki/index.md'] = hash(await readFile(path.join(workspace, '.bluefatfish/wiki/index.md')));
await writeFile(path.join(output, 'generation-origin.json'), JSON.stringify({ actual, source, sourceHash: hash(sourceBytes), ledgerHash: hash(ledger), grantHash: hash(grant), originalWorkspace: historical.workspace, copiedWorkspace: workspace, copiedRealHistory: true, manualNavigation: 'Actual README copied into the legacy Wiki for window checks; not model-generated content', modelsCalled: false }, null, 2));
const binaryHash = hash(await readFile(path.join(app, 'Contents/MacOS/BlueFatFish'))); command('/usr/bin/codesign', ['--verify', '--deep', '--strict', app]);
await writeFile(path.join(output, 'wiki-generation-origin.json'), JSON.stringify({ repository: root, app, binaryHash, files, modelsCalled: false }, null, 2));
console.log(JSON.stringify({ output, binaryHash })); command('/usr/bin/open', ['-n', app, '--args', '--check', output, '--wiki-plan-check', '--wiki-generation-check']);
let ready;
for (let i = 0; i < 480; i++) {
  try { ready = JSON.parse(await readFile(path.join(output, 'wiki-generation-ui-ready.json'), 'utf8')); break; } catch (e) { if (e.code !== 'ENOENT') throw e; }
  try { const failure = JSON.parse(await readFile(path.join(output, 'wiki-generation-report.json'), 'utf8')); throw Error(JSON.stringify(failure)); } catch (e) { if (e.code !== 'ENOENT') throw e; }
  await pause(250);
}
if (!ready || ready.binaryHash !== binaryHash) throw Error('Actual candidate did not reach the generation-management window');
console.log(JSON.stringify({ ready: true, output, appPID: ready.appPID, checks: ready.checks }));
let report;
for (let i = 0; i < 7200; i++) { try { report = JSON.parse(await readFile(path.join(output, 'wiki-generation-report.json'), 'utf8')); break; } catch (e) { if (e.code !== 'ENOENT') throw e; } await pause(500); }
if (!report) throw Error('Retain the unfinished actual window run');
const after = await production(); await writeFile(path.join(output, 'production-after.json'), JSON.stringify(after, null, 2));
const independent = { productionIncludingWikiSettingsUnchanged: isDeepStrictEqual(before, after), actualCandidate: report.binaryHash === binaryHash && report.appPID === ready.appPID, noModelCalls: report.modelsCalled === false, originalFailureUnchanged: hash(await readFile(source)) === hash(sourceBytes), actualLedgerUnchanged: hash(await readFile(path.join(actual, 'wiki-request-ledger.json'))) === hash(ledger), actualAuthorizationUnchanged: hash(await readFile(path.join(actual, 'wiki-budget-authorization.json'))) === hash(grant) };
for (const [name, expected] of Object.entries(files)) independent['source:' + name] = hash(await readFile(path.join(workspace, name))) === expected;
report.independent = independent; report.success &&= Object.values(independent).every(Boolean);
await writeFile(path.join(output, 'wiki-generation-report.json'), JSON.stringify(report, null, 2));
console.log(JSON.stringify({ success: report.success, output, nativeChecks: Object.keys(report.checks).length, independentChecks: Object.keys(independent).length })); if (!report.success) process.exitCode = 1;

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
if (actualIndex < 0 || !process.argv[actualIndex + 1]) throw Error('Use --actual-run <retained real Wiki acceptance round>');
const actual = path.resolve(process.argv[actualIndex + 1]);
const output = await mkdtemp(path.join(os.tmpdir(), 'bluefatfish-wiki-updates-')), workspace = path.join(output, 'workspace');
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
function command(file, args) { const r = spawnSync(file, args, { encoding: 'utf8' }); if (r.status !== 0) throw Error(r.stderr || file); return r.stdout; }
async function production() {
  const base = path.join(os.homedir(), 'Library/Application Support/BlueFatFish'), names = ['settings.json', 'history.json', 'agent/index.json', 'organization.json', 'automations/definitions.json', 'models/catalog.json', 'extensions/mcp.json', 'extensions/hooks.json', 'extensions/hook-settings.json', 'extensions/settings.json', 'extensions/agents.json', 'extensions/teams.json', 'worktrees/policy.json', 'worktrees/history.json', 'worktrees/scheduler.lock', 'computer-use/settings.json', 'imports/batch.json', 'knowledge/catalog.json', 'knowledge-cards/settings.json', 'wiki/settings.json'];
  for (const name of await readdir(path.join(base, 'agent'))) if (/^[0-9a-f-]{36}\.json$/i.test(name)) names.push('agent/' + name);
  return Object.fromEntries(await Promise.all(names.sort().map(async name => [name, await readFile(path.join(base, name)).then(hash).catch(e => { if (e.code === 'ENOENT') return null; throw e; })])));
}
const before = await production();
await writeFile(path.join(output, 'production-before.json'), JSON.stringify(before, null, 2));
const ledger = await readFile(path.join(actual, 'wiki-request-ledger.json')), grant = await readFile(path.join(actual, 'wiki-budget-authorization.json'));
await mkdir(path.join(output, 'profile'), { recursive: true }); await cp(path.join(actual, 'profile/settings.json'), path.join(output, 'profile/settings.json'));
const baseRef = command('/usr/bin/git', ['-C', root, 'rev-parse', 'a6820e6']).trim(), sourceRef = command('/usr/bin/git', ['-C', root, 'rev-parse', 'HEAD']).trim();
const files = {}, baselineFiles = {}, stages = {};
async function sourceFile(ref, name, target) {
  const bytes = Buffer.from(command('/usr/bin/git', ['-C', root, 'show', ref + ':' + name])); await mkdir(path.dirname(target), { recursive: true }); await writeFile(target, bytes); return hash(bytes);
}
for (const name of ['README.md', 'docs/DEVELOPMENT.md', 'native/AgentWiki.swift', 'package.json']) baselineFiles[name] = await sourceFile(baseRef, name, path.join(workspace, name));
command('/usr/bin/git', ['init', '--quiet', '--initial-branch=wiki-updates', workspace]);
command('/usr/bin/git', ['-C', workspace, 'config', 'user.name', 'Wiki Acceptance']); command('/usr/bin/git', ['-C', workspace, 'config', 'user.email', 'wiki-acceptance@localhost']);
command('/usr/bin/git', ['-C', workspace, 'config', 'commit.gpgSign', 'false']); command('/usr/bin/git', ['-C', workspace, 'config', 'core.hooksPath', '/dev/null']);
command('/usr/bin/git', ['-C', workspace, 'add', '.']); command('/usr/bin/git', ['-C', workspace, 'commit', '--quiet', '-m', 'Actual retained project source baseline']);
const baseCommit = command('/usr/bin/git', ['-C', workspace, 'rev-parse', 'HEAD']).trim();
for (const [stage, names] of Object.entries({ next: Object.keys(baselineFiles), third: ['native/AgentWikiContext.swift'], fourth: ['docs/REPO-WIKI.md'], fifth: ['native/AgentWikiPlan.swift'] })) {
  stages[stage] = {};
  for (const name of names) { stages[stage][name] = await sourceFile(sourceRef, name, path.join(output, 'stages', stage, name)); files[name] = stages[stage][name]; }
}
await writeFile(path.join(output, 'updates-origin.json'), JSON.stringify({ repository: root, baseRef, sourceRef, baseCommit, baselineFiles, stages, actual, ledgerHash: hash(ledger), grantHash: hash(grant), modelsCalled: false, wikiInput: 'Manual pages quote actual baseline source excerpts and line citations. These are native update-policy inputs, not AI-generated knowledge.' }, null, 2));
const binaryHash = hash(await readFile(path.join(app, 'Contents/MacOS/BlueFatFish'))); command('/usr/bin/codesign', ['--verify', '--deep', '--strict', app]);
await writeFile(path.join(output, 'wiki-updates-candidate.json'), JSON.stringify({ repository: root, app, binaryHash, files, modelsCalled: false }, null, 2));
console.log(JSON.stringify({ output, binaryHash })); command('/usr/bin/open', ['-n', app, '--args', '--check', output, '--wiki-plan-check', '--wiki-updates-check']);
let ready;
for (let i = 0; i < 480; i++) {
  try { ready = JSON.parse(await readFile(path.join(output, 'wiki-updates-ui-ready.json'), 'utf8')); break; } catch (e) { if (e.code !== 'ENOENT') throw e; }
  try { const failure = JSON.parse(await readFile(path.join(output, 'wiki-updates-report.json'), 'utf8')); throw Error(JSON.stringify(failure)); } catch (e) { if (e.code !== 'ENOENT') throw e; }
  await pause(250);
}
if (!ready || ready.binaryHash !== binaryHash) throw Error('Actual candidate did not reach the Wiki update window');
console.log(JSON.stringify({ ready: true, output, appPID: ready.appPID, checks: ready.checks }));
let report;
for (let i = 0; i < 7200; i++) { try { report = JSON.parse(await readFile(path.join(output, 'wiki-updates-report.json'), 'utf8')); break; } catch (e) { if (e.code !== 'ENOENT') throw e; } await pause(500); }
if (!report) throw Error('Retain the unfinished actual window run');
const after = await production(); await writeFile(path.join(output, 'production-after.json'), JSON.stringify(after, null, 2));
const independent = { productionIncludingWikiSettingsUnchanged: isDeepStrictEqual(before, after), actualCandidate: report.binaryHash === binaryHash && report.appPID === ready.appPID, noModelCalls: report.modelsCalled === false, originalWikiLedgerUnchanged: hash(await readFile(path.join(actual, 'wiki-request-ledger.json'))) === hash(ledger), originalWikiGrantUnchanged: hash(await readFile(path.join(actual, 'wiki-budget-authorization.json'))) === hash(grant) };
for (const [stage, entries] of Object.entries(stages)) for (const [name, expected] of Object.entries(entries)) independent['actual-stage:' + stage + ':' + name] = hash(await readFile(path.join(output, 'stages', stage, name))) === expected;
report.independent = independent; report.success &&= Object.values(independent).every(Boolean);
await writeFile(path.join(output, 'wiki-updates-report.json'), JSON.stringify(report, null, 2));
console.log(JSON.stringify({ success: report.success, output, nativeChecks: Object.keys(report.checks).length, independentChecks: Object.keys(independent).length })); if (!report.success) process.exitCode = 1;

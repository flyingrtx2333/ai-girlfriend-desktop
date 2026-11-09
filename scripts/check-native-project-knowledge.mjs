import { spawnSync } from 'node:child_process';
import { readFile, writeFile, readdir, mkdir, mkdtemp, cp } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { isDeepStrictEqual } from 'node:util';
import { fileURLToPath } from 'node:url';
import os from 'node:os';
import path from 'node:path';

const root = fileURLToPath(new URL('../', import.meta.url)), appIndex = process.argv.indexOf('--candidate-app'), actualIndex = process.argv.indexOf('--actual-run');
if (appIndex < 0 || actualIndex < 0) throw Error('Use --candidate-app <signed app> --actual-run <retained Wiki round>');
const app = path.resolve(process.argv[appIndex + 1]), actual = path.resolve(process.argv[actualIndex + 1]), hash = b => createHash('sha256').update(b).digest('hex');
const output = await mkdtemp(path.join(os.tmpdir(), 'bluefatfish-project-knowledge-')), workspace = path.join(output, 'workspace'), pause = ms => new Promise(r => setTimeout(r, ms));
function command(file, args) { const result = spawnSync(file, args, { encoding: 'utf8' }); if (result.status !== 0) throw Error(result.stderr || file); return result.stdout; }
async function production() {
  const base = path.join(os.homedir(), 'Library/Application Support/BlueFatFish'), names = ['settings.json', 'history.json', 'agent/index.json', 'organization.json', 'automations/definitions.json', 'models/catalog.json', 'extensions/mcp.json', 'extensions/hooks.json', 'extensions/hook-settings.json', 'extensions/settings.json', 'extensions/agents.json', 'extensions/teams.json', 'worktrees/policy.json', 'worktrees/history.json', 'worktrees/scheduler.lock', 'computer-use/settings.json', 'imports/batch.json', 'knowledge/catalog.json', 'knowledge-cards/settings.json', 'wiki/settings.json'];
  for (const name of await readdir(path.join(base, 'agent'))) if (/^[0-9a-f-]{36}\.json$/i.test(name)) names.push('agent/' + name);
  return Object.fromEntries(await Promise.all(names.sort().map(async name => [name, await readFile(path.join(base, name)).then(hash).catch(e => { if (e.code === 'ENOENT') return null; throw e; })])));
}
const before = await production(), ledger = await readFile(path.join(actual, 'wiki-request-ledger.json')), grant = await readFile(path.join(actual, 'wiki-budget-authorization.json'));
await writeFile(path.join(output, 'production-before.json'), JSON.stringify(before, null, 2));
await mkdir(path.join(output, 'profile'), { recursive: true }); await cp(path.join(actual, 'profile/settings.json'), path.join(output, 'profile/settings.json'));
const files = {};
for (const name of ['README.md', 'docs/DEVELOPMENT.md', 'native/AgentWiki.swift', 'package.json']) { const data = await readFile(path.join(root, name)), target = path.join(workspace, name); await mkdir(path.dirname(target), { recursive: true }); await writeFile(target, data); files[name] = hash(data); }
await writeFile(path.join(workspace, '.gitignore'), '.bluefatfish/\n.qoder/\n');
command('/usr/bin/git', ['init', '--quiet', '--initial-branch=project-knowledge', workspace]);
command('/usr/bin/git', ['-C', workspace, 'config', 'user.name', 'Knowledge Acceptance']); command('/usr/bin/git', ['-C', workspace, 'config', 'user.email', 'knowledge-acceptance@localhost']); command('/usr/bin/git', ['-C', workspace, 'config', 'commit.gpgSign', 'false']); command('/usr/bin/git', ['-C', workspace, 'config', 'core.hooksPath', '/dev/null']); command('/usr/bin/git', ['-C', workspace, 'add', '.']); command('/usr/bin/git', ['-C', workspace, 'commit', '--quiet', '-m', 'Actual project source for native knowledge generation']);
command('/usr/bin/git', ['-C', workspace, 'branch', 'knowledge-other']);
for (const name of ['cancellation-workspace', 'budget-workspace']) await cp(workspace, path.join(output, name), { recursive: true });
const binaryHash = hash(await readFile(path.join(app, 'Contents/MacOS/BlueFatFish'))); command('/usr/bin/codesign', ['--verify', '--deep', '--strict', app]);
await writeFile(path.join(output, 'project-knowledge-origin.json'), JSON.stringify({ repository: root, app, binaryHash, files, actual, ledgerHash: hash(ledger), grantHash: hash(grant), modelsCalled: false }, null, 2));
console.log(JSON.stringify({ output, binaryHash })); command('/usr/bin/open', ['-n', app, '--args', '--check', output, '--wiki-plan-check', '--project-knowledge-check']);
let ready;
for (let i = 0; i < 480; i++) {
  try { ready = JSON.parse(await readFile(path.join(output, 'project-knowledge-ui-ready.json'), 'utf8')); break; } catch (e) { if (e.code !== 'ENOENT') throw e; }
  try { throw Error(JSON.stringify(JSON.parse(await readFile(path.join(output, 'project-knowledge-report.json'), 'utf8')))); } catch (e) { if (e.code !== 'ENOENT') throw e; }
  await pause(250);
}
if (!ready || ready.binaryHash !== binaryHash) throw Error('Native project knowledge checks did not reach the actual window');
console.log(JSON.stringify({ ready: true, output, appPID: ready.appPID, checks: ready.checks }));
let report;
for (let i = 0; i < 7200; i++) { try { report = JSON.parse(await readFile(path.join(output, 'project-knowledge-report.json'), 'utf8')); break; } catch (e) { if (e.code !== 'ENOENT') throw e; } await pause(500); }
if (!report) throw Error('Retain unfinished native window run');
const after = await production(); await writeFile(path.join(output, 'production-after.json'), JSON.stringify(after, null, 2));
const independent = { dailyProfileUnchanged: isDeepStrictEqual(before, after), actualCandidate: report.binaryHash === binaryHash && report.appPID === ready.appPID, noModelCalls: report.modelsCalled === false && report.checks.finalNoModelReceiptsOrFabricatedCompletion === true, retainedWikiLedgerUnchanged: hash(await readFile(path.join(actual, 'wiki-request-ledger.json'))) === hash(ledger), retainedWikiGrantUnchanged: hash(await readFile(path.join(actual, 'wiki-budget-authorization.json'))) === hash(grant) };
for (const [name, expected] of Object.entries(files)) independent['actual-source:' + name] = hash(await readFile(path.join(workspace, name))) === expected;
report.independent = independent; report.success &&= Object.values(independent).every(Boolean);
await writeFile(path.join(output, 'project-knowledge-report.json'), JSON.stringify(report, null, 2));
console.log(JSON.stringify({ success: report.success, output, nativeChecks: Object.keys(report.checks).length, independentChecks: Object.keys(independent).length })); if (!report.success) process.exitCode = 1;

import { spawnSync } from 'node:child_process';
import { mkdir, mkdtemp, readFile, writeFile, readdir } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { isDeepStrictEqual } from 'node:util';
import { fileURLToPath } from 'node:url';
import os from 'node:os';
import path from 'node:path';

const root = fileURLToPath(new URL('../', import.meta.url)), appIndex = process.argv.indexOf('--candidate-app');
if (appIndex < 0 || !process.argv[appIndex + 1]) throw Error('Use --candidate-app <signed application>');
const app = path.resolve(process.argv[appIndex + 1]), actualIndex = process.argv.indexOf('--actual-run'), actual = actualIndex < 0 ? null : path.resolve(process.argv[actualIndex + 1]), hash = data => createHash('sha256').update(data).digest('hex'), pause = ms => new Promise(resolve => setTimeout(resolve, ms));
const output = await mkdtemp(path.join(os.tmpdir(), 'bluefatfish-task-archive-')), profile = path.join(os.homedir(), 'Library/Application Support/BlueFatFish');
function command(file, args) { const result = spawnSync(file, args, { encoding: 'utf8' }); if (result.status !== 0) throw Error(result.stderr || file); return result.stdout; }
async function production() {
  const names = ['settings.json', 'history.json', 'organization.json', 'agent/index.json', 'automations/definitions.json', 'models/catalog.json', 'extensions/mcp.json', 'extensions/hooks.json', 'extensions/hook-settings.json', 'extensions/settings.json', 'extensions/agents.json', 'extensions/teams.json', 'worktrees/policy.json', 'worktrees/history.json', 'worktrees/scheduler.lock', 'computer-use/settings.json', 'imports/batch.json', 'knowledge/catalog.json', 'knowledge-cards/settings.json', 'wiki/settings.json'];
  for (const name of await readdir(path.join(profile, 'agent'))) if (/^[0-9a-f-]{36}\.json$/i.test(name)) names.push('agent/' + name);
  const result = Object.fromEntries(await Promise.all(names.sort().map(async name => [name, await readFile(path.join(profile, name)).then(hash).catch(error => { if (error.code === 'ENOENT') return null; throw error; })])));
  result.dailyBinary = hash(await readFile(path.join(root, 'build/蓝色大肥鱼.app/Contents/MacOS/BlueFatFish')));
  if (actual) for (const name of ['wiki-request-ledger.json', 'wiki-budget-authorization.json', 'profile/agent/F3C22B92-75F2-4846-B8AF-71F08CE11024.json']) result['retained-wiki:' + name] = hash(await readFile(path.join(actual, name)));
  return result;
}
const before = await production(); await writeFile(path.join(output, 'production-before.json'), JSON.stringify(before, null, 2));
const sources = {}, heads = {};
for (const project of ['alpha', 'beta', 'empty']) {
  const directory = path.join(output, 'projects', project); await mkdir(directory, { recursive: true });
  const name = project === 'beta' ? 'native/AgentRuntime.swift' : 'README.md', data = await readFile(path.join(root, name)); await writeFile(path.join(directory, 'README.md'), data); sources[project] = hash(data);
  command('/usr/bin/git', ['init', '--quiet', '--initial-branch=main', directory]); command('/usr/bin/git', ['-C', directory, 'add', 'README.md']);
  command('/usr/bin/git', ['-C', directory, '-c', 'user.name=Archive Acceptance', '-c', 'user.email=archive@localhost', '-c', 'commit.gpgSign=false', '-c', 'core.hooksPath=/dev/null', 'commit', '--quiet', '-m', 'Actual repository source for archive acceptance']);
  heads[project] = command('/usr/bin/git', ['-C', directory, 'rev-parse', 'HEAD']).trim();
}
const binaryHash = hash(await readFile(path.join(app, 'Contents/MacOS/BlueFatFish'))); command('/usr/bin/codesign', ['--verify', '--deep', '--strict', app]);
await writeFile(path.join(output, 'task-archive-origin.json'), JSON.stringify({ repository: root, app, binaryHash, sources, heads, actual, modelsCalled: false }, null, 2));
console.log(JSON.stringify({ output, app, binaryHash })); command('/usr/bin/open', ['-n', app, '--args', '--check', output, '--organization-check', '--task-archive-check']);
let ready;
for (let i = 0; i < 480; i++) {
  try { ready = JSON.parse(await readFile(path.join(output, 'task-archive-ui-ready.json'), 'utf8')); break; } catch (error) { if (error.code !== 'ENOENT') throw error; }
  try { throw Error(JSON.stringify(JSON.parse(await readFile(path.join(output, 'task-archive-report.json'), 'utf8')))); } catch (error) { if (error.code !== 'ENOENT') throw error; }
  await pause(250);
}
if (!ready || ready.binaryHash !== binaryHash) throw Error('Native archive checks did not reach the actual window; retain this run');
console.log(JSON.stringify({ ready: true, output, appPID: ready.appPID, checks: ready.checks }));
let report;
for (let i = 0; i < 7200; i++) { try { report = JSON.parse(await readFile(path.join(output, 'task-archive-report.json'), 'utf8')); break; } catch (error) { if (error.code !== 'ENOENT') throw error; } await pause(500); }
if (!report) throw Error('Retain the unfinished archive UI acceptance');
const after = await production(); await writeFile(path.join(output, 'production-after.json'), JSON.stringify(after, null, 2));
const independent = { dailyProfileAndApplicationUnchanged: isDeepStrictEqual(before, after), actualCandidate: report.binaryHash === binaryHash && report.appPID === ready.appPID, noModelCalls: report.modelsCalled === false && report.checks.noModelCallsReceiptsOrAssistantReplies === true };
for (const project of ['alpha', 'beta', 'empty']) { independent['source:' + project] = hash(await readFile(path.join(output, 'projects', project, 'README.md'))) === sources[project]; independent['head:' + project] = command('/usr/bin/git', ['-C', path.join(output, 'projects', project), 'rev-parse', 'HEAD']).trim() === heads[project]; }
const index = JSON.parse(await readFile(path.join(output, 'profile/agent/index.json'), 'utf8')), records = Object.fromEntries(await Promise.all(Object.entries(ready.tasks).map(async ([key, id]) => [key, JSON.parse(await readFile(path.join(output, 'profile/agent', id + '.json'), 'utf8'))])));
independent.restoredTasksAndEarlierArchiveMatchIndexAndFiles = ['alpha', 'second', 'beta', 'none', 'general'].every(key => records[key].archived === false && index.tasks.find(task => task.id === records[key].id)?.archived === false) && records.old.archived === true && index.tasks.find(task => task.id === records.old.id)?.archived === true;
independent.draftsAndCheckpointBytesRetained = records.alpha.draft === '保留的编程草稿' && records.general.draft === '保留的通用草稿' && hash(await readFile(path.join(output, 'profile/agent', ready.tasks.alpha, 'checkpoints/README-copy.md'))) === sources.alpha;
report.independent = independent; report.success &&= Object.values(independent).every(Boolean); await writeFile(path.join(output, 'task-archive-report.json'), JSON.stringify(report, null, 2));
console.log(JSON.stringify({ success: report.success, output, nativeChecks: Object.keys(report.checks).length, independentChecks: Object.keys(independent).length })); if (!report.success) process.exitCode = 1;

import { spawnSync } from 'node:child_process';
import { mkdir, mkdtemp, readFile, writeFile, readdir } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { isDeepStrictEqual } from 'node:util';
import { fileURLToPath } from 'node:url';
import os from 'node:os';
import path from 'node:path';

const root = fileURLToPath(new URL('../', import.meta.url)), appIndex = process.argv.indexOf('--candidate-app');
if (appIndex < 0 || !process.argv[appIndex + 1]) throw Error('Use --candidate-app <signed application>');
const app = path.resolve(process.argv[appIndex + 1]), actualIndex = process.argv.indexOf('--actual-run'), actual = actualIndex < 0 ? null : path.resolve(process.argv[actualIndex + 1]);
const hash = data => createHash('sha256').update(data).digest('hex'), pause = ms => new Promise(resolve => setTimeout(resolve, ms));
const output = await mkdtemp(path.join(os.tmpdir(), 'bluefatfish-repo-wiki-overview-')), profile = path.join(os.homedir(), 'Library/Application Support/BlueFatFish');
function command(file, args) {
  const result = spawnSync(file, args, { encoding: 'utf8' });
  if (result.status !== 0) throw Error(result.stderr || file); return result.stdout;
}
async function production() {
  const names = ['settings.json', 'history.json', 'organization.json', 'agent/index.json', 'automations/definitions.json', 'models/catalog.json', 'extensions/mcp.json', 'extensions/hooks.json', 'extensions/hook-settings.json', 'extensions/settings.json', 'extensions/agents.json', 'extensions/teams.json', 'worktrees/policy.json', 'worktrees/history.json', 'worktrees/scheduler.lock', 'computer-use/settings.json', 'imports/batch.json', 'knowledge/catalog.json', 'knowledge-cards/settings.json', 'wiki/settings.json'];
  for (const name of await readdir(path.join(profile, 'agent'))) if (/^[0-9a-f-]{36}\.json$/i.test(name)) names.push('agent/' + name);
  const result = Object.fromEntries(await Promise.all(names.sort().map(async name => [name, await readFile(path.join(profile, name)).then(hash).catch(error => { if (error.code === 'ENOENT') return null; throw error; })])));
  result.dailyBinary = hash(await readFile(path.join(root, 'build/蓝色大肥鱼.app/Contents/MacOS/BlueFatFish')));
  if (actual) for (const name of ['wiki-request-ledger.json', 'wiki-budget-authorization.json', 'profile/agent/F3C22B92-75F2-4846-B8AF-71F08CE11024.json']) result['retained-wiki:' + name] = hash(await readFile(path.join(actual, name)));
  return result;
}
const before = await production(); await writeFile(path.join(output, 'production-before.json'), JSON.stringify(before, null, 2));
const sources = {}, heads = {}, legacy = {}, sourceNames = ['README.md', 'native/AgentRuntime.swift', 'native/AgentStore.swift'];
for (const project of ['alpha', 'beta', 'gamma', 'disconnected']) {
  const directory = path.join(output, 'projects', project); await mkdir(directory, { recursive: true });
  for (const name of project === 'alpha' ? sourceNames : ['README.md']) {
    const data = await readFile(path.join(root, name)), target = path.join(directory, name);
    await mkdir(path.dirname(target), { recursive: true }); await writeFile(target, data); sources[project + '/' + name] = hash(data);
  }
  if (['alpha', 'beta'].includes(project)) {
    command('/usr/bin/git', ['init', '--quiet', '--initial-branch=main', directory]);
    command('/usr/bin/git', ['-C', directory, 'add', ...(project === 'alpha' ? sourceNames : ['README.md'])]);
    command('/usr/bin/git', ['-C', directory, '-c', 'user.name=Repo Wiki Overview Acceptance', '-c', 'user.email=repo-wiki@localhost', '-c', 'commit.gpgSign=false', '-c', 'core.hooksPath=/dev/null', 'commit', '--quiet', '-m', 'Actual source for repository Wiki overview']);
    heads[project] = command('/usr/bin/git', ['-C', directory, 'rev-parse', 'HEAD']).trim();
  }
}
const alpha = path.join(output, 'projects/alpha');
command('/usr/bin/git', ['-C', alpha, 'branch', 'overview-other']);
command('/usr/bin/git', ['-C', alpha, 'worktree', 'add', '--quiet', '--detach', path.join(output, 'projects/external-worktree'), 'HEAD']);
for (const [file, title, source] of [['index.md', '源码入口', 'native/AgentRuntime.swift'], ['storage.md', '任务存储', 'native/AgentStore.swift']]) {
  const excerpt = (await readFile(path.join(root, source), 'utf8')).split('\n').slice(0, 40).join('\n');
  const data = Buffer.from('# ' + title + '\n\n~~~swift\n' + excerpt + '\n~~~\n\n来源：' + source + '。\n');
  const target = path.join(alpha, '.bluefatfish/wiki', file); await mkdir(path.dirname(target), { recursive: true }); await writeFile(target, data); legacy[file] = hash(data);
}
const binaryHash = hash(await readFile(path.join(app, 'Contents/MacOS/BlueFatFish'))); command('/usr/bin/codesign', ['--verify', '--deep', '--strict', app]);
await writeFile(path.join(output, 'repo-wiki-overview-origin.json'), JSON.stringify({ repository: root, app, binaryHash, sources, heads, legacy, actual, modelsCalled: false, documents: 'Actual source excerpts manually arranged, exported and imported; not generated by a model.' }, null, 2));
console.log(JSON.stringify({ output, app, binaryHash })); command('/usr/bin/open', ['-n', app, '--args', '--check', output, '--organization-check', '--repo-wiki-overview-check']);
let ready;
for (let i = 0; i < 480; i++) {
  try { ready = JSON.parse(await readFile(path.join(output, 'repo-wiki-overview-ui-ready.json'), 'utf8')); break; } catch (error) { if (error.code !== 'ENOENT') throw error; }
  try { throw Error(JSON.stringify(JSON.parse(await readFile(path.join(output, 'repo-wiki-overview-report.json'), 'utf8')))); } catch (error) { if (error.code !== 'ENOENT') throw error; }
  await pause(250);
}
if (!ready || ready.binaryHash !== binaryHash) throw Error('Actual repository Wiki overview did not reach the window; retain this run');
console.log(JSON.stringify({ ready: true, output, appPID: ready.appPID, checks: ready.checks }));
let report;
for (let i = 0; i < 7200; i++) {
  try { report = JSON.parse(await readFile(path.join(output, 'repo-wiki-overview-report.json'), 'utf8')); break; } catch (error) { if (error.code !== 'ENOENT') throw error; } await pause(500);
}
if (!report) throw Error('Retain unfinished repository Wiki overview acceptance');
const after = await production(); await writeFile(path.join(output, 'production-after.json'), JSON.stringify(after, null, 2));
const independent = { dailyProfileApplicationAndRetainedWikiUnchanged: isDeepStrictEqual(before, after), actualCandidate: report.binaryHash === binaryHash && report.appPID === ready.appPID, noModelCalls: report.modelsCalled === false && report.checks.noModelAttemptsReceiptsAssistantRepliesOrStartedWiki === true };
for (const [name, expected] of Object.entries(sources)) {
  let file = path.join(output, 'projects', name);
  if (name.startsWith('disconnected/')) try { await readFile(file); } catch (error) { if (error.code !== 'ENOENT') throw error; file = path.join(output, 'held-disconnected', name.slice('disconnected/'.length)); }
  independent['source:' + name] = hash(await readFile(file)) === expected;
}
for (const [name, expected] of Object.entries(legacy)) independent['legacy:' + name] = hash(await readFile(path.join(alpha, '.bluefatfish/wiki', name))) === expected;
for (const [name, expected] of Object.entries(heads)) independent['head:' + name] = command('/usr/bin/git', ['-C', path.join(output, 'projects', name), 'rev-parse', 'HEAD']).trim() === expected;
independent.alphaReturnedToMain = command('/usr/bin/git', ['-C', alpha, 'symbolic-ref', '--short', 'HEAD']).trim() === 'main';
report.independent = independent; report.success &&= Object.values(independent).every(Boolean); await writeFile(path.join(output, 'repo-wiki-overview-report.json'), JSON.stringify(report, null, 2));
console.log(JSON.stringify({ success: report.success, output, nativeChecks: Object.keys(report.checks).length, independentChecks: Object.keys(independent).length })); if (!report.success) process.exitCode = 1;

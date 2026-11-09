import { spawnSync } from 'node:child_process';
import { readFile, writeFile, readdir, mkdir, mkdtemp } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { isDeepStrictEqual } from 'node:util';
import { fileURLToPath } from 'node:url';
import os from 'node:os';
import path from 'node:path';

const root = fileURLToPath(new URL('../', import.meta.url)), appIndex = process.argv.indexOf('--candidate-app'), actualIndex = process.argv.indexOf('--actual-run');
if (appIndex < 0 || actualIndex < 0) throw Error('Use --candidate-app <signed app> --actual-run <retained Wiki round>');
const app = path.resolve(process.argv[appIndex + 1]), actual = path.resolve(process.argv[actualIndex + 1]), hash = data => createHash('sha256').update(data).digest('hex');
const output = await mkdtemp(path.join(os.tmpdir(), 'bluefatfish-knowledge-sharing-')), workspace = path.join(output, 'workspace'), pause = ms => new Promise(resolve => setTimeout(resolve, ms));
function command(file, args) { const result = spawnSync(file, args, { encoding: 'utf8' }); if (result.status !== 0) throw Error(result.stderr || file); return result.stdout; }
async function protectedState() {
  const base = path.join(os.homedir(), 'Library/Application Support/BlueFatFish'), names = ['settings.json', 'history.json', 'agent/index.json', 'organization.json', 'automations/definitions.json', 'models/catalog.json', 'extensions/mcp.json', 'extensions/hooks.json', 'extensions/hook-settings.json', 'extensions/settings.json', 'extensions/agents.json', 'extensions/teams.json', 'worktrees/policy.json', 'worktrees/history.json', 'worktrees/scheduler.lock', 'computer-use/settings.json', 'imports/batch.json', 'knowledge/catalog.json', 'knowledge-cards/settings.json', 'wiki/settings.json'];
  for (const name of await readdir(path.join(base, 'agent'))) if (/^[0-9a-f-]{36}\.json$/i.test(name)) names.push('agent/' + name);
  const result = Object.fromEntries(await Promise.all(names.sort().map(async name => [name, await readFile(path.join(base, name)).then(hash).catch(error => { if (error.code === 'ENOENT') return null; throw error; })])));
  for (const name of ['wiki-request-ledger.json', 'wiki-budget-authorization.json', 'profile/agent/F3C22B92-75F2-4846-B8AF-71F08CE11024.json']) result['retained-wiki:' + name] = hash(await readFile(path.join(actual, name)));
  result.dailyBinary = hash(await readFile(path.join(root, 'build/蓝色大肥鱼.app/Contents/MacOS/BlueFatFish')));
  return result;
}
const before = await protectedState(); await writeFile(path.join(output, 'protected-before.json'), JSON.stringify(before, null, 2));
const sourceHashes = {}, legacyHashes = {};
async function copy(name, relative, convert) {
  const data = await readFile(path.join(root, name)), bytes = convert ? convert(data) : data; sourceHashes[name] = hash(data);
  await mkdir(path.dirname(path.join(workspace, relative)), { recursive: true }); await writeFile(path.join(workspace, relative), bytes);
  if (relative.startsWith('.bluefatfish/wiki/')) legacyHashes[relative] = hash(bytes);
}
for (const name of ['README.md', 'native/AgentWiki.swift', 'package.json']) await copy(name, 'source/' + name);
await writeFile(path.join(workspace, '.gitignore'), '.bluefatfish/\n'); command('/usr/bin/git', ['init', '--quiet', '--initial-branch=knowledge-sharing', workspace]);
command('/usr/bin/git', ['-C', workspace, 'config', 'user.name', 'Knowledge Acceptance']); command('/usr/bin/git', ['-C', workspace, 'config', 'user.email', 'knowledge-acceptance@localhost']); command('/usr/bin/git', ['-C', workspace, 'config', 'commit.gpgSign', 'false']); command('/usr/bin/git', ['-C', workspace, 'config', 'core.hooksPath', '/dev/null']);
command('/usr/bin/git', ['-C', workspace, 'add', 'source', '.gitignore']); command('/usr/bin/git', ['-C', workspace, 'commit', '--quiet', '-m', 'Actual project sources for knowledge transfer']); command('/usr/bin/git', ['-C', workspace, 'branch', 'sharing-other']);
for (const name of ['README.md', 'docs/AGENT-READING.md']) await copy(name, '.bluefatfish/wiki/project/' + name, name.endsWith('AGENT-READING.md') ? data => Buffer.concat([Buffer.from([255, 254]), Buffer.from(data.toString('utf8').replace(/\r\n/g, '\n').replace(/\n/g, '\r\n'), 'utf16le')]) : null);
for (const entry of await readdir(path.join(root, 'docs/media'), { withFileTypes: true })) if (entry.isFile() && /\.(png|jpe?g|gif|webp|heic|heif|tiff?)$/i.test(entry.name)) await copy('docs/media/' + entry.name, '.bluefatfish/wiki/project/docs/media/' + entry.name);
const navigation = '# 项目知识\n\n[实际 README](project/README.md)\n\n[实际文档](project/docs/AGENT-READING.md)\n\n[实际源码](../../source/native/AgentWiki.swift#L1)\n';
await writeFile(path.join(workspace, '.bluefatfish/wiki/index.md'), navigation); legacyHashes['.bluefatfish/wiki/index.md'] = hash(Buffer.from(navigation));
const binaryHash = hash(await readFile(path.join(app, 'Contents/MacOS/BlueFatFish'))); command('/usr/bin/codesign', ['--verify', '--deep', '--strict', app]);
await writeFile(path.join(output, 'knowledge-sharing-origin.json'), JSON.stringify({ repository: root, app, binaryHash, actual, sourceHashes, legacyHashes, modelsCalled: false }, null, 2));
console.log(JSON.stringify({ output, app, binaryHash })); command('/usr/bin/open', ['-n', app, '--args', '--check', output, '--wiki-plan-check', '--project-knowledge-sharing-check']);
let ready;
for (let i = 0; i < 480; i++) {
  try { ready = JSON.parse(await readFile(path.join(output, 'knowledge-sharing-ui-ready.json'), 'utf8')); break; } catch (error) { if (error.code !== 'ENOENT') throw error; }
  try { throw Error(JSON.stringify(JSON.parse(await readFile(path.join(output, 'knowledge-sharing-report.json'), 'utf8')))); } catch (error) { if (error.code !== 'ENOENT') throw error; }
  await pause(250);
}
if (!ready || ready.binaryHash !== binaryHash) throw Error('Native knowledge transfer did not reach the actual window; retain this run');
console.log(JSON.stringify({ ready: true, output, appPID: ready.appPID, checks: ready.checks }));
let report;
for (let i = 0; i < 7200; i++) { try { report = JSON.parse(await readFile(path.join(output, 'knowledge-sharing-report.json'), 'utf8')); break; } catch (error) { if (error.code !== 'ENOENT') throw error; } await pause(500); }
if (!report) throw Error('Actual knowledge transfer UI acceptance is unfinished; retain this run');
const after = await protectedState(); await writeFile(path.join(output, 'protected-after.json'), JSON.stringify(after, null, 2));
const independent = { dailyAndRetainedWikiUnchanged: isDeepStrictEqual(before, after), actualCandidate: report.binaryHash === binaryHash && report.appPID === ready.appPID, noModelCalls: report.modelsCalled === false && report.checks.noModelMessagesReceiptsOrUnexpectedGeneration === true };
const rollback = path.join(output, 'rollback/backup'), journal = JSON.parse(await readFile(path.join(rollback, 'transfer.json'), 'utf8')), outcome = JSON.parse(await readFile(path.join(rollback, 'outcome.json'), 'utf8'));
independent.actualFailedWritesRestoredFromExactBackups = outcome.state === 'rolled-back' && journal.entries.length === 3 && (await Promise.all(journal.entries.map(async entry => entry.before ? hash(await readFile(entry.path)) === entry.before && hash(await readFile(path.join(rollback, entry.backup))) === entry.before : await readFile(entry.path).then(() => false, error => { if (error.code === 'ENOENT') return true; throw error; })))).every(Boolean);
for (const name of ['README.md', 'native/AgentWiki.swift', 'package.json']) independent['source:' + name] = hash(await readFile(path.join(workspace, 'source', name))) === sourceHashes[name];
for (const [name, expected] of Object.entries(legacyHashes)) independent['legacy:' + name] = hash(await readFile(path.join(workspace, name))) === expected;
report.independent = independent; report.success &&= Object.values(independent).every(Boolean); await writeFile(path.join(output, 'knowledge-sharing-report.json'), JSON.stringify(report, null, 2));
console.log(JSON.stringify({ success: report.success, output, nativeChecks: Object.keys(report.checks).length, independentChecks: Object.keys(independent).length })); if (!report.success) process.exitCode = 1;

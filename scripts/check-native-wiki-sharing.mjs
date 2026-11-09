import { spawnSync } from 'node:child_process';
import { readFile, writeFile, readdir, mkdir, mkdtemp, cp } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { isDeepStrictEqual } from 'node:util';
import { fileURLToPath } from 'node:url';
import os from 'node:os';
import path from 'node:path';

const root = fileURLToPath(new URL('../', import.meta.url)), index = process.argv.indexOf('--candidate-app');
if (index < 0 || !process.argv[index + 1]) throw Error('Use --candidate-app <strictly signed application>');
const app = path.resolve(process.argv[index + 1]), hash = data => createHash('sha256').update(data).digest('hex');
function command(file, args) { const result = spawnSync(file, args, { encoding: 'utf8' }); if (result.status !== 0) throw Error(result.stderr || file); return result.stdout; }
const pause = ms => new Promise(resolve => setTimeout(resolve, ms)), output = await mkdtemp(path.join(os.tmpdir(), 'bluefatfish-wiki-sharing-')), workspace = path.join(output, 'workspace'), snapshotRoot = path.join(output, 'source-snapshot');
async function production() {
  const base = path.join(os.homedir(), 'Library/Application Support/BlueFatFish'), names = ['settings.json', 'history.json', 'agent/index.json', 'organization.json', 'automations/definitions.json', 'models/catalog.json', 'extensions/mcp.json', 'extensions/hooks.json', 'extensions/hook-settings.json', 'extensions/settings.json', 'extensions/agents.json', 'extensions/teams.json', 'worktrees/policy.json', 'worktrees/history.json', 'worktrees/scheduler.lock', 'computer-use/settings.json', 'imports/batch.json', 'knowledge/catalog.json', 'knowledge-cards/settings.json'];
  for (const name of await readdir(path.join(base, 'agent'))) if (/^[0-9a-f-]{36}\.json$/i.test(name)) names.push('agent/' + name);
  return Object.fromEntries(await Promise.all(names.sort().map(async name => [name, await readFile(path.join(base, name)).then(hash).catch(error => { if (error.code === 'ENOENT') return null; throw error; })])));
}
const before = await production(); await writeFile(path.join(output, 'production-before.json'), JSON.stringify(before, null, 2));
const sourceHashes = {}, legacyHashes = {};
async function copySource(name, relative, convert) {
  const data = await readFile(path.join(root, name)); sourceHashes[name] = hash(data); await mkdir(path.dirname(path.join(snapshotRoot, name)), { recursive: true }); await writeFile(path.join(snapshotRoot, name), data);
  const bytes = convert ? convert(data) : data; await mkdir(path.dirname(path.join(workspace, relative)), { recursive: true }); await writeFile(path.join(workspace, relative), bytes);
  if (relative.startsWith('.bluefatfish/wiki/')) legacyHashes[relative] = hash(bytes);
}
for (const name of ['README.md', 'native/AgentWiki.swift', 'package.json']) await copySource(name, 'source/' + name);
command('/usr/bin/git', ['init', '--quiet', '--initial-branch=wiki-one', workspace]);
await writeFile(path.join(workspace, '.gitignore'), '.bluefatfish/\n'); command('/usr/bin/git', ['-C', workspace, 'add', 'source', '.gitignore']);
command('/usr/bin/git', ['-C', workspace, '-c', 'user.name=Wiki Acceptance', '-c', 'user.email=wiki-acceptance@localhost', 'commit', '--quiet', '-m', 'Actual source files for local Wiki sharing acceptance']); command('/usr/bin/git', ['-C', workspace, 'branch', 'wiki-two']);
for (const name of ['README.md', 'CHANGELOG.md', 'docs/AGENT-READING.md', 'docs/DEVELOPMENT.md', 'docs/ROADMAP.md', 'docs/REPO-WIKI.md']) await copySource(name, '.bluefatfish/wiki/project/' + name, name === 'docs/AGENT-READING.md' ? data => Buffer.concat([Buffer.from([255, 254]), Buffer.from(data.toString('utf8').replace(/\r\n/g, '\n').replace(/\n/g, '\r\n'), 'utf16le')]) : null);
for (const entry of await readdir(path.join(root, 'docs/media'), { withFileTypes: true })) if (entry.isFile() && /\.(png|jpe?g|gif|webp|heic|heif|tiff?)$/i.test(entry.name)) await copySource('docs/media/' + entry.name, '.bluefatfish/wiki/project/docs/media/' + entry.name);
await copySource('node_modules/yaml/README.md', 'source/yaml-readme.md');
const navigation = '# Wiki 导入导出\n\n[实际文档](project/docs/AGENT-READING.md#预览编辑)\n\n[实际源码](../../source/native/AgentWiki.swift#L1)\n\n[绝对源码链接](' + new URL('file://' + path.join(workspace, 'source/native/AgentWiki.swift')).href + '#L1)\n\n本目录为实际项目文档的人工导航，用于文件流转检查，并非模型生成结果。\n';
await writeFile(path.join(workspace, '.bluefatfish/wiki/index.md'), navigation); legacyHashes['.bluefatfish/wiki/index.md'] = hash(Buffer.from(navigation));
const prior = path.join(root, 'evidence/agent/bluefatfish-wiki-plan-HiOivx'), oldReady = JSON.parse(await readFile(path.join(prior, 'wiki-plan-ui-ready.json'), 'utf8'));
const oldTask = JSON.parse(await readFile(path.join(prior, 'profile/agent/index.json'), 'utf8')); const importedV2 = [];
async function findV2(directory) {
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const name = path.join(directory, entry.name);
    if (entry.isDirectory()) { if (entry.name !== 'checkpoints' && entry.name !== 'files') await findV2(name); }
    else if (entry.name.endsWith('.json')) { let value; try { value = JSON.parse(await readFile(name, 'utf8')); } catch { continue; } if (value.version === 2 && value.language === 'en' && value.branch === 'refs/heads/wiki-one' && value.root?.startsWith('.bluefatfish/wiki/.generated/')) importedV2.push(value); }
  }
}
await findV2(path.join(prior, 'profile/agent')); if (importedV2.length !== 1 || oldReady.modelsCalled !== false || !oldTask.tasks.length) throw Error('Need the actual retained V2 manual-import fixture, not fabricated model output');
const v2 = importedV2[0]; await writeFile(path.join(output, 'actual-v2-manifest.json'), JSON.stringify(v2)); await cp(path.join(prior, 'workspace', v2.root), path.join(workspace, v2.root), { recursive: true });
const binaryHash = hash(await readFile(path.join(app, 'Contents/MacOS/BlueFatFish')));
await writeFile(path.join(output, 'wiki-sharing-origin.json'), JSON.stringify({ repository: root, app, binaryHash, sourceHashes, legacyHashes, priorManualFixture: prior, modelsCalled: false }, null, 2));
command('/usr/bin/codesign', ['--verify', '--deep', '--strict', app]); console.log(JSON.stringify({ output, app, binaryHash }));
command('/usr/bin/open', ['-n', app, '--args', '--check', output, '--wiki-plan-check', '--wiki-sharing-check']);
let ready;
for (let i = 0; i < 480; i++) {
  try { ready = JSON.parse(await readFile(path.join(output, 'wiki-sharing-ui-ready.json'), 'utf8')); break; } catch (error) { if (error.code !== 'ENOENT') throw error; }
  try { const failed = JSON.parse(await readFile(path.join(output, 'wiki-sharing-report.json'), 'utf8')); throw Error(JSON.stringify(failed)); } catch (error) { if (error.code !== 'ENOENT') throw error; }
  await pause(250);
}
if (!ready || ready.binaryHash !== binaryHash) throw Error('Actual candidate did not finish native checks; retain this run'); console.log(JSON.stringify({ ready: true, appPID: ready.appPID, output, checks: ready.checks }));
let report;
for (let i = 0; i < 7200; i++) { try { report = JSON.parse(await readFile(path.join(output, 'wiki-sharing-report.json'), 'utf8')); break; } catch (error) { if (error.code !== 'ENOENT') throw error; } await pause(500); }
if (!report) throw Error('Actual UI acceptance is unfinished; retain this run');
const after = await production(); await writeFile(path.join(output, 'production-after.json'), JSON.stringify(after, null, 2));
const independent = { productionProfileUnchanged: isDeepStrictEqual(before, after), actualCandidate: report.binaryHash === binaryHash && report.appPID === ready.appPID, noModelCalls: report.modelsCalled === false };
for (const [name, expected] of Object.entries(legacyHashes)) independent['legacy:' + name] = hash(await readFile(path.join(workspace, name))) === expected;
for (const name of ['README.md', 'native/AgentWiki.swift', 'package.json']) independent['projectSource:' + name] = hash(await readFile(path.join(workspace, 'source', name))) === sourceHashes[name];
report.independent = independent; report.success &&= Object.values(independent).every(Boolean); await writeFile(path.join(output, 'wiki-sharing-report.json'), JSON.stringify(report, null, 2));
console.log(JSON.stringify({ success: report.success, output, nativeChecks: Object.keys(report.checks).length, independentChecks: Object.keys(independent).length })); if (!report.success) process.exitCode = 1;

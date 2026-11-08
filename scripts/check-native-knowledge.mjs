import { spawnSync } from 'node:child_process';
import { readFile, writeFile, readdir, mkdtemp, mkdir, cp, unlink } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { isDeepStrictEqual } from 'node:util';
import { fileURLToPath } from 'node:url';
import os from 'node:os';
import path from 'node:path';

const root = fileURLToPath(new URL('../', import.meta.url)), resume = process.argv.indexOf('--resume');
const output = resume < 0 ? await mkdtemp(path.join(os.tmpdir(), 'bluefatfish-knowledge-')) : path.resolve(process.argv[resume + 1]);
if (!path.basename(output).startsWith('bluefatfish-knowledge-')) throw new Error('Use an actual knowledge acceptance directory');
const hash = value => createHash('sha256').update(value).digest('hex');
const json = async name => JSON.parse(await readFile(path.join(output, name), 'utf8'));
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
function command(executable, args) { const result = spawnSync(executable, args, { encoding: 'utf8' }); if (result.status !== 0) throw new Error(result.stderr || result.stdout || executable); return result.stdout; }
function live(pid) { try { process.kill(pid, 0); return true; } catch (error) { if (error.code === 'ESRCH') return false; throw error; } }
async function snapshot() {
  const base = path.join(os.homedir(), 'Library/Application Support/BlueFatFish');
  const names = ['settings.json', 'history.json', 'agent/index.json', 'organization.json', 'automations/definitions.json', 'models/catalog.json', 'extensions/mcp.json', 'extensions/hooks.json', 'extensions/hook-settings.json', 'extensions/settings.json', 'extensions/agents.json', 'extensions/teams.json', 'worktrees/policy.json', 'worktrees/history.json', 'worktrees/scheduler.lock', 'computer-use/settings.json', 'imports/batch.json', 'knowledge/catalog.json'];
  for (const name of await readdir(path.join(base, 'agent'))) if (/^[0-9a-f-]{36}\.json$/i.test(name)) names.push('agent/' + name);
  return Object.fromEntries(await Promise.all(names.sort().map(async name => [name, await readFile(path.join(base, name)).then(hash).catch(error => { if (error.code === 'ENOENT') return null; throw error; })])));
}
const before = resume < 0 ? await snapshot() : await json('production-before.json');
if (!isDeepStrictEqual(before, await snapshot())) throw new Error('Preserve and inspect changed daily data');
if (resume < 0) await writeFile(path.join(output, 'production-before.json'), JSON.stringify(before, null, 2));
console.log(JSON.stringify({ output }));
if (process.argv.includes('--prepare-only')) process.exit(0);
const app = path.join(root, 'build/蓝色大肥鱼.app'), binaryHash = hash(await readFile(path.join(app, 'Contents/MacOS/BlueFatFish')));
const manifestPath = path.join(root, 'vendor/sherpa-onnx/manifest.json'), manifestBytes = await readFile(manifestPath), manifest = JSON.parse(manifestBytes);
async function waitJSON(name, seconds, pid) {
  const deadline = Date.now() + seconds * 1000;
  while (Date.now() < deadline) {
    const value = await json(name).catch(error => { if (error.code === 'ENOENT' || error instanceof SyntaxError) return null; throw error; });
    if (value) return value;
    if (pid && !live(pid)) { const failure = await json('knowledge-report.json').catch(() => null); throw new Error(failure?.error || 'Actual application exited before ' + name); }
    await pause(200);
  }
  throw new Error('Observation deadline; preserve the original knowledge process');
}
let report;
try {
  const previous = await json('knowledge-process.json').catch(() => null);
  if (previous && live(previous.appPID)) throw new Error('Existing knowledge acceptance is still running; preserve it');
  for (const name of ['knowledge-process.json', 'knowledge-ui-ready.json', 'knowledge-report.json', 'finish-knowledge-ui']) await unlink(path.join(output, name)).catch(error => { if (error.code !== 'ENOENT') throw error; });
  command('/usr/bin/open', ['-n', app, '--args', '--check', output, '--knowledge-check', '--live-agent', '--knowledge-source', manifestPath]);
  const owner = await waitJSON('knowledge-process.json', 30), ready = await waitJSON('knowledge-ui-ready.json', 180, owner.appPID);
  if (ready.binaryHash !== binaryHash) throw new Error('Actual UI candidate mismatch');
  console.log(JSON.stringify({ phase: 'actual-ui-ready', outputDirectory: output, ...ready }));
  report = await waitJSON('knowledge-report.json', 2000, owner.appPID);
  for (let i = 0; i < 100 && live(owner.appPID); i++) await pause(100);
  if (live(owner.appPID)) throw new Error('Original application is still running');
  if (!report.success) throw new Error(report.error || 'Knowledge acceptance failed');
  const task = JSON.parse(await readFile(path.join(output, 'profile/agent', ready.taskID + '.json'), 'utf8')), receipts = task.modelReceipts ?? [];
  const catalog = JSON.parse(await readFile(path.join(output, 'profile/knowledge/catalog.json'), 'utf8'));
  const base = catalog.bases.find(value => value.name === '离线语音依赖' && value.workspace == null && !value.archived);
  const source = catalog.sources.find(value => value.baseID === base?.id && value.file.sha256 === hash(manifestBytes) && !value.archived);
  const copied = source && await readFile(path.join(output, 'profile/knowledge/sources', source.file.id, 'source.json'));
  const reply = JSON.parse(report.reply.slice(report.reply.indexOf('{'), report.reply.lastIndexOf('}') + 1));
  const expected = { version: manifest.version, runtime: { sha256: manifest.runtime.sha256 }, libraries: manifest.libraries };
  const actual = { version: reply.version, runtime: { sha256: reply.runtime?.sha256 }, libraries: reply.libraries };
  const downloadOrigin = await json('knowledge-download-origin.json'), download = await readFile(downloadOrigin.path);
  await writeFile(path.join(output, 'downloaded-manifest.json'), download);
  report.download = { actualSavedPath: downloadOrigin.path, savedFileSHA256: hash(download) };
  const accounted = receipts.length > 0 && receipts.every(value => Number.isInteger(value.inputTokens) && Number.isInteger(value.outputTokens)) && receipts.reduce((n, value) => n + value.inputTokens, 0) === task.inputTokens && receipts.reduce((n, value) => n + value.outputTokens, 0) === task.outputTokens;
  report.independent = {
    productionProfileUnchanged: isDeepStrictEqual(before, await snapshot()),
    originalSourceSHA256: hash(manifestBytes),
    importedActualSourceMatches: !!copied && hash(copied) === hash(manifestBytes),
    downloadedFileMatches: hash(download) === hash(manifestBytes),
    realModelAnswerMatchesOriginalManifest: isDeepStrictEqual(actual, expected),
    receiptAccountingMatches: accounted,
    selectedWorkspaceRemainsUnset: task.workspace == null,
    modeRemainsAsk: task.mode === 'ask',
  };
  report.success &&= Object.values(report.native.checks).every(Boolean) && Object.entries(report.independent).filter(([key]) => key !== 'originalSourceSHA256').every(([, value]) => value === true);
} catch (error) { report = { ...(report ?? {}), success: false, error: error.message }; }
finally {
  await writeFile(path.join(output, 'knowledge-driver-report.json'), JSON.stringify(report, null, 2));
  const archive = path.join(root, 'evidence/agent', path.basename(output) + '-' + new Date().toISOString().replace(/[:.]/g, '-'));
  await mkdir(path.dirname(archive), { recursive: true }); await cp(output, archive, { recursive: true });
  console.log(JSON.stringify({ success: report?.success, output, archive, error: report?.error }));
}
if (!report?.success) process.exitCode = 1;

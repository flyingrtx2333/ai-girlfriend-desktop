import { spawnSync } from 'node:child_process';
import { readFile, writeFile, readdir, mkdtemp, mkdir, cp } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { isDeepStrictEqual } from 'node:util';
import { fileURLToPath } from 'node:url';
import os from 'node:os';
import path from 'node:path';

const root = fileURLToPath(new URL('../', import.meta.url));
const editing = process.argv.includes('--editing'), prefix = editing ? 'markdown-edit' : 'markdown';
const candidate = process.argv.indexOf('--candidate-app');
if (candidate < 0 || !process.argv[candidate + 1]) throw new Error('Use --candidate-app <signed application>');
const app = path.resolve(process.argv[candidate + 1]);
const output = await mkdtemp(path.join(os.tmpdir(), 'bluefatfish-' + prefix + '-'));
const hash = data => createHash('sha256').update(data).digest('hex');
function command(file, args) {
  const result = spawnSync(file, args, { encoding: 'utf8' });
  if (result.status !== 0) throw new Error(result.stderr || file);
  return result.stdout;
}
async function snapshot() {
  const base = path.join(os.homedir(), 'Library/Application Support/BlueFatFish');
  const names = ['settings.json', 'history.json', 'agent/index.json', 'organization.json', 'automations/definitions.json', 'models/catalog.json', 'extensions/mcp.json', 'extensions/hooks.json', 'extensions/hook-settings.json', 'extensions/settings.json', 'extensions/agents.json', 'extensions/teams.json', 'worktrees/policy.json', 'worktrees/history.json', 'worktrees/scheduler.lock', 'computer-use/settings.json', 'imports/batch.json', 'knowledge/catalog.json', 'knowledge-cards/settings.json'];
  for (const name of await readdir(path.join(base, 'agent'))) if (/^[0-9a-f-]{36}\.json$/i.test(name)) names.push('agent/' + name);
  return Object.fromEntries(await Promise.all(names.sort().map(async name => [name, await readFile(path.join(base, name)).then(hash).catch(error => { if (error.code === 'ENOENT') return null; throw error; })])));
}
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
const before = await snapshot(); await writeFile(path.join(output, 'production-before.json'), JSON.stringify(before, null, 2));
const source = path.join(output, 'source-snapshot'), sourceHashes = {};
const documents = ['README.md', 'docs/DEVELOPMENT.md', 'docs/AGENT-READING.md', 'native/AgentWiki.swift'];
for (const entry of await readdir(path.join(root, 'docs/media'), { withFileTypes: true })) if (entry.isFile() && /\.(png|jpe?g|gif|webp|heic|heif|tiff?)$/i.test(entry.name)) documents.push('docs/media/' + entry.name);
for (const name of documents) {
  const bytes = await readFile(path.join(root, name)); sourceHashes[name] = hash(bytes);
  await mkdir(path.dirname(path.join(source, name)), { recursive: true }); await writeFile(path.join(source, name), bytes);
}
await writeFile(path.join(output, prefix + '-source-origin.json'), JSON.stringify({ repository: root, source, files: sourceHashes }, null, 2));
const binary = path.join(app, 'Contents/MacOS/BlueFatFish'), binaryHash = hash(await readFile(binary));
let report;
try {
  command('/usr/bin/codesign', ['--verify', '--deep', '--strict', app]);
  const signing = spawnSync('/usr/bin/codesign', ['-d', '--verbose=4', app], { encoding: 'utf8' });
  if (signing.status !== 0 || !/^Authority=(Developer ID Application:|Apple Development:)/m.test(signing.stderr) || !/^TeamIdentifier=8BPSC5L74V$/m.test(signing.stderr)) throw new Error('Use the project signing identity');
  command('/usr/bin/open', ['-n', app, '--args', '--check', output, '--' + prefix + '-check', '--' + prefix + '-source', source]);
  let ready;
  for (let i = 0; i < 480; i++) {
    ready = await readFile(path.join(output, prefix + '-ui-ready.json'), 'utf8').then(JSON.parse).catch(error => { if (error.code === 'ENOENT') return null; throw error; });
    if (ready) break;
    const failed = await readFile(path.join(output, prefix + '-report.json'), 'utf8').then(JSON.parse).catch(error => { if (error.code === 'ENOENT') return null; throw error; });
    if (failed) throw new Error(failed.error || 'Native reader checks failed before UI');
    await pause(500);
  }
  if (!ready || ready.binaryHash !== binaryHash || ready.modelsCalled !== false) throw new Error('Actual reader candidate mismatch');
  console.log(JSON.stringify({ phase: 'actual-ui-ready', output, ...ready }));
  for (let i = 0; i < 7200; i++) {
    report = await readFile(path.join(output, prefix + '-report.json'), 'utf8').then(JSON.parse).catch(error => { if (error.code === 'ENOENT') return null; throw error; });
    if (report) break;
    await pause(500);
  }
  if (!report) throw new Error('Keep the original reader process and inspect it before retrying');
  const records = [];
  for (const name of await readdir(path.join(output, 'profile/agent'))) if (/^[0-9a-f-]{36}\.json$/i.test(name)) records.push(JSON.parse(await readFile(path.join(output, 'profile/agent', name), 'utf8')));
  const originalTask = records.find(record => record.id === ready.taskID), otherTask = records.find(record => record.id === ready.otherTaskID);
  report.actualTaskReadback = { tasks: records.length, modelRequests: records.reduce((sum, record) => sum + (record.modelReceipts?.length ?? 0), 0), messages: records.reduce((sum, record) => sum + record.messages.length, 0), queued: records.reduce((sum, record) => sum + (record.queuedMessages?.length ?? 0) + (record.queuedInputs?.length ?? 0), 0) };
  const originalDocuments = await Promise.all(Object.entries(sourceHashes).map(async ([name, digest]) => hash(await readFile(path.join(root, name))) === digest));
  report.independent = { dailyProfileUnchanged: isDeepStrictEqual(before, await snapshot()), binaryMatches: report.binaryHash === binaryHash, projectSignatureVerified: true, originalRepositoryDocumentsUnchanged: originalDocuments.every(Boolean), actualTaskFilesHaveNoModelRequestsOrMessages: records.length >= 3 && report.actualTaskReadback.modelRequests === 0 && report.actualTaskReadback.messages === 0 && report.actualTaskReadback.queued === 0, bothTaskDraftsPersisted: (editing ? originalTask?.draft === '保留的A草稿' : originalTask?.draft?.startsWith('保留的A草稿\n\n[文件选文：docs/AGENT-READING.md]') === true) && otherTask?.draft === '保留的B草稿' };
  if (editing) {
    const plan = JSON.parse(await readFile(path.join(output, 'markdown-edit-plan.json'), 'utf8'));
    report.independent.externalVersionPreserved = hash(await readFile(plan.file)) === plan.externalHash;
    report.independent.unsavedDraftRetained = hash(await readFile(path.join(output, 'retained-unsaved-draft.md'))) === plan.draftHash;
  }
  report.success &&= report.modelsCalled === false && Object.values(report.independent).every(Boolean);
} catch (error) { report = { ...(report ?? {}), success: false, error: error.message }; }
await writeFile(path.join(output, prefix + '-driver-report.json'), JSON.stringify(report, null, 2));
const archive = path.join(root, 'evidence/agent', path.basename(output)); await mkdir(path.dirname(archive), { recursive: true }); await cp(output, archive, { recursive: true });
console.log(JSON.stringify({ success: report.success, output, archive, error: report.error }));
if (!report.success) process.exitCode = 1;

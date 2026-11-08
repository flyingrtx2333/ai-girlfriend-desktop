import { spawnSync } from 'node:child_process';
import { readFile, writeFile, readdir, mkdtemp, mkdir, cp, chmod } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { isDeepStrictEqual } from 'node:util';
import { fileURLToPath } from 'node:url';
import os from 'node:os';
import path from 'node:path';

const root = fileURLToPath(new URL('../', import.meta.url));
const option = name => { const index = process.argv.indexOf(name); if (index < 0 || !process.argv[index + 1]) throw new Error('Use ' + name); return path.resolve(process.argv[index + 1]); };
const app = option('--candidate-app'), media = option('--media-directory');
const output = await mkdtemp(path.join(os.tmpdir(), 'bluefatfish-video-preview-'));
const hash = data => createHash('sha256').update(data).digest('hex');
function command(file, args) {
  const result = spawnSync(file, args, { encoding: 'utf8' });
  if (result.status !== 0) throw new Error(result.stderr || file); return result.stdout;
}
async function snapshot() {
  const base = path.join(os.homedir(), 'Library/Application Support/BlueFatFish');
  const names = ['settings.json', 'history.json', 'agent/index.json', 'organization.json', 'automations/definitions.json', 'models/catalog.json', 'extensions/mcp.json', 'extensions/hooks.json', 'extensions/hook-settings.json', 'extensions/settings.json', 'extensions/agents.json', 'extensions/teams.json', 'worktrees/policy.json', 'worktrees/history.json', 'worktrees/scheduler.lock', 'computer-use/settings.json', 'imports/batch.json', 'knowledge/catalog.json', 'knowledge-cards/settings.json'];
  for (const name of await readdir(path.join(base, 'agent'))) if (/^[0-9a-f-]{36}\.json$/i.test(name)) names.push('agent/' + name);
  return Object.fromEntries(await Promise.all(names.sort().map(async name => [name, await readFile(path.join(base, name)).then(hash).catch(error => { if (error.code === 'ENOENT') return null; throw error; })])));
}
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
const before = await snapshot(); await writeFile(path.join(output, 'production-before.json'), JSON.stringify(before, null, 2));
const origin = JSON.parse(await readFile(path.join(media, 'media-origin.json'), 'utf8'));
if (origin.files.length !== 2 || !['flower.mp4', 'flower.webm'].every(name => origin.files.some(file => file.name === name))) throw new Error('Use the two independently probed real MP4/WebM files');
const workspace = path.join(output, 'workspace'); await mkdir(path.join(workspace, 'media'), { recursive: true }); await mkdir(path.join(workspace, 'docs'));
for (const file of origin.files) {
  const bytes = await readFile(path.join(media, file.name)); if (hash(bytes) !== file.sha256) throw new Error('Media source changed');
  await writeFile(path.join(workspace, 'media', file.name), bytes); await chmod(path.join(workspace, 'media', file.name), 0o444);
  await cp(path.join(media, file.name + '.probe.json'), path.join(output, file.name + '.probe.json'));
}
await writeFile(path.join(output, 'media-origin.json'), JSON.stringify(origin, null, 2));
const guide = await readFile(path.join(root, 'docs/AGENT-READING.md'));
await writeFile(path.join(workspace, 'docs/VIDEO.md'), Buffer.concat([guide, Buffer.from('\n\n## 视频来源\n\n[播放 MP4](../media/flower.mp4)\n\n[播放 WebM](../media/flower.webm)\n')]));
await writeFile(path.join(output, 'project-guide-source.json'), JSON.stringify({ path: 'docs/AGENT-READING.md', sha256: hash(guide) }, null, 2));
const binaryHash = hash(await readFile(path.join(app, 'Contents/MacOS/BlueFatFish')));
let report;
try {
  command('/usr/bin/codesign', ['--verify', '--deep', '--strict', app]);
  const signing = spawnSync('/usr/bin/codesign', ['-d', '--verbose=4', app], { encoding: 'utf8' });
  if (signing.status !== 0 || !/^Authority=(Developer ID Application:|Apple Development:)/m.test(signing.stderr) || !/^TeamIdentifier=8BPSC5L74V$/m.test(signing.stderr)) throw new Error('Use the project signing identity');
  command('/usr/bin/open', ['-n', app, '--args', '--check', output, '--video-preview-check']);
  let ready;
  for (let i = 0; i < 480; i++) {
    ready = await readFile(path.join(output, 'video-preview-ui-ready.json'), 'utf8').then(JSON.parse).catch(error => { if (error.code === 'ENOENT') return null; throw error; });
    if (ready) break;
    const failed = await readFile(path.join(output, 'video-preview-report.json'), 'utf8').then(JSON.parse).catch(error => { if (error.code === 'ENOENT') return null; throw error; });
    if (failed) { report = failed; throw new Error(failed.error || 'Native video checks failed before UI'); }
    await pause(500);
  }
  if (!ready || ready.binaryHash !== binaryHash || ready.modelsCalled !== false) throw new Error('Actual video candidate mismatch');
  console.log(JSON.stringify({ phase: 'actual-ui-ready', output, ...ready }));
  for (let i = 0; i < 7200; i++) {
    report = await readFile(path.join(output, 'video-preview-report.json'), 'utf8').then(JSON.parse).catch(error => { if (error.code === 'ENOENT') return null; throw error; });
    if (report) break; await pause(500);
  }
  if (!report) throw new Error('Keep the original live video process and inspect it before retrying');
  const records = [];
  for (const name of await readdir(path.join(output, 'profile/agent'))) if (/^[0-9a-f-]{36}\.json$/i.test(name)) records.push(JSON.parse(await readFile(path.join(output, 'profile/agent', name), 'utf8')));
  const original = records.find(record => record.id === ready.taskID), other = records.find(record => record.id === ready.otherTaskID);
  report.actualTaskReadback = { tasks: records.length, modelRequests: records.reduce((sum, record) => sum + (record.modelReceipts?.length ?? 0), 0), messages: records.reduce((sum, record) => sum + record.messages.length, 0), queued: records.reduce((sum, record) => sum + (record.queuedMessages?.length ?? 0) + (record.queuedInputs?.length ?? 0), 0) };
  report.independent = {
    dailyProfileUnchanged: isDeepStrictEqual(before, await snapshot()), binaryMatches: report.binaryHash === binaryHash, projectSignatureVerified: true,
    mediaFilesUnchanged: (await Promise.all(origin.files.map(async file => hash(await readFile(path.join(workspace, 'media', file.name))) === file.sha256))).every(Boolean),
    originalRepositoryGuideUnchanged: hash(await readFile(path.join(root, 'docs/AGENT-READING.md'))) === hash(guide),
    actualTaskFilesHaveNoModelRequestsOrMessages: records.length >= 3 && report.actualTaskReadback.modelRequests === 0 && report.actualTaskReadback.messages === 0 && report.actualTaskReadback.queued === 0,
    bothTaskDraftsPersisted: original?.draft === '保留的A草稿' && other?.draft === '保留的B草稿',
  };
  if (report.uiValidated) {
    const initial = JSON.parse(await readFile(path.join(output, 'native-video-initial.json'), 'utf8'));
    const fullscreen = JSON.parse(await readFile(path.join(output, 'native-video-fullscreen-playing.json'), 'utf8'));
    const restored = JSON.parse(await readFile(path.join(output, 'native-video-record-restored.json'), 'utf8'));
    report.independent.actualFullscreenPlayback = fullscreen.appPID === ready.appPID && fullscreen.player?.fullscreen === true && fullscreen.player?.paused === false && fullscreen.player?.frames > 0 && fullscreen.player?.clientHeight >= 350;
    report.independent.exitFullscreenRestoresActualPlayerArea = restored.appPID === ready.appPID && restored.player?.fullscreen === false && restored.player?.clientHeight >= 200 && restored.player?.clientWidth === initial.player?.clientWidth && restored.player?.clientHeight === initial.player?.clientHeight;
  }
  report.success &&= report.modelsCalled === false && Object.values(report.independent).every(Boolean);
} catch (error) { report = { ...(report ?? {}), success: false, error: error.message }; }
await writeFile(path.join(output, 'video-preview-driver-report.json'), JSON.stringify(report, null, 2));
const archive = path.join(root, 'evidence/agent', path.basename(output)); await mkdir(path.dirname(archive), { recursive: true }); await cp(output, archive, { recursive: true });
console.log(JSON.stringify({ success: report.success, output, archive, error: report.error }));
if (!report.success) process.exitCode = 1;

import { spawn, spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { createWriteStream } from 'node:fs';
import { chmod, mkdir, mkdtemp, readFile, readdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../', import.meta.url));
const option = name => { const i = process.argv.indexOf(name); return i < 0 ? undefined : process.argv[i + 1]; };
if (process.argv.includes('--live-agent')) throw Error('Video acceptance does not call models');
const app = process.env.BLUEFATFISH_APP;
if (!app) throw Error('Set BLUEFATFISH_APP to an independent acceptance application');
const binary = path.join(app, 'Contents/MacOS/BlueFatFish'), hash = bytes => createHash('sha256').update(bytes).digest('hex');
const command = (file, args) => { const p = spawnSync(file, args, { encoding: 'utf8' }); if (p.status !== 0) throw Error(p.stderr || file); return p.stdout; };
command('/usr/bin/codesign', ['--verify', '--deep', '--strict', app]);
const metadata = JSON.parse(command('/usr/bin/plutil', ['-convert', 'json', '-o', '-', path.join(app, 'Contents/Info.plist')]));
if (metadata.BlueFatFishAcceptanceOnly !== true) throw Error('Use an acceptance-only application; daily data must remain isolated');
const reopen = option('--reopen'), manual = !!reopen || process.argv.includes('--manual-ui'), knowledge = process.argv.includes('--knowledge');
await mkdir(path.join(root, 'evidence/agent'), { recursive: true });
const output = reopen ? path.resolve(reopen) : await mkdtemp(path.join(root, 'evidence/agent/video-workspace-command-'));
for (const name of ['tmp', 'shared-home']) await mkdir(path.join(output, name), { recursive: true });
if (!reopen) {
  const media = option('--media-directory');
  if (!media) throw Error('Use --media-directory with independently verified public MP4 and WebM files');
  const origin = JSON.parse(await readFile(path.join(media, 'media-origin.json'), 'utf8'));
  const workspace = path.join(output, 'workspace'), probes = {};
  for (const name of ['media', 'docs']) await mkdir(path.join(workspace, name), { recursive: true });
  for (const name of ['flower.mp4', 'flower.webm']) {
    const source = origin.files.find(f => f.name === name), bytes = await readFile(path.join(media, name));
    if (!source || hash(bytes) !== source.sha256) throw Error('Public video source changed: ' + name);
    const target = path.join(workspace, 'media', name); await writeFile(target, bytes); await chmod(target, 0o444);
    const probe = JSON.parse(command(process.env.FFPROBE_PATH ?? '/opt/homebrew/bin/ffprobe', ['-v', 'quiet', '-show_format', '-show_streams', '-of', 'json', target]));
    if (Math.abs(Number(probe.format.duration) - source.duration) > 0.01 || !probe.streams.some(s => s.codec_type === 'video' && s.width === 960 && s.height === 540)) throw Error('Independent decoder metadata mismatch: ' + name);
    probes[name] = probe;
  }
  const original = await readFile(path.join(workspace, 'media/flower.mp4')), free = Buffer.alloc(1_200_008);
  free.writeUInt32BE(free.length, 0); free.write('free', 4, 'ascii');
  const large = path.join(workspace, 'media/flower-large.mp4'); await writeFile(large, Buffer.concat([original, free])); await chmod(large, 0o444);
  const largeProbe = JSON.parse(command(process.env.FFPROBE_PATH ?? '/opt/homebrew/bin/ffprobe', ['-v', 'quiet', '-show_format', '-show_streams', '-of', 'json', large]));
  if (Number(largeProbe.format.size) <= 2_000_000 || Math.abs(Number(largeProbe.format.duration) - 5.055) > 0.01) throw Error('Large real MP4 is invalid');
  probes['flower-large.mp4'] = largeProbe;
  await writeFile(path.join(workspace, 'media/broken.mp4'), original.subarray(0, 128)); await chmod(path.join(workspace, 'media/broken.mp4'), 0o444);
  await writeFile(path.join(workspace, 'docs/VIDEO.md'), '# 视频资料\n\n[播放 MP4](../media/flower.mp4)\n\n[播放 WebM](../media/flower.webm)\n'); await chmod(path.join(workspace, 'docs/VIDEO.md'), 0o600);
  await writeFile(path.join(output, 'independent-media-probes.json'), JSON.stringify(probes, null, 2) + '\n');
  await writeFile(path.join(output, 'media-origin.json'), JSON.stringify(origin, null, 2) + '\n');
}
const phase = reopen ? `restart-${Date.now()}` : 'initial', binaryHash = hash(await readFile(binary));
const args = ['--check', output, ...(manual ? ['--manual-ui', knowledge ? (reopen ? '--knowledge-video-reopen' : '--knowledge-video-fixtures') : (reopen ? '--video-workspace-reopen' : '--video-workspace-fixtures')] : ['--video-workspace-check', ...(knowledge ? ['--knowledge-video-check'] : [])])];
const child = spawn(binary, args, { stdio: ['ignore', 'pipe', 'pipe'], env: { ...process.env, TMPDIR: path.join(output, 'tmp') + '/' } });
const log = createWriteStream(path.join(output, `launch-${phase}.log`)); child.stdout.pipe(log, { end: false }); child.stderr.pipe(log, { end: false });
await writeFile(path.join(output, `launch-${phase}.json`), JSON.stringify({ app, appPID: child.pid, binaryHash, args }, null, 2) + '\n');
console.log(JSON.stringify({ output, appPID: child.pid, binaryHash, manual }));
try {
  const status = await new Promise((resolve, reject) => { child.once('error', reject); child.once('close', (code, signal) => resolve({ code, signal })); });
  const report = JSON.parse(await readFile(path.join(output, manual ? `manual-ui-result-${child.pid}.json` : 'video-workspace-report.json'), 'utf8'));
  const fixture = JSON.parse(await readFile(path.join(output, 'video-workspace-fixtures.json'), 'utf8'));
  const directory = path.join(output, 'profile/agent'), tasks = await Promise.all((await readdir(directory)).filter(n => /^[0-9a-f-]{36}\.json$/i.test(n)).map(n => readFile(path.join(directory, n), 'utf8').then(JSON.parse)));
  const independent = { sameApplication: report.appPID === child.pid && report.binaryHash === binaryHash && hash(await readFile(binary)) === binaryHash,
    noModelRequests: report.modelRequests === 0 && tasks.every(t => !t.inputTokens && !t.outputTokens && !(t.modelReceipts ?? []).length && !t.messages.length),
    firstTaskInputPreserved: tasks.find(t => t.id === fixture.taskID)?.draft === '保留视频任务输入。', otherTaskInputPreserved: tasks.find(t => t.id === fixture.otherID)?.draft === '保留另一视频任务输入。' };
  if (!manual) {
    independent.actualSourceBytesRemain = Object.entries(report.sourceHashes ?? {}).length === 5 && (await Promise.all(Object.entries(report.sourceHashes ?? {}).map(async ([file, expected]) => hash(await readFile(file)) === expected))).every(Boolean);
  }
  const success = status.code === 0 && (manual || report.success === true && Object.values(report.checks).every(Boolean)) && Object.values(independent).every(Boolean);
  await writeFile(path.join(output, `independent-${phase}.json`), JSON.stringify({ ...report, independent, status, success }, null, 2) + '\n');
  console.log(JSON.stringify({ output, success, checks: Object.keys(report.checks ?? {}).length, failed: Object.keys(report.checks ?? {}).filter(k => !report.checks[k]), independent, error: report.error })); process.exitCode = success ? 0 : 1;
} finally { log.end(); }

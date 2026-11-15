import { spawn, spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { createWriteStream } from 'node:fs';
import { chmod, mkdir, mkdtemp, readFile, realpath, stat, writeFile } from 'node:fs/promises';
import { createServer } from 'node:http';
import { finished } from 'node:stream/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const root = fileURLToPath(new URL('../', import.meta.url)), app = process.env.BLUEFATFISH_APP;
const option = name => { const i = process.argv.indexOf(name); return i < 0 ? null : process.argv[i + 1]; };
const reopen = option('--reopen'), manual = process.argv.includes('--manual-ui'), media = option('--media-directory');
if (!app || process.argv.includes('--live-agent') || (!reopen && !media)) throw Error('请指定独立验收应用及已核对的公开视频目录；本检查不调用模型。');
const command = (file, args) => { const p = spawnSync(file, args, { encoding: 'utf8' }); if (p.status !== 0) throw Error(p.stderr || p.stdout || file); return p.stdout; };
const info = JSON.parse(command('/usr/bin/plutil', ['-convert', 'json', '-o', '-', path.join(app, 'Contents/Info.plist')]));
if (info.BlueFatFishAcceptanceOnly !== true || !info.CFBundleIdentifier?.startsWith('com.xjs.bluefatfish.')) throw Error('子窗口恢复只能使用独立验收应用。');
command('/usr/bin/codesign', ['--verify', '--deep', '--strict', app]);
const evidence = await realpath(path.join(root, 'evidence/agent'));
const output = reopen ? await realpath(reopen) : await mkdtemp(path.join(evidence, 'child-recovery-command-'));
if (!output.startsWith(evidence + path.sep)) throw Error('验收资料必须留在项目外置盘。');
for (const name of ['tmp', 'shared-home', 'workspace/media']) await mkdir(path.join(output, name), { recursive: true, mode: 0o700 });
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
if (!reopen) {
  const origin = JSON.parse(await readFile(path.join(media, 'media-origin.json'), 'utf8')), probes = {};
  for (const name of ['flower.mp4', 'flower.webm']) {
    const source = origin.files.find(f => f.name === name), bytes = await readFile(path.join(media, name));
    if (!source || hash(bytes) !== source.sha256) throw Error('公开视频来源摘要变化：' + name);
    const target = path.join(output, 'workspace/media', name); await writeFile(target, bytes); await chmod(target, 0o444);
    const probe = JSON.parse(command(process.env.FFPROBE_PATH ?? '/opt/homebrew/bin/ffprobe', ['-v', 'quiet', '-show_format', '-show_streams', '-of', 'json', target]));
    if (Math.abs(Number(probe.format.duration) - source.duration) > 0.01 || !probe.streams.some(s => s.codec_type === 'video' && s.width === 960 && s.height === 540)) throw Error('独立解码元数据不匹配：' + name);
    probes[name] = probe;
  }
  await writeFile(path.join(output, 'workspace/README.md'), 'PUBLIC_CHILD_GUIDE_417\n');
  await writeFile(path.join(output, 'media-origin.json'), JSON.stringify(origin, null, 2) + '\n');
  await writeFile(path.join(output, 'independent-media-probes.json'), JSON.stringify(probes, null, 2) + '\n');
}
const requests = [], results = [];
const html = '<!doctype html><meta charset="utf-8"><title>子窗口公开验收</title><style>body{font:18px system-ui;padding:36px;background:#f6f8fa;color:#182b2b}main{padding:30px;background:white;border-left:8px solid #168b79}label{display:block;margin:20px 0}input,textarea{display:block;font:inherit;width:90%;padding:10px}</style><main><h1>PUBLIC CHILD WINDOW</h1><label>标题<input id="title" value="PUBLIC_CHILD_TITLE"></label><label>备注<textarea id="note">PUBLIC_CHILD_FORM</textarea></label><p>公开页面 · 本机截图标注验收</p></main>';
const server = createServer((req, res) => { requests.push({ method: req.method, url: req.url }); res.writeHead(req.method === 'GET' ? 200 : 405, { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' }); res.end(req.method === 'GET' ? html : 'Method not allowed'); });
const port = reopen ? new URL(JSON.parse(await readFile(path.join(output, 'browser-input.json'), 'utf8')).url).port : 0;
await new Promise((resolve, reject) => { server.once('error', reject); server.listen(port, '127.0.0.1', resolve); });
if (!reopen) await writeFile(path.join(output, 'browser-input.json'), JSON.stringify({ url: `http://127.0.0.1:${server.address().port}/` }, null, 2) + '\n');
const binary = path.join(app, 'Contents/MacOS/BlueFatFish'), binaryHash = hash(await readFile(binary));
async function run(stage, ui = false) {
  const label = `${stage}-${Date.now()}`, args = ['--check', output, ui ? '--workspace-child-recovery-ui' : '--workspace-child-recovery-check', '--recovery-stage', stage];
  const child = spawn(binary, args, { env: { ...process.env, TMPDIR: path.join(output, 'tmp') + '/' }, stdio: ['ignore', 'pipe', 'pipe'] });
  const stdout = createWriteStream(path.join(output, label + '-stdout.log')), stderr = createWriteStream(path.join(output, label + '-stderr.log')); child.stdout.pipe(stdout); child.stderr.pipe(stderr);
  const identity = { app, appPID: child.pid, binaryHash, args, stage, label };
  await writeFile(path.join(output, label + '-process.json'), JSON.stringify(identity, null, 2) + '\n'); console.log(JSON.stringify({ output, ...identity }));
  const status = await new Promise((resolve, reject) => { child.once('error', reject); child.once('exit', (exit, signal) => resolve({ exit, signal })); });
  await Promise.all([finished(stdout), finished(stderr)]);
  const bytes = await readFile(path.join(output, ui ? 'child-recovery-ui-ready.json' : 'child-recovery-report.json')); await writeFile(path.join(output, label + '-report.json'), bytes);
  const report = JSON.parse(bytes), sameApplication = report.appPID === child.pid && report.binaryHash === binaryHash && hash(await readFile(binary)) === binaryHash;
  const result = { stage, label, ...status, sameApplication, success: status.exit === 0 && sameApplication && report.success === true && report.modelRequests === 0 && Object.values(report.checks).every(Boolean), checks: Object.keys(report.checks).length, failed: Object.keys(report.checks).filter(k => !report.checks[k]), error: report.error, modelRequests: report.modelRequests };
  results.push(result); await writeFile(path.join(output, label + '-result.json'), JSON.stringify(result, null, 2) + '\n'); console.log(JSON.stringify({ output, ...result }));
  if (!result.success) throw Error('实际子窗口恢复阶段失败：' + stage);
}
try {
  if (manual || reopen) await run(reopen ? 'observe' : 'seed', true);
  else {
    await run('seed'); await run('reopen');
    const fixture = JSON.parse(await readFile(path.join(output, 'child-recovery-fixture.json'), 'utf8'));
    const page = path.join(output, 'profile/workspace-recovery', fixture.windowID, 'pages', fixture.firstTab + '.json'), original = await readFile(page);
    await writeFile(path.join(output, 'original-child-page.json'), original);
    const value = JSON.parse(original), state = JSON.parse(Buffer.from(value.state, 'base64')); state.videoWindow.version = 2;
    value.state = Buffer.from(JSON.stringify(state)).toString('base64'); const input = Buffer.from(JSON.stringify(value) + '\n');
    await writeFile(page, input); await writeFile(path.join(output, 'future-child-input.json'), input);
    await run('invalid'); if (!Buffer.from(await readFile(page)).equals(input)) throw Error('未来子窗口记录被改写');
    await run('retry'); await run('close'); await run('closed');
    const origin = JSON.parse(await readFile(path.join(output, 'media-origin.json'), 'utf8'));
    const sourcesExact = (await Promise.all(origin.files.filter(x => ['flower.mp4', 'flower.webm'].includes(x.name)).map(async x => { const file = path.join(output, 'workspace/media', x.name); return hash(await readFile(file)) === x.sha256 && ((await stat(file)).mode & 0o777) === 0o444; }))).every(Boolean);
    const checks = { sameApplication: results.every(x => x.sameApplication), allStagesPassed: results.length === 6 && results.every(x => x.success), originalVideosAndModesPreserved: sourcesExact, readmePreserved: await readFile(path.join(output, 'workspace/README.md'), 'utf8') === 'PUBLIC_CHILD_GUIDE_417\n', noWebWrites: requests.every(x => x.method === 'GET'), noModelRequests: results.every(x => x.modelRequests === 0) };
    await writeFile(path.join(output, 'independent.json'), JSON.stringify({ success: Object.values(checks).every(Boolean), checks }, null, 2) + '\n');
    if (!Object.values(checks).every(Boolean)) throw Error('子窗口恢复独立核对失败'); console.log(JSON.stringify({ output, success: true, checks }));
  }
} finally {
  server.close();
  await writeFile(path.join(output, `results-${Date.now()}.json`), JSON.stringify(results, null, 2) + '\n');
  await writeFile(path.join(output, `requests-${Date.now()}.json`), JSON.stringify(requests, null, 2) + '\n');
}

import { spawn, spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { createWriteStream } from 'node:fs';
import { chmod, mkdir, mkdtemp, readFile, realpath, rename, stat, writeFile } from 'node:fs/promises';
import { finished } from 'node:stream/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { verifyNativeCandidate } from './native-signing.mjs';

const root = fileURLToPath(new URL('../', import.meta.url)), app = process.env.BLUEFATFISH_APP;
const option = name => { const i = process.argv.indexOf(name); return i < 0 ? null : process.argv[i + 1]; };
const reopen = option('--reopen'), manual = process.argv.includes('--manual-ui'), media = option('--media-directory');
const allowed = new Set(['--reopen', '--manual-ui', '--media-directory']);
for (let i = 2; i < process.argv.length; i++) {
  const flag = process.argv[i]; if (!allowed.has(flag)) throw Error('不支持的来源恢复检查选项：' + flag);
  if (flag !== '--manual-ui') { if (!process.argv[++i] || process.argv[i].startsWith('--')) throw Error('缺少选项值：' + flag); }
}
if (!app || (!reopen && !media) || (manual && reopen)) throw Error('请指定独立验收应用及已核对的公开视频目录；本检查不调用模型。');
if (verifyNativeCandidate(app).kind !== 'isolated-local') throw Error('来源阅读恢复只使用独立本地验收包。');
const evidence = await realpath(path.join(root, 'evidence/agent'));
const output = reopen ? await realpath(reopen) : await mkdtemp(path.join(evidence, 'source-recovery-command-'));
if (!output.startsWith(evidence + path.sep)) throw Error('验收资料必须留在项目外置盘。');
for (const name of ['tmp', 'shared-home', 'workspace/media', 'workspace/sources']) await mkdir(path.join(output, name), { recursive: true, mode: 0o700 });
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const utf8 = value => Buffer.concat([Buffer.from([0xef, 0xbb, 0xbf]), Buffer.from(value)]);
const utf16 = value => Buffer.concat([Buffer.from([0xff, 0xfe]), Buffer.from(value, 'utf16le')]);
if (!reopen) {
  const origin = JSON.parse(await readFile(path.join(media, 'media-origin.json'), 'utf8'));
  const source = origin.files.find(f => f.name === 'flower.mp4'), bytes = await readFile(path.join(media, 'flower.mp4'));
  if (!source || hash(bytes) !== source.sha256) throw Error('公开视频来源摘要变化。');
  const target = path.join(output, 'workspace/media/flower.mp4'); await writeFile(target, bytes); await chmod(target, 0o444);
  const probeResult = spawnSync(process.env.FFPROBE_PATH ?? '/opt/homebrew/bin/ffprobe', ['-v', 'quiet', '-show_format', '-show_streams', '-of', 'json', target], { encoding: 'utf8' });
  if (probeResult.status !== 0) throw Error(probeResult.stderr || '独立解码探测失败');
  const probe = JSON.parse(probeResult.stdout);
  if (Math.abs(Number(probe.format.duration) - source.duration) > 0.01 || !probe.streams.some(s => s.codec_type === 'video' && s.width === 960 && s.height === 540)) throw Error('独立解码元数据不匹配。');
  const parentText = '# 来源链父文档\r\n\r\n[公开来源一](sources/source1.md#来源一)\r\n\r\nPUBLIC_PARENT_SOURCE_417\r\n';
  const source1Text = '# 来源一\r\n\r\n[继续阅读来源二](source2.md#章节二)\r\n\r\nPUBLIC_SOURCE_ONE_417 中文😀\r\n';
  const paragraphs = Array.from({ length: 180 }, (_, i) => `${i === 60 ? '## 章节二\r\n\r\n' : i === 120 ? '## 章节三\r\n\r\n' : ''}PUBLIC_SOURCE_${i} 中文😀，公开来源正文第 ${i} 段，保持完整内容和独立阅读位置。`);
  const source2Text = '# 来源二\r\n\r\n[公开视频](../media/flower.mp4)\r\n\r\n' + paragraphs.join('\r\n\r\n') + '\r\n';
  const changedText = '# 来源二外部修订\r\n\r\nPUBLIC_CHANGED_SOURCE_628 中文😀\r\n';
  const changed = utf16(changedText);
  const input = { parentDraft: parentText.replace('PUBLIC_PARENT_SOURCE_417', 'PUBLIC_PARENT_DRAFT_518 中文😀'), source1Text, source2Text, changedText, changedSourceHash: hash(changed), changedBodyHash: hash(Buffer.from(changedText)) };
  for (const name of ['parent-a.md', 'parent-b.md', 'parent-independent.md']) await writeFile(path.join(output, 'workspace', name), utf8(parentText), { mode: 0o600 });
  await writeFile(path.join(output, 'workspace/sources/source1.md'), utf8(source1Text), { mode: 0o600 });
  await writeFile(path.join(output, 'workspace/sources/source2.md'), utf16(source2Text), { mode: 0o600 });
  await writeFile(path.join(output, 'source-input.json'), JSON.stringify(input, null, 2) + '\n', { mode: 0o600 });
  await writeFile(path.join(output, 'changed-source.bin'), changed, { mode: 0o600 });
  await writeFile(path.join(output, 'media-origin.json'), JSON.stringify({ ...origin, files: [source] }, null, 2) + '\n');
  await writeFile(path.join(output, 'independent-media-probe.json'), JSON.stringify(probe, null, 2) + '\n');
}
const binary = path.join(app, 'Contents/MacOS/BlueFatFish'), binaryHash = hash(await readFile(binary)), results = [];
async function run(stage, ui = false) {
  const label = `${stage}-${Date.now()}`, args = ['--check', output, ui ? '--workspace-source-recovery-ui' : '--workspace-source-recovery-check', '--recovery-stage', stage];
  const child = spawn(binary, args, { env: { ...process.env, TMPDIR: path.join(output, 'tmp') + '/' }, stdio: ['ignore', 'pipe', 'pipe'] });
  const stdout = createWriteStream(path.join(output, label + '-stdout.log')), stderr = createWriteStream(path.join(output, label + '-stderr.log')); child.stdout.pipe(stdout); child.stderr.pipe(stderr);
  const identity = { app, appPID: child.pid, binaryHash, args, stage, label };
  await writeFile(path.join(output, label + '-process.json'), JSON.stringify(identity, null, 2) + '\n'); console.log(JSON.stringify({ output, ...identity }));
  const status = await new Promise((resolve, reject) => { child.once('error', reject); child.once('exit', (exit, signal) => resolve({ exit, signal })); });
  await Promise.all([finished(stdout), finished(stderr)]);
  const bytes = await readFile(path.join(output, ui ? 'source-recovery-ui-ready.json' : 'source-recovery-report.json')); await writeFile(path.join(output, label + '-report.json'), bytes);
  const report = JSON.parse(bytes), sameApplication = report.appPID === child.pid && report.binaryHash === binaryHash && hash(await readFile(binary)) === binaryHash;
  const result = { stage, label, ...status, sameApplication, success: status.exit === 0 && sameApplication && report.success === true && report.modelRequests === 0 && Object.keys(report.checks).length > 0 && Object.values(report.checks).every(Boolean), checks: Object.keys(report.checks).length, failed: Object.keys(report.checks).filter(k => !report.checks[k]), error: report.error, modelRequests: report.modelRequests };
  results.push(result); await writeFile(path.join(output, label + '-result.json'), JSON.stringify(result, null, 2) + '\n'); console.log(JSON.stringify({ output, ...result }));
  if (!result.success) throw Error('来源阅读恢复阶段失败：' + stage);
}
try {
  if (manual || reopen) await run(reopen ? 'observe' : 'seed', true);
  else {
    await run('seed');
    const fixture = JSON.parse(await readFile(path.join(output, 'source-recovery-fixture.json'), 'utf8'));
    const pages = path.join(output, 'profile/workspace-recovery', fixture.window, 'pages'), page = path.join(pages, fixture.floatTab + '.json');
    const original = await readFile(page); await writeFile(path.join(output, 'original-source-page.json'), original);
    const value = JSON.parse(original), state = JSON.parse(Buffer.from(value.state, 'base64')); state.sourceWindow.version = 2;
    value.state = Buffer.from(JSON.stringify(state)).toString('base64'); const future = Buffer.from(JSON.stringify(value) + '\n');
    await writeFile(page, future); await writeFile(path.join(output, 'future-source-input.json'), future);
    await run('invalid'); if (!Buffer.from(await readFile(page)).equals(future)) throw Error('未来格式来源记录被改写。');
    await run('retry');
    const held = path.join(output, 'original-source2.bin'); await rename(fixture.source2, held);
    await run('missing');
    await writeFile(fixture.source2, await readFile(path.join(output, 'changed-source.bin')), { mode: 0o600 });
    await run('changed'); await rename(held, fixture.source2); await run('reopen'); await run('closed');
    const savedParent = JSON.parse(Buffer.from(JSON.parse(await readFile(page, 'utf8')).state, 'base64'));
    const sourceFiles = Object.entries(fixture.hashes);
    const checks = {
      allSevenProcessesPassed: results.length === 7 && results.every(x => x.success),
      sameApplication: results.every(x => x.sameApplication),
      originalSourcesAndVideoBytesPreserved: (await Promise.all(sourceFiles.map(async ([file, expected]) => hash(await readFile(file)) === expected))).every(Boolean),
      originalSourceModesPreserved: (await Promise.all(sourceFiles.map(async ([file]) => ((await stat(file)).mode & 0o777) === (file === fixture.video ? 0o444 : 0o600)))).every(Boolean),
      parentDraftFullBodyPreserved: savedParent.text === fixture.parentDraft && savedParent.openedHash === fixture.hashes[fixture.parentFloat],
      explicitCloseClearedOnlyLinkedSourceChain: savedParent.sourceWindow === undefined,
      noModels: results.every(x => x.modelRequests === 0)
    };
    await writeFile(path.join(output, 'independent.json'), JSON.stringify({ success: Object.values(checks).every(Boolean), checks }, null, 2) + '\n');
    if (!Object.values(checks).every(Boolean)) throw Error('来源阅读恢复独立核对失败。'); console.log(JSON.stringify({ output, success: true, checks }));
  }
} finally { await writeFile(path.join(output, `results-${Date.now()}.json`), JSON.stringify(results, null, 2) + '\n'); }

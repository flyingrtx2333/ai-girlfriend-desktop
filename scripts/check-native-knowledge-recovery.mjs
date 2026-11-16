import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { createWriteStream } from 'node:fs';
import { chmod, mkdir, mkdtemp, readFile, realpath, writeFile } from 'node:fs/promises';
import { finished } from 'node:stream/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { verifyNativeCandidate } from './native-signing.mjs';

const root = fileURLToPath(new URL('../', import.meta.url)), app = process.env.BLUEFATFISH_APP;
const option = name => { const i = process.argv.indexOf(name); return i < 0 ? null : process.argv[i + 1]; };
const reopen = option('--reopen'), manual = process.argv.includes('--manual-ui'), media = option('--media-directory');
for (let i = 2; i < process.argv.length; i++) {
  const flag = process.argv[i];
  if (!['--reopen', '--manual-ui', '--media-directory'].includes(flag)) throw Error('不支持的知识来源恢复检查选项：' + flag);
  if (flag !== '--manual-ui' && (!process.argv[++i] || process.argv[i].startsWith('--'))) throw Error('缺少选项值：' + flag);
}
if (!app || (!reopen && !media) || (manual && reopen)) throw Error('请指定独立验收应用及已核对的公开视频目录；本检查不调用模型。');
if (verifyNativeCandidate(app).kind !== 'isolated-local') throw Error('知识来源恢复只使用独立本地验收包。');
const evidence = await realpath(path.join(root, 'evidence/agent'));
const output = reopen ? await realpath(reopen) : await mkdtemp(path.join(evidence, 'knowledge-recovery-command-'));
if (!output.startsWith(evidence + path.sep)) throw Error('验收资料必须留在项目外置盘。');
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
for (const name of ['tmp', 'shared-home', 'workspace/media', 'workspace/docs']) await mkdir(path.join(output, name), { recursive: true, mode: 0o700 });
if (!reopen) {
  const origin = JSON.parse(await readFile(path.join(media, 'media-origin.json'), 'utf8'));
  for (const name of ['flower.mp4', 'flower.webm']) {
    const file = origin.files.find(f => f.name === name), bytes = await readFile(path.join(media, name));
    if (!file || hash(bytes) !== file.sha256) throw Error('公开视频来源摘要变化：' + name);
    const target = path.join(output, 'workspace/media', name); await writeFile(target, bytes); await chmod(target, 0o444);
  }
  await writeFile(path.join(output, 'media-origin.json'), JSON.stringify(origin, null, 2) + '\n');
  await writeFile(path.join(output, 'workspace/README.md'), 'PUBLIC_KNOWLEDGE_RECOVERY_417\n');
  await writeFile(path.join(output, 'workspace/docs/VIDEO.md'), '# Wiki 来源一\r\n\r\n[继续阅读来源二](SOURCE.md)\r\n\r\nPUBLIC_KNOWLEDGE_GUIDE_417 中文😀\r\n');
  const text = '# Wiki 来源二\r\n\r\n[公开视频](../media/flower.mp4)\r\n\r\n' + Array.from({ length: 160 }, (_, i) => `PUBLIC_KNOWLEDGE_SOURCE_${i} 中文😀，公开的第 ${i} 段资料，保留原始内容及各自的阅读位置。`).join('\r\n\r\n') + '\r\n';
  await writeFile(path.join(output, 'workspace/docs/SOURCE.md'), Buffer.concat([Buffer.from([0xff, 0xfe]), Buffer.from(text, 'utf16le')]));
}
const binary = path.join(app, 'Contents/MacOS/BlueFatFish'), binaryHash = hash(await readFile(binary)), results = [];
async function run(stage, ui = false) {
  const label = `${stage}-${Date.now()}`, args = ['--check', output, ui ? '--knowledge-source-recovery-ui' : '--knowledge-source-recovery-check', '--recovery-stage', stage];
  const child = spawn(binary, args, { env: { ...process.env, TMPDIR: path.join(output, 'tmp') + '/' }, stdio: ['ignore', 'pipe', 'pipe'] });
  const stdout = createWriteStream(path.join(output, label + '-stdout.log')), stderr = createWriteStream(path.join(output, label + '-stderr.log')); child.stdout.pipe(stdout); child.stderr.pipe(stderr);
  const identity = { app, appPID: child.pid, binaryHash, args, stage, label };
  await writeFile(path.join(output, label + '-process.json'), JSON.stringify(identity, null, 2) + '\n'); console.log(JSON.stringify({ output, ...identity }));
  const status = await new Promise((resolve, reject) => { child.once('error', reject); child.once('exit', (exit, signal) => resolve({ exit, signal })); });
  await Promise.all([finished(stdout), finished(stderr)]);
  const bytes = await readFile(path.join(output, ui ? 'knowledge-source-recovery-ui-ready.json' : 'knowledge-source-recovery-report.json')); await writeFile(path.join(output, label + '-report.json'), bytes);
  const report = JSON.parse(bytes), sameApplication = report.appPID === child.pid && report.binaryHash === binaryHash && hash(await readFile(binary)) === binaryHash;
  const result = { stage, label, ...status, sameApplication, success: status.exit === 0 && sameApplication && report.success === true && report.modelRequests === 0 && Object.keys(report.checks).length > 0 && Object.values(report.checks).every(Boolean), checks: Object.keys(report.checks).length, failed: Object.keys(report.checks).filter(k => !report.checks[k]), error: report.error, modelRequests: report.modelRequests };
  results.push(result); await writeFile(path.join(output, label + '-result.json'), JSON.stringify(result, null, 2) + '\n'); console.log(JSON.stringify({ output, ...result }));
  if (!result.success) throw Error('知识来源恢复阶段失败：' + stage);
}
try {
  if (manual || reopen) await run(reopen ? 'observe' : 'seed', true);
  else {
    await run('seed');
    const fixture = JSON.parse(await readFile(path.join(output, 'knowledge-source-recovery-fixture.json'), 'utf8'));
    const layoutPath = path.join(output, 'profile/workspace-recovery', fixture.window, 'layout.json'), original = await readFile(layoutPath);
    await writeFile(path.join(output, 'original-knowledge-layout.json'), original);
    const layout = JSON.parse(original), reader = layout.knowledge.readers[0], state = JSON.parse(Buffer.from(reader.state, 'base64'));
    state.sourceWindow.version = 2; reader.state = Buffer.from(JSON.stringify(state)).toString('base64');
    const future = JSON.stringify(layout, null, 2) + '\n'; await writeFile(path.join(output, 'future-knowledge-layout.json'), future); await writeFile(layoutPath, future);
    await run('future');
    await writeFile(layoutPath, original);
    await run('resume'); await run('hidden'); await run('direct-seed'); await run('direct-resume'); await run('closed');
  }
} finally {
  await writeFile(path.join(output, 'knowledge-source-recovery-command-report.json'), JSON.stringify({ output, app, binaryHash, results, success: results.length === (manual || reopen ? 1 : 7) && results.every(r => r.success), modelRequests: 0 }, null, 2) + '\n');
}

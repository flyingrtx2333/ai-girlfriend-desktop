import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { createWriteStream } from 'node:fs';
import { mkdir, mkdtemp, readFile, realpath, rename, stat, writeFile } from 'node:fs/promises';
import { finished } from 'node:stream/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { verifyNativeCandidate } from './native-signing.mjs';

const root = fileURLToPath(new URL('../', import.meta.url)), app = process.env.BLUEFATFISH_APP;
const option = name => { const i = process.argv.indexOf(name); return i < 0 ? null : process.argv[i + 1]; };
const reopen = option('--reopen'), manual = process.argv.includes('--manual-ui');
for (let i = 2; i < process.argv.length; i++) {
  const flag = process.argv[i]; if (!['--reopen', '--manual-ui'].includes(flag)) throw Error('不支持的知识阅读恢复检查选项：' + flag);
  if (flag === '--reopen' && (!process.argv[++i] || process.argv[i].startsWith('--'))) throw Error('缺少重开目录');
}
if (!app || manual && reopen || verifyNativeCandidate(app).kind !== 'isolated-local') throw Error('知识阅读恢复只使用指定的独立本地验收包，不调用模型。');
const evidence = await realpath(path.join(root, 'evidence/agent'));
const output = reopen ? await realpath(reopen) : await mkdtemp(path.join(evidence, 'knowledge-reader-command-'));
if (!output.startsWith(evidence + path.sep)) throw Error('验收资料必须留在项目外置盘。');
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
for (const name of ['tmp', 'shared-home', 'project-a', 'project-b']) await mkdir(path.join(output, name), { recursive: true, mode: 0o700 });
if (!reopen) {
  const text = '# PUBLIC_READER_PROJECT_417\r\n\r\n' + Array.from({ length: 370 }, (_, i) => `PUBLIC_READER_LINE_${i} 中文😀，第 ${i} 行公开验收资料，两个项目内容相同但归属和位置各自保存。`).join('\r\n') + '\r\n';
  const source = Buffer.concat([Buffer.from([0xef, 0xbb, 0xbf]), Buffer.from(text)]), changed = Buffer.concat([Buffer.from([0xef, 0xbb, 0xbf]), Buffer.from(text.replace('PUBLIC_READER_LINE_359', 'PUBLIC_CHANGED_ROW_359'))]);
  for (const project of ['project-a', 'project-b']) await writeFile(path.join(output, project, 'README.md'), source, { mode: 0o444 });
  await writeFile(path.join(output, 'original-source.bin'), source, { mode: 0o600 }); await writeFile(path.join(output, 'changed-source.bin'), changed, { mode: 0o600 });
  const publishedBody = Array.from({ length: 38 }, (_, i) => `PUBLIC_CARD_LINE_${i} 中文😀，核对原始内容。`).join('\n\n');
  const draftBody = publishedBody + '\n\n' + Array.from({ length: 100 }, (_, i) => `PUBLIC_UNSAVED_LINE_${i} 中文😀，完整保留无效但尚未保存的编辑。`).join('\n');
  const input = { publishedBody, draftTitle: 'PUBLIC_UNSAVED_TITLE_518 中文😀', draftBody, changedHash: hash(changed), savedTitle: 'PUBLIC_SAVED_TITLE_729 中文😀', savedBody: publishedBody + '\n\nPUBLIC_CARD_SAVED_729 中文😀' };
  if (Buffer.byteLength(publishedBody) > 4000 || Buffer.byteLength(draftBody) <= 4000 || Buffer.byteLength(input.savedBody) > 4000) throw Error('公开卡片样例长度边界无效');
  await writeFile(path.join(output, 'reader-input.json'), JSON.stringify(input, null, 2) + '\n');
}
const binary = path.join(app, 'Contents/MacOS/BlueFatFish'), binaryHash = hash(await readFile(binary)), results = [];
async function run(stage, ui = false) {
  const label = `${stage}-${Date.now()}`, args = ['--check', output, ui ? '--knowledge-reader-recovery-ui' : '--knowledge-reader-recovery-check', '--recovery-stage', stage];
  const child = spawn(binary, args, { env: { ...process.env, TMPDIR: path.join(output, 'tmp') + '/' }, stdio: ['ignore', 'pipe', 'pipe'] });
  const stdout = createWriteStream(path.join(output, label + '-stdout.log')), stderr = createWriteStream(path.join(output, label + '-stderr.log')); child.stdout.pipe(stdout); child.stderr.pipe(stderr);
  const identity = { app, appPID: child.pid, binaryHash, args, stage, label };
  await writeFile(path.join(output, label + '-process.json'), JSON.stringify(identity, null, 2) + '\n'); console.log(JSON.stringify({ output, ...identity }));
  const status = await new Promise((resolve, reject) => { child.once('error', reject); child.once('exit', (exit, signal) => resolve({ exit, signal })); });
  await Promise.all([finished(stdout), finished(stderr)]);
  const bytes = await readFile(path.join(output, ui ? 'knowledge-reader-ui-ready.json' : 'knowledge-reader-report.json')); await writeFile(path.join(output, label + '-report.json'), bytes);
  const report = JSON.parse(bytes), sameApplication = report.appPID === child.pid && report.binaryHash === binaryHash && hash(await readFile(binary)) === binaryHash;
  const result = { stage, label, ...status, sameApplication, success: status.exit === 0 && sameApplication && report.success === true && report.modelRequests === 0 && Object.keys(report.checks).length > 0 && Object.values(report.checks).every(Boolean), checks: Object.keys(report.checks).length, failed: Object.keys(report.checks).filter(k => !report.checks[k]), error: report.error, modelRequests: report.modelRequests };
  results.push(result); await writeFile(path.join(output, label + '-result.json'), JSON.stringify(result, null, 2) + '\n'); console.log(JSON.stringify({ output, ...result }));
  if (!result.success) throw Error('知识阅读恢复阶段失败：' + stage);
}
try {
  if (manual || reopen) await run(reopen ? 'observe' : 'seed', true);
  else {
    await run('seed');
    const fixture = JSON.parse(await readFile(path.join(output, 'knowledge-reader-fixture.json'), 'utf8'));
    const layoutPath = path.join(output, 'profile/workspace-recovery', fixture.firstWindow, 'layout.json'), original = await readFile(layoutPath);
    await writeFile(path.join(output, 'original-card-layout.json'), original);
    const layout = JSON.parse(original), page = layout.knowledge.readers[0], state = JSON.parse(Buffer.from(page.state, 'base64'));
    state.source.version = 2; page.state = Buffer.from(JSON.stringify(state)).toString('base64');
    const future = JSON.stringify(layout, null, 2) + '\n'; await writeFile(path.join(output, 'future-card-layout.json'), future); await writeFile(layoutPath, future);
    await run('future'); await writeFile(layoutPath, original);
    const sourceA = path.join(output, 'project-a/README.md'), held = path.join(output, 'source-a-held.bin');
    if (fixture.fileA !== sourceA || hash(await readFile(sourceA)) !== fixture.sourceHash) throw Error('来源样例路径或摘要变化');
    await rename(sourceA, held); await run('missing'); await rename(held, sourceA);
    await run('retry');
    const pointer = await realpath(fixture.bookPointer), originalBook = await readFile(path.join(output, 'original-book.json')), external = JSON.parse(await readFile(path.join(output, 'external-book-proof.json'), 'utf8'));
    if (!pointer.startsWith(path.join(output, 'profile') + path.sep) || !/^[0-9a-f]{64}\.json$/.test(path.basename(pointer)) || hash(originalBook) !== fixture.bookHash || hash(await readFile(pointer)) !== external.hash) throw Error('原卡片版本或临时修复范围无效');
    await writeFile(path.join(output, 'external-book-pointer.json'), await readFile(pointer)); await writeFile(pointer, originalBook);
    await rename(sourceA, path.join(output, 'source-a-before-change.bin')); await writeFile(sourceA, await readFile(path.join(output, 'changed-source.bin')), { mode: 0o444 });
    await run('changed');
    await rename(sourceA, path.join(output, 'source-a-changed.bin')); await rename(path.join(output, 'source-a-before-change.bin'), sourceA);
    await run('original'); await run('closed');
    const preserved = await Promise.all(['project-a', 'project-b'].map(async name => ({ hash: hash(await readFile(path.join(output, name, 'README.md'))), mode: (await stat(path.join(output, name, 'README.md'))).mode & 0o777 })));
    const checks = { allSevenProcessesPassed: results.length === 7 && results.every(r => r.success), sameApplication: results.every(r => r.sameApplication), originalSourceBytesAndPermissionsExact: preserved.every(x => x.hash === fixture.sourceHash && x.mode === 0o444), originalBookAndFailedVersionsRetained: hash(originalBook) === fixture.bookHash && hash(await readFile(path.join(output, 'external-book-pointer.json'))) === external.hash, noModels: results.every(r => r.modelRequests === 0) };
    await writeFile(path.join(output, 'independent.json'), JSON.stringify({ success: Object.values(checks).every(Boolean), checks }, null, 2) + '\n');
  }
} finally {
  await writeFile(path.join(output, 'knowledge-reader-command-report.json'), JSON.stringify({ output, app, binaryHash, results, success: results.length === (manual || reopen ? 1 : 7) && results.every(r => r.success), modelRequests: 0 }, null, 2) + '\n');
}

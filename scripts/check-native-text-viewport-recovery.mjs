import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { createWriteStream } from 'node:fs';
import { mkdir, mkdtemp, readFile, realpath, stat, writeFile } from 'node:fs/promises';
import { finished } from 'node:stream/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { verifyNativeCandidate } from './native-signing.mjs';

const root = fileURLToPath(new URL('../', import.meta.url)), app = process.env.BLUEFATFISH_APP;
const args = process.argv.slice(2), manual = args.includes('--manual-ui'), reopen = args[0] === '--reopen' ? args[1] : null, diagram = args.includes('--diagram-preview');
if (!app || !(args.length === 0 || args.length === 1 && (manual || diagram) || args.length === 2 && reopen)) throw Error('请指定独立验收应用；可用 --diagram-preview、--manual-ui 或 --reopen <原目录>，本检查不调用模型。');
if (verifyNativeCandidate(app).kind !== 'isolated-local') throw Error('文本位置恢复只使用独立本地验收包。');
const evidence = await realpath(path.join(root, 'evidence/agent'));
const output = reopen ? await realpath(reopen) : await mkdtemp(path.join(evidence, diagram ? 'markdown-diagram-command-' : 'text-viewport-command-'));
if (!output.startsWith(evidence + path.sep)) throw Error('验收资料必须留在项目外置盘。');
for (const name of ['tmp', 'shared-home', 'workspace']) await mkdir(path.join(output, name), { recursive: true, mode: 0o700 });
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
if (diagram) {
  await writeFile(path.join(output, 'workspace/diagram.md'), await readFile(path.join(root, 'docs/AGENT-READING.md')), { mode: 0o600 });
} else if (!reopen) {
  const plainText = Array.from({ length: 260 }, (_, i) => i === 150 ? 'PUBLIC_PLAIN_CURSOR_518 中文😀' : `原文 ${i} PUBLIC_PLAIN_LINE_${i} 保留完整正文。`).join('\r\n') + '\r\n';
  const paragraphs = Array.from({ length: 180 }, (_, i) => i === 80 ? 'PUBLIC_BLOCK_ORIGINAL_517' : `公开段落 ${i} PUBLIC_PARAGRAPH_${i}，保留中文与表情😀。`);
  paragraphs.splice(120, 0, '| 第一列 | 第二列 |\r\n| --- | --- |\r\n| 原值 | PUBLIC_CELL_ORIGINAL_628 |');
  const guideText = '# 公开文本位置验收\r\n\r\n' + paragraphs.join('\r\n\r\n') + '\r\n';
  const blockValue = 'BLOCK_EDIT_BEFORE 中文😀\n' + Array.from({ length: 24 }, (_, i) => `BLOCK_INPUT_LINE_${i} 保留段落内容`).join('\n');
  const cellValue = 'CELL_EDIT_BEFORE 中文😀\n' + Array.from({ length: 16 }, (_, i) => `CELL_INPUT_LINE_${i}`).join('\n') + '\nCELL_END | 值';
  const blockSource = value => value.replaceAll('\n', '\r\n');
  const cellSource = value => value.replaceAll('|', '\\|').replaceAll('\n', '<br>');
  const input = { plainText, guideText, blockValue, cellValue,
    expectedBlock: guideText.replace('PUBLIC_BLOCK_ORIGINAL_517', blockSource(blockValue)),
    expectedCell: guideText.replace('PUBLIC_CELL_ORIGINAL_628', cellSource(cellValue)),
    continuedBlock: guideText.replace('PUBLIC_BLOCK_ORIGINAL_517', blockSource(blockValue.replace('中文😀', 'BLOCK_RESUMED_739'))),
    continuedCell: guideText.replace('PUBLIC_CELL_ORIGINAL_628', cellSource(cellValue.replace('中文😀', 'CELL_RESUMED_842'))),
    continuedReading: guideText.replace('PUBLIC_PARAGRAPH_50', 'RAW_RESUMED_953') };
  await writeFile(path.join(output, 'input.json'), JSON.stringify(input, null, 2) + '\n', { mode: 0o600 });
  await writeFile(path.join(output, 'workspace/plain.txt'), Buffer.concat([Buffer.from([0xff, 0xfe]), Buffer.from(plainText, 'utf16le')]), { mode: 0o600 });
  await writeFile(path.join(output, 'workspace/guide.md'), Buffer.concat([Buffer.from([0xef, 0xbb, 0xbf]), Buffer.from(guideText)]), { mode: 0o600 });
  await writeFile(path.join(output, 'workspace/reading.md'), Buffer.concat([Buffer.from([0xef, 0xbb, 0xbf]), Buffer.from(guideText)]), { mode: 0o600 });
}
const binary = path.join(app, 'Contents/MacOS/BlueFatFish'), binaryHash = hash(await readFile(binary)), results = [];
async function run(stage, ui = false) {
  const label = `${stage}-${Date.now()}`, parameters = ['--check', output, ui ? '--workspace-text-viewport-ui' : '--workspace-text-viewport-check', '--recovery-stage', stage];
  const child = spawn(binary, parameters, { env: { ...process.env, TMPDIR: path.join(output, 'tmp') + '/' }, stdio: ['ignore', 'pipe', 'pipe'] });
  const stdout = createWriteStream(path.join(output, label + '-stdout.log')), stderr = createWriteStream(path.join(output, label + '-stderr.log')); child.stdout.pipe(stdout); child.stderr.pipe(stderr);
  const identity = { app, appPID: child.pid, binaryHash, args: parameters, stage, label };
  await writeFile(path.join(output, label + '-process.json'), JSON.stringify(identity, null, 2) + '\n'); console.log(JSON.stringify({ output, ...identity }));
  const status = await new Promise((resolve, reject) => { child.once('error', reject); child.once('exit', (exit, signal) => resolve({ exit, signal })); });
  await Promise.all([finished(stdout), finished(stderr)]);
  const bytes = await readFile(path.join(output, ui ? 'text-viewport-ui-ready.json' : 'text-viewport-report.json')); await writeFile(path.join(output, label + '-report.json'), bytes);
  const report = JSON.parse(bytes), sameApplication = report.appPID === child.pid && report.binaryHash === binaryHash && hash(await readFile(binary)) === binaryHash;
  const result = { stage, label, ...status, sameApplication, success: status.exit === 0 && sameApplication && report.success === true && report.modelRequests === 0 && Object.keys(report.checks).length > 0 && Object.values(report.checks).every(Boolean), checks: Object.keys(report.checks).length, failed: Object.keys(report.checks).filter(k => !report.checks[k]), error: report.error, modelRequests: report.modelRequests };
  results.push(result); await writeFile(path.join(output, label + '-result.json'), JSON.stringify(result, null, 2) + '\n'); console.log(JSON.stringify({ output, ...result }));
  if (!result.success) throw Error('文本位置恢复阶段失败：' + stage);
}
try {
  if (diagram) {
    await run('diagram-seed');
    const fixture = JSON.parse(await readFile(path.join(output, 'diagram-fixture.json'), 'utf8'));
    const page = path.join(output, 'profile/workspace-recovery', fixture.window, 'pages', fixture.tab + '.json');
    const savedPreview = async () => JSON.parse(Buffer.from(JSON.parse(await readFile(page, 'utf8')).state, 'base64')).markdownViewport;
    const saved = await savedPreview();
    await run('diagram-reopen');
    const returned = await savedPreview();
    const checks = {
      sameApplication: results.length === 2 && results.every(result => result.sameApplication),
      activeDiagramAndZoomWereSaved: saved.diagram.index === 0 && saved.diagram.scale > 0 && Math.abs(saved.diagram.x - 0.36) < 0.02,
      returningClosesPreviewAndKeepsTheOriginalSelection: returned.diagram == null &&
        JSON.stringify(returned.viewport.selections) === JSON.stringify(saved.viewport.selections),
      originalMarkdownMatchesFixtureAndRepository: hash(await readFile(fixture.file)) === fixture.hash &&
        (await readFile(path.join(root, 'docs/AGENT-READING.md'))).equals(await readFile(fixture.file)),
      noModels: results.every(result => result.modelRequests === 0),
    };
    const success = Object.values(checks).every(Boolean);
    await writeFile(path.join(output, 'independent.json'), JSON.stringify({ success, checks }, null, 2) + '\n');
    if (!success) throw Error('图表恢复的独立核对未通过');
    console.log(JSON.stringify({ output, success, checks }));
  } else if (manual || reopen) await run(reopen ? 'observe' : 'seed', true);
  else {
    await run('seed');
    const fixture = JSON.parse(await readFile(path.join(output, 'text-viewport-fixture.json'), 'utf8'));
    const pages = path.join(output, 'profile/workspace-recovery', fixture.window, 'pages'), cellPath = path.join(pages, fixture.cellTab + '.json');
    const original = await readFile(cellPath); await writeFile(path.join(output, 'original-cell-page.json'), original);
    const value = JSON.parse(original), state = JSON.parse(Buffer.from(value.state, 'base64')); state.markdownViewport.version = 2;
    value.state = Buffer.from(JSON.stringify(state)).toString('base64'); const future = Buffer.from(JSON.stringify(value) + '\n');
    await writeFile(cellPath, future); await writeFile(path.join(output, 'future-view-input.json'), future);
    await run('invalid'); if (!Buffer.from(await readFile(cellPath)).equals(future)) throw Error('未来格式的原编辑记录被改写');
    await run('retry');
    const plain = path.join(output, 'workspace/plain.txt'), originalPlain = await readFile(plain), plainPage = path.join(pages, fixture.plainTab + '.json');
    await writeFile(path.join(output, 'original-plain-file.bin'), originalPlain); await writeFile(path.join(output, 'original-plain-page.json'), await readFile(plainPage));
    const changed = Buffer.concat([Buffer.from([0xff, 0xfe]), Buffer.from('EXTERNAL_CHANGED_PLAIN_627\r\n', 'utf16le')]); await writeFile(plain, changed);
    await run('source'); if (!Buffer.from(await readFile(plain)).equals(changed)) throw Error('变化后的原文件被改写');
    await writeFile(plain, originalPlain); await run('reopen');
    const input = JSON.parse(await readFile(path.join(output, 'input.json'), 'utf8'));
    const decoded = async tab => JSON.parse(Buffer.from(JSON.parse(await readFile(path.join(pages, tab + '.json'), 'utf8')).state, 'base64'));
    const block = await decoded(fixture.blockTab), cell = await decoded(fixture.cellTab), reading = await decoded(fixture.readingTab);
    const checks = { allFiveProcessesPassed: results.length === 5 && results.every(x => x.success), sameApplication: results.every(x => x.sameApplication),
      fullContinuedBlockExact: block.text === input.continuedBlock && block.markdownViewport.editor.value.includes('BLOCK_RESUMED_739'),
      fullContinuedCellExact: cell.text === input.continuedCell && cell.markdownViewport.editor.value.includes('CELL_RESUMED_842'),
      fullContinuedOriginalViewExact: reading.text === input.continuedReading,
      originalFilesAndModesExact: (await Promise.all(Object.entries(fixture.sourceHashes).map(async ([file, expected]) => hash(await readFile(file)) === expected && ((await stat(file)).mode & 0o777) === 0o600))).every(Boolean),
      noModels: results.every(x => x.modelRequests === 0) };
    await writeFile(path.join(output, 'independent.json'), JSON.stringify({ success: Object.values(checks).every(Boolean), checks }, null, 2) + '\n');
    if (!Object.values(checks).every(Boolean)) throw Error('文本位置独立全文核对失败'); console.log(JSON.stringify({ output, success: true, checks }));
  }
} finally { await writeFile(path.join(output, `results-${Date.now()}.json`), JSON.stringify(results, null, 2) + '\n'); }

import { spawn, spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { createWriteStream } from 'node:fs';
import { finished } from 'node:stream/promises';
import { mkdir, mkdtemp, readFile, writeFile, rename, stat } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const root = fileURLToPath(new URL('../', import.meta.url)), app = process.env.BLUEFATFISH_APP;
if (!app || process.argv.length !== 2) throw Error('请指定独立验收应用；画布恢复检查不调用模型。');
const info = spawnSync('/usr/bin/plutil', ['-convert', 'json', '-o', '-', path.join(app, 'Contents/Info.plist')], { encoding: 'utf8' });
if (info.status !== 0 || JSON.parse(info.stdout).BlueFatFishAcceptanceOnly !== true) throw Error('画布恢复检查只能使用独立验收应用。');
const output = await mkdtemp(path.join(root, 'evidence/agent/canvas-recovery-command-'));
for (const name of ['tmp', 'shared-home']) await mkdir(path.join(output, name));
const binary = path.join(app, 'Contents/MacOS/BlueFatFish');
const hash = bytes => createHash('sha256').update(bytes).digest('hex'), binaryHash = hash(await readFile(binary));
const json = async file => JSON.parse(await readFile(file, 'utf8'));
const results = [];
for (const stage of ['seed', 'reopen']) {
  const args = ['--check', output, '--workspace-canvas-recovery-check', '--recovery-stage', stage];
  const child = spawn(binary, args, { env: { ...process.env, TMPDIR: path.join(output, 'tmp') + '/' }, stdio: ['ignore', 'pipe', 'pipe'] });
  const stdout = createWriteStream(path.join(output, stage + '-stdout.log')), stderr = createWriteStream(path.join(output, stage + '-stderr.log'));
  child.stdout.pipe(stdout); child.stderr.pipe(stderr);
  await writeFile(path.join(output, stage + '-process.json'), JSON.stringify({ app, appPID: child.pid, binaryHash, args }, null, 2) + '\n');
  console.log(JSON.stringify({ output, stage, appPID: child.pid, binaryHash }));
  const status = await new Promise((resolve, reject) => { child.once('error', reject); child.once('exit', (exit, signal) => resolve({ exit, signal })); });
  await Promise.all([finished(stdout), finished(stderr)]);
  const bytes = await readFile(path.join(output, 'canvas-recovery-report.json'));
  await writeFile(path.join(output, stage + '-report.json'), bytes);
  const report = JSON.parse(bytes);
  const sameApplication = report.appPID === child.pid && report.binaryHash === binaryHash && hash(await readFile(binary)) === binaryHash;
  const success = status.exit === 0 && sameApplication && report.success === true && report.modelRequests === 0 && Object.keys(report.checks).length > 0 && Object.values(report.checks).every(Boolean);
  const result = { output, stage, ...status, sameApplication, success, checks: Object.keys(report.checks).length, failed: Object.keys(report.checks).filter(key => !report.checks[key]), error: report.error, modelRequests: report.modelRequests };
  results.push(result); console.log(JSON.stringify(result));
  await writeFile(path.join(output, stage + '-result.json'), JSON.stringify(result, null, 2) + '\n');
  if (!success) { process.exitCode = 1; break; }
  const fixture = await json(path.join(output, 'canvas-recovery-fixture.json')), independent = {};
  const annotationFile = path.join(output, 'saved-canvas-annotation.json');
  const initialAnnotation = stage === 'reopen' && fixture.annotationImageHash ? await json(annotationFile) : null;
  for (const key of ['a', 'b', 'c', 'd']) {
    const owner = key === 'c' ? fixture.second : fixture.first, task = await json(path.join(output, 'profile/agent', owner + '.json'));
    const record = task.canvases.find(value => value.id === fixture.ids[key]);
    const source = path.join(output, 'profile/agent', owner, 'canvases', fixture.ids[key], 'document.canvas.tsx');
    const expected = stage === 'reopen' && key === 'c' ? fixture.drafts[key] : fixture.originals[key];
    const actual = await readFile(stage === 'reopen' && key === 'd' ? path.join(output, 'moved-original.canvas.tsx') : source);
    independent[key + 'ExactSourceBytesAndRecordedHash'] = actual.equals(Buffer.from(expected)) && record.hash === hash(actual);
    independent[key + 'ExistingDraftAndBaseline'] = key === 'b' || stage === 'reopen' && key === 'c'
      ? record.draft == null && record.draftHash == null
      : record.draft === fixture.drafts[key] && record.draftHash === hash(Buffer.from(fixture.originals[key]));
    const pageFile = path.join(output, 'profile/workspace-recovery', fixture.windowID, 'pages', fixture.tabs[key] + '.json');
    const page = await json(pageFile), state = JSON.parse(Buffer.from(page.state, 'base64'));
    independent[key + 'PrivateWindowStateReferencesActualCanvas'] = page.kind === 'canvas' && page.taskID === owner && page.asset == null && state.canvasID === fixture.ids[key] && (await stat(pageFile)).mode % 0o1000 === 0o600;
    const annotationSuffix = owner === fixture.first && initialAnnotation
      ? '\n画布「' + initialAnnotation.draft.source.title + '」的批注（源码版本 ' + initialAnnotation.sourceHash.slice(0, 12) + '）：' + initialAnnotation.draft.note
      : '';
    independent[key + 'FullTaskComposerRetained'] = task.draft === '保留原任务输入 PUBLIC_CANVAS_INPUT_184' + annotationSuffix;
    if (key === 'b' && fixture.annotationImageHash) {
      if (stage === 'seed') {
        const annotation = state.annotation;
        independent.inlineAnnotationStoredWithOriginalImageAndVersion = page.dirty && annotation?.draft.source.tabID === record.id &&
          annotation.sourceHash === record.hash && hash(Buffer.from(annotation.draft.image, 'base64')) === fixture.annotationImageHash &&
          annotation.draft.marks.length === 1 && !task.draftAttachmentIDs?.length;
        if (annotation) await writeFile(annotationFile, JSON.stringify(annotation, null, 2) + '\n');
      } else {
        const attachment = task.attachments?.find(item => item.id === task.draftAttachmentIDs?.[0]);
        const png = attachment && await readFile(path.join(output, 'profile/agent', owner, 'attachments', attachment.id, 'source.png'));
        independent.resumedAnnotationExportedOnceWithOriginalCanvasVersion = !page.dirty && state.annotation == null &&
          task.draftAttachmentIDs?.length === 1 && attachment?.canvasCapture?.canvasID === record.id &&
          attachment.canvasCapture.sourceHash === initialAnnotation.sourceHash && attachment.canvasCapture.annotations === 1 &&
          png && hash(png) === attachment.sha256;
      }
    }
  }
  independent.projectFileUnchanged = await readFile(path.join(output, 'public-canvas-project/README.md'), 'utf8') === 'PUBLIC_CANVAS_SOURCE_SENTINEL_263\n';
  const proof = { success: Object.values(independent).every(Boolean), checks: independent };
  await writeFile(path.join(output, stage + '-independent.json'), JSON.stringify(proof, null, 2) + '\n');
  if (!proof.success) throw Error('画布恢复文件独立核对失败：' + Object.keys(independent).filter(key => !independent[key]).join(', '));
  if (stage === 'seed') {
    const source = path.join(output, 'profile/agent', fixture.first, 'canvases', fixture.ids.d, 'document.canvas.tsx');
    await rename(source, path.join(output, 'moved-original.canvas.tsx'));
    await writeFile(path.join(output, 'missing-source-fixture.json'), JSON.stringify({ source, movedSHA256: hash(await readFile(path.join(output, 'moved-original.canvas.tsx'))) }, null, 2) + '\n');
    // Earlier layouts stored the generic Canvas label. Preserve their exact
    // bytes, then exercise that existing format without materializing tabs.
    const layoutFile = path.join(output, 'profile/workspace-recovery', fixture.windowID, 'layout.json');
    const original = await readFile(layoutFile), legacy = JSON.parse(original);
    await writeFile(path.join(output, 'seed-original-layout.json'), original);
    for (const task of legacy.tasks) for (const tab of task.tabs) if (tab.root.startsWith('canvas:')) tab.title = '画布';
    await writeFile(layoutFile, JSON.stringify(legacy) + '\n');
    await writeFile(path.join(output, 'legacy-layout-fixture.json'), JSON.stringify({ version: legacy.version, originalSHA256: hash(original), legacySHA256: hash(await readFile(layoutFile)), retainedPageIDs: legacy.tasks.flatMap(task => task.tabs.map(tab => tab.id)) }, null, 2) + '\n');
  }
}
await writeFile(path.join(output, 'results.json'), JSON.stringify(results, null, 2) + '\n');

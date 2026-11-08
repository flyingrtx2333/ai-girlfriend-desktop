import { spawnSync } from 'node:child_process';
import { readFile, writeFile, readdir, mkdtemp, mkdir, cp } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { isDeepStrictEqual } from 'node:util';
import { fileURLToPath } from 'node:url';
import os from 'node:os';
import path from 'node:path';

const root = fileURLToPath(new URL('../', import.meta.url));
const encodings = process.argv.includes('--encodings'), conflicts = process.argv.includes('--conflicts'), editing = process.argv.includes('--editing') || conflicts || encodings;
const prefix = encodings ? 'text-encoding' : conflicts ? 'file-conflict' : editing ? 'markdown-edit' : 'markdown';
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
if (encodings) {
  const fixture = path.join(output, 'encoding-fixtures'); await mkdir(fixture);
  const guide = (await readFile(path.join(source, 'docs/AGENT-READING.md'), 'utf8')).replace(/\r\n/g, '\n').replace(/\n/g, '\r\n');
  const body = guide + '\r\n[GB18030 来源](../sources/legacy-guide.md)\r\n', paragraph = guide.split('\r\n').find(line => line.startsWith('任务记录的 Markdown'));
  const gbAfter = '任务记录的 Markdown 文档已按 GB18030 重新打开；中文正文保存后继续保留原编码。';
  const unicodeAfter = '任务记录的 Markdown 文档以 UTF-16 保留标记和换行，正文已修改😀。';
  const ascii = guide.split('\r\n').filter(line => /^[\x00-\x7f]*$/.test(line)).join('\r\n');
  const convert = (text, encoding, marker = []) => {
    const value = spawnSync('/usr/bin/iconv', ['-f', 'UTF-8', '-t', encoding], { input: Buffer.from(text), maxBuffer: 16_000_000 });
    if (value.status !== 0) throw new Error('Independent iconv conversion failed: ' + encoding);
    return Buffer.concat([Buffer.from(marker), value.stdout]);
  };
  const choices = [['utf-8', 'UTF-8', [239,187,191]], ['utf-16le','UTF-16LE',[255,254]], ['utf-16be','UTF-16BE',[254,255]], ['utf-32le','UTF-32LE',[255,254,0,0]], ['utf-32be','UTF-32BE',[0,0,254,255]], ['gb18030','GB18030',[]], ['big5','BIG5',[]], ['shift-jis','SHIFT_JIS',[]], ['windows-1252','WINDOWS-1252',[]], ['iso-8859-1','ISO-8859-1',[]]];
  const vectors = [];
  for (const [encoding, iconv, marker] of choices) for (const bom of marker.length ? [false, true] : [false]) {
    const text = ['big5','shift-jis'].includes(encoding) ? ascii + '\r\n中文文件\r\n' : encoding === 'windows-1252' ? ascii + '\r\nCafé €\r\n' : encoding === 'iso-8859-1' ? ascii + '\r\nCafé\r\n' : '\u0301\uFEFF' + body;
    const name = encoding + (bom ? '-bom' : '') + '.bin', bytes = convert(text, iconv, bom ? marker : []); await writeFile(path.join(fixture, name), bytes);
    vectors.push({ name, encoding, bom, text, sha256: hash(bytes) });
  }
  const big5Text = ascii + '\r\n中文文件\r\n';
  const workflow = { paragraphBefore: paragraph, gbParagraphAfter: gbAfter, unicodeParagraphAfter: unicodeAfter, big5Before: '中文文件', big5After: '中文文件已保存', files: {} };
  for (const [name, text, encoding, marker] of [['gb-before',body,'GB18030',[]], ['gb-after',body.replace(paragraph,gbAfter),'GB18030',[]], ['gb-external',body+'\r\n<!-- 外部编码文件更新 -->\r\n','GB18030',[]], ['big5-before',big5Text,'BIG5',[]], ['big5-after',big5Text.replace('中文文件','中文文件已保存'),'BIG5',[]], ['unicode-before',body,'UTF-16LE',[255,254]], ['unicode-after',body.replace(paragraph,unicodeAfter),'UTF-16LE',[255,254]], ['reference',body,'GB18030',[]]]) {
    const bytes = convert(text, encoding, marker); await writeFile(path.join(fixture, name+'.bin'), bytes); workflow.files[name] = { name: name+'.bin', sha256: hash(bytes), text };
  }
  await writeFile(path.join(output, 'encoding-fixtures.json'), JSON.stringify({ converter: '/usr/bin/iconv', sourceHash: sourceHashes['docs/AGENT-READING.md'], vectors, workflow }, null, 2));
}
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
  if (editing && !conflicts && !encodings) {
    const plan = JSON.parse(await readFile(path.join(output, 'markdown-edit-plan.json'), 'utf8'));
    report.independent.externalVersionPreserved = hash(await readFile(plan.file)) === plan.externalHash;
    report.independent.unsavedDraftRetained = hash(await readFile(path.join(output, 'retained-unsaved-draft.md'))) === plan.draftHash;
  }
  if (conflicts) {
    const plan = JSON.parse(await readFile(path.join(output, 'file-conflict-plan.json'), 'utf8'));
    report.independent.adoptedDiskBytesPreserved = hash(await readFile(plan.file)) === plan.finalDiskHash;
    const current = JSON.parse(await readFile(path.join(output, 'native-conflict-readback.json'), 'utf8'));
    report.independent.adoptedEditorMatchesDisk = current.draftHash === plan.finalDiskHash && current.openedHash === plan.finalDiskHash && current.dirty === false;
  }
  if (encodings) {
    const plan = JSON.parse(await readFile(path.join(output, 'text-encoding-plan.json'), 'utf8'));
    report.independent.encodedFilesMatchIndependentExpectations = (await Promise.all(plan.files.map(async value => hash(await readFile(value.path)) === value.expectedHash))).every(Boolean);
    const current = JSON.parse(await readFile(path.join(output, 'native-encoding-readback.json'), 'utf8'));
    report.independent.editorBytesMatchSavedUnicodeFile = hash(Buffer.from(current.encodedDraftBase64, 'base64')) === plan.unicodeAfterHash && current.openedHash === plan.unicodeAfterHash && current.dirty === false;
  }
  report.success &&= report.modelsCalled === false && Object.values(report.independent).every(Boolean);
} catch (error) { report = { ...(report ?? {}), success: false, error: error.message }; }
await writeFile(path.join(output, prefix + '-driver-report.json'), JSON.stringify(report, null, 2));
const archive = path.join(root, 'evidence/agent', path.basename(output)); await mkdir(path.dirname(archive), { recursive: true }); await cp(output, archive, { recursive: true });
console.log(JSON.stringify({ success: report.success, output, archive, error: report.error }));
if (!report.success) process.exitCode = 1;

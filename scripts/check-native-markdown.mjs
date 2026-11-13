import { spawnSync } from 'node:child_process';
import { readFile, writeFile, readdir, mkdtemp, mkdir, cp } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { isDeepStrictEqual } from 'node:util';
import { fileURLToPath } from 'node:url';
import os from 'node:os';
import path from 'node:path';
import { verifyNativeCandidate } from './native-signing.mjs';

const root = fileURLToPath(new URL('../', import.meta.url));
const tree = process.argv.includes('--wiki-tree'), tables = process.argv.includes('--tables'), encodings = process.argv.includes('--encodings'), conflicts = process.argv.includes('--conflicts'), editing = process.argv.includes('--editing') || conflicts || encodings || tables || tree;
const prefix = tree ? 'wiki-tree' : tables ? 'markdown-table' : encodings ? 'text-encoding' : conflicts ? 'file-conflict' : editing ? 'markdown-edit' : 'markdown';
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
if (tree) {
  const workspace = path.join(output,'workspace'), wiki = '.bluefatfish/wiki/', imported = {};
  async function document(origin, relative, converted) {
    const data = await readFile(path.join(root,origin)); sourceHashes[origin] = hash(data);
    await mkdir(path.dirname(path.join(source,origin)),{recursive:true}); await writeFile(path.join(source,origin),data);
    const bytes = converted ?? data; await mkdir(path.dirname(path.join(workspace,relative)),{recursive:true}); await writeFile(path.join(workspace,relative),bytes); imported[relative] = {origin,sha256:hash(bytes)};
  }
  for (const name of ['README.md','docs/DEVELOPMENT.md','docs/AGENT-READING.md','docs/ROADMAP.md']) await document(name,wiki+'项目/'+name);
  await cp(path.join(source,'docs/media'),path.join(workspace,wiki+'项目/docs/media'),{recursive:true});
  const text=(await readFile(path.join(source,'docs/AGENT-READING.md'),'utf8')).replace(/\r\n/g,'\n').replace(/\n/g,'\r\n');
  const convert = value => {const result=spawnSync('/usr/bin/iconv',['-f','UTF-8','-t','UTF-16LE'],{input:Buffer.from(value),maxBuffer:16_000_000});if(result.status!==0)throw Error('Independent UTF-16 conversion failed');return Buffer.concat([Buffer.from([255,254]),result.stdout]);};
  await document('docs/AGENT-READING.md',wiki+'项目/docs/AGENT-READING.md',convert(text));
  await document('docs/AGENT-READING.md',wiki+'项目/编码 说明😀.markdown',convert(text));
  await document('docs/DEVELOPMENT.md',wiki+'目录.md/开发说明.MARKDOWN');
  const packages=(await readdir(path.join(root,'node_modules'),{withFileTypes:true})).filter(e=>e.isDirectory()&&!e.name.startsWith('.')&&!e.name.startsWith('@')).map(e=>e.name).sort();let count=0;
  for(const name of packages){const file='node_modules/'+name+'/README.md';let data;try{data=await readFile(path.join(root,file));}catch(error){if(error.code==='ENOENT')continue;throw error;}if(data.length>64000)continue;await document(file,wiki+'依赖/'+name+'/README.md');if(++count===44)break;}
  if(count!==44)throw Error('Need actual installed dependency documentation to verify the old 40-page limit');
  const index='# 项目文档\n\n[预览编辑](项目/docs/AGENT-READING.md#预览编辑)\n\n[开发与版本管理](项目/docs/DEVELOPMENT.md#目录)\n\n此目录为实际项目文档和已安装依赖说明的人工导航，不是本轮模型生成结果。\n';
  await mkdir(path.join(workspace,wiki),{recursive:true});await writeFile(path.join(workspace,wiki+'index.md'),index);imported[wiki+'index.md']={origin:'manual acceptance navigation',sha256:hash(Buffer.from(index))};
  const paragraph=text.split('\r\n').find(l=>l.startsWith('任务记录的 Markdown')), replacement='任务记录的 Markdown 文档已从 Wiki 文档树定位；这份实际修改应在刷新目录与切换保护中保留。';
  const saved=convert(text.replace(paragraph,replacement));await writeFile(path.join(output,'wiki-tree-expected-saved.bin'),saved);
  await writeFile(path.join(output,'wiki-tree-plan.json'),JSON.stringify({workspace,imported,initialPages:Object.keys(imported).sort(),target:wiki+'项目/docs/AGENT-READING.md',paragraphBefore:paragraph,paragraphAfter:replacement,savedHash:hash(saved),added:wiki+'新增/ROADMAP.md',removed:wiki+'依赖/any-promise/README.md',description:'Actual repository Markdown and 44 installed dependency READMEs; manual navigation is explicitly labeled; not a generation or model-quality check'},null,2));
  await writeFile(path.join(output,prefix+'-source-origin.json'),JSON.stringify({repository:root,source,files:sourceHashes},null,2));
}
if (tables) {
  const fixtures = path.join(output, 'table-fixtures'); await mkdir(fixtures);
  const guide = (await readFile(path.join(source, 'docs/AGENT-READING.md'), 'utf8')).replace(/\r\n/g, '\n').replace(/\n/g, '\r\n');
  const block = rows => rows.join('\r\n');
  const rows = ['| 对象 | 修改范围 | 文件 |','| --- | --- | --- |','| 正文或代码块 | 当前块的 Markdown | 保存后写入 |','| 表格单元格 | 当前单元格 | 保存后写入 |','| 只读来源 | 不可编辑 | 保持不变 |'];
  if (guide.split(block(rows)).length !== 2) throw new Error('Update the actual project table targets');
  const states = { initial: guide, insertedRow: guide.replace(block(rows),block([...rows.slice(0,2),'|  |  |  |',...rows.slice(2)])) };
  const four = ['| 对象 |  | 修改范围 | 文件 |','| --- | --- | --- | --- |','|  |  |  |  |','| 正文或代码块 |  | 当前块的 Markdown | 保存后写入 |','| 表格单元格 |  | 当前单元格 | 保存后写入 |','| 只读来源 |  | 不可编辑 | 保持不变 |'];
  states.insertedColumn = guide.replace(block(rows),block(four));
  const filled = four.map((row,index) => index === 2 ? '|  | 新增 \\| 中文😀<br>第二行 |  |  |' : row);
  states.filledCell = guide.replace(block(rows),block(filled));
  for (const [name,marker] of [['alignLeft',':---'],['alignCenter',':---:'],['alignRight','---:']]) states[name] = guide.replace(block(rows),block(filled.map((row,index) => index === 1 ? '| --- | '+marker+' | --- | --- |' : row)));
  states.external = states.alignCenter + '\r\n<!-- 外部实际写入：表格结构编辑验收 -->\r\n'; states.unsaved = states.alignRight;
  const hashes = {};
  for (const [name,text] of Object.entries(states)) {
    const converted = spawnSync('/usr/bin/iconv',['-f','UTF-8','-t','UTF-16LE'],{input:Buffer.from(text),maxBuffer:16_000_000});
    if (converted.status !== 0) throw new Error('Independent UTF-16 conversion failed');
    const bytes = Buffer.concat([Buffer.from([255,254]),converted.stdout]); hashes[name] = hash(bytes); await writeFile(path.join(fixtures,name+'.bin'),bytes);
  }
  await writeFile(path.join(output,'markdown-table-plan.json'),JSON.stringify({sourceHash:sourceHashes['docs/AGENT-READING.md'],encoding:'UTF-16LE',bom:true,lineEndings:'CRLF',states,hashes,cellValue:'新增 | 中文😀\n第二行'},null,2));
  const lead = '\uFEFF# 前😀\r\n\r\n', tail = '\r\n\r\n尾部👩🏽‍💻\r\n';
  const base = '| A\\|B | `C|D` |\r\n| :---- | -----: |\r\n| **中文** | 值 |';
  const v = (name,source,row,column,action,expected) => ({name,source,row,column,action,...(expected === null ? {reject:true} : {expected})});
  const vectors = [
    v('columnInsertPreservesEscapedCodePipesBOMAndOutsideBytes',lead+base+tail,1,1,3,lead+'| A\\|B |  | `C|D` |\r\n| :---- | --- | -----: |\r\n| **中文** |  | 值 |'+tail),
    v('columnDeletePreservesRemainingRawMarkup',lead+base+tail,1,0,5,lead+'| `C|D` |\r\n| -----: |\r\n| 值 |'+tail),
    v('alignmentChangesOnlySelectedDelimiter',lead+base+tail,1,1,7,lead+base.replace('-----: ',':-----: ')+tail),
    v('headerRowInsertionStaysBelowSeparator',lead+base+tail,0,0,1,lead+base.replace('| **中文**','|  |  |\r\n| **中文**')+tail),
    v('rowDeleteKeepsHeaderSeparatorAndOutsideText',lead+base+tail,1,0,2,lead+'| A\\|B | `C|D` |\r\n| :---- | -----: |'+tail),
    v('rowInsertAtEOFDoesNotAddFinalNewline','A|B\n---|---\nx|y',1,0,1,'A|B\n---|---\nx|y\n|  |  |'),
    v('bareEdgeColumnInsertRemainsRenderable','A|B\n---|---\nx|y\n',1,0,3,'|  |A|B\n --- |---|---\n|  |x|y\n'),
    v('shortAndExtraRowsKeepCellPositions','| A | B |\n| --- | --- |\n| x |\n| a | b | extra |\n',1,1,4,'| A | B |  |\n| --- | --- | --- |\n| x |  |  |\n| a | b |  | extra |\n'),
    v('headerDeletionRejected',base,0,0,2,null), v('insertAboveHeaderRejected',base,0,0,0,null),
    v('lastColumnDeletionRejected','| A |\n| --- |\n| B |\n',1,0,5,null),
    v('invalidCellSelectionRejected',base,8,0,1,null)
  ];
  await writeFile(path.join(output,'table-vectors.json'),JSON.stringify(vectors,null,2));
}
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
  const signing = verifyNativeCandidate(app);
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
  report.signing = signing;
  const records = [];
  for (const name of await readdir(path.join(output, 'profile/agent'))) if (/^[0-9a-f-]{36}\.json$/i.test(name)) records.push(JSON.parse(await readFile(path.join(output, 'profile/agent', name), 'utf8')));
  const originalTask = records.find(record => record.id === ready.taskID), otherTask = records.find(record => record.id === ready.otherTaskID);
  report.actualTaskReadback = { tasks: records.length, modelRequests: records.reduce((sum, record) => sum + (record.modelReceipts?.length ?? 0), 0), messages: records.reduce((sum, record) => sum + record.messages.length, 0), queued: records.reduce((sum, record) => sum + (record.queuedMessages?.length ?? 0) + (record.queuedInputs?.length ?? 0), 0) };
  const originalDocuments = await Promise.all(Object.entries(sourceHashes).map(async ([name, digest]) => hash(await readFile(path.join(root, name))) === digest));
  report.independent = { dailyProfileUnchanged: isDeepStrictEqual(before, await snapshot()), binaryMatches: report.binaryHash === binaryHash, candidateSignatureVerified: true, originalRepositoryDocumentsUnchanged: originalDocuments.every(Boolean), actualTaskFilesHaveNoModelRequestsOrMessages: records.length >= 3 && report.actualTaskReadback.modelRequests === 0 && report.actualTaskReadback.messages === 0 && report.actualTaskReadback.queued === 0, bothTaskDraftsPersisted: (editing ? originalTask?.draft === '保留的A草稿' : originalTask?.draft?.startsWith('保留的A草稿\n\n[文件选文：docs/AGENT-READING.md]') === true) && otherTask?.draft === '保留的B草稿' };
  if (editing && !conflicts && !encodings && !tables && !tree) {
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
  if (tables) {
    const plan = JSON.parse(await readFile(path.join(output,'markdown-table-plan.json'),'utf8'));
    const final = JSON.parse(await readFile(path.join(output,'native-table-final.json'),'utf8'));
    report.independent.conflictingExternalUTF16BytesPreserved = hash(await readFile(ready.file)) === plan.hashes.external;
    report.independent.unsavedTableBytesMatchIndependentIconv = hash(Buffer.from(final.encodedDraftBase64,'base64')) === plan.hashes.unsaved && final.openedHash === plan.hashes.alignCenter && final.dirty === true;
    const saved = JSON.parse(await readFile(path.join(output,'native-table-saved.json'),'utf8'));
    report.independent.actualSavedTableMatchesIndependentBytes = saved.draftHash === plan.hashes.alignCenter && saved.openedHash === plan.hashes.alignCenter && saved.dirty === false;
  }
  if (tree) {
    const plan=JSON.parse(await readFile(path.join(output,'wiki-tree-plan.json'),'utf8')), final=JSON.parse(await readFile(path.join(output,'native-wiki-tree-final.json'),'utf8'));
    report.independent.actualSavedWikiBytesMatchIndependentIconv=hash(await readFile(path.join(plan.workspace,plan.target)))===plan.savedHash;
    report.independent.actualDirectoryRefreshAddsAndRemovesDocuments=final.tree.pages.some(p=>p.path===plan.added)&&!final.tree.pages.some(p=>p.path===plan.removed);
    report.independent.otherImportedDocumentsUnchanged=(await Promise.all(Object.entries(plan.imported).filter(([name])=>![plan.target,plan.removed].includes(name)).map(async([name,value])=>hash(await readFile(path.join(plan.workspace,name)))===value.sha256))).every(Boolean);
  }
  report.success &&= report.modelsCalled === false && Object.values(report.independent).every(Boolean);
} catch (error) { report = { ...(report ?? {}), success: false, error: error.message }; }
await writeFile(path.join(output, prefix + '-driver-report.json'), JSON.stringify(report, null, 2));
const archive = path.join(root, 'evidence/agent', path.basename(output)); await mkdir(path.dirname(archive), { recursive: true }); await cp(output, archive, { recursive: true });
console.log(JSON.stringify({ success: report.success, output, archive, error: report.error }));
if (!report.success) process.exitCode = 1;

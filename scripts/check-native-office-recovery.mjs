import { spawn, spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { createWriteStream } from 'node:fs';
import { finished } from 'node:stream/promises';
import { mkdir, mkdtemp, readFile, writeFile, copyFile, rename } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const root = fileURLToPath(new URL('../', import.meta.url));
const app = process.env.BLUEFATFISH_APP, python = process.env.BLUEFATFISH_OFFICE_PYTHON;
if (!app || !python || process.argv.length !== 2) throw Error('请指定独立验收应用及已安装 Office 验收依赖的 Python；不调用模型。');
const command = (file, args) => {
  const run = spawnSync(file, args, { encoding: 'utf8' });
  if (run.status !== 0) throw Error(run.stderr || run.stdout || file);
  return run.stdout;
};
const info = JSON.parse(command('/usr/bin/plutil', ['-convert', 'json', '-o', '-', path.join(app, 'Contents/Info.plist')]));
if (info.BlueFatFishAcceptanceOnly !== true) throw Error('办公恢复检查只能使用独立验收应用。');
const output = await mkdtemp(path.join(root, 'evidence/agent/office-recovery-command-'));
for (const name of ['tmp', 'shared-home', 'originals']) await mkdir(path.join(output, name));
command(python, [path.join(root, 'scripts/fixtures/office-documents.py'), path.join(output, 'originals')]);
const binary = path.join(app, 'Contents/MacOS/BlueFatFish');
const hash = bytes => createHash('sha256').update(bytes).digest('hex'), binaryHash = hash(await readFile(binary));
const results = [];
for (const stage of ['seed', 'reopen']) {
  const args = ['--check', output, '--workspace-office-recovery-check', '--recovery-stage', stage];
  const child = spawn(binary, args, { env: { ...process.env, TMPDIR: path.join(output, 'tmp') + '/' }, stdio: ['ignore', 'pipe', 'pipe'] });
  const stdout = createWriteStream(path.join(output, stage + '-stdout.log')), stderr = createWriteStream(path.join(output, stage + '-stderr.log'));
  child.stdout.pipe(stdout); child.stderr.pipe(stderr);
  await writeFile(path.join(output, stage + '-process.json'), JSON.stringify({ app, appPID: child.pid, binaryHash, args }, null, 2) + '\n');
  console.log(JSON.stringify({ output, stage, appPID: child.pid, binaryHash }));
  // The actual child remains authoritative if observation is interrupted.
  const status = await new Promise((resolve, reject) => { child.once('error', reject); child.once('exit', (exit, signal) => resolve({ exit, signal })); });
  await Promise.all([finished(stdout), finished(stderr)]);
  const bytes = await readFile(path.join(output, 'office-recovery-report.json'));
  await writeFile(path.join(output, stage + '-report.json'), bytes);
  const report = JSON.parse(bytes);
  const sameApplication = report.appPID === child.pid && report.binaryHash === binaryHash && hash(await readFile(binary)) === binaryHash;
  const success = status.exit === 0 && sameApplication && report.success === true && report.modelRequests === 0 && Object.keys(report.checks).length > 0 && Object.values(report.checks).every(Boolean);
  const result = { output, stage, ...status, sameApplication, success, checks: Object.keys(report.checks).length, failed: Object.keys(report.checks).filter(key => !report.checks[key]), error: report.error, modelRequests: report.modelRequests };
  results.push(result); console.log(JSON.stringify(result));
  await writeFile(path.join(output, stage + '-result.json'), JSON.stringify(result, null, 2) + '\n');
  if (!success) { process.exitCode = 1; break; }
  const independent = JSON.parse(command(python, [path.join(root, 'scripts/fixtures/verify-office-documents.py'), path.join(output, 'originals'), path.join(output, 'recovered-exports'), '审阅人：恢复草稿二']));
  await writeFile(path.join(output, stage + '-independent.json'), JSON.stringify(independent, null, 2) + '\n');
  if (!independent.success) throw Error('完整 Office 文件独立读取失败');
  if (stage === 'seed') {
    const fixture = JSON.parse(await readFile(path.join(output, 'office-recovery-fixture.json'), 'utf8'));
    const legacyPath = path.join(output, 'profile/workspace-recovery', fixture.windowID, 'pages', fixture.tabs.missing + '.json');
    const beforeLegacy = await readFile(legacyPath), legacy = JSON.parse(beforeLegacy), state = JSON.parse(Buffer.from(legacy.state, 'base64'));
    if (typeof state.view !== 'string' || JSON.parse(state.view).format !== 'docx') throw Error('Missing real Office view before legacy migration check');
    await writeFile(path.join(output, 'legacy-office-before.json'), beforeLegacy);
    delete state.view;
    legacy.state = Buffer.from(JSON.stringify(state)).toString('base64');
    await writeFile(legacyPath, JSON.stringify(legacy) + '\n');
    await writeFile(path.join(output, 'legacy-office-input.json'), await readFile(legacyPath));
    command(python, ['-c', 'from docx import Document; import sys; d=Document(sys.argv[1]); next(p for p in d.paragraphs if p.text=="审阅人：待填写").text="审阅人：外部编辑"; d.save(sys.argv[2])', path.join(output, 'originals/sample.docx'), fixture.paths.docx]);
    await rename(fixture.paths.missing, path.join(path.dirname(fixture.paths.missing), 'moved-original.docx'));
    await writeFile(path.join(output, 'external-source-changes.json'), JSON.stringify({ changedWord: hash(await readFile(fixture.paths.docx)), readOnlySpreadsheet: hash(await readFile(fixture.paths.xlsx)), movedOriginal: hash(await readFile(path.join(path.dirname(fixture.paths.missing), 'moved-original.docx'))) }, null, 2) + '\n');
  } else {
    const fixture = JSON.parse(await readFile(path.join(output, 'office-recovery-fixture.json'), 'utf8')), saved = path.join(output, 'saved-source-readback');
    await mkdir(saved);
    for (const format of ['docx', 'xlsx', 'pptx']) await copyFile(format === 'pptx' ? fixture.paths.pptx : path.join(output, 'recovered-exports/sample.' + format), path.join(saved, 'sample.' + format));
    const actualSaved = JSON.parse(command(python, [path.join(root, 'scripts/fixtures/verify-office-documents.py'), path.join(output, 'originals'), saved, '审阅人：恢复草稿二']));
    await writeFile(path.join(output, 'actual-saved-independent.json'), JSON.stringify(actualSaved, null, 2) + '\n');
  }
}
await writeFile(path.join(output, 'results.json'), JSON.stringify(results, null, 2) + '\n');

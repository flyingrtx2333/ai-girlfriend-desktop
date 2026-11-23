import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdir, mkdtemp, readFile, readdir, stat, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { verifyNativeCandidate } from './native-signing.mjs';

const app = process.env.BLUEFATFISH_APP;
if (!app || process.argv.length !== 2 || verifyNativeCandidate(app).kind !== 'isolated-local') {
  throw Error('请指定独立本地签名的画布打包验收应用。');
}
const base = fileURLToPath(new URL('../evidence/agent/', import.meta.url));
await mkdir(base, { recursive: true });
const output = await mkdtemp(path.join(base, 'canvas-skill-form-command-'));
for (const name of ['tmp', 'shared-home']) await mkdir(path.join(output, name), { mode: 0o700 });
const binary = path.join(app, 'Contents/MacOS/BlueFatFish');
const hash = contents => createHash('sha256').update(contents).digest('hex');
const bytes = file => readFile(path.join(output, file));
const json = async file => JSON.parse(await bytes(file));
const binaryHash = hash(await readFile(binary));
const results = [];
console.log(JSON.stringify({ output, binaryHash }));
for (const stage of ['seed', 'reopen', 'completed']) {
  const args = ['--check', output, '--workspace-canvas-recovery-check', '--canvas-skill-form', '--recovery-stage', stage];
  const run = spawnSync(binary, args, { encoding: 'utf8', timeout: 90000, env: { ...process.env, TMPDIR: path.join(output, 'tmp') + '/' } });
  await writeFile(path.join(output, stage + '-stdout.log'), run.stdout ?? '');
  await writeFile(path.join(output, stage + '-stderr.log'), run.stderr ?? '');
  await writeFile(path.join(output, stage + '-process.json'), JSON.stringify({ app, args, appPID: run.pid, exit: run.status, binaryHash }) + '\n');
  if (run.error || run.status !== 0) throw run.error ?? Error(run.stderr || '画布打包验收未退出');
  const report = await json('skill-form-report.json');
  const sameApplication = report.appPID === run.pid && report.binaryHash === binaryHash && hash(await readFile(binary)) === binaryHash;
  const failed = Object.entries(report.checks).filter(([, passed]) => !passed).map(([name]) => name);
  const result = { output, stage, appPID: run.pid, binaryHash, sameApplication, success: sameApplication && report.success && report.modelRequests === 0 && !failed.length,
    checks: Object.keys(report.checks).length, failed, modelRequests: report.modelRequests, error: report.error };
  results.push(result);
  console.log(JSON.stringify(result));
  await writeFile(path.join(output, stage + '-report.json'), JSON.stringify(report, null, 2) + '\n');
  if (!result.success) { process.exitCode = 1; break; }

  const fixture = await json('skill-form-fixture.json');
  const owner = await json(`profile/agent/${fixture.taskID}.json`), other = await json(`profile/agent/${fixture.other}.json`);
  const record = owner.canvases.find(value => value.id === fixture.id);
  const source = await bytes(`profile/agent/${fixture.taskID}/canvases/${fixture.id}/document.canvas.tsx`);
  const pagePath = `profile/workspace-recovery/${fixture.windowID}/pages/${fixture.tabID}.json`;
  const page = await json(pagePath), state = JSON.parse(Buffer.from(page.state, 'base64'));
  const packagePath = 'packages/public-canvas-skill';
  const sentinel = await bytes('packages/already-there/sentinel.txt');
  const checks = {
    originalTaskComposersAndUsage: owner.draft === '原工作台输入' && other.draft === '另一任务输入' &&
      [owner, other].every(task => !task.modelReceipts?.length && !task.inputTokens && !task.outputTokens),
    expectedCanvasRevision: source.equals(Buffer.from(stage === 'seed' ? fixture.original : fixture.changed)) && record.hash === hash(source),
    samePrivatePage: page.kind === 'canvas' && page.taskID === owner.id && state.canvasID === record.id && (await stat(path.join(output, pagePath))).mode % 0o1000 === 0o600,
    existingFolderIsByteExact: sentinel.equals(Buffer.from('保留已存在目录\n')),
  };
  if (stage === 'seed') {
    const draft = state.skill, position = draft?.editorPositions.formatting.selections[0];
    checks.exactOriginalDraftAndSelection = page.dirty && draft?.sourceHash === record.hash && draft.canvasID === record.id && draft.taskID === owner.id &&
      draft.specification.formatting === fixture.input && draft.specification.name === '../invalid' && draft.focus === 'formatting' && draft.scrollY > 0 &&
      position && fixture.input.slice(position.location, position.location + position.length) === fixture.phrase;
    checks.noEarlyExport = (await readdir(path.join(output, 'packages'))).join(',') === 'already-there';
  } else {
    const document = (await bytes(packagePath + '/SKILL.md')).toString('utf8');
    checks.packageUsesTheExplicitlyReviewedVersion = document.includes('模板源码版本：' + record.hash) &&
      document.includes(fixture.input.replace(fixture.phrase, '已接着编辑 ✅')) &&
      (await bytes(packagePath + '/references/template.canvas.tsx')).equals(source);
    checks.finishedDraftClearedAndNoDuplicateOutput = !page.dirty && !state.skill &&
      (await readdir(path.join(output, 'packages'))).sort().join(',') === 'already-there,public-canvas-skill' &&
      (await readdir(path.join(output, packagePath))).sort().join(',') === 'SKILL.md,references';
  }
  const success = Object.values(checks).every(value => value === true);
  await writeFile(path.join(output, stage + '-independent.json'), JSON.stringify({ success, checks }, null, 2) + '\n');
  console.log(JSON.stringify({ output, stage, independent: checks, success }));
  if (!success) { process.exitCode = 1; break; }
}
await writeFile(path.join(output, 'results.json'), JSON.stringify(results, null, 2) + '\n');

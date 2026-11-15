import { spawn, spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { createWriteStream } from 'node:fs';
import { finished } from 'node:stream/promises';
import { mkdir, mkdtemp, readFile, writeFile, stat, readdir } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { verifyNativeCandidate } from './native-signing.mjs';

const root = fileURLToPath(new URL('../', import.meta.url)), app = process.env.BLUEFATFISH_APP;
if (!app || process.argv.length !== 2) throw Error('请明确指定 BLUEFATFISH_APP 独立验收应用；编辑恢复检查不调用模型。');
verifyNativeCandidate(app);
const metadata = spawnSync('/usr/bin/plutil', ['-convert', 'json', '-o', '-', path.join(app, 'Contents/Info.plist')], { encoding: 'utf8' });
if (metadata.status !== 0 || JSON.parse(metadata.stdout).BlueFatFishAcceptanceOnly !== true) throw Error('编辑恢复检查只能使用独立验收应用。');
const output = await mkdtemp(path.join(root, 'evidence/agent/edit-recovery-command-'));
for (const name of ['tmp', 'shared-home']) await mkdir(path.join(output, name));
const hash = value => createHash('sha256').update(value).digest('hex');
const json = async name => JSON.parse(await readFile(path.join(output, name), 'utf8'));
const binary = path.join(app, 'Contents/MacOS/BlueFatFish'), binaryHash = hash(await readFile(binary)), results = [];
let originalGeneral, baselineTasks, baselineFiles;
const taskFile = id => path.join(output, 'profile/agent', id + '.json');
const projectFiles = async project => Object.fromEntries(await Promise.all(['a.txt', 'b space.txt', 'created.txt'].map(async name => {
  try { return [name, hash(await readFile(path.join(project, name)))]; } catch (error) { if (error.code === 'ENOENT') return [name, null]; throw error; }
})));
for (const stage of ['seed', 'unavailable', 'reopen', 'after-send']) {
  if (stage === 'unavailable') {
    const fixture = await json('edit-recovery-fixture.json');
    originalGeneral = await readFile(taskFile(fixture.generalTask));
    await writeFile(path.join(output, 'seed-original-general.json'), originalGeneral);
    const changed = JSON.parse(originalGeneral), message = changed.messages.find(value => value.id === fixture.generalMessage);
    if (!message) throw Error('独立验收缺少原始问题。');
    message.attachmentIDs = ['00000000-0000-4000-8000-000000000965'];
    await writeFile(taskFile(fixture.generalTask), JSON.stringify(changed) + '\n');
    await writeFile(path.join(output, 'unavailable-source-change.json'), JSON.stringify({ taskID: fixture.generalTask, messageID: fixture.generalMessage, onlyAttachmentIDsChanged: true, originalContentUnchanged: message.content === JSON.parse(originalGeneral).messages.find(value => value.id === fixture.generalMessage).content, originalSHA256: hash(originalGeneral), changedSHA256: hash(await readFile(taskFile(fixture.generalTask))) }, null, 2) + '\n');
  } else if (stage === 'reopen') {
    const fixture = await json('edit-recovery-fixture.json');
    await writeFile(taskFile(fixture.generalTask), originalGeneral);
  }
  const args = ['--check', output, '--workspace-edit-recovery-check', '--recovery-stage', stage];
  const child = spawn(binary, args, { cwd: root, env: { ...process.env, TMPDIR: path.join(output, 'tmp') + '/' }, stdio: ['ignore', 'pipe', 'pipe'] });
  const stdout = createWriteStream(path.join(output, stage + '-stdout.log')), stderr = createWriteStream(path.join(output, stage + '-stderr.log'));
  child.stdout.pipe(stdout); child.stderr.pipe(stderr);
  await writeFile(path.join(output, stage + '-process.json'), JSON.stringify({ app, appPID: child.pid, binaryHash, args }, null, 2) + '\n');
  console.log(JSON.stringify({ output, stage, appPID: child.pid, binaryHash }));
  const status = await new Promise((resolve, reject) => { child.once('error', reject); child.once('exit', (exit, signal) => resolve({ exit, signal })); });
  await Promise.all([finished(stdout), finished(stderr)]);
  await writeFile(path.join(output, stage + '-process-exit.json'), JSON.stringify(status, null, 2) + '\n');
  const report = await json('edit-recovery-report.json');
  await writeFile(path.join(output, stage + '-report.json'), JSON.stringify(report, null, 2) + '\n');
  if (status.exit !== 0 || status.signal != null || !report.success) {
    const result = { output, stage, ...status, success: false, checks: Object.keys(report.checks ?? {}).length, failed: Object.keys(report.checks ?? {}).filter(name => !report.checks[name]), error: report.error, modelRequests: report.modelRequests };
    results.push(result); await writeFile(path.join(output, stage + '-result.json'), JSON.stringify(result, null, 2) + '\n');
    console.log(JSON.stringify(result)); process.exitCode = 1; break;
  }
  const fixture = await json('edit-recovery-fixture.json'), projectTask = JSON.parse(await readFile(taskFile(fixture.projectTask))), generalTask = JSON.parse(await readFile(taskFile(fixture.generalTask)));
  if (stage === 'seed') {
    baselineTasks = { project: projectTask, general: generalTask };
    baselineFiles = await projectFiles(fixture.project);
    await writeFile(path.join(output, 'seed-original-tasks.json'), JSON.stringify(baselineTasks, null, 2) + '\n');
    await writeFile(path.join(output, 'seed-project-files.json'), JSON.stringify(baselineFiles, null, 2) + '\n');
  }
  const checks = {}, equal = (left, right) => JSON.stringify(left) === JSON.stringify(right);
  checks.sameApplication = binaryHash === hash(await readFile(binary)) && report.binaryHash === binaryHash && report.appPID === child.pid;
  checks.zeroModelRequests = report.modelRequests === 0;
  checks.originalProjectHistoryAndComposerExact = equal(projectTask.messages, baselineTasks.project.messages) && projectTask.draft === baselineTasks.project.draft;
  checks.originalGeneralComposerExact = generalTask.draft === baselineTasks.general.draft;
  if (stage === 'seed' || stage === 'unavailable') {
    const expectedGeneral = structuredClone(baselineTasks.general);
    if (stage === 'unavailable') expectedGeneral.messages.find(value => value.id === fixture.generalMessage).attachmentIDs = ['00000000-0000-4000-8000-000000000965'];
    checks.onlyDeclaredTaskSourceChange = equal(generalTask, expectedGeneral) && equal(projectTask, baselineTasks.project);
    checks.actualProjectFilesUnchanged = equal(await projectFiles(fixture.project), baselineFiles);
    for (const key of ['a', 'b', 'c', 'd']) {
      const window = key === 'd' ? fixture.childWindow : fixture.mainWindow;
      const owner = key === 'c' ? fixture.generalTask : fixture.projectTask;
      const message = key === 'c' ? fixture.generalMessage : key === 'b' ? fixture.secondMessage : fixture.firstMessage;
      const file = path.join(output, 'profile/workspace-recovery', window, 'pages', fixture.tabs[key] + '.json');
      const page = JSON.parse(await readFile(file)), state = JSON.parse(Buffer.from(page.state, 'base64'));
      checks[key + 'ExactPrivateDraftOwnerAndOriginal'] = page.taskID === owner && page.kind === 'edit-resend' && page.dirty && state.taskID === owner && state.messageID === message && state.text === fixture.texts[key] && /^[0-9a-f]{64}$/.test(state.originalHash) && !page.asset && ((await stat(file)).mode & 0o777) === 0o600;
      const layout = JSON.parse(await readFile(path.join(output, 'profile/workspace-recovery', window, 'layout.json')));
      checks[key + 'LayoutReferencesExactMessageAndTab'] = layout.tasks.find(value => value.taskID === owner)?.tabs.some(value => value.id === fixture.tabs[key] && value.root === 'edit-resend:' + message) === true;
    }
  } else {
    checks.originalGeneralHistoryExact = equal(generalTask.messages, baselineTasks.general.messages);
    checks.originalsArchived = projectTask.archived === true && generalTask.archived === true;
    const continuations = await json('edit-recovery-applied.json');
    for (const key of ['project', 'general']) {
      const next = JSON.parse(await readFile(taskFile(continuations[key]))), before = baselineTasks[key];
      checks[key + 'ActualReplacementHasExactEditedInputAndOwner'] = next.parentID === before.id && next.draft === before.draft && next.messages.at(-1)?.content === fixture.texts[key === 'project' ? 'b' : 'c'] && next.mode === before.mode && next.permission === before.permission;
    }
    checks.actualEarlierProjectFileBytesRestored = (await readFile(path.join(fixture.project, 'a.txt'), 'utf8')) === 'alpha-one\n' && (await readFile(path.join(fixture.project, 'b space.txt'), 'utf8')) === 'beta-one\n' && (await projectFiles(fixture.project))['created.txt'] === null;
    for (const window of [fixture.mainWindow, fixture.childWindow]) {
      const layout = JSON.parse(await readFile(path.join(output, 'profile/workspace-recovery', window, 'layout.json')));
      checks[window + 'ClosedEditorsAreNotReferenced'] = layout.tasks.every(value => value.tabs.every(tab => !tab.root.startsWith('edit-resend:')));
    }
  }
  const names = (await readdir(path.join(output, 'profile/agent'))).filter(name => name.endsWith('.json') && name !== 'index.json');
  const records = await Promise.all(names.map(name => json('profile/agent/' + name)));
  checks.noReceiptsTokensOrAssistantMessages = records.every(value => !(value.modelReceipts ?? []).length && !value.inputTokens && !value.outputTokens && !value.messages.some(message => message.role === 'assistant'));
  await writeFile(path.join(output, stage + '-independent.json'), JSON.stringify({ success: Object.values(checks).every(Boolean), checks }, null, 2) + '\n');
  const success = status.exit === 0 && status.signal == null && report.success && Object.values(report.checks).every(Boolean) && Object.values(checks).every(Boolean);
  const result = { output, stage, ...status, sameApplication: checks.sameApplication, success, checks: Object.keys(report.checks).length, failed: Object.keys(report.checks).filter(name => !report.checks[name]), independentFailed: Object.keys(checks).filter(name => !checks[name]), modelRequests: report.modelRequests, error: report.error };
  results.push(result); await writeFile(path.join(output, stage + '-result.json'), JSON.stringify(result, null, 2) + '\n');
  console.log(JSON.stringify(result));
  if (!success) { process.exitCode = 1; break; }
}
await writeFile(path.join(output, 'results.json'), JSON.stringify(results, null, 2) + '\n');

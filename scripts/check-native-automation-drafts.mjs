import { spawnSync } from 'node:child_process';
import { cp, mkdir, mkdtemp, readFile, stat, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import os from 'node:os';
import path from 'node:path';

const root = fileURLToPath(new URL('../', import.meta.url)), args = process.argv.slice(2);
const option = name => args.includes(name) ? args[args.indexOf(name) + 1] : undefined;
const hash = data => createHash('sha256').update(data).digest('hex');
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
const hold = args.includes('--hold-ui');
if (args.includes('--live-agent')) throw new Error('This check does not authorize model transmission.');
const output = option('--directory') ? path.resolve(option('--directory')) : await mkdtemp(path.join(os.tmpdir(), 'bluefatfish-automation-drafts-'));
const read = async name => JSON.parse(await readFile(path.join(output, name), 'utf8'));
async function maybe(name) { try { return await read(name); } catch (error) { if (error.code !== 'ENOENT') throw error; return undefined; } }
let inputs;
if (option('--directory')) {
  inputs = await read('automation-draft-inputs.json');
  if (inputs.directory !== output || inputs.scope !== 'automation-drafts') throw new Error('The prepared directory does not match.');
} else {
  await mkdir(path.join(output, 'workspace')); await mkdir(path.join(output, 'shared-home'));
  await cp(path.join(root, 'README.md'), path.join(output, 'workspace/README.md'));
  inputs = { scope: 'automation-drafts', directory: output, publicSource: hash(await readFile(path.join(output, 'workspace/README.md'))) };
  await writeFile(path.join(output, 'automation-draft-inputs.json'), JSON.stringify(inputs, null, 2));
}
if (args.includes('--prepare-only')) { console.log(JSON.stringify({ output, prepared: true, modelTransmissionAuthorized: false })); process.exit(0); }
const app = option('--app');
if (!app || path.extname(app) !== '.app' || !path.isAbsolute(app)) throw new Error('Pass an explicit signed candidate with --app.');
const binary = path.join(app, 'Contents/MacOS/BlueFatFish');
await stat(binary);
const signature = spawnSync('/usr/bin/codesign', ['--verify', '--deep', '--strict', app], { encoding: 'utf8' });
if (signature.status !== 0) throw new Error(signature.stderr || 'Candidate signature is invalid.');
const binaryHash = hash(await readFile(binary));
if (await maybe('automation-draft-started.json') || await maybe('automation-draft-result.json')) throw new Error('The original directory has already started and cannot be replayed.');
if (hash(await readFile(path.join(output, 'workspace/README.md'))) !== inputs.publicSource) throw new Error('The public input changed.');
console.log(JSON.stringify({ output, app, binaryHash, hold, modelTransmissionAuthorized: false }));
const launchArgs = ['--check', output, '--automation-draft-check', ...(hold ? ['--hold-automation-draft-ui'] : ['--background-component-check'])];
const launched = spawnSync('/usr/bin/open', ['-n', app, '--args', ...launchArgs], { encoding: 'utf8' });
if (launched.status !== 0) throw new Error(launched.stderr || 'Candidate did not launch.');
let command, pid, ready, result;
const deadline = Date.now() + (hold ? 7_350_000 : 120_000);
while (Date.now() < deadline) {
  const started = await maybe('automation-draft-started.json');
  if (started && !command) {
    pid = started.appPID;
    const process = spawnSync('/bin/ps', ['-ww', '-p', String(pid), '-o', 'command='], { encoding: 'utf8' });
    if (process.status === 0 && process.stdout.trim().startsWith(`${binary} --check ${output} --automation-draft-check`)) {
      command = process.stdout.trim();
      await writeFile(path.join(output, 'actual-process-command.json'), JSON.stringify({ appPID: pid, command, binaryHash }, null, 2));
    }
  }
  if (hold && !ready) {
    ready = await maybe('automation-draft-ui-ready.json');
    if (ready) {
      if (!command || ready.appPID !== pid || ready.binaryHash !== binaryHash || !Object.values(ready.checks).every(Boolean)) throw new Error('The actual UI process or native checks did not match.');
      console.log(JSON.stringify({ uiReady: true, output, appPID: pid, taskID: ready.taskID, draftID: ready.draftID, nativeChecks: Object.keys(ready.checks).length }));
    }
  }
  result = await maybe('automation-draft-result.json');
  if (result) break;
  await pause(command ? 250 : 50);
}
if (!result) throw new Error(`The original check has not produced a terminal report. Inspect its process; do not replay ${output}`);
const alive = () => spawnSync('/bin/ps', ['-p', String(result.appPID), '-o', 'stat='], { encoding: 'utf8' }).stdout.trim() !== '';
const exitDeadline = Date.now() + 10_000;
while (alive() && Date.now() < exitDeadline) await pause(100);
const taskIDs = (await read('profile/agent/index.json')).tasks.map(task => task.id);
const tasks = await Promise.all(taskIDs.map(id => read(`profile/agent/${id}.json`)));
const definitions = (await read('profile/automations/definitions.json')).automations;
const sourceTask = tasks.find(task => task.id === result.taskID), draft = sourceTask?.automationDrafts?.find(draft => draft.id === result.draftID);
let expectedNext;
if (draft && Number.isFinite(result.previewReference)) {
  const schedule = draft.automation.schedule;
  const formatter = new Intl.DateTimeFormat('en-US', { timeZone: schedule.timeZone, weekday: 'short', hour: '2-digit', minute: '2-digit', hourCycle: 'h23' });
  for (let time = (Math.floor(result.previewReference / 60) + 1) * 60, end = time + 8 * 86400; time <= end; time += 60) {
    const fields = Object.fromEntries(formatter.formatToParts(new Date(time * 1000)).map(part => [part.type, part.value]));
    if (schedule.weekdays.includes(['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'].indexOf(fields.weekday) + 1) && Number(fields.hour) === schedule.hour && Number(fields.minute) === schedule.minute) { expectedNext = time; break; }
  }
}
const independent = {
  actualSignedProcessCommandMatched: !!command && result.appPID === pid && result.binaryHash === binaryHash,
  actualApplicationExited: !alive(),
  actualPublicSourceUnchanged: hash(await readFile(path.join(output, 'workspace/README.md'))) === inputs.publicSource && result.sourceHash === inputs.publicSource,
  taskProposalMatchesActualToolReceiptAndOwner: !!draft && draft.taskID === sourceTask.id && draft.automation.name === result.draftReceipt?.name && draft.automation.workspace === sourceTask.workspace && draft.savedAt === undefined,
  proposalRemainsSeparateFromSavedDefinitions: !!draft && !definitions.some(value => value.id === draft.automation.id),
  preservedOriginalDefinitionWithGeneralWorkMode: definitions.some(value => value.id === result.originalAutomationID && value.name === '保留的本机计划' && value.workMode === 'general' && !value.enabled && value.prompt === '只读核对公开 README，不修改文件。'),
  actualPreviewMatchesIndependentTimeZoneAndWeekdayCalculation: expectedNext !== undefined && result.previewNext === expectedNext,
  noModelReceiptAssistantReplyOrActiveJob: result.blockedModelAttempts === 0 && !result.activeJobs && tasks.every(task => !task.modelReceipts?.length && !task.messages.some(message => message.role === 'assistant')),
};
const report = { appPID: result.appPID, binaryHash, nativeSuccess: result.success, nativeChecks: result.checks, independent, actualModelTransmissions: 0, success: result.success && Object.values(independent).every(Boolean) };
await writeFile(path.join(output, 'automation-draft-driver-report.json'), JSON.stringify(report, null, 2));
console.log(JSON.stringify({ output, success: report.success, nativeChecks: Object.keys(result.checks).length, independent }));
if (!report.success) process.exitCode = 1;

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
const output = option('--directory') ? path.resolve(option('--directory')) : await mkdtemp(path.join(os.tmpdir(), 'bluefatfish-agent-drafts-'));
const read = async name => JSON.parse(await readFile(path.join(output, name), 'utf8'));
async function maybe(name) { try { return await read(name); } catch (error) { if (error.code !== 'ENOENT') throw error; return undefined; } }
let inputs;
if (option('--directory')) {
  inputs = await read('agent-draft-inputs.json');
  if (inputs.directory !== output || inputs.scope !== 'agent-drafts') throw new Error('The prepared directory does not match.');
} else {
  await mkdir(path.join(output, 'workspace')); await mkdir(path.join(output, 'shared-home'));
  await cp(path.join(root, 'README.md'), path.join(output, 'workspace/README.md'));
  inputs = { scope: 'agent-drafts', directory: output, publicSource: hash(await readFile(path.join(output, 'workspace/README.md'))) };
  await writeFile(path.join(output, 'agent-draft-inputs.json'), JSON.stringify(inputs, null, 2));
}
if (args.includes('--prepare-only')) { console.log(JSON.stringify({ output, prepared: true, modelTransmissionAuthorized: false })); process.exit(0); }
const app = option('--app');
if (!app || path.extname(app) !== '.app' || !path.isAbsolute(app)) throw new Error('Pass an explicit signed candidate with --app.');
const binary = path.join(app, 'Contents/MacOS/BlueFatFish');
await stat(binary);
const signature = spawnSync('/usr/bin/codesign', ['--verify', '--deep', '--strict', app], { encoding: 'utf8' });
if (signature.status !== 0) throw new Error(signature.stderr || 'Candidate signature is invalid.');
const binaryHash = hash(await readFile(binary));
if (await maybe('agent-draft-started.json') || await maybe('agent-draft-result.json')) throw new Error('The original directory has already started and cannot be replayed.');
if (hash(await readFile(path.join(output, 'workspace/README.md'))) !== inputs.publicSource) throw new Error('The public input changed.');
console.log(JSON.stringify({ output, app, binaryHash, hold, modelTransmissionAuthorized: false }));
const launchArgs = ['--check', output, '--agent-draft-check', ...(hold ? ['--hold-draft-ui'] : ['--background-component-check'])];
const launched = spawnSync('/usr/bin/open', ['-n', app, '--args', ...launchArgs], { encoding: 'utf8' });
if (launched.status !== 0) throw new Error(launched.stderr || 'Candidate did not launch.');
let command, pid, ready, result;
const deadline = Date.now() + (hold ? 7_350_000 : 120_000);
while (Date.now() < deadline) {
  const started = await maybe('agent-draft-started.json');
  if (started && !command) {
    pid = started.appPID;
    const process = spawnSync('/bin/ps', ['-ww', '-p', String(pid), '-o', 'command='], { encoding: 'utf8' });
    if (process.status === 0 && process.stdout.trim().startsWith(`${binary} --check ${output} --agent-draft-check`)) {
      command = process.stdout.trim();
      await writeFile(path.join(output, 'actual-process-command.json'), JSON.stringify({ appPID: pid, command, binaryHash }, null, 2));
    }
  }
  if (hold && !ready) {
    ready = await maybe('agent-draft-ui-ready.json');
    if (ready) {
      if (!command || ready.appPID !== pid || ready.binaryHash !== binaryHash || !Object.values(ready.checks).every(Boolean)) throw new Error('The actual UI process or native checks did not match.');
      console.log(JSON.stringify({ uiReady: true, output, appPID: pid, taskID: ready.taskID, draftID: ready.draftID, nativeChecks: Object.keys(ready.checks).length }));
    }
  }
  result = await maybe('agent-draft-result.json');
  if (result) break;
  await pause(command ? 250 : 50);
}
if (!result) throw new Error(`The original check has not produced a terminal report. Inspect its process; do not replay ${output}`);
let alive = () => spawnSync('/bin/ps', ['-p', String(result.appPID), '-o', 'stat='], { encoding: 'utf8' }).stdout.trim() !== '';
const exitDeadline = Date.now() + 10_000;
while (alive() && Date.now() < exitDeadline) await pause(100);
const source = await readFile(path.join(output, 'workspace/README.md'));
const taskNames = (await read('profile/agent/index.json')).tasks.map(task => task.id);
const tasks = await Promise.all(taskNames.map(id => read(`profile/agent/${id}.json`)));
const profiles = (await read('profile/extensions/agents.json')).agents;
const independent = {
  actualSignedProcessCommandMatched: !!command && result.appPID === pid && result.binaryHash === binaryHash,
  actualApplicationExited: !alive(),
  actualPublicSourceUnchanged: hash(source) === inputs.publicSource && result.sourceHash === inputs.publicSource,
  actualDraftReceiptMatchesTask: tasks.some(task => task.id === result.taskID && task.agentDrafts?.some(draft => draft.id === result.draftID && draft.profile.name === result.draftReceipt.name && draft.profile.instructions === result.draftReceipt.instructions)),
  preservedOriginalProfile: profiles.some(profile => profile.name === '保留的本机角色' && !profile.enabled && profile.instructions === '读取实际文件，不修改。'),
  noModelReceiptAssistantReplyOrActiveJob: result.blockedModelAttempts === 0 && !result.activeJobs && tasks.every(task => !task.modelReceipts?.length && !task.messages.some(message => message.role === 'assistant')),
};
const report = { appPID: result.appPID, binaryHash, nativeSuccess: result.success, nativeChecks: result.checks, independent, actualModelTransmissions: 0, success: result.success && Object.values(independent).every(Boolean) };
await writeFile(path.join(output, 'agent-draft-driver-report.json'), JSON.stringify(report, null, 2));
console.log(JSON.stringify({ output, success: report.success, nativeChecks: Object.keys(result.checks).length, independent }));
if (!report.success) process.exitCode = 1;

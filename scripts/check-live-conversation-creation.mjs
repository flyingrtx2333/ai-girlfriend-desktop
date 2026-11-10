import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdir, mkdtemp, readFile, readdir, writeFile } from 'node:fs/promises';
import { isDeepStrictEqual } from 'node:util';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import os from 'node:os';

const args = process.argv.slice(2), option = name => args.includes(name) ? args[args.indexOf(name) + 1] : undefined;
const app = option('--app'), prepared = option('--directory'), prepare = args.includes('--prepare-only'), preflight = args.includes('--preflight');
if (!prepare && !app || !prepare && !preflight && !prepared) throw new Error('Prepare a fresh directory, then pass the exact signed --app and --directory after separate authorization.');
const root = fileURLToPath(new URL('../', import.meta.url)), prefix = preflight ? 'bluefatfish-conversation-creation-preflight-' : 'bluefatfish-conversation-creation-live-';
const output = prepared ? path.resolve(prepared) : await mkdtemp(path.join(os.tmpdir(), prefix));
if (!path.basename(output).startsWith(prefix)) throw new Error('Use a separate directory for this exact live or preflight scope.');
const hash = data => createHash('sha256').update(data).digest('hex'), pause = ms => new Promise(resolve => setTimeout(resolve, ms));
const read = async name => JSON.parse(await readFile(path.join(output, name), 'utf8'));
async function maybe(name) { try { return await read(name); } catch (error) { if (error.code === 'ENOENT') return undefined; throw error; } }
const production = path.join(os.homedir(), 'Library/Application Support/BlueFatFish');
async function dailyHashes() {
  const names = ['settings.json', 'history.json', 'organization.json', 'agent/index.json', 'extensions/agents.json', 'extensions/plugin-agent-models.json', 'automations/definitions.json'];
  for (const name of await readdir(path.join(production, 'agent')).catch(error => { if (error.code === 'ENOENT') return []; throw error; })) if (/^[A-Fa-f0-9-]{36}\.json$/.test(name)) names.push('agent/' + name);
  return Object.fromEntries(await Promise.all(names.map(async name => [name, await readFile(path.join(production, name)).then(hash).catch(error => { if (error.code === 'ENOENT') return null; throw error; })])));
}
if (!prepared) {
  await mkdir(path.join(output, 'project')); await mkdir(path.join(output, 'shared-home'));
  await writeFile(path.join(output, 'project/README.md'), await readFile(path.join(root, 'README.md')));
  const intent = {
    scope: 'conversation-creation', roleName: 'README 只读核对员', automationName: 'README 一次性核对', timeZone: 'Asia/Shanghai', scheduleLeadSeconds: 300,
    rolePrompt: '请创建一个本机 Agent，名称为「README 只读核对员」，职责是核对公开项目说明。指令要求：只按当前项目的 README.md 原文回答，实际读取文件并逐项标明行号，缺少依据时明确说明；不修改文件，不执行终端，不联网，不委派。先给我可审阅的角色草稿，模型和启用状态由我在表单选择，不要直接启用或开始任务。',
    readPrompt: '实际读取 README.md 的第1至45行，只按原文回答三项：应用完整名称、原生界面技术、源码构建命令。每项引用实际行号，120字以内。不修改文件，不执行终端，不联网，不委派。',
  };
  await writeFile(path.join(output, 'conversation-creation-intent.json'), JSON.stringify(intent, null, 2));
  const inputs = {}; for (const name of ['project/README.md', 'conversation-creation-intent.json']) inputs[name] = hash(await readFile(path.join(output, name)));
  await writeFile(path.join(output, 'input-hashes.json'), JSON.stringify(inputs, null, 2)); await writeFile(path.join(output, 'production-before.json'), JSON.stringify(await dailyHashes(), null, 2));
} else if (prepare) throw new Error('Preparation never overwrites an earlier directory.');
if (prepare) { console.log(JSON.stringify({ output, prepared: true, modelTransmissionAuthorized: false, maximumRequiresSeparateApproval: 20 })); process.exit(0); }
const before = await read('production-before.json'), inputs = await read('input-hashes.json');
if (!isDeepStrictEqual(Object.keys(inputs).sort(), ['conversation-creation-intent.json', 'project/README.md'])) throw new Error('The prepared input file list changed.');
if (!isDeepStrictEqual(before, await dailyHashes())) throw new Error('Daily profile changed since preparation; no app was launched.');
for (const [name, expected] of Object.entries(inputs)) if (hash(await readFile(path.join(output, name))) !== expected) throw new Error('Prepared public input changed.');
const stem = preflight ? 'conversation-creation-preflight' : 'conversation-creation';
for (const name of [`${stem}-started.json`, `${stem}-result.json`, 'conversation-creation-request-ledger.json', 'profile/agent/index.json']) if (await readFile(path.join(output, name)).then(() => true).catch(error => { if (error.code === 'ENOENT') return false; throw error; })) throw new Error('This directory has already started; preserve its process, tasks, attempts and original records.');
const signed = spawnSync('/usr/bin/codesign', ['--verify', '--deep', '--strict', path.resolve(app)], { encoding: 'utf8' }); if (signed.status !== 0) throw new Error('Candidate strict signature failed.');
const binary = path.join(path.resolve(app), 'Contents/MacOS/BlueFatFish'), binaryHash = hash(await readFile(binary));
if (!preflight) {
  const auth = await read('conversation-creation-authorization.json'), proofPath = option('--preflight-report');
  if (auth.scope !== 'conversation-creation' || auth.maximumRequests !== 20 || auth.contextLimit !== 8192 || auth.replyLimit !== 512 || auth.model !== 'deepseek-flash' || path.resolve(auth.directory) !== output || auth.candidateHash !== binaryHash || auth.inputsHash !== hash(await readFile(path.join(output, 'input-hashes.json')))) throw new Error('This exact scope needs separate explicit authorization for at most 20 requests.');
  if (!proofPath) throw new Error('Pass the successful --preflight-report for this exact signed binary.');
  const proof = JSON.parse(await readFile(proofPath, 'utf8'));
  if (!proof.success || proof.binaryHash !== binaryHash || proof.blockedModelAttempts !== 0 || proof.modelTransmissionAuthorized !== false) throw new Error('The zero-transmission preflight did not match this candidate.');
}
await writeFile(path.join(output, preflight ? 'preflight-run-intent.json' : 'run-intent.json'), JSON.stringify({ app: path.resolve(app), binaryHash, scope: 'conversation-creation', maximum: preflight ? 0 : 20, preflight }, null, 2));
const launchArgs = ['--check', output, preflight ? '--conversation-creation-preflight-check' : '--conversation-creation-live-check', ...(preflight ? ['--background-component-check'] : ['--live-agent'])];
console.log(JSON.stringify({ output, binaryHash, preflight, maximum: preflight ? 0 : 20 }));
const launched = spawnSync('/usr/bin/open', [...(preflight ? ['-g'] : []), '-n', path.resolve(app), '--args', ...launchArgs], { encoding: 'utf8' }); if (launched.status !== 0) throw new Error('The exact candidate did not launch.');
let result, command, pid, checkedProcessAt = 0; const seen = new Set(), deadline = Date.now() + (preflight ? 120_000 : 3_900_000);
const stages = ['role-draft-ready', 'role-saved-ready', 'role-use-completed', 'automation-draft-ready', 'automation-enabled', 'complete-ready'];
while (Date.now() < deadline) {
  const start = await maybe(`${stem}-started.json`);
  if (start && !command) {
    pid = start.appPID; const observed = spawnSync('/bin/ps', ['-ww', '-p', String(pid), '-o', 'command='], { encoding: 'utf8' }).stdout.trim();
    if (observed.startsWith(`${binary} --check ${output} ${launchArgs[2]}`)) { command = observed; await writeFile(path.join(output, 'actual-process-command.json'), JSON.stringify({ appPID: pid, command, binaryHash }, null, 2)); }
  }
  if (!preflight) for (const stage of stages) if (!seen.has(stage)) {
    const value = await maybe(`conversation-creation-stage-${stage}.json`);
    if (value) { if (value.binaryHash !== binaryHash || value.appPID !== pid) throw new Error('Stage belongs to another process or candidate.'); seen.add(stage); console.log(JSON.stringify({ stage, ...value })); }
  }
  result = await maybe(`${stem}-result.json`); if (result) break;
  if (command && Date.now() - checkedProcessAt >= 1000) {
    checkedProcessAt = Date.now();
    if (!spawnSync('/bin/ps', ['-p', String(pid), '-o', 'stat='], { encoding: 'utf8' }).stdout.trim()) {
      await writeFile(path.join(output, 'driver-terminal-without-result.json'), JSON.stringify({ appPID: pid, binaryHash, actualProcessEnded: true, resultMissing: true }, null, 2));
      throw new Error('The original process ended without a result; all records remain and no replacement run was launched.');
    }
  }
  await pause(command ? 250 : 50);
}
if (!result) throw new Error('Observation ended without a terminal report; inspect the same process and preserve all attempts rather than replaying.');
const alive = () => spawnSync('/bin/ps', ['-p', String(result.appPID), '-o', 'stat='], { encoding: 'utf8' }).stdout.trim() !== '';
for (let i = 0; i < 100 && alive(); i++) await pause(100);
const independent = { actualSignedProcessMatched: !!command && result.appPID === pid && result.binaryHash === binaryHash, actualApplicationExited: !alive(), dailyProfileUnchanged: isDeepStrictEqual(before, await dailyHashes()), publicInputsUnchanged: (await Promise.all(Object.entries(inputs).map(async ([name, expected]) => hash(await readFile(path.join(output, name))) === expected))).every(Boolean) };
if (preflight) independent.noRequestLedgerCreated = !await maybe('conversation-creation-request-ledger.json');
else {
  const ledger = await maybe('conversation-creation-request-ledger.json'), index = await maybe('profile/agent/index.json');
  const tasks = await Promise.all((index?.tasks ?? []).map(task => read(`profile/agent/${task.id}.json`)));
  const receipts = tasks.flatMap(task => task.modelReceipts ?? []), definitions = await maybe('profile/automations/definitions.json'), profiles = await maybe('profile/extensions/agents.json');
  const role = profiles?.agents?.find(role => role.id === result.profileID), automation = definitions?.automations?.find(value => value.id === result.automationID);
  const roleDraft = tasks.find(task => task.id === result.roleCreatorTaskID)?.agentDrafts?.[0], planDraft = tasks.find(task => task.id === result.automationCreatorTaskID)?.automationDrafts?.[0];
  const names = await readdir(path.join(output, 'profile/automations/runs')).catch(error => { if (error.code === 'ENOENT') return []; throw error; });
  const runs = await Promise.all(names.filter(name => name.endsWith('.json')).map(name => read(`profile/automations/runs/${name}`)));
  Object.assign(independent, {
    ledgerMatchesReportedAttemptsAndSharedTwentyLimit: ledger?.maximum === 20 && ledger.attempts.length === result.usedRequests && ledger.attempts.length > 0 && ledger.attempts.length <= 20 && new Set(ledger.attempts.map(attempt => attempt.id)).size === ledger.attempts.length,
    receiptsBelongToConfiguredRealModelAndFitLedger: receipts.length >= 4 && receipts.length <= (ledger?.attempts.length ?? 0) && receipts.every(receipt => receipt.requestedModel === 'deepseek-flash'),
    savedRoleKeepsModelGeneratedInstructions: !!role && !!roleDraft && role.id === roleDraft.profile.id && role.instructions === roleDraft.profile.instructions && role.description === roleDraft.profile.description && role.name === roleDraft.profile.name && roleDraft.savedAt !== undefined && role.enabled && role.readOnly && !role.network,
    savedAutomationKeepsGeneratedPromptAndReviewedRole: !!automation && !!planDraft && automation.id === planDraft.automation.id && automation.prompt === planDraft.automation.prompt && automation.executor === `agent:${role?.id}` && planDraft.savedAt !== undefined && !automation.enabled && automation.readOnly && !automation.network && automation.schedule.frequency === 'once',
    exactlyOneActualScheduledRunAtRequestedTime: runs.length === 1 && runs[0].status === 'completed' && runs[0].trigger === 'schedule' && runs[0].id === result.scheduledRunID && runs[0].scheduled + 978307200 === result.requestedUnix,
    noActiveJobsAndTemporaryPlansPaused: result.activeJobs === false && result.allPlansPaused === true && definitions?.automations?.every(value => !value.enabled),
  });
}
const report = { ...result, independent, success: result.success && Object.values(independent).every(Boolean) };
await writeFile(path.join(output, `${stem}-driver-report.json`), JSON.stringify(report, null, 2));
console.log(JSON.stringify({ output, success: report.success, preflight, usedRequests: result.usedRequests ?? 0, independent, requiresIndependentAnswerReview: report.requiresIndependentAnswerReview ?? false })); if (!report.success) process.exitCode = 1;

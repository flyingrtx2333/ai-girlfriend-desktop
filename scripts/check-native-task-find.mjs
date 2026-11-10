import { spawnSync } from 'node:child_process';
import { mkdtemp, mkdir, readFile, writeFile, chmod } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import os from 'node:os';

const args = process.argv.slice(2), value = flag => args.includes(flag) ? args[args.indexOf(flag) + 1] : undefined;
if (!value('--app') || !value('--reply-task') || args.includes('--live-agent')) throw new Error('Pass --app and --reply-task with a preserved real-model task; this entry never authorizes model requests.');
const app = path.resolve(value('--app')), originalPath = path.resolve(value('--reply-task')), hash = data => createHash('sha256').update(data).digest('hex');
if (spawnSync('/usr/bin/codesign', ['--verify', '--deep', '--strict', app]).status !== 0) throw new Error('Candidate signature failed.');
const original = await readFile(originalPath), genuine = JSON.parse(original), reply = [...genuine.messages].reverse().find(message => message.role === 'assistant' && !message.nativeContext && message.content?.includes('project/readme-review') && !message.toolCalls?.length && genuine.modelReceipts?.some(receipt => receipt.completed && receipt.messageID === message.id && receipt.returnedModel));
if (!reply) throw new Error('The original task must contain the actual public-README reply and its completed model receipt. No replacement reply is generated.');
const output = await mkdtemp(path.join(os.tmpdir(), 'bluefatfish-task-find-'));
await mkdir(path.join(output, 'shared-home')); await mkdir(path.join(output, 'workspace'));
const publicSource = await readFile(fileURLToPath(new URL('../README.md', import.meta.url))), corpus = Buffer.from(publicSource.toString('utf8').repeat(32));
await writeFile(path.join(output, 'workspace/README.md'), publicSource); await writeFile(path.join(output, 'workspace/README-repeated.md'), corpus);
await writeFile(path.join(output, 'actual-reply-source.json'), original); await chmod(path.join(output, 'actual-reply-source.json'), 0o444);
await writeFile(path.join(output, 'source-provenance.json'), JSON.stringify({ originalPath, originalHash: hash(original), genuineTaskID: genuine.id, genuineReplyID: reply.id, existingReceiptIDs: genuine.modelReceipts.filter(receipt => receipt.messageID === reply.id).map(receipt => receipt.id), modelRequestsAuthorized: false }, null, 2));
const binary = path.join(app, 'Contents/MacOS/BlueFatFish'), binaryHash = hash(await readFile(binary));
const read = async name => JSON.parse(await readFile(path.join(output, name), 'utf8'));
async function maybe(name) { try { return await read(name); } catch (error) { if (error.code === 'ENOENT') return undefined; throw error; } }
console.log(JSON.stringify({ output, binaryHash, modelTransmissionAuthorized: false }));
if (spawnSync('/usr/bin/open', ['-g', '-n', app, '--args', '--check', output, '--task-find-check', '--background-component-check']).status !== 0) throw new Error('Candidate launch failed.');
let result, pid, command; const deadline = Date.now() + 120_000;
while (Date.now() < deadline) {
  const started = await maybe('task-find-started.json');
  if (started && !command) {
    pid = started.appPID; command = spawnSync('/bin/ps', ['-ww', '-p', String(pid), '-o', 'command='], { encoding: 'utf8' }).stdout.trim();
    if (command !== `${binary} --check ${output} --task-find-check --background-component-check`) throw new Error('Actual signed process did not match.');
    await writeFile(path.join(output, 'actual-process-command.json'), JSON.stringify({ pid, command, binaryHash }, null, 2));
  }
  result = await maybe('task-find-result.json'); if (result) break;
  if (pid && !spawnSync('/bin/ps', ['-p', String(pid), '-o', 'stat='], { encoding: 'utf8' }).stdout.trim()) throw new Error('Original process ended without a result; retain all original records.');
  await new Promise(resolve => setTimeout(resolve, 100));
}
if (!result) throw new Error('Observation ended without a terminal report. Inspect the same process; do not relaunch.');
const alive = () => !!spawnSync('/bin/ps', ['-p', String(pid), '-o', 'stat='], { encoding: 'utf8' }).stdout.trim();
for (let i = 0; i < 100 && alive(); i++) await new Promise(resolve => setTimeout(resolve, 100));
if (!result.success) { console.log(JSON.stringify(result)); process.exit(1); }
const data = await read('task-find-data.json'), texts = [corpus.toString('utf8'), publicSource.toString('utf8')];
function occurrences(text, query) {
  const haystack = text.toLowerCase(), needle = query.toLowerCase(), ranges = []; let cursor = 0;
  while (cursor < haystack.length) { const index = haystack.indexOf(needle, cursor); if (index < 0) break; ranges.push({ location: index, length: needle.length }); cursor = index + needle.length; }
  return ranges;
}
const queriesMatch = data.queries.every(query => {
  const expected = texts.flatMap((text, i) => occurrences(text, query.query).map((range, occurrence) => ({ ...range, messageID: data.sources[i].messageID, occurrence })));
  return query.count === expected.length && query.samples.every(sample => ['location', 'length', 'messageID', 'occurrence'].every(key => sample[key] === expected[sample.index]?.[key]));
});
const first = await read(`profile/agent/${data.publicTaskID}.json`), second = await read(`profile/agent/${data.otherTaskID}.json`), migrated = await read('legacy-v2-migrated.json');
const independent = {
  exactSignedProcessAndExit: !!command && result.appPID === pid && result.binaryHash === binaryHash && !alive(),
  originalGenuineTaskAndReadonlyCopyUnchanged: hash(await readFile(originalPath)) === hash(original) && hash(await readFile(path.join(output, 'actual-reply-source.json'))) === hash(original) && data.genuineSourceHash === hash(original),
  genuineReplyAndReceiptMatchOriginal: data.genuineReplyID === reply.id && data.genuineReceiptIDs.every(id => genuine.modelReceipts.some(receipt => receipt.id === id && receipt.messageID === reply.id && receipt.completed)),
  actualPublicFilesAndIndexedHashesMatch: hash(await readFile(path.join(output, 'workspace/README.md'))) === hash(publicSource) && hash(await readFile(path.join(output, 'workspace/README-repeated.md'))) === hash(corpus) && data.sources.every((source, i) => source.sha256 === hash(Buffer.from(texts[i])) && source.utf16Length === texts[i].length),
  allLiteralCountsAndUtf16PositionsMatchIndependentScan: queriesMatch,
  legacyV2MigrationPreservesOldFindKey: migrated.version === 3 && migrated.bindings.newTask.key === 'f' && migrated.bindings.findInTask.key === '',
  actualUserHistoriesAndDraftsRemainSeparate: first.messages.length === 2 && second.messages.length === 1 && first.draft === '小鲸：保留这份尚未发送的草稿。' && second.draft === '另一份未发送的草稿。' && [first, second].every(task => task.messages.every(message => message.role === 'user') && !task.modelReceipts?.length),
  modelNeverRequested: result.blockedModelAttempts === 0,
};
const report = { ...result, independent, actualModelRequests: 0, success: Object.values(independent).every(Boolean) };
await writeFile(path.join(output, 'task-find-driver-report.json'), JSON.stringify(report, null, 2));
console.log(JSON.stringify({ output, success: report.success, nativeChecks: Object.keys(result.checks).length, independent })); if (!report.success) process.exitCode = 1;

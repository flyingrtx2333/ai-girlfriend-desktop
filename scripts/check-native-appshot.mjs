import { spawnSync } from 'node:child_process';
import { mkdtemp, mkdir, readFile, readdir, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import os from 'node:os';

const args = process.argv.slice(2), index = args.indexOf('--app'), app = index >= 0 ? path.resolve(args[index + 1]) : undefined;
if (!app || args.includes('--live-agent')) throw new Error('Pass the exact signed candidate; AppShot checks never authorize model requests.');
if (spawnSync('/usr/bin/codesign', ['--verify', '--deep', '--strict', app]).status !== 0) throw new Error('Candidate signature failed.');
const root = fileURLToPath(new URL('../', import.meta.url)), output = await mkdtemp(path.join(os.tmpdir(), 'bluefatfish-appshot-'));
await mkdir(path.join(output, 'workspace')); await mkdir(path.join(output, 'shared-home'));
const publicSource = await readFile(path.join(root, 'README.md')); await writeFile(path.join(output, 'workspace/README.md'), publicSource);
const hash = data => createHash('sha256').update(data).digest('hex'), binary = path.join(app, 'Contents/MacOS/BlueFatFish'), binaryHash = hash(await readFile(binary));
const read = async name => JSON.parse(await readFile(path.join(output, name), 'utf8'));
async function maybe(name) { try { return await read(name); } catch (error) { if (error.code === 'ENOENT') return undefined; throw error; } }
console.log(JSON.stringify({ output, binaryHash, modelTransmissionAuthorized: false, externalApplicationCaptureAuthorized: false }));
if (spawnSync('/usr/bin/open', ['-n', app, '--args', '--check', output, '--appshot-check']).status !== 0) throw new Error('Candidate launch failed.');
let result, pid, command; const deadline = Date.now() + 120_000;
while (Date.now() < deadline) {
  const started = await maybe('appshot-started.json');
  if (started && !command) {
    pid = started.appPID; command = spawnSync('/bin/ps', ['-ww', '-p', String(pid), '-o', 'command='], { encoding: 'utf8' }).stdout.trim();
    if (!command.startsWith(`${binary} --check ${output} --appshot-check`)) throw new Error('Actual signed process did not match.');
    await writeFile(path.join(output, 'actual-process-command.json'), JSON.stringify({ pid, command, binaryHash }, null, 2));
  }
  result = await maybe('appshot-result.json'); if (result) break;
  if (pid && !spawnSync('/bin/ps', ['-p', String(pid), '-o', 'stat='], { encoding: 'utf8' }).stdout.trim()) throw new Error('Original process ended without a result; retain all original records.');
  await new Promise(resolve => setTimeout(resolve, 100));
}
if (!result) throw new Error('Observation ended without a terminal report; inspect the same process.');
const alive = () => !!spawnSync('/bin/ps', ['-p', String(pid), '-o', 'stat='], { encoding: 'utf8' }).stdout.trim();
for (let i = 0; i < 100 && alive(); i++) await new Promise(resolve => setTimeout(resolve, 100));
if (!result.success) { console.log(JSON.stringify(result)); process.exitCode = 1; }
else {
  const file = await read('actual-attachment.json'), document = await read(`profile/agent/${result.taskID}/attachments/${file.id}/content.json`), png = await readFile(path.join(output, 'actual-window.png'));
  const names = (await readdir(path.join(output, 'profile/agent'))).filter(name => /^[A-Fa-f0-9-]{36}\.json$/.test(name)), tasks = await Promise.all(names.map(name => read('profile/agent/' + name)));
  const other = tasks.find(task => task.id === result.otherTaskID), actual = tasks.find(task => task.id === result.taskID);
  const wire = await read('actual-wire.json'), parts = wire.flatMap(message => Array.isArray(message.content) ? message.content : []), images = parts.filter(part => part.type === 'image_url');
  const actualJpeg = images.length === 1 && typeof images[0].image_url?.url === 'string' && images[0].image_url.url.startsWith('data:image/jpeg;base64,') ? Buffer.from(images[0].image_url.url.slice('data:image/jpeg;base64,'.length), 'base64') : Buffer.alloc(0);
  const independent = {
    actualSignedProcessAndExit: !!command && result.appPID === pid && result.binaryHash === binaryHash && !alive(),
    actualPublicSourceUnchanged: hash(await readFile(path.join(output, 'workspace/README.md'))) === hash(publicSource) && result.sourceHash === hash(publicSource),
    actualPngDimensionsAndHashMatchAttachment: png.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10])) && png.readUInt32BE(16) === file.width && png.readUInt32BE(20) === file.height && hash(png) === file.sha256,
    fullAccessibleTextHashMatchesActualRecord: hash(Buffer.from(document.parts[0].text)) === file.desktopCapture.textHash && document.parts[0].text.includes('本轮只核对实际窗口快照') && file.desktopCapture.appShot,
    actualSerializedImageAndAccessibleText: actualJpeg[0] === 0xff && actualJpeg[1] === 0xd8 && actualJpeg.at(-2) === 0xff && actualJpeg.at(-1) === 0xd9 && wire.some(message => typeof message.content === 'string' && message.content.includes('本轮只核对实际窗口快照')),
    actualUnsentOtherTaskPreserved: other?.draft === '另一个任务的未发送草稿' && !other?.attachments?.length && !other?.messages?.length,
    submittedReferenceBelongsToActualTaskOnly: actual?.messages.length === 1 && actual.messages[0].attachmentIDs.includes(file.id) && actual.messages[0].visuals[0].id === file.id,
    modelNeverRequestedAndNoAssistantReceipt: result.blockedModelAttempts === 0 && tasks.every(task => !task.modelReceipts?.length && !task.messages.some(message => message.role === 'assistant')),
    globalShortcutDisabledAtCompletion: (await read('profile/computer-use/appshot.json')).shortcut === 'disabled',
  };
  const report = { ...result, independent, actualModelRequests: 0, externalApplicationCaptureAuthorized: false, success: Object.values(independent).every(Boolean) };
  await writeFile(path.join(output, 'appshot-driver-report.json'), JSON.stringify(report, null, 2));
  console.log(JSON.stringify({ output, success: report.success, nativeChecks: Object.keys(result.checks).length, independent })); if (!report.success) process.exitCode = 1;
}

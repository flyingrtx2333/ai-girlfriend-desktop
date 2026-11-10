import { spawnSync } from 'node:child_process';
import { mkdtemp, mkdir, readFile, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import os from 'node:os';
import path from 'node:path';

const args = process.argv.slice(2), index = args.indexOf('--app'), app = index >= 0 ? path.resolve(args[index + 1]) : undefined;
if (!app || args.includes('--live-agent')) throw new Error('Pass the exact signed --app; this check never authorizes model requests.');
const signed = spawnSync('/usr/bin/codesign', ['--verify', '--deep', '--strict', app]);
if (signed.status !== 0) throw new Error('Candidate signature failed.');
const output = await mkdtemp(path.join(os.tmpdir(), 'bluefatfish-shortcuts-'));
await mkdir(path.join(output, 'shared-home'));
const binary = path.join(app, 'Contents/MacOS/BlueFatFish'), hash = data => createHash('sha256').update(data).digest('hex'), binaryHash = hash(await readFile(binary));
const read = async name => JSON.parse(await readFile(path.join(output, name), 'utf8'));
async function maybe(name) { try { return await read(name); } catch (error) { if (error.code === 'ENOENT') return undefined; throw error; } }
const launched = spawnSync('/usr/bin/open', ['-g', '-n', app, '--args', '--check', output, '--shortcut-check', '--background-component-check']);
if (launched.status !== 0) throw new Error('Candidate launch failed.');
console.log(JSON.stringify({ output, binaryHash, modelTransmissionAuthorized: false }));
let command, pid, result;
const deadline = Date.now() + 120_000;
while (Date.now() < deadline) {
  const started = await maybe('shortcut-started.json');
  if (started && !command) {
    pid = started.appPID;
    command = spawnSync('/bin/ps', ['-ww', '-p', String(pid), '-o', 'command='], { encoding: 'utf8' }).stdout.trim();
    if (!command.startsWith(`${binary} --check ${output} --shortcut-check`)) throw new Error('Actual candidate process did not match.');
    await writeFile(path.join(output, 'actual-process-command.json'), JSON.stringify({ command, pid, binaryHash }, null, 2));
  }
  result = await maybe('shortcut-result.json'); if (result) break;
  if (pid && !spawnSync('/bin/ps', ['-p', String(pid), '-o', 'stat='], { encoding: 'utf8' }).stdout.trim()) throw new Error('Original process ended without a result; preserve all original records.');
  await new Promise(resolve => setTimeout(resolve, 100));
}
if (!result) throw new Error('Observation ended without a terminal report; inspect the same process.');
const alive = () => !!spawnSync('/bin/ps', ['-p', String(pid), '-o', 'stat='], { encoding: 'utf8' }).stdout.trim();
for (let i = 0; i < 100 && alive(); i++) await new Promise(resolve => setTimeout(resolve, 100));
const config = await read('shortcut-store-check/shortcuts.json'), profile = await read('profile/shortcuts.json');
const independent = {
  exactSignedProcess: !!command && result.appPID === pid && result.binaryHash === binaryHash,
  actualProcessExited: !alive(),
  persistedCombinationMatchesIndependentReadback: config.version === 1 && Object.keys(config.bindings).length === 1 && config.bindings.searchTasks.key === 'j' && config.bindings.searchTasks.modifiers === 1572864,
  realApplicationConfigRestored: profile.version === 1 && Object.keys(profile.bindings).length === 0,
  modelWasNeverRequested: result.blockedModelAttempts === 0,
};
const report = { ...result, independent, success: result.success && Object.values(independent).every(Boolean) };
await writeFile(path.join(output, 'shortcut-driver-report.json'), JSON.stringify(report, null, 2));
console.log(JSON.stringify({ output, success: report.success, nativeChecks: Object.keys(result.checks).length, independent }));
if (!report.success) process.exitCode = 1;

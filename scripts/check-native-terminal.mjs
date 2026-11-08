import { spawnSync } from 'node:child_process';
import { readFile, writeFile, readdir, mkdtemp, mkdir, cp, unlink } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { isDeepStrictEqual } from 'node:util';
import { fileURLToPath } from 'node:url';
import os from 'node:os';
import path from 'node:path';

const root = fileURLToPath(new URL('../', import.meta.url)), resume = process.argv.indexOf('--resume');
const output = resume < 0 ? await mkdtemp(path.join(os.tmpdir(), 'bluefatfish-terminal-')) : path.resolve(process.argv[resume + 1]);
if (!path.basename(output).startsWith('bluefatfish-terminal-')) throw new Error('Use an actual terminal acceptance directory');
const hash = value => createHash('sha256').update(value).digest('hex');
const json = async name => JSON.parse(await readFile(path.join(output, name), 'utf8'));
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
function command(executable, args) { const result = spawnSync(executable, args, { encoding: 'utf8' }); if (result.status !== 0) throw new Error(result.stderr || result.stdout || executable); return result.stdout; }
function live(pid) { try { process.kill(pid, 0); return true; } catch (error) { if (error.code === 'ESRCH') return false; throw error; } }
async function snapshot() {
  const base = path.join(os.homedir(), 'Library/Application Support/BlueFatFish');
  const names = ['settings.json', 'history.json', 'agent/index.json', 'organization.json', 'automations/definitions.json', 'models/catalog.json', 'extensions/mcp.json', 'extensions/hooks.json', 'extensions/hook-settings.json', 'extensions/settings.json', 'extensions/agents.json', 'extensions/teams.json', 'worktrees/policy.json', 'worktrees/history.json', 'worktrees/scheduler.lock', 'computer-use/settings.json', 'imports/batch.json'];
  for (const name of await readdir(path.join(base, 'agent'))) if (/^[0-9a-f-]{36}\.json$/i.test(name)) names.push('agent/' + name);
  return Object.fromEntries(await Promise.all(names.sort().map(async name => [name, await readFile(path.join(base, name)).then(hash).catch(error => { if (error.code === 'ENOENT') return null; throw error; })])));
}
function machine() {
  const disk = command('/bin/df', ['-kP', '/', '/System/Volumes/Data']);
  return { checkedAt: new Date().toISOString(), physicalBytes: Number(command('/usr/sbin/sysctl', ['-n', 'hw.memsize']).trim()), disk, availableBytes: Object.fromEntries(disk.trim().split('\n').slice(1).map(row => { const cells = row.trim().split(/\s+/); return [cells.at(-1), Number(cells[3]) * 1024]; })) };
}
const before = resume < 0 ? await snapshot() : await json('production-before.json');
if (!isDeepStrictEqual(before, await snapshot())) throw new Error('Preserve and inspect changed daily data');
if (resume < 0) { await writeFile(path.join(output, 'production-before.json'), JSON.stringify(before, null, 2)); await writeFile(path.join(output, 'machine-before.json'), JSON.stringify(machine(), null, 2)); }
console.log(JSON.stringify({ output }));
if (process.argv.includes('--prepare-only')) process.exit(0);
const app = path.join(root, 'build/蓝色大肥鱼.app'), binaryHash = hash(await readFile(path.join(app, 'Contents/MacOS/BlueFatFish')));
async function waitJSON(name, seconds, pid) {
  const deadline = Date.now() + seconds * 1000;
  while (Date.now() < deadline) {
    const value = await json(name).catch(error => { if (error.code === 'ENOENT' || error instanceof SyntaxError) return null; throw error; });
    if (value) return value;
    if (pid && !live(pid)) { const failure = await json('terminal-report.json').catch(() => null); throw new Error(failure?.error || 'Actual application exited before ' + name); }
    await pause(200);
  }
  throw new Error('Observation deadline; preserve the original terminal process');
}
let report;
try {
  const previous = await json('terminal-process.json').catch(() => null);
  if (previous && live(previous.appPID)) throw new Error('Existing terminal acceptance is still running; preserve it');
  for (const name of ['terminal-process.json', 'terminal-ui-ready.json', 'terminal-report.json', 'finish-terminal-ui']) await unlink(path.join(output, name)).catch(error => { if (error.code !== 'ENOENT') throw error; });
  command('/usr/bin/open', ['-n', app, '--args', '--check', output, '--terminal-check', '--live-agent']);
  const owner = await waitJSON('terminal-process.json', 30), ready = await waitJSON('terminal-ui-ready.json', 180, owner.appPID);
  if (ready.binaryHash !== binaryHash) throw new Error('Actual UI candidate mismatch');
  console.log(JSON.stringify({ phase: 'actual-ui-ready', output, ...ready, independentBefore: await json('machine-before.json') }));
  report = await waitJSON('terminal-report.json', 1500, owner.appPID);
  for (let i = 0; i < 100 && live(owner.appPID); i++) await pause(100);
  if (live(owner.appPID)) throw new Error('Original application is still running');
  if (!report.success) throw new Error(report.error || 'Terminal acceptance failed');
  const task = JSON.parse(await readFile(path.join(output, 'profile/agent', ready.taskID + '.json'), 'utf8')), receipts = task.modelReceipts ?? [], current = machine();
  const actual = report.commands.filter(value => value.successful), physicalObserved = actual.some(value => /\bsysctl\b[\s\S]*hw\.memsize/.test(value.command) && value.text.includes(String(current.physicalBytes)));
  const disks = [];
  for (const value of actual) for (const row of value.text.split('\n')) {
    if (!/\bdf\b/.test(value.command)) continue;
    if (!/^\/dev\/\S+\s/.test(row)) continue;
    const cells = row.trim().split(/\s+/), mount = cells.at(-1);
    if (!(mount in current.availableBytes)) continue;
    const token = /^(\d+(?:\.\d+)?)([KMGTPE]?)(i?)(B?)$/i.exec(cells[3]);
    if (!token) continue;
    const power = 'KMGTPE'.indexOf(token[2].toUpperCase()) + 1;
    const base = token[3] || !/\bdf\s+-H\b/.test(value.command) ? 1024 : 1000;
    const unit = token[2] ? base ** power : /1024-blocks|1K-blocks/i.test(value.text) ? 1024 : 512;
    const observed = Number(token[1]) * unit, tolerance = Math.max(unit, 64 * 1024 ** 2);
    disks.push({ mount, observed, actual: current.availableBytes[mount], tolerance, matches: Math.abs(observed - current.availableBytes[mount]) <= tolerance });
  }
  const accounted = receipts.length > 0 && receipts.every(value => Number.isInteger(value.inputTokens) && Number.isInteger(value.outputTokens)) && receipts.reduce((n, value) => n + value.inputTokens, 0) === task.inputTokens && receipts.reduce((n, value) => n + value.outputTokens, 0) === task.outputTokens;
  report.independent = { productionProfileUnchanged: isDeepStrictEqual(before, await snapshot()), physicalMemoryBytes: current.physicalBytes, actualTerminalPhysicalMemoryMatches: physicalObserved, diskReadbacks: disks, actualTerminalDiskMatches: disks.some(value => value.matches), receiptAccountingMatches: accounted, selectedWorkspaceRemainsUnset: task.workspace == null, modeRemainsAsk: task.mode === 'ask', machineAfter: current };
  report.success &&= Object.values(report.native.checks).every(Boolean) && report.independent.productionProfileUnchanged && physicalObserved && report.independent.actualTerminalDiskMatches && accounted && task.workspace == null && task.mode === 'ask';
} catch (error) { report = { ...(report ?? {}), success: false, error: error.message }; }
finally {
  await writeFile(path.join(output, 'terminal-driver-report.json'), JSON.stringify(report, null, 2));
  const archive = path.join(root, 'evidence/agent', path.basename(output) + '-' + new Date().toISOString().replace(/[:.]/g, '-'));
  await mkdir(path.dirname(archive), { recursive: true }); await cp(output, archive, { recursive: true });
  console.log(JSON.stringify({ success: report?.success, output, archive, error: report?.error }));
}
if (!report?.success) process.exitCode = 1;

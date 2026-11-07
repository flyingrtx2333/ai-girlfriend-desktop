import { spawnSync } from 'node:child_process';
import { cp, lstat, mkdir, mkdtemp, readFile, unlink, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import os from 'node:os';
import path from 'node:path';
import { isDeepStrictEqual } from 'node:util';

const root = fileURLToPath(new URL('../', import.meta.url));
const option = name => { const i = process.argv.indexOf(name); return i < 0 ? undefined : process.argv[i + 1]; };
const resume = option('--resume'), output = resume ? path.resolve(resume) : await mkdtemp(path.join(os.tmpdir(), 'bluefatfish-canvas-skill-'));
if (!path.basename(output).startsWith('bluefatfish-canvas-skill-')) throw new Error('Use an actual Canvas Skill acceptance directory');
const live = process.argv.includes('--live-agent'), hold = process.argv.includes('--hold-ui');
const hash = data => createHash('sha256').update(data).digest('hex'), pause = ms => new Promise(resolve => setTimeout(resolve, ms));
const production = path.join(os.homedir(), 'Library/Application Support/BlueFatFish');
const names = ['settings.json', 'history.json', 'agent/index.json', 'agent/A7A38353-CBA2-431C-84F1-4903E73EA373.json', 'automations/definitions.json', 'models/catalog.json', 'extensions/mcp.json', 'extensions/hooks.json', 'extensions/hook-settings.json', 'worktrees/policy.json', 'worktrees/history.json', 'worktrees/scheduler.lock', 'computer-use/settings.json'];
const profileHashes = async () => Object.fromEntries(await Promise.all(names.map(async name => [name, await readFile(path.join(production, name)).then(hash).catch(error => { if (error.code === 'ENOENT') return null; throw error; })])));
const before = resume ? JSON.parse(await readFile(path.join(output, 'production-before.json'), 'utf8')) : await profileHashes();
const alive = pid => { try { process.kill(pid, 0); return true; } catch (error) { if (error.code === 'ESRCH') return false; throw error; } };
if (JSON.stringify(before) !== JSON.stringify(await profileHashes())) throw new Error('Production profile changed; preserve and inspect');
if (!resume) {
  const sourceProfile = option('--source-profile'), taskID = option('--source-task');
  if (!sourceProfile || !taskID || !/^[A-Fa-f0-9-]{36}$/.test(taskID)) throw new Error('Choose an existing real-model Canvas with --source-profile and --source-task');
  const task = JSON.parse(await readFile(path.join(sourceProfile, 'agent', taskID + '.json'), 'utf8'));
  if (task.status !== 'completed' || !task.canvases?.length || !task.modelReceipts?.length) throw new Error('Source must be an actual completed-model Canvas task');
  const copied = spawnSync('/usr/bin/ditto', [sourceProfile, path.join(output, 'profile')], { encoding: 'utf8' });
  if (copied.status !== 0) throw new Error(copied.stderr);
  await mkdir(path.join(output, 'shared-home')); await mkdir(path.join(output, 'repo'));
  await writeFile(path.join(output, 'repo/sales.csv'), 'item,amount\nA,11.35\nB,7.65\nC,30.50\n');
  await writeFile(path.join(output, 'source.json'), JSON.stringify({ taskID, sourceProfile: path.resolve(sourceProfile) }));
  await writeFile(path.join(output, 'production-before.json'), JSON.stringify(before, null, 2));
} else {
  const previous = JSON.parse(await readFile(path.join(output, 'canvas-skill-process.json'), 'utf8'));
  if (alive(previous.appPID)) throw new Error('Original Canvas Skill app is live; continue its actual handle');
  for (const name of ['canvas-skill-report.json', 'canvas-skill-process.json', 'canvas-skill-ui-ready.json', 'finish-canvas-skill-ui']) await unlink(path.join(output, name)).catch(error => { if (error.code !== 'ENOENT') throw error; });
}
const inputHash = hash(await readFile(path.join(output, 'repo/sales.csv')));
async function waitFile(name, seconds, owner) {
  const deadline = Date.now() + seconds * 1000;
  while (Date.now() < deadline) {
    try { return JSON.parse(await readFile(path.join(output, name), 'utf8')); } catch (error) { if (error.code !== 'ENOENT' && !(error instanceof SyntaxError)) throw error; }
    if (owner && !alive(owner)) throw new Error('Actual app exited before ' + name);
    await pause(300);
  }
  throw new Error('Timed out waiting for ' + name + '; preserve any live original handle');
}
let report;
console.log(JSON.stringify({ output, live, hold }));
try {
  if (live && !hold) throw new Error('Live acceptance requires --hold-ui for actual package/import and interaction');
  const launch = spawnSync('/usr/bin/open', ['-n', path.join(root, 'build/蓝色大肥鱼.app'), '--args', '--check', output, '--canvas-check', '--canvas-skill-check', ...(live ? ['--live-agent'] : []), ...(hold ? ['--hold-ui'] : [])], { encoding: 'utf8' });
  if (launch.status !== 0) throw new Error(launch.stderr);
  const owner = await waitFile('canvas-skill-process.json', 30);
  report = await waitFile('canvas-skill-report.json', live ? 2800 : 120, owner.appPID);
  for (let n = 0; n < 100 && alive(owner.appPID); n++) await pause(100);
  if (alive(owner.appPID)) throw new Error('Acceptance app still live; preserve its original handle');
  if (!report.success) throw new Error(report.error || 'Native acceptance did not pass');
  const source = JSON.parse(await readFile(path.join(output, 'source.json'), 'utf8'));
  const original = JSON.parse(await readFile(path.join(source.sourceProfile, 'agent', source.taskID + '.json'), 'utf8'));
  const retained = JSON.parse(await readFile(path.join(output, 'profile/agent', source.taskID + '.json'), 'utf8'));
  report.independent = { productionProfileUnchanged: JSON.stringify(before) === JSON.stringify(await profileHashes()), actualInputCsvUnchanged: inputHash === hash(await readFile(path.join(output, 'repo/sales.csv'))), originalActualMessagesAndReceiptsUnchanged: isDeepStrictEqual(original.messages, retained.messages) && isDeepStrictEqual(original.modelReceipts, retained.modelReceipts) };
  if (live) {
    const task = JSON.parse(await readFile(path.join(output, 'profile/agent', report.live.taskID + '.json'), 'utf8')), receipts = task.modelReceipts ?? [];
    const rows = (await readFile(path.join(output, 'repo/sales.csv'), 'utf8')).trim().split('\n').slice(1), cents = rows.reduce((n, r) => n + Math.round(Number(r.split(',')[1]) * 100), 0);
    report.independent.actualModelMatchesIndependentNewDataCalculation = report.live.renderedBeforeUI.text.includes((cents / 100).toFixed(2));
    report.independent.actualUsageFullyAccounted = receipts.length > 0 && receipts.every(r => Number.isInteger(r.inputTokens) && Number.isInteger(r.outputTokens)) && task.inputTokens === receipts.reduce((n, r) => n + r.inputTokens, 0) && task.outputTokens === receipts.reduce((n, r) => n + r.outputTokens, 0);
    report.independent.onlyScopedToolsUsed = task.messages.flatMap(m => m.toolCalls ?? []).every(c => ['load_tools', 'read_file', 'list_directory', 'list_skills', 'read_skill', 'read_skill_resource', 'unload_skill', 'update_plan', 'read_task_history', 'canvas_list', 'canvas_create', 'canvas_read', 'canvas_update', 'canvas_edit', 'canvas_restore', 'canvas_inspect', 'canvas_screenshot'].includes(c.name));
    const canvas = task.canvases[0], base = path.join(output, 'profile/agent', task.id, 'canvases', canvas.id), preview = JSON.parse(await readFile(path.join(base, 'preview.json'), 'utf8'));
    report.independent.inlinePreviewIsPrivateAndMatchesActualSource = preview.sourceHash === canvas.hash && hash(await readFile(path.join(base, 'document.canvas.tsx'))) === canvas.hash && hash(await readFile(path.join(base, 'preview.png'))) === preview.imageHash && ((await lstat(path.join(base, 'preview.png'))).mode & 0o777) === 0o600;
  }
  report.success &&= Object.values(report.independent).every(Boolean);
} catch (error) { report = { ...(report ?? {}), success: false, error: error.message }; }
finally {
  await writeFile(path.join(output, 'canvas-skill-driver-report.json'), JSON.stringify(report, null, 2) + '\n');
  const archive = path.join(root, 'evidence/agent', path.basename(output).replace('bluefatfish-', '') + '-' + new Date().toISOString().replace(/[:.]/g, '-'));
  await mkdir(path.dirname(archive), { recursive: true });
  const archived = spawnSync('/usr/bin/ditto', [output, archive], { encoding: 'utf8' });
  if (archived.status !== 0) throw new Error(archived.stderr);
  console.log(JSON.stringify({ success: report?.success, output, archive, error: report?.error }));
}
if (!report?.success) process.exitCode = 1;

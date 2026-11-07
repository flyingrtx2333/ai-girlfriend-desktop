import { spawnSync } from 'node:child_process';
import { cp, lstat, mkdir, mkdtemp, readFile, readdir, unlink, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { createServer } from 'node:http';
import { fileURLToPath } from 'node:url';
import os from 'node:os';
import path from 'node:path';

const root = fileURLToPath(new URL('../', import.meta.url)), resumeAt = process.argv.indexOf('--resume');
const output = resumeAt >= 0 ? path.resolve(process.argv[resumeAt + 1] ?? '') : await mkdtemp(path.join(os.tmpdir(), 'bluefatfish-canvas-'));
if (!path.basename(output).startsWith('bluefatfish-canvas-')) throw new Error('Use an actual canvas acceptance directory');
const live = process.argv.includes('--live-agent'), hold = process.argv.includes('--hold-ui'), holdExport = process.argv.includes('--hold-export');
const pause = ms => new Promise(resolve => setTimeout(resolve, ms)), hash = bytes => createHash('sha256').update(bytes).digest('hex');
const production = path.join(os.homedir(), 'Library/Application Support/BlueFatFish');
const names = ['settings.json', 'history.json', 'agent/index.json', 'agent/A7A38353-CBA2-431C-84F1-4903E73EA373.json', 'automations/definitions.json', 'models/catalog.json', 'extensions/mcp.json', 'extensions/hooks.json', 'extensions/hook-settings.json', 'worktrees/policy.json', 'worktrees/history.json', 'worktrees/scheduler.lock', 'computer-use/settings.json'];
async function profileHashes() { return Object.fromEntries(await Promise.all(names.map(async name => [name, await readFile(path.join(production, name)).then(hash).catch(error => { if (error.code === 'ENOENT') return null; throw error; })]))); }
const before = resumeAt >= 0 ? JSON.parse(await readFile(path.join(output, 'production-before.json'), 'utf8')) : await profileHashes();
const alive = pid => { try { process.kill(pid, 0); return true; } catch (error) { if (error.code === 'ESRCH') return false; throw error; } };
if (JSON.stringify(before) !== JSON.stringify(await profileHashes())) throw new Error('Production profile changed; preserve and inspect');
if (resumeAt < 0) {
  await mkdir(path.join(output, 'repo')); await mkdir(path.join(output, 'shared-home'));
  await writeFile(path.join(output, 'repo/sales.csv'), 'item,amount\nA,19.90\nB,20.00\nC,9.10\n');
  await writeFile(path.join(output, 'production-before.json'), JSON.stringify(before, null, 2));
} else {
  const previous = JSON.parse(await readFile(path.join(output, 'canvas-process.json'), 'utf8'));
  if (alive(previous.appPID)) throw new Error('Original canvas acceptance app is still live');
  for (const name of ['canvas-report.json', 'canvas-ui-ready.json', 'canvas-process.json', 'finish-canvas-ui', 'finish-canvas-export']) await unlink(path.join(output, name)).catch(error => { if (error.code !== 'ENOENT') throw error; });
}
const inputHash = hash(await readFile(path.join(output, 'repo/sales.csv')));
async function waitFile(name, seconds, owner) {
  const deadline = Date.now() + seconds * 1000;
  while (Date.now() < deadline) {
    try { return JSON.parse(await readFile(path.join(output, name), 'utf8')); } catch (error) { if (error.code !== 'ENOENT' && !(error instanceof SyntaxError)) throw error; }
    if (owner && !alive(owner)) throw new Error('Actual acceptance app exited before ' + name);
    await pause(250);
  }
  throw new Error('Timed out waiting for ' + name);
}
let report, owner;
console.log(JSON.stringify({ output, live, hold, holdExport }));
try {
  const launch = spawnSync('/usr/bin/open', ['-n', path.join(root, 'build/蓝色大肥鱼.app'), '--args', '--check', output, '--canvas-check', ...(live ? ['--live-agent'] : []), ...(hold ? ['--hold-ui'] : [])], { encoding: 'utf8' });
  if (launch.status !== 0) throw new Error(launch.stderr);
  owner = await waitFile('canvas-process.json', 30);
  report = await waitFile('canvas-report.json', live ? 420 : 90, owner.appPID);
  console.log(JSON.stringify({ success: report.success, nativeAndModelChecks: Object.keys(report.checks ?? {}).length, live: report.live, error: report.error }));
  if (hold && report.success) {
    const deadline = Date.now() + 1220_000;
    while (Date.now() < deadline && alive(owner.appPID)) {
      try { await readFile(path.join(output, 'finish-canvas-ui')); break; } catch (error) { if (error.code !== 'ENOENT') throw error; }
      await pause(300);
    }
  }
  for (let n = 0; n < 100 && alive(owner.appPID); n++) await pause(100);
  if (alive(owner.appPID)) throw new Error('Acceptance app is still live; preserve its original handle');
  report = JSON.parse(await readFile(path.join(output, 'canvas-report.json'), 'utf8'));
  if (!report.success) throw new Error(report.error || 'Native canvas acceptance did not pass');
  const tasks = await Promise.all((await readdir(path.join(output, 'profile/agent'))).filter(name => name.endsWith('.json') && name !== 'index.json').map(name => readFile(path.join(output, 'profile/agent', name), 'utf8').then(JSON.parse)));
  report.independent = { productionProfileUnchanged: JSON.stringify(before) === JSON.stringify(await profileHashes()), actualCsvBytesUnchanged: hash(await readFile(path.join(output, 'repo/sales.csv'))) === inputHash };
  if (live) {
    const task = tasks.find(task => task.id === report.live?.taskID), calls = task?.messages.flatMap(message => message.toolCalls ?? []) ?? [], receipts = task?.modelReceipts ?? [];
    const rows = (await readFile(path.join(output, 'repo/sales.csv'), 'utf8')).trim().split('\n').slice(1), cents = rows.reduce((sum, row) => sum + Math.round(Number(row.split(',')[1]) * 100), 0);
    const code = await readFile(path.join(output, 'actual-model.canvas.tsx')), record = task?.canvases?.find(canvas => canvas.id === report.live?.canvasID);
    report.independent.actualRenderedSumMatchesIndependentCsvCalculation = report.live.rendered.text.includes((cents / 100).toFixed(2)) && rows.length === 3;
    report.independent.actualModelSourceAndRecordMatch = hash(code) === record?.hash && record?.hash === report.afterUI?.sourceHash;
    report.independent.modelUsedOnlyScopedReadAndCanvasTools = calls.length > 0 && calls.every(call => ['load_tools', 'read_file', 'list_directory', 'read_task_history', 'update_plan', 'canvas_list', 'canvas_create', 'canvas_read', 'canvas_update', 'canvas_edit', 'canvas_restore', 'canvas_inspect', 'canvas_screenshot'].includes(call.name));
    report.independent.actualModelUsageAccounted = task?.status === 'completed' && receipts.length > 0 && task.inputTokens === receipts.reduce((n, r) => n + r.inputTokens, 0) && task.outputTokens === receipts.reduce((n, r) => n + r.outputTokens, 0);
    report.independent.actualSourceSnapshotsRemainPrivate = (await Promise.all(record.versions.map(async version => { const file = path.join(output, 'profile/agent', task.id, 'canvases', record.id, 'versions', version.hash + '.canvas.tsx'), info = await lstat(file); return !info.isSymbolicLink() && (info.mode & 0o777) === 0o600 && hash(await readFile(file)) === version.hash; }))).every(Boolean);
    if (holdExport && report.success) {
      const bytes = await readFile(path.join(output, 'actual-model-canvas.html'));
      const server = createServer((request, response) => { if (request.url !== '/canvas.html') { response.writeHead(404); response.end(); return; } response.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' }); response.end(bytes); });
      await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
      const url = `http://127.0.0.1:${server.address().port}/canvas.html`;
      await writeFile(path.join(output, 'export-server.json'), JSON.stringify({ url, pid: process.pid, htmlSHA256: hash(bytes) }, null, 2)); console.log(JSON.stringify({ actualExportURL: url, output }));
      const deadline = Date.now() + 1220_000;
      while (Date.now() < deadline) { try { await readFile(path.join(output, 'finish-canvas-export')); break; } catch (error) { if (error.code !== 'ENOENT') throw error; } await pause(300); }
      await new Promise(resolve => server.close(resolve));
    }
  } else report.independent.noModelRequests = tasks.every(task => !(task.modelReceipts ?? []).length);
  report.success &&= Object.values(report.independent).every(Boolean);
} catch (error) { report = { ...(report ?? {}), success: false, error: error.message }; }
finally {
  await writeFile(path.join(output, 'canvas-driver-report.json'), JSON.stringify(report, null, 2) + '\n');
  const archive = path.join(root, 'evidence/agent', path.basename(output).replace('bluefatfish-', '') + '-' + new Date().toISOString().replace(/[:.]/g, '-'));
  await mkdir(path.dirname(archive), { recursive: true }); await cp(output, archive, { recursive: true, verbatimSymlinks: true });
  console.log(JSON.stringify({ success: report?.success, output, archive, error: report?.error }));
}
if (!report?.success) process.exitCode = 1;

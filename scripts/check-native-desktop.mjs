import { spawnSync } from 'node:child_process';
import { cp, mkdir, mkdtemp, readFile, readdir, unlink, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import os from 'node:os';
import path from 'node:path';

const root = fileURLToPath(new URL('../', import.meta.url)), resumeAt = process.argv.indexOf('--resume');
const output = resumeAt >= 0 ? path.resolve(process.argv[resumeAt + 1] ?? '') : await mkdtemp(path.join(os.tmpdir(), 'bluefatfish-desktop-'));
if (!path.basename(output).startsWith('bluefatfish-desktop-')) throw new Error('Use an actual desktop acceptance directory');
const live = process.argv.includes('--live-agent'), hold = process.argv.includes('--hold-ui'), pause = ms => new Promise(resolve => setTimeout(resolve, ms));
const hash = data => createHash('sha256').update(data).digest('hex'), production = path.join(os.homedir(), 'Library/Application Support/BlueFatFish');
const names = ['settings.json', 'history.json', 'agent/index.json', 'agent/A7A38353-CBA2-431C-84F1-4903E73EA373.json', 'automations/definitions.json', 'models/catalog.json', 'extensions/mcp.json', 'extensions/hooks.json', 'extensions/hook-settings.json', 'worktrees/policy.json', 'worktrees/history.json', 'worktrees/scheduler.lock', 'computer-use/settings.json'];
async function profileHashes() { return Object.fromEntries(await Promise.all(names.map(async name => [name, await readFile(path.join(production, name)).then(hash).catch(error => { if (error.code === 'ENOENT') return null; throw error; })]))); }
const before = resumeAt >= 0 ? JSON.parse(await readFile(path.join(output, 'production-before.json'), 'utf8')) : await profileHashes();
if (JSON.stringify(before) !== JSON.stringify(await profileHashes())) throw new Error('Production profile changed: preserve and inspect');
if (resumeAt < 0) {
  await mkdir(path.join(output, 'shared-home'));
  const name = '小鲸电脑操作验收-' + path.basename(output).slice(-6) + '.txt';
  const original = '电脑操作验收\n销售合计：49.00\n行数：3\n审阅人：待填写\n', expected = original.replace('审阅人：待填写', '审阅人：海盐-7319');
  await writeFile(path.join(output, name), original);
  await writeFile(path.join(output, 'public-document.json'), JSON.stringify({ name, path: path.join(output, name), original, expected }, null, 2));
  await writeFile(path.join(output, 'production-before.json'), JSON.stringify(before, null, 2));
} else {
  const old = JSON.parse(await readFile(path.join(output, 'desktop-process.json'), 'utf8'));
  try { process.kill(old.appPID, 0); throw new Error('Original desktop acceptance process is still live'); } catch (error) { if (error.code !== 'ESRCH') throw error; }
  for (const name of ['desktop-ui-ready.json', 'desktop-report.json', 'desktop-process.json', 'finish-desktop-ui', 'stop-desktop-check']) await unlink(path.join(output, name)).catch(error => { if (error.code !== 'ENOENT') throw error; });
}
const alive = pid => { try { process.kill(pid, 0); return true; } catch (error) { if (error.code === 'ESRCH') return false; throw error; } };
async function waitFile(name, seconds, owner) {
  const deadline = Date.now() + seconds * 1000;
  while (Date.now() < deadline) {
    try { return JSON.parse(await readFile(path.join(output, name), 'utf8')); } catch (error) { if (error.code !== 'ENOENT' && !(error instanceof SyntaxError)) throw error; }
    if (owner && !alive(owner)) throw new Error('Actual desktop acceptance app exited before ' + name);
    await pause(250);
  }
  throw new Error('Timed out waiting for ' + name);
}
let report;
console.log(JSON.stringify({ output, live, hold, publicDocument: JSON.parse(await readFile(path.join(output, 'public-document.json'), 'utf8')).path }));
try {
  const launch = spawnSync('/usr/bin/open', ['-n', path.join(root, 'build/蓝色大肥鱼.app'), '--args', '--check', output, '--desktop-check', ...(live ? ['--live-agent'] : []), ...(hold ? ['--hold-ui'] : [])], { encoding: 'utf8' });
  if (launch.status !== 0) throw new Error(launch.stderr);
  const process = await waitFile('desktop-process.json', 30), ready = await waitFile('desktop-ui-ready.json', 30, process.appPID);
  console.log(JSON.stringify({ actualUIReady: ready }));
  report = await waitFile('desktop-report.json', live ? 2130 : 30, process.appPID);
  console.log(JSON.stringify({ success: report.success, checks: Object.keys(report.checks ?? {}).length, error: report.error }));
  if (hold && report.success) {
    const deadline = Date.now() + 1220_000;
    while (Date.now() < deadline && alive(process.appPID)) {
      try { await readFile(path.join(output, 'finish-desktop-ui')); break; } catch (error) { if (error.code !== 'ENOENT') throw error; }
      await pause(300);
    }
  }
  const tasks = await Promise.all((await readdir(path.join(output, 'profile/agent'))).filter(name => name.endsWith('.json') && name !== 'index.json').map(name => readFile(path.join(output, 'profile/agent', name), 'utf8').then(JSON.parse)));
  const fixture = JSON.parse(await readFile(path.join(output, 'public-document.json'), 'utf8'));
  report.independent = { productionProfileUnchanged: JSON.stringify(before) === JSON.stringify(await profileHashes()), actualSystemPermissionsWereReported: typeof ready.actualPermissions.accessibility === 'boolean' && typeof ready.actualPermissions.screen_recording === 'boolean' };
  if (live) {
    const task = tasks.find(task => task.id === report.live?.taskID), calls = task?.messages.flatMap(message => message.toolCalls ?? []) ?? [], receipts = task?.modelReceipts ?? [];
    report.independent.actualTextEditSavedExactDocument = await readFile(fixture.path, 'utf8') === fixture.expected;
    report.independent.documentBytesMatchNativeReadback = hash(await readFile(fixture.path)) === report.live?.documentSHA256;
    report.independent.onlyDesktopToolsWereUsed = calls.length > 0 && calls.every(call => ['desktop_status', 'desktop_windows', 'desktop_connect', 'desktop_read', 'desktop_screenshot', 'desktop_action', 'desktop_disconnect', 'load_tools', 'read_task_history', 'update_plan'].includes(call.name));
    report.independent.actualModelUsageAccounted = task?.status === 'completed' && receipts.length > 0 && task.inputTokens === receipts.reduce((n, r) => n + r.inputTokens, 0) && task.outputTokens === receipts.reduce((n, r) => n + r.outputTokens, 0);
  } else report.independent.noModelRequests = tasks.every(task => !(task.modelReceipts ?? []).length);
  report.success &&= Object.values(report.independent).every(Boolean);
} catch (error) { report = { ...(report ?? {}), success: false, error: error.message }; }
finally {
  if (!report?.success) await writeFile(path.join(output, 'stop-desktop-check'), 'driver stopped; preserve the original actual task\n');
  await writeFile(path.join(output, 'finish-desktop-ui'), 'finished\n');
  const owner = await readFile(path.join(output, 'desktop-process.json'), 'utf8').then(JSON.parse).catch(() => null);
  for (let n = 0; owner && n < 50 && alive(owner.appPID); n++) await pause(100);
  await writeFile(path.join(output, 'desktop-driver-report.json'), JSON.stringify(report, null, 2) + '\n');
  const archive = path.join(root, 'evidence/agent', path.basename(output).replace('bluefatfish-', '') + '-' + new Date().toISOString().replace(/[:.]/g, '-'));
  await mkdir(path.dirname(archive), { recursive: true }); await cp(output, archive, { recursive: true, verbatimSymlinks: true });
  console.log(JSON.stringify({ success: report?.success, output, archive, error: report?.error }));
}
if (!report?.success) process.exitCode = 1;

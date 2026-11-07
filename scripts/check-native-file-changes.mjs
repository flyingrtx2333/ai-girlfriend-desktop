import { spawnSync } from 'node:child_process';
import { cp, chmod, mkdir, mkdtemp, readFile, readdir, realpath, rename, unlink, lstat, symlink, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import os from 'node:os';
import path from 'node:path';

const root = fileURLToPath(new URL('../', import.meta.url)), resumeAt = process.argv.indexOf('--resume');
const resume = resumeAt >= 0, output = resume ? path.resolve(process.argv[resumeAt + 1] ?? '') : await mkdtemp(path.join(os.tmpdir(), 'bluefatfish-file-changes-'));
const resumeStamp = new Date().toISOString().replace(/[:.]/g, '-');
if (resume && !path.basename(output).startsWith('bluefatfish-file-changes-')) throw new Error('Resume requires an actual file-change acceptance directory');
const initialArchive = path.join(root, 'evidence/agent', path.basename(output).replace('bluefatfish-', ''));
const repo = path.join(output, 'repo'), live = process.argv.includes('--live-agent'), hold = process.argv.includes('--hold-ui');
const serverRoot = path.join(os.homedir(), 'Library/Caches/bluefatfish-mcp-real/node_modules/@modelcontextprotocol/server-filesystem');
const serverEntry = path.join(serverRoot, 'dist/index.js'), serverVersion = JSON.parse(await readFile(path.join(serverRoot, 'package.json'), 'utf8')).version;
const hash = data => createHash('sha256').update(data).digest('hex'), pause = ms => new Promise(resolve => setTimeout(resolve, ms));
const production = path.join(os.homedir(), 'Library/Application Support/BlueFatFish');
const profileNames = ['settings.json', 'history.json', 'agent/index.json', 'agent/A7A38353-CBA2-431C-84F1-4903E73EA373.json', 'automations/definitions.json', 'models/catalog.json', 'extensions/mcp.json', 'extensions/hooks.json', 'extensions/hook-settings.json', 'worktrees/policy.json', 'worktrees/history.json', 'worktrees/scheduler.lock'];
async function profileHashes() { return Object.fromEntries(await Promise.all(profileNames.map(async name => [name, await readFile(path.join(production, name)).then(hash).catch(error => { if (error.code === 'ENOENT') return null; throw error; })]))); }
const before = resume ? JSON.parse(await readFile(path.join(output, 'production-before.json'), 'utf8')) : await profileHashes();
if (resume) { if (JSON.stringify(before) !== JSON.stringify(await profileHashes())) throw new Error('Production profile changed since the original run; preserve and inspect'); }
else { await writeFile(path.join(output, 'production-before.json'), JSON.stringify(before, null, 2)); await mkdir(repo); await mkdir(path.join(output, 'shared-home')); await mkdir(path.join(output, 'tmp')); }
const baseline = {
  'public.txt': 'head-public\n', 'remove.txt': 'restore-deleted-public\n', 'rename.txt': 'rename-public\n', 'kind-change': 'original-file-kind\n',
  'executable.sh': '#!/bin/sh\nprintf original\\n\n', 'mode-only.sh': '#!/bin/sh\nprintf mode\\n\n',
  'user-only.txt': 'head-user-only\n', '.gitignore': 'ignored.txt\n', 'interrupt.txt': 'original-before-interrupt\n',
  'mcp-note.json': JSON.stringify({ draft: 'user-public-note', reviewer: 'public-reviewer' }) + '\n',
  'sales.csv': 'item,amount\nA,19.90\nB,20.00\nC,9.10\n',
};
if (!resume) for (const [name, data] of Object.entries(baseline)) await writeFile(path.join(repo, name), data);
if (!resume) { await chmod(path.join(repo, 'executable.sh'), 0o755); await chmod(path.join(repo, 'mode-only.sh'), 0o644); }
const portrait = await readFile(path.join(root, 'public/portraits/whale-maid/character.png'));
if (!resume) { await writeFile(path.join(repo, 'binary.bin'), Buffer.concat(Array.from({ length: Math.ceil(6_000_000 / portrait.length) }, () => portrait)).subarray(0, 6_000_000)); await writeFile(path.join(output, 'outside.txt'), 'public-outside-never-read-marker\n'); await symlink(path.join(output, 'outside.txt'), path.join(repo, 'external-link')); }
const gitPath = spawnSync('/usr/bin/xcrun', ['--find', 'git'], { encoding: 'utf8' }).stdout.trim();
const git = args => { const result = spawnSync(gitPath, ['-C', repo, '-c', 'core.hooksPath=/dev/null', '-c', 'commit.gpgsign=false', ...args], { encoding: 'utf8', env: { PATH: '/usr/bin:/bin:/opt/homebrew/bin', HOME: os.homedir(), GIT_CONFIG_GLOBAL: '/dev/null', GIT_CONFIG_SYSTEM: '/dev/null', GIT_OPTIONAL_LOCKS: '0' } }); if (result.status !== 0) throw new Error(result.stderr); return result.stdout; };
if (!resume) {
git(['init', '-b', 'main']); git(['config', 'user.name', 'Public File Acceptance']); git(['config', 'user.email', 'public-check@example.invalid']); git(['add', '--all']); git(['commit', '-m', 'Public file change acceptance']);
await writeFile(path.join(repo, 'public.txt'), 'staged-public\n'); await writeFile(path.join(repo, 'user-only.txt'), 'other-staged-public\n'); git(['add', 'public.txt', 'user-only.txt']);
await writeFile(path.join(repo, 'public.txt'), 'user-working\n'); await writeFile(path.join(repo, 'user-only.txt'), 'user-only-working\n');
await writeFile(path.join(repo, '.env'), 'public-protected-not-a-credential\n'); await writeFile(path.join(repo, 'ignored.txt'), 'public-ignored-build-marker\n');
await writeFile(path.join(output, 'fixtures.json'), JSON.stringify({ node: process.execPath, serverEntry, serverVersion }, null, 2));
}
const mainHead = resume ? (await readFile(path.join(initialArchive, 'repo/.git/refs/heads/main'), 'utf8')).trim() : git(['rev-parse', 'HEAD']).trim();
const mainIndex = hash(await readFile(path.join(resume ? path.join(initialArchive, 'repo') : repo, '.git/index')));
const inputs = Object.fromEntries(await Promise.all(['sales.csv', 'user-only.txt', '.env', 'ignored.txt', 'binary.bin'].map(async name => [name, hash(await readFile(path.join(resume ? path.join(initialArchive, 'repo') : repo, name)))])));
const app = path.join(root, 'build/蓝色大肥鱼.app');
function launch(args) { const result = spawnSync('/usr/bin/open', ['-n', app, '--args', '--check', output, '--file-change-check', ...args], { encoding: 'utf8' }); if (result.status !== 0) throw new Error(result.stderr); }
const alive = pid => { try { process.kill(pid, 0); return true; } catch (error) { if (error.code === 'ESRCH') return false; throw error; } };
async function until(seconds, fn) { const deadline = Date.now() + seconds * 1000; while (Date.now() < deadline) { const value = await fn(); if (value) return value; await pause(100); } throw new Error('Actual process/report did not reach the expected state: ' + output); }
async function reportFile(name, seconds) { return until(seconds, async () => { try { return JSON.parse(await readFile(path.join(output, name), 'utf8')); } catch (error) { if (error.code !== 'ENOENT' && !(error instanceof SyntaxError)) throw error; return null; } }); }
const taskFile = id => path.join(output, 'profile/agent', id + '.json');
const taskRecords = async () => Promise.all((await readdir(path.join(output, 'profile/agent'))).filter(name => name.endsWith('.json') && name !== 'index.json').map(name => readFile(path.join(output, 'profile/agent', name), 'utf8').then(JSON.parse)));
const usage = tasks => tasks.filter(t => (t.modelReceipts ?? []).length).map(t => ({ id: t.id, receipts: t.modelReceipts, input: t.inputTokens, output: t.outputTokens })).sort((a, b) => a.id.localeCompare(b.id));
let report;
console.log(JSON.stringify({ output, live, hold, resume, officialServerVersion: serverVersion }));
try {
  if (!resume) {
  launch(['--capture-interrupt']); const owner = await reportFile('interruption-owner.json', 30);
  const commandPID = await until(30, async () => { try { const value = Number((await readFile(path.join(repo, 'interruption-process.pid'), 'utf8')).trim()); const task = JSON.parse(await readFile(taskFile(owner.taskID), 'utf8')); return Number.isInteger(value) && value > 1 && task.pendingFileCapture ? value : null; } catch { return null; } });
  const args = spawnSync('/bin/ps', ['-p', String(owner.appPID), '-o', 'args='], { encoding: 'utf8' }).stdout;
  if (!alive(owner.appPID) || !args.includes(output) || !args.includes('--capture-interrupt') || !alive(commandPID)) throw new Error('Interruption owner is not the actual isolated app/command');
  process.kill(owner.appPID, 'SIGKILL'); try { process.kill(-commandPID, 'SIGKILL'); } catch (error) { if (error.code !== 'ESRCH') throw error; }
  await until(10, () => !alive(owner.appPID) && !alive(commandPID));
  await writeFile(path.join(output, 'actual-interruption.json'), JSON.stringify({ appPID: owner.appPID, commandPID, appExited: true, ownedCommandExited: true, taskID: owner.taskID }, null, 2));
  launch(['--capture-recover']); const recovered = await reportFile('interruption-report.json', 30); if (!recovered.success || recovered.recoveryAppPID === owner.appPID) throw new Error('Actual interrupted task did not recover without replay');
  await until(10, () => !alive(recovered.recoveryAppPID));
  } else {
    const previous = JSON.parse(await readFile(path.join(output, 'file-change-report.json'), 'utf8')), owner = JSON.parse(await readFile(path.join(output, 'check-process.json'), 'utf8'));
    if (alive(owner.appPID) || previous.success || !Object.values(previous.checks ?? {}).length || !Object.values(previous.checks).every(Boolean)) throw new Error('The original isolated run is not terminal with all native checks passed');
    const originalReportExists = await lstat(path.join(output, 'original-verifier-report.json')).then(() => true).catch(error => { if (error.code === 'ENOENT') return false; throw error; });
    await rename(path.join(output, 'file-change-report.json'), path.join(output, originalReportExists ? 'verifier-stop-' + resumeStamp + '.json' : 'original-verifier-report.json'));
    await unlink(path.join(output, 'finish-ui')).catch(error => { if (error.code !== 'ENOENT') throw error; });
  }
  launch([...(live ? ['--live-agent'] : []), ...(hold ? ['--hold-ui'] : []), ...(resume ? ['--resume-file-change-check'] : [])]);
  report = await reportFile('file-change-report.json', live ? 420 : 120);
  await writeFile(path.join(output, 'native-check-report.json'), JSON.stringify(report, null, 2) + '\n');
  console.log(JSON.stringify({ nativeSuccess: report.success, checks: Object.keys(report.checks ?? {}).length, failed: Object.entries(report.checks ?? {}).filter(([, value]) => !value).map(([name]) => name), error: report.error }));
  if (report.success) {
    const previousUsage = usage(await taskRecords()), initialTask = JSON.parse(await readFile(taskFile(report.ui.taskID), 'utf8'));
    const change = initialTask.changes.find(c => c.id === report.ui.changeID);
    const checkpointRoot = await realpath(path.join(output, 'profile/agent', report.ui.taskID, 'checkpoints'));
    if (!change?.backup || !(await realpath(change.backup)).startsWith(checkpointRoot + path.sep) || hash(await readFile(change.backup)) !== report.ui.beforeSHA256) throw new Error('MCP checkpoint does not contain the actual existing note');
    if (hold) { const deadline = Date.now() + 1220_000; while (Date.now() < deadline) { try { await readFile(path.join(output, 'finish-ui')); break; } catch {} await pause(500); } }
    const tasks = await taskRecords(), task = tasks.find(t => t.id === report.ui.taskID);
    report.independent = {
      actualMainHeadUnchanged: git(['rev-parse', 'HEAD']).trim() === mainHead && mainHead === report.mainHead,
      actualRawIndexUnchanged: hash(await readFile(path.join(repo, '.git/index'))) === mainIndex && mainIndex === report.mainIndexSHA256,
      actualInputsAndOtherStagedFilePreserved: (await Promise.all(Object.entries(inputs).map(async ([name, digest]) => hash(await readFile(path.join(repo, name))) === digest))).every(Boolean),
      actualExistingMcpNoteBackedUpExactly: hash(await readFile(change.backup)) === hash(Buffer.from(baseline['mcp-note.json'])),
      uiAddedNoModelRequests: JSON.stringify(previousUsage) === JSON.stringify(usage(tasks)),
    };
    if (hold) {
      report.independent.actualUiRollbackRestoresOriginalUserNote = hash(await readFile(path.join(repo, 'mcp-note.json'))) === report.ui.beforeSHA256 && task.changes.find(c => c.id === report.ui.changeID)?.restoredAt !== undefined;
    }
    if (live) {
      const rows = (await readFile(path.join(repo, 'sales.csv'), 'utf8')).trim().split('\n').slice(1), cents = rows.reduce((n, row) => n + Math.round(Number(row.split(',')[1]) * 100), 0);
      const terminalBytes = await readFile(path.join(repo, 'terminal-report.json')), terminal = JSON.parse(terminalBytes);
      const calls = task.messages.flatMap(m => m.toolCalls ?? []), receipts = task.modelReceipts ?? [];
      report.independent.actualModelTerminalReportMatchesIndependentCsvSum = Object.keys(terminal).length === 2 && Math.round(terminal.total * 100) === cents && terminal.rows === rows.length && hash(terminalBytes) === report.live.terminalSHA256;
      const canonical = value => JSON.stringify(value, (_, data) => data && typeof data === 'object' && !Array.isArray(data) ? Object.fromEntries(Object.entries(data).sort(([a], [b]) => a.localeCompare(b))) : data);
      const external = c => { const args = JSON.parse(c.arguments); if (c.name === 'call_mcp_tool') return args; const route = report.live.toolRoutes?.[c.id]; return route?.function === c.name && canonical(route.arguments) === canonical(args) ? route : null; };
      const completed = call => task.events.some(event => event.toolCallID === call.id && event.status === 'completed');
      report.independent.actualModelUsesBothToolKinds = calls.some(c => c.name === 'run_command' && completed(c)) && calls.some(c => external(c)?.tool === 'write_file' && completed(c)) && !calls.some(c => ['write_file', 'edit_file', 'git_commit', 'git_push', 'web_search', 'fetch_url'].includes(c.name) && completed(c));
      report.independent.actualOutOfScopeCommandsWereRejected = (report.live.rejectedCalls ?? []).every(id => task.approvals.some(a => a.call.id === id && a.decision === 'deny') && task.events.some(event => event.toolCallID === id && event.status === 'failed'));
      report.independent.actualModelUsageAccounted = task.inputTokens === receipts.reduce((n, r) => n + r.inputTokens, 0) && task.outputTokens === receipts.reduce((n, r) => n + r.outputTokens, 0) && task.status === 'completed';
      if (resume) {
        const originalTask = JSON.parse(await readFile(path.join(initialArchive, 'profile/agent', task.id + '.json'), 'utf8'));
        const originalReceipts = originalTask.modelReceipts ?? [], intent = t => t.messages.filter(m => m.role === 'user' && m.nativeContext !== true).at(-1)?.id;
        report.independent.sameActualTaskIntentAndReceiptPrefixSurviveRestart = originalTask.id === task.id && intent(originalTask) === intent(task) && canonical(receipts.slice(0, originalReceipts.length)) === canonical(originalReceipts);
      }
      const afterObject = await readFile(path.join(output, 'profile/agent', task.id, 'checkpoints/objects', report.live.mcpNoteSHA256));
      const note = JSON.parse(afterObject);
      report.independent.actualMcpWrittenNoteMatchesCsvAndReviewer = Object.keys(note).length === 3 && Math.round(note.total * 100) === cents && note.rows === rows.length && note.reviewer === '海盐-7319';
    } else report.noModelRequests = usage(tasks).length === 0;
    const objects = path.join(output, 'profile/agent', report.ui.taskID, 'checkpoints/objects');
    report.independent.actualCheckpointFilesArePrivate = (await Promise.all((await readdir(objects)).map(async name => ((await lstat(path.join(objects, name))).mode & 0o777) === 0o600))).every(Boolean);
    report.productionAfter = await profileHashes(); report.productionProfileUnchanged = JSON.stringify(before) === JSON.stringify(report.productionAfter);
    report.success &&= Object.values(report.independent).every(Boolean) && report.productionProfileUnchanged && (live || report.noModelRequests);
  }
} catch (error) { report = { ...(report ?? {}), success: false, error: error.message }; }
finally {
  await writeFile(path.join(output, 'finish-ui'), 'finished\n');
  try {
    const owner = JSON.parse(await readFile(path.join(output, 'check-process.json'), 'utf8'));
    for (let n = 0; n < 30 && alive(owner.appPID); n++) await pause(100);
    if (alive(owner.appPID)) {
      const command = spawnSync('/bin/ps', ['-p', String(owner.appPID), '-o', 'args='], { encoding: 'utf8' }).stdout;
      if (!command.includes(output) || !command.includes('--file-change-check')) throw new Error('Cleanup refused an unrelated process');
      const rows = spawnSync('/bin/ps', ['-axo', 'pid=,ppid='], { encoding: 'utf8' }).stdout.trim().split('\n').map(line => line.trim().split(/\s+/).map(Number));
      const owned = new Set([owner.appPID]); for (let n = 0; n < 16; n++) for (const [pid, parent] of rows) if (owned.has(parent)) owned.add(pid);
      for (const pid of [...owned].reverse()) { try { process.kill(pid, 'SIGTERM'); } catch (error) { if (error.code !== 'ESRCH') throw error; } }
      await pause(500);
      for (const pid of owned) if (alive(pid)) { try { process.kill(pid, 'SIGKILL'); } catch (error) { if (error.code !== 'ESRCH') throw error; } }
      await writeFile(path.join(output, 'bounded-check-cleanup.json'), JSON.stringify({ appPID: owner.appPID, ownedPIDs: [...owned], productionAppExcluded: true }, null, 2));
    }
  } catch (error) { if (error.code !== 'ENOENT') { report.success = false; report.cleanupError = error.message; } }
  await writeFile(path.join(output, 'file-change-report.json'), JSON.stringify(report, null, 2) + '\n');
  const archive = path.join(root, 'evidence/agent', path.basename(output).replace('bluefatfish-', '') + (resume ? '-resumed-' + resumeStamp : '')); await mkdir(path.dirname(archive), { recursive: true }); await cp(output, archive, { recursive: true, verbatimSymlinks: true });
  console.log(JSON.stringify({ success: report?.success, output, archive, independent: report?.independent, error: report?.error }));
}
if (!report?.success) process.exitCode = 1;

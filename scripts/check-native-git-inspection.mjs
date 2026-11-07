import { spawnSync } from 'node:child_process';
import { cp, mkdir, mkdtemp, readFile, readdir, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import os from 'node:os';
import path from 'node:path';

const root = fileURLToPath(new URL('../', import.meta.url));
const output = await mkdtemp(path.join(os.tmpdir(), 'bluefatfish-git-inspection-'));
await mkdir(path.join(output, 'shared-home'), { recursive: true });
const hash = data => createHash('sha256').update(data).digest('hex');
const profile = path.join(os.homedir(), 'Library/Application Support/BlueFatFish');
const names = ['settings.json', 'history.json', 'agent/index.json', 'agent/A7A38353-CBA2-431C-84F1-4903E73EA373.json', 'automations/definitions.json', 'models/catalog.json', 'extensions/mcp.json', 'extensions/hooks.json', 'extensions/hook-settings.json'];
const hashes = () => Promise.all(names.map(async name => [name, await readFile(path.join(profile, name)).then(hash).catch(error => { if (error.code === 'ENOENT') return null; throw error; })])).then(Object.fromEntries);
const before = await hashes(); await writeFile(path.join(output, 'production-before.json'), JSON.stringify(before, null, 2));
const hold = process.argv.includes('--hold-ui'), sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
console.log(JSON.stringify({ output, hold }));
try {
  const launch = spawnSync('/usr/bin/open', ['-n', path.join(root, 'build/蓝色大肥鱼.app'), '--args', '--check', output, '--git-inspection-check', ...(hold ? ['--hold-ui'] : [])], { encoding: 'utf8' });
  if (launch.status !== 0) throw new Error(launch.stderr || 'Git review check did not launch');
  let report;
  const deadline = Date.now() + 120_000;
  while (Date.now() < deadline) { try { report = JSON.parse(await readFile(path.join(output, 'git-inspection-report.json'), 'utf8')); break; } catch {} await sleep(250); }
  if (!report) throw new Error('No terminal Git inspection report: ' + output);
  console.log(JSON.stringify({ success: report.success, checks: Object.keys(report.checks ?? {}).length, failed: Object.entries(report.checks ?? {}).filter(([, pass]) => !pass).map(([name]) => name), error: report.error }));
  if (hold && report.success) {
    const limit = Date.now() + 920_000;
    while (Date.now() < limit) { try { await readFile(path.join(output, 'finish-ui')); break; } catch {} await sleep(500); }
  }
  await writeFile(path.join(output, 'finish-ui'), 'finished\n');
  if (report.success) {
    const executable = spawnSync('/usr/bin/xcrun', ['--find', 'git'], { encoding: 'utf8' }).stdout.trim();
    const git = args => {
      const result = spawnSync(executable, ['-C', path.join(output, 'repo'), ...args], { encoding: 'utf8', env: { ...process.env, GIT_OPTIONAL_LOCKS: '0', GIT_TERMINAL_PROMPT: '0' } });
      if (result.status !== 0) throw new Error(result.stderr); return result.stdout;
    };
    report.independentGitReadback = {
      headPreserved: git(['rev-parse', 'HEAD']).trim() === report.head,
      otherUserStagingPreserved: git(['show', ':other.txt']) === 'other-user-staged\n',
      reviewedIndexVersion: git(['show', ':layered.txt']) === 'index-changed\n',
      workingVersionPreserved: await readFile(path.join(output, 'repo/layered.txt'), 'utf8') === 'working-version\n',
      turnVersionPreserved: await readFile(path.join(output, 'repo/turn.txt'), 'utf8') === 'turn-two\n',
    };
    const tasks = await Promise.all((await readdir(path.join(output, 'profile/agent'))).filter(name => name.endsWith('.json') && name !== 'index.json').map(async name => JSON.parse(await readFile(path.join(output, 'profile/agent', name), 'utf8'))));
    const actualTask = tasks.find(task => task.id === report.taskID);
    report.independentGitReadback.latestTurnSnapshotHasActualPriorBytes = await readFile(actualTask.gitTurn.changes[0].backup, 'utf8') === 'turn-one-final\n-- body\n++ body\n';
    report.independentGitReadback.originalRollbackSnapshotPreserved = await readFile(actualTask.changes.find(change => path.basename(change.path) === 'turn.txt').backup, 'utf8') === 'base\n';
    report.noModelRequests = tasks.every(task => !task.inputTokens && !task.outputTokens && !(task.modelReceipts ?? []).length);
    report.productionAfter = await hashes(); report.productionProfileUnchanged = JSON.stringify(before) === JSON.stringify(report.productionAfter);
    report.success &&= Object.values(report.independentGitReadback).every(Boolean) && report.noModelRequests && report.productionProfileUnchanged;
  }
  await writeFile(path.join(output, 'git-inspection-report.json'), JSON.stringify(report, null, 2) + '\n');
  const archive = path.join(root, 'evidence/agent', path.basename(output).replace('bluefatfish-', '')); await mkdir(path.dirname(archive), { recursive: true }); await cp(output, archive, { recursive: true });
  if (!report.success) throw new Error('Git inspection acceptance failed: ' + archive);
  console.log(JSON.stringify({ success: true, output, archive, independentGitReadback: true, noModelRequests: report.noModelRequests, productionProfileUnchanged: report.productionProfileUnchanged }));
} catch (error) { await writeFile(path.join(output, 'finish-ui'), 'failed\n'); throw error; }

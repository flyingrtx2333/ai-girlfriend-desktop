import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdir, mkdtemp, readFile, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { verifyNativeCandidate } from './native-signing.mjs';

const root = fileURLToPath(new URL('../', import.meta.url));
const app = process.env.BLUEFATFISH_APP;
const lifecycle = process.argv.length === 3 && process.argv[2] === '--lifecycle';
const monitor = process.argv.length === 3 && process.argv[2] === '--monitor';
if (!app || (!lifecycle && !monitor && process.argv.length !== 2)) throw Error('请指定独立验收应用，可用 --lifecycle 或 --monitor，不调用模型。');
const info = spawnSync('/usr/bin/plutil', ['-convert', 'json', '-o', '-', path.join(app, 'Contents/Info.plist')], { encoding: 'utf8' });
if (info.status !== 0 || JSON.parse(info.stdout).BlueFatFishAcceptanceOnly !== true) throw Error('工作区恢复检查只能使用独立验收应用。');
await mkdir(path.join(root, 'evidence/agent'), { recursive: true });
const output = await mkdtemp(path.join(root, 'evidence/agent', monitor ? 'monitor-recovery-command-' : 'workspace-recovery-command-'));
await mkdir(path.join(output, 'tmp'));
const monitorSources = ['README.md', 'docs/AGENT-READING.md', 'docs/AGENT-PLAN.md', 'docs/DEVELOPMENT.md',
  'docs/REPO-WIKI.md', 'docs/ROADMAP.md', 'docs/QODER-UI-SPEC.md', 'package.json'];
if (monitor) {
  if (verifyNativeCandidate(app).kind !== 'isolated-local') throw Error('任务监控恢复使用独立本地签名包。');
  await mkdir(path.join(output, 'workspace/docs'), { recursive: true, mode: 0o700 });
  for (const source of monitorSources) await writeFile(path.join(output, 'workspace', source), await readFile(path.join(root, source)), { mode: 0o600 });
}
const binary = path.join(app, 'Contents/MacOS/BlueFatFish');
const hash = async () => createHash('sha256').update(await readFile(binary)).digest('hex');
const binaryHash = await hash();
const results = [];
for (const stage of lifecycle || monitor ? ['seed', 'reopen'] : ['storage']) {
  const flags = monitor ? ['--task-monitor-check', '--task-monitor-recovery-check'] : [lifecycle ? '--workspace-recovery-lifecycle-check' : '--workspace-recovery-check'];
  const run = spawnSync(binary, ['--check', output, ...flags, ...(lifecycle || monitor ? ['--recovery-stage', stage] : [])], { encoding: 'utf8', timeout: 180000, env: { ...process.env, TMPDIR: path.join(output, 'tmp') + '/' } });
  await writeFile(path.join(output, `${stage}-stdout.log`), run.stdout ?? '');
  await writeFile(path.join(output, `${stage}-stderr.log`), run.stderr ?? '');
  await writeFile(path.join(output, `${stage}-process.json`), JSON.stringify({ app, appPID: run.pid, binaryHash, exit: run.status, signal: run.signal }, null, 2) + '\n');
  if (run.error || run.status !== 0) throw run.error ?? Error(run.stderr || '工作区恢复检查未完成');
  const bytes = await readFile(path.join(output, monitor ? 'task-monitor-report.json' : lifecycle ? 'workspace-recovery-lifecycle-report.json' : 'workspace-recovery-report.json'));
  await writeFile(path.join(output, `${stage}-report.json`), bytes);
  const report = JSON.parse(bytes);
  const sameApplication = report.appPID === run.pid && report.binaryHash === binaryHash && await hash() === binaryHash;
  const success = sameApplication && report.success === true && report.modelRequests === 0 && Object.keys(report.checks).length > 0 && Object.values(report.checks).every(Boolean);
  const result = { stage, appPID: run.pid, binaryHash, sameApplication, success, checks: Object.keys(report.checks).length, failed: Object.keys(report.checks).filter(key => !report.checks[key]), error: report.error, modelRequests: report.modelRequests };
  results.push(result);
  console.log(JSON.stringify({ output, ...result }));
  if (!success) { process.exitCode = 1; break; }
}
await writeFile(path.join(output, 'results.json'), JSON.stringify(results, null, 2) + '\n');
if (monitor && results.length === 2 && results.every(result => result.success)) {
  const read = async name => JSON.parse(await readFile(path.join(output, name), 'utf8'));
  const fixture = await read('monitor-fixture.json');
  const scope = id => path.join('profile/workspace-recovery', id);
  const first = await read(path.join(scope(fixture.primaryWindow), 'task-monitor.json'));
  const second = await read(path.join(scope(fixture.secondaryWindow), 'task-monitor.json'));
  const mainLayout = await read(path.join(scope(fixture.primaryWindow), 'layout.json'));
  const secondLayout = await read(path.join(scope(fixture.secondaryWindow), 'layout.json'));
  const draftA = await read(path.join('profile/agent', fixture.first + '.json'));
  const draftB = await read(path.join('profile/agent', fixture.other + '.json'));
  const checks = {
    distinctWindowsAndMainLayoutsKeepTheirFormat: first.windowID !== second.windowID && first.windowID === mainLayout.id &&
      second.windowID === secondLayout.id && !('monitor' in mainLayout) && !('monitor' in secondLayout),
    monitorRecordsKeepDifferentGroupsAndFrames: first.tasks[fixture.first].reading.position.row === 'plan' &&
      second.tasks[fixture.first].reading.position.row === 'outputs' && second.tasks[fixture.first].frame.width === fixture.secondary.frame.width,
    explicitHiddenTaskPersists: first.tasks[fixture.other].explicitVisibility && !first.tasks[fixture.other].visible,
    originalDraftsAndNoModelUsage: [draftA, draftB].every(task => task.draft === '保留待发送的任务输入' && !task.modelReceipts?.length),
    originalPublicFilesMatch: (await Promise.all(monitorSources.map(async source => (await readFile(path.join(root, source))).equals(await readFile(path.join(output, 'workspace', source)))))).every(Boolean),
  };
  const success = Object.values(checks).every(Boolean);
  await writeFile(path.join(output, 'independent.json'), JSON.stringify({ success, checks }, null, 2) + '\n');
  console.log(JSON.stringify({ output, success, checks }));
  if (!success) process.exitCode = 1;
}

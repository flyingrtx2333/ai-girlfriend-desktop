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
const composer = process.argv.length === 3 && process.argv[2] === '--composer';
const reopen = lifecycle || monitor || composer;
if (!app || (!reopen && process.argv.length !== 2)) throw Error('请指定独立验收应用，可用 --lifecycle、--monitor 或 --composer，不调用模型。');
const info = spawnSync('/usr/bin/plutil', ['-convert', 'json', '-o', '-', path.join(app, 'Contents/Info.plist')], { encoding: 'utf8' });
if (info.status !== 0 || JSON.parse(info.stdout).BlueFatFishAcceptanceOnly !== true) throw Error('工作区恢复检查只能使用独立验收应用。');
await mkdir(path.join(root, 'evidence/agent'), { recursive: true });
const prefix = composer ? 'composer-recovery-command-' : monitor ? 'monitor-recovery-command-' : 'workspace-recovery-command-';
const output = await mkdtemp(path.join(root, 'evidence/agent', prefix));
await mkdir(path.join(output, 'tmp'));
const monitorSources = ['README.md', 'docs/AGENT-READING.md', 'docs/AGENT-PLAN.md', 'docs/DEVELOPMENT.md',
  'docs/REPO-WIKI.md', 'docs/ROADMAP.md', 'docs/QODER-UI-SPEC.md', 'package.json'];
if (monitor) {
  if (verifyNativeCandidate(app).kind !== 'isolated-local') throw Error('任务监控恢复使用独立本地签名包。');
  await mkdir(path.join(output, 'workspace/docs'), { recursive: true, mode: 0o700 });
  for (const source of monitorSources) await writeFile(path.join(output, 'workspace', source), await readFile(path.join(root, source)), { mode: 0o600 });
}
if (composer) {
  if (verifyNativeCandidate(app).kind !== 'isolated-local') throw Error('输入区恢复使用独立本地签名包。');
  await mkdir(path.join(output, 'workspace'), { mode: 0o700 });
  const readme = await readFile(path.join(root, 'README.md'));
  await writeFile(path.join(output, 'workspace/README.md'), readme, { mode: 0o600 });
  const lines = readme.toString('utf8').split(/\r?\n/).filter(line => line && !line.startsWith('<'));
  const sample = Array.from({ length: 52 }, (_, i) => '项目说明 ' + (i + 1) + ' · ' + Array.from(lines[i % lines.length]).slice(0, 36).join(''));
  const firstPhrase = '公开文档第一处 中文😀';
  sample[13] = firstPhrase;
  sample[36] = '另一扇窗读到这里 🐋';
  const first = sample.join('\n');
  const other = ['当前磁盘与内存分别有多少？', ...sample.slice(0, 16), '无工作区问答 原选区🧭', ...sample.slice(17, 30)].join('\n');
  const replacement = '已在原选区继续修改 中文✅';
  const inputs = { first, other, beforeChange: '已有草稿的原来的选区。', afterChange: '另一处产生的新版本。保留这一份正文。', replacement,
    expected: first.replace(firstPhrase, replacement) };
  await writeFile(path.join(output, 'composer-inputs.json'), JSON.stringify(inputs, null, 2) + '\n', { mode: 0o600 });
}
const binary = path.join(app, 'Contents/MacOS/BlueFatFish');
const hash = async () => createHash('sha256').update(await readFile(binary)).digest('hex');
const binaryHash = await hash();
const results = [];
for (const stage of reopen ? ['seed', 'reopen'] : ['storage']) {
  const flags = monitor ? ['--task-monitor-check', '--task-monitor-recovery-check'] :
    [composer ? '--composer-recovery-check' : lifecycle ? '--workspace-recovery-lifecycle-check' : '--workspace-recovery-check'];
  const run = spawnSync(binary, ['--check', output, ...flags, ...(reopen ? ['--recovery-stage', stage] : [])], { encoding: 'utf8', timeout: 180000, env: { ...process.env, TMPDIR: path.join(output, 'tmp') + '/' } });
  await writeFile(path.join(output, `${stage}-stdout.log`), run.stdout ?? '');
  await writeFile(path.join(output, `${stage}-stderr.log`), run.stderr ?? '');
  await writeFile(path.join(output, `${stage}-process.json`), JSON.stringify({ app, appPID: run.pid, binaryHash, exit: run.status, signal: run.signal }, null, 2) + '\n');
  if (run.error || run.status !== 0) throw run.error ?? Error(run.stderr || '工作区恢复检查未完成');
  const bytes = await readFile(path.join(output, composer ? 'composer-report.json' : monitor ? 'task-monitor-report.json' : lifecycle ? 'workspace-recovery-lifecycle-report.json' : 'workspace-recovery-report.json'));
  await writeFile(path.join(output, `${stage}-report.json`), bytes);
  const report = JSON.parse(bytes);
  const sameApplication = report.appPID === run.pid && report.binaryHash === binaryHash && await hash() === binaryHash;
  const success = sameApplication && report.success === true && report.modelRequests === 0 && Object.keys(report.checks).length > 0 && Object.values(report.checks).every(Boolean);
  const result = { stage, appPID: run.pid, binaryHash, sameApplication, success, checks: Object.keys(report.checks).length, failed: Object.keys(report.checks).filter(key => !report.checks[key]), error: report.error, modelRequests: report.modelRequests };
  results.push(result);
  console.log(JSON.stringify({ output, ...result }));
  if (!success) { process.exitCode = 1; break; }
  if (composer && stage === 'seed') {
    const fixture = JSON.parse(await readFile(path.join(output, 'composer-fixture.json'), 'utf8'));
    for (const [name, id] of [['main', fixture.mainWindow], ['second', fixture.secondWindow]]) {
      const data = await readFile(path.join(output, 'profile/workspace-recovery', id, 'draft-viewports.json'));
      await writeFile(path.join(output, name + '-before-reopen.json'), data);
    }
  }
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
if (composer && results.length === 2 && results.every(result => result.success)) {
  const read = async name => JSON.parse(await readFile(path.join(output, name), 'utf8'));
  const fixture = await read('composer-fixture.json'), inputs = await read('composer-inputs.json');
  const main = await read('main-before-reopen.json'), second = await read('second-before-reopen.json');
  const a = main.tasks[fixture.first], b = second.tasks[fixture.first], standalone = main.tasks[fixture.other];
  const tasks = await Promise.all([fixture.first, fixture.other, fixture.changed].map(id => read(path.join('profile/agent', id + '.json'))));
  const snippet = (text, record) => text.slice(record.selections[0].location, record.selections[0].location + record.selections[0].length);
  const digest = text => createHash('sha256').update(text).digest('hex');
  const checks = {
    bothWindowsStoreDifferentSelectionsAndTheSameDraftHash: main.windowID !== second.windowID && a.hash === b.hash && a.hash === digest(inputs.first) &&
      snippet(inputs.first, a) === '公开文档第一处 中文😀' && snippet(inputs.first, b) === '另一扇窗读到这里 🐋',
    askDraftRetainsItsOwnExactSelection: standalone.hash === digest(inputs.other) && snippet(inputs.other, standalone) === '无工作区问答 原选区🧭',
    onlyTheExplicitEditChangesTheOriginalDraft: tasks[0].draft === inputs.expected && tasks[1].draft === inputs.other && tasks[2].draft === inputs.afterChange,
    publicSourceAndModelStateRemainExact: (await readFile(path.join(output, 'workspace/README.md'))).equals(await readFile(path.join(root, 'README.md'))) &&
      tasks.every(task => !task.modelReceipts?.length && !task.messages?.length),
  };
  const success = Object.values(checks).every(Boolean);
  await writeFile(path.join(output, 'independent.json'), JSON.stringify({ success, checks }, null, 2) + '\n');
  console.log(JSON.stringify({ output, success, checks }));
  if (!success) process.exitCode = 1;
}

import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { readFile, mkdir, mkdtemp, readdir, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const root = fileURLToPath(new URL('../', import.meta.url));
const evidence = path.join(root, 'evidence/agent');
const app = process.env.BLUEFATFISH_APP;
if (!app || !app.startsWith(evidence + '/')) throw Error('请指定外置盘内的独立验收应用');
const plist = spawnSync('/usr/bin/plutil', ['-extract', 'BlueFatFishAcceptanceOnly', 'raw', '-o', '-', path.join(app, 'Contents/Info.plist')], { encoding: 'utf8' });
if (plist.status !== 0 || plist.stdout.trim() !== 'true') throw Error('缺少独立验收标记');
const signature = spawnSync('/usr/bin/codesign', ['--verify', '--deep', '--strict', app], { encoding: 'utf8' });
if (signature.status !== 0) throw Error(signature.stderr);
await mkdir(evidence, { recursive: true });
const output = await mkdtemp(path.join(evidence, 'workspace-worktrees-command-'));
await mkdir(path.join(output, 'shared-home'));
const binary = path.join(app, 'Contents/MacOS/BlueFatFish');
const hash = value => createHash('sha256').update(value).digest('hex');
const binaryHash = hash(await readFile(binary));
const run = spawnSync(binary, ['--check', output, '--workspace-worktrees-check'], { encoding: 'utf8', timeout: 180_000 });
await writeFile(path.join(output, 'stdout.log'), run.stdout ?? '');
await writeFile(path.join(output, 'stderr.log'), run.stderr ?? '');
await writeFile(path.join(output, 'process.json'), JSON.stringify({ app, binaryHash, appPID: run.pid, exit: run.status, signal: run.signal }, null, 2) + '\n');
if (run.error || run.status !== 0) throw run.error ?? Error(run.stderr || run.stdout);
const report = JSON.parse(await readFile(path.join(output, 'workspace-worktrees-report.json'), 'utf8'));
if (report.appPID !== run.pid || hash(await readFile(binary)) !== binaryHash) throw Error('验收进程或程序已变化');
if (report.success) {
  const fixture = JSON.parse(await readFile(path.join(output, 'workspace-worktrees-fixtures.json'), 'utf8'));
  const executable = spawnSync('/usr/bin/xcrun', ['--find', 'git'], { encoding: 'utf8' }).stdout.trim();
  const git = (directory, args) => {
    const result = spawnSync(executable, ['-C', directory, ...args], { encoding: 'utf8', env: { PATH: '/usr/bin:/bin', GIT_CONFIG_GLOBAL: '/dev/null', GIT_CONFIG_SYSTEM: '/dev/null', GIT_OPTIONAL_LOCKS: '0' } });
    if (result.status !== 0) throw Error(result.stderr); return result.stdout;
  };
  const directory = path.join(output, 'profile/agent');
  const tasks = await Promise.all((await readdir(directory)).filter(name => name.endsWith('.json') && name !== 'index.json').map(name => readFile(path.join(directory, name), 'utf8').then(JSON.parse)));
  const child = tasks.find(task => task.id === report.createdTaskID);
  const sources = child.worktreeOrigins;
  report.independent = {
    everySourceIndexRemainsExact: (await Promise.all(fixture.sources.map(async source => hash(await readFile(path.join(source.root, '.git/index'))) === source.indexSHA256))).every(Boolean),
    everyOriginalHeadAndWorkingVersionRemainsExact: fixture.sources.every((source, index) => git(source.root, ['rev-parse', 'HEAD']).trim() === source.head) && (await Promise.all(fixture.sources.map(async (source, index) => await readFile(path.join(source.root, 'public.txt'), 'utf8') === `working-${index}\n`))).every(Boolean),
    everySourceUsesItsOwnReleaseCommit: fixture.sources.every(source => git(sources.find(origin => origin.root === source.root).path, ['rev-parse', 'HEAD']).trim() === source.release),
    bothRestoredCheckoutsRetainActualWrittenFiles: (await Promise.all(sources.map(async source => await readFile(path.join(source.path, 'native-created.txt'), 'utf8') === 'isolated write\n'))).every(Boolean),
    allCheckoutsRegisteredWithGit: sources.every(source => git(source.root, ['worktree', 'list', '--porcelain']).includes('worktree ' + source.path + '\n')),
    noModelReceiptsInAnyTask: tasks.every(task => !(task.modelReceipts?.length) && !task.inputTokens && !task.outputTokens),
  };
  report.success = Object.values(report.independent).every(Boolean);
  await writeFile(path.join(output, 'independent-report.json'), JSON.stringify(report, null, 2) + '\n');
}
const success = report.success && report.modelRequests === 0 && Object.values(report.checks).every(Boolean);
console.log(JSON.stringify({ output, binaryHash, appPID: run.pid, success, checks: Object.keys(report.checks).length, failed: Object.keys(report.checks).filter(key => !report.checks[key]), independent: report.independent, error: report.error, modelRequests: report.modelRequests }));
process.exitCode = success ? 0 : 1;

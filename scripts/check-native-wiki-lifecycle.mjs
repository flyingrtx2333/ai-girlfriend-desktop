import { spawn, spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { createWriteStream } from 'node:fs';
import { copyFile, mkdir, mkdtemp, readFile, readdir, realpath, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../', import.meta.url));
const option = name => { const i = process.argv.indexOf(name); return i < 0 ? undefined : process.argv[i + 1]; };
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
function command(file, args, cwd = root, raw = false) {
  const p = spawnSync(file, args, { cwd, encoding: raw ? undefined : 'utf8' });
  if (p.status !== 0) throw Error(p.stderr?.toString() || file);
  return p.stdout;
}
if (process.argv.includes('--live-agent')) throw Error('Wiki lifecycle acceptance does not transmit model requests');
const app = process.env.BLUEFATFISH_APP;
if (!app) throw Error('Set BLUEFATFISH_APP to an independent acceptance application');
command('/usr/bin/codesign', ['--verify', '--deep', '--strict', app]);
const metadata = JSON.parse(command('/usr/bin/plutil', ['-convert', 'json', '-o', '-', path.join(app, 'Contents/Info.plist')]));
if (metadata.BlueFatFishAcceptanceOnly !== true) throw Error('Use an acceptance-only application');
const reopen = option('--reopen'), manual = !!reopen || process.argv.includes('--manual-ui');
await mkdir(path.join(root, 'evidence/agent'), { recursive: true });
const output = reopen ? path.resolve(reopen) : await mkdtemp(path.join(root, 'evidence/agent/wiki-lifecycle-command-'));
if (!output.startsWith(path.join(root, 'evidence/agent/wiki-lifecycle-command-')) || await realpath(output) !== output) throw Error('Preserve the original acceptance directory without a symbolic link');
for (const name of ['tmp', 'shared-home', 'source', 'next-snapshot', 'third-snapshot', 'public-project']) await mkdir(path.join(output, name), { recursive: true });
const source = path.join(output, 'source/README.md'), workspace = path.join(output, 'public-project');
if (!reopen) {
  const baseSource = command('/usr/bin/git', ['rev-parse', 'bf6a50e']).trim(), currentSource = command('/usr/bin/git', ['rev-parse', 'HEAD']).trim(), inputs = {};
  for (const name of ['README.md', 'docs/REPO-WIKI.md']) {
    const before = command('/usr/bin/git', ['show', `${baseSource}:${name}`], root, true), after = command('/usr/bin/git', ['show', `${currentSource}:${name}`], root, true);
    for (const folder of ['public-project', 'next-snapshot']) await mkdir(path.dirname(path.join(output, folder, name)), { recursive: true });
    await writeFile(path.join(workspace, name), before); await writeFile(path.join(output, 'next-snapshot', name), after); inputs[name] = { before: hash(before), after: hash(after) };
  }
  await copyFile(path.join(workspace, 'README.md'), source);
  const third = command('/usr/bin/git', ['show', `${currentSource}:native/AgentWiki.swift`], root, true);
  await mkdir(path.join(output, 'third-snapshot/native'), { recursive: true }); await writeFile(path.join(output, 'third-snapshot/native/AgentWiki.swift'), third);
  const git = (...args) => command('/usr/bin/git', args, workspace);
  git('init', '-b', 'main'); git('config', 'user.name', 'BlueFatFish acceptance'); git('config', 'user.email', 'acceptance@example.invalid'); git('config', 'commit.gpgsign', 'false'); git('config', 'core.hooksPath', '/dev/null');
  await writeFile(path.join(workspace, '.git/info/exclude'), '.bluefatfish/\n.qoder/\n'); git('add', '--', 'README.md', 'docs/REPO-WIKI.md'); git('commit', '--quiet', '-m', 'Actual public source baseline');
  await writeFile(path.join(output, 'source-input.json'), JSON.stringify({ baseSource, currentSource, baseCommit: git('rev-parse', 'HEAD').trim(), inputs, thirdSHA256: hash(third) }, null, 2) + '\n');
}
const binary = path.join(app, 'Contents/MacOS/BlueFatFish'), binaryHash = hash(await readFile(binary)), phase = reopen ? `restart-${Date.now()}` : 'initial';
const args = ['--check', output, '--knowledge-page-source', source, ...(manual ? ['--manual-ui', reopen ? '--wiki-lifecycle-reopen' : '--wiki-lifecycle-fixtures'] : ['--wiki-lifecycle-check'])];
const child = spawn(binary, args, { cwd: root, env: { ...process.env, TMPDIR: path.join(output, 'tmp') + '/' }, stdio: ['ignore', 'pipe', 'pipe'] });
const finished = new Promise((resolve, reject) => { child.once('error', reject); child.once('close', (code, signal) => resolve({ code, signal })); });
const log = createWriteStream(path.join(output, `launch-${phase}.log`)); child.stdout.pipe(log, { end: false }); child.stderr.pipe(log, { end: false });
await writeFile(path.join(output, `launch-${phase}.json`), JSON.stringify({ app, appPID: child.pid, binaryHash, args }, null, 2) + '\n'); console.log(JSON.stringify({ output, appPID: child.pid, binaryHash, manual }));
const status = await finished; log.end();
const report = await readFile(path.join(output, manual ? `manual-ui-result-${child.pid}.json` : 'wiki-lifecycle-report.json'), 'utf8').then(JSON.parse).catch(async error => {
  if (error.code !== 'ENOENT' || !manual) throw error;
  return JSON.parse(await readFile(path.join(output, `manual-ui-error-${child.pid}.json`), 'utf8'));
});
const fixture = await readFile(path.join(output, 'wiki-lifecycle-fixtures.json'), 'utf8').then(JSON.parse).catch(error => { if (error.code !== 'ENOENT') throw error; return null; });
const input = JSON.parse(await readFile(path.join(output, 'source-input.json'), 'utf8'));
const actualDiff = await readFile(path.join(output, 'initial-actual-diff.patch')).catch(error => { if (error.code !== 'ENOENT') throw error; return Buffer.alloc(0); });
const expectedDiff = fixture ? command('/usr/bin/git', ['diff', '--no-ext-diff', '--no-textconv', '--no-renames', '--no-color', '--unified=3', fixture.baseCommit, fixture.head, '--', 'README.md', 'docs/REPO-WIKI.md'], workspace, true) : Buffer.alloc(0);
const tasks = await Promise.all((await readdir(path.join(output, 'profile/agent'))).filter(n => /^[0-9a-f-]{36}\.json$/i.test(n)).map(n => readFile(path.join(output, 'profile/agent', n), 'utf8').then(JSON.parse)));
const independent = { sameApplication: report.appPID === child.pid && report.binaryHash === binaryHash && hash(await readFile(binary)) === binaryHash,
  noModelUsage: tasks.every(t => !t.inputTokens && !t.outputTokens && !(t.modelReceipts ?? []).length),
  completeDiffMatchesIndependentGit: !!fixture && actualDiff.length > 0 && actualDiff.equals(expectedDiff),
  actualSourceSnapshotsVerified: !!fixture && fixture.baseCommit === input.baseCommit && Object.entries(input.inputs).every(([name, expected]) => hash(command('/usr/bin/git', ['show', `${fixture.baseCommit}:${name}`], workspace, true)) === expected.before && hash(command('/usr/bin/git', ['show', `${fixture.head}:${name}`], workspace, true)) === expected.after),
  projectDraftRetained: !!fixture && tasks.find(t => t.id === fixture.taskID)?.draft === '项目任务未发送的草稿。',
  standaloneDraftRetained: !!fixture && tasks.find(t => t.id === fixture.standaloneID)?.draft === '无工作区任务未发送的草稿。',
  publicReadmePreserved: hash(await readFile(source)) === input.inputs['README.md'].before && hash(await readFile(path.join(workspace, 'README.md'))) === input.inputs['README.md'].after,
  actualWikiDocumentationPreserved: hash(await readFile(path.join(workspace, 'docs/REPO-WIKI.md'))) === input.inputs['docs/REPO-WIKI.md'].after };
const success = status.code === 0 && (manual || report.success === true) && Object.values(independent).every(Boolean);
await writeFile(path.join(output, `independent-${phase}.json`), JSON.stringify({ ...report, independent, status, success }, null, 2) + '\n');
console.log(JSON.stringify({ output, success, checks: Object.keys(report.checks ?? {}).length, failed: Object.keys(report.checks ?? {}).filter(k => !report.checks[k]), independent, error: report.error })); process.exitCode = success ? 0 : 1;

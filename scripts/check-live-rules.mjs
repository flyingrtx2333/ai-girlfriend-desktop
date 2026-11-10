import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdir, mkdtemp, readFile, readdir, writeFile } from 'node:fs/promises';
import { isDeepStrictEqual } from 'node:util';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import os from 'node:os';

const option = name => { const i = process.argv.indexOf(name); return i < 0 ? undefined : process.argv[i + 1]; };
const app = option('--app'), prepared = option('--directory'), prepareOnly = process.argv.includes('--prepare-only'), globOnly = process.argv.includes('--glob-only');
const maximum = globOnly ? 6 : 16, scope = globOnly ? 'rules-glob' : 'rules', stem = globOnly ? 'rules-glob-live' : 'rules-live', directoryPrefix = 'bluefatfish-' + stem + '-';
if (!prepareOnly && (!prepared || !app)) throw new Error('Use --prepare-only first; then pass --directory and the exact signed --app after separate authorization');
const root = fileURLToPath(new URL('../', import.meta.url)), output = prepared ? path.resolve(prepared) : await mkdtemp(path.join(os.tmpdir(), directoryPrefix));
if (!path.basename(output).startsWith(directoryPrefix)) throw new Error('Use an independent directory for this exact rules scope');
const hash = value => createHash('sha256').update(value).digest('hex'), pause = ms => new Promise(resolve => setTimeout(resolve, ms));
const production = path.join(os.homedir(), 'Library/Application Support/BlueFatFish');
async function dailyHashes() {
  const names = ['settings.json', 'history.json', 'organization.json', 'agent/index.json', 'extensions/agents.json', 'extensions/plugin-agent-models.json'];
  for (const name of await readdir(path.join(production, 'agent')).catch(e => { if (e.code === 'ENOENT') return []; throw e; })) if (/^[A-Fa-f0-9-]{36}\.json$/.test(name)) names.push('agent/' + name);
  const values = {}; for (const name of names) values[name] = await readFile(path.join(production, name)).then(hash).catch(e => { if (e.code === 'ENOENT') return null; throw e; }); return values;
}
if (prepareOnly) {
  if (prepared) throw new Error('Preparation creates one new directory and never overwrites an earlier one');
  await mkdir(path.join(output, 'project/docs'), { recursive: true }); await mkdir(path.join(output, 'shared-home'));
  const source = await readFile(path.join(root, 'README.md'));
  await writeFile(path.join(output, 'project/README.md'), source); await writeFile(path.join(output, 'project/docs/README.md'), source); await writeFile(path.join(output, 'project/package.json'), await readFile(path.join(root, 'package.json')));
  const inputs = {}; for (const name of ['project/README.md', 'project/docs/README.md', 'project/package.json']) inputs[name] = hash(await readFile(path.join(output, name)));
  await writeFile(path.join(output, 'input-hashes.json'), JSON.stringify(inputs, null, 2)); await writeFile(path.join(output, 'production-before.json'), JSON.stringify(await dailyHashes(), null, 2));
  console.log(JSON.stringify({ output, prepared: true, authorized: false, scope, maximumRequiresSeparateApproval: maximum })); process.exit(0);
}
const inputs = JSON.parse(await readFile(path.join(output, 'input-hashes.json'), 'utf8')), before = JSON.parse(await readFile(path.join(output, 'production-before.json'), 'utf8'));
if (!isDeepStrictEqual(before, await dailyHashes())) throw new Error('Daily profile changed since preparation; no app was launched');
for (const [name, expected] of Object.entries(inputs)) if (hash(await readFile(path.join(output, name))) !== expected) throw new Error('Prepared public input changed: ' + name);
for (const name of [stem + '-started.json', stem + '-result.json', stem + '-request-ledger.json', 'profile/agent/index.json']) if (await readFile(path.join(output, name)).then(() => true).catch(e => { if (e.code === 'ENOENT') return false; throw e; })) throw new Error('Acceptance already started; preserve the actual ledger, tasks and process rather than replaying it');
const authorization = JSON.parse(await readFile(path.join(output, stem + '-authorization.json'), 'utf8'));
if (authorization.scope !== scope || authorization.maximumRequests !== maximum || authorization.contextLimit !== 8192 || authorization.replyLimit !== 512 || authorization.model !== 'deepseek-flash' || path.resolve(authorization.directory) !== output) throw new Error('This exact scope requires separate explicit ' + maximum + '-request authorization');
const signed = spawnSync('/usr/bin/codesign', ['--verify', '--deep', '--strict', path.resolve(app)], { encoding: 'utf8' }); if (signed.status !== 0) throw new Error(signed.stderr);
const binaryHash = hash(await readFile(path.join(app, 'Contents/MacOS/BlueFatFish'))); await writeFile(path.join(output, 'run-intent.json'), JSON.stringify({ app: path.resolve(app), binaryHash, maximum, scope }, null, 2));
console.log(JSON.stringify({ output, binaryHash, maximum, scope }));
const opened = spawnSync('/usr/bin/open', ['-g', '-n', path.resolve(app), '--args', '--check', output, globOnly ? '--rules-glob-live-check' : '--rules-live-check', '--live-agent', '--background-component-check'], { encoding: 'utf8' }); if (opened.status !== 0) throw new Error(opened.stderr);
let report; const deadline = Date.now() + 1080_000;
while (Date.now() < deadline) { try { report = JSON.parse(await readFile(path.join(output, stem + '-result.json'), 'utf8')); break; } catch (e) { if (e.code !== 'ENOENT' && !(e instanceof SyntaxError)) throw e; } await pause(250); }
if (!report) throw new Error('Observation deadline reached; no restart, task replacement or ledger reset was performed');
const alive = pid => { const state = spawnSync('/bin/ps', ['-p', String(pid), '-o', 'stat='], { encoding: 'utf8' }).stdout.trim(); return state.length > 0 && !state.startsWith('Z'); };
for (let i = 0; i < 100 && alive(report.appPID); i++) await pause(100);
const ledger = await readFile(path.join(output, stem + '-request-ledger.json'), 'utf8').then(JSON.parse).catch(e => { if (e.code === 'ENOENT') return null; throw e; });
report.independent = { actualApplicationExited: !alive(report.appPID), binaryMatchesCandidate: report.binaryHash === binaryHash, dailyProfileUnchanged: isDeepStrictEqual(before, await dailyHashes()), publicSourcesUnchanged: (await Promise.all(Object.entries(inputs).map(async ([name, expected]) => hash(await readFile(path.join(output, name))) === expected))).every(Boolean), boundedLedgerMatchesActualReportedAttempts: ledger?.maximum === maximum && ledger.attempts.length === report.usedRequests && ledger.attempts.length <= maximum, noActiveJobs: report.activeJobs === false, backgroundRemainsInactive: report.activationCount === 0 && report.visibleWindowCount === 0 && report.applicationActive === false };
report.success &&= Object.values(report.independent).every(Boolean); await writeFile(path.join(output, stem + '-driver-report.json'), JSON.stringify(report, null, 2) + '\n');
console.log(JSON.stringify({ output, success: report.success, usedRequests: report.usedRequests, independent: report.independent, error: report.error, requiresIndependentAnswerReview: report.requiresIndependentAnswerReview })); if (!report.success) process.exitCode = 1;

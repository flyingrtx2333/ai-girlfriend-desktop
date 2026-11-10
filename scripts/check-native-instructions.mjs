import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdir, mkdtemp, readFile, readdir, symlink, writeFile } from 'node:fs/promises';
import { isDeepStrictEqual } from 'node:util';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import os from 'node:os';

const index = process.argv.indexOf('--app'), app = index < 0 ? null : process.argv[index + 1];
if (!app) throw new Error('Pass the exact signed candidate with --app');
const root = fileURLToPath(new URL('../', import.meta.url)), output = await mkdtemp(path.join(os.tmpdir(), 'bluefatfish-instructions-实际 '));
const hash = value => createHash('sha256').update(value).digest('hex'), pause = ms => new Promise(resolve => setTimeout(resolve, ms));
async function dailyHashes() {
  const folder = path.join(os.homedir(), 'Library/Application Support/BlueFatFish'), names = ['settings.json', 'history.json', 'organization.json', 'agent/index.json', 'extensions/agents.json'];
  for (const name of await readdir(path.join(folder, 'agent')).catch(e => { if (e.code === 'ENOENT') return []; throw e; })) if (/^[A-Fa-f0-9-]{36}\.json$/.test(name)) names.push('agent/' + name);
  const values = {}; for (const name of names) values[name] = await readFile(path.join(folder, name)).then(hash).catch(e => { if (e.code === 'ENOENT') return null; throw e; }); return values;
}
const before = await dailyHashes(), fixtures = {
  'real project/AGENTS.md': 'ROOT_INSTRUCTIONS_731\nSee @docs/guide.md. `@not-an-import.md`\n```md\n@also-not-an-import.md\n```\n',
  'real project/AGENTS.local.md': 'LOCAL_INSTRUCTIONS_832\n',
  'real project/docs/guide.md': 'PROJECT_IMPORT_933\n@../shared/conditions.md\n',
  'real project/shared/conditions.md': 'CYCLE_IMPORT_134\n@../docs/guide.md\n',
  'real project/src/AGENTS.md': 'NESTED_INSTRUCTIONS_235\n@notes.md\n',
  'real project/src/notes.md': 'NESTED_IMPORT_437\n',
  'real project/src/deep/AGENTS.local.md': 'DEEP_LOCAL_336\n',
  'shared-home/.qoder/AGENTS.md': 'QODER_INSTRUCTIONS_428\n@relative.md\n@~/public-user.md\n',
  'shared-home/.qoder/relative.md': 'USER_RELATIVE_IMPORT_529\n',
  'shared-home/public-user.md': 'USER_HOME_IMPORT_630\n',
  'external instructions.md': 'EXTERNAL_ALLOWED_639\n',
  'ancestor repo/AGENTS.md': 'REPO_PARENT_942\n',
  'ancestor repo/packages/app/AGENTS.md': 'CHILD_ROOT_740\n',
  'AGENTS.md': 'OUTSIDE_GIT_841\n',
  'sensitive project/AGENTS.md': '@.env\n',
  'sensitive project/.env': 'NEVER_LOAD_ENV_143\n'
};
for (let i = 0; i < 11; i++) fixtures['deep project/' + (i === 0 ? 'AGENTS.md' : 'depth-' + i + '.md')] = 'DEPTH_' + i + '\n' + (i < 10 ? '@depth-' + (i + 1) + '.md\n' : '');
for (const [name, text] of Object.entries(fixtures)) { const file = path.join(output, name); await mkdir(path.dirname(file), { recursive: true }); await writeFile(file, text); }
for (const directory of ['other project', 'invalid project']) await mkdir(path.join(output, directory), { recursive: true });
await writeFile(path.join(output, 'invalid project/AGENTS.md'), Buffer.from([0xff, 0xfe, 0x81]));
const source = await readFile(path.join(root, 'native/AgentMemory.swift')); await writeFile(path.join(output, 'real project/src/deep/source.swift'), source);
await symlink(path.join(output, 'external instructions.md'), path.join(output, 'real project/src/linked.swift'));
for (const directory of ['real project', 'ancestor repo']) { const initialized = spawnSync('/usr/bin/git', ['init', '-q', path.join(output, directory)], { encoding: 'utf8' }); if (initialized.status !== 0) throw new Error(initialized.stderr); }
const inputs = {}; for (const name of [...Object.keys(fixtures), 'invalid project/AGENTS.md', 'real project/src/deep/source.swift']) inputs[name] = hash(await readFile(path.join(output, name)));
await writeFile(path.join(output, 'input-hashes.json'), JSON.stringify(inputs, null, 2)); await writeFile(path.join(output, 'production-before.json'), JSON.stringify(before, null, 2));
const signed = spawnSync('/usr/bin/codesign', ['--verify', '--deep', '--strict', path.resolve(app)], { encoding: 'utf8' }); if (signed.status !== 0) throw new Error(signed.stderr);
const binaryHash = hash(await readFile(path.join(app, 'Contents/MacOS/BlueFatFish'))); console.log(JSON.stringify({ output, binaryHash, modelTransmission: 'blocked' }));
const opened = spawnSync('/usr/bin/open', ['-g', '-n', path.resolve(app), '--args', '--check', output, '--instruction-check', '--background-component-check'], { encoding: 'utf8' }); if (opened.status !== 0) throw new Error(opened.stderr);
let report; const deadline = Date.now() + 120_000;
while (Date.now() < deadline) { try { report = JSON.parse(await readFile(path.join(output, 'instruction-result.json'), 'utf8')); break; } catch (e) { if (e.code !== 'ENOENT' && !(e instanceof SyntaxError)) throw e; } await pause(150); }
if (!report) throw new Error('Observation deadline reached; retain this process and directory without replay');
const alive = pid => { const state = spawnSync('/bin/ps', ['-p', String(pid), '-o', 'stat='], { encoding: 'utf8' }).stdout.trim(); return state.length > 0 && !state.startsWith('Z'); };
for (let i = 0; i < 100 && alive(report.appPID); i++) await pause(100);
report.independent = { actualApplicationExited: !alive(report.appPID), binaryMatchesCandidate: report.binaryHash === binaryHash, dailyProfileUnchanged: isDeepStrictEqual(before, await dailyHashes()), actualSourceHashMatches: report.sourceHash === inputs['real project/src/deep/source.swift'], allUneditedInputsKeepExactBytes: (await Promise.all(Object.entries(inputs).filter(([name]) => name !== 'real project/AGENTS.local.md').map(async ([name, h]) => hash(await readFile(path.join(output, name))) === h))).every(Boolean), savedLocalInstructionsMatchExpectedBytes: hash(await readFile(path.join(output, 'real project/AGENTS.local.md'))) === hash(fixtures['real project/AGENTS.local.md'] + '\nSAVED_LOCAL_244\n'), noModelOrActiveJobs: report.blockedModelAttempts === 0 && report.activeJobs === false, backgroundRemainsInactive: report.activationCount === 0 && report.applicationActive === false && report.visibleWindowCount === 0 };
report.success &&= Object.values(report.independent).every(Boolean); await writeFile(path.join(output, 'instruction-driver-report.json'), JSON.stringify(report, null, 2) + '\n');
console.log(JSON.stringify({ output, success: report.success, checks: Object.keys(report.checks ?? {}).length, failed: Object.entries(report.checks ?? {}).filter(([, value]) => !value).map(([name]) => name), independent: report.independent, error: report.error })); if (!report.success) process.exitCode = 1;

import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdir, mkdtemp, readFile, readdir, readlink, symlink, writeFile } from 'node:fs/promises';
import { isDeepStrictEqual } from 'node:util';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import os from 'node:os';

const option = name => { const i = process.argv.indexOf(name); return i < 0 ? undefined : process.argv[i + 1]; };
const app = option('--app'); if (!app) throw new Error('Pass the exact signed candidate with --app');
const root = fileURLToPath(new URL('../', import.meta.url)), output = await mkdtemp(path.join(os.tmpdir(), 'bluefatfish-local-rules-规则 '));
const hash = value => createHash('sha256').update(value).digest('hex'), pause = ms => new Promise(resolve => setTimeout(resolve, ms));
const production = path.join(os.homedir(), 'Library/Application Support/BlueFatFish');
async function dailyHashes() {
  const names = ['settings.json', 'history.json', 'organization.json', 'agent/index.json', 'extensions/agents.json', 'extensions/hooks.json', 'extensions/hook-settings.json'];
  for (const name of await readdir(path.join(production, 'agent')).catch(e => { if (e.code === 'ENOENT') return []; throw e; })) if (/^[A-Fa-f0-9-]{36}\.json$/.test(name)) names.push('agent/' + name);
  const result = {};
  for (const name of names) result[name] = await readFile(path.join(production, name)).then(hash).catch(e => { if (e.code === 'ENOENT') return null; throw e; });
  async function walk(folder, prefix) { for (const item of await readdir(folder, { withFileTypes: true }).catch(e => { if (e.code === 'ENOENT') return []; throw e; })) { const file = path.join(folder, item.name), key = prefix + '/' + item.name; if (item.isSymbolicLink()) result[key] = 'link:' + await readlink(file); else if (item.isDirectory()) await walk(file, key); else result[key] = hash(await readFile(file)); } }
  await walk(path.join(production, 'extensions/plugins'), 'extensions/plugins'); await walk(path.join(production, 'extensions/plugin-hooks'), 'extensions/plugin-hooks'); return result;
}
const before = await dailyHashes();
for (const folder of ['real project/src/deep', 'real project/src/vendor', 'real project/edit', 'real project/.qoder/rules', 'real project/src/.qoder/rules', 'real project/src/.bluefatfish/rules', 'other project', 'linked project', 'shared-home/.qoder/rules', '.qoder/rules', 'external-rules/rules']) await mkdir(path.join(output, folder), { recursive: true });
const source = await readFile(path.join(root, 'README.md'));
await writeFile(path.join(output, 'public-readme.md'), source); await writeFile(path.join(output, 'real project/src/deep/api.ts'), source); await writeFile(path.join(output, 'real project/src/vendor/excluded.ts'), source); await writeFile(path.join(output, 'external.md'), source);
await writeFile(path.join(output, 'real project/edit/review.md'), 'Acceptance before 3827\n'); await writeFile(path.join(output, 'node-path.txt'), process.execPath);
await writeFile(path.join(output, 'shared-home/.qoder/rules/user.md'), 'QODER_USER_319\n'); await writeFile(path.join(output, 'real project/.qoder/rules/project.md'), 'QODER_PROJECT_418\n'); await writeFile(path.join(output, 'real project/src/.bluefatfish/rules/nested.md'), 'NESTED_NATIVE_617\n'); await writeFile(path.join(output, 'real project/src/.qoder/rules/nested.md'), 'NESTED_QODER_716\n');
await writeFile(path.join(output, 'real project/src/.qoder/rules/source.md'), '---\ntrigger: glob\npaths: ["**/*.ts"]\n---\n\nNESTED_GLOB_914\n'); await writeFile(path.join(output, '.qoder/rules/parent.md'), 'RULE_PARENT_OUTSIDE_815\n'); await writeFile(path.join(output, 'external-rules/rules/outside.md'), 'OUTSIDE_SYMLINK_RULE_112\n');
await symlink(path.join(output, 'external.md'), path.join(output, 'real project/src/linked.ts')); await symlink(path.join(output, 'external-rules'), path.join(output, 'linked project/.qoder'));
await writeFile(path.join(output, 'real project/slow.cjs'), "const fs=require('node:fs'),cp=require('node:child_process');const child=cp.spawn('/bin/sleep',['30'],{stdio:'ignore'});fs.writeFileSync('slow-pids.json',JSON.stringify({pid:process.pid,child:child.pid}));setTimeout(()=>console.log('finished actual process'),30000);\n");
const made = spawnSync(process.env.BLUEFATFISH_CHECK_PYTHON || '/opt/homebrew/bin/python3', ['-c', 'import json,pathlib,sys,zipfile\np=pathlib.Path(sys.argv[1])\nwith zipfile.ZipFile(p/"limit-rules.zip","w",zipfile.ZIP_DEFLATED) as z:\n z.writestr(".qoder-plugin/plugin.json",json.dumps({"name":"limit-rules","version":"1.0.0"}))\n z.writestr("rules/limit.md","A"*60000)\n', output], { encoding: 'utf8' }); if (made.status !== 0) throw new Error(made.stderr || 'Actual rules ZIP preparation failed');
const preserved = ['public-readme.md', 'real project/src/deep/api.ts', 'real project/src/vendor/excluded.ts', 'external.md', 'shared-home/.qoder/rules/user.md', 'real project/.qoder/rules/project.md', 'real project/src/.bluefatfish/rules/nested.md', 'real project/src/.qoder/rules/nested.md', 'real project/src/.qoder/rules/source.md', '.qoder/rules/parent.md', 'external-rules/rules/outside.md', 'limit-rules.zip'];
const inputs = {}; for (const name of preserved) inputs[name] = hash(await readFile(path.join(output, name)));
await writeFile(path.join(output, 'input-hashes.json'), JSON.stringify(inputs, null, 2)); await writeFile(path.join(output, 'production-before.json'), JSON.stringify(before, null, 2));
const signed = spawnSync('/usr/bin/codesign', ['--verify', '--deep', '--strict', path.resolve(app)], { encoding: 'utf8' }); if (signed.status !== 0) throw new Error(signed.stderr);
const binaryHash = hash(await readFile(path.join(app, 'Contents/MacOS/BlueFatFish'))); console.log(JSON.stringify({ output, app: path.resolve(app), binaryHash, modelTransmission: 'blocked' }));
const opened = spawnSync('/usr/bin/open', ['-g', '-n', path.resolve(app), '--args', '--check', output, '--local-rule-check', '--background-component-check'], { encoding: 'utf8' }); if (opened.status !== 0) throw new Error(opened.stderr);
let report; const deadline = Date.now() + 180_000;
while (Date.now() < deadline) { try { report = JSON.parse(await readFile(path.join(output, 'local-rule-result.json'), 'utf8')); break; } catch (e) { if (e.code !== 'ENOENT' && !(e instanceof SyntaxError)) throw e; } await pause(150); }
if (!report) throw new Error('Native observation deadline reached; no restart or record replacement was performed');
const alive = pid => { const state = spawnSync('/bin/ps', ['-p', String(pid), '-o', 'stat='], { encoding: 'utf8' }).stdout.trim(); return state.length > 0 && !state.startsWith('Z'); };
for (let i = 0; i < 100 && alive(report.appPID); i++) await pause(100);
report.independent = { actualApplicationExited: !alive(report.appPID), actualCancelledProcessesExited: report.actualCancelledPIDs?.length === 2 && report.actualCancelledPIDs.every(pid => !alive(pid)), binaryMatchesCandidate: report.binaryHash === binaryHash, dailyProfileUnchanged: isDeepStrictEqual(before, await dailyHashes()), actualPublicAndCompatibilityInputsUnchanged: (await Promise.all(Object.entries(inputs).map(async ([name, h]) => hash(await readFile(path.join(output, name))) === h))).every(Boolean), actualPublicReadHashMatches: report.sourceHash === inputs['real project/src/deep/api.ts'], noModelOrActiveJob: report.blockedModelAttempts === 0 && report.activeJobs === false, backgroundRemainsInactive: report.activationCount === 0 && report.applicationActive === false && report.visibleWindowCount === 0 };
report.success &&= Object.values(report.independent).every(Boolean); await writeFile(path.join(output, 'local-rule-driver-report.json'), JSON.stringify(report, null, 2) + '\n'); console.log(JSON.stringify({ output, success: report.success, checks: Object.keys(report.checks ?? {}).length, independent: report.independent, failed: Object.entries(report.checks ?? {}).filter(([,v]) => !v).map(([k]) => k), error: report.error })); if (!report.success) process.exitCode = 1;

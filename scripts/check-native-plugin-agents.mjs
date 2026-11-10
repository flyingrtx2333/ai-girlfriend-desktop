import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdir, mkdtemp, readFile, readdir, writeFile } from 'node:fs/promises';
import { isDeepStrictEqual } from 'node:util';
import { fileURLToPath } from 'node:url';
import os from 'node:os';
import path from 'node:path';

const option = name => { const i = process.argv.indexOf(name); return i < 0 ? undefined : process.argv[i + 1]; };
const root = fileURLToPath(new URL('../', import.meta.url)), app = option('--app');
const prepared = option('--prepared'), output = prepared ? path.resolve(prepared) : await mkdtemp(path.join(os.tmpdir(), 'bluefatfish-plugin-agents-'));
if (!path.basename(output).startsWith('bluefatfish-plugin-agents-')) throw new Error('Use an independent plugin Agent acceptance directory');
const hash = data => createHash('sha256').update(data).digest('hex'), pause = ms => new Promise(resolve => setTimeout(resolve, ms));
const production = path.join(os.homedir(), 'Library/Application Support/BlueFatFish');
async function profileHashes() {
  const names = ['settings.json', 'history.json', 'organization.json', 'agent/index.json', 'extensions/agents.json', 'extensions/plugin-agent-models.json'];
  for (const name of await readdir(path.join(production, 'agent')).catch(e => { if (e.code === 'ENOENT') return []; throw e; })) if (/^[A-Fa-f0-9-]{36}\.json$/.test(name)) names.push('agent/' + name);
  return Object.fromEntries(await Promise.all(names.sort().map(async name => [name, await readFile(path.join(production, name)).then(hash).catch(e => { if (e.code === 'ENOENT') return null; throw e; })])));
}
if (!prepared) {
  await mkdir(path.join(output, 'repo')); await mkdir(path.join(output, 'shared-home'));
  await writeFile(path.join(output, 'repo/source.txt'), await readFile(path.join(root, 'README.md')));
  const python = process.env.BLUEFATFISH_CHECK_PYTHON || '/opt/homebrew/bin/python3';
  const made = spawnSync(python, ['-c', String.raw`import json,pathlib,sys,zipfile
p=pathlib.Path(sys.argv[1])
def archive(name,files,prefix=''):
 with zipfile.ZipFile(p/name,'w',zipfile.ZIP_DEFLATED) as z:
  for key,value in files.items(): z.writestr(prefix+key,value)
def role(name='reviewer',tools='tools:\n  - Read\n  - Grep\n  - Glob',extra=''):
 return '---\nname: '+name+'\ndescription: 核对当前项目的真实来源文件\n'+tools+'\nmodel: inherit\npermissionMode: default\n'+extra+'---\n\n只读当前项目，核对实际来源，返回有依据的结论。保留原文件。\n'
manifest={'name':'native-roles','agents':['agents/reviewer.md','roles/integrator.md']}
bundle={'.qoder-plugin/plugin.json':json.dumps(manifest),'agents/reviewer.md':role(),'roles/integrator.md':role('integrator','tools: [Read, Write]\ndisallowedTools: [Write]','skills:\n  - source\nmcpServers: [source-data]\nreadOnly: false\nnetwork: true\n'),'skills/source/SKILL.md':'---\nname: source\ndescription: 读取包内公开来源\n---\n\n读取 references/source.txt。','skills/source/references/source.txt':(p/'repo/source.txt').read_bytes(),'.mcp.json':json.dumps({'mcpServers':{'source-data':{'command':'/usr/bin/false','args':[]}}})}
archive('native-roles.zip',bundle)
only={'.qoder-plugin/plugin.json':json.dumps({'name':'agent-only'}),'agents/audit.md':role('audit','tools: Read,Grep,Glob')}; archive('agent-only.zip',only)
archive('missing-agent.zip',{'.qoder-plugin/plugin.json':json.dumps({'name':'missing-role','agents':'missing.md'})})
archive('duplicate-agent.zip',{**only,'agents/second.md':role('audit')})
archive('unknown-tool.zip',{**only,'agents/audit.md':role('audit','tools: [ImaginaryTool]')})
archive('unknown-field.zip',{**only,'agents/audit.md':role('audit',extra='hooks: unsupported\n')})
archive('missing-skill.zip',{**only,'agents/audit.md':role('audit',extra='skills: [missing]\n')})
archive('duplicate-field.zip',{**only,'agents/audit.md':role('audit',extra='name: changed\n')})
ui={'.qoder-plugin/plugin.json':json.dumps({'name':'review-studio','displayName':'项目审阅角色','version':'1.0.0','author':{'name':'BlueFatFish acceptance'}}),'agents/reviewer.md':role(),'README.md':'# 项目审阅角色\n\n只读取选定项目，核对真实文件。\n'}; archive('review-studio.zip',ui,'review-studio/')
`, output], { encoding: 'utf8' });
  if (made.status !== 0) throw new Error(made.stderr || 'Actual ZIP creation failed');
  const inputs = Object.fromEntries(await Promise.all((await readdir(output)).filter(n => n.endsWith('.zip')).map(async name => [name, hash(await readFile(path.join(output, name)))])));
  inputs['repo/source.txt'] = hash(await readFile(path.join(output, 'repo/source.txt')));
  await writeFile(path.join(output, 'input-hashes.json'), JSON.stringify(inputs, null, 2));
  await writeFile(path.join(output, 'production-before.json'), JSON.stringify(await profileHashes(), null, 2));
}
console.log(JSON.stringify({ output, modelTransmission: 'blocked', prepared: !app }));
if (process.argv.includes('--prepare-only')) process.exit(0);
if (!app) throw new Error('Pass --app with the exact signed candidate; the daily application is never selected automatically');
for (const name of ['plugin-agent-result.json', 'profile/agent/index.json']) if (await readFile(path.join(output, name)).then(() => true).catch(e => { if (e.code === 'ENOENT') return false; throw e; })) throw new Error('Acceptance already started in this directory; preserve its actual records and process');
const before = JSON.parse(await readFile(path.join(output, 'production-before.json'), 'utf8'));
if (!isDeepStrictEqual(before, await profileHashes())) throw new Error('Daily profile changed since preparation; no app was launched');
const signed = spawnSync('/usr/bin/codesign', ['--verify', '--deep', '--strict', path.resolve(app)], { encoding: 'utf8' });
if (signed.status !== 0) throw new Error(signed.stderr || 'Candidate signature failed');
const binaryHash = hash(await readFile(path.join(app, 'Contents/MacOS/BlueFatFish')));
const opened = spawnSync('/usr/bin/open', ['-g', '-n', path.resolve(app), '--args', '--check', output, '--plugin-agent-check', '--background-component-check'], { encoding: 'utf8' });
if (opened.status !== 0) throw new Error(opened.stderr || 'Candidate launch failed');
let result;
const deadline = Date.now() + 180_000;
while (Date.now() < deadline) {
  try { result = JSON.parse(await readFile(path.join(output, 'plugin-agent-result.json'), 'utf8')); break; } catch (e) { if (e.code !== 'ENOENT' && !(e instanceof SyntaxError)) throw e; }
  await pause(150);
}
if (!result) throw new Error('Native observation deadline reached; no restart or record replacement was performed');
const alive = pid => { const state = spawnSync('/bin/ps', ['-p', String(pid), '-o', 'stat='], { encoding: 'utf8' }).stdout.trim(); return state.length > 0 && !state.startsWith('Z'); };
for (let i = 0; i < 100 && alive(result.appPID); i++) await pause(100);
const inputs = JSON.parse(await readFile(path.join(output, 'input-hashes.json'), 'utf8'));
result.independent = { actualProcessExited: !alive(result.appPID), binaryMatchesCandidate: result.binaryHash === binaryHash, dailyProfileUnchanged: isDeepStrictEqual(before, await profileHashes()), allSourceFilesUnchanged: (await Promise.all(Object.entries(inputs).map(async ([name, expected]) => hash(await readFile(path.join(output, name))) === expected))).every(Boolean), noExternalModelRequest: result.blockedModelAttempts === 0, backgroundRemainsInactive: result.backgroundComponentCheck === true && result.activationCount === 0 && result.visibleWindowCount === 0 && result.applicationActive === false };
result.success &&= Object.values(result.independent).every(Boolean);
await writeFile(path.join(output, 'plugin-agent-driver-report.json'), JSON.stringify(result, null, 2) + '\n');
console.log(JSON.stringify({ output, success: result.success, nativeChecks: Object.keys(result.checks ?? {}).length, independent: result.independent, appPID: result.appPID, binaryHash, error: result.error }));
if (!result.success) process.exitCode = 1;

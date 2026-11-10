import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdir, mkdtemp, readFile, readdir, writeFile } from 'node:fs/promises';
import { isDeepStrictEqual } from 'node:util';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import os from 'node:os';

const i = process.argv.indexOf('--app'), app = i < 0 ? null : process.argv[i + 1];
if (!app && !process.argv.includes('--prepare-only')) throw new Error('Pass the exact signed candidate with --app');
const root = fileURLToPath(new URL('../', import.meta.url)), output = await mkdtemp(path.join(os.tmpdir(), 'bluefatfish-plugin-scopes-项目 '));
const hash = value => createHash('sha256').update(value).digest('hex'), pause = ms => new Promise(resolve => setTimeout(resolve, ms));
async function dailyHashes() {
  const folder = path.join(os.homedir(), 'Library/Application Support/BlueFatFish'), names = ['settings.json', 'history.json', 'organization.json', 'agent/index.json', 'extensions/agents.json', 'extensions/mcp.json', 'extensions/hook-settings.json', 'extensions/plugin-agent-models.json', 'extensions/project-plugin-approvals.json'];
  for (const name of await readdir(path.join(folder, 'agent')).catch(e => { if (e.code === 'ENOENT') return []; throw e; })) if (/^[A-Fa-f0-9-]{36}\.json$/.test(name)) names.push('agent/' + name);
  const values = {}; for (const name of names) values[name] = await readFile(path.join(folder, name)).then(hash).catch(e => { if (e.code === 'ENOENT') return null; throw e; }); return values;
}
await mkdir(path.join(output, 'real project')); await writeFile(path.join(output, 'real project/source.txt'), await readFile(path.join(root, 'README.md'))); await writeFile(path.join(output, 'node-path.txt'), process.execPath);
await writeFile(path.join(output, 'real project/slow.cjs'), "const fs=require('node:fs'),cp=require('node:child_process');const child=cp.spawn('/bin/sleep',['30'],{stdio:'ignore'});fs.writeFileSync('slow-pids.json',JSON.stringify({pid:process.pid,child:child.pid}));setTimeout(()=>console.log('finished actual process'),30000);\n");
const prepared = spawnSync(process.env.BLUEFATFISH_CHECK_PYTHON || '/opt/homebrew/bin/python3', ['-c', String.raw`import json,pathlib,sys,zipfile
p=pathlib.Path(sys.argv[1]);node=sys.argv[2];plugin_root='$'+'{QODER_PLUGIN_ROOT}';resource='$'+'{RESOURCE_PATH}'
server=r'''import fs from 'node:fs';import crypto from 'node:crypto';import readline from 'node:readline';
const rl=readline.createInterface({input:process.stdin});
rl.on('line',line=>{let m;try{m=JSON.parse(line)}catch{return}if(m.id===undefined)return;let result={};
if(m.method==='initialize')result={protocolVersion:'2024-11-05',capabilities:{tools:{}},serverInfo:{name:'actual-version-source',version:'1.0.0'}};
else if(m.method==='tools/list')result={tools:[{name:'read_source',description:'Read the actual public source hash and installed version',inputSchema:{type:'object',properties:{},additionalProperties:false}}]};
else if(m.method==='tools/call'){const bytes=fs.readFileSync(process.env.RESOURCE_PATH),version=JSON.parse(fs.readFileSync(new URL('./skills/source/resources/version.json',import.meta.url),'utf8'));result={content:[{type:'text',text:JSON.stringify({sourceSha256:crypto.createHash('sha256').update(bytes).digest('hex'),version:version.value,pid:process.pid})}]};}
process.stdout.write(JSON.stringify({jsonrpc:'2.0',id:m.id,result})+'\n');});
'''
for version in [1,2]:
 manifest={'name':'lifecycle-tools','displayName':'版本工具','version':str(version)+'.0.0','description':'Actual public-file tools for plugin updates and recovery','author':'Native acceptance'}
 files={'.qoder-plugin/plugin.json':json.dumps(manifest),'README.md':'Actual plugin version '+str(version)+'\n','skills/source/SKILL.md':'---\nname: source\ndescription: Read the actual bundled public resource.\n---\nRead resources/version.json and preserve the public project source.\n','skills/source/resources/version.json':json.dumps({'value':'version-'+str(version)}),'agents/reviewer.md':'---\nname: reviewer\ndescription: Review actual public source\ntools: [read_file, read_skill, read_skill_resource]\nskills: [source]\nreadOnly: true\nnetwork: false\n---\nRead actual public files and cite their contents.\n','commands/inspect.md':'Read the actual public source. Arguments: $ARGUMENTS\n','rules/current.md':'---\ntrigger: always_on\n---\nPLUGIN_RULE_VERSION_'+str(version)+'\n','server.mjs':server,'.mcp.json':json.dumps({'mcpServers':{'local':{'command':node,'args':[plugin_root+'/server.mjs'],'env':{'RESOURCE_PATH':resource},'timeout':15000}}}),'hooks/hooks.json':json.dumps({'hooks':{'SessionStart':[{'hooks':[{'name':'source','type':'command','command':node,'args':[plugin_root+'/hook.cjs'],'env':{'UPDATE_MARKER':'public-plugin-update'},'network':False,'timeout':10}]}]}}),'hook.cjs':"process.stdin.resume();process.stdin.on('end',()=>console.log('actual plugin source version "+str(version)+"'));\n"}
 if version==2:files['agents/implementer.md']='---\nname: implementer\ndescription: Explicit project edits\ntools: [read_file, write_file]\nreadOnly: false\nnetwork: false\n---\nOnly edit the project when the user explicitly asks.\n'
 with zipfile.ZipFile(p/('lifecycle-v'+str(version)+'.zip'),'w',zipfile.ZIP_DEFLATED) as z:
  for name,text in files.items():z.writestr(name,text)
 if version==2:
  files['.qoder-plugin/plugin.json']=json.dumps({**manifest,'name':'other-tools'})
  with zipfile.ZipFile(p/'other-plugin.zip','w',zipfile.ZIP_DEFLATED) as z:
   for name,text in files.items():z.writestr(name,text)
`, output, process.execPath], { encoding: 'utf8' });
if (prepared.status !== 0) throw new Error(prepared.stderr || 'ZIP preparation failed');
await mkdir(path.join(output, 'other project')); await mkdir(path.join(output, 'copied project')); await mkdir(path.join(output, 'shared-home'));
await writeFile(path.join(output, 'other project/source.txt'), await readFile(path.join(root, 'docs/AGENT-READING.md')));
await writeFile(path.join(output, 'copied project/source.txt'), await readFile(path.join(root, 'README.md')));
await writeFile(path.join(output, 'other project/slow.cjs'), await readFile(path.join(output, 'real project/slow.cjs')));
const before = await dailyHashes(), inputs = {};
for (const name of ['lifecycle-v1.zip', 'lifecycle-v2.zip', 'other-plugin.zip', 'real project/source.txt', 'other project/source.txt', 'copied project/source.txt', 'real project/slow.cjs', 'other project/slow.cjs', 'node-path.txt']) inputs[name] = hash(await readFile(path.join(output, name)));
await writeFile(path.join(output, 'production-before.json'), JSON.stringify(before, null, 2)); await writeFile(path.join(output, 'input-hashes.json'), JSON.stringify(inputs, null, 2));
if (process.argv.includes('--prepare-only')) { console.log(JSON.stringify({ output, preparedOnly: true, modelTransmission: 'blocked' })); process.exit(0); }
const signed = spawnSync('/usr/bin/codesign', ['--verify', '--deep', '--strict', path.resolve(app)], { encoding: 'utf8' }); if (signed.status !== 0) throw new Error(signed.stderr);
const binaryHash = hash(await readFile(path.join(app, 'Contents/MacOS/BlueFatFish'))); console.log(JSON.stringify({ output, binaryHash, modelTransmission: 'blocked' }));
const alive = pid => { const state = spawnSync('/bin/ps', ['-p', String(pid), '-o', 'stat='], { encoding: 'utf8' }).stdout.trim(); return state.length > 0 && !state.startsWith('Z'); };
async function result(name, timeout = 180_000) { const until = Date.now() + timeout; while (Date.now() < until) { try { return JSON.parse(await readFile(path.join(output, name), 'utf8')); } catch (e) { if (e.code !== 'ENOENT' && !(e instanceof SyntaxError)) throw e; } await pause(100); } throw new Error('Observation deadline reached: preserve this exact process and records; do not replay'); }
const opened = spawnSync('/usr/bin/open', ['-g', '-n', path.resolve(app), '--args', '--check', output, '--plugin-scope-check', '--background-component-check'], { encoding: 'utf8' }); if (opened.status !== 0) throw new Error(opened.stderr);
const native = await result('plugin-scope-result.json');
for (let j = 0; j < 100 && alive(native.appPID); j++) await pause(100);
native.independent = { actualApplicationExited: !alive(native.appPID), allSixActualCommandAndConnectorProcessesExited: native.actualPIDs?.length === 6 && native.actualPIDs.every(pid => !alive(pid)), binaryMatchesCandidate: native.binaryHash === binaryHash, dailyProfileUnchanged: isDeepStrictEqual(before, await dailyHashes()), publicSourcesAndArchivesUnchanged: (await Promise.all(Object.entries(inputs).map(async ([name, h]) => hash(await readFile(path.join(output, name))) === h))).every(Boolean), actualIndependentSourceHashesMatch: native.sourceHashes?.['real project/source.txt'] === inputs['real project/source.txt'] && native.sourceHashes?.['other project/source.txt'] === inputs['other project/source.txt'], noModelOrActiveJobs: native.blockedModelAttempts === 0 && native.activeJobs === false, backgroundRemainsInactive: native.activationCount === 0 && native.applicationActive === false && native.visibleWindowCount === 0 };
native.success &&= Object.values(native.independent).every(Boolean); await writeFile(path.join(output, 'plugin-scope-driver-report.json'), JSON.stringify(native, null, 2) + '\n');
console.log(JSON.stringify({ output, success: native.success, checks: Object.keys(native.checks ?? {}).length, independent: native.independent, failed: Object.entries(native.checks ?? {}).filter(([, v]) => !v).map(([k]) => k), appPID: native.appPID, error: native.error })); if (!native.success) process.exit(1);
const retained = path.join(output, 'initial-native-agent-records'); await mkdir(retained);
for (const name of await readdir(path.join(output, 'profile/agent'))) if (name.endsWith('.json')) await writeFile(path.join(retained, name), await readFile(path.join(output, 'profile/agent', name)));
function launch(flag) { const r = spawnSync('/usr/bin/open', ['-g', '-n', path.resolve(app), '--args', '--check', output, flag, '--background-component-check'], { encoding: 'utf8' }); if (r.status !== 0) throw new Error(r.stderr); }
async function ended(pid) { for (let j = 0; j < 100 && alive(pid); j++) await pause(100); return !alive(pid); }
launch('--plugin-scope-crash-check'); const preparedCrash = await result('plugin-scope-crash-prepared.json');
const args = spawnSync('/bin/ps', ['-p', String(preparedCrash.appPID), '-o', 'command='], { encoding: 'utf8' }).stdout;
if (!alive(preparedCrash.appPID) || !args.includes(path.resolve(app) + '/Contents/MacOS/BlueFatFish') || !args.includes('--check ' + output) || !args.includes('--plugin-scope-crash-check') || preparedCrash.localActivationRevokedBeforePublication !== true) throw new Error('The exact original revoked-before-publish process is not confirmed live; no signal sent');
process.kill(preparedCrash.appPID, 'SIGKILL'); if (!await ended(preparedCrash.appPID)) throw new Error('Original killed process is still live; do not restart');
await writeFile(path.join(output, 'plugin-scope-actual-kill.json'), JSON.stringify({ appPID: preparedCrash.appPID, signal: 'SIGKILL', exactProcessVerifiedBeforeSignal: true, processActuallyEnded: true, preparedMarker: preparedCrash }, null, 2));
launch('--plugin-scope-recovery-check'); const recovered = await result('plugin-scope-recovery-result.json');
recovered.independent = { actualRecoveryProcessExited: await ended(recovered.appPID), originalKilledProcessRemainsTerminal: !alive(preparedCrash.appPID), binaryMatchesCandidate: recovered.binaryHash === binaryHash, dailyProfileUnchanged: isDeepStrictEqual(before, await dailyHashes()), publicSourcesAndArchivesUnchanged: (await Promise.all(Object.entries(inputs).map(async ([name, h]) => hash(await readFile(path.join(output, name))) === h))).every(Boolean), noModelOrActiveJobs: recovered.blockedModelAttempts === 0 && recovered.activeJobs === false, backgroundRemainsInactive: recovered.activationCount === 0 && recovered.applicationActive === false && recovered.visibleWindowCount === 0 };
recovered.success &&= Object.values(recovered.independent).every(Boolean); await writeFile(path.join(output, 'plugin-scope-recovery-driver-report.json'), JSON.stringify(recovered, null, 2) + '\n'); console.log(JSON.stringify({ output, stage: 'actual-project-crash-recovery', success: recovered.success, checks: Object.keys(recovered.checks ?? {}).length, independent: recovered.independent, failed: Object.entries(recovered.checks ?? {}).filter(([, v]) => !v).map(([k]) => k), error: recovered.error })); if (!recovered.success) process.exitCode = 1;

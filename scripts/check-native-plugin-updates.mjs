import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdir, mkdtemp, readFile, readdir, writeFile } from 'node:fs/promises';
import { isDeepStrictEqual } from 'node:util';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import os from 'node:os';

const i = process.argv.indexOf('--app'), app = i < 0 ? null : process.argv[i + 1];
if (!app) throw new Error('Pass the exact signed candidate with --app');
const root = fileURLToPath(new URL('../', import.meta.url)), output = await mkdtemp(path.join(os.tmpdir(), 'bluefatfish-plugin-updates-版本 '));
const hash = value => createHash('sha256').update(value).digest('hex'), pause = ms => new Promise(resolve => setTimeout(resolve, ms));
async function dailyHashes() {
  const folder = path.join(os.homedir(), 'Library/Application Support/BlueFatFish'), names = ['settings.json', 'history.json', 'organization.json', 'agent/index.json', 'extensions/agents.json', 'extensions/mcp.json', 'extensions/hook-settings.json'];
  for (const name of await readdir(path.join(folder, 'agent')).catch(e => { if (e.code === 'ENOENT') return []; throw e; })) if (/^[A-Fa-f0-9-]{36}\.json$/.test(name)) names.push('agent/' + name);
  const values = {}; for (const name of names) values[name] = await readFile(path.join(folder, name)).then(hash).catch(e => { if (e.code === 'ENOENT') return null; throw e; }); return values;
}
await mkdir(path.join(output, 'real project')); await mkdir(path.join(output, 'shared-home')); await writeFile(path.join(output, 'real project/source.txt'), await readFile(path.join(root, 'README.md'))); await writeFile(path.join(output, 'node-path.txt'), process.execPath);
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
const before = await dailyHashes(), inputs = {};
for (const name of ['lifecycle-v1.zip', 'lifecycle-v2.zip', 'other-plugin.zip', 'real project/source.txt', 'real project/slow.cjs', 'node-path.txt']) inputs[name] = hash(await readFile(path.join(output, name)));
await writeFile(path.join(output, 'production-before.json'), JSON.stringify(before, null, 2)); await writeFile(path.join(output, 'input-hashes.json'), JSON.stringify(inputs, null, 2));
const signed = spawnSync('/usr/bin/codesign', ['--verify', '--deep', '--strict', path.resolve(app)], { encoding: 'utf8' }); if (signed.status !== 0) throw new Error(signed.stderr);
const binaryHash = hash(await readFile(path.join(app, 'Contents/MacOS/BlueFatFish'))); console.log(JSON.stringify({ output, binaryHash, modelTransmission: 'blocked' }));
const alive = pid => { const state = spawnSync('/bin/ps', ['-p', String(pid), '-o', 'stat='], { encoding: 'utf8' }).stdout.trim(); return state.length > 0 && !state.startsWith('Z'); };
async function readResult(name, timeout = 120_000) { const until = Date.now() + timeout; while (Date.now() < until) { try { return JSON.parse(await readFile(path.join(output, name), 'utf8')); } catch (e) { if (e.code !== 'ENOENT' && !(e instanceof SyntaxError)) throw e; } await pause(100); } throw new Error('Observation deadline reached: preserve the exact process and files, do not replay'); }
function launch(flag) { const opened = spawnSync('/usr/bin/open', ['-g', '-n', path.resolve(app), '--args', '--check', output, flag, '--background-component-check'], { encoding: 'utf8' }); if (opened.status !== 0) throw new Error(opened.stderr); }
async function ended(pid) { for (let j = 0; j < 100 && alive(pid); j++) await pause(100); return !alive(pid); }
launch('--plugin-update-check'); const native = await readResult('plugin-update-result.json');
native.independent = { actualApplicationExited: await ended(native.appPID), actualCancelledProcessesExited: native.actualCancelledPIDs?.length === 3 && native.actualCancelledPIDs.every(pid => !alive(pid)), binaryMatchesCandidate: native.binaryHash === binaryHash, dailyProfileUnchanged: isDeepStrictEqual(before, await dailyHashes()), publicSourceAndArchivesUnchanged: (await Promise.all(Object.entries(inputs).map(async ([name, h]) => hash(await readFile(path.join(output, name))) === h))).every(Boolean), sourceHashMatchesActualPublicFile: native.sourceHash === inputs['real project/source.txt'], noModelOrActiveJobs: native.blockedModelAttempts === 0 && native.activeJobs === false, backgroundRemainsInactive: native.activationCount === 0 && native.applicationActive === false && native.visibleWindowCount === 0 };
native.success &&= Object.values(native.independent).every(Boolean); await writeFile(path.join(output, 'plugin-update-driver-report.json'), JSON.stringify(native, null, 2) + '\n');
console.log(JSON.stringify({ output, stage: 'native', success: native.success, checks: Object.keys(native.checks ?? {}).length, independent: native.independent, failed: Object.entries(native.checks ?? {}).filter(([, v]) => !v).map(([k]) => k), error: native.error }));
if (!native.success) process.exit(1);
launch('--plugin-update-crash-check'); const preparedCrash = await readResult('plugin-update-crash-prepared.json');
const args = spawnSync('/bin/ps', ['-p', String(preparedCrash.appPID), '-o', 'command='], { encoding: 'utf8' }).stdout;
if (!alive(preparedCrash.appPID) || !args.includes(path.resolve(app) + '/Contents/MacOS/BlueFatFish') || !args.includes('--check ' + output) || !args.includes('--plugin-update-crash-check')) throw new Error('The exact original pause process is not confirmed live; no signal sent');
process.kill(preparedCrash.appPID, 'SIGKILL'); if (!await ended(preparedCrash.appPID)) throw new Error('Original killed process still live; retain its handle and do not restart');
await writeFile(path.join(output, 'plugin-update-actual-kill.json'), JSON.stringify({ appPID: preparedCrash.appPID, signal: 'SIGKILL', exactProcessVerifiedBeforeSignal: true, processActuallyEnded: true, preparedMarker: preparedCrash }, null, 2));
launch('--plugin-update-recovery-check'); const recovery = await readResult('plugin-update-recovery-result.json');
recovery.independent = { actualRecoveryApplicationExited: await ended(recovery.appPID), originalKilledProcessRemainsTerminal: !alive(preparedCrash.appPID), binaryMatchesCandidate: recovery.binaryHash === binaryHash, dailyProfileUnchanged: isDeepStrictEqual(before, await dailyHashes()), publicSourcesAndArchivesUnchanged: (await Promise.all(Object.entries(inputs).map(async ([name, h]) => hash(await readFile(path.join(output, name))) === h))).every(Boolean), noActualModelRequest: recovery.modelRequests === 0, backgroundRemainsInactive: recovery.activationCount === 0 && recovery.applicationActive === false && recovery.visibleWindowCount === 0 };
recovery.success &&= Object.values(recovery.independent).every(Boolean); await writeFile(path.join(output, 'plugin-update-recovery-driver-report.json'), JSON.stringify(recovery, null, 2) + '\n'); console.log(JSON.stringify({ output, stage: 'actual-crash-recovery', success: recovery.success, checks: Object.keys(recovery.checks ?? {}).length, independent: recovery.independent, error: recovery.error })); if (!recovery.success) process.exitCode = 1;

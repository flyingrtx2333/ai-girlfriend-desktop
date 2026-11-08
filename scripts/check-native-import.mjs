import { spawnSync } from 'node:child_process';
import { mkdir, mkdtemp, readFile, writeFile, readdir, cp, unlink } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { isDeepStrictEqual } from 'node:util';
import { fileURLToPath } from 'node:url';
import os from 'node:os';
import path from 'node:path';

const root = fileURLToPath(new URL('../', import.meta.url));
const position = process.argv.indexOf('--resume');
const output = position < 0 ? await mkdtemp(path.join(os.tmpdir(), 'bluefatfish-import-')) : path.resolve(process.argv[position + 1]);
if (!path.basename(output).startsWith('bluefatfish-import-')) throw new Error('Use an actual import acceptance directory');
const hash = bytes => createHash('sha256').update(bytes).digest('hex'), pause = ms => new Promise(resolve => setTimeout(resolve,ms));
function command(executable,args,options={}) { const r=spawnSync(executable,args,{encoding:'utf8',...options});if(r.status!==0)throw new Error(r.stderr||r.stdout||executable+' failed');return r.stdout; }
const live = pid => { try { process.kill(pid,0);return true; } catch(e) { if(e.code==='ESRCH')return false;throw e; } };
async function snapshot() {
  const base=path.join(os.homedir(),'Library/Application Support/BlueFatFish');
  const names=['settings.json','history.json','agent/index.json','agent/A7A38353-CBA2-431C-84F1-4903E73EA373.json','automations/definitions.json','models/catalog.json','extensions/mcp.json','extensions/hooks.json','extensions/hook-settings.json','extensions/settings.json','extensions/agents.json','extensions/teams.json','worktrees/policy.json','worktrees/history.json','worktrees/scheduler.lock','computer-use/settings.json','organization.json','imports/batch.json'];
  return Object.fromEntries(await Promise.all(names.map(async name=>[name,await readFile(path.join(base,name)).then(hash).catch(e=>{if(e.code==='ENOENT')return null;throw e;})])));
}
const original = position < 0 ? await snapshot() : JSON.parse(await readFile(path.join(output,'production-before.json'),'utf8'));
if(!isDeepStrictEqual(original,await snapshot()))throw new Error('Preserve and inspect the changed daily profile');
if(position < 0) {
  await writeFile(path.join(output,'production-before.json'),JSON.stringify(original,null,2));
  const prepare=String.raw`import sqlite3,pathlib,json,hashlib,shutil,sys
dest=pathlib.Path(sys.argv[1]); project=sys.argv[2]; home=pathlib.Path.home()
db=sqlite3.connect('file:'+str(home/'.codex/state_5.sqlite')+'?mode=ro',uri=True)
rows=db.execute('select id,rollout_path,title,archived,source from threads where cwd=?',(project,)).fetchall();db.close()
valid=[r for r in rows if pathlib.Path(r[1]).exists() and 10000<pathlib.Path(r[1]).stat().st_size<1000000 and '"subagent"' not in r[4]]
progress=next(r for r in valid if '现在都实现多少功能了' in r[2]); other=next(r for r in valid if r[0]!=progress[0])
codex=dest/'sources/codex'; (codex/'sessions').mkdir(parents=True)
index=sqlite3.connect(codex/'state_5.sqlite');index.execute('create table threads(id text,title text,archived integer,source text)')
records=[]
for row in [other,progress]:
 source=pathlib.Path(row[1]); target=codex/'sessions'/source.name; shutil.copy2(source,target)
 index.execute('insert into threads values(?,?,?,?)',(row[0],row[2],row[3],row[4])); records.append({'id':row[0],'source':str(source),'copy':str(target),'sha256':hashlib.sha256(source.read_bytes()).hexdigest(),'title':row[2],'archived':row[3],'kind':'codex'})
index.commit();index.close()
qoder=dest/'sources/qoder'; (qoder/'projects/public').mkdir(parents=True)
chosen={}
for source in (home/'.qoder/projects').glob('*/*.jsonl'):
 if source.stat().st_size>10000:continue
 human=[]
 try:
  for line in source.open():
   d=json.loads(line);blocks=d.get('message',{}).get('content',[])
   if d.get('type')=='user' and isinstance(blocks,list):
    human += [b.get('text','') for b in blocks if isinstance(b,dict) and b.get('type')=='text']
 except Exception:continue
 first=next((v.strip() for v in human if v.strip()),'')
 key='qoder' if first=='hi' else 'qoderUI' if first.startswith('每天给我一道 AI 应用开发面试题') else None
 if key and key not in chosen:chosen[key]=(source,first)
 if len(chosen)==2:break
assert len(chosen)==2,'Preserve actual source records; missing public Qoder inputs'
for key,(source,first) in chosen.items():
 target=qoder/'projects/public'/source.name;shutil.copy2(source,target)
 records.append({'id':source.stem,'source':str(source),'copy':str(target),'sha256':hashlib.sha256(source.read_bytes()).hexdigest(),'firstUser':first,'kind':key})
manifest={'codexRoot':str(codex),'qoderRoot':str(qoder),'codex':progress[0],'codexOther':other[0],'qoder':next(r['id'] for r in records if r['kind']=='qoder'),'qoderUI':next(r['id'] for r in records if r['kind']=='qoderUI'),'records':records}
(dest/'import-fixtures.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2))
print(json.dumps({'actualSourceRecords':len(records)}))`;
  console.log(command('/usr/bin/python3',['-c',prepare,output,process.env.BLUEFATFISH_SOURCE_ROOT || '/Volumes/江波龙/Allprojects/ai-girlfriend-desktop']).trim());
  const business=path.join(process.env.BLUEFATFISH_SOURCE_ROOT || '/Volumes/江波龙/Allprojects/ai-girlfriend-desktop','evidence/agent',path.basename(output)+'-business');await mkdir(business,{recursive:true});
  const csv='item,amount\ncoffee,14.20\nticket,8.35\npaper,21.10\n';await writeFile(path.join(business,'input.csv'),csv);
  await writeFile(path.join(output,'import-business.json'),JSON.stringify({directory:business,input:path.join(business,'input.csv'),result:path.join(business,'result.json'),inputHash:hash(csv)},null,2));
}
console.log(JSON.stringify({output}));
if(process.argv.includes('--prepare-only'))process.exit(0);
const app=path.join(root,'build/蓝色大肥鱼.app'), binaryHash=hash(await readFile(path.join(app,'Contents/MacOS/BlueFatFish')));
async function waitJSON(directory,name,seconds,pid) { const until=Date.now()+seconds*1000;while(Date.now()<until) {
  const value=await readFile(path.join(directory,name),'utf8').then(JSON.parse).catch(e=>{if(e.code==='ENOENT'||e instanceof SyntaxError)return null;throw e;});if(value)return value;
  if(pid&&!live(pid)){const failure=await readFile(path.join(directory,'import-report.json'),'utf8').then(JSON.parse).catch(()=>null);throw new Error(failure?.error||'Actual check exited before '+name);}
  await pause(200);
}throw new Error('Observation deadline; preserve the original process for '+name); }
async function waitExit(pid) { for(let i=0;i<100&&live(pid);i++)await pause(100);if(live(pid))throw new Error('Actual process remains live; preserve '+pid); }
async function launch(directory,args) {
  const previous=await readFile(path.join(directory,'import-process.json'),'utf8').then(JSON.parse).catch(()=>null);if(previous&&live(previous.appPID))throw new Error('Existing import process is live; preserve it');
  for(const name of ['import-process.json','import-report.json','import-ui-ready.json','finish-import-ui'])await unlink(path.join(directory,name)).catch(e=>{if(e.code!=='ENOENT')throw e;});
  command('/usr/bin/open',['-n',app,'--args','--check',directory,'--import-check',...args]);return await waitJSON(directory,'import-process.json',30);
}
let report;
try {
  const native=path.join(output,'native-'+binaryHash.slice(0,12));await mkdir(native,{recursive:true});
  if(!await readFile(path.join(native,'import-fixtures.json')).catch(()=>null)) {
    await cp(path.join(output,'sources'),path.join(native,'sources'),{recursive:true});
    const fixtures=JSON.parse(await readFile(path.join(output,'import-fixtures.json'),'utf8'));
    fixtures.codexRoot=path.join(native,'sources/codex');fixtures.qoderRoot=path.join(native,'sources/qoder');
    for(const record of fixtures.records)record.copy=record.copy.replace(output,native);
    const extra=String.raw`import sqlite3,pathlib,json,hashlib,shutil,sys
manifest=json.loads(sys.argv[1]); root=pathlib.Path(manifest['codexRoot']); home=pathlib.Path.home(); db=sqlite3.connect('file:'+str(home/'.codex/state_5.sqlite')+'?mode=ro',uri=True)
selected=None
for row in db.execute('select id,rollout_path,title,archived,source from threads where source like ?',('%"subagent"%',)):
 try:parent=json.loads(row[4])['subagent']['thread_spawn']['parent_thread_id']
 except Exception:continue
 p=pathlib.Path(row[1])
 if parent in [manifest['codex'],manifest['codexOther']] and p.exists() and p.stat().st_size<1000000:selected=row;break
db.close();assert selected is not None,'Actual subagent source missing; do not fabricate one'
p=pathlib.Path(selected[1]); target=root/'sessions'/p.name;shutil.copy2(p,target)
db=sqlite3.connect(root/'state_5.sqlite');db.execute('insert into threads values(?,?,?,?)',(selected[0],selected[2],selected[3],selected[4]));db.commit();db.close()
manifest['records'].append({'id':selected[0],'source':str(p),'copy':str(target),'sha256':hashlib.sha256(p.read_bytes()).hexdigest(),'kind':'nativeSubagent'})
print(json.dumps(manifest,ensure_ascii=False))`;
    const augmented=JSON.parse(command('/usr/bin/python3',['-c',extra,JSON.stringify(fixtures)]));
    await writeFile(path.join(native,'import-fixtures.json'),JSON.stringify(augmented,null,2));
  }
  let nativeResult=await readFile(path.join(native,'import-native.json'),'utf8').then(JSON.parse).catch(()=>null);
  if(!nativeResult) {
    const previousPhase=await readFile(path.join(native,'import-phase.json'),'utf8').then(JSON.parse).catch(()=>null);
    let owner=await launch(native,['--import-native-only']);
    if(previousPhase?.phase==='paused') {nativeResult=await waitJSON(native,'import-native.json',180,owner.appPID);await waitExit(owner.appPID);}
    else {const phase=await waitJSON(native,'import-phase.json',180,owner.appPID);await waitExit(owner.appPID);if(phase.phase!=='paused')throw new Error('Actual paused checkpoint missing');owner=await launch(native,['--import-native-only']);nativeResult=await waitJSON(native,'import-native.json',180,owner.appPID);await waitExit(owner.appPID);}
  }
  if(!nativeResult?.success)throw new Error(nativeResult?.error||'Native import checks failed');
  const owner=await launch(output,['--live-agent','--hold-ui']);const ready=await waitJSON(output,'import-ui-ready.json',1800,owner.appPID);
  const business=JSON.parse(await readFile(path.join(output,'import-business.json'),'utf8')), result=JSON.parse(await readFile(business.result,'utf8'));
  const cents=[1420n,835n,2110n].reduce((a,b)=>a+b,0n), expected=(cents/100n)+'.'+String(cents%100n).padStart(2,'0');
  if(result.history_term!=='SWE-bench'||String(result.total)!==expected||hash(await readFile(business.input))!==business.inputHash)throw new Error('Imported real history or actual CSV result mismatch');
  console.log(JSON.stringify({phase:'actual-ui-ready',output,appPID:ready.appPID,binaryHash,independent:{historyTerm:result.history_term,total:result.total,inputUnchanged:true},tasks:ready.tasks}));
  report=await waitJSON(output,'import-report.json',1500,owner.appPID);await waitExit(owner.appPID);
  if(!report.success)throw new Error(report.error||'Actual import acceptance failed');
  const fixtures=JSON.parse(await readFile(path.join(output,'import-fixtures.json'),'utf8'));
  const sourceRecordsUnchanged=(await Promise.all(fixtures.records.map(async r=>hash(await readFile(r.source))===r.sha256&&hash(await readFile(r.copy))===r.sha256))).every(Boolean);
  const accounting={};
  for(const [key,id] of Object.entries(ready.tasks)) {
    const t=JSON.parse(await readFile(path.join(output,'profile/agent',id+'.json'),'utf8')), receipts=t.modelReceipts??[];
    accounting[key]=receipts.length>0&&receipts.every(r=>Number.isInteger(r.inputTokens)&&Number.isInteger(r.outputTokens))&&receipts.reduce((n,r)=>n+r.inputTokens,0)===t.inputTokens&&receipts.reduce((n,r)=>n+r.outputTokens,0)===t.outputTokens;
  }
  report.native=nativeResult;report.independent={sourceRecordsUnchanged,productionProfileUnchanged:isDeepStrictEqual(original,await snapshot()),actualReceiptsAccounted:accounting,decimalTotal:expected,actualResult:result};
  report.success&&=sourceRecordsUnchanged&&report.independent.productionProfileUnchanged&&Object.values(accounting).every(Boolean);
}catch(error){report={...(report??{}),success:false,error:error.message};}
finally {
  await writeFile(path.join(output,'import-driver-report.json'),JSON.stringify(report,null,2));const archive=path.join(root,'evidence/agent',path.basename(output).replace('bluefatfish-','')+'-'+new Date().toISOString().replace(/[:.]/g,'-'));await cp(output,archive,{recursive:true});console.log(JSON.stringify({success:report?.success,output,archive,error:report?.error}));
}
if(!report?.success)process.exitCode=1;

import { spawnSync } from 'node:child_process';
import { mkdir, mkdtemp, readFile, writeFile, unlink } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { isDeepStrictEqual } from 'node:util';
import { fileURLToPath } from 'node:url';
import os from 'node:os';
import path from 'node:path';

const root = fileURLToPath(new URL('../', import.meta.url));
const index = process.argv.indexOf('--resume'), output = index < 0 ? await mkdtemp(path.join(os.tmpdir(), 'bluefatfish-organization-')) : path.resolve(process.argv[index + 1]);
if(!path.basename(output).startsWith('bluefatfish-organization-')) throw new Error('Use an actual work mode acceptance directory');
const hash = data => createHash('sha256').update(data).digest('hex'), pause = ms => new Promise(resolve => setTimeout(resolve,ms));
const alive = pid => { try { process.kill(pid,0); return true; } catch(e) { if(e.code==='ESRCH') return false; throw e; } };
const profile = path.join(os.homedir(),'Library/Application Support/BlueFatFish');
async function productionSnapshot() {
  const names = ['settings.json','history.json','agent/index.json','agent/A7A38353-CBA2-431C-84F1-4903E73EA373.json','automations/definitions.json','models/catalog.json','extensions/mcp.json','extensions/hooks.json','extensions/hook-settings.json','extensions/settings.json','extensions/agents.json','extensions/teams.json','worktrees/policy.json','worktrees/history.json','worktrees/scheduler.lock','computer-use/settings.json','organization.json'];
  return Object.fromEntries(await Promise.all(names.map(async name=>[name,await readFile(path.join(profile,name)).then(hash).catch(e=>{if(e.code==='ENOENT')return null;throw e;})])));
}
const before = index < 0 ? await productionSnapshot() : JSON.parse(await readFile(path.join(output,'production-before.json'),'utf8'));
if(!isDeepStrictEqual(before,await productionSnapshot())) throw new Error('Production profile changed; preserve and inspect');
const csv = 'item,amount\ncoffee,14.20\nticket,8.35\npaper,21.10\n';
const initialCode = 'import csv\nimport sys\nwith open(sys.argv[1], newline="", encoding="utf-8") as source:\n    rows = list(csv.DictReader(source))\nprint("{:.2f}".format(sum(int(float(row["amount"])) for row in rows)))\n';
function command(command,args,options={}) { const r=spawnSync(command,args,{encoding:'utf8',...options});if(r.status!==0)throw new Error(r.stderr||r.stdout||command+' failed');return r.stdout; }
if(index < 0) {
  await writeFile(path.join(output,'production-before.json'),JSON.stringify(before,null,2));
  for(const name of ['coding','general','shared-home']) await mkdir(path.join(output,name));
  await writeFile(path.join(output,'coding/data.csv'),csv);await writeFile(path.join(output,'general/expenses.csv'),csv);
  await writeFile(path.join(output,'coding/calculator.py'),initialCode);
  command('/usr/bin/git',['init','-b','codex/work-mode-check'],{cwd:path.join(output,'coding')});
  command('/usr/bin/git',['add','data.csv','calculator.py'],{cwd:path.join(output,'coding')});
  command('/usr/bin/git',['-c','user.name=Work Mode Check','-c','user.email=check@local.invalid','-c','commit.gpgsign=false','commit','-m','Public decimal input'],{cwd:path.join(output,'coding')});
  const head=command('/usr/bin/git',['rev-parse','HEAD'],{cwd:path.join(output,'coding')}).trim();
  const initialOutput=command('/usr/bin/python3',['calculator.py','data.csv'],{cwd:path.join(output,'coding')}).trim();
  if(initialOutput!=='43.00')throw new Error('Preserve and inspect the actual initial program output');
  await writeFile(path.join(output,'original-inputs.json'),JSON.stringify({csvHash:hash(csv),codeHash:hash(initialCode),head,initialOutput},null,2));
} else {
  const previous=await readFile(path.join(output,'organization-process.json'),'utf8').then(JSON.parse).catch(e=>{if(e.code==='ENOENT')return null;throw e;});
  if(previous && alive(previous.appPID))throw new Error('Original acceptance app is live; keep its actual handle');
  for(const name of ['organization-process.json','organization-report.json','organization-ui-ready.json','finish-organization-ui'])await unlink(path.join(output,name)).catch(e=>{if(e.code!=='ENOENT')throw e;});
}
console.log(JSON.stringify({output}));
if(process.argv.includes('--prepare-only'))process.exit(0);
async function waitFile(name,seconds,pid) {
  const until=Date.now()+seconds*1000;
  while(Date.now()<until) {
    const value=await readFile(path.join(output,name),'utf8').then(JSON.parse).catch(e=>{if(e.code==='ENOENT'||e instanceof SyntaxError)return null;throw e;});if(value)return value;
    if(pid && !alive(pid)){const final=await readFile(path.join(output,'organization-report.json'),'utf8').then(JSON.parse).catch(()=>null);throw new Error(final?.error||'Acceptance app exited before '+name);}
    await pause(300);
  }
  throw new Error('Observation deadline for '+name+'; preserve the original running handle');
}
let report;
try {
  command('/usr/bin/open',['-n',path.join(root,'build/蓝色大肥鱼.app'),'--args','--check',output,'--organization-check','--live-agent','--hold-ui']);
  const owner=await waitFile('organization-process.json',30);
  const ready=await waitFile('organization-ui-ready.json',2000,owner.appPID);
  const originals=JSON.parse(await readFile(path.join(output,'original-inputs.json'),'utf8'));
  const cents=csv.trim().split('\n').slice(1).map(line=>BigInt(line.split(',')[1].replace('.',''))).reduce((a,b)=>a+b,0n), expected=(cents/100n)+'.'+String(cents%100n).padStart(2,'0');
  const actual=command('/usr/bin/python3',['calculator.py','data.csv'],{cwd:path.join(output,'coding')}).trim();
  const result=(await readFile(path.join(output,'coding/result.txt'),'utf8')).trim(), summary=await readFile(path.join(output,'general/summary.md'),'utf8');
  const independent={decimalTotal:expected,actualProgramOutput:actual,resultFile:result,programAndFileMatch:actual===expected&&result===expected,generalSummaryMatches:summary.includes(expected),inputCSVsUnchanged:hash(await readFile(path.join(output,'coding/data.csv')))===originals.csvHash&&hash(await readFile(path.join(output,'general/expenses.csv')))===originals.csvHash,sourceActuallyChanged:hash(await readFile(path.join(output,'coding/calculator.py')))!==originals.codeHash,gitHeadUnchanged:command('/usr/bin/git',['rev-parse','HEAD'],{cwd:path.join(output,'coding')}).trim()===originals.head};
  if(Object.values(independent).some(v=>v===false))throw new Error(JSON.stringify(independent));
  await writeFile(path.join(output,'organization-independent.json'),JSON.stringify(independent,null,2));
  console.log(JSON.stringify({phase:'actual-ui-ready',output,appPID:ready.appPID,tasks:ready.tasks,independent}));
  report=await waitFile('organization-report.json',1500,owner.appPID);
  for(let i=0;i<100&&alive(owner.appPID);i++)await pause(100);
  if(alive(owner.appPID))throw new Error('Actual app remains live; preserve its handle');
  if(!report.success)throw new Error(report.error||'Work mode check failed');
  const accounting={};
  for(const [mode,id] of Object.entries(ready.tasks)) {
    const task=JSON.parse(await readFile(path.join(output,'profile/agent',id+'.json'),'utf8')), receipts=task.modelReceipts??[], calls=task.messages.flatMap(m=>m.toolCalls??[]);
    accounting[mode]=receipts.length>0&&receipts.every(r=>Number.isInteger(r.inputTokens)&&Number.isInteger(r.outputTokens))&&receipts.reduce((n,r)=>n+r.inputTokens,0)===task.inputTokens&&receipts.reduce((n,r)=>n+r.outputTokens,0)===task.outputTokens&&calls.every(c=>['load_tools','update_plan','read_file','list_directory','search_files','write_file','edit_file','run_command'].includes(c.name));
  }
  report.independent={...independent,productionProfileUnchanged:isDeepStrictEqual(before,await productionSnapshot()),actualReceiptsAccounted:accounting};
  report.success&&=report.independent.productionProfileUnchanged&&Object.values(accounting).every(Boolean);
} catch(error) {report={...(report??{}),success:false,error:error.message};}
finally {
  await writeFile(path.join(output,'organization-driver-report.json'),JSON.stringify(report,null,2));
  const archive=path.join(root,'evidence/agent',path.basename(output).replace('bluefatfish-','')+'-'+new Date().toISOString().replace(/[:.]/g,'-'));await mkdir(path.dirname(archive),{recursive:true});command('/usr/bin/ditto',[output,archive]);console.log(JSON.stringify({success:report?.success,output,archive,error:report?.error}));
}
if(!report?.success)process.exitCode=1;

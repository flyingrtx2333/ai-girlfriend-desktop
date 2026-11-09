import { spawnSync } from 'node:child_process';
import { mkdir, mkdtemp, readFile, writeFile, readdir, copyFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { isDeepStrictEqual } from 'node:util';
import { fileURLToPath } from 'node:url';
import os from 'node:os';
import path from 'node:path';

const root = fileURLToPath(new URL('../', import.meta.url));
function option(name) { const i=process.argv.indexOf(name); if(i<0||!process.argv[i+1])throw Error('Missing '+name); return path.resolve(process.argv[i+1]); }
const app=option('--candidate-app'), actual=option('--actual-run'), retainedImport=option('--import-run'), hash=data=>createHash('sha256').update(data).digest('hex'), pause=ms=>new Promise(resolve=>setTimeout(resolve,ms));
const output=await mkdtemp(path.join(os.tmpdir(),'bluefatfish-task-records-')), profile=path.join(os.homedir(),'Library/Application Support/BlueFatFish');
function command(file,args) { const r=spawnSync(file,args,{encoding:'utf8'});if(r.status!==0)throw Error(r.stderr||file);return r.stdout; }
function live(pid) { try {process.kill(pid,0);return true;}catch(error){if(error.code==='ESRCH')return false;throw error;} }
async function json(name) { try {return JSON.parse(await readFile(name,'utf8'));}catch(error){if(error.code==='ENOENT')return null;throw error;} }
async function waitJSON(directory,name,phase,failure) {
  let deadline=Date.now()+120000;
  for(;;) {
    const value=await json(path.join(directory,name));if(value)return value;
    const report=failure&&await json(path.join(directory,failure));if(report)throw Error(JSON.stringify(report));
    const processInfo=await json(path.join(directory,'task-records-process-'+phase+'.json'));
    if(processInfo&&!live(processInfo.appPID))throw Error('Actual '+phase+' process stopped before '+name);
    if(Date.now()>deadline){if(processInfo&&live(processInfo.appPID)){console.log(JSON.stringify({verifiedWaiting:phase,appPID:processInfo.appPID}));deadline=Date.now()+60000;}else throw Error('No confirmed live process for '+name);}
    await pause(250);
  }
}
async function waitExit(pid) { for(let i=0;i<100&&live(pid);i++)await pause(100);if(live(pid))throw Error('Retain live process '+pid); }
const importManifest=await json(path.join(retainedImport,'import-fixtures.json')), imported=importManifest?.records.find(r=>r.kind==='qoder');
if(!imported)throw Error('Retain the actual public Qoder conversation; no substitute records');
const importBytes=await readFile(imported.copy);if(hash(importBytes)!==imported.sha256)throw Error('Retained real Qoder source changed');
async function production() {
  const names=['settings.json','history.json','organization.json','agent/index.json','agent/deleted-records.json','automations/definitions.json','models/catalog.json','extensions/mcp.json','extensions/hooks.json','extensions/hook-settings.json','extensions/settings.json','extensions/agents.json','extensions/teams.json','worktrees/policy.json','worktrees/history.json','worktrees/scheduler.lock','computer-use/settings.json','imports/batch.json','knowledge/catalog.json','knowledge-cards/settings.json','wiki/settings.json'];
  for(const name of await readdir(path.join(profile,'agent')))if(/^[a-f0-9-]{36}\.json$/i.test(name))names.push('agent/'+name);
  const values=Object.fromEntries(await Promise.all(names.sort().map(async name=>[name,await readFile(path.join(profile,name)).then(hash).catch(error=>{if(error.code==='ENOENT')return null;throw error;})])));
  values.dailyBinary=hash(await readFile(path.join(root,'build/蓝色大肥鱼.app/Contents/MacOS/BlueFatFish')));
  for(const name of ['wiki-request-ledger.json','wiki-budget-authorization.json','profile/agent/F3C22B92-75F2-4846-B8AF-71F08CE11024.json'])values['retained-wiki:'+name]=hash(await readFile(path.join(actual,name)));
  values.retainedQoderSource=hash(await readFile(imported.copy));return values;
}
const before=await production();await writeFile(path.join(output,'production-before.json'),JSON.stringify(before,null,2));
const sources={},heads={};
for(const project of ['alpha','beta','empty']) {
  const directory=path.join(output,'projects',project);await mkdir(directory,{recursive:true});
  const bytes=await readFile(path.join(root,project==='beta'?'native/AgentRuntime.swift':'README.md'));await writeFile(path.join(directory,'README.md'),bytes);sources[project]=hash(bytes);
  command('/usr/bin/git',['init','--quiet','--initial-branch=main',directory]);command('/usr/bin/git',['-C',directory,'add','README.md']);
  command('/usr/bin/git',['-C',directory,'-c','user.name=Task Record Acceptance','-c','user.email=records@localhost','-c','commit.gpgSign=false','-c','core.hooksPath=/dev/null','commit','--quiet','-m','Actual source for task record acceptance']);heads[project]=command('/usr/bin/git',['-C',directory,'rev-parse','HEAD']).trim();
}
command('/usr/bin/git',['-C',path.join(output,'projects/alpha'),'-c','core.hooksPath=/dev/null','worktree','add','--quiet','--detach',path.join(output,'projects/worktree'),'HEAD']);
const worktrees=command('/usr/bin/git',['-C',path.join(output,'projects/alpha'),'worktree','list','--porcelain']);
const imports=path.join(output,'import-source/projects/public');await mkdir(imports,{recursive:true});await writeFile(path.join(imports,path.basename(imported.copy)),importBytes);
await copyFile(path.join(actual,'profile/agent/F3C22B92-75F2-4846-B8AF-71F08CE11024.json'),path.join(output,'retained-real-wiki.json'));
const binaryHash=hash(await readFile(path.join(app,'Contents/MacOS/BlueFatFish')));command('/usr/bin/codesign',['--verify','--deep','--strict',app]);
await writeFile(path.join(output,'task-records-origin.json'),JSON.stringify({repository:root,app,binaryHash,sources,heads,worktrees,actual,retainedImport,retainedSourceHash:imported.sha256,modelsCalled:false},null,2));console.log(JSON.stringify({output,app,binaryHash}));
const recovery=path.join(output,'recovery');await mkdir(recovery);await copyFile(path.join(root,'README.md'),path.join(recovery,'README.md'));
command('/usr/bin/open',['-n',app,'--args','--check',recovery,'--organization-check','--task-records-crash-check']);
const committed=await waitJSON(recovery,'deletion-committed.json','crash','task-records-recovery-report.json');
if(committed.binaryHash!==binaryHash||!live(committed.appPID))throw Error('Wrong or stopped crash-check process');
const actualCommand=command('/bin/ps',['-p',String(committed.appPID),'-o','command=']);if(!actualCommand.includes(app+'/Contents/MacOS/BlueFatFish')||!actualCommand.includes(recovery)||!actualCommand.includes('--task-records-crash-check'))throw Error('Preserve unrelated process');
process.kill(committed.appPID,'SIGTERM');await waitExit(committed.appPID);
const retainedRecord=await readFile(path.join(recovery,'profile/agent',committed.id+'.json')), retainedCheckpoint=await readFile(path.join(recovery,'profile/agent',committed.id,'checkpoints/README-copy.md')), retainedLedger=await json(path.join(recovery,'profile/agent/deleted-records.json'));
if(!retainedLedger.tasks.includes(committed.id)||retainedLedger.pending.length!==1||hash(retainedCheckpoint)!==committed.sourceHash)throw Error('Actual interruption did not leave the committed deletion and private cache');
await writeFile(path.join(recovery,'actual-process-termination.json'),JSON.stringify({appPID:committed.appPID,binaryHash,signal:'SIGTERM',exited:true,recordHash:hash(retainedRecord),checkpointHash:hash(retainedCheckpoint),pending:retainedLedger.pending.length},null,2));
command('/usr/bin/open',['-n',app,'--args','--check',recovery,'--organization-check','--task-records-recovery-check']);
const recovered=await waitJSON(recovery,'task-records-recovery-report.json','recovery');if(!recovered.success)throw Error(JSON.stringify(recovered));await waitExit(recovered.appPID);
command('/usr/bin/open',['-n',app,'--args','--check',output,'--organization-check','--task-records-check']);
const ready=await waitJSON(output,'task-records-ui-ready.json','main','task-records-report.json');if(ready.binaryHash!==binaryHash)throw Error('Wrong actual UI candidate');
console.log(JSON.stringify({ready:true,output,appPID:ready.appPID,nativeChecks:ready.checks,recoveryChecks:recovered.checks}));
const report=await waitJSON(output,'task-records-report.json','main'),after=await production();await writeFile(path.join(output,'production-after.json'),JSON.stringify(after,null,2));
const independent={dailyProfileApplicationAndRetainedEvidenceUnchanged:isDeepStrictEqual(before,after),actualCandidate:report.binaryHash===binaryHash&&report.appPID===ready.appPID,actualProcessTerminationAndRecovery:recovered.success&&recovered.binaryHash===binaryHash,noModelCalls:report.modelsCalled===false&&report.checks.noUnexpectedModelRequestOrFabricatedReplyInUITasks===true};
for(const project of ['alpha','beta','empty']){independent['source:'+project]=hash(await readFile(path.join(output,'projects',project,'README.md')))===sources[project];independent['head:'+project]=command('/usr/bin/git',['-C',path.join(output,'projects',project),'rev-parse','HEAD']).trim()===heads[project];}
independent.worktreeAndGitRegistrationPreserved=command('/usr/bin/git',['-C',path.join(output,'projects/alpha'),'worktree','list','--porcelain'])===worktrees&&hash(await readFile(path.join(output,'projects/worktree/README.md')))===sources.alpha;
const real=JSON.parse(await readFile(path.join(output,'retained-real-wiki.json'),'utf8')), exported=JSON.parse(await readFile(path.join(output,'native-real-history.json'),'utf8')), messages=real.messages.filter(m=>m.nativeContext!==true);
independent.realModelHistoryExportMatchesOriginalMessagesAndCalls=exported.messages.length===messages.length&&exported.messages.every((m,i)=>m.id===messages[i].id&&m.role===messages[i].role&&m.content===messages[i].content&&isDeepStrictEqual(m.toolCalls??[],(messages[i].toolCalls??[]).map(c=>({id:c.id,name:c.name,arguments:c.arguments}))));
const uiSource=await json(path.join(output,'ui-parent-before.json')),uiJSON=await json(path.join(output,'ui-history.json')),uiMarkdown=await readFile(path.join(output,ready.tasks.parent+'.md'),'utf8');
independent.actualUISavePanelsExportSameTaskAndPreserveMessages=uiJSON?.taskID===ready.tasks.parent&&uiJSON.messages.length===uiSource.messages.length&&uiJSON.messages.every((m,i)=>m.id===uiSource.messages[i].id&&m.role===uiSource.messages[i].role&&m.content===uiSource.messages[i].content)&&uiMarkdown.includes(ready.tasks.parent)&&uiSource.messages.every(m=>uiMarkdown.includes(m.content));
independent.actualUIExportKeepsAttachmentMetadataAndOmitsUnsentDraft=uiJSON.attachments.some(a=>a.id===ready.attachment&&a.sha256===sources.alpha)&&uiJSON.draft===undefined&&!uiMarkdown.includes(uiSource.draft)&&uiMarkdown.includes(sources.alpha);
const ledger=await json(path.join(output,'profile/agent/deleted-records.json')),index=await json(path.join(output,'profile/agent/index.json')),removed=['parent','child','clearOne','clearTwo','workspaceOne','workspaceTwo','workspaceOld'];
independent.confirmedDeletionScopesMatchLedgerAndIndex=!!ledger&&removed.every(key=>ledger.tasks.includes(ready.tasks[key])&&!index.tasks.some(t=>t.id===ready.tasks[key]))&&ledger.workspaces.includes(ready.workspaceArchiveID)&&ledger.pending.length===0;
const fork=await json(path.join(output,'profile/agent',ready.tasks.fork+'.json')),general=await json(path.join(output,'profile/agent',ready.tasks.general+'.json'));independent.remainingForkGeneralDraftAndAttachmentPreserved=fork?.draft==='保留的分支草稿'&&general?.draft==='保留的通用草稿'&&hash(await readFile(path.join(output,'profile/agent',ready.tasks.fork,'attachments',ready.attachment,'source.md')))===sources.alpha;
report.recovery=recovered;report.independent=independent;report.success&&=Object.values(independent).every(Boolean);await writeFile(path.join(output,'task-records-report.json'),JSON.stringify(report,null,2));console.log(JSON.stringify({success:report.success,output,nativeChecks:Object.keys(report.checks).length,independentChecks:Object.keys(independent).length,recoveryChecks:Object.keys(recovered.checks).length}));if(!report.success)process.exitCode=1;

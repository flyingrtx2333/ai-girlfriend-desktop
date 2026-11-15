import {spawn,spawnSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {createWriteStream} from 'node:fs';
import {copyFile,mkdir,mkdtemp,readFile,realpath,writeFile} from 'node:fs/promises';
import {createServer} from 'node:http';
import {finished} from 'node:stream/promises';
import {fileURLToPath} from 'node:url';
import path from 'node:path';

const root=fileURLToPath(new URL('../',import.meta.url)),app=process.env.BLUEFATFISH_APP,python=process.env.BLUEFATFISH_OFFICE_PYTHON;
const option=name=>{const i=process.argv.indexOf(name);return i<0?null:process.argv[i+1];};
const reopen=option('--reopen'),manual=process.argv.includes('--manual-ui');
if(!app||!python||process.argv.includes('--live-agent'))throw Error('请指定独立验收应用和现有 Office 核对依赖；不调用模型。');
const command=(file,args)=>{const p=spawnSync(file,args,{encoding:'utf8'});if(p.status!==0)throw Error(p.stderr||p.stdout||file);return p.stdout;};
const info=JSON.parse(command('/usr/bin/plutil',['-convert','json','-o','-',path.join(app,'Contents/Info.plist')]));
if(info.BlueFatFishAcceptanceOnly!==true)throw Error('独立窗口恢复只能使用验收应用。');
command('/usr/bin/codesign',['--verify','--deep','--strict',app]);
const output=reopen?await realpath(reopen):await mkdtemp(path.join(root,'evidence/agent/floating-recovery-command-'));
if(!output.startsWith(await realpath(path.join(root,'evidence/agent'))+path.sep))throw Error('验收资料必须留在项目外置盘。');
for(const name of ['tmp','shared-home','workspace','originals'])await mkdir(path.join(output,name),{recursive:true,mode:0o700});
const hash=bytes=>createHash('sha256').update(bytes).digest('hex');
if(!reopen){
  command(python,[path.join(root,'scripts/fixtures/office-documents.py'),path.join(output,'originals')]);
  await copyFile(path.join(output,'originals/sample.docx'),path.join(output,'workspace/sample.docx'));
  await writeFile(path.join(output,'workspace/draft.md'),'# PUBLIC_FLOATING_ORIGINAL_473\n');
  await writeFile(path.join(output,'workspace/closed.txt'),'PUBLIC_FLOATING_CLOSED_617\n');
}
const oldInput=reopen?JSON.parse(await readFile(path.join(output,'browser-input.json'),'utf8')):null;
const server=createServer((req,res)=>{res.writeHead(200,{'content-type':'text/html; charset=utf-8'});res.end('<!doctype html><meta charset="utf-8"><title>公开窗口恢复表单</title><label>公开草稿<input id="note" aria-label="公开草稿"></label><p>PUBLIC_FLOATING_WEB_941</p><div style="height:2000px"></div>');});
await new Promise((resolve,reject)=>{server.once('error',reject);server.listen(oldInput?Number(new URL(oldInput.url).port):0,'127.0.0.1',resolve);});
const base=`http://127.0.0.1:${server.address().port}/`;
if(!reopen)await writeFile(path.join(output,'browser-input.json'),JSON.stringify({url:base},null,2)+'\n');
const binary=path.join(app,'Contents/MacOS/BlueFatFish'),binaryHash=hash(await readFile(binary)),results=[];
const originals=Object.fromEntries(await Promise.all(['sample.docx','draft.md','closed.txt'].map(async name=>[name,hash(await readFile(path.join(output,'workspace',name)))])));
async function run(stage,ui=false){
  const label=`${stage}-${Date.now()}`,args=['--check',output,ui?'--workspace-floating-recovery-ui':'--workspace-floating-recovery-check','--recovery-stage',stage];
  const child=spawn(binary,args,{env:{...process.env,TMPDIR:path.join(output,'tmp')+'/'},stdio:['ignore','pipe','pipe']});
  const stdout=createWriteStream(path.join(output,label+'-stdout.log')),stderr=createWriteStream(path.join(output,label+'-stderr.log'));child.stdout.pipe(stdout);child.stderr.pipe(stderr);
  const identity={app,appPID:child.pid,binaryHash,args,stage,label};await writeFile(path.join(output,label+'-process.json'),JSON.stringify(identity,null,2)+'\n');console.log(JSON.stringify({output,...identity}));
  const status=await new Promise((resolve,reject)=>{child.once('error',reject);child.once('exit',(exit,signal)=>resolve({exit,signal}));});
  await Promise.all([finished(stdout),finished(stderr)]);
  const bytes=await readFile(path.join(output,ui?'floating-recovery-ui-ready.json':'floating-recovery-report.json'));await writeFile(path.join(output,label+'-report.json'),bytes);
  const report=JSON.parse(bytes),sameApplication=report.appPID===child.pid&&report.binaryHash===binaryHash&&hash(await readFile(binary))===binaryHash;
  const result={stage,label,...status,sameApplication,success:status.exit===0&&sameApplication&&report.success===true&&report.modelRequests===0&&Object.keys(report.checks).length>0&&Object.values(report.checks).every(Boolean),checks:Object.keys(report.checks).length,failed:Object.keys(report.checks).filter(k=>!report.checks[k]),error:report.error,modelRequests:report.modelRequests};
  results.push(result);await writeFile(path.join(output,label+'-result.json'),JSON.stringify(result,null,2)+'\n');console.log(JSON.stringify({output,...result}));
  if(!result.success)throw Error('独立窗口恢复阶段失败：'+stage);
}
try{
  if(manual||reopen)await run(reopen?'observe':'seed',true);
  else{
    await run('seed');
    const fixture=JSON.parse(await readFile(path.join(output,'floating-recovery-fixture.json'),'utf8'));
    const metadata=fixture.main.find(x=>x.tab.root==='document:'+fixture.file),target=path.join(output,'profile/workspace-recovery',fixture.windowID,'pages',metadata.tab.id+'.json');
    const before=await readFile(target),value=JSON.parse(before);value.kind='future-record';const invalid=Buffer.from(JSON.stringify(value)+'\n');
    await writeFile(path.join(output,'original-page.json'),before);await writeFile(path.join(output,'invalid-page-input.json'),invalid);await writeFile(target,invalid);
    await run('invalid');if(!Buffer.from(await readFile(target)).equals(invalid))throw Error('未支持的原草稿被改写');
    await run('retry');await run('reopen');
    const checks={allStagesPassed:results.length===4&&results.every(x=>x.success),sameApplication:results.every(x=>x.sameApplication),noModels:results.every(x=>x.modelRequests===0),sourceFilesExact:(await Promise.all(Object.entries(originals).map(async([name,digest])=>hash(await readFile(path.join(output,'workspace',name)))===digest))).every(Boolean)};
    const independent=JSON.parse(command(python,['-c','from docx import Document; from pathlib import Path; import sys,json; p=Path(sys.argv[1]); original=[x.text for x in Document(p/"originals/sample.docx").paragraphs]; actual=[x.text for x in Document(p/"reopen-recovered.docx").paragraphs]; expected=["审阅人：独立窗口草稿" if x=="审阅人：待填写" else x for x in original]; print(json.dumps({"fullParagraphsExactExceptDeclaredEdit":actual==expected,"reviewerPresent":"审阅人：独立窗口草稿" in actual}))',output]));
    Object.assign(checks,independent);await writeFile(path.join(output,'independent.json'),JSON.stringify({success:Object.values(checks).every(Boolean),checks},null,2)+'\n');
    if(!Object.values(checks).every(Boolean))throw Error('独立文件核对失败');console.log(JSON.stringify({output,success:true,checks}));
  }
}finally{server.close();await writeFile(path.join(output,`results-${Date.now()}.json`),JSON.stringify(results,null,2)+'\n');}

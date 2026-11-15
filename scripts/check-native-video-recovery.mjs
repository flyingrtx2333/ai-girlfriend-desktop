import { spawn,spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { createWriteStream } from 'node:fs';
import { chmod,mkdir,mkdtemp,readFile,realpath,writeFile } from 'node:fs/promises';
import { finished } from 'node:stream/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const root=fileURLToPath(new URL('../',import.meta.url)),app=process.env.BLUEFATFISH_APP;
const option=name=>{const i=process.argv.indexOf(name);return i<0?null:process.argv[i+1];};
const reopen=option('--reopen'),manual=process.argv.includes('--manual-ui'),media=option('--media-directory');
if(!app||process.argv.includes('--live-agent')||(!reopen&&!media))throw Error('请指定独立验收应用及已核对的公开视频目录；本检查不调用模型。');
const command=(file,args)=>{const p=spawnSync(file,args,{encoding:'utf8'});if(p.status!==0)throw Error(p.stderr||p.stdout||file);return p.stdout;};
const info=JSON.parse(command('/usr/bin/plutil',['-convert','json','-o','-',path.join(app,'Contents/Info.plist')]));
if(info.BlueFatFishAcceptanceOnly!==true)throw Error('视频恢复只能使用独立验收应用。');
command('/usr/bin/codesign',['--verify','--deep','--strict',app]);
const output=reopen?await realpath(reopen):await mkdtemp(path.join(root,'evidence/agent/video-recovery-command-'));
if(!output.startsWith(await realpath(path.join(root,'evidence/agent'))+path.sep))throw Error('验收资料必须留在项目外置盘。');
for(const name of ['tmp','shared-home','workspace/media','outside-scope'])await mkdir(path.join(output,name),{recursive:true,mode:0o700});
const hash=bytes=>createHash('sha256').update(bytes).digest('hex');
if(!reopen){
  const origin=JSON.parse(await readFile(path.join(media,'media-origin.json'),'utf8')),probes={};
  for(const name of ['flower.mp4','flower.webm']){
    const source=origin.files.find(f=>f.name===name),bytes=await readFile(path.join(media,name));
    if(!source||hash(bytes)!==source.sha256)throw Error('公开视频来源摘要变化：'+name);
    const target=path.join(output,'workspace/media',name);await writeFile(target,bytes);await chmod(target,0o444);
    const probe=JSON.parse(command(process.env.FFPROBE_PATH??'/opt/homebrew/bin/ffprobe',['-v','quiet','-show_format','-show_streams','-of','json',target]));
    if(Math.abs(Number(probe.format.duration)-source.duration)>0.01||!probe.streams.some(s=>s.codec_type==='video'&&s.width===960&&s.height===540))throw Error('独立解码元数据不匹配：'+name);
    probes[name]=probe;
  }
  await writeFile(path.join(output,'workspace/README.md'),'PUBLIC_VIDEO_PROJECT_417\n');
  await writeFile(path.join(output,'media-origin.json'),JSON.stringify(origin,null,2)+'\n');
  await writeFile(path.join(output,'independent-media-probes.json'),JSON.stringify(probes,null,2)+'\n');
}
const binary=path.join(app,'Contents/MacOS/BlueFatFish'),binaryHash=hash(await readFile(binary)),results=[];
async function run(stage,ui=false){
  const label=`${stage}-${Date.now()}`,args=['--check',output,ui?'--workspace-video-recovery-ui':'--workspace-video-recovery-check','--recovery-stage',stage];
  const child=spawn(binary,args,{env:{...process.env,TMPDIR:path.join(output,'tmp')+'/'},stdio:['ignore','pipe','pipe']});
  const stdout=createWriteStream(path.join(output,label+'-stdout.log')),stderr=createWriteStream(path.join(output,label+'-stderr.log'));child.stdout.pipe(stdout);child.stderr.pipe(stderr);
  const identity={app,appPID:child.pid,binaryHash,args,stage,label};await writeFile(path.join(output,label+'-process.json'),JSON.stringify(identity,null,2)+'\n');console.log(JSON.stringify({output,...identity}));
  const status=await new Promise((resolve,reject)=>{child.once('error',reject);child.once('exit',(exit,signal)=>resolve({exit,signal}));});
  await Promise.all([finished(stdout),finished(stderr)]);
  const bytes=await readFile(path.join(output,ui?'video-recovery-ui-ready.json':'video-recovery-report.json'));await writeFile(path.join(output,label+'-report.json'),bytes);
  const report=JSON.parse(bytes),sameApplication=report.appPID===child.pid&&report.binaryHash===binaryHash&&hash(await readFile(binary))===binaryHash;
  const result={stage,label,...status,sameApplication,success:status.exit===0&&sameApplication&&report.success===true&&report.modelRequests===0&&Object.values(report.checks).every(Boolean),checks:Object.keys(report.checks).length,failed:Object.keys(report.checks).filter(k=>!report.checks[k]),error:report.error,modelRequests:report.modelRequests};
  results.push(result);await writeFile(path.join(output,label+'-result.json'),JSON.stringify(result,null,2)+'\n');console.log(JSON.stringify({output,...result}));
  if(!result.success)throw Error('实际视频恢复阶段失败：'+stage);
}
try{
  if(manual||reopen)await run(reopen?'reopen':'seed',true);
  else{
    await run('seed');
    const fixture=JSON.parse(await readFile(path.join(output,'video-recovery-fixture.json'),'utf8'));
    const page=path.join(output,'profile/workspace-recovery',fixture.windowID,'pages',fixture.tabID+'.json'),original=await readFile(page);
    await writeFile(path.join(output,'original-video-page.json'),original);
    for(const stage of ['invalid','legacy','mismatch']){
      const value=JSON.parse(original),state=JSON.parse(Buffer.from(value.state,'base64'));
      if(stage==='invalid')state.video.version=2;
      if(stage==='legacy')delete state.video;
      if(stage==='mismatch'){state.file=fixture.secondFile;state.selection=fixture.secondFile;}
      value.state=Buffer.from(JSON.stringify(state)).toString('base64');const input=Buffer.from(JSON.stringify(value)+'\n');
      await writeFile(page,input);await writeFile(path.join(output,stage+'-video-input.json'),input);await run(stage);
      if(stage!=='legacy'&&!Buffer.from(await readFile(page)).equals(input))throw Error('拒绝的播放记录被改写：'+stage);
      await writeFile(page,original);
    }
    const taskPath=path.join(output,'profile/agent',fixture.taskID+'.json'),indexPath=path.join(output,'profile/agent/index.json');
    const taskBytes=await readFile(taskPath),indexBytes=await readFile(indexPath),task=JSON.parse(taskBytes);task.workspace=path.join(output,'outside-scope');
    await writeFile(path.join(output,'original-scope-task.json'),taskBytes);await writeFile(path.join(output,'original-scope-index.json'),indexBytes);
    await writeFile(taskPath,JSON.stringify(task)+'\n');await writeFile(path.join(output,'scope-video-input.json'),original);await run('scope');
    if(!Buffer.from(await readFile(page)).equals(original))throw Error('失去范围后播放记录被改写');
    await writeFile(taskPath,taskBytes);await writeFile(indexPath,indexBytes);
    await run('reopen');await run('closed');
    const origin=JSON.parse(await readFile(path.join(output,'media-origin.json'),'utf8'));
    const checks={sameApplication:results.every(x=>x.sameApplication),allStagesPassed:results.length===7&&results.every(x=>x.success),originalVideosPreserved:(await Promise.all(origin.files.filter(x=>['flower.mp4','flower.webm'].includes(x.name)).map(async x=>hash(await readFile(path.join(output,'workspace/media',x.name)))===x.sha256))).every(Boolean),readmePreserved:await readFile(path.join(output,'workspace/README.md'),'utf8')==='PUBLIC_VIDEO_PROJECT_417\n',noModelRequests:results.every(x=>x.modelRequests===0)};
    await writeFile(path.join(output,'independent.json'),JSON.stringify({success:Object.values(checks).every(Boolean),checks},null,2)+'\n');
    if(!Object.values(checks).every(Boolean))throw Error('视频恢复独立核对失败');console.log(JSON.stringify({output,success:true,checks}));
  }
}finally{await writeFile(path.join(output,`results-${Date.now()}.json`),JSON.stringify(results,null,2)+'\n');}

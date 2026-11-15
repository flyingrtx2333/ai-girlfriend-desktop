import { createServer } from 'node:http';
import { spawn, spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { createWriteStream } from 'node:fs';
import { mkdir, mkdtemp, readFile, writeFile } from 'node:fs/promises';
import { finished } from 'node:stream/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const root = fileURLToPath(new URL('../', import.meta.url)), app = process.env.BLUEFATFISH_APP;
const args = process.argv.slice(2), manual = args.includes('--manual-ui'), reopen = args[0] === '--reopen' ? args[1] : null;
if (!app || !(args.length === 0 || args.length === 1 && manual || args.length === 2 && reopen)) throw Error('请指定独立验收应用；可用 --manual-ui 或 --reopen <原目录>，不调用模型。');
const command = (file, parameters) => { const run = spawnSync(file, parameters, { encoding:'utf8' }); if (run.status !== 0) throw Error(run.stderr || run.stdout || file); return run.stdout; };
const info = JSON.parse(command('/usr/bin/plutil', ['-convert','json','-o','-',path.join(app,'Contents/Info.plist')]));
if (info.BlueFatFishAcceptanceOnly !== true) throw Error('浏览器恢复只能使用独立验收应用。');
command('/usr/bin/codesign', ['--verify','--deep','--strict',app]);
const output = reopen ? path.resolve(reopen) : await mkdtemp(path.join(root,'evidence/agent/browser-recovery-command-'));
if (!output.startsWith(path.join(root,'evidence/agent/'))) throw Error('验收资料须位于项目外置盘目录。');
for (const name of ['tmp','shared-home']) await mkdir(path.join(output,name),{recursive:true});
const previous = reopen ? JSON.parse(await readFile(path.join(output,'browser-input.json'),'utf8')) : null;
const requests = [], hash = bytes => createHash('sha256').update(bytes).digest('hex');
const html = pathname => `<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><title>恢复网页 ${pathname === '/first/form' ? '一' : pathname === '/second/form' ? '二' : pathname === '/other/form' ? '独立窗口' : pathname === '/posted' ? 'POST 结果' : '历史'}</title><style>body{margin:32px;font:16px -apple-system,sans-serif;background:#f4f7f5;color:#183c32}h1{font-size:28px}label{display:block;margin:16px 0 6px}textarea{width:90%;height:100px}input,select,textarea,button{font:inherit;padding:6px}section{height:1600px;background:linear-gradient(#d9ece3,#f4f7f5);margin-top:24px;padding:24px}.marker{height:100px;width:160px;background:#157c67}</style></head><body><h1>浏览器恢复验收</h1><p>PUBLIC_BROWSER_PAGE_417</p><label for="note">网页说明</label><textarea id="note" name="note"></textarea><label><input type="checkbox" id="flag" name="flag">保留选项</label><label for="choice">选择项目</label><select id="choice" name="choice"><option value="one">第一项</option><option value="two">第二项</option></select><label for="password">公开测试密码字段</label><input id="password" type="password" name="password" autocomplete="off"><form id="post" method="POST" action="/posted"><input type="hidden" name="marker" value="PUBLIC_POST_417"><button>提交测试表单</button></form><p>${pathname === '/posted' ? 'POST 已记录' : '网页表单未提交'}</p><section><div class="marker"></div><p>滚动中的公开页面 PUBLIC_SCROLL_618</p></section><p>PUBLIC_END_829</p></body></html>`;
const server = createServer(async (request,response) => {
  const pathname = new URL(request.url,'http://127.0.0.1').pathname;
  for await (const chunk of request) { if (chunk.length > 100_000) { response.writeHead(413); response.end(); return; } }
  requests.push({method:request.method,path:pathname});
  response.writeHead(200,{'Content-Type':'text/html; charset=utf-8','Cache-Control':'no-store'}); response.end(html(pathname));
});
await new Promise((resolve,reject) => { server.once('error',reject); server.listen(previous ? new URL(previous.url).port : 0,'127.0.0.1',resolve); });
const base = `http://127.0.0.1:${server.address().port}/`;
if (!reopen) await writeFile(path.join(output,'browser-input.json'),JSON.stringify({url:base},null,2)+'\n');
const binary = path.join(app,'Contents/MacOS/BlueFatFish'), binaryHash = hash(await readFile(binary)), results = [];
async function run(stage, ui=false) {
  const label = `${stage}-${Date.now()}`, parameters = ['--check',output,ui ? '--workspace-browser-recovery-ui' : '--workspace-browser-recovery-check','--recovery-stage',stage];
  const child = spawn(binary,parameters,{env:{...process.env,TMPDIR:path.join(output,'tmp')+'/'},stdio:['ignore','pipe','pipe']});
  const stdout = createWriteStream(path.join(output,label+'-stdout.log')), stderr = createWriteStream(path.join(output,label+'-stderr.log'));
  child.stdout.pipe(stdout);child.stderr.pipe(stderr);
  const identity={app,appPID:child.pid,binaryHash,serverPID:process.pid,args:parameters,stage,label};
  await writeFile(path.join(output,label+'-process.json'),JSON.stringify(identity,null,2)+'\n');
  console.log(JSON.stringify({output,...identity}));
  const status = await new Promise((resolve,reject)=>{child.once('error',reject);child.once('exit',(exit,signal)=>resolve({exit,signal}));});
  await Promise.all([finished(stdout),finished(stderr)]);
  const bytes=await readFile(path.join(output,ui?'browser-recovery-ui-ready.json':'browser-recovery-report.json'));
  await writeFile(path.join(output,label+'-report.json'),bytes);
  const report=JSON.parse(bytes), sameApplication=report.appPID===child.pid && report.binaryHash===binaryHash && hash(await readFile(binary))===binaryHash;
  const result={stage,label,...status,sameApplication,success:status.exit===0 && sameApplication && report.success===true && report.modelRequests===0 && Object.values(report.checks).every(Boolean),checks:Object.keys(report.checks).length,failed:Object.keys(report.checks).filter(k=>!report.checks[k]),error:report.error,modelRequests:report.modelRequests};
  results.push(result);await writeFile(path.join(output,label+'-result.json'),JSON.stringify(result,null,2)+'\n');console.log(JSON.stringify({output,...result}));
  if(!result.success)throw Error('实际浏览器恢复阶段失败：'+stage);
  return report;
}
try {
  if (manual || reopen) { await run(reopen?'reopen':'seed',true); }
  else {
    await run('seed');
    const fixture=JSON.parse(await readFile(path.join(output,'browser-recovery-fixture.json'),'utf8'));
    const page=path.join(output,'profile/workspace-recovery',fixture.windowID,'pages',fixture.tabID+'.json');
    const original=await readFile(page), value=JSON.parse(original), state=JSON.parse(Buffer.from(value.state,'base64'));
    await writeFile(path.join(output,'browser-before-future.json'),original);
    state.version=2;value.state=Buffer.from(JSON.stringify(state)).toString('base64');
    const future=Buffer.from(JSON.stringify(value)+'\n');await writeFile(page,future);await writeFile(path.join(output,'future-browser-input.json'),future);
    await run('invalid');
    if(!Buffer.from(await readFile(page)).equals(future))throw Error('未来版本浏览器记录被改写');
    await writeFile(page,original);
    const reopened=await run('reopen');
    if(hash(await readFile(reopened.attachment.path))!==reopened.attachment.sha256)throw Error('实际标注附件摘要不一致');
    await run('closed');
    const independent={sameApplication:results.every(r=>r.sameApplication),allStagesPassed:results.every(r=>r.success),postSentOnlyOnceByExplicitSeed:requests.filter(r=>r.method==='POST').length===1,readmeUnchanged:await readFile(path.join(output,'public-browser-project/README.md'),'utf8')==='PUBLIC_BROWSER_PROJECT_417\n',actualAttachmentMatches:hash(await readFile(reopened.attachment.path))===reopened.attachment.sha256,noModelRequests:results.every(r=>r.modelRequests===0)};
    await writeFile(path.join(output,'independent.json'),JSON.stringify({success:Object.values(independent).every(Boolean),checks:independent,requests},null,2)+'\n');
    if(!Object.values(independent).every(Boolean))throw Error('浏览器恢复独立核对失败');
    console.log(JSON.stringify({output,success:true,independent}));
  }
} finally {
  await writeFile(path.join(output,`requests-${Date.now()}.json`),JSON.stringify(requests,null,2)+'\n');
  await writeFile(path.join(output,`results-${Date.now()}.json`),JSON.stringify(results,null,2)+'\n');
  await new Promise(resolve=>server.close(resolve));
}

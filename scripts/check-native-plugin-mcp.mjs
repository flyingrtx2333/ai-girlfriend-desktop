import { spawn, spawnSync } from 'node:child_process';
import { mkdir, mkdtemp, readFile, readdir, readlink, lstat, writeFile, unlink } from 'node:fs/promises';
import { createHash, randomBytes } from 'node:crypto';
import { isDeepStrictEqual } from 'node:util';
import { fileURLToPath } from 'node:url';
import os from 'node:os';
import path from 'node:path';

const root = fileURLToPath(new URL('../', import.meta.url));
const option = name => { const index = process.argv.indexOf(name); return index < 0 ? undefined : process.argv[index + 1]; };
const resume = option('--resume'), output = resume ? path.resolve(resume) : await mkdtemp(path.join(os.tmpdir(), 'bluefatfish-plugin-mcp-'));
if (!path.basename(output).startsWith('bluefatfish-plugin-mcp-')) throw new Error('Use an actual plugin MCP acceptance directory');
const live = process.argv.includes('--live-agent'), hold = process.argv.includes('--hold-ui');
const hash = value => createHash('sha256').update(value).digest('hex'), pause = ms => new Promise(resolve => setTimeout(resolve, ms));
const production = path.join(os.homedir(), 'Library/Application Support/BlueFatFish');
async function productionSnapshot() {
  const names = ['settings.json','history.json','agent/index.json','agent/A7A38353-CBA2-431C-84F1-4903E73EA373.json','automations/definitions.json','models/catalog.json','extensions/mcp.json','extensions/hooks.json','extensions/hook-settings.json','extensions/settings.json','extensions/agents.json','extensions/teams.json','worktrees/policy.json','worktrees/history.json','worktrees/scheduler.lock','computer-use/settings.json'];
  const entries = await Promise.all(names.map(async name => [name, await readFile(path.join(production,name)).then(hash).catch(error => { if(error.code==='ENOENT')return null;throw error; })]));
  async function walk(dir, relative = '') {
    const children = await readdir(dir,{withFileTypes:true}).catch(error=>{if(error.code==='ENOENT')return [];throw error;});
    for(const child of children.sort((a,b)=>a.name.localeCompare(b.name))) {
      const full=path.join(dir,child.name), name=path.join(relative,child.name);
      if(child.isSymbolicLink())entries.push(['plugins/'+name,'link:'+await readlink(full)]);else if(child.isDirectory())await walk(full,name);else entries.push(['plugins/'+name,hash(await readFile(full))]);
    }
  }
  await walk(path.join(production,'extensions/plugins'));return Object.fromEntries(entries);
}
const alive = pid => { try { process.kill(pid,0);return true; } catch(error) {if(error.code==='ESRCH')return false;throw error;} };
async function waitFile(name, seconds, owner) {
  const deadline=Date.now()+seconds*1000;
  while(Date.now()<deadline) {
    try{return JSON.parse(await readFile(path.join(output,name),'utf8'));}catch(error){if(error.code!=='ENOENT'&&!(error instanceof SyntaxError))throw error;}
    if(owner&&!alive(owner))throw new Error('Actual app exited before '+name);await pause(250);
  }
  throw new Error('Observation deadline reached for '+name+'; preserve original handles');
}
const before=resume?JSON.parse(await readFile(path.join(output,'production-before.json'),'utf8')):await productionSnapshot();
if(!isDeepStrictEqual(before,await productionSnapshot()))throw new Error('Production profile changed; preserve and inspect');
if(!resume) {
  for(const dir of ['repo','shared-home','private','ui'])await mkdir(path.join(output,dir));
  await writeFile(path.join(output,'repo/sales.csv'),'item,amount\nA,14.20\nB,8.35\nC,21.10\n');
  await writeFile(path.join(output,'private/http-key'),randomBytes(32).toString('hex')+'\n',{mode:0o600});
  await writeFile(path.join(output,'production-before.json'),JSON.stringify(before,null,2)+'\n');
} else {
  const previous=await readFile(path.join(output,'plugin-mcp-process.json'),'utf8').then(JSON.parse).catch(error=>{if(error.code==='ENOENT')return null;throw error;});
  if(previous&&alive(previous.appPID))throw new Error('Original acceptance app is still live; continue its actual handle');
  for(const name of ['plugin-mcp-process.json','plugin-mcp-report.json','plugin-mcp-ui-ready.json','plugin-mcp-disabled-verified.json','begin-plugin-mcp-lifecycle','verify-plugin-mcp-disabled','finish-plugin-mcp-ui'])await unlink(path.join(output,name)).catch(error=>{if(error.code!=='ENOENT')throw error;});
}
let http=await readFile(path.join(output,'http-ready.json'),'utf8').then(JSON.parse).catch(error=>{if(error.code==='ENOENT')return null;throw error;});
if(!http||!alive(http.pid)) {
  const previousPort=http?new URL(http.url).port:null;
  await unlink(path.join(output,'http-ready.json')).catch(error=>{if(error.code!=='ENOENT')throw error;});
  const backend=spawn(process.execPath,[path.join(root,'scripts/fixtures/ledger-mcp.mjs'),'--http','--csv',path.join(output,'repo/sales.csv'),'--log',path.join(output,'http-requests.jsonl'),'--key-file',path.join(output,'private/http-key'),'--ready-file',path.join(output,'http-ready.json'),...(previousPort?['--port',previousPort]:[])],{detached:true,stdio:'ignore',env:{PATH:'/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin'}});
  backend.unref();http=await waitFile('http-ready.json',15,backend.pid);
}
const fixtureReady = await lstat(path.join(output,'ledger-tools.zip')).then(s=>s.isFile()).catch(error=>{if(error.code==='ENOENT')return false;throw error;});
if(!fixtureReady) {
  for(const name of ['plugin-mcp-native.json','plugin-mcp-live-task.json'])if(await lstat(path.join(output,name)).then(()=>true).catch(error=>{if(error.code==='ENOENT')return false;throw error;}))throw new Error('Accepted fixture is missing; preserve original inputs');
  const fixture=spawnSync('/usr/bin/python3',['-c',String.raw`import json,pathlib,sys,zipfile,hashlib
from decimal import Decimal
p=pathlib.Path(sys.argv[1]);node=sys.argv[2];endpoint=sys.argv[3];entry=pathlib.Path(sys.argv[4]).read_text()
def archive(name,files):
 with zipfile.ZipFile(p/name,'w',zipfile.ZIP_DEFLATED) as z:
  for key,value in files.items():z.writestr(key,value)
def stdio(log):return {'command':node,'args':['$'+'{QODER_PLUGIN_ROOT}/server.mjs','--log',str(p/log)],'env':{'LEDGER_CSV':'$'+'{SALES_CSV}'},'timeout':20000}
archive('native-ledger.zip',{'.qoder-plugin/plugin.json':json.dumps({'name':'native-ledger','displayName':'原生连接器检查'}),'.mcp.json':json.dumps({'mcpServers':{'local':stdio('native-requests.jsonl')}}),'server.mjs':entry})
archive('legacy-plugin.zip',{'.qoder-plugin/plugin.json':json.dumps({'name':'legacy-plugin'}),'commands/check.md':'---\ndescription: 旧安装记录兼容\n---\n\n核对实际文件。'})
files={'.qoder-plugin/plugin.json':json.dumps({'name':'ledger-tools','displayName':'销售连接器','version':'1.0.0','author':{'name':'BlueFatFish acceptance'},'mcpServers':'./connections.json'},ensure_ascii=False),'connections.json':json.dumps({'mcpServers':{'local':stdio('live-requests.jsonl'),'remote':{'type':'streamable-http','url':endpoint,'headers':{'X-Ledger-Key':'$'+'{LEDGER_HTTP_KEY}'},'timeout':20000}}}),'server.mjs':entry,'README.md':'# 销售连接器\n\n本机与 HTTP 销售核对工具。\n','skills/reconcile/SKILL.md':'---\nname: reconcile\ndescription: 分别通过两个销售连接器核对同一份实际 CSV。\n---\n\n使用 list_mcp_servers 获取已分配连接器的当前配置。分别连接 ledger-tools:local 和 ledger-tools:remote，按目录获取 sum_sales 的实际工具名称与参数，然后分别调用。工具无参数。只使用实际 MCP 输出，不用本机文件读取替代计算。核对两份结果 rows、total、currency、sourceSha256 一致，然后 write_file 保存 reconciliation.json，顶层字段仅 stdio、http，值分别是对应工具返回的上述四项字段。最后 read_file 回读该文件并核对。不要修改 sales.csv，不运行终端，不使用其他服务。\n'}
archive('ledger-tools.zip',files)
rows=[line.split(',') for line in (p/'repo/sales.csv').read_text().strip().splitlines()[1:]]
result={'rows':len(rows),'total':format(sum(Decimal(row[1]) for row in rows),'.2f'),'currency':'CNY','sourceSha256':hashlib.sha256((p/'repo/sales.csv').read_bytes()).hexdigest()}
(p/'independent-expected.json').write_text(json.dumps({'result':{'stdio':result,'http':result},'packageFiles':{k:hashlib.sha256(v.encode()).hexdigest() for k,v in files.items()},'packageHash':hashlib.sha256((p/'ledger-tools.zip').read_bytes()).hexdigest()}))
`,output,process.execPath,http.url,path.join(root,'scripts/fixtures/ledger-mcp.mjs')],{encoding:'utf8'});
  if(fixture.status!==0)throw new Error(fixture.stderr||'Actual plugin ZIP creation failed');
}
console.log(JSON.stringify({output,live,hold,httpPID:http.pid}));
if(process.argv.includes('--prepare-only'))process.exit(0);
let report;
try {
  if(live&&!hold)throw new Error('Real acceptance requires --hold-ui');
  const opened=spawnSync('/usr/bin/open',['-n',path.join(root,'build/蓝色大肥鱼.app'),'--args','--check',output,'--extension-check','--plugin-mcp-check',...(live?['--live-agent']:[]),...(hold?['--hold-ui']:[])],{encoding:'utf8'});
  if(opened.status!==0)throw new Error(opened.stderr);
  const owner=await waitFile('plugin-mcp-process.json',30);report=await waitFile('plugin-mcp-report.json',live?5400:180,owner.appPID);
  for(let i=0;i<100&&alive(owner.appPID);i++)await pause(100);
  if(alive(owner.appPID))throw new Error('Actual acceptance app remains live; preserve its handle');
  if(!report.success)throw new Error(report.error||'Native plugin MCP checks failed');
  report.independent={productionProfileUnchanged:isDeepStrictEqual(before,await productionSnapshot())};
  if(live) {
    const expected=JSON.parse(await readFile(path.join(output,'independent-expected.json'),'utf8')),actual=JSON.parse(await readFile(path.join(output,'repo/reconciliation.json'),'utf8')),task=JSON.parse(await readFile(path.join(output,'profile/agent',report.live.taskID+'.json'),'utf8'));
    const receipt=JSON.parse(await readFile(path.join(output,'profile/extensions/plugins/ledger-tools/receipt.json'),'utf8')),requests=JSON.parse('['+(await readFile(path.join(output,'http-requests.jsonl'),'utf8')).trim().split('\n').join(',')+']');
    report.independent.actualSavedFileMatchesIndependentDecimalCalculation=isDeepStrictEqual(actual,expected.result);
    report.independent.actualCsvRemainsUnchanged=hash(await readFile(path.join(output,'repo/sales.csv')))===expected.result.stdio.sourceSha256;
    report.independent.realHttpHeaderWasAccepted=requests.some(r=>r.event==='http-auth'&&r.authorized===true)&&requests.some(r=>r.event==='calculated'&&r.sourceSha256===expected.result.http.sourceSha256&&r.total===expected.result.http.total);
    report.independent.actualImportedPackageBytesMatchReviewedZip=receipt.sourceHash===expected.packageHash&&isDeepStrictEqual(receipt.hashes,expected.packageFiles);
    report.independent.packagedResourcesRemainPrivateAndUnchanged=(await Promise.all(Object.entries(expected.packageFiles).map(async([name,h])=>{const file=path.join(output,'profile/extensions/plugins/ledger-tools/payload',name);return hash(await readFile(file))===h&&((await lstat(file)).mode&0o777)===0o400;}))).every(Boolean);
    const receipts=task.modelReceipts??[];
    report.independent.realModelUsageFullyAccounted=receipts.length>0&&receipts.every(r=>Number.isInteger(r.inputTokens)&&Number.isInteger(r.outputTokens))&&task.inputTokens===receipts.reduce((n,r)=>n+r.inputTokens,0)&&task.outputTokens===receipts.reduce((n,r)=>n+r.outputTokens,0);
    report.independent.bothActualConnectorToolsCalled=task.messages.flatMap(m=>m.toolCalls??[]).filter(c=>c.name.startsWith('mcp_')).length>=2;
  }
  report.success&&=Object.values(report.independent).every(Boolean);
}catch(error){report={...(report??{}),success:false,error:error.message};}
finally {
  await writeFile(path.join(output,'plugin-mcp-driver-report.json'),JSON.stringify(report,null,2)+'\n');
  if(report?.success&&alive(http.pid))process.kill(http.pid,'SIGTERM');
  const archive=path.join(root,'evidence/agent',path.basename(output).replace('bluefatfish-','')+'-'+new Date().toISOString().replace(/[:.]/g,'-'));await mkdir(path.dirname(archive),{recursive:true});
  const copied=spawnSync('/usr/bin/ditto',[output,archive],{encoding:'utf8'});if(copied.status!==0)throw new Error(copied.stderr);
  console.log(JSON.stringify({success:report?.success,output,archive,error:report?.error}));
}
if(!report?.success)process.exitCode=1;

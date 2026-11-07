import { spawnSync } from 'node:child_process';
import { mkdir, mkdtemp, readFile, readdir, lstat, readlink, unlink, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { isDeepStrictEqual } from 'node:util';
import { fileURLToPath } from 'node:url';
import os from 'node:os';
import path from 'node:path';

const root = fileURLToPath(new URL('../', import.meta.url));
const option = name => { const i = process.argv.indexOf(name); return i < 0 ? undefined : process.argv[i + 1]; };
const resume = option('--resume'), output = resume ? path.resolve(resume) : await mkdtemp(path.join(os.tmpdir(), 'bluefatfish-plugins-'));
if (!path.basename(output).startsWith('bluefatfish-plugins-')) throw new Error('Use an actual plugin acceptance directory');
const live = process.argv.includes('--live-agent'), hold = process.argv.includes('--hold-ui');
const hash = data => createHash('sha256').update(data).digest('hex'), pause = ms => new Promise(resolve => setTimeout(resolve, ms));
const production = path.join(os.homedir(), 'Library/Application Support/BlueFatFish');
const names = ['settings.json', 'history.json', 'agent/index.json', 'agent/A7A38353-CBA2-431C-84F1-4903E73EA373.json', 'automations/definitions.json', 'models/catalog.json', 'extensions/mcp.json', 'extensions/hooks.json', 'extensions/hook-settings.json', 'extensions/settings.json', 'extensions/agents.json', 'extensions/teams.json', 'worktrees/policy.json', 'worktrees/history.json', 'worktrees/scheduler.lock', 'computer-use/settings.json'];
async function profileHashes() {
  const entries = await Promise.all(names.map(async name => [name, await readFile(path.join(production, name)).then(hash).catch(error => { if (error.code === 'ENOENT') return null; throw error; })]));
  async function walk(dir, relative = '') {
    const children = await readdir(dir, { withFileTypes: true }).catch(error => { if (error.code === 'ENOENT') return []; throw error; });
    for (const child of children.sort((a,b)=>a.name.localeCompare(b.name))) {
      const full = path.join(dir, child.name), name = path.join(relative, child.name);
      if (child.isSymbolicLink()) entries.push(['plugins/' + name, 'link:' + await readlink(full)]);
      else if (child.isDirectory()) await walk(full, name);
      else entries.push(['plugins/' + name, hash(await readFile(full))]);
    }
  }
  await walk(path.join(production, 'extensions/plugins')); return Object.fromEntries(entries);
}
const before = resume ? JSON.parse(await readFile(path.join(output, 'production-before.json'), 'utf8')) : await profileHashes();
const alive = pid => { try { process.kill(pid, 0); return true; } catch (error) { if (error.code === 'ESRCH') return false; throw error; } };
if (!isDeepStrictEqual(before, await profileHashes())) throw new Error('Production profile changed; preserve and inspect');
if (!resume) {
  await mkdir(path.join(output,'repo')); await mkdir(path.join(output,'shared-home'));
  await writeFile(path.join(output,'repo/sales.csv'),'item,amount\nA,14.20\nB,8.35\nC,21.10\n');
  const fixture = spawnSync('/usr/bin/python3', ['-c', String.raw`import json,pathlib,sys,zipfile,hashlib
from decimal import Decimal
p=pathlib.Path(sys.argv[1])
def archive(name,files,prefix=''):
 with zipfile.ZipFile(p/name,'w',zipfile.ZIP_DEFLATED) as z:
  for file,data in files.items(): z.writestr(prefix+file,data)
native={'.qoder-plugin/plugin.json':json.dumps({'name':'native-plugin','version':'1.0.0','author':{'name':'BlueFatFish acceptance'}}),'skills/check/SKILL.md':'---\nname: check\ndescription: 原生包资源检查\n---\n\n读取 references/check.txt。','skills/check/references/check.txt':'native-reference','commands/count.md':'---\ndescription: 参数检查\n---\n\n核对 $ARGUMENTS。'}
archive('native-plugin.zip',native)
archive('traversal.zip',{**native,'../outside.txt':'must-not-escape'})
archive('duplicate.zip',{**native,'skills/check/references/CHECK.txt':'alias'})
archive('unsupported.zip',{**native,'hooks/hook.json':'{}'})
missing={**native,'.qoder-plugin/plugin.json':json.dumps({'name':'missing-plugin','skills':'missing','commands':'commands'})};archive('missing.zip',missing)
archive('ordinary.skill',{'SKILL.md':'---\nname: ordinary-check\ndescription: 原有单项 Skill ZIP\n---\n\n读取实际输入。','references/plain.txt':'ordinary-reference'},'ordinary-check/')
plugin={'.qoder-plugin/plugin.json':json.dumps({'name':'sales-workbench','displayName':'销售工作台','version':'1.0.0','description':'按实际销售数据生成核对结果。','author':{'name':'BlueFatFish acceptance'}},ensure_ascii=False),'README.md':'# 销售工作台\n\n包含销售核对 Skill、交接命令及输出格式。\n','skills/review-sales/SKILL.md':'---\nname: review-sales\ndescription: 核对当前销售 CSV，按已有约定生成实际结果。\n---\n\n先通过 read_skill_resource 读取 references/report.json，再读取当前项目 sales.csv。用整数分计算合计，将符合 review_minimum 的 item 放入 review 数组。按参考约定创建 summary.json，total 必须是两位小数字符串，rows 是数据行数，currency 取参考约定。仅使用现有文件和工具。保存后必须 read_file 回读 summary.json 并核对实际内容。不要修改 CSV，不运行命令、不联网。\n','skills/review-sales/references/report.json':json.dumps({'currency':'CNY','review_minimum':'20.00','fields':['total','rows','review','currency']}),'commands/handoff.md':'---\ndescription: 根据已完成工作整理交接。\n---\n\n根据本任务实际文件与执行记录整理交接，保留来源。$ARGUMENTS\n'}
archive('sales-workbench.zip',plugin,'sales-workbench/')
rows=[line.split(',') for line in (p/'repo/sales.csv').read_text().strip().splitlines()[1:]]
expected={'total':format(sum(Decimal(row[1]) for row in rows),'.2f'),'rows':len(rows),'review':[row[0] for row in rows if Decimal(row[1])>=Decimal('20.00')],'currency':'CNY'}
(p/'independent-expected.json').write_text(json.dumps({'result':expected,'packageFiles':{key:hashlib.sha256(value.encode()).hexdigest() for key,value in plugin.items()},'packageHash':hashlib.sha256((p/'sales-workbench.zip').read_bytes()).hexdigest()},ensure_ascii=False))
`, output], { encoding:'utf8' });
  if (fixture.status !== 0) throw new Error(fixture.stderr || 'Actual plugin ZIP creation failed');
  await writeFile(path.join(output,'production-before.json'),JSON.stringify(before,null,2));
} else {
  const previous = JSON.parse(await readFile(path.join(output,'plugin-process.json'),'utf8'));
  if (alive(previous.appPID)) throw new Error('Original plugin acceptance app is live; continue its actual handle');
  for (const name of ['plugin-report.json','plugin-process.json','plugin-ui-ready.json','plugin-disabled-verified.json','verify-plugin-disabled','finish-plugin-ui']) await unlink(path.join(output,name)).catch(error=>{if(error.code!=='ENOENT')throw error;});
}
const inputHash = hash(await readFile(path.join(output,'repo/sales.csv')));
async function waitFile(name, seconds, owner) {
  const deadline = Date.now()+seconds*1000;
  while(Date.now()<deadline) {
    try { return JSON.parse(await readFile(path.join(output,name),'utf8')); } catch(error) { if(error.code!=='ENOENT' && !(error instanceof SyntaxError))throw error; }
    if(owner && !alive(owner)) throw new Error('Actual app exited before '+name);
    await pause(300);
  }
  throw new Error('Observation deadline reached for '+name+'; preserve the live original handle');
}
let report;
console.log(JSON.stringify({output,live,hold}));
try {
  if(live&&!hold)throw new Error('Real plugin acceptance requires --hold-ui');
  const launched=spawnSync('/usr/bin/open',['-n',path.join(root,'build/蓝色大肥鱼.app'),'--args','--check',output,'--extension-check','--plugin-check',...(live?['--live-agent']:[]),...(hold?['--hold-ui']:[])],{encoding:'utf8'});
  if(launched.status!==0)throw new Error(launched.stderr);
  const owner=await waitFile('plugin-process.json',30);report=await waitFile('plugin-report.json',live?5400:180,owner.appPID);
  for(let i=0;i<100&&alive(owner.appPID);i++)await pause(100);
  if(alive(owner.appPID))throw new Error('Acceptance app remains live; preserve its actual handle');
  if(!report.success)throw new Error(report.error||'Plugin checks failed');
  report.independent={productionProfileUnchanged:isDeepStrictEqual(before,await profileHashes()),actualCsvUnchanged:inputHash===hash(await readFile(path.join(output,'repo/sales.csv')))};
  if(live) {
    const expected=JSON.parse(await readFile(path.join(output,'independent-expected.json'),'utf8')), actual=JSON.parse(await readFile(path.join(output,'repo/summary.json'),'utf8'));
    const task=JSON.parse(await readFile(path.join(output,'profile/agent',report.live.taskID+'.json'),'utf8')),receipts=task.modelReceipts??[],plugin=path.join(output,'profile/extensions/plugins/sales-workbench'),receipt=JSON.parse(await readFile(path.join(plugin,'receipt.json'),'utf8'));
    report.independent.actualFileMatchesIndependentDecimalCalculation=isDeepStrictEqual(actual,expected.result);
    report.independent.importedBytesMatchActualZip=receipt.sourceHash===expected.packageHash&&isDeepStrictEqual(receipt.hashes,expected.packageFiles);
    const resources=await Promise.all(Object.entries(expected.packageFiles).map(async([name,h])=>hash(await readFile(path.join(plugin,'payload',name)))===h&&((await lstat(path.join(plugin,'payload',name))).mode&0o777)===0o400));
    report.independent.packagedResourcesRemainPrivateAndUnchanged=resources.every(Boolean);
    report.independent.actualModelUsageFullyAccounted=receipts.length>0&&receipts.every(r=>Number.isInteger(r.inputTokens)&&Number.isInteger(r.outputTokens))&&task.inputTokens===receipts.reduce((n,r)=>n+r.inputTokens,0)&&task.outputTokens===receipts.reduce((n,r)=>n+r.outputTokens,0);
    report.independent.onlyAssignedToolsUsed=task.messages.flatMap(m=>m.toolCalls??[]).every(c=>['load_tools','read_file','write_file','list_skills','read_skill','read_skill_resource','unload_skill','update_plan','ask_user','read_task_history','finish_task'].includes(c.name));
  }
  report.success&&=Object.values(report.independent).every(Boolean);
} catch(error) { report={...(report??{}),success:false,error:error.message}; }
finally {
  await writeFile(path.join(output,'plugin-driver-report.json'),JSON.stringify(report,null,2)+'\n');
  const archive=path.join(root,'evidence/agent',path.basename(output).replace('bluefatfish-','')+'-'+new Date().toISOString().replace(/[:.]/g,'-'));await mkdir(path.dirname(archive),{recursive:true});
  const copied=spawnSync('/usr/bin/ditto',[output,archive],{encoding:'utf8'});if(copied.status!==0)throw new Error(copied.stderr);
  console.log(JSON.stringify({success:report?.success,output,archive,error:report?.error}));
}
if(!report?.success)process.exitCode=1;

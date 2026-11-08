import { spawnSync } from 'node:child_process';
import { mkdir, mkdtemp, readFile, writeFile, copyFile, unlink } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { isDeepStrictEqual } from 'node:util';
import { fileURLToPath } from 'node:url';
import os from 'node:os';
import path from 'node:path';

const root = fileURLToPath(new URL('../', import.meta.url));
const option = name => { const index = process.argv.indexOf(name); return index < 0 ? undefined : process.argv[index + 1]; };
const resume = option('--resume'), output = resume ? path.resolve(resume) : await mkdtemp(path.join(os.tmpdir(), 'bluefatfish-office-'));
if (!path.basename(output).startsWith('bluefatfish-office-')) throw new Error('Use an actual Office acceptance directory');
const python = option('--python') ?? '/usr/bin/python3', live = process.argv.includes('--live-agent'), hold = process.argv.includes('--hold-ui');
const outputLimit = option('--office-output-limit');
if(outputLimit !== undefined && (!/^[0-9]+$/.test(outputLimit) || +outputLimit < 512 || +outputLimit > 4096)) throw new Error('Office acceptance output limit must be 512 through 4096');
const hash = data => createHash('sha256').update(data).digest('hex'), pause = ms => new Promise(resolve => setTimeout(resolve, ms));
const alive = pid => { try { process.kill(pid, 0); return true; } catch(error) { if(error.code === 'ESRCH') return false; throw error; } };
const production = path.join(os.homedir(), 'Library/Application Support/BlueFatFish');
async function productionSnapshot() {
  const names = ['settings.json','history.json','agent/index.json','agent/A7A38353-CBA2-431C-84F1-4903E73EA373.json','automations/definitions.json','models/catalog.json','extensions/mcp.json','extensions/hooks.json','extensions/hook-settings.json','extensions/settings.json','extensions/agents.json','extensions/teams.json','worktrees/policy.json','worktrees/history.json','worktrees/scheduler.lock','computer-use/settings.json'];
  const entries = await Promise.all(names.map(async name => [name, await readFile(path.join(production, name)).then(hash).catch(error => { if(error.code === 'ENOENT') return null; throw error; })]));
  return Object.fromEntries(entries);
}
async function waitFile(name, seconds, owner) {
  const deadline = Date.now() + seconds * 1000;
  while(Date.now() < deadline) {
    try { return JSON.parse(await readFile(path.join(output, name), 'utf8')); } catch(error) { if(error.code !== 'ENOENT' && !(error instanceof SyntaxError)) throw error; }
    if(owner && !alive(owner)) {
      const actual = await readFile(path.join(output, 'office-report.json'), 'utf8').then(JSON.parse).catch(() => null);
      throw new Error(actual?.error ?? 'Actual Office acceptance app exited before ' + name);
    }
    await pause(300);
  }
  throw new Error('Observation deadline for ' + name + '; preserve the actual running handle');
}
function independent(saved, reviewer) {
  const result = spawnSync(python, [path.join(root, 'scripts/fixtures/verify-office-documents.py'), path.join(output, 'originals'), saved, reviewer], { encoding: 'utf8' });
  let report; try { report = JSON.parse(result.stdout); } catch { throw new Error(result.stderr || result.stdout || 'Independent Office readback failed'); }
  if(result.status !== 0 || !report.success) throw new Error(JSON.stringify(report));
  return report;
}
const before = resume ? JSON.parse(await readFile(path.join(output, 'production-before.json'), 'utf8')) : await productionSnapshot();
if (!isDeepStrictEqual(before, await productionSnapshot())) throw new Error('Production profile changed; preserve and inspect');
if(!resume) {
  await writeFile(path.join(output, 'production-before.json'), JSON.stringify(before, null, 2));
  for(const directory of ['originals','repo','shared-home']) await mkdir(path.join(output, directory));
  const result = spawnSync(python, [path.join(root, 'scripts/fixtures/office-documents.py'), path.join(output, 'originals')], { encoding: 'utf8' });
  if(result.status !== 0) throw new Error(result.stderr || result.stdout || 'Prepare a Python environment with python-docx, openpyxl, python-pptx and Pillow');
  for(const ext of ['docx','xlsx','pptx']) await copyFile(path.join(output,'originals','sample.'+ext), path.join(output,'repo','sample.'+ext));
} else {
  const previous = await readFile(path.join(output, 'office-process.json'),'utf8').then(JSON.parse).catch(error => { if(error.code === 'ENOENT') return null; throw error; });
  if(previous && alive(previous.appPID)) throw new Error('Original Office acceptance app is live; continue its existing handle');
  for(const name of ['office-process.json','office-report.json','office-ui-ready.json','finish-office-ui']) await unlink(path.join(output, name)).catch(error => { if(error.code !== 'ENOENT') throw error; });
}
console.log(JSON.stringify({output, live, hold}));
if(process.argv.includes('--prepare-only')) process.exit(0);
if(live && !hold) throw new Error('Actual Office model acceptance requires --hold-ui');
let report;
try {
  const opened = spawnSync('/usr/bin/open', ['-n', path.join(root, 'build/蓝色大肥鱼.app'), '--args', '--check', output, '--office-check', ...(live ? ['--live-agent'] : []), ...(hold ? ['--hold-ui'] : []), ...(outputLimit ? ['--office-output-limit', outputLimit] : [])], { encoding: 'utf8' });
  if(opened.status !== 0) throw new Error(opened.stderr);
  const owner = await waitFile('office-process.json', 30);
  const ready = await waitFile('office-ui-ready.json', live ? 2100 : 240, owner.appPID);
  const nativeName = 'office-native-' + owner.candidateHash.slice(0, 12) + '.json', native = JSON.parse(await readFile(path.join(output, nativeName), 'utf8'));
  const proof = { native: independent(native.workspace, '审阅人：原生验收') };
  if(live) proof.live = independent(path.join(output,'repo'), '审阅人：海盐-2086');
  await writeFile(path.join(output, 'office-independent-before-ui.json'), JSON.stringify(proof, null, 2));
  console.log(JSON.stringify({phase:'actual-ui-ready', output, appPID:ready.appPID, taskID:ready.taskID, independent:true}));
  report = await waitFile('office-report.json', hold ? 1500 : 60, owner.appPID);
  for(let i=0; i<100 && alive(owner.appPID); i++) await pause(100);
  if(alive(owner.appPID)) throw new Error('Actual Office acceptance app remains live; preserve its handle');
  if(!report.success) throw new Error(report.error || 'Actual Office check failed');
  report.independent = { ...proof, productionProfileUnchanged:isDeepStrictEqual(before, await productionSnapshot()) };
  const inputs = JSON.parse(await readFile(path.join(output,'originals/source-sha256.json'),'utf8'));
  report.independent.originalInputFilesUnchanged = (await Promise.all(Object.entries(inputs).map(async ([name, expected]) => hash(await readFile(path.join(output,'originals',name))) === expected))).every(Boolean);
  if(live) {
    const result = JSON.parse(await readFile(path.join(output,'office-live-result.json'),'utf8')), task = JSON.parse(await readFile(path.join(output,'profile/agent',result.taskID+'.json'),'utf8'));
    const receipts = task.modelReceipts ?? [], calls = task.messages.flatMap(message => message.toolCalls ?? []);
    report.independent.actualModelReceiptsAccounted = receipts.length > 0 && receipts.every(r => Number.isInteger(r.inputTokens) && Number.isInteger(r.outputTokens)) && task.inputTokens === receipts.reduce((n,r)=>n+r.inputTokens,0) && task.outputTokens === receipts.reduce((n,r)=>n+r.outputTokens,0);
    report.independent.actualModelUsedOfficeOnly = calls.some(call => call.name==='office_edit') && calls.every(call => ['office_read','office_edit','load_tools','update_plan'].includes(call.name));
  }
  report.success &&= Object.values(report.independent).every(value => typeof value !== 'boolean' || value);
} catch(error) { report = {...(report ?? {}), success:false, error:error.message}; }
finally {
  await writeFile(path.join(output,'office-driver-report.json'),JSON.stringify(report,null,2));
  const archive = path.join(root,'evidence/agent',path.basename(output).replace('bluefatfish-','')+'-'+new Date().toISOString().replace(/[:.]/g,'-'));
  await mkdir(path.dirname(archive),{recursive:true});
  const copied = spawnSync('/usr/bin/ditto',[output,archive],{encoding:'utf8'});if(copied.status!==0)throw new Error(copied.stderr);
  console.log(JSON.stringify({success:report?.success,output,archive,error:report?.error}));
}
if(!report?.success)process.exitCode=1;

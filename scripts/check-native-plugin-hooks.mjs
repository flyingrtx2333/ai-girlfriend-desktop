import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { createServer } from 'node:http';
import { appendFile, mkdir, mkdtemp, readFile, readdir, readlink, writeFile } from 'node:fs/promises';
import { isDeepStrictEqual } from 'node:util';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import os from 'node:os';

const option = name => { const i = process.argv.indexOf(name); return i < 0 ? undefined : process.argv[i + 1]; };
const app = option('--app');
if (!app) throw new Error('Pass the exact signed candidate with --app; this check never launches the daily application');
const root = fileURLToPath(new URL('../', import.meta.url)), output = await mkdtemp(path.join(os.tmpdir(), 'bluefatfish-plugin-hooks-配置 '));
const hash = value => createHash('sha256').update(value).digest('hex'), pause = ms => new Promise(resolve => setTimeout(resolve, ms));
const production = path.join(os.homedir(), 'Library/Application Support/BlueFatFish');
async function profileHashes() {
  const result = {}, names = ['settings.json', 'history.json', 'organization.json', 'agent/index.json', 'extensions/hooks.json', 'extensions/hook-settings.json'];
  for (const name of await readdir(path.join(production, 'agent')).catch(e => { if (e.code === 'ENOENT') return []; throw e; })) if (/^[A-Fa-f0-9-]{36}\.json$/.test(name)) names.push('agent/' + name);
  for (const name of names) result[name] = await readFile(path.join(production, name)).then(hash).catch(e => { if (e.code === 'ENOENT') return null; throw e; });
  async function walk(folder, prefix) {
    const entries = await readdir(folder, { withFileTypes: true }).catch(e => { if (e.code === 'ENOENT') return []; throw e; });
    result[prefix + '/'] = entries.length;
    for (const entry of entries) { const full = path.join(folder, entry.name), name = prefix + '/' + entry.name; if (entry.isSymbolicLink()) result[name] = 'link:' + await readlink(full); else if (entry.isDirectory()) await walk(full, name); else result[name] = hash(await readFile(full)); }
  }
  for (const name of ['plugins', 'plugin-hooks']) await walk(path.join(production, 'extensions', name), 'extensions/' + name);
  return result;
}
const before = await profileHashes();
await mkdir(path.join(output, 'real project')); await mkdir(path.join(output, 'shared-home'));
await writeFile(path.join(output, 'real project/source.txt'), await readFile(path.join(root, 'README.md')));
await writeFile(path.join(output, 'reference.txt'), await readFile(path.join(root, 'package.json')));
let httpRequests = 0;
const server = createServer(async (request, response) => {
  try {
    let bytes = Buffer.alloc(0); for await (const part of request) { bytes = Buffer.concat([bytes, part]); if (bytes.length > 500_000) throw new Error('Input too large'); }
    const body = JSON.parse(bytes.toString('utf8')), matched = request.headers['x-plugin-check'] === 'public-plugin-header';
    if (request.url !== '/hook-check' || !matched) { response.writeHead(403); response.end(); return; }
    const sourceHash = hash(await readFile(path.join(output, 'real project/source.txt'))); httpRequests++;
    await appendFile(path.join(output, 'http-requests.jsonl'), JSON.stringify({ headerMatched: matched, event: body.hook_event_name, sourceHash }) + '\n');
    response.writeHead(200, { 'Content-Type': 'application/json' }); response.end(JSON.stringify({ hookSpecificOutput: { hookEventName: body.hook_event_name, additionalContext: 'http.source=' + sourceHash + '; echo=' + request.headers['x-plugin-check'] } }));
  } catch (error) { response.writeHead(500); response.end(error.message); }
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
let report;
try {
  const url = 'http://127.0.0.1:' + server.address().port + '/hook-check';
  const made = spawnSync(process.env.BLUEFATFISH_CHECK_PYTHON || '/opt/homebrew/bin/python3', ['-c', String.raw`import json,pathlib,sys,zipfile
p=pathlib.Path(sys.argv[1]);node=sys.argv[2];url=sys.argv[3];macro='$'+'{PLUGIN_ROOT}'
runner="""const fs=require('node:fs'),crypto=require('node:crypto'),cp=require('node:child_process'),path=require('node:path');
const input=JSON.parse(fs.readFileSync(0,'utf8')),mode=process.argv[2],root=process.env.PLUGIN_ROOT;
const sha=bytes=>crypto.createHash('sha256').update(bytes).digest('hex');
if(mode==='slow') { const child=cp.spawn('/bin/sleep',['30'],{stdio:'ignore'}); fs.writeFileSync(path.join(input.cwd,'slow-pids.json'),JSON.stringify({pid:process.pid,child:child.pid})); setTimeout(()=>console.log(JSON.stringify({hookSpecificOutput:{hookEventName:input.hook_event_name,additionalContext:'late result must not be delivered'}})),30000); }
else if(mode==='block') { if(input.tool_input?.path==='blocked.txt') { console.error('plugin policy blocked'); process.exitCode=2; } else console.log('{}'); }
else { const source=sha(fs.readFileSync(path.join(input.cwd,'source.txt'))),ref=sha(fs.readFileSync(path.join(root,'resources/reference.txt'))),rootOK=root===process.env.QODER_PLUGIN_ROOT&&root===process.env.CLAUDE_PLUGIN_ROOT&&root===process.env.QODER_HOOK_ROOT; console.log(JSON.stringify({hookSpecificOutput:{hookEventName:input.hook_event_name,additionalContext:'source='+source+'; ref='+ref+'; rootOK='+rootOK+'; marker='+process.env.PUBLIC_MARKER}})); }
"""
def archive(name,files,prefix=''):
 with zipfile.ZipFile(p/name,'w',zipfile.ZIP_DEFLATED) as z:
  for key,value in files.items():z.writestr(prefix+key,value)
def command(name,mode='source',**extra):return {'name':name,'type':'command','command':node,'args':[macro+'/hooks/runner.cjs',mode],'env':{'PUBLIC_MARKER':'public-plugin-marker'},'timeout':10,**extra}
hooks={'hooks':{'SessionStart':[{'hooks':[command('source')]}],'InstructionsLoaded':[{'hooks':[{'name':'shell-root','type':'command','command':node+' "$QODER_PLUGIN_ROOT/hooks/runner.cjs" source','env':{'PUBLIC_MARKER':'public-plugin-marker'},'timeout':10}]}],'PreToolUse':[{'matcher':'Read','hooks':[command('conditional-block','block',**{'if':'Read(blocked.txt)'})]}],'PostToolUse':[{'async':True,'hooks':[command('slow','slow',timeout=40)]}],'Notification':[{'hooks':[{'name':'local-http','type':'http','url':url,'headers':{'X-Plugin-Check':'public-plugin-header'},'allowedEnvVars':[],'timeout':10}]}],'StopFailure':[{'hooks':[{'name':'pending-model','type':'prompt','prompt':'核对当前事件 $ARGUMENTS，返回实际依据。'}]}],'SessionEnd':[{'hooks':[{'name':'pending-agent','type':'agent','prompt':'读取当前项目后返回实际依据。','tools':['Read'],'maxTurns':1}]}]}}
resources={'hooks/runner.cjs':runner,'resources/reference.txt':(p/'reference.txt').read_bytes()}
native={'.qoder-plugin/plugin.json':json.dumps({'name':'native-hooks','version':'1.0.0'}),'hooks/hooks.json':json.dumps(hooks,ensure_ascii=False),**resources};archive('native-hooks.zip',native)
plain={'hooks':{'SessionStart':[{'hooks':[{'name':'plain','type':'command','command':'/usr/bin/true'}]}]}}
archive('inline-hooks.zip',{'.qoder-plugin/plugin.json':json.dumps({'name':'inline-hooks','hooks':plain})})
archive('array-hooks.zip',{'.qoder-plugin/plugin.json':json.dumps({'name':'array-hooks','hooks':['configs/check.json']}),'configs/check.json':json.dumps(plain)})
archive('missing-hooks.zip',{'.qoder-plugin/plugin.json':json.dumps({'name':'missing-hooks','hooks':'absent.json'})})
bad=json.loads(json.dumps(plain));bad['hooks']['SessionStart'][0]['hooks'][0]['imaginaryPermission']=True;archive('bad-field.zip',{'.qoder-plugin/plugin.json':json.dumps({'name':'bad-field','hooks':bad})})
bad=json.loads(json.dumps(plain));bad['hooks']['SessionStart'][0]['hooks'][0]['network']='true';archive('bad-network.zip',{'.qoder-plugin/plugin.json':json.dumps({'name':'bad-network','hooks':bad})})
bad=json.loads(json.dumps(plain));bad['hooks']['SessionStart'][0]['hooks'][0]['env']={'PLUGIN_ROOT':'/untrusted'};archive('reserved-env.zip',{'.qoder-plugin/plugin.json':json.dumps({'name':'reserved-env','hooks':bad})})
archive('orphan-hooks.zip',{'.qoder-plugin/plugin.json':json.dumps({'name':'orphan-hooks'}),'hooks/unknown.json':'{}'})
ui={'.qoder-plugin/plugin.json':json.dumps({'name':'review-hooks','displayName':'文件核对 Hook','version':'1.0.0','author':{'name':'BlueFatFish acceptance'}}),'hooks/hooks.json':json.dumps({'hooks':{'SessionStart':[{'hooks':[command('核对公开来源')]}]}},ensure_ascii=False),'README.md':'# 文件核对 Hook\n\n启动任务时核对当前项目与包内公开来源。\n',**resources};archive('review-hooks.zip',ui,'review-hooks/')
`, output, process.execPath, url], { encoding: 'utf8' });
  if (made.status !== 0) throw new Error(made.stderr || 'ZIP creation failed');
  const inputs = {}; for (const name of (await readdir(output)).filter(name => name.endsWith('.zip') || name === 'reference.txt')) inputs[name] = hash(await readFile(path.join(output, name))); inputs['real project/source.txt'] = hash(await readFile(path.join(output, 'real project/source.txt')));
  await writeFile(path.join(output, 'input-hashes.json'), JSON.stringify(inputs, null, 2)); await writeFile(path.join(output, 'production-before.json'), JSON.stringify(before, null, 2));
  const signed = spawnSync('/usr/bin/codesign', ['--verify', '--deep', '--strict', path.resolve(app)], { encoding: 'utf8' }); if (signed.status !== 0) throw new Error(signed.stderr);
  const binaryHash = hash(await readFile(path.join(app, 'Contents/MacOS/BlueFatFish')));
  console.log(JSON.stringify({ output, app: path.resolve(app), binaryHash, actualHTTPServerPort: server.address().port, modelTransmission: 'blocked' }));
  const opened = spawnSync('/usr/bin/open', ['-g', '-n', path.resolve(app), '--args', '--check', output, '--plugin-hook-check', '--background-component-check'], { encoding: 'utf8' }); if (opened.status !== 0) throw new Error(opened.stderr);
  const deadline = Date.now() + 180_000;
  while (Date.now() < deadline) { try { report = JSON.parse(await readFile(path.join(output, 'plugin-hook-result.json'), 'utf8')); break; } catch (error) { if (error.code !== 'ENOENT' && !(error instanceof SyntaxError)) throw error; } await pause(150); }
  if (!report) throw new Error('Native observation deadline reached; no restart or replacement was performed');
  const alive = pid => { const state = spawnSync('/bin/ps', ['-p', String(pid), '-o', 'stat='], { encoding: 'utf8' }).stdout.trim(); return state.length > 0 && !state.startsWith('Z'); };
  for (let i = 0; i < 100 && alive(report.appPID); i++) await pause(100);
  const task = report.checkedTaskID ? JSON.parse(await readFile(path.join(output, 'profile/agent', report.checkedTaskID + '.json'), 'utf8')) : null;
  const contexts = (task?.events ?? []).map(event => event.hook?.effect?.context ?? '').join('\n');
  report.independent = { actualApplicationExited: !alive(report.appPID), actualCancelledProcessesExited: (report.actualCancelledPIDs ?? []).length === 2 && report.actualCancelledPIDs.every(pid => !alive(pid)), binaryMatchesCandidate: report.binaryHash === binaryHash, dailyProfileUnchanged: isDeepStrictEqual(before, await profileHashes()), publicInputsAndZIPsUnchanged: (await Promise.all(Object.entries(inputs).map(async ([name, h]) => hash(await readFile(path.join(output, name))) === h))).every(Boolean), actualProjectAndPackageHashesReturned: contexts.includes('source=' + inputs['real project/source.txt']) && contexts.includes('ref=' + inputs['reference.txt']), realAuthenticatedHTTPWasObserved: httpRequests === 1, noModelCallOrActiveJob: report.blockedModelAttempts === 0 && report.activeHookJobs === false, backgroundRemainsInactive: report.activationCount === 0 && report.applicationActive === false && report.visibleWindowCount === 0 };
  report.success &&= Object.values(report.independent).every(Boolean);
} catch (error) { report = { ...(report ?? {}), success: false, error: error.message }; }
finally { server.closeAllConnections?.(); await new Promise(resolve => server.close(resolve)); await writeFile(path.join(output, 'plugin-hook-driver-report.json'), JSON.stringify(report, null, 2) + '\n'); }
console.log(JSON.stringify({ output, success: report.success, nativeChecks: Object.keys(report.checks ?? {}).length, independent: report.independent, error: report.error, actualHTTPServerClosed: true }));
if (!report.success) process.exitCode = 1;

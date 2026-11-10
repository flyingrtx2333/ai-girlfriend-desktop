import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdir, mkdtemp, readFile, readdir, readlink, writeFile } from 'node:fs/promises';
import { isDeepStrictEqual } from 'node:util';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import os from 'node:os';

const option = name => { const i = process.argv.indexOf(name); return i < 0 ? undefined : process.argv[i + 1]; };
const app = option('--app'); if (!app) throw new Error('Pass the exact signed candidate with --app');
const root = fileURLToPath(new URL('../', import.meta.url)), output = await mkdtemp(path.join(os.tmpdir(), 'bluefatfish-plugin-rules-规则 '));
const hash = value => createHash('sha256').update(value).digest('hex'), pause = ms => new Promise(resolve => setTimeout(resolve, ms));
const production = path.join(os.homedir(), 'Library/Application Support/BlueFatFish');
async function dailyHashes() {
  const names = ['settings.json', 'history.json', 'organization.json', 'agent/index.json', 'extensions/agents.json', 'extensions/hooks.json', 'extensions/hook-settings.json'];
  for (const name of await readdir(path.join(production, 'agent')).catch(e => { if (e.code === 'ENOENT') return []; throw e; })) if (/^[A-Fa-f0-9-]{36}\.json$/.test(name)) names.push('agent/' + name);
  const result = {};
  for (const name of names) result[name] = await readFile(path.join(production, name)).then(hash).catch(e => { if (e.code === 'ENOENT') return null; throw e; });
  async function walk(folder, prefix) { for (const item of await readdir(folder, { withFileTypes: true }).catch(e => { if (e.code === 'ENOENT') return []; throw e; })) { const file = path.join(folder, item.name), key = prefix + '/' + item.name; if (item.isSymbolicLink()) result[key] = 'link:' + await readlink(file); else if (item.isDirectory()) await walk(file, key); else result[key] = hash(await readFile(file)); } }
  await walk(path.join(production, 'extensions/plugins'), 'extensions/plugins'); await walk(path.join(production, 'extensions/plugin-hooks'), 'extensions/plugin-hooks'); return result;
}
const before = await dailyHashes(); await mkdir(path.join(output, 'real project')); await mkdir(path.join(output, 'other project')); await mkdir(path.join(output, 'shared-home'));
await writeFile(path.join(output, 'public-readme.md'), await readFile(path.join(root, 'README.md'))); await writeFile(path.join(output, 'public-package.json'), await readFile(path.join(root, 'package.json'))); await writeFile(path.join(output, 'node-path.txt'), process.execPath);
const made = spawnSync(process.env.BLUEFATFISH_CHECK_PYTHON || '/opt/homebrew/bin/python3', ['-c', String.raw`import json,pathlib,sys,zipfile,subprocess
p=pathlib.Path(sys.argv[1]);project=p/'real project';source=(p/'public-readme.md').read_bytes()
names=['src/api.ts','src/client.ts','src/vendor/excluded.ts','src/deep/nested.ts','docs/README.md','README.md','a.ts','src/alpha.ts','src/beta.ts','src/gamma.ts']
for name in names:
 f=project/name;f.parent.mkdir(parents=True,exist_ok=True);f.write_bytes(source)
(p/'external.md').write_bytes(source);(project/'src/linked.ts').symlink_to(p/'external.md')
(project/'slow.cjs').write_text("const fs=require('node:fs'),cp=require('node:child_process');const child=cp.spawn('/bin/sleep',['30'],{stdio:'ignore'});fs.writeFileSync('slow-pids.json',JSON.stringify({pid:process.pid,child:child.pid}));setTimeout(()=>console.log('finished actual process'),30000);")
def archive(name,files,prefix=''):
 with zipfile.ZipFile(p/name,'w',zipfile.ZIP_DEFLATED) as z:
  for key,value in files.items():z.writestr(prefix+key,value)
def rule(front,body):return ('---\n'+front+'\n---\n\n' if front else '')+body+'\n'
rules={'rules/always.md':rule('','# 核对约定\n提交结论前核对实际来源。RULE_ALWAYS_381'),'rules/manual.md':rule('trigger: manual\ndescription: 用户明确选择时核对来源','# 手动审阅\n保留原文和引用。RULE_MANUAL_583'),'rules/decision.md':rule('trigger: model_decision\ndescription: 核对项目元信息时选择','# 项目信息\n按实际读取的项目说明回答。RULE_DECISION_BODY_482'),'rules/code/api.md':rule('trigger: glob\nglob: ["src/**/*.ts", "!src/vendor/**"]','# 源码审阅\n先读源码再作结论。RULE_GLOB_684')}
base={'.qoder-plugin/plugin.json':json.dumps({'name':'native-rules','version':'1.0.0'}),'resources/reference.txt':(p/'public-package.json').read_bytes(),**rules};archive('native-rules.zip',base)
archive('declared-rules.zip',{'.qoder-plugin/plugin.json':json.dumps({'name':'declared-rules','rules':['custom/check.md']}),'custom/check.md':rule('paths:\n  - "**/*.ts"\n  - "/*.md"\nalwaysApply: false','根据实际文件判断。')})
archive('precedence-rules.zip',{'.qoder-plugin/plugin.json':json.dumps({'name':'precedence-rules','rules':'custom.md'}),'custom.md':rule('trigger: manual\nalwaysApply: true','仅明确选择后应用。')})
archive('bom-rules.zip',{'.qoder-plugin/plugin.json':json.dumps({'name':'bom-rules'}),'rules/manual.md':('\ufeff'+rule('trigger: manual','仅明确选择后应用。')).replace('\n','\r').encode('utf-8')})
archive('bad-pattern-type.zip',{'.qoder-plugin/plugin.json':json.dumps({'name':'bad-pattern-type'}),'rules/invalid.md':rule('paths: [true]','核对来源。')})
for filename,front in [('bad-trigger.zip','trigger: imaginary'),('bad-decision.zip','trigger: model_decision'),('bad-boolean.zip','alwaysApply: enabled'),('bad-glob.zip','trigger: glob\nglob: "src/[abc"'),('bad-field.zip','unknownPermission: true')]:archive(filename,{'.qoder-plugin/plugin.json':json.dumps({'name':'invalid-rules'}),'rules/check.md':rule(front,'核对真实来源。')})
archive('orphan-rules.zip',{'.qoder-plugin/plugin.json':json.dumps({'name':'orphan-rules'}),'rules/unsupported.txt':'unparsed rule'})
archive('duplicate-rules.zip',{'.qoder-plugin/plugin.json':json.dumps({'name':'duplicate-rules','rules':['rules','rules/always.md']}),**rules})
ui={'.qoder-plugin/plugin.json':json.dumps({'name':'review-rules','displayName':'文件审阅规则','version':'1.0.0','author':{'name':'BlueFatFish acceptance'}}),'README.md':'# 文件审阅规则\n\n按实际来源核对结论，保留项目文件。\n',**{k:v.replace('RULE_','UI_RULE_') for k,v in rules.items()}};archive('review-rules.zip',ui,'review-rules/')
subprocess.run(['/usr/bin/git','init','--quiet',str(project)],check=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
groups=[['**/*.ts'],['*.md'],['/*.md'],['src/**/*.ts','!src/vendor/**'],['src/*.ts'],['src/[ab]*.ts'],['src[!a]api.ts'],['src[!-z]api.ts'],['src/**'],['docs/']];oracle=[]
for patterns in groups:
 (project/'.gitignore').write_text('\n'.join(patterns)+'\n');r=subprocess.run(['/usr/bin/git','-C',str(project),'check-ignore','--no-index','--stdin','-z'],input='\0'.join(names).encode()+b'\0',stdout=subprocess.PIPE,stderr=subprocess.PIPE);assert r.returncode in (0,1),r.stderr
 matches=set(r.stdout.decode().strip('\0').split('\0'));oracle.extend({'patterns':patterns,'path':name,'matched':name in matches} for name in names)
(project/'.gitignore').unlink();(p/'glob-oracle.json').write_text(json.dumps(oracle,indent=2))
`, output], { encoding: 'utf8' }); if (made.status !== 0) throw new Error(made.stderr || 'Actual ZIP or Git oracle preparation failed');
const inputs = {}; async function collect(folder, prefix = '') { for (const item of await readdir(folder, { withFileTypes: true })) { const full = path.join(folder, item.name), key = prefix + item.name; if (item.isDirectory() && item.name !== '.git') await collect(full, key + '/'); else if (item.isFile()) inputs[key] = hash(await readFile(full)); } } await collect(output);
await writeFile(path.join(output, 'input-hashes.json'), JSON.stringify(inputs, null, 2)); await writeFile(path.join(output, 'production-before.json'), JSON.stringify(before, null, 2));
const signed = spawnSync('/usr/bin/codesign', ['--verify', '--deep', '--strict', path.resolve(app)], { encoding: 'utf8' }); if (signed.status !== 0) throw new Error(signed.stderr);
const binaryHash = hash(await readFile(path.join(app, 'Contents/MacOS/BlueFatFish'))); console.log(JSON.stringify({ output, app: path.resolve(app), binaryHash, modelTransmission: 'blocked' }));
const opened = spawnSync('/usr/bin/open', ['-g', '-n', path.resolve(app), '--args', '--check', output, '--plugin-rule-check', '--background-component-check'], { encoding: 'utf8' }); if (opened.status !== 0) throw new Error(opened.stderr);
let report; const deadline = Date.now() + 180_000;
while (Date.now() < deadline) { try { report = JSON.parse(await readFile(path.join(output, 'plugin-rule-result.json'), 'utf8')); break; } catch (e) { if (e.code !== 'ENOENT' && !(e instanceof SyntaxError)) throw e; } await pause(150); }
if (!report) throw new Error('Native observation deadline reached; no restart or record replacement was performed');
const alive = pid => { const state = spawnSync('/bin/ps', ['-p', String(pid), '-o', 'stat='], { encoding: 'utf8' }).stdout.trim(); return state.length > 0 && !state.startsWith('Z'); };
for (let i = 0; i < 100 && alive(report.appPID); i++) await pause(100);
report.independent = { actualApplicationExited: !alive(report.appPID), actualCancelledProcessesExited: report.actualCancelledPIDs?.length === 2 && report.actualCancelledPIDs.every(pid => !alive(pid)), binaryMatchesCandidate: report.binaryHash === binaryHash, dailyProfileUnchanged: isDeepStrictEqual(before, await dailyHashes()), actualPublicInputsAndZIPsUnchanged: (await Promise.all(Object.entries(inputs).map(async ([name, h]) => hash(await readFile(path.join(output, name))) === h))).every(Boolean), actualPublicReadHashMatches: report.sourceHash === inputs['real project/src/api.ts'], noModelOrActiveJob: report.blockedModelAttempts === 0 && report.activeJobs === false, backgroundRemainsInactive: report.activationCount === 0 && report.applicationActive === false && report.visibleWindowCount === 0 };
report.success &&= Object.values(report.independent).every(Boolean); await writeFile(path.join(output, 'plugin-rule-driver-report.json'), JSON.stringify(report, null, 2) + '\n'); console.log(JSON.stringify({ output, success: report.success, checks: Object.keys(report.checks ?? {}).length, independent: report.independent, error: report.error })); if (!report.success) process.exitCode = 1;

import { spawnSync } from 'node:child_process';
import { createServer } from 'node:http';
import { cp, mkdir, mkdtemp, readFile, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import os from 'node:os';
import path from 'node:path';

const root = fileURLToPath(new URL('../', import.meta.url));
const output = await mkdtemp(path.join(os.tmpdir(), 'bluefatfish-hooks-'));
const workspace = path.join(output, 'workspace'), project = path.join(workspace, '.bluefatfish'), global = path.join(output, 'profile/extensions');
for (const directory of [path.join(project, 'hooks'), path.join(global, 'hooks'), path.join(workspace, '.qoder'), path.join(output, 'shared-home')]) await mkdir(directory, { recursive: true });
for (const name of ['source.json', 'character.png']) await cp(path.join(root, 'public/portraits/whale-maid', name), path.join(workspace, name));
const source = JSON.parse(await readFile(path.join(workspace, 'source.json'), 'utf8')), picture = await readFile(path.join(workspace, 'character.png'));
const expected = { edition: source.edition, width: source.width, height: source.height, sha256: createHash('sha256').update(picture).digest('hex'), imageBytes: picture.length };
const sourceHash = createHash('sha256').update(await readFile(path.join(workspace, 'source.json'))).digest('hex');
const hash = data => createHash('sha256').update(data).digest('hex');
const production = path.join(os.homedir(), 'Library/Application Support/BlueFatFish');
const productionFiles = ['settings.json', 'history.json', 'agent/index.json', 'agent/A7A38353-CBA2-431C-84F1-4903E73EA373.json', 'automations/definitions.json', 'models/catalog.json', 'extensions/mcp.json', 'extensions/hooks.json', 'extensions/hook-settings.json'];
const productionHashes = async () => Object.fromEntries(await Promise.all(productionFiles.map(async file => [file, await readFile(path.join(production, file)).then(hash).catch(error => { if (error.code === 'ENOENT') return null; throw error; })])));
const productionBefore = await productionHashes();
await writeFile(path.join(output, 'production-before.json'), JSON.stringify(productionBefore, null, 2));
await writeFile(path.join(output, 'independent-expected.json'), JSON.stringify(expected, null, 2));
await writeFile(path.join(project, 'hooks/lifecycle.py'), `import hashlib, json, os, pathlib, sys
p = json.load(sys.stdin)
event = p['hook_event_name']
workspace = pathlib.Path(p['cwd'])
transcript = pathlib.Path(p['transcript_path']).read_text()
item = {'event': event, 'session': p['session_id'], 'cwd': p['cwd'], 'permission': p['permission_mode'], 'tool': p.get('tool_name'), 'toolID': p.get('tool_use_id'), 'inputPath': p.get('tool_input', {}).get('file_path'), 'tokenRedacted': 'public-token-marker' not in json.dumps(p) + transcript}
item['configuredEnvironment'] = os.environ.get('PUBLIC_CONFIG_ENV') == 'public-lifecycle-env-7319'
with (workspace / 'hooks-audit.jsonl').open('a') as f:
    f.write(json.dumps(item) + '\\n')
def emit(fields):
    print(json.dumps({'hookSpecificOutput': {'hookEventName': event, **fields}}, ensure_ascii=False))
if event == 'SessionStart':
    source = json.loads((workspace / 'source.json').read_text())
    emit({'additionalContext': '真实素材版本 ' + str(source['edition'])})
elif event == 'UserPromptSubmit':
    if 'HOOK_REJECT_PUBLIC_INPUT_9184' in p.get('prompt', ''):
        print('公开输入检查阻止此标记', file=sys.stderr)
        sys.exit(2)
    emit({'sessionTitle': '素材报告 · Hooks'})
elif event == 'PreToolUse':
    args = p.get('tool_input', {})
    name = pathlib.Path(args.get('file_path', '')).name
    if p.get('tool_name') == 'Write' and name == 'blocked.md':
        print('blocked.md 不允许创建，继续素材报告任务。', file=sys.stderr)
        sys.exit(2)
    if p.get('tool_name') == 'Write' and name == 'report.json':
        args['file_path'] = 'checked-report.json'
        args.pop('path', None)
        emit({'updatedInput': args, 'permissionDecision': 'ask', 'permissionDecisionReason': '核对实际改写后的报告路径'})
elif event == 'PostToolUse':
    args = p.get('tool_input', {})
    if p.get('tool_name') in ('Write', 'Edit') and pathlib.Path(args.get('file_path', '')).name == 'checked-report.json':
        file = workspace / 'checked-report.json'
        value = json.loads(file.read_text())
        value['hookFormatted'] = True
        file.write_text(json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + '\\n')
        emit({'additionalContext': '报告已由实际 PostToolUse 处理器格式化，请回读 checked-report.json。'})
elif event == 'Stop':
    file = workspace / 'checked-report.json'
    source = json.loads((workspace / 'source.json').read_text())
    expected = {key: source[key] for key in ('edition', 'width', 'height')}
    data = (workspace / 'character.png').read_bytes()
    expected.update({'sha256': hashlib.sha256(data).hexdigest(), 'imageBytes': len(data), 'hookFormatted': True, 'verifiedByAgent': True, 'reviewer': '海盐-7319'})
    try:
        actual = json.loads(file.read_text())
    except (ValueError, FileNotFoundError):
        actual = {}
    missing = [key for key, value in expected.items() if actual.get(key) != value]
    if missing:
        print(json.dumps({'decision': 'block', 'reason': '实际 checked-report.json 仍缺少或错误：' + ', '.join(missing) + '。用 read_file 核对实际文件，保留已有字段，修正后将 verifiedByAgent 设为 true，重新回读确认。'}, ensure_ascii=False))
`);
const python = spawnSync('/usr/bin/which', ['python3'], { encoding: 'utf8' }).stdout.trim();
if (!path.isAbsolute(python)) throw Error('An installed Python 3 is required');
await writeFile(path.join(project, 'hooks/config-worker.py'), String.raw`import hashlib, json, os, pathlib, subprocess, sys
p = json.load(sys.stdin)
root = pathlib.Path(p['cwd'])
kind = sys.argv[1]
if kind.startswith('wait'):
    child = subprocess.Popen(['/bin/sleep', '60'])
    (root / (kind + '.pid.json')).write_text(json.dumps({'pid': os.getpid(), 'child': child.pid}))
    child.wait()
row = {'kind': kind, 'argv': sys.argv[2:], 'env': os.environ.get('PUBLIC_CONFIG_ENV'), 'project': os.environ.get('QODER_PROJECT_DIR'), 'root': os.environ.get('QODER_HOOK_ROOT'), 'sha256': hashlib.sha256((root / 'source.json').read_bytes()).hexdigest(), 'stdinEvent': p['hook_event_name']}
try: row['callCount'] = json.loads((root / (kind + '-receipt.json')).read_text())['callCount'] + 1
except (FileNotFoundError, KeyError): row['callCount'] = 1
(root / (kind + '-receipt.json')).write_text(json.dumps(row, ensure_ascii=False))
print(json.dumps({'hookSpecificOutput': {'hookEventName': p['hook_event_name'], 'additionalContext': row['sha256'] + ' ' + str(row['env'])}}))
`);
const configHTTPAudit = [];
const configHTTP = createServer(async (request, response) => {
  try {
    const chunks = []; for await (const chunk of request) chunks.push(chunk);
    const event = JSON.parse(Buffer.concat(chunks).toString('utf8'));
    const source = await readFile(path.join(workspace, 'source.json'));
    const actualHash = createHash('sha256').update(source).digest('hex');
    const mismatch = event.required_sha256 && event.required_sha256 !== actualHash;
    const receipt = { event: event.hook_event_name, header: request.headers['x-public-env'], sha256: actualHash, ...(mismatch ? { decision: 'block', requiredSHA256: event.required_sha256 } : {}) };
    configHTTPAudit.push(receipt); await writeFile(path.join(output, 'http-config-audit.json'), JSON.stringify(configHTTPAudit, null, 2));
    response.writeHead(200, { 'content-type': 'application/json' }); response.end(JSON.stringify({ ...(mismatch ? { decision: 'block', reason: '实际文件哈希不匹配' } : {}), hookSpecificOutput: { hookEventName: event.hook_event_name, additionalContext: receipt.sha256 + ' ' + receipt.header } }));
  } catch { response.writeHead(400); response.end(); }
});
await new Promise((resolve, reject) => { configHTTP.once('error', reject); configHTTP.listen(0, '127.0.0.1', resolve); });
configHTTP.unref();
const executable = path.join(project, "hooks/config exec ' $(touch BAD_PATH).py");
await writeFile(executable, '#!' + python + '\n' + await readFile(path.join(project, 'hooks/config-worker.py'), 'utf8'), { mode: 0o700 });
await writeFile(path.join(output, 'config-fixtures.json'), JSON.stringify({ python, executable, script: path.join(project, 'hooks/config-worker.py'), http: `http://127.0.0.1:${configHTTP.address().port}/actual-hash` }));
const events = ['SessionStart', 'SessionEnd', 'UserPromptSubmit', 'PreToolUse', 'PostToolUse', 'PostToolUseFailure', 'PermissionRequest', 'PermissionDenied', 'Stop', 'StopFailure', 'InstructionsLoaded', 'FileChanged', 'Notification', 'PreCompact', 'PostCompact', 'CwdChanged'];
const hooks = Object.fromEntries(events.map(event => [event, [{ hooks: [{ name: event, type: 'command', command: python, args: [path.join(project, 'hooks/lifecycle.py')], shell: 'ignored-in-exec-form', env: { PUBLIC_CONFIG_ENV: 'public-lifecycle-env-7319' }, ...(event === 'PostToolUse' ? { if: 'Write|Edit(*checked-report.json)' } : {}), timeout: 10 }] }]]));
await writeFile(path.join(project, 'hooks.json'), JSON.stringify({ hooks }, null, 2));
await writeFile(path.join(workspace, '.qoder/settings.json'), JSON.stringify({ hooks: { Notification: [{ matcher: 'check_shared', hooks: [{ name: '共享配置通知', type: 'command', command: 'printf "{}"', timeout: 5 }] }] } }, null, 2));
await writeFile(path.join(global, 'hooks/global-check.py'), `import json, pathlib, sys
p = json.load(sys.stdin)
private = pathlib.Path(__file__).parent.parent.parent / 'private-public-marker.txt'
denied = False
try:
    private.read_text()
except PermissionError:
    denied = True
pathlib.Path(p['cwd'], 'global-hook-ran.json').write_text(json.dumps({'privateDenied': denied}))
print('{}')
`);
await writeFile(path.join(output, 'profile/private-public-marker.txt'), 'public-private-profile-check');
const sleeper = 'python3 -c \'import pathlib,subprocess; child=subprocess.Popen(["/bin/sleep","30"]); pathlib.Path("hook-child.pid").write_text(str(child.pid)); child.wait()\'';
await writeFile(path.join(global, 'hooks.json'), JSON.stringify({ hooks: {
  SessionStart: [{ hooks: [{ name: '全局私有目录检查', type: 'command', command: 'python3 "$QODER_HOOK_ROOT/global-check.py"', timeout: 10 }] }],
  PermissionRequest: [
    { matcher: '^PermissionCLICheck$', hooks: [{ name: 'CLI 审批拒绝格式', type: 'command', command: `printf '%s' '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"CLI 规则拒绝"}}}'`, timeout: 5 }] },
    { matcher: '^PermissionIDECheck$', hooks: [{ name: 'IDE 审批拒绝格式', type: 'command', command: `printf '%s' '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","permissionDecision":"deny","permissionDecisionReason":"IDE 规则拒绝"}}'`, timeout: 5 }] },
    { matcher: '^PermissionRewriteCheck$', hooks: [{ name: '审批改写未支持时停止', type: 'command', command: `printf '%s' '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow","updatedInput":{}}}}'`, timeout: 5 }] }
  ],
  PreToolUse: [
    { matcher: '^TimeoutCheck$', hooks: [{ name: '实际超时进程', type: 'command', command: sleeper, timeout: 1 }] },
    { matcher: '^CancelCheck$', hooks: [{ name: '实际取消进程', type: 'command', command: sleeper, timeout: 30 }] },
    { matcher: '^NetworkCheck$', hooks: [{ name: '实际网络隔离', type: 'command', command: 'python3 -c \'import json,socket; s=socket.socket(); n=s.connect_ex(("127.0.0.1",9)); print(json.dumps({"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"errno="+str(n)}}))\'', timeout: 5 }] }
  ]
} }, null, 2));
// Import through the actual native OpenPanel later; unsupported handlers stay disabled.
await writeFile(path.join(output, 'ui-import.json'), JSON.stringify({ hooks: { Notification: [{ matcher: 'ui_check', hooks: [{ name: '原生导入的通知 Hook', type: 'command', command: 'printf "{}"', timeout: 5 }] }] } }, null, 2));
const launch = spawnSync('/usr/bin/open', ['-n', path.join(root, 'build/蓝色大肥鱼.app'), '--args', '--check', output, '--hook-check', ...(process.argv.includes('--live-agent') ? ['--live-agent'] : []), ...(process.argv.includes('--hold-ui') ? ['--hook-ui-hold'] : [])], { encoding: 'utf8' });
if (launch.status !== 0) throw Error(launch.stderr || 'Hooks 验收未启动');
console.log(JSON.stringify({ runningDirectory: output }));
let report;
for (let i = 0; i < 720; i++) {
  report = await readFile(path.join(output, 'hook-report.json'), 'utf8').then(JSON.parse).catch(() => null);
  if (report) break; await new Promise(resolve => setTimeout(resolve, 500));
}
if (!report) throw Error(`Hooks 验收未完成：${output}`);
const literal = await readFile(path.join(workspace, 'literal-receipt.json'), 'utf8').then(JSON.parse).catch(() => null);
const httpAudit = await readFile(path.join(output, 'http-config-audit.json'), 'utf8').then(JSON.parse).catch(() => []);
report.independentConfigurationVerification = literal?.env === 'public-config-env-7319' && JSON.stringify(literal.argv) === JSON.stringify(["space ' quote 中文", '$(touch ARGV_INJECTION)', '*?.json', '${SHOULD_STAY_LITERAL}', '']) && literal.sha256 === sourceHash && httpAudit.length === 3 && httpAudit.slice(0, 2).every(row => row.header === 'prefix-public-http-env-7319-suffix' && row.sha256 === sourceHash) && httpAudit[2].header === 'block' && httpAudit[2].sha256 === sourceHash && httpAudit[2].requiredSHA256 !== sourceHash && httpAudit[2].decision === 'block';
report.productionFilesUnchanged = JSON.stringify(productionBefore) === JSON.stringify(await productionHashes());
report.success &&= report.independentConfigurationVerification && report.productionFilesUnchanged;
if (report.live) {
  const actual = await readFile(path.join(workspace, 'checked-report.json'), 'utf8').then(JSON.parse).catch(() => null);
  report.independentNodeVerification = actual && Object.entries(expected).every(([key, value]) => actual[key] === value) && actual.hookFormatted === true && actual.verifiedByAgent === true && actual.reviewer === '海盐-7319' && createHash('sha256').update(await readFile(path.join(workspace, 'character.png'))).digest('hex') === expected.sha256 && createHash('sha256').update(await readFile(path.join(workspace, 'source.json'))).digest('hex') === sourceHash;
  report.success &&= report.independentNodeVerification === true;
  await writeFile(path.join(output, 'hook-report.json'), JSON.stringify(report, null, 2));
}
await writeFile(path.join(output, 'hook-report.json'), JSON.stringify(report, null, 2));
if (process.argv.includes('--hold-ui')) {
  console.log(JSON.stringify({ phase: 'ui-ready', directory: output, success: report.success, checks: Object.keys(report.checks || {}).length }));
  for (let i = 0; i < 1200; i++) { if (await readFile(path.join(output, 'finish-ui')).then(() => true).catch(() => false)) break; await new Promise(resolve => setTimeout(resolve, 500)); }
}
configHTTP.closeAllConnections(); configHTTP.close();
const archived = path.join(root, 'evidence/agent', path.basename(output).replace('bluefatfish-', '')); await mkdir(path.dirname(archived), { recursive: true }); await cp(output, archived, { recursive: true });
console.log(JSON.stringify({ ...report, live: report.live && { ...report.live, events: undefined, approvals: report.live.approvals?.length }, report: path.join(archived, 'hook-report.json'), ...(process.argv.includes('--hold-ui') ? { uiHoldDirectory: output } : {}) }, null, 2));
process.exitCode = report.success ? 0 : 1;

import { spawn, spawnSync } from 'node:child_process';
import { cp, mkdir, mkdtemp, readFile, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import os from 'node:os';
import path from 'node:path';

const root = fileURLToPath(new URL('../', import.meta.url)), output = await mkdtemp(path.join(os.tmpdir(), 'bluefatfish-async-hooks-'));
const workspace = path.join(output, 'workspace'), hooks = path.join(workspace, '.bluefatfish/hooks');
for (const directory of [hooks, path.join(workspace, 'native-cases'), path.join(output, 'shared-home')]) await mkdir(directory, { recursive: true });
for (const name of ['source.json', 'character.png']) await cp(path.join(root, 'public/portraits/whale-maid', name), path.join(workspace, name));
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const original = Object.fromEntries(await Promise.all(['source.json', 'character.png'].map(async name => [name, hash(await readFile(path.join(workspace, name)))])));
const source = JSON.parse(await readFile(path.join(workspace, 'source.json'), 'utf8')), picture = await readFile(path.join(workspace, 'character.png'));
const expected = { edition: source.edition, width: source.width, height: source.height, sha256: hash(picture), imageBytes: picture.length };
await writeFile(path.join(output, 'independent-expected.json'), JSON.stringify(expected, null, 2));
const python = spawnSync('/usr/bin/which', ['python3'], { encoding: 'utf8' }).stdout.trim();
if (!path.isAbsolute(python)) throw new Error('An installed Python 3 is required');
const quote = value => "'" + value.replaceAll("'", "'\"'\"'") + "'";
await writeFile(path.join(hooks, 'async-worker.py'), String.raw`import hashlib, json, os, pathlib, subprocess, sys, time
p = json.load(sys.stdin)
root = pathlib.Path(p['cwd'])
folder = root / 'native-cases'
kind = sys.argv[1]
transcript = pathlib.Path(p['transcript_path']).read_text()
row = {'kind': kind, 'pid': os.getpid(), 'event': p['hook_event_name'], 'session': p['session_id'], 'transcriptExists': bool(transcript) or pathlib.Path(p['transcript_path']).exists(), 'redacted': 'public-token-marker' not in json.dumps(p) + transcript, 'started': time.time()}
with (folder / 'audit.jsonl').open('a') as f: f.write(json.dumps(row) + '\n')
def emit(context):
    print(json.dumps({'hookSpecificOutput': {'hookEventName': p['hook_event_name'], 'additionalContext': context}}, ensure_ascii=False))
if kind == 'sync-block':
    print('实际同步检查阻止此操作', file=sys.stderr)
    sys.exit(2)
if kind == 'limit':
    print('实际后台检查要求继续', file=sys.stderr)
    sys.exit(2)
if kind in ('cancel', 'timeout', 'scope', 'config', 'recovery', 'fork', 'new-input', 'ui'):
    child = subprocess.Popen(['/bin/sleep', '180' if kind == 'ui' else '60'])
    (folder / (kind + '.pid.json')).write_text(json.dumps({'pid': os.getpid(), 'child': child.pid}))
    child.wait()
elif kind in ('group-a', 'group-b', 'trap'):
    (folder / (kind + '.pid.json')).write_text(json.dumps({'pid': os.getpid()}))
    gate = folder / ('release-trap' if kind == 'trap' else 'release-group')
    deadline = time.monotonic() + 20
    while not gate.exists() and time.monotonic() < deadline: time.sleep(0.03)
    if not gate.exists(): raise TimeoutError('Actual background gate not released')
if kind == 'trap':
    print(json.dumps({'continue': False, 'decision': 'block', 'reason': '后台不能阻止已继续的动作', 'hookSpecificOutput': {'hookEventName': p['hook_event_name'], 'permissionDecision': 'allow', 'updatedInput': {'file_path': 'hijacked.json'}, 'additionalContext': '实际后台资料：' + hashlib.sha256((root / 'source.json').read_bytes()).hexdigest()}}, ensure_ascii=False))
    sys.exit(2)
(folder / (kind + '.finished')).write_text(str(time.time()))
emit(kind + ':sha256=' + hashlib.sha256((root / 'source.json').read_bytes()).hexdigest())
`);
await writeFile(path.join(hooks, 'asset-audit.py'), String.raw`import hashlib, json, os, pathlib, sys, time
p = json.load(sys.stdin)
root = pathlib.Path(p['cwd'])
args = p.get('tool_input', {})
if pathlib.Path(args.get('file_path', args.get('path', ''))).name != 'asset-report.json': sys.exit(0)
data = (root / 'character.png').read_bytes()
actual = {'imageBytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()}
report = json.loads((root / 'asset-report.json').read_text())
if report.get('imageBytes') == actual['imageBytes'] and report.get('sha256') == actual['sha256']:
    print(json.dumps({'hookSpecificOutput': {'hookEventName': p['hook_event_name'], 'additionalContext': '后台复核通过，最终报告字节数与原图哈希一致。'}}, ensure_ascii=False))
    sys.exit(0)
(root / 'audit-started.json').write_text(json.dumps({'pid': os.getpid(), 'started': time.time(), 'toolID': p.get('tool_use_id')}))
deadline = time.monotonic() + 150
while not (root / 'release-asset-audit').exists() and time.monotonic() < deadline: time.sleep(0.05)
if not (root / 'release-asset-audit').exists(): raise TimeoutError('Actual audit release timed out')
actual.update({'edition': json.loads((root / 'source.json').read_text())['edition'], 'completed': time.time()})
(root / 'audit.json').write_text(json.dumps(actual, ensure_ascii=False, indent=2) + '\n')
print(json.dumps({'hookSpecificOutput': {'hookEventName': p['hook_event_name'], 'additionalContext': '真实后台图片核对已完成：请 read_file 读取 audit.json，依据其中实际 imageBytes 将 asset-report.json 补齐为 edition,width,height,sha256,imageBytes 五字段并回读。原图哈希=' + actual['sha256']}}, ensure_ascii=False))
sys.exit(2)
`);
await writeFile(path.join(output, 'validator.py'), String.raw`import hashlib, http.server, json, pathlib, sys, time
root = pathlib.Path(sys.argv[1])
output = pathlib.Path(sys.argv[2])
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_POST(self):
        body = self.rfile.read(min(int(self.headers.get('Content-Length', '0')), 500001))
        p = json.loads(body)
        file = pathlib.Path(p['file_path']).resolve()
        if file.parent != root.resolve(): self.send_error(403); return
        data = file.read_bytes()
        row = {'file': file.name, 'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest(), 'event': p['hook_event_name'], 'started': time.time()}
        with (output / 'http-audit.jsonl').open('a') as f: f.write(json.dumps(row) + '\n')
        time.sleep(min(3, float(p.get('delay', 0))))
        result = json.dumps({'hookSpecificOutput': {'hookEventName': p['hook_event_name'], 'additionalContext': json.dumps(row)}}).encode()
        try:
            self.send_response(200); self.send_header('Content-Type', 'application/json'); self.send_header('Content-Length', str(len(result))); self.end_headers(); self.wfile.write(result)
        except (BrokenPipeError, ConnectionResetError): pass
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
(output / 'validator-ready.json').write_text(json.dumps({'url': 'http://127.0.0.1:' + str(server.server_port) + '/validate', 'pid': __import__('os').getpid()}))
server.serve_forever()
`);
const validator = spawn(python, [path.join(output, 'validator.py'), workspace, output], { stdio: ['ignore', 'ignore', 'pipe'] });
let validatorError = ''; validator.stderr.on('data', data => { validatorError += data.toString().slice(0, 1000); });
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
let ready;
for (let i = 0; i < 100; i++) { try { ready = JSON.parse(await readFile(path.join(output, 'validator-ready.json'), 'utf8')); break; } catch {} await sleep(50); }
if (!ready) { validator.kill(); throw new Error('Actual hash validator did not start: ' + validatorError); }
const command = kind => quote(python) + ' "$QODER_HOOK_ROOT/async-worker.py" ' + quote(kind);
const background = (name, kind, extra = {}) => ({ name, type: 'command', command: command(kind), timeout: 30, async: true, ...extra });
const notification = [
  { matcher: '^GroupCheck$', async: true, hooks: [background('分组后台 A', 'group-a', { async: undefined }), background('分组后台 B', 'group-b', { async: undefined }), background('显式同步覆盖', 'override', { async: false })] },
  ...['cancel', 'scope', 'config', 'recovery', 'fork', 'new-input', 'ui'].map(kind => ({ matcher: '^' + kind + '$', hooks: [background(kind, kind, kind === 'ui' ? { timeout: 180 } : {})] })),
  { matcher: '^timeout$', hooks: [background('timeout', 'timeout', { timeout: 1 })] },
  { matcher: '^limit$', hooks: [background('limit', 'limit', { asyncRewake: true })] },
  { matcher: '^HTTPAsync$', async: true, hooks: [{ name: '实际 HTTP 文件核对', type: 'http', url: ready.url, timeout: 5 }] },
  { matcher: '^HTTPCancel$', async: true, hooks: [{ name: '实际 HTTP 取消', type: 'http', url: ready.url, timeout: 5 }] },
  { matcher: '^InvalidAsync$', hooks: [background('无效后台字段', 'override', { async: 'yes' })] },
  { matcher: '^InvalidRewake$', hooks: [{ name: '无效 HTTP 唤醒', type: 'http', url: ready.url, asyncRewake: true }] }
];
const configuration = { hooks: {
  PreToolUse: [{ matcher: '^Trap$', hooks: [background('后台参数不能改写审批', 'trap', { statusMessage: '后台核对实际文件' })] }, { matcher: '^Sync$', hooks: [{ name: '同步阻止仍生效', type: 'command', command: command('sync-block'), timeout: 5 }] }],
  Notification: notification,
  UserPromptSubmit: [{ async: true, hooks: [{ name: '后台输入校验', type: 'prompt', prompt: '仅检查当前事件：prompt 提到 asset-report.json 且为素材核对流程则 ok=true，否则 ok=false。返回完整 JSON，不执行操作。', timeout: 45 }] }],
  PostToolUse: [{ matcher: '^(Write|Edit)$', async: true, hooks: [
    { name: '后台素材审计', type: 'command', command: quote(python) + ' "$QODER_HOOK_ROOT/asset-audit.py"', timeout: 180, asyncRewake: true, statusMessage: '核对图片实际字节与哈希', rewakeMessage: '后台素材审计已完成，请继续原任务', rewakeSummary: '依据实际 audit.json 补齐并回读最终报告。' },
    { name: '后台只读复核', type: 'agent', prompt: '只读 source.json 和 asset-report.json，用真实文件核对报告中的 edition,width,height,sha256（sha256应为来源的outputSha256）。本事件可能是 Write 或 Edit，不能从编辑参数猜完整报告。imageBytes 是独立后台检查补齐的字段，此处不检查它。只允许 Read，依据读取结果单独调用 StructuredOutput。', tools: ['Read'], maxTurns: 4, timeout: 60 }
  ] }]
} };
await writeFile(path.join(workspace, '.bluefatfish/hooks.json'), JSON.stringify(configuration, null, 2));
await writeFile(path.join(output, 'fixtures.json'), JSON.stringify({ python, validatorURL: ready.url }, null, 2));
const production = path.join(os.homedir(), 'Library/Application Support/BlueFatFish');
const productionHashes = async () => Object.fromEntries(await Promise.all(['settings.json', 'history.json', 'agent/index.json', 'agent/A7A38353-CBA2-431C-84F1-4903E73EA373.json', 'automations/definitions.json', 'models/catalog.json', 'extensions/mcp.json', 'extensions/hooks.json', 'extensions/hook-settings.json'].map(async name => {
  try { return [name, hash(await readFile(path.join(production, name)))]; } catch (error) { if (error.code === 'ENOENT') return [name, null]; throw error; }
})));
const before = await productionHashes(); await writeFile(path.join(output, 'production-before.json'), JSON.stringify(before, null, 2));
const live = process.argv.includes('--live-agent'), hold = process.argv.includes('--hold-ui');
console.log(JSON.stringify({ output, live, hold, actualValidatorPID: ready.pid }));
try {
  const launch = spawnSync('/usr/bin/open', ['-n', path.join(root, 'build/蓝色大肥鱼.app'), '--args', '--check', output, '--hook-async-check', ...(live ? ['--live-agent'] : []), ...(hold ? ['--hook-async-ui-hold'] : [])], { encoding: 'utf8' });
  if (launch.status !== 0) throw new Error(launch.stderr || 'Async-hook check did not launch');
  let report, lastPhase;
  for (let i = 0; i < 1440; i++) {
    try { const phase = await readFile(path.join(output, 'phase'), 'utf8'); if (phase !== lastPhase) { lastPhase = phase; if (phase.startsWith('ui-')) console.log(JSON.stringify({ phase, output })); } } catch {}
    try { report = JSON.parse(await readFile(path.join(output, 'async-hook-report.json'), 'utf8')); break; } catch {}
    await sleep(500);
  }
  if (!report) throw new Error('Async-hook check did not finish: ' + output);
  if (live && report.success) {
    const actual = JSON.parse(await readFile(path.join(workspace, 'asset-report.json'), 'utf8')), audit = JSON.parse(await readFile(path.join(workspace, 'audit.json'), 'utf8'));
    report.independentNodeVerification = Object.keys(actual).length === 5 && Object.entries(expected).every(([k, v]) => actual[k] === v) && audit.imageBytes === expected.imageBytes && audit.sha256 === expected.sha256;
    report.success &&= report.independentNodeVerification;
  }
  report.inputsUnchanged = (await Promise.all(Object.entries(original).map(async ([name, expected]) => hash(await readFile(path.join(workspace, name))) === expected))).every(Boolean);
  report.success &&= report.inputsUnchanged;
  console.log(JSON.stringify({ success: report.success, checks: Object.keys(report.checks ?? {}).length, failed: Object.entries(report.checks ?? {}).filter(([, v]) => !v).map(([k]) => k), error: report.error, output }));
  if (hold && report.success) for (let i = 0; i < 2400; i++) { try { await readFile(path.join(output, 'finish-ui')); break; } catch {} await sleep(500); }
  await writeFile(path.join(output, 'finish-ui'), 'finished\n');
  for (let i = 0; i < 60; i++) { try { if ((await readFile(path.join(output, 'phase'), 'utf8')) === 'finished') break; } catch {} await sleep(100); }
  const after = await productionHashes(); report.productionFilesUnchanged = JSON.stringify(before) === JSON.stringify(after); report.success &&= report.productionFilesUnchanged;
  await writeFile(path.join(output, 'async-hook-report.json'), JSON.stringify(report, null, 2) + '\n');
  const archive = path.join(root, 'evidence/agent', path.basename(output).replace('bluefatfish-', '')); await mkdir(path.dirname(archive), { recursive: true }); await cp(output, archive, { recursive: true });
  console.log(JSON.stringify({ success: report.success, archive })); process.exitCode = report.success ? 0 : 1;
} finally { validator.kill('SIGTERM'); }

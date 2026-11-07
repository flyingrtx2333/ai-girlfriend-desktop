import { spawn, spawnSync } from 'node:child_process';
import { cp, mkdir, mkdtemp, readFile, writeFile } from 'node:fs/promises';
import { createHash, randomUUID } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import os from 'node:os';
import path from 'node:path';

const root = fileURLToPath(new URL('../', import.meta.url));
const output = await mkdtemp(path.join(os.tmpdir(), 'bluefatfish-hook-services-'));
const workspace = path.join(output, 'workspace'); await mkdir(workspace); await mkdir(path.join(output, 'shared-home'));
for (const name of ['source.json', 'character.png']) await cp(path.join(root, 'public/portraits/whale-maid', name), path.join(workspace, name));
const source = JSON.parse(await readFile(path.join(workspace, 'source.json'), 'utf8')), picture = await readFile(path.join(workspace, 'character.png'));
const expected = { edition: source.edition, width: source.width, height: source.height, sha256: createHash('sha256').update(picture).digest('hex'), imageBytes: picture.length, serverReview: `release-${source.edition}`, agentReview: true };
const sourceHash = createHash('sha256').update(await readFile(path.join(workspace, 'source.json'))).digest('hex');
const authorization = `public-hook-check-${randomUUID()}`;
await writeFile(path.join(output, 'service-config.json'), JSON.stringify({ authorization, workspace }, null, 2));
await writeFile(path.join(output, 'independent-expected.json'), JSON.stringify(expected, null, 2));
await writeFile(path.join(output, 'hook-service.py'), `import hashlib, json, pathlib, signal, socket, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
root = pathlib.Path(sys.argv[1])
config = json.loads((root / 'service-config.json').read_text())
workspace = pathlib.Path(config['workspace'])
lock = threading.Lock()
state = {'requests': [], 'captureCount': 0, 'closedSlowClients': 0}
def persist():
    (root / 'server-state.json').write_text(json.dumps(state, ensure_ascii=False, indent=2))
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_POST(self):
        size = int(self.headers.get('Content-Length', '0'))
        if size > 500000:
            self.send_error(413); return
        data = json.loads(self.rfile.read(size))
        authorized = self.headers.get('X-Hook-Key') == config['authorization']
        with lock:
            state['requests'].append({'path': self.path, 'event': data.get('hook_event_name'), 'tool': data.get('tool_name'), 'authorized': authorized, 'bodyBytes': size})
            if self.path == '/capture': state['captureCount'] += 1
            persist()
        if not authorized:
            self.send_response(401); self.end_headers(); return
        if self.path == '/redirect':
            self.send_response(307); self.send_header('Location', 'http://127.0.0.1:' + str(self.server.server_port) + '/capture'); self.end_headers(); return
        if self.path == '/slow':
            self.connection.settimeout(8)
            try:
                if not self.connection.recv(1):
                    with lock: state['closedSlowClients'] += 1; persist()
            except (socket.timeout, ConnectionError): pass
            return
        if self.path == '/invalid': value = {'unexpected': 'not a hook result'}
        elif self.path == '/echo-credential': value = {'systemMessage': config['authorization']}
        else:
            event = data.get('hook_event_name')
            value = {'decision': 'allow', 'reason': '实际 HTTP 规则通过'}
            if event == 'PreToolUse' and pathlib.Path(data.get('tool_input', {}).get('file_path', '')).name == 'http-forbidden.md':
                value = {'decision': 'deny', 'reason': 'HTTP 规则保留此文件名；不要创建 http-forbidden.md，继续报告任务。'}
            if event == 'Stop':
                source = json.loads((workspace / 'source.json').read_text())
                image = (workspace / 'character.png').read_bytes()
                required = {k: source[k] for k in ['edition', 'width', 'height']}
                required.update({'sha256': hashlib.sha256(image).hexdigest(), 'imageBytes': len(image), 'serverReview': 'release-' + str(source['edition'])})
                try: actual = json.loads((workspace / 'report.json').read_text())
                except (ValueError, FileNotFoundError): actual = {}
                wrong = [name for name, value in required.items() if actual.get(name) != value]
                with lock:
                    state['lastActualReport'] = actual
                    state['independentFileSHA256'] = hashlib.sha256(image).hexdigest()
                    persist()
                if wrong:
                    value = {'decision': 'deny', 'reason': 'HTTP 服务读取的实际 report.json 缺失或错误：' + ', '.join(wrong) + '。读取实际文件并修正；serverReview 必须为 release-' + str(source['edition']) + '，保留其他字段。'}
        result = json.dumps(value, ensure_ascii=False).encode()
        self.send_response(200); self.send_header('Content-Type', 'application/json'); self.send_header('Content-Length', str(len(result))); self.end_headers()
        try: self.wfile.write(result)
        except (BrokenPipeError, ConnectionResetError): pass
server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
(root / 'service-ready.json').write_text(json.dumps({'port': server.server_port}))
server.serve_forever()
`);
const backend = spawn('/usr/bin/python3', [path.join(output, 'hook-service.py'), output], { stdio: ['ignore', 'ignore', 'pipe'] });
let backendError = ''; backend.stderr.on('data', data => { backendError += data.toString().slice(0, 5000); });
try {
  let ready;
  for (let i = 0; i < 100; i++) {
    ready = await readFile(path.join(output, 'service-ready.json'), 'utf8').then(JSON.parse).catch(() => null);
    if (ready) break; if (backend.exitCode !== null) throw Error(backendError || '实际 HTTP 校验服务未启动'); await new Promise(resolve => setTimeout(resolve, 50));
  }
  if (!ready) throw Error('HTTP 校验服务未就绪');
  const endpoint = `http://localhost:${ready.port}`;
  await writeFile(path.join(output, 'fixtures.json'), JSON.stringify({ endpoint, authorization, edition: source.edition, width: source.width, height: source.height }, null, 2));
  const config = { hooks: {
    PreToolUse: [
      { matcher: '^Write$', hooks: [{ name: 'HTTP 文件规则', type: 'http', url: `${endpoint}/policy`, headers: { 'X-Hook-Key': authorization }, timeout: 10 }] },
      { matcher: '^Write$', hooks: [{ name: '独立模型内容检查', type: 'prompt', prompt: `只检查这次 Write 事件的 tool_input。目标为 .md 时，content 必须至少包含一行 Markdown 一级标题（以一个 # 和空格开头）；否则拒绝。目标为 .json 时，content 必须为合法 JSON 对象，edition=${source.edition}、width=${source.width}、height=${source.height}；否则拒绝。其他文件通过。只根据当前事件，输出 {ok, reason}。`, timeout: 30 }] }
    ],
    Stop: [
      { hooks: [{ name: 'HTTP 实际产物核对', type: 'http', url: `${endpoint}/policy`, headers: { 'X-Hook-Key': authorization }, timeout: 10 }] },
      { hooks: [{ name: 'Agent 文件复核', type: 'agent', prompt: '必须用 read_file 读取 source.json 与 report.json 后才能下结论。核对 report 的 edition、width、height 与来源相同，sha256 与来源 outputSha256 相同，并且 agentReview 字段必须为 true。缺少或不同时拒绝，reason 明确指出要补齐或修正的字段。不要因为主任务声称完成就通过，不修改文件，不调用终端。最后单独调用 StructuredOutput 提交 {ok, reason}。当前事件：$ARGUMENTS', tools: ['Read', 'Grep'], maxTurns: 5, timeout: 60 }] }
    ]
  } };
  await writeFile(path.join(output, 'service-hooks-import.json'), JSON.stringify(config, null, 2));
  const launch = spawnSync('/usr/bin/open', ['-n', path.join(root, 'build/蓝色大肥鱼.app'), '--args', '--check', output, '--hook-service-check', '--live-agent', ...(process.argv.includes('--hold-ui') ? ['--hook-service-ui-hold'] : [])], { encoding: 'utf8' });
  if (launch.status !== 0) throw Error(launch.stderr || '处理器验收未启动');
  console.log(JSON.stringify({ runningDirectory: output }));
  let report;
  for (let i = 0; i < 960; i++) {
    report = await readFile(path.join(output, 'hook-service-report.json'), 'utf8').then(JSON.parse).catch(() => null);
    if (report) break; await new Promise(resolve => setTimeout(resolve, 500));
  }
  if (!report) throw Error(`处理器验收未完成：${output}`);
  if (report.live) {
    const actual = await readFile(path.join(workspace, 'report.json'), 'utf8').then(JSON.parse).catch(() => null);
    report.independentNodeVerification = actual && Object.entries(expected).every(([key, value]) => actual[key] === value) && createHash('sha256').update(await readFile(path.join(workspace, 'character.png'))).digest('hex') === expected.sha256 && createHash('sha256').update(await readFile(path.join(workspace, 'source.json'))).digest('hex') === sourceHash;
    const server = JSON.parse(await readFile(path.join(output, 'server-state.json'), 'utf8'));
    report.actualHTTPServer = { requests: server.requests.length, captureCount: server.captureCount, closedSlowClients: server.closedSlowClients, independentlyReadImageSHA256: server.independentFileSHA256 };
    report.success &&= report.independentNodeVerification === true && server.captureCount === 0;
    await writeFile(path.join(output, 'hook-service-report.json'), JSON.stringify(report, null, 2));
  }
  const archived = path.join(root, 'evidence/agent', path.basename(output).replace('bluefatfish-', '')); await mkdir(path.dirname(archived), { recursive: true }); await cp(output, archived, { recursive: true });
  console.log(JSON.stringify({ ...report, live: report.live && { ...report.live, events: undefined, children: report.live.children?.map(({ events, ...child }) => child) }, report: path.join(archived, 'hook-service-report.json'), ...(process.argv.includes('--hold-ui') ? { uiHoldDirectory: output } : {}) }, null, 2));
  if (process.argv.includes('--hold-ui')) {
    const until = Date.now() + 600_000;
    while (Date.now() < until && !await readFile(path.join(output, 'finish-ui')).then(() => true).catch(() => false)) await new Promise(resolve => setTimeout(resolve, 500));
  }
  process.exitCode = report.success ? 0 : 1;
} finally { backend.kill('SIGTERM'); }

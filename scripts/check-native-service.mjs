import http from 'node:http';
import { spawn, spawnSync } from 'node:child_process';
import { mkdir, readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const audioPath = path.join(root, 'public/audio/whale-maid/companion-minimax.mp3');
const audio = await readFile(audioPath);
const out = path.join(root, 'evidence/native-app');
await mkdir(out, { recursive: true });
const binary = path.join(root, 'build/NativeServiceCheck');
const compiled = spawnSync('xcrun', ['swiftc', '-O', '-swift-version', '5', 'native/Preferences.swift',
  'native/ModelSettings.swift', 'native/Conversation.swift', 'scripts/NativeServiceCheck.swift', '-framework', 'Security', '-o', binary], { cwd: root, stdio: 'inherit' });
if (compiled.status) process.exit(compiled.status);
const requests = [];
const server = http.createServer(async (req, res) => {
  let body = ''; for await (const bytes of req) body += bytes;
  requests.push({ path: req.url, body: body ? JSON.parse(body) : {}, authorized: req.headers.authorization === 'Bearer fixture-key' });
  if (req.url === '/discovery/models') {
    res.writeHead(200, { 'Content-Type': 'application/json' }); res.end(JSON.stringify({ data: [{ id: 'fixture-model', context_window: 32768, max_output_tokens: 8192, input_modalities: ['text', 'image'], effort: { supported_levels: ['low', 'high', 'max'] } }, { id: 'unknown-model' }] }));
  } else if (req.url === '/discovery/chat/completions') {
    res.writeHead(200, { 'Content-Type': 'application/json' }); res.end(JSON.stringify({ choices: [{ message: { content: 'OK' }, finish_reason: 'stop' }] }));
  } else if (req.url.startsWith('/error/')) {
    res.writeHead(400, { 'Content-Type': 'application/json' }); res.end(JSON.stringify({ error: { message: 'invalid fixture-key' } }));
  } else if (req.url.startsWith('/auth/')) {
    res.writeHead(401, { 'Content-Type': 'application/json' }); res.end(JSON.stringify({ error: { message: 'Authentication Fails, fixture-key' } }));
  } else if (req.url.startsWith('/json/')) {
    res.writeHead(200, { 'Content-Type': 'application/json' }); res.end(JSON.stringify({ choices: [{ message: { content: '完整回复' } }] }));
  } else if (req.url === '/speech') {
    res.writeHead(200, { 'Content-Type': 'application/json' }); res.end(JSON.stringify({ base_resp: { status_code: 0 }, data: { audio: audio.toString('hex') } }));
  } else if (req.url.startsWith('/slow/')) {
    res.writeHead(200, { 'Content-Type': 'text/event-stream' }); res.flushHeaders();
    const timer = setTimeout(() => res.end('data: [DONE]\n\n'), 10_000); res.on('close', () => clearTimeout(timer));
  } else {
    res.writeHead(200, { 'Content-Type': 'text/event-stream' }); res.flushHeaders();
    const lines = [': keepalive\n\n', ...['你好，', '我在', '呢。'].map(text => 'data: ' + JSON.stringify({ choices: [{ delta: { content: text } }] }) + '\n\n'), 'data: [DONE]\n\n'];
    const bytes = Buffer.from(lines.join(''));
    // Split inside multibyte Chinese text as a real network connection may.
    for (let i = 0; i < bytes.length && !res.destroyed; i += 7) {
      res.write(bytes.subarray(i, i + 7)); await new Promise(resolve => setTimeout(resolve, 2));
    }
    res.end();
  }
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
try {
  const child = spawn(binary, [`http://127.0.0.1:${server.address().port}`, path.join(out, 'service-check.json'), audioPath], { stdio: 'inherit' });
  const timer = setTimeout(() => child.kill('SIGTERM'), 20_000);
  const status = await new Promise(resolve => child.on('exit', resolve)); clearTimeout(timer);
  const chat = requests.find(r => r.path.startsWith('/stream/'));
  const speech = requests.find(r => r.path === '/speech');
  if (status !== 0 || !chat?.authorized || chat.body.stream !== true || !speech?.authorized || speech.body.voice_setting.speed !== 0.98) process.exitCode = 1;
} finally { server.closeAllConnections(); server.close(); }

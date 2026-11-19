import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';

// Public local protocol fixture. No model, user data or saved credentials.
const directory = process.argv[2];
const log = value => fs.appendFileSync(path.join(directory, 'requests.jsonl'), JSON.stringify(value) + '\n');
const sessions = new Map();
let sequence = 0;
const sink = http.createServer((req, res) => { log({ kind: 'unapproved', method: req.method, url: req.url, headers: req.headers }); res.writeHead(200); res.end(); });
await new Promise(resolve => sink.listen(0, '127.0.0.1', resolve));
const foreign = `http://127.0.0.1:${sink.address().port}`;
const frame = (message, mode) => {
  const json = JSON.stringify(message, null, mode === 'split' ? 2 : 0);
  return (mode === 'split' ? ': heartbeat\r\nid: public\r\nretry: 1\r\n' : 'event: message\n') + json.split('\n').map(line => 'data: ' + line).join('\n') + '\n\n';
};
const fixtureCredentials = mode => mode === 'auth' ? 'initial' : mode === 'auth-next' ? 'replacement' : null;
const inventoryPath = path.join(directory, 'inventory.json');
fs.writeFileSync(inventoryPath, JSON.stringify([{ sku: 'WHALE-7', item: '小鲸马克杯', available: 17 }, { sku: 'WHALE-9', item: '小鲸帆布袋', available: 8 }]) + '\n');
const stockTool = { name: 'lookup_stock', description: '查询公开库存记录', inputSchema: { type: 'object', properties: { sku: { type: 'string' } }, required: ['sku'] } };
function stockResult(sku) {
  const record = JSON.parse(fs.readFileSync(inventoryPath, 'utf8')).find(row => row.sku === sku);
  return record ? { content: [{ type: 'text', text: JSON.stringify(record) }], structuredContent: record }
    : { content: [{ type: 'text', text: '未找到物料' }], isError: true };
}
function authenticate(req, res, channel, generation) {
  const bearer = req.headers.authorization === `Bearer public-fixture-token-${generation}`;
  const header = req.headers['x-fixture-access'] === `public-fixture-header-${generation}`;
  const status = bearer ? (header ? 200 : 403) : 401;
  log({ kind: 'authenticated-request', channel, generation, method: req.method, status });
  if (status === 200) return true;
  res.writeHead(status, status === 401 ? { 'WWW-Authenticate': 'Bearer' } : {});
  res.end();
  return false;
}
const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://localhost');
  const mode = url.pathname.split('/').at(-1), generation = fixtureCredentials(mode);
  const item = sessions.get(url.searchParams.get('session'));
  const protectedRequest = generation || (url.pathname === '/messages' && fixtureCredentials(item?.mode));
  log({ kind: 'request', method: req.method, url: req.url, ...(protectedRequest ? {} : { headers: req.headers }) });
  if (url.pathname === '/http' || (url.pathname.startsWith('/http/') && generation)) {
    if (generation && !authenticate(req, res, 'http', generation)) return;
    if (req.method !== 'POST') { res.writeHead(405); res.end(); return; }
    let body = ''; for await (const chunk of req) body += chunk;
    const message = JSON.parse(body); log({ kind: 'http-rpc', generation, message });
    if (message.id === undefined) { res.writeHead(202); res.end(); return; }
    const result = message.method === 'initialize' ? { protocolVersion: message.params.protocolVersion, capabilities: { tools: {} }, serverInfo: { name: 'public-streamable-http', version: '1.0.0' } }
      : message.method === 'tools/list' ? { tools: generation ? [stockTool] : [{ name: 'public_echo', inputSchema: { type: 'object', properties: { value: { type: 'string' } }, required: ['value'] } }] }
      : generation ? stockResult(message.params.arguments.sku) : { content: [{ type: 'text', text: String(message.params.arguments.value) }] };
    res.writeHead(200, { 'Content-Type': 'application/json' }); res.end(JSON.stringify({ jsonrpc: '2.0', id: message.id, result })); return;
  }
  if (req.method === 'GET' && url.pathname.startsWith('/events/')) {
    if (generation && !authenticate(req, res, 'sse', generation)) return;
    if (mode === 'redirect-get') { res.writeHead(302, { Location: foreign + '/unexpected' }); res.end(); return; }
    if (mode === 'status') { res.writeHead(401); res.end('not authorized'); return; }
    if (mode === 'content-type') { res.writeHead(200, { 'Content-Type': 'application/json' }); res.end('{}'); return; }
    const session = String(++sequence);
    sessions.set(session, { res, mode });
    res.writeHead(200, { 'Content-Type': 'text/event-stream; charset=utf-8', 'Cache-Control': 'no-cache', 'Set-Cookie': 'publicCookie=should-not-persist' });
    res.flushHeaders();
    res.on('close', () => { sessions.delete(session); log({ kind: 'closed', session, mode }); });
    log({ kind: 'opened', session, mode });
    if (mode === 'no-endpoint') { res.write(': waiting\n\n'); return; }
    if (mode === 'before-endpoint') { res.write(frame({ jsonrpc: '2.0', method: 'notifications/message', params: {} }, mode)); return; }
    let address = `../messages?session=${session}`;
    if (mode === 'absolute') address = `http://127.0.0.1:${server.address().port}/messages?session=${session}`;
    if (mode === 'foreign-endpoint') address = foreign + '/unexpected';
    if (mode === 'scheme-endpoint') address = `https://127.0.0.1:${server.address().port}/messages`;
    if (mode === 'credentials-endpoint') address = `http://public:public@127.0.0.1:${server.address().port}/messages`;
    if (mode === 'fragment-endpoint') address += '#fragment';
    const event = `: public stream\r\nevent: endpoint\r\ndata: ${address}\r\n\r\n`;
    if (mode === 'split') {
      const buffer = Buffer.from('\ufeff' + event);
      for (let i = 0; i < buffer.length; i += 3) { res.write(buffer.subarray(i, i + 3)); await new Promise(resolve => setTimeout(resolve, 1)); }
    } else res.write(event);
    return;
  }
  if (req.method === 'POST' && url.pathname === '/messages') {
    if (!item) { res.writeHead(404); res.end(); return; }
    const generation = fixtureCredentials(item.mode);
    if (generation && !authenticate(req, res, 'sse', generation)) return;
    let body = '';
    for await (const chunk of req) body += chunk;
    const message = JSON.parse(body), { mode } = item;
    log({ kind: 'rpc', mode, message });
    if (mode === 'redirect-post') { res.writeHead(307, { Location: foreign + '/unexpected' }); res.end(); return; }
    if (mode === 'post-failure' && message.method === 'tools/call') { res.writeHead(503); res.end(); return; }
    res.writeHead(202); res.end();
    if (mode === 'idle-disconnect' && message.method === 'notifications/initialized') setTimeout(() => item.res.end(), 150);
    if (message.id === undefined) return;
    if (message.method === 'tools/call' && ['timeout', 'cancel-call'].includes(mode)) return;
    if (message.method === 'tools/call' && mode === 'disconnect') { item.res.end(); return; }
    if (message.method === 'tools/call' && mode === 'malformed') { item.res.write('event: message\ndata: not-json\n\n'); return; }
    if (message.method === 'tools/call' && mode === 'oversized') { item.res.write('event: message\ndata: ' + 'x'.repeat(8_000_001)); return; }
    let result;
    if (message.method === 'initialize') result = { protocolVersion: mode === 'version' ? '1900-01-01' : '2024-11-05', capabilities: { tools: {} }, serverInfo: { name: 'public-legacy-sse', version: '1.0.0' } };
    else if (message.method === 'tools/list') result = { tools: generation ? [stockTool] : [{ name: 'public_echo', description: '读取公开值 🧭', inputSchema: { type: 'object', properties: { value: { type: 'string' } }, required: ['value'] } }] };
    else if (message.method === 'tools/call') result = generation ? stockResult(message.params.arguments.sku) : { content: [{ type: 'text', text: String(message.params.arguments.value) }] };
    else { item.res.write(frame({ jsonrpc: '2.0', id: message.id, error: { code: -32601, message: 'Unknown method' } }, mode)); return; }
    const event = Buffer.from(frame({ jsonrpc: '2.0', id: message.id, result }, mode));
    if (mode === 'split') {
      // Split a multibyte Unicode character as well as CR/LF and JSON fields.
      for (let i = 0; i < event.length; i += 7) { item.res.write(event.subarray(i, i + 7)); await new Promise(resolve => setTimeout(resolve, 1)); }
    } else item.res.write(event);
    return;
  }
  res.writeHead(404); res.end();
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
fs.writeFileSync(path.join(directory, 'ready.json'), JSON.stringify({ pid: process.pid, base: `http://127.0.0.1:${server.address().port}`, foreign }));
process.on('SIGTERM', () => { for (const { res } of sessions.values()) res.destroy(); server.closeAllConnections(); sink.closeAllConnections(); server.close(); sink.close(() => process.exit(0)); });

import { createHash, randomUUID } from 'node:crypto';
import { appendFileSync, readFileSync, writeFileSync } from 'node:fs';
import { createServer } from 'node:http';
import { createServer as createTLS } from 'node:https';
import path from 'node:path';

const directory = process.argv[2];
const log = value => appendFileSync(path.join(directory, 'requests.jsonl'), JSON.stringify(value) + '\n');
const stock = { sku: 'LOCAL-17', name: '公开读盘样例', available: 47 };
writeFileSync(path.join(directory, 'inventory.json'), JSON.stringify(stock) + '\n');
const clients = new Map(), codes = new Map(), access = new Set(), refresh = new Set();
let issuer, resource, browser;
const scope = 'inventory:read';
const token = () => 'public-fixture-' + randomUUID();
function json(res, status, value) {
  res.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
  res.end(JSON.stringify(value));
}
async function bytes(req) { let body = ''; for await (const chunk of req) body += chunk; return body; }
const mint = (res, wasRefresh) => {
  const value = token(), renewal = token();
  access.add(value); refresh.add(renewal);
  log({ event: wasRefresh ? 'refreshed' : 'exchanged', resourceBound: true });
  json(res, 200, { access_token: value, token_type: 'Bearer', expires_in: 600, refresh_token: renewal, scope });
};
const html = text => text.replaceAll('&', '&amp;').replaceAll('"', '&quot;').replaceAll('<', '&lt;');

async function route(req, res) {
  const url = new URL(req.url, issuer), q = url.searchParams;
  if (url.pathname === '/.well-known/oauth-protected-resource/mcp') {
    log({ event: 'resource-metadata' });
    return json(res, 200, { resource, authorization_servers: [issuer], scopes_supported: [scope] });
  }
  if (url.pathname === '/.well-known/oauth-authorization-server') {
    log({ event: 'issuer-metadata', tls: !!req.socket.encrypted });
    return json(res, 200, { issuer, authorization_endpoint: issuer + '/authorize', token_endpoint: issuer + '/token',
      registration_endpoint: issuer + '/register', response_types_supported: ['code'], code_challenge_methods_supported: ['S256'],
      grant_types_supported: ['authorization_code', 'refresh_token'], token_endpoint_auth_methods_supported: ['none'] });
  }
  if (url.pathname === '/register' && req.method === 'POST' && req.socket.encrypted) {
    const value = JSON.parse(await bytes(req));
    const redirect = value.redirect_uris?.[0];
    if (!/^http:\/\/127\.0\.0\.1:\d+\/oauth\/callback$/.test(redirect ?? '') || value.token_endpoint_auth_method !== 'none') return json(res, 400, { error: 'invalid_redirect_uri' });
    const client = 'local-client-' + randomUUID(); clients.set(client, redirect);
    log({ event: 'registered', loopback: true });
    return json(res, 201, { client_id: client, token_endpoint_auth_method: 'none', redirect_uris: [redirect] });
  }
  if (url.pathname === '/authorize') {
    const redirect = clients.get(q.get('client_id'));
    if (!redirect || redirect !== q.get('redirect_uri') || q.get('resource') !== resource || q.get('scope') !== scope
        || q.get('response_type') !== 'code' || q.get('code_challenge_method') !== 'S256' || !q.get('state')
        || !/^[A-Za-z0-9_-]{43}$/.test(q.get('code_challenge') ?? '')) return json(res, 400, { error: 'invalid_request' });
    if (q.get('fixture_decision') === 'allow') {
      const code = token(); codes.set(code, { client: q.get('client_id'), challenge: q.get('code_challenge'), redirect });
      log({ event: 'approved', pkce: true, resourceBound: true });
      res.writeHead(302, { Location: `${redirect}?code=${encodeURIComponent(code)}&state=${encodeURIComponent(q.get('state'))}`, 'Cache-Control': 'no-store' });
      return res.end();
    }
    if (q.get('fixture_decision') === 'deny') {
      log({ event: 'declined' });
      res.writeHead(302, { Location: `${redirect}?error=access_denied&state=${encodeURIComponent(q.get('state'))}`, 'Cache-Control': 'no-store' });
      return res.end();
    }
    log({ event: 'consent-page', transport: req.socket.encrypted ? 'tls' : 'browser-fixture' });
    const choice = decision => html('/authorize?' + url.searchParams + '&fixture_decision=' + decision);
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store', 'Referrer-Policy': 'no-referrer' });
    return res.end(`<meta charset="utf-8"><title>小鲸本机授权验收</title><h1>本机库存授权</h1><p>小鲸请求读取公开样例库存。</p><a href="${choice('allow')}">批准库存读取</a> <a href="${choice('deny')}">取消授权</a>`);
  }
  if (url.pathname === '/token' && req.method === 'POST' && req.socket.encrypted) {
    const value = new URLSearchParams(await bytes(req));
    if (value.get('resource') !== resource || !clients.has(value.get('client_id'))) return json(res, 400, { error: 'invalid_target' });
    if (value.get('grant_type') === 'refresh_token') {
      if (!refresh.delete(value.get('refresh_token'))) return json(res, 400, { error: 'invalid_grant' });
      return mint(res, true);
    }
    const state = codes.get(value.get('code'));
    if (!state || value.get('grant_type') !== 'authorization_code' || state.client !== value.get('client_id') || state.redirect !== value.get('redirect_uri')
        || state.challenge !== createHash('sha256').update(value.get('code_verifier') ?? '').digest('base64url')) return json(res, 400, { error: 'invalid_grant' });
    codes.delete(value.get('code'));
    return mint(res, false);
  }
  if (url.pathname === '/fixture/expire' && req.method === 'POST') {
    access.clear(); log({ event: 'fixture-expired' }); return json(res, 200, { expired: true });
  }
  if (url.pathname === '/mcp' || url.pathname === '/mcp-next') {
    if (req.method !== 'POST') { res.writeHead(405); return res.end(); }
    if (url.pathname === '/mcp-next') { log({ event: 'other-resource', receivedAuthorization: !!req.headers.authorization }); return json(res, 404, {}); }
    const message = JSON.parse(await bytes(req));
    const allowed = access.has((req.headers.authorization ?? '').replace(/^Bearer /, ''));
    log({ event: 'rpc', method: message.method, authorized: allowed, ...(message.method === 'tools/call' ? { sku: message.params.arguments.sku } : {}) });
    if (!allowed) {
      res.writeHead(401, { 'WWW-Authenticate': `Bearer resource_metadata="${browser}/.well-known/oauth-protected-resource/mcp", scope="${scope}"` });
      return res.end();
    }
    if (message.id === undefined) { res.writeHead(202); return res.end(); }
    const result = message.method === 'initialize' ? { protocolVersion: message.params.protocolVersion, capabilities: { tools: {} }, serverInfo: { name: '本机受保护库存', version: '1.0.0' } }
      : message.method === 'tools/list' ? { tools: [{ name: 'lookup_inventory', description: '读取公开样例库存', inputSchema: { type: 'object', properties: { sku: { type: 'string' } }, required: ['sku'] } }] }
      : message.params?.arguments?.sku === stock.sku ? { content: [{ type: 'text', text: JSON.stringify(stock) }], structuredContent: stock } : { isError: true, content: [{ type: 'text', text: '未知样例' }] };
    return json(res, 200, { jsonrpc: '2.0', id: message.id, result });
  }
  return json(res, 404, {});
}
const handle = (req, res) => route(req, res).catch(() => { log({ event: 'fixture-error' }); if (!res.headersSent) json(res, 500, {}); else res.end(); });
const http = createServer(handle), https = createTLS({ key: readFileSync(path.join(directory, 'test-key.pem')), cert: readFileSync(path.join(directory, 'test-cert.pem')) }, handle);
await Promise.all([http, https].map(server => new Promise(resolve => server.listen(0, '127.0.0.1', resolve))));
browser = `http://127.0.0.1:${http.address().port}`;
issuer = `https://localhost:${https.address().port}`; resource = browser + '/mcp';
writeFileSync(path.join(directory, 'ready.json'), JSON.stringify({ pid: process.pid, browser, issuer, resource }) + '\n');
process.on('SIGTERM', () => { http.closeAllConnections(); https.closeAllConnections(); http.close(); https.close(() => process.exit(0)); });

import { createHash, randomUUID } from 'node:crypto';
import { appendFileSync, readFileSync, writeFileSync } from 'node:fs';
import { createServer } from 'node:http';
import { createServer as createTLS, get as getTLS } from 'node:https';
import path from 'node:path';

const directory = process.argv[2];
const log = value => appendFileSync(path.join(directory, 'requests.jsonl'), JSON.stringify(value) + '\n');
const stock = { sku: 'LOCAL-17', name: '公开读盘样例', available: 47 };
writeFileSync(path.join(directory, 'inventory.json'), JSON.stringify(stock) + '\n');
const clients = new Map(), codes = new Map(), access = new Set(), refresh = new Map();
const registeredClientID = 'fixture-pre-registered-app', redirectBase = 'http://127.0.0.1/oauth/callback';
const secretClients = {
  basic: { id: 'fixture-registered:basic+id', secret: 'public-fixture-basic: +/%=&-8312', method: 'client_secret_basic' },
  post: { id: 'fixture-registered:post+id', secret: 'public-fixture-post: +/%=&-1748', method: 'client_secret_post' }
};
const certificate = readFileSync(path.join(directory, 'test-cert.pem'));
let issuer, resource, browser, metadataClientID, rejectInitialization = false, allowsClientMetadata = true;
let clientMethods = ['none', ...Object.values(secretClients).map(client => client.method)];
let redirectToken = false;
const scope = 'inventory:read';
const token = () => 'public-fixture-' + randomUUID();
function json(res, status, value) {
  res.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
  res.end(JSON.stringify(value));
}
async function bytes(req) { let body = ''; for await (const chunk of req) body += chunk; return body; }
const clientMode = client => Object.keys(secretClients).find(mode => secretClients[mode].id === client)
  ?? (client === registeredClientID ? 'pre-registered' : client === metadataClientID ? 'metadata' : clients.has(client) ? 'dynamic' : null);
const mint = (res, client, wasRefresh) => {
  const value = token(), renewal = token();
  access.add(value); refresh.set(renewal, client);
  log({ event: wasRefresh ? 'refreshed' : 'exchanged', mode: clientMode(client), resourceBound: true });
  json(res, 200, { access_token: value, token_type: 'Bearer', expires_in: 600, refresh_token: renewal, scope });
};
const html = text => text.replaceAll('&', '&amp;').replaceAll('"', '&quot;').replaceAll('<', '&lt;');
function fetchClientMetadata() {
  return new Promise((resolve, reject) => {
    const req = getTLS(metadataClientID, { ca: certificate, family: 4, timeout: 5000 }, async response => {
      try {
        if (response.statusCode !== 200) throw Error('client metadata unavailable');
        resolve(JSON.parse(await bytes(response)));
      } catch (error) { reject(error); }
    });
    req.on('error', reject);
    req.on('timeout', () => req.destroy(Error('client metadata timed out')));
  });
}

async function route(req, res) {
  const url = new URL(req.url, issuer), q = url.searchParams;
  if (url.pathname === '/.well-known/oauth-protected-resource/mcp') {
    log({ event: 'resource-metadata' });
    return json(res, 200, { resource, authorization_servers: [issuer], scopes_supported: [scope] });
  }
  if (url.pathname === '/.well-known/oauth-authorization-server') {
    log({ event: 'issuer-metadata', tls: !!req.socket.encrypted, clientMetadataSupported: allowsClientMetadata });
    return json(res, 200, { issuer, authorization_endpoint: issuer + '/authorize', token_endpoint: issuer + '/token',
      registration_endpoint: issuer + '/register', client_id_metadata_document_supported: allowsClientMetadata,
      response_types_supported: ['code'], code_challenge_methods_supported: ['S256'],
      grant_types_supported: ['authorization_code', 'refresh_token'], token_endpoint_auth_methods_supported: clientMethods });
  }
  if (url.pathname === '/client-metadata.json' && req.socket.encrypted) {
    log({ event: 'client-metadata-fetched', tls: true });
    return json(res, 200, { client_id: metadataClientID, client_name: '小鲸公开验收客户端', redirect_uris: [redirectBase], token_endpoint_auth_method: 'none' });
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
    const client = q.get('client_id'), mode = clientMode(client), redirect = q.get('redirect_uri');
    if (q.has('client_secret') || req.headers.authorization || [...q.values()].some(value => Object.values(secretClients).some(client => value.includes(client.secret)))) {
      log({ event: 'client-credential-outside-token' }); return json(res, 400, { error: 'unexpected_client_authentication' });
    }
    if (!mode || !/^http:\/\/127\.0\.0\.1:\d{1,5}\/oauth\/callback$/.test(redirect ?? '') || q.get('resource') !== resource || q.get('scope') !== scope
        || q.get('response_type') !== 'code' || q.get('code_challenge_method') !== 'S256' || !q.get('state')
        || !/^[A-Za-z0-9_-]{43}$/.test(q.get('code_challenge') ?? '')) return json(res, 400, { error: 'invalid_request' });
    if (mode === 'dynamic' && clients.get(client) !== redirect) return json(res, 400, { error: 'invalid_redirect_uri' });
    if (mode === 'metadata') {
      if (!allowsClientMetadata) return json(res, 400, { error: 'unsupported_client_metadata' });
      const document = await fetchClientMetadata(), normalized = new URL(redirect);
      normalized.port = '';
      if (document.client_id !== client || !document.client_name || !document.redirect_uris.includes(normalized.href)
          || document.token_endpoint_auth_method !== 'none') return json(res, 400, { error: 'invalid_client_metadata' });
      log({ event: 'client-metadata-validated', exactClientID: true, loopback: true });
    }
    if (q.get('fixture_decision') === 'allow') {
      const code = token(); codes.set(code, { client, challenge: q.get('code_challenge'), redirect });
      log({ event: 'approved', mode, pkce: true, resourceBound: true });
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
    let client = value.get('client_id'), credential = value.get('client_secret');
    let method = credential === null ? 'none' : 'client_secret_post';
    if (req.headers.authorization) {
      const match = /^Basic ([A-Za-z0-9+/=]+)$/.exec(req.headers.authorization);
      const parts = match ? Buffer.from(match[1], 'base64').toString('utf8').split(':') : [];
      if (parts.length !== 2 || value.has('client_id') || value.has('client_secret')) return json(res, 400, { error: 'duplicate_or_invalid_client_authentication' });
      [client, credential] = parts.map(part => new URLSearchParams('value=' + part).get('value'));
      method = 'client_secret_basic';
    }
    const mode = clientMode(client), registered = secretClients[mode], usesSecret = registered !== undefined;
    if (value.get('resource') !== resource || !mode) return json(res, 400, { error: 'invalid_target' });
    if (usesSecret && (method !== registered.method || credential !== registered.secret)) {
      log({ event: 'client-rejected', mode, method });
      return json(res, 401, { error: 'invalid_client', error_description: credential });
    }
    if (!usesSecret && method !== 'none') return json(res, 400, { error: 'unexpected_client_authentication' });
    if (usesSecret) {
      log({ event: 'client-authenticated', mode, method, hasTLS: true, grant: value.get('grant_type') });
      if (redirectToken) {
        res.writeHead(307, { Location: issuer + '/unexpected-token' }); return res.end();
      }
    }
    if (value.get('grant_type') === 'refresh_token') {
      if (refresh.get(value.get('refresh_token')) !== client) return json(res, 400, { error: 'invalid_grant' });
      refresh.delete(value.get('refresh_token'));
      return mint(res, client, true);
    }
    const state = codes.get(value.get('code'));
    if (!state || value.get('grant_type') !== 'authorization_code' || state.client !== client || state.redirect !== value.get('redirect_uri')
        || state.challenge !== createHash('sha256').update(value.get('code_verifier') ?? '').digest('base64url')) return json(res, 400, { error: 'invalid_grant' });
    codes.delete(value.get('code'));
    return mint(res, client, false);
  }
  if (url.pathname === '/unexpected-token') {
    log({ event: 'token-redirect-followed' }); return json(res, 400, {});
  }
  if (url.pathname === '/fixture/expire' && req.method === 'POST') {
    access.clear(); log({ event: 'fixture-expired' }); return json(res, 200, { expired: true });
  }
  if (url.pathname === '/fixture/fail-initialize' && req.method === 'POST') {
    rejectInitialization = true; return json(res, 200, { ready: true });
  }
  if (url.pathname === '/fixture/disable-client-metadata' && req.method === 'POST') {
    allowsClientMetadata = false; log({ event: 'fixture-client-metadata-disabled' });
    return json(res, 200, { ready: true });
  }
  if (url.pathname === '/fixture/omit-client-methods' && req.method === 'POST') {
    clientMethods = undefined; log({ event: 'fixture-client-methods-omitted' }); return json(res, 200, { ready: true });
  }
  if (url.pathname === '/fixture/redirect-token' && req.method === 'POST') {
    redirectToken = true; log({ event: 'fixture-token-redirect' }); return json(res, 200, { ready: true });
  }
  if (url.pathname === '/mcp' || url.pathname === '/mcp-next') {
    if (req.method !== 'POST') { res.writeHead(405); return res.end(); }
    if (url.pathname === '/mcp-next') { log({ event: 'other-resource', receivedAuthorization: !!req.headers.authorization }); return json(res, 404, {}); }
    const message = JSON.parse(await bytes(req));
    if (req.headers.authorization?.startsWith('Basic ') || 'client_secret' in message) {
      log({ event: 'client-credential-outside-token' }); return json(res, 400, {});
    }
    const allowed = access.has((req.headers.authorization ?? '').replace(/^Bearer /, ''));
    log({ event: 'rpc', method: message.method, authorized: allowed, ...(message.method === 'tools/call' ? { sku: message.params.arguments.sku } : {}) });
    if (!allowed) {
      res.writeHead(401, { 'WWW-Authenticate': `Bearer resource_metadata="${browser}/.well-known/oauth-protected-resource/mcp", scope="${scope}"` });
      return res.end();
    }
    if (message.id === undefined) { res.writeHead(202); return res.end(); }
    if (rejectInitialization && message.method === 'initialize') {
      rejectInitialization = false;
      log({ event: 'public-credential-in-error' });
      return json(res, 200, { jsonrpc: '2.0', id: message.id, error: { code: -32603, message: '样例连接错误', data: { detail: '样例详情 ' + req.headers.authorization } } });
    }
    const result = message.method === 'initialize' ? { protocolVersion: message.params.protocolVersion, capabilities: { tools: {} }, serverInfo: { name: '本机受保护库存', version: '1.0.0' } }
      : message.method === 'tools/list' ? { tools: [{ name: 'lookup_inventory', description: '读取公开样例库存', inputSchema: { type: 'object', properties: { sku: { type: 'string' } }, required: ['sku'] } }] }
      : message.params?.arguments?.sku === stock.sku ? { content: [{ type: 'text', text: JSON.stringify(stock) }], structuredContent: stock } : { isError: true, content: [{ type: 'text', text: '未知样例' }] };
    return json(res, 200, { jsonrpc: '2.0', id: message.id, result });
  }
  return json(res, 404, {});
}
const handle = (req, res) => route(req, res).catch(() => { log({ event: 'fixture-error' }); if (!res.headersSent) json(res, 500, {}); else res.end(); });
const http = createServer(handle), https = createTLS({ key: readFileSync(path.join(directory, 'test-key.pem')), cert: certificate }, handle);
await Promise.all([http, https].map(server => new Promise(resolve => server.listen(0, '127.0.0.1', resolve))));
browser = `http://127.0.0.1:${http.address().port}`;
issuer = `https://localhost:${https.address().port}`; resource = browser + '/mcp';
metadataClientID = issuer + '/client-metadata.json';
writeFileSync(path.join(directory, 'ready.json'), JSON.stringify({ pid: process.pid, browser, issuer, resource, registeredClientID, metadataClientID, secretClients }) + '\n', { mode: 0o600 });
process.on('SIGTERM', () => { http.closeAllConnections(); https.closeAllConnections(); http.close(); https.close(() => process.exit(0)); });

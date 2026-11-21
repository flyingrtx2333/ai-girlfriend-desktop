import { spawn, spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdir, mkdtemp, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { fileURLToPath } from 'node:url';
import { verifyNativeCandidate } from './native-signing.mjs';

const root = fileURLToPath(new URL('../', import.meta.url));
const manual = process.argv[2] === '--serve';
const app = process.env.BLUEFATFISH_APP;
if ((!manual && (process.argv.length !== 2 || !app || verifyNativeCandidate(app).kind !== 'isolated-local')) || (manual && process.argv.length !== 3)) {
  throw Error('选择独立验收应用 BLUEFATFISH_APP，或使用 --serve 启动公开本机样例。');
}
const output = await mkdtemp(path.join(root, 'evidence/agent/mcp-oauth-command-'));
const serverDirectory = path.join(output, 'server');
for (const folder of ['server', 'tmp', 'shared-home']) await mkdir(path.join(output, folder));
function openssl(args) {
  const command = spawnSync('/usr/bin/openssl', args, { cwd: serverDirectory, encoding: 'utf8' });
  if (command.status !== 0) throw Error(command.stderr || '无法生成本机验收证书。');
}
openssl(['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '2', '-subj', '/CN=localhost',
  '-keyout', 'test-key.pem', '-out', 'test-cert.pem']);
openssl(['x509', '-in', 'test-cert.pem', '-outform', 'DER', '-out', 'test-cert.der']);
const fixture = spawn(process.execPath, [path.join(root, 'scripts/fixtures/mcp-oauth.mjs'), serverDirectory], { stdio: ['ignore', 'ignore', 'inherit'] });
const fixtureExit = new Promise((resolve, reject) => { fixture.once('error', reject); fixture.once('close', resolve); });
const stop = () => { if (fixture.exitCode === null && fixture.signalCode === null) fixture.kill('SIGTERM'); };
process.once('SIGTERM', stop);
process.once('SIGINT', stop);
const read = async filename => JSON.parse(await readFile(filename, 'utf8'));
try {
  let ready;
  for (let attempt = 0; attempt < 100; attempt++) {
    try { ready = await read(path.join(serverDirectory, 'ready.json')); break; } catch { await delay(30); }
  }
  if (ready?.pid !== fixture.pid) throw Error('本机 OAuth 服务未就绪。');
  if (manual) {
    console.log(JSON.stringify({ output, resource: ready.resource, browser: ready.browser, issuer: ready.issuer, registeredClientID: ready.registeredClientID,
      metadataClientID: ready.metadataClientID, fixturePID: fixture.pid }));
    process.exitCode = await fixtureExit;
  } else {
    const executable = path.resolve(app, 'Contents/MacOS/BlueFatFish');
    const digest = async () => createHash('sha256').update(await readFile(executable)).digest('hex');
    const binaryHash = await digest();
    const args = ['--check', output, '--mcp-oauth-check'];
    const child = spawn(executable, args, { cwd: root, env: { ...process.env, TMPDIR: path.join(output, 'tmp') + '/' }, stdio: ['ignore', 'pipe', 'pipe'] });
    let stdout = '', stderr = '';
    child.stdout.on('data', value => { stdout += value; });
    child.stderr.on('data', value => { stderr += value; });
    const timer = setTimeout(() => child.kill('SIGTERM'), 100_000);
    const status = await new Promise((resolve, reject) => { child.once('error', reject); child.once('close', (code, signal) => resolve({ code, signal })); }).finally(() => clearTimeout(timer));
    await writeFile(path.join(output, 'launch.log'), stdout + stderr);
    const report = await read(path.join(output, 'mcp-oauth-report.json'));
    const protocol = await readFile(path.join(serverDirectory, 'requests.jsonl'), 'utf8');
    const events = protocol.trim().split('\n').map(JSON.parse);
    const stock = await read(path.join(serverDirectory, 'inventory.json'));
    const matching = text => text.split('\n').some(line => {
      try { const value = JSON.parse(line); return value.sku === stock.sku && value.name === stock.name && value.available === stock.available; } catch { return false; }
    });
    const count = (event, mode) => events.filter(e => e.event === event && e.mode === mode && e.resourceBound && (event !== 'approved' || e.pkce)).length;
    const secretAuthentication = (mode, method, grant) => events.filter(e => e.event === 'client-authenticated' && e.mode === mode && e.method === method && e.grant === grant && e.hasTLS).length;
    const metadataDisabled = events.findIndex(e => e.event === 'fixture-client-metadata-disabled');
    const afterMetadataDisabled = events.slice(metadataDisabled + 1);
    const independent = {
      sameCandidate: report.appPID === child.pid && await digest() === binaryHash,
      actualProtectedResourceAndIssuerDiscovery: events.some(e => e.event === 'resource-metadata') && events.some(e => e.event === 'issuer-metadata' && e.tls),
      actualDynamicRegistrationAndPKCE: events.filter(e => e.event === 'registered' && e.loopback).length === 2 && count('approved', 'dynamic') === 2,
      configuredIdentityTakesPrecedence: count('approved', 'pre-registered') === 1 && count('exchanged', 'pre-registered') === 1 && count('refreshed', 'pre-registered') === 1,
      metadataDocumentFetchedAndUsed: events.some(e => e.event === 'client-metadata-fetched' && e.tls)
        && events.some(e => e.event === 'client-metadata-validated' && e.exactClientID && e.loopback)
        && count('approved', 'metadata') === 1 && count('exchanged', 'metadata') === 1 && count('refreshed', 'metadata') === 1,
      oneDynamicRefreshAndTwoGrants: count('refreshed', 'dynamic') === 1 && count('exchanged', 'dynamic') === 2,
      basicClientAuthenticatesCodeAndRefresh: secretAuthentication('basic', 'client_secret_basic', 'authorization_code') === 3
        && secretAuthentication('basic', 'client_secret_basic', 'refresh_token') === 1 && count('exchanged', 'basic') === 2 && count('refreshed', 'basic') === 1,
      postClientAuthenticatesCodeAndRefresh: secretAuthentication('post', 'client_secret_post', 'authorization_code') === 1
        && secretAuthentication('post', 'client_secret_post', 'refresh_token') === 1 && count('exchanged', 'post') === 1 && count('refreshed', 'post') === 1,
      boundConsentAndIncorrectSecretRejected: count('approved', 'basic') === 4 && count('approved', 'post') === 1
        && events.filter(e => e.event === 'client-rejected' && e.mode === 'basic' && e.method === 'client_secret_basic').length === 1,
      basicDefaultAndBlockedRedirect: events.some(e => e.event === 'fixture-client-methods-omitted') && events.some(e => e.event === 'fixture-token-redirect')
        && !events.some(e => e.event === 'token-redirect-followed' || e.event === 'client-credential-outside-token'),
      noFallbackWithoutMetadataSupport: metadataDisabled >= 0 && afterMetadataDisabled.some(e => e.event === 'issuer-metadata' && !e.clientMetadataSupported)
        && !afterMetadataDisabled.some(e => ['registered', 'approved', 'consent-page', 'client-metadata-fetched'].includes(e.event)),
      inventoryMatchesIndependentSource: Object.keys(report.inventory).length === 14 && Object.values(report.inventory).every(matching) && events.filter(e => e.event === 'rpc' && e.method === 'tools/call' && e.authorized && e.sku === stock.sku).length === 14,
      onlyRequestedResourceReceivesGrant: !events.some(e => e.event === 'other-resource' || e.event === 'fixture-error'),
      credentialsOmittedFromLogs: !protocol.includes('public-fixture-') && !protocol.includes('local-client-'),
      failedHandshakeActuallyReturned: events.some(e => e.event === 'public-credential-in-error'),
      noModels: report.modelRequests === 0
    };
    const success = status.code === 0 && report.success && Object.values(independent).every(Boolean);
    await writeFile(path.join(output, 'independent.json'), JSON.stringify({ status, app, binaryHash, report, independent, success }, null, 2) + '\n');
    console.log(JSON.stringify({ output, success, checks: Object.keys(report.checks).length, failed: Object.keys(report.checks).filter(name => !report.checks[name]), independent, error: report.error }));
    process.exitCode = success ? 0 : 1;
  }
} finally { stop(); await fixtureExit; }

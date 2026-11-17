import { spawn, spawnSync } from 'node:child_process';
import { mkdtemp, mkdir, writeFile, symlink } from 'node:fs/promises';
import http from 'node:http';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../', import.meta.url));
const output = await mkdtemp(path.join(root, 'evidence/agent/credential-config-check-'));
const alias = path.join('/tmp', 'bff-' + path.basename(output));
await symlink(output, alias);
for (const name of ['tmp', 'swift-cache', 'clang-cache']) await mkdir(path.join(output, name));
const env = { ...process.env, TMPDIR: path.join(alias, 'tmp') + '/' };
const binary = path.join(output, 'check'), fixture = path.join(output, 'profile');
const sources = ['native/Preferences.swift', 'native/ModelSettings.swift', 'native/Conversation.swift', 'scripts/NativeCredentialConfigCheck.swift'];
const compiled = spawnSync('xcrun', ['swiftc', '-swift-version', '5', '-module-cache-path', path.join(alias, 'swift-cache'), '-Xcc', '-fmodules-cache-path=' + path.join(alias, 'clang-cache'), ...sources, '-framework', 'Security', '-o', binary], { cwd: root, env, encoding: 'utf8' });
await writeFile(path.join(output, 'compile.log'), (compiled.stdout ?? '') + (compiled.stderr ?? ''));
if (compiled.error || compiled.status !== 0) throw compiled.error ?? Error('Credential check compilation failed: ' + output);
const rows = [];
for (const mode of ['seed', 'verify']) {
  const result = spawnSync(binary, [mode, fixture], { env, encoding: 'utf8' });
  await writeFile(path.join(output, mode + '.log'), (result.stdout ?? '') + (result.stderr ?? ''));
  if (result.error || result.status !== 0) throw result.error ?? Error('Credential check failed: ' + mode + ' in ' + output);
  rows.push(JSON.parse(result.stdout));
}
const requests = [];
const server = http.createServer(async (request, response) => {
  let body = ''; for await (const bytes of request) body += bytes;
  const authorized = request.headers.authorization === 'Bearer public-fixture-model-key-0123456789';
  requests.push({ path: request.url, authorized, model: JSON.parse(body).model });
  response.writeHead(authorized ? 200 : 401, { 'Content-Type': 'application/json' });
  response.end(JSON.stringify({ choices: [{ message: { content: 'OK' }, finish_reason: 'stop' }] }));
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
try {
  const result = await new Promise((resolve, reject) => {
    const process = spawn(binary, ['probe', fixture, 'http://127.0.0.1:' + server.address().port], { env });
    let stdout = '', stderr = '';
    process.stdout.on('data', data => stdout += data); process.stderr.on('data', data => stderr += data);
    process.on('error', reject); process.on('exit', code => resolve({ code, stdout, stderr }));
  });
  await writeFile(path.join(output, 'probe.log'), result.stdout + result.stderr);
  if (result.code !== 0) throw Error('Local saved-key request failed: ' + output);
  rows.push(JSON.parse(result.stdout));
} finally { await new Promise(resolve => server.close(resolve)); }
const checks = rows.reduce((sum, row) => sum + Object.keys(row.checks).length, 0);
const success = rows.every(row => row.success && Object.values(row.checks).every(Boolean)) && requests.length === 1 && requests.every(request => request.authorized);
await writeFile(path.join(output, 'report.json'), JSON.stringify({ success, checks, rows, requests, realModelRequests: 0 }, null, 2) + '\n');
console.log(JSON.stringify({ output, success, checks, localRequests: requests.length, realModelRequests: 0 }));
process.exitCode = success ? 0 : 1;

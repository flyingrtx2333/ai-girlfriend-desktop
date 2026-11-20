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
  throw Error('选择独立验收应用 BLUEFATFISH_APP，或使用 --serve 启动公开目录样例。');
}
const output = await mkdtemp(path.join(root, 'evidence/agent/plugin-market-command-'));
const server = path.join(output, 'server');
for (const name of ['server', 'tmp', 'shared-home']) await mkdir(path.join(output, name));
function openssl(args) {
  const run = spawnSync('/usr/bin/openssl', args, { cwd: server, encoding: 'utf8' });
  if (run.status !== 0) throw Error(run.stderr || '无法生成本机目录验收证书。');
}
openssl(['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '2', '-subj', '/CN=localhost', '-keyout', 'test-key.pem', '-out', 'test-cert.pem']);
openssl(['x509', '-in', 'test-cert.pem', '-outform', 'DER', '-out', 'test-cert.der']);
const fixture = spawn(process.execPath, [path.join(root, 'scripts/fixtures/plugin-market.mjs'), server], { stdio: ['ignore', 'ignore', 'inherit'] });
const exited = new Promise((resolve, reject) => { fixture.once('error', reject); fixture.once('close', resolve); });
const stop = () => { if (fixture.exitCode === null && fixture.signalCode === null) fixture.kill('SIGTERM'); };
process.once('SIGTERM', stop); process.once('SIGINT', stop);
const json = async file => JSON.parse(await readFile(file, 'utf8'));
try {
  let ready;
  for (let retry = 0; retry < 100; retry++) {
    try { ready = await json(path.join(server, 'ready.json')); break; } catch { await delay(30); }
  }
  if (ready?.pid !== fixture.pid) throw Error('本机插件市场服务未就绪。');
  if (manual) {
    console.log(JSON.stringify({ output, origin: ready.origin, listing: ready.origin + '/marketplace.json', fixturePID: fixture.pid }));
    process.exitCode = await exited;
  } else {
    const binary = path.resolve(app, 'Contents/MacOS/BlueFatFish');
    const hash = data => createHash('sha256').update(data).digest('hex');
    const binaryHash = hash(await readFile(binary));
    const child = spawn(binary, ['--check', output, '--plugin-market-check'], { cwd: root,
      env: { ...process.env, TMPDIR: path.join(output, 'tmp') + '/' }, stdio: ['ignore', 'pipe', 'pipe'] });
    let launchLog = '';
    child.stdout.on('data', data => { launchLog += data; }); child.stderr.on('data', data => { launchLog += data; });
    const timeout = setTimeout(() => child.kill('SIGTERM'), 95_000);
    const processStatus = await new Promise((resolve, reject) => { child.once('error', reject); child.once('close', (code, signal) => resolve({ code, signal })); }).finally(() => clearTimeout(timeout));
    await writeFile(path.join(output, 'launch.log'), launchLog);
    const report = await json(path.join(output, 'plugin-market-report.json'));
    const requests = (await readFile(path.join(server, 'requests.jsonl'), 'utf8')).split('\n').filter(Boolean).map(JSON.parse);
    const facts = await json(path.join(server, 'facts.json'));
    const expected = (phase, item) => (report.results[phase] ?? '').includes(item.sku)
      && new RegExp('"quantity"\\s*:\\s*' + item.quantity + '\\b').test(report.results[phase] ?? '')
      && (report.results[phase] ?? '').includes('"' + item.version + '"');
    const independent = {
      exactAppUsed: child.pid === report.appPID && hash(await readFile(binary)) === binaryHash,
      concreteHTTPSListings: ['1.0.0', '2.0.0'].every(version => requests.some(row => row.event === 'directory' && row.version === version && row.tls)),
      completeArchiveBytes: (await Promise.all(facts.map(async item => {
        const name = 'inventory-helper-' + item.version + '.zip', sha256 = hash(await readFile(path.join(server, name)));
        return requests.some(row => row.event === 'archive' && row.name === name && row.sha256 === sha256 && row.tls);
      }))).every(Boolean),
      badDigestActuallyFetched: requests.some(row => row.event === 'archive' && row.name === 'bad-checksum.zip' && row.sha256 !== '0'.repeat(64)),
      installedSkillsReadIndependentFacts: expected('install', facts[0]) && expected('update', facts[1]),
      credentialFreeArchiveRequests: !requests.some(row => row.credentialHeader || row.event === 'unknown-path'),
      noModels: report.modelRequests === 0
    };
    const success = processStatus.code === 0 && report.success && Object.values(independent).every(Boolean);
    await writeFile(path.join(output, 'independent.json'), JSON.stringify({ app, binaryHash, processStatus, report, independent, success }, null, 2) + '\n');
    console.log(JSON.stringify({ output, success, checks: Object.keys(report.checks).length, failed: Object.keys(report.checks).filter(name => !report.checks[name]), independent, error: report.error }));
    process.exitCode = success ? 0 : 1;
  }
} finally { stop(); await exited; }

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
  throw Error('选择独立验收应用 BLUEFATFISH_APP，或使用 --serve 启动目录样例。');
}
const output = await mkdtemp(path.join(root, 'evidence/agent/plugin-market-command-'));
const server = path.join(output, 'server');
for (const name of ['server', 'tmp', 'shared-home']) await mkdir(path.join(output, name));
function openssl(args) {
  const run = spawnSync('/usr/bin/openssl', args, { cwd: server, encoding: 'utf8' });
  if (run.status !== 0) throw Error(run.stderr || '无法生成本机目录验收证书。');
}
openssl(['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '2', '-subj', '/CN=localhost',
  '-addext', 'subjectAltName=DNS:localhost', '-addext', 'basicConstraints=critical,CA:TRUE',
  '-addext', 'keyUsage=critical,keyCertSign,digitalSignature,keyEncipherment', '-addext', 'subjectKeyIdentifier=hash',
  '-keyout', 'test-key.pem', '-out', 'test-cert.pem']);
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
    const privateFacts = await json(path.join(server, 'private-facts.json'));
    const commits = await json(path.join(server, 'repository-facts.json'));
    const expected = (phase, item) => (report.results[phase] ?? '').includes(item.sku)
      && new RegExp('"quantity"\\s*:\\s*' + item.quantity + '\\b').test(report.results[phase] ?? '')
      && (report.results[phase] ?? '').includes('"' + item.version + '"');
    function trackedFile(commit, file) {
      const actual = spawnSync('/usr/bin/git', ['-C', path.join(server, 'repository'), 'show', commit + ':' + file], { encoding: 'utf8' });
      if (actual.status !== 0) throw Error('无法独立读取样例提交的原始文件');
      return JSON.parse(actual.stdout);
    }
    const stock = 'skills/inventory/resources/count.json';
    const verb = ['Install', 'Update'];
    const gitFacts = commits.every(({ commit }, index) =>
      expected('repo' + verb[index], trackedFile(commit, 'plugins/repo-stock/' + stock))
      && expected('root' + verb[index], trackedFile(commit, stock)));
    const newVersion = requests.findIndex(row => row.event === 'fixture-state' && row.version === '2.0.0');
    const independent = {
      exactAppUsed: child.pid === report.appPID && hash(await readFile(binary)) === binaryHash,
      concreteHTTPSListings: ['1.0.0', '2.0.0'].every(version => requests.some(row => row.event === 'directory' && row.version === version && row.tls)),
      completeArchiveBytes: (await Promise.all(facts.map(async item => {
        const name = 'inventory-helper-' + item.version + '.zip', sha256 = hash(await readFile(path.join(server, name)));
        return requests.some(row => row.event === 'archive' && row.name === name && row.sha256 === sha256 && row.tls);
      }))).every(Boolean),
      badDigestActuallyFetched: requests.some(row => row.event === 'archive' && row.name === 'bad-checksum.zip' && row.sha256 !== '0'.repeat(64)),
      installedSkillsReadIndependentFacts: expected('install', facts[0]) && expected('update', facts[1]),
      bothBranchRefsActuallyResolve: commits.every(({ commit }) => requests.some(row => row.event === 'git-ref' && row.ref === 'release/inventory' && row.commit === commit && row.tls)),
      pinnedManifestsFetchedAtBothCommits: commits.every(({ commit }) =>
        requests.some(row => row.event === 'git-manifest' && row.ref === commit && row.key === 'contents/.claude-plugin/marketplace.json' && row.tls)),
      downloadedBothUnmodifiedGitArchives: (await Promise.all(commits.map(async ({ commit }) => {
        const digest = hash(await readFile(path.join(server, commit + '.zip')));
        return requests.some(row => row.event === 'git-archive' && row.commit === commit && row.sha256 === digest && row.tls);
      }))).every(Boolean),
      afterBranchMoveStillLoadsPinnedOldCommit: newVersion >= 0 && requests.slice(newVersion).some(row => row.event === 'git-archive' && row.commit === commits[0].commit)
        && !requests.some(row => row.event === 'git-ref' && row.ref === 'removed-branch'),
      installedRepositorySkillsReadIndependentlyVerifiedGitFiles: gitFacts,
      realGenericGitPackReadsBothCommits: commits.every(({ commit }) =>
        requests.some(row => row.event === 'git-http' && row.tls && row.uploadPack && row.requested === commit && row.hasFetch)),
      nativeHTTPSGitReadsExactInitialUpdatedAndRestoredPayloads:
        expected('httpsGitInstall', trackedFile(commits[0].commit, 'plugins/repo-stock/' + stock))
        && expected('httpsGitUpdate', trackedFile(commits[1].commit, 'plugins/repo-stock/' + stock))
        && expected('httpsGitRestore', trackedFile(commits[0].commit, 'plugins/repo-stock/' + stock))
        && expected('httpsGitBranch', trackedFile(commits[1].commit, stock)),
      oldCommitWasFetchedAfterLiveBranchAdvanced: requests.some(row => row.event === 'git-http' && row.version === '2.0.0'
        && row.requested === commits[0].commit && row.hasFetch),
      protectedGitRedirectDidNotMakeSecondRequest: requests.some(row => row.event === 'git-redirect')
        && !requests.some(row => row.event === 'git-followed-redirect'),
      publicRequestsRemainCredentialFree: !requests.some(row =>
        (row.credentialHeader && !['private-directory-request', 'private-git-http', 'private-git-denied'].includes(row.event))
        || row.event === 'unknown-path'),
      privateListingAndPackageRequiredTheExactCredential: privateFacts.every(({ version }) =>
        ['/private/marketplace.json', '/private/private-inventory-' + version + '.zip'].every(endpoint =>
          requests.some(row => row.event === 'private-directory-request' && row.path === endpoint && row.version === version
            && row.authorized && row.credentialHeader && row.tls))),
      deniedEachPrivateMarketWithoutItsOwnToken: requests.some(row => row.event === 'private-directory-request' && !row.authorized && !row.credentialHeader)
        && requests.some(row => row.event === 'private-directory-request' && !row.authorized && row.credentialHeader)
        && requests.some(row => row.event === 'private-git-denied' && !row.credentialHeader)
        && !requests.some(row => row.event === 'private-git-denied' && row.credentialHeader),
      neighboringArchiveRequestedWithoutCredentials: requests.some(row => row.event === 'neighboring-public-archive' && row.tls && !row.credentialHeader),
      privateRedirectNeverReachedItsDestination: requests.some(row => row.path === '/private/redirect.zip' && row.authorized)
        && !requests.some(row => row.path === '/private/redirect-destination.zip'),
      realAuthenticatedGitFetchUsesBothPinnedCommits: commits.every(({ commit }) =>
        requests.some(row => row.event === 'private-git-http' && row.tls && row.credentialHeader && row.hasFetch && row.requested === commit)),
      privateInstallAndUpdateMatchOriginalFixtures: commits.every(({ commit }, index) =>
        expected('privateArchive' + verb[index], privateFacts[index]) && expected('privateGit' + verb[index], trackedFile(commit, 'plugins/repo-stock/' + stock))),
      noModels: report.modelRequests === 0
    };
    const success = processStatus.code === 0 && report.success && Object.values(independent).every(Boolean);
    await writeFile(path.join(output, 'independent.json'), JSON.stringify({ app, binaryHash, processStatus, report, independent, success }, null, 2) + '\n');
    console.log(JSON.stringify({ output, success, checks: Object.keys(report.checks).length, failed: Object.keys(report.checks).filter(name => !report.checks[name]), independent, error: report.error }));
    process.exitCode = success ? 0 : 1;
  }
} finally { stop(); await exited; }

import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { installNativeBuild } from './native-delivery.mjs';

const root = fileURLToPath(new URL('../', import.meta.url));
if (process.argv.length !== 2 && !(process.argv.length === 4 && process.argv[2] === '--app')) throw new Error('可用 --app 指定原证书签名应用；检查不会启动或修改它。');
const source = path.resolve(process.argv[3] ?? path.join(root, 'build/蓝色大肥鱼.app'));
await fs.mkdir(path.join(root, 'evidence/agent'), { recursive: true });
const output = await fs.mkdtemp(path.join(root, 'evidence/agent/native-delivery-'));
process.env.TMPDIR = output + path.sep;
const run = (command, args) => execFileSync(command, args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
const digest = async file => createHash('sha256').update(await fs.readFile(file)).digest('hex');
const appFiles = application => ['Contents/MacOS/BlueFatFish', 'Contents/Info.plist', 'Contents/_CodeSignature/CodeResources'].map(file => path.join(application, file));
const fingerprint = application => Promise.all(appFiles(application).map(digest));
const original = await fingerprint(source);
run('/usr/bin/codesign', ['--verify', '--deep', '--strict', source]);
const checks = [];
async function fixture(name) {
  const directory = path.join(output, name); await fs.mkdir(directory);
  const candidate = path.join(directory, 'candidate.app'), destination = path.join(directory, 'installed.app');
  for (const application of [candidate, destination]) run('/bin/cp', ['-cR', source, application]);
  return { directory, candidate, destination };
}
async function rejected(name, prepare, pattern) {
  const item = await fixture(name); await prepare(item);
  const before = await fingerprint(item.destination), candidateBefore = await fingerprint(item.candidate);
  await assert.rejects(installNativeBuild(item.candidate, item.destination), pattern);
  assert.deepEqual(await fingerprint(item.destination), before);
  assert.deepEqual(await fingerprint(item.candidate), candidateBefore);
  checks.push(name + ': rejected; candidate and installed contents preserved');
}
try {
  const success = await fixture('successful-update');
  const oldInode = (await fs.stat(success.destination)).ino, newInode = (await fs.stat(success.candidate)).ino;
  const installed = await installNativeBuild(success.candidate, success.destination);
  assert.equal((await fs.stat(installed.application)).ino, newInode);
  assert.equal((await fs.stat(installed.backup)).ino, oldInode);
  assert.deepEqual(await fingerprint(installed.application), original);
  assert.deepEqual(await fingerprint(installed.backup), original);
  assert.match(installed.certificateSHA256, /^[0-9a-f]{64}$/);
  checks.push('successful-update: candidate installed; exact prior directory and signed contents backed up');

  const first = await fixture('first-install'), firstTarget = path.join(first.directory, 'new.app');
  const firstResult = await installNativeBuild(first.candidate, firstTarget);
  assert.equal(firstResult.backup, null);
  assert.deepEqual(await fingerprint(firstTarget), original);
  checks.push('first-install: verified production candidate installed without deleting another application');

  await rejected('invalid-signature', async ({ candidate }) => {
    await fs.appendFile(path.join(candidate, 'Contents/MacOS/BlueFatFish'), 'invalid signature fixture');
  }, /codesign/);
  await rejected('acceptance-package', async ({ candidate }) => {
    run('/usr/bin/plutil', ['-insert', 'BlueFatFishAcceptanceOnly', '-bool', 'true', path.join(candidate, 'Contents/Info.plist')]);
  }, /独立验收包/);
  await rejected('different-identifier', async ({ candidate }) => {
    run('/usr/bin/plutil', ['-replace', 'CFBundleIdentifier', '-string', 'com.xjs.bluefatfish.delivery-fixture', path.join(candidate, 'Contents/Info.plist')]);
  }, /正式候选/);
  await rejected('adhoc-signature', async ({ candidate }) => {
    run('/usr/bin/codesign', ['--force', '--sign', '-', '--timestamp=none', candidate]);
    run('/usr/bin/codesign', ['--verify', '--deep', '--strict', candidate]);
  }, /原证书签名/);

  for (const target of ['candidate', 'destination']) {
    const busy = await fixture(target + '-in-use'), handle = await fs.open(path.join(busy[target], 'Contents/MacOS/BlueFatFish'), 'r');
    try {
      await assert.rejects(installNativeBuild(busy.candidate, busy.destination), /仍在使用/);
      assert.deepEqual(await fingerprint(busy.candidate), original);
      assert.deepEqual(await fingerprint(busy.destination), original);
    } finally { await handle.close(); }
    checks.push(target + '-in-use: actual open executable refused; both applications preserved');
  }

  const failed = await fixture('rename-failure'), rename = fs.rename;
  fs.rename = async (from, to) => {
    if (from === failed.candidate && to === failed.destination) throw Object.assign(new Error('simulated install failure'), { code: 'EIO' });
    return rename(from, to);
  };
  try { await assert.rejects(installNativeBuild(failed.candidate, failed.destination), /simulated install failure/); }
  finally { fs.rename = rename; }
  assert.deepEqual(await fingerprint(failed.destination), original);
  assert.deepEqual(await fingerprint(failed.candidate), original);
  checks.push('rename-failure: actual previous directory restored; failed candidate retained');

  const backupFailed = await fixture('backup-failure');
  fs.rename = async (from, to) => {
    if (from === backupFailed.destination) throw Object.assign(new Error('simulated backup failure'), { code: 'EACCES' });
    return rename(from, to);
  };
  try { await assert.rejects(installNativeBuild(backupFailed.candidate, backupFailed.destination), /simulated backup failure/); }
  finally { fs.rename = rename; }
  assert.deepEqual(await fingerprint(backupFailed.destination), original);
  assert.deepEqual(await fingerprint(backupFailed.candidate), original);
  checks.push('backup-failure: installed application and candidate preserved in place');

  const recoveryFailed = await fixture('recovery-failure');
  fs.rename = async (from, to) => {
    if (to === recoveryFailed.destination) throw Object.assign(new Error('simulated install/recovery failure'), { code: 'EIO' });
    return rename(from, to);
  };
  try { await assert.rejects(installNativeBuild(recoveryFailed.candidate, recoveryFailed.destination), error => error instanceof AggregateError && /旧版仍保留/.test(error.message)); }
  finally { fs.rename = rename; }
  const [saved] = (await fs.readdir(recoveryFailed.directory)).filter(name => name.startsWith('previous-'));
  assert.ok(saved);
  assert.deepEqual(await fingerprint(path.join(recoveryFailed.directory, saved, 'installed.app')), original);
  assert.deepEqual(await fingerprint(recoveryFailed.candidate), original);
  checks.push('recovery-failure: original signed application retained at reported backup; candidate preserved');

  const same = await fixture('same-path');
  await assert.rejects(installNativeBuild(same.candidate, same.candidate), /独立目录/);
  assert.deepEqual(await fingerprint(same.candidate), original);
  checks.push('same-path: refused before changing either application');
  const nested = await fixture('nested-path');
  await assert.rejects(installNativeBuild(nested.destination, path.join(nested.destination, 'Contents/child.app')), /独立目录/);
  assert.deepEqual(await fingerprint(nested.destination), original);
  checks.push('nested-path: refused before changing containing application');
  const linked = await fixture('symlink-destination');
  const link = path.join(linked.directory, 'linked.app'); await fs.symlink(linked.destination, link);
  await assert.rejects(installNativeBuild(linked.candidate, link), /独立的应用目录/);
  assert.deepEqual(await fingerprint(linked.destination), original);
  checks.push('symlink-destination: real application and path link preserved');

  assert.deepEqual(await fingerprint(source), original);
  run('/usr/bin/codesign', ['--verify', '--deep', '--strict', source]);
  checks.push('original-application: signed executable, metadata and resource seal unchanged; never launched');
  const report = { success: true, source, output, modelRequests: 0, privateSigningIdentityUsed: false, checks };
  await fs.writeFile(path.join(output, 'delivery-report.json'), JSON.stringify(report, null, 2) + '\n');
  console.log(JSON.stringify(report, null, 2));
} catch (error) {
  await fs.writeFile(path.join(output, 'delivery-report.json'), JSON.stringify({ success: false, source, output, checks, error: error.stack }, null, 2) + '\n');
  throw error;
}

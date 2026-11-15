import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { installNativeBuild } from './native-delivery.mjs';

const root = fileURLToPath(new URL('../', import.meta.url));
const output = await fs.mkdtemp(path.join(root, 'evidence/agent/local-delivery-'));
process.env.TMPDIR = output + '/';
const run = (command, args) => execFileSync(command, args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
const checks = [];
const metadata = { CFBundleIdentifier: 'com.xjs.bluefatfish', CFBundleExecutable: 'BlueFatFish', NSAccentColorName: 'AccentColor', BlueFatFishSourceCommit: 'a'.repeat(40), BlueFatFishSourceDirty: false, BlueFatFishBuildDate: new Date().toISOString() };
async function app(directory, name, overrides = {}) {
  const target = path.join(directory, name + '.app');
  await fs.mkdir(path.join(target, 'Contents/MacOS'), { recursive: true });
  run('/bin/cp', ['-c', path.join(root, 'build/蓝色大肥鱼.app/Contents/MacOS/BlueFatFish'), path.join(target, 'Contents/MacOS/BlueFatFish')]);
  await fs.writeFile(path.join(target, 'Contents/Info.plist'), JSON.stringify({ ...metadata, ...overrides }));
  run('/usr/bin/plutil', ['-convert', 'xml1', path.join(target, 'Contents/Info.plist')]);
  run('/usr/bin/codesign', ['--force', '--sign', '-', '--timestamp=none', target]);
  return target;
}
async function fixture(name, overrides) {
  const directory = path.join(output, name); await fs.mkdir(directory);
  return { candidate: await app(directory, 'candidate', overrides), destination: await app(directory, 'installed') };
}
async function rejected(name, overrides, pattern) {
  const item = await fixture(name, overrides), before = (await fs.stat(item.destination)).ino;
  await assert.rejects(installNativeBuild(item.candidate, item.destination, { local: true }), pattern);
  assert.equal((await fs.stat(item.destination)).ino, before);
  run('/usr/bin/codesign', ['--verify', '--deep', '--strict', item.destination]);
  await fs.access(item.candidate); checks.push(name);
}
try {
  const item = await fixture('local-update'), oldInode = (await fs.stat(item.destination)).ino;
  await assert.rejects(installNativeBuild(item.candidate, item.destination), /原证书签名/);
  checks.push('local-signature-requires-explicit-option');
  const installed = await installNativeBuild(item.candidate, item.destination, { local: true });
  assert.equal(installed.signing, 'local'); assert.equal(installed.sourceCommit, metadata.BlueFatFishSourceCommit);
  assert.equal((await fs.stat(installed.backup)).ino, oldInode);
  run('/usr/bin/codesign', ['--verify', '--deep', '--strict', installed.application]);
  checks.push('local-update-preserves-exact-old-directory');
  for (const [name, overrides, pattern] of [
    ['acceptance-rejected', { BlueFatFishAcceptanceOnly: true }, /独立验收包/],
    ['wrong-identity-rejected', { CFBundleIdentifier: 'com.example.fixture' }, /正式候选/],
    ['missing-accent-rejected', { NSAccentColorName: '' }, /强调色/],
    ['dirty-source-rejected', { BlueFatFishSourceDirty: true }, /干净源码/],
    ['missing-revision-rejected', { BlueFatFishSourceCommit: '' }, /干净源码/],
    ['invalid-build-date-rejected', { BlueFatFishBuildDate: 'unknown' }, /构建时间/]
  ]) await rejected(name, overrides, pattern);
  const busy = await fixture('busy-destination'), handle = await fs.open(path.join(busy.destination, 'Contents/MacOS/BlueFatFish'));
  try { await assert.rejects(installNativeBuild(busy.candidate, busy.destination, { local: true }), /仍在使用/); }
  finally { await handle.close(); }
  checks.push('actual-open-executable-rejected');
  const failed = await fixture('rollback'), originalRename = fs.rename, before = (await fs.stat(failed.destination)).ino;
  fs.rename = async (from, to) => { if (from === failed.candidate) throw new Error('install fixture failure'); return originalRename(from, to); };
  try { await assert.rejects(installNativeBuild(failed.candidate, failed.destination, { local: true }), /install fixture failure/); }
  finally { fs.rename = originalRename; }
  assert.equal((await fs.stat(failed.destination)).ino, before); await fs.access(failed.candidate);
  checks.push('failed-install-restores-exact-old-directory');
  await fs.writeFile(path.join(output, 'report.json'), JSON.stringify({ success: true, checks, modelRequests: 0 }, null, 2));
  console.log(JSON.stringify({ output, success: true, checks: checks.length, modelRequests: 0 }));
} catch (error) {
  await fs.writeFile(path.join(output, 'report.json'), JSON.stringify({ success: false, checks, error: error.stack }, null, 2));
  throw error;
}

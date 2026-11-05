import { spawnSync } from 'node:child_process';
import { readFile, mkdir, writeFile } from 'node:fs/promises';
import { createHash, randomUUID } from 'node:crypto';
import { signNative } from './native-signing.mjs';

await mkdir('build/keychain-check', { recursive: true });
await mkdir('evidence/edition23', { recursive: true });
function run(command, args) {
  const r = spawnSync(command, args, { encoding: 'utf8', timeout: 25_000 });
  if (r.error || r.status !== 0) throw new Error(`${args[0]}: ${r.error?.message || r.stderr || r.stdout}`);
  return r;
}
const base = `com.xjs.bluefatfish.check.${randomUUID()}`;
const before = 'build/keychain-check/before', after = 'build/keychain-check/after', legacy = 'build/keychain-check/legacy';
const source = ['native/Preferences.swift', 'native/ModelSettings.swift', 'native/Conversation.swift', 'scripts/NativeKeychainCheck.swift'];
run('xcrun', ['swiftc', '-O', '-swift-version', '5', ...source, '-framework', 'Security', '-o', before]);
run('xcrun', ['swiftc', '-O', '-swift-version', '5', '-D', 'UPDATED', ...source, '-framework', 'Security', '-o', after]);
await writeFile(legacy, await readFile(before), { mode: 0o755 });
run('codesign', ['--force', '--sign', '-', '--identifier', 'com.xjs.bluefatfish.legacy-keychaincheck', legacy]);
signNative(before, 'com.xjs.bluefatfish.keychaincheck'); signNative(after, 'com.xjs.bluefatfish.keychaincheck');
const rows = [];
function check(binary, mode, service, ...args) { const value = JSON.parse(run(binary, [mode, service, ...args]).stdout); rows.push(value); console.log(JSON.stringify(value)); return value; }
try {
  check(legacy, 'legacy-write', base + '.old');
  check(before, 'write', base + '.current');
  check(after, 'read', base + '.current');
  check(after, 'legacy', base + '.migrated', base + '.old');
  check(legacy, 'read-legacy', base + '.old');
  const requirement = binary => {
    const r = run('codesign', ['-d', '-r-', binary]);
    const match = `${r.stdout}\n${r.stderr}`.match(/^(?:# )?designated => (.+)$/m);
    if (!match) throw new Error('Cannot read designated requirement.');
    return match[1];
  };
  const hash = async binary => createHash('sha256').update(await readFile(binary)).digest('hex');
  const stable = requirement(before) === requirement(after) && !requirement(after).includes('cdhash');
  const changed = await hash(before) !== await hash(after);
  if (!stable || !changed) throw new Error('Signing identity did not remain stable across changed code.');
  const report = { success: true, changedBinary: changed, stableRequirement: stable, rows,
    scope: 'Real macOS Keychain with isolated public fixture credentials. Different binaries, same Apple certificate. Legacy ad-hoc item is retained. No user credentials or ACLs are changed.' };
  await writeFile('evidence/edition23/keychain-check.json', JSON.stringify(report, null, 2) + '\n');
  console.log(JSON.stringify(report, null, 2));
} finally {
  for (const [binary, suffix] of [[before, '.current'], [after, '.migrated'], [legacy, '.old']]) {
    try { run(binary, ['cleanup', base + suffix]); } catch (e) { console.error(`Fixture cleanup ${suffix}: ${e.message}`); }
  }
}

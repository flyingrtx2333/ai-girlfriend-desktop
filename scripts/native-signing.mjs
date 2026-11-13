import { execFileSync, spawnSync } from 'node:child_process';
import { realpathSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

export function signingIdentity() {
  const output = execFileSync('/usr/bin/security', ['find-identity', '-v', '-p', 'codesigning'], { encoding: 'utf8' });
  const identities = [...output.matchAll(/^\s*\d+\) ([A-F0-9]{40}) "([^"]+)"/gm)]
    .map(([, hash, name]) => ({ hash, name }));
  const requested = process.env.BLUEFATFISH_SIGN_IDENTITY;
  const candidates = requested ? identities.filter(i => i.hash === requested || i.name === requested)
    : identities.filter(i => /^(Apple Development:|Developer ID Application:)/.test(i.name));
  if (candidates.length !== 1) throw new Error('请用 BLUEFATFISH_SIGN_IDENTITY 指定一个有效的 Apple 签名证书；应用不再回退到临时签名。');
  return candidates[0].hash;
}

export function signNative(target, identifier) {
  const args = ['--force', '--sign', signingIdentity(), '--timestamp=none'];
  if (identifier) args.push('--identifier', identifier);
  execFileSync('/usr/bin/codesign', [...args, target], { stdio: 'inherit' });
  execFileSync('/usr/bin/codesign', ['--verify', '--strict', target], { stdio: 'inherit' });
}

export function signNativeCheck(target) {
  const info = path.join(target, 'Contents/Info.plist');
  const value = key => execFileSync('/usr/bin/plutil', ['-extract', key, 'raw', '-o', '-', info], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim();
  let isolated = false;
  try { isolated = value('BlueFatFishAcceptanceOnly') === 'true' && value('CFBundleIdentifier').startsWith('com.xjs.bluefatfish.'); } catch { /* Missing metadata is not an acceptance package. */ }
  if (!isolated) {
    throw new Error('本地签名只用于独立验收包，不能替换日常应用的签名。');
  }
  execFileSync('/usr/bin/codesign', ['--force', '--sign', '-', '--timestamp=none', target], { stdio: 'inherit' });
  execFileSync('/usr/bin/codesign', ['--verify', '--deep', '--strict', target], { stdio: 'inherit' });
}

export function verifyNativeCandidate(target) {
  execFileSync('/usr/bin/codesign', ['--verify', '--deep', '--strict', target], { stdio: ['ignore', 'pipe', 'pipe'] });
  const signing = spawnSync('/usr/bin/codesign', ['-d', '--verbose=4', target], { encoding: 'utf8' });
  const metadata = JSON.parse(execFileSync('/usr/bin/plutil', ['-convert', 'json', '-o', '-', path.join(target, 'Contents/Info.plist')], { encoding: 'utf8' }));
  const project = signing.status === 0 && /^Authority=(Developer ID Application:|Apple Development:)/m.test(signing.stderr) && /^TeamIdentifier=8BPSC5L74V$/m.test(signing.stderr);
  if (project) return { kind: 'project', identifier: metadata.CFBundleIdentifier };
  const relative = path.relative(realpathSync(fileURLToPath(new URL('../evidence/agent', import.meta.url))), realpathSync(target));
  const isolated = signing.status === 0 && /^Signature=adhoc$/m.test(signing.stderr) && metadata.BlueFatFishAcceptanceOnly === true && metadata.CFBundleIdentifier?.startsWith('com.xjs.bluefatfish.') && relative && !relative.startsWith('..') && !path.isAbsolute(relative);
  if (!isolated) throw new Error('候选应用签名或独立验收标记无效。');
  return { kind: 'isolated-local', identifier: metadata.CFBundleIdentifier };
}

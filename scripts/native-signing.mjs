import { execFileSync } from 'node:child_process';
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

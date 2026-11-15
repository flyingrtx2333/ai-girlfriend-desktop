import fs from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { execFileSync, spawnSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../', import.meta.url));
const dailyApplication = path.join(root, 'build/蓝色大肥鱼.app');
const run = (command, args) => execFileSync(command, args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
function productionInfo(application) {
  const info = JSON.parse(run('/usr/bin/plutil', ['-convert', 'json', '-o', '-', path.join(application, 'Contents/Info.plist')]));
  if (info.BlueFatFishAcceptanceOnly || info.CFBundleIdentifier !== 'com.xjs.bluefatfish' || info.CFBundleExecutable !== 'BlueFatFish') {
    throw new Error('只能安装日常应用的正式候选；独立验收包继续留在验收目录。');
  }
  run('/usr/bin/codesign', ['--verify', '--deep', '--strict', application]);
  return info;
}
function assertUnused(application) {
  const result = spawnSync('/usr/sbin/lsof', ['-Fpcfat', path.join(application, 'Contents/MacOS/BlueFatFish')], { encoding: 'utf8' });
  if (result.error) throw result.error;
  if (![0, 1].includes(result.status) || result.stderr.trim()) throw new Error('无法确认应用是否正在使用，未替换应用。');
  for (const record of result.stdout.trim().split(/\n(?=p\d)/).filter(Boolean)) {
    const pid = record.match(/^p(\d+)\n/)?.[1];
    const descriptors = record.split('\nf').slice(1);
    // The system's shared-volume service retains read caches for files inspected
    // by development tools. It does not execute this Mac application. Keep all
    // executable mappings, write handles and other readers protected.
    const readCache = descriptors.length > 0 && descriptors.every(value => /^\d+\nar\ntREG\n?$/.test(value));
    const service = pid && readCache ? run('/bin/ps', ['-p', pid, '-o', 'comm=']).trim() : '';
    if (service !== '/System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine') {
      throw new Error('应用文件仍在使用，请正常退出应用后再安装；候选已保留。');
    }
  }
}

export async function installNativeBuild(candidatePath, destinationPath = dailyApplication, { local = false } = {}) {
  const candidate = await fs.realpath(candidatePath);
  const destination = path.join(await fs.realpath(path.dirname(destinationPath)), path.basename(destinationPath));
  if (candidate === destination || candidate.startsWith(destination + path.sep) || destination.startsWith(candidate + path.sep)) {
    throw new Error('候选与日常应用必须位于独立目录。');
  }
  const previous = await fs.lstat(destination).catch(error => { if (error.code !== 'ENOENT') throw error; return null; });
  if (previous?.isSymbolicLink() || (previous && !previous.isDirectory())) throw new Error('应用安装位置必须是独立的应用目录。');
  const metadata = productionInfo(candidate);
  if (previous) productionInfo(destination);
  if (local) {
    const signing = spawnSync('/usr/bin/codesign', ['--display', '--verbose=4', candidate], { encoding: 'utf8' });
    if (signing.status !== 0 || !/^Signature=adhoc$/m.test(signing.stderr)) throw new Error('本地安装选项只接受已校验的本地签名候选。');
    if (metadata.NSAccentColorName !== 'AccentColor' || !/^[a-f0-9]{40}$/.test(metadata.BlueFatFishSourceCommit ?? '') || metadata.BlueFatFishSourceDirty !== false || !Number.isFinite(Date.parse(metadata.BlueFatFishBuildDate ?? ''))) {
      throw new Error('正式候选缺少强调色、干净源码版本或构建时间，未安装。');
    }
  }
  // Extract public certificates only; verification never requests a private key.
  const signatures = local ? null : await fs.mkdtemp(path.join(path.dirname(candidate), 'signature-'));
  async function certificate(application, name) {
    const prefix = path.join(signatures, name + '-');
    run('/usr/bin/codesign', ['--display', '--extract-certificates=' + prefix, application]);
    const bytes = await fs.readFile(prefix + '0').catch(error => {
      if (error.code !== 'ENOENT') throw error;
      throw new Error('正式候选必须使用原证书签名，不能使用验收签名替换。');
    });
    return createHash('sha256').update(bytes).digest('hex');
  }
  const certificateSHA256 = local ? null : await certificate(candidate, 'candidate');
  if (previous && !local) {
    if (certificateSHA256 !== await certificate(destination, 'previous')) throw new Error('签名证书与现有日常应用不同，未替换应用。');
    const requirement = run('/usr/bin/codesign', ['--display', '-r-', destination]).match(/^designated => (.+)$/m)?.[1];
    if (!requirement) throw new Error('无法核对原应用的签名身份，未替换应用。');
    run('/usr/bin/codesign', ['--verify', '--strict', '-R=' + requirement, candidate]);
  }
  assertUnused(candidate);
  if (previous) assertUnused(destination);
  const backup = previous ? path.join(await fs.mkdtemp(path.join(path.dirname(candidate), 'previous-')), path.basename(destination)) : null;
  if (backup) await fs.rename(destination, backup);
  try {
    await fs.rename(candidate, destination);
  } catch (error) {
    if (backup) {
      try { await fs.rename(backup, destination); }
      catch (recovery) { throw new AggregateError([error, recovery], `安装失败，旧版仍保留在 ${backup}；自动恢复未完成。`); }
    }
    throw error;
  }
  return { application: destination, backup, certificateSHA256, signing: local ? 'local' : 'certificate', sourceCommit: metadata.BlueFatFishSourceCommit };
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const args = process.argv.slice(2), local = args[0] === '--local';
  if (args.length !== (local ? 2 : 1)) throw new Error('请指定正式候选应用路径；仅在用户允许本地签名更新时传入 --local。');
  console.log(JSON.stringify(await installNativeBuild(path.resolve(args[local ? 1 : 0]), dailyApplication, { local }), null, 2));
}

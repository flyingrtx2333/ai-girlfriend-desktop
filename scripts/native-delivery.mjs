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
}
function assertUnused(application) {
  const result = spawnSync('/usr/sbin/lsof', ['-t', path.join(application, 'Contents/MacOS/BlueFatFish')], { encoding: 'utf8' });
  if (result.error) throw result.error;
  if (![0, 1].includes(result.status) || result.stderr.trim()) throw new Error('无法确认应用是否正在使用，未替换应用。');
  if (result.stdout.trim()) throw new Error('应用文件仍在使用，请正常退出应用后再安装；候选已保留。');
}

export async function installNativeBuild(candidatePath, destinationPath = dailyApplication) {
  const candidate = await fs.realpath(candidatePath);
  const destination = path.join(await fs.realpath(path.dirname(destinationPath)), path.basename(destinationPath));
  if (candidate === destination || candidate.startsWith(destination + path.sep) || destination.startsWith(candidate + path.sep)) {
    throw new Error('候选与日常应用必须位于独立目录。');
  }
  const previous = await fs.lstat(destination).catch(error => { if (error.code !== 'ENOENT') throw error; return null; });
  if (previous?.isSymbolicLink() || (previous && !previous.isDirectory())) throw new Error('应用安装位置必须是独立的应用目录。');
  productionInfo(candidate);
  if (previous) productionInfo(destination);
  // Extract public certificates only; verification never requests a private key.
  const signatures = await fs.mkdtemp(path.join(path.dirname(candidate), 'signature-'));
  async function certificate(application, name) {
    const prefix = path.join(signatures, name + '-');
    run('/usr/bin/codesign', ['--display', '--extract-certificates=' + prefix, application]);
    const bytes = await fs.readFile(prefix + '0').catch(error => {
      if (error.code !== 'ENOENT') throw error;
      throw new Error('正式候选必须使用原证书签名，不能使用验收签名替换。');
    });
    return createHash('sha256').update(bytes).digest('hex');
  }
  const certificateSHA256 = await certificate(candidate, 'candidate');
  if (previous) {
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
  return { application: destination, backup, certificateSHA256 };
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  if (process.argv.length !== 3) throw new Error('请指定已签名的正式候选应用路径。');
  console.log(JSON.stringify(await installNativeBuild(path.resolve(process.argv[2])), null, 2));
}

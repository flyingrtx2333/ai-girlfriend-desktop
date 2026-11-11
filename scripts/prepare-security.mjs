import { chmod, mkdir, mkdtemp, readFile, rename, rm } from 'node:fs/promises';
import { execFile } from 'node:child_process';
import { createHash } from 'node:crypto';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';

const run = promisify(execFile);
const root = fileURLToPath(new URL('../vendor/security/', import.meta.url));
const sha256 = data => createHash('sha256').update(data).digest('hex');
const matches = (file, expected) => readFile(file).then(data => sha256(data) === expected, () => false);
const releases = [
  {
    name: 'gitleaks',
    url: 'https://github.com/gitleaks/gitleaks/releases/download/v8.30.1/gitleaks_8.30.1_darwin_arm64.tar.gz',
    archive: 'b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5',
    binary: 'ba52fb1bfabbcde42f032afad3d6e0b19dff8ed105229a16e7caa338bbc0e84f',
    format: 'tar',
  },
  {
    name: 'ast-grep',
    url: 'https://github.com/ast-grep/ast-grep/releases/download/0.51.1/app-aarch64-apple-darwin.zip',
    archive: 'a95772097b4d02bd9d45ed63b300c37041ae3c36632b3bf19250cc7c10187dc4',
    binary: '094391a222233faed3be5170b4abf7098162cc3322ce7dd6b83a1e113a6ce550',
    format: 'zip',
  },
];

export async function prepareSecurity() {
  const cache = path.join(root, '.cache');
  const bin = path.join(root, 'bin');
  await mkdir(cache, { recursive: true });
  await mkdir(bin, { recursive: true });
  const results = await Promise.allSettled(releases.map(async item => {
    const target = path.join(bin, item.name);
    if (await matches(target, item.binary)) {
      await chmod(target, 0o755);
      return target;
    }
    const temporary = await mkdtemp(path.join(cache, item.name + '-'));
    try {
      const archive = path.join(cache, new URL(item.url).pathname.split('/').at(-1));
      if (!await matches(archive, item.archive)) {
        const download = path.join(temporary, 'archive');
        await run('/usr/bin/curl', ['-fLsS', '--connect-timeout', '15', '--max-time', '180', '--retry', '1', item.url, '-o', download]);
        if (!await matches(download, item.archive)) throw new Error(`${item.name} archive checksum mismatch`);
        await rename(download, archive);
      }
      if (item.format === 'tar') {
        await run('/usr/bin/tar', ['-xf', archive, '-C', temporary, item.name]);
      } else {
        await run('/usr/bin/unzip', ['-jo', archive, item.name, '-d', temporary]);
      }
      const extracted = path.join(temporary, item.name);
      if (!await matches(extracted, item.binary)) throw new Error(`${item.name} executable checksum mismatch`);
      await chmod(extracted, 0o755);
      await rename(extracted, target);
      return target;
    } finally {
      await rm(temporary, { recursive: true, force: true });
    }
  }));
  return results.map(result => {
    if (result.status === 'rejected') throw result.reason;
    return result.value;
  });
}

if (process.argv[1] === fileURLToPath(import.meta.url)) await prepareSecurity();

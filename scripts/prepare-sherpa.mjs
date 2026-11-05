import { readFile, writeFile, mkdir, rename } from 'node:fs/promises';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const run = promisify(execFile);
export const sherpaRoot = fileURLToPath(new URL('../vendor/sherpa-onnx/', import.meta.url));
const digest = data => createHash('sha256').update(data).digest('hex');
async function valid(file, sha256) { return readFile(file).then(data => digest(data) === sha256).catch(() => false); }
export async function prepareSherpa() {
  const manifest = JSON.parse(await readFile(path.join(sherpaRoot, 'manifest.json'), 'utf8'));
  const results = await Promise.allSettled([manifest.runtime, ...manifest.files].map(async item => {
    const file = path.join(sherpaRoot, item.file);
    if (await valid(file, item.sha256)) return;
    await mkdir(path.dirname(file), { recursive: true });
    const temporary = file + '.download';
    await run('/usr/bin/curl', ['-fLsS', '--connect-timeout', '15', '--max-time', '180', '--retry', '1', item.url, '-o', temporary]);
    if (!await valid(temporary, item.sha256)) throw new Error(`Sherpa asset checksum mismatch: ${item.file}`);
    await rename(temporary, file);
  }));
  for (const result of results) if (result.status === 'rejected') throw result.reason;
  for (const item of manifest.libraries) {
    const file = path.join(sherpaRoot, 'lib', item.file);
    if (await valid(file, item.sha256)) continue;
    const { stdout } = await run('/usr/bin/unzip', ['-p', path.join(sherpaRoot, manifest.runtime.file), `runtimes/osx-arm64/native/${item.file}`], { encoding: 'buffer', maxBuffer: 40_000_000 });
    if (digest(stdout) !== item.sha256) throw new Error(`Sherpa runtime checksum mismatch: ${item.file}`);
    await mkdir(path.dirname(file), { recursive: true }); await writeFile(file, stdout);
  }
}
if (process.argv[1] === fileURLToPath(import.meta.url)) await prepareSherpa();

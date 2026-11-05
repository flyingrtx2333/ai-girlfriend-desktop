import { spawnSync } from 'node:child_process';
import { readFile, mkdir, rm } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../', import.meta.url));
const output = root + 'evidence/edition29/native/';
await mkdir(output, { recursive: true });
await rm(output + 'settings-report.json', { force: true });
const result = spawnSync(root + 'build/蓝色大肥鱼.app/Contents/MacOS/BlueFatFish',
  ['--check', output, '--settings-check'], { encoding: 'utf8', timeout: 20000 });
if (result.error || result.status !== 0) throw result.error ?? Error(result.stderr || result.stdout);
const report = JSON.parse(await readFile(output + 'settings-report.json', 'utf8'));
console.log(JSON.stringify(report, null, 2));
process.exitCode = report.success ? 0 : 1;

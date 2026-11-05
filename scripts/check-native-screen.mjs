import { spawnSync } from 'node:child_process';
import { readFile, mkdir, rm } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../', import.meta.url));
const output = root + 'evidence/edition30/native/';
await mkdir(output, { recursive: true });
await rm(output + 'screen-report.json', { force: true });
const args = process.argv.slice(2);
const app = args.includes('--installed') ? '/Users/xjs/Applications/蓝色大肥鱼.app' : root + 'build/蓝色大肥鱼.app';
const result = spawnSync(app + '/Contents/MacOS/BlueFatFish', ['--check', output, '--screen-check', ...args], { encoding: 'utf8', timeout: 60000 });
if (result.error || result.status !== 0) throw result.error ?? Error(result.stderr || result.stdout);
const report = JSON.parse(await readFile(output + 'screen-report.json', 'utf8'));
console.log(JSON.stringify(report, null, 2));
process.exitCode = report.success ? 0 : 1;

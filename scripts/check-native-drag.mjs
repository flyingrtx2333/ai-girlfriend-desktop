import { spawnSync } from 'node:child_process';
import { readFile, mkdir, rm } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const output = path.join(root, 'evidence/edition20/native');
await mkdir(output, { recursive: true }); await rm(path.join(output, 'drag-report.json'), { force: true });
const app = path.join(root, 'build/蓝色大肥鱼.app/Contents/MacOS/BlueFatFish');
const run = spawnSync(app, ['--check', output, '--drag-check'], { stdio: 'inherit', timeout: 20000 });
if (run.error) throw run.error;
const report = JSON.parse(await readFile(path.join(output, 'drag-report.json'), 'utf8'));
console.log(JSON.stringify({ success: report.success, blocked: report.blocked, checks: report.checks,
  peakAngle: report.peakAngle, peakInertia: report.peakInertia, errors: report.errors }, null, 2));
process.exitCode = report.blocked ? 2 : report.success && run.status === 0 ? 0 : 1;

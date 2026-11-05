import { spawnSync } from 'node:child_process';
import { readFile, mkdir, rm } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';

const output = fileURLToPath(new URL('../evidence/edition26/native/', import.meta.url));
await mkdir(output, { recursive: true }); await rm(output + 'feedback-report.json', { force: true });
const binary = fileURLToPath(new URL('../build/蓝色大肥鱼.app/Contents/MacOS/BlueFatFish', import.meta.url));
const args = ['--check', output, '--feedback-check'];
if (process.argv.includes('--live-tts')) args.push('--live-tts');
const run = spawnSync(binary, args, { stdio: 'inherit', timeout: 60000 });
if (run.error) throw run.error;
const report = JSON.parse(await readFile(output + 'feedback-report.json', 'utf8'));
console.log(JSON.stringify(report, null, 2));
process.exitCode = report.success && run.status === 0 ? 0 : 1;

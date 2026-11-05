import { spawnSync } from 'node:child_process';
import { readFile, mkdir, rm } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';

const output = fileURLToPath(new URL('../evidence/edition27/native/', import.meta.url));
await mkdir(output, { recursive: true }); await rm(output + 'microphone-report.json', { force: true });
const app = fileURLToPath(new URL('../build/蓝色大肥鱼.app', import.meta.url));
// LaunchServices preserves the app's existing microphone/Speech attribution.
const opened = spawnSync('/usr/bin/open', ['-n', app, '--args', '--check', output, '--mic-check'], { stdio: 'inherit' });
if (opened.status !== 0) process.exit(opened.status || 1);
let report;
for (let i = 0; i < 80; i++) {
  report = await readFile(output + 'microphone-report.json', 'utf8').then(JSON.parse).catch(() => null);
  if (report) break;
  await new Promise(resolve => setTimeout(resolve, 500));
}
if (!report) throw Error('麦克风检查未完成，请确认系统授权。');
console.log(JSON.stringify(report, null, 2)); process.exitCode = report.success ? 0 : 1;

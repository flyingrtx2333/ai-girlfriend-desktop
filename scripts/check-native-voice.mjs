import { spawnSync, spawn } from 'node:child_process';
import { readFile, mkdir, rm } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const output = path.join(root, 'evidence/edition24/native'), reportFile = path.join(output, 'voice-report.json');
await mkdir(output, { recursive: true }); await rm(reportFile, { force: true });
// Test speech only; production replies continue to use the configured MiniMax.
for (const [name, text] of [['wake-command', '小鲸小鲸，今天星期几？'], ['no-wake', '今天的天气很好，我们去公园散步吧。'], ['near-wake', '小鲸今天想吃什么？小金鱼在水里游。']]) {
  const audio = spawnSync('say', ['-v', 'Tingting', '-o', path.join(root, `evidence/edition24/${name}.aiff`), text], { stdio: 'inherit' });
  if (audio.status !== 0) process.exit(audio.status || 1);
}
// LaunchServices must own privacy attribution. Running the executable directly
// from a coding host incorrectly attributes Speech permission to that host.
const app = path.join(root, 'build/蓝色大肥鱼.app');
const opened = spawn('/usr/bin/open', ['-n', app, '--args', '--check', output, '--voice-check'], { stdio: 'inherit' });
await new Promise(resolve => opened.on('exit', resolve));
let report;
for (let i = 0; i < 180; i++) {
  report = await readFile(reportFile, 'utf8').then(JSON.parse).catch(() => null);
  if (report) break;
  await new Promise(resolve => setTimeout(resolve, 500));
}
if (!report) { console.error('语音检查未完成，请解锁 Mac 并确认系统授权后重试。'); process.exitCode = 2; }
else { console.log(JSON.stringify(report, null, 2)); process.exitCode = report.success ? 0 : 1; }

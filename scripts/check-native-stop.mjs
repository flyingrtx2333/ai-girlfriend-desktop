import { spawnSync } from 'node:child_process';
import { readFile, mkdir, rm } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../', import.meta.url)), output = root + 'evidence/edition31/native/';
await mkdir(output, { recursive: true }); await rm(output + 'stop-report.json', { force: true });
const run = (cmd, args) => { const r = spawnSync(cmd, args, { encoding: 'utf8' }); if (r.status !== 0) throw Error(r.stderr || r.stdout); };
run('/usr/bin/say', ['-v', 'Tingting', '-o', root + 'evidence/edition31/stop.aiff', '小鲸小鲸，请停止录音。']);
run('ffmpeg', ['-y', '-v', 'error', '-i', root + 'evidence/edition31/stop.aiff', '-f', 'lavfi', '-t', '6', '-i', 'anoisesrc=r=22050:a=0.035', '-filter_complex', '[0:a][1:a]concat=n=2:v=0:a=1[out]', '-map', '[out]', root + 'evidence/edition31/stop-with-noise.aiff']);
const app = process.argv.includes('--installed') ? '/Users/xjs/Applications/蓝色大肥鱼.app' : root + 'build/蓝色大肥鱼.app';
run('/usr/bin/open', ['-n', app, '--args', '--check', output, '--stop-check']);
let report;
for (let i = 0; i < 100; i++) {
  report = await readFile(output + 'stop-report.json', 'utf8').then(JSON.parse).catch(() => null);
  if (report) break;
  await new Promise(resolve => setTimeout(resolve, 500));
}
if (!report) throw Error('停止录音检查未完成，请确认 Mac 已解锁且已有麦克风与语音识别权限。');
console.log(JSON.stringify(report, null, 2)); process.exitCode = report.success ? 0 : 1;

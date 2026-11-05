import { spawnSync } from 'node:child_process';
import { readFile, writeFile, mkdir, rm } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../', import.meta.url)), output = root + 'evidence/edition28/native/';
await mkdir(output, { recursive: true }); await rm(output + 'conversation-report.json', { force: true });
const run = (cmd, args) => { const r = spawnSync(cmd, args, { encoding: 'utf8' }); if (r.status !== 0) throw Error(r.stderr || r.stdout); return r.stdout; };
run('/usr/bin/say', ['-v', 'Tingting', '-o', root + 'evidence/edition28/turn-first.aiff', '小鲸小鲸，我想问你一件事。']);
run('/usr/bin/say', ['-v', 'Tingting', '-o', root + 'evidence/edition28/turn-second.aiff', '这个周末去哪里散步比较好？']);
run('ffmpeg', ['-y', '-v', 'error', '-i', root + 'evidence/edition28/turn-first.aiff', '-f', 'lavfi', '-t', '1.8', '-i', 'anullsrc=r=22050:cl=mono', '-i', root + 'evidence/edition28/turn-second.aiff', '-filter_complex', '[0:a][1:a][2:a]concat=n=3:v=0:a=1[out]', '-map', '[out]', root + 'evidence/edition28/turn-pause.aiff']);
run('/usr/bin/open', ['-n', root + 'build/蓝色大肥鱼.app', '--args', '--check', output, '--conversation-check']);
let report;
for (let i = 0; i < 120; i++) {
  report = await readFile(output + 'conversation-report.json', 'utf8').then(JSON.parse).catch(() => null);
  if (report) break;
  await new Promise(resolve => setTimeout(resolve, 500));
}
if (!report) throw Error('原生对话检查未完成，请确认 Mac 已解锁且语音识别权限有效。');
console.log(JSON.stringify({ success: report.success, checks: report.checks, layout: report.layout, turn: report.turn, analysisSeconds: report.speech?.analysisSeconds, maxClockErrorSeconds: report.speech?.maxClockErrorSeconds, errors: report.errors }, null, 2));
const shots = report.speech?.frames ?? [];
if (shots.length) {
  const lines = shots.flatMap((frame, i) => [`file '${frame.file}'`, `duration ${Math.max(.02, (shots[i + 1]?.time ?? frame.time + .1) - frame.time)}`]);
  await writeFile(output + 'lip-frames.txt', lines.join('\n') + '\n');
  run('ffmpeg', ['-y', '-v', 'error', '-f', 'concat', '-safe', '0', '-i', output + 'lip-frames.txt', '-i', root + 'public/audio/whale-maid/companion-minimax.mp3', '-filter_complex', '[0:v]scale=680:960,format=rgba[pet];color=c=0xf3eee9:s=680x960:r=30[bg];[bg][pet]overlay=shortest=1:format=auto,format=yuv420p[v]', '-map', '[v]', '-map', '1:a', '-c:v', 'libx264', '-c:a', 'aac', '-shortest', '-movflags', '+faststart', root + 'evidence/edition28/lip-sync.mp4']);
}
process.exitCode = report.success ? 0 : 1;

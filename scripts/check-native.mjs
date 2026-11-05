import { spawn, spawnSync, execFileSync } from 'node:child_process';
import { mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const output = path.join(root, 'evidence/native-app');
const usage = path.join(root, 'build/native-usage');
const app = path.join(root, 'build/蓝色大肥鱼.app/Contents/MacOS/BlueFatFish');
await mkdir(output, { recursive: true });
await rm(path.join(output, 'phase'), { force: true });
await rm(path.join(output, 'report.json'), { force: true });
const compiled = spawnSync('xcrun', ['clang', '-O2', 'scripts/native-usage.c', '-o', usage], { cwd: root, stdio: 'inherit' });
if (compiled.status) process.exit(compiled.status);
function processes() {
  return execFileSync('ps', ['-axo', 'pid=,comm='], { encoding: 'utf8' }).trim().split('\n')
    .map(line => { const [, pid, command] = line.match(/^\s*(\d+)\s+(.+)$/); return { pid: Number(pid), command }; });
}
const initial = new Set(processes().map(p => p.pid));
const child = spawn(app, ['--check', output, '--profile'], { stdio: 'inherit' });
let finished = false; const timer = setTimeout(() => child.kill('SIGTERM'), 45_000);
const completion = new Promise(resolve => child.on('exit', code => { finished = true; resolve(code); }));
const samples = {}, names = {};
try {
  while (!finished) {
    const phase = await readFile(path.join(output, 'phase'), 'utf8').catch(() => '');
    if (['idle', 'speaking', 'hidden'].includes(phase)) {
      // This short isolated launch owns these newly created WebKit processes.
      const owned = processes().filter(p => p.pid === child.pid || (!initial.has(p.pid)
        && /\/com\.apple\.WebKit\.(WebContent|GPU|Networking)$/.test(p.command)));
      owned.forEach(p => { names[p.pid] = p.command.split('/').at(-1); });
      if (owned.length) {
        const rows = execFileSync(usage, owned.map(p => String(p.pid)), { encoding: 'utf8' }).trim().split('\n').map(JSON.parse);
        (samples[phase] ??= []).push({ time: performance.now(), rows });
      }
    }
    await new Promise(resolve => setTimeout(resolve, 500));
  }
  const status = await completion; clearTimeout(timer);
  const report = JSON.parse(await readFile(path.join(output, 'report.json'), 'utf8'));
  const modes = {};
  for (const [phase, all] of Object.entries(samples)) {
    // Skip the first second after a visibility/audio transition.
    const stable = all.filter(s => s.time - all[0].time >= 1000), first = stable[0], last = stable.at(-1);
    if (!first || !last || first === last) continue;
    const seconds = (last.time - first.time) / 1000;
    const rows = last.rows.map(p => {
      const prior = first.rows.find(r => r.pid === p.pid) ?? p;
      return { name: names[p.pid], pid: p.pid, footprintMiB: p.footprint / 1048576,
        cpuPercent: (p.cpuNanoseconds - prior.cpuNanoseconds) / 1e9 / seconds * 100,
        wakeupsPerSecond: (p.wakeups - prior.wakeups) / seconds };
    });
    modes[phase] = { seconds, processes: rows, totalFootprintMiB: rows.reduce((s, p) => s + p.footprintMiB, 0),
      totalCPUPercent: rows.reduce((s, p) => s + p.cpuPercent, 0), totalWakeupsPerSecond: rows.reduce((s, p) => s + p.wakeupsPerSecond, 0) };
  }
  const performanceReport = { machine: execFileSync('sysctl', ['-n', 'machdep.cpu.brand_string'], { encoding: 'utf8' }).trim(),
    method: 'proc_pid_rusage physical footprint, app + newly created WebKit content/GPU/network processes. CPU percent of one core; short local samples, not watts.', modes };
  await writeFile(path.join(output, 'performance.json'), JSON.stringify(performanceReport, null, 2));
  console.log(JSON.stringify({ success: report.success, checks: report.checks, modes }, null, 2));
  if (status !== 0 || !report.success) process.exitCode = 1;
} finally { clearTimeout(timer); if (!finished) child.kill('SIGTERM'); }

import { spawn, spawnSync } from 'node:child_process';
import { cp, mkdir, mkdtemp, readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import os from 'node:os';
import path from 'node:path';

const root = fileURLToPath(new URL('../', import.meta.url));
const parent = path.join(root, 'evidence/agent'); await mkdir(parent, { recursive: true });
// A freshly signed app can block in TCC before creating its profile on an
// external volume. Run with a private system-temporary profile, then archive.
const output = await mkdtemp(path.join(os.tmpdir(), 'bluefatfish-browser-'));
const archived = path.join(parent, path.basename(output).replace('bluefatfish-', ''));
const live = process.argv.includes('--live-agent');
const visual = process.argv.includes('--visual');
const server = spawn(process.execPath, [path.join(root, 'node_modules/vite/bin/vite.js'), '--host', '127.0.0.1', '--port', '4178', '--strictPort'], { cwd: root, stdio: 'ignore' });
try {
  let ready = false;
  for (let i = 0; i < 60; i++) {
    if (server.exitCode !== null) throw Error('本机 4178 端口不可用，开发预览未启动');
    ready = await fetch('http://127.0.0.1:4178').then(r => r.ok).catch(() => false);
    if (ready) break; await new Promise(resolve => setTimeout(resolve, 100));
  }
  if (!ready) throw Error('本项目实际开发预览未就绪');
  const launch = spawnSync('/usr/bin/open', ['-n', path.join(root, 'build/蓝色大肥鱼.app'), '--args', '--check', output, '--browser-check', ...(visual ? ['--browser-visual'] : []), ...(process.argv.includes('--extended') ? ['--browser-extended'] : []), ...(live ? ['--live-agent'] : [])], { encoding: 'utf8' });
  if (launch.status !== 0) throw Error(launch.stderr || '浏览器检查未启动');
  let report;
  for (let i = 0; i < (visual ? 960 : live ? 720 : 300); i++) {
    report = await readFile(path.join(output, 'browser-report.json'), 'utf8').then(JSON.parse).catch(() => null);
    if (report) break; await new Promise(resolve => setTimeout(resolve, 500));
  }
  if (!report) throw Error(`浏览器检查未完成：${output}`);
  await cp(output, archived, { recursive: true });
  const liveSummary = report.live && { success: report.live.success, checks: report.live.checks, model: report.live.model, status: report.live.status, result: report.live.result, approvalCount: report.live.approvalCount };
  const annotations = report.annotations?.map(({ expectedFromActualDOM, result, status, image }) => ({ expectedFromActualDOM, result, status, image }));
  console.log(JSON.stringify({ ...report, live: liveSummary, annotations, report: path.join(archived, 'browser-report.json') }, null, 2));
  process.exitCode = report.success ? 0 : 1;
} finally { server.kill('SIGTERM'); }

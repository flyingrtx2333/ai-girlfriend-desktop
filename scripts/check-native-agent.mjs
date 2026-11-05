import { spawnSync } from 'node:child_process';
import { mkdir, mkdtemp, readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const root = fileURLToPath(new URL('../', import.meta.url));
const parent = path.join(root, 'evidence/agent'); await mkdir(parent, { recursive: true });
const output = await mkdtemp(path.join(parent, 'core-'));
const launch = spawnSync('/usr/bin/open', ['-n', path.join(root, 'build/蓝色大肥鱼.app'), '--args', '--check', output, '--agent-check', '--live-agent'], { encoding: 'utf8' });
if (launch.status !== 0) throw Error(launch.stderr || 'Agent 检查未启动');
let report;
for (let i = 0; i < 480; i++) {
  report = await readFile(path.join(output, 'agent-report.json'), 'utf8').then(JSON.parse).catch(() => null);
  if (report) break;
  await new Promise(resolve => setTimeout(resolve, 500));
}
if (!report) throw Error(`Agent 检查未完成：${output}`);
console.log(JSON.stringify({ success: report.success, checks: report.checks, model: report.live?.model, status: report.live?.status, approvalCount: report.live?.approvalCount, result: report.live?.result, error: report.error, report: path.join(output, 'agent-report.json') }, null, 2));
process.exitCode = report.success ? 0 : 1;

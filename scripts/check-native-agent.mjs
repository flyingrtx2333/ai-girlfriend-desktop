import { spawnSync } from 'node:child_process';
import { mkdir, mkdtemp, readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const root = fileURLToPath(new URL('../', import.meta.url));
const parent = path.join(root, 'evidence/agent'); await mkdir(parent, { recursive: true });
const context = process.argv.includes('--context'), filename = context ? 'context-report.json' : 'agent-report.json';
const output = await mkdtemp(path.join(parent, context ? 'context-' : 'core-'));
const launch = spawnSync('/usr/bin/open', ['-n', path.join(root, 'build/蓝色大肥鱼.app'), '--args', '--check', output, context ? '--context-check' : '--agent-check', '--live-agent'], { encoding: 'utf8' });
if (launch.status !== 0) throw Error(launch.stderr || 'Agent 检查未启动');
let report;
for (let i = 0; i < 480; i++) {
  report = await readFile(path.join(output, filename), 'utf8').then(JSON.parse).catch(() => null);
  if (report) break;
  await new Promise(resolve => setTimeout(resolve, 500));
}
if (!report) throw Error(`Agent 检查未完成：${output}`);
console.log(JSON.stringify({ success: report.success, checks: report.checks, model: report.live?.model, status: report.live?.status, approvalCount: report.live?.approvalCount, compactions: report.live?.compactions, result: report.live?.result, error: report.error, report: path.join(output, filename) }, null, 2));
process.exitCode = report.success ? 0 : 1;

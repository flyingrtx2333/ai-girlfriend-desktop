import { spawnSync } from 'node:child_process';
import { mkdir, mkdtemp, readFile, stat } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const root = fileURLToPath(new URL('../', import.meta.url));
const parent = path.join(root, 'evidence/agent'); await mkdir(parent, { recursive: true });
const kind = process.argv.includes('--wiki-ui') ? 'wiki-ui' : process.argv.includes('--index') ? 'index' : process.argv.includes('--git') ? 'git' : process.argv.includes('--context') ? 'context' : 'agent';
const filename = kind + '-report.json';
const fixtureIndex = process.argv.indexOf('--fixtures');
if (kind === 'wiki-ui' && (fixtureIndex < 0 || !process.argv[fixtureIndex + 1])) throw Error('--wiki-ui needs --fixtures <previous index check directory>');
const output = kind === 'wiki-ui' ? path.resolve(process.argv[fixtureIndex + 1]) : await mkdtemp(path.join(parent, kind === 'agent' ? 'core-' : kind + '-'));
const started = Date.now();
const launch = spawnSync('/usr/bin/open', ['-n', path.join(root, 'build/蓝色大肥鱼.app'), '--args', '--check', output, '--' + kind + '-check', ...(kind === 'wiki-ui' ? [] : process.argv.includes('--git-ui-only') ? ['--git-ui-only'] : ['--live-agent'])], { encoding: 'utf8' });
if (launch.status !== 0) throw Error(launch.stderr || 'Agent 检查未启动');
let report;
for (let i = 0; i < (kind === 'index' ? 900 : 480); i++) {
  report = await readFile(path.join(output, filename), 'utf8').then(JSON.parse).catch(() => null);
  if (report && (await stat(path.join(output, filename))).mtimeMs < started) report = null;
  if (report) break;
  await new Promise(resolve => setTimeout(resolve, 500));
}
if (!report) throw Error(`Agent 检查未完成：${output}`);
console.log(JSON.stringify({ success: report.success, checks: report.checks, model: report.live?.model, status: report.live?.status, approvalCount: report.live?.approvalCount, compactions: report.live?.compactions, result: report.live?.result, error: report.error, report: path.join(output, filename) }, null, 2));
process.exitCode = report.success ? 0 : 1;

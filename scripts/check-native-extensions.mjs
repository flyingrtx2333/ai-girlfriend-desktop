import { spawnSync } from 'node:child_process';
import { cp, mkdir, mkdtemp, readFile, readdir, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import os from 'node:os';
import path from 'node:path';

const root = fileURLToPath(new URL('../', import.meta.url));
const output = await mkdtemp(path.join(os.tmpdir(), 'bluefatfish-extensions-'));
const workspace = path.join(output, 'workspace'), source = path.join(output, 'skill-source/asset-inventory');
await mkdir(path.join(workspace, 'assets'), { recursive: true });
await mkdir(path.join(source, 'scripts'), { recursive: true });
const actualFiles = ['public/portraits/whale-maid/character.png', 'public/portraits/whale-maid/source.json', 'src/style.css'];
for (const name of actualFiles) await cp(path.join(root, name), path.join(workspace, 'assets', path.basename(name)));
await writeFile(path.join(source, 'SKILL.md'), `---
name: asset-inventory
description: 为实际素材生成文件名、字节数与 SHA256 清单。用于素材清单和打包前校验。
---

为当前项目 assets 目录生成 manifest.json。先用 read_skill_resource 查看 scripts/inventory.py，再通过 run_command 使用任务资源副本中的现有脚本：python3 <副本目录>/scripts/inventory.py assets manifest.json。不要另写计算脚本，按现有审批执行。读取生成的 manifest.json，报告文件数、总字节数和至少一个文件的 SHA256 前十二位。只有实际文件与输出能作为完成证据。
`);
await writeFile(path.join(source, 'scripts/inventory.py'), `import hashlib, json, pathlib, sys
source = pathlib.Path(sys.argv[1]).resolve()
target = pathlib.Path(sys.argv[2]).resolve()
rows = [{'name': p.name, 'bytes': p.stat().st_size, 'sha256': hashlib.sha256(p.read_bytes()).hexdigest()} for p in sorted(source.iterdir()) if p.is_file()]
result = {'files': rows, 'file_count': len(rows), 'total_bytes': sum(row['bytes'] for row in rows)}
target.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\\n')
print(json.dumps(result, ensure_ascii=False))
`);
const zip = path.join(output, 'asset-inventory.skill');
let child = spawnSync('/usr/bin/zip', ['-q', '-r', zip, 'asset-inventory'], { cwd: path.dirname(source), encoding: 'utf8' });
if (child.status !== 0) throw Error(child.stderr || 'Skill 资源打包失败');
child = spawnSync('/usr/bin/python3', ['-c', 'import sys,zipfile\nwith zipfile.ZipFile(sys.argv[1],"w") as z:\n z.writestr("../escaped-extension.txt","must not escape")\n z.writestr("SKILL.md","---\\nname: unsafe\\n---\\ninvalid archive")', path.join(output, 'unsafe.zip')], { encoding: 'utf8' });
if (child.status !== 0) throw Error(child.stderr || 'ZIP 路径边界夹具创建失败');
const reference = [];
for (const name of await readdir(path.join(workspace, 'assets'))) {
  const data = await readFile(path.join(workspace, 'assets', name));
  reference.push({ name, bytes: data.length, sha256: createHash('sha256').update(data).digest('hex') });
}
await writeFile(path.join(output, 'independent-expected.json'), JSON.stringify({ files: reference.sort((a, b) => a.name.localeCompare(b.name)), file_count: reference.length, total_bytes: reference.reduce((sum, item) => sum + item.bytes, 0), actualSources: actualFiles }, null, 2));
const launch = spawnSync('/usr/bin/open', ['-n', path.join(root, 'build/蓝色大肥鱼.app'), '--args', '--check', output, '--extension-check', ...(process.argv.includes('--live-agent') ? ['--live-agent'] : []), ...(process.argv.includes('--hold-ui') ? ['--extension-ui-hold'] : [])], { encoding: 'utf8' });
if (launch.status !== 0) throw Error(launch.stderr || '扩展检查未启动');
let report;
for (let i = 0; i < 720; i++) {
  report = await readFile(path.join(output, 'extension-report.json'), 'utf8').then(JSON.parse).catch(() => null);
  if (report) break; await new Promise(resolve => setTimeout(resolve, 500));
}
if (!report) throw Error(`扩展检查未完成：${output}`);
if (report.live) {
  const actual = await readFile(path.join(workspace, 'manifest.json'), 'utf8').then(JSON.parse).catch(() => null);
  const expected = JSON.parse(await readFile(path.join(output, 'independent-expected.json'), 'utf8'));
  report.independentNodeVerification = actual && actual.file_count === expected.file_count && actual.total_bytes === expected.total_bytes && actual.files.length === expected.files.length && actual.files.every(row => expected.files.some(other => other.name === row.name && other.bytes === row.bytes && other.sha256 === row.sha256));
  report.success &&= report.independentNodeVerification === true;
  await writeFile(path.join(output, 'extension-report.json'), JSON.stringify(report, null, 2));
}
const parent = path.join(root, 'evidence/agent'); await mkdir(parent, { recursive: true });
const archived = path.join(parent, path.basename(output).replace('bluefatfish-', '')); await cp(output, archived, { recursive: true });
const live = report.live && { ...report.live, events: undefined };
console.log(JSON.stringify({ ...report, live, report: path.join(archived, 'extension-report.json'), ...(process.argv.includes('--hold-ui') ? { uiHoldDirectory: output } : {}) }, null, 2));
process.exitCode = report.success ? 0 : 1;

import { spawnSync } from 'node:child_process';
import { cp, mkdir, mkdtemp, readFile, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import os from 'node:os';
import path from 'node:path';

const root = fileURLToPath(new URL('../', import.meta.url));
const output = await mkdtemp(path.join(os.tmpdir(), 'bluefatfish-custom-agents-'));
const workspace = path.join(output, 'workspace');
await mkdir(workspace, { recursive: true });
await mkdir(path.join(output, 'shared-home'), { recursive: true });
for (const name of ['source.json', 'character.png']) await cp(path.join(root, 'public/portraits/whale-maid', name), path.join(workspace, name));
const hash = data => createHash('sha256').update(data).digest('hex');
const sourceBytes = await readFile(path.join(workspace, 'source.json')), source = JSON.parse(sourceBytes), image = await readFile(path.join(workspace, 'character.png'));
const expected = { edition: source.edition, width: source.width, height: source.height, imageBytes: image.length, sha256: hash(image) };
const nested = process.argv.includes('--nested-only'), live = process.argv.includes('--live-agent') || nested, hold = process.argv.includes('--hold-ui');
const reportPath = path.join(output, 'custom-agent-report.json');
const sleep = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));
console.log(JSON.stringify({ output, live, hold }));
try {
  const launch = spawnSync('/usr/bin/open', ['-n', path.join(root, 'build/蓝色大肥鱼.app'), '--args', '--check', output, '--custom-agent-check', ...(live ? ['--live-agent'] : []), ...(nested ? ['--nested-only'] : []), ...(hold ? ['--custom-agent-ui-hold'] : [])], { encoding: 'utf8' });
  if (launch.status !== 0) throw new Error(launch.stderr || 'Application did not launch');
  let report;
  const deadline = Date.now() + (live ? 450_000 : 45_000);
  while (Date.now() < deadline) {
    try { report = JSON.parse(await readFile(reportPath, 'utf8')); break; } catch (error) { if (error.code !== 'ENOENT' && !(error instanceof SyntaxError)) throw error; }
    await sleep(250);
  }
  if (!report) throw new Error(`No terminal report: ${output}`);
  if (!report.success) throw new Error(JSON.stringify(report));
  if (live) {
    if (nested) {
      if (report.leafIDs?.length !== 2) throw new Error('Both actual leaf records are required');
      for (const id of report.leafIDs) {
        const task = JSON.parse(await readFile(path.join(output, 'profile/agent', `${id}.json`), 'utf8'));
        const final = task.messages.filter(message => message.role === 'assistant' && message.content).at(-1)?.content;
        const actual = JSON.parse(final?.match(/\{[^{}]*\}/)?.[0] ?? 'null');
        if (!actual || Object.keys(actual).length !== 3 || ['edition', 'width', 'height'].some(key => actual[key] !== expected[key])) throw new Error('Nested leaf result does not match actual source');
      }
    } else {
      const actual = JSON.parse(await readFile(path.join(workspace, 'delegated-report.json'), 'utf8'));
      if (Object.keys(actual).length !== Object.keys(expected).length || Object.entries(expected).some(([key, value]) => actual[key] !== value)) throw new Error('Independent actual-file verification failed');
    }
    if (hash(await readFile(path.join(workspace, 'source.json'))) !== hash(sourceBytes) || hash(await readFile(path.join(workspace, 'character.png'))) !== hash(image)) throw new Error('Public inputs changed');
    report.independentNodeVerification = true;
    await writeFile(reportPath, JSON.stringify(report, null, 2) + '\n');
  }
  if (hold) {
    console.log(JSON.stringify({ uiReady: true, output, checks: Object.keys(report.checks).length }));
    const end = Date.now() + 620_000;
    while (Date.now() < end) {
      try { await readFile(path.join(output, 'finish-ui')); break; } catch {}
      await sleep(500);
    }
  }
  await writeFile(path.join(output, 'finish-ui'), 'finished\n');
  const archive = path.join(root, 'evidence/agent', path.basename(output).replace('bluefatfish-', ''));
  await mkdir(path.dirname(archive), { recursive: true });
  await cp(output, archive, { recursive: true });
  console.log(JSON.stringify({ success: true, output, archive, checks: Object.keys(report.checks).length, independentNodeVerification: !!report.independentNodeVerification }));
} catch (error) {
  await writeFile(path.join(output, 'finish-ui'), 'failed\n');
  try {
    const report = JSON.parse(await readFile(reportPath, 'utf8'));
    report.nativeChecksPassed = report.success;
    report.success = false; report.independentNodeVerification = false; report.acceptanceError = String(error.message ?? error);
    await writeFile(reportPath, JSON.stringify(report, null, 2) + '\n');
    const archive = path.join(root, 'evidence/agent', path.basename(output).replace('bluefatfish-', ''));
    await cp(output, archive, { recursive: true });
  } catch {}
  throw error;
}

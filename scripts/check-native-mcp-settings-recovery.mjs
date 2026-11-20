import { spawn } from 'node:child_process';
import { createHash, randomUUID } from 'node:crypto';
import { mkdir, mkdtemp, readFile, stat, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { verifyNativeCandidate } from './native-signing.mjs';

const root = fileURLToPath(new URL('../', import.meta.url)), app = process.env.BLUEFATFISH_APP;
if (!app || process.argv.length !== 2 || verifyNativeCandidate(app).kind !== 'isolated-local') {
  throw Error('请用 BLUEFATFISH_APP 指定独立验收应用。');
}
const json = async file => JSON.parse(await readFile(file, 'utf8'));
const hash = data => createHash('sha256').update(data).digest('hex');
const output = await mkdtemp(path.join(root, 'evidence/agent/mcp-settings-check-'));
for (const directory of ['tmp', 'shared-home']) await mkdir(path.join(output, directory));
const binary = path.resolve(app, 'Contents/MacOS/BlueFatFish'), binaryHash = hash(await readFile(binary));
const snapshot = {}, allResults = [];
let fixture, originalRegistry;
for (const stage of ['seed', 'changed', 'reopen']) {
  if (stage === 'changed') {
    const servers = JSON.parse(originalRegistry), server = servers.find(item => item.id === fixture.http);
    if (!server) throw Error('本机样例缺少源连接器。');
    server.name = 'Public OAuth External'; server.revision = randomUUID();
    await writeFile(fixture.registry, JSON.stringify(servers, null, 2));
  } else if (stage === 'reopen') await writeFile(fixture.registry, originalRegistry);

  const args = ['--check', output, '--settings-mcp-recovery-check', '--recovery-stage', stage];
  const child = spawn(binary, args, { cwd: root, env: { ...process.env, TMPDIR: path.join(output, 'tmp') + '/' }, stdio: ['ignore', 'pipe', 'pipe'] });
  let log = '';
  child.stdout.on('data', data => { log += data; });
  child.stderr.on('data', data => { log += data; });
  console.log(JSON.stringify({ output, stage, appPID: child.pid }));
  const timeout = setTimeout(() => child.kill('SIGTERM'), 60_000);
  const exit = await new Promise((resolve, reject) => { child.once('error', reject); child.once('close', resolve); }).finally(() => clearTimeout(timeout));
  await writeFile(path.join(output, stage + '-launch.log'), log);
  const report = await json(path.join(output, stage + '-mcp-settings-report.json'));
  const result = { stage, exit, nativeChecks: Object.keys(report.checks).length, failed: Object.keys(report.checks).filter(key => !report.checks[key]), error: report.error,
    sameBinary: report.appPID === child.pid && hash(await readFile(binary)) === binaryHash, modelRequests: report.modelRequests };
  if (stage === 'seed') {
    fixture = await json(path.join(output, 'mcp-settings-fixture.json'));
    if (!fixture.registry.startsWith(output + path.sep)) throw Error('本机样例配置路径无效。');
    originalRegistry = await readFile(fixture.registry);
  }
  const independent = {};
  for (const [role, id] of Object.entries(fixture.windows)) {
    const filename = path.join(output, 'profile/workspace-recovery', id, 'layout.json');
    const saved = (await json(filename)).settings;
    if (!saved) throw Error('设置记录缺失：' + role);
    independent[role + 'BindingAndPermissions'] = saved.active && saved.root === 'mcp' && saved.context.taskID === fixture.tasks[role] &&
      !saved.context.workspace && ((await stat(filename)).mode & 0o777) === 0o600;
    const pages = saved.pages.map(page => JSON.parse(Buffer.from(page.state, 'base64')));
    independent[role + 'CredentialsNotInJournal'] = !JSON.stringify(pages).includes('PUBLIC_FIXTURE_UNMASKED_045');
    if (stage === 'seed') snapshot[role] = saved;
    if (role === 'form' && stage !== 'reopen') {
      const detail = pages.at(-1);
      independent.formDraftValueAndSelectionExact = detail.server === fixture.http && detail.form.fields.timeout === '60000_PUBLIC_INVALID' &&
        detail.viewport.focus === 'timeout' && detail.viewport.fields.timeout.selection?.location === 6 && detail.viewport.fields.timeout.selection?.length === 6;
      if (stage === 'changed') independent.changedSourceLeavesPreviousJournalExact = JSON.stringify(saved) === JSON.stringify(snapshot.form);
    }
    if (role === 'json' && stage === 'seed') independent.jsonWholeDraftRetained = pages.at(-1).text.includes('PUBLIC_RECOVERY_LINE_81 中文') && pages.at(-1).text.includes('"timeoutSeconds": 0');
    if (role === 'catalog') independent.filteredCatalogPosition = pages[0].query === 'Public Catalog' && Math.abs(pages[0].y - 600) < 4;
    if (role === 'tools') independent.toolPageSelectionRetained = pages.at(-1).toolTab === true;
  }
  const servers = await json(fixture.registry);
  if (stage === 'reopen') {
    const changedIDs = new Set([fixture.http, fixture.program]);
    independent.correctedDraftsWriteOnlyOriginalServers = JSON.stringify(servers.filter(item => !changedIDs.has(item.id))) ===
      JSON.stringify(JSON.parse(originalRegistry).filter(item => !changedIDs.has(item.id))) &&
      servers.find(item => item.id === fixture.http)?.timeoutSeconds === 72 && servers.find(item => item.id === fixture.program)?.timeoutSeconds === 85;
  }
  result.independent = independent;
  result.success = exit === 0 && report.success && result.sameBinary && report.modelRequests === 0 && Object.values(independent).every(Boolean);
  await writeFile(path.join(output, stage + '-result.json'), JSON.stringify(result, null, 2) + '\n');
  allResults.push(result); console.log(JSON.stringify(result));
  if (!result.success) break;
}
const success = allResults.length === 3 && allResults.every(result => result.success);
await writeFile(path.join(output, 'results.json'), JSON.stringify({ application: app, binaryHash, success, stages: allResults }, null, 2) + '\n');
console.log(JSON.stringify({ output, success, stages: allResults.length }));
if (!success) process.exitCode = 1;

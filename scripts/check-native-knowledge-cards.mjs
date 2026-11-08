import { spawnSync } from 'node:child_process';
import { readFile, writeFile, readdir, mkdtemp, mkdir, cp, unlink } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { isDeepStrictEqual } from 'node:util';
import { fileURLToPath } from 'node:url';
import os from 'node:os';
import path from 'node:path';

const root = fileURLToPath(new URL('../', import.meta.url)), resume = process.argv.indexOf('--resume');
const output = resume < 0 ? await mkdtemp(path.join(os.tmpdir(), 'bluefatfish-cards-')) : path.resolve(process.argv[resume + 1]);
if (!path.basename(output).startsWith('bluefatfish-cards-')) throw new Error('Use an actual cards acceptance directory');
const hash = data => createHash('sha256').update(data).digest('hex'), pause = ms => new Promise(resolve => setTimeout(resolve, ms));
const json = async name => JSON.parse(await readFile(path.join(output, name), 'utf8'));
function command(file, args, options = {}) {
  const result = spawnSync(file, args, { encoding: 'utf8', maxBuffer: 50_000_000, ...options });
  if (result.status !== 0) throw new Error(result.stderr?.toString() || result.stdout?.toString() || file); return result.stdout;
}
function live(pid) { try { process.kill(pid, 0); return true; } catch (error) { if (error.code === 'ESRCH') return false; throw error; } }
async function snapshot() {
  const base = path.join(os.homedir(), 'Library/Application Support/BlueFatFish');
  const names = ['settings.json', 'history.json', 'agent/index.json', 'organization.json', 'automations/definitions.json', 'models/catalog.json', 'extensions/mcp.json', 'extensions/hooks.json', 'extensions/hook-settings.json', 'extensions/settings.json', 'extensions/agents.json', 'extensions/teams.json', 'worktrees/policy.json', 'worktrees/history.json', 'worktrees/scheduler.lock', 'computer-use/settings.json', 'imports/batch.json', 'knowledge/catalog.json', 'knowledge-cards/settings.json'];
  for (const name of await readdir(path.join(base, 'agent'))) if (/^[0-9a-f-]{36}\.json$/i.test(name)) names.push('agent/' + name);
  return Object.fromEntries(await Promise.all(names.sort().map(async name => [name, await readFile(path.join(base, name)).then(hash).catch(error => { if (error.code === 'ENOENT') return null; throw error; })])));
}
const before = resume < 0 ? await snapshot() : await json('production-before.json');
if (!isDeepStrictEqual(before, await snapshot())) throw new Error('Preserve and inspect changed daily data');
if (resume < 0) {
  await writeFile(path.join(output, 'production-before.json'), JSON.stringify(before, null, 2));
  const commit = command('/usr/bin/git', ['-C', root, 'rev-parse', 'HEAD']).trim(), source = path.join(output, 'source-snapshot');
  await mkdir(source);
  const archive = command('/usr/bin/git', ['-C', root, 'archive', commit, 'native', 'docs', 'package.json', 'package-lock.json'], { encoding: null });
  command('/usr/bin/tar', ['-xf', '-', '-C', source], { input: archive });
  command('/usr/bin/git', ['-C', source, 'init', '-b', 'main']); command('/usr/bin/git', ['-C', source, 'add', '.']);
  command('/usr/bin/git', ['-C', source, '-c', 'core.hooksPath=/dev/null', '-c', 'commit.gpgsign=false', '-c', 'user.name=BlueFatFish Local Acceptance', '-c', 'user.email=local-validation@example.invalid', 'commit', '-m', 'Preserve actual project module snapshot']);
  const files = Object.fromEntries(await Promise.all(['native/AgentKnowledgeLibrary.swift', 'native/AgentDocument.swift', 'package.json'].map(async name => [name, hash(await readFile(path.join(root, name)))])));
  await writeFile(path.join(output, 'cards-source-origin.json'), JSON.stringify({ repository: root, commit, source, scope: ['native', 'docs', 'package.json', 'package-lock.json'], files }, null, 2));
}
console.log(JSON.stringify({ output }));
if (process.argv.includes('--prepare-only')) process.exit(0);
const app = path.join(root, 'build/蓝色大肥鱼.app'), binaryHash = hash(await readFile(path.join(app, 'Contents/MacOS/BlueFatFish'))), origin = await json('cards-source-origin.json');
async function waitJSON(name, seconds, pid) {
  const deadline = Date.now() + seconds * 1000;
  while (Date.now() < deadline) {
    const value = await json(name).catch(error => { if (error.code === 'ENOENT' || error instanceof SyntaxError) return null; throw error; });
    if (value) return value;
    if (pid && !live(pid)) { const report = await json('cards-report.json').catch(() => null); throw new Error(report?.error || 'Actual application exited before ' + name); }
    await pause(200);
  }
  throw new Error('Observation deadline; preserve the original cards process and tasks');
}
let report;
try {
  const previous = await json('cards-process.json').catch(() => null);
  if (previous && live(previous.appPID)) throw new Error('Existing cards acceptance is still running; preserve it');
  for (const name of ['cards-process.json', 'cards-ui-ready.json', 'cards-report.json', 'finish-cards-ui']) await unlink(path.join(output, name)).catch(error => { if (error.code !== 'ENOENT') throw error; });
  command('/usr/bin/open', ['-n', app, '--args', '--check', output, '--knowledge-cards-check', '--live-agent', '--cards-source', origin.source]);
  const owner = await waitJSON('cards-process.json', 30), ready = await waitJSON('cards-ui-ready.json', 240, owner.appPID);
  if (ready.binaryHash !== binaryHash) throw new Error('Actual UI candidate mismatch');
  console.log(JSON.stringify({ phase: 'actual-ui-ready', outputDirectory: output, ...ready }));
  report = await waitJSON('cards-report.json', 7200, owner.appPID);
  for (let i = 0; i < 100 && live(owner.appPID); i++) await pause(100);
  if (live(owner.appPID)) throw new Error('Original application is still running');
  if (!report.success) throw new Error(report.error || 'Cards acceptance failed');
  const agent = path.join(output, 'profile/agent'), files = (await readdir(agent)).filter(name => /^[0-9a-f-]{36}\.json$/i.test(name));
  const tasks = await Promise.all(files.map(async name => JSON.parse(await readFile(path.join(agent, name), 'utf8'))));
  const generated = tasks.filter(task => task.kind === 'knowledge-cards'), versionsRoot = path.join(agent, 'projects', hash(Buffer.from(origin.source)), 'knowledge-cards/versions');
  const versions = await Promise.all((await readdir(versionsRoot)).filter(name => name.endsWith('.json')).map(async name => JSON.parse(await readFile(path.join(versionsRoot, name), 'utf8'))));
  const published = versions.filter(book => book.taskID && generated.some(task => task.id === book.taskID && task.status === 'completed'));
  let referencesValid = published.length > 0;
  for (const book of published) for (const card of book.cards) for (const ref of card.sources) {
    const actual = await readFile(path.join(origin.source, ref.path));
    const original = ref.path === 'native/AgentKnowledgeLibrary.swift' ? Buffer.from(actual.toString().replace('160_000_000', '150_000_000')) : actual;
    const candidates = [actual, original];
    referencesValid &&= candidates.some(data => hash(data) === ref.sha256 && ref.line > 0 && ref.endLine >= ref.line && ref.endLine <= data.toString().split('\n').length);
  }
  const allReceipts = tasks.flatMap(task => task.modelReceipts ?? []);
  const accounted = allReceipts.length > 0 && tasks.every(task => (task.modelReceipts ?? []).every(r => Number.isInteger(r.inputTokens) && Number.isInteger(r.outputTokens)) && (task.modelReceipts ?? []).reduce((n, r) => n + r.inputTokens, 0) === task.inputTokens && (task.modelReceipts ?? []).reduce((n, r) => n + r.outputTokens, 0) === task.outputTokens);
  const unchanged = await Promise.all(Object.entries(origin.files).map(async ([name, sha]) => hash(await readFile(path.join(origin.repository, name))) === sha));
  report.independent = {
    productionProfileUnchanged: isDeepStrictEqual(before, await snapshot()),
    originalBusinessSourceFilesUnchanged: unchanged.every(Boolean),
    publishedCardsReferenceActualSourceLinesAndHashes: referencesValid,
    generatedThreeCategories: published.every(book => ['architecture', 'spec', 'tech_stack'].every(kind => book.cards.some(card => card.kind === kind))),
    realChineseGenerationAndAutomaticUpdate: published.filter(book => book.language === 'zh').length >= 2 && generated.some(task => task.knowledgeJob?.automatic && task.status === 'completed'),
    realEnglishGeneration: published.some(book => book.language === 'en' && book.cards.every(card => (card.body.match(/[a-z]+/gi) ?? []).length >= 12 && (card.body.match(/[\u4e00-\u9fff]/g) ?? []).length < 20)),
    actualBeforeAndAfterLimit: published.some(book => book.cards.some(card => card.kind === 'spec' && /150\s*MB|150[_,]?000[_,]?000/i.test(card.body))) && published.some(book => book.cards.some(card => card.kind === 'spec' && /160\s*MB|160[_,]?000[_,]?000/i.test(card.body))),
    realKnowledgeEditTool: tasks.some(task => task.kind !== 'knowledge-cards' && task.messages.some(message => message.role === 'user' && message.content.startsWith('/knowledge-edit ')) && task.events.some(event => event.title === 'edit_project_knowledge' && event.status === 'completed') && (task.modelReceipts?.length ?? 0) > 0),
    actualReceiptsAccounted: accounted,
    requestBoundsPreserved: allReceipts.length <= 90 && generated.every(task => (task.modelReceipts?.length ?? 0) <= 30),
    originalContextAndReplyBudgets: ready.context === 8192 && ready.output === 512,
  };
  report.requests = allReceipts.length; report.source = origin; report.success &&= Object.values(report.independent).every(Boolean);
} catch (error) { report = { ...(report ?? {}), success: false, error: error.message }; }
finally {
  await writeFile(path.join(output, 'cards-driver-report.json'), JSON.stringify(report, null, 2));
  const archive = path.join(root, 'evidence/agent', path.basename(output) + '-' + new Date().toISOString().replace(/[:.]/g, '-'));
  await mkdir(path.dirname(archive), { recursive: true }); await cp(output, archive, { recursive: true });
  console.log(JSON.stringify({ success: report?.success, output, archive, error: report?.error }));
}
if (!report?.success) process.exitCode = 1;

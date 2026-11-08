import { spawnSync } from 'node:child_process';
import { readFile, writeFile, mkdir, mkdtemp, readdir, realpath } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { isDeepStrictEqual } from 'node:util';
import { fileURLToPath } from 'node:url';
import os from 'node:os';
import path from 'node:path';

const root = fileURLToPath(new URL('../', import.meta.url)), hash = bytes => createHash('sha256').update(bytes).digest('hex');
const option = name => { const i = process.argv.indexOf(name); return i < 0 ? undefined : process.argv[i + 1]; };
const app = option('--candidate-app'); if (!app) throw Error('Use --candidate-app <signed application>');
function command(file, args) { const result = spawnSync(file, args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }); if (result.status !== 0) throw Error(result.stderr || file); return result.stdout; }
const candidate = path.resolve(app); command('/usr/bin/codesign', ['--verify', '--deep', '--strict', candidate]);
const binary = path.join(candidate, 'Contents/MacOS/BlueFatFish'), binaryHash = hash(await readFile(binary));
if (process.argv.includes('--prepare-only')) {
  const output = await mkdtemp(path.join(os.tmpdir(), 'bluefatfish-wiki-live-')), workspace = path.join(output, 'workspace'), profile = path.join(output, 'profile');
  const daily = path.join(os.homedir(), 'Library/Application Support/BlueFatFish'), settings = await readFile(path.join(daily, 'settings.json')), preferences = JSON.parse(settings);
  if (preferences.contextTokens !== 8192 || preferences.replyTokens !== 512) throw Error('Preserve the existing 8192/512 configuration');
  const sourceHashes = {};
  for (const name of ['README.md', 'docs/DEVELOPMENT.md', 'native/AgentWiki.swift', 'package.json']) { const bytes = await readFile(path.join(root, name)); sourceHashes[name] = hash(bytes); await mkdir(path.dirname(path.join(workspace, name)), { recursive: true }); await writeFile(path.join(workspace, name), bytes); }
  command('/usr/bin/git', ['init', '--quiet', '--initial-branch=wiki-live', workspace]); command('/usr/bin/git', ['-C', workspace, 'add', '.']);
  command('/usr/bin/git', ['-C', workspace, '-c', 'user.name=Wiki Acceptance', '-c', 'user.email=wiki-acceptance@localhost', 'commit', '--quiet', '-m', 'Actual repository snapshot for real Wiki generation']);
  await mkdir(path.join(workspace, '.bluefatfish/repowiki'), { recursive: true });
  await writeFile(path.join(workspace, '.bluefatfish/repowiki/wiki_plan.yaml'), 'version: 1\nrepowiki:\n  template: architecture\n  notes:\n    - text: Keep each page concise and cite actual source lines.\n  documents:\n    - {title: Overview, goal: Explain the actual application and entry points, hints: [README.md]}\n    - {title: Development, goal: Explain the actual native build and validation flow, parent: Overview, hints: [docs/DEVELOPMENT.md]}\n');
  await mkdir(profile, { recursive: true }); await writeFile(path.join(profile, 'settings.json'), settings, { mode: 0o600 });
  const names = ['settings.json', 'history.json', 'agent/index.json', 'organization.json', 'automations/definitions.json', 'models/catalog.json', 'extensions/mcp.json', 'extensions/hooks.json', 'extensions/hook-settings.json', 'extensions/settings.json', 'extensions/agents.json', 'extensions/teams.json', 'worktrees/policy.json', 'worktrees/history.json', 'worktrees/scheduler.lock', 'computer-use/settings.json', 'imports/batch.json', 'knowledge/catalog.json', 'knowledge-cards/settings.json'];
  for (const name of await readdir(path.join(daily, 'agent'))) if (/^[0-9a-f-]{36}\.json$/i.test(name)) names.push('agent/' + name);
  const protectedFiles = Object.fromEntries(await Promise.all(names.map(async name => [name, await readFile(path.join(daily, name)).then(hash).catch(e => { if (e.code === 'ENOENT') return null; throw e; })])));
  const configurationHash = hash(await readFile(path.join(workspace, '.bluefatfish/repowiki/wiki_plan.yaml')));
  await writeFile(path.join(output, 'wiki-live-preparation.json'), JSON.stringify({ source: root, sourceHashes, configurationHash, app: candidate, binaryHash, model: preferences.model, context: 8192, output: 512, protectedFiles, modelsCalled: false, authorization: 'Pending a separate explicit Wiki request allowance; no authorization file created' }, null, 2));
  console.log(JSON.stringify({ output, binaryHash, model: preferences.model, context: 8192, reply: 512, modelsCalled: false }));
} else {
  const output = option('--resume'), language = option('--language');
  if (!output || !['zh', 'en'].includes(language) || !path.basename(output).startsWith('bluefatfish-wiki-live-')) throw Error('Use --resume <prepared directory> --language zh|en after explicit user authorization');
  await readFile(path.join(output, 'wiki-budget-authorization.json'));
  const result = spawnSync(binary, ['--wiki-live-check', '--live-agent', '--check', path.resolve(output), '--wiki-language', language, ...(process.argv.includes('--resume-repaired') ? ['--wiki-resume-repaired'] : [])], { stdio: 'inherit' });
  const report = JSON.parse(await readFile(path.join(output, 'wiki-live-' + language + '-report.json'), 'utf8')), preparation = JSON.parse(await readFile(path.join(output, 'wiki-live-preparation.json'), 'utf8'));
  const after = Object.fromEntries(await Promise.all(Object.keys(preparation.protectedFiles).map(async name => [name, await readFile(path.join(os.homedir(), 'Library/Application Support/BlueFatFish', name)).then(hash).catch(e => { if (e.code === 'ENOENT') return null; throw e; })])));
  const independent = { productionProfileUnchanged: isDeepStrictEqual(preparation.protectedFiles, after), actualCandidate: report.binaryHash === binaryHash, budgetPreserved: report.context === 8192 && report.output === 512, requestBoundsPreserved: Number.isInteger(report.requests) && report.requests <= report.requestLimit };
  for (const [name, expected] of Object.entries(preparation.sourceHashes)) independent['sourceUnchanged:' + name] = hash(await readFile(path.join(output, 'workspace', name))) === expected;
  if (report.taskID) {
    const task = JSON.parse(await readFile(path.join(output, 'profile/agent', report.taskID + '.json'), 'utf8'));
    independent.configurationFrozen = task.wikiJob?.configurationHash === preparation.configurationHash && task.wikiJob?.language === language;
    const pageRoot = path.join(await realpath(path.join(output, 'workspace')), task.wikiJob.root) + '/';
    independent.sourceWritesAbsent = (await Promise.all((task.changes ?? []).map(change => realpath(change.path).then(value => value.startsWith(pageRoot)).catch(() => false)))).every(Boolean);
    independent.actualModelReceiptsPresent = (task.modelReceipts?.length ?? 0) > 0 && task.modelReceipts.length <= report.requests;
    if (report.success) {
      const manifest = JSON.parse(await readFile(path.join(output, 'wiki-live-' + language + '-manifest.json'), 'utf8'));
      independent.manifestHasExactLanguageTaskAndBranch = manifest.language === language && manifest.taskID === task.id && manifest.branch === task.wikiJob.branch;
      independent.publishedPageBytesMatch = (await Promise.all(Object.entries(manifest.pages).map(async ([name, expected]) => hash(await readFile(path.join(output, 'workspace', name))) === expected))).every(Boolean);
    }
  }
  report.independent = independent; report.success &&= Object.values(independent).every(Boolean);
  await writeFile(path.join(output, 'wiki-live-' + language + '-' + report.attemptID + '-driver-report.json'), JSON.stringify(report, null, 2));
  await writeFile(path.join(output, 'wiki-live-' + language + '-driver-report.json'), JSON.stringify(report, null, 2));
  console.log(JSON.stringify({ success: report.success, output, independent })); process.exitCode = result.status === 0 && report.success ? 0 : 1;
}

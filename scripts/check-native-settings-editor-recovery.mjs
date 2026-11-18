import { spawn, spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { createWriteStream } from 'node:fs';
import { finished } from 'node:stream/promises';
import { mkdir, mkdtemp, readFile, writeFile, stat, realpath, readdir, lstat, readlink } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import os from 'node:os';
import path from 'node:path';
import { verifyNativeCandidate } from './native-signing.mjs';

const root = fileURLToPath(new URL('../', import.meta.url)), app = process.env.BLUEFATFISH_APP;
const daily = process.argv[2] === '--daily';
if (!app || process.argv.length !== (daily ? 3 : 2)) throw Error('请明确指定应用；仅用 --daily 检查已安装的日常应用。设置恢复检查不调用模型。');
const plutil = spawnSync('/usr/bin/plutil', ['-convert', 'json', '-o', '-', path.join(app, 'Contents/Info.plist')], { encoding: 'utf8' });
if (plutil.status !== 0) throw Error('无法核对应用元数据。');
const metadata = JSON.parse(plutil.stdout);
if (daily) {
  if (await realpath(app) !== await realpath(path.join(root, 'build/蓝色大肥鱼.app')) || metadata.BlueFatFishAcceptanceOnly || metadata.CFBundleIdentifier !== 'com.xjs.bluefatfish' || metadata.CFBundleExecutable !== 'BlueFatFish' || metadata.BlueFatFishSourceDirty !== false || !/^[a-f0-9]{40}$/.test(metadata.BlueFatFishSourceCommit ?? '')) throw Error('--daily 仅接受当前项目已安装的日常应用。');
  if (spawnSync('/usr/bin/codesign', ['--verify', '--deep', '--strict', app]).status !== 0) throw Error('日常应用签名校验失败。');
  const running = spawnSync('/usr/bin/pgrep', ['-x', 'BlueFatFish'], { encoding: 'utf8' });
  if (running.error || ![0, 1].includes(running.status)) throw Error('无法核对日常进程。');
  for (const pid of running.stdout.split(/\s+/).filter(Boolean)) {
    const process = spawnSync('/bin/ps', ['-p', pid, '-o', 'comm='], { encoding: 'utf8' });
    if (process.status === 0 && process.stdout.trim() === path.join(await realpath(app), 'Contents/MacOS/BlueFatFish')) throw Error('请先正常退出日常应用；测试只使用独立公开资料。');
  }
} else {
  verifyNativeCandidate(app);
  if (!metadata.BlueFatFishAcceptanceOnly) throw Error('请指定独立验收应用，日常应用须显式使用 --daily。');
}
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const json = async file => JSON.parse(await readFile(file, 'utf8'));
const output = await mkdtemp(path.join(root, daily ? 'evidence/agent/settings-recovery-daily-' : 'evidence/agent/settings-recovery-command-'));
for (const name of ['tmp', 'shared-home']) await mkdir(path.join(output, name));
const binary = path.join(app, 'Contents/MacOS/BlueFatFish'), binaryHash = hash(await readFile(binary)), infoHash = hash(await readFile(path.join(app, 'Contents/Info.plist')));
async function formal() {
  const directory = path.join(os.homedir(), 'Library/Application Support/BlueFatFish'), values = {};
  async function walk(relative) {
    for (const name of (await readdir(path.join(directory, relative))).sort()) {
      const key = path.join(relative, name), file = path.join(directory, key), value = await lstat(file), mode = value.mode % 0o1000;
      if (value.isSymbolicLink()) values[key] = { type: 'symlink', target: await readlink(file), mode };
      else if (value.isDirectory()) await walk(key);
      else if (value.isFile()) values[key] = { sha256: hash(await readFile(file)), bytes: value.size, mode };
    }
  }
  try { await walk(''); } catch (error) { if (error.code !== 'ENOENT') throw error; }
  return values;
}
const formalBefore = await formal(), results = [];
await writeFile(path.join(output, 'formal-before.json'), JSON.stringify(formalBefore, null, 2) + '\n');
await writeFile(path.join(output, 'application-proof.json'), JSON.stringify({ application: app, kind: daily ? 'installed-daily' : 'acceptance', sourceCommit: metadata.BlueFatFishSourceCommit, binaryHash, infoHash, modelRequests: 0 }, null, 2) + '\n');
let originalTask, snapshots;
const long = Array.from({ length: 90 }, (_, i) => i === 74 ? 'PUBLIC_SETTINGS_MARKER_582 中文😀' : `PUBLIC_SETTINGS_LINE_${i} 中文😀`).join('\n') + '\n';
const invalidSkill = '---\nname: invalid-unclosed\ndescription: retain whole draft\n' + long;
const invalidCommand = '---\nPUBLIC_COMMAND_UNCLOSED_491\n' + long;
const savedSkill = '---\nname: public-beta-skill\ndescription: saved public recovery\n---\n\nPUBLIC_SAVED_SKILL_784 中文😀\n';
for (const stage of ['seed', 'unavailable', 'reopen']) {
  if (stage !== 'seed') {
    const fixture = await json(path.join(output, 'settings-editor-fixture.json')), taskFile = path.join(output, 'profile/agent', fixture.multi + '.json');
    if (stage === 'unavailable') {
      originalTask = await readFile(taskFile); await writeFile(path.join(output, 'original-task-before-scope-change.json'), originalTask);
      const task = JSON.parse(originalTask); task.workspaceScope.folders = [fixture.beta]; await writeFile(taskFile, JSON.stringify(task) + '\n');
    } else await writeFile(taskFile, originalTask);
  }
  const args = ['--check', output, '--settings-editor-recovery-check', '--recovery-stage', stage];
  const child = spawn(binary, args, { cwd: root, env: { ...process.env, TMPDIR: path.join(output, 'tmp') + '/' }, stdio: ['ignore', 'pipe', 'pipe'] });
  const stdout = createWriteStream(path.join(output, stage + '-stdout.log')), stderr = createWriteStream(path.join(output, stage + '-stderr.log'));
  child.stdout.pipe(stdout); child.stderr.pipe(stderr);
  await writeFile(path.join(output, stage + '-process.json'), JSON.stringify({ appPID: child.pid, args, binaryHash }, null, 2) + '\n');
  console.log(JSON.stringify({ output, stage, appPID: child.pid, binaryHash }));
  const status = await new Promise((resolve, reject) => { child.once('error', reject); child.once('exit', (exit, signal) => resolve({ exit, signal })); });
  await Promise.all([finished(stdout), finished(stderr)]);
  const reportBytes = await readFile(path.join(output, 'settings-editor-report.json')); await writeFile(path.join(output, stage + '-report.json'), reportBytes);
  const report = JSON.parse(reportBytes), sameApplication = report.appPID === child.pid && report.binaryHash === binaryHash && hash(await readFile(binary)) === binaryHash;
  const success = status.exit === 0 && report.success && report.modelRequests === 0 && sameApplication && Object.keys(report.checks).length > 0 && Object.values(report.checks).every(Boolean);
  const result = { output, stage, ...status, success, sameApplication, checks: Object.keys(report.checks).length, failed: Object.keys(report.checks).filter(key => !report.checks[key]), error: report.error, modelRequests: report.modelRequests };
  results.push(result); console.log(JSON.stringify(result)); await writeFile(path.join(output, stage + '-result.json'), JSON.stringify(result, null, 2) + '\n');
  if (!success) { process.exitCode = 1; break; }
  const fixture = await json(path.join(output, 'settings-editor-fixture.json')), settings = {}, independent = {};
  for (const [role, id] of Object.entries(fixture.windows)) {
    const file = path.join(output, 'profile/workspace-recovery', id, 'layout.json'), layout = await json(file), state = layout.settings;
    if (!state) throw Error('独立设置记录缺失：' + role);
    settings[role] = state;
    independent[role + 'PrivateFileAndVersion'] = (await stat(file)).mode % 0o1000 === 0o600 && state.version === 1 && layout.id === id;
    independent[role + 'OriginalScopeExact'] = role === 'creation' ? state.context.taskID == null && state.context.workspace == null : state.context.taskID === (['rule', 'skill'].includes(role) ? fixture.multi : fixture.general) && (state.context.workspace ?? null) === (role === 'rule' ? fixture.alpha : role === 'skill' ? fixture.beta : null);
    const page = JSON.parse(Buffer.from(state.pages[0].state, 'base64'));
    if (role === 'command') independent.commandWholeDraftExact = page.body === invalidCommand + (stage === 'reopen' ? 'LAST_EDIT_PUBLIC_842\n' : '');
    if (role === 'rule') independent.ruleWholeDraftAndOriginalFileExact = page.body === long && page.selected.id === fixture.rule && fileURLToPath(page.selected.source) === path.join(fixture.alpha, '.bluefatfish/rules/public-alpha-rule.md');
    if (role === 'skill') independent.skillWholeDraftExact = page.body === (stage === 'reopen' ? savedSkill : invalidSkill) && page.selected.id === fixture.skill;
    if (role === 'creation' && stage !== 'reopen') {
      const form = JSON.parse(Buffer.from(state.pages.at(-1).state, 'base64'));
      independent.tasklessInvalidNameScopeAndSelectionExact = form.name === 'PUBLIC_INVALID_NAME/😀' && form.scope === 0 && form.selection.location === 7 && form.selection.length === 7;
    }
    if (stage === 'unavailable' && ['rule', 'skill'].includes(role)) independent[role + 'UnavailableRecordExact'] = JSON.stringify(state) === JSON.stringify(snapshots[role]);
  }
  if (stage === 'seed') snapshots = settings;
  for (const [file, expected] of Object.entries(fixture.sources)) {
    const bytes = await readFile(file);
    const changedSkill = stage === 'reopen' && file.endsWith('/public-beta-skill/SKILL.md');
    const externalRule = stage === 'reopen' && file.endsWith('/public-alpha-rule.md');
    independent['source:' + path.relative(output, file)] = changedSkill ? bytes.toString() === savedSkill : externalRule ? bytes.toString() === '---\nname: public-alpha-rule\ntrigger: manual\n---\n\nPUBLIC_EXTERNAL_RULE_UPDATE_814\n' : hash(bytes) === expected;
  }
  for (const [owner, draft] of [[fixture.multi, 'PUBLIC_ORIGINAL_MULTI_DRAFT_594'], [fixture.general, 'PUBLIC_ORIGINAL_GENERAL_DRAFT_386']]) {
    const task = await json(path.join(output, 'profile/agent', owner + '.json')); independent[owner + 'OriginalComposerAndNoMessages'] = task.draft === draft && task.messages.length === 0;
  }
  if (stage === 'reopen') {
    independent.manualCreationUsesOnlyUserScope = (await readFile(path.join(output, 'profile/extensions/skills/public-created-skill/SKILL.md'), 'utf8')).includes('name: public-created-skill');
    independent.newRuleUsesOnlyUserScope = (await readFile(path.join(output, 'profile/extensions/rules/public-created-rule.md'), 'utf8')).includes('PUBLIC_CREATED_USER_RULE_747');
    independent.originalTaskBytesRestored = (await readFile(path.join(output, 'profile/agent', fixture.multi + '.json'))).equals(originalTask);
  }
  const proof = { success: Object.values(independent).every(Boolean), checks: independent, modelRequests: 0 };
  await writeFile(path.join(output, stage + '-independent.json'), JSON.stringify(proof, null, 2) + '\n');
  if (!proof.success) throw Error('设置恢复独立核对失败：' + Object.keys(independent).filter(key => !independent[key]).join(', '));
}
await writeFile(path.join(output, 'results.json'), JSON.stringify(results, null, 2) + '\n');
const after = await formal(), checks = { formalFilesBytesAndModesExact: JSON.stringify(after) === JSON.stringify(formalBefore), installedBinaryOrCandidateUnchanged: hash(await readFile(binary)) === binaryHash, applicationMetadataUnchanged: hash(await readFile(path.join(app, 'Contents/Info.plist'))) === infoHash, allThreeStagesPassed: results.length === 3 && results.every(value => value.success) };
const preservation = { success: Object.values(checks).every(Boolean), checks, sourceCommit: metadata.BlueFatFishSourceCommit, formalEntries: Object.keys(formalBefore).length, modelRequests: 0 };
await writeFile(path.join(output, 'preservation-proof.json'), JSON.stringify(preservation, null, 2) + '\n');
console.log(JSON.stringify({ output, daily, ...preservation }));
if (!preservation.success) process.exitCode = 1;

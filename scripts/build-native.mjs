import { cp, mkdir, mkdtemp, readFile, readdir, realpath, symlink, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { signingIdentity, signNative, signNativeCheck } from './native-signing.mjs';
import { installNativeBuild } from './native-delivery.mjs';
import { prepareSherpa, sherpaRoot } from './prepare-sherpa.mjs';
import { prepareSecurity } from './prepare-security.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const checkOnly = process.argv.length === 3 && process.argv[2] === '--check';
if (process.argv.length !== 2 && !checkOnly) throw new Error('用 --check 构建独立验收包，或不加参数构建正式候选。');
if (!checkOnly) signingIdentity();
await mkdir(path.join(root, 'build'), { recursive: true });
const staging = await mkdtemp(path.join(root, 'build', 'native-staging-'));
console.log(`构建目录：${staging}`);
const physicalCache = path.join(root, 'build', 'native-cache');
await mkdir(physicalCache, { recursive: true });
// Swift's temporary paths must be ASCII; only the link lives on the system disk.
const cache = '/tmp/bluefatfish-native-' + createHash('sha256').update(root).digest('hex').slice(0, 16);
try { await symlink(physicalCache, cache); }
catch (error) { if (error.code !== 'EEXIST') throw error; }
if (await realpath(cache) !== await realpath(physicalCache)) throw new Error('构建缓存链接指向其他目录，请检查后重试。');
for (const directory of ['tmp', 'modules', 'clang', 'npm', 'swiftpm']) await mkdir(path.join(cache, directory), { recursive: true });
Object.assign(process.env, { TMPDIR: path.join(cache, 'tmp') + path.sep, npm_config_cache: path.join(cache, 'npm'),
  SWIFTPM_MODULECACHE_OVERRIDE: path.join(cache, 'modules'), CLANG_MODULE_CACHE_PATH: path.join(cache, 'clang') });
const output = path.join(staging, checkOnly ? '蓝色大肥鱼验收.app' : '蓝色大肥鱼.app');
const contents = path.join(output, 'Contents'), resources = path.join(contents, 'Resources');
function run(command, args) {
  const result = spawnSync(command, args, { cwd: root, stdio: 'inherit' });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(`${command} 失败（${result.status ?? result.signal}）；构建目录保留在 ${staging}`);
}
function signBuildArtifact(target) {
  if (!checkOnly) return signNative(target);
  run('/usr/bin/codesign', ['--force', '--sign', '-', '--timestamp=none', target]);
  run('/usr/bin/codesign', ['--verify', '--strict', target]);
}
await prepareSherpa();
const scanners = await prepareSecurity();
function buildPackage(directory, product) {
  const args = ['swift', 'build', '--package-path', directory, '--build-system', 'native', '-c', 'release', '--cache-path', path.join(cache, 'swiftpm')];
  run('xcrun', [...args, '--product', product]);
  const result = spawnSync('xcrun', [...args, '--show-bin-path'], { cwd: root, encoding: 'utf8' });
  if (result.status !== 0) throw new Error(result.stderr || `${product} build path unavailable`);
  return result.stdout.trim();
}
const mcpProducts = buildPackage('native-mcp', 'BlueFatFishMCP');
const terminalProducts = buildPackage('native-terminal', 'BlueFatFishTerminal');
run('npm', ['run', 'build']);
run('npm', ['run', 'build:canvas']);
run('npm', ['run', 'build:office']);
run('npm', ['run', 'build:diagrams']);
run('npm', ['run', 'build:wiki']);
await mkdir(path.join(contents, 'MacOS'), { recursive: true });
await mkdir(path.join(resources, 'web'), { recursive: true });
for (const scanner of scanners) {
  const destination = path.join(contents, 'MacOS', path.basename(scanner));
  await cp(scanner, destination);
  signBuildArtifact(destination);
}
const security = path.join(root, 'vendor', 'security');
await cp(path.join(security, 'rules'), path.join(resources, 'security'), { recursive: true });
const frameworks = path.join(contents, 'Frameworks'); await mkdir(frameworks, { recursive: true });
for (const [products, name] of [[mcpProducts, 'libBlueFatFishMCP.dylib'], [terminalProducts, 'libBlueFatFishTerminal.dylib']]) {
  const library = path.join(frameworks, name);
  await cp(path.join(products, name), library);
  run('/usr/bin/install_name_tool', ['-id', `@rpath/${name}`, library]);
  signBuildArtifact(library);
}
await cp(path.join(terminalProducts, 'SwiftTerm_SwiftTerm.bundle'), path.join(resources, 'SwiftTerm_SwiftTerm.bundle'), { recursive: true });
for (const name of ['libsherpa-onnx-c-api.dylib', 'libonnxruntime.dylib']) {
  const destination = path.join(frameworks, name); await cp(path.join(sherpaRoot, 'lib', name), destination); signBuildArtifact(destination);
}
const files = (await readdir(path.join(root, 'native'))).filter(f => f.endsWith('.swift')).map(f => path.join('native', f));
run('xcrun', ['swiftc', '-O', '-whole-module-optimization', '-swift-version', '5', '-target', 'arm64-apple-macosx14.0',
  '-module-cache-path', path.join(cache, 'modules'), '-Xcc', '-fmodules-cache-path=' + path.join(cache, 'clang'),
  ...files, '-import-objc-header', 'native/SherpaBridge.h', '-I', path.join(sherpaRoot, 'include'), '-I', path.join(mcpProducts, 'Modules'), '-I', path.join(root, 'native-mcp/.build/checkouts/swift-system/Sources/CSystem/include'),
  '-I', path.join(terminalProducts, 'Modules'), '-I', path.join(terminalProducts, 'TerminalPTY.build'),
  '-L', frameworks, '-lBlueFatFishMCP', '-lBlueFatFishTerminal', '-lsherpa-onnx-c-api', '-lsqlite3', '-Xlinker', '-rpath', '-Xlinker', '@executable_path/../Frameworks',
  '-framework', 'AppKit', '-framework', 'WebKit', '-framework', 'Quartz', '-framework', 'PDFKit', '-framework', 'Vision', '-framework', 'ImageIO', '-framework', 'AVFAudio', '-framework', 'Security',
  '-framework', 'UniformTypeIdentifiers', '-framework', 'Speech', '-framework', 'AVFoundation', '-framework', 'AudioToolbox', '-framework', 'Accelerate', '-framework', 'ScreenCaptureKit', '-framework', 'UserNotifications', '-framework', 'JavaScriptCore', '-o', path.join(contents, 'MacOS', 'BlueFatFish')]);
const version = JSON.parse(await readFile(path.join(root, 'package.json'), 'utf8')).version;
const revision = spawnSync('git', ['rev-parse', 'HEAD'], { cwd: root, encoding: 'utf8' });
if (revision.status !== 0 || !/^[a-f0-9]{40}\s*$/.test(revision.stdout)) throw new Error('无法记录构建源码版本。');
const dirty = spawnSync('git', ['status', '--porcelain', '--untracked-files=no'], { cwd: root, encoding: 'utf8' });
if (dirty.status !== 0) throw new Error('无法记录构建工作区状态。');
await writeFile(path.join(contents, 'Info.plist'), `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>BlueFatFish</string>
<key>CFBundleIdentifier</key><string>${checkOnly ? 'com.xjs.bluefatfish.check.' + path.basename(staging).toLowerCase() : 'com.xjs.bluefatfish'}</string>
${checkOnly ? '<key>BlueFatFishAcceptanceOnly</key><true/>' : ''}
<key>BlueFatFishSourceCommit</key><string>${revision.stdout.trim()}</string>
<key>BlueFatFishSourceDirty</key>${dirty.stdout.trim() ? '<true/>' : '<false/>'}
<key>BlueFatFishBuildDate</key><string>${new Date().toISOString()}</string>
<key>CFBundleName</key><string>蓝色大肥鱼</string>
<key>CFBundleDisplayName</key><string>蓝色大肥鱼</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>${version}</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
${checkOnly ? '' : `<key>CFBundleDocumentTypes</key><array><dict>
<key>CFBundleTypeName</key><string>任务附件</string>
<key>CFBundleTypeRole</key><string>Viewer</string>
<key>LSHandlerRank</key><string>Alternate</string>
<key>CFBundleTypeExtensions</key><array>${['txt', 'md', 'csv', 'tsv', 'json', 'jsonl', 'yaml', 'yml', 'toml', 'xml', 'html', 'htm', 'svg', 'log', 'swift', 'py', 'js', 'jsx', 'ts', 'tsx', 'css', 'sql', 'sh', 'rs', 'go', 'java', 'c', 'h', 'cpp', 'png', 'jpg', 'jpeg', 'heic', 'heif', 'tif', 'tiff', 'webp', 'gif', 'pdf', 'docx', 'xlsx', 'pptx'].map(type => `<string>${type}</string>`).join('')}</array>
</dict></array>`}
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSSupportsAutomaticGraphicsSwitching</key><true/>
<key>NSMicrophoneUsageDescription</key><string>用于语音唤醒和直接对话。</string>
<key>NSSpeechRecognitionUsageDescription</key><string>在本机识别唤醒词和语音消息。</string>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>`);
// Bundle the approved portrait only. No browser engine, node_modules, source
// archives or unused multi-megabyte 3D models are shipped in the application.
for (const item of ['index.html', 'assets', 'canvas', 'office', 'diagrams', 'wiki', 'portraits/whale-maid', 'animations/airi', 'audio/whale-maid']) {
  const target = path.join(resources, 'web', item); await mkdir(path.dirname(target), { recursive: true });
  await cp(path.join(root, 'dist', item), target, { recursive: true });
}
await cp(path.join(sherpaRoot, 'model'), path.join(resources, 'wake-model'), { recursive: true });
await mkdir(path.join(resources, 'licenses'), { recursive: true });
for (const name of ['Gitleaks-LICENSE.txt', 'ast-grep-LICENSE.txt', 'OSV-Scanner-LICENSE.txt', 'Opengrep-LICENSE.txt', 'Opengrep-NOTICE.txt']) await cp(path.join(security, name), path.join(resources, 'licenses', name));
for (const name of ['LICENSE-sherpa.txt', 'LICENSE-onnxruntime.txt', 'THIRD-PARTY-NOTICES-onnxruntime.txt']) await cp(path.join(sherpaRoot, name), path.join(resources, 'licenses', name));
for (const [repo, license] of [['swift-sdk', 'LICENSE'], ['swift-system', 'LICENSE.txt'], ['swift-log', 'LICENSE.txt'], ['eventsource', 'LICENSE.md']]) {
  await cp(path.join(root, 'native-mcp/.build/checkouts', repo, license), path.join(resources, 'licenses', `MCP-${repo}-LICENSE.txt`));
}
await cp(path.join(root, 'native-terminal/.build/checkouts/SwiftTerm/LICENSE'), path.join(resources, 'licenses', 'SwiftTerm-LICENSE.txt'));
const iconset = path.join(staging, 'AppIcon.iconset');
run(path.join(contents, 'MacOS', 'BlueFatFish'), [...(checkOnly ? ['--check', path.join(staging, 'icon-profile')] : []), '--make-icons', iconset]);
run('/usr/bin/iconutil', ['-c', 'icns', '-o', path.join(resources, 'AppIcon.icns'), iconset]);
if (checkOnly) {
  signNativeCheck(output);
  console.log(`独立验收应用：${output}`);
} else {
  signNative(output);
  console.log(JSON.stringify(await installNativeBuild(output), null, 2));
}

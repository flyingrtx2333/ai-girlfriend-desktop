import { cp, mkdir, readFile, readdir, rm, writeFile } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { signingIdentity, signNative } from './native-signing.mjs';
import { prepareSherpa, sherpaRoot } from './prepare-sherpa.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const output = path.join(root, 'build', '蓝色大肥鱼.app');
const contents = path.join(output, 'Contents'), resources = path.join(contents, 'Resources');
function run(command, args) {
  const result = spawnSync(command, args, { cwd: root, stdio: 'inherit' });
  if (result.error) throw result.error;
  if (result.status !== 0) process.exit(result.status || 1);
}
signingIdentity(); // Fail before replacing the build if no stable identity exists.
await prepareSherpa();
const mcpBuildArgs = ['swift', 'build', '--package-path', 'native-mcp', '--build-system', 'native', '-c', 'release'];
run('xcrun', [...mcpBuildArgs, '--product', 'BlueFatFishMCP']);
const mcpBin = spawnSync('xcrun', [...mcpBuildArgs, '--show-bin-path'], { cwd: root, encoding: 'utf8' });
if (mcpBin.status !== 0) throw new Error(mcpBin.stderr || 'MCP build path unavailable');
const mcpProducts = mcpBin.stdout.trim();
run('npm', ['run', 'build']);
run('npm', ['run', 'build:canvas']);
run('npm', ['run', 'build:office']);
run('npm', ['run', 'build:diagrams']);
await rm(output, { recursive: true, force: true });
await mkdir(path.join(contents, 'MacOS'), { recursive: true });
await mkdir(path.join(resources, 'web'), { recursive: true });
const frameworks = path.join(contents, 'Frameworks'); await mkdir(frameworks, { recursive: true });
const mcpLibrary = path.join(frameworks, 'libBlueFatFishMCP.dylib');
await cp(path.join(mcpProducts, 'libBlueFatFishMCP.dylib'), mcpLibrary);
run('/usr/bin/install_name_tool', ['-id', '@rpath/libBlueFatFishMCP.dylib', mcpLibrary]); signNative(mcpLibrary);
for (const name of ['libsherpa-onnx-c-api.dylib', 'libonnxruntime.dylib']) {
  const destination = path.join(frameworks, name); await cp(path.join(sherpaRoot, 'lib', name), destination); signNative(destination);
}
const files = (await readdir(path.join(root, 'native'))).filter(f => f.endsWith('.swift')).map(f => path.join('native', f));
run('xcrun', ['swiftc', '-O', '-whole-module-optimization', '-swift-version', '5', '-target', 'arm64-apple-macosx14.0',
  ...files, '-import-objc-header', 'native/SherpaBridge.h', '-I', path.join(sherpaRoot, 'include'), '-I', path.join(mcpProducts, 'Modules'), '-I', path.join(root, 'native-mcp/.build/checkouts/swift-system/Sources/CSystem/include'),
  '-L', frameworks, '-lBlueFatFishMCP', '-lsherpa-onnx-c-api', '-lsqlite3', '-Xlinker', '-rpath', '-Xlinker', '@executable_path/../Frameworks',
  '-framework', 'AppKit', '-framework', 'WebKit', '-framework', 'Quartz', '-framework', 'PDFKit', '-framework', 'Vision', '-framework', 'ImageIO', '-framework', 'AVFAudio', '-framework', 'Security',
  '-framework', 'UniformTypeIdentifiers', '-framework', 'Speech', '-framework', 'AVFoundation', '-framework', 'AudioToolbox', '-framework', 'Accelerate', '-framework', 'ScreenCaptureKit', '-framework', 'UserNotifications', '-o', path.join(contents, 'MacOS', 'BlueFatFish')]);
const version = JSON.parse(await readFile(path.join(root, 'package.json'), 'utf8')).version;
await writeFile(path.join(contents, 'Info.plist'), `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>BlueFatFish</string>
<key>CFBundleIdentifier</key><string>com.xjs.bluefatfish</string>
<key>CFBundleName</key><string>蓝色大肥鱼</string>
<key>CFBundleDisplayName</key><string>蓝色大肥鱼</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>${version}</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
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
for (const item of ['index.html', 'assets', 'canvas', 'office', 'diagrams', 'portraits/whale-maid', 'animations/airi', 'audio/whale-maid']) {
  const target = path.join(resources, 'web', item); await mkdir(path.dirname(target), { recursive: true });
  await cp(path.join(root, 'dist', item), target, { recursive: true });
}
await cp(path.join(sherpaRoot, 'model'), path.join(resources, 'wake-model'), { recursive: true });
await mkdir(path.join(resources, 'licenses'), { recursive: true });
for (const name of ['LICENSE-sherpa.txt', 'LICENSE-onnxruntime.txt', 'THIRD-PARTY-NOTICES-onnxruntime.txt']) await cp(path.join(sherpaRoot, name), path.join(resources, 'licenses', name));
for (const [repo, license] of [['swift-sdk', 'LICENSE'], ['swift-system', 'LICENSE.txt'], ['swift-log', 'LICENSE.txt'], ['eventsource', 'LICENSE.md']]) {
  await cp(path.join(root, 'native-mcp/.build/checkouts', repo, license), path.join(resources, 'licenses', `MCP-${repo}-LICENSE.txt`));
}
const iconset = path.join(root, 'build', 'AppIcon.iconset');
await rm(iconset, { recursive: true, force: true });
run(path.join(contents, 'MacOS', 'BlueFatFish'), ['--make-icons', iconset]);
run('/usr/bin/iconutil', ['-c', 'icns', '-o', path.join(resources, 'AppIcon.icns'), iconset]);
signNative(output);
console.log(output);

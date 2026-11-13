import { fork, spawn, spawnSync } from 'node:child_process';
import { createServer } from 'node:http';
import { createHash, randomUUID } from 'node:crypto';
import { appendFile, mkdir, mkdtemp, readFile, readdir, writeFile } from 'node:fs/promises';
import { once } from 'node:events';
import { isDeepStrictEqual } from 'node:util';
import { fileURLToPath, pathToFileURL } from 'node:url';
import os from 'node:os';
import path from 'node:path';

const args = process.argv.slice(2), hash = data => createHash('sha256').update(data).digest('hex');
const official = path.join(os.homedir(), 'Library/Caches/bluefatfish-mcp-everything-real/node_modules/@modelcontextprotocol/server-everything');
const version = JSON.parse(await readFile(path.join(official, 'package.json'), 'utf8')).version;
if (version !== '2.2.1') throw new Error('Use the official server-everything 2.2.1 acceptance dependency.');
const serverEntry = path.join(official, 'dist/index.js');
if (args[0] === '--official-http-worker') await serve(args[1], args[2]);
else await verify();

async function serve(output, page) {
  if (typeof process.send !== 'function' || !output || !page?.startsWith('/public-readme/')) throw new Error('The private HTTP worker requires its driver.');
  const { createApp } = await import(pathToFileURL(path.join(official, 'dist/transports/streamableHttp.js')).href);
  const source = await readFile(path.join(output, 'workspace/README.md')), sourceHash = hash(source);
  const { app: mcp, shutdown } = createApp();
  const server = createServer(async (request, response) => {
    if (request.method !== 'GET' || request.url !== page) { mcp(request, response); return; }
    try {
      await appendFile(path.join(output, 'actual-public-page-reads.jsonl'), JSON.stringify({ method: 'GET', path: page, bytes: source.length, sha256: sourceHash, receivedAt: new Date().toISOString() }) + '\n');
      response.writeHead(200, { 'Content-Type': 'text/plain; charset=utf-8', 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' }); response.end(source);
    } catch { response.writeHead(500); response.end(); }
  });
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  // The official shutdown handler exits its process. Isolate it so it cannot
  // override the driver's failure status or interrupt its evidence writes.
  let stopping = false;
  const stop = () => { if (!stopping) { stopping = true; void shutdown(); } };
  process.once('message', message => { if (message === 'shutdown') stop(); });
  process.once('disconnect', stop);
  process.send({ port: server.address().port, pid: process.pid });
}

async function verify() {
  const appIndex = args.indexOf('--app'), ui = args.includes('--hold-ui');
  if (appIndex < 0 || !args[appIndex + 1] || args.includes('--live-agent')) throw new Error('Pass --app for an exact signed candidate. This check never authorizes model requests.');
  const app = path.resolve(args[appIndex + 1]), binary = path.join(app, 'Contents/MacOS/BlueFatFish'), library = path.join(app, 'Contents/Frameworks/libBlueFatFishMCP.dylib');
  if (spawnSync('/usr/bin/codesign', ['--verify', '--deep', '--strict', app]).status !== 0) throw new Error('Candidate signature failed.');
  const binaryHash = hash(await readFile(binary)), libraryHash = hash(await readFile(library));
  const output = await mkdtemp(path.join(os.tmpdir(), 'bluefatfish-mcp-input-'));
  const source = await readFile(fileURLToPath(new URL('../README.md', import.meta.url))), sourceHash = hash(source), page = '/public-readme/' + randomUUID();
  await mkdir(path.join(output, 'workspace')); await mkdir(path.join(output, 'shared-home'));
  await writeFile(path.join(output, 'workspace/README.md'), source);
  const worker = fork(fileURLToPath(import.meta.url), ['--official-http-worker', output, page], { stdio: ['ignore', 'inherit', 'inherit', 'ipc'], env: { PATH: '/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin', LANG: 'en_US.UTF-8' } });
  const workerExit = once(worker, 'exit');
  const [address] = await Promise.race([once(worker, 'message'), workerExit.then(() => { throw new Error('Official HTTP worker ended before listening.'); })]);
  if (address.pid !== worker.pid) throw new Error('Unexpected HTTP worker identity.');
  const origin = 'http://127.0.0.1:' + address.port;
  const fixture = { node: process.execPath, serverEntry, version, endpoint: origin + '/mcp', publicURL: origin + page, sourceHash, httpPID: worker.pid, modelTransmissionAuthorized: false };
  await writeFile(path.join(output, 'mcp-input-fixture.json'), JSON.stringify(fixture, null, 2));
  console.log(JSON.stringify({ output, app, binaryHash, libraryHash, ui, officialVersion: version, httpPID: worker.pid, modelTransmissionAuthorized: false }));
  const read = async name => JSON.parse(await readFile(path.join(output, name), 'utf8'));
  const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
  async function maybe(name) { try { return await read(name); } catch (error) { if (error.code === 'ENOENT') return undefined; throw error; } }
  const appArgs = ['--check', output, ...(ui ? ['--manual-ui', '--mcp-input-ui'] : ['--mcp-input-check', '--background-component-check'])];
  const command = [binary, ...appArgs].join(' ');
  const actualCommand = pid => spawnSync('/bin/ps', ['-ww', '-p', String(pid), '-o', 'command='], { encoding: 'utf8' }).stdout.trim();
  let pid;
  try {
    let launchError;
    const launched = spawn(binary, appArgs, { stdio: 'inherit' });
    launched.once('error', error => { launchError = error; });
    let started;
    for (let attempt = 0; attempt < 120; attempt++) {
      if (launchError) throw launchError;
      const marker = ui ? (await readdir(output)).find(name => /^manual-ui-process-\d+\.json$/.test(name)) : 'mcp-input-started.json';
      if (marker) started = await maybe(marker);
      if (started) break;
      await sleep(125);
    }
    if (!started) {
      const row = spawnSync('/bin/ps', ['-axww', '-o', 'pid=,command='], { encoding: 'utf8' }).stdout.split('\n').find(line => line.trim().replace(/^\d+\s+/, '') === command);
      if (!row) throw new Error('No matching process or startup record; preserve original output.');
      pid = Number(row.trim().split(/\s+/, 1)[0]);
      console.error('Original process is still alive without a startup record; observing the same process.');
      while (actualCommand(pid) === command) await sleep(500);
      throw new Error('Original process ended before startup readback; preserve original output.');
    }
    pid = started.appPID;
    if (pid !== launched.pid || actualCommand(pid) !== command || started.binaryHash !== binaryHash || (ui && (!started.modelTransmissionBlocked || started.modelRequestsAtStart !== 0))) throw new Error('Actual signed process did not match acceptance entry.');
    await writeFile(path.join(output, 'actual-process-command.json'), JSON.stringify({ pid, command, binaryHash, libraryHash }, null, 2));
    if (ui) console.log(JSON.stringify({ uiReady: true, output, appPID: pid, httpPID: worker.pid, publicURL: fixture.publicURL }));
    let report, warned = false;
    const deadline = Date.now() + 120_000;
    while (actualCommand(pid) === command) {
      if (!ui && !report) report = await maybe('mcp-input-report.json');
      if (!ui && !warned && Date.now() > deadline) { warned = true; console.error('Observation time exceeded; the original candidate and its HTTP service remain live.'); }
      await sleep(250);
    }
    if (!ui) report ??= await maybe('mcp-input-report.json');
    if (!ui && report?.success !== true) {
      const failure = { output, appPID: pid, binaryHash, libraryHash, success: false, nativeReport: report ?? null };
      await writeFile(path.join(output, 'mcp-input-driver-failure.json'), JSON.stringify(failure, null, 2));
      console.log(JSON.stringify({ output, appPID: pid, success: false, error: report?.error ?? 'Native checks did not complete successfully.' }));
      process.exitCode = 1; return;
    }
    const created = await read('mcp-input-created.json'), first = await read('profile/agent/' + created.taskID + '.json'), other = await read('profile/agent/' + created.otherTaskID + '.json');
    const common = {
      exactSignedProcessExited: !!pid && actualCommand(pid) !== command,
      publicSourceUnchanged: hash(await readFile(path.join(output, 'workspace/README.md'))) === sourceHash && created.sourceHash === sourceHash,
      draftsAndUserInputUnchanged: first.draft === '这份草稿不发送给连接器。' && other.draft === '另一项任务的草稿。' && first.messages.length === 1 && first.messages[0].content === source.toString('utf8').split('\n')[0] && !other.messages.length,
      noNewAssistantOrReceipt: [first, other].every(task => !task.modelReceipts?.length && task.messages.every(message => message.role === 'user')),
    };
    const independent = ui ? common : {
      ...common,
      realNativeReport: report?.success === true && report.appPID === pid && report.binaryHash === binaryHash && report.blockedModelAttempts === 0,
      officialAcceptedExactTypedValues: report?.actual?.accepted?.action === 'accept' && isDeepStrictEqual(report.actual.accepted.content, report.expectedAcceptedContent) && report.actual.accepted.content.name === source.toString('utf8').split('\n')[0] && report.actual.accepted.content.check === false,
      actualDeclineCancelAndStaleResponsesHaveNoContent: ['decline', 'cancel', 'stale', 'urlDecline'].every(name => report?.actual?.[name]?.content === undefined && report?.actual?.[name]?.action === (['decline', 'urlDecline'].includes(name) ? 'decline' : 'cancel')),
      publicBrowserWasNotOpenedByNativeCheck: (await readdir(output)).every(name => name !== 'actual-public-page-reads.jsonl'),
    };
    const result = { output, appPID: pid, binaryHash, libraryHash, mode: ui ? 'window-process-only' : 'native', independent, modelTransmissionAuthorized: false, success: Object.values(independent).every(Boolean) };
    await writeFile(path.join(output, 'mcp-input-driver-report.json'), JSON.stringify(result, null, 2));
    console.log(JSON.stringify({ ...result, nativeChecks: Object.keys(report?.checks ?? {}).length, error: report?.error, failed: Object.keys(report?.checks ?? {}).filter(key => !report.checks[key]) }));
    if (!result.success) process.exitCode = 1;
  } finally {
    if (pid && actualCommand(pid) === command) {
      console.error('Waiting for the same candidate before stopping its local HTTP service.');
      while (actualCommand(pid) === command) await sleep(500);
    }
    if (worker.connected) worker.send('shutdown');
    const [code, signal] = await workerExit;
    if (code !== 0 || signal) throw new Error('Official HTTP worker did not exit cleanly.');
  }
}

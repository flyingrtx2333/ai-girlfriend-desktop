import { readFile, appendFile, writeFile } from 'node:fs/promises';
import { createHash, timingSafeEqual } from 'node:crypto';
import { createInterface } from 'node:readline';
import { createServer } from 'node:http';

const option = name => { const index = process.argv.indexOf(name); return index < 0 ? undefined : process.argv[index + 1]; };
const transport = process.argv.includes('--http') ? 'http' : 'stdio';
const csv = option('--csv') ?? process.env.LEDGER_CSV, logPath = option('--log');
if (!csv || !logPath) throw new Error('An actual CSV and request log are required');
const log = async value => appendFile(logPath, JSON.stringify({ at: new Date().toISOString(), pid: process.pid, transport, ...value }) + '\n');
async function sumSales() {
  const bytes = await readFile(csv), lines = bytes.toString('utf8').trim().split(/\r?\n/);
  if (lines.shift() !== 'item,amount') throw new Error('Expected item,amount CSV');
  let cents = 0n;
  for (const line of lines) {
    const cells = line.split(',');
    if (cells.length !== 2 || !cells[0] || !/^\d+\.\d{2}$/.test(cells[1])) throw new Error('Invalid sales row');
    cents += BigInt(cells[1].replace('.', ''));
  }
  return { rows: lines.length, total: `${cents / 100n}.${String(cents % 100n).padStart(2, '0')}`, currency: 'CNY', sourceSha256: createHash('sha256').update(bytes).digest('hex') };
}
async function respond(message) {
  const base = { jsonrpc: '2.0', id: message.id };
  await log({ method: message.method, ...(message.method === 'tools/call' ? { tool: message.params?.name } : {}) });
  if (message.id === undefined) return null;
  if (message.method === 'initialize') return { ...base, result: { protocolVersion: message.params.protocolVersion, capabilities: { tools: {} }, serverInfo: { name: 'ledger-tools', version: '1.0.0' } } };
  if (message.method === 'ping') return { ...base, result: {} };
  if (message.method === 'tools/list') return { ...base, result: { tools: [{ name: 'sum_sales', description: '读取已配置的实际销售 CSV，用整数分合计，返回行数、两位小数合计、币种及输入文件 SHA256。无参数。', inputSchema: { type: 'object', properties: {}, additionalProperties: false }, annotations: { readOnlyHint: true, idempotentHint: true } }] } };
  if (message.method === 'tools/call' && message.params?.name === 'sum_sales') {
    if (Object.keys(message.params.arguments ?? {}).length) return { ...base, error: { code: -32602, message: 'sum_sales takes no arguments' } };
    try {
      const result = await sumSales(); await log({ event: 'calculated', ...result });
      return { ...base, result: { content: [{ type: 'text', text: JSON.stringify(result) }], structuredContent: result, isError: false } };
    } catch (error) { return { ...base, result: { content: [{ type: 'text', text: error.message }], isError: true } }; }
  }
  return { ...base, error: { code: -32601, message: 'Method not found' } };
}
if (transport === 'stdio') {
  for await (const line of createInterface({ input: process.stdin, crlfDelay: Infinity })) {
    try { const result = await respond(JSON.parse(line)); if (result) process.stdout.write(JSON.stringify(result) + '\n'); }
    catch { process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id: null, error: { code: -32700, message: 'Parse error' } }) + '\n'); }
  }
} else {
  const key = Buffer.from((await readFile(option('--key-file'), 'utf8')).trim());
  const server = createServer(async (req, res) => {
    const supplied = Buffer.from(req.headers['x-ledger-key'] ?? '');
    const authorized = key.length === supplied.length && timingSafeEqual(key, supplied);
    if (!authorized) { await log({ event: 'http-auth', authorized: false }); res.writeHead(401).end(); return; }
    if (req.method !== 'POST' || req.url !== '/mcp') { res.writeHead(405).end(); return; }
    try {
      let size = 0; const chunks = [];
      for await (const chunk of req) { size += chunk.length; if (size > 64_000) throw new Error('Request too large'); chunks.push(chunk); }
      const message = JSON.parse(Buffer.concat(chunks).toString('utf8'));
      await log({ event: 'http-auth', authorized: true }); const result = await respond(message);
      if (result) res.writeHead(200, { 'Content-Type': 'application/json' }).end(JSON.stringify(result)); else res.writeHead(202).end();
    } catch { res.writeHead(400).end(); }
  });
  await new Promise(resolve => server.listen(Number(option('--port') ?? 0), '127.0.0.1', resolve));
  await writeFile(option('--ready-file'), JSON.stringify({ pid: process.pid, url: `http://127.0.0.1:${server.address().port}/mcp` }));
  process.on('SIGTERM', () => server.close(() => process.exit(0)));
}

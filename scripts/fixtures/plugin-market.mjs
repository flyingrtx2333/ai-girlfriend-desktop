import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { appendFileSync, readFileSync, writeFileSync } from 'node:fs';
import { createServer } from 'node:https';
import path from 'node:path';

const root = process.argv[2];
const zip = spawnSync('/usr/bin/python3', ['-c', `
from pathlib import Path
import json, sys, zipfile
root = Path(sys.argv[1])
def write(name, title, version, quantity):
    data = {"sku": "FIXTURE-8", "quantity": quantity, "version": version}
    with zipfile.ZipFile(root / (name + '-' + version + '.zip'), 'w', zipfile.ZIP_DEFLATED) as archive:
        archive.writestr('.claude-plugin/plugin.json', json.dumps({"name": name, "displayName": title, "version": version, "author": {"name": "公开样例作者"}}, ensure_ascii=False))
        archive.writestr('README.md', f'# {title} {version}\\n')
        archive.writestr('skills/inventory/SKILL.md', '---\\nname: inventory\\ndescription: Read the bundled public sample inventory.\\n---\\nRead resources/count.json for the current inventory.\\n')
        archive.writestr('skills/inventory/resources/count.json', json.dumps(data, ensure_ascii=False) + '\\n')
    return data
facts = [write('inventory-helper', '库存速查', '1.0.0', 42), write('inventory-helper', '库存速查', '2.0.0', 88)]
write('review-notes', '审阅笔记', '1.0.0', 13)
(root / 'facts.json').write_text(json.dumps(facts) + '\\n')
`, root], { encoding: 'utf8' });
if (zip.status !== 0) throw Error(zip.stderr || 'Plugin ZIP fixture could not be created.');
const archive = name => readFileSync(path.join(root, name));
const digest = name => createHash('sha256').update(archive(name)).digest('hex');
const log = value => appendFileSync(path.join(root, 'requests.jsonl'), JSON.stringify(value) + '\n');
writeFileSync(path.join(root, 'requests.jsonl'), '');
let origin, version = '1.0.0', invalid = false;
function send(res, status, value) {
  res.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
  res.end(JSON.stringify(value));
}
function entry(name, title, category, description, v, checksum = true) {
  const filename = `${name}-${v}.zip`;
  return { name, displayName: title, description, author: { name: '公开样例作者' }, category, version: v,
    source: { source: 'archive', url: origin + '/' + filename, ...(checksum ? { sha256: digest(filename) } : {}) } };
}
const server = createServer({ key: archive('test-key.pem'), cert: archive('test-cert.pem') }, (req, res) => {
  const url = new URL(req.url, origin);
  if (url.pathname === '/fixture' && req.method === 'POST') {
    if (['1.0.0', '2.0.0'].includes(url.searchParams.get('version'))) version = url.searchParams.get('version');
    invalid = url.searchParams.get('invalid') === '1';
    log({ event: 'fixture-state', version, invalid }); return send(res, 200, { version, invalid });
  }
  if (req.method !== 'GET') return send(res, 405, {});
  if (['/marketplace.json', '/other-marketplace.json'].includes(url.pathname)) {
    log({ event: 'directory', version, path: url.pathname, invalid, tls: !!req.socket.encrypted });
    if (invalid) return send(res, 200, { name: 'missing-owner', plugins: [] });
    const stock = entry('inventory-helper', '库存速查', '工作流', '查阅公开库存数量与版本', version);
    const review = entry('review-notes', '审阅笔记', '开发', '公开审阅清单', '1.0.0', false);
    const corrupt = { name: 'checksum-test', displayName: '摘要不符样例', category: '检查', version: '1.0.0',
      source: { source: 'archive', url: origin + '/bad-checksum.zip', sha256: '0'.repeat(64) } };
    const external = { name: 'source-not-supported', displayName: 'Git 来源样例', category: '开发',
      source: { source: 'github', repo: 'public-example/never-requested' } };
    return send(res, 200, { name: url.pathname === '/marketplace.json' ? 'public-plugin-market' : 'different-market',
      owner: { name: '公开样例目录' }, plugins: [stock, review, corrupt, external] });
  }
  const filename = url.pathname.slice(1);
  if (['inventory-helper-1.0.0.zip', 'inventory-helper-2.0.0.zip', 'review-notes-1.0.0.zip', 'bad-checksum.zip'].includes(filename)) {
    const data = archive(filename === 'bad-checksum.zip' ? 'review-notes-1.0.0.zip' : filename);
    log({ event: 'archive', name: filename, sha256: createHash('sha256').update(data).digest('hex'), tls: !!req.socket.encrypted,
      credentialHeader: !!req.headers.authorization || !!req.headers.cookie });
    res.writeHead(200, { 'Content-Type': 'application/zip', 'Content-Length': data.length, 'Cache-Control': 'no-store' }); return res.end(data);
  }
  log({ event: 'unknown-path', path: url.pathname }); return send(res, 404, {});
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
origin = `https://localhost:${server.address().port}`;
writeFileSync(path.join(root, 'ready.json'), JSON.stringify({ pid: process.pid, origin }) + '\n');
process.on('SIGTERM', () => { server.closeAllConnections(); server.close(() => process.exit(0)); });

import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { appendFileSync, readFileSync, writeFileSync } from 'node:fs';
import { createServer } from 'node:https';
import path from 'node:path';

const root = process.argv[2];
const zip = spawnSync('/usr/bin/python3', ['-c', `
from pathlib import Path
import json, os, subprocess, sys, zipfile
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

repo = root / 'repository'
repo.mkdir()
env = {**os.environ, 'GIT_CONFIG_NOSYSTEM': '1', 'GIT_CONFIG_GLOBAL': '/dev/null'}
def git(*args):
    return subprocess.check_output(['/usr/bin/git', '-C', str(repo), *args], env=env).decode().strip()
git('init', '--quiet', '--template=')
def file(path, content):
    output = repo / path
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(content)
def plugin(folder, name, title, version, quantity):
    def member(path):
        return str(Path(folder) / path)
    file(member('.qoder-plugin/plugin.json'), json.dumps({'name':name,'displayName':title,'version':version,'author':'公开仓库作者'}, ensure_ascii=False))
    file(member('skills/inventory/SKILL.md'), '---\\nname: inventory\\ndescription: Read the public repository inventory.\\n---\\nRead resources/count.json.\\n')
    file(member('skills/inventory/resources/count.json'), json.dumps({'sku':'GIT-EXAMPLE-7','quantity':quantity,'version':version})+'\\n')
revisions=[]
for version, quantity in [('1.0.0',61), ('2.0.0',97)]:
    plugin('.', 'repo-workflow', '仓库工作流', version, quantity + 100)
    plugin('plugins/repo-stock', 'repo-stock', '仓库库存', version, quantity)
    plugin('plugins/other', 'other', '其他目录', version, 1234)
    listing = {'name':'repository-market','owner':{'name':'公开仓库目录'},'metadata':{'pluginRoot':'./plugins'},'plugins':[
        {'name':'repo-stock','displayName':'仓库库存','version':version,'category':'工作流','source':'repo-stock'},
        {'name':'other','displayName':'其他目录','version':version,'category':'开发','source':'./plugins/other'},
        {'name':'invalid-path','displayName':'越界路径样例','category':'检查','source':'./plugins/../other'}]}
    file('.claude-plugin/marketplace.json', json.dumps(listing, ensure_ascii=False))
    git('add','.')
    git('-c','user.name=Fixture','-c','user.email=fixture@example.test','-c','commit.gpgsign=false','commit','--quiet','-m','Fixture '+version)
    revision=git('rev-parse','HEAD')
    git('archive', '--format=zip', '--prefix=fixture-extensions-'+revision[:12]+'/', '--output='+str(root / (revision+'.zip')), revision)
    (root / (revision+'.json')).write_text(json.dumps(listing, ensure_ascii=False))
    revisions.append({'version':version,'quantity':quantity,'rootQuantity':quantity+100,'commit':revision})
(root / 'repository-facts.json').write_text(json.dumps(revisions)+'\\n')
`, root], { encoding: 'utf8' });
if (zip.status !== 0) throw Error(zip.stderr || 'Plugin ZIP fixture could not be created.');
const archive = name => readFileSync(path.join(root, name));
const digest = name => createHash('sha256').update(archive(name)).digest('hex');
const log = value => appendFileSync(path.join(root, 'requests.jsonl'), JSON.stringify(value) + '\n');
const revisions = JSON.parse(archive('repository-facts.json'));
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
function sendZip(res, data) {
  res.writeHead(200, { 'Content-Type': 'application/zip', 'Content-Length': data.length, 'Cache-Control': 'no-store' });
  return res.end(data);
}
const server = createServer({ key: archive('test-key.pem'), cert: archive('test-cert.pem') }, (req, res) => {
  const url = new URL(req.url, origin);
  if (url.pathname === '/fixture' && req.method === 'POST') {
    if (['1.0.0', '2.0.0'].includes(url.searchParams.get('version'))) version = url.searchParams.get('version');
    invalid = url.searchParams.get('invalid') === '1';
    log({ event: 'fixture-state', version, invalid }); return send(res, 200, { version, invalid });
  }
  if (req.method !== 'GET') return send(res, 405, {});
  const credentialHeader = !!req.headers.authorization || !!req.headers.cookie;
  const repository = '/repos/fixture-lab/extensions/';
  if (url.pathname.startsWith(repository)) {
    const current = revisions.find(revision => revision.version === version);
    const request = url.pathname.slice(repository.length);
    if (request.startsWith('commits/')) {
      const ref = decodeURIComponent(request.slice('commits/'.length));
      log({ event: 'git-ref', ref, commit: current.commit, credentialHeader, tls: !!req.socket.encrypted });
      if (!['HEAD', 'release/inventory'].includes(ref)) return send(res, 404, {});
      if (req.headers.accept === 'application/vnd.github.sha') {
        res.writeHead(200, { 'Content-Type': 'text/plain' });
        return res.end(current.commit);
      }
      return send(res, 200, { sha: current.commit });
    }
    if (request.startsWith('contents/')) {
      const ref = url.searchParams.get('ref');
      const pinned = revisions.find(revision => revision.commit === ref);
      log({ event: 'git-manifest', key: request, ref, credentialHeader, tls: !!req.socket.encrypted });
      if (!pinned || request !== 'contents/.claude-plugin/marketplace.json') return send(res, 404, {});
      return send(res, 200, JSON.parse(archive(ref + '.json')));
    }
    if (request.startsWith('zipball/')) {
      const commit = request.slice('zipball/'.length);
      if (!revisions.some(revision => revision.commit === commit)) return send(res, 404, {});
      const data = archive(commit + '.zip');
      log({ event: 'git-archive', commit, sha256: digest(commit + '.zip'), credentialHeader, tls: !!req.socket.encrypted });
      return sendZip(res, data);
    }
  }
  if (['/marketplace.json', '/other-marketplace.json'].includes(url.pathname)) {
    log({ event: 'directory', version, path: url.pathname, invalid, tls: !!req.socket.encrypted });
    if (invalid) return send(res, 200, { name: 'missing-owner', plugins: [] });
    const stock = entry('inventory-helper', '库存速查', '工作流', '查阅公开库存数量与版本', version);
    const review = entry('review-notes', '审阅笔记', '开发', '公开审阅清单', '1.0.0', false);
    const corrupt = { name: 'checksum-test', displayName: '摘要不符样例', category: '检查', version: '1.0.0',
      source: { source: 'archive', url: origin + '/bad-checksum.zip', sha256: '0'.repeat(64) } };
    const external = { name: 'source-not-supported', displayName: '其他来源样例', category: '开发', source: { source: 'npm', package: 'never-requested' } };
    const github = { name: 'repo-workflow', displayName: '仓库工作流', category: '开发', version,
      source: { source: 'github', repo: 'fixture-lab/extensions', ref: 'release/inventory' } };
    const explicit = { name: 'repo-stock', displayName: '固定提交的仓库库存', category: '工作流', version: '1.0.0',
      source: { source: 'git-subdir', url: 'https://github.com/fixture-lab/extensions.git', ref: 'removed-branch', sha: revisions[0].commit, path: 'plugins/repo-stock' } };
    const primary = url.pathname === '/marketplace.json';
    return send(res, 200, { name: primary ? 'public-plugin-market' : 'different-market',
      owner: { name: primary ? '公开样例目录' : '另一公开目录' }, plugins: primary ? [stock, review, corrupt, external, github, explicit] : [stock, review] });
  }
  const filename = url.pathname.slice(1);
  if (['inventory-helper-1.0.0.zip', 'inventory-helper-2.0.0.zip', 'review-notes-1.0.0.zip', 'bad-checksum.zip'].includes(filename)) {
    const data = archive(filename === 'bad-checksum.zip' ? 'review-notes-1.0.0.zip' : filename);
    log({ event: 'archive', name: filename, sha256: createHash('sha256').update(data).digest('hex'), tls: !!req.socket.encrypted,
      credentialHeader });
    return sendZip(res, data);
  }
  log({ event: 'unknown-path', path: url.pathname }); return send(res, 404, {});
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
origin = `https://localhost:${server.address().port}`;
writeFileSync(path.join(root, 'ready.json'), JSON.stringify({ pid: process.pid, origin }) + '\n');
process.on('SIGTERM', () => { server.closeAllConnections(); server.close(() => process.exit(0)); });

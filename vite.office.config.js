import { defineConfig } from 'vite';
import { readFile, readdir } from 'node:fs/promises';
import path from 'node:path';

export default defineConfig({
  root: 'office', base: './',
  build: { outDir: '../dist/office', emptyOutDir: true, target: 'safari17', assetsInlineLimit: 0, sourcemap: false },
  // Dynamic chunks that import their worker entry re-evaluate it in WebKit,
  // resetting its open document. Keep each worker's code in one module.
  worker: { format: 'es', rolldownOptions: { output: { codeSplitting: false } } },
  plugins: [{
    name: 'office-license-notices',
    async generateBundle() {
      const packages = new Set();
      for (const id of this.getModuleIds()) {
        const match = id.replaceAll('\\', '/').match(/^(.*\/node_modules\/(?:@[^/]+\/)?[^/]+)\//);
        if (match) packages.add(match[1]);
      }
      const notices = [];
      for (const directory of [...packages].sort()) {
        const manifest = JSON.parse(await readFile(path.join(directory, 'package.json'), 'utf8'));
        const entries = await readdir(directory);
        const files = entries.filter(name => /^(license|licence|copying|notice|third-party-notices)(\.|$)/i.test(name));
        if (entries.includes('LICENSES')) for (const file of await readdir(path.join(directory, 'LICENSES'), { withFileTypes: true })) {
          if (file.isFile()) files.push(path.join('LICENSES', file.name));
        }
        const licenses = await Promise.all(files.map(name => readFile(path.join(directory, name), 'utf8')));
        notices.push(`${manifest.name} ${manifest.version}\n${manifest.license ?? ''}\n${licenses.join('\n')}`);
      }
      this.emitFile({ type: 'asset', fileName: 'THIRD-PARTY-NOTICES.txt', source: notices.join('\n\n----------------\n\n') });
    },
  }],
});

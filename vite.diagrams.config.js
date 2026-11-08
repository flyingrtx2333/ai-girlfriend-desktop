import { defineConfig } from 'vite';
import { readFile, readdir } from 'node:fs/promises';
import path from 'node:path';

export default defineConfig({
  publicDir: false,
  define: { 'process.env.NODE_ENV': '"production"' },
  build: {
    outDir: 'dist/diagrams', emptyOutDir: true, target: 'safari17', assetsInlineLimit: 0,
    lib: { entry: 'diagrams/runtime.js', name: 'BlueFatFishDiagrams', formats: ['iife'], fileName: () => 'runtime.js', cssFileName: 'style' },
    rolldownOptions: { output: { codeSplitting: false } },
  },
  plugins: [{
    name: 'diagram-license-notices',
    async generateBundle() {
      const packages = new Set();
      for (const id of this.getModuleIds()) {
        const match = id.replaceAll('\\', '/').match(/^(.*\/node_modules\/(?:@[^/]+\/)?[^/]+)\//);
        if (match) packages.add(match[1]);
      }
      const notices = [];
      for (const directory of [...packages].sort()) {
        const manifest = JSON.parse(await readFile(path.join(directory, 'package.json'), 'utf8'));
        const names = (await readdir(directory)).filter(name => /^(license|licence|copying|notice)(\.|$)/i.test(name));
        const licenses = await Promise.all(names.map(name => readFile(path.join(directory, name), 'utf8')));
        notices.push(`${manifest.name} ${manifest.version}\n${manifest.license ?? ''}\n${licenses.join('\n')}`);
      }
      this.emitFile({ type: 'asset', fileName: 'THIRD-PARTY-NOTICES.txt', source: notices.join('\n\n----------------\n\n') });
    },
  }],
});

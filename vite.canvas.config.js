import { defineConfig } from 'vite';
import { readFile, readdir } from 'node:fs/promises';
import path from 'node:path';

export default defineConfig({
  define: { 'process.env.NODE_ENV': '"production"' },
  build: {
    outDir: 'dist/canvas', emptyOutDir: true, target: 'safari17',
    lib: { entry: 'canvas/runtime.tsx', name: 'BlueFatFishCanvas', formats: ['iife'], fileName: () => 'runtime.js', cssFileName: 'style' },
  },
  plugins: [{
    name: 'canvas-license-notices',
    async generateBundle() {
      const packages = new Set();
      for (const id of this.getModuleIds()) {
        const match = id.replaceAll('\\', '/').match(/^(.*\/node_modules\/(?:@[^/]+\/)?[^/]+)\//);
        if (match) packages.add(match[1]);
      }
      const notices = [];
      for (const directory of [...packages].sort()) {
        const manifest = JSON.parse(await readFile(path.join(directory, 'package.json'), 'utf8'));
        const files = (await readdir(directory)).filter(name => /^(license|licence|copying|notice)(\.|$)/i.test(name));
        const licenses = await Promise.all(files.map(name => readFile(path.join(directory, name), 'utf8')));
        notices.push(`${manifest.name} ${manifest.version}\n${manifest.license ?? ''}\n${licenses.join('\n')}`);
      }
      this.emitFile({ type: 'asset', fileName: 'THIRD-PARTY-NOTICES.txt', source: notices.join('\n\n----------------\n\n') });
    },
  }],
});

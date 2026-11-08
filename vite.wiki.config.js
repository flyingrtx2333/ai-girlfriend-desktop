import { defineConfig } from 'vite';
import { readFile } from 'node:fs/promises';

export default defineConfig({
  publicDir: false,
  build: {
    outDir: 'dist/wiki', emptyOutDir: true, target: 'safari17',
    lib: { entry: 'wiki/runtime.js', name: 'BlueFatFishWikiYAML', formats: ['iife'], fileName: () => 'runtime.js' },
    rolldownOptions: { output: { codeSplitting: false } },
  },
  plugins: [{ name: 'wiki-yaml-license', async generateBundle() {
    const manifest = JSON.parse(await readFile('node_modules/yaml/package.json', 'utf8'));
    this.emitFile({ type: 'asset', fileName: 'THIRD-PARTY-NOTICES.txt', source: `${manifest.name} ${manifest.version}\n${manifest.license}\n${await readFile('node_modules/yaml/LICENSE', 'utf8')}` });
  } }],
});

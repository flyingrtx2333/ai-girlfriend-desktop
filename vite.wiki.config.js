import { defineConfig } from 'vite';
import { readFile } from 'node:fs/promises';

export default defineConfig({
  publicDir: false,
  // JavaScriptCore has no DOM. Select the pure JavaScript entity decoder.
  resolve: { conditions: ['worker'] },
  build: {
    outDir: 'dist/wiki', emptyOutDir: true, target: 'safari17',
    lib: { entry: 'wiki/runtime.js', name: 'BlueFatFishWikiYAML', formats: ['iife'], fileName: () => 'runtime.js' },
    rolldownOptions: { output: { codeSplitting: false } },
  },
  plugins: [{ name: 'wiki-parser-licenses', async generateBundle() {
    const packages = new Set([...this.getModuleIds()].flatMap(id => {
      const name = id.split('/node_modules/')[1]; return name ? [name.split('/').slice(0, name.startsWith('@') ? 2 : 1).join('/')] : [];
    }));
    const notices = new Map();
    for (const name of [...packages].sort()) {
      const manifest = JSON.parse(await readFile(`node_modules/${name}/package.json`, 'utf8')); let license;
      for (const file of ['LICENSE', 'license', 'LICENSE.md', 'license.md', 'LICENSE.txt', 'license.txt']) {
        try { license = await readFile(`node_modules/${name}/${file}`, 'utf8'); break; } catch (error) { if (error.code !== 'ENOENT') throw error; }
      }
      if (!license) throw Error('Missing bundled license for ' + name);
      const entry = `${manifest.name} ${manifest.version} (${manifest.license})`; notices.set(license, [...(notices.get(license) ?? []), entry]);
    }
    this.emitFile({ type: 'asset', fileName: 'THIRD-PARTY-NOTICES.txt', source: [...notices].map(([license, names]) => names.join('\n') + '\n\n' + license).join('\n\n') });
  } }],
});

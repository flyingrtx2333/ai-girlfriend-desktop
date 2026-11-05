// Offline model LOD. Geometry and vertex colors stay in ordinary glTF; no runtime decoder.
import { NodeIO } from '@gltf-transform/core';
import { MeshoptSimplifier } from 'meshoptimizer';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';

const input = process.argv[2];
if (!input) throw new Error('Pass the original deep-whale-maid v0.5.0 GLB path.');
const original = await readFile(input);
const originalSha = createHash('sha256').update(original).digest('hex');
if (originalSha !== '91a7fdc50aecc65685c81075afd9d0bcf6923c75ee5d09067013706052ac3a4f') throw new Error('Unexpected source model.');
await MeshoptSimplifier.ready;
const io = new NodeIO();
const document = await io.read(input);
let before = 0, after = 0;
for (const mesh of document.getRoot().listMeshes()) {
  const facial = /cranium|orbital|lash|lip|smile|eyelid|brow/i.test(mesh.getName());
  for (const primitive of mesh.listPrimitives()) {
    const positions = primitive.getAttribute('POSITION');
    let indices = new Uint32Array(primitive.getIndices().getArray());
    before += indices.length / 3;
    if (indices.length > 1500) {
      const target = Math.max(300, Math.floor(indices.length * (facial ? .5 : .16) / 3) * 3);
      const colors = primitive.getAttribute('COLOR_0');
      if (colors) {
        const values = new Float32Array(colors.getCount() * colors.getElementSize());
        const element = [];
        for (let i = 0; i < colors.getCount(); i++) values.set(colors.getElement(i, element), i * colors.getElementSize());
        [indices] = MeshoptSimplifier.simplifyWithAttributes(indices, positions.getArray(), 3, values, colors.getElementSize(), Array(colors.getElementSize()).fill(1), null, target, facial ? .0008 : .003, ['LockBorder']);
      } else {
        [indices] = MeshoptSimplifier.simplify(indices, positions.getArray(), 3, target, facial ? .0008 : .003, ['LockBorder']);
      }
    }
    after += indices.length / 3;
    const [remap, count] = MeshoptSimplifier.compactMesh(indices);
    for (const semantic of primitive.listSemantics()) {
      const attribute = primitive.getAttribute(semantic);
      const old = attribute.getArray(), stride = attribute.getElementSize();
      const compact = new old.constructor(count * stride);
      for (let i = 0; i < remap.length; i++) if (remap[i] !== 0xffffffff) compact.set(old.subarray(i * stride, i * stride + stride), remap[i] * stride);
      primitive.setAttribute(semantic, attribute.clone().setArray(compact));
    }
    primitive.setIndices(primitive.getIndices().clone().setArray(indices));
  }
}
for (const accessor of document.getRoot().listAccessors()) {
  if (accessor.listParents().every(parent => parent.propertyType === 'Root')) accessor.dispose();
}
const destination = 'public/models/whale-maid';
await mkdir(destination, { recursive: true });
const output = `${destination}/whale-maid-mobile.glb`;
await io.write(output, document);
const bytes = await readFile(output);
const report = { source: 'https://github.com/SelinLee/ai-moe-atlas/tree/main/public/models/deep-whale-maid/v0.5.0', license: 'CC BY-NC-SA 4.0', sourceSha256: originalSha, outputSha256: createHash('sha256').update(bytes).digest('hex'), sourceBytes: original.length, outputBytes: bytes.length, sourceTriangles: before, outputTriangles: after, proportions: 'Original chibi geometry preserved; no nonuniform body scaling.' };
await writeFile(`${destination}/source.json`, JSON.stringify(report, null, 2) + '\n');
console.log(JSON.stringify(report, null, 2));

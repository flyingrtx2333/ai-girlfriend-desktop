import assert from 'node:assert/strict';
import { mkdir, writeFile } from 'node:fs/promises';
import { chromium } from 'playwright';
import { NodeIO } from '@gltf-transform/core';

// Eye-specific proof: use the production loader/materials and inspect the actual
// rendered irises, floating fragments and bangs through the closure sequence.
await mkdir('evidence/edition14', { recursive: true });
const io = new NodeIO();
const raw = await io.read('assets/whale-maid-v2-rigged/tripo-out/whale-maid-v2-rig-rig-6cff3b31/model.glb');
const final = await io.read('public/models/whale-maid-v2/whale-maid-rigged.glb');
const primitive = doc => doc.getRoot().listMeshes()[0].listPrimitives()[0];
assert.equal(primitive(final).listTargets().length, 0, 'Blinking must not deform the body or bangs.');
assert.deepEqual(primitive(final).getAttribute('POSITION').getArray(), primitive(raw).getAttribute('POSITION').getArray());

const browser = await chromium.launch({ channel: 'chrome', headless: true });
try {
  const page = await browser.newPage({ viewport: { width: 1000, height: 800 }, deviceScaleFactor: 1 });
  const errors = [];
  page.on('pageerror', e => errors.push(e.message));
  page.on('console', msg => { if (msg.type() === 'error') errors.push(msg.text()); });
  await page.route('http://127.0.0.1:4173/', r => r.fulfill({ contentType: 'text/html', body: '<!doctype html><body style="margin:0;background:#f4e9e4"></body>' }));
  await page.goto('http://127.0.0.1:4173/');
  const proof = await page.evaluate(async () => {
    const T = await import('/node_modules/three/build/three.module.js');
    const { loadWhaleMaid } = await import('/src/character.js');
    const { lightCharacter } = await import('/src/lighting.js');
    const renderer = new T.WebGLRenderer({ antialias: true, alpha: true, preserveDrawingBuffer: true });
    renderer.setSize(1000, 800); document.body.append(renderer.domElement);
    const scene = new T.Scene(); lightCharacter(scene, renderer);
    const camera = new T.PerspectiveCamera(33, 1.25, .1, 50);
    camera.position.set(0, .88, 3.3); camera.lookAt(0, .91, 0);
    const character = await loadWhaleMaid(); scene.add(character.root);
    const state = { time: 0, motion: 0, happy: false, shock: 0, dragging: false, looking: false, pointer: { x: 0, y: 0 }, blinking: false, volume: 0 };
    const frame = (left, right, turn = 0) => {
      for (let i = 0; i < 90; i++) character.update(1 / 60, { ...state, looking: !!turn, pointer: { x: turn, y: 0 } });
      character.root.traverse(m => {
        if (m.morphTargetDictionary) {
          m.morphTargetInfluences[m.morphTargetDictionary.blinkLeft] = left;
          m.morphTargetInfluences[m.morphTargetDictionary.blinkRight] = right;
        }
        m.material?.userData.blinkUniform?.value.set(left, right);
      });
      renderer.render(scene, camera);
      const gl = renderer.getContext(), pixels = new Uint8Array(1000 * 800 * 4);
      gl.readPixels(0, 0, 1000, 800, gl.RGBA, gl.UNSIGNED_BYTE, pixels);
      return pixels;
    };
    const count = (pixels, rect, predicate) => {
      let n = 0;
      for (let y = rect[1]; y < rect[3]; y++) for (let x = rect[0]; x < rect[2]; x++) {
        const p = ((799 - y) * 1000 + x) * 4;
        if (predicate(pixels[p], pixels[p + 1], pixels[p + 2])) n++;
      }
      return n;
    };
    const irises = pixels => [[265, 490, 370, 598], [520, 490, 628, 598]].map(rect => count(pixels, rect, (r, g, b) => b > r * 1.25 && b > g * 1.1 && r < 160));
    const open = frame(0, 0), half = frame(.5, .5), closed = frame(1, 1), wink = frame(1, 0);
    let hairDifference = 0, hairPixels = 0;
    for (let y = 250; y < 545; y++) for (let x = 400; x < 505; x++) {
      const i = ((799 - y) * 1000 + x) * 4;
      if (open[i + 2] > open[i] * 1.25) {
        hairPixels++;
        hairDifference += Math.abs(open[i] - closed[i]) + Math.abs(open[i + 1] - closed[i + 1]) + Math.abs(open[i + 2] - closed[i + 2]);
      }
    }
    const floatingFragments = count(half, [230, 465, 355, 504], (r, g, b) => r < 160 && g < 130 && b < 120 && r > b * 1.25);
    window.__eyeFrame = frame;
    return { open: irises(open), half: irises(half), closed: irises(closed), wink: irises(wink), floatingFragments, hairPixelDifference: hairDifference / (hairPixels * 3) };
  });
  for (const [name, left, right, turn] of [['open', 0, 0, 0], ['half', .5, .5, 0], ['closed', 1, 1, 0], ['wink', 1, 0, 0], ['turned', 1, 1, 1], ['turned-left', 1, 1, -1]]) {
    await page.evaluate(([left, right, turn]) => window.__eyeFrame(left, right, turn), [left, right, turn]);
    await page.screenshot({ path: `evidence/edition14/after-${name}.png` });
  }
  await writeFile('evidence/edition14/eyes-check.json', JSON.stringify({ ...proof, sourceGeometryUnchanged: true, errors }, null, 2));
  assert.deepEqual(errors, []);
  for (let i = 0; i < 2; i++) {
    assert(proof.open[i] > 1000, 'An open iris must render.');
    assert(proof.half[i] > 100 && proof.half[i] < proof.open[i] * .8, 'Half closure must occlude the iris.');
    assert(proof.closed[i] < proof.open[i] * .02, 'A closed lid must hide the iris.');
  }
  assert(proof.wink[0] < proof.open[0] * .02 && Math.abs(proof.wink[1] - proof.open[1]) < 10, 'The two eyelids must work independently.');
  assert(proof.floatingFragments < 5, 'Old lash fragments must not float above the moving lid.');
  assert(proof.hairPixelDifference < .25, 'Blinks must preserve the bangs.');
  console.log(JSON.stringify(proof, null, 2));
} finally { await browser.close(); }

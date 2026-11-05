import assert from 'node:assert/strict';
import { writeFile } from 'node:fs/promises';
import { chromium } from 'playwright';

const browser = await chromium.launch({ channel: 'chrome', headless: true });
try {
  const page = await browser.newPage({ viewport: { width: 1000, height: 900 }, deviceScaleFactor: 1 });
  const errors = [];
  page.on('pageerror', e => errors.push(e.message));
  page.on('console', m => { if (m.type() === 'error') errors.push(m.text()); });
  await page.route('http://127.0.0.1:4173/', r => r.fulfill({ contentType: 'text/html', body: '<!doctype html><body style="margin:0;background:#f4e9e4"></body>' }));
  await page.goto('http://127.0.0.1:4173/');
  const proof = await page.evaluate(async () => {
    const T = await import('/node_modules/three/build/three.module.js');
    const { loadPortrait } = await import('/src/portrait.js');
    const renderer = new T.WebGLRenderer({ antialias: true, alpha: true, preserveDrawingBuffer: true });
    renderer.outputColorSpace = T.SRGBColorSpace; renderer.setSize(1000, 900); document.body.append(renderer.domElement);
    const scene = new T.Scene(), camera = new T.PerspectiveCamera(33, 1000 / 900, .1, 50);
    camera.position.set(0, .35, 4.8); camera.lookAt(0, .75, 0);
    const character = await loadPortrait(); scene.add(character.root);
    const base = { time: 0, motion: 0, happy: false, shock: 0, dragging: false, looking: false, pointer: { x: 0, y: 0 }, blinking: false, volume: 0 };
    function frame(extra = {}) {
      for (let i = 0; i < 60; i++) character.update(1 / 60, { ...base, ...extra });
      renderer.render(scene, camera);
      const gl = renderer.getContext(), pixels = new Uint8Array(1000 * 900 * 4);
      gl.readPixels(0, 0, 1000, 900, gl.RGBA, gl.UNSIGNED_BYTE, pixels); return pixels;
    }
    const project = (x, y) => {
      const v = new T.Vector3((x - 627) * 3.7 / 1205, 2 - y * 3.7 / 1205, 0).project(camera);
      return [Math.round((v.x + 1) * 500), Math.round((1 - v.y) * 450)];
    };
    const rect = ([x0, y0, x1, y1]) => [...project(x0, y0), ...project(x1, y1)];
    function count(pixels, sourceRect, predicate) {
      const [x0, y0, x1, y1] = rect(sourceRect); let n = 0;
      for (let y = y0; y < y1; y++) for (let x = x0; x < x1; x++) {
        const i = ((899 - y) * 1000 + x) * 4;
        if (predicate(pixels[i], pixels[i + 1], pixels[i + 2])) n++;
      } return n;
    }
    const iris = pixels => [[494, 417, 574, 493], [671, 395, 751, 471]].map(r => count(pixels, r, (r, g, b) => b > r * 1.2 && b > g * 1.08 && r < 190));
    const mouth = pixels => count(pixels, [603, 489, 653, 525], (r, g, b) => r < 160 && g < 120 && b < 140);
    function mouthBounds(pixels) {
      const [x0, y0, x1, y1] = rect([603, 489, 653, 525]);
      let left = x1, right = x0, top = y1, bottom = y0;
      for (let y = y0; y < y1; y++) for (let x = x0; x < x1; x++) {
        const i = ((899 - y) * 1000 + x) * 4;
        if (pixels[i] < 160 && pixels[i + 1] < 120 && pixels[i + 2] < 140) { left = Math.min(left, x); right = Math.max(right, x); top = Math.min(top, y); bottom = Math.max(bottom, y); }
      }
      return { width: right - left + 1, height: bottom - top + 1 };
    }
    const open = frame(), half = frame({ blinkAmount: .5 }), closed = frame({ blinking: true }), restored = frame(), speaking = frame({ volume: .5 });
    const mouthShapes = {
      wide: mouthBounds(frame({ volume: .5, vowels: { ee: 1, ou: 0 } })),
      round: mouthBounds(frame({ volume: .5, vowels: { ee: 0, ou: 1 } })),
      stopped: mouth(frame()),
    };
    const reference = new Image(); reference.src = '/design/references/whale-maid-finish-target.png'; await reference.decode();
    const canvas = document.createElement('canvas'); canvas.width = canvas.height = 1254;
    const context = canvas.getContext('2d', { willReadFrequently: true }); context.drawImage(reference, 0, 0);
    const raw = context.getImageData(0, 0, 1254, 1254).data;
    const samples = [[520, 300], [720, 320], [630, 487], [555, 522], [690, 510], [550, 690], [650, 740]];
    const sourceError = samples.map(([x, y]) => {
      const [sx, sy] = project(x, y), i = ((899 - sy) * 1000 + sx) * 4, j = (y * 1254 + x) * 4;
      return [0, 1, 2].reduce((sum, c) => sum + Math.abs(open[i + c] - raw[j + c]), 0) / 3;
    });
    const live = frame({ time: 2.3, motion: 1 });
    const regions = { hair: [270, 550, 440, 780], chest: [490, 605, 760, 735], hands: [540, 750, 710, 842], tail: [870, 810, 1047, 990] };
    const movement = {};
    for (const [name, sourceRect] of Object.entries(regions)) {
      const [x0, y0, x1, y1] = rect(sourceRect); let total = 0, n = 0;
      for (let y = Math.max(0, y0); y < Math.min(900, y1); y++) for (let x = Math.max(0, x0); x < Math.min(1000, x1); x++) {
        const i = ((899 - y) * 1000 + x) * 4;
        total += Math.abs(live[i] - open[i]) + Math.abs(live[i + 1] - open[i + 1]) + Math.abs(live[i + 2] - open[i + 2]); n += 3;
      } movement[name] = total / n;
    }
    const face = { open: iris(open), half: iris(half), closed: iris(closed), restored: iris(restored), mouth: { idle: mouth(open), speaking: mouth(speaking), ...mouthShapes } };
    camera.position.set(0, .08, 8.4); camera.lookAt(0, .08, 0);
    for (let i = 0; i < 180; i++) character.update(1 / 60, base);
    const layeredNeutral = frame();
    const layerSamples = [[883, 833], [1012, 825], [918, 910], [867, 965], [568, 1188], [662, 1188]];
    const layerSourceErrors = layerSamples.map(([x, y]) => {
      const [sx, sy] = project(x, y), i = ((899 - sy) * 1000 + sx) * 4, j = (y * 1254 + x) * 4;
      return [0, 1, 2].reduce((sum, c) => sum + Math.abs(layeredNeutral[i + c] - raw[j + c]), 0) / 3;
    });
    // Read the production vertex deformation back from the GPU at fixed source
    // coordinates. This separates local movement from a whole-image translation.
    let probeUniforms;
    for (const name of ['AnimatedPortrait', 'PortraitTail']) {
      const mesh = character.root.getObjectByName(name), compile = mesh.material.onBeforeCompile;
      mesh.material.onBeforeCompile = shader => {
        compile(shader); probeUniforms = shader.uniforms;
        shader.vertexShader = shader.vertexShader.replace('#include <common>', '#include <common>\nvarying vec2 vRecordedMotion;')
          .replace('#include <project_vertex>', 'vRecordedMotion = moved - pixel; transformed.xy -= vec2(moved.x - pixel.x, pixel.y - moved.y) * (3.7 / 1205.0);\n#include <project_vertex>');
        shader.fragmentShader = `varying vec2 vRecordedMotion; varying vec2 vMapUv;
          uniform sampler2D map; uniform sampler2D uTailMask;
          void main() { vec2 mask = texture2D(uTailMask, vMapUv).rg;
            float alpha = texture2D(map, vMapUv).a * ${name === 'PortraitTail' ? 'mask.g' : '(1.0 - mask.r)'};
            if (alpha < 0.02) discard;
            gl_FragColor = vec4(vec2(0.5) + vRecordedMotion / 80.0, 0.0, 1.0); }`;
      };
      mesh.material.customProgramCacheKey = () => `portrait-motion-readback-18-${name}`; mesh.material.needsUpdate = true;
    }
    const markers = {
      head: [627, 470], waist: [627, 742], chest: [628, 665], bow: [625, 630],
      fringe: [614, 316], ahoge: [440, 75], hairLeft: [313, 659], hairLeftInner: [413, 682], hairRightInner: [837, 676], hairRight: [941, 639],
      sleeveLeft: [493, 695], sleeveRight: [752, 686], handLeft: [589, 792], handRight: [654, 790],
      cuffLeft: [551, 765], cuffRight: [687, 765], hemLeft: [423, 940], hemRight: [795, 943], apron: [628, 883],
      tailRoot: [872, 963], tailFin: [1024, 812], footLeft: [565, 1165], footRight: [669, 1162],
    };
    const trajectories = Object.fromEntries(Object.keys(markers).map(name => [name, []]));
    const pixels = new Uint8Array(1000 * 900 * 4), gl = renderer.getContext();
    for (let i = 0; i < 960; i++) {
      character.update(1 / 60, { ...base, time: i / 60, motion: 1 });
      if (i % 6) continue;
      renderer.render(scene, camera); gl.readPixels(0, 0, 1000, 900, gl.RGBA, gl.UNSIGNED_BYTE, pixels);
      for (const [name, source] of Object.entries(markers)) {
        const [x, y] = project(...source), j = ((899 - y) * 1000 + x) * 4;
        trajectories[name].push([(pixels[j] / 255 - .5) * 80, (pixels[j + 1] / 255 - .5) * 80]);
      }
    }
    const span = (name, anchor = 'waist') => {
      const path = trajectories[name].map((p, i) => p.map((v, axis) => v - trajectories[anchor][i][axis]));
      return Math.hypot(...[0, 1].map(axis => Math.max(...path.map(p => p[axis])) - Math.min(...path.map(p => p[axis]))));
    };
    const localMotion = Object.fromEntries(Object.keys(markers).filter(n => !['head', 'waist', 'footLeft', 'footRight'].includes(n))
      .map(name => [name, span(name, ['fringe', 'ahoge', 'hairLeft', 'hairRight', 'hairLeftInner', 'hairRightInner'].includes(name) ? 'head' : 'waist')]));
    const footDrift = ['footLeft', 'footRight'].map(name => Math.hypot(...[0, 1].map(axis => Math.max(...trajectories[name].map(p => p[axis])) - Math.min(...trajectories[name].map(p => p[axis])))));
    // Compare the same rendered frame with only the new small controls zeroed.
    // Float readback preserves subpixel finger motion without amplifying it.
    const target = new T.WebGLRenderTarget(1000, 900, { type: T.FloatType, depthBuffer: false });
    const fineControls = {};
    for (const phase of [2.9, 3.8]) {
      for (let i = 0; i < 90; i++) character.update(1 / 60, { ...base, time: phase, motion: 1 });
      for (const [uniform, points] of [
      ['uFingers', [[591, 825], [615, 810], [637, 810], [646, 825]]],
      ['uFinTips', [[896, 827], [1024, 825]]],
      ['uHairTips', [[344, 774], [465, 622], [793, 626], [909, 742]]],
    ]) {
      const saved = probeUniforms[uniform].value.clone();
      const sample = () => {
        renderer.setRenderTarget(target); renderer.render(scene, camera);
        return points.map(p => { const [x, y] = project(...p), color = new Float32Array(4);
          renderer.readRenderTargetPixels(target, x, 899 - y, 1, 1, color); return [...color]; });
      };
      const active = sample(); probeUniforms[uniform].value.multiplyScalar(0); const disabled = sample();
      probeUniforms[uniform].value.copy(saved);
        const differences = active.map((p, i) => Math.hypot(p[0] - disabled[i][0], p[1] - disabled[i][1]) * 80);
        fineControls[uniform] = differences.map((d, i) => Math.max(d, fineControls[uniform]?.[i] ?? 0));
      }
    }
    renderer.setRenderTarget(null); target.dispose();
    return { ...face, meanSourcePixelError: sourceError.reduce((a, b) => a + b, 0) / sourceError.length, sourceErrors: sourceError, layerSourceErrors, movement, localMotionSourcePixels: localMotion, footDriftSourcePixels: footDrift, fineControlSourcePixels: fineControls };
  });
  for (let i = 0; i < 2; i++) {
    assert(proof.open[i] > 1000, 'Reference irises must render.');
    assert(proof.closed[i] < proof.open[i] * .03, 'Closed lids must cover the irises.');
    assert(proof.half[i] > proof.closed[i] && proof.half[i] < proof.open[i] * .7, 'Half lids must cover part of each iris.');
    assert(Math.abs(proof.restored[i] - proof.open[i]) < 10, 'The original eyes must restore.');
  }
  assert(proof.meanSourcePixelError < 8, 'Neutral colors must match the supplied reference.');
  assert(proof.mouth.speaking > proof.mouth.idle + 40, 'Speech must visibly open the mouth.');
  assert(proof.mouth.wide.width > proof.mouth.round.width * 1.4 && proof.mouth.round.height > proof.mouth.wide.height, 'Wide and round vowels must render different contours.');
  assert(proof.mouth.stopped < 10, 'Silence must restore the reference lips.');
  for (const [name, difference] of Object.entries(proof.movement)) assert(difference > .1, `${name} must keep moving.`);
  for (const [name, span] of Object.entries(proof.localMotionSourcePixels)) assert(span > .4, `${name} must move independently of its body anchor.`);
  assert(proof.footDriftSourcePixels.every(d => d < .35), 'Idle must leave both feet planted.');
  if (proof.layerSourceErrors.some(d => d >= 12)) console.log({ layerSourceErrors: proof.layerSourceErrors, fineControls: proof.fineControlSourcePixels });
  assert(proof.layerSourceErrors.every(d => d < 12), 'Tail layering and feet must preserve neutral reference colors.');
  for (const [name, differences] of Object.entries(proof.fineControlSourcePixels)) assert(differences.every(d => d > .03), `${name} must add actual local movement.`);

  await page.unroute('http://127.0.0.1:4173/');
  await page.addInitScript(() => {
    const create = AudioContext.prototype.createMediaElementSource;
    AudioContext.prototype.createMediaElementSource = function (media) { window.__voice = media; return create.call(this, media); };
  });
  await page.goto('http://127.0.0.1:4173/', { waitUntil: 'domcontentloaded' });
  await page.waitForFunction(() => document.querySelector('#app')?.dataset.appearance === 'portrait' && !document.querySelector('#appearance').disabled);
  assert.equal(await page.locator('#app').getAttribute('data-appearance'), 'portrait');
  await page.locator('#appearance').click();
  await page.waitForFunction(() => document.querySelector('#app').dataset.appearance === 'model' && !document.querySelector('#appearance').disabled);
  assert.equal(await page.locator('#motion-menu button:not([hidden])').count(), 16);
  await page.locator('#appearance').click();
  await page.waitForFunction(() => document.querySelector('#app').dataset.appearance === 'portrait');
  assert.equal(await page.locator('#motion-menu button:not([hidden])').count(), 9);
  assert.equal(await page.locator('#stage canvas').count(), 1);
  await page.locator('[data-action=speak]').click();
  await page.waitForFunction(() => window.__voice?.currentTime > .7 && !window.__voice.paused);
  await page.screenshot({ path: 'evidence/edition18/ui-speaking.png' });
  await page.locator('[data-action=speak]').click();
  await page.mouse.move(500, 330); await page.mouse.down(); await page.mouse.move(570, 290, { steps: 8 });
  await page.getByText('被拎起来了', { exact: true }).waitFor(); await page.mouse.up(); await page.locator('#reset').click();
  assert.deepEqual(errors, []);
  // Save evidence after interaction: Vite watches files inside this project.
  await writeFile('evidence/edition18/render-check.json', JSON.stringify(proof, null, 2) + '\n');
  console.log(JSON.stringify({ ...proof, ui: 'appearance switch, real audio and drag passed', errors }, null, 2));
} finally { await browser.close(); }

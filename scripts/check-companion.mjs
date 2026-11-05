import assert from 'node:assert/strict';
import { mkdir, writeFile } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import { chromium } from 'playwright';

const output = 'evidence/edition25'; await mkdir(output, { recursive: true });
const browser = await chromium.launch({ channel: 'chrome', headless: true });
try {
  const page = await browser.newPage({ viewport: { width: 204, height: 288 }, deviceScaleFactor: 1.5 });
  const errors = []; page.on('pageerror', e => errors.push(e.message));
  await page.addInitScript(() => {
    window.whaleNative = { post() {} };
    window.whaleNativeReceive = message => window.dispatchEvent(new CustomEvent('whale-native', { detail: message }));
  });
  await page.goto('http://127.0.0.1:4173/');
  await page.waitForFunction(() => window.whaleDiagnostics?.().frames > 30);
  const input = await page.evaluate(async () => {
    const stage = document.querySelector('#stage'), rect = stage.getBoundingClientRect();
    // DOM event fixture only. OS capture is owned by AppKit in production;
    // simulate its delayed release without pretending to move the real mouse.
    stage.setPointerCapture = () => {}; stage.hasPointerCapture = () => false;
    const event = (type, id, y) => stage.dispatchEvent(new PointerEvent(type, { bubbles: true, pointerId: id, button: 0,
      clientX: rect.left + rect.width * .5, clientY: rect.top + rect.height * y, screenX: 500, screenY: 300 }));
    const snapshot = () => structuredClone(window.whaleDiagnostics());
    const before = snapshot();
    event('pointerdown', 101, .3); event('lostpointercapture', 101, .3);
    const cancelled = snapshot();
    window.whaleNativeReceive({ type: 'dragEnd', payload: { moved: false } });
    const head = snapshot();
    window.whaleNativeReceive({ type: 'dragEnd', payload: { moved: false } });
    const duplicate = snapshot();
    await new Promise(r => setTimeout(r, 850));
    const pat = snapshot();
    event('pointerdown', 102, .61); event('pointerup', 102, .61);
    const pendingBody = snapshot();
    window.whaleNativeReceive({ type: 'dragEnd', payload: { moved: false } });
    const body = snapshot();
    await new Promise(r => setTimeout(r, 230)); const flinch = snapshot();
    event('pointerdown', 103, .3);
    window.whaleNativeReceive({ type: 'translation', payload: { x: .5, y: .2, held: true, moved: true } });
    window.whaleNativeReceive({ type: 'dragEnd', payload: { moved: true } });
    const moved = snapshot();
    return { before: before.interaction, cancelled: cancelled.interaction, head: head.interaction, duplicate: duplicate.interaction,
      pendingBody: pendingBody.interaction, body: body.interaction, moved: moved.interaction,
      patExpression: pat.expression, flinchExpression: flinch.expression, drawCalls: flinch.drawCalls, triangles: flinch.triangles };
  });
  assert.equal(input.cancelled.count, input.before.count, 'Lost WebKit capture must wait for the physical host release.');
  assert.equal(input.head.kind, 'happy'); assert.equal(input.head.zone, 'head');
  assert.equal(input.head.count, input.before.count + 1); assert.equal(input.duplicate.count, input.head.count);
  assert.equal(input.pendingBody.count, input.head.count); assert.equal(input.body.kind, 'startled'); assert.equal(input.body.zone, 'body');
  assert.equal(input.moved.count, input.body.count, 'A drag must not fire a touch reaction.');
  assert.equal(input.patExpression.action, 'pet'); assert(input.patExpression.eyes[0] > .6);
  assert.equal(input.flinchExpression.action, 'startle'); assert(input.flinchExpression.opening > .2);
  assert.equal(input.drawCalls, 2); assert(input.triangles < 60000);

  await page.route('http://127.0.0.1:4173/animation-proof', r => r.fulfill({ contentType: 'text/html', body: '<body style="margin:0"></body>' }));
  await page.goto('http://127.0.0.1:4173/animation-proof');
  const visual = await page.evaluate(async () => {
    const T = await import('/node_modules/three/build/three.module.js'), { loadPortrait } = await import('/src/portrait.js');
    const renderer = new T.WebGLRenderer({ alpha: true, antialias: true, preserveDrawingBuffer: true });
    renderer.setSize(408, 576); renderer.setPixelRatio(1.5); renderer.outputColorSpace = T.SRGBColorSpace;
    const camera = new T.PerspectiveCamera(33, 204 / 288, .1, 60); camera.position.set(0, .35, 6.9); camera.lookAt(0, .08, 0);
    const character = await loadPortrait(null, { compact: true }), scene = new T.Scene(); scene.add(character.root);
    const base = { motion: 1, happy: false, shock: 0, looking: false, pointer: { x: 0, y: 0 }, volume: 0, blinkAmount: 0, held: false };
    const project = (x, y) => new T.Vector3((x - 627) * 3.7 / 1205, 2 - y * 3.7 / 1205, 0).project(camera);
    const hit = (x, y) => { const p = project(x, y), ray = new T.Raycaster(); ray.setFromCamera(p, camera); return character.hitTest(ray.ray)?.zone ?? null; };
    character.update(1 / 60, { ...base, time: 0, motion: 0 }); scene.updateMatrixWorld(true);
    const zones = { forehead: hit(627, 305), face: hit(627, 485), torso: hit(626, 660), hands: hit(620, 803), skirt: hit(650, 920), transparent: hit(40, 400) };
    const canvas = document.createElement('canvas'); canvas.width = 900; canvas.height = 1180; document.body.append(canvas);
    const c = canvas.getContext('2d'), stream = canvas.captureStream(60);
    const recorder = new MediaRecorder(stream, { mimeType: 'video/webm;codecs=vp9', videoBitsPerSecond: 5_000_000 });
    const chunks = [], shots = {}; recorder.ondataavailable = e => { if (e.data.size) chunks.push(e.data); };
    const stopped = new Promise(resolve => { recorder.onstop = resolve; }); recorder.start();
    let start, last, frames = 0;
    await new Promise(resolve => {
      const tick = now => {
        start ??= now; last ??= now; const t = (now - start) / 1000, dt = Math.min(.04, (now - last) / 1000 || 1 / 60); last = now;
        let label = '待机', activity = null, touch = { side: -1 };
        if (t >= 3 && t < 6.4) { label = '摸摸头'; activity = { name: 'pet', time: t - 3 }; }
        else if (t >= 6.4 && t < 9.2) { label = '戳身体'; activity = { name: 'startle', time: t - 6.4 }; touch.side = 1; }
        else if (t >= 9.2) { label = '摇尾巴'; activity = { name: 'tailWag', time: t - 9.2 }; }
        character.update(dt, { ...base, time: t + 12, activity, touch }); renderer.render(scene, camera);
        c.fillStyle = '#ede3de'; c.fillRect(0, 0, 900, 1180); c.drawImage(renderer.domElement, 42, 0, 816, 1152);
        c.font = '28px sans-serif'; c.fillStyle = '#555570'; c.fillText(label, 38, 1150);
        if (!shots[label] && ((label === '待机' && t > 2.2) || (label === '摸摸头' && t > 4.1) || (label === '戳身体' && t > 6.65) || (label === '摇尾巴' && t > 10.4))) shots[label] = canvas.toDataURL('image/png').split(',')[1];
        frames++; if (t < 14.2) requestAnimationFrame(tick); else resolve();
      }; requestAnimationFrame(tick);
    });
    recorder.stop(); await stopped; stream.getTracks().forEach(t => t.stop());

    // Read displacement from the actual production GPU shader. Remove group
    // movement so separate hair, cloth and tail motion cannot pass via a hop.
    for (const name of ['AnimatedPortrait', 'PortraitTail']) {
      const mesh = character.root.getObjectByName(name), material = mesh.material, compile = material.onBeforeCompile;
      material.transparent = false; material.blending = T.NoBlending;
      material.onBeforeCompile = shader => {
        compile(shader);
        shader.vertexShader = shader.vertexShader.replace('#include <common>', '#include <common>\nvarying vec2 vPartMotion;')
          .replace('#include <project_vertex>', 'vPartMotion=moved-pixel; transformed.xy=position.xy;\n#include <project_vertex>');
        shader.fragmentShader = `varying vec2 vPartMotion;varying vec2 vMapUv;uniform sampler2D map;uniform sampler2D uTailMask;
          void main(){vec2 m=texture2D(uTailMask,vMapUv).rg;if(texture2D(map,vMapUv).a*${name === 'PortraitTail' ? 'm.g' : '(1.0-m.r)'}<.02)discard;gl_FragColor=vec4(vPartMotion,0.,1.);}`;
      };
      material.customProgramCacheKey = () => 'parts25-' + name; material.needsUpdate = true;
    }
    const probe = new T.OrthographicCamera(-627 * 3.7 / 1205, 627 * 3.7 / 1205, 2, 2 - 1254 * 3.7 / 1205, .1, 10); probe.position.z = 3;
    const target = new T.WebGLRenderTarget(512, 512, { type: T.FloatType, depthBuffer: false });
    const markers = { head: [627,470], waist: [627,742], chest: [628,665], bow: [625,630], hairLeft: [313,659], hairRight: [941,639], hands: [589,792], hem: [795,943], tail: [1024,812], foot: [565,1165] };
    const paths = Object.fromEntries(Object.keys(markers).map(n => [n, []]));
    for (let i = 0; i < 600; i++) {
      character.update(1 / 60, { ...base, time: 30 + i / 60 });
      if (i % 10) continue;
      const pose = character.root.getObjectByName('AnimatedPortrait').parent; pose.position.set(0, 0, 0); pose.rotation.z = 0;
      renderer.setRenderTarget(target); renderer.render(scene, probe);
      for (const [name, [x,y]] of Object.entries(markers)) {
        const pixel = new Float32Array(4); renderer.readRenderTargetPixels(target, Math.floor(x / 1254 * 512), Math.floor((1-y / 1254) * 512), 1, 1, pixel);
        paths[name].push([pixel[0],pixel[1],pixel[3]]);
      }
    }
    const scale = (3.7 / 1205) * 288 / (2 * Math.tan(33 / 2 * Math.PI / 180) * 6.9);
    const span = (name, anchor = 'waist') => {
      const p = paths[name].map((v,i) => [v[0] - paths[anchor][i][0],v[1] - paths[anchor][i][1]]);
      return Math.hypot(...[0,1].map(a => Math.max(...p.map(v => v[a])) - Math.min(...p.map(v => v[a])))) * scale;
    };
    const movement = Object.fromEntries(['chest','bow','hairLeft','hairRight','hands','hem','tail'].map(n => [n,span(n,n.startsWith('hair')?'head':'waist')]));
    return { video: Array.from(new Uint8Array(await new Blob(chunks).arrayBuffer())), shots,
      proof: { zones, frames, seconds: (last-start)/1000, nativeViewport: [204,288], localIdleMovementLogicalPixels: movement,
        footDriftSourcePixels: Math.max(...paths.foot.map(p=>Math.hypot(p[0],p[1]))), validMarkers: Object.values(paths).every(p=>p.every(v=>v[2]>.9)),
        scope: 'Actual compact WebGL production shaders. Local movement subtracts head/waist anchors, not just changed control values. Enlarged real-time animation for inspection.' } };
  });
  assert.equal(visual.proof.zones.forehead, 'head'); assert.equal(visual.proof.zones.face, 'head');
  for (const name of ['torso','hands','skirt']) assert.equal(visual.proof.zones[name], 'body');
  assert.equal(visual.proof.zones.transparent, null); assert(visual.proof.validMarkers);
  for (const [name, pixels] of Object.entries(visual.proof.localIdleMovementLogicalPixels)) assert(pixels > (name === 'tail' ? 2 : .25), `${name} lacks visible local motion: ${pixels}`);
  assert(visual.proof.footDriftSourcePixels < .1);
  await writeFile(`${output}/companion.webm`, Buffer.from(visual.video));
  for (const [label, bytes] of Object.entries(visual.shots)) await writeFile(`${output}/${label}.png`, Buffer.from(bytes,'base64'));
  const report = { success: errors.length === 0, input, visual: visual.proof, errors };
  await writeFile(`${output}/interaction-report.json`, JSON.stringify(report,null,2)+'\n'); assert.deepEqual(errors, []);
  const encoded = spawnSync('ffmpeg', ['-y','-hide_banner','-loglevel','error','-i',`${output}/companion.webm`,'-an','-c:v','libx264','-preset','fast','-crf','21','-pix_fmt','yuv420p','-movflags','+faststart',`${output}/companion.mp4`], { stdio: 'inherit' });
  assert.equal(encoded.status, 0); console.log(JSON.stringify({success:true, visual:visual.proof, input: {head:input.head,body:input.body}, errors},null,2));
} finally { await browser.close(); }

import assert from 'node:assert/strict';
import { mkdir, writeFile } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import { chromium } from 'playwright';

const output = 'evidence/edition20'; await mkdir(output, { recursive: true });
const browser = await chromium.launch({ channel: 'chrome', headless: true });
try {
  const page = await browser.newPage({ viewport: { width: 1200, height: 920 } });
  const errors = []; page.on('pageerror', e => errors.push(e.message));
  await page.route('http://127.0.0.1:4173/', r => r.fulfill({ contentType: 'text/html', body: '<!doctype html><body style="margin:0"></body>' }));
  await page.goto('http://127.0.0.1:4173/');
  const result = await page.evaluate(async () => {
    const T = await import('/node_modules/three/build/three.module.js');
    const { loadPortrait: before } = await import('/evidence/edition20/before/portrait.js');
    const { loadPortrait: after } = await import('/src/portrait.js');
    const views = [];
    for (const load of [before, after]) {
      const renderer = new T.WebGLRenderer({ alpha: true, antialias: true, preserveDrawingBuffer: true });
      renderer.setSize(258, 364); renderer.setPixelRatio(1.5); renderer.outputColorSpace = T.SRGBColorSpace;
      const camera = new T.PerspectiveCamera(33, 258 / 364, .1, 60);
      camera.position.set(0, .35, 6.9); camera.lookAt(0, .08, 0);
      const character = await load(null, { compact: true }), control = await load(null, { compact: true });
      const scene = new T.Scene(), controlScene = new T.Scene(); scene.add(character.root); controlScene.add(control.root);
      views.push({ renderer, camera, character, control, scene, controlScene, peakAngle: 0, releaseAngle: 0 });
    }
    const base = { motion: 1, looking: false, pointer: { x: 0, y: 0 }, happy: false, shock: 0, volume: 0, blinkAmount: 0 };
    const trajectory = t => {
      const held = t >= 1 && t < 6.6, phase = Math.max(0, Math.min(5.6, t - 1));
      return { held, translation: { x: Math.sin(phase * Math.PI * 2 / 2.8) * 1.25, y: Math.sin(phase * Math.PI * 2 / 2.8) * .22 }, grab: { x: 0, y: .65 } };
    };
    function update(view, t, dt) {
      const state = { ...base, time: t + 7, ...trajectory(t) };
      view.character.update(dt, state); view.control.update(dt, { ...state, held: false, translation: { x: 0, y: 0 } });
      const angle = Math.abs(view.character.root.userData.expression.suspension?.angle ?? 0);
      view.peakAngle = Math.max(view.peakAngle, angle); if (t > 9) view.releaseAngle = angle;
    }
    const canvas = document.createElement('canvas'); canvas.width = 1200; canvas.height = 920; document.body.append(canvas);
    const c = canvas.getContext('2d');
    const stream = canvas.captureStream(60), recorder = new MediaRecorder(stream, { mimeType: 'video/webm;codecs=vp9', videoBitsPerSecond: 5_000_000 });
    const chunks = []; recorder.ondataavailable = e => { if (e.data.size) chunks.push(e.data); };
    const stopped = new Promise(resolve => { recorder.onstop = resolve; }); recorder.start();
    let start, last, frames = 0, still;
    await new Promise(resolve => {
      function tick(now) {
        start ??= now; last ??= now; const t = (now - start) / 1000, dt = Math.min(.04, (now - last) / 1000 || 1 / 60); last = now;
        c.fillStyle = '#18232e'; c.fillRect(0, 0, 1200, 920); c.fillStyle = '#2a3a49';
        for (let y = 0; y < 920; y += 20) for (let x = 0; x < 1200; x += 20) if ((x / 20 + y / 20) % 2) c.fillRect(x, y, 20, 20);
        views.forEach((v, i) => {
          update(v, t, dt); v.renderer.render(v.scene, v.camera);
          c.drawImage(v.renderer.domElement, i * 600 + 42, 72, 516, 728);
          c.fillStyle = '#f0f4fc'; c.font = '26px sans-serif'; c.fillText(i ? '现在' : '之前', i * 600 + 24, 38);
        });
        c.font = '23px sans-serif'; c.fillStyle = '#e0bf85';
        c.fillText(t < 1 ? '待机' : t < 6.6 ? '拖动' : '松手回摆', 24, 868);
        c.fillRect(260, 860, 860, 2); c.beginPath(); c.arc(690 + trajectory(t).translation.x * 250, 860, 7, 0, Math.PI * 2); c.fill();
        if (!still && t > 2) still = canvas.toDataURL('image/png').split(',')[1];
        frames++; if (t < 9.6) requestAnimationFrame(tick); else resolve();
      } requestAnimationFrame(tick);
    });
    recorder.stop(); await stopped; stream.getTracks().forEach(t => t.stop());

    // Read actual production vertex deformation from the GPU, with the group
    // transform removed. A matching no-drag control removes idle hair motion.
    // This proves local hair displacement instead of counting moved uniforms.
    const markerPixels = [[313, 659], [344, 774], [941, 639], [909, 742]], size = 1254, scale = 3.7 / 1205;
    const probeCamera = new T.OrthographicCamera(-size * scale / 2, size * scale / 2, 2, 2 - size * scale, .1, 10);
    probeCamera.position.z = 3;
    const target = new T.WebGLRenderTarget(512, 512, { type: T.FloatType, depthBuffer: false });
    for (const v of views) for (const char of [v.character, v.control]) {
      char.root.getObjectByName('PortraitTail').visible = false;
      const mesh = char.root.getObjectByName('AnimatedPortrait'), original = mesh.material, material = original.clone();
      material.transparent = false; material.blending = T.NoBlending;
      material.onBeforeCompile = shader => {
        original.onBeforeCompile(shader);
        shader.vertexShader = shader.vertexShader.replace('#include <common>', '#include <common>\nvarying vec2 vDragMotion;')
          .replace('#include <project_vertex>', 'vDragMotion = moved - pixel; transformed.xy = position.xy;\n#include <project_vertex>');
        shader.fragmentShader = 'varying vec2 vDragMotion; varying vec2 vMapUv; uniform sampler2D map; void main(){ if(texture2D(map,vMapUv).a<0.1)discard; gl_FragColor=vec4(vDragMotion,0.0,1.0); }';
      };
      material.customProgramCacheKey = () => 'drag-motion-probe-20'; mesh.material = material;
    }
    function sample(v, char, scene) {
      const pose = char.root.getObjectByName('AnimatedPortrait').parent;
      const pos = pose.position.clone(), angle = pose.rotation.z;
      pose.position.set(0, 0, 0); pose.rotation.z = 0;
      v.renderer.setRenderTarget(target); v.renderer.render(scene, probeCamera);
      const values = markerPixels.map(([x, y]) => {
        const a = new Float32Array(4); v.renderer.readRenderTargetPixels(target, Math.floor(x / size * 512), Math.floor((1 - y / size) * 512), 1, 1, a); return [a[0], a[1]];
      });
      pose.position.copy(pos); pose.rotation.z = angle; v.renderer.setRenderTarget(null); return values;
    }
    const localHair = views.map(() => markerPixels.map(() => 0));
    for (let frame = 0; frame < 240; frame++) {
      const t = frame / 60;
      for (const [i, v] of views.entries()) {
        const state = { ...base, time: 18 + t, ...trajectory(t) };
        v.character.update(1 / 60, state); v.control.update(1 / 60, { ...state, held: false, translation: { x: 0, y: 0 } });
        if (frame % 6) continue;
        const moving = sample(v, v.character, v.scene), control = sample(v, v.control, v.controlScene);
        moving.forEach((p, j) => { localHair[i][j] = Math.max(localHair[i][j], Math.hypot(p[0] - control[j][0], p[1] - control[j][1])); });
      }
    }
    const pixelsPerSourcePixel = scale * 364 / (2 * Math.tan(33 / 2 * Math.PI / 180) * 6.9);
    return { video: Array.from(new Uint8Array(await new Blob(chunks).arrayBuffer())), still,
      proof: { frames, seconds: (last - start) / 1000, smallViewport: [258, 364], sourceHairMotion: localHair,
        hairMotionInLogicalPixels: localHair.map(a => a.map(n => n * pixelsPerSourcePixel)),
        peakSuspensionDegrees: views.map(v => v.peakAngle * 180 / Math.PI), releasedDegrees: views.map(v => v.releaseAngle * 180 / Math.PI),
        scope: 'Production GPU shader displacement minus the matched idle control; whole-body hanging transform excluded from hair samples. Video uses the user’s small avatar size, enlarged as a Retina screenshot.' } };
  });
  await writeFile(`${output}/drag-response.webm`, Buffer.from(result.video));
  await writeFile(`${output}/drag-frame.png`, Buffer.from(result.still, 'base64'));
  await writeFile(`${output}/drag-render-check.json`, JSON.stringify({ ...result.proof, errors }, null, 2));
  const encoded = spawnSync('ffmpeg', ['-y', '-hide_banner', '-loglevel', 'error', '-i', `${output}/drag-response.webm`, '-an', '-c:v', 'libx264', '-preset', 'fast', '-crf', '21', '-pix_fmt', 'yuv420p', '-movflags', '+faststart', `${output}/drag-response.mp4`], { stdio: 'inherit' });
  assert.equal(encoded.status, 0); assert.deepEqual(errors, []);
  assert(result.proof.peakSuspensionDegrees[1] > 2, 'Dragging must visibly swing the body below the grip.');
  assert(result.proof.releasedDegrees[1] < .5, 'Release must settle instead of leaving a tilted image.');
  assert(result.proof.hairMotionInLogicalPixels[1].every(n => n > 1.5), 'Local hair movement must be visible at the small desktop size.');
  console.log(JSON.stringify(result.proof, null, 2));
} finally { await browser.close(); }

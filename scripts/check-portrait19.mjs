import assert from 'node:assert/strict';
import { mkdir, writeFile } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import { chromium } from 'playwright';

const output = 'evidence/edition19';
await mkdir(output, { recursive: true });
const browser = await chromium.launch({ channel: 'chrome', headless: true });
try {
  const page = await browser.newPage({ viewport: { width: 1200, height: 960 } });
  const errors = []; page.on('pageerror', e => errors.push(e.message));
  await page.route('http://127.0.0.1:4173/', r => r.fulfill({ contentType: 'text/html', body: '<!doctype html><body style="margin:0"></body>' }));
  await page.goto('http://127.0.0.1:4173/');
  const result = await page.evaluate(async () => {
    const loadImage = async src => { const i = new Image(); i.src = src; await i.decode(); return i; };
    const [oldImage, newImage] = await Promise.all([
      loadImage('/evidence/edition19/before/character.png'), loadImage('/portraits/whale-maid/character.png'),
    ]);
    const sample = document.createElement('canvas'); sample.width = sample.height = 1254;
    const sc = sample.getContext('2d', { willReadFrequently: true });
    const pixels = image => { sc.clearRect(0, 0, 1254, 1254); sc.drawImage(image, 0, 0); return sc.getImageData(0, 0, 1254, 1254).data; };
    const old = pixels(oldImage), fresh = pixels(newImage);
    let removedPixels = 0, addedPixels = 0, oldPaleLeaks = 0, newPaleLeaks = 0;
    for (let y = 0; y < 1254; y++) for (let x = 0; x < 1254; x++) {
      const i = (y * 1254 + x) * 4;
      if (old[i + 3] > 80 && fresh[i + 3] < 32) removedPixels++;
      if (fresh[i + 3] > old[i + 3] + 2) addedPixels++;
      if (y > 515 && y < 810 && (x < 410 || x > 865)) {
        for (const [p, before] of [[old, true], [fresh, false]]) {
          if (p[i + 3] > 96 && p[i] > 210 && p[i + 2] - Math.max(p[i], p[i + 1]) < 8) {
            if (before) oldPaleLeaks++; else newPaleLeaks++;
          }
        }
      }
    }
    const faceSamples = [[534, 455], [711, 433], [628, 507], [555, 522], [620, 470]];
    const facePixelError = faceSamples.map(([x, y]) => {
      const i = (y * 1254 + x) * 4; return Math.max(...[0, 1, 2].map(c => Math.abs(old[i + c] - fresh[i + c])));
    });
    const edges = document.createElement('canvas'); edges.width = 1400; edges.height = 1080;
    const ec = edges.getContext('2d');
    function background(ctx, x, y, w, h, light = false) {
      ctx.fillStyle = light ? '#f2eee8' : '#17202b'; ctx.fillRect(x, y, w, h);
      ctx.fillStyle = light ? '#e1ddd6' : '#273544';
      for (let yy = 0; yy < h; yy += 16) for (let xx = 0; xx < w; xx += 16) if ((xx / 16 + yy / 16) % 2) ctx.fillRect(x + xx, y + yy, Math.min(16, w - xx), Math.min(16, h - yy));
    }
    [oldImage, newImage].forEach((image, i) => {
      const x = i * 700; background(ec, x, 0, 700, 1080);
      ec.font = '28px sans-serif'; ec.fillStyle = '#fff'; ec.fillText(i ? '现在' : '之前', x + 24, 38);
      ec.drawImage(image, x + 70, 50, 560, 560);
      for (const [j, box] of [[0, [240, 620, 210, 200]], [1, [815, 605, 210, 200]], [2, [490, 1110, 245, 110]]]) {
        const xx = x + 14 + j * 228, yy = 650;
        background(ec, xx, yy, 216, 210, j === 1);
        ec.drawImage(image, ...box, xx, yy, 216, 210);
        background(ec, xx, yy + 216, 216, 210, j !== 1);
        ec.drawImage(image, ...box, xx, yy + 216, 216, 210);
      }
    });
    const T = await import('/node_modules/three/build/three.module.js');
    const { loadPortrait: before } = await import('/evidence/edition19/before/portrait.js');
    const { loadPortrait: after } = await import('/src/portrait.js');
    const views = [];
    for (const load of [before, after]) {
      const renderer = new T.WebGLRenderer({ antialias: true, alpha: true, preserveDrawingBuffer: true });
      renderer.setSize(500, 700); renderer.outputColorSpace = T.SRGBColorSpace;
      const camera = new T.PerspectiveCamera(33, 500 / 700, .1, 60);
      camera.position.set(0, .35, 6.9); camera.lookAt(0, .08, 0);
      const scene = new T.Scene(), character = await load(null, { compact: true }); scene.add(character.root);
      views.push({ renderer, scene, camera, character });
    }
    const canvas = document.createElement('canvas'); canvas.width = 1200; canvas.height = 960; document.body.append(canvas);
    const c = canvas.getContext('2d'), channelRanges = [{}, {}];
    const stream = canvas.captureStream(60), recorder = new MediaRecorder(stream, { mimeType: 'video/webm;codecs=vp9', videoBitsPerSecond: 6_000_000 });
    const chunks = []; recorder.ondataavailable = e => { if (e.data.size) chunks.push(e.data); };
    const stopped = new Promise(resolve => { recorder.onstop = resolve; });
    recorder.start(); let started, last, frames = 0, still;
    await new Promise(resolve => {
      function tick(now) {
        started ??= now; last ??= now; const t = (now - started) / 1000, dt = Math.min(.04, (now - last) / 1000 || 1 / 60); last = now;
        const amount = Math.min(1, Math.max(0, (t - 1) * 1.5)) * Math.min(1, Math.max(0, 12 - t));
        const pointer = { x: Math.sin((t - 1) * 1.4) * .85 * amount, y: Math.sin(t * .9) * .48 * amount };
        const blinkTime = t % 4.6, blinkAmount = blinkTime > 3.5 && blinkTime < 3.725 ? Math.sin((blinkTime - 3.5) / .225 * Math.PI) : 0;
        background(c, 0, 0, 1200, 960);
        views.forEach(({ renderer, scene, camera, character }, i) => {
          character.update(dt, { time: t + 7, motion: 1, looking: true, pointer, volume: 0, happy: false, shock: 0, blinkAmount });
          renderer.render(scene, camera); c.drawImage(renderer.domElement, i * 600, 42, 600, 840);
          c.fillStyle = '#eff3fb'; c.font = '24px sans-serif'; c.fillText(i ? '现在' : '之前', i * 600 + 22, 32);
          const secondary = character.root.userData.expression.secondary;
          secondary.forEach((v, index) => { const range = channelRanges[i][index] ??= [v, v]; range[0] = Math.min(range[0], v); range[1] = Math.max(range[1], v); });
        });
        c.fillStyle = '#879caf'; c.fillRect(80, 920, 1040, 2);
        c.beginPath(); c.arc(600 + pointer.x * 500, 920, 8, 0, Math.PI * 2); c.fillStyle = '#e0b978'; c.fill();
        if (!still && t > 6) still = canvas.toDataURL('image/png').split(',')[1];
        frames++; if (t < 13) requestAnimationFrame(tick); else resolve();
      }
      requestAnimationFrame(tick);
    });
    recorder.stop(); await stopped; stream.getTracks().forEach(t => t.stop());
    return { edges: edges.toDataURL('image/png').split(',')[1], still, video: Array.from(new Uint8Array(await new Blob(chunks).arrayBuffer())),
      proof: { removedPixels, addedPixels, oldPaleLeaks, newPaleLeaks, facePixelError, frames, seconds: (last - started) / 1000,
        channelRanges, renderCalls: views[1].renderer.info.render.calls, triangles: views[1].renderer.info.render.triangles,
        scope: 'Same pointer trajectory, compact production meshes, original artwork colors, live GPU rendering. Video is enlarged for inspection; no AI response test.' } };
  });
  await writeFile(`${output}/edge-comparison.png`, Buffer.from(result.edges, 'base64'));
  await writeFile(`${output}/motion-frame.png`, Buffer.from(result.still, 'base64'));
  await writeFile(`${output}/mouse-response.webm`, Buffer.from(result.video));
  await writeFile(`${output}/render-check.json`, JSON.stringify({ ...result.proof, errors }, null, 2));
  assert.equal(errors.length, 0, errors.join('\n'));
  assert(result.proof.removedPixels > 5000 && result.proof.addedPixels === 0, 'Clean the old matte without adding a new silhouette.');
  assert(result.proof.facePixelError.every(e => e <= 1), 'Reference face and animation anchors must be preserved.');
  assert(result.proof.newPaleLeaks < result.proof.oldPaleLeaks * .25, 'Pale background leakage around the hair must drop.');
  const encoded = spawnSync('ffmpeg', ['-y', '-hide_banner', '-loglevel', 'error', '-i', `${output}/mouse-response.webm`, '-an', '-c:v', 'libx264', '-preset', 'fast', '-crf', '21', '-pix_fmt', 'yuv420p', '-movflags', '+faststart', `${output}/mouse-response.mp4`], { stdio: 'inherit' });
  if (encoded.status) process.exit(encoded.status);
  console.log(JSON.stringify({ ...result.proof, channelRanges: undefined, errors }, null, 2));
} finally { await browser.close(); }

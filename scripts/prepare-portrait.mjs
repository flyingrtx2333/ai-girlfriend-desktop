import { chromium } from 'playwright';
import { readFile, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';

// Rebuild from the reference RGB and the saved extraction guide; no service call.
const source = 'design/references/whale-maid-finish-target.png';
const guide = 'design/portrait19/extraction-guide.png';
const bytes = await readFile(source), guideBytes = await readFile(guide);
const browser = await chromium.launch({ channel: 'chrome', headless: true });
try {
  const page = await browser.newPage();
  const result = await page.evaluate(async ({ url, guideUrl }) => {
    const image = new Image(); image.src = url; await image.decode();
    const width = image.width, height = image.height, canvas = document.createElement('canvas');
    canvas.width = width; canvas.height = height;
    const context = canvas.getContext('2d', { willReadFrequently: true });
    context.drawImage(image, 0, 0);
    const frame = context.getImageData(0, 0, width, height), rgb = frame.data.slice();
    const distance = new Float32Array(width * height), background = new Uint8Array(width * height);
    for (let y = 0; y < height; y++) {
      const left = [0, 0, 0], right = [0, 0, 0];
      for (let x = 0; x < 32; x++) for (let c = 0; c < 3; c++) {
        left[c] += rgb[(y * width + x) * 4 + c] / 32;
        right[c] += rgb[(y * width + width - 1 - x) * 4 + c] / 32;
      }
      for (let x = 0; x < width; x++) {
        const i = y * width + x;
        distance[i] = Math.hypot(...left.map((v, c) => rgb[i * 4 + c] - (v + (right[c] - v) * x / (width - 1))));
      }
    }
    const candidates = new Uint8Array(width * height), queue = new Int32Array(width * height);
    for (let i = 0; i < background.length; i++) {
      const x = i % width, y = Math.floor(i / width), [r, g, b] = rgb.subarray(i * 4, i * 4 + 3);
      const face = ((x - 625) / 185) ** 2 + ((y - 455) / 120) ** 2 < 1;
      const apron = ((x - 627) / 115) ** 2 + ((y - 845) / 82) ** 2 < 1;
      const hands = ((x - 627) / 80) ** 2 + ((y - 800) / 58) ** 2 < 1;
      const lace = (b > g - 2 && x > 230 && x < 1048 && y > 60 && y < 1060) || (b > g - 1 && x > 500 && x < 730 && y < 1208);
      const foot = ((x - 561) / 58) ** 2 + ((y - 1165) / 48) ** 2 < 1 || ((x - 666) / 55) ** 2 + ((y - 1165) / 48) ** 2 < 1;
      const leg = y < 1150 && x > 505 && x < 725;
      const floor = y > 1100 && !foot && !leg && !lace && !(b > r * 1.08 && b > g * 1.08);
      if ((!face && !apron && !hands && !lace && distance[i] <= 26) || floor) candidates[i] = 1;
    }
    let begin = 0, end = 0;
    function add(i) {
      if (i < 0 || i >= background.length || background[i] || !candidates[i]) return;
      background[i] = 1; queue[end++] = i;
    }
    for (let x = 0; x < width; x++) { add(x); add((height - 1) * width + x); }
    for (let y = 0; y < height; y++) { add(y * width); add(y * width + width - 1); }
    for (const [x, y] of [[520, 75], [315, 531], [292, 700], [357, 769], [933, 544], [949, 683], [908, 751], [856, 865]]) add(y * width + x);
    while (begin < end) {
      const i = queue[begin++], x = i % width;
      if (x) add(i - 1); if (x < width - 1) add(i + 1);
      add(i - width); add(i + width);
    }
    const visited = background.slice();
    for (let seed = 0; seed < candidates.length; seed++) {
      if (!candidates[seed] || visited[seed]) continue;
      begin = 0; end = 1; queue[0] = seed; visited[seed] = 1;
      function visit(i) { if (i >= 0 && i < candidates.length && candidates[i] && !visited[i]) { visited[i] = 1; queue[end++] = i; } }
      while (begin < end) {
        const i = queue[begin++], x = i % width;
        if (x) visit(i - 1); if (x < width - 1) visit(i + 1);
        visit(i - width); visit(i + width);
      }
      if (end > 512) for (let i = 0; i < end; i++) background[queue[i]] = 1;
    }
    let visible = 0;
    for (let y = 1144; y <= 1208; y++) for (const [left, right] of [[500, 616], [616, 735]]) {
      let min = right, max = left;
      for (let x = left; x < right; x++) {
        const [r, g, b] = rgb.subarray((y * width + x) * 4, (y * width + x) * 4 + 3);
        if (b > r * 1.035 && b > g * 1.035 && Math.max(r, g, b) < 235) { min = Math.min(min, x); max = Math.max(max, x); }
      }
      if (max > min) for (let x = left; x < right; x++) if (x < min - 1 || x > max + 1) background[y * width + x] = 1;
    }
    for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) {
      const i = y * width + x;
      let alpha = background[i] ? 0 : 1;
      if (y > 1208) alpha = 0;
      if (alpha && x > 0 && x < width - 1 && y > 0 && y < height - 1 && [i - 1, i + 1, i - width, i + width].some(j => background[j])) alpha = Math.max(.15, Math.min(1, (distance[i] - 12) / 38));
      frame.data[i * 4 + 3] = Math.round(alpha * 255);
      if (alpha > .5) visible++;
    }
    const guideImage = new Image(); guideImage.src = guideUrl; await guideImage.decode();
    if (guideImage.width !== width || guideImage.height !== height) throw new Error('Extraction guide must keep the reference canvas.');
    context.clearRect(0, 0, width, height); context.drawImage(guideImage, 0, 0);
    const guidePixels = context.getImageData(0, 0, width, height).data;
    // The generated guide supplies alpha only: face, paint and animation anchors
    // remain the exact reference pixels. Intersecting prevents new edge islands.
    const matte = new Uint8Array(width * height), interior = new Float32Array(width * height);
    const isHairEdge = (x, y) => y > 488 && y < 820 && (x < 461 || x > 794)
      && (((x - 625) / 185) ** 2 + ((y - 455) / 120) ** 2 > 1)
      && (y < 775 || x < 400 || x > 858);
    for (let i = 0; i < matte.length; i++) {
      matte[i] = Math.min(frame.data[i * 4 + 3], guidePixels[i * 4 + 3]);
      const x = i % width, y = Math.floor(i / width), p = i * 4;
      const hairEdge = isHairEdge(x, y);
      if (hairEdge && distance[i] < 48) {
        const blue = rgb[p + 2] - Math.max(rgb[p], rgb[p + 1]);
        matte[i] = Math.round(matte[i] * Math.max(0, Math.min(1, (blue - 2) / 10)));
      }
      interior[i] = matte[i] < 96 ? 0 : 10000;
    }
    for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) {
      const i = y * width + x;
      if (x) interior[i] = Math.min(interior[i], interior[i - 1] + 1);
      if (y) interior[i] = Math.min(interior[i], interior[i - width] + 1);
    }
    for (let y = height - 1; y >= 0; y--) for (let x = width - 1; x >= 0; x--) {
      const i = y * width + x;
      if (x + 1 < width) interior[i] = Math.min(interior[i], interior[i + 1] + 1);
      if (y + 1 < height) interior[i] = Math.min(interior[i], interior[i + width] + 1);
    }
    let cleanedEdges = 0; visible = 0;
    for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) {
      const i = y * width + x, p = i * 4;
      const hairEdge = isHairEdge(x, y);
      frame.data[p + 3] = Math.round(matte[i] * (hairEdge && interior[i] <= 1 ? .5 : 1));
      if (frame.data[p + 3] > 127) visible++;
      if (!matte[i] || interior[i] > 2 || (!hairEdge && matte[i] > 250)) continue;
      let best = -1, nearest = Infinity;
      for (let dy = -4; dy <= 4; dy++) for (let dx = -4; dx <= 4; dx++) {
        const nx = x + dx, ny = y + dy, d = dx * dx + dy * dy, j = ny * width + nx;
        if (nx < 0 || nx >= width || ny < 0 || ny >= height || d >= nearest || matte[j] < 250 || interior[j] < 3) continue;
        best = j * 4; nearest = d;
      }
      if (best >= 0) {
        // Extend nearby foreground paint into the antialias band, removing the
        // peach matte without multiplying a pale halo onto dark desktops.
        for (let c = 0; c < 3; c++) frame.data[p + c] = rgb[best + c];
        cleanedEdges++;
      }
    }
    context.putImageData(frame, 0, 0);
    const png = canvas.toDataURL('image/png').split(',')[1];
    const hair = new Uint8Array(width * height);
    const inIris = (x, y) => [[534, 455], [711, 433]].some(([cx, cy]) => ((x - cx) / 43) ** 2 + ((y - cy) / 45) ** 2 < 1);
    for (let i = 0; i < hair.length; i++) {
      const [r, g, b] = rgb.subarray(i * 4, i * 4 + 3);
      if (b > r * 1.015 && b > g * 1.015 && !inIris(i % width, Math.floor(i / width))) hair[i] = 1;
    }
    for (let pass = 0; pass < 2; pass++) {
      const next = hair.slice();
      for (let y = 1; y < height - 1; y++) for (let x = 1; x < width - 1; x++) {
        const i = y * width + x, [r, g, b] = rgb.subarray(i * 4, i * 4 + 3);
        if (!hair[i] && r < 225 && g > r - 15 && b > g - 5 && !inIris(x, y) && [i - 1, i + 1, i - width, i + width].some(j => hair[j])) next[i] = 1;
      }
      hair.set(next);
    }
    const smooth = (a, b, v) => { const t = Math.max(0, Math.min(1, (v - a) / (b - a))); return t * t * (3 - 2 * t); };
    const basis = (x, y) => [1, x, y, x * x, x * y, y * y];
    for (const [cx, cy] of [[534, 455], [711, 433]]) {
      const matrix = Array.from({ length: 6 }, () => Array(9).fill(0)); let count = 0;
      for (let y = cy - 82; y <= cy + 80; y += 2) for (let x = cx - 98; x <= cx + 98; x += 2) {
        const dx = x - cx, dy = y - cy, [r, g, b] = rgb.subarray((y * width + x) * 4, (y * width + x) * 4 + 3);
        if ((Math.abs(dx) < 72 && dy > -56 && dy < 44) || r < 185 || r < g + 9 || r < b + 12) continue;
        const f = basis(dx / 80, dy / 70); count++;
        for (let i = 0; i < 6; i++) {
          for (let j = 0; j < 6; j++) matrix[i][j] += f[i] * f[j];
          matrix[i][6] += f[i] * r; matrix[i][7] += f[i] * g; matrix[i][8] += f[i] * b;
        }
      }
      if (count < 50) throw new Error('Not enough reference skin around an eye.');
      for (let i = 1; i < 6; i++) matrix[i][i] += count * (i > 2 ? .02 : .005);
      for (let i = 0; i < 6; i++) {
        let pivot = i; for (let j = i + 1; j < 6; j++) if (Math.abs(matrix[j][i]) > Math.abs(matrix[pivot][i])) pivot = j;
        [matrix[i], matrix[pivot]] = [matrix[pivot], matrix[i]];
        const divisor = matrix[i][i]; for (let k = i; k < 9; k++) matrix[i][k] /= divisor;
        for (let j = 0; j < 6; j++) if (j !== i) { const factor = matrix[j][i]; for (let k = i; k < 9; k++) matrix[j][k] -= factor * matrix[i][k]; }
      }
      for (let y = cy - 90; y <= cy + 90; y++) for (let x = cx - 100; x <= cx + 100; x++) {
        const dx = x - cx, dy = y - cy, px = Math.cos(.124) * dx - Math.sin(.124) * dy, py = Math.sin(.124) * dx + Math.cos(.124) * dy;
        const i = (y * width + x) * 4, [r, g, b] = rgb.subarray(i, i + 3);
        if (hair[y * width + x]) continue;
        const blend = 1 - smooth(.86, 1.17, Math.max(Math.abs(px) / 72, Math.abs(py) / 57));
        const f = basis(dx / 80, dy / 70);
        for (let c = 0; c < 3; c++) {
          const fitted = Math.max(c ? 145 : 200, Math.min(255, f.reduce((sum, v, j) => sum + v * matrix[j][6 + c], 0)));
          const skin = fitted * .65 + rgb[(489 * width + 628) * 4 + c] * .35;
          frame.data[i + c] = Math.round(rgb[i + c] + (skin - rgb[i + c]) * blend);
        }
      }
    }
    // Keep RGB available in the PNG; alpha 248/255 tags skin/hair for the shader.
    for (let i = 0; i < hair.length; i++) frame.data[i * 4 + 3] = hair[i] ? 255 : 248;
    context.putImageData(frame, 0, 0);
    return { png, skinPng: canvas.toDataURL('image/png').split(',')[1], width, height, visible, cleanedEdges };
  }, { url: `data:image/png;base64,${bytes.toString('base64')}`, guideUrl: `data:image/png;base64,${guideBytes.toString('base64')}` });
  if (result.width !== 1254 || result.height !== 1254 || result.visible < 400000 || result.visible > 1100000) throw new Error('Reference mask requires review.');
  const output = Buffer.from(result.png, 'base64');
  const skin = Buffer.from(result.skinPng, 'base64');
  await writeFile('public/portraits/whale-maid/character.png', output);
  await writeFile('public/portraits/whale-maid/skin.png', skin);
  await writeFile('public/portraits/whale-maid/source.json', JSON.stringify({ edition: 19, source, guide, sourceSha256: createHash('sha256').update(bytes).digest('hex'), guideSha256: createHash('sha256').update(guideBytes).digest('hex'), outputSha256: createHash('sha256').update(output).digest('hex'), skinSha256: createHash('sha256').update(skin).digest('hex'), width: result.width, height: result.height, visiblePixels: result.visible, cleanedEdges: result.cleanedEdges, method: 'Reference RGB with the intersected alpha of a saved imagegen extraction guide; local foreground color extension on antialiased edges.', limitation: 'Front-facing deforming portrait, not a full 3D or Cubism model.', rebuildCallsExternalServices: false }, null, 2) + '\n');
  console.log({ width: result.width, height: result.height, visiblePixels: result.visible, bytes: output.length });
} finally { await browser.close(); }

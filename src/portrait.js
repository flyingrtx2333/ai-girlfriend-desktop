import * as THREE from 'three';
import { loadIdleLayer } from './idle.js';
import { sampleMotion } from './motions.js';
import { createTailLayer } from './portrait-tail.js';

const SIZE = 1254, SCALE = 3.7 / 1205;
// Pixel-space anchors are fitted to this artwork. Weights are baked once;
// only the small set of motion channels changes while the GPU deforms it.
const hairParts = [
  { pivot: [612, 160], center: [610, 315], radius: [103, 155], stiffness: 96, damping: 15 },
  { pivot: [476, 205], center: [455, 400], radius: [85, 145], stiffness: 72, damping: 12 },
  { pivot: [737, 194], center: [773, 370], radius: [91, 150], stiffness: 76, damping: 12 },
  { pivot: [576, 112], center: [509, 75], radius: [111, 91], stiffness: 110, damping: 10 },
  { pivot: [341, 478], center: [314, 658], radius: [80, 170], stiffness: 31, damping: 7 },
  { pivot: [415, 493], center: [413, 682], radius: [70, 167], stiffness: 45, damping: 8 },
  { pivot: [819, 477], center: [833, 674], radius: [73, 170], stiffness: 42, damping: 8 },
  { pivot: [906, 448], center: [936, 636], radius: [83, 182], stiffness: 28, damping: 6.5 },
];
const hairTips = [
  { pivot: [300, 693], center: [344, 774], radius: [64, 59] },
  { pivot: [459, 578], center: [465, 622], radius: [37, 40] },
  { pivot: [799, 564], center: [793, 626], radius: [35, 41] },
  { pivot: [942, 644], center: [909, 742], radius: [57, 63] },
];
const fingers = [
  { pivot: [579, 807], center: [591, 825], radius: [21, 15] },
  { pivot: [612, 796], center: [615, 810], radius: [11, 14] },
  { pivot: [640, 796], center: [637, 810], radius: [11, 14] },
  { pivot: [655, 808], center: [646, 825], radius: [21, 15] },
];

// ponytail: reference pixels preserve the artwork at a low local cost. This is
// a deforming portrait, with a limited front view, rather than a new 3D model.
export async function loadPortrait(onProgress, { compact = false } = {}) {
  const texture = await new THREE.TextureLoader().loadAsync('/portraits/whale-maid/character.png', onProgress);
  texture.colorSpace = THREE.SRGBColorSpace; texture.anisotropy = 4;
  const skinTexture = await new THREE.TextureLoader().loadAsync('/portraits/whale-maid/skin.png');
  skinTexture.colorSpace = THREE.SRGBColorSpace; skinTexture.anisotropy = 4;
  const idle = await loadIdleLayer();
  const canvas = document.createElement('canvas'); canvas.width = canvas.height = SIZE;
  const context = canvas.getContext('2d', { willReadFrequently: true }); context.drawImage(texture.image, 0, 0);
  const alpha = context.getImageData(0, 0, SIZE, SIZE).data;
  context.clearRect(0, 0, SIZE, SIZE); context.drawImage(skinTexture.image, 0, 0);
  const hairMask = context.getImageData(0, 0, SIZE, SIZE).data;
  const uniforms = {
    uPortrait: { value: texture }, uSkin: { value: skinTexture }, uTime: { value: 0 },
    uPose: { value: new THREE.Vector4() }, uFlow: { value: new THREE.Vector4() },
    uEyes: { value: new THREE.Vector2() }, uGaze: { value: new THREE.Vector2() },
    uMouth: { value: new THREE.Vector3() }, uBody: { value: new THREE.Vector4() },
    uEmotion: { value: new THREE.Vector2() },
    uHairFront: { value: new THREE.Vector4() }, uHairBack: { value: new THREE.Vector4() },
    uBreath: { value: new THREE.Vector4() }, uArms: { value: new THREE.Vector2() },
    uHands: { value: new THREE.Vector4() }, uCloth: { value: new THREE.Vector4() },
    uTail: { value: new THREE.Vector2() }, uFinTips: { value: new THREE.Vector2() },
    uHairTips: { value: new THREE.Vector4() }, uFingers: { value: new THREE.Vector4() },
    uTrim: { value: new THREE.Vector4() },
  };
  const tailLayer = createTailLayer(texture, uniforms, alpha, SCALE);
  const material = new THREE.MeshBasicMaterial({ map: texture, transparent: true, depthWrite: false, alphaTest: .015, toneMapped: false });
  material.userData.portraitLayer = 'body';
  material.onBeforeCompile = shader => {
    Object.assign(shader.uniforms, uniforms);
    shader.vertexShader = shader.vertexShader.replace('#include <common>', `#include <common>
      uniform sampler2D uPortrait;
      uniform float uTime;
      uniform vec4 uPose;
      uniform vec4 uFlow;
      uniform vec4 uBody;
      uniform vec3 uMouth;
      uniform vec4 uHairFront;
      uniform vec4 uHairBack;
      uniform vec4 uBreath;
      uniform vec2 uArms;
      uniform vec4 uHands;
      uniform vec4 uCloth;
      uniform vec2 uTail;
      uniform vec4 uHairTips;
      uniform vec4 uFingers;
      uniform vec4 uTrim;
      attribute vec4 aHairFront;
      attribute vec4 aHairBack;
      attribute vec4 aBodyParts;
      attribute vec4 aCloth;
      attribute vec4 aHairTips;
      attribute vec4 aFingers;
      attribute vec4 aTrim;
      mat2 rotatePortrait(float a) { return mat2(cos(a), sin(a), -sin(a), cos(a)); }
      vec2 portraitBend(vec2 point, vec2 pin, float angle) { return rotatePortrait(angle) * (point - pin) - (point - pin); }
    `).replace('#include <begin_vertex>', `
      #include <begin_vertex>
      vec2 pixel = vec2(uv.x, 1.0 - uv.y) * 1254.0;
      vec2 moved = pixel;
      float head = 1.0 - smoothstep(555.0, 660.0, pixel.y);
      float feet = 1.0 - smoothstep(970.0, 1150.0, pixel.y);
      vec2 pivot = vec2(627.0, 584.0);
      moved += head * (rotatePortrait(uPose.x) * (pixel - pivot) - (pixel - pivot));
      moved += head * vec2(uPose.y * 13.0, -uPose.z * 15.0 - uFlow.z);
      float face = exp(-pow((pixel.x - 627.0) / 185.0, 4.0) - pow((pixel.y - 470.0) / 116.0, 4.0));
      moved.x += face * uPose.y * 7.0;
      moved.y += face * (pixel.y - 460.0) * uPose.z * 0.04;
      float jaw = exp(-pow((pixel.x - 628.0) / 90.0, 2.0) - pow((pixel.y - 533.0) / 38.0, 2.0));
      moved.y += jaw * uMouth.x * 2.8;
      ${hairParts.map((part, i) => {
        const group = i < 4 ? 'Front' : 'Back', lane = 'xyzw'[i % 4];
        return `moved += aHair${group}.${lane} * portraitBend(pixel, vec2(${part.pivot.map(n => n.toFixed(1)).join(', ')}), uHair${group}.${lane});`;
      }).join('\n')}
      ${hairTips.map((part, i) => {
        const lane = 'xyzw'[i], root = hairParts[4 + i].pivot.map(n => n.toFixed(1)).join(', ');
        return `{ vec2 pin = vec2(${part.pivot.map(n => n.toFixed(1)).join(', ')});
          vec2 parentPixel = pixel + aHairBack.${lane} * portraitBend(pixel, vec2(${root}), uHairBack.${lane});
          pin += aHairBack.${lane} * portraitBend(pin, vec2(${root}), uHairBack.${lane});
          moved += aHairTips.${lane} * portraitBend(parentPixel, pin, uHairTips.${lane}); }`;
      }).join('\n')}
      float balance = 1.0 - smoothstep(640.0, 1060.0, pixel.y);
      vec2 bodyPivot = vec2(627.0, 1030.0);
      moved += balance * (rotatePortrait(uBody.x) * (pixel - bodyPivot) - (pixel - bodyPivot));
      moved += feet * vec2(uBody.y, uBody.z);
      // Breathing lifts the ribcage and collar, with smaller shoulder motion.
      // The abdomen and planted feet stay stable instead of scaling the image.
      moved.y -= aBodyParts.x * uBreath.x;
      moved.x += aBodyParts.x * (pixel.x - 627.0) * uBreath.y;
      moved.y -= (aBodyParts.y + aBodyParts.z) * uBreath.z;
      float clasp = 1.0 - exp(-dot((pixel - vec2(623.0, 815.0)) / vec2(34.0, 27.0), (pixel - vec2(623.0, 815.0)) / vec2(34.0, 27.0)));
      moved += aBodyParts.y * clasp * portraitBend(pixel, vec2(491.0, 633.0), uArms.x);
      moved += aBodyParts.z * clasp * portraitBend(pixel, vec2(750.0, 626.0), uArms.y);
      float leftHand = 1.0 - smoothstep(612.0, 637.0, pixel.x);
      moved += aBodyParts.w * (vec2(uHands.x, uHands.y - uBreath.w) + clasp * mix(
        portraitBend(pixel, vec2(687.0, 765.0), uHands.w),
        portraitBend(pixel, vec2(553.0, 770.0), uHands.z), leftHand));
      float fingertipContact = 1.0 - exp(-dot((pixel - vec2(623.0, 826.0)) / vec2(9.0, 10.0), (pixel - vec2(623.0, 826.0)) / vec2(9.0, 10.0)));
      ${fingers.map((part, i) => `moved += fingertipContact * aFingers.${'xyzw'[i]} * portraitBend(pixel, vec2(${part.pivot.map(n => n.toFixed(1)).join(', ')}), uFingers.${'xyzw'[i]});`).join('\n')}
      moved += aCloth.x * portraitBend(pixel, vec2(625.0, 600.0), uCloth.x);
      moved += aCloth.y * portraitBend(pixel, vec2(594.0, 786.0), uCloth.y);
      moved += aCloth.z * portraitBend(pixel, vec2(669.0, 784.0), uCloth.z);
      moved.y += aCloth.w * (uCloth.w + sin((pixel.x - 627.0) * 0.036) * uCloth.w * 0.24);
      moved.x += aCloth.w * (pixel.x - 627.0) * uBreath.y * 0.35;
      moved.x += aCloth.w * uFlow.x;
      moved.y += dot(aTrim, uTrim) * (1.0 + sin(pixel.x * 0.14 - uTime * 2.2) * 0.22);
      moved.y += feet * uFlow.y;
      moved.y += smoothstep(450.0, 1100.0, pixel.y) * uFlow.w;
      transformed.xy += vec2(moved.x - pixel.x, pixel.y - moved.y) * ${SCALE};
    `);
    shader.fragmentShader = shader.fragmentShader.replace('#include <common>', `#include <common>
      uniform sampler2D uPortrait;
      uniform sampler2D uSkin;
      uniform sampler2D uTailMask;
      uniform vec2 uEyes;
      uniform vec2 uGaze;
      uniform vec3 uMouth;
      uniform vec2 uEmotion;
      mat2 portraitRotation(float a) { return mat2(cos(a), sin(a), -sin(a), cos(a)); }
      vec4 artwork(vec2 p) { return texture2D(uPortrait, vec2(p.x / 1254.0, 1.0 - p.y / 1254.0)); }
      vec4 portraitEye(vec4 original, vec2 pixel, vec2 center, float blink) {
        vec2 p = portraitRotation(0.124) * (pixel - center);
        if (abs(p.x) > 100.0 || abs(p.y) > 90.0) return original;
        vec4 skin = texture2D(uSkin, vec2(pixel.x / 1254.0, 1.0 - pixel.y / 1254.0));
        vec2 skinUv = vec2(pixel.x / 1254.0, 1.0 - pixel.y / 1254.0);
        float hairTag = max(skin.a, max(texture2D(uSkin, skinUv + vec2(1.0, 0.0) / 1254.0).a, texture2D(uSkin, skinUv - vec2(1.0, 0.0) / 1254.0).a));
        hairTag = max(hairTag, max(texture2D(uSkin, skinUv + vec2(0.0, 1.0) / 1254.0).a, texture2D(uSkin, skinUv - vec2(0.0, 1.0) / 1254.0).a));
        float foregroundHair = smoothstep(0.98, 0.995, hairTag);
        if (foregroundHair > 0.98) return original;
        vec4 color = original;
        vec2 gaze = vec2(uGaze.x * 5.0, -uGaze.y * 3.0);
        float iris = length(p / vec2(34.0, 36.0));
        float shifted = length((p - gaze) / vec2(34.0, 36.0));
        vec4 sclera = artwork(center + portraitRotation(-0.124) * vec2(-42.0, 1.0));
        if (sclera.b > sclera.r * 1.1) sclera = artwork(vec2(610.0, 484.0));
        if (length(gaze) > 0.05) {
          color = mix(color, sclera, 1.0 - smoothstep(1.0, 1.07, iris));
          vec4 irisColor = artwork(center + portraitRotation(-0.124) * (p - gaze));
          color = mix(color, irisColor, 1.0 - smoothstep(0.98, 1.04, shifted));
        }
        float u = p.x / 64.0;
        float oldTop = (center.x < 600.0 ? -42.0 : -37.0) + 26.0 * u * u;
        float oldBottom = 38.0 - 29.0 * u * u;
        float closed = mix(7.0 - 8.0 * u * u, -4.0 + 12.0 * u * u, uEmotion.x);
        float top = mix(oldTop, closed - 0.6, blink), bottom = mix(oldBottom, closed + 0.6, blink);
        float sides = 1.0 - smoothstep(1.0, 1.15, abs(u));
        float covered = max(1.0 - smoothstep(top - 0.7, top + 0.7, p.y), smoothstep(bottom - 0.7, bottom + 0.7, p.y));
        float feather = 1.0 - smoothstep(55.0, 85.0, abs(p.y));
        color.rgb = mix(color.rgb, skin.rgb, covered * sides * feather * (1.0 - foregroundHair) * smoothstep(0.0, 0.08, blink));
        // A tapered lid follows the reference's thick outer lashes without
        // crushing a twelve-pixel painted lash into noisy subpixel fragments.
        float outer = center.x < 600.0 ? -u : u;
        float width = mix(3.6, 1.5, blink) * (0.8 + smoothstep(0.1, 0.9, outer));
        float taper = smoothstep(-1.07, -0.72, outer) * (1.0 - smoothstep(0.92, 1.15, outer));
        float lash = (1.0 - smoothstep(width - 0.6, width + 0.6, abs(p.y - top))) * taper;
        for (int i = 0; i < 2; i++) {
          float start = 0.60 + float(i) * 0.15;
          float phase = clamp((outer - start) / 0.32, 0.0, 1.0);
          float flick = top - pow(phase, 1.4) * (6.0 + float(i) * 2.0);
          float tip = (1.0 - smoothstep(0.65, 1.0, phase)) * smoothstep(start, start + 0.07, outer);
          lash = max(lash, (1.0 - smoothstep(0.35, 1.15, abs(p.y - flick))) * tip);
        }
        lash *= smoothstep(0.02, 0.25, blink) * (1.0 - foregroundHair);
        vec3 lashPaint = mix(vec3(0.046, 0.024, 0.032), vec3(0.085, 0.042, 0.048), smoothstep(top - width, top + width, p.y));
        color.rgb = mix(color.rgb, lashPaint, lash);
        return color;
      }
    `).replace('#include <map_fragment>', `
      #ifdef USE_MAP
        vec2 pixel = vec2(vMapUv.x, 1.0 - vMapUv.y) * 1254.0;
        vec4 painted = artwork(pixel);
        painted.a *= 1.0 - texture2D(uTailMask, vMapUv).r;
        painted = portraitEye(painted, pixel, vec2(534.0, 455.0), uEyes.x);
        painted = portraitEye(painted, pixel, vec2(711.0, 433.0), uEyes.y);
        vec2 cheek = vec2(abs(pixel.x - 625.0) - 112.0, pixel.y - 506.0);
        float blush = exp(-dot(cheek / vec2(38.0, 17.0), cheek / vec2(38.0, 17.0))) * uEmotion.y * 0.16;
        painted.rgb = mix(painted.rgb, vec3(0.94, 0.37, 0.36), blush);
        float opening = uMouth.x;
        vec2 mouth = pixel - vec2(628.0, 507.0);
        if (abs(mouth.x) < 27.0 && abs(mouth.y) < 24.0 && opening > 0.005) {
          vec4 skin = artwork(vec2(pixel.x, 498.0 - mouth.x * 0.05));
          float erase = 1.0 - smoothstep(0.7, 1.2, length(mouth / vec2(23.0, 13.0)));
          painted = mix(painted, skin, erase * smoothstep(0.0, 0.15, opening));
          float width = 12.5 + uMouth.y * 6.0 - uMouth.z * 4.0;
          float x = mouth.x / width;
          float arch = sqrt(max(0.0, 1.0 - x * x));
          float height = opening * (11.0 - uMouth.y * 4.0 + uMouth.z * 1.5);
          float upper = -arch * (0.6 + height * mix(0.42, 0.85, uMouth.z));
          float lower = arch * (0.7 + height * 0.9);
          float cavity = smoothstep(upper - 0.6, upper + 0.6, mouth.y) * (1.0 - smoothstep(lower - 0.6, lower + 0.6, mouth.y));
          cavity *= 1.0 - smoothstep(0.95, 1.04, abs(x));
          float tongue = exp(-pow(mouth.x / (width * 0.85), 2.0) - pow((mouth.y - lower + 1.0) / (height * 0.55 + 0.5), 2.0));
          vec3 inside = mix(vec3(0.068, 0.025, 0.036), vec3(0.55, 0.20, 0.25), tongue * 0.85);
          float teeth = (1.0 - smoothstep(upper + 1.0, upper + 2.3, mouth.y)) * smoothstep(0.18, 0.38, opening);
          inside = mix(inside, vec3(0.88, 0.77, 0.71), teeth * (0.55 + uMouth.y * 0.35));
          float lip = exp(-pow((mouth.y - lower - 0.8) / 1.0, 2.0)) * arch * smoothstep(0.0, 0.2, opening) * 0.18;
          painted.rgb = mix(painted.rgb, vec3(0.70, 0.35, 0.31), lip);
          painted.rgb = mix(painted.rgb, inside, cavity);
        }
        diffuseColor *= painted;
      #endif
    `);
  };
  material.customProgramCacheKey = () => 'whale-maid-portrait-20';
  const root = new THREE.Group(); root.name = 'ReferencePortrait';
  const pose = new THREE.Group(); root.add(pose);
  // Densify only the hand rows/columns; fine finger creases need more than the
  // original eight-pixel lattice, while the face and outer silhouette stay put.
  const divisions = compact ? 96 : 160, handStep = compact ? 3 : 2;
  const axis = (start, end) => [...Array.from({ length: divisions + 1 }, (_, i) => i * SIZE / divisions),
    ...Array.from({ length: Math.floor((end - start) / handStep) + 1 }, (_, i) => start + i * handStep)]
    .sort((a, b) => a - b).filter((v, i, values) => !i || v - values[i - 1] > .3);
  const columns = axis(535, 715), rows = axis(735, 851);
  const geometry = new THREE.PlaneGeometry(SIZE * SCALE, SIZE * SCALE, columns.length - 1, rows.length - 1);
  for (let row = 0; row < rows.length; row++) for (let column = 0; column < columns.length; column++) {
    const i = row * columns.length + column, x = columns[column], y = rows[row];
    geometry.attributes.position.setXYZ(i, (x - SIZE / 2) * SCALE, 2 - y * SCALE, 0);
    geometry.attributes.uv.setXY(i, x / SIZE, 1 - y / SIZE);
  }
  const uv = geometry.attributes.uv;
  const weights = { aHairFront: [], aHairBack: [], aBodyParts: [], aCloth: [], aHairTips: [], aFingers: [], aTrim: [] };
  const smooth = THREE.MathUtils.smoothstep;
  const region = (x, y, cx, cy, rx, ry) => Math.exp(-(((x - cx) / rx) ** 2 + ((y - cy) / ry) ** 2));
  for (let i = 0; i < uv.count; i++) {
    const x = uv.getX(i) * SIZE, y = (1 - uv.getY(i)) * SIZE;
    const hairAt = (dx, dy) => hairMask[(THREE.MathUtils.clamp(Math.round(y + dy), 0, SIZE - 1) * SIZE + THREE.MathUtils.clamp(Math.round(x + dx), 0, SIZE - 1)) * 4 + 3] > 252 ? 1 : 0;
    // Use the prepared hair mask, which excludes irises. Pigment highlights
    // must not change deformation strength across the same painted lock.
    const hair = (hairAt(0, 0) * 4 + hairAt(-4, 0) + hairAt(4, 0) + hairAt(0, -4) + hairAt(0, 4)) / 8;
    const tail = tailLayer.cut[Math.min(SIZE - 1, Math.round(y)) * SIZE + Math.min(SIZE - 1, Math.round(x))] / 255;
    const front = [], back = [];
    hairParts.forEach((part, j) => {
      const w = (j < 4 ? region(x, y, ...part.center, ...part.radius)
        : Math.exp(-(((x - part.center[0]) / part.radius[0]) ** 2)) * smooth(y, part.pivot[1] - 15, part.pivot[1] + 185)) * hair;
      if (j < 4) front.push(w * (j === 3 ? 1 - smooth(y, 126, 154) : smooth(y, 146, 205) * (1 - smooth(y, 515, 566))));
      else back.push(w * smooth(y, 434, 536) * (1 - smooth(y, 820, 880)) * (1 - tail)
        * (j < 6 ? 1 - smooth(x, 439, 468) : smooth(x, 770, 801)));
    });
    for (const [name, parts] of [['aHairFront', front], ['aHairBack', back]]) {
      const sum = Math.max(1, parts.reduce((a, b) => a + b, 0)); weights[name].push(...parts.map(w => w / sum));
    }
    weights.aBodyParts.push(
      region(x, y, 627, 650, 108, 88),
      region(x, y, 518, 705, 67, 92) * smooth(y, 616, 656),
      region(x, y, 722, 698, 67, 95) * smooth(y, 611, 651),
      region(x, y, 621, 786, 103, 65),
    );
    const hem = smooth(y, 812, 882) * (1 - smooth(y, 1008, 1058));
    weights.aCloth.push(
      region(x, y, 625, 618, 65, 43),
      region(x, y, 454, 930, 105, 92) * hem,
      region(x, y, 788, 929, 107, 93) * hem * (1 - tail),
      region(x, y, 625, 866, 133, 88),
    );
    weights.aHairTips.push(...hairTips.map(part => region(x, y, ...part.center, ...part.radius) * hair * (1 - tail)));
    const p = (Math.min(SIZE - 1, Math.round(y)) * SIZE + Math.min(SIZE - 1, Math.round(x))) * 4;
    const skin = smooth((alpha[p] - alpha[p + 2]) / 255, .04, .12) * smooth((alpha[p] - alpha[p + 1]) / 255, .04, .10);
    weights.aFingers.push(...fingers.map(part => region(x, y, ...part.center, ...part.radius) * skin));
    weights.aTrim.push(region(x, y, 548, 759, 38, 26), region(x, y, 681, 755, 38, 26),
      region(x, y, 626, 925, 141, 22), region(x, y, 625, 991, 250, 26) * (1 - tail));
  }
  for (const [name, values] of Object.entries(weights)) geometry.setAttribute(name, new THREE.Float32BufferAttribute(values, 4));
  const mesh = new THREE.Mesh(geometry, material); mesh.name = 'AnimatedPortrait'; mesh.renderOrder = 1;
  pose.add(tailLayer.mesh, mesh);
  const gaze = new THREE.Vector2(), eyes = [0, 0], vowelsSmoothed = new THREE.Vector2();
  const springSpecs = [
    ...hairParts.map(p => [p.stiffness, p.damping]),
    [80, 11], [30, 7], [27, 6.5], [38, 9], // chest bow, two hems, apron
    [55, 13], [50, 12], [75, 13], [70, 12], // arms and wrists
    [28, 6.5], [48, 7.5], [44, 10], [40, 9], // two tail links and clasped hands
    [84, 14], [92, 15], [88, 14], [79, 13], // four visible finger/thumb regions
    [78, 11], [72, 10], [38, 8], [31, 7], // cuffs, apron lace, lower lace
    [64, 10], [57, 9], // left and right fluke tips
    [14, 4.3], [24, 5.6], [23, 5.5], [12, 3.9], // flexible curl tips lag their roots
  ];
  const springs = springSpecs.map(([stiffness, damping]) => ({ value: 0, velocity: 0, stiffness, damping }));
  const targets = new Float32Array(springs.length), previousPosition = new THREE.Vector2(), previousVelocity = new THREE.Vector2();
  let breath = 0, speaking = 0, priorRoll = 0, priorYaw = 0, priorPitch = 0, priorBody = 0, inertia = 0;
  let bodyShiftX = 0, bodyShiftY = 0;
  const suspension = { angle: 0, velocity: 0, hold: 0, stretch: 0 };
  const grabPoint = new THREE.Vector2(0, .65), dragVelocity = new THREE.Vector2();
  let opening = 0, lift = 0, roll = 0, yaw = 0, pitch = 0, bodyRoll = 0, smile = 0, blush = 0, started = 0, reaction = false;
  const allowedMotions = new Set(['nod', 'shake', 'bow', 'jump', 'curious', 'glance', 'shy', 'doze', 'listen', 'pet', 'tailWag', 'sway']);
  const inverse = new THREE.Matrix4(), localRay = new THREE.Ray(), point = new THREE.Vector3();
  return {
    root, allowedMotions, get lift() { return lift; },
    hitTest(ray) {
      pose.updateWorldMatrix(true, false);
      localRay.copy(ray).applyMatrix4(inverse.copy(pose.matrixWorld).invert());
      if (!localRay.intersectPlane(new THREE.Plane(new THREE.Vector3(0, 0, 1), 0), point)) return null;
      const x = Math.round(point.x / SCALE + SIZE / 2), y = Math.round((2 - point.y) / SCALE);
      if (x < 0 || x >= SIZE || y < 0 || y >= SIZE) return null;
      const opaque = (dx, dy) => {
        const px = x + dx, py = y + dy;
        return px >= 0 && px < SIZE && py >= 0 && py < SIZE && alpha[(py * SIZE + px) * 4 + 3] >= 30;
      };
      // A small edge tolerance follows the moving painted silhouette. Large
      // transparent areas still pass through to the desktop.
      if (!opaque(0, 0) && ![-10, 0, 10].some(dy => [-10, 0, 10].some(dx => opaque(dx, dy)))) return null;
      return { point: pose.localToWorld(point.clone()), anchor: point.clone(), zone: y < 574 ? 'head' : 'body', source: [x, y] };
    },
    update(dt, state) {
      const { time, motion, happy, shock, looking, pointer, blinking, blinkAmount, volume, vowels, activity, translation, held = false, grab, touch } = state;
      if (happy && !reaction) started = time; reaction = happy;
      const performed = activity || (happy ? { name: 'pet', time: time - started } : shock ? { name: 'startle', time: 2.4 - shock * 2.4 } : null);
      const expression = sampleMotion(performed?.name, performed?.time);
      const side = ['pet', 'startle'].includes(performed?.name) ? (touch?.side || 1) : 1;
      const surprise = expression?.emotion?.[2] ?? 0, brace = expression?.body?.[2] ?? 0;
      const responseSpeed = performed?.name === 'startle' ? 16 : performed?.name === 'pet' ? 7 : 3.5;
      idle.update(dt, volume > .05 ? 1 : 0, motion);
      // Eyes settle first; head and soft parts follow on different time scales.
      gaze.x = THREE.MathUtils.damp(gaze.x, (looking ? THREE.MathUtils.clamp(pointer.x, -1, 1) : Math.sin(Math.floor(time / 3.3) * 2.4) * .16 * motion) * (1 - surprise * .5) + side * surprise * .35, 18, dt);
      gaze.y = THREE.MathUtils.damp(gaze.y, looking ? THREE.MathUtils.clamp(pointer.y, -1, 1) : Math.sin(Math.floor(time / 4.7) * 1.7) * .09 * motion, 18, dt);
      const head = expression?.joints.Head ?? [0, 0, 0], captured = idle.joints.Head;
      roll = THREE.MathUtils.damp(roll, head[0] * .55 * side + captured[0] * .22 + (gaze.x * .032 + gaze.y * .014) * motion + Math.sin(time * .47) * .008 * motion, Math.max(7, responseSpeed), dt);
      yaw = THREE.MathUtils.damp(yaw, gaze.x * .95 * motion + head[1] * 3 * side + captured[1] * .25, Math.max(5.5, responseSpeed), dt);
      pitch = THREE.MathUtils.damp(pitch, gaze.y * .36 * motion + head[2] * 4 + captured[2] * .25, Math.max(6, responseSpeed), dt);
      bodyRoll = THREE.MathUtils.damp(bodyRoll, (expression?.joints.Spine2?.[0] ?? 0) * .5 * side + (idle.joints.Spine[0] + idle.joints.Spine1[0] + idle.joints.Spine2[0]) * .18 + (gaze.x * .014 + Math.sin(time * .56) * .006) * motion - roll * .1, responseSpeed, dt);
      bodyShiftX = THREE.MathUtils.damp(bodyShiftX, gaze.x * 4.2 * motion + (expression?.body?.[0] ?? 0) * side, responseSpeed, dt);
      bodyShiftY = THREE.MathUtils.damp(bodyShiftY, gaze.y * 1.5 * motion - (expression?.body?.[1] ?? 0), responseSpeed, dt);
      smile = THREE.MathUtils.damp(smile, expression?.emotion?.[0] ?? (happy ? .85 : performed?.name === 'shy' ? .5 : expression?.mouth?.[1] ?? 0), 5, dt);
      blush = THREE.MathUtils.damp(blush, expression?.emotion?.[1] ?? (happy || performed?.name === 'shy' ? 1 : 0), 4, dt);
      const phase = (time / 4.4 + Math.sin(time * .19) * .012) % 1;
      const inhaling = phase < .38 ? smooth(phase, 0, .38) : 1 - smooth(phase, .38, 1);
      breath = THREE.MathUtils.damp(breath, (inhaling * 2 - 1) * motion, 5, dt);
      speaking = THREE.MathUtils.damp(speaking, volume * motion, 5, dt);
      const rollSpeed = THREE.MathUtils.clamp((roll - priorRoll) / Math.max(.001, dt), -1.2, 1.2);
      const yawSpeed = THREE.MathUtils.clamp((yaw - priorYaw) / Math.max(.001, dt), -3.5, 3.5);
      const pitchSpeed = THREE.MathUtils.clamp((pitch - priorPitch) / Math.max(.001, dt), -2, 2);
      const bodySpeed = THREE.MathUtils.clamp((bodyRoll - priorBody) / Math.max(.001, dt), -.5, .5);
      priorRoll = roll; priorYaw = yaw; priorPitch = pitch; priorBody = bodyRoll;
      const rawX = THREE.MathUtils.clamp(((translation?.x ?? 0) - previousPosition.x) / Math.max(.001, dt), -20, 20);
      const rawY = THREE.MathUtils.clamp(((translation?.y ?? 0) - previousPosition.y) / Math.max(.001, dt), -20, 20);
      // Native window events do not arrive on every render frame. Smooth velocity
      // before differentiating so coalesced events cannot chatter the hair.
      dragVelocity.x = THREE.MathUtils.damp(dragVelocity.x, rawX, 12, dt);
      dragVelocity.y = THREE.MathUtils.damp(dragVelocity.y, rawY, 12, dt);
      const vx = dragVelocity.x, vy = dragVelocity.y;
      const acceleration = THREE.MathUtils.clamp((vx - previousVelocity.x) / Math.max(.001, dt), -60, 60);
      const accelerationY = THREE.MathUtils.clamp((vy - previousVelocity.y) / Math.max(.001, dt), -60, 60);
      previousPosition.set(translation?.x ?? 0, translation?.y ?? 0); previousVelocity.copy(dragVelocity);
      suspension.hold = THREE.MathUtils.damp(suspension.hold, held ? motion : 0, held ? 14 : 7, dt);
      if (held && grab) grabPoint.set(THREE.MathUtils.clamp(grab.x, -1.2, 1.2), THREE.MathUtils.clamp(grab.y, -1.3, 1.9));
      const hangingTarget = held ? THREE.MathUtils.clamp(-vx * .023 - acceleration * .0012 + grabPoint.x * .035, -.085, .085) * motion : 0;
      const steps = Math.max(1, Math.ceil(dt * 120)), step = dt / steps;
      for (let i = 0; i < steps; i++) {
        suspension.velocity += (52 * (hangingTarget - suspension.angle) - 8.5 * suspension.velocity) * step;
        suspension.angle = THREE.MathUtils.clamp(suspension.angle + suspension.velocity * step, -.105, .105);
      }
      suspension.stretch = THREE.MathUtils.damp(suspension.stretch,
        (THREE.MathUtils.clamp(vy * .55 + accelerationY * .07, -7, 8) + 1.8) * suspension.hold, 9, dt);
      // Positive pixel-space rotation bends a hanging lock to the LEFT. This
      // opposes rightward acceleration; the old negative sign made it lead.
      inertia = THREE.MathUtils.damp(inertia, THREE.MathUtils.clamp(acceleration * .006 + vx * .024, -.22, .22) * motion, 12, dt);
      const wind = (Math.sin(time * .79) + Math.sin(time * .37 + .8) * .4) * motion;
      // Front locks react quickly, long locks lag, and each side has its own
      // phase and stiffness. The same head/torso input keeps them related.
      for (let i = 0; i < 8; i++) {
        const breeze = (Math.sin(time * (.77 + i * .035) + i * 1.23) + wind * .45) * motion;
        targets[i] = i < 4
          ? (-rollSpeed * .045 - yawSpeed * .022 - pitchSpeed * .012 + inertia * (i === 3 ? -.6 : .65) + suspension.angle * .15 + breeze * .009) * (i === 3 ? 3.1 : 1)
          : -roll * .6 + yaw * .055 - rollSpeed * .085 - yawSpeed * (i % 2 ? .032 : .045) + inertia * 1.4 + suspension.angle * .9 + breeze * (i === 4 || i === 7 ? .030 : .019);
        const limit = i === 3 ? .24 : i < 4 ? .14 : .24;
        targets[i] = THREE.MathUtils.clamp(targets[i], -limit, limit);
      }
      targets[8] = breath * .018 + bodyRoll * .3 - rollSpeed * .025 - yawSpeed * .014 - bodySpeed * .1 + inertia * .25;
      targets[9] = bodyRoll * -.75 + breath * .008 + Math.sin(time * .91 + .6) * .013 * motion + inertia * .8 + suspension.angle * .6 - bodySpeed * .12 - yawSpeed * .018;
      targets[10] = bodyRoll * -.6 - breath * .007 + Math.sin(time * .84 + 2.4) * .012 * motion + inertia * .65 + suspension.angle * .5 - bodySpeed * .09 - yawSpeed * .014;
      targets[11] = -breath * .7 + Math.sin(time * .66 + .7) * .4 * motion + vy * .55 - bodySpeed * 11 - yawSpeed * .9 - pitchSpeed * 1.6;
      const joints = idle.joints;
      targets[12] = THREE.MathUtils.clamp(joints.LeftArm[0] * .65 + joints.LeftShoulder[0] * .35 + breath * .007 + speaking * Math.sin(time * 1.7) * .012 - bodySpeed * .07 - yawSpeed * .006 + (expression?.joints.LeftArm?.[0] ?? 0) * .018 - brace * .055, -.085, .085);
      targets[13] = THREE.MathUtils.clamp(joints.RightArm[0] * .65 - joints.RightShoulder[0] * .35 - breath * .006 + speaking * Math.sin(time * 1.7 + 1.9) * .011 + bodySpeed * .06 + yawSpeed * .005 + (expression?.joints.RightArm?.[0] ?? 0) * .018 + brace * .055, -.085, .085);
      targets[14] = joints.LeftHand[2] * .12 + joints.LeftForeArm[1] * .35 + breath * .006 - brace * .03;
      targets[15] = joints.RightHand[2] * .16 + joints.RightForeArm[1] * .3 - breath * .006 + brace * .03;
      targets[16] = THREE.MathUtils.clamp((Math.sin(time * 1.08 + .4) * .068 + Math.sin(time * .47) * .02) * motion - bodyRoll * .8 - roll * .3 + yaw * .035 - yawSpeed * .025 - bodySpeed * .15 - inertia * .75 + suspension.angle * .5 + (expression?.tail?.[0] ?? 0), -.24, .24);
      targets[17] = -springs[16].value * .7 - springs[16].velocity * .07 + Math.sin(time * 1.18 - .6) * .046 * motion + inertia * .4 + (expression?.tail?.[1] ?? 0);
      targets[18] = joints.LeftHand[0] * 35 - joints.RightHand[0] * 24 + Math.sin(time * .69 + .8) * 1.5 * motion - bodySpeed * 8 - yawSpeed * .45;
      targets[19] = (joints.LeftShoulder[0] + joints.RightShoulder[0]) * 16 + Math.sin(time * .93) * .7 * motion - speaking * .7 - (expression?.hands?.[0] ?? 0) * 9 - brace * 6;
      const fidgetPhase = time % 9.8;
      const quiet = performed?.name === 'doze' ? .1 : performed ? .45 : 1;
      const squeeze = delay => smooth(fidgetPhase - delay, 1.8, 2.45) * (1 - smooth(fidgetPhase - delay, 3.05, 4.15));
      targets[20] = (squeeze(0) * .032 + breath * .004) * motion * quiet + brace * .035;
      targets[21] = -squeeze(.12) * .024 * motion * quiet;
      targets[22] = squeeze(.22) * .022 * motion * quiet;
      targets[23] = (-squeeze(.32) * .030 - breath * .003) * motion * quiet - brace * .03;
      targets[24] = -(targets[12] - springs[12].value) * 35 - breath * .24 + squeeze(0) * .18 * motion;
      targets[25] = (targets[13] - springs[13].value) * 35 - breath * .22 + squeeze(.2) * .15 * motion;
      targets[26] = -breath * .42 - springs[11].velocity * .2;
      targets[27] = -breath * .24 + inertia * 8 + (springs[9].velocity - springs[10].velocity) * 9 - bodySpeed * 5 - yawSpeed * .4;
      targets[28] = -springs[17].velocity * .04 + Math.sin(time * 1.46 + .5) * .019 * motion - inertia * .25 + (expression?.tail?.[2] ?? 0);
      targets[29] = -springs[17].velocity * .065 + Math.sin(time * 1.32 + 1.6) * .024 * motion - inertia * .18 - (expression?.tail?.[2] ?? 0) * .8;
      for (let i = 0; i < 4; i++) targets[30 + i] = THREE.MathUtils.clamp(-springs[4 + i].velocity * .11
        + (springs[4 + i].value - targets[4 + i]) * .45 + Math.sin(time * (1.1 + i * .08) + i) * .014 * motion, -.25, .25);
      for (let part = 0; part < springs.length; part++) {
        const channel = springs[part], steps = Math.max(1, Math.ceil(dt * 120)), step = dt / steps;
        for (let i = 0; i < steps; i++) {
          channel.velocity += (channel.stiffness * (targets[part] - channel.value) - channel.damping * channel.velocity) * step;
          channel.value += channel.velocity * step;
        }
      }
      lift = THREE.MathUtils.damp(lift, expression?.lift ?? 0, 24, dt);
      const a = suspension.angle, cs = Math.cos(a), sn = Math.sin(a);
      pose.rotation.z = a;
      // Rotate beneath the actual grab point rather than around the feet.
      pose.position.set(grabPoint.x - (cs * grabPoint.x - sn * grabPoint.y),
        lift + grabPoint.y - (sn * grabPoint.x + cs * grabPoint.y), 0);
      for (let i = 0; i < 2; i++) {
        const expressionEye = Math.max(expression?.blink ? 1 : expression?.eyes?.[i] ?? 0, smile * .07);
        const target = Math.max(blinking ? 1 : 0, expressionEye);
        eyes[i] = blinkAmount === undefined
          ? THREE.MathUtils.damp(eyes[i], target, target > eyes[i] ? 65 : 40, dt)
          : Math.max(blinkAmount, THREE.MathUtils.damp(eyes[i], expressionEye, 40, dt));
      }
      opening = THREE.MathUtils.damp(opening, state.speechShape?.open ?? Math.max(THREE.MathUtils.clamp((volume - .035) * 1.5, 0, 1), expression?.mouth?.[0] ?? 0), state.speechShape ? 55 : volume > .06 ? 26 : 34, dt);
      vowelsSmoothed.x = THREE.MathUtils.damp(vowelsSmoothed.x, vowels?.ee ?? 0, state.speechShape ? 35 : 15, dt);
      vowelsSmoothed.y = THREE.MathUtils.damp(vowelsSmoothed.y, volume > .05 ? vowels?.ou ?? 0 : Math.max(vowels?.ou ?? 0, surprise * .85), state.speechShape ? 35 : 15, dt);
      uniforms.uTime.value = time;
      uniforms.uPose.value.set(roll, yaw, pitch, motion);
      uniforms.uFlow.value.set(-inertia * 14, -(expression?.balance?.[1] ?? 0) / SCALE * .4, breath * 1.1, suspension.stretch);
      uniforms.uBody.value.set(bodyRoll, (expression?.balance?.[0] ?? 0) / SCALE * .5 + idle.position.x / SCALE * .3 + bodyShiftX, -(expression?.joints.Spine2?.[2] ?? 0) * 45 - bodyShiftY, 0);
      uniforms.uHairFront.value.set(...springs.slice(0, 4).map(s => s.value));
      uniforms.uHairBack.value.set(...springs.slice(4, 8).map(s => s.value));
      uniforms.uCloth.value.set(...springs.slice(8, 12).map(s => s.value));
      uniforms.uArms.value.set(springs[12].value, springs[13].value);
      uniforms.uHands.value.set(springs[18].value, springs[19].value, springs[14].value, springs[15].value);
      uniforms.uTail.value.set(springs[16].value, springs[17].value);
      uniforms.uFinTips.value.set(springs[28].value, springs[29].value);
      uniforms.uHairTips.value.set(...springs.slice(30, 34).map(s => s.value));
      uniforms.uFingers.value.set(...springs.slice(20, 24).map(s => s.value));
      uniforms.uTrim.value.set(...springs.slice(24, 28).map(s => s.value));
      uniforms.uBreath.value.set(breath * 4.8 + brace * 2.5, breath * .0065, breath * 1.5 + brace * 2, breath * 2);
      uniforms.uEyes.value.set(...eyes); uniforms.uGaze.value.copy(gaze);
      uniforms.uMouth.value.set(opening, vowelsSmoothed.x, vowelsSmoothed.y);
      uniforms.uEmotion.value.set(smile, blush);
      root.userData.expression = { eyes: [...eyes], opening, gaze: gaze.toArray(), head: [roll, yaw, pitch], breath, secondary: springs.map(s => s.value),
        action: performed?.name ?? 'idle', emotion: [smile, blush, surprise], body: [bodyRoll, bodyShiftX, bodyShiftY],
        suspension: { angle: a, inertia, hold: suspension.hold, stretch: suspension.stretch,
          settling: held || Math.abs(a) > .001 || Math.abs(suspension.velocity) > .005 || Math.abs(inertia) > .002 } };
    },
  };
}

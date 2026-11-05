import * as THREE from 'three';

// The visible tail is cut from the existing painting. The skirt, bow and lace
// stay on the foreground layer; a small underlap covers the attachment.
export function createTailLayer(texture, uniforms, pixels, scale) {
  const size = texture.image.width;
  const outline = [[775,770],[1072,770],[1072,1018],[775,1018]];
  const hair = [[770,720],[965,720],[955,739],[941,751],[926,765],[907,779],[887,789],[866,793],[843,793],[822,791],[800,784],[775,772]];
  const clothing = [[770,770],[856,770],[856,952],[859,958],[850,968],[828,982],[807,995],[783,1005],[770,1010]];
  const hiddenFluke = [[867,779],[876,786],[887,790],[903,794],[920,797],[936,806],[946,823],[944,844],[934,863],[909,855],[885,843],[872,827],[865,808]];
  const inside = (x, y, points) => {
    let hit = false;
    for (let i = 0, j = points.length - 1; i < points.length; j = i++) {
      const [ax, ay] = points[i], [bx, by] = points[j];
      if ((ay > y) !== (by > y) && x < (bx - ax) * (y - ay) / (by - ay) + ax) hit = !hit;
    }
    return hit;
  };
  const cut = new Uint8Array(size * size), data = new Uint8Array(size * size * 4);
  for (let y = 770; y < 1018; y++) for (let x = 778; x < 1072; x++) {
    if (inside(x, y, outline) && !inside(x, y, hair) && !inside(x, y, clothing)) cut[y * size + x] = 255;
  }
  for (let y = 768; y < 1020; y++) for (let x = 776; x < 1074; x++) {
    const source = y * size + x, target = ((size - 1 - y) * size + x) * 4;
    const blue = pixels[source * 4 + 2] > pixels[source * 4] + 7;
    const pad = x < 890 && y > 880 ? 6 : 2;
    const near = blue && !inside(x, y, hair) && [-pad, 0, pad].some(dy => [-pad, 0, pad].some(dx => cut[(y + dy) * size + x + dx]));
    const repair = !cut[source] && inside(x, y, hiddenFluke) && !inside(x, y, clothing);
    data[target] = cut[source]; data[target + 1] = cut[source] || near || repair ? 255 : 0;
    data[target + 2] = repair ? 255 : 0; data[target + 3] = 255;
  }
  const mask = new THREE.DataTexture(data, size, size, THREE.RGBAFormat);
  mask.minFilter = mask.magFilter = THREE.LinearFilter; mask.needsUpdate = true;
  uniforms.uTailMask = { value: mask };
  const geometry = new THREE.PlaneGeometry(300 * scale, 260 * scale, 40, 36);
  const positions = geometry.attributes.position, uv = geometry.attributes.uv;
  for (let i = 0; i < uv.count; i++) {
    const x = 776 + uv.getX(i) * 300, y = 768 + (1 - uv.getY(i)) * 260;
    positions.setXYZ(i, (x - size / 2) * scale, 2 - y * scale, 0);
    uv.setXY(i, x / size, 1 - y / size);
  }
  const material = new THREE.MeshBasicMaterial({ map: texture, transparent: true, depthWrite: false, alphaTest: .015, toneMapped: false });
  material.userData.portraitLayer = 'tail';
  material.onBeforeCompile = shader => {
    Object.assign(shader.uniforms, uniforms);
    shader.vertexShader = shader.vertexShader.replace('#include <common>', `#include <common>
      uniform vec2 uTail;
      uniform vec2 uFinTips;
      uniform vec4 uBody;
      uniform vec4 uFlow;
      mat2 tailRotation(float a) { return mat2(cos(a), sin(a), -sin(a), cos(a)); }
      vec2 tailBend(vec2 p, vec2 pin, float a) { return tailRotation(a) * (p - pin) - (p - pin); }
    `).replace('#include <begin_vertex>', `#include <begin_vertex>
      vec2 pixel = vec2(uv.x, 1.0 - uv.y) * ${size.toFixed(1)};
      vec2 moved = pixel;
      vec2 socket = vec2(947.0, 872.0), rootPin = vec2(819.0, 977.0);
      float leaf = smoothstep(22.0, 100.0, length(pixel - socket)) * (1.0 - smoothstep(870.0, 909.0, pixel.y));
      float left = 1.0 - smoothstep(933.0, 958.0, pixel.x);
      moved += leaf * mix(tailBend(pixel, vec2(954.0, 859.0), uFinTips.y), tailBend(pixel, vec2(937.0, 865.0), uFinTips.x), left);
      float joint = smoothstep(65.0, 140.0, 978.0 - pixel.y + (pixel.x - 829.0) * 0.35);
      moved += joint * tailBend(moved, socket, uTail.y);
      moved += tailBend(moved, rootPin, uTail.x);
      float balance = 1.0 - smoothstep(640.0, 1060.0, rootPin.y);
      float feet = 1.0 - smoothstep(970.0, 1150.0, rootPin.y);
      moved += balance * tailBend(rootPin, vec2(627.0, 1030.0), uBody.x);
      moved += feet * vec2(uBody.y, uBody.z + uFlow.y);
      moved.y += smoothstep(450.0, 1100.0, rootPin.y) * uFlow.w;
      transformed.xy += vec2(moved.x - pixel.x, pixel.y - moved.y) * ${scale};
    `);
    shader.fragmentShader = shader.fragmentShader.replace('#include <common>', '#include <common>\nuniform sampler2D uTailMask;')
      .replace('#include <map_fragment>', `#include <map_fragment>
        vec4 tailMask = texture2D(uTailMask, vMapUv);
        if (tailMask.b > 0.01) {
          // Continue the occluded leaf using nearby visible tail paint. This
          // remains behind the original foreground hair at the neutral pose.
          vec2 pixel = vec2(vMapUv.x, 1.0 - vMapUv.y) * ${size.toFixed(1)};
          vec2 paintPoint = vec2(mix(890.0, pixel.x, 0.7), 802.0 + max(0.0, 802.0 - pixel.y) * 0.5);
          vec4 repair = texture2D(map, vec2(paintPoint.x / ${size.toFixed(1)}, 1.0 - paintPoint.y / ${size.toFixed(1)}));
          repair.a = 1.0;
          diffuseColor = mix(diffuseColor, repair, tailMask.b);
        }
        diffuseColor.a *= tailMask.g;
      `);
  };
  material.customProgramCacheKey = () => 'whale-maid-tail-layer-18';
  const mesh = new THREE.Mesh(geometry, material); mesh.name = 'PortraitTail'; mesh.renderOrder = 0;
  return { mesh, mask, cut };
}

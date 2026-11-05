import * as THREE from 'three';

// Local repair of the existing asset. The approved front artwork supplies color;
// the face, lids and eyeballs below are separate curved, animated geometry.
// ponytail: front projection suits a companion facing the viewer; a dedicated
// painted UV atlas is needed for large side turns with the same fidelity.
const OFFSET = new THREE.Vector3(-.0003556162, .4899249971, -.0001099408);
const EYES = [-.094, .044], RADIUS = .061;
const portraitUV = (x, y) => [(600 + (x + .025) * 1300) / 1199, 1 - (480 - (y - .127) * 1300) / 1312];
const depth = (x, y) => .09 + .108 * Math.sqrt(Math.max(.0002, 1 - ((x + .025) / .177) ** 2 - ((y - .142) / .102) ** 2))
  + .006 * Math.exp(-(((x + .025) / .019) ** 2 + ((y - .092) / .017) ** 2));
function normal(x, y) {
  const d = .0002;
  return new THREE.Vector3(-(depth(x + d, y) - depth(x - d, y)) / (2 * d), -(depth(x, y + d) - depth(x, y - d)) / (2 * d), 1).normalize();
}
const upper = u => .158 - .026 * u * u;
const lower = u => .103 + .029 * u * u;
const shut = u => .124 + .008 * u * u;
const top = u => .2 - .068 * u * u;
const bottom = u => .075 + .057 * u * u;

function surfaceGeometry(points, indices, uvPoints = points) {
  const geometry = new THREE.BufferGeometry();
  geometry.setAttribute('position', new THREE.Float32BufferAttribute(points.flatMap(([x, y, z]) => [x, y, z ?? depth(x, y)]), 3));
  geometry.setAttribute('normal', new THREE.Float32BufferAttribute(points.flatMap(([x, y]) => normal(x, y).toArray()), 3));
  geometry.setAttribute('uv', new THREE.Float32BufferAttribute(uvPoints.flatMap(([x, y]) => portraitUV(x, y)), 2));
  if (indices) geometry.setIndex(indices);
  return geometry;
}

function faceGeometry() {
  const face = new THREE.Shape();
  face.absellipse(-.025, .142, .177, .102, 0, Math.PI * 2, false);
  for (const cx of EYES) {
    const hole = new THREE.Path();
    hole.moveTo(cx - RADIUS, .132);
    hole.quadraticCurveTo(cx, .268, cx + RADIUS, .132);
    hole.quadraticCurveTo(cx, .018, cx - RADIUS, .132);
    face.holes.push(hole);
  }
  const outline = new THREE.ShapeGeometry(face, 64).toNonIndexed();
  const source = outline.getAttribute('position'), points = [];
  function triangle(a, b, c, level = 0) {
    // Uniform subdivision keeps shared edges identical after curving the skin.
    if (level < 3) {
      const mid = (p, q) => [(p[0] + q[0]) / 2, (p[1] + q[1]) / 2];
      const ab = mid(a, b), bc = mid(b, c), ca = mid(c, a);
      triangle(a, ab, ca, level + 1); triangle(ab, b, bc, level + 1);
      triangle(ca, bc, c, level + 1); triangle(ab, bc, ca, level + 1);
    } else points.push(a, b, c);
  }
  for (let i = 0; i < source.count; i += 3) triangle(...[i, i + 1, i + 2].map(j => [source.getX(j), source.getY(j)]));
  outline.dispose();
  return surfaceGeometry(points);
}

function lidGeometry(cx, lowerLid) {
  const points = [], closed = [], uv = [], indices = [], columns = 48, rows = 16;
  for (let j = 0; j <= rows; j++) for (let i = 0; i <= columns; i++) {
    const u = i / columns * 2 - 1, v = j / rows, x = cx + RADIUS * u;
    const outer = lowerLid ? bottom(u) : top(u), inner = lowerLid ? lower(u) : upper(u);
    const y = THREE.MathUtils.lerp(outer, inner, v), closedY = THREE.MathUtils.lerp(outer, shut(u), v);
    points.push([x, y]); closed.push([x, closedY]);
    // Skin stretches from above/below the painted eye; no iris is painted onto a lid.
    const skinY = lowerLid ? inner : .17 - .02 * u * u;
    uv.push([x, THREE.MathUtils.lerp(outer, skinY, v)]);
    if (j < rows && i < columns) {
      const a = j * (columns + 1) + i, b = a + columns + 1;
      if (lowerLid) indices.push(a, a + 1, b, a + 1, b + 1, b);
      else indices.push(a, b, a + 1, a + 1, b, b + 1);
    }
  }
  const geometry = surfaceGeometry(points, indices, uv);
  geometry.morphAttributes.position = [new THREE.Float32BufferAttribute(closed.flatMap(([x, y]) => [x, y, depth(x, y)]), 3)];
  geometry.morphAttributes.normal = [new THREE.Float32BufferAttribute(closed.flatMap(([x, y]) => normal(x, y).toArray()), 3)];
  return geometry;
}

function lashGeometry(cx) {
  const points = [], closed = [], indices = [], columns = 64;
  for (let j = 0; j < 2; j++) for (let i = 0; i <= columns; i++) {
    const u = i / columns * 2 - 1, x = cx + RADIUS * u;
    const thickness = Math.sqrt(Math.max(0, 1 - u * u)) * (j ? .0034 : -.00025);
    const y = upper(u) + thickness, closedY = shut(u) + thickness * .65;
    points.push([x, y, depth(x, y) + .001]);
    closed.push([x, closedY, depth(x, closedY) + .001]);
    if (!j && i < columns) { const a = i, b = i + columns + 1; indices.push(a, a + 1, b, a + 1, b + 1, b); }
  }
  const geometry = surfaceGeometry(points, indices);
  geometry.morphAttributes.position = [new THREE.Float32BufferAttribute(closed.flat(), 3)];
  return geometry;
}

function relaxLace(mesh) {
  const geometry = mesh.geometry, position = geometry.getAttribute('position'), uv = geometry.getAttribute('uv');
  const canvas = document.createElement('canvas'); canvas.width = canvas.height = 1024;
  const context = canvas.getContext('2d', { willReadFrequently: true });
  context.drawImage(mesh.material.map.image, 0, 0, 1024, 1024);
  const pixels = context.getImageData(0, 0, 1024, 1024).data;
  const groups = [], lookup = new Map(), ids = new Uint32Array(position.count);
  for (let i = 0; i < position.count; i++) {
    const p = [position.getX(i), position.getY(i), position.getZ(i)], key = p.map(v => Math.round(v * 1e5)).join(',');
    let id = lookup.get(key);
    if (id === undefined) { id = groups.length; lookup.set(key, id); groups.push({ p, members: [], neighbors: new Set(), selected: p[1] - OFFSET.y > .28 }); }
    ids[i] = id;
    const group = groups[id]; group.members.push(i);
    const x = THREE.MathUtils.clamp(Math.floor(uv.getX(i) * 1024), 0, 1023), y = THREE.MathUtils.clamp(Math.floor(uv.getY(i) * 1024), 0, 1023), at = (y * 1024 + x) * 4;
    const [r, g, b] = pixels.subarray(at, at + 3);
    group.selected &&= r > 160 && g > 150 && b > 150 && Math.max(r, g, b) - Math.min(r, g, b) < 65;
  }
  const indices = geometry.index.array;
  for (let i = 0; i < indices.length; i += 3) for (let j = 0; j < 3; j++) {
    const a = ids[indices[i + j]], group = groups[a];
    if (group.selected) { group.neighbors.add(ids[indices[i + (j + 1) % 3]]); group.neighbors.add(ids[indices[i + (j + 2) % 3]]); }
  }
  const selected = groups.filter(g => g.selected && g.neighbors.size && [...g.neighbors].every(id => groups[id].selected));
  const original = selected.map(g => g.p.slice());
  for (let iteration = 0; iteration < 12; iteration++) for (const strength of [.45, -.47]) {
    const next = selected.map(group => group.p.map((v, axis) => v + strength * ([...group.neighbors].reduce((sum, id) => sum + groups[id].p[axis], 0) / group.neighbors.size - v)));
    for (let i = 0; i < selected.length; i++) selected[i].p = next[i];
  }
  let maxDisplacement = 0;
  for (let j = 0; j < selected.length; j++) {
    const group = selected[j], delta = new THREE.Vector3(...group.p).sub(new THREE.Vector3(...original[j])).clampLength(0, .004);
    maxDisplacement = Math.max(maxDisplacement, delta.length());
    group.p = original[j].map((v, axis) => v + delta.getComponent(axis));
    for (const i of group.members) position.setXYZ(i, ...group.p);
  }
  const sourceNormals = geometry.getAttribute('normal'), normals = new Float32Array(sourceNormals.count * 3);
  for (let i = 0; i < sourceNormals.count; i++) normals.set([sourceNormals.getX(i), sourceNormals.getY(i), sourceNormals.getZ(i)], i * 3);
  geometry.computeVertexNormals();
  const updated = geometry.getAttribute('normal');
  for (let i = 0; i < position.count; i++) if (!groups[ids[i]].selected) updated.setXYZ(i, ...normals.subarray(i * 3, i * 3 + 3));
  position.needsUpdate = updated.needsUpdate = true;
  geometry.computeBoundingSphere();
  return { vertices: selected.reduce((n, g) => n + g.members.length, 0), maxDisplacement };
}

export async function repairAppearance(root) {
  const texture = await new THREE.TextureLoader().loadAsync('/models/whale-maid-v2/appearance/reference-front.png');
  texture.colorSpace = THREE.SRGBColorSpace;
  texture.anisotropy = 4;
  let body, head;
  root.traverse(node => {
    if (node.isSkinnedMesh && node.geometry.attributes.uv && !node.morphTargetDictionary) body = node;
    if (node.isBone && /Head$/.test(node.name)) head = node;
    if (node.morphTargetDictionary) node.visible = false;
  });
  if (!body || !head) throw new Error('角色缺少头部或身体网格');
  const lace = relaxLace(body);
  root.updateMatrixWorld(true);
  const face = new THREE.Group(); face.name = 'RebuiltFace'; face.matrixAutoUpdate = false;
  const frame = new THREE.Matrix4().makeRotationY(Math.PI / 2).setPosition(OFFSET);
  face.matrix.copy(head.matrixWorld).invert().multiply(body.matrixWorld).multiply(frame);
  head.add(face);

  const skin = new THREE.MeshStandardMaterial({ name: 'PortraitSkin', map: texture, color: new THREE.Color().setScalar(.72), emissive: '#ffffff', emissiveIntensity: .36, roughness: .68, metalness: 0, envMapIntensity: .3 });
  skin.onBeforeCompile = shader => {
    shader.vertexShader = shader.vertexShader.replace('#include <common>', '#include <common>\nvarying vec2 vFacePoint;')
      .replace('#include <morphtarget_vertex>', '#include <morphtarget_vertex>\nvFacePoint = transformed.xy;');
    shader.fragmentShader = shader.fragmentShader.replace('#include <common>', '#include <common>\nvarying vec2 vFacePoint;')
      .replace('#include <map_fragment>', `
      #ifdef USE_MAP
        float portraitY = vFacePoint.y > 0.08 ? vFacePoint.y : 0.08 + (vFacePoint.y - 0.08) * 0.8;
        vec2 skinUv = vec2((600.0 + (vFacePoint.x + 0.025) * 1300.0) / 1199.0, 1.0 - (480.0 - (portraitY - 0.127) * 1300.0) / 1312.0);
        vec4 portraitSkin = texture2D(map, skinUv);
        vec4 cleanSkin = texture2D(map, vec2(600.0 / 1199.0, 1.0 - 523.0 / 1312.0));
        vec3 cheek = texture2D(map, vec2(500.0 / 1199.0, 1.0 - 550.0 / 1312.0)).rgb;
        cleanSkin.rgb = mix(cleanSkin.rgb, cheek, smoothstep(0.045, 0.16, abs(vFacePoint.x + 0.025)) * 0.3);
        float eyeDistance = min(abs(vFacePoint.x + 0.094), abs(vFacePoint.x - 0.044));
        float repair = (1.0 - smoothstep(0.045, 0.083, eyeDistance)) * (1.0 - smoothstep(0.037, 0.078, abs(vFacePoint.y - 0.135)));
        if ((portraitSkin.b > portraitSkin.r * 1.1 && portraitSkin.b > portraitSkin.g) || portraitSkin.r < 0.4)
          portraitSkin = cleanSkin;
        portraitSkin.rgb = mix(portraitSkin.rgb, cleanSkin.rgb, repair);
        diffuseColor *= portraitSkin;
      #endif
    `).replace('#include <emissivemap_fragment>', 'totalEmissiveRadiance = diffuseColor.rgb * 0.36;');
  };
  const faceBase = new THREE.Mesh(faceGeometry(), skin); faceBase.name = 'FaceSurface'; face.add(faceBase);
  const neck = new THREE.Mesh(new THREE.SphereGeometry(1, 24, 16), new THREE.MeshStandardMaterial({ color: '#e5bda8', roughness: .75, envMapIntensity: .3 }));
  neck.position.set(-.025, .022, .055); neck.scale.set(.026, .024, .04); neck.name = 'NeckBridge'; face.add(neck);
  const lashesMaterial = new THREE.MeshStandardMaterial({ color: '#38202e', roughness: .6, side: THREE.DoubleSide });
  const lids = [], lashes = [], eyeballs = [];
  for (const [side, cx] of EYES.entries()) {
    const eye = new THREE.Mesh(new THREE.SphereGeometry(1, 48, 32), new THREE.MeshPhysicalMaterial({ name: 'Cornea', map: texture, color: new THREE.Color().setScalar(.8), roughness: .38, clearcoat: .35, clearcoatRoughness: .25, envMapIntensity: .18 }));
    eye.geometry.scale(RADIUS, .05, .034);
    const positions = eye.geometry.getAttribute('position'), uv = eye.geometry.getAttribute('uv');
    for (let i = 0; i < uv.count; i++) uv.setXY(i, ...portraitUV(cx + positions.getX(i), .126 + positions.getY(i)));
    eye.position.set(cx, .126, .14); eye.name = `Eye${side}`; face.add(eye); eyeballs.push(eye);
    for (const isLower of [false, true]) {
      const mesh = new THREE.Mesh(lidGeometry(cx, isLower), skin);
      mesh.name = `${isLower ? 'Lower' : 'Upper'}Eyelid${side}`;
      mesh.morphTargetDictionary = { [side ? 'blinkRight' : 'blinkLeft']: 0 };
      face.add(mesh); lids.push({ mesh, side });
    }
    const lash = new THREE.Mesh(lashGeometry(cx), lashesMaterial); lash.name = `EyeLine${side}`;
    lash.morphTargetDictionary = { [side ? 'blinkRight' : 'blinkLeft']: 0 };
    face.add(lash); lashes.push({ mesh: lash, side });
  }
  const mouth = new THREE.Group(); mouth.name = 'VoiceMouth'; mouth.position.set(-.025, .0805, depth(-.025, .0805) + .0012);
  mouth.add(new THREE.Mesh(new THREE.CircleGeometry(1, 48), new THREE.MeshBasicMaterial({ color: '#542f39' })));
  const tongue = new THREE.Mesh(new THREE.CircleGeometry(1, 32), new THREE.MeshBasicMaterial({ color: '#d88d9c' }));
  tongue.position.set(0, -.38, .0001); tongue.scale.set(.68, .24, 1); mouth.add(tongue);
  face.add(mouth);

  // Remove the fused generated face while retaining foreground bangs. Nothing is
  // cut from the source file; the original geometry and textures remain intact.
  const material = body.material;
  material.normalScale.setScalar(.35);
  material.onBeforeCompile = shader => {
    shader.uniforms.uPortrait = { value: texture };
    shader.vertexShader = shader.vertexShader.replace('#include <common>', '#include <common>\nvarying vec3 vAssetPosition;')
      .replace('#include <begin_vertex>', '#include <begin_vertex>\nvAssetPosition = position;');
    shader.fragmentShader = shader.fragmentShader.replace('#include <common>', '#include <common>\nvarying vec3 vAssetPosition;\nuniform sampler2D uPortrait;')
      .replace('#include <map_fragment>', `
        #include <map_fragment>
        vec3 generatedColor = diffuseColor.rgb;
        vec2 portraitPoint = vec2(-vAssetPosition.z - 0.0001099408, vAssetPosition.y - 0.4899249971);
        vec2 portraitUv = vec2((600.0 + (portraitPoint.x + 0.025) * 1300.0) / 1199.0, 1.0 - (480.0 - (portraitPoint.y - 0.127) * 1300.0) / 1312.0);
        vec4 artwork = texture2D(uPortrait, portraitUv);
        float hairMask = float(diffuseColor.b > diffuseColor.r * 1.2 && diffuseColor.b > diffuseColor.g && artwork.b > artwork.r * 1.1);
        float laceMask = float(min(min(diffuseColor.r, diffuseColor.g), diffuseColor.b) > 0.25 && min(min(artwork.r, artwork.g), artwork.b) > 0.25 && portraitPoint.y > 0.27);
        float portraitBlend = smoothstep(0.05, 0.16, vAssetPosition.x) * smoothstep(0.02, 0.08, portraitPoint.y) * artwork.a * hairMask * 0.85;
        portraitBlend = max(portraitBlend, smoothstep(0.04, 0.14, vAssetPosition.x) * laceMask * artwork.a * 0.75);
        diffuseColor.rgb = mix(diffuseColor.rgb, artwork.rgb * 0.7, portraitBlend);
      `)
      .replace('#include <roughnessmap_fragment>', `
        #include <roughnessmap_fragment>
        float gold = smoothstep(2.5, 5.0, diffuseColor.r / (diffuseColor.b + 0.01));
        float head = smoothstep(0.46, 0.56, vAssetPosition.y);
        roughnessFactor = clamp(roughnessFactor, mix(mix(mix(0.76, 0.60, head), 0.46, hairMask), 0.32, gold), 0.95);
      `).replace('#include <metalnessmap_fragment>', '#include <metalnessmap_fragment>\nmetalnessFactor *= gold;');
    shader.fragmentShader = shader.fragmentShader.replace('#include <color_fragment>', `
      #include <color_fragment>
      vec2 p = vec2(-vAssetPosition.z - 0.0001099408, vAssetPosition.y - 0.4899249971);
      float oval = pow((p.x + 0.025) / 0.21, 2.0) + pow((p.y - 0.14) / 0.15, 2.0);
      bool eyeRegion = min(length((p - vec2(-0.094, 0.127)) / vec2(0.061, 0.045)), length((p - vec2(0.044, 0.127)) / vec2(0.061, 0.045))) < 1.0;
      bool blue = diffuseColor.b > diffuseColor.r * 1.2 && diffuseColor.b > diffuseColor.g && (diffuseColor.b > diffuseColor.r * 1.6 || diffuseColor.b > 0.12);
      bool artHair = artwork.b > artwork.r * 1.05 && artwork.b > artwork.g;
      bool foregroundHair = (blue || artHair) && generatedColor.g > generatedColor.r * 0.8 && (!eyeRegion || vAssetPosition.x > 0.204);
      bool generatedSkin = generatedColor.r > generatedColor.g * 1.02 && generatedColor.r > generatedColor.b * 1.04;
      bool replaced = p.y < 0.065 ? generatedSkin : artwork.r > artwork.b * 1.03 || eyeRegion || generatedSkin;
      if (oval < 1.0 && p.y > 0.025 && p.y < 0.245 && generatedSkin) discard;
      if (oval < 1.0 && p.y > 0.025 && vAssetPosition.x > 0.045 && !foregroundHair && replaced) discard;
    `);
  };
  material.customProgramCacheKey = () => 'whale-maid-rebuilt-face-14'; material.needsUpdate = true;
  face.traverse(node => { if (node.isMesh) { node.castShadow = false; node.receiveShadow = false; } });
  const movingLids = [...lids, ...lashes];
  return {
    face, lace,
    update(eyes, opening, gazeX, gazeY, vowels, dt = 1 / 60) {
      for (const { mesh, side } of movingLids) mesh.morphTargetInfluences[0] = eyes[side];
      for (const eye of eyeballs) {
        eye.rotation.y = THREE.MathUtils.damp(eye.rotation.y, gazeX * .12, 12, dt);
        eye.rotation.x = THREE.MathUtils.damp(eye.rotation.x, -gazeY * .07, 12, dt);
      }
      const ee = vowels?.ee ?? 0, ou = vowels?.ou ?? 0;
      mouth.scale.set(.0115 * (1 + opening * (ee * .3 - ou * .25)), .00035 + opening * (.009 - ee * .004), 1);
      tongue.visible = opening > .15;
    },
  };
}

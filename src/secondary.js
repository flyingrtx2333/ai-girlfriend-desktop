import * as THREE from 'three';

export function addSecondaryMotion(model) {
  let body;
  model.traverse(node => { if (node.isSkinnedMesh && node.geometry.attributes.uv && !node.morphTargetDictionary) body = node; });
  const original = body.skeleton;
  const find = name => original.bones.find(bone => bone.name.endsWith(name));
  const head = find('Head'), hips = find('Hips'), chest = find('Spine2');
  // Nested links let the tip lag behind its root without extra meshes or
  // per-frame vertex work. Pivots are in this model's original bind frame.
  const definitions = [
    ['HairLeftRoot', head, [.02,.70,-.16], 60,8],
    ['HairLeftMid', 0, [.02,.59,-.17], 44,6],
    ['HairLeftTip', 1, [.02,.48,-.18], 30,4.5],
    ['HairRightRoot', head, [.02,.70,.16], 60,8],
    ['HairRightMid', 3, [.02,.59,.17], 44,6],
    ['HairRightTip', 4, [.02,.48,.18], 30,4.5],
    ['Ahoge', head, [0,.865,.02], 70,7],
    ['WhaleTailRoot', hips, [-.035,.30,-.16], 36,6],
    ['WhaleTailTip', 7, [-.045,.30,-.25], 26,4.5],
    ['SkirtFront', hips, [.12,.34,0], 55,9],
    ['SkirtLeft', hips, [0,.34,.12], 55,9],
    ['SkirtBack', hips, [-.12,.34,0], 55,9],
    ['SkirtRight', hips, [0,.34,-.12], 55,9],
    ['BowLeft', chest, [.15,.49,-.035], 75,8],
    ['BowRight', chest, [.15,.49,.035], 75,8],
  ];
  const parts = [];
  for (const [name, parentRef, pivot, stiffness, damping] of definitions) {
    const parent = typeof parentRef === 'number' ? parts[parentRef].bone : parentRef;
    const bone = new THREE.Bone(); bone.name = name;
    bone.position.copy(parent.worldToLocal(body.localToWorld(new THREE.Vector3(...pivot))));
    parent.add(bone); bone.updateWorldMatrix(true, false);
    const inverse = bone.getWorldQuaternion(new THREE.Quaternion()).invert();
    parts.push({
      bone, stiffness, damping, inverseBind: bone.matrixWorld.clone().invert(), vertices: 0,
      axes: [new THREE.Vector3(1,0,0), new THREE.Vector3(0,1,0), new THREE.Vector3(0,0,1)].map(axis => axis.applyQuaternion(inverse)),
      channels: Array.from({ length: 3 }, () => ({ value: 0, velocity: 0 })),
    });
  }
  const skeleton = new THREE.Skeleton([...original.bones, ...parts.map(part => part.bone)], [...original.boneInverses, ...parts.map(part => part.inverseBind)]);
  model.traverse(node => { if (node.isSkinnedMesh) node.skeleton = skeleton; });
  const canvas = document.createElement('canvas'), image = body.material.map.image;
  canvas.width = Math.min(image.width, 1024); canvas.height = Math.round(image.height * canvas.width / image.width);
  const context = canvas.getContext('2d', { willReadFrequently: true });
  context.drawImage(image, 0, 0, canvas.width, canvas.height);
  const pixels = context.getImageData(0, 0, canvas.width, canvas.height).data;
  const { position, uv, skinIndex, skinWeight } = body.geometry.attributes;
  const smooth = THREE.MathUtils.smoothstep, clamp = THREE.MathUtils.clamp;
  const headIndex = original.bones.indexOf(head);
  for (let i = 0; i < position.count; i++) {
    const x = position.getX(i), y = position.getY(i), z = position.getZ(i);
    if (y < .18) continue;
    const px = clamp(Math.round(uv.getX(i) * (canvas.width - 1)), 0, canvas.width - 1);
    const py = clamp(Math.round(uv.getY(i) * (canvas.height - 1)), 0, canvas.height - 1);
    const pixel = (py * canvas.width + px) * 4;
    const blue = pixels[pixel + 2] > pixels[pixel] * 1.15 && pixels[pixel + 2] > pixels[pixel + 1];
    const ids = [skinIndex.getX(i), skinIndex.getY(i), skinIndex.getZ(i), skinIndex.getW(i)];
    const weights = [skinWeight.getX(i), skinWeight.getY(i), skinWeight.getZ(i), skinWeight.getW(i)];
    const headWeight = weights.reduce((sum, weight, k) => sum + (ids[k] === headIndex ? weight : 0), 0);
    let first = 0, second = 0, blend = 0, weight = 0;
    // The irises share the hair's blue palette. Keep the entire face plate
    // rigidly attached to Head when assigning the side-hair weights.
    const facePlate = x > .14 && y > .54 && y < .705 && Math.abs(z) < .17;
    if (blue && !facePlate && y > .395 && y < .74 && Math.abs(z) > .115 && headWeight > .3) {
      const distance = clamp((.69 - y) / .24, 0, 1) * 2;
      const link = Math.min(1, Math.floor(distance));
      first = (z < 0 ? 0 : 3) + link; second = first + 1; blend = distance - link;
      weight = .88 * smooth(Math.abs(z), .115, .19) * smooth(.74 - y, 0, .12) * smooth(y, .395, .425) * smooth(headWeight, .3, .85);
    } else if (blue && y > .87) {
      first = second = 6; weight = .9 * smooth(y, .87, .93);
    } else if (blue && y < .43 && z < -.185) {
      first = 7; second = 8; blend = smooth(-z, .22, .30);
      weight = .9 * smooth(-z, .185, .255) * smooth(.43 - y, 0, .06) * (1 - smooth(x, -.02, .065));
    } else if (y < .40 && y > .19) {
      const radius = Math.hypot(x, z), direction = ((Math.atan2(z,x) + Math.PI * 2) % (Math.PI * 2)) / (Math.PI / 2);
      first = 9 + Math.floor(direction); second = 9 + (Math.floor(direction) + 1) % 4; blend = direction % 1;
      weight = .55 * smooth(radius, .12, .19) * smooth(.40 - y, 0, .12) * smooth(y, .19, .225);
    } else if (blue && y > .455 && y < .54 && Math.abs(z) < .105 && x > .13) {
      first = second = z < 0 ? 13 : 14;
      weight = .6 * smooth(Math.abs(z), .012, .040) * smooth(y, .455, .48) * smooth(.54 - y, 0, .025);
    }
    if (weight < .001) continue;
    const order = [0,1,2,3].sort((a,b) => weights[b] - weights[a]);
    const retained = weights[order[0]] + weights[order[1]];
    const w0 = weights[order[0]] / retained * (1 - weight), w1 = weights[order[1]] / retained * (1 - weight);
    skinIndex.setXYZW(i, ids[order[0]], ids[order[1]], original.bones.length + first, original.bones.length + second);
    skinWeight.setXYZW(i, w0, w1, weight * (1 - blend), weight * blend);
    parts[first].vertices++; if (second !== first) parts[second].vertices++;
  }
  skinIndex.needsUpdate = skinWeight.needsUpdate = true;
  model.userData.secondaryMotion = Object.fromEntries(parts.map(part => [part.bone.name, part.vertices]));
  const rotation = new THREE.Quaternion(), targets = parts.map(() => [0,0,0]);
  return function update(dt, time, motion, joints, balanceChannels, liftVelocity) {
    const headSpeed = axis => joints.Head.channels[axis].velocity + joints.Neck.channels[axis].velocity + joints.Spine2.channels[axis].velocity;
    const bodySpeed = axis => joints.Hips.channels[axis].velocity + joints.Spine.channels[axis].velocity;
    const wind = Math.sin(time * .95) * .012 * motion;
    parts.forEach((part, index) => {
      const target = targets[index];
      if (index < 6) {
        const link = index % 3, side = index < 3 ? -1 : 1;
        target[0] = -headSpeed(0) * (.08 + link * .025) + wind * (1 + link * .35);
        target[1] = -headSpeed(1) * (.09 + link * .025) + Math.sin(time * 1.15 + side * .45 - link * .35) * .006 * motion;
        target[2] = -headSpeed(2) * (.10 + link * .025) + side * wind * .35;
      } else if (index === 6) {
        target[0] = -headSpeed(0) * .13 + wind * 1.5;
        target[1] = -headSpeed(1) * .08; target[2] = -headSpeed(2) * .13;
      } else if (index < 9) {
        target[0] = Math.sin(time * 1.05 - (index - 7) * .5) * .055 * motion - bodySpeed(0) * .1;
        target[1] = -bodySpeed(1) * .16; target[2] = -liftVelocity * .07;
      } else if (index < 13) {
        const angle = (index - 9) * Math.PI / 2;
        target[0] = -bodySpeed(0) * .09 + balanceChannels[0].velocity * .25 + wind * Math.cos(angle) * .45;
        target[1] = -bodySpeed(1) * .12;
        target[2] = -bodySpeed(2) * .09 - liftVelocity * .06 + wind * Math.sin(angle) * .45;
      } else {
        const side = index === 13 ? -1 : 1;
        target[0] = -joints.Spine2.channels[0].velocity * .1 + side * Math.sin(time * 1.5) * .012 * motion;
        target[1] = -joints.Spine2.channels[1].velocity * .1;
        target[2] = -joints.Spine2.channels[2].velocity * .1 + wind * .6;
      }
      part.bone.quaternion.identity();
      for (let axis = 0; axis < 3; axis++) {
        const channel = part.channels[axis], goal = clamp(target[axis], -.12, .12);
        const steps = Math.max(1, Math.ceil(dt * 120)), step = dt / steps;
        for (let i = 0; i < steps; i++) {
          channel.velocity += (part.stiffness * (goal - channel.value) - part.damping * channel.velocity) * step;
          channel.value += channel.velocity * step;
        }
        part.bone.quaternion.multiply(rotation.setFromAxisAngle(part.axes[axis], channel.value));
      }
    });
  };
}

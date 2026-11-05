import * as THREE from 'three';
import { GLTFLoader } from 'three/addons/loaders/GLTFLoader.js';
import { sampleMotion } from './motions.js';
import { softenMaterial } from './lighting.js';
import { addSecondaryMotion } from './secondary.js';
import { plantFeet } from './footing.js';
import { loadIdleLayer } from './idle.js';
import { repairAppearance } from './appearance.js';

export async function loadWhaleMaid(onProgress) {
  const gltf = await new GLTFLoader().loadAsync('/models/whale-maid-v2/whale-maid-rigged.glb?v=13-eyes', onProgress);
  const idle = await loadIdleLayer();
  gltf.scene.updateMatrixWorld(true);
  const materials = new Map();
  gltf.scene.traverse(mesh => {
    if (!mesh.isMesh) return;
    const source = mesh.material;
    if (!materials.has(source)) materials.set(source, softenMaterial(source));
    mesh.material = materials.get(source);
    mesh.castShadow = !!mesh.material.map && !mesh.morphTargetDictionary;
    mesh.receiveShadow = true;
  });
  for (const source of materials.keys()) source.dispose();
  const updateSecondary = addSecondaryMotion(gltf.scene);
  const joints = {};
  const responses = {
    head: { frequency: 16, speed: 1, acceleration: 4 },
    shoulder: { frequency: 12, speed: .7, acceleration: 4 },
    arm: { frequency: 16, speed: 1.6, acceleration: 6 },
    forearm: { frequency: 18, speed: 2, acceleration: 8 },
    hand: { frequency: 22, speed: 1.8, acceleration: 10 },
    body: { frequency: 14, speed: 1.4, acceleration: 6 },
  };
  // Retain velocity when a gesture is interrupted. Limits also protect rapid
  // menu switching from turning a large pose change into a one-frame jerk.
  function follow(channel, target, dt, response, immediate = false) {
    if (immediate) { channel.value = target; channel.velocity = 0; return target; }
    const { frequency, speed, acceleration } = response;
    const delta = channel.value - target, impulse = channel.velocity + frequency * delta;
    const decay = Math.exp(-frequency * dt);
    const desiredVelocity = (channel.velocity - frequency * impulse * dt) * decay;
    const velocity = THREE.MathUtils.clamp(
      THREE.MathUtils.clamp(desiredVelocity, channel.velocity - acceleration * dt, channel.velocity + acceleration * dt), -speed, speed,
    );
    channel.value = Math.abs(velocity - desiredVelocity) < 1e-8
      ? target + (delta + impulse * dt) * decay
      : channel.value + (channel.velocity + velocity) * dt * .5;
    channel.velocity = velocity;
    return channel.value;
  }
  for (const name of ['Hips', 'Head', 'Neck', 'Spine', 'Spine1', 'Spine2', 'LeftShoulder', 'RightShoulder', 'LeftArm', 'RightArm', 'LeftForeArm', 'RightForeArm', 'LeftHand', 'RightHand', 'LeftUpLeg', 'RightUpLeg', 'LeftLeg', 'RightLeg', 'LeftFoot', 'RightFoot']) {
    let bone;
    gltf.scene.traverse(node => { if (node.isBone && node.name.endsWith(name)) bone = node; });
    if (!bone) throw new Error(`角色缺少骨骼：${name}`);
    const inverse = bone.getWorldQuaternion(new THREE.Quaternion()).invert();
    const kind = /Head|Neck/.test(name) ? 'head' : /Shoulder/.test(name) ? 'shoulder' : /ForeArm/.test(name) ? 'forearm' : /Arm/.test(name) ? 'arm' : /Hand/.test(name) ? 'hand' : 'body';
    joints[name] = {
      bone, rest: bone.quaternion.clone(), channels: Array.from({ length: 3 }, () => ({ value: 0, velocity: 0 })), response: responses[kind],
      axes: [new THREE.Vector3(1, 0, 0), new THREE.Vector3(0, 1, 0), new THREE.Vector3(0, 0, 1)].map(axis => axis.applyQuaternion(inverse)),
    };
  }
  const rotation = new THREE.Quaternion();
  let actionPose = null;
  function turn(name, x, y, z, dt, immediate = false) {
    const spine = name.startsWith('Spine');
    const extra = actionPose?.joints[spine ? 'Spine2' : name];
    const weight = spine ? name === 'Spine2' ? .5 : .25 : 1;
    if (extra) { x += extra[0] * weight; y += extra[1] * weight; z += extra[2] * weight; }
    const live = idle.joints[name];
    if (live) { x += live[0]; y += live[1]; z += live[2]; }
    const joint = joints[name];
    joint.bone.quaternion.copy(joint.rest);
    for (let i = 0; i < 3; i++) {
      const angle = follow(joint.channels[i], i === 0 ? x : i === 1 ? y : z, dt, joint.response, immediate);
      joint.bone.quaternion.multiply(rotation.setFromAxisAngle(joint.axes[i], angle));
    }
    joint.bone.quaternion.normalize();
  }
  const fingers = [];
  const normal = new THREE.Vector3(), forward = new THREE.Vector3(), point = new THREE.Vector3();
  const findBone = name => {
    let bone;
    gltf.scene.traverse(node => { if (node.isBone && node.name.endsWith(name)) bone = node; });
    return bone;
  };
  for (const [sideIndex, side] of ['Left', 'Right'].entries()) {
    const hand = joints[`${side}Hand`].bone.getWorldPosition(new THREE.Vector3());
    const index = findBone(`${side}HandIndex1`).getWorldPosition(new THREE.Vector3()).sub(hand);
    const pinky = findBone(`${side}HandPinky1`).getWorldPosition(new THREE.Vector3()).sub(hand);
    normal.crossVectors(index, pinky).normalize();
    if (normal.x < 0) normal.negate();
    for (const [fingerIndex, finger] of ['Thumb', 'Index', 'Middle', 'Ring', 'Pinky'].entries()) {
      for (let segment = 1; segment <= 3; segment++) {
        const bone = findBone(`${side}Hand${finger}${segment}`);
        bone.getWorldPosition(point);
        bone.children[0].getWorldPosition(forward).sub(point).normalize();
        const axis = forward.clone().cross(normal).normalize().applyQuaternion(bone.getWorldQuaternion(new THREE.Quaternion()).invert());
        const base = (fingerIndex ? .07 + fingerIndex * .025 : .045) * (segment === 1 ? .7 : 1);
        fingers.push({ bone, rest: bone.quaternion.clone(), axis, base, sideIndex, strength: fingerIndex ? segment === 1 ? .7 : 1.05 : .35, channel: { value: base, velocity: 0 } });
      }
    }
  }
  function curlFingers(dt, immediate = false) {
    for (const finger of fingers) {
      const grip = (actionPose?.hands?.[finger.sideIndex] ?? 0) + fingerActivity[finger.sideIndex];
      const angle = follow(finger.channel, Math.max(0, finger.base + grip * finger.strength), dt, responses.hand, immediate);
      finger.bone.quaternion.copy(finger.rest).multiply(rotation.setFromAxisAngle(finger.axis, angle));
    }
  }
  const fingerActivity = [0, 0];
  curlFingers(0, true);
  // Start in the same relaxed stance that idle returns to; never display bind pose.
  turn('LeftArm', -.48, 0, -.04, 0, true);
  turn('RightArm', .52, 0, -.04, 0, true);
  turn('LeftForeArm', .06, 0, .65, 0, true);
  turn('RightForeArm', -.07, 0, .58, 0, true);
  turn('LeftHand', 0, 0, -.2, 0, true);
  turn('RightHand', 0, 0, -.2, 0, true);
  const root = new THREE.Group();
  root.name = 'TripoWhaleMaid';
  const pose = new THREE.Group();
  root.add(pose);
  const model = gltf.scene;
  model.rotation.y = -Math.PI / 2;
  model.updateMatrixWorld(true);
  const bounds = new THREE.Box3().setFromObject(model);
  const center = bounds.getCenter(new THREE.Vector3());
  const scale = 3.7 / bounds.getSize(new THREE.Vector3()).y;
  model.scale.setScalar(scale);
  model.position.set(-center.x * scale, -1.7 - bounds.min.y * scale, -center.z * scale);
  pose.add(model);
  root.updateMatrixWorld(true);
  const updateFooting = plantFeet(model, joints);

  const expressions = [];
  model.traverse(mesh => {
    if (mesh.morphTargetDictionary) {
      mesh.material.forceSinglePass = true;
      expressions.push(mesh);
    }
  });
  const appearance = await repairAppearance(root);
  root.userData.appearance = { edition: 14, lace: appearance.lace };

  // One cheap envelope; pointer movement never traverses the model's triangles.
  const hitBounds = new THREE.Box3().setFromObject(root).expandByScalar(.06);
  const inverse = new THREE.Matrix4(), localRay = new THREE.Ray(), hitPoint = new THREE.Vector3();
  function hitTest(ray) {
    root.updateWorldMatrix(true, false);
    localRay.copy(ray).applyMatrix4(inverse.copy(root.matrixWorld).invert());
    localRay.origin.y -= pose.position.y;
    if (!localRay.intersectBox(hitBounds, hitPoint)) return null;
    hitPoint.y += pose.position.y;
    return { point: root.localToWorld(hitPoint.clone()) };
  }
  let mouth = 0, talking = 0, emphasis = 0, reactionKind = '', reactionStarted = 0;
  const eyes = [0, 0], balance = new THREE.Vector3();
  const balanceChannels = Array.from({ length: 3 }, () => ({ value: 0, velocity: 0 }));
  const balanceResponse = { frequency: 14, speed: .22, acceleration: 1.6 };
  const lift = { value: 0, velocity: 0 };
  const liftResponse = { frequency: 28, speed: 2, acceleration: 24 };
  function update(dt, { time, motion, happy, shock, dragging, looking, pointer, blinking, volume, vowels, activity }) {
    const reacting = !activity && !dragging ? shock > 0 ? 'startle' : happy ? 'wave' : '' : '';
    if (reacting !== reactionKind) { reactionKind = reacting; reactionStarted = time; }
    const performed = activity || (reactionKind ? { name: reactionKind, time: time - reactionStarted } : null);
    actionPose = sampleMotion(performed?.name, performed?.time);
    pose.position.y = follow(lift, actionPose?.lift ?? 0, dt, liftResponse);
    if (pose.position.y < 0) { pose.position.y = lift.value = 0; lift.velocity = Math.max(0, lift.velocity); }
    pose.rotation.y = THREE.MathUtils.damp(pose.rotation.y, actionPose?.yaw ?? 0, 12, dt);
    pose.rotation.z = THREE.MathUtils.damp(pose.rotation.z, 0, 8, dt);
    const closing = blinking || actionPose?.blink;
    for (let i = 0; i < 2; i++) {
      const target = closing ? 1 : actionPose?.eyes?.[i] ?? 0;
      eyes[i] = THREE.MathUtils.damp(eyes[i], target, target > eyes[i] ? 48 : 30, dt);
    }
    for (const material of materials.values()) material.userData.blinkUniform?.value.set(eyes[0], eyes[1]);
    const opening = THREE.MathUtils.clamp((volume - .035) * 1.8, 0, 1);
    mouth = THREE.MathUtils.damp(mouth, opening, opening > mouth ? 24 : 32, dt);
    talking = THREE.MathUtils.damp(talking, volume > .055 ? 1 : 0, volume > .055 ? 3.5 : 1.6, dt);
    emphasis = THREE.MathUtils.damp(emphasis, volume, 6, dt);
    // The captured whole-body layer never stops for an emote. Speech, gaze and
    // authored gestures add to it, with smaller speech gestures on an occupied arm.
    idle.update(dt, talking, motion);
    const speech = talking * motion, leftFree = actionPose?.joints.LeftArm ? .2 : 1;
    const rightFree = actionPose?.joints.RightArm ? .2 : 1;
    const leftBeat = speech * (.5 + Math.sin(time * 1.7) * .5) * leftFree;
    const rightBeat = speech * (.5 + Math.sin(time * 1.7 + 1.8) * .5) * rightFree;
    const gazeX = looking ? pointer.x * (actionPose ? .65 : 1) : Math.sin(Math.floor(time / 4.8) * 2.4) * .2 * motion;
    const gazeY = looking ? pointer.y * (actionPose ? .65 : 1) : Math.sin(time * .35) * .14 * motion;
    const breath = Math.sin(time * 1.55) * .009 * motion;
    turn('Hips', 0, -gazeX * .008, 0, dt);
    turn('Head', Math.sin(time * .43) * .018 * motion, gazeX * .13, gazeY * .05 - emphasis * .024 * motion, dt);
    turn('Neck', 0, gazeX * .028, gazeY * .016 - emphasis * .01 * motion, dt);
    turn('Spine', 0, gazeX * .008, -breath * .25, dt);
    turn('Spine1', 0, gazeX * .012, breath * .45 + emphasis * .008 * motion, dt);
    turn('Spine2', 0, gazeX * .018, breath + emphasis * .016 * motion, dt);
    turn('LeftShoulder', leftBeat * .025 + breath * .25, 0, 0, dt);
    turn('RightShoulder', -rightBeat * .023 - breath * .25, 0, 0, dt);
    turn('LeftArm', -.48 + leftBeat * .13 - (dragging ? .06 : 0), -.015 * speech, -.04 + breath * .3, dt);
    turn('RightArm', .52 - rightBeat * .12 + (dragging ? .06 : 0), .015 * speech, -.04 + breath * .3, dt);
    turn('LeftForeArm', .06 + leftBeat * .06, 0, .65 + leftBeat * .13, dt);
    turn('RightForeArm', -.07 - rightBeat * .055, 0, .58 + rightBeat * .12, dt);
    turn('LeftHand', leftBeat * .025, leftBeat * .04, -.2 + leftBeat * .045, dt);
    turn('RightHand', -rightBeat * .025, -rightBeat * .04, -.2 + rightBeat * .045, dt);
    for (const side of ['Left', 'Right']) {
      turn(`${side}UpLeg`, 0, 0, 0, dt);
      turn(`${side}Leg`, 0, 0, 0, dt);
    }
    const posture = [idle.position.x - gazeX * .008, Math.min(idle.position.y, 0) - .018 * motion - Math.abs(breath) * .12, idle.position.z + emphasis * .012 * motion];
    for (let i = 0; i < 3; i++) balance.setComponent(i, follow(balanceChannels[i], (actionPose?.balance?.[i] ?? 0) + posture[i], dt, balanceResponse));
    updateFooting(balance);
    fingerActivity[0] = (.025 + Math.sin(time * .85) * .02 + leftBeat * .035) * motion;
    fingerActivity[1] = (.025 + Math.sin(time * .85 + 1.4) * .02 + rightBeat * .035) * motion;
    curlFingers(dt);
    updateSecondary(dt, time, motion, joints, balanceChannels, lift.velocity);
    for (const mesh of expressions) {
      const dict = mesh.morphTargetDictionary, weights = mesh.morphTargetInfluences;
      weights[dict.blinkLeft] = eyes[0];
      weights[dict.blinkRight] = eyes[1];
      for (const [i, name] of ['aa', 'ee', 'ou'].entries()) {
        if (dict[name] === undefined) continue;
        const target = Math.max(mouth * (vowels?.[name] ?? (name === 'aa' ? 1 : 0)), actionPose?.mouth?.[i] ?? 0);
        weights[dict[name]] = THREE.MathUtils.damp(weights[dict[name]], target, 26, dt);
      }
    }
    appearance.update(eyes, Math.max(mouth, ...(actionPose?.mouth ?? [0])), gazeX, gazeY, vowels, dt);
  }
  return { root, update, hitTest, get lift() { return pose.position.y; } };
}

import * as THREE from 'three';
import { GLTFLoader } from 'three/addons/loaders/GLTFLoader.js';

// AIRI's captured idle has seven torso links. Preserve their combined rotations
// when adapting it to this three-link Mixamo spine, rather than dropping links.
const chains = {
  Hips: ['root'], Spine: ['torso_1', 'torso_2'], Spine1: ['torso_3', 'torso_4'],
  Spine2: ['torso_5', 'torso_6', 'torso_7'], Neck: ['neck_1'], Head: ['neck_2', 'head'],
  LeftShoulder: ['l_shoulder'], RightShoulder: ['r_shoulder'],
  LeftArm: ['l_up_arm'], RightArm: ['r_up_arm'],
  LeftForeArm: ['l_low_arm'], RightForeArm: ['r_low_arm'],
  LeftHand: ['l_hand'], RightHand: ['r_hand'],
};

export async function loadIdleLayer() {
  const gltf = await new GLTFLoader().loadAsync('/animations/airi/idle_loop.vrma');
  const clip = gltf.animations[0];
  if (!clip) throw new Error('待机动作加载失败');
  const tracks = new Map(clip.tracks.map(track => [track.name, track.createInterpolant()]));
  const overlap = .65, period = clip.duration - overlap;
  const sourceToModel = new THREE.Quaternion().setFromAxisAngle(new THREE.Vector3(0,1,0), Math.PI / 2);
  const modelToSource = sourceToModel.clone().invert();
  const first = new THREE.Quaternion(), second = new THREE.Quaternion(), sample = new THREE.Quaternion();
  const euler = new THREE.Euler(0,0,0,'XYZ');
  const identity = new THREE.Quaternion();
  const motion = Object.fromEntries(Object.keys(chains).map(name => [name, [0,0,0]]));
  const inverses = {}, position = new THREE.Vector3(), origin = new THREE.Vector3();

  function rotationAt(name, phase, out) {
    const track = tracks.get(`${name}.quaternion`);
    if (!track) return out.identity();
    if (phase >= overlap) return out.fromArray(track.evaluate(phase)).normalize();
    first.fromArray(track.evaluate(period + phase)).normalize();
    second.fromArray(track.evaluate(phase)).normalize();
    const t = phase / overlap, weight = t * t * (3 - 2 * t);
    return out.copy(first).slerp(second, weight);
  }
  function chainAt(nodes, phase, out) {
    out.identity();
    for (const name of nodes) out.multiply(rotationAt(name, phase, sample));
    return out.normalize();
  }
  function positionAt(phase, out) {
    const track = tracks.get('root.position');
    out.fromArray(track.evaluate(phase));
    if (phase < overlap) {
      const start = out.clone();
      out.fromArray(track.evaluate(period + phase));
      const t = phase / overlap;
      out.lerp(start, t * t * (3 - 2 * t));
    }
    return out.multiplyScalar(.01);
  }
  for (const [name, nodes] of Object.entries(chains)) inverses[name] = chainAt(nodes, 0, new THREE.Quaternion()).invert();
  positionAt(0, origin);
  const group = new THREE.Quaternion(), scaled = new THREE.Quaternion();
  let clock = 0;
  return {
    joints: motion, position,
    update(dt, speech, amount) {
      clock += dt * (1 + speech * .16);
      const phase = clock % period;
      for (const [name, nodes] of Object.entries(chains)) {
        chainAt(nodes, phase, group).multiply(inverses[name]);
        group.premultiply(sourceToModel).multiply(modelToSource);
        scaled.copy(identity).slerp(group, (1.65 + speech * .45) * amount);
        euler.setFromQuaternion(scaled, 'XYZ');
        motion[name][0] = euler.x; motion[name][1] = euler.y; motion[name][2] = euler.z;
      }
      positionAt(phase, position).sub(origin).multiplyScalar(1.55 * amount);
    },
  };
}

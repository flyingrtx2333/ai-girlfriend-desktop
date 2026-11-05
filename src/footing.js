import * as THREE from 'three';

export function plantFeet(model, joints) {
  model.updateWorldMatrix(true, true);
  const hips = joints.Hips.bone;
  const hipRest = hips.position.clone();
  const hipPoint = model.worldToLocal(hips.getWorldPosition(new THREE.Vector3()));
  const legs = ['Left', 'Right'].map(side => {
    const thigh = joints[`${side}UpLeg`].bone, shin = joints[`${side}Leg`].bone, foot = joints[`${side}Foot`].bone;
    const a = model.worldToLocal(thigh.getWorldPosition(new THREE.Vector3()));
    const b = model.worldToLocal(shin.getWorldPosition(new THREE.Vector3()));
    const c = model.worldToLocal(foot.getWorldPosition(new THREE.Vector3()));
    const direction = c.clone().sub(a).normalize(), pole = b.clone().sub(a);
    pole.addScaledVector(direction, -pole.dot(direction)).normalize();
    return {
      thigh, shin, foot, target: c, pole,
      upper: a.distanceTo(b), lower: b.distanceTo(c),
      footRest: foot.quaternion.clone(),
      footRotation: model.getWorldQuaternion(new THREE.Quaternion()).invert().multiply(foot.getWorldQuaternion(new THREE.Quaternion())),
    };
  });
  const a = new THREE.Vector3(), b = new THREE.Vector3(), target = new THREE.Vector3(), knee = new THREE.Vector3();
  const direction = new THREE.Vector3(), pole = new THREE.Vector3(), delta = new THREE.Vector3(), origin = new THREE.Vector3();
  const rotation = new THREE.Quaternion(), parentRotation = new THREE.Quaternion(), modelRotation = new THREE.Quaternion();
  const scale = new THREE.Vector3();
  function aim(bone, end, point) {
    bone.getWorldPosition(a); end.getWorldPosition(b);
    direction.copy(b).sub(a).normalize(); delta.copy(point).sub(a).normalize();
    rotation.setFromUnitVectors(direction, delta).multiply(bone.getWorldQuaternion(parentRotation));
    bone.quaternion.copy(bone.parent.getWorldQuaternion(parentRotation).invert().multiply(rotation));
    bone.updateWorldMatrix(false, true);
  }
  return function update(balance) {
    hips.position.copy(hipRest);
    for (const leg of legs) leg.foot.quaternion.copy(leg.footRest);
    if (balance.lengthSq() < 1e-12) return;
    model.updateWorldMatrix(true, false);
    delta.copy(balance);
    model.parent.localToWorld(delta).sub(model.parent.getWorldPosition(origin));
    target.copy(hipPoint); model.localToWorld(target).add(delta);
    hips.position.copy(hips.parent.worldToLocal(target));
    hips.updateWorldMatrix(true, true);
    model.getWorldQuaternion(modelRotation); model.getWorldScale(scale);
    for (const leg of legs) {
      target.copy(leg.target); model.localToWorld(target);
      leg.thigh.getWorldPosition(a);
      direction.copy(target).sub(a);
      const upper = leg.upper * scale.x, lower = leg.lower * scale.x;
      const distance = THREE.MathUtils.clamp(direction.length(), Math.abs(upper - lower) + 1e-5, upper + lower - 1e-5);
      direction.normalize();
      pole.copy(leg.pole).applyQuaternion(modelRotation);
      pole.addScaledVector(direction, -pole.dot(direction)).normalize();
      const along = (upper * upper - lower * lower + distance * distance) / (2 * distance);
      knee.copy(a).addScaledVector(direction, along).addScaledVector(pole, Math.sqrt(Math.max(0, upper * upper - along * along)));
      aim(leg.thigh, leg.shin, knee);
      aim(leg.shin, leg.foot, target);
      rotation.copy(modelRotation).multiply(leg.footRotation);
      leg.foot.quaternion.copy(leg.foot.parent.getWorldQuaternion(parentRotation).invert().multiply(rotation));
      leg.foot.updateWorldMatrix(false, true);
    }
  };
}

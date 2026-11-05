import assert from 'node:assert/strict';
import { mkdir, writeFile } from 'node:fs/promises';
import { chromium } from 'playwright';

const browser = await chromium.launch({ channel: 'chrome', headless: true });
const page = await browser.newPage({ viewport: { width: 1200, height: 800 }, deviceScaleFactor: 1 });
const errors = [];
page.on('pageerror', error => errors.push(error.message));
const results = [];
const expressionEvidence = {};
const check = async (name, fn) => { await fn(); results.push(name); };
const patch = rect => page.evaluate(rect => new Promise(resolve => requestAnimationFrame(() => {
  const canvas = document.querySelector('#stage canvas'), gl = canvas.getContext('webgl2');
  const x = Math.round(rect[0] * canvas.width), y = Math.round((1 - rect[3]) * canvas.height);
  const width = Math.round((rect[2] - rect[0]) * canvas.width), height = Math.round((rect[3] - rect[1]) * canvas.height);
  const pixels = new Uint8Array(width * height * 4);
  gl.readPixels(x, y, width, height, gl.RGBA, gl.UNSIGNED_BYTE, pixels);
  resolve(Array.from(pixels));
})), rect);
const difference = (a, b) => a.reduce((sum, value, i) => sum + (i % 4 === 3 ? 0 : Math.abs(value - b[i])), 0) / (a.length * .75);
await mkdir('evidence/edition14', { recursive: true });
try {
  await page.emulateMedia({ reducedMotion: 'reduce' });
  await page.goto('http://127.0.0.1:4173/?appearance=model', { waitUntil: 'networkidle' });
  await check('近景与全身视角', async () => {
    await page.getByText('自在摸鱼', { exact: true }).waitFor();
    assert.equal(await page.locator('#app').getAttribute('data-view'), 'close');
    await page.screenshot({ path: 'evidence/edition14/companion.png' });
    await page.getByRole('button', { name: '全身', exact: true }).click();
    await page.waitForTimeout(1600);
    assert.equal(await page.locator('#app').getAttribute('data-view'), 'full');
  });
  await check('模型渲染', async () => {
    await page.getByText('自在摸鱼', { exact: true }).waitFor();
    assert.equal(await page.locator('canvas').count(), 1);
    await page.screenshot({ path: 'evidence/idle.png' });
  });
  await check('骨骼驱动与表情贴合', async () => {
    const proof = await page.evaluate(async () => {
      const { loadWhaleMaid } = await import('/src/character.js');
      const { MOTIONS } = await import('/src/motions.js');
      const { Vector3 } = await import('/node_modules/three/build/three.module.js');
      const character = await loadWhaleMaid();
      let body;
      const face = character.root.getObjectByName('FaceSurface');
      character.root.traverse(mesh => {
        if (mesh.isSkinnedMesh && mesh.geometry.attributes.uv && !mesh.morphTargetDictionary) body = mesh;
      });
      if (!body || !face) throw new Error('Body and rebuilt face must both load.');
      const refresh = () => {
        character.root.updateMatrixWorld(true);
        character.root.traverse(mesh => { if (mesh.isSkinnedMesh) mesh.skeleton.update(); });
      };
      const vertex = (mesh, i) => mesh.getVertexPosition(i, new Vector3()).applyMatrix4(mesh.matrixWorld);
      refresh();
      const faceBefore = vertex(face, 0);
      let nearest = 0, sole = 0, lowest = Infinity, distance = Infinity;
      for (let i = 0; i < body.geometry.attributes.position.count; i++) {
        const position = vertex(body, i), d = position.distanceTo(faceBefore);
        if (d < distance) { nearest = i; distance = d; }
        const y = body.geometry.attributes.position.getY(i);
        if (y < lowest) { sole = i; lowest = y; }
      }
      const headBefore = vertex(body, nearest), soleBefore = vertex(body, sole);
      for (let i = 0; i < 90; i++) character.update(1 / 60, {
        time: 0, motion: 0, happy: false, shock: 0, dragging: false,
        looking: true, pointer: { x: 1, y: .5 }, blinking: false, volume: 0,
      });
      refresh();
      const headAfter = vertex(body, nearest), faceAfter = vertex(face, 0);
      const bonePoint = name => body.skeleton.bones.find(bone => bone.name.endsWith(name)).getWorldPosition(new Vector3());
      const restingArms = ['Left', 'Right'].map(side => {
        const shoulder = bonePoint(`${side}Arm`), hand = bonePoint(`${side}Hand`);
        return { side, drop: shoulder.y - hand.y, spreadRatio: Math.abs(hand.x - shoulder.x) / (shoulder.y - hand.y) };
      });
      const state = { motion: 0, shock: 0, dragging: false, looking: false, pointer: { x: 0, y: 0 }, blinking: false, volume: 0 };
      for (let i = 0; i < 90; i++) character.update(1 / 60, { ...state, time: 0, happy: false });
      refresh();
      const handBefore = bonePoint('LeftHand');
      for (let i = 0; i < 90; i++) character.update(1 / 60, { ...state, time: i / 60, happy: true });
      refresh();
      const greetingHandRise = bonePoint('LeftHand').y - handBefore.y;
      for (let i = 0; i < 90; i++) character.update(1 / 60, { ...state, time: 0, happy: false });
      refresh();
      const handReturnError = bonePoint('LeftHand').distanceTo(handBefore);
      const restingRotations = body.skeleton.bones.map(bone => bone.quaternion.clone().normalize());
      const restingFeet = ['Left', 'Right'].map(side => bonePoint(`${side}Foot`));
      const motionProof = {};
      for (const [name, spec] of Object.entries(MOTIONS)) {
        let maxAngle = 0, maxLift = 0, footDrift = 0, secondaryAngle = 0;
        for (let t = 0; t < spec.duration; t += 1 / 30) {
          character.update(1 / 30, { ...state, time: 0, happy: false, activity: { name, time: t } });
          refresh();
          maxLift = Math.max(maxLift, character.lift);
          body.skeleton.bones.forEach((bone, i) => { maxAngle = Math.max(maxAngle, bone.quaternion.clone().normalize().angleTo(restingRotations[i])); });
          for (const [i, side] of ['Left', 'Right'].entries()) {
            const position = bonePoint(`${side}Foot`); position.y -= character.lift;
            footDrift = Math.max(footDrift, position.distanceTo(restingFeet[i]));
          }
          for (const bone of body.skeleton.bones.filter(bone => /HairLeft|HairRight|Ahoge|WhaleTail/.test(bone.name))) secondaryAngle = Math.max(secondaryAngle, bone.quaternion.angleTo(bone.quaternion.clone().identity()));
        }
        for (let i = 0; i < 45; i++) character.update(1 / 30, { ...state, time: 0, happy: false });
        // Hair and cloth can still settle after the authored body pose returns.
        const returnError = Math.max(character.lift, ...body.skeleton.bones.map((bone, i) => bone.name.startsWith('mixamorig') ? bone.quaternion.clone().normalize().angleTo(restingRotations[i]) : 0));
        motionProof[name] = { maxAngle, maxLift, returnError, footDrift, secondaryAngle };
      }
      // A gesture must leave the rest of the body alive. Inspect actual bone
      // transforms through a full captured idle cycle, with the feet constrained.
      const liveNames = ['Hips', 'Spine2', 'Head', 'RightArm', 'RightHand', 'LeftLeg', 'HairLeftTip', 'SkirtFront', 'WhaleTailTip'];
      const liveBones = liveNames.map(name => body.skeleton.bones.find(bone => bone.name.endsWith(name)));
      const liveRest = liveBones.map(bone => bone.quaternion.clone().normalize());
      const liveDuringGesture = Object.fromEntries(liveNames.map(name => [name, 0]));
      let liveFootDrift = 0;
      for (let i = 0; i < 600; i++) {
        character.update(1 / 60, { ...state, motion: 1, time: i / 60, happy: false, activity: { name: 'wave', time: i / 60 % MOTIONS.wave.duration } });
        refresh();
        liveBones.forEach((bone, index) => { liveDuringGesture[liveNames[index]] = Math.max(liveDuringGesture[liveNames[index]], bone.quaternion.clone().normalize().angleTo(liveRest[index])); });
        ['Left', 'Right'].forEach((side, index) => { liveFootDrift = Math.max(liveFootDrift, bonePoint(`${side}Foot`).distanceTo(restingFeet[index])); });
      }
      return {
        bones: body.skeleton.bones.length,
        headMovement: headAfter.distanceTo(headBefore),
        soleMovement: soleBefore.distanceTo(vertex(body, sole)),
        faceAttachmentError: Math.abs(faceAfter.distanceTo(headAfter) - faceBefore.distanceTo(headBefore)),
        restingArms, greetingHandRise, handReturnError, motionProof, liveDuringGesture, liveFootDrift,
      };
    });
    expressionEvidence.skeleton = proof;
    await writeFile('evidence/edition14/skeleton-check.json', JSON.stringify(proof, null, 2));
    assert(proof.bones >= 60);
    assert(proof.headMovement > .01, 'Head geometry must move through skinning.');
    assert(proof.soleMovement < .0001, 'Looking and layered gestures must keep the soles grounded.');
    assert(proof.faceAttachmentError < .0001, 'Expressions must stay attached to the turning head.');
    for (const arm of proof.restingArms) assert(arm.drop > .25 && arm.spreadRatio < .65, 'Idle arms must hang down rather than remain outstretched.');
    assert(proof.greetingHandRise > .2, 'Greeting must visibly raise the hand.');
    assert(proof.handReturnError < .001, 'Greeting must return to the relaxed stance.');
    assert.equal(Object.keys(proof.motionProof).length, 16);
    for (const [name, motion] of Object.entries(proof.motionProof)) {
      assert(motion.maxAngle > .06, `${name} must move the skeleton.`);
      assert(motion.returnError < .001, `${name} must return to rest.`);
    }
    assert(proof.motionProof.jump.maxLift > .2, 'Jump must actually leave the ground.');
    for (const name of ['curious', 'glance', 'shy', 'doze', 'present', 'listen', 'dance']) assert(proof.motionProof[name].footDrift < .001, `${name} must keep both feet planted.`);
    assert(proof.motionProof.curious.secondaryAngle > .002, 'A head gesture must drive secondary hair motion.');
    for (const [name, angle] of Object.entries(proof.liveDuringGesture)) assert(angle > .003, `${name} must keep moving during a gesture.`);
    assert(proof.liveFootDrift < .001, 'Continuous body motion must keep both feet planted.');
  });
  await check('实际眼睑闭合与恢复', async () => {
    await page.getByRole('button', { name: '眨眼', exact: true }).click();
    await page.waitForTimeout(100);
    const closed = await patch([.42, .38, .56, .44]);
    await page.screenshot({ path: 'evidence/blink.png' });
    await page.waitForTimeout(320);
    const open = await patch([.42, .38, .56, .44]);
    expressionEvidence.eyePixelDifference = difference(closed, open);
    assert(expressionEvidence.eyePixelDifference > 1, 'Eye rendering must actually change, then reopen.');
  });
  await check('视线跟随', async () => {
    await page.getByRole('button', { name: '看向鼠标', exact: true }).click();
    await page.mouse.move(890, 250);
    await page.waitForTimeout(400);
    assert.equal(await page.locator('#status').textContent(), '在看你');
    await page.screenshot({ path: 'evidence/look.png' });
  });
  await check('动作菜单、播放与打断', async () => {
    await page.getByRole('button', { name: '待机', exact: true }).click();
    await page.getByRole('button', { name: '动作', exact: true }).click();
    assert.equal(await page.locator('#motion-menu button').count(), 16);
    await page.screenshot({ path: 'evidence/motion-menu.png' });
    await page.getByRole('button', { name: '鞠躬', exact: true }).click();
    assert.equal(await page.locator('#status').textContent(), '鞠躬');
    assert.equal(await page.locator('#motion-menu').isVisible(), false);
    await page.waitForTimeout(800);
    await page.screenshot({ path: 'evidence/bow.png' });
    await page.getByText('自在摸鱼', { exact: true }).waitFor();
    await page.getByRole('button', { name: '动作', exact: true }).click();
    await page.getByRole('button', { name: '小跳', exact: true }).click();
    await page.waitForTimeout(250);
    await page.getByRole('button', { name: '复位', exact: true }).click();
    assert.equal(await page.locator('#status').textContent(), '自在摸鱼');
  });
  await check('触摸头部与拖拽', async () => {
    await page.mouse.click(590, 260);
    assert.equal(await page.locator('#status').textContent(), '开心');
    await page.waitForTimeout(180);
    await page.screenshot({ path: 'evidence/touch.png' });
    await page.mouse.move(590, 280);
    await page.mouse.down();
    await page.mouse.move(740, 270, { steps: 12 });
    assert.equal(await page.locator('#status').textContent(), '被拎起来了');
    await page.screenshot({ path: 'evidence/drag.png' });
    await page.mouse.up();
    await page.getByRole('button', { name: '复位', exact: true }).click();
    assert.equal(await page.locator('#status').textContent(), '自在摸鱼');
  });
  await check('戳肚子与恢复', async () => {
    await page.getByRole('button', { name: '戳一下', exact: true }).click();
    assert.equal(await page.locator('#status').textContent(), '吓一跳');
    await page.screenshot({ path: 'evidence/poke.png' });
    await page.getByText('自在摸鱼', { exact: true }).waitFor();
  });
  await check('真实音频播放与打断', async () => {
    // Cancelling before AudioContext.resume resolves must also cancel playback.
    await page.evaluate(() => {
      document.querySelector('[data-action="speak"]').click();
      document.querySelector('[data-action="idle"]').click();
    });
    await page.waitForTimeout(200);
    assert.equal(await page.locator('#status').textContent(), '自在摸鱼');
    assert.equal(await page.locator('#speech').isVisible(), false);
    await page.getByRole('button', { name: '复位', exact: true }).click();
    await page.waitForTimeout(300);
    const restingMouth = await patch([.475, .433, .525, .47]);
    await page.getByRole('button', { name: '说话演示', exact: true }).click();
    await page.getByText('正在说话', { exact: true }).waitFor();
    let peak = 0;
    for (let i = 0; i < 8; i++) {
      await page.waitForTimeout(120);
      const change = difference(restingMouth, await patch([.475, .433, .525, .47]));
      if (change > peak) { peak = change; await page.screenshot({ path: 'evidence/speak.png' }); }
    }
    expressionEvidence.speakingMouthPixelDifference = peak;
    assert(peak > .05, 'Real audio must change the rendered mouth.');
    assert.equal(await page.locator('#speech').isVisible(), true);
    assert.equal(await page.locator('#error').isVisible(), false);
    await page.getByRole('button', { name: '说话演示', exact: true }).click();
    assert.equal(await page.locator('#speech').isVisible(), false);
    assert.equal(await page.locator('#status').textContent(), '自在摸鱼');
    await page.waitForTimeout(300);
    const stopped = difference(restingMouth, await patch([.475, .433, .525, .47]));
    expressionEvidence.stoppedMouthPixelDifference = stopped;
    assert(stopped < peak * .4 + .03, 'Stopping audio must close the mouth.');
  });
  await check('背景切换与窄屏', async () => {
    const button = page.getByRole('button', { name: '棋盘背景', exact: true });
    await button.click();
    assert.equal(await button.getAttribute('aria-pressed'), 'true');
    await button.click();
    await page.setViewportSize({ width: 390, height: 844 });
    await page.waitForTimeout(350);
    const bounds = await page.locator('footer').boundingBox();
    assert(bounds.x >= 0 && bounds.x + bounds.width <= 390);
    await page.screenshot({ path: 'evidence/mobile.png' });
    await page.getByRole('button', { name: '动作', exact: true }).click();
    const menu = await page.locator('#motion-menu').boundingBox();
    assert(menu.x >= 0 && menu.x + menu.width <= 390);
    await page.screenshot({ path: 'evidence/mobile-menu.png' });
  });
  assert.deepEqual(errors, []);
  await writeFile('evidence/check.json', JSON.stringify({ at: new Date().toISOString(), browser: await browser.version(), results, expressionEvidence, errors }, null, 2));
  console.log(`通过：${results.join('、')}。`);
} finally {
  await browser.close();
}

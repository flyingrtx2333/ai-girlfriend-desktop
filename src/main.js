import * as THREE from 'three';
import { loadPortrait } from './portrait.js';
import { MOTIONS, COMPANION_MOTIONS } from './motions.js';
import { sampleSpeech } from './speech.js';
import { lightCharacter } from './lighting.js';
import './style.css';

const nativeHost = window.whaleNative;
const nativeDesktop = !!nativeHost;
if (nativeDesktop) document.documentElement.classList.add('desktop-pet');
let nativeVisible = true, nativePerformance = 'auto', nativeLowPower = false;
let nativeSpeaking = false, nativeVolume = 0, nativePeakVolume = 0, nativeHit = null;
let nativeSpeechFrames = [], nativeAudioPosition = 0, nativeAudioClock = 0, nativeSpeechShape = null;
let nativeScreenPhase = 'idle', nativeScreenSince = 0, nativeScreenDirection = -.65;
const nativeScreenGaze = new THREE.Vector2();
let nativeFrames = 0, nativeFPS = 0, fpsFrames = 0, fpsStarted = performance.now();
const nativeTranslation = new THREE.Vector2();
const nativeGrab = new THREE.Vector2(0, .65);
let nativeHeld = false, nativeMotionEvents = 0;
let dragPeakAngle = 0, dragPeakInertia = 0;
const stage = document.querySelector('#stage');
const status = document.querySelector('#status');
const error = document.querySelector('#error');
const speech = document.querySelector('#speech');
const buttons = [...document.querySelectorAll('[data-action]')];
const motionMenu = document.querySelector('#motion-menu');
const motionToggle = document.querySelector('#motions');
const framingToggle = document.querySelector('#framing');
const appearanceToggle = document.querySelector('#appearance');
let appearanceType = !nativeDesktop && new URLSearchParams(location.search).get('appearance') === 'model' ? 'model' : 'portrait';
const characters = new Map();
let lightingReady = false;
function ensureLighting() {
  if (!lightingReady) { lightCharacter(scene, renderer); lightingReady = true; }
}
async function loadCharacter(type, progress) {
  return type === 'portrait' ? loadPortrait(progress, { compact: nativeDesktop }) : (await import('./character.js')).loadWhaleMaid(progress);
}
let framing = nativeDesktop ? 'full' : 'close';
document.querySelector('#app').dataset.view = framing;
const motionButtons = Object.entries(MOTIONS).map(([name, spec]) => {
  const button = document.createElement('button');
  button.textContent = spec.label;
  button.dataset.motion = name;
  button.disabled = true;
  button.setAttribute('aria-pressed', 'false');
  motionMenu.append(button);
  return button;
});
const reducedMotion = matchMedia('(prefers-reduced-motion: reduce)').matches;
const scene = new THREE.Scene();
const camera = new THREE.PerspectiveCamera(33, 1, .1, 60);
camera.position.set(0, .35, 9.7);
camera.lookAt(0, .08, 0);
let renderer;
try {
  renderer = new THREE.WebGLRenderer({ antialias: true, alpha: true });
} catch {
  error.textContent = '无法启动 3D 渲染，请使用支持 WebGL 的浏览器。';
  error.hidden = false;
  status.textContent = '加载失败';
  buttons.forEach(button => button.disabled = true);
  throw new Error('WebGL unavailable');
}
renderer.setPixelRatio(Math.min(devicePixelRatio, nativeDesktop ? 1.5 : 2));
renderer.setClearColor(0x000000, 0);
renderer.outputColorSpace = THREE.SRGBColorSpace;
if (appearanceType === 'model') ensureLighting();
stage.append(renderer.domElement);
renderer.domElement.addEventListener('webglcontextlost', event => {
  event.preventDefault();
  error.textContent = '3D 渲染已中断，请刷新页面。';
  error.hidden = false;
});
let character;
try {
  character = await loadCharacter(appearanceType, progress => {
    status.textContent = progress.total ? `加载 ${Math.round(progress.loaded / progress.total * 100)}%` : '正在加载角色';
  });
} catch (cause) {
  status.textContent = '加载失败';
  error.textContent = '角色加载失败，请刷新重试。';
  error.hidden = false;
  throw cause;
}
const carrier = new THREE.Group();
carrier.add(character.root);
scene.add(carrier);
characters.set(appearanceType, character);
document.querySelector('#app').dataset.appearance = appearanceType;
const motionSpec = name => MOTIONS[name] || COMPANION_MOTIONS[name];
const supportsMotion = name => character.allowedMotions ? character.allowedMotions.has(name) : Object.hasOwn(MOTIONS, name);
function refreshAppearance() {
  appearanceToggle.textContent = appearanceType === 'portrait' ? '立体' : '原画';
  appearanceToggle.setAttribute('aria-label', `切换到${appearanceToggle.textContent}外观`);
  motionButtons.forEach(button => button.hidden = !supportsMotion(button.dataset.motion));
}
buttons.forEach(button => button.disabled = false);
motionButtons.forEach(button => button.disabled = false);
motionToggle.disabled = false;
framingToggle.disabled = false;
appearanceToggle.disabled = false;
refreshAppearance();
framingToggle.addEventListener('click', () => {
  framing = framing === 'close' ? 'full' : 'close';
  framingToggle.textContent = framing === 'close' ? '全身' : '近景';
  document.querySelector('#app').dataset.view = framing;
});

const shadow = new THREE.Mesh(new THREE.PlaneGeometry(10,10), new THREE.ShadowMaterial({opacity:.30,depthWrite:false}));
shadow.rotation.x = -Math.PI / 2;
shadow.position.set(0, -1.72, 0);
shadow.receiveShadow = true;
shadow.visible = appearanceType === 'model';
scene.add(shadow);
appearanceToggle.addEventListener('click', async () => {
  appearanceToggle.disabled = true;
  const next = appearanceType === 'portrait' ? 'model' : 'portrait';
  try {
    status.textContent = '正在加载角色';
    const loaded = characters.get(next) || await loadCharacter(next);
    if (next === 'model') ensureLighting();
    cancelMotion(); stopVoice(); reaction = ''; drag = null; mode = 'idle';
    offset.set(0, 0); targetOffset.set(0, 0); velocity.set(0, 0);
    carrier.remove(character.root); character = loaded; carrier.add(character.root);
    characters.set(next, loaded); appearanceType = next;
    document.querySelector('#app').dataset.appearance = next;
    renderer.shadowMap.enabled = next === 'model'; shadow.visible = next === 'model';
    refreshAppearance(); error.hidden = true;
  } catch { showError('外观加载失败，请重试。'); }
  appearanceToggle.disabled = false; updateStatus();
});

let mode = 'idle', reactionUntil = 0, reaction = '', last = performance.now(), elapsed = 0;
let reactionStarted = 0, happyMotion = 'curious', touchCount = 0;
let touch = { zone: 'head', side: 1 }, interactionCount = 0;
let nextBlink = 3.5, blinkUntil = 0, blinkStarted = -10, audioContext, analyser, samples, spectrum, voiceRequest = 0;
let drag = null;
let activeMotion = null, nextIdleMotion = nativeDesktop ? 7 : 5, idleMotionIndex = 0;
const idleMotions = ['tailWag', 'curious', 'sway', 'glance', 'listen', 'nod', 'shy', 'doze'];
const offset = new THREE.Vector2(), targetOffset = new THREE.Vector2(), velocity = new THREE.Vector2();
const pointer = new THREE.Vector2(), hitPointer = new THREE.Vector2(), raycaster = new THREE.Raycaster();
let pointerPresent = false, lastPointerMove = 0;
const plane = new THREE.Plane(new THREE.Vector3(0, 0, 1), 0);
const audio = new Audio('/audio/whale-maid/companion-minimax.mp3');
audio.preload = 'auto';
function showError(message) { error.textContent = message; error.hidden = false; }
function updateStatus() {
  status.textContent = drag?.moved ? '被拎起来了' : reaction ? (reaction === 'happy' ? '摸摸头' : '吓一跳') : nativeScreenPhase === 'observing' ? '看看屏幕' : nativeScreenPhase === 'thinking' ? '想一想' : activeMotion ? motionSpec(activeMotion.name).label : mode === 'speak' ? '正在说话' : mode === 'look' ? '在看你' : '自在摸鱼';
  buttons.forEach(button => button.setAttribute('aria-pressed', String(button.dataset.action === mode)));
  motionButtons.forEach(button => button.setAttribute('aria-pressed', String(button.dataset.motion === activeMotion?.name)));
}
function cancelMotion() { activeMotion = null; nextIdleMotion = elapsed + (nativeDesktop ? 18 : 10); }
function playMotion(name) {
  if (!motionSpec(name) || !supportsMotion(name)) return;
  activeMotion = { name, started: elapsed };
  nextBlink = elapsed + 1.8 + Math.random() * 1.5;
  reaction = '';
  updateStatus();
}
for (const button of motionButtons) button.addEventListener('click', () => {
  playMotion(button.dataset.motion);
  motionMenu.hidePopover();
});
function stopVoice() {
  voiceRequest++;
  audio.pause();
  audio.currentTime = 0;
  speech.hidden = true;
  if (mode === 'speak') mode = 'idle';
}
async function speak() {
  stopVoice();
  const request = voiceRequest;
  error.hidden = true;
  try {
    if (!audioContext) {
      audioContext = new AudioContext();
      analyser = audioContext.createAnalyser();
      analyser.fftSize = 2048;
      analyser.smoothingTimeConstant = .35;
      samples = new Uint8Array(analyser.fftSize);
      spectrum = new Uint8Array(analyser.frequencyBinCount);
      audioContext.createMediaElementSource(audio).connect(analyser);
      analyser.connect(audioContext.destination);
    }
    await audioContext.resume();
    if (request !== voiceRequest) return;
    mode = 'speak';
    updateStatus();
    await audio.play();
    if (request === voiceRequest && mode === 'speak') speech.hidden = false;
  } catch {
    if (request !== voiceRequest) return;
    mode = 'idle';
    showError('语音播放失败，请重试。');
  }
  updateStatus();
}
function react(kind = 'startled', contact = touch) {
  if (reaction === kind && elapsed - reactionStarted < .25) return;
  cancelMotion();
  touch = contact; interactionCount++;
  reaction = kind;
  reactionStarted = elapsed;
  if (kind === 'happy') {
    const available = (supportsMotion('pet') ? ['pet'] : ['curious', 'shy', 'wave']).filter(supportsMotion);
    happyMotion = available[touchCount++ % available.length];
  }
  reactionUntil = elapsed + (kind === 'happy' ? motionSpec(happyMotion).duration : 2.4);
  if (appearanceType === 'model' && kind !== 'happy') velocity.y += .25;
  updateStatus();
}
for (const button of buttons) {
  button.addEventListener('click', () => {
    const action = button.dataset.action;
    if (action === 'speak') {
      if (mode === 'speak') { stopVoice(); updateStatus(); } else void speak();
    } else if (action === 'poke') react();
    else if (action === 'blink') { blinkStarted = elapsed; blinkUntil = elapsed + .36; nextBlink = elapsed + 4; }
    else { cancelMotion(); stopVoice(); mode = action; reaction = ''; updateStatus(); }
  });
}
audio.addEventListener('ended', () => { stopVoice(); updateStatus(); });
audio.addEventListener('error', () => {
  if (mode === 'speak') { stopVoice(); showError('语音文件无法加载。'); updateStatus(); }
});
document.querySelector('#reset').addEventListener('click', () => {
  cancelMotion();
  stopVoice(); mode = 'idle'; reaction = ''; drag = null;
  offset.set(0, 0); targetOffset.set(0, 0); velocity.set(0, 0);
  error.hidden = true; stage.style.cursor = ''; updateStatus();
});
document.querySelector('#background').addEventListener('click', event => {
  const on = document.body.classList.toggle('checker');
  event.currentTarget.setAttribute('aria-pressed', String(on));
});
function locate(event) {
  const rect = stage.getBoundingClientRect();
  hitPointer.set((event.clientX - rect.left) / rect.width * 2 - 1, -(event.clientY - rect.top) / rect.height * 2 + 1);
  if (!nativeDesktop) {
    pointer.copy(hitPointer); pointerPresent = true; lastPointerMove = elapsed;
  }
  raycaster.setFromCamera(hitPointer, camera);
  return character.hitTest(raycaster.ray);
}
function planePoint() {
  return raycaster.ray.intersectPlane(plane, new THREE.Vector3());
}
stage.addEventListener('pointermove', event => {
  const hit = locate(event);
  if (nativeDesktop) setNativeHit(!!hit || !!drag);
  if (drag && event.pointerId === drag.id) {
    if (Math.hypot(nativeDesktop ? event.screenX - drag.sx : event.clientX - drag.x, nativeDesktop ? event.screenY - drag.sy : event.clientY - drag.y) > 5) drag.moved = true;
    const point = planePoint();
    if (!nativeDesktop && point && drag.moved) {
      const maxX = camera.aspect < 1 ? 1 : 2.8;
      targetOffset.set(THREE.MathUtils.clamp(point.x - drag.origin.x + drag.offset.x, -maxX, maxX), THREE.MathUtils.clamp(point.y - drag.origin.y + drag.offset.y, -.6, 1.7));
      updateStatus();
    }
  }
  stage.style.cursor = drag?.moved ? 'grabbing' : hit ? 'grab' : '';
});
stage.addEventListener('pointerdown', event => {
  if (event.button !== 0 || drag) return;
  const hit = locate(event);
  if (!hit) return;
  const point = planePoint();
  if (!point) return;
  cancelMotion();
  reaction = '';
  const local = character.root.worldToLocal(hit.point.clone());
  drag = { id: event.pointerId, x: event.clientX, y: event.clientY, sx: event.screenX, sy: event.screenY, moved: false, origin: point.clone(), offset: offset.clone(),
    zone: hit.zone || (local.y - character.lift > .4 ? 'head' : 'body'), side: Math.sign(hit.anchor?.x ?? local.x) || 1 };
  drag.anchor = hit.anchor || character.root.worldToLocal(hit.point.clone());
  if (nativeDesktop) { nativeGrab.copy(drag.anchor); nativeHeld = true; nativeMotionEvents = 0; dragPeakAngle = 0; dragPeakInertia = 0; }
  stage.setPointerCapture(event.pointerId);
  nativeHost?.post('dragBegin');
  updateStatus();
});
function release(event, cancelled = false, fromHost = false) {
  if (!drag || drag.id !== event.pointerId) return;
  // Native window movement may cancel WebKit capture before mouse-up. Keep
  // the contact until the host confirms the physical release and drag flag.
  if (nativeDesktop && !fromHost) { if (!cancelled) nativeHost.post('dragEnd'); return; }
  if (nativeDesktop && Math.hypot(event.screenX - drag.sx, event.screenY - drag.sy) > 5) drag.moved = true;
  if (!drag.moved && !cancelled) react(drag.zone === 'head' ? 'happy' : 'startled', { zone: drag.zone, side: drag.side });
  drag = null;
  targetOffset.set(0, 0);
  if (stage.hasPointerCapture(event.pointerId)) stage.releasePointerCapture(event.pointerId);
  stage.style.cursor = ''; updateStatus();
}
stage.addEventListener('pointerup', event => release(event));
stage.addEventListener('pointercancel', event => release(event, true));
stage.addEventListener('lostpointercapture', event => release(event, true));
stage.addEventListener('pointerleave', () => { if (!nativeDesktop) pointerPresent = false; if (nativeDesktop && !drag) setNativeHit(false); });
function setNativeHit(hit) {
  if (nativeHost && nativeHit !== hit) { nativeHit = hit; nativeHost.post('hit', { hit }); }
}
if (nativeDesktop) {
  window.petPointerAt = (x, y) => { const hit = !!locate({ clientX: x, clientY: y }) || !!drag; setNativeHit(hit); return hit; };
  window.petPointerGaze = (x, y) => {
    pointer.set(THREE.MathUtils.clamp(x, -1, 1), THREE.MathUtils.clamp(y, -1, 1));
    pointerPresent = true; lastPointerMove = elapsed;
  };
  window.petPointerLeave = () => { if (!drag) setNativeHit(false); };
  stage.addEventListener('dblclick', () => nativeHost.post('chat'));
  stage.addEventListener('contextmenu', event => { event.preventDefault(); nativeHost.post('menu'); });
}
function resize() {
  const { width, height } = stage.getBoundingClientRect();
  camera.aspect = width / height;
  camera.updateProjectionMatrix();
  renderer.setSize(width, height);
}
new ResizeObserver(resize).observe(stage);
resize();
const cameraFocus = new THREE.Vector3(0, .75, 0);
camera.position.z = Math.max(4.8, 3.45 / camera.aspect);
camera.lookAt(cameraFocus);

function frame(now) {
  const dt = Math.min((now - last) / 1000, nativeDesktop ? .08 : .04);
  last = now;
  elapsed += dt;
  if (activeMotion && elapsed - activeMotion.started >= motionSpec(activeMotion.name).duration) {
    activeMotion = null;
    nextIdleMotion = elapsed + (nativeDesktop ? 12 + Math.random() * 8 : 8 + Math.random() * 5);
    updateStatus();
  }
  if (!reducedMotion && nativePerformance !== 'paused' && nativeScreenPhase === 'idle' && !activeMotion && !reaction && !drag && mode === 'idle' && elapsed >= nextIdleMotion) {
    const available = idleMotions.filter(supportsMotion);
    playMotion(available[idleMotionIndex++ % available.length]);
  }
  if (reaction && elapsed > reactionUntil) { reaction = ''; updateStatus(); }
  if (elapsed > nextBlink) { blinkStarted = elapsed; blinkUntil = elapsed + .16; nextBlink = elapsed + 3.1 + Math.random() * 2.4; }
  const blinking = elapsed < blinkUntil;
  const blinkTime = elapsed - blinkStarted;
  const blinkAmount = blinkTime < .065 ? THREE.MathUtils.smoothstep(blinkTime, 0, .065) : 1 - THREE.MathUtils.smoothstep(blinkTime, .085, .225);
  const happy = reaction === 'happy';
  const shock = reaction === 'startled' ? Math.max(0, (reactionUntil - elapsed) / 2.4) : 0;
  const blend = 1 - Math.exp(-dt * 8);
  if (drag?.moved) {
    offset.lerp(targetOffset, blend);
    velocity.set(0, 0);
  } else {
    // Damped spring. Clamp dt above so returning from a hidden tab cannot explode.
    velocity.addScaledVector(offset, -32 * dt);
    velocity.multiplyScalar(Math.exp(-6.5 * dt));
    offset.addScaledVector(velocity, dt);
  }
  const motion = reducedMotion || nativePerformance === 'paused' ? 0 : 1;
  const fullView = framing === 'full' || ['jump', 'dance', 'stretch', 'cheer'].includes(activeMotion?.name);
  const distance = nativeDesktop ? Math.max(6.9, 4.8 / camera.aspect) : fullView ? (appearanceType === 'portrait' ? Math.max(9.2, 6.8 / camera.aspect) : Math.max(10.2, 7.4 / camera.aspect)) : Math.max(4.8, 3.45 / camera.aspect);
  camera.position.z = THREE.MathUtils.damp(camera.position.z, distance, 5, dt);
  cameraFocus.y = THREE.MathUtils.damp(cameraFocus.y, fullView ? .08 : .75, 5, dt);
  camera.lookAt(cameraFocus);
  carrier.position.x = offset.x;
  carrier.position.y = offset.y;
  character.root.position.y = 0;
  character.root.rotation.y = THREE.MathUtils.damp(character.root.rotation.y, .035 + (mode === 'look' && pointerPresent ? pointer.x * .02 : 0), 6, dt);
  character.root.rotation.z = THREE.MathUtils.damp(character.root.rotation.z, appearanceType === 'portrait' ? 0 : drag?.moved ? -offset.x * .07 : -velocity.x * .05, 5, dt);
  character.root.scale.setScalar(1);
  let volume = 0, vowels = { aa: 1, ee: 0, ou: 0 };
  if (nativeDesktop && nativeSpeaking) {
    nativeSpeechShape = nativeSpeechFrames.length ? sampleSpeech(nativeSpeechFrames, nativeAudioPosition + (performance.now() - nativeAudioClock) / 1000) : null;
    if (nativeSpeechShape) nativeVolume = nativeSpeechShape.open;
    nativePeakVolume = Math.max(nativePeakVolume, nativeVolume); volume = nativeVolume;
    vowels = nativeSpeechShape ? { aa: Math.max(0, 1 - nativeSpeechShape.ee - nativeSpeechShape.ou), ee: nativeSpeechShape.ee, ou: nativeSpeechShape.ou } : { aa: 1, ee: 0, ou: 0 };
  } else if (mode === 'speak' && analyser) {
    analyser.getByteTimeDomainData(samples);
    let sum = 0;
    for (const sample of samples) sum += ((sample - 128) / 128) ** 2;
    volume = Math.min(1, Math.sqrt(sum / samples.length) * 5);
    analyser.getByteFrequencyData(spectrum);
    // Audio bands provide soft vowel-like variation; silence closes every shape.
    // This is live audio analysis, not a phoneme recognizer.
    const band = (low, high) => {
      const bin = audioContext.sampleRate / analyser.fftSize;
      let energy = 0;
      const first = Math.ceil(low / bin), last = Math.floor(high / bin);
      for (let i = first; i <= last; i++) energy += spectrum[i] ** 2;
      return energy / (last - first + 1);
    };
    const low = band(250, 850), middle = band(850, 1600), high = band(1600, 3000);
    const aa = .4 + middle / (low + middle + high + 1);
    const ee = high / (low + high + 1);
    const ou = low / (low + high + 1) * .65;
    const total = aa + ee + ou;
    vowels = { aa: aa / total, ee: ee / total, ou: ou / total };
  }
  const screenTime = elapsed - nativeScreenSince;
  const attending = nativeScreenPhase === 'observing' || nativeScreenPhase === 'thinking';
  if (attending) nativeScreenGaze.set(nativeScreenPhase === 'observing' ? nativeScreenDirection + Math.sin(screenTime * 2.2) * .13 : .17 + Math.sin(screenTime * .6) * .12,
    nativeScreenPhase === 'observing' ? .28 + Math.sin(screenTime * 1.4) * .08 : .42 + Math.sin(screenTime * .7) * .04);
  const screenMotion = nativeScreenPhase === 'observing' ? 'screenObserve' : nativeScreenPhase === 'thinking' ? 'screenThink' : null;
  const activity = screenMotion && !reducedMotion ? { name: screenMotion, time: screenTime % motionSpec(screenMotion).duration }
    : nativeScreenPhase === 'commenting' ? { name: 'nod', time: Math.min(screenTime * .6, MOTIONS.nod.duration - .01) }
    : activeMotion ? { name: activeMotion.name, time: elapsed - activeMotion.started }
    : happy ? { name: happyMotion, time: elapsed - reactionStarted } : null;
  character.update(dt, { time: elapsed, motion, happy, shock, blinking, blinkAmount, volume, vowels, looking: attending || pointerPresent && (nativeDesktop || mode === 'look' || !!drag || elapsed - lastPointerMove < 3), pointer: attending ? nativeScreenGaze : pointer, dragging: !!drag?.moved,
    held: nativeDesktop ? nativeHeld : !!drag, grab: nativeDesktop ? nativeGrab : drag?.anchor,
    activity, touch, speechShape: nativeSpeaking ? nativeSpeechShape : null, translation: nativeDesktop ? nativeTranslation : offset });
  renderer.render(scene, camera);
  if (nativeDesktop) {
    const suspension = character.root.userData.expression?.suspension;
    if (suspension) { dragPeakAngle = Math.max(dragPeakAngle, Math.abs(suspension.angle)); dragPeakInertia = Math.max(dragPeakInertia, Math.abs(suspension.inertia)); }
    nativeFrames++; fpsFrames++;
    if (now - fpsStarted >= 1000) { nativeFPS = Math.round(fpsFrames * 1000 / (now - fpsStarted)); fpsFrames = 0; fpsStarted = now; }
  }
}
// Stop drawing when hidden; the clock and spring remain bounded on resume.
let nativeTimer = 0, nativeRaf = 0, nativeDeadline = 0;
function targetFPS() {
  if (!nativeVisible || document.hidden || nativePerformance === 'paused') return 0;
  const interactive = nativeSpeaking || nativeScreenPhase !== 'idle' || nativeHeld || !!drag || !!reaction || !!activeMotion || (character?.root.userData.expression?.suspension?.settling ?? false) || (pointerPresent && elapsed - lastPointerMove < 1.5);
  return nativeLowPower ? (interactive ? 30 : 15) : nativePerformance === 'smooth' || interactive ? 60 : 30;
}
function nativeTick(now) {
  if (!targetFPS()) return;
  frame(now);
  const fps = targetFPS();
  if (!fps) return;
  const interval = 1000 / fps;
  nativeDeadline = Math.max(nativeDeadline, now - interval) + interval;
  nativeTimer = setTimeout(() => { nativeRaf = requestAnimationFrame(nativeTick); }, Math.max(0, nativeDeadline - performance.now() - 2));
}
function visibility() {
  if (nativeDesktop) {
    clearTimeout(nativeTimer); cancelAnimationFrame(nativeRaf);
    last = performance.now(); nativeDeadline = last;
    if (targetFPS()) nativeRaf = requestAnimationFrame(nativeTick);
    else if (nativeVisible && !document.hidden) frame(last);
  } else if (document.hidden) renderer.setAnimationLoop(null);
  else { last = performance.now(); renderer.setAnimationLoop(frame); }
}
document.addEventListener('visibilitychange', visibility);
window.addEventListener('pagehide', () => { stopVoice(); renderer.setAnimationLoop(null); clearTimeout(nativeTimer); cancelAnimationFrame(nativeRaf); });
if (nativeDesktop) {
  window.addEventListener('whale-native', ({ detail: { type, payload } }) => {
    if (type === 'preferences') {
      nativeVisible = payload.visible !== false; nativePerformance = payload.performance || 'auto'; nativeLowPower = !!payload.lowPower;
      if (nativePerformance === 'paused') cancelMotion();
      visibility();
    } else if (type === 'speechStart') { nativeSpeaking = true; nativeVolume = 0; nativePeakVolume = 0; nativeSpeechFrames = payload.frames || []; nativeAudioPosition = payload.position || 0; nativeAudioClock = performance.now(); mode = 'speak'; updateStatus(); }
    else if (type === 'speechLevel') { if (!nativeSpeechFrames.length) nativeVolume = Math.max(0, Math.min(1, Number(payload.volume) || 0)); nativeAudioPosition = payload.position ?? nativeAudioPosition; nativeAudioClock = performance.now(); nativePeakVolume = Math.max(nativePeakVolume, nativeVolume); }
    else if (type === 'speechEnd') { nativeSpeaking = false; nativeVolume = 0; nativeSpeechFrames = []; nativeSpeechShape = null; if (mode === 'speak') mode = 'idle'; updateStatus(); }
    else if (type === 'voiceListen') playMotion('listen');
    else if (type === 'screenState') {
      nativeScreenPhase = ['observing', 'thinking', 'commenting'].includes(payload.phase) ? payload.phase : 'idle';
      nativeScreenSince = elapsed; nativeScreenDirection = payload.direction ?? -.65;
      if (nativeScreenPhase !== 'idle') cancelMotion();
      updateStatus();
    }
    else if (type === 'dragState') { nativeHeld = !!payload.held; if (nativeHeld) { nativeMotionEvents = 0; dragPeakAngle = 0; dragPeakInertia = 0; } }
    else if (type === 'translation') {
      nativeTranslation.set(payload.x, payload.y); nativeHeld = payload.held !== false; nativeMotionEvents++;
      if (drag && payload.moved) drag.moved = true;
    } else if (type === 'dragEnd') {
      nativeHeld = false;
      if (drag) { drag.moved ||= !!payload.moved; release({ pointerId: drag.id, screenX: drag.sx, screenY: drag.sy }, false, true); }
    }
    else if (type === 'reset') document.querySelector('#reset').click();
  });
  window.whaleDiagnostics = () => ({ frames: nativeFrames, fps: nativeVisible ? nativeFPS : 0, targetFPS: targetFPS(),
    visible: nativeVisible, speaking: nativeSpeaking, volume: nativeVolume, peakVolume: nativePeakVolume, compact: true,
    drawCalls: renderer.info.render.calls, triangles: renderer.info.render.triangles,
    drawingBuffer: [renderer.domElement.width, renderer.domElement.height], pixelRatio: renderer.getPixelRatio(),
    pointer: pointer.toArray(), screen: { phase: nativeScreenPhase, time: elapsed - nativeScreenSince, gaze: nativeScreenGaze.toArray() }, expression: character.root.userData.expression, speech: { curveFrames: nativeSpeechFrames.length, position: nativeAudioPosition, playhead: nativeSpeaking ? nativeAudioPosition + (performance.now() - nativeAudioClock) / 1000 : 0, shape: nativeSpeechShape },
    interaction: { count: interactionCount, kind: reaction, zone: touch.zone, side: touch.side },
    drag: { held: nativeHeld, motionEvents: nativeMotionEvents, translation: nativeTranslation.toArray(), peakAngle: dragPeakAngle, peakInertia: dragPeakInertia } });
}
visibility();
updateStatus();
nativeHost?.post('ready');

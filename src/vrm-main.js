import * as THREE from 'three';
import { GLTFLoader } from 'three/addons/loaders/GLTFLoader.js';
import { OrbitControls } from 'three/addons/controls/OrbitControls.js';
import { VRMLoaderPlugin, VRMUtils } from '@pixiv/three-vrm';
import { VRMAnimationLoaderPlugin, createVRMAnimationClip } from '@pixiv/three-vrm-animation';

const container = document.getElementById('canvas-container');
const statusEl = document.getElementById('status');
const infoTitle = document.getElementById('info-title');
const infoDesc = document.getElementById('info-desc');
const btnSwitchModel = document.getElementById('btn-switch-model');
const btnPose = document.getElementById('btn-pose');
const btnIdle = document.getElementById('btn-idle');
const btnBlink = document.getElementById('btn-blink');
const btnTalk = document.getElementById('btn-talk');
const btnLook = document.getElementById('btn-look');

// 1. Scene, Camera, Renderer
const scene = new THREE.Scene();
scene.background = new THREE.Color(0x0f172a);

const camera = new THREE.PerspectiveCamera(30, window.innerWidth / window.innerHeight, 0.1, 20);
camera.position.set(0, 1.25, 2.2);

const renderer = new THREE.WebGLRenderer({ antialias: true, powerPreference: 'high-performance' });
renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
renderer.setSize(window.innerWidth, window.innerHeight);
renderer.toneMapping = THREE.ACESFilmicToneMapping;
renderer.toneMappingExposure = 1.05;
renderer.shadowMap.enabled = true;
renderer.shadowMap.type = THREE.PCFShadowMap;
container.appendChild(renderer.domElement);

const controls = new OrbitControls(camera, renderer.domElement);
controls.target.set(0, 1.15, 0);
controls.enableDamping = true;
controls.dampingFactor = 0.05;
controls.minDistance = 0.8;
controls.maxDistance = 4.0;
controls.maxPolarAngle = Math.PI / 2 + 0.1;

// 2. Lighting
const ambientLight = new THREE.AmbientLight(0xffffff, 1.2);
scene.add(ambientLight);

const mainLight = new THREE.DirectionalLight(0xfff5ea, 1.8);
mainLight.position.set(1.5, 3, 2);
mainLight.castShadow = true;
scene.add(mainLight);

const fillLight = new THREE.DirectionalLight(0xdbeafe, 0.9);
fillLight.position.set(-2, 1.5, -1);
scene.add(fillLight);

// Floor grid
const grid = new THREE.GridHelper(10, 20, 0x334155, 0x1e293b);
grid.position.y = 0;
scene.add(grid);

// 3. State & Variables
let currentVrm = null;
let currentMixer = null;
let idleAction = null;
let isLookAtActive = true;
let isTalking = false;
let talkTimer = 0;
let isRelaxedPose = true;
let currentModelType = 'whale-maid'; // 'whale-maid' | 'deepseek-chan'
let cachedVrmaAnimation = null;

// LookAt target object
const lookAtTarget = new THREE.Object3D();
camera.add(lookAtTarget);
lookAtTarget.position.set(0, 0, -1);

window.addEventListener('pointermove', (e) => {
  const mouseX = (e.clientX / window.innerWidth) * 2 - 1;
  const mouseY = -(e.clientY / window.innerHeight) * 2 + 1;
  if (isLookAtActive && currentVrm) {
    lookAtTarget.position.x = mouseX * 0.8;
    lookAtTarget.position.y = 1.15 + mouseY * 0.5;
    lookAtTarget.position.z = 1.0;
  }
});

// 4. VRM Pose Correction
// Mixamo 原始绑定模型在 T-Pose（大字型）下，若待机动画仅含微幅呼吸摇摆，必须叠加上自然的垂手偏置
function updateArmPose() {
  if (!currentVrm?.humanoid) return;
  const leftUpper = currentVrm.humanoid.getNormalizedBoneNode('leftUpperArm');
  const rightUpper = currentVrm.humanoid.getNormalizedBoneNode('rightUpperArm');
  const leftLower = currentVrm.humanoid.getNormalizedBoneNode('leftLowerArm');
  const rightLower = currentVrm.humanoid.getNormalizedBoneNode('rightLowerArm');

  if (isRelaxedPose && currentModelType === 'whale-maid') {
    if (leftUpper) {
      // 旋转向下贴近躯干，略微前倾
      leftUpper.rotation.z -= 1.25;
      leftUpper.rotation.x += 0.12;
    }
    if (rightUpper) {
      rightUpper.rotation.z += 1.25;
      rightUpper.rotation.x += 0.12;
    }
    if (leftLower) {
      leftLower.rotation.z -= 0.22;
      leftLower.rotation.y += 0.15;
    }
    if (rightLower) {
      rightLower.rotation.z += 0.22;
      rightLower.rotation.y -= 0.15;
    }
  }
}

// 5. Load Model Function
const loader = new GLTFLoader();
loader.register((parser) => new VRMLoaderPlugin(parser));
loader.register((parser) => new VRMAnimationLoaderPlugin(parser));

async function loadModel(type) {
  currentModelType = type;
  if (currentVrm) {
    scene.remove(currentVrm.scene);
    VRMUtils.deepDispose(currentVrm.scene);
    currentVrm = null;
    currentMixer = null;
    idleAction = null;
  }

  statusEl.textContent = `加载中 (${type})...`;
  const modelUrl = type === 'whale-maid'
    ? '/models/whale-maid-v2/whale-maid.vrm'
    : '/models/deepseek-chan/DeepSeek-chan.vrm';

  try {
    const gltf = await loader.loadAsync(modelUrl);
    const vrm = gltf.userData.vrm;
    if (!vrm) throw new Error('未读取到 VRM 实例');
    currentVrm = vrm;
    scene.add(vrm.scene);

    VRMUtils.rotateVRM0(vrm);

    // 针对 AI 生成版鲸鱼娘优化材质透光与双面
    if (type === 'whale-maid') {
      vrm.scene.traverse((node) => {
        if (node.isMesh && node.name.includes('FacialExpressions')) {
          node.material.depthWrite = true;
          node.material.transparent = true;
          node.material.opacity = 0.98;
        }
      });
    }

    if (vrm.lookAt) {
      vrm.lookAt.target = lookAtTarget;
      vrm.lookAt.autoUpdate = true;
    }

    // 绑定 AIRI 动捕
    if (!cachedVrmaAnimation) {
      const vrmaGltf = await loader.loadAsync('/animations/airi/idle_loop.vrma');
      const vrmAnimations = vrmaGltf.userData.vrmAnimations;
      if (vrmAnimations && vrmAnimations.length > 0) {
        cachedVrmaAnimation = vrmAnimations[0];
      }
    }

    if (cachedVrmaAnimation) {
      const clip = createVRMAnimationClip(cachedVrmaAnimation, vrm);
      currentMixer = new THREE.AnimationMixer(vrm.scene);
      idleAction = currentMixer.clipAction(clip);
      idleAction.play();
    }

    // 更新界面描述
    if (type === 'whale-maid') {
      infoTitle.textContent = '当前模型：鲸鱼娘 (AI转版)';
      infoDesc.innerHTML = '• 来源：Tripo AI 单图生成 + 算法硬缝合眼皮<br>• 说明：原模型为 T-Pose，已用代码叠加垂手站姿；眼皮由外部算法补丁构成，故形变时容易显厚。';
      btnSwitchModel.textContent = '切换为专业版 VRM (DeepSeek-chan)';
      btnPose.style.display = 'inline-block';
    } else {
      infoTitle.textContent = '当前模型：DeepSeek-chan (专业版 VRM)';
      infoDesc.innerHTML = '• 来源：专业 3D 建模师制作的标准 VRM<br>• 特性：眼球眼窝独立几何，标准 52 种 Blendshape，眼睑闭合极其柔和，具备完整的 SpringBone 头发物理。';
      btnSwitchModel.textContent = '切换为 AI 鲸鱼娘 (对比)';
      btnPose.style.display = 'none';
    }

    statusEl.textContent = '就绪 · 运行中';
  } catch (err) {
    console.error('加载失败:', err);
    statusEl.textContent = '加载失败: ' + err.message;
    statusEl.style.color = '#ef4444';
  }
}

// 6. UI Events
btnSwitchModel.addEventListener('click', () => {
  loadModel(currentModelType === 'whale-maid' ? 'deepseek-chan' : 'whale-maid');
});

btnPose.addEventListener('click', () => {
  isRelaxedPose = !isRelaxedPose;
  btnPose.classList.toggle('active', isRelaxedPose);
  btnPose.textContent = isRelaxedPose ? '自然垂手姿势' : '原始大字型 (T-Pose)';
});

btnIdle.addEventListener('click', () => {
  if (!idleAction) return;
  if (idleAction.isRunning()) {
    idleAction.stop();
    btnIdle.classList.remove('active');
  } else {
    idleAction.play();
    btnIdle.classList.add('active');
  }
});

let isBlinking = false;
btnBlink.addEventListener('click', () => {
  if (!currentVrm || isBlinking) return;
  isBlinking = true;
  // 自然眨眼应是极快速的瞬态过程（约 120ms）：快速闭上再睁开
  const startTime = performance.now();
  const duration = 140; // 毫秒

  function tickBlink(now) {
    const elapsed = now - startTime;
    const progress = Math.min(1, elapsed / duration);
    // 使用正弦半波让眼睛快速闭合并回弹
    const blinkVal = Math.sin(progress * Math.PI);
    currentVrm.expressionManager.setValue('blink', blinkVal);

    if (progress < 1) {
      requestAnimationFrame(tickBlink);
    } else {
      currentVrm.expressionManager.setValue('blink', 0);
      isBlinking = false;
    }
  }
  requestAnimationFrame(tickBlink);
});

btnTalk.addEventListener('click', () => {
  isTalking = !isTalking;
  btnTalk.classList.toggle('active', isTalking);
  if (!isTalking && currentVrm) {
    currentVrm.expressionManager.setValue('aa', 0);
    currentVrm.expressionManager.setValue('ou', 0);
  }
});

btnLook.addEventListener('click', () => {
  isLookAtActive = !isLookAtActive;
  btnLook.classList.toggle('active', isLookAtActive);
  if (!isLookAtActive && currentVrm?.lookAt) {
    lookAtTarget.position.set(0, 1.15, 2.0);
  }
});

// 7. Render Loop
let lastTime = performance.now();

function animate(now) {
  requestAnimationFrame(animate);
  const delta = Math.min(0.1, (now - lastTime) / 1000);
  lastTime = now;

  // 1. 先推进动画 Mixer（计算待机动作）
  if (currentMixer) {
    currentMixer.update(delta);
  }

  // 2. 叠加上手臂垂下姿态（解决 T-Pose）
  updateArmPose();

  // 3. 更新口型与表情
  if (currentVrm) {
    if (isTalking) {
      talkTimer += delta * 8;
      const aa = Math.max(0, Math.sin(talkTimer));
      const ou = Math.max(0, Math.cos(talkTimer * 0.7));
      currentVrm.expressionManager.setValue('aa', aa * 0.7);
      currentVrm.expressionManager.setValue('ou', ou * 0.4);
    }

    currentVrm.update(delta);
  }

  controls.update();
  renderer.render(scene, camera);
}

window.addEventListener('resize', () => {
  camera.aspect = window.innerWidth / window.innerHeight;
  camera.updateProjectionMatrix();
  renderer.setSize(window.innerWidth, window.innerHeight);
});

loadModel('whale-maid');
requestAnimationFrame((now) => {
  lastTime = now;
  animate(now);
});

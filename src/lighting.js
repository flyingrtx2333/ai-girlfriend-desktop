import * as THREE from 'three';

export function lightCharacter(scene, renderer) {
  renderer.outputColorSpace = THREE.SRGBColorSpace;
  renderer.toneMapping = THREE.NeutralToneMapping;
  renderer.toneMappingExposure = 1;
  renderer.shadowMap.enabled = true;
  renderer.shadowMap.type = THREE.VSMShadowMap;
  const studio = new THREE.Scene();
  studio.background = new THREE.Color().setRGB(.08,.08,.08);
  for (const [position, size, intensity] of [[[-3,4,5],[4,5],2.5],[[4,2,3],[5,4],.8],[[0,6,-1],[4,3],.6]]) {
    const panel = new THREE.Mesh(new THREE.PlaneGeometry(...size), new THREE.MeshBasicMaterial({color:new THREE.Color().setRGB(intensity,intensity,intensity)}));
    panel.position.set(...position); panel.lookAt(0,.5,0); studio.add(panel);
  }
  const pmrem = new THREE.PMREMGenerator(renderer);
  scene.environment = pmrem.fromScene(studio, .10).texture;
  scene.environmentIntensity = .85;
  studio.traverse(node => { if (node.isMesh) { node.geometry.dispose(); node.material.dispose(); } });
  pmrem.dispose();
  scene.add(new THREE.HemisphereLight('#fffaf5', '#d7cfd0', 1.25));
  const key = new THREE.DirectionalLight('#fffaf5', 1.6);
  key.position.set(-3, 12, 4); key.target.position.set(0,.2,0);
  key.castShadow = true;
  key.shadow.mapSize.set(1024,1024);
  Object.assign(key.shadow.camera, {left:-3.5,right:3.5,top:3.5,bottom:-3.5,near:.5,far:18});
  key.shadow.bias = -.0002; key.shadow.normalBias = .012;
  key.shadow.radius = 32; key.shadow.blurSamples = 16; key.shadow.intensity = .45;
  scene.add(key, key.target);
  const fill = new THREE.DirectionalLight('#ffffff', 1.2);
  fill.position.set(4, 2, 5);
  scene.add(fill);
}

export function softenMaterial(source) {
  const material = source.clone();
  material.forceSinglePass = true;
  if (source.name === 'EyeLids') material.depthWrite = false;
  material.normalScale.multiplyScalar(.12);
  if (material.roughnessMap) {
    material.aoMap = material.roughnessMap;
    material.aoMapIntensity = .25;
  }
  if (!material.map) return material;
  const blinkUniform = { value: new THREE.Vector2() };
  material.userData.blinkUniform = blinkUniform;
  // Retain all generated PBR maps. Keep cloth matte and corneas glossy instead
  // of letting generated low roughness turn the whole outfit into enamel.
  material.onBeforeCompile = shader => {
    shader.uniforms.uBlink = blinkUniform;
    shader.vertexShader = shader.vertexShader.replace('#include <common>', '#include <common>\nvarying vec3 vAssetPosition;')
      .replace('#include <begin_vertex>', '#include <begin_vertex>\nvAssetPosition = position;');
    shader.fragmentShader = shader.fragmentShader.replace('#include <common>', `#include <common>
      varying vec3 vAssetPosition;
      uniform vec2 uBlink;
      // Match the fitted eyelid profile in design/model-v2/face-profile.json.
      // Hide the generated lash surface only inside the opaque part of a lid.
      bool coveredByLid(vec2 p, float cx, float blink) {
        float u = (p.x - cx) / 0.061;
        if (abs(u) > 0.90) return false;
        float top = 0.2 - 0.036 * u * u;
        float upper = mix(0.156 - 0.026 * u * u, 0.124 + 0.01 * u * u, blink);
        float bottom = mix(0.102 + 0.031 * u * u, 0.085 + 0.045 * u * u, blink);
        float lower = mix(0.102 + 0.031 * u * u, 0.124 + 0.01 * u * u, blink);
        return (p.y > upper && p.y < mix(top, upper, 0.22)) ||
          (p.y > mix(bottom, lower, 0.22) && p.y < lower);
      }
    `)
      .replace('#include <color_fragment>', `
        #include <color_fragment>
        vec2 facePoint = vec2(-vAssetPosition.z, vAssetPosition.y - 0.489925);
        float uLeft = (facePoint.x + 0.094) / 0.061, uRight = (facePoint.x - 0.044) / 0.061;
        float u = abs(uLeft) < abs(uRight) ? uLeft : uRight;
        bool inEye = facePoint.y < 0.158 - 0.026 * u * u &&
          facePoint.y > 0.092 + 0.031 * u * u && vAssetPosition.x < 0.211;
        bool blueSurface = diffuseColor.b > diffuseColor.r * 1.2 && diffuseColor.b > diffuseColor.g;
        bool hairInFront = blueSurface && (diffuseColor.b > diffuseColor.r * 1.6 || diffuseColor.b > 0.12) && !inEye;
        if (!hairInFront && vAssetPosition.x > 0.14 && vAssetPosition.x < 0.25 &&
          (coveredByLid(facePoint, -0.094, uBlink.x) || coveredByLid(facePoint, 0.044, uBlink.y))) discard;
      `)
      .replace('#include <roughnessmap_fragment>', `
        #include <roughnessmap_fragment>
        float head = smoothstep(0.46, 0.56, vAssetPosition.y);
        float eyeA = 1.0 - smoothstep(0.7, 1.1, length((facePoint - vec2(-0.094, 0.127)) / vec2(0.046, 0.034)));
        float eyeB = 1.0 - smoothstep(0.7, 1.1, length((facePoint - vec2(0.044, 0.127)) / vec2(0.046, 0.034)));
        float eye = max(eyeA * (1.0 - uBlink.x), eyeB * (1.0 - uBlink.y)) * smoothstep(0.15, 0.18, vAssetPosition.x) * (1.0 - smoothstep(0.202, 0.212, vAssetPosition.x));
        float gold = smoothstep(2.5, 5.0, diffuseColor.r / (diffuseColor.b + 0.01));
        float minimumRoughness = mix(mix(0.78, 0.58, head), 0.44, eye);
        roughnessFactor = clamp(roughnessFactor, mix(minimumRoughness, 0.32, gold), 0.96);
      `).replace('#include <metalnessmap_fragment>', '#include <metalnessmap_fragment>\nmetalnessFactor *= gold;');
  };
  material.customProgramCacheKey = () => 'whale-maid-v2-fitted-eyes';
  return material;
}

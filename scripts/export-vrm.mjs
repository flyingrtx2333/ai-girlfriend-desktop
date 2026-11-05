import fs from 'node:fs';
import path from 'node:path';

const inputGlbPath = 'public/models/whale-maid-v2/whale-maid-rigged.glb';
const outputVrmPath = 'public/models/whale-maid-v2/whale-maid.vrm';

const glbBuf = fs.readFileSync(inputGlbPath);
// GLB header: magic(4) + version(4) + length(4)
const magic = glbBuf.readUInt32LE(0);
if (magic !== 0x46546C67) {
  throw new Error('Not a valid GLB file');
}

const jsonChunkLen = glbBuf.readUInt32LE(12);
const jsonChunkType = glbBuf.readUInt32LE(16);
const jsonBuf = glbBuf.subarray(20, 20 + jsonChunkLen);
const json = JSON.parse(jsonBuf.toString('utf8'));

// Binary chunk starts after json chunk (aligned to 4 bytes)
const binHeaderOffset = 20 + jsonChunkLen;
const binChunkLen = glbBuf.readUInt32LE(binHeaderOffset);
const binChunkType = glbBuf.readUInt32LE(binHeaderOffset + 4);
const binBuf = glbBuf.subarray(binHeaderOffset + 8, binHeaderOffset + 8 + binChunkLen);

console.log('GLB JSON parsed successfully. Nodes:', json.nodes.length);

// 1. Build bone map
const MIXAMO_TO_VRM1 = {
  'mixamorig:Hips': 'hips',
  'mixamorig:Spine': 'spine',
  'mixamorig:Spine1': 'chest',
  'mixamorig:Spine2': 'upperChest',
  'mixamorig:Neck': 'neck',
  'mixamorig:Head': 'head',
  'mixamorig:LeftShoulder': 'leftShoulder',
  'mixamorig:LeftArm': 'leftUpperArm',
  'mixamorig:LeftForeArm': 'leftLowerArm',
  'mixamorig:LeftHand': 'leftHand',
  'mixamorig:RightShoulder': 'rightShoulder',
  'mixamorig:RightArm': 'rightUpperArm',
  'mixamorig:RightForeArm': 'rightLowerArm',
  'mixamorig:RightHand': 'rightHand',
  'mixamorig:LeftUpLeg': 'leftUpperLeg',
  'mixamorig:LeftLeg': 'leftLowerLeg',
  'mixamorig:LeftFoot': 'leftFoot',
  'mixamorig:LeftToeBase': 'leftToes',
  'mixamorig:RightUpLeg': 'rightUpperLeg',
  'mixamorig:RightLeg': 'rightLowerLeg',
  'mixamorig:RightFoot': 'rightFoot',
  'mixamorig:RightToeBase': 'rightToes',
  'mixamorig:LeftHandThumb1': 'leftThumbMetacarpal',
  'mixamorig:LeftHandThumb2': 'leftThumbProximal',
  'mixamorig:LeftHandThumb3': 'leftThumbDistal',
  'mixamorig:LeftHandIndex1': 'leftIndexProximal',
  'mixamorig:LeftHandIndex2': 'leftIndexIntermediate',
  'mixamorig:LeftHandIndex3': 'leftIndexDistal',
  'mixamorig:LeftHandMiddle1': 'leftMiddleProximal',
  'mixamorig:LeftHandMiddle2': 'leftMiddleIntermediate',
  'mixamorig:LeftHandMiddle3': 'leftMiddleDistal',
  'mixamorig:LeftHandRing1': 'leftRingProximal',
  'mixamorig:LeftHandRing2': 'leftRingIntermediate',
  'mixamorig:LeftHandRing3': 'leftRingDistal',
  'mixamorig:LeftHandPinky1': 'leftLittleProximal',
  'mixamorig:LeftHandPinky2': 'leftLittleIntermediate',
  'mixamorig:LeftHandPinky3': 'leftLittleDistal',
  'mixamorig:RightHandThumb1': 'rightThumbMetacarpal',
  'mixamorig:RightHandThumb2': 'rightThumbProximal',
  'mixamorig:RightHandThumb3': 'rightThumbDistal',
  'mixamorig:RightHandIndex1': 'rightIndexProximal',
  'mixamorig:RightHandIndex2': 'rightIndexIntermediate',
  'mixamorig:RightHandIndex3': 'rightIndexDistal',
  'mixamorig:RightHandMiddle1': 'rightMiddleProximal',
  'mixamorig:RightHandMiddle2': 'rightMiddleIntermediate',
  'mixamorig:RightHandMiddle3': 'rightMiddleDistal',
  'mixamorig:RightHandRing1': 'rightRingProximal',
  'mixamorig:RightHandRing2': 'rightRingIntermediate',
  'mixamorig:RightHandRing3': 'rightRingDistal',
  'mixamorig:RightHandPinky1': 'rightLittleProximal',
  'mixamorig:RightHandPinky2': 'rightLittleIntermediate',
  'mixamorig:RightHandPinky3': 'rightLittleDistal',
};

const humanBones = {};
json.nodes.forEach((node, index) => {
  if (node.name && MIXAMO_TO_VRM1[node.name]) {
    const vrmBone = MIXAMO_TO_VRM1[node.name];
    humanBones[vrmBone] = { node: index };
  }
});

console.log('Mapped VRM humanoid bones:', Object.keys(humanBones).length);

// 2. Locate FaceRig node and its morph targets
const faceRigNodeIndex = json.nodes.findIndex(n => n.name === 'FaceRig');
console.log('FaceRig node index:', faceRigNodeIndex);

// Expressions preset
const expressionsPreset = {
  blink: {
    isBinary: false,
    morphTargetBinds: [
      { node: faceRigNodeIndex, index: 0, weight: 1 },
      { node: faceRigNodeIndex, index: 1, weight: 1 }
    ]
  },
  blinkLeft: {
    isBinary: false,
    morphTargetBinds: [
      { node: faceRigNodeIndex, index: 0, weight: 1 }
    ]
  },
  blinkRight: {
    isBinary: false,
    morphTargetBinds: [
      { node: faceRigNodeIndex, index: 1, weight: 1 }
    ]
  },
  aa: {
    isBinary: false,
    morphTargetBinds: [
      { node: faceRigNodeIndex, index: 2, weight: 1 }
    ]
  },
  ee: {
    isBinary: false,
    morphTargetBinds: [
      { node: faceRigNodeIndex, index: 3, weight: 1 }
    ]
  },
  ou: {
    isBinary: false,
    morphTargetBinds: [
      { node: faceRigNodeIndex, index: 4, weight: 1 }
    ]
  },
  oh: {
    isBinary: false,
    morphTargetBinds: [
      { node: faceRigNodeIndex, index: 4, weight: 1 }
    ]
  }
};

// 3. Inject VRMC_vrm extension
if (!json.extensionsUsed) json.extensionsUsed = [];
if (!json.extensionsUsed.includes('VRMC_vrm')) json.extensionsUsed.push('VRMC_vrm');

if (!json.extensions) json.extensions = {};
json.extensions.VRMC_vrm = {
  specVersion: '1.0',
  meta: {
    name: 'Whale Maid',
    version: '1.0',
    authors: ['Blue Fat Fish'],
    avatarPermission: 'everyone',
    allowExcessivelySexualUsage: false,
    allowExcessivelyViolentUsage: false,
    commercialUsage: 'personalNonProfit',
    creditNotation: 'unnecessary',
    modification: 'allowModification',
    licenseUrl: 'https://vrm.dev/licenses/1.0/'
  },
  humanoid: {
    humanBones
  },
  expressions: {
    preset: expressionsPreset
  },
  lookAt: {
    offsetFromHeadBone: [0, 0.08, 0],
    type: 'expression'
  }
};

// Also inject VRM 0.x extension so tools supporting only VRM 0.0 also load it!
if (!json.extensionsUsed.includes('VRM')) json.extensionsUsed.push('VRM');
const vrm0HumanBones = Object.entries(humanBones).map(([bone, obj]) => {
  // convert camelCase to VRM 0.x bone name (e.g. leftUpperArm -> leftUpperArm)
  return {
    bone,
    node: obj.node,
    useDefaultValues: true
  };
});

json.extensions.VRM = {
  exporterVersion: 'Antigravity VRM Exporter 1.0',
  specVersion: '0.0',
  meta: {
    title: 'Whale Maid',
    version: '1.0',
    author: 'Blue Fat Fish'
  },
  humanoid: {
    humanBones: vrm0HumanBones
  },
  blendShapeMaster: {
    blendShapeGroups: [
      {
        name: 'Blink',
        presetName: 'blink',
        binds: [
          { mesh: 1, index: 0, weight: 100 },
          { mesh: 1, index: 1, weight: 100 }
        ]
      },
      {
        name: 'Blink_L',
        presetName: 'blink_l',
        binds: [{ mesh: 1, index: 0, weight: 100 }]
      },
      {
        name: 'Blink_R',
        presetName: 'blink_r',
        binds: [{ mesh: 1, index: 1, weight: 100 }]
      },
      {
        name: 'A',
        presetName: 'a',
        binds: [{ mesh: 1, index: 2, weight: 100 }]
      },
      {
        name: 'E',
        presetName: 'e',
        binds: [{ mesh: 1, index: 3, weight: 100 }]
      },
      {
        name: 'O',
        presetName: 'o',
        binds: [{ mesh: 1, index: 4, weight: 100 }]
      },
      {
        name: 'U',
        presetName: 'u',
        binds: [{ mesh: 1, index: 4, weight: 100 }]
      }
    ]
  }
};

// Pack into GLB binary
let updatedJsonStr = JSON.stringify(json);
let jsonStrBuffer = Buffer.from(updatedJsonStr, 'utf8');
// Pad JSON with trailing spaces to 4-byte alignment
const padLength = (4 - (jsonStrBuffer.length % 4)) % 4;
if (padLength > 0) {
  jsonStrBuffer = Buffer.concat([jsonStrBuffer, Buffer.from(' '.repeat(padLength), 'utf8')]);
}

const outJsonChunkLen = jsonStrBuffer.length;
const outBinChunkLen = binBuf.length;
const totalLength = 12 + 8 + outJsonChunkLen + 8 + outBinChunkLen;

const outBuf = Buffer.alloc(totalLength);
// GLB Header
outBuf.writeUInt32LE(0x46546C67, 0); // "glTF"
outBuf.writeUInt32LE(2, 4);          // version 2
outBuf.writeUInt32LE(totalLength, 8);

// JSON Chunk Header
outBuf.writeUInt32LE(outJsonChunkLen, 12);
outBuf.writeUInt32LE(0x4E4F534A, 16); // "JSON"
jsonStrBuffer.copy(outBuf, 20);

// BIN Chunk Header
const binOffset = 20 + outJsonChunkLen;
outBuf.writeUInt32LE(outBinChunkLen, binOffset);
outBuf.writeUInt32LE(0x004E4942, binOffset + 4); // "BIN\0"
binBuf.copy(outBuf, binOffset + 8);

fs.writeFileSync(outputVrmPath, outBuf);
console.log(`Saved VRM model to ${outputVrmPath} (${(outBuf.length / (1024 * 1024)).toFixed(2)} MB)`);

// Model-specific, offline eyelid and mouth construction; no per-frame vertex work.
import {NodeIO} from '@gltf-transform/core';
import * as T from 'three';
import {readFile, writeFile} from 'node:fs/promises';

const input = process.argv[2] || 'public/models/whale-maid-generated/whale-maid-v1.glb';
const output = process.argv[3] || 'public/models/whale-maid-generated/whale-maid-expressions.glb';
const referencePath = process.argv[4] || 'public/models/whale-maid-generated/whale-maid-v1.glb';
const profile = process.argv[5] ? JSON.parse(await readFile(process.argv[5], 'utf8')) : {};
const io = new NodeIO(), doc = await io.read(input);
const root = doc.getRoot(), buffer = root.listBuffers()[0];
const originalMesh = root.listMeshes()[0], source = originalMesh.listPrimitives()[0];
const bodyNode=root.listNodes().find(n=>n.getMesh()===originalMesh);
const skinning=bodyNode.getSkin();
const src = source.getAttribute('POSITION').getArray();
// Tripo reorders vertices and moves the mesh origin when rigging; UVs retain
// correspondence. Verify that the approved shape survived and recover its frame.
const offset=[0,0,0];
if(skinning) {
  const reference=await io.read(referencePath);
  const ref=reference.getRoot().listMeshes()[0].listPrimitives()[0];
  const refPosition=ref.getAttribute('POSITION'),refUV=ref.getAttribute('TEXCOORD_0');
  const min=source.getAttribute('POSITION').getMin([]),refMin=refPosition.getMin([]);
  for(let k=0;k<3;k++)offset[k]=min[k]-refMin[k];
  const uvKey=(a,i)=>a.getElement(i,[]).map(v=>Math.round(v*1e6)).join(',');
  const lookup=new Map();
  for(let i=0;i<refUV.getCount();i++)lookup.set(uvKey(refUV,i),i);
  const uv=source.getAttribute('TEXCOORD_0');
  for(let i=0;i<uv.getCount();i++) {
    const j=lookup.get(uvKey(uv,i));
    if(j===undefined)throw new Error('Rig UV correspondence changed; recalibration required.');
    const expected=refPosition.getElement(j,[]);
    for(let k=0;k<3;k++)if(Math.abs(src[i*3+k]-offset[k]-expected[k])>1e-5)throw new Error('Rig geometry changed; recalibration required.');
  }
}
const front = new Float32Array(src.length);
for (let i=0;i<src.length;i+=3) front.set([-(src[i+2]-offset[2]),src[i+1]-offset[1],src[i]-offset[0]],i);
// Index the projected triangles once. Expression preparation samples thousands
// of face points; each query only visits its local bin, even on the dense asset.
const indices = source.getIndices().getArray(), bins = new Map(), binSize = .012;
const binKey = (x,y) => `${x},${y}`;
for (let i=0;i<indices.length;i+=3) {
  const points=[indices[i],indices[i+1],indices[i+2]].map(j=>[front[j*3],front[j*3+1],front[j*3+2]]);
  const minY=Math.min(...points.map(p=>p[1])),maxY=Math.max(...points.map(p=>p[1]));
  if(maxY<.025||minY>.23)continue;
  const minX=Math.floor(Math.min(...points.map(p=>p[0]))/binSize),maxX=Math.floor(Math.max(...points.map(p=>p[0]))/binSize);
  for(let x=minX;x<=maxX;x++)for(let y=Math.floor(minY/binSize);y<=Math.floor(maxY/binSize);y++) {
    const key=binKey(x,y);if(!bins.has(key))bins.set(key,[]);bins.get(key).push(points);
  }
}
const surfaceCache = new Map();
function surface(x,y,eye=false) {
  const key=`${x.toFixed(5)},${y.toFixed(5)},${eye}`;
  if(surfaceCache.has(key))return surfaceCache.get(key);
  let z=-Infinity;
  for(const [a,b,c] of bins.get(binKey(Math.floor(x/binSize),Math.floor(y/binSize)))||[]) {
    const d=(b[1]-c[1])*(a[0]-c[0])+(c[0]-b[0])*(a[1]-c[1]);
    if(Math.abs(d)<1e-12)continue;
    const u=((b[1]-c[1])*(x-c[0])+(c[0]-b[0])*(y-c[1]))/d;
    const v=((c[1]-a[1])*(x-c[0])+(a[0]-c[0])*(y-c[1]))/d,w=1-u-v;
    if(u<0||v<0||w<0)continue;
    const depth=u*a[2]+v*b[2]+w*c[2];
    if(!eye||depth<.216)z=Math.max(z,depth);
  }
  if(!Number.isFinite(z))z=.18;
  surfaceCache.set(key,z);return z;
}
const names=['blinkLeft','blinkRight','aa','ee','ou'];
const fittedEyes=profile.eyeMode==='fitted';
const material=doc.createMaterial('ExpressionSkin').setBaseColorFactor([1,1,1,1]).setRoughnessFactor(.9).setMetallicFactor(0).setDoubleSided(true).setAlphaMode('BLEND');
const lidMaterial=fittedEyes?doc.createMaterial('EyeLids').setBaseColorFactor([1,1,1,1]).setRoughnessFactor(.58).setMetallicFactor(0).setDoubleSided(true).setAlphaMode('BLEND'):material;
const faceMesh=doc.createMesh('FacialExpressions').setExtras({targetNames:names}).setWeights(names.map(()=>0));
const skin=new T.Color().setRGB(...(profile.skin||[224,199,184]).map(v=>v/255),T.SRGBColorSpace);
const blush=new T.Color().setRGB(...(profile.blush||[227,175,160]).map(v=>v/255),T.SRGBColorSpace);
const dark=new T.Color('#4c2c3c'),lash=new T.Color('#30232f'),tongue=new T.Color('#c7768d');
const toSource=([x,y,z])=>[z+offset[0],y+offset[1],-x+offset[2]];
function addPart(name,base,targets,colors,indices,alphas=[],partMaterial=material) {
  const positions=new Float32Array(base.flatMap(toSource));
  const g=new T.BufferGeometry();g.setAttribute('position',new T.BufferAttribute(new Float32Array(targets.find(Boolean)?.flatMap(toSource)||positions),3));g.setIndex(indices);g.computeVertexNormals();
  const normals=g.getAttribute('normal').array;
  const accessor=(label,type,array)=>doc.createAccessor(label).setType(type).setArray(array).setBuffer(buffer);
  const p=doc.createPrimitive().setMaterial(partMaterial).setAttribute('POSITION',accessor(name,'VEC3',positions)).setAttribute('NORMAL',accessor(`${name}:normal`,'VEC3',normals)).setAttribute('COLOR_0',accessor(`${name}:color`,'VEC4',new Float32Array(colors.flatMap((c,i)=>[...c.toArray(),alphas[i]??1])))).setIndices(accessor(`${name}:indices`,'SCALAR',new Uint16Array(indices)));
  for(let s=0;s<names.length;s++) {
    const target=targets[s]||base,delta=new Float32Array(positions.length);
    for(let i=0;i<target.length;i++){const point=toSource(target[i]);for(let c=0;c<3;c++)delta[i*3+c]=point[c]-positions[i*3+c];}
    p.addTarget(doc.createPrimitiveTarget(names[s]).setAttribute('POSITION',accessor(`${name}:${names[s]}`,'VEC3',delta)));
  }
  faceMesh.addPrimitive(p);
}
function gridIndices(columns,rows) {
  const indices=[];
  for(let y=0;y<rows;y++)for(let x=0;x<columns;x++){const a=y*(columns+1)+x,b=a+columns+1;indices.push(a,b,a+1,a+1,b,b+1);}
  return indices;
}
for(let side=0;side<2;side++) {
  const cx=profile.eyes?.[side]??(side===0?-.095:.045),rx=profile.eyeRadius??.061;
  const palette=profile.eyeColors?.[side];
  const lidSkin=palette?new T.Color().setRGB(...palette.skin.map(v=>v/255),T.SRGBColorSpace):skin;
  const lidBlush=palette?new T.Color().setRGB(...palette.blush.map(v=>v/255),T.SRGBColorSpace).lerp(lidSkin,.65):blush;
  // Fit the recessed eye socket, behind the bangs. The upper lid has real area
  // even when open, so generated lash bumps cannot emerge above the moving rim.
  const lidSurface=fittedEyes
    ?(x,y)=>(profile.lidDepth??.190)+(side===0?1:-1)*(profile.lidSlope??.26)*(x-cx)-1.8*(x-cx)**2+.13*(y-.13)
    :(x,y)=>Math.min(profile.lidCap??.218,(profile.lidDepth??.216)+(side===0?1:-1)*(profile.lidSlope??.25)*(x-cx)-2*(x-cx)**2)+.03*(y-.13);
  for(const lower of [false,true]) {
    const base=[],closed=[],colors=[],alphas=[],columns=40,rows=14;
    for(let j=0;j<=rows;j++)for(let i=0;i<=columns;i++) {
      const u=i/columns*2-1,v=j/rows,x=cx+rx*u;
      const fixed=lower?(profile.lowerEdge??.090)+(profile.lowerCurve??.036)*u*u:(profile.upperEdge??.188)-(profile.upperCurve??.023)*u*u;
      const lid=(profile.closedY??.111)+(profile.closedCurve??.020)*u*u;
      const y=fixed+(lid-fixed)*v;
      const openY=lower?(profile.openLower??.100)+(profile.openLowerCurve??.030)*u*u:(profile.openUpper??.157)-(profile.openUpperCurve??.025)*u*u;
      const baseY=fittedEyes&&!lower?fixed+(openY-fixed)*v:openY;
      base.push([x,baseY,fittedEyes&&!lower?lidSurface(x,baseY):surface(x,openY,true)+.001]);
      closed.push([x,y,lidSurface(x,y)]);
      colors.push(lower?lidBlush.clone().lerp(lidSkin,v):lidSkin.clone());
      alphas.push(T.MathUtils.smoothstep(v,0,fittedEyes ? .20 : .24)*(1-T.MathUtils.smoothstep(Math.abs(u),fittedEyes ? .90 : .94,1)));
    }
    const targets=[];targets[side]=closed;
    addPart(`${lower?'Lower':'Upper'}Lid${side}`,base,targets,colors,gridIndices(columns,rows),alphas,lidMaterial);
  }
  const base=[],closed=[],colors=[],columns=48;
  for(let j=0;j<=1;j++)for(let i=0;i<=columns;i++) {
    const u=i/columns*2-1,x=cx+rx*u,lid=(profile.closedY??.111)+(profile.closedCurve??.020)*u*u;
    const y=lid+(j===0?-.0003:(profile.lashThickness??.0018))*Math.sqrt(Math.max(0,1-u*u));
    const openY=(profile.openUpper??.157)-(profile.openUpperCurve??.025)*u*u;
    const openLashY=openY+(j===0?-.0003:(profile.lashThickness??.0018))*Math.sqrt(Math.max(0,1-u*u));
    base.push(fittedEyes?[x,openLashY,lidSurface(x,openLashY)+(profile.lashOffset??.0012)]:[x,openY,surface(x,openY,true)+.0015]);
    closed.push([x,y,lidSurface(x,y)+(profile.lashOffset??.0007)]);colors.push(lash);
  }
  const targets=[];targets[side]=closed;
  addPart(`Lashes${side}`,base,targets,colors,gridIndices(columns,1));
}
// A recessed mouth with a skin rim and tongue. Aa/Ee/Ou share the same topology.
const segments=48;
const mouthX=profile.mouthX??-.025,mouthY=profile.mouthY??.074;
function mouth(rx,ry) {
  const positions=[],colors=[],indices=[];
  const rings=[[1.32,skin,.0015],[1.04,skin.clone().lerp(tongue,.12),.002],[.95,dark,.001],[.5,dark,.0006],[0,dark,.0006]];
  for(const [r,color,depth] of rings)for(let i=0;i<=segments;i++) {
    const a=i/segments*Math.PI*2,x=mouthX+Math.cos(a)*rx*r,y=mouthY+Math.sin(a)*ry*r;
    positions.push([x,y,surface(x,y)+depth]);colors.push(color);
  }
  indices.push(...gridIndices(segments,rings.length-1));
  const start=positions.length;
  for(let i=0;i<=segments;i++) {
    const a=i/segments*Math.PI*2,x=mouthX+Math.cos(a)*rx*.55,y=mouthY-ry*.46+Math.sin(a)*ry*.22;
    positions.push([x,y,surface(x,y)+.0011]);colors.push(tongue);
  }
  positions.push([mouthX,mouthY-ry*.46,surface(mouthX,mouthY-ry*.46)+.0011]);colors.push(tongue);
  const center=positions.length-1;
  for(let i=0;i<segments;i++)indices.push(center,start+i,start+i+1);
  return {positions,colors,indices};
}
const neutral=mouth(.0115,.00025),aa=mouth(.012,.010),ee=mouth(.016,.005),ou=mouth(.008,.009);
addPart('Mouth',neutral.positions,[null,null,aa.positions,ee.positions,ou.positions],neutral.colors,neutral.indices);
const faceNode=doc.createNode('FaceRig').setMesh(faceMesh);
if(skinning) {
  const joints=skinning.listJoints(),head=joints.findIndex(j=>/head$/i.test(j.getName()));
  if(head<0)throw new Error('Rig has no identifiable Head joint.');
  // Keep the face rigid with its expression geometry. Automatic neck blending
  // otherwise lets painted eyes and lips slide under the eyelids when turning.
  const ids=source.getAttribute('JOINTS_0'),weights=source.getAttribute('WEIGHTS_0');
  for(let i=0;i<src.length;i+=3) {
    const y=front[i+1],z=front[i+2];
    if(y>.055||(y>.035&&z>.13&&Math.abs(front[i]+.025)<.19)) {
      ids.setElement(i/3,[head,0,0,0]);weights.setElement(i/3,[1,0,0,0]);
    }
  }
  faceNode.setSkin(skinning);
  for(const p of faceMesh.listPrimitives()) {
    const count=p.getAttribute('POSITION').getCount(),ids=new Uint16Array(count*4),weights=new Float32Array(count*4);
    for(let i=0;i<count;i++){ids[i*4]=head;weights[i*4]=1;}
    p.setAttribute('JOINTS_0',doc.createAccessor().setType('VEC4').setArray(ids).setBuffer(buffer));
    p.setAttribute('WEIGHTS_0',doc.createAccessor().setType('VEC4').setArray(weights).setBuffer(buffer));
  }
}
// Keep expression vertices in exactly the original model's coordinate frame.
faceNode.setMatrix(bodyNode.getMatrix());
const parent=bodyNode.getParentNode();
if(parent)parent.addChild(faceNode);else root.listScenes()[0].addChild(faceNode);
await io.write(output,doc);
const report={input,output,referencePath,profile,names,facialVertices:faceMesh.listPrimitives().reduce((n,p)=>n+p.getAttribute('POSITION').getCount(),0),skinned:!!skinning,sourceFrameOffset:offset};
await writeFile(`${output}.expressions.json`,JSON.stringify(report,null,2)+'\n');console.log(report);

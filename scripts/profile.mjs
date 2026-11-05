import { chromium } from 'playwright';
import {mkdir,writeFile} from 'node:fs/promises';
const name=process.argv[2]||'current';
await mkdir('evidence',{recursive:true});
const browser=await chromium.launch({channel:'chrome',headless:true});
try {
 const page=await browser.newPage({viewport:{width:1200,height:800},deviceScaleFactor:2});
 await page.addInitScript(()=>{
  window.__motionStates=[];
  document.addEventListener('DOMContentLoaded',()=>{
   const status=document.querySelector('#status');
   new MutationObserver(()=>{const value=status.textContent;if(window.__motionStates.at(-1)!==value)window.__motionStates.push(value);}).observe(status,{childList:true,subtree:true,characterData:true});
  });
  window.__renderProbe={calls:0,triangles:0};
  const original=HTMLCanvasElement.prototype.getContext;
  HTMLCanvasElement.prototype.getContext=function(...args){
   const gl=original.apply(this,args);
   if(gl&&args[0]==='webgl2'&&!gl.__probed){
    gl.__probed=true;window.__gl=gl;
    const draw=gl.drawElements.bind(gl);
    gl.drawElements=(mode,count,...rest)=>{window.__renderProbe.calls++;if(mode===gl.TRIANGLES)window.__renderProbe.triangles+=count/3;return draw(mode,count,...rest);};
   }return gl;
  };
 });
 await page.goto('http://127.0.0.1:4173',{waitUntil:'networkidle',timeout:60000});
 await page.waitForFunction(()=>!document.querySelector('[data-action="idle"]').disabled);
 await page.waitForTimeout(1000);
 const cdp=await page.context().newCDPSession(page);
 await cdp.send('Profiler.enable');await cdp.send('Profiler.start');
 const measure=()=>page.evaluate(async()=>{
  const gaps=[];let last=performance.now();const start=last;
  const probe=window.__renderProbe;const calls=probe.calls,triangles=probe.triangles;
  await new Promise(resolve=>{function tick(now){gaps.push(now-last);last=now;if(now-start<3000)requestAnimationFrame(tick);else resolve();}requestAnimationFrame(tick);});
  gaps.shift();gaps.sort((a,b)=>a-b);
  const ext=window.__gl.getExtension('WEBGL_debug_renderer_info');
  return {fps:Math.round(gaps.length/(last-start)*1000),p95FrameMs:Math.round(gaps[Math.floor(gaps.length*.95)]*10)/10,drawCallsPerFrame:Math.round((probe.calls-calls)/gaps.length),trianglesPerFrame:Math.round((probe.triangles-triangles)/gaps.length),gpu:ext?window.__gl.getParameter(ext.UNMASKED_RENDERER_WEBGL):'unknown',drawingBuffer:[window.__gl.drawingBufferWidth,window.__gl.drawingBufferHeight]};
 });
 const idle=await measure();
 const moving=measure();
 for(let i=0;i<90;i++)await page.mouse.move(440+Math.sin(i*.2)*200,380+Math.cos(i*.2)*120);
 const pointer=await moving;
 const {profile}=await cdp.send('Profiler.stop');
 const names=new Map(profile.nodes.map(n=>[n.id,n.callFrame.functionName||'(anonymous)']));
 const counts={};for(const id of profile.samples||[])counts[names.get(id)]=(counts[names.get(id)]||0)+1;
 const report={name,idle,pointer,observedStates:await page.evaluate(()=>window.__motionStates),hotFunctions:Object.entries(counts).sort((a,b)=>b[1]-a[1]).slice(0,18)};
 await writeFile(`evidence/performance-${name}.json`,JSON.stringify(report,null,2));
 await page.screenshot({path:`evidence/proportion-${name}.png`});
 console.log(JSON.stringify(report,null,2));
} finally {await browser.close();}

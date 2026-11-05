// Compositor sprites on real Windows hardware (src/zenit_app/sprite_host.zig,
// native/windows/compositor_sprites.cpp): images are what DWM composes for the
// window, read from the screen (/windows/capture*); drawable readback cannot
// see sprite visuals. The Windows counterpart of scripts/check_compositor_sprites.py.
//
//   exact      locked frame clock on a flipbook sample, sprites frozen on that
//              frame; disabling sprites makes the GPU paint the same instant:
//              the composed windows must match per channel (max diff 0), and no
//              frame is rendered while the sprites are up. Spinner and button
//              (loading rings over button fills) pages.
//   live       real clock: DWM animates (images 270 ms apart differ) while the
//              application renders nothing.
//   hand-off   real clock, one image per composition of a sprite's cell while
//              the sprite leaves (GPU paints again) and later takes over again.
//              Every image must be a picture of the animation (nearest flipbook
//              frame), and the frame index must advance by a frame or so per
//              composition across both hand-offs: a stale presentation (the
//              frame from before the sprite took over) or a missing node would
//              show as a jump or as no match.
import {clickTestId,key,mouseMove,request,sleep,stats,waitForServerReady} from './client';
import {assert,getSessionDir,run,test,writeSessionFile} from './runner';
import {decodePng,type DecodedPng} from './png';

const results:any[]=[];
function check(name:string,ok:boolean,detail:any={}){
 results.push({check:name,ok,...detail});
 writeSessionFile('sprites.json',JSON.stringify({results},null,2));
 console.log((ok?'PASS ':'FAIL ')+name+' '+JSON.stringify(detail));
}
const sprites=(body:any={})=>request('POST','/sprites',body);

async function navigate(name:string){
 await request('POST','/redraw',{continuous:false});
 await mouseMove(-10,-10);
 for(let i=0;i<3;i++)await key('escape');
 assert((await clickTestId('nav.'+name)).ok,'navigation failed '+name);
 await sleep(1200);
}

async function waitUntil<T>(f:()=>Promise<T|false|null|undefined>,ms:number,interval=100):Promise<T|false|null|undefined>{
 const end=performance.now()+ms;
 for(;;){const v=await f(); if(v||performance.now()>end)return v; await sleep(interval);}
}

// Frames rendered over `ms` without harness traffic (each command renders one).
async function quietFrames(ms:number):Promise<number>{
 const a=(await stats()).frame_count; await sleep(ms); return (await stats()).frame_count-a-1;
}

let shot=0;
async function capture(tag:string,rect=[0,0,0,0]):Promise<DecodedPng>{
 const path=`${getSessionDir()}/${String(shot++).padStart(2,'0')}-${tag}.png`;
 const r=await request('POST','/windows/capture',{path,x:rect[0],y:rect[1],w:rect[2],h:rect[3]});
 assert(r?.ok===true,'capture failed '+tag);
 return decodePng(path);
}

function px(img:DecodedPng,x:number,y:number,c:number){return img.pixels[(y*img.width+x)*img.channels+c];}

// Per-channel max difference inside rects (window pixels).
function regionDiff(a:DecodedPng,b:DecodedPng,rects:number[][]){
 let max=0,pixels=0,cells=0;
 for(const [x0,y0,w,h] of rects){
  // Cells may reach past the window (a ring scrolled half out of view);
  // a cell wholly outside it shows nothing.
  const W=Math.min(a.width,b.width), H=Math.min(a.height,b.height);
  if(x0>=W||y0>=H||x0+w<=0||y0+h<=0)continue;
  cells++;
  for(let y=Math.max(0,y0);y<Math.min(H,y0+h);y++)for(let x=Math.max(0,x0);x<Math.min(W,x0+w);x++){
   let d=0; for(let c=0;c<3;c++)d=Math.max(d,Math.abs(px(a,x,y,c)-px(b,x,y,c)));
   if(d>0)pixels++; max=Math.max(max,d);
  }
 }
 return {max,pixels,cells};
}
function wholeDiff(a:DecodedPng,b:DecodedPng){return regionDiff(a,b,[[0,0,Math.min(a.width,b.width),Math.min(a.height,b.height)]]);}

const PERIOD_MS=5600;

async function exact(story:string){
 const tag=story+'-exact';
 await navigate(story);
 await request('POST','/sprites/freeze',{on:true});
 assert((await sprites({enabled:true}))?.enabled===true,'sprites did not enable');
 await request('POST','/clock',{step_ms:8,locked:true});
 await sleep(300);
 // A locked clock settles sprites only while it advances: let them settle
 // (and their atlases build) first, then land on a flipbook sample.
 await request('POST','/clock/advance',{ms:1000});
 await waitUntil(async()=>{const s=await sprites(); return s.building===0&&s.active>0&&s;},6000);
 const s0=await sprites();
 const frames=Math.round(PERIOD_MS*120/1000);
 const dt=PERIOD_MS/frames;
 // Mid cycle: long arcs, so a phase error cannot hide in a tiny one.
 const target=(Math.floor(s0.frame_time_ms/dt)+3+240)*dt;
 await request('POST','/clock/advance',{ms:target-s0.frame_time_ms});
 const st:any=await waitUntil(async()=>{const s=await sprites(); return s.active>0&&s.active===s.placements&&s.building===0&&Math.abs(s.frame_time_ms-target)<1e-3&&s;},8000);
 check(tag+': sprites admitted',!!st&&st.active>0,{status:st||await sprites()});
 const settled=await waitUntil(async()=>(await quietFrames(500))<=0,4000,0);
 const quiet=await quietFrames(600);
 check(tag+': no frames while composited',!!settled&&quiet<=0,{frames:quiet});
 const rects:number[][]=st?st.rects:[];
 const sprite=await capture(tag+'-sprite');
 await sprites({enabled:false});
 const gone=await waitUntil(async()=>(await sprites()).active===0,3000);
 await sleep(400);
 check(tag+': sprites released',!!gone);
 check(tag+': frozen clock unchanged',Math.abs((await sprites()).frame_time_ms-target)<1e-3);
 const gpu=await capture(tag+'-gpu');
 const cells=regionDiff(sprite,gpu,rects);
 // With the native title bar the client area is shorter and the button
 // page's rings sit below it: placed without a visual, nothing to compare
 // (cells counts only cells inside the window).
 check(tag+': composited sprites == GPU paint (per-channel max 0)',rects.length>0&&cells.max===0&&(cells.cells>0||story==='button'),{...cells,rects});
 const all=wholeDiff(sprite,gpu);
 check(tag+': whole window unchanged by the hand-over',all.max===0,all);
 await request('POST','/sprites/freeze',{on:false});
 await request('POST','/clock',{step_ms:0});
 return {rects,status:st};
}

async function live(){
 await navigate('spinner');
 await sprites({enabled:true});
 const st:any=await waitUntil(async()=>{const s=await sprites(); return s.active>0&&s.active===s.sources&&s;},8000);
 check('live: sprites admitted',!!st,{status:st||await sprites()});
 const settled=await waitUntil(async()=>(await quietFrames(500))<=0,4000,0);
 const quiet=await quietFrames(1000);
 check('live: no frames while animating',!!settled&&quiet<=0,{frames:quiet});
 const a=await capture('live-a'); await sleep(270); const b=await capture('live-b');
 const d=regionDiff(a,b,st?st.rects:[]);
 check('live: the compositor animates',d.pixels>50,d);
 check('live: still composited after captures',(await sprites()).active>0);
 await sprites({enabled:false});
}

// Place every burst image in the loop: the flipbook step k whose frames k and
// k+1 bracket it pixel by pixel (within `tol`). A sprite shows a flipbook
// frame exactly; a GPU frame painted between two samples lies between them,
// except where the arc is shorter than one step's travel (a pixel it crosses
// between two samples is lit in neither): hence the tolerance. A stale or
// missing picture is off by 150 levels and more.
function placeFrames(book:DecodedPng,info:any,burst:DecodedPng,count:number,tol=48){
 const [cw,ch]=info.cell; const cols=info.columns; const n=info.frames;
 const frameAt=(f:number,x:number,y:number,c:number)=>px(book,(f%cols)*cw+x,Math.floor(f/cols)*ch+y,c);
 const out:{index:number,outside:number,exact:boolean}[]=[];
 let prev=-1;
 for(let i=0;i<count;i++){
  const outside=(k:number,limit:number)=>{
   const k1=(k+1)%n; let worst=0;
   for(let y=0;y<ch;y++)for(let x=0;x<cw;x++)for(let c=0;c<3;c++){
    const a=frameAt(k,x,y,c), b=frameAt(k1,x,y,c), v=px(burst,x,i*ch+y,c);
    const d=Math.max(0,Math.min(a,b)-v,v-Math.max(a,b));
    if(d>worst){worst=d; if(worst>limit)return worst;}
   }
   return worst;
  };
  let best=-1,bestOut=1e9;
  // Near the previous image first: when the arc is at its shortest a few
  // distant frames look alike, and the animation only moves forward.
  if(prev>=0)for(let k=-2;k<=8;k++){const f=((prev+k)%n+n)%n; const o=outside(f,bestOut); if(o<bestOut){bestOut=o;best=f;}}
  if(bestOut>tol)for(let f=0;f<n;f++){const o=outside(f,bestOut); if(o<bestOut){bestOut=o;best=f; if(o===0)break;}}
  // Exactly a flipbook frame (what a sprite shows), not just between two.
  const equal=(f:number)=>{for(let y=0;y<ch;y++)for(let x=0;x<cw;x++)for(let c=0;c<3;c++)if(frameAt(f,x,y,c)!==px(burst,x,i*ch+y,c))return false; return true;};
  const exact=bestOut===0&&(equal(best)||equal((best+1)%n));
  out.push({index:best,outside:bestOut,exact}); prev=best;
 }
 return {frames:out,tol};
}

// The sprite shows flipbook frames exactly: runs of exact images are the
// compositor's, the rest the GPU path's. Hand-overs are the run boundaries.
function spriteRuns(m:{exact:boolean}[],minLength=10){
 const runs:[number,number][]=[]; let start=-1;
 for(let i=0;i<=m.length;i++){
  const exact=i<m.length&&m[i].exact;
  if(exact&&start<0)start=i;
  if(!exact&&start>=0){if(i-start>=minLength)runs.push([start,i-1]); start=-1;}
 }
 return runs;
}

async function handoff(){
 await navigate('spinner');
 await sprites({enabled:true});
 const st:any=await waitUntil(async()=>{const s=await sprites(); return s.active>0&&s.active===s.sources&&s;},8000);
 check('hand-off: sprites admitted',!!st,{status:st||await sprites()});
 if(!st)return;
 // Long enough under the compositor that a stale presentation would show.
 await sleep(1500);
 const bookPath=`${getSessionDir()}/handoff-flipbook.png`;
 const info:any=await request('POST','/sprites/flipbook',{path:bookPath,index:0});
 check('hand-off: flipbook written',info?.ok===true,{info});
 if(!info?.ok)return;
 const [x,y]=info.origin, [w,h]=info.cell;
 const count=480;
 const burstPath=`${getSessionDir()}/handoff-burst.png`;
 assert((await request('POST','/windows/capture-burst',{path:burstPath,x,y,w,h,count}))?.ok===true,'burst did not start');
 await sleep(500);
 await sprites({enabled:false});          // sprite -> GPU frames
 await sleep(800);
 await sprites({enabled:true});           // GPU frames -> sprite after settling
 // Poll without blocking the UI thread (a waiting command would stall frames).
 const timeline:any[]=[]; const t0=performance.now();
 const done:any=await waitUntil(async()=>{
  const sp=await sprites(); timeline.push({ms:Math.round(performance.now()-t0),active:sp.active,building:sp.building,reason0:sp.reasons?.[0],error:sp.host_error});
  const r=await request('POST','/windows/capture-burst-wait',{timeout_ms:0}); return r?.done&&r;},15000,50);
 writeSessionFile('handoff-timeline.json',JSON.stringify(timeline,null,1));
 check('hand-off: burst captured',done?.ok===true,{done});
 if(!done?.ok)return;
 const book=decodePng(bookPath), burst=decodePng(burstPath);
 const placed=placeFrames(book,info,burst,count);
 const m=placed.frames;
 const n=info.frames;
 // Signed loop steps (a GPU frame may show an instant just before the sprite's last).
 const steps=m.slice(1).map((e,i)=>{const d=((e.index-m[i].index)%n+n)%n; return d>n/2?d-n:d;});
 const worst=Math.max(...m.map(e=>e.outside));
 // Images are a composition or two apart (2 frames at 120 Hz). Across a
 // hand-over the GPU path's own presentation latency (1.5 to 4 frames) shows
 // as a step up to 3 frames off: within the GPU path's latency jitter, as the
 // macOS caret check allows.
 const runs=spriteRuns(m);
 const handovers:{at:number,step:number,kind:string}[]=[];
 for(const [a,b] of runs){
  if(a>0)handovers.push({at:a-1,step:steps[a-1],kind:'gpu->sprite'});
  if(b<m.length-1)handovers.push({at:b,step:steps[b],kind:'sprite->gpu'});
 }
 const gpuSteps=steps.filter((_,i)=>!runs.some(([a,b])=>i>=a&&i<b));
 writeSessionFile('handoff.json',JSON.stringify({info,matches:m,steps,runs,handovers},null,1));
 check('hand-off: every composition is a frame of the animation',worst<=placed.tol,{worst,exact:m.filter(e=>e.exact).length,count});
 check('hand-off: sprite, GPU path, sprite again',runs.length===2&&runs[0][0]===0&&handovers.length===2,{runs});
 check('hand-off: phase continuous across hand-overs',handovers.every(h=>Math.abs(h.step-2)<=3),{handovers,
  gpu_steps_hist:gpuSteps.reduce((h:any,s)=>{h[s]=(h[s]??0)+1;return h;},{})});
 await sprites({enabled:false});
}

test('compositor sprites on real hardware',async()=>{
 await waitForServerReady(15000);
 const active=await request('POST','/windows/native-input',{action:'activate'});
 assert(active.foreground===true,'app is not the foreground window');
 const host=await sprites();
 assert(typeof host?.atlas_bytes==='number','this build has no Windows sprite host');
 // Every compacted atlas built, for offline checks.
 await request('POST','/sprites/dump',{path:getSessionDir()});
 await exact('spinner');
 await exact('button');
 await live();
 await handoff();
 const failed=results.filter(r=>!r.ok);
 assert(failed.length===0,`${failed.length} sprite checks failed: ${failed.map(f=>f.check).join('; ')}`);
});

run();

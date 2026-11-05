// In-use cost on real Windows hardware, measured like scripts/measure_usage.py on macOS:
// an app-injected 120 Hz wheel stream per scene, process CPU from the OS, GPU dedicated
// memory from the GPU Process Memory counters, frame cadence and per-frame stage times
// from /stats. Diagnostics: rows are recorded, only collection failures fail the test.
import {clickTestId,key,mouseMove,request,resetTiming,sleep,stats,tree,waitForServerReady} from './client';
import {assert,run,test,writeSessionFile} from './runner';
import {spawnSync} from 'node:child_process';

const rows:any[]=[];
function save(){writeSessionFile('scroll-perf.json',JSON.stringify({rows},null,2));}

function ps(script:string):string{
 const r=spawnSync('powershell.exe',['-NoProfile','-NonInteractive','-Command',script],{encoding:'utf8',timeout:30000});
 return (r.stdout??'').trim();
}
let pid=0;
function appPid():number{
 if(!pid)pid=Number(ps("(Get-Process -Name 'zenit-windows-storybook' | Sort-Object StartTime -Descending | Select-Object -First 1).Id"));
 return pid;
}
// Process CPU seconds plus per-thread CPU ms in one snapshot (the main thread is the oldest).
function cpuSnapshot():{total:number,threads:Map<number,number>,main:number}{
 const out=ps(`$p=Get-Process -Id ${appPid()}; "$($p.TotalProcessorTime.TotalSeconds)"; $p.Threads | Sort-Object StartTime | % { "$($_.Id) $($_.TotalProcessorTime.TotalMilliseconds)" }`);
 const lines=out.split(/\r?\n/).map(l=>l.trim()).filter(Boolean);
 const threads=new Map<number,number>(); let main=0;
 for(const l of lines.slice(1)){const [id,ms]=l.split(/\s+/).map(Number); if(!main)main=id; threads.set(id,ms);}
 return {total:Number(lines[0]),threads,main};
}
function threadPct(a:ReturnType<typeof cpuSnapshot>,b:ReturnType<typeof cpuSnapshot>,elapsed:number){
 const rows:[number,number][]=[];
 for(const [id,ms] of b.threads)rows.push([id,(ms-(a.threads.get(id)??0))/10/elapsed]);
 rows.sort((x,y)=>y[1]-x[1]);
 const main=rows.find(r=>r[0]===b.main);
 return {main_thread_pct:Math.round((main?.[1]??0)*10)/10,top_threads:rows.slice(0,5).map(([id,p])=>`${id===b.main?'main':id}:${Math.round(p*10)/10}`).join(' ')};
}
function stageMeans(t0:any,t1:any){
 if(!t1)return null;
 const frames=(t1.frames??0)-(t0?.frames??0); if(frames<=0)return null;
 const out:any={frames};
 for(const k of Object.keys(t1))if(k!=='frames')out[k]=Math.round(((t1[k]??0)-(t0?.[k]??0))/frames*10)/10;
 return out;
}
function gpuMiB():{dedicated:number,shared:number}{
 // One instance per (pid, adapter LUID, engine-less physical segment); sum them.
 const out=ps(`$s=(Get-Counter -ErrorAction SilentlyContinue '\\GPU Process Memory(pid_${appPid()}_*)\\Dedicated Usage','\\GPU Process Memory(pid_${appPid()}_*)\\Shared Usage').CounterSamples; `+
  `$d=($s|?{$_.Path -like '*dedicated usage'}|Measure-Object CookedValue -Sum).Sum; $h=($s|?{$_.Path -like '*shared usage'}|Measure-Object CookedValue -Sum).Sum; "$d $h"`);
 const [d,h]=out.split(/\s+/).map(Number);
 return {dedicated:Math.round((d||0)/1048576*10)/10,shared:Math.round((h||0)/1048576*10)/10};
}
function workingSetMiB():number{return Math.round(Number(ps(`(Get-Process -Id ${appPid()}).PrivateMemorySize64`))/1048576*10)/10;}

async function navigate(name:string){
 await request('POST','/redraw',{continuous:false});
 await mouseMove(-10,-10);
 for(let i=0;i<3;i++)await key('escape');
 assert((await clickTestId('nav.'+name)).ok,'navigation failed '+name);
 await sleep(1500);
}

async function sample(scene:string,phase:string,ms:number,stream?:{x:number,y:number}){
 // Real native input keeps the display awake; injected input does not reset the idle timer.
 await request('POST','/windows/native-input',{action:'key',vk:0x10,edge:'press'});
 await resetTiming();
 const s0=await stats(), c0=cpuSnapshot(), t0=performance.now();
 if(stream){
  const count=Math.round(ms/1000*120);
  assert((await request('POST','/scroll_stream',{x:stream.x,y:stream.y,step:12,span:30,count,interval_ms:1000/120})).ok,'scroll_stream failed');
 }
 await sleep(ms);
 const c1=cpuSnapshot(), t1=performance.now(), s1=await stats();
 const gpu=gpuMiB();
 const elapsed=(t1-t0)/1000;
 const row={scene,phase,cpu_pct:Math.round(1000*(c1.total-c0.total)/elapsed)/10,...threadPct(c0,c1,elapsed),
  fps:Math.round(10*(s1.frame_count-s0.frame_count)/elapsed)/10,
  gpu_dedicated_mib:gpu.dedicated,gpu_shared_mib:gpu.shared,private_mib:workingSetMiB(),
  cpu_frame_us:s1.cpu_frame_us,cpu_p95_us:s1.cpu_p95_us,gpu_execute_us:s1.gpu_execute_us,gpu_p95_us:s1.gpu_p95_us,
  total_frame_us:s1.total_frame_us,total_p95_us:s1.total_p95_us,layout_us:s1.layout_us,render_gen_us:s1.render_gen_us,
  gpu_encode_us:s1.gpu_encode_us,timing_samples:s1.timing_samples,renderer:s1.renderer_backend,scale:s1.window_scale,
  mean:stageMeans(s0.stage_totals,s1.stage_totals)};
 rows.push(row);save();console.log('PERF '+JSON.stringify(row));
 assert(Number.isFinite(row.cpu_pct),'cpu sample failed');
 return row;
}

test('scroll and idle CPU / GPU memory / cadence on real hardware',async()=>{
 await waitForServerReady(15000);
 const active=await request('POST','/windows/native-input',{action:'activate'});
 assert(active.foreground===true,'app is not the foreground window');
 const win=(await tree()).rect;
 rows.push({phase:'environment',window:win,pid:appPid(),scale:(await stats()).window_scale,renderer:(await stats()).renderer_backend});save();
 const scenes:[string,string,number,number][]=[
  ['sidebar-scroll','button',120,win.h*0.55],
  ['list-scroll','virtuallist',400,260],
  // glasschrome's content scrolls under its toolbar glass (glasslab has no
  // scroll area there: the wheel moved nothing and measured no-op frames).
  ['glass-scroll','glasschrome',win.w*0.5,win.h*0.35],
 ];
 for(let rep=0;rep<2;rep++){
  for(const [scene,story,x,y] of scenes){
   await navigate(story);
   await sample(scene,'idle-before',4000);
   const r=await sample(scene,'scroll',8000,{x,y});
   // A wheel stream over content that cannot scroll renders nothing: the row
   // would measure an idle page, not scrolling.
   assert(r.fps>=30,`${scene}: the wheel stream did not scroll (fps ${r.fps})`);
   await sleep(1500);
   await sample(scene,'idle-after',4000);
  }
 }
 await navigate('spinner');
 await sample('spinner','idle-animating',6000);
 // Animation frame-rate policy: the same spinner page presenting every 1st,
 // 2nd and 4th vblank (120 / 60 / 30 Hz on a 120 Hz panel), interleaved.
 for(let rep=0;rep<2;rep++)for(const interval of [1,2,4]){
  const set=await request('POST','/perf/present-interval',{interval});
  if(!set?.ok){rows.push({phase:'present-interval-unsupported',interval});save();break;}
  await sleep(500);
  await sample('spinner',`present-interval-${interval}`,6000);
 }
 await request('POST','/perf/present-interval',{interval:0});
});

run();

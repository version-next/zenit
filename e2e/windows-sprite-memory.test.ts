// Memory over a compositor sprite's life on real Windows hardware: GPU (shared)
// and private memory and atlas bytes while sprites take over the button and
// spinner pages, and after leaving them (transient build storage must not
// stay). Diagnostics: rows are recorded, only collection failures fail the test.
import {clickTestId,key,mouseMove,request,resetTiming,sleep,stats,tree,waitForServerReady} from './client';
import {assert,run,test,writeSessionFile} from './runner';
import {spawn,spawnSync} from 'node:child_process';

const rows:any[]=[];
function save(){writeSessionFile('sprite-memory.json',JSON.stringify({rows},null,2));}

function ps(script:string):string{
 const r=spawnSync('powershell.exe',['-NoProfile','-NonInteractive','-Command',script],{encoding:'utf8',timeout:30000});
 return (r.stdout??'').trim();
}
let pid=0;
function appPid():number{
 if(!pid)pid=Number(ps("(Get-Process -Name 'zenit-windows-storybook' | Sort-Object StartTime -Descending | Select-Object -First 1).Id"));
 return pid;
}
function cpuSnapshot():{total:number,threads:Map<number,number>,main:number}{
 const out=ps(`$p=Get-Process -Id ${appPid()}; "$($p.TotalProcessorTime.TotalSeconds)"; $p.Threads | Sort-Object StartTime | % { "$($_.Id) $($_.TotalProcessorTime.TotalMilliseconds)" }`);
 const lines=out.split(/\r?\n/).map(l=>l.trim()).filter(Boolean);
 const threads=new Map<number,number>(); let main=0;
 for(const l of lines.slice(1)){const [id,ms]=l.split(/\s+/).map(Number); if(!main)main=id; threads.set(id,ms);}
 return {total:Number(lines[0]),threads,main};
}
// The compositor's own CPU (DWM steps compositor sprites): its process times
// are not readable from a user session, its performance counter is. Sampled
// over the measurement window in the background; % of one core, like cpu_pct.
function dwmSampler(seconds:number){
 const child=spawn('powershell.exe',['-NoProfile','-NonInteractive','-Command',
  `(Get-Counter '\\Process(dwm)\\% Processor Time' -SampleInterval 1 -MaxSamples ${seconds}).CounterSamples | % { $_.CookedValue }`],{stdio:['ignore','pipe','ignore']});
 let out='';
 child.stdout.on('data',(d:Buffer)=>{out+=d.toString();});
 return ()=>new Promise<number>(resolve=>{
  const finish=()=>{const v=out.split(/\r?\n/).map(Number).filter(Number.isFinite); resolve(v.length?Math.round(10*v.reduce((a,b)=>a+b,0)/v.length)/10:NaN);};
  if(child.exitCode!==null)finish(); else child.on('exit',finish);
 });
}
function threadPct(a:ReturnType<typeof cpuSnapshot>,b:ReturnType<typeof cpuSnapshot>,elapsed:number){
 const r:[number,number][]=[];
 for(const [id,ms] of b.threads)r.push([id,(ms-(a.threads.get(id)??0))/10/elapsed]);
 r.sort((x,y)=>y[1]-x[1]);
 const main=r.find(x=>x[0]===b.main);
 return {main_thread_pct:Math.round((main?.[1]??0)*10)/10,top_threads:r.slice(0,6).map(([id,p])=>`${id===b.main?'main':id}:${Math.round(p*10)/10}`).join(' ')};
}
function stageMeans(t0:any,t1:any){
 if(!t1)return null;
 const frames=(t1.frames??0)-(t0?.frames??0); if(frames<=0)return null;
 const out:any={frames};
 for(const k of Object.keys(t1))if(k!=='frames')out[k]=Math.round(((t1[k]??0)-(t0?.[k]??0))/frames*10)/10;
 return out;
}
function gpuMiB():{dedicated:number,shared:number}{
 const out=ps(`$s=(Get-Counter -ErrorAction SilentlyContinue '\\GPU Process Memory(pid_${appPid()}_*)\\Dedicated Usage','\\GPU Process Memory(pid_${appPid()}_*)\\Shared Usage').CounterSamples; `+
  `$d=($s|?{$_.Path -like '*dedicated usage'}|Measure-Object CookedValue -Sum).Sum; $h=($s|?{$_.Path -like '*shared usage'}|Measure-Object CookedValue -Sum).Sum; "$d $h"`);
 const [d,h]=out.split(/\s+/).map(Number);
 return {dedicated:Math.round((d||0)/1048576*10)/10,shared:Math.round((h||0)/1048576*10)/10};
}
function privateMiB():number{return Math.round(Number(ps(`(Get-Process -Id ${appPid()}).PrivateMemorySize64`))/1048576*10)/10;}

async function navigate(name:string){
 await request('POST','/redraw',{continuous:false});
 await mouseMove(-10,-10);
 for(let i=0;i<3;i++)await key('escape');
 assert((await clickTestId('nav.'+name)).ok,'navigation failed '+name);
 await sleep(1500);
}

// Compositor sprites are off under the harness by default (drawable readback
// cannot see them). A build whose host presents them reports atlas_bytes.
async function spritesSupported():Promise<boolean>{
 const st=await request('POST','/sprites',{});
 return st!=null&&typeof st.atlas_bytes==='number';
}
async function sample(scene:string,phase:string,ms:number){
 // Real native input keeps the display awake; injected input does not reset the idle timer.
 await request('POST','/windows/native-input',{action:'key',vk:0x10,edge:'press'});
 await resetTiming();
 const s0=await stats(), c0=cpuSnapshot(), t0=performance.now();
 const dwm=dwmSampler(Math.max(1,Math.floor(ms/1000)-1));
 await sleep(ms);
 const c1=cpuSnapshot(), t1=performance.now(), s1=await stats();
 const dwm_pct=await dwm();
 const gpu=gpuMiB();
 const elapsed=(t1-t0)/1000;
 const row={scene,phase,cpu_pct:Math.round(1000*(c1.total-c0.total)/elapsed)/10,dwm_pct,...threadPct(c0,c1,elapsed),
  fps:Math.round(10*(s1.frame_count-s0.frame_count)/elapsed)/10,
  gpu_dedicated_mib:gpu.dedicated,gpu_shared_mib:gpu.shared,private_mib:privateMiB(),
  cpu_frame_us:s1.cpu_frame_us,cpu_p95_us:s1.cpu_p95_us,gpu_execute_us:s1.gpu_execute_us,
  total_frame_us:s1.total_frame_us,layout_us:s1.layout_us,render_gen_us:s1.render_gen_us,
  gpu_encode_us:s1.gpu_encode_us,renderer:s1.renderer_backend,scale:s1.window_scale,
  sprites:await request('POST','/sprites',{}),mean:stageMeans(s0.stage_totals,s1.stage_totals)};
 rows.push(row);save();console.log('PERF '+JSON.stringify(row));
 assert(Number.isFinite(row.cpu_pct),'cpu sample failed');
 return row;
}

test('memory probe',async()=>{
 await waitForServerReady(15000);
 await request('POST','/windows/native-input',{action:'activate'});
 const mem=async(tag:string)=>{const g=gpuMiB(); const st=await request('POST','/sprites',{}); const row={tag,gpu:g.shared,priv:privateMiB(),atlas:st.atlas_bytes,building:st.building,active:st.active}; rows.push(row); save(); console.log('PERF '+JSON.stringify(row));};
 await navigate('button');
 await mem('button-gpu');
 await request('POST','/sprites',{enabled:true});
 for(let i=0;i<6;i++){await sleep(1500); await mem('button-sprites-'+i);}
 await request('POST','/sprites',{enabled:false});
 await navigate('divider');
 for(let i=0;i<5;i++){await sleep(2000); await mem('divider-after-'+i);}
 await navigate('spinner');
 await request('POST','/sprites',{enabled:true});
 for(let i=0;i<4;i++){await sleep(1500); await mem('spinner-sprites-'+i);}
 await request('POST','/sprites',{enabled:false});
 await navigate('divider');
 for(let i=0;i<3;i++){await sleep(2000); await mem('divider-after2-'+i);}
});

run();

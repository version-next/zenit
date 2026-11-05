// Pixel-state driver. Keep production animation durations and capture every
// submitted frame. Fixed logical steps cover pixels independently of WARP speed;
// the realtime Storybook suite remains the latency check.
import {clickTestId,mouseMove,query,request,resizeWindow,screenPos,screenshot,stats,tree,waitFor,waitForServerReady} from './client';
import {test,run,assert,getSessionDir} from './runner';
import {writeFileSync} from 'node:fs';
test('Windows shared Notification drives compact submitted-frame fade audit',async()=>{
 await waitForServerReady(15000);
 assert((await request("POST","/clock",{step_ms:33})).ok,"deterministic clock unavailable");
 try {
 assert((await resizeWindow(650,480)).ok,'resize failed');
 await waitFor(async()=>{const t=await tree();return Math.abs(t.rect.w-650)<1&&Math.abs(t.rect.h-480)<1?t:null},10000,50);
 assert((await clickTestId('nav.notification')).ok,'notification navigation failed');
 await waitFor(async()=>(await query('story.notify.btn.warning'))[0]??null,10000,50);
 // Right-align the independently animated hover-status pill, away from the
 // left top-padding oracle. Bottom-center puts its shadow over those samples;
 // top-right puts the card over the page heading's textured backdrop instead.
 assert((await clickTestId('story.notify.pos.br')).ok,'bottom-right dock failed');
 await waitFor(async()=>(await query('story.notify.status'))[0]?.text==='bottom_right'?true:null,10000,50);
 // Resolve the trigger before the baseline: selecting the dock can scroll it
 // offscreen, and clickTestId would otherwise change the backdrop on entry.
 await screenPos('story.notify.btn.warning');
 await mouseMove(20,20);
 const dir=getSessionDir();
 assert((await screenshot(`${dir}/notification-fade-baseline.png`)).ok,'baseline capture failed');
 const opaque=(n:Awaited<ReturnType<typeof query>>[number]):boolean=>(n.opacity??1)>=.999&&(n.children??[]).every(c=>c.visible===false||opaque(c));
 for(let cycle=0;cycle<3;cycle++){
  assert((await clickTestId('story.notify.btn.warning')).ok,'warning click failed');
  const card=await waitFor(async()=>{const n=(await query('story.notify.warning'))[0];return n&&opaque(n)?n:null},15000,50);
  if(cycle===0){
   assert((await screenshot(`${dir}/notification-fade-settled.png`)).ok,'settled capture failed');
   writeFileSync(`${dir}/notification-fade-fixture.json`,JSON.stringify({card:card.rect,node:card,scale:(await stats()).window_scale}));
  }
  await mouseMove(card.rect.x+20,card.rect.y+20);
  await waitFor(async()=>{const n=(await query('story.notify.warning.close'))[0];return n&&n.visible!==false&&(n.opacity??1)>.9?n:null},10000,50);
  assert((await clickTestId('story.notify.warning.close')).ok,'close click failed');
  assert((await mouseMove(20,20)).ok,'close pointer relocation failed');
  await waitFor(async()=>{const n=(await query('story.notify.warning'))[0];return !n||n.rect.w===0||n.rect.h===0?true:null},15000,50);
 }
 assert((await screenshot(`${dir}/notification-fade-closed.png`)).ok,'closed capture failed');
 } finally {
  assert((await request("POST","/clock",{step_ms:0})).ok,"realtime clock restore failed");
 }
});
run();

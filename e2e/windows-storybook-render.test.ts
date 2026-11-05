import { clickTestId, mouseMove, query, screenshot, sleep, tree, waitFor, waitForServerReady, stats, startFrameObservation, readFrameObservation } from "./client";
import { writeFileSync } from "node:fs";
import { decodePng } from "./png";
import { checkboxInk } from "./checkbox-pixels";
import { assert, getSessionDir, run, test } from "./runner";

test("Windows Notification portal keeps title and body inside the placed card", async () => {
  await waitForServerReady(15000);
  assert((await clickTestId("nav.notification")).ok, "notification navigation failed");
  await waitFor(async () => (await query("story.notify.pos.tr"))[0] ?? null, 5000, 50);
  assert((await clickTestId("story.notify.pos.tr")).ok, "position action failed");
  await waitFor(async () => (await query("story.notify.status"))[0]?.text === "top_right" ? true : null, 3000, 50);
  // The source origin is not empty: the window header draws its title there.
  // Measure leaked ink against this pre-notification frame.
  const baselinePath = `${getSessionDir()}/windows-notification-portal-baseline.png`;
  assert((await screenshot(baselinePath)).ok, "baseline screenshot failed");
  const baseline = decodePng(baselinePath);
  assert((await clickTestId("story.notify.btn.warning")).ok, "warning action failed");
  // This checks settled placement/ink, not animation latency. WARP can take
  // longer than 800 ms to submit the nested title/body entrance layers.
  const started = Date.now();
  const fullyOpaque = (node: Awaited<ReturnType<typeof query>>[number]): boolean =>
    (node.opacity ?? 1) >= .999 && (node.children ?? []).every(child =>
      child.visible === false || fullyOpaque(child));
  const settledCard = await waitFor(async () => {
    const card = (await query("story.notify.warning"))[0];
    return card && fullyOpaque(card) ? card : null;
  }, 10000, 50);
  // Screenshot transfer can exceed the notification lifetime over WAN. Use
  // its real hover-pause behavior before readback and follow-up geometry RPCs.
  await mouseMove(settledCard.rect.x + settledCard.rect.w - 15, settledCard.rect.y + settledCard.rect.h - 15);
  console.log(`  notification settled after ${Date.now() - started}ms (not a performance assertion)`);
  const path = `${getSessionDir()}/windows-notification-portal.png`;
  assert((await screenshot(path)).ok, "notification screenshot failed");
  const png = decodePng(path);
  const root = await tree();
  const scale = png.width / root.rect.w;
  const card = (await query("story.notify.warning"))[0]?.rect;
  assert(card && Math.abs(card.x + card.w - (root.rect.w - 22)) < 2 && Math.abs(card.y - 78) < 2, "card is not top-right");
  assert(baseline.width === png.width && baseline.height === png.height, "baseline size changed");
  const ink = (x: number, y: number, w: number, h: number, image = png) => {
    let coverage = 0;
    for (let py = Math.ceil(y * scale); py < Math.floor((y + h) * scale); py++) {
      for (let px = Math.ceil(x * scale); px < Math.floor((x + w) * scale); px++) {
        assert(px >= 0 && py >= 0 && px < image.width && py < image.height, "notification sample outside screenshot");
        const i = (py * image.width + px) * image.channels;
        const gray = (image.pixels[i] + image.pixels[i+1] + image.pixels[i+2]) / 3;
        // Integrate antialiased glyph coverage in logical pixels. Counting only
        // samples darker than 120 discards thin 1x glyphs that are visible, but
        // succeeds at 1.75x merely because it has more physical samples.
        // Ignore the light glass/background entirely; 70 is the body ink tone.
        coverage += Math.max(0, Math.min(1, (200 - gray) / 130));
      }
    }
    return coverage / (scale * scale);
  };
  const title = ink(card.x + 50, card.y + 10, 160, 22);
  const body = ink(card.x + 50, card.y + 34, 250, 19);
  const leaked = ink(58, 10, 160, 22) - ink(58, 10, 160, 22, baseline);
  console.log(`  notification title=${title}, body=${body}, source-origin=${leaked}, ${path}`);
  assert(title > 70 && body > 70, "placed notification has no title/body ink");
  assert(leaked < 20, "notification content leaked to source origin");
});

test("Windows Notification glass fade captures entry and exit for frame audit", async () => {
  await waitForServerReady(15000);
  assert((await clickTestId("nav.notification")).ok,"notification navigation failed");
  await waitFor(async()=>(await query("story.notify.pos.tr"))[0]??null,5000,50);
  await clickTestId("story.notify.btn.clear");
  await sleep(600);
  await clickTestId("story.notify.pos.tr");
  const directory=getSessionDir();
  assert((await screenshot(`${directory}/notification-fade-baseline.png`)).ok,"notification baseline failed");
  for(let cycle=0;cycle<3;cycle++) {
  await clickTestId("story.notify.btn.warning");
  await sleep(800);
  const card=(await query("story.notify.warning"))[0]?.rect;
  assert(card,"settled notification missing");
  // Hold the actual notification before potentially slow WAN screenshot upload.
  await mouseMove(card.x+20,card.y+20);
  if(cycle===0) assert((await screenshot(`${directory}/notification-fade-settled.png`)).ok,"notification settled failed");
  if(cycle===0) writeFileSync(`${directory}/notification-fade-fixture.json`,JSON.stringify({card,node:(await query("story.notify.warning"))[0],scale:(await stats()).window_scale}));
  await mouseMove(card.x+20,card.y+20);
  await sleep(350);
  // The close control is hover-revealed. A coordinate click while it is still
  // hidden hits the card instead; this fade audit must first reach its trigger.
  await waitFor(async()=>{
    const close=(await query("story.notify.warning.close"))[0];
    return close && close.visible!==false && (close.opacity??1)>.9 ? close : null;
  },5000,50);
  assert((await clickTestId("story.notify.warning.close")).ok,"notification close failed");
  await mouseMove(-10,-10);
  await sleep(800);
  const after=(await query("story.notify.warning"))[0];
  const exited=!after || after.rect.w===0 || after.rect.h===0;
  if(!exited) {
    const base=`${directory}/notification-exit-failure-${cycle}`;
    writeFileSync(`${base}.json`,JSON.stringify({cycle,after,
      close:await query("story.notify.warning.close"),stats:await stats(),tree:await tree()},null,2));
    assert((await screenshot(`${base}.png`)).ok,"notification failure screenshot unavailable");
    console.log(`  notification exit failure: ${base}.json, ${base}.png`);
  }
  assert(exited,"notification did not exit");
  }
  assert((await screenshot(`${directory}/notification-fade-closed.png`)).ok,"notification closed failed");
});

test("Windows Checkbox check and indeterminate icons produce pixels", async () => {
  await waitForServerReady(15000);
  await clickTestId("nav.checkbox");
  await waitFor(async () => (await query("story.checkbox.checked"))[0] ?? null, 5000, 50);
  await sleep(200);
  const path = `${getSessionDir()}/windows-checkbox-icons.png`;
  assert((await screenshot(path)).ok, "screenshot failed");
  const png = decodePng(path);
  const root = await tree();
  const scale = png.width / root.rect.w;
  for (const id of ["story.checkbox.checked", "story.checkbox.indeterminate"]) {
    const row = (await query(id))[0];
    // The first child is the square, excluding label text and the virtual
    // pointer over the navigation item. Its center contains only icon ink.
    const box = row.children?.[0];
    assert(box && box.rect.w > 0 && box.rect.h > 0, `missing checkbox square: ${id}`);
    // Ink is anything clearly brighter than the actual accent fill: at 100% DPI the
    // antialiased 2px minus dash lands between pixel rows at ~50% coverage, so a "white"
    // threshold would count zero pixels for a visibly drawn mark. Minimum counts are per
    // logical area (calibrated on 1.75x captures: 10 light / 30 dark).
    const minLight = Math.ceil(3.3 * scale * scale), minFill = Math.ceil(10 * scale * scale);
    const x0 = Math.ceil((box.rect.x + 2) * scale);
    const y0 = Math.ceil((box.rect.y + 2) * scale);
    const x1 = Math.floor((box.rect.x + box.rect.w - 2) * scale);
    const y1 = Math.floor((box.rect.y + box.rect.h - 2) * scale);
    assert(x0 >= 0 && y0 >= 0 && x1 <= png.width && y1 <= png.height, "checkbox outside drawable");
    const { ink, background, fill } = checkboxInk(png, { x0, y0, x1, y1 });
    console.log(`  ${id}: ink=${ink} (min ${minLight}), fill=${background} (min ${minFill}), color=${fill}, ${path}`);
    assert(ink >= minLight && background >= minFill, `${id} has no visible light icon on its accent square`);
  }
});

test("Windows Modal settled content and closed background preserve pixels", async () => {
  await waitForServerReady(15000);
  await clickTestId("nav.modal");
  await waitFor(async () => (await query("story.modal.open"))[0] ?? null, 5000, 50);
  await sleep(300);
  const basePath = `${getSessionDir()}/windows-modal-baseline.png`;
  assert((await screenshot(basePath)).ok, "baseline screenshot failed");
  const baseline = decodePng(basePath);
  const scale = baseline.width / (await tree()).rect.w;
  let bounds: {x: number; y: number; w: number; h: number};
  const mean = (png: ReturnType<typeof decodePng>, x: number, y: number, w: number, h: number) => {
    let sum = 0, count = 0;
    for (let py = Math.ceil(y * scale); py < Math.floor((y + h) * scale); py++) {
      for (let px = Math.ceil(x * scale); px < Math.floor((x + w) * scale); px++) {
        const i = (py * png.width + px) * png.channels;
        sum += (png.pixels[i] + png.pixels[i + 1] + png.pixels[i + 2]) / 3;
        count++;
      }
    }
    return sum / count;
  };
  for (let cycle = 0; cycle < 3; cycle++) {
    const check = async (stage: string, dialogVisible: boolean) => {
      const path = `${getSessionDir()}/windows-modal-${cycle}-${stage}.png`;
      assert((await screenshot(path)).ok, "screenshot failed");
      const png = decodePng(path);
      const backdrop = mean(png, 950, 750, 30, 30);
      console.log(`  ${cycle} ${stage}: backdrop=${backdrop}, ${path}`);
      assert(backdrop > 90, `${stage} backdrop turned black`);
      if (dialogVisible) {
        // Bottom-right body area: the old layer bounds cut this whole area
        // away during transitions, leaving only a narrow header strip.
        const body = mean(png, bounds!.x + bounds!.w - 120, bounds!.y + bounds!.h - 30, 30, 10);
        assert(body - backdrop > 2, `${stage} dialog body is clipped or absent (body=${body}, backdrop=${backdrop})`);
      } else {
        let changed = 0;
        for (let y = Math.max(0, Math.ceil((bounds!.y - 64) * scale)); y < Math.min(png.height, Math.floor((bounds!.y + bounds!.h + 64) * scale)); y++) {
          for (let x = Math.max(0, Math.ceil((bounds!.x - 64) * scale)); x < Math.min(png.width, Math.floor((bounds!.x + bounds!.w + 64) * scale)); x++) {
            const i = (y * png.width + x) * png.channels;
            const j = (y * baseline.width + x) * baseline.channels;
            if ([0, 1, 2].some(c => Math.abs(png.pixels[i+c] - baseline.pixels[j+c]) > 3)) changed++;
          }
        }
        assert(changed <= 10, `closed dialog leaves ${changed} stale pixels`);
      }
    };
    assert((await clickTestId("story.modal.open")).ok, "modal open command failed");
    // Stable endpoint checks live here. Intermediate pixels are mandatory in
    // windows_shared_regression.py's native submitted-frame archive phase;
    // a screenshot RPC after close can legitimately arrive after the fade.
    const settled = await waitFor(async () => {
      const dialog = (await query("story.modal.dialog"))[0];
      return dialog && (dialog.effective_opacity ?? 0) >= .999 ? dialog : null;
    }, 10000, 50);
    bounds = settled.rect;
    await check("settled", true);
    assert((await clickTestId("modal.close")).ok, "modal close command failed");
    await waitFor(async () => {
      const dialog = (await query("story.modal.dialog"))[0];
      return dialog && dialog.effective_opacity === 0 ? dialog : null;
    }, 10000, 50);
    assert((await mouseMove((await tree()).rect.w-20, (await tree()).rect.h-20)).ok, "pointer relocation failed");
    await check("closed", false);
  }
});

test("Windows Modal animations progress without screenshot RPC", async () => {
  await waitForServerReady(15000);
  await clickTestId("nav.modal");
  await waitFor(async () => (await query("story.modal.open"))[0] ?? null, 5000, 50);
  // Keep the RPC transport silent throughout each transition. Screenshot GPU
  // readback otherwise contaminates measured native presentation intervals.
  for (let cycle = 0; cycle < 6; cycle++) {
    assert((await startFrameObservation("story.modal.dialog")).supported, "frame observation unavailable");
    assert((await clickTestId("story.modal.open")).ok, "modal open failed");
    await sleep(400);
    const dialog = (await query("story.modal.dialog"))[0];
    assert(dialog && dialog.visible !== false, "modal did not enter");
    assert((await clickTestId("modal.close")).ok, "modal close failed");
    await sleep(400);
    const closed = (await query("story.modal.dialog"))[0];
    const observation = await readFrameObservation();
    writeFileSync(`${getSessionDir()}/windows-modal-silent-${cycle}-frames.json`, JSON.stringify({cycle, entered:dialog, closed, observation}, null, 2));
    if (closed?.visible !== false) {
      const base = `${getSessionDir()}/windows-modal-silent-${cycle}-failure`;
      writeFileSync(`${base}.json`, JSON.stringify({cycle, entered:dialog, closed, observation, stats:await stats(), tree:await tree()}, null, 2));
      await screenshot(`${base}.png`);
    }
    assert(closed?.visible === false, "modal did not exit");
  }
});

// Keep the failed stage and actual pixels: a bare timeout cannot distinguish a
// missed animation window, a blocked reopen, or a close that never completed.
async function waitModalStage<T>(stage: string, predicate: () => Promise<T | null>, interval: number): Promise<T> {
  try {
    return await waitFor(predicate, 5000, interval);
  } catch (error) {
    const base = `${getSessionDir()}/windows-modal-failure-${stage}`;
    try {
      const observation = await readFrameObservation();
      const state = { stage, observation, dialog: await query("story.modal.dialog"), open: await query("story.modal.open"),
        close: await query("modal.close"), stats: await stats(), tree: await tree() };
      writeFileSync(`${base}.json`, JSON.stringify(state, null, 2));
      assert((await screenshot(`${base}.png`)).ok, "failure screenshot unavailable");
      console.log(`  Modal failure evidence: ${base}.json, ${base}.png`);
    } catch (captureError) {
      console.log(`  Modal failure capture: ${captureError}`);
    }
    throw new Error(`${stage}: ${error}`);
  }
}

test("Windows Modal interrupted transitions clear the panel and shadow", async () => {
  await waitForServerReady(15000);
  assert((await clickTestId("nav.modal")).ok, "modal navigation failed");
  await waitFor(async () => (await query("story.modal.open"))[0] ?? null, 5000, 50);
  // Measure the dialog from a settled open: the hidden dialog's placeholder rect
  // (offscreen, at the window origin) says nothing about where the panel and its
  // shadow are painted, and story layout changes would silently move the audited
  // region onto unrelated content such as the trigger button.
  assert((await clickTestId("story.modal.open")).ok, "initial modal open failed");
  const settledDialog = await waitFor(async () => {
    const d = (await query("story.modal.dialog"))[0];
    return d && d.visible !== false && (d.opacity ?? 1) > .999 ? d : null;
  }, 10000, 50);
  const dialogBounds = settledDialog.rect;
  assert(dialogBounds && dialogBounds.w > 0 && dialogBounds.h > 0, "missing Modal geometry");
  assert((await clickTestId("modal.close")).ok, "initial modal close failed");
  await waitFor(async () => (await query("story.modal.dialog"))[0]?.visible === false ? true : null, 10000, 50);
  // Park the virtual pointer where every cycle parks it, so the cursor glyph
  // never counts as a difference inside the audited region.
  assert((await mouseMove((await tree()).rect.w-20, (await tree()).rect.h-20)).ok, "pointer relocation failed");
  await sleep(300);
  const basePath = `${getSessionDir()}/windows-modal-interrupted-baseline.png`;
  assert((await screenshot(basePath)).ok, "baseline screenshot failed");
  const baseline = decodePng(basePath);
  const scale = baseline.width / (await tree()).rect.w;
  for (let cycle = 0; cycle < 3; cycle++) {
    assert((await startFrameObservation("story.modal.dialog", "escape_on_enter")).supported, "submitted frame observation unavailable");
    assert((await clickTestId("story.modal.open")).ok, "modal open failed");
    // Escape is dispatched locally after the first submitted entering frame.
    // A LAN round trip cannot reliably catch this short state on a slow adapter.
    await waitModalStage(`${cycle}-exit`, async () => (await query("story.modal.dialog"))[0]?.visible === false ? true : null, 20);
    assert((await mouseMove((await tree()).rect.w-20, (await tree()).rect.h-20)).ok, "pointer relocation failed");
    const path = `${getSessionDir()}/windows-modal-interrupted-${cycle}-closed.png`;
    assert((await screenshot(path)).ok, "closed screenshot failed");
    const png = decodePng(path);
    assert(png.width === baseline.width && png.height === baseline.height, "drawable size changed");
    let changed = 0;
    for (let y = Math.max(0, Math.ceil((dialogBounds!.y - 64) * scale)); y < Math.min(png.height, Math.floor((dialogBounds!.y + dialogBounds!.h + 64) * scale)); y++) {
      for (let x = Math.max(0, Math.ceil((dialogBounds!.x - 64) * scale)); x < Math.min(png.width, Math.floor((dialogBounds!.x + dialogBounds!.w + 64) * scale)); x++) {
        const i = (y * png.width + x) * png.channels;
        const j = (y * baseline.width + x) * baseline.channels;
        if ([0, 1, 2].some(c => Math.abs(png.pixels[i+c] - baseline.pixels[j+c]) > 3)) changed++;
      }
    }
    assert(changed <= 10, `interrupted cycle ${cycle} left ${changed} stale pixels`);
    // Include a fully painted reference for the native frame audit and prove
    // that interrupted dismissal did not leave the next opening broken.
    assert((await clickTestId("story.modal.open")).ok, "reopen after interruption failed");
    await waitModalStage(`${cycle}-reopen-settled`, async () => {
      const settled = (await query("story.modal.dialog"))[0];
      return settled && settled.visible !== false && (settled.opacity ?? 1) > .999 ? settled : null;
    }, 20);
    assert((await clickTestId("modal.close")).ok, "final close failed");
    await waitModalStage(`${cycle}-final-close`, async () => (await query("story.modal.dialog"))[0]?.visible === false ? true : null, 20);
    const observation = await readFrameObservation();
    writeFileSync(`${getSessionDir()}/windows-modal-interrupted-${cycle}-frames.json`, JSON.stringify(observation, null, 2));
    assert(!observation.overflow && observation.missing === 0, "incomplete submitted frame observation");
    const actionIndex = observation.action_frame_index;
    assert(typeof actionIndex === "number" && Number.isInteger(actionIndex) &&
      actionIndex >= 0 && actionIndex < observation.frames.length,
      "Escape did not fire on a submitted entering frame");
    const trigger = observation.frames[actionIndex!];
    assert(trigger.effective_opacity! > 0 && trigger.effective_opacity! < .999,
      "Escape fired outside the entering transition");
    const closedIndex = observation.frames.findIndex((frame, index) =>
      index > actionIndex! && frame.effective_opacity === 0);
    assert(closedIndex > actionIndex!, "interrupted entrance never submitted a closed frame");
    assert(observation.frames.slice(actionIndex! + 1, closedIndex).every(frame =>
      frame.effective_opacity! <= trigger.effective_opacity! + .001),
      "interrupted entrance continued becoming more opaque");
    assert(observation.frames.length > 0 && observation.frames.every(frame =>
      typeof frame.opacity === "number" && Number.isFinite(frame.opacity) && frame.opacity >= 0 && frame.opacity <= 1 &&
      typeof frame.effective_opacity === "number" && Number.isFinite(frame.effective_opacity) && frame.effective_opacity >= 0 && frame.effective_opacity <= 1),
      "submitted frames lack valid opacity values");
    assert(observation.frames.some(frame => frame.effective_opacity! > 0 && frame.effective_opacity! < .999),
      "submitted frames did not contain a visible transition");
    assert(observation.frames.at(-1)!.effective_opacity === 0, "last submitted frame retained visible modal content");
  }
});

run();

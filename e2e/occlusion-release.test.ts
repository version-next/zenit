// Background RPC regression: an occluded window stops rendering and releases
// frame-loop GPU resources; revealing it repaints the identical frame.
// `/window occlude|reveal` forces the macOS occlusion path without covering
// the real window (native occlusion is ignored under ZENIT_E2E_BACKGROUND).
import { test, run, assert, appendLog, getSessionDir } from "./runner";
import { waitForServerReady, clickTestId, mouseMove, request, screenshot, stats, sleep } from "./client";
import { readFileSync } from "node:fs";

const dir = getSessionDir();
const frames = async () => Number((await stats()).frame_count ?? 0);
const windowAction = (action: string) => request("POST", "/window", { action }) as Promise<{ ok?: boolean; suspended?: boolean }>;

test("occluded window skips frames, trims resources and repaints identically when revealed", async () => {
  await waitForServerReady();
  for (const story of ["glasslab", "card"]) {
    await clickTestId(`nav.${story}`);
    // Park the synthetic pointer and let press/hover transitions settle so the
    // comparison isolates the occlusion round trip.
    await mouseMove(-10, -10);
    await request("POST", "/wait", { frames: 30 });
    await sleep(800);
    await request("POST", "/wait", { frames: 5 });
    assert((await screenshot(`${dir}/${story}-visible.png`)).ok, "visible capture");
    const occluded = await windowAction("occlude");
    assert(occluded.ok === true && occluded.suspended === true, `${story}: occlude accepted ${JSON.stringify(occluded)}`);
    await sleep(300);
    const start = await frames();
    // Longer than the 1 s idle trim delay: the trim is due immediately anyway.
    await sleep(1200);
    const end = await frames();
    appendLog(`${story}: frames while occluded ${start} -> ${end}`);
    assert(end === start, `${story}: occluded window kept rendering (${start} -> ${end})`);
    const revealed = await windowAction("reveal");
    assert(revealed.ok === true && revealed.suspended === false, `${story}: reveal accepted`);
    await request("POST", "/wait", { frames: 3 });
    assert((await screenshot(`${dir}/${story}-revealed.png`)).ok, "revealed capture");
    const same = Buffer.compare(readFileSync(`${dir}/${story}-visible.png`), readFileSync(`${dir}/${story}-revealed.png`)) === 0;
    assert(same, `${story}: first frames after reveal differ from the pre-occlusion frame`);
  }
});

test("an animating story pauses while occluded and resumes when revealed", async () => {
  await clickTestId("nav.spinner");
  await request("POST", "/wait", { frames: 10 });
  await windowAction("occlude");
  await sleep(200);
  const start = await frames();
  await sleep(600);
  const paused = await frames();
  await windowAction("reveal");
  await request("POST", "/wait", { frames: 10 });
  const resumed = await frames();
  appendLog(`spinner: occluded ${start} -> ${paused}, revealed -> ${resumed}`);
  assert(paused === start, `spinner rendered while occluded (${start} -> ${paused})`);
  assert(resumed > paused, "spinner did not resume after reveal");
});

await run();

// Background RPC regression for resize presentation: every programmatic
// resize step must present a frame whose drawable matches the new geometry,
// with no stale-size discard loop and no lost frames. No native pointer input;
// AppKit live resize itself (drag) is verified manually.
import { test, run, assert, appendLog, getSessionDir } from "./runner";
import { waitForServerReady, request, screenshot, stats, resizeWindow } from "./client";
import { readFileSync } from "fs";

const dir = getSessionDir();

function pngSize(path: string): [number, number] {
  const bytes = readFileSync(path);
  return [bytes.readUInt32BE(16), bytes.readUInt32BE(20)];
}

test("programmatic resize presents matching drawables without stale discards", async () => {
  await waitForServerReady();
  await resizeWindow(980, 600);
  await request("POST", "/wait", { frames: 8 });
  const before = await stats();
  const discardsBefore = Number(before.stale_drawable_discards ?? -1);
  assert(discardsBefore >= 0, "stats must publish stale_drawable_discards");
  const sizes: Array<[number, number]> = [[1200, 780], [760, 480], [1400, 900], [980, 600], [1001, 633]];
  let scale = 0;
  for (const [w, h] of sizes) {
    assert((await resizeWindow(w, h)).ok, `resize ${w}x${h}`);
    await request("POST", "/wait", { frames: 2 });
    const path = `${dir}/resize-${w}x${h}.png`;
    assert((await screenshot(path)).ok, `capture ${w}x${h}`);
    const [pw, ph] = pngSize(path);
    if (scale === 0) scale = pw / w;
    appendLog(`resize ${w}x${h} -> drawable ${pw}x${ph}`);
    assert(Number.isInteger(scale) && scale >= 1, `backing scale ${scale}`);
    assert(pw === w * scale && ph === h * scale, `drawable ${pw}x${ph} != ${w}x${h} @${scale}x`);
  }
  // Rapid steps without waiting: the main loop may see several sizes per frame.
  for (let i = 0; i < 12; i++) await resizeWindow(i % 2 ? 900 : 1300, i % 2 ? 560 : 820);
  await resizeWindow(980, 600);
  await request("POST", "/wait", { frames: 8 });
  const after = await stats();
  const discards = Number(after.stale_drawable_discards) - discardsBefore;
  appendLog(`stale discards during resize sequence: ${discards}; frames ${before.frame_count} -> ${after.frame_count}`);
  // Main-loop resizes reconfigure before layout, so no frame should be stale.
  assert(discards === 0, `unexpected stale discards: ${discards}`);
  assert(Number(after.frame_count) > Number(before.frame_count), "frames kept presenting");
  const final = `${dir}/resize-final.png`;
  assert((await screenshot(final)).ok, "final capture");
  const [fw, fh] = pngSize(final);
  assert(fw === 980 * scale && fh === 600 * scale, `final drawable ${fw}x${fh}`);
});

await run();

import { request, query, tree, screenshot, stats, waitFor, waitForServerReady } from "./client";
import { decodePng, countDarkPixels } from "./png";
import { assert, appendLog, getSessionDir, run, test } from "./runner";
test("glyph gutter: undefined page contents cannot bleed into transformed text", async () => {
  await waitForServerReady();
  const poison = await request("POST", "/review/glyph-gutter-poison", {});
  assert(poison.ok, `poison setup failed: ${JSON.stringify(poison)}`);
  await waitFor(async () => (await stats()).frame_count > poison.frame_count ? true : null);
  const beforePath = `${getSessionDir()}/poisoned.png`;
  assert((await screenshot(beforePath)).ok, "poisoned capture failed");
  const rect = (await query("review.glyph-gutter.stage"))[0].rect;
  const scale = decodePng(beforePath).width / (await tree()).rect.w;
  const result = await request("POST", "/review/glyph-gutter-clear", {});
  assert(result.ok && result.cleared_regions > 0, `oracle did not clear glyph rings: ${JSON.stringify(result)}`);
  await waitFor(async () => (await stats()).frame_count > result.frame_count ? true : null);
  const afterPath = `${getSessionDir()}/cleared.png`;
  assert((await screenshot(afterPath)).ok, "oracle capture failed");
  const before = decodePng(beforePath), after = decodePng(afterPath);
  assert(countDarkPixels(after, rect, scale) > 100, "text oracle was blank");
  let changed = 0;
  for (let y = Math.ceil(rect.y * scale); y < Math.floor((rect.y + rect.h) * scale); y++) {
    for (let x = Math.ceil(rect.x * scale); x < Math.floor((rect.x + rect.w) * scale); x++) {
      const i = (y * before.width + x) * before.channels;
      if ([0, 1, 2].some(c => before.pixels[i + c] !== after.pixels[i + c])) changed++;
    }
  }
  appendLog(`gutter: ${JSON.stringify({ changed_pixels: changed, cleared_regions: result.cleared_regions })}`);
  assert(changed === 0, `${changed} pixels depended on uninitialized atlas gutter`);
});
run();

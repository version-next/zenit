// The adaptive window example on a real Windows desktop: gallery geometry for
// every preset, preview actions never touching the real window, real caption
// actions, F11 fullscreen with the Windows reveal policy, the Alt menu bar and one
// real "Try" window opened from a Windows preset. Mirrors
// scripts/run_window_example_acceptance.py for the worker's bundled-suite stage.
import { clickTestId, query, request, resizeWindow, screenshot, sleep, waitForServerReady } from "./client";
import { assert, getSessionDir, run, test } from "./runner";

type Node = { tag?: string; test_id?: string; rect: { x: number; y: number; w: number; h: number }; children?: Node[] };
const state = () => request("POST", "/window-state", {});
const visible = async (id: string) => (await query(id)).filter((n: Node) => n.rect.w > 0 && n.rect.h > 0);
function* descendants(node: Node): Generator<Node> { yield node; for (const c of node.children ?? []) yield* descendants(c); }
async function waitState(field: string, value: unknown, timeoutMs = 12000) {
  const deadline = Date.now() + timeoutMs;
  let s = await state();
  while (s[field] !== value && Date.now() < deadline) { await sleep(50); s = await state(); }
  return s;
}
const presets = ["macos", "windows", "windows-max", "gnome", "ubuntu", "kde", "left", "fallback", "narrow720", "narrow640", "narrow520"];

test("gallery presets keep m97vV geometry at 1500x1040", async () => {
  await waitForServerReady(15000);
  await resizeWindow(1500, 1040);
  await sleep(300);
  for (const name of presets) {
    const header = (await visible(`preview.${name}.header`))[0];
    assert(!!header && Math.abs(header.rect.h - 38) < 0.01, `${name}: header height ${header?.rect.h}`);
    const drags = await query(`preview.${name}.drag`);
    assert(drags.length === 1, `${name}: expected one drag region, got ${drags.length}`);
    const drag = drags[0];
    assert(drag.rect.w >= 159.99 && Math.abs(drag.rect.h - header.rect.h) < 0.01 &&
      Math.abs(drag.rect.y - header.rect.y) < 0.01, `${name}: drag region must fill header height: ${JSON.stringify(drag.rect)}`);
    if (["windows", "windows-max", "ubuntu", "gnome", "kde"].includes(name)) {
      const button = (await visible(`preview.${name}.close`))[0];
      const expected = name.startsWith("windows") ? 0 : name === "kde" ? 10 : 8;
      const r = header.rect, br = button.rect;
      assert(Math.abs(r.x + r.w - br.x - br.w - expected) < 0.02, `${name}: close inset ${r.x + r.w - br.x - br.w}`);
      const glyph = [...descendants(button)].find((n) => n.tag === "image")!.rect;
      assert(Math.abs(glyph.x + glyph.w / 2 - br.x - br.w / 2) < 0.02 && Math.abs(glyph.y + glyph.h / 2 - br.y - br.h / 2) < 0.02, `${name}: glyph off-center`);
    }
    assert((await visible(`preview.${name}.try`)).length === 1, `${name}: Try button missing`);
  }
  assert((await screenshot(`${getSessionDir()}/adaptive-gallery.png`)).ok, "gallery screenshot failed");
});

test("preview caption actions never touch the real window", async () => {
  const before = await state();
  await clickTestId("preview.windows.maximize");
  await sleep(200);
  const after = await state();
  assert(before.maximized === after.maximized, `preview maximize changed the real window: ${JSON.stringify(after)}`);
});

test("real caption maximize and restore", async () => {
  await clickTestId("window.maximize");
  let s = await waitState("maximized", true);
  assert(s.maximized, `native maximize: ${JSON.stringify(s)}`);
  await clickTestId("window.maximize");
  s = await waitState("maximized", false);
  assert(!s.maximized, `native restore: ${JSON.stringify(s)}`);
});

test("F11 fullscreen reveals the Header at the top edge and restores", async () => {
  await request("POST", "/key_down", { key: "f11" });
  let s = await waitState("fullscreen", true);
  s = await waitState("fullscreen_transitioning", false);
  assert(s.fullscreen && !s.fullscreen_transitioning, `F11 fullscreen: ${JSON.stringify(s)}`);
  await request("POST", "/mouse_move", { x: 400, y: 1 });
  await sleep(450);
  s = await state();
  assert(s.revealed, `Windows fullscreen must reveal the Header at the edge: ${JSON.stringify(s)}`);
  await request("POST", "/key_down", { key: "f11" });
  s = await waitState("fullscreen", false);
  s = await waitState("fullscreen_transitioning", false);
  assert(!s.fullscreen && !s.fullscreen_transitioning && (await visible("window.header")).length === 1, `F11 restore: ${JSON.stringify(s)}`);
});

test("Alt toggles the temporary menu bar and Escape dismisses it", async () => {
  await request("POST", "/key_down", { key: "Alt" });
  await request("POST", "/key_up", { key: "Alt" });
  assert((await state()).menu, "Alt release did not show the menu bar");
  await request("POST", "/key_down", { key: "escape" });
  assert(!(await state()).menu, "Escape did not dismiss the menu bar");
});

test("Try opens one real window for a Windows preset and nothing for a macOS preset", async () => {
  const before = (await state()).windows;
  await clickTestId("preview.macos.try");
  await sleep(600);
  assert((await state()).windows === before, "a disabled Try opened a window");
  await clickTestId("preview.windows.try");
  const deadline = Date.now() + 8000;
  while ((await state()).windows < before + 1 && Date.now() < deadline) await sleep(100);
  const s = await state();
  assert(s.windows === before + 1, `Try did not open a real window: ${JSON.stringify(s)}`);
  await sleep(500);
  assert((await screenshot(`${getSessionDir()}/adaptive-try-window.png`)).ok, "Try window screenshot failed");
});

await run();

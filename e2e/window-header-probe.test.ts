// Storybook window header probe (not a CI gate): ZENIT_E2E_TEST_FILE=e2e/window-header-probe.test.ts.
// Captures the header at rest, fullscreen (F11) and after restore, and logs the header
// geometry and chrome-relevant nodes so each desktop's layout can be checked by eye.
import { clickTestId, key, query, request, scrollAt, sleep, tree, waitForServerReady } from "./client";
import { decodePng } from "./png";
import { appendLog, assert, getSessionDir, run, test } from "./runner";

/// Windows, with desktop capture allowed (--allow-foreground): the composed desktop must show
/// the application-drawn caption buttons, not a cut-out (the black slot DWM leaves when the
/// surface clips its native caption area without DWM painting buttons there).
async function checkCaptionComposited(stage: string) {
  if (process.platform !== "win32") return;
  const ids = ["window.controls.minimize", "window.controls.maximize", "window.controls.close"];
  const rects = (await Promise.all(ids.map(visibleRect))).filter((r) => r);
  if (rects.length === 0) return;
  const dir = getSessionDir();
  const target = `${dir}/caption-${stage}-target.png`, desktop = `${dir}/caption-${stage}-desktop.png`;
  await request("POST", "/screenshot", { path: target });
  const capture = await request("POST", "/windows/native-desktop", { path: desktop }).catch(() => null);
  if (!capture?.ok) { appendLog(`  ${stage}: desktop capture unavailable (needs --allow-foreground)`); return; }
  const a = decodePng(desktop), b = decodePng(target), scale = b.width / (await tree()).rect.w;
  let black = 0, total = 0;
  for (const r of rects) for (let y = Math.ceil(r.y * scale); y < Math.floor((r.y + r.h) * scale); y += 2)
    for (let x = Math.ceil(r.x * scale); x < Math.floor((r.x + r.w) * scale); x += 2) {
      const pa = ((y + capture.client_y) * a.width + x + capture.client_x) * a.channels, pb = (y * b.width + x) * b.channels;
      const dark = [0, 1, 2].every((c) => a.pixels[pa + c] < 16), app = [0, 1, 2].some((c) => b.pixels[pb + c] > 48);
      if (dark && app) black++;
      total++;
    }
  const line = `  ${stage}: caption black pixels ${black}/${total}`;
  appendLog(line); console.log(line);
  assert(black <= total * 0.02, `${stage}: caption buttons cut out to black on the desktop (${black}/${total})`);
}

/// First laid-out match: the left and right caption groups share test ids; one is hidden.
async function visibleRect(id: string) {
  return (await query(id).catch(() => [])).map((n: any) => n.rect).find((r: any) => r && r.w > 0 && r.h > 0);
}

async function snap(name: string) {
  const dir = getSessionDir();
  await request("POST", "/screenshot", { path: `${dir}/header-${name}.png` });
  const r = (await tree()).rect;
  const parts: string[] = [`window=${r.w}x${r.h}`];
  for (const id of ["storybook.header", "sidebar", "storybook.previous", "storybook.title", "storybook.devtools", "storybook.search", "window.controls.minimize", "window.controls.maximize", "window.controls.close"]) {
    const r = await visibleRect(id);
    if (r) parts.push(`${id}=${r.x.toFixed(0)},${r.y.toFixed(0)} ${r.w.toFixed(0)}x${r.h.toFixed(0)}`);
  }
  const line = `  ${name}: ${parts.join(" | ")}`;
  appendLog(line); console.log(line);
}

/// Windows, with real input allowed (--allow-foreground): the application-drawn maximize button
/// answers a real mouse click (SendInput). Its hit test reports HTMAXBUTTON for Snap Layouts, so
/// the click arrives as non-client messages, never as the harness's synthetic client click.
async function checkRealCaptionClick() {
  if (process.platform !== "win32") return;
  if (!(await visibleRect("window.controls.maximize"))) return;
  const native = (body: object) => request("POST", "/windows/native-input", body).catch(() => null);
  const activated = await native({ action: "activate" });
  if (!activated?.ok) { appendLog("  real caption click: native input unavailable (needs --allow-foreground)"); return; }
  const before = (await tree()).rect;
  const click = async () => {
    const r = (await visibleRect("window.controls.maximize"))!;
    assert((await native({ action: "pointer-down", x: r.x + r.w / 2, y: r.y + r.h / 2 }))?.ok, "real caption press failed");
    assert((await native({ action: "drag-release" }))?.ok, "real caption release failed");
  };
  await click();
  let grown = false;
  for (let i = 0; i < 50 && !grown; i++) { await sleep(100); const r = (await tree()).rect; grown = r.w > before.w || r.h > before.h; }
  const line = `  real caption click: maximize ${grown ? "ok" : "no effect"}`;
  appendLog(line); console.log(line);
  assert(grown, "application-drawn maximize button ignored a real click");
  await click();
  let restored = false;
  for (let i = 0; i < 50 && !restored; i++) { await sleep(100); const r = (await tree()).rect; restored = r.w === before.w && r.h === before.h; }
  assert(restored, "application-drawn maximize button did not restore on a real click");
}

test("storybook window header across states", async () => {
  await waitForServerReady(60000);
  await clickTestId("nav.button");
  await sleep(600);
  await snap("rest");
  await checkCaptionComposited("rest");
  await checkRealCaptionClick();
  const header = (await query("storybook.header"))[0];
  assert(header && header.rect.y === 0, "header is not at the window top");
  for (let i = 0; i < 6; i++) { await scrollAt(700, 500, 0, -60); await sleep(30); }
  await sleep(600);
  await snap("scrolled");
  await key("f11");
  await sleep(1800);
  await snap("fullscreen");
  await key("f11");
  await sleep(1800);
  await snap("restored");
  await checkCaptionComposited("restored");
});

test("emoji squares render as one glyph each (evidence)", async () => {
  await clickTestId("nav.emoji");
  await sleep(1200);
  const dir = getSessionDir();
  const path = `${dir}/emoji.png`;
  await request("POST", "/screenshot", { path });
  const scale = decodePng(path).width / (await tree()).rect.w;
  // The app's own frame, and (Windows, --allow-foreground) the composed desktop.
  const sources: { name: string; file: string; dx: number; dy: number }[] = [{ name: "app", file: path, dx: 0, dy: 0 }];
  if (process.platform === "win32") {
    const desktop = `${dir}/emoji-desktop.png`;
    const capture = await request("POST", "/windows/native-desktop", { path: desktop }).catch(() => null);
    if (capture?.ok) sources.push({ name: "desktop", file: desktop, dx: capture.client_x, dy: capture.client_y });
  }
  for (const source of sources) for (const id of ["story.emoji.red", "story.emoji.green", "story.emoji.blue"]) {
    const img = decodePng(source.file);
    const r = (await query(id))[0].rect;
    // Walk the centre column of the node: report each run of saturated (emoji) pixels.
    const x = Math.round((r.x + r.w / 2) * scale) + source.dx;
    const runs: string[] = [];
    let start = -1;
    for (let y = Math.floor(r.y * scale) - 4 + source.dy; y < Math.ceil((r.y + r.h) * scale) + 40 + source.dy && y < img.height; y++) {
      const i = (y * img.width + x) * img.channels;
      const px = [img.pixels[i], img.pixels[i + 1], img.pixels[i + 2]];
      const sat = Math.max(...px) - Math.min(...px) > 60;
      if (sat && start < 0) start = y;
      if (!sat && start >= 0) { runs.push(`${start}-${y - 1}`); start = -1; }
    }
    if (start >= 0) runs.push(`${start}-open`);
    const line = `  ${source.name} ${id}: node=${r.x.toFixed(1)},${r.y.toFixed(1)} ${r.w.toFixed(1)}x${r.h.toFixed(1)} scale=${scale} colour runs at x=${x}: ${runs.join(" ")}`;
    appendLog(line); console.log(line);
  }
});

run();

/// popover-text-seam.test.ts: a popover's opening animation must scale its settled text as one
/// picture: no glyph moves, re-rounds or changes raster on its own, during the animation or when
/// it settles.
///
/// Story popovertext opens a scale_fade and a dropdown popover whose rest origin is off the device
/// grid. On a locked 60 Hz clock every opening frame is captured and explained by a forward model
/// of a static texture: the settled picture, resampled bilinearly through a fitted scale + offset
/// and faded by a fitted opacity over a fitted background level (frame = alpha*S((X - b) / k) + c).
/// What the model cannot explain, the rms residual over the settled text in gray levels, is the
/// score.
///
/// Measured (2x displays): a static texture leaves only 8-bit rounding, <= 0.16 gray on macOS
/// (Metal) and on Windows 11 (D3D12, Intel Arc), at every scale. A text raster that switches mode
/// or re-snaps glyphs leaves 6-15 gray for the whole animation, growing towards rest.
///
/// (An earlier version registered the frame back onto the settled picture and compared with a
/// synthesized floor. Registering an already resampled frame biases the fitted transform, so the
/// floor was synthesized at the wrong offset and near-rest frames read as excess on Windows.)
///
/// Run: ZENIT_E2E_TEST_FILE=e2e/popover-text-seam.test.ts bash scripts/run_storybook_e2e.sh
import { mkdirSync } from "node:fs";
import { clickTestId, key, mouseMove, query, request, screenshot, sleep, tree, waitForServerReady } from "./client";
import { decodePng } from "./png";
import { appendLog, assert, getSessionDir, run, test } from "./runner";

const STEP = 1000 / 60;
/// 8-bit rounding of the texture and of the composite stays below 0.2 gray; a raster seam leaves 6+.
const MAX_RMS_GRAY = Number(process.env.SEAM_MAX_RMS_GRAY ?? "1.5");

interface Rect { x: number; y: number; w: number; h: number }
interface Img { w: number; h: number; a: Float64Array }
interface Region { x0: number; y0: number; x1: number; y1: number }

async function advance(ms: number): Promise<void> {
  const r: any = await request("POST", "/clock/advance", { ms });
  if (r.error) throw new Error(`advance: ${JSON.stringify(r)}`);
  for (let i = 0; i < 2000 && ((await request("GET", "/stats")) as any).clock_budget_ms > 0; i++) await sleep(5);
}

function load(path: string): Img {
  const png = decodePng(path);
  const a = new Float64Array(png.width * png.height);
  for (let i = 0; i < a.length; i++) {
    const j = i * png.channels;
    a[i] = 0.299 * png.pixels[j] + 0.587 * png.pixels[j + 1] + 0.114 * png.pixels[j + 2];
  }
  return { w: png.width, h: png.height, a };
}

function sample(img: Img, x: number, y: number): number {
  const cx = Math.min(Math.max(x, 0), img.w - 1.001), cy = Math.min(Math.max(y, 0), img.h - 1.001);
  const x0 = Math.floor(cx), y0 = Math.floor(cy), fx = cx - x0, fy = cy - y0;
  const i = y0 * img.w + x0;
  const top = img.a[i] * (1 - fx) + img.a[i + 1] * fx;
  const bot = img.a[i + img.w] * (1 - fx) + img.a[i + img.w + 1] * fx;
  return top * (1 - fy) + bot * fy;
}

function medianIn(img: Img, r: Region): number {
  const v: number[] = [];
  for (let y = r.y0; y < r.y1; y += 2) for (let x = r.x0; x < r.x1; x += 2) v.push(img.a[y * img.w + x]);
  v.sort((p, q) => p - q);
  return v[v.length >> 1];
}

/// Bounding box of the settled text inside the panel interior, padded by `pad` device px: the
/// model is fitted where the text is, away from the border, corners and shadow.
function textBox(settled: Img, interior: Region, pad: number): Region {
  const bg = medianIn(settled, interior);
  let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
  for (let y = interior.y0; y < interior.y1; y++) for (let x = interior.x0; x < interior.x1; x++) {
    if (bg - settled.a[y * settled.w + x] < 60) continue;
    x0 = Math.min(x0, x); y0 = Math.min(y0, y); x1 = Math.max(x1, x + 1); y1 = Math.max(y1, y + 1);
  }
  assert(Number.isFinite(x0), "no settled text inside the panel");
  return { x0: x0 - pad, y0: y0 - pad, x1: x1 + pad, y1: y1 + pad };
}

/// Forward model over frame region r: frame(X) = alpha * settled((X - b) / k) + c, alpha and c in
/// closed form. Returns the rms residual in gray levels.
function explain(frame: Img, settled: Img, r: Region, p: number[]) {
  const [k, bx, by] = p;
  let n = 0, ss = 0, sf = 0, sss = 0, ssf = 0, sff = 0;
  for (let y = r.y0; y < r.y1; y++) for (let x = r.x0; x < r.x1; x++) {
    const s = sample(settled, (x - bx) / k, (y - by) / k), f = frame.a[y * frame.w + x];
    n++; ss += s; sf += f; sss += s * s; ssf += s * f; sff += f * f;
  }
  const vs = sss - ss * ss / n, cv = ssf - ss * sf / n, vf = sff - sf * sf / n;
  const alpha = vs > 0 ? cv / vs : 0;
  const sse = Math.max(0, vf - alpha * cv);
  return { sse, alpha, rms: Math.sqrt(sse / n) };
}

function nelderMead(f: (p: number[]) => number, x0: number[], steps: number[], iters = 400): number[] {
  const n = x0.length;
  let simplex = [x0.slice(), ...steps.map((s, i) => { const p = x0.slice(); p[i] += s; return p; })];
  let vals = simplex.map(f);
  for (let it = 0; it < iters; it++) {
    const order = vals.map((_, i) => i).sort((a, b) => vals[a] - vals[b]);
    simplex = order.map((i) => simplex[i]); vals = order.map((i) => vals[i]);
    const c = new Array(n).fill(0);
    for (let i = 0; i < n; i++) for (let j = 0; j < n; j++) c[j] += simplex[i][j] / n;
    const at = (t: number) => c.map((cj, j) => cj + t * (simplex[n][j] - cj));
    const xr = at(-1), fr = f(xr);
    if (fr < vals[0]) {
      const xe = at(-2), fe = f(xe);
      if (fe < fr) { simplex[n] = xe; vals[n] = fe; } else { simplex[n] = xr; vals[n] = fr; }
    } else if (fr < vals[n - 1]) {
      simplex[n] = xr; vals[n] = fr;
    } else {
      const xc = at(0.5), fc = f(xc);
      if (fc < vals[n]) { simplex[n] = xc; vals[n] = fc; }
      else for (let i = 1; i <= n; i++) { simplex[i] = simplex[i].map((v, j) => simplex[0][j] + 0.5 * (v - simplex[0][j])); vals[i] = f(simplex[i]); }
    }
    if (Math.abs(vals[n] - vals[0]) <= 1e-10 * Math.max(1, Math.abs(vals[0]))) break;
  }
  return simplex[vals.indexOf(Math.min(...vals))];
}

function fit(frame: Img, settled: Img, r: Region, init: number[]) {
  const cost = (q: number[]) => explain(frame, settled, r, q).sse;
  const coarse = nelderMead(cost, init, [0.004, 1.5, 1.5]);
  const fine = nelderMead(cost, coarse, [0.0005, 0.2, 0.2]);
  return { p: fine, ...explain(frame, settled, r, fine) };
}

async function openAndMeasure(name: string, dir: string, scale: number) {
  const trigger = `story.popovertext.${name}.trigger`;
  const content = `story.popovertext.${name}.content`;
  await request("POST", "/clock", { step_ms: 0 });
  await clickTestId(trigger); await mouseMove(-10, -10); await sleep(700);
  const chrome = (await query(content))[0];
  assert(chrome, `${content} must mount`);
  const rect = chrome.rect as Rect;
  await key("escape"); await sleep(700);

  const lock: any = await request("POST", "/clock", { step_ms: STEP, locked: true });
  assert(!lock.error, `clock lock: ${JSON.stringify(lock)}`);
  await advance(STEP * 4);
  await clickTestId(trigger);
  await mouseMove(-10, -10);
  const frames: string[] = [];
  for (let i = 0; i < 14; i++) {
    await advance(STEP);
    const p = `${dir}/${name}-${String(i).padStart(2, "0")}.png`;
    await screenshot(p); frames.push(p);
  }
  await advance(600);
  const settledPath = `${dir}/${name}-settled.png`;
  await screenshot(settledPath);
  await request("POST", "/clock", { step_ms: 0 });
  await key("escape"); await sleep(500);

  // Text area: the settled text inside the panel interior (inset 12 logical px clears border,
  // corners and shadow), padded 4 logical px.
  const interior: Region = {
    x0: Math.round((rect.x + 12) * scale), y0: Math.round((rect.y + 12) * scale),
    x1: Math.round((rect.x + rect.w - 12) * scale), y1: Math.round((rect.y + rect.h - 12) * scale),
  };
  const settled = load(settledPath);
  const r = textBox(settled, interior, Math.round(4 * scale));
  // The panel scales about a point near its top-left (bottom_start placement).
  const ax = rect.x * scale, ay = rect.y * scale;
  let worst = 0, measured = 0, p = [0.95, ax * 0.05, ay * 0.05];
  const rows: string[] = [];
  for (const path of frames) {
    const frame = load(path);
    const m = fit(frame, settled, r, p);
    const id = path.slice(-6, -4);
    if (!(m.alpha > 0.3) || !(m.p[0] > 0.9 && m.p[0] < 1.1)) { rows.push(`${id} skipped alpha=${m.alpha.toFixed(2)} k=${m.p[0].toFixed(4)}`); continue; }
    worst = Math.max(worst, m.rms);
    measured++;
    p = m.p;
    rows.push(`${id} k=${m.p[0].toFixed(4)} b=(${m.p[1].toFixed(2)},${m.p[2].toFixed(2)}) alpha=${m.alpha.toFixed(2)} rms=${m.rms.toFixed(2)} gray`);
  }
  appendLog(`  ${name}: frames=${measured} worst rms=${worst.toFixed(2)} gray (limit ${MAX_RMS_GRAY})`);
  for (const row of rows) appendLog(`    ${row}`);
  console.log(`  ${name}: frames=${measured} worst rms=${worst.toFixed(2)} gray`);
  assert(measured >= 6, `${name}: only ${measured} opening frames measured`);
  return worst;
}

test("popover text: opening scales the settled text as one picture", async () => {
  await waitForServerReady(60000);
  await clickTestId("nav.popovertext");
  await mouseMove(-10, -10);
  await sleep(800);
  const dir = `${getSessionDir()}/popover-text-seam`;
  mkdirSync(dir, { recursive: true });
  const root = await tree();
  const probe = `${dir}/probe.png`;
  await screenshot(probe);
  const scale = decodePng(probe).width / root.rect.w;
  const failures: string[] = [];
  for (const name of ["scale", "dropdown"]) {
    const worst = await openAndMeasure(name, dir, scale);
    if (worst > MAX_RMS_GRAY) failures.push(`${name}: text departs from a static-texture composite (rms ${worst.toFixed(2)} gray > ${MAX_RMS_GRAY})`);
  }
  assert(failures.length === 0, failures.join("; "));
});

await run();

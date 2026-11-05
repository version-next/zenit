import { clickTestId, mouseMove, stats, screenPos, query, resizeWindow, screenshot, sleep, tree, waitFor, waitForServerReady, request } from "./client";
import { decodePng } from "./png";
import { assert, getSessionDir, run, test } from "./runner";

const bg = [20, 40, 60];
async function capture(stage: string) {
  await sleep(100);
  const path = `${getSessionDir()}/windows-images-${stage}.png`;
  assert((await screenshot(path)).ok, "capture failed");
  let png = decodePng(path);
  let pngPath = path;
  let scrollCaptures = 0;
  // Logical client dimensions are rounded on Windows; their ratio to drawable
  // width is not the true DPI scale at fractional scaling.
  const scale = (await stats()).window_scale;
  assert(typeof scale === "number" && scale > 0, "native window scale unavailable");
  console.log(`  ${path}, scale=${scale}`);
  const nodes = new Map<string, any>();
  const placements = new Map<string, any>();
  const sample = async (id: string, dx: number, dy: number) => {
    let node = nodes.get(id);
    if (!node) {
      node = (await query(id))[0];
      assert(node, `missing ${id}`);
      const placed = await screenPos(id);
      if (Math.abs(placed.x-node.rect.x) > .01 || Math.abs(placed.y-node.rect.y) > .01) {
        await sleep(100);
        const movedPath = `${getSessionDir()}/windows-images-${stage}-scroll-${scrollCaptures++}.png`;
        assert((await screenshot(movedPath)).ok, "scrolled capture failed");
        png = decodePng(movedPath);
        pngPath = movedPath;
        nodes.clear();
        placements.clear();
        node = (await query(id))[0];
        assert(node, `missing scrolled ${id}`);
      }
      nodes.set(id, node);
      placements.set(id, placed);
    }
    const x = Math.floor((node.rect.x + dx) * scale);
    const y = Math.floor((node.rect.y + dy) * scale);
    if (!(x >= 0 && x < png.width && y >= 0 && y < png.height)) {
      // screenPos can scroll: report its existing response without issuing it
      // again and changing the state whose screenshot failed.
      let currentStats: unknown;
      try { currentStats = await stats(); }
      catch (error) { currentStats = { diagnostic_error: String(error) }; }
      const root = await tree();
      function pathTo(node: any): any[] | null {
        if (node.test_id === id) return [node];
        for (const child of node.children ?? []) {
          const path = pathTo(child);
          if (path) return [node, ...path];
        }
        return null;
      }
      const ancestors = pathTo(root)?.map(n => ({ tag: n.tag, test_id: n.test_id, rect: n.rect,
        translate_y: n.translate_y, component: n.component }));
      assert(false, `sample outside screenshot: ${JSON.stringify({
        stage, id, dx, dy, pixel: { x, y }, node_rect: node.rect,
        screen_pos: placements.get(id), scale,
        png: { path: pngPath, width: png.width, height: png.height },
        current_stats: currentStats, ancestors,
      })}`);
    }
    const i = (y * png.width + x) * png.channels;
    return { rgb: [png.pixels[i], png.pixels[i+1], png.pixels[i+2]], x: (x + .5) / scale - node.rect.x, y: (y + .5) / scale - node.rect.y };
  };
  return {
    scale, sample,
    async pixel(id: string, dx: number, dy: number) { return (await sample(id, dx, dy)).rgb; }
  };
}
function near(actual: number[], expected: number[], label: string, tolerance = 4) {
  assert(actual.every((v, i) => Math.abs(v-expected[i]) <= tolerance), `${label}: ${actual}, expected ${expected}`);
}

test("Windows App starts with font configuration and mounts after nonzero allocation and prior quit", async () => {
  await waitForServerReady(15000);
  const root = await tree();
  assert(root.rect.w > 0 && root.rect.h > 0, "App did not mount a visible root");
  assert((await query("gallery.window-status"))[0]?.text === "window-contract=PASS", "reused App did not enter its UI loop");
});

test("Windows native menu preserves Unicode, checked/disabled states, 64-bit commands and replacement lifetime", async () => {
  await waitForServerReady(15000);
  const status = (await query("gallery.menu-status"))[0]?.text;
  assert(status === "menu-contract=PASS", `native menu contract failed: ${status}`);
});

test("Windows titlebar hit testing preserves controls, logical coordinates, disabled bands and foreground", async () => {
  await waitForServerReady(15000);
  const node = (await query("gallery.window-status"))[0];
  assert(node?.text === "window-contract=PASS", `native titlebar contract failed: ${node?.text}`);
});

test("Windows capture loss and batched moves preserve cancellation, fast drag, next-click recovery, native cursor routing, live-resize paint, logical client sizing and display refresh", async () => {
  await waitForServerReady(15000);
  assert((await clickTestId("gallery.window-status")).ok, "pointer contract command failed");
  const terminal = await waitFor(async () => {
    const text = (await query("gallery.window-status"))[0]?.text;
    return text === "pointer-contract=PASS" || text === "pointer-contract=FAIL" ? text : null;
  }, 5000, 50);
  assert(terminal === "pointer-contract=PASS", `native pointer contract failed: ${terminal}; see native stderr stage diagnostics`);
  await capture("pointer-cancel");
});

test("Windows GPU window suppresses GDI background erasure", async () => {
  await waitForServerReady(15000);
  const node = (await query("gallery.erase-status"))[0];
  assert(node?.text === "erase-contract=PASS", `native background erasure contract failed: ${node?.text}`);
});

test("Windows arcs preserve sweep, radial ends, hollow center, opacity and clips", async () => {
  await waitForServerReady(15000);
  const image = await capture("arcs");
  near(await image.pixel("arc.quarter", 74, 74), [255, 255, 255], "quarter interior");
  near(await image.pixel("arc.quarter", 84, 45), bg, "before radial start");
  near(await image.pixel("arc.quarter", 45, 84), bg, "after radial end");
  near(await image.pixel("arc.quarter", 50, 50), bg, "quarter hollow center");
  for (const [x,y] of [[84,50], [50,84], [16,50], [50,16]]) {
    near(await image.pixel("arc.full", x, y), [255, 255, 255], "full circle quadrant");
  }
  near(await image.pixel("arc.full", 50, 50), bg, "full hollow center");
  near(await image.pixel("arc.full", 75, 50), bg, "inside inner radius");
  near(await image.pixel("arc.full", 94, 50), bg, "outside outer radius");
  near(await image.pixel("arc.negative", 74, 26), [255, 255, 255], "negative start angle");
  near(await image.pixel("arc.negative", 74, 74), bg, "outside negative sweep");
  near(await image.pixel("arc.opacity", 50, 84), [138, 148, 158], "arc group opacity");
  near(await image.pixel("arc.zero", 84, 50), bg, "zero sweep draws nothing");
  near(await image.pixel("arc.clipped", 16, 50), [255, 255, 255], "clip interior");
  near(await image.pixel("arc.clipped", 84, 50), bg, "clip exterior");
});

test("Windows native clipboard preserves PNG alpha and external bitmap formats", async () => {
  await waitForServerReady(15000);
  assert((await clickTestId("gallery.clipboard")).ok, "clipboard button failed");
  const text = await waitFor(async () => {
    const node = (await query("gallery.clipboard-status"))[0];
    const value = node?.text ?? node?.children?.map((child: any) => child.text ?? "").join(" ") ?? "";
    return value.includes("clipboard-contract=") ? value : null;
  }, 5000, 50);
  assert(text.includes("clipboard-contract=PASS"), `native clipboard contract failed: ${text}`);
});
async function check(stage: string) {
  const image = await capture(stage);
  near(await image.pixel("gallery.quadrant", 25, 25), [255, 0, 0], "red quadrant");
  near(await image.pixel("gallery.quadrant", 75, 25), [0, 255, 0], "green quadrant");
  near(await image.pixel("gallery.quadrant", 25, 75), [0, 0, 255], "blue quadrant");
  near(await image.pixel("gallery.quadrant", 75, 75), [138, 148, 158], "premultiplied alpha");
  near(await image.pixel("gallery.rounded", 1, 1), bg, "rounded corner clipped");
  near(await image.pixel("gallery.rounded", 50, 50), [255, 255, 255], "rounded center");
  near(await image.pixel("gallery.rotated", 25, 25), [0, 0, 255], "rotated blue");
  near(await image.pixel("gallery.rotated", 75, 25), [255, 0, 0], "rotated red");
  near(await image.pixel("gallery.tint", 50, 50), [74, 52, 158], "RGBA tint");
  near(await image.pixel("gallery.opacity", 50, 50), [138, 148, 158], "group opacity");
  near(await image.pixel("gallery.clipped-image", 25, 25), [255, 0, 0], "clip interior");
  near(await image.pixel("gallery.clipped-image", 75, 25), bg, "clip exterior");
}

test("Windows RGBA textures preserve alpha, tint, rotation, clips and resize", async () => {
  await waitForServerReady(15000);
  assert((await query("gallery.status"))[0]?.text === "textures=2 bytes=20", "texture API initialization failed");
  await check("initial");
  assert((await resizeWindow(900, 650)).ok, "resize failed");
  await check("resized");
  assert((await resizeWindow(800, 600)).ok, "restore size failed");
  await check("restored");
});

test("Windows unloaded texture handles cannot alias replacement images", async () => {
  assert((await clickTestId("gallery.replace")).ok, "replacement failed");
  assert((await query("gallery.status"))[0]?.text === "texture-replaced; old-handles-invalid", "texture API lifecycle checks failed");
  const image = await capture("replaced");
  near(await image.pixel("gallery.quadrant", 25, 25), [0, 255, 0], "new texture uploaded");
  near(await image.pixel("gallery.rotated", 25, 25), bg, "stale rotated texture handle");
  near(await image.pixel("gallery.clipped-image", 25, 25), bg, "stale clipped texture handle");
  near(await image.pixel("gallery.rounded", 50, 50), [255, 255, 255], "other live texture preserved");
});

test("Windows shadows preserve body cutout, spread, inset direction and dual colors", async () => {
  const panel = (await query("gallery.shadow-panel"))[0];
  assert(panel && Math.abs(panel.rect.h - 160) < 0.01, `shadow reference panel compressed: ${JSON.stringify(panel?.rect)}`);
  const image = await capture("shadows");
  const bottom = await image.pixel("shadow.outer", 50, 106);
  const top = await image.pixel("shadow.outer", 50, -6);
  assert(bottom.every(v => v < 210), `offset shadow absent: ${bottom}`);
  near(top, [255, 255, 255], "offset shadow does not extend above");
  near(await image.pixel("shadow.outer", 50, 50), [255, 255, 255], "transparent body punches outer-shadow hole");
  near(await image.pixel("shadow.outer", 50, 130), [255, 255, 255], "blur fades to background");
  const positive = await image.pixel("shadow.spread-positive", 110, 50);
  const negative = await image.pixel("shadow.spread-negative", 110, 50);
  assert(positive[0] < negative[0]-15, `spread did not expand shadow: ${positive} vs ${negative}`);
  near(negative, [255, 255, 255], "negative spread shrinks shadow");
  // A real regression split the bitmap sampler at an optimization boundary,
  // leaving a bright one-pixel line across an otherwise smooth shadow edge.
  let previous: number[] | undefined;
  for (const y of [15.5, 16, 16.5, 17, 17.5]) {
    const pixel = await image.pixel("shadow.spread-positive", -1.5, y);
    if (previous) assert(pixel.every((v,c) => Math.abs(v-previous![c]) <= 5), `shadow edge seam: ${previous} -> ${pixel}`);
    previous = pixel;
  }
  const insetTop = await image.pixel("shadow.inset", 50, 2);
  assert(insetTop.every(v => v < 100), `inset top edge absent: ${insetTop}`);
  near(await image.pixel("shadow.inset", 50, 50), [255, 255, 255], "inset does not fill center");
  near(await image.pixel("shadow.inset", 50, 98), [255, 255, 255], "inset offset leaves bottom clear");
  const left = await image.pixel("shadow.dual", -4, 50);
  const right = await image.pixel("shadow.dual", 104, 50);
  assert(left[2] > left[0]+60, `blue shadow absent: ${left}`);
  assert(right[0] > right[2]+60, `red shadow absent: ${right}`);
  near(await image.pixel("shadow.dual", 50, 50), [255, 255, 255], "dual shadow body fill preserved");
  await resizeWindow(900, 650);
  const resized = await capture("shadows-resized");
  const again = await resized.pixel("shadow.outer", 50, 106);
  near(again, bottom, "shadow regenerated after target resize");
  await resizeWindow(800, 600);
});

test("Windows vector paths preserve curves, winding holes and stroke joins", async () => {
  await waitForServerReady(15000);
  assert((await clickTestId("gallery.paths")).ok, "path gallery activation failed");
  const image = await capture("paths");
  near(await image.pixel("path.evenodd",20,50), [255,255,255], "evenodd body");
  near(await image.pixel("path.evenodd",50,50), bg, "evenodd hole");
  near(await image.pixel("path.nonzero",50,50), [255,255,255], "nonzero same-winding center");
  near(await image.pixel("path.quad",50,30), [138,148,158], "quadratic interior and opacity");
  near(await image.pixel("path.quad",50,10), bg, "quadratic exterior, not control polygon");
  near(await image.pixel("path.cubic",50,30), [255,255,255], "cubic interior");
  near(await image.pixel("path.cubic",50,10), bg, "cubic exterior, not control polygon");
  near(await image.pixel("path.clipped",20,50), [255,255,255], "path clip interior");
  near(await image.pixel("path.clipped",80,50), bg, "path clip exterior");
  near(await image.pixel("path.miter",50,4), [255,255,255], "miter outer tip");
  near(await image.pixel("path.bevel",50,4), bg, "bevel tip removed");
  // The round join reaches y = 5 (apex 10, half width 5). Sample 1.5 pt out so
  // the pixel centre clears the antialiasing band at 1x as well as 1.75x/2x.
  near(await image.pixel("path.round",50,3), bg, "round tip removed");
  near(await image.pixel("path.miter-limit",50,4), bg, "over-limit miter becomes bevel");
  near(await image.pixel("path.miter-limit",50,15), [255,255,255], "acute join remains filled");
  for (const id of ["path.miter","path.bevel","path.round"]) {
    near(await image.pixel(id,30,30), [255,255,255], "stroke interior");
    near(await image.pixel(id,50,35), bg, "stroke unfilled interior");
    near(await image.pixel(id,8,54), bg, "flat open cap");
  }
});

test("Windows independent corners, inside borders and opacity clip match shared shapes", async () => {
  await waitForServerReady(15000);
  assert((await clickTestId("gallery.paths")).ok, "shape gallery activation failed");
  const image = await capture("rounded");
  for (const id of ["round.fill", "round.gradient"]) {
    near(await image.pixel(id, 2, 2), bg, "large TL removes corner");
    near(await image.pixel(id, 98, 2), [255,255,255], "square TR remains");
    near(await image.pixel(id, 98, 98), bg, "BR has independent curve");
    near(await image.pixel(id, 2, 98), bg, "BL has independent curve");
    near(await image.pixel(id, 20, 20), [255,255,255], "TL curve interior");
    near(await image.pixel(id, 50, 50), [255,255,255], "body remains filled");
  }
  near(await image.pixel("round.border", 50, 2), [255,255,255], "six-pixel top band");
  near(await image.pixel("round.border", 50, 8), bg, "border inner cutout");
  near(await image.pixel("round.border", -2, 50), bg, "border stays inside bounds");
  near(await image.pixel("round.border", 50, 50), bg, "border hollow center");
  near(await image.pixel("round.border", 2, 2), bg, "border preserves curved TL");
  near(await image.pixel("round.wide-border", 50, 50), [255,255,255], "border thicker than half-size fills body");
  // Clamped corner circle: centre (20, 20), radius 20. (4, 4) stays ~1.9 pt
  // outside it at every scale; (5, 5) sat in the 1x antialiasing band.
  near(await image.pixel("round.clamp", 4, 4), bg, "oversized radius clamps to half height");
  near(await image.pixel("round.clamp", 15, 5), [255,255,255], "clamped radius retains curve interior");
  near(await image.pixel("round.clip", 2, 2), bg, "rounded mask removes child corner");
  near(await image.pixel("round.clip", 50, 50), [138,148,158], "masked content retains opacity");
  near(await image.pixel("round.clip", -5, 50), bg, "rotated mask clips oversized child");
});

test("Windows nested legacy opacity layers preserve destination offsets and scaling", async () => {
  assert((await resizeWindow(900, 800)).ok, "layer fixture resize failed");
  assert((await clickTestId("gallery.paths")).ok, "layer fixture activation failed");
  const image = await capture("legacy-layers");
  near(await image.pixel("layer.legacy", 60, 20), [138,148,158], "outer destination retains opacity");
  near(await image.pixel("layer.legacy", 80, 35), [10,20,158], "nested destination scales in parent frame");
  near(await image.pixel("layer.legacy", 10, 10), bg, "source origin is not painted");
  near(await image.pixel("layer.legacy", 95, 35), bg, "scaled child does not bleed outside layer");
});

/** W3C compositing blend B(cb, cs) per channel on sRGB-encoded bytes (opaque
 * backdrop and source). */
function blendEncoded(mode: string, backdrop: number[], source: number[]): number[] {
  const f = (b: number, s: number): number => {
    switch (mode) {
      case "normal": return s;
      case "multiply": return b * s;
      case "screen": return b + s - b * s;
      case "overlay": return b <= .5 ? 2 * b * s : 1 - 2 * (1 - b) * (1 - s);
      case "darken": return Math.min(b, s);
      case "lighten": return Math.max(b, s);
      case "color-dodge": return b === 0 ? 0 : s >= 1 ? 1 : Math.min(1, b / (1 - s));
      case "color-burn": return b >= 1 ? 1 : s <= 0 ? 0 : 1 - Math.min(1, (1 - b) / s);
      case "hard-light": return s <= .5 ? 2 * b * s : 1 - 2 * (1 - b) * (1 - s);
      case "soft-light": {
        const d = b <= .25 ? ((16 * b - 12) * b + 4) * b : Math.sqrt(b);
        return s <= .5 ? b - (1 - 2 * s) * b * (1 - b) : b + (2 * s - 1) * (d - b);
      }
      case "difference": return Math.abs(b - s);
      case "exclusion": return b + s - 2 * b * s;
    }
    throw new Error(`unknown blend mode ${mode}`);
  };
  return backdrop.map((b, i) => Math.round(255 * f(b / 255, source[i] / 255)));
}

test("Windows blend modes preserve encoded colors, alpha, nested opacity and geometric clips", async () => {
  await waitForServerReady(15000);
  assert((await clickTestId("gallery.blends")).ok, "blend fixture activation failed");
  const check = async (stage: string) => {
    const image = await capture(stage);
    // W3C separable blend equations on sRGB-encoded channels (all backends
    // blend encoded values, as AppKit does: docs/SRGB_BLENDING_PLAN.md), with
    // destination=(128,192,64), source=(192,64,128).
    const modes = ["normal","multiply","screen","overlay","darken","lighten","color-dodge","color-burn","hard-light","soft-light","difference","exclusion"];
    for (const mode of modes) near(await image.pixel(`blend.${mode}`,50,50),blendEncoded(mode,[128,192,64],[192,64,128]),mode);
    near(await image.pixel("blend.alpha",50,50),[153,193,90],"texture alpha times group opacity");
    near(await image.pixel("blend.nested",50,50),[10,148,30],"blend within isolated opacity group");
    near(await image.pixel("blend.rounded",50,50),blendEncoded("multiply",[128,192,64],[192,64,128]),"blend within rounded clip");
    near(await image.pixel("blend.rounded",2,2),bg,"rounded clip rejects corner");
    near(await image.pixel("blend.rotated",50,50),blendEncoded("multiply",[128,192,64],[192,64,128]),"rotated rounded blend center");
    near(await image.pixel("blend.rotated",2,2),[128,192,64],"rotated rounded blend preserves backdrop");
    // Yellow (255,255,0,128) group at .5 opacity; a multiply group with cyan
    // inside a rounded clip: multiply gives (0,1,0) under the yellow's alpha .5
    // -> (0,1,.5) in the group, composited at .5 over the (20,40,60) backdrop.
    near(await image.pixel("blend.clip-translucent",50,50),[10,148,94],"clip passes translucent backdrop to blend");
    near(await image.pixel("blend.clip-translucent",2,2),[79,94,45],"clip does not double-compose backdrop alpha");
  };
  await check("blend-modes");
  assert((await resizeWindow(1000,850)).ok,"blend resize failed");
  await check("blend-resized");
});

const srgbLin = (v: number) => v <= .04045 ? v / 12.92 : Math.pow((v + .055) / 1.055, 2.4);
const srgbEnc = (v: number) => { v = Math.max(0, Math.min(1, v)); return Math.round(255 * (v <= .0031308 ? 12.92 * v : 1.055 * Math.pow(v, 1 / 2.4) - .055)); };
/** Black/white sources blurred with some weights: a value calibrated for the
 * old linear-light pipeline (encode(W)) becomes 255*W now that blurs average
 * sRGB-encoded values (docs/SRGB_BLENDING_PLAN.md). Exact for any weights. */
function encodedMix(linearCalibrated: number): number[] {
  return [0, 0, 0].map(() => Math.round(255 * srgbLin(linearCalibrated / 255)));
}
/** Glass over the 4px black/white stripes at local blur level `level`
 * (0 = sharp, 1 = blur): the legacy material decodes both samples and mixes
 * them in linear light, then encodes. The blur of the stripes is 50% grey
 * (encoded 0.5); `sharp` is the encoded stripe value under the sample. */
function glassLevel(level: number, sharp = 0): number[] {
  const v = (1 - level) * srgbLin(sharp / 255) + level * srgbLin(.5);
  return [0, 0, 0].map(() => srgbEnc(v));
}
/** BlurGradient profile (glass.metal gradient_blur_level): smoothstep between
 * stops along gt, stop strength = absolute blur level. */
function blurProfile(gt: number, stops: [number, number][]): number {
  const ss = (a: number, b: number, x: number) => { const t = Math.max(0, Math.min(1, (x - a) / (b - a))); return t * t * (3 - 2 * t); };
  let prof = stops[0][1];
  for (let i = 0; i < stops.length - 1; i++) {
    const p0 = stops[i][0], p1 = Math.max(stops[i + 1][0], p0 + 1e-4);
    if (gt >= p0) prof = stops[i][1] + (stops[i + 1][1] - stops[i][1]) * ss(p0, p1, gt);
  }
  return Math.max(0, Math.min(1, prof));
}

test("Windows backdrop blur mixes sharp and blurred backdrop per gradient profile within rounded bounds", async () => {
  await waitForServerReady(15000);
  assert((await resizeWindow(1200,850)).ok,"blur resize failed");
  assert((await clickTestId("gallery.blur")).ok,"blur activation failed");
  const check = async (stage: string) => {
    const image = await capture(stage);
    near(await image.pixel("blur.sharp",54,50),[0,0,0],"zero blur level remains sharp");
    near(await image.pixel("blur.zero",54,50),[0,0,0],"zero radius remains sharp");
    near(await image.pixel("blur.uniform",54,50),encodedMix(188),"black-white blur");
    // Sample columns sit on black stripes (x = 54, 22, 78); the ramp fixtures
    // run from blur level 1 to 0 along their direction.
    const ramp: [number, number][] = [[0, 1], [1, 0]];
    near(await image.pixel("blur.half",54,50),glassLevel(.5),"half mix");
    near(await image.pixel("blur.gradient",54,20),glassLevel(blurProfile(.2, ramp)),"smoothstep gradient top",6);
    near(await image.pixel("blur.gradient",54,80),glassLevel(blurProfile(.8, ramp)),"smoothstep gradient bottom",6);
    near(await image.pixel("blur.top",54,20),glassLevel(blurProfile(.8, ramp)),"top direction reverses profile",6);
    near(await image.pixel("blur.top",54,80),glassLevel(blurProfile(.2, ramp)),"top direction lower sample",6);
    near(await image.pixel("blur.left",22,50),glassLevel(blurProfile(.78, ramp)),"left direction",6);
    near(await image.pixel("blur.left",78,50),glassLevel(blurProfile(.22, ramp)),"left direction opposite sample",6);
    near(await image.pixel("blur.right",22,50),glassLevel(blurProfile(.22, ramp)),"right direction",6);
    near(await image.pixel("blur.right",78,50),glassLevel(blurProfile(.78, ramp)),"right direction opposite sample",6);
    near(await image.pixel("blur.inactive",54,50),glassLevel(1),"zero gradient strength retains base blur");
    const four: [number, number][] = [[0, 0], [.4, 1], [.6, 0], [1, 0]];
    near(await image.pixel("blur.four",54,50),glassLevel(blurProfile(.5, four)),"four-stop middle mix");
    near(await image.pixel("blur.four",54,44),glassLevel(blurProfile(.44, four)),"four-stop inner interval",6);
    near(await image.pixel("blur.four",54,80),[0,0,0],"four-stop sharp end");
    near(await image.pixel("blur.rounded",54,50),glassLevel(1),"rounded center");
    near(await image.pixel("blur.rounded",2,2),[255,255,255],"rounded corner keeps sharp backdrop");
    // Red/blue stripes blur to encoded (.5, 0, .5); saturation 0 keeps the
    // Rec.709 luma of the linear colour, brightness halves it.
    near(await image.pixel("blur.color",54,50),[0,0,0].map(()=>srgbEnc((.2126+.0722)*srgbLin(.5)*.5)),"saturation and brightness in linear light");
  };
  await check("blur");
  assert((await resizeWindow(1150,800)).ok,"blur second resize failed");
  await check("blur-resized");
  assert((await clickTestId("gallery.blur-change")).ok,"backdrop change failed");
  const changed = await capture("blur-changed");
  near(await changed.pixel("blur.uniform",54,50),[0,255,0],"blur samples updated backdrop");
});

for (const [layout,activation] of [["isolated","gallery.blur-isolate"],["neighboring","gallery.blur"]] as const)
test(`Windows Glass fades preserve blurred underlying pixels without gray or black contamination (${layout})`, async () => {
  await waitForServerReady(15000);
  assert((await resizeWindow(1200,850)).ok,"glass fade resize failed");
  assert((await clickTestId(activation)).ok,"glass fade activation failed");
  const reference = await capture(`glass-fade-${layout}-reference`);
  // A faded group is the glass composited over the untouched backdrop at its
  // opacity. Both ends are measured: the glass from the reference, the
  // backdrop from the alpha-0 frame (stripe edges sit on fractional device
  // pixels, so a synthetic 0/255 stripe oracle is wrong at the boundaries).
  const alphas = [0.75,0.5,0.25,0,0.25,0.5,0.75,1];
  const frames: Awaited<ReturnType<typeof capture>>[] = [];
  for (const index of alphas.keys()) {
    assert((await clickTestId("gallery.blur-fade")).ok,"glass fade action failed");
    frames.push(await capture(`glass-fade-${layout}-${index}`));
  }
  const cleared = frames[alphas.indexOf(0)];
  let maxError=0;
  for (const [index,alpha] of alphas.entries()) {
    const image = frames[index];
    for (const [x,y,label] of [[54,50,"black stripe"],[50,50,"white stripe"]] as const) {
      const base = await cleared.pixel("blur.uniform",x,y), glass = await reference.pixel("blur.uniform",x,y);
      near(await image.pixel("blur.uniform",x,y),base.map((v,i)=>Math.round(v+(glass[i]-v)*alpha)),`${label} alpha=${alpha}`);
    }
    // The blur kernel needs pixels outside the group, including below it.
    for (const y of [3,8,20,50,80,92,97]) for (const x of [3,8,20,50,80,92,97]) {
      const sample = await image.sample("blur.uniform",x,y);
      const original = await cleared.pixel("blur.uniform",x,y);
      const filtered = await reference.pixel("blur.uniform",x,y);
      const expected=filtered.map((v,i)=>Math.round(original[i]+(v-original[i])*alpha));
      const error=Math.max(...sample.rgb.map((v,i)=>Math.abs(v-expected[i])));
      maxError=Math.max(maxError,error);
      if(error>4) console.log(`  edge (${x},${y}) alpha=${alpha}: ${sample.rgb}, expected ${expected}`);
    }
  }
  assert(maxError<=4,`Glass edge compositing max channel error=${maxError}`);
});

test("Windows backdrop luminance measures each owner's own backdrop", async () => {
  await waitForServerReady(15000);
  assert((await resizeWindow(1150,800)).ok, "luminance resize failed");
  assert((await clickTestId("gallery.blur")).ok, "luminance fixture activation failed");
  const read = async () => {
    assert((await clickTestId("gallery.luminance")).ok, "luminance read failed");
    const text = (await query("gallery.luminance-status"))[0]?.text ?? "";
    const match = /^n=(\d+); values=(.*)$/.exec(text);
    assert(match, `missing luminance data: ${text}`);
    return { count: Number(match[1]), values: match[2].split(",").map(Number) };
  };
  // A solid backdrop of linear luminance L reads between .70 L and L: the
  // reading averages the blurred backdrop under the glass's own rect, and the
  // blur pulls the dark page in along the rect's edges (measured .75-.86 for
  // a 100px panel at 12px blur). Reading the whole padded capture gave .31
  // for white; that is what this bounds.
  const check = async (expected: number[], stage: string) => {
    let last: unknown;
    const within = (v: number, L: number) => L < 0 ? v === -1 : L < .005 ? v <= .01 : v >= .70 * L - .002 && v <= 1.02 * L + .005;
    const data = await waitFor(async () => {
      const data = await read();
      if (JSON.stringify(last) !== JSON.stringify(data)) console.log(`  ${stage} sample: ${JSON.stringify(data)}`);
      last = data;
      return data.count === 11 && data.values.length === 12 &&
        data.values.every((v,i) => within(v, expected[i])) ? data : null;
    }, 8000, 50);
    console.log(`  ${stage}: ${JSON.stringify(data)}`);
  };
  // The reading is the mean linear luminance of the blurred (encoded-space)
  // backdrop over the glass's own rect: 4px black/white stripes blur to
  // encoded .5 (linear .214), lowered near the rect's edges where the blur
  // pulls in the dark page around the 100px panel. Every stripe panel has the
  // same geometry, so the readings agree with each other; red/blue stripes
  // carry Rec.709 red+blue weight (.285) of the black/white value.
  {
    let last: unknown;
    const data = await waitFor(async () => {
      const data = await read();
      if (JSON.stringify(last) !== JSON.stringify(data)) console.log(`  stripes sample: ${JSON.stringify(data)}`);
      last = data;
      if (data.count !== 11 || data.values.length !== 12 || data.values[7] !== -1) return null;
      const bw = data.values.filter((_, i) => i !== 6 && i !== 7);
      const mean = bw.reduce((a, b) => a + b, 0) / bw.length;
      const ok = bw.every(v => Math.abs(v - mean) <= .02) && mean > srgbLin(.5) * .75 && mean <= srgbLin(.5) * 1.05 &&
        Math.abs(data.values[6] - (.2126 + .0722) * mean) <= .015;
      return ok ? data : null;
    }, 8000, 50);
    console.log(`  black/white and red/blue stripes: ${JSON.stringify(data)}`);
  }
  assert((await clickTestId("gallery.luminance-solid")).ok, "solid backgrounds failed");
  const linear = (v: number) => v/255 <= .04045 ? v/255/12.92 : ((v/255+.055)/1.055)**2.4;
  await check([0,linear(128),1,.2126,.7152,.0722,.9278,-1,.2848,linear(32),linear(192),linear(64)],
    "distinct owner backgrounds and inactive zero-radius owner");
  assert((await clickTestId("gallery.blur-change")).ok, "green background update failed");
  const green = Array(12).fill(.7152);
  green[7] = -1;
  await check(green, "live background update");
  // Hidden owners leave the published set: the renderer retires the slots of
  // glass absent from the frame's paint table (the encoder's "encoded this
  // frame" is not visibility under prefix reuse and cached layers).
  assert((await clickTestId("gallery.paths")).ok, "hide luminance fixture failed");
  const hidden = await waitFor(async () => { const d = await read(); return d.count === 0 ? d : null; }, 4000, 50);
  assert(hidden.values.every(v => v === -1), `hidden owners still published: ${JSON.stringify(hidden)}`);
});

async function nearSample(image: Awaited<ReturnType<typeof capture>>, id: string, x: number, y: number,
  expected: (px: number, py: number) => number[], label: string) {
  const sample = await image.sample(id, x, y);
  near(sample.rgb, expected(sample.x, sample.y), label);
}

test("Windows gradients preserve premultiplied colors, stops, direction, radial geometry and extend", async () => {
  await waitForServerReady(15000);
  assert((await resizeWindow(1000, 850)).ok, "gradient resize failed");
  assert((await clickTestId("gallery.gradients")).ok, "gradient fixture activation failed");
  // Gradients interpolate sRGB-encoded channels (docs/SRGB_BLENDING_PLAN.md):
  // a 0..1 channel ramp is 255 * t on screen.
  const encode = (v: number) => Math.round(255 * v);
  const rb = (t: number) => [encode(1-t), 0, encode(t)];
  const multi = (t: number) => t <= .25 ? [encode(1-t/.25),encode(t/.25),0]
    : [0,encode(1-(t-.25)/.75),encode((t-.25)/.75)];
  const radial = (x: number, y: number, cx=.5, cy=.5, rx=.5, ry=.5) =>
    Math.hypot((x/200-cx)/rx, (y/100-cy)/ry);
  const check = async (stage: string) => {
    const image = await capture(`gradients-${stage}`);
    const sample = (id: string, x: number, y: number, f: (x: number,y: number) => number[], label: string) => nearSample(image,id,x,y,f,label);
    for (const id of ["gradient.linear", "gradient.legacy"]) {
      await sample(id,100,50,x=>rb(x/200),"midpoint");
      await sample(id,50,50,x=>rb(x/200),"quarter interpolation");
    }
    await sample("gradient.multi",100,25,(_,y)=>multi(y/100),"nonuniform middle stop");
    await sample("gradient.multi",100,62,(_,y)=>multi(y/100),"middle-to-last stop");
    await sample("gradient.diagonal",150,25,(x,y)=>rb((x/200+y/100)/2),"diagonal normalized UV on non-square bounds");
    await sample("gradient.alpha",100,50,x=>{const a=x/200;return [Math.round(20*(1-a)),Math.round(40*(1-a)),Math.round(255*a+60*(1-a))];},"transparent red cannot bleed into premultiplied blue");
    // The radial cusp crosses the pixel: bound its actual physical footprint.
    const center = await image.sample("gradient.radial",100,50), half=.5/image.scale;
    const bound = rb(Math.max(...[-half,half].flatMap(dx=>[-half,half].map(dy=>radial(center.x+dx,center.y+dy)))));
    assert(center.rgb[0]>=bound[0]-4 && center.rgb[1]<=4 && center.rgb[2]<=bound[2]+4,
      `radial center outside its pixel footprint: ${center.rgb}, bound ${bound}`);
    await sample("gradient.radial",110,50,(x,y)=>rb(radial(x,y)),"radial near center");
    await sample("gradient.radial",150,50,(x,y)=>rb(radial(x,y)),"radial half radius");
    await sample("gradient.offset",60,40,(x,y)=>rb(radial(x,y,.25,.4,.75,.3)),"offset elliptical near center");
    await sample("gradient.offset",125,40,(x,y)=>rb(radial(x,y,.25,.4,.75,.3)),"custom elliptical radius");
    await sample("gradient.repeat",162,50,(x,y)=>rb(radial(x,y,.5,.5,.25,.25)-1),"radial repeat beyond first radius");
    await sample("gradient.reflect",162,50,(x,y)=>rb(2-radial(x,y,.5,.5,.25,.25)),"radial reflected second radius");
    near(await image.pixel("gradient.ellipse",1,1),bg,"ellipse gradient excludes corner");
    await sample("gradient.ellipse",100,50,x=>rb(x/200),"ellipse gradient center");
    near(await image.pixel("gradient.rounded",1,1),bg,"independent rounded corner clips gradient");
    await sample("gradient.rounded",198,1,x=>multi(x/200),"square corner retains gradient");
    near(await image.pixel("gradient.single",100,50),[0,255,255],"single-stop constant color");
  };
  try {
    await check("initial");
    assert((await resizeWindow(1100,850)).ok,"gradient resize failed");
    await check("resized");
  } finally { await clickTestId("gallery.paths"); }
});

test("Windows path gradients preserve bounds, direction, multi-stops, alpha, holes, curves and clips", async () => {
  await waitForServerReady(15000);
  assert((await resizeWindow(1100,850)).ok,"path gradient resize failed");
  assert((await clickTestId("gallery.paths")).ok,"path gradient activation failed");
  // Gradients interpolate sRGB-encoded channels (docs/SRGB_BLENDING_PLAN.md):
  // a 0..1 channel ramp is 255 * t on screen.
  const encode = (v: number) => Math.round(255 * v);
  const color=(t:number)=>t<=.25?[encode(1-t/.25),encode(t/.25),0]:[0,encode(1-(t-.25)/.75),encode((t-.25)/.75)];
  const check=async(stage:string)=>{
    const image=await capture(`path-gradients-${stage}`);
    const sample=(id:string,x:number,y:number,f:(x:number,y:number)=>number[],label:string)=>nearSample(image,id,x,y,f,label);
    await sample("path.gradient-horizontal",53,52,x=>color((x-13)/80),"horizontal uses offset geometry bounds");
    await sample("path.gradient-vertical",53,32,(_,y)=>color((y-12)/80),"vertical middle stop");
    await sample("path.gradient-diagonal",73,32,(x,y)=>color(((x-13)/80+(y-12)/80)/2),"diagonal normalized geometry");
    // This radial sample straddles the nonuniform .25 stop. A pixel's
    // integrated color must lie within its physical footprint, including the
    // stop itself; a point-only oracle incorrectly requires zero red.
    const r = await image.sample("path.gradient-radial",43,44), half=.5/(80*image.scale);
    const rx=Math.abs((r.x-13)/80-.25), ry=Math.abs((r.y-12)/80-.4);
    const low=2*Math.hypot(Math.max(rx-half,0),Math.max(ry-half,0)), high=2*Math.hypot(rx+half,ry+half);
    const footprint=[color(low),color(high)];
    if(low<=.25 && high>=.25) footprint.push(color(.25));
    assert(r.rgb.every((v,c)=>v>=Math.min(...footprint.map(p=>p[c]))-4 && v<=Math.max(...footprint.map(p=>p[c]))+4),
      `radial stop outside pixel footprint: ${r.rgb}, range ${low}..${high}`);
    await sample("path.gradient-radial",53,60,(x,y)=>color(2*Math.hypot((x-13)/80-.25,(y-12)/80-.4)),"radial absolute normalized center away from stop");
    await sample("path.gradient-alpha",23,52,x=>{const a=.5*((x-13)/80/.25);return [Math.round(bg[0]*(1-a)),Math.round(255*a+bg[1]*(1-a)),Math.round(bg[2]*(1-a))];},"transparent first stop and path opacity");
    await sample("path.gradient-alpha",53,52,x=>color((x-13)/80).map((v,c)=>Math.round(v*.5+bg[c]*.5)),"gradient brush opacity");
    near(await image.pixel("path.gradient-hole",53,52),bg,"gradient preserves evenodd hole");
    await sample("path.gradient-hole",23,52,x=>color((x-13)/80),"gradient hole contour body");
    await sample("path.gradient-clipped",23,52,x=>color((x-13)/80),"gradient clip inside");
    near(await image.pixel("path.gradient-clipped",55,52),bg,"gradient clip outside");
    await sample("path.gradient-curve",53,42,x=>color((x-13)/80),"quadratic gradient interior");
    near(await image.pixel("path.gradient-curve",53,12),bg,"quadratic excludes control polygon");
    near(await image.pixel("path.gradient-horizontal",5,52),bg,"offset geometry exterior");
  };
  await check("initial");
  assert((await resizeWindow(1150,850)).ok,"path gradient target resize failed");
  await check("resized");
});

test("Windows retained pixels match full repaint after text, alpha, movement and resize", async () => {
  await waitForServerReady(15000);
  assert((await resizeWindow(1150, 850)).ok, "retained fixture resize failed");
  assert((await clickTestId("gallery.retained")).ok, "retained fixture activation failed");
  await sleep(900);
  const initial = await stats();
  const snap = async (name: string) => {
    assert((await mouseMove((await tree()).rect.w-20, (await tree()).rect.h-20)).ok, "pointer parking failed");
    await sleep(150);
    const path = `${getSessionDir()}/retained-${name}.png`;
    assert((await screenshot(path)).ok, "retained capture failed");
    const png = decodePng(path);
    const node = (await query("retained.sample"))[0];
    assert(node, "retained sample missing");
    const scale = png.width / (await tree()).rect.w;
    const pixels: number[] = [];
    const x0 = Math.floor(node.rect.x * scale), y0 = Math.floor(node.rect.y * scale);
    const x1 = Math.ceil((node.rect.x + node.rect.w) * scale);
    const y1 = Math.ceil((node.rect.y + node.rect.h) * scale);
    assert(x0 >= 0 && y0 >= 0 && x1 <= png.width && y1 <= png.height, "sample outside capture");
    for (let y = y0; y < y1; y++) for (let x = x0; x < x1; x++) {
      const i = (y * png.width + x) * png.channels;
      pixels.push(png.pixels[i], png.pixels[i+1], png.pixels[i+2]);
    }
    return pixels;
  };
  const compare = (a: number[], b: number[], stage: string) => {
    assert(a.length === b.length, "sample dimensions changed between reference captures");
    let bad = 0, max = 0;
    for (let i = 0; i < a.length; i++) {
      const d = Math.abs(a[i] - b[i]);
      if (d > 3) bad++;
      max = Math.max(max, d);
    }
    console.log(`  ${stage}: channels=${a.length}, mismatches=${bad}, max_delta=${max}`);
    assert(bad === 0, `${stage}: retained pixels differ from full redraw (${bad} channels, max ${max})`);
  };
  let previous: number[] | undefined;
  const check = async (stage: string) => {
    const retained = await snap(`${stage}-cached`);
    if (stage.startsWith("mutation")) {
      assert(previous && previous.length === retained.length, "mutation baseline missing");
      const changed = retained.reduce((n, value, i) => n + (Math.abs(value - previous![i]) > 3 ? 1 : 0), 0);
      assert(changed > 100, `pixel mutation did not reach the screen (${changed} changed channels)`);
    }
    previous = retained;
    assert((await clickTestId("retained.full")).ok, "full repaint toggle failed");
    await waitFor(async () => (await query("retained.mode"))[0]?.text === "full" ? true : null, 3000, 30);
    const before = await stats();
    const full = await snap(`${stage}-full`);
    const after = await stats();
    assert(after.retained_hits === before.retained_hits && after.retained_misses === before.retained_misses &&
      after.retained_partial_repaints === before.retained_partial_repaints, "reference unexpectedly used retained rendering");
    compare(retained, full, stage);
    assert((await clickTestId("retained.enable")).ok, "retained toggle failed");
    await waitFor(async () => (await query("retained.mode"))[0]?.text === "retained" ? true : null, 3000, 30);
    compare(await snap(`${stage}-reused`), full, `${stage} reused`);
  };
  try {
    await check("long-text");
    for (let i = 0; i < 4; i++) {
      assert((await clickTestId("retained.change")).ok, "pixel mutation failed");
      await check(`mutation-${i}`);
    }
    assert((await resizeWindow(1000, 850)).ok, "retained resize failed");
    await check("resized");
    const final = await stats();
    console.log(`  retained: hits ${initial.retained_hits}->${final.retained_hits}, partial ${initial.retained_partial_repaints}->${final.retained_partial_repaints}`);
    assert(final.retained_hits > initial.retained_hits, "no real retained reuse observed");
    assert(final.retained_partial_repaints > initial.retained_partial_repaints, "no real partial repaint observed");
  } finally {
    await clickTestId("retained.enable");
    await clickTestId("modal.close");
    await sleep(400);
  }
});

test("Windows conic gradients preserve angle, linear premultiplied stops and native shape clips", async()=>{
  await waitForServerReady(15000);await resizeWindow(1100,1100);await clickTestId("gallery.gradients");
  // Gradients interpolate sRGB-encoded channels (docs/SRGB_BLENDING_PLAN.md):
  // a 0..1 channel ramp is 255 * t on screen.
  const encode = (v: number) => Math.round(255 * v);
  const angle=(x:number,y:number,start=0)=>{const v=(Math.atan2(y/100-.5,x/200-.5)-start)/(2*Math.PI)+.5;return v-Math.floor(v);};
  const rb=(t:number)=>[encode(1-t),0,encode(t)];
  const multi=(t:number)=>t<.25?[encode(1-t/.25),encode(t/.25),0]:[0,encode(1-(t-.25)/.75),encode((t-.25)/.75)];
  for(const stage of ["initial","resized"]){
    const image=await capture(`conic-${stage}`);
    for(const [x,y] of [[160,20],[160,80],[40,80],[40,20],[180,50]]){
      await nearSample(image,"gradient.conic",x,y,(px,py)=>rb(angle(px,py)),"conic normalized non-square quadrant");
      await nearSample(image,"gradient.conic-rounded",x,y,(px,py)=>rb(angle(px,py)),"conic rounded interior");
      await nearSample(image,"gradient.conic-legacy",x,y,(px,py)=>rb(angle(px,py,-Math.PI/2)),"legacy conic rotated start");
      await nearSample(image,"gradient.conic-angle",x,y,(px,py)=>multi(angle(px,py,Math.PI/2)),"conic angle and nonuniform multistop");
      await nearSample(image,"gradient.conic-alpha",x,y,(px,py)=>{const t=angle(px,py);return [Math.round(bg[0]*(1-t)),Math.round(bg[1]*(1-t)),Math.round(255*t+bg[2]*(1-t))];},"conic transparent red does not bleed");
    }
    near(await image.pixel("gradient.conic-rounded",1,1),bg,"conic independent rounded clip");
    near(await image.pixel("gradient.conic-single",1,1),bg,"conic ellipse corner clip");
    near(await image.pixel("gradient.conic-single",100,50),[0,255,255],"conic single stop");
    await resizeWindow(1150,1100);
  }
  await clickTestId("gallery.paths");
  const path=await capture("conic-path");
  const pathAngle=(x:number,y:number,start=0)=>{const v=(Math.atan2((y-12)/80-.4,(x-13)/80-.25)-start)/(2*Math.PI);return v-Math.floor(v);};
  for(const [x,y] of [[23,32],[73,32],[73,72],[23,72]]){
    await nearSample(path,"path.conic",x,y,(px,py)=>multi(pathAngle(px,py)),"path conic uses geometry bounds and custom center");
    await nearSample(path,"path.conic-angle",x,y,(px,py)=>multi(pathAngle(px,py,Math.PI/2)),"path conic start angle");
  }
  near(await path.pixel("path.conic-hole",53,52),bg,"conic evenodd hole");
  await nearSample(path,"path.conic-hole",23,52,(x,y)=>multi(pathAngle(x,y)),"conic hole contour body");
  await nearSample(path,"path.conic-alpha",73,32,(x,y)=>multi(pathAngle(x,y)).map((v,c)=>Math.round(v*.5+bg[c]*.5)),"conic path brush opacity");
  near(await path.pixel("path.conic",5,52),bg,"conic path geometry exterior");
});
test("Windows polygon masks preserve nonrectangular edges, fill rules, opacity, nested clips and resize", async () => {
  await waitForServerReady(15000);
  await resizeWindow(1100, 1100);
  assert((await clickTestId("gallery.paths")).ok, "polygon gallery activation failed");
  for (const stage of ["initial", "resized"]) {
    const image = await capture(`polygon-clips-${stage}`);
    near(await image.pixel("clip.triangle", 50, 35), [255,255,255], "triangle interior");
    near(await image.pixel("clip.triangle", 25, 65), bg, "triangle AABB corner excluded");
    near(await image.pixel("clip.triangle", 5, 35), bg, "offset polygon exterior");
    near(await image.pixel("clip.evenodd", 20, 50), [255,255,255], "evenodd ring");
    near(await image.pixel("clip.evenodd", 50, 50), bg, "evenodd hole");
    near(await image.pixel("clip.nonzero", 50, 50), [255,255,255], "same winding contours retain center");
    near(await image.pixel("clip.opacity", 20, 50), [138,148,158], "polygon mask inside opacity composite");
    near(await image.pixel("clip.opacity", 50, 50), bg, "opacity composite preserves hole");
    near(await image.pixel("clip.nested", 40, 35), [255,255,255], "nested rectangle and polygon intersection");
    near(await image.pixel("clip.nested", 60, 35), bg, "nested rectangle excludes polygon interior");
    near(await image.pixel("clip.nested", 25, 65), bg, "polygon excludes nested rectangle interior");
    await resizeWindow(1150, 1100);
  }
});

test("Windows procedural noise preserves local value fields, seed, scale, alpha, clips and changing physical grain",async()=>{
  await waitForServerReady(15000);await resizeWindow(1100,1000);await clickTestId("gallery.noise");
  const wang=(n:number)=>{n=((n^61)^(n>>>16))>>>0;n=(n+(n<<3))>>>0;n=(n^(n>>>4))>>>0;n=Math.imul(n,0x27d4eb2d)>>>0;return (n^(n>>>15))>>>0;};
  const hash=(x:number,y:number)=>wang(((Math.abs(x)*1000)>>>0)^wang(Math.imul((Math.abs(y)*1000)>>>0,2654435761)))/4294967295;
  const value=(x:number,y:number,scale=8,seed=0)=>{
    const sx=x/scale+Math.fround(seed*Math.fround(17.3)),sy=y/scale+Math.fround(seed*Math.fround(31.7)),ix=Math.floor(sx),iy=Math.floor(sy),fx=sx-ix,fy=sy-iy;
    const ux=fx*fx*(3-2*fx),uy=fy*fy*(3-2*fy),mix=(a:number,b:number,t:number)=>a+(b-a)*t;
    return mix(mix(hash(ix,iy),hash(ix+1,iy),ux),mix(hash(ix,iy+1),hash(ix+1,iy+1),ux),uy)-.5;
  };
  // Noise is added to the sRGB-encoded fill (the SDF shader's fill + n * intensity).
  const color=(x:number,y:number,scale=8,seed=0,base=[128,128,128])=>base.map(v=>Math.round(255*Math.max(0,Math.min(1,v/255+value(x,y,scale,seed)*.6))));
  const a=await capture("noise-initial");
  // The shader samples the value field at the physical pixel centre relative
  // to the node's (possibly fractional) rect, so the expected colour is taken
  // at the centre `sample` reports, not at a guessed sub-pixel offset: at 100%
  // DPI a panel at y=221.5 is sampled at local y=dy, not dy+.25.
  const at=async(id:string,x:number,y:number)=>{const s=await a.sample(id,x,y);return {rgb:s.rgb,x:s.x-80,y:s.y-48};};
  for(const [x,y] of [[20,30],[43,27],[80,48],[120,70]]){
    const v=await at("noise.value",x,y);
    near(v.rgb,color(v.x,v.y),"logical centered Wang/Hermite value field");
    near(await a.pixel("noise.value-copy",x,y),v.rgb,"value pattern independent of absolute node position",1);
    const seed=await at("noise.seed",x,y);
    near(seed.rgb,color(seed.x,seed.y,8,31),"instance seed changes lattice");
    const scaled=await at("noise.scale",x,y);
    near(scaled.rgb,color(scaled.x,scaled.y,16),"logical lattice spacing");
    const rounded=await at("noise.rounded",x,y);
    near(rounded.rgb,color(rounded.x,rounded.y),"rounded interior value field");
    near(await a.pixel("noise.disabled",x,y),[128,128,128],"disabled mode retains base fill");
    const alpha=128/255,translucent=await at("noise.alpha",x,y);
    near(translucent.rgb,color(translucent.x,translucent.y,8,0,[32,96,160]).map((v,c)=>Math.round(v*alpha+bg[c]*(1-alpha))),"noise changes linear RGB without changing alpha");
  }
  near(await a.pixel("noise.rounded",1,1),bg,"independent noise rounded corner");
  near(await a.pixel("noise.transparent",80,48),bg,"noise cannot create alpha from transparent fill");
  const rotated=await at("noise.rotated",100,48);
  near(rotated.rgb,color(rotated.y,-rotated.x),"rotated local coordinates through offscreen composite");
  const region=async(stage:string,id:string)=>{
    const png=decodePng(`${getSessionDir()}/windows-images-${stage}.png`),scale=png.width/(await tree()).rect.w,node=(await query(id))[0];
    const values:number[]=[];for(let y=0;y<64;y++)for(let x=0;x<64;x++){const px=Math.floor((node.rect.x+60)*scale)+x,py=Math.floor((node.rect.y+30)*scale)+y;assert(px>=0&&py>=0&&px<png.width&&py<png.height,"noise region outside capture");values.push(png.pixels[(py*png.width+px)*png.channels]);}return values;
  };
  const grain=await region("noise-initial","noise.film"),smooth=await region("noise-initial","noise.value");
  const rough=(v:number[])=>{let sum=0;for(let y=0;y<64;y++)for(let x=0;x<63;x++)sum+=Math.abs(v[y*64+x]-v[y*64+x+1]);return sum/(64*63);};
  assert(rough(grain)>35&&rough(smooth)<12,`grain must vary per physical pixel: grain=${rough(grain)}, value=${rough(smooth)}`);
  // Film grain is reseeded per encoded frame and a visible grain asks for the
  // next frame itself (the renderer's paint-table scan), so a static scene
  // keeps rendering and the presented grain changes without any input.
  // The shader uses an 8-bit frame seed: patterns repeat every 256 frames.
  // The earlier capture precedes dozens of pixel-query RPCs, so comparing it
  // here can sample the same phase of that cycle even while grain animates.
  // Take a fresh baseline and prove both captures fit inside one seed period.
  const animationStart=(await stats()).frame_count;
  await capture("noise-animation-baseline");
  const animatedGrain=await region("noise-animation-baseline","noise.film");
  const opacity=await region("noise-animation-baseline","noise.film-opacity");
  const grainBefore=(await stats()).frame_count;
  // Check autonomous progress rather than a minimum frame rate: Debug builds
  // under x64 emulation can take longer than 300 ms to encode one frame.
  await waitFor(async()=>(await stats()).frame_count>=grainBefore+3?true:null,10000,50);
  const grainAfter=(await stats()).frame_count;
  assert(grainAfter-grainBefore>=3,`film grain did not drive frames by itself: ${grainBefore} -> ${grainAfter}`);
  await capture("noise-next-frame");
  const animationEnd=(await stats()).frame_count;
  assert(animationEnd-animationStart<256,`noise capture interval aliases the 256-frame seed period: ${animationStart}->${animationEnd}`);
  const next=await region("noise-next-frame","noise.film"),stable=await region("noise-next-frame","noise.value"),opacityNext=await region("noise-next-frame","noise.film-opacity");
  const changed=(x:number[],y:number[])=>x.reduce((n,v,i)=>n+(Math.abs(v-y[i])>5?1:0),0)/x.length;
  console.log(`  noise frame progress=${grainBefore}->${grainAfter}, film changed=${changed(animatedGrain,next).toFixed(3)}, opacity film changed=${changed(opacity,opacityNext).toFixed(3)}`);
  assert(changed(animatedGrain,next)>.6&&changed(opacity,opacityNext)>.6,"film grain or nested opacity grain froze between rendered frames");
  assert(changed(smooth,stable)===0,"value noise changed between frames");
  console.log(`  noise: physical roughness=${rough(grain).toFixed(2)}, logical roughness=${rough(smooth).toFixed(2)}, film changed=${changed(animatedGrain,next).toFixed(3)}, opacity film changed=${changed(opacity,opacityNext).toFixed(3)}`);
  // Retained hits count per rendered frame: render frames between the two
  // captures (a static scene renders none), with the tree marked dirty so
  // the group's content is re-emitted and must still hit its retained surface.
  const renderFrames=async(n:number)=>{
    const start=(await stats()).frame_count;
    const redraw=await request("POST","/redraw",{continuous:true});
    assert(!(redraw as any).error,`continuous redraw unsupported: ${JSON.stringify(redraw)}`);
    try{await waitFor(async()=>(await stats()).frame_count>=start+n?true:null,10000,50);}
    finally{await request("POST","/redraw",{continuous:false});}
  };
  await clickTestId("noise.cache");await renderFrames(2);await capture("noise-cache-a");const before=await stats();
  await renderFrames(3);await capture("noise-cache-b");const after=await stats();
  const cachedFilmA=await region("noise-cache-a","noise.film"),cachedFilmB=await region("noise-cache-b","noise.film"),cachedValueA=await region("noise-cache-a","noise.value-copy"),cachedValueB=await region("noise-cache-b","noise.value-copy");
  assert(after.retained_hits>before.retained_hits,"static value group did not reuse a retained surface");
  assert(changed(cachedFilmA,cachedFilmB)>.6,"opaque composited film grain reused stale retained pixels");
  assert(changed(cachedValueA,cachedValueB)===0,"retained value noise changed");
  console.log(`  noise retained: hits ${before.retained_hits}->${after.retained_hits}, film changed=${changed(cachedFilmA,cachedFilmB).toFixed(3)}`);
});


test("Windows flat glass transmits colored linear light according to slab thickness", async () => {
  await waitForServerReady(15000);
  assert((await resizeWindow(1200,850)).ok,"glass resize failed");
  assert((await clickTestId("gallery.glass")).ok,"glass activation failed");
  // Independent CPU oracle of the shader's Beer-Lambert transmission
  // (glass.metal): T_ref = mix(1, linear(tint), alpha * .6) at the 8px
  // reference, absorption T_ref^(d/8) applied to the linear backdrop. Flat
  // top/bottom surfaces add no bezel thickness; d is at least .5.
  const encode = srgbEnc;
  const expected = (thickness: number, _scale: number, alpha=1, light=1) => {
    const d=Math.max(thickness,.5);
    return [1,0,128/255].map(c => encode(Math.min(1,light)*Math.max(.02,Math.max(.05,1+(srgbLin(c)-1)*alpha*.60)**(d/8))));
  };
  const verify = async(stage: string) => {
    const image = await capture(stage);
    near(await image.pixel("glass.tint",50,50),expected(8,image.scale),"8px center plus geometric transmission");
    near(await image.pixel("glass.thin",50,50),expected(4,image.scale),"thin slab absorption");
    near(await image.pixel("glass.thick",50,50),expected(16,image.scale),"thick slab absorption");
    near(await image.pixel("glass.alpha",50,50),expected(8,image.scale,128/255),"partial tint density");
    near(await image.pixel("glass.zero-thickness",50,50),expected(0,image.scale),"zero center thickness keeps the minimum slab");
    near(await image.pixel("glass.transparent",50,50),[255,255,255],"zero-alpha tint neutral");
    near(await image.pixel("glass.white",50,50),[255,255,255],"white tint neutral");
    near(await image.pixel("glass.rounded",50,50),expected(8,image.scale),"rounded slab center");
    near(await image.pixel("glass.rounded",2,2),[255,255,255],"rounded coverage unchanged");
    near(await image.pixel("glass.color",50,50),expected(8,image.scale,1,.2126*.5),"saturation/brightness precede transmission");
    near(await image.pixel("glass.overbright",50,50),expected(8,image.scale),"linear input clamps before absorption");
  };
  await verify("glass-transmission");
  assert((await resizeWindow(1150,800)).ok,"glass second resize failed");
  await verify("glass-transmission-resized");
});

test("Windows SVG icon masks preserve rounded rotation, group alpha and nested clips", async () => {
  await waitForServerReady(15000);
  await clickTestId("gallery.icons");
  // Two native client widths; pixel sampling uses each actual capture scale.
  for (const width of [1100, 980]) {
    assert((await resizeWindow(width, 800)).ok, "resize failed");
    const image = await capture(`svg-mask-${width}`);
    near(await image.pixel("icon.square", 2, 2), [255,255,255], "unclipped control corner");
    near(await image.pixel("icon.rounded", 2, 2), bg, "SVG corner clipped");
    near(await image.pixel("icon.rounded", 40, 50), [255,255,255], "SVG center retained");
    near(await image.pixel("icon.rounded", 40, 3), [255,255,255], "SVG top straight edge retained");
    // Rotate pre-mask samples around the rectangular icon center.
    const c = Math.cos(Math.PI/6), s = Math.sin(Math.PI/6);
    const point = (x: number,y: number) => [40+(x-40)*c-(y-50)*s,50+(x-40)*s+(y-50)*c];
    for (const [x,y,color,label] of [[2,2,bg,"rotated clipped corner"],[40,50,[255,255,255],"rotated center"],[40,3,[255,255,255],"rotated straight edge"]] as const) {
      const p = point(x,y);
      near(await image.pixel("icon.rotated",p[0],p[1]), [...color], label);
    }
    for (let y = 8; y <= 92; y += 12) for (let x = 8; x <= 72; x += 8) {
      const qx = Math.abs(x-40)-8, qy = Math.abs(y-50)-18;
      const distance = Math.min(Math.max(qx,qy),0)+Math.hypot(Math.max(qx,0),Math.max(qy,0))-32;
      if (Math.abs(distance) <= 3) continue; // Exclude antialiasing coverage, not missing pixels.
      const color = distance < 0 ? [255,255,255] : bg;
      near(await image.pixel("icon.rounded",x,y),color,`rounded mask oracle ${x},${y}`);
      const p = point(x,y);
      near(await image.pixel("icon.rotated",p[0],p[1]),color,`rotated mask oracle ${x},${y}`);
    }
    for (const x of [10,40,70]) {
      near(await image.pixel("icon.opacity",x,50), [138,148,158], "overlapping shapes get opacity once");
      near(await image.pixel("icon.tint-alpha",x,50), [79,94,109], "tint alpha and opacity multiply once");
    }
    near(await image.pixel("icon.nested",40,50),[79,94,109],"nested parent and icon opacity");
    near(await image.pixel("icon.nested",65,50),bg,"parent clip rejects child");
    near(await image.pixel("icon.nested",2,2),bg,"nested icon rounded corner");
  }
});

test("Windows native menu commands reach App ActionDispatcher and rendered state without manual SDK pumping", async () => {
  await waitForServerReady(15000);
  assert((await resizeWindow(1100,850)).ok, "live menu fixture resize failed");
  await clickTestId("gallery.menu-status");
  const expected = async (old: number, fresh: number) => {
    const text = `old=${old} new=${fresh} disabled=0`;
    await waitFor(async () => (await query("menu.live.status"))[0]?.text === text ? true : null, 5000, 50);
    assert((await query("menu.live.status"))[0]?.text === text, `missing app action: ${text}`);
  };
  await expected(0,0);
  await clickTestId("menu.live.fire"); await expected(1,0);
  await clickTestId("menu.live.shortcut"); await expected(2,0);
  await clickTestId("menu.live.disabled"); await sleep(200); await expected(2,0);
  await clickTestId("menu.live.replace"); await sleep(200); await expected(2,0);
  await clickTestId("menu.live.new"); await expected(2,1);
  const image = await capture("menu-live-action");
  let ink = 0;
  for(let y=2;y<20;y+=2) for(let x=2;x<210;x+=2) {
    const pixel = await image.pixel("menu.live.status",x,y);
    if(pixel.every(channel => channel > 180)) ink++;
  }
  assert(ink > 50, `menu action state did not produce visible text: ${ink}`);
  await clickTestId("menu.live.clear"); await sleep(200); await expected(2,1);
  for(const id of ["menu.live.fire", "menu.live.shortcut", "menu.live.disabled", "menu.live.new"]) {
    assert((await clickTestId(id)).ok, `cleared-menu control failed: ${id}`);
  }
  await sleep(200); await expected(2,1);
});

run();

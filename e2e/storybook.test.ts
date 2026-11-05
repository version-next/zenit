/// storybook.test.ts: all registered Storybook scenes e2e with visual (screenshot) + log data dual verification.
///
/// Each component: clickTestId switch -> collect story subtree all text -> assert all expected data
/// values appear (log verification proves rendered, not empty panel) -> screenshot to session dir
/// (visual verification, non-empty + manual/baseline review). Interactive components add state
/// assertions + screenshot after interaction.
import {
  stats,
  health,
  focused,
  query,
  tree,
  clickTestId,
  clickAt,
  mouseDown,
  mouseMove,
  mouseUp,
  pointerLeave,
  setWindowActive,
  key,
  screenPos,
  startFrameObservation,
  readFrameObservation,
  captureFrameAt,
  screenshot as captureScreenshot,
  waitForServerReady,
  waitFor,
  sleep,
  type_,
  inputState,
  imePreedit,
  imeCommit,
  scrollAt,
  trackpadScroll,
  magnifyAt,
  dragAt,
  resizeWindow,
  resetTiming,
  getE2eTimeoutMs,
  request,
} from "./client";
import { test, run, assert, getSessionDir, appendLog, currentTestOrdinal } from "./runner";
import { statSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { decodePng as decodePngFile, countDarkPixels, countNonBackgroundPixels } from "./png";

/// Pixel-level verification: rect region must have enough dark pixels (text/graphics really drawn).
/// Prevent 'layout OK but GPU blank' bugs (Modal empty panel missed 49/49 on settle). Light
/// graphics use custom: assert region not pure background.
///
/// assertRegionHasInk countDarkPixels uses near-black (lum < 100), fails for spinner thin
/// circles/skeleton light; normal render spinner 24 dark pixels, skeleton 0; dark criterion
/// mispredicts success as blank. Ink/coverage minimums calibrated on 2x Retina, scale by area for
/// other DPIs; at 1x text stroke is one pixel wide.
function minAtScale(calibrated: number, scale: number): number {
  return Math.max(1, Math.round(calibrated * (scale / 2) ** 2));
}

function assertRegionNotBlank(pngPath: string, rect: { x: number; y: number; w: number; h: number }, label: string, calibratedMin = 200): void {
  const png = decodePng(pngPath);
  const scale = captureScale(pngPath, png.width);
  const minPixels = minAtScale(calibratedMin, scale);
  const n = countNonBackgroundPixels(png, rect, scale);
  appendLog(`  ${label}: non_bg_pixels=${n} (min=${minPixels})`);
  assert(n >= minPixels, `${label} 区域是一片纯背景（non_bg=${n} < ${minPixels}）— 图形没画出来`);
}

function assertRegionHasInk(pngPath: string, rect: { x: number; y: number; w: number; h: number }, label: string, calibratedMin = 200): void {
  const png = decodePng(pngPath);
  const scale = captureScale(pngPath, png.width);
  const minDark = minAtScale(calibratedMin, scale);
  const dark = countDarkPixels(png, rect, scale);
  appendLog(`  ${label}: dark_pixels=${dark} (min=${minDark})`);
  assert(dark >= minDark, `${label} 区域像素级空白（dark=${dark} < ${minDark}）— 内容没画出来`);
}

const DIR = getSessionDir();
const decodedCapturePaths = new WeakMap<ReturnType<typeof decodePngFile>, string>();
function decodePng(path: string): ReturnType<typeof decodePngFile> {
  const image = decodePngFile(path);
  decodedCapturePaths.set(image, path);
  return image;
}
function decodedCaptureScale(image: ReturnType<typeof decodePngFile>): number {
  const path = decodedCapturePaths.get(image);
  assert(path != null, "missing decoded capture path");
  return captureScale(path!, image.width);
}

const captureWidths = new Map<string, number>();
async function screenshot(path: string) {
  const width = (await tree()).rect.w;
  assert(width > 0, "missing native client width");
  const result = await captureScreenshot(path);
  assert(result.ok === true, `screenshot failed: ${path}`);
  captureWidths.set(path, width);
  return result;
}
function captureScale(path: string, pixelWidth: number): number {
  const width = captureWidths.get(path);
  assert(width != null && width > 0, `missing capture dimensions: ${path}`);
  return pixelWidth / width;
}

/// read average RGB of rect center pixel (3x3 mean removes antialiasing noise)
function centerPixel(pngPath: string, rect: { x: number; y: number; w: number; h: number }): [number, number, number] {
  const png = decodePng(pngPath);
  const scale = captureScale(pngPath, png.width);
  const cx = Math.round((rect.x + rect.w / 2) * scale);
  const cy = Math.round((rect.y + rect.h / 2) * scale);
  let r = 0, g = 0, b = 0, n = 0;
  for (let dy = -1; dy <= 1; dy++) {
    for (let dx = -1; dx <= 1; dx++) {
      const i = ((cy + dy) * png.width + (cx + dx)) * png.channels;
      r += png.pixels[i]; g += png.pixels[i + 1]; b += png.pixels[i + 2]; n++;
    }
  }
  return [Math.round(r / n), Math.round(g / n), Math.round(b / n)];
}

/// scan rect for darkest (R+G+B min) pixel. For text strokes; text center often falls between
/// letters on background, center sampling gets background not glyph.
function meanRgbOf(png: ReturnType<typeof decodePng>, rect: { x: number; y: number; w: number; h: number }, scale: number): number[] {
  const x0 = Math.round(rect.x * scale), y0 = Math.round(rect.y * scale), x1 = Math.round((rect.x + rect.w) * scale), y1 = Math.round((rect.y + rect.h) * scale);
  let r = 0, g = 0, b = 0, n = 0;
  for (let y = y0; y < y1; y++) for (let x = x0; x < x1; x++) { const i = (y * png.width + x) * png.channels; r += png.pixels[i]; g += png.pixels[i + 1]; b += png.pixels[i + 2]; n++; }
  return n ? [r / n, g / n, b / n] : [0, 0, 0];
}

function darkestPixel(pngPath: string, rect: { x: number; y: number; w: number; h: number }): [number, number, number] {
  const png = decodePng(pngPath);
  const scale = captureScale(pngPath, png.width);
  const x0 = Math.max(0, Math.round(rect.x * scale));
  const y0 = Math.max(0, Math.round(rect.y * scale));
  const x1 = Math.min(png.width, Math.round((rect.x + rect.w) * scale));
  const y1 = Math.min(png.height, Math.round((rect.y + rect.h) * scale));
  assert(x1 > x0 && y1 > y0, "pixel sample region outside capture");
  let best: [number, number, number] = [255, 255, 255];
  let bestSum = 766;
  for (let y = y0; y < y1; y++) {
    for (let x = x0; x < x1; x++) {
      const i = (y * png.width + x) * png.channels;
      const r = png.pixels[i], g = png.pixels[i + 1], b = png.pixels[i + 2];
      const sum = r + g + b;
      if (sum < bestSum) { bestSum = sum; best = [r, g, b]; }
    }
  }
  return best;
}

/// count column distribution of inked pixels in rect. For RTL verification: reversed overlapping
/// glyphs squeeze ink narrow, correct layout spans most node width. Returns
/// {first,last,span,cols,width}, all relative logical columns.
function inkColumns(
  pngPath: string,
  rect: { x: number; y: number; w: number; h: number },
  threshold = 160,
): { first: number; last: number; span: number; cols: number; width: number } {
  const png = decodePng(pngPath);
  const scale = captureScale(pngPath, png.width);
  const x0 = Math.max(0, Math.round(rect.x * scale));
  const y0 = Math.max(0, Math.round(rect.y * scale));
  const x1 = Math.min(png.width, Math.round((rect.x + rect.w) * scale));
  const y1 = Math.min(png.height, Math.round((rect.y + rect.h) * scale));
  let first = -1, last = -1, cols = 0;
  const mass: number[] = [];
  for (let x = x0; x < x1; x++) {
    let inked = false;
    let m = 0;
    for (let y = y0; y < y1; y++) {
      const i = (y * png.width + x) * png.channels;
      // dark strokes (text color pure black) on light background.
      if (png.pixels[i] < threshold && png.pixels[i + 1] < threshold && png.pixels[i + 2] < threshold) {
        inked = true;
        m += threshold - png.pixels[i];
      }
    }
    mass.push(m);
    if (inked) {
      if (first < 0) first = x - x0;
      last = x - x0;
      cols++;
    }
  }
  // ink centroid normalized to 0..1 within span. 1=ink right. Glyph-order fingerprint: same text
  // forward/reverse mirror ink, centroid flips. Span/density miss 'reversed but uniform'; centroid
  // catches it, true RTL cut-per-codepoint failure mode.
  let total = 0, acc = 0;
  for (let i = 0; i < mass.length; i++) { total += mass[i]; acc += mass[i] * i; }
  const centroid = total > 0 && last > first ? (acc / total - first) / (last - first) : 0.5;
  return { first, last, span: last - first + 1, cols, width: x1 - x0, centroid };
}

function assertColorNear(actual: [number, number, number], expected: [number, number, number], label: string, tol = 12): void {
  const d = Math.max(Math.abs(actual[0] - expected[0]), Math.abs(actual[1] - expected[1]), Math.abs(actual[2] - expected[2]));
  appendLog(`  ${label}: rgb=(${actual.join(",")}) expect=(${expected.join(",")}) maxdiff=${d}`);
  assert(d <= tol, `${label} 颜色不符: 实际(${actual.join(",")}) 期望(${expected.join(",")}) 容差${tol}`);
}

// expected data values (text) appearing in component story. Prove component actually rendered (not
// empty). One-to-one with stories.zig values.
const EXPECT: Record<string, string[]> = {
  controls: ["01 / CONTROLS", "Controls", "Sizes", "Variants × states", "Composition", "Selection controls", "Keyboard focus", "Add item", "Mixed"],
  button: ["Primary", "Secondary", "Ghost", "Danger", "Link", "Download", "Saving…", "Loading", "Normal", "Disabled", "Block primary"],
  checkbox: ["Unchecked", "Checked", "Indeterminate", "Disabled", "changed"],
  switch: ["Off", "On", "Disabled"],
  radio: ["Selected", "Unselected", "Option X", "Option Y", "Option Z"],
  slider: ["40.0", "5.0"],
  rate: ["value 3 / 5", "readonly value 4", "count 10, value 7", "Sizes"],
  stepper: ["0–10, step 1", "5", "step 0.25, clamped to 0–1", "0.25", "At the maximum", "10", "Disabled", "3"],
  group: ["Horizontal button group", "Day", "Week", "Month", "Year", "Copy", "Top", "Middle", "Bottom"],
  input: ["Types", "Name", "Email", "Password", "Your name", "you@example.com", "Sizes", "Search", "Required", "With helper", "3–20 characters", "With error", "This field is invalid", "Readonly", "Read only value", "Disabled"],
  textarea: ["Notes", "With helper", "Max 500 characters", "With error", "Please write more", "Disabled"],
  editabletext: ["Quarterly roadmap", "title → Quarterly roadmap"],
  select: ["Select", "With icon", "Clearable", "Searchable", "Multiple · LG", "Multiple searchable · XS", "Option 1"],
  combobox: ["Fruit", "Type to search fruit"],
  tags: ["Zig", "UI", "Add tag…", "Return or a trailing comma commits a tag."],
  upload: ["Attachment", "Choose file…", "design-system.pdf"],
  datetimepicker: ["Oct 16, 2026 14:30:00"],
  datepicker: ["Pick a date"],
  daterange: ["Start date", "End date"],
  form: ["Name", "Email", "Submit", "Full name", "(not submitted)"],
  formcompose: ["Filter toolbar · same size", "Search orders…", "Status", "Owner", "Reset", "Apply filters", "New order", "Region", "Normal", "USD", "Create order"],
  badge: ["info", "success", "warning", "error", "Online", "Error", "Sizes"],
  tag: ["neutral", "accent", "success", "warning", "danger", "info", "Sizes", "Small", "Medium", "Default", "Outline", "Closable"],
  chip: ["Variants", "Default", "Active", "Outline", "Disabled", "Closable", "Sizes", "With icon", "Starred", "Folder"],
  card: ["Variants", "Default", "Outlined", "Elevated", "Card with body", "Body content goes here.", "States", "Selected", "Hoverable", "Interactive", "No padding"],
  alert: ["A new version is ready", "Update when you’re ready. Your workspace will be restored.", "All changes saved", "Your project is up to date across your devices.", "You’re working offline", "Changes stay on this device until you reconnect.", "We couldn’t save your changes", "Your edits are safe. Check your connection and try again.", "Title-less alert with just a message."],
  progress: ["25", "60", "100", "Heights", "Error", "indeterminate"],
  spinner: [], // pure graphics no text - only verify panel mount + screenshot
  skeleton: [], // pure placeholder graphics no text
  timeline: ["Created", "Order placed", "09:00", "Shipped", "In transit", "Delivered", "Pending"],
  table: ["Name", "Role", "Age", "Alice", "Admin", "Bob", "Carol", "Dave", "Editor", "Heidi", "41"],
  datatable: ["Name", "Role", "City", "Alice", "Berlin", "Carol", "Page 1 / 3", "Prev", "Next"],
  tree: ["src", "main.zig", "root.zig", "README.md"],
  calendar: ["2026", "31"],
  markdown: ["Markdown", "bold", "italic", "bullet one", "bullet two"],
  icons: ["activity", "check", "heart", "calendar", "Sizes & tints"],
  tabs: ["underline", "pill", "tab", "Overview", "Details", "Settings", "Disabled", "Sizes", "One", "Two", "Three"],
  accordion: ["Section One", "Section Two", "Section Three", "Panel body content."],
  menu: ["Actions", "Recent", "Open another file"], // item in closed popover, verify after opening interaction test below
  breadcrumb: ["Home", "Library", "Data"],
  steps: ["Horizontal", "Account", "Create account", "Profile", "Fill details", "Done", "Finish", "Vertical"],
  notification: ["九种类型 Nine kinds", "成功 Success", "撤销 Undo", "堆叠 Stack", "连发 4 条", "八个停靠位置 Positions", "上左", "左中"],
  tooltip: ["Top", "Bottom", "Left", "Right"],
  popover: ["Toggle Popover", "Positions", "Hover me"],
  modal: ["Open Modal"],
  sheet: ["Open Sheet"],
  zindex: ["Sibling z-index", "Overflow container", "Pop", "Tip", "Open Nested Modal"],
  divider: ["Styles", "Labeled", "LEFT", "OR", "RIGHT", "Vertical", "Left", "Middle", "Right"],
  stack: ["HStack gap=8", "VStack gap=8", "One", "Two", "Three"],
  layoutbox: ["Coverage matrix", "Padding-box anatomy", "content 624 × 132", "Percentage inset", "Flex vs Grid", "Sizing modes", "Overflow clipping"],
  virtuallist: ["Row 0", "Row 1"],
  virtuallistdynamic: ["#0", "#1"],
  scrolling: ["Vertical · wheel / trackpad", "Horizontal · sideways scroll", "Inner list"],
  scrollarea: ["Scrollable line 0", "Scrollable line 1"],
  grid: ["0,0", "0,1", "1,0"],
  glassbox: ["Toolbar", "Tab bar", "Continue", "Regular", "Interactive", "hover / press me", "Clear", "Backdrop shows through.", "Identity", "Drag me"],
  glasslab: ["Drag me", "Companion", "Glass variant", "Container spacing"],
  glasscontrols: [], // Slider/toggle geometry: verify stage pixels below.
  glasscontrolsios: ["iOS slider & switch"],
  glasstoolbar: ["last: (none)", "view: 0", "dark view: 0"],
  glassiosbars: ["iOS bars (idiom .ios)"],
  glasspopover: ["Menu: appears at once"],
  glasschrome: ["Scroll +90", "Scroll −90", "Ship v1.0", "Board"],
  glassmotion: ["Morph", "Floating glass toolbar", "Scroll +80", "Materialize", "Toggle glass"],
  glasssplit: ["Split toolbar", "Expand card", "Toolbar expands", "Card collapses"],
  glassunion: [], // ink: INK_TARGET
  glassadapt: ["bar: light", "panel: light"],
  glassconcentric: [], // Nested glass scene: verify stage pixels below.
  glassextension: [], // Striped extension scene: verify stage pixels below.
  canvasevents: ["scroll (none)", "magnify (none)", "drag (none)", "clip (none)", "Clipboard PNG roundtrip"],
  drag: ["state: idle", "clicks: 0", "width: 240px", "Horizontal resize"],
  // 2026-08-16 core review regression-anchor story (numbers change with interaction, assert stable
  // prefix only)
  multiclick: ["single:", "double:", "triple:", "long:", "click / double-click / hold"],
  animctl: ["Play yoyo", "Play timeline", "Reverse timeline", "KF reset", "KF +1s", "yoyo: state=", "tl: state=", "kf: loops=", "spring: ticks="],
  vectorpath: ["Bursts 40-pt", "triangles mode"],
  blend: ["multiply", "screen", "difference", "normal control"],
  emoji: ["red square", "green square", "blue square", "grayscale control", "mixed run"],
  rtl: [
    "numbers + RTL",
    "mirrored punctuation",
    "Arabic tashkeel",
    "URL / email",
    "wrapped editable RTL",
  ],
  wordnav: ["Mixed-script sample", "привет", "αβγ", "Expected Alt+Right stops"],
  viewdsl: ["Declarative todo", "Add todo", "Clear done", "Write the view DSL", "Anchor control-flow regions", "Cross-review with GLM", "0 of 3 done"],
  wall: ["Actions", "Deploy", "Search components…", "Asia Pacific", "Sync over iCloud", "September 2026", "Aurora", "Build succeeded", "select.zig", "What is a retained tree?"],
  glassgroup: ["Back", "Share"],
  glassmerge: [], // (its note is outside the panel: WidgetSpec.note) ink: INK_TARGET
  glasstint: ["Same cases over gray 128", "Overlapping tints"],
  glassislands: ["Island first", "Island second", "content below the slab"],
  glassappkit: ["NSGlassEffectView parity"],
  glassidiom: ["GlassIdiom: row 1 macOS, row 2 iOS"],
  glassioslens: ["iOS tab bar lens fixtures", "Home", "Library", "Radio"],
  blendlab: ["Liquid Glass Hamburgefonstiv 0123"],
  glassedge: [], // the scene is in the window portal; ink: INK_TARGET
  popoverregress: ["Tall Popover"],
  cornerclip: ["Per-corner overflow clip", "Attached group", "Shader clip", "Opacity fold", "Clip surface (glass)", "Clip layer (nested in a rounded clip)", "Half turn", "Half turn, opacity fold", "Mirrored", "Nested: uniform 20 > TR 10", "Nested x3: TL / TR / BR", "Crossing: uniform 20 > 70 wide, TR 12", "Crossing x3: TL 20 > TR 16 > BL 12", "Nested x3, opacity fold", "Oversized TL, direct", "Oversized TL, opacity fold", "Oversized TL, blend composite", "Oversized TL, clip layer"],
  paintreplay: ["Add row", "Remove row", "alpha", "beta", "Rounded card with clipped children", "translucent pill"],
  heavytext: ["Heavy text overflow", "glyph00"],
  textanimjitter: ["Rotate 360", "Opacity: fading in and out, steadily"],
  cleanup: ["Toggle child", "cleanups: 0", "cleanup child mounted"],
  // assert only provider-neutral system icon contract; Storybook independent of vendor naming.
  interactionlifecycle: ["Settled focus destination", "Click removes this target", "Path hit area: left 80 px only"],
  teardownstress: ["Reactive teardown ordering", "grid mounted", "Run 10 cycles"],
  secsvg: ["Malformed SVG corpus", "close operand — rejected safely", "non-finite arc — rejected safely", "valid control rendered"],
  secopacity: ["10 nested composited opacity groups", "DEPTH 10 VISIBLE", "AFTER STACK MUST BE VISIBLE"],
  sectext: ["65,536-space editable run", "bytes: 65546", "Select all and replace with x"],
};

const KEYS = Object.keys(EXPECT);

// recursively collect all text fields in subtree.
function collectText(node: any, out: string[]): void {
  // display:none subtree (harness marked hidden) doesn't render, its text doesn't count as
  // 'visible'.
  if (node?.hidden) return;
  if (node?.text) out.push(node.text);
  for (const c of node?.children ?? []) collectText(c, out);
}

/// find node by text in subtree, return its rect.
///
/// Most components lack per-item test_id (Tabs/Accordion exceptions); coordinate hardcoding is
/// fragile and opaque. Text-based location is stable for 'click Nth item' interactions.
function findByText(node: any, text: string): { x: number; y: number; w: number; h: number } | null {
  if (node?.text === text && node.rect) return node.rect;
  for (const c of node?.children ?? []) {
    const hit = findByText(c, text);
    if (hit) return hit;
  }
  return null;
}

async function clickText(rootTestId: string, text: string): Promise<void> {
  const root = (await query(rootTestId))[0];
  assert(root != null, `${rootTestId} 节点不存在`);
  const r = findByText(root, text);
  assert(r != null, `${rootTestId} 子树里找不到文本 "${text}"`);
  await clickAt(r!.x + r!.w / 2, r!.y + r!.h / 2);
}

/// EXPECT empty AND animated components: single-frame ink invalid (screenshot timing sets rotation
/// angle, ink varies, spinner 165-1032). Change to 'it really animates': screenshot two frames
/// interval-apart, region pixels must differ.
///
/// Also better reflects component value; spinner's meaning is rotation.
const ANIMATED_INK = new Map<string, string>([["spinner", "story.spinner.row"]]);

async function assertAnimates(key: string, targetId: string): Promise<void> {
  const box = (await query(targetId))[0];
  assert(box != null, `${targetId} 节点不存在，无法做动画断言`);

  const pathA = `${DIR}/story-${key}-frameA.png`;
  const pathB = `${DIR}/story-${key}-frameB.png`;
  await screenshot(pathA);
  await sleep(180); // enough for spinner to rotate visibly, doesn't slow suite
  await screenshot(pathB);

  const a = decodePng(pathA);
  const b = decodePng(pathB);
  const scale = captureScale(pathA, a.width);
  const x0 = Math.max(0, Math.round(box.rect.x * scale));
  const y0 = Math.max(0, Math.round(box.rect.y * scale));
  const x1 = Math.min(a.width, Math.round((box.rect.x + box.rect.w) * scale));
  const y1 = Math.min(a.height, Math.round((box.rect.y + box.rect.h) * scale));
  let diff = 0;
  for (let y = y0; y < y1; y++) {
    for (let x = x0; x < x1; x++) {
      const i = (y * a.width + x) * a.channels;
      if (Math.abs(a.pixels[i] - b.pixels[i]) > 6) diff++;
    }
  }
  appendLog(`  ${targetId}: 跨帧差异像素=${diff}`);
  assert(diff >= 50, `${targetId} 两帧之间没有变化（diff=${diff}）— 动画没在跑或图形没画出来`);
}

/// Spinner ink stays inside each spinner's own bounds. The arc keeps its rotation angles in the
/// instance's shadow-offset slots; the quad once grew with them, and the arc field's jump at the
/// sweep ends drew thin rays out of every spinner (worse the longer it ran).
test("spinner arcs draw nothing outside their ring", async () => {
  await switchTo("spinner");
  await sleep(1500); // let the angles grow, as they do in a long-running app
  const rects: { x: number; y: number; w: number; h: number }[] = [];
  for (let i = 0; i < 5; i++) {
    const node = (await query(`story.spinner.${i}`))[0];
    assert(node != null, `story.spinner.${i} 不存在`);
    rects.push(node.rect);
  }
  // Window chrome and the page title (Windows draws it above the story) are not spinner ink.
  const chrome: { x: number; y: number; w: number; h: number }[] = [];
  for (const id of ["storybook.header", "storybook.page", "sidebar"]) for (const n of await query(id).catch(() => [])) chrome.push(n.rect);
  const inside = (x: number, y: number) => [...rects, ...chrome].some((r) => x >= r.x - 1 && x <= r.x + r.w + 1 && y >= r.y - 1 && y <= r.y + r.h + 1);
  for (let frame = 0; frame < 3; frame++) {
    const path = `${DIR}/story-spinner-bounds-${frame}.png`;
    await screenshot(path);
    const img = decodePng(path);
    const scale = captureScale(path, img.width);
    let stray = 0;
    for (const r of rects) {
      for (let y = Math.floor((r.y - 40) * scale); y < Math.ceil((r.y + r.h + 40) * scale); y++) {
        for (let x = Math.floor((r.x - 40) * scale); x < Math.ceil((r.x + r.w + 40) * scale); x++) {
          if (x < 0 || y < 0 || x >= img.width || y >= img.height || inside(x / scale, y / scale)) continue;
          const i = (y * img.width + x) * img.channels;
          if (0.299 * img.pixels[i] + 0.587 * img.pixels[i + 1] + 0.114 * img.pixels[i + 2] < 200) stray++;
        }
      }
    }
    appendLog(`  spinner frame ${frame}: ink outside spinner bounds = ${stray}`);
    assert(stray === 0, `spinner 外框之外出现墨迹（射线）：${stray} 像素，frame ${frame}`);
    await sleep(120);
  }
});

async function storyTexts(key: string): Promise<string> {
  const q = await query(`story.${key}`);
  const out: string[] = [];
  if (q[0]) collectText(q[0], out);
  return out.join(" │ ");
}

async function shot(name: string): Promise<number> {
  const path = `${DIR}/story-${name}.png`;
  const r = await screenshot(path);
  assert(r.ok === true, `screenshot rpc not ok for ${name}: ${JSON.stringify(r)}`);
  const size = statSync(path).size;
  appendLog(`  screenshot ${name}: ${size} bytes`);
  return size;
}

/// fixed sleep then wait until app stops. New glass does brightness probe first frame (hide until
/// reading arrives, 2-3 frames), tens of ms at 60Hz, software raster (Windows WARP, 0.2-0.7s/frame
/// full) needs 1s+; fixed sleep alone captures blank probe. Poll interval scales with frame time;
/// always-animated story returns at cap.
async function settle(minMs: number, maxMs = getE2eTimeoutMs(8000)): Promise<void> {
  await sleep(minMs);
  const deadline = Date.now() + maxMs;
  let last = await stats();
  while (Date.now() < deadline) {
    await sleep(Math.max(200, (3 * (last.total_frame_us || 0)) / 1000));
    const now = await stats();
    if (now.frame_count === last.frame_count) return;
    last = now;
  }
}

/// animation clock. Wallclock sleep sampling animation frames depends on speed: software raster
/// 300-420ms yields 0-1 frames. Slow renderer: fixed-stride clock (each submit advances
/// animation_time by stride ms), animSleep waits by frame count, sample at same moment; fast keeps
/// wallclock.
///
/// High-latency harness (tunneled real device, 0.5-1.5s RPC) uses fixed clock too, 16ms stride:
/// 60fps animates real-speed, then stops/freezes, auto-disappearing hints (2s capsule, 5.2s
/// progress) don't expire before test reads.
let animClockStep = 0;
let animClockLocked = false;
async function harnessLatencyMs(): Promise<number> {
  const samples: number[] = [];
  for (let i = 0; i < 3; i++) {
    const t0 = Date.now();
    await stats();
    samples.push(Date.now() - t0);
  }
  return samples.sort((a, b) => a - b)[1];
}
/// high-latency harness locked clock: time advances only by animSleep's grants, mid-animation
/// sample at precise moment, RPC unaffected. Only for cases using animSleep throughout.
async function useAnimationClock(lockForSampling = false): Promise<void> {
  const s = await stats();
  const slowRenderer = Math.max(s.total_frame_us || 0, s.total_p95_us || 0) > 50_000;
  const latency = lockForSampling ? Infinity : slowRenderer ? 0 : process.env.ZENIT_E2E_FORCE_LOCKED_CLOCK === "1" ? Infinity : await harnessLatencyMs();
  if (!slowRenderer && latency <= 150) return;
  animClockStep = slowRenderer && !lockForSampling ? 33 : 16;
  animClockLocked = lockForSampling || !slowRenderer;
  const r = await request("POST", "/clock", { step_ms: animClockStep, locked: animClockLocked });
  assert(!r.error, `animation clock: ${JSON.stringify(r)}`);
  appendLog(`  ${animClockLocked ? "locked" : "fixed"} animation clock ${animClockStep} ms/frame (${slowRenderer ? "slow renderer" : `harness latency ${latency} ms`})`);
}
/// high-latency harness free-stepping 16ms: 60fps same as wallclock, then stops/freezes, transient
/// hints don't expire before read. Suits cases using wallclock sleep for animation end.
async function useIdleFrozenClock(): Promise<void> {
  if (process.env.ZENIT_E2E_FORCE_LOCKED_CLOCK !== "1" && (await harnessLatencyMs()) <= 150) return;
  animClockStep = 16;
  animClockLocked = false;
  const r = await request("POST", "/clock", { step_ms: animClockStep });
  assert(!r.error, `animation clock: ${JSON.stringify(r)}`);
  appendLog(`  idle-frozen animation clock ${animClockStep} ms/frame (harness latency)`);
}
async function useRealtimeClock(): Promise<void> {
  if (animClockStep === 0) return;
  animClockStep = 0;
  animClockLocked = false;
  await request("POST", "/clock", { step_ms: 0 });
}
/// current animation time (ms): fixed clock = submitted_frames × stride, else wallclock. Deadline
/// by this, else 16x slowdown transition doesn't reach window before wallclock deadline.
async function animNow(): Promise<number> {
  if (animClockStep === 0) return Date.now();
  if (animClockLocked) return (await stats() as any).frame_time_ms;
  return (await stats()).frame_count * animClockStep;
}
/// wait ms milliseconds animation time. Fixed clock counts submitted frames; returns when no more
/// frames (animation done, idle).
async function animSleep(ms: number): Promise<void> {
  if (animClockStep === 0) return sleep(ms);
  if (animClockLocked) {
    const r = await request("POST", "/clock/advance", { ms });
    assert(!r.error, `clock advance: ${JSON.stringify(r)}`);
    const deadline = Date.now() + 60_000;
    while (((await stats()) as any).clock_budget_ms > 0) {
      assert(Date.now() < deadline, `locked clock did not spend ${ms} ms`);
      await sleep(20);
    }
    return;
  }
  const frames = Math.ceil(ms / animClockStep);
  const start = (await stats()).frame_count;
  let last = start;
  let changed = Date.now();
  for (;;) {
    const s = await stats();
    if (s.frame_count - start >= frames) return;
    if (s.frame_count !== last) {
      last = s.frame_count;
      changed = Date.now();
    } else if (Date.now() - changed > Math.max(3000, (4 * (s.total_frame_us || 0)) / 1000)) {
      appendLog(`  animSleep(${ms}) idle after ${s.frame_count - start}/${frames} frames (last frame ${Math.round((s.total_frame_us || 0) / 1000)} ms)`);
      return;
    }
    await sleep(50);
  }
}

let freshMountOrdinal = -1;
async function switchTo(storyKey: string): Promise<void> {
  await useRealtimeClock();
  // A failed overlay assertion must not poison every following test. Move the
  // pointer outside the window (fresh hover edge) and unwind up to three nested
  // overlay tiers before clicking the sidebar. Each RPC is processed on its
  // own app frame, so close effects commit between Escape presses.
  await mouseMove(-10, -10);
  for (let i = 0; i < 3; i++) await key("escape");
  // Every test starts from a freshly mounted story. Clicking the nav item of the story that is
  // already shown keeps it mounted, with whatever state the previous test left (a submitted
  // form, a scrolled canvas), so the outcome would depend on which test ran before. Later calls
  // within the same test keep their state on purpose (ComboBox re-focuses after a selection).
  if (freshMountOrdinal !== currentTestOrdinal()) {
    freshMountOrdinal = currentTestOrdinal();
    if ((await query(`story.${storyKey}`)).length > 0) {
      const away = storyKey === "button" ? "controls" : "button";
      assert((await clickTestId(`nav.${away}`)).ok === true, `failed to click nav.${away}`);
      await waitFor(async () =>
        (await query(`story.${storyKey}`)).length === 0 && (await query(`story.${away}`)).length === 1 ? true : null,
      getE2eTimeoutMs(6000), 50);
    }
  }
  const click = await clickTestId(`nav.${storyKey}`);
  assert(click.ok === true, `failed to click nav.${storyKey}: ${JSON.stringify(click)}`);
  // wait panel appears AND text subtree built (Show mounts container then builds body; query
  // between sees empty). Text stories wait content text, graphics stories wait actual child layout.
  const panel = await waitFor(async () => {
    const q = await query(`story.${storyKey}`);
    if (q.length !== 1 || !q[0]) return null;
    const out: string[] = [];
    collectText(q[0], out);
    // stories without expected texts (graphics, or their note lives outside the panel:
    // WidgetSpec.note) are ready once their root has a size
    const ready = (EXPECT[storyKey]?.length ?? 0) === 0
      ? q[0].children?.some((child: any) => child.rect?.w > 0 && child.rect?.h > 0)
      : out.length > 0;
    return ready ? q : null;
  }, getE2eTimeoutMs(6000), 50);
  assert(panel.length === 1, `expected exactly 1 story.${storyKey} panel with content, got ${panel.length}`);
}

/// Opens / closes a multi-select from its chevron. The trigger's centre can land on a tag's remove
/// button: tag widths follow the platform UI font.
async function clickSelectChevron(id: string): Promise<void> {
  const r = await screenPos(id);
  assert((await clickAt(r.x + r.w - 20, r.y + r.h / 2)).ok === true, `failed to click ${id} chevron`);
}

test("server reachable", async () => {
  await waitForServerReady(15000);
  assert((await health()).status === "ok");
}, { fatal: true });

async function scrollingState(part: string) {
  const nodes = await query(`story.scrolling.${part}.status`);
  const text: string[] = [];
  for (const node of nodes) collectText(node, text);
  const value = text.join(" ");
  const match = /x=(-?\d+) y=(-?\d+)/.exec(value);
  assert(match != null, `missing scroll readout: ${value}`);
  return { x: Number(match![1]), y: Number(match![2]), text: value };
}

async function scrollPanel(part: string, dx: number, dy: number, mods = {}) {
  const r = await screenPos(`story.scrolling.${part}`);
  await scrollAt(r.x + 40, r.y + Math.min(40, r.h / 2), dx, dy, mods);
  await sleep(80);
}

test("scrolling: logical points, axes and reset", async () => {
  await switchTo("scrolling");
  await scrollPanel("vertical", 0, -60);
  assert((await scrollingState("vertical")).y === 60, "vertical wheel must move 60 logical points");
  assert((await scrollingState("horizontal")).x === 0, "vertical wheel changed sibling");
  await scrollPanel("horizontal", -80, 0);
  assert((await scrollingState("horizontal")).x === 80, `horizontal wheel must move 80 logical points: ${JSON.stringify(await scrollingState("horizontal"))}`);
  await shot("scrolling-axes");
  await clickTestId("story.scrolling.vertical.reset");
  await clickTestId("story.scrolling.horizontal.reset");
  assert((await scrollingState("vertical")).y === 0, "vertical reset failed");
  assert((await scrollingState("horizontal")).x === 0, "horizontal reset failed");
});

test("scrolling: nested ownership and boundary handoff", async () => {
  await switchTo("scrolling");
  await scrollPanel("inner", 0, -40);
  assert((await scrollingState("inner")).y === 40, "inner did not consume wheel");
  assert((await scrollingState("outer")).y === 0, "parent moved before inner boundary");
  await scrollPanel("inner", 0, -460);
  const edge = (await scrollingState("inner")).y;
  assert(edge > 40, `inner did not reach bottom: ${JSON.stringify(await scrollingState("inner"))}`);
  await scrollPanel("inner", 0, -40);
  assert((await scrollingState("inner")).y === edge, "inner crossed its boundary");
  assert((await scrollingState("outer")).y > 0, "wheel did not hand off to parent");
  await shot("scrolling-nested-handoff");
});

test("scrolling: zero-delta trackpad and momentum lifecycle", async () => {
  await switchTo("scrolling");
  await scrollPanel("vertical", 0, 0, { phase: "began" });
  await scrollPanel("vertical", 0, -24, { phase: "changed" });
  await scrollPanel("vertical", 0, 0, { phase: "ended" });
  let state = await scrollingState("vertical");
  assert(state.y === 24 && state.text.includes("ended/none"), `lost trackpad ending: ${state.text}`);
  await scrollPanel("vertical", 0, -12, { momentum: "began" });
  await scrollPanel("vertical", 0, -8, { momentum: "changed" });
  await scrollPanel("vertical", 0, 0, { momentum: "ended" });
  state = await scrollingState("vertical");
  assert(state.y === 44 && state.text.includes("none/ended"), `lost momentum ending: ${state.text}`);
  await shot("scrolling-trackpad-ended");
});


test("scrolling: stationary pointer — hover follows content scrolled under it (wheel, momentum, nested)", async () => {
  await switchTo("scrolling");
  const hovered = async () => (await stats()).hover!;
  // Pointer goes near the row's left edge; colour samples come from the empty right part.
  const rowCenter = async (id: string) => {
    const r = await screenPos(id);
    return { x: r.x + 40, y: r.y + r.h / 2, sx: r.x + r.w - 40 };
  };
  // Earlier scrolling tests leave the lists scrolled: start from the top (clicks move the pointer,
  // which is fine before the stationary part).
  for (const part of ["vertical", "outer", "inner"]) await clickTestId(`story.scrolling.${part}.reset`);
  await settle(200);
  // Rest the pointer on Row 02 of the vertical list (rows are 30pt tall).
  const p = await rowCenter("story.scrolling.vertical.row.02");
  await mouseMove(p.x, p.y);
  await settle(250);
  let h = await hovered();
  assert(h.test_id === "story.scrolling.vertical.row.02", `pointer rests on Row 02: ${JSON.stringify(h)}`);
  const changes0 = h.reconcile_changes;

  // Wheel 60pt without moving the pointer: Row 04 arrives under it and takes the hover.
  await scrollAt(p.x, p.y, 0, -60);
  await settle(250);
  assert((await scrollingState("vertical")).y === 60, "wheel must scroll the vertical list by 60");
  h = await hovered();
  assert(h.test_id === "story.scrolling.vertical.row.04", `hover must follow the row under the stationary pointer: ${JSON.stringify(h)}`);
  assert(h.reconcile_changes > changes0, `re-resolution must have changed hover: ${JSON.stringify(h)}`);
  await shot("scrolling-stationary-hover");
  const png = `${DIR}/story-scrolling-stationary-hover.png`;
  const under = await rowCenter("story.scrolling.vertical.row.04");
  const next = await rowCenter("story.scrolling.vertical.row.05");
  const prev = await rowCenter("story.scrolling.vertical.row.03");
  const at = (q: { sx: number; y: number }) => centerPixel(png, { x: q.sx - 3, y: q.y - 3, w: 6, h: 6 });
  const hoverBg = at(under);
  const plainBg = at(next);
  appendLog(`  stationary hover: row04=(${hoverBg}) row05=(${plainBg}) row03=(${at(prev)})`);
  assert(Math.max(...hoverBg.map((c, i) => Math.abs(c - plainBg[i]))) >= 3, `row under the pointer must paint hover: (${hoverBg}) vs (${plainBg})`);
  assertColorNear(at(prev), plainBg, "row that scrolled out from under the pointer is no longer hovered", 3);

  // Trackpad gesture + momentum: hover lands on the row under the pointer once content rests.
  await scrollAt(p.x, p.y, 0, 0, { phase: "began" });
  await scrollAt(p.x, p.y, 0, -24, { phase: "changed" });
  await scrollAt(p.x, p.y, 0, 0, { phase: "ended" });
  await scrollAt(p.x, p.y, 0, -36, { momentum: "began" });
  await scrollAt(p.x, p.y, 0, 0, { momentum: "ended" });
  await settle(300);
  const y = (await scrollingState("vertical")).y;
  const panel = await screenPos("story.scrolling.vertical");
  const expectRow = Math.floor((p.y - panel.y + y) / 30) + 1;
  h = await hovered();
  assert(h.test_id === `story.scrolling.vertical.row.${String(expectRow).padStart(2, "0")}`,
    `after momentum (y=${y}) hover must be Row ${expectRow}: ${JSON.stringify(h)}`);

  // Pointer leaves the window: nothing hovers, and later scrolling does not resurrect hover.
  await mouseMove(-10, -10);
  await settle(200);
  assert((await hovered()).test_id === null, "pointer outside the window clears hover");

  // Nested: pointer on the inner list; the inner list consumes the wheel until its edge, then the
  // outer list scrolls and carries the inner rows under the pointer.
  const q = await rowCenter("story.scrolling.inner.row.02");
  await mouseMove(q.x, q.y);
  await settle(250);
  assert((await hovered()).test_id === "story.scrolling.inner.row.02", `inner Row 02 hovered: ${JSON.stringify(await hovered())}`);
  await scrollAt(q.x, q.y, 0, -30);
  await settle(250);
  h = await hovered();
  assert(h.test_id === "story.scrolling.inner.row.03", `inner wheel moves hover to Row 03: ${JSON.stringify(h)}`);
  // Inner list: 20 rows x 30 = 600 in a 100 viewport, edge at 500 (now at 30).
  await scrollAt(q.x, q.y, 0, -470);
  await settle(300);
  const innerEdge = (await scrollingState("inner")).y;
  assert(innerEdge === 500 && (await scrollingState("outer")).y === 0, `inner at its edge, outer untouched: inner=${innerEdge}`);
  h = await hovered();
  assert(h.test_id === "story.scrolling.inner.row.19", `inner at its edge: Row 19 under the pointer: ${JSON.stringify(h)}`);
  // Past the edge the wheel hands off: the outer list moves 40 and carries the inner rows up.
  await scrollAt(q.x, q.y, 0, -40);
  await settle(300);
  const outerY = (await scrollingState("outer")).y;
  assert(outerY === 40 && (await scrollingState("inner")).y === innerEdge, `handoff to outer: outer=${outerY}`);
  // Whatever row now sits under the pointer must be the hovered one (geometry is the authority).
  const tree = await query("story.scrolling.inner.content");
  let rowUnder: string | null = null;
  const walk = (n: any) => {
    if (typeof n?.test_id === "string" && n.test_id.startsWith("story.scrolling.inner.row.") && n.rect &&
      q.y >= n.rect.y && q.y < n.rect.y + n.rect.h) rowUnder = n.test_id;
    for (const c of n?.children ?? []) walk(c);
  };
  walk(tree[0]);
  h = await hovered();
  appendLog(`  nested handoff: outer y=${outerY}, row under pointer=${rowUnder}, hovered=${h.test_id}`);
  assert(rowUnder === "story.scrolling.inner.row.20" && h.test_id === rowUnder, `after outer scroll the row under the pointer (${rowUnder}) must be hovered: ${JSON.stringify(h)}`);
  await shot("scrolling-stationary-hover-nested");
  await clickTestId("story.scrolling.outer.reset");
  await clickTestId("story.scrolling.inner.reset");
});

test("scrolling: hover follows the pointer in an inactive window and stops under a covering window", async () => {
  await switchTo("scrolling");
  const hovered = async () => (await stats()).hover!;
  for (const part of ["vertical", "outer", "inner"]) await clickTestId(`story.scrolling.${part}.reset`);
  await settle(200);
  const row = async (id: string) => {
    const r = await screenPos(id);
    return { x: r.x + 40, y: r.y + r.h / 2, sx: r.x + r.w - 40 };
  };
  const p = await row("story.scrolling.vertical.row.02");
  await mouseMove(p.x, p.y);
  await settle(200);
  assert((await hovered()).test_id === "story.scrolling.vertical.row.02", `pointer rests on Row 02: ${JSON.stringify(await hovered())}`);
  try {
    // Another application becomes active. Native hover (AppKit activeAlways tracking areas, Win32,
    // Wayland pointer focus) does not depend on activation, and the background window still
    // wheel-scrolls under the pointer: hover follows the row that arrives.
    assert((await setWindowActive(false)).ok, "window_active route");
    await settle(150);
    let h = await hovered();
    assert(h.test_id === "story.scrolling.vertical.row.02" && h.pointer_live, `deactivation keeps hover: ${JSON.stringify(h)}`);
    const changes = h.reconcile_changes;
    await scrollAt(p.x, p.y, 0, -60);
    await settle(250);
    assert((await scrollingState("vertical")).y === 60, "inactive window scrolls by 60");
    h = await hovered();
    assert(h.test_id === "story.scrolling.vertical.row.04" && h.reconcile_changes > changes,
      `inactive window: hover follows the row under the pointer: ${JSON.stringify(h)}`);
    await shot("scrolling-inactive-hover");
    const png = `${DIR}/story-scrolling-inactive-hover.png`;
    const at = async (id: string) => { const q = await row(id); return centerPixel(png, { x: q.sx - 3, y: q.y - 3, w: 6, h: 6 }); };
    const hoverBg = await at("story.scrolling.vertical.row.04");
    const plainBg = await at("story.scrolling.vertical.row.05");
    assert(Math.max(...hoverBg.map((c, i) => Math.abs(c - plainBg[i]))) >= 3, `inactive window paints hover: (${hoverBg}) vs (${plainBg})`);

    // Another window is ordered over the resting pointer: the platform reports pointer_left at an
    // unchanged position inside the content. Hover clears and content scrolled meanwhile does
    // not resurrect it.
    assert((await pointerLeave()).ok, "pointer_leave route");
    await settle(150);
    h = await hovered();
    assert(h.test_id === null && !h.pointer_over_content && !h.pointer_live, `covered: no hover: ${JSON.stringify(h)}`);
    await shot("scrolling-covered-no-hover");
    const covered = `${DIR}/story-scrolling-covered-no-hover.png`;
    const q4 = await row("story.scrolling.vertical.row.04");
    assertColorNear(centerPixel(covered, { x: q4.sx - 3, y: q4.y - 3, w: 6, h: 6 }), plainBg, "covered row paints no hover", 3);
    const hits = h.reconcile_hit_tests;
    await scrollAt(p.x, p.y, 0, -30);
    await settle(250);
    h = await hovered();
    assert(h.test_id === null && h.reconcile_hit_tests === hits, `content scrolled under the covering window stays unhovered: ${JSON.stringify(h)}`);
    // The window moves away: the platform re-delivers the resting position.
    await mouseMove(p.x, p.y);
    await settle(200);
    h = await hovered();
    assert(h.test_id === "story.scrolling.vertical.row.05" && h.pointer_live, `uncovered: the row under the pointer hovers again: ${JSON.stringify(h)}`);
  } finally {
    await setWindowActive(true);
    await clickTestId("story.scrolling.vertical.reset");
  }
});

// ── all components: switch + data verification + screenshot (visual + log data dual) ──
for (const key of KEYS) {
  test(`${key}: 数据值 + 截图`, async () => {
    await switchTo(key);
    // log data verification: all expected values must appear in story subtree. With retry: panel
    // two-stage mount (container then body), single query may hit rebuild and see empty
    // (card/checkbox occasional flake cause); real missing data still timeouts.
    let texts = "";
    await waitFor(async () => {
      texts = await storyTexts(key);
      const missing = EXPECT[key].filter((v) => !texts.includes(v));
      return missing.length === 0 ? true : null;
    }, getE2eTimeoutMs(5000), 60).catch(() => {});
    appendLog(`  story.${key} texts: ${texts || "(none)"}`);
    const missing = EXPECT[key].filter((v) => !texts.includes(v));
    assert(
      missing.length === 0,
      `story.${key} 缺数据值: [${missing.join(", ")}] — 实际文本: ${texts}`,
    );

    if (key === "stack") {
      // Both stacks now use the same design copy. Check each occurrence so a
      // missing HStack or VStack child cannot be masked by its sibling stack.
      const nodes = (await query("story.stack"))[0];
      const labels: string[] = [];
      if (nodes) collectText(nodes, labels);
      for (const value of ["One", "Two", "Three"])
        assert(labels.filter((text) => text === value).length === 2, `both stacks must render ${value}`);
    }

    if (key === "datepicker" || key === "daterange") {
      const empty = (await query(`story.${key}.empty`))[0];
      const placeholders: string[] = [];
      if (empty) collectText(empty, placeholders);
      for (const placeholder of EXPECT[key])
        assert(placeholders.includes(placeholder), `empty ${key} missing placeholder ${placeholder}`);
    }

    const path = `${DIR}/story-${key}.png`;
    await shot(key);

    // Warning: cannot assert screenshot byte count alone (full window ~220k-360k bytes, old 3000
    // off by 100x). For EXPECT-empty pure graphics, data empty too; test degrades to 'mounted +
    // alive', exactly where pixel verification needed. Use story region ink assertions.
    // Frame graphics node only, avoid other content masking failures. Note: spinner excluded
    // (rotation, screenshot timing varies angle, pixel 165-1032 on full run). Correct test is frame
    // diff, not ink (separate). skeleton static, stable ink (120k+), applies.
    const INK_TARGET: Record<string, string> = {
      skeleton: "story.skeleton.col",
      glassmerge: "story.glassmerge.s40.g16",
      glassedge: "story.glassedge.right",
      glassunion: "story.glassunion.stage",
      glassextension: "story.glassextension.stage",
      glassconcentric: "story.glassconcentric.stage",
      glasscontrols: "story.glasscontrols.stage",
    };
    if (EXPECT[key].length === 0) {
      // animated components use frame-diff criterion (see ANIMATED_INK comment)
      if (ANIMATED_INK.has(key)) {
        await assertAnimates(key, ANIMATED_INK.get(key)!);
        return;
      }
      const targetId = INK_TARGET[key];
      assert(
        targetId != null,
        `${key} 的 EXPECT 为空但没有配 INK_TARGET —— 该用例会退化成零视觉验证。` +
          `若该组件是动画（像 spinner），单帧墨量判据不适用，需要跨帧比较，` +
          `请显式在这里说明并补对应用例。`,
      );
      const box = (await query(targetId))[0];
      assert(box != null, `${targetId} 节点不存在，无法做墨量断言`);
      if (key === "skeleton") {
        // Shimmer can briefly get close to the Windows page color. Sample a full cycle
        // and require the same ink floor on a frame where the bones are visible.
        for (let frame = 0; frame < 5; frame++) {
          const framePath = frame === 0 ? path : `${DIR}/story-skeleton-shimmer-${frame}.png`;
          if (frame > 0) {
            await settle(420);
            await screenshot(framePath);
          }
          const img = decodePng(framePath);
          const scale = decodedCaptureScale(img);
          const ink = countNonBackgroundPixels(img, box.rect, scale);
          appendLog(`  skeleton frame ${frame}: non_bg_pixels=${ink}`);
          if (ink >= minAtScale(200, scale)) return;
        }
        assert(false, "Skeleton must paint visible bones during its shimmer cycle");
      }
      assertRegionNotBlank(path, box.rect, targetId);
    }

    // app still alive (rendering/interaction not crashed)
    assert((await health()).status === "ok", `app died after ${key}`);
  });
}

// ── Layout / Box Model: geometry ground truth ──
// Story handles visualization; read global rect for same test_ids, subtract parent offset then
// assert local CSS geometry. When padding/content coordinate systems mix, both screenshot and
// numeric gates go red.
test("LayoutBox: padding-box / percent / stretch / Flex / Grid geometry", async () => {
  await switchTo("layoutbox");

  const rect = async (id: string) => {
    const node = (await query(id))[0];
    assert(node != null && node.rect.w > 0 && node.rect.h > 0, `${id} 没有有效布局 rect`);
    return node.rect;
  };
  const near = (actual: number, expected: number, label: string, tolerance = 0.75) => {
    const delta = Math.abs(actual - expected);
    appendLog(`  ${label}: actual=${actual.toFixed(3)} expected=${expected.toFixed(3)} delta=${delta.toFixed(3)}`);
    assert(delta <= tolerance, `${label}: ${actual} != ${expected} (±${tolerance})`);
  };

  const parent = await rect("story.layoutbox.absolute.parent");
  const guide = await rect("story.layoutbox.absolute.content-guide");
  const origin = await rect("story.layoutbox.absolute.origin");
  const outer = await rect("story.layoutbox.absolute.outer-edge");
  const contentEdge = await rect("story.layoutbox.absolute.content-edge");
  near(guide.x - parent.x, 32, "content guide x");
  near(guide.y - parent.y, 28, "content guide y");
  near(guide.w, 624, "content guide width");
  near(guide.h, 132, "content guide height");
  near(origin.x - parent.x, 0, "left:0 origin x");
  near(origin.y - parent.y, 0, "top:0 origin y");
  near(parent.x + parent.w - (outer.x + outer.w), 0, "right:0 gap");
  near(parent.y + parent.h - (outer.y + outer.h), 0, "bottom:0 gap");
  near(parent.x + parent.w - (contentEdge.x + contentEdge.w), 44, "content-edge right gap");
  near(parent.y + parent.h - (contentEdge.y + contentEdge.h), 20, "content-edge bottom gap");

  const percentParent = await rect("story.layoutbox.percent.parent");
  const percent = await rect("story.layoutbox.percent.marker");
  near(percent.x - percentParent.x, 85.5, "left:25%");
  near(percent.y - percentParent.y, 75, "top:50%");

  const stretchParent = await rect("story.layoutbox.stretch.parent");
  const stretch = await rect("story.layoutbox.stretch.child");
  near(stretch.x - stretchParent.x, 14, "stretch left");
  near(stretch.y - stretchParent.y, 18, "stretch top");
  near(stretch.w, 306, "stretch width");
  near(stretch.h, 120, "stretch height");

  const flexParent = await rect("story.layoutbox.flex.parent");
  const flexA = await rect("story.layoutbox.flex.a");
  const flexB = await rect("story.layoutbox.flex.b");
  const flexAbs = await rect("story.layoutbox.flex.absolute");
  near(flexA.x - flexParent.x, 20, "Flex first item starts at padding.left");
  near(flexB.x - flexParent.x, 104, "Flex gap + B margin-left");
  near(flexAbs.x - flexParent.x, 308, "Flex absolute right:0 x");
  near(flexAbs.y - flexParent.y, 0, "Flex absolute top:0 y");

  const gridParent = await rect("story.layoutbox.grid.parent");
  const gridA = await rect("story.layoutbox.grid.a");
  const gridB = await rect("story.layoutbox.grid.b");
  const gridC = await rect("story.layoutbox.grid.c");
  const gridAbs = await rect("story.layoutbox.grid.absolute");
  near(gridA.x - gridParent.x, 20, "Grid first track x");
  near(gridA.w, 70, "Grid 70px track");
  near(gridB.x - gridParent.x, 98, "Grid 1fr track x");
  near(gridB.w, 72, "Grid 1fr width");
  near(gridC.x - gridParent.x, 178, "Grid 2fr track x");
  near(gridC.w, 144, "Grid 2fr width");
  near(gridAbs.x - gridParent.x, 308, "Grid absolute right:0 x");
  near(gridAbs.y - gridParent.y, 136, "Grid absolute bottom:0 y");

  const sizingParent = await rect("story.layoutbox.sizing.parent");
  const sizingPx = await rect("story.layoutbox.sizing.px");
  const sizingPercent = await rect("story.layoutbox.sizing.percent");
  const sizingGrow = await rect("story.layoutbox.sizing.grow");
  near(sizingPx.w, 80, "px sizing");
  near(sizingPercent.w, 132, "20% of 660 content width");
  near(sizingParent.x + sizingParent.w - (sizingGrow.x + sizingGrow.w), 20, "grow ends at content edge");
});

// -- interaction: Checkbox click changes status text --
// -- interaction: Tabs switch --
// Tabs' core is click-switch; labels show in any state, so label-only checks pass when broken.
// -- interaction: Switch toggle --
// Switch's core is toggle; label-only EXPECT passes even with a broken toggle.
/// control-flow region anchor (tag=anchor, display:none, zero size) is position bookkeeping:
/// exclude before indexing
function stripAnchors(n: any): any {
  return { ...n, children: (n.children ?? []).filter((c: any) => c.tag !== "anchor").map(stripAnchors) };
}

test("Steps: 连接线连贯（横向贯穿圆心 / 纵向末段贴圆圈）+ 圆圈序号居中", async () => {
  await switchTo("steps");
  await sleep(300);
  const panel = stripAnchors((await query("story.steps"))[0]);
  const steppers: any[] = [];
  const walk = (n: any) => { if (n.component === "Steps") steppers.push(n); for (const c of n.children ?? []) walk(c); };
  walk(panel);
  assert(steppers.length === 2, `expected 2 Steps (horizontal + vertical), got ${steppers.length}`);
  const [h, v] = steppers;
  const cx = (r: any) => r.x + r.w / 2;
  const cy = (r: any) => r.y + r.h / 2;
  const near = (actual: number, expected: number, label: string, tol = 0.75) => {
    const d = Math.abs(actual - expected);
    appendLog(`  ${label}: actual=${actual.toFixed(2)} expected=${expected.toFixed(2)} delta=${d.toFixed(2)}`);
    assert(d <= tol, `${label}: ${actual} != ${expected} (±${tol})`);
  };

  // ── horizontal: [track, progress, step0, step1, step2], circle = step.children[0]
  const hk = h.children;
  const hCircles = hk.slice(2).map((s: any) => s.children[0].rect);
  const track = hk[0].rect, progress = hk[1].rect;
  assert(track.w > 0 && progress.w > 0, `横向连接线宽度为 0（track=${track.w} progress=${progress.w}）`);
  near(track.x, cx(hCircles[0]), "h track 起点 = 首圆心");
  near(track.x + track.w, cx(hCircles[hCircles.length - 1]), "h track 终点 = 末圆心");
  near(cy(track), cy(hCircles[0]), "h track 竖向居中于圆心");
  near(progress.x + progress.w, cx(hCircles[1]), "h progress 终点 = 当前(第 2 步)圆心");

  // ── vertical: row -> [indicator -> [circle, connector?], text]
  const rows = v.children;
  for (let i = 0; i + 1 < rows.length; i++) {
    const c = rows[i].children[0].children[0].rect;
    const conn = rows[i].children[0].children[1].rect;
    const next = rows[i + 1].children[0].children[0].rect;
    near(conn.y, c.y + c.h, `v connector ${i} 顶 = 圆圈 ${i} 底`);
    near(conn.y + conn.h, next.y, `v connector ${i} 底 = 圆圈 ${i + 1} 顶`);
    near(cx(conn), cx(c), `v connector ${i} 水平居中`);
  }

  // ── pixels: line really drawn, number truly centered
  const path = `${DIR}/story-steps-connectors.png`;
  assert((await screenshot(path)).ok === true, "screenshot failed");
  const png = decodePng(path);
  const scale = captureScale(path, png.width);
  const px = (x: number, y: number) => {
    const i = (Math.round(y * scale) * png.width + Math.round(x * scale)) * png.channels;
    return [png.pixels[i], png.pixels[i + 1], png.pixels[i + 2]];
  };
  const bg = px(h.rect.x + 2, h.rect.y + h.rect.h - 2);
  const differs = (p: number[]) => Math.abs(p[0] - bg[0]) + Math.abs(p[1] - bg[1]) + Math.abs(p[2] - bg[2]) > 30;
  for (let i = 0; i + 1 < hCircles.length; i++) {
    const midX = (hCircles[i].x + hCircles[i].w + hCircles[i + 1].x) / 2;
    const p = px(midX, cy(hCircles[0]));
    appendLog(`  h gap ${i} mid pixel=${p} bg=${bg}`);
    assert(differs(p), `横向第 ${i}→${i + 1} 段连接线没画出来（pixel=${p} ≈ bg=${bg}）`);
  }
  const lastConn = rows[rows.length - 2].children[0].children[1].rect;
  const lastCircle = rows[rows.length - 1].children[0].children[0].rect;
  for (let y = lastConn.y + 1; y < lastCircle.y + 2; y += 0.5) {
    const p = px(cx(lastConn), y);
    assert(differs(p), `纵向末段连接线在 y=${y.toFixed(1)} 断开（pixel=${p}，末圆圈顶 ${lastCircle.y}）`);
  }
  // white number ink centroid in dark circle vs circle center (in inscribed square, avoid
  // antialiasing)
  const inkCentroid = (r: any) => {
    const half = 9;
    let sx = 0, sy = 0, m = 0;
    for (let y = Math.round((cy(r) - half) * scale); y <= Math.round((cy(r) + half) * scale); y++) {
      for (let x = Math.round((cx(r) - half) * scale); x <= Math.round((cx(r) + half) * scale); x++) {
        const i = (y * png.width + x) * png.channels;
        const lum = 0.299 * png.pixels[i] + 0.587 * png.pixels[i + 1] + 0.114 * png.pixels[i + 2];
        const w = Math.max(0, lum - 128);
        // Texture pixels occupy [x,x+1) × [y,y+1). Compare their centers
        // with logical circle geometry; index coordinates bias ink by half a
        // physical pixel, most visibly at 1x on Linux.
        sx += w * (x + 0.5); sy += w * (y + 0.5); m += w;
      }
    }
    assert(m > 0, "圆圈内没有白色序号墨迹");
    return [sx / m / scale, sy / m / scale];
  };
  for (const [label, r] of [["h 圆圈 2", hCircles[1]], ["v 末圆圈 3", lastCircle]] as const) {
    const [ix, iy] = inkCentroid(r);
    near(ix, cx(r), `${label} 序号墨迹 x`, 1.5);
    near(iy, cy(r), `${label} 序号墨迹 y`, 1.5);
  }
});

test("Steps: Next / Back 驱动当前步 signal，进度线与禁用态跟随", async () => {
  await switchTo("steps");
  const horizontal = async () => {
    const steppers: any[] = [];
    const walk = (n: any) => { if (n.component === "Steps") steppers.push(n); for (const c of n.children ?? []) walk(c); };
    walk(stripAnchors((await query("story.steps"))[0]));
    return steppers[0];
  };
  const progressEndsAt = async (circle: number) => {
    const h = await horizontal();
    const progress = h.children[1].rect;
    const c = h.children[2 + circle].children[0].rect;
    return Math.abs(progress.x + progress.w - (c.x + c.w / 2)) <= 0.75;
  };
  const panelText = async () => await storyTexts("steps");
  assert(await progressEndsAt(1), "初始进度线应止于第 2 个圆心");
  assert((await clickTestId("story.steps.next")).ok === true);
  await waitFor(async () => ((await progressEndsAt(2)) ? true : null), getE2eTimeoutMs(2000), 40)
    .catch(async () => { throw new Error(`Next 后进度线应止于第 3 个圆心；texts=${await panelText()}`); });
  assert((await panelText()).includes("Horizontal (step 3 active)"), `标题未跟随：${await panelText()}`);
  // reached last step: Next disabled, next click shouldn't overflow
  assert((await clickTestId("story.steps.next")).ok === true);
  await sleep(150);
  assert(await progressEndsAt(2), "最后一步再点 Next 不应改变进度");
  await shot("steps-after-next");
  assert((await clickTestId("story.steps.back")).ok === true);
  await waitFor(async () => ((await progressEndsAt(1)) ? true : null), getE2eTimeoutMs(2000), 40);
  assert((await panelText()).includes("Horizontal (step 2 active)"), `Back 后标题未跟随：${await panelText()}`);
});

test("Card: 点卡片改选中，selected 由同一个 signal 派生", async () => {
  await switchTo("card");
  const status = async () => (await query("story.card.status"))[0]?.text ?? "";
  assert((await status()) === "plan → basic", `初始应为 "plan → basic"，got "${await status()}"`);
  assert((await clickTestId("story.card.pro")).ok === true);
  await waitFor(async () => ((await status()) === "plan → pro" ? true : null), getE2eTimeoutMs(2000), 40)
    .catch(async () => { throw new Error(`点 Pro 后应为 "plan → pro"，got "${await status()}"`); });
  await sleep(200); // wait border transition before screenshot
  await shot("card-pick-pro");
});

test("Rate: 点星改分，派生标签跟随", async () => {
  await switchTo("rate");
  const status = async () => (await query("story.rate.status"))[0]?.text ?? "";
  assert((await status()) === "value 3 / 5", `初始标签应为 "value 3 / 5"，got "${await status()}"`);
  const rate = (await query("story.rate.basic"))[0];
  const fifth = rate.children[4].rect;
  assert((await clickAt(fifth.x + fifth.w / 2, fifth.y + fifth.h / 2)).ok === true);
  await waitFor(async () => ((await status()) === "value 5 / 5" ? true : null), getE2eTimeoutMs(2000), 40)
    .catch(async () => { throw new Error(`点第 5 颗星后标签应为 "value 5 / 5"，got "${await status()}"`); });
  await shot("rate-after-click");
});

test("Switch: 交互 — 拨动改状态，disabled 不响应", async () => {
  await switchTo("switch");

  const statusOf = async () => (await query("story.switch.status"))[0]?.text ?? "";
  assert(
    (await statusOf()) === "toggled → (none)",
    `switch 初始 status 应为 "toggled → (none)"，got "${await statusOf()}"`,
  );

  // story.switch.off has initial_checked=false, toggle must turn on
  const sw = await screenPos("story.switch.off");
  await clickAt(sw.x + sw.h / 2, sw.y + sw.h / 2);
  await waitFor(async () => ((await statusOf()) !== "toggled → (none)" ? true : null)).catch(() => {});
  assert(
    (await statusOf()) === "toggled → on",
    `拨动后应为 "toggled → on"（initial_checked=false），got "${await statusOf()}"`,
  );

  // toggle again to off, verify true toggle not one-way set
  await clickAt(sw.x + sw.h / 2, sw.y + sw.h / 2);
  await waitFor(async () => ((await statusOf()) === "toggled → off" ? true : null)).catch(() => {});
  assert(
    (await statusOf()) === "toggled → off",
    `再拨一次应回到 "toggled → off"，got "${await statusOf()}"`,
  );
  await shot("switch-toggled-back");
});

// ── interaction: RadioGroup mutual exclusion ──
// Mutual exclusion is radio's defining semantics: select Y must deselect X. Prior EXPECT only had
// labels, broken select or all-selected both passed green.
test("RadioGroup: 交互 — 选中切换且互斥", async () => {
  await switchTo("radio");

  const statusOf = async () => (await query("story.radio.status"))[0]?.text ?? "";
  // status directly from selected signal (RadioGroup controlled source), initial 'x'
  await waitFor(async () => ((await statusOf()) === "selected → x" ? true : null), 4000, 50).catch(() => {});
  assert(
    (await statusOf()) === "selected → x",
    `radio 初始 status 应为 "selected → x"（由选中值 signal 派生），got "${await statusOf()}"`,
  );

  // select Option Y
  await clickText("story.radio.group", "Option Y");
  await waitFor(async () => ((await statusOf()) === "selected → y" ? true : null)).catch(() => {});
  assert(
    (await statusOf()) === "selected → y",
    `点 Option Y 后应为 "selected → y"，got "${await statusOf()}"`,
  );

  // select Option Z, verify continuous switch (prerequisite for exclusion)
  await clickText("story.radio.group", "Option Z");
  await waitFor(async () => ((await statusOf()) === "selected → z" ? true : null)).catch(() => {});
  assert(
    (await statusOf()) === "selected → z",
    `点 Option Z 后应为 "selected → z"，got "${await statusOf()}"`,
  );
  await shot("radio-selected-z");
});

// ── interaction: Accordion expand/collapse ──
// Prior only had static text (titles appear both states), broken click passed green.
// Warning: can't use 'body text count': collapse only sets height:0 + overflow_hidden, nodes stay
// in tree, text collection still gets all (measured). True observable is body container rect.h.
// Hidden glass (an empty notification viewport's pill / clear-all) must not hold frames: its
// first-frame family probe waits for the glass to be drawn without asking for a frame every tick
// (it kept the window at 60 fps and overflowed the Windows frame-archive gate).
test("Notification: 空闲时停帧——未画出的玻璃不持续要帧", async () => {
  await switchTo("notification");
  await mouseMove(-10, -10);
  await sleep(1500);
  const a = (await stats()).frame_count;
  await sleep(1000);
  const b = (await stats()).frame_count;
  appendLog(`  idle frames in 1 s: ${b - a}`);
  assert(b - a <= 2, `notification 空闲 1 秒应不出帧（实际 ${b - a} 帧）`);
});

test("Breadcrumb: 点前级报告 id，当前级不可点", async () => {
  await switchTo("breadcrumb");
  const status = async () => (await query("story.breadcrumb.status"))[0]?.text ?? "";
  await clickText("story.breadcrumb.path", "Data");
  await sleep(200);
  assert((await status()) === "selected → (none)", `当前级不应可点（${await status()}）`);
  await clickText("story.breadcrumb.path", "Library");
  await sleep(200);
  appendLog(`  status: ${await status()}`);
  assert((await status()) === "selected → lib", `点 Library 应报告其 id lib（${await status()}）`);
});

test("Form: Submit 跑全部规则显示错误；填好后 on_submit 收到值", async () => {
  await switchTo("form");
  const textsUnder = async (id: string) => {
    const out: string[] = [];
    collectText((await query(id))[0], out);
    return out;
  };
  await clickTestId("story.form.submit");
  await sleep(250);
  let all = [...(await textsUnder("story.form.name")), ...(await textsUnder("story.form.email"))];
  appendLog(`  empty submit: ${all.join(" │ ")}`);
  assert(all.includes("Name is required") && all.includes("Email is required"), `空提交应显示两条必填错误（${all.join(" │ ")}）`);
  assert((await textsUnder("story.form.status")).includes("(not submitted)"), "规则不通过时 on_submit 不应触发");
  await clickText("story.form.name", "Full name");
  await type_("Ada Lovelace");
  await clickText("story.form.email", "you@example.com");
  await type_("ada@example.com");
  await clickTestId("story.form.submit");
  await sleep(250);
  all = [...(await textsUnder("story.form.name")), ...(await textsUnder("story.form.email"))];
  assert(!all.includes("Name is required") && !all.includes("Email is required"), `填好后错误应消失（${all.join(" │ ")}）`);
  const st = (await textsUnder("story.form.status")).join(" ");
  appendLog(`  status: ${st}`);
  assert(st === "submitted → Ada Lovelace <ada@example.com>", `on_submit 应收到填入的值（${st}）`);
});

test("Accordion: 交互 — 折叠首节高度归零，展开第二节高度撑开", async () => {
  await switchTo("accordion");

  /// each section content container height: expanded > 0, collapsed == 0.
  /// Warning: must see content layer, not body child; body rect.h is content height, unchanged when
  /// collapsed (clipping at render). accordion.content is internal test_id.
  const bodyHeights = async (): Promise<number[]> => {
    // the first (independent) group; the exclusive FAQ group below adds three more
    const ns = (await query("accordion.content")).slice(0, 3);
    assert(ns.length === 3, `应查到 3 个 accordion.content，got ${ns.length}`);
    return ns.map((n: any) => n.rect.h);
  };

  const expandedCount = async () => (await bodyHeights()).filter((h) => h > 0).length;

  assert(
    (await expandedCount()) === 1,
    `accordion 初始应恰好 1 节展开（story 里只有首节 expanded），实际高度分布 ${JSON.stringify(await bodyHeights())}`,
  );

  // collapse first -> expanded count zero
  await clickText("story.accordion", "Section One");
  await waitFor(async () => ((await expandedCount()) === 0 ? true : null)).catch(() => {});
  assert(
    (await expandedCount()) === 0,
    `折叠 Section One 后应 0 节展开，实际高度分布 ${JSON.stringify(await bodyHeights())}`,
  );
  await shot("accordion-collapsed");

  // expand second -> back to 1 (verify expand works too, not just collapse)
  await clickText("story.accordion", "Section Two");
  await waitFor(async () => ((await expandedCount()) === 1 ? true : null)).catch(() => {});
  assert(
    (await expandedCount()) === 1,
    `展开 Section Two 后应 1 节展开，实际高度分布 ${JSON.stringify(await bodyHeights())}`,
  );
  await shot("accordion-section2-expanded");
});

test("Tabs: 交互 — 点击切换 active，且 disabled 不响应", async () => {
  await switchTo("tabs");

  const statusOf = async () => (await query("story.tabs.status"))[0]?.text ?? "";
  assert(
    (await statusOf()) === "active → t1",
    `tabs 初始 status 应为 "active → t1"，got "${await statusOf()}"`,
  );

  // click Details (t2)
  await clickText("story.tabs.underline", "Details");
  await waitFor(async () => ((await statusOf()) !== "active → t1" ? true : null)).catch(() => {});
  assert(
    (await statusOf()) === "active → t2",
    `点 Details 后应为 "active → t2"，got "${await statusOf()}"`,
  );
  await shot("tabs-active-t2");

  // click Settings (t3), verify continuous switch not just first
  await clickText("story.tabs.underline", "Settings");
  await waitFor(async () => ((await statusOf()) === "active → t3" ? true : null)).catch(() => {});
  assert(
    (await statusOf()) === "active → t3",
    `点 Settings 后应为 "active → t3"，got "${await statusOf()}"`,
  );

  // disabled tab must not respond: status stays t3
  await clickText("story.tabs.underline", "Disabled");
  await sleep(200);
  assert(
    (await statusOf()) === "active → t3",
    `disabled tab 不应触发 on_change，status 应停在 "active → t3"，got "${await statusOf()}"`,
  );
  await shot("tabs-disabled-noop");

  // Warning: on_change callback alone insufficient: setActive guard 'if (index==active_index)
  // return', when broken (always 0) every click fires, callback OK but visual selection broken.
  // Mutation (active_index unupdated) passes all-green with callback-only. Must separately assert
  // user-visible selection.
  // underline variant: highlight box via translate_x on current tab. Assert it really moved to
  // Settings x (not first tab).
  const root = (await query("story.tabs.underline"))[0];
  assert(root != null, "story.tabs.underline 不存在");
  const rSettings = findByText(root, "Settings");
  assert(rSettings != null, "找不到 Settings 标签");

  const rOverview = findByText(root, "Overview");
  assert(rOverview != null, "找不到 Overview 标签");

  // tabs.highlight is selection indicator, translate_x points to current tab (local coords).
  // Different from label rect (global), comparing 'offset relative to first tab'.
  const hlAtSettings = (await query("tabs.highlight"))[0];
  assert(hlAtSettings != null, "找不到 tabs.highlight 节点");
  // translate_x 0 may be omitted by query, normalize to 0 to avoid undefined in diagnostics.
  const hlShift = hlAtSettings.translate_x ?? 0;
  const expectedShift = rSettings!.x - rOverview!.x;
  appendLog(
    `  tabs highlight: translate_x=${hlShift} 期望位移≈${expectedShift.toFixed(1)}`,
  );
  assert(
    Math.abs(hlShift - expectedShift) <= 6,
    `highlight 条未移到 Settings（translate_x=${hlShift}，期望≈${expectedShift.toFixed(1)}）` +
      ` —— active_index 没有驱动渲染`,
  );

  // three variants bind same signal: pill/tab variants' indicator also leaves first tab
  const highlights = await query("tabs.highlight");
  assert(highlights.length >= 3, `应有 3 个变体的 tabs.highlight，got ${highlights.length}`);
  for (const [i, hl] of highlights.slice(0, 3).entries()) {
    assert(
      (hl.translate_x ?? 0) > 20,
      `第 ${i} 个变体的 highlight 未跟随共享 signal（translate_x=${hl.translate_x ?? 0}）`,
    );
  }
});

test("Checkbox: 交互 — 点击改 status 值", async () => {
  await switchTo("checkbox");
  // switchTo waits only 'panel has text', status text may lag; explicitly wait (occasional:
  // 'initial status should have (none), got empty').
  const before = await waitFor(async () => {
    const t = (await query("story.checkbox.status"))[0]?.text ?? "";
    return t.length > 0 ? t : null;
  }, 4000, 50);
  appendLog(`  checkbox status before: "${before}"`);
  assert(before.includes("(none)"), `checkbox 初始 status 应含 (none), got "${before}"`);

  const pos = await screenPos("story.checkbox.box");
  await clickAt(pos.x + pos.h / 2, pos.y + pos.h / 2);
  await sleep(250);

  const after = (await query("story.checkbox.status"))[0]?.text ?? "";
  appendLog(`  checkbox status after: "${after}"`);
  await shot("checkbox-after-click");
  // Warning: can't use after.includes('checked'), 'unchecked'.includes('checked') is true, masks
  // check vs uncheck, state reversal bug passes green. story.checkbox.box initial_checked=false,
  // toggle must be checked.
  assert(
    after === "changed → checked",
    `checkbox 点击后 status 应为 "changed → checked"（initial_checked=false），got "${after}"`,
  );
});

// ── Signal-first: one signal drives progress bar, text mirror, button disabled state ──
test("Progress: 交互 — signal 驱动进度、状态与按钮禁用", async () => {
  await switchTo("progress");
  const statusOf = async () => (await query("story.progress.live.status"))[0]?.text ?? "";
  await waitFor(async () => ((await statusOf()) === "live = 30%" ? true : null), 4000, 50);
  const step = await screenPos("story.progress.step");
  for (let i = 0; i < 7; i++) {
    await clickAt(step.x + step.w / 2, step.y + step.h / 2);
    await sleep(80);
  }
  await waitFor(async () => ((await statusOf()) === "live = 100%" ? true : null), 4000, 50).catch(() => {});
  assert((await statusOf()) === "live = 100%", `7 次 +10% 后应为 100%，got "${await statusOf()}"`);
  // button disabled by derived value when 100: next click shouldn't exceed
  await clickAt(step.x + step.w / 2, step.y + step.h / 2);
  await sleep(150);
  assert((await statusOf()) === "live = 100%", `禁用后点击不应改变进度，got "${await statusOf()}"`);
  await shot("progress-live-full");
  const reset = await screenPos("story.progress.reset");
  await clickAt(reset.x + reset.w / 2, reset.y + reset.h / 2);
  await waitFor(async () => ((await statusOf()) === "live = 0%" ? true : null), 4000, 50).catch(() => {});
  assert((await statusOf()) === "live = 0%", `Reset 后应为 0%，got "${await statusOf()}"`);
});

test("Badge: 交互 — 计数 signal 驱动文本，归零派生为点状", async () => {
  await switchTo("badge");
  const badgeText = async () => (await query("story.badge.live"))[0]?.text ?? "";
  await waitFor(async () => ((await badgeText()) === "3" ? true : null), 4000, 50);
  const add = await screenPos("story.badge.add");
  await clickAt(add.x + add.w / 2, add.y + add.h / 2);
  await waitFor(async () => ((await badgeText()) === "4" ? true : null), 4000, 50).catch(() => {});
  assert((await badgeText()) === "4", `+1 后徽章应显示 4，got "${await badgeText()}"`);
  const clear = await screenPos("story.badge.clear");
  await clickAt(clear.x + clear.w / 2, clear.y + clear.h / 2);
  await waitFor(async () => ((await badgeText()) === "" ? true : null), 4000, 50).catch(() => {});
  assert((await badgeText()) === "", `清零后应为点状（无文本），got "${await badgeText()}"`);
  const dot = await screenPos("story.badge.live");
  assert(Math.round(dot.w) === 8 && Math.round(dot.h) === 8, `点状徽章应为 8×8，got ${dot.w}×${dot.h}`);
  await shot("badge-live-dot");
});

// ── interaction: Slider click track, screenshot proves thumb/value move ──
test("Slider: 交互 — 点 track 改值", async () => {
  await switchTo("slider");
  const pos = await screenPos("story.slider.track");
  appendLog(`  slider track: x=${pos.x} y=${pos.y} w=${pos.w}`);
  await clickAt(pos.x + pos.w * 0.8, pos.y + pos.h / 2);
  await sleep(250);
  // first slider value rises to ~80 after clicking 80%
  const texts = await storyTexts("slider");
  appendLog(`  slider texts after click: ${texts}`);
  await shot("slider-after-click");
  assert((await health()).status === "ok", "app died after slider interaction");
});

// ── interaction: Drag primitive, drag changes state/geometry, click suppression, Escape
// cancels/reverts ──
// Primary semantic assertions (docs sec 18.4), screenshots visual aid only.
test("Slider: stepped drag stays snapped and ends on release", async () => {
  await switchTo("slider");
  const pos = await screenPos("story.slider.stepped.track");
  const y = pos.y + pos.h / 2;
  const expectValue = async (value: string) => {
    await waitFor(async () => {
      const nodes = await query("story.slider.stepped");
      return findRectByText(nodes[0], value);
    }, getE2eTimeoutMs(2000), 40).catch(async () => {
      throw new Error(`expected slider ${value}; state=${JSON.stringify(await query("story.slider.stepped"))}`);
    });
  };
  assert((await mouseDown(pos.x + pos.w * 0.5, y)).ok === true);
  try {
    await expectValue("5.0");
    assert((await mouseMove(pos.x + pos.w * 0.61, y)).ok === true);
    await expectValue("6.0");
    assert((await mouseMove(pos.x + pos.w * 0.64, y)).ok === true);
    await expectValue("6.0");
    assert((await mouseMove(pos.x + pos.w * 0.9, y)).ok === true);
    await expectValue("9.0");
  } finally {
    assert((await mouseUp(pos.x + pos.w * 0.9, y)).ok === true);
  }
  assert((await mouseMove(pos.x + pos.w * 0.1, y)).ok === true);
  await expectValue("9.0");
  await shot("slider-stepped-drag");
});

test("Slider: feedback playground is opt-in and can be reset and disabled", async () => {
  // Re-selecting the active story preserves state; remount before checking
  // the default-off contract independently of the preceding drag test.
  await switchTo("slider");
  const status = async () => (await query("story.slider.feedback.status"))[0]?.text ?? "";
  const expectStatus = async (text: string) => {
    await waitFor(async () => (await status()) === text ? true : null, getE2eTimeoutMs(2000), 40)
      .catch(async () => { throw new Error(`expected ${text}; got ${await status()}`); });
  };
  await expectStatus("Feedback: off | stepped: 5.0 | continuous: 5.0");
  assert((await clickTestId("story.slider.feedback.toggle")).ok === true);
  await expectStatus("Feedback: on | stepped: 5.0 | continuous: 5.0");
  const basic = await screenPos("story.slider.track");
  const basicY = basic.y + basic.h / 2;
  assert((await mouseDown(basic.x + basic.w * 0.4, basicY)).ok === true);
  try {
    assert((await mouseMove(basic.x + basic.w * 0.8, basicY)).ok === true);
    await waitFor(async () => findRectByText((await query("story.slider.basic"))[0], "80.0"), getE2eTimeoutMs(2000), 40);
  } finally {
    assert((await mouseUp(basic.x + basic.w * 0.8, basicY)).ok === true);
  }
  const stepped = await screenPos("story.slider.stepped.track");
  const y = stepped.y + stepped.h / 2;
  assert((await mouseDown(stepped.x + stepped.w * 0.5, y)).ok === true);
  try {
    assert((await mouseMove(stepped.x + stepped.w * 0.81, y)).ok === true);
    await expectStatus("Feedback: on | stepped: 8.0 | continuous: 5.0");
  } finally {
    await mouseUp(stepped.x + stepped.w * 0.81, y);
  }
  const continuous = await screenPos("story.slider.continuous.track");
  assert((await clickAt(continuous.x + continuous.w * 0.63, continuous.y + continuous.h / 2)).ok === true);
  await expectStatus("Feedback: on | stepped: 8.0 | continuous: 6.3");
  await shot("slider-feedback-on");
  assert((await clickTestId("story.slider.feedback.reset")).ok === true);
  await expectStatus("Feedback: on | stepped: 5.0 | continuous: 5.0");
  assert((await clickTestId("story.slider.feedback.toggle")).ok === true);
  await expectStatus("Feedback: off | stepped: 5.0 | continuous: 5.0");
  assert((await clickAt(stepped.x + stepped.w * 0.7, y)).ok === true);
  await expectStatus("Feedback: off | stepped: 7.0 | continuous: 5.0");
  await shot("slider-feedback-off");
});

test("Slider: native patterns are selectable without implicitly enabling feedback", async () => {
  await switchTo("slider");
  const expectPattern = async (name: string) => {
    await waitFor(async () => (await query("story.slider.feedback.pattern"))[0]?.text === `Pattern: ${name}` ? true : null,
      getE2eTimeoutMs(2000), 40);
  };
  const expectEnabled = async (enabled: boolean) => {
    const text = (await query("story.slider.feedback.status"))[0]?.text ?? "";
    assert(text.startsWith(`Feedback: ${enabled ? "on" : "off"} |`), `wrong feedback state: ${text}`);
  };
  await expectPattern("Alignment");
  assert((await clickTestId("story.slider.pattern.generic")).ok === true);
  await expectPattern("Generic");
  await expectEnabled(false);
  assert((await clickTestId("story.slider.feedback.toggle")).ok === true);
  for (const [id, name, ratio, value] of [
    ["generic", "Generic", 0.7, "7.0"],
    ["level_change", "Level change", 0.3, "3.0"],
    ["alignment", "Alignment", 0.6, "6.0"],
  ] as const) {
    assert((await clickTestId(`story.slider.pattern.${id}`)).ok === true);
    await expectPattern(name);
    await expectEnabled(true);
    const track = await screenPos("story.slider.stepped.track");
    assert((await clickAt(track.x + track.w * ratio, track.y + track.h / 2)).ok === true);
    await waitFor(async () => findRectByText((await query("story.slider.stepped"))[0], value), getE2eTimeoutMs(2000), 40);
  }
  assert((await clickTestId("story.slider.feedback.toggle")).ok === true);
  assert((await clickTestId("story.slider.pattern.level_change")).ok === true);
  await expectPattern("Level change");
  await expectEnabled(false);
  await shot("slider-pattern-settings");
});

test("Drag: 交互 — 拖动方块 + click 抑制 + Escape 取消", async () => {
  await switchTo("drag");
  const box = await screenPos("story.drag.box");
  const cx0 = box.x + box.w / 2;
  const cy0 = box.y + box.h / 2;

  // 1) drag 60px: status -> end, click suppressed (stay 0)
  await mouseDown(cx0, cy0);
  await mouseMove(cx0 + 30, cy0 + 10);
  await mouseMove(cx0 + 60, cy0 + 20);
  await mouseUp(cx0 + 60, cy0 + 20);
  await sleep(250);
  let texts = await storyTexts("drag");
  appendLog(`  drag texts after drag: ${texts}`);
  assert(texts.includes("state: end"), `drag end 状态未出现: ${texts}`);
  assert(texts.includes("clicks: 0"), `drag 后 click 未被抑制: ${texts}`);
  // square really moved by delta (geometry verification)
  const moved = await screenPos("story.drag.box");
  assert(Math.abs(moved.x - box.x - 60) <= 2, `box 未按 delta.x=60 移动: ${box.x} -> ${moved.x}`);

  // 2) short click in place (below threshold): click stays valid, count +1
  await clickAt(moved.x + moved.w / 2, moved.y + moved.h / 2);
  await sleep(250);
  texts = await storyTexts("drag");
  assert(texts.includes("clicks: 1"), `普通 click 未恢复: ${texts}`);

  // 3) Escape during drag: cancel text + position reverts, late up no click
  const p2 = await screenPos("story.drag.box");
  const cx2 = p2.x + p2.w / 2;
  const cy2 = p2.y + p2.h / 2;
  await mouseDown(cx2, cy2);
  await mouseMove(cx2 + 40, cy2);
  await key("escape");
  await mouseUp(cx2 + 40, cy2);
  await sleep(250);
  texts = await storyTexts("drag");
  appendLog(`  drag texts after escape: ${texts}`);
  assert(texts.includes("state: cancel (escape)"), `Escape 取消状态未出现: ${texts}`);
  assert(texts.includes("clicks: 1"), `取消后的 up 不应产生 click: ${texts}`);
  const back = await screenPos("story.drag.box");
  assert(Math.abs(back.x - p2.x) <= 2, `cancel 未回滚位置: ${p2.x} -> ${back.x}`);

  await shot("drag-after-interactions");
  assert((await health()).status === "ok", "app died after drag interaction");
});

// ── interaction: Modal click button opens -> dialog visible + centered + body text ──
// blend_mode end-to-end pixel acceptance (2026-07-30 wired). Colors use 0/255, sRGB transfer
// unchanged at 0/1, blend results consistent, assert exact values. Prior both disconnected,
// multiply silently degraded, multiply position reads cyan not green, must fail.
test("BlendModes: 像素 — multiply/screen/difference 精确色值 + normal 对照", async () => {
  await switchTo("blend");
  await sleep(400); // settle
  await shot("blend-modes");
  const png = `${DIR}/story-blend-modes.png`;

  const cases: Array<[string, [number, number, number]]> = [
    ["story.blend.multiply", [0, 255, 0]],     // yellow x cyan
    ["story.blend.screen", [255, 0, 255]],     // red + blue
    ["story.blend.difference", [0, 255, 255]], // |white - red|
    ["story.blend.control", [0, 255, 255]], // control reference: hold cyan
  ];
  for (const [id, expected] of cases) {
    const nodes = await query(id);
    assert(nodes.length > 0 && nodes[0].rect.w > 10, `${id} 节点没布局出来`);
    assertColorNear(centerPixel(png, nodes[0].rect), expected, id);
  }
});

// Regression: Modal was unusable; the barrier's absolute grow / grow containing block is the 844px
// content panel (inline, not the window), so after open only an 844x32 misaligned bar showed,
// dialog uncentered, body h=0. Fix: window-root portal + content uses inline scale_fade (not a
// composited surface, which draws the centered dialog back at (0,0)).
// Clicks the real button and asserts the dialog is centered and visible.
test("Modal: 交互 — 打开后 dialog 居中可见 + body 文本", async () => {
  await switchTo("modal");
  await shot("modal-closed");
  // click real button (use test_id, not hand-calculated coords)
  const btn = await screenPos("story.modal.open");
  await clickAt(btn.x + btn.w / 2, btn.y + btn.h / 2);
  await sleep(900); // wait for entrance animation settle
  await shot("modal-open");

  // dialog must truly layout (not 0x0)
  const dlg = (await query("story.modal.dialog"))[0];
  assert(dlg != null, "modal dialog 节点查不到（未打开？）");
  const r = dlg.rect;
  appendLog(`  modal dialog rect=(${Math.round(r.x)},${Math.round(r.y)} ${Math.round(r.w)}x${Math.round(r.h)})`);
  assert(r.w > 100 && r.h > 40, `modal dialog 尺寸异常 (${r.w}x${r.h}) — 应是真实 dialog`);

  // centered: dialog center should be near window horizontal center (window width 1100,
  // center ~550). Old bug positioned dialog left of panel (x~228).
  const cx_dialog = r.x + r.w / 2;
  assert(cx_dialog > 400, `modal dialog 未水平居中 (center_x=${Math.round(cx_dialog)}, 应 > 400)`);

  // body text must be visible (h > 0). Old bug gave body h=0.
  const out: string[] = [];
  collectText(dlg, out);
  const joined = out.join(" │ ");
  appendLog(`  modal dialog texts: ${joined}`);
  assert(joined.includes("Example Modal"), `modal 缺标题 — 实际: ${joined}`);
  assert(joined.includes("Modal body content."), `modal 缺 body 文本 — 实际: ${joined}`);

  // pixel-level: settled dialog must truly render text (regression gate: settle frame
  // blank panel bug).
  assertRegionHasInk(`${DIR}/story-modal-open.png`, r, "modal dialog pixels");

  // Negative pixel gate: the dialog-left backdrop region must be ink-free. A GPU retained
  // missed-path
  // forgot the pipeline flush before the layer, so the entire page content (including the Open
  // Modal
  // button) was flushed into the cached overlay surface texture, appearing as a duplicate dark
  // button/text in the backdrop. Positive "has ink" gates alone can't catch this. Sample region:
  // the pure-dim area left of the dialog.
  {
    const png = decodePng(`${DIR}/story-modal-open.png`);
    const scale = captureScale(`${DIR}/story-modal-open.png`, png.width);
    const leftOfDialog = { x: 300, y: r.y, w: Math.max(60, r.x - 320), h: r.h };
    const stray = countDarkPixels(png, leftOfDialog, scale);
    appendLog(`  modal backdrop stray ink: dark_pixels=${stray} (max=50)`);
    assert(stray <= 50, `modal backdrop 出现不该有的内容（dark=${stray} > 50）— 疑似 surface 纹理被污染/错位合成`);
  }

  // Key regression (hit-test): clicking dialog interior/text must NEVER close the modal.
  // Barrier/content need a pointer hit role; without it clicks pass through to the background
  // ScrollArea, outside-click logic sees "clicked outside content", and any click closes.
  // Dialog node is reused across open/close, not destroyed; the visible field judges state
  // (a closed query still returns the node but visible=false).
  const dcx = r.x + r.w / 2, dcy = r.y + r.h * 0.75; // dialog lower-half blank area
  await clickAt(dcx, dcy);
  await sleep(500);
  const afterInside = (await query("story.modal.dialog"))[0];
  appendLog(`  after inside-dialog click, visible=${afterInside?.visible}`);
  assert(afterInside?.visible !== false, `点 dialog 内部竟关闭了 modal（hit-test 穿透）`);

  // click x close, must truly trigger x handler (not leak-click outside-dismiss).
  await clickTestId("modal.close");
  await sleep(800);
  const closed = (await query("story.modal.dialog"))[0];
  appendLog(`  after × click, dialog visible=${closed?.visible}`);
  assert(closed?.visible === false, `× 关闭按钮没生效（dialog 仍 visible）`);
  assert((await health()).status === "ok", "app died after closing modal");
});

// Interaction verify: Sheet click button open -> panel stuck right visible + content text
/// Find the panel/backdrop boundary using their measured luminance contrast.
/// During fade-in the panel is legitimately translucent; a fixed white-pixel
/// threshold misclassifies that whole moving panel as backdrop on Windows.
function sheetPanelEdgeX(pngPath: string, logicalY: number): number | null {
  const png = decodePng(pngPath);
  const scale = captureScale(pngPath, png.width);
  const y = Math.round(logicalY * scale);
  const luminance = (x: number) => {
    const i = (y * png.width + x) * png.channels;
    return (png.pixels[i] + png.pixels[i + 1] + png.pixels[i + 2]) / 3;
  };
  const mean = (start: number, end: number) => {
    let sum = 0;
    for (let x = start; x < end; x++) sum += luminance(x);
    return sum / (end-start);
  };
  const panel = mean(png.width-16, png.width-4);
  const backdrop = mean(Math.floor(png.width*.60), Math.floor(png.width*.65));
  // A uniform/blank frame must fail; do not turn any arbitrary image into an
  // edge. This row is intentionally below the fixture's text and controls.
  if (panel-backdrop < 8) return null;
  const threshold = (panel+backdrop)/2;
  for (let x = png.width - 1; x > png.width * 0.3; x--) {
    if (luminance(x) < threshold) return (x + 1) / scale;
  }
  return null;
}

test("Sheet: 交互 — 打开后 panel 贴边可见 + content 文本", async () => {
  await switchTo("sheet");
  const backend = (await stats()).renderer_backend;
  const nativeSample = backend === "legacy" || backend === "d3d12" || backend === "d3d11" || backend === "opengl";
  const viewportWidth = (await tree()).rect.w;
  assert(viewportWidth > 0, "missing native client width");
  let nativeSampleX: number | undefined;
  if (nativeSample) {
    await useAnimationClock();
    const samplePath = `${DIR}/story-sheet-mid-anim.png`;
    const sampleWidth = (await tree()).rect.w;
    assert(sampleWidth > 0, "missing native client width");
    const sample = await captureFrameAt("story.sheet.panel", "story.sheet.open", 120, samplePath);
    captureWidths.set(samplePath, sampleWidth);
    nativeSampleX = sample.x;
    assert(sample.ok, `native Sheet sample failed: ${JSON.stringify(sample)}`);
    appendLog(`  native Sheet capture requested=${sample.requested_ms}ms actual=${sample.sample_ms}ms x=${sample.x}`);
    assert(sample.requested_ms === 120 && sample.sample_ms >= 120 && sample.sample_ms <= 200,
      `Sheet sample missed 120ms deadline by more than one 80ms slow frame: ${sample.sample_ms}ms`);
  } else {
    const btn = await screenPos("story.sheet.open");
    await clickAt(btn.x + btn.w / 2, btn.y + btn.h / 2);
    // Without native frame capture the sample instant is sleep + screenshot
    // latency. The overlay now starts on its first clean geometry observation
    // (no extra two-frame warmup), so 120 ms lands in the ease-out-quint tail
    // (~2 px from settle under suite load). 60 ms restores the old margin; a
    // frozen animation still reads exactly the settled edge (780).
    await sleep(60);
    await shot("sheet-mid-anim");
  }

  // Animation mid-frame pixel gate (Sheet freeze regression).
  // GPU retained fingerprint must cover nested begin_opacity_layer composite params: a child
  // layer's
  // transform changes every frame but the parent layer (window-root overlay group) fingerprint
  // stays
  // the same -> parent stale every frame -> slide-in pixels frozen, jump to end on completion.
  // The layout tree advances normally, so rect assertions pass; only mid-animation pixels catch it.
  // Settlement at x~780; assert at t~120ms that the panel left edge is "entered but not settled".
  const midEdge = sheetPanelEdgeX(`${DIR}/story-sheet-mid-anim.png`, 500);
  const sampledPanel = (await query("story.sheet.panel"))[0];
  assert(sampledPanel != null && sampledPanel.rect.w > 0, "missing Sheet panel geometry");
  const settledEdge = viewportWidth - sampledPanel.rect.w;
  if (nativeSampleX !== undefined) assert(midEdge != null && Math.abs(midEdge - nativeSampleX) <= 2,
    `captured Sheet pixels do not match sampled geometry: ${midEdge} vs ${nativeSampleX}`);
  appendLog(`  sheet mid-anim panel edge x=${midEdge == null ? "none" : Math.round(midEdge)}`);
  assert(
    midEdge != null && midEdge > settledEdge + 8 && midEdge < viewportWidth - 2,
    `sheet 滑入动画中段面板位置异常 (edge=${midEdge == null ? "不可见" : Math.round(midEdge)}) — ` +
      `应在 (${settledEdge + 8},${viewportWidth - 2}) 之间；=${settledEdge} 表示画面直接跳到终点（动画冻结），不可见表示还没入场`,
  );

  await animSleep(780);
  await shot("sheet-open");

  const panel = (await query("story.sheet.panel"))[0];
  assert(panel != null, "sheet panel 节点查不到（未打开？）");
  const r = panel.rect;
  appendLog(`  sheet panel rect=(${Math.round(r.x)},${Math.round(r.y)} ${Math.round(r.w)}x${Math.round(r.h)})`);
  assert(r.w > 100 && r.h > 100, `sheet panel 尺寸异常 (${r.w}x${r.h})`);
  // side=right: panel right edge should approach window right edge (~1100).
  assert(r.x + r.w > 900, `sheet panel 未贴右边 (right=${Math.round(r.x + r.w)})`);

  const out: string[] = [];
  collectText(panel, out);
  assert(out.join(" ").includes("Sheet panel content."), `sheet 缺 content 文本 — 实际: ${out.join(" ")}`);

  // pixel-level: settled panel must truly render text (regression gate: settle frame
  // blank panel bug).
  assertRegionHasInk(`${DIR}/story-sheet-open.png`, r, "sheet panel pixels");

  // key regression (hit-test): click panel interior must NOT close; click left backdrop
  // blank close. Also must close sheet; sheet barrier now truly blocks clicks (modal
  // semantics), not closing blocks subsequent nav switch.
  await clickAt(r.x + r.w / 2, r.y + r.h / 2); // panel interior
  await animSleep(400);
  const afterInside = (await query("story.sheet.panel"))[0];
  assert(afterInside?.visible !== false, `点 sheet panel 内部竟关闭了（hit-test 穿透）`);
  await clickAt(80, 500); // left backdrop (panel on right)
  await animSleep(600);
  const closed = (await query("story.sheet.panel"))[0];
  appendLog(`  after backdrop click, sheet panel visible=${closed?.visible}`);
  assert(closed?.visible === false, `sheet backdrop 点击未关闭`);
  assert((await health()).status === "ok", "app died after closing sheet");
});

// ── interaction: Menu click trigger opens -> popup appears with item data ──
function findRectByText(node: any, label: string): any {
  if (node?.text === label) return node.rect ?? null;
  for (const c of node?.children ?? []) {
    const r = findRectByText(c, label);
    if (r) return r;
  }
  return null;
}

test("Notification: 九种类型、折叠 / 展开堆叠、悬停暂停、删除中间一条平滑补位、八个位置、原地转换", async () => {
  await switchTo("notification");

  // notification attaches to window-root portal; collect only notification cards + badges, exclude
  // host history (same titles visible when closed).
  async function fullTreeTexts(): Promise<string> {
    const o: string[] = [];
    const walk = (n: any) => {
      if (n.component === "Notification" || n.component === "Notification.pill") collectText(n, o);
      else for (const c of n.children ?? []) walk(c);
    };
    walk(await tree());
    return o.join(" │ ");
  }
  async function windowSize(): Promise<{ w: number; h: number }> {
    const full = await tree();
    return { w: full.rect.w, h: full.rect.h };
  }
  // hover determined by real pointer hit-test each frame (16.7). If window pops under physical
  // mouse, real motion events override injected (measured (427,748) non-injected), reissue during
  // wait.
  async function holdPointer(x: number, y: number, ms: number): Promise<void> {
    const end = Date.now() + ms;
    while (Date.now() < end) {
      await mouseMove(x, y);
      await sleep(Math.min(100, Math.max(0, end - Date.now())));
    }
  }
  async function clearAll(): Promise<void> {
    await mouseMove(-10, -10);
    await clickTestId("story.notify.btn.clear");
    await sleep(600);
  }
  const win = await windowSize();
  await clearAll();

  // 1. success card: enters, sticks bottom-center anchor (22 margin), hover pauses timer.
  await clickTestId("story.notify.btn.success");
  // Establish the real hover before expensive readbacks consume the card's
  // finite lifetime. Keep the same >3600ms pause and resume/expiry assertions.
  const hoverReady = await waitFor(async () => {
    const card = (await query("story.notify.success"))[0];
    return card && card.rect.w > 0 && card.rect.h > 0 &&
      card.rect.y >= 0 && card.rect.y + card.rect.h <= win.h ? card.rect : null;
  }, getE2eTimeoutMs(2000), 30);
  await mouseMove(hoverReady.x + 200, hoverReady.y + hoverReady.h / 2);
  await shot("notify-success-entering");
  await sleep(700);
  await shot("notify-success-settled");
  let joined = await fullTreeTexts();
  assert(joined.includes("已保存到 iCloud"), `success 缺文本 — ${joined}`);
  const success = await screenPos("story.notify.success");
  appendLog(`  success rect: ${JSON.stringify(success)} window ${JSON.stringify(win)}`);
  assert(Math.abs(success.w - 392) < 0.5, `卡片宽度应为 392: ${success.w}`);
  assert(Math.abs(success.x + success.w / 2 - win.w / 2) < 1, `bottom-center 未水平居中: ${success.x}`);
  assert(Math.abs(success.y + success.h - (win.h - 22)) < 1.5, `底部边距应为 22: bottom=${success.y + success.h}`);
  assertRegionHasInk(`${DIR}/story-notify-success-settled.png`, success, "success card pixels", 50);
  await holdPointer(success.x + 200, success.y + success.h / 2, 4200); // already exceeded 3600ms dwell, hover must keep it.
  await shot("notify-success-hover-paused");
  assert((await fullTreeTexts()).includes("已保存到 iCloud"), "悬停没有暂停计时");
  await mouseMove(-10, -10);
  await waitFor(async () => ((await fullTreeTexts()).includes("已保存到 iCloud") ? null : true), 5000, 100);
  await shot("notify-success-expired");

  // 2. nine types all pop (pixel comparison vs design separate).
  for (const [kind, text] of [
    ["error", "network timeout"],
    ["warning", "磁盘空间不足"],
    ["progress", "正在上传附件"],
    ["action", "邀请你加入文档"],
    ["person", "林可可"],
    ["undo", "已移动 4 个项目到废纸篓"],
    ["quiet", "已切换到分支"],
    ["digest", "勿扰期间收到 7 条提醒"],
  ] as const) {
    await clearAll();
    await useAnimationClock();
    await clickTestId(`story.notify.btn.${kind}`);
    await animSleep(700);
    // Read the transient state before the (slow) capture; the shot is evidence.
    assert((await fullTreeTexts()).includes(text), `${kind} 未出现: ${text}`);
    await shot(`notify-kind-${kind}`);
    await useRealtimeClock();
  }
  await clearAll();

  // 3. send 4: stacked collapse shows 9px of top layer, newest topmost (closest to anchor).
  await clickTestId("story.notify.btn.burst");
  await sleep(800);
  await shot("notify-stack-collapsed");
  const c0 = await screenPos("story.notify.stack.3");
  const c1 = await screenPos("story.notify.stack.2");
  const c2 = await screenPos("story.notify.stack.1");
  appendLog(`  collapsed tops: ${c0.y} ${c1.y} ${c2.y}`);
  // collapsed clipped to top layer height: bottom edges step up 9px.
  assert(Math.abs((c0.y + c0.h) - (c1.y + c1.h) - 9) < 1, `第 2 层露边应为 9px: ${(c0.y + c0.h) - (c1.y + c1.h)}`);
  assert(Math.abs((c1.y + c1.h) - (c2.y + c2.h) - 9) < 1, `第 3 层露边应为 9px`);
  joined = await fullTreeTexts();
  assert(joined.includes("还有 3 条 · 悬停展开"), `折叠角标文案不对 — ${joined}`);

  // 4. hover expand: full height, 9px spacing; badge becomes 'hovering'.
  await holdPointer(c0.x + 200, c0.y + c0.h / 2, 800);
  await shot("notify-stack-expanded");
  const e0 = await screenPos("story.notify.stack.3");
  const e1 = await screenPos("story.notify.stack.2");
  const e2 = await screenPos("story.notify.stack.1");
  const e3 = await screenPos("story.notify.stack.0");
  appendLog(`  expanded: ${JSON.stringify([e0, e1, e2, e3].map((r) => [r.y, r.h]))}`);
  assert(Math.abs(e0.y - (e1.y + e1.h) - 9) < 1, `展开间距应为 9: ${e0.y - (e1.y + e1.h)}`);
  assert(Math.abs(e1.y - (e2.y + e2.h) - 9) < 1, `展开间距应为 9`);
  assert(Math.abs(e2.y - (e3.y + e3.h) - 9) < 1, `展开间距应为 9`);
  assert((await fullTreeTexts()).includes("悬停中 · 全部计时已暂停"), "展开角标文案不对");

  // 5. delete middle: below compensates continuously (per-frame monotonic, no jumps), others
  //    unchanged.
  const before = e3.y;
  await useAnimationClock();
  const observation = await startFrameObservation("story.notify.stack.0");
  await clickTestId("story.notify.stack.1.close");
  // pointer left on deleted card's ×; after reflow may be outside stack, animation end checks real
  // coords and collapses (16.7 spec). Simulate user keeps hovering: pointer back to top layer (same
  // position). Reflow is 300ms cubicBezier(0.22,0.92,0.24,1): slope~4.2, 60ms walks ~80%, single
  // step < total 70% contradicts (first sample depends on RPC latency). True semantics: observe
  // positions between start/end (no teleport), monotonic, end correct. Windows samples locally
  // post-submit, others keep RPC sampling.
  const target = before + e2.h + 9;
  const samples: number[] = [];
  if (observation.supported) {
    await holdPointer(e0.x + 200, e0.y + e0.h / 2, 500);
    await animSleep(500);
    const observed = await readFrameObservation();
    appendLog(`  submitted reflow frames: ${JSON.stringify(observed)}`);
    assert(!observed.overflow && observed.missing === 0, "补位帧观察不完整");
    assert(observed.frames.length >= 3, "补位提交帧不足");
    samples.push(...observed.frames.map((frame) => frame.y));
    samples.push((await screenPos("story.notify.stack.0")).y);
  } else {
    for (let i = 0; i < 8; i++) {
      samples.push((await screenPos("story.notify.stack.0")).y);
      await holdPointer(e0.x + 200, e0.y + e0.h / 2, 40);
    }
  }
  await useRealtimeClock();
  await shot("notify-stack-middle-removed");
  appendLog(`  reflow samples (${samples.length} frames): before=${before} target=${target} ${samples.join(", ")}`);
  let prev = before;
  for (const y of samples) {
    assert(y >= prev - 0.5, `补位方向不对（应向下补）: ${prev} → ${y}`);
    prev = y;
  }
  const intermediate = samples.filter((y) => y > before + 1 && y < target - 1);
  assert(intermediate.length > 0, `补位没有过渡（瞬移）: ${samples.join(", ")}`);
  const settled = samples[samples.length - 1];
  assert(Math.abs(settled - target) < 2, `补位终点不对: ${settled} vs ${target}`);
  assert((await query("story.notify.stack.1")).length === 0, "被关闭的中间一条没有移除");
  assert((await query("story.notify.stack.3")).length === 1, "上方卡片被重建（test id 丢失）");
  await clearAll();

  // 6. eight positions: anchor + symbol. Assert representative four corners + two sides.
  for (const [pos, check] of [
    ["tr", (r: any) => Math.abs(r.x + r.w - (win.w - 22)) < 1.5 && Math.abs(r.y - (56 + 22)) < 1.5],
    ["tl", (r: any) => Math.abs(r.x - 22) < 1.5 && Math.abs(r.y - (56 + 22)) < 1.5],
    ["bl", (r: any) => Math.abs(r.x - 22) < 1.5 && Math.abs(r.y + r.h - (win.h - 22)) < 1.5],
    ["rc", (r: any) => Math.abs(r.x + r.w - (win.w - 22)) < 1.5 && Math.abs(r.y + r.h / 2 - (56 + (win.h - 56) / 2)) < 1.5],
    ["lc", (r: any) => Math.abs(r.x - 22) < 1.5],
  ] as const) {
    await clickTestId(`story.notify.pos.${pos}`);
    await clickTestId("story.notify.btn.warning");
    await sleep(800);
    await shot(`notify-position-${pos}`);
    const r = await screenPos("story.notify.warning");
    appendLog(`  position ${pos}: ${JSON.stringify(r)}`);
    assert(check(r), `位置 ${pos} 几何不对: ${JSON.stringify(r)}`);
    await clearAll();
  }
  await clickTestId("story.notify.pos.bc");

  // 7. in-place morph: undo -> ring -> checkmark; accept -> remove buttons, height shrinks. Card
  //    not rebuilt (test_id kept).
  await clickTestId("story.notify.btn.undo");
  await sleep(700);
  const undoBefore = await screenPos("story.notify.undo");
  await clickTestId("story.notify.undo.action.0");
  await sleep(500);
  await shot("notify-undo-settled");
  const status1: string[] = [];
  const st1 = await query("story.notify.status");
  if (st1[0]) collectText(st1[0], status1);
  assert(status1.join(" ").includes("undo"), `撤销事件未上报 — ${status1.join(" ")}`);
  const undoAfter = await screenPos("story.notify.undo");
  assert(undoAfter.h < undoBefore.h - 20, `撤销后按钮区应移除: ${undoBefore.h} → ${undoAfter.h}`);
  await clearAll();

  await clickTestId("story.notify.btn.action");
  await sleep(700);
  const acceptBefore = await screenPos("story.notify.action");
  await clickTestId("story.notify.action.action.0");
  await sleep(700);
  await shot("notify-accept-settled");
  const acceptAfter = await screenPos("story.notify.action");
  assert(acceptAfter.h < acceptBefore.h - 20, `接受后按钮区应移除: ${acceptBefore.h} → ${acceptAfter.h}`);
  assert((await fullTreeTexts()).includes("已加入文档"), "接受后标题未改写");
  await clearAll();
});

test("Notification: 触控板横扫按 ended 关闭、cancelled 弹回，鼠标滚轮不驱动横扫", async () => {
  await switchTo("notification");
  async function cardTexts(): Promise<string> {
    const o: string[] = [];
    const walk = (n: any) => {
      if (n.component === "Notification") collectText(n, o);
      else for (const c of n.children ?? []) walk(c);
    };
    walk(await tree());
    return o.join(" │ ");
  }
  async function clearAll(): Promise<void> {
    await mouseMove(-10, -10);
    await clickTestId("story.notify.btn.clear");
    await sleep(600);
  }
  await clearAll();
  await clickTestId("story.notify.btn.warning");
  await sleep(700);
  const w0 = await screenPos("story.notify.warning");
  const x = w0.x + 120, y = w0.y + w0.h / 2;
  // scrollAt supplies a dispatch location, not pointer motion. Put the pointer
  // over the card as a real wheel/trackpad interaction would, so auto-expiry
  // cannot masquerade as gesture dismissal while RPC steps are in progress.
  await mouseMove(x, y);

  // scroll wheel has no gesture phase: no swipe, card still, no close
  for (let i = 0; i < 8; i++) {
    await scrollAt(x, y, 30, 0);
    await sleep(16);
  }
  await sleep(500);
  const w1 = await screenPos("story.notify.warning");
  assert(Math.abs(w1.x - w0.x) < 1, `滚轮不应移动卡片: ${w0.x} -> ${w1.x}`);
  assert((await cardTexts()).includes("磁盘空间不足"), "滚轮把通知关掉了");

  // gesture cancelled by system: even over threshold, snaps back
  await scrollAt(x, y, 0, 0, { phase: "began" });
  for (let i = 0; i < 8; i++) {
    await scrollAt(x, y, 20, 0, { phase: "changed" });
    await sleep(16);
  }
  await scrollAt(x, y, 0, 0, { phase: "cancelled" });
  await sleep(700);
  const w2 = await screenPos("story.notify.warning");
  assert(Math.abs(w2.x - w0.x) < 1, `cancelled 应弹回: ${w0.x} -> ${w2.x}`);
  assert((await cardTexts()).includes("磁盘空间不足"), "cancelled 却关闭了通知");

  // long pause won't auto-release; ended over 84px threshold closes
  await scrollAt(x, y, 0, 0, { phase: "began" });
  for (let i = 0; i < 8; i++) {
    await scrollAt(x, y, 20, 0, { phase: "changed" });
    await sleep(16);
  }
  await sleep(600);
  assert((await cardTexts()).includes("磁盘空间不足"), "手指还在板上，通知不应被关闭");
  await scrollAt(x, y, 0, 0, { phase: "ended" });
  await sleep(700);
  assert(!(await cardTexts()).includes("磁盘空间不足"), "ended 越过阈值后没有关闭");
  await clearAll();
});

test("Notification: 拖拽关闭（84px 阈值 / 弹回 / 甩出）、不可拖拽区、内联回复 Enter 提交", async () => {
  await switchTo("notification");
  // query notification card only (host center history may have same title on tree).
  async function fullTreeTexts(): Promise<string> {
    const o: string[] = [];
    const walk = (n: any) => {
      if (n.component === "Notification") collectText(n, o);
      else for (const c of n.children ?? []) walk(c);
    };
    walk(await tree());
    return o.join(" │ ");
  }
  async function clearAll(): Promise<void> {
    await mouseMove(-10, -10);
    await clickTestId("story.notify.btn.clear");
    await sleep(600);
  }
  // real pointer drag: move per step, one frame each.
  async function dragBy(x: number, y: number, dx: number): Promise<void> {
    await mouseDown(x, y);
    const steps = 8;
    for (let i = 1; i <= steps; i++) {
      await mouseMove(x + (dx * i) / steps, y);
      await sleep(16);
    }
    await mouseUp(x + dx, y);
  }
  await clearAll();

  // 1. dx=40: below threshold, release snaps back.
  await clickTestId("story.notify.btn.warning");
  await sleep(700);
  const w0 = await screenPos("story.notify.warning");
  await dragBy(w0.x + 120, w0.y + w0.h / 2, 40);
  await shot("notify-swipe-under-threshold-released");
  await sleep(700);
  const w1 = await screenPos("story.notify.warning");
  appendLog(`  swipe 40 → x ${w0.x} → ${w1.x}`);
  assert(Math.abs(w1.x - w0.x) < 1, `未达阈值应弹回: ${w0.x} → ${w1.x}`);
  assert((await fullTreeTexts()).includes("磁盘空间不足"), "未达阈值却被关闭");

  // 2. dx=130: exceeds 84px, closes and flicks.
  await dragBy(w0.x + 120, w0.y + w0.h / 2, 130);
  await sleep(60);
  await shot("notify-swipe-fling");
  await sleep(600);
  assert(!(await fullTreeTexts()).includes("磁盘空间不足"), "越过阈值没有关闭");
  await clearAll();

  // 3. press in button area doesn't start swipe (data-noswipe).
  await clickTestId("story.notify.btn.error");
  await sleep(700);
  const retry = await screenPos("story.notify.error.action.1");
  const e0 = await screenPos("story.notify.error");
  await dragBy(retry.x + retry.w / 2, retry.y + retry.h / 2, 140);
  await sleep(600);
  const e1 = await screenPos("story.notify.error");
  assert(Math.abs(e1.x - e0.x) < 1 && (await fullTreeTexts()).includes("上传失败"), `按钮区拖动触发了手势: ${e0.x} → ${e1.x}`);
  await clearAll();

  // 4. inline reply: input + Enter -> quote in place, card not rebuilt, event carries reply.
  await clickTestId("story.notify.btn.person");
  await sleep(700);
  const p0 = await screenPos("story.notify.person");
  // reply box below divider: card bottom minus ~25px.
  await clickAt(p0.x + 120, p0.y + p0.h - 25);
  await type_("好的，马上看");
  await sleep(150);
  await shot("notify-reply-typed");
  await key("return");
  await sleep(500);
  await shot("notify-reply-sent");
  // text assertion reads tree, not pixels; in-place morph must really render (real regression:
  // hover pause didn't show new layer).
  const sent = await screenPos("story.notify.person");
  assertRegionHasInk(`${DIR}/story-notify-reply-sent.png`, { x: sent.x + 60, y: sent.y + 10, w: 260, h: sent.h - 20 }, "reply sent content pixels", 150);
  const joined = await fullTreeTexts();
  assert(joined.includes("好的，马上看"), `回复内容未以引用出现 — ${joined}`);
  const st: string[] = [];
  const sq = await query("story.notify.status");
  if (sq[0]) collectText(sq[0], st);
  assert(st.join(" ").includes("reply"), `回复事件未上报 — ${st.join(" ")}`);
  assert((await query("story.notify.person")).length === 1, "发送后卡片被重建（test id 丢失）");
  await clearAll();
});

test("Notification: 文案提示胶囊（16.13）— 与卡片同一堆叠、宽度随内容、悬停展开、按钮原地转换、超长封顶 480", async () => {
  await switchTo("notification");
  async function cardTexts(): Promise<string> {
    const o: string[] = [];
    const walk = (n: any) => {
      if (n.component === "Notification") collectText(n, o);
      else for (const c of n.children ?? []) walk(c);
    };
    walk(await tree());
    return o.join(" │ ");
  }
  async function clearAll(): Promise<void> {
    await mouseMove(-10, -10);
    await clickTestId("story.notify.btn.clear");
    await sleep(600);
  }
  async function holdPointer(x: number, y: number, ms: number): Promise<void> {
    const end = Date.now() + ms;
    while (Date.now() < end) {
      await mouseMove(x, y);
      await sleep(Math.min(100, Math.max(0, end - Date.now())));
    }
  }
  const full = await tree();
  const win = { w: full.rect.w, h: full.rect.h };
  await clearAll();
  // Auto-dismissing hints (2 s) must outlive a slow harness round trip.
  await useIdleFrozenClock();

  // 1. single: 36h capsule, bottom center (card stack anchor, 22 margin).
  await clickTestId("story.notify.hint.btn.success");
  await sleep(600);
  await shot("notify-hint-success");
  const one = await screenPos("story.notify.hint.success");
  appendLog(`  hint rect: ${JSON.stringify(one)} window ${JSON.stringify(win)}`);
  assert(Math.abs(one.h - 36) < 0.5, `胶囊高度应为 36: ${one.h}`);
  assert(one.w > 60 && one.w < 200, `胶囊宽度应随内容: ${one.w}`);
  assert(Math.abs(one.x + one.w / 2 - win.w / 2) < 1, `胶囊未水平居中: ${one.x}`);
  assert(Math.abs(one.y + one.h - (win.h - 22)) < 1.5, `底部边距应为 22: bottom=${one.y + one.h}`);
  assertRegionHasInk(`${DIR}/story-notify-hint-success.png`, one, "hint capsule pixels", 20);

  // 2. same stack: capsule topmost when collapsed, cards behind; expanded staggered.
  await clearAll();
  await clickTestId("story.notify.btn.warning");
  await sleep(150);
  await clickTestId("story.notify.hint.btn.undo");
  await sleep(700);
  const hint = await screenPos("story.notify.hint.undo");
  const warnCollapsed = await screenPos("story.notify.warning");
  assert(warnCollapsed.y < hint.y && hint.y - warnCollapsed.y < 20, `折叠态卡片应在胶囊后方露边: card y=${warnCollapsed.y} hint y=${hint.y}`);
  await holdPointer(hint.x + 40, hint.y + hint.h / 2, 900);
  await shot("notify-hint-stack-expanded");
  const hintExp = await screenPos("story.notify.hint.undo");
  const warnExp = await screenPos("story.notify.warning");
  assert(warnExp.y + warnExp.h <= hintExp.y - 8, `展开后卡片应排在胶囊上方: card bottom=${warnExp.y + warnExp.h} hint y=${hintExp.y}`);

  // 3. capsule button: story morphs in-place to 'undo done' (same id, no new).
  const click = await clickTestId("story.notify.hint.undo.action.0");
  assert(click.ok === true, `撤销按钮点击失败: ${JSON.stringify(click)}`);
  await sleep(500);
  await shot("notify-hint-undone");
  const texts = await cardTexts();
  assert(texts.includes("已撤销替换"), `撤销后未原地转换: ${texts}`);
  assert(!texts.includes("已在当前文件替换"), `旧文案仍在: ${texts}`);
  assert((await query("story.notify.hint.undo")).length === 1, "原地转换不应重建卡片（test id 丢失）");

  // 4. long text: width capped 480 (single-line ellipsis).
  await clearAll();
  await clickTestId("story.notify.hint.btn.long");
  await sleep(600);
  await shot("notify-hint-long");
  const long = await screenPos("story.notify.hint.long");
  assert(Math.abs(long.w - 480) < 0.5, `超长胶囊应封顶 480: ${long.w}`);
  await clearAll();
});

test("NumberStepper: 交互 — 点 Increase 箭头步进", async () => {
  await switchTo("stepper");
  const plus = await screenPos("story.stepper.increase");
  assert(plus.w > 0 && plus.h > 0, "找不到 Increase 箭头");
  await clickAt(plus.x + plus.w / 2, plus.y + plus.h / 2);
  await sleep(250);
  const t1 = await query("story.stepper.basic");
  const out: string[] = [];
  if (t1[0]) collectText(t1[0], out);
  appendLog(`  stepper after +: ${out.join(" │ ")}`);
  assert(out.includes("6"), `+ 后应为 6 — ${out.join(" │ ")}`);
  // Cross the digit boundary through real clicks: text content alone would
  // miss a stale intrinsic-width cache that clips the newly rendered label.
  let nine: any;
  for (let value = 7; value <= 10; value++) {
    assert((await clickAt(plus.x + plus.w / 2, plus.y + plus.h / 2)).ok === true);
    const rect = await waitFor(async () => {
      const current = await query("story.stepper.basic");
      return findRectByText(current[0], String(value));
    }, getE2eTimeoutMs(2000), 40);
    if (value === 9) nine = rect;
    if (value === 10) {
      assert(rect.w > nine.w + 1, `9→10 must remeasure width: ${nine.w}→${rect.w}`);
      // RYMhT aligns the value to the field start, alongside right-side arrows.
      assert(Math.abs(rect.x - nine.x) < 1, "updated value must retain its left alignment");
      assert(rect.x + rect.w < plus.x, "two-digit value must not overlap the arrow strip");
      await shot("stepper-digit-growth");
      assertRegionHasInk(`${DIR}/story-stepper-digit-growth.png`, rect, "stepper two-digit label", 10);
    }
  }
});

test("NumberStepper: 键入 — 回车提交 / Esc 放弃 / 失焦提交 / 上下键步进", async () => {
  await switchTo("stepper");
  const wrapper = (await query("story.stepper.basic"))[0].rect;
  const plus = await screenPos("story.stepper.increase");
  // the value area: everything left of the arrow strip
  const field = { x: wrapper.x + 1, y: wrapper.y + 1, w: plus.x - wrapper.x - 2, h: wrapper.h - 2 };
  const texts = async () => {
    const out: string[] = [];
    collectText((await query("story.stepper.basic"))[0], out);
    return out;
  };
  const waitText = (value: string) => waitFor(async () => (await texts()).includes(value) ? true : null, getE2eTimeoutMs(2000), 40);
  const focusField = async () => {
    assert((await clickAt(field.x + field.w / 2, field.y + field.h / 2)).ok === true);
    await sleep(150);
    await key("a", { cmd: true });
  };

  // Return commits once, clamped (42 -> 10 proves the commit, not just the draft)
  await focusField();
  await type_("42");
  await waitText("42");
  await shot("stepper-typing-draft");
  await key("return");
  await waitText("10");

  // Escape discards the draft
  await focusField();
  await type_("3");
  await waitText("3");
  await key("escape");
  await waitText("10");

  // Up steps from the draft (4 + 1), not from the committed 10
  await focusField();
  await type_("4");
  await key("up");
  await waitText("5");

  // blur commits: "02" is normalized to "2" only by a commit
  await focusField();
  await type_("02");
  await waitText("02");
  await clickAt(wrapper.x + wrapper.w + 200, wrapper.y + wrapper.h / 2);
  await waitText("2");
  assert(!(await texts()).includes("02"), "blur must commit and normalize the draft");
  await shot("stepper-typed-committed");
  appendLog(`  stepper after typing: ${(await texts()).join(" │ ")}`);
});

test("TagsInput: 交互 — 逗号提交 + × 删除", async () => {
  await switchTo("tags");
  await clickTestId("story.tags.input");
  await type_("gpu,");
  await sleep(350);
  let out: string[] = [];
  let tr = await query("story.tags.wrapper");
  if (tr[0]) collectText(tr[0], out);
  appendLog(`  tags after commit: ${out.join(" │ ")}`);
  assert(out.includes("gpu"), `逗号提交后应有 gpu tag — ${out.join(" │ ")}`);
  await shot("tags-committed");
  // Default Add button commits through the same path.
  await clickTestId("story.tags.input");
  await type_("default-add");
  const addButton = await screenPos("story.tags.add");
  assert(addButton.w > 0 && addButton.h > 0, "默认 Add 按钮必须存在");
  assert((await clickTestId("story.tags.add")).ok === true, "默认 Add 必须可点击");
  await sleep(350);
  const afterAdd: string[] = [];
  const addTree = await query("story.tags.wrapper");
  if (addTree[0]) collectText(addTree[0], afterAdd);
  const addInputTexts: string[] = [];
  collectText((await query("story.tags.input"))[0], addInputTexts);
  assert(afterAdd.filter((t) => t === "default-add").length - addInputTexts.filter((t) => t === "default-add").length === 1, `默认 Add 应提交真实 tag — ${afterAdd.join(" │ ")}`);
  assert(!addInputTexts.includes("default-add"), "默认 Add 提交后必须清空输入框");
  await clickTestId("story.tags.input");
  // Return commits too, and clears the input
  await type_("text");
  await key("return");
  await sleep(350);
  out = [];
  tr = await query("story.tags.wrapper");
  if (tr[0]) collectText(tr[0], out);
  appendLog(`  tags after Return: ${out.join(" │ ")}`);
  // (the wrapper's text includes the input's own; a chip is a "text" outside it)
  const field = (await query("story.tags.input"))[0];
  const ft: string[] = [];
  collectText(field, ft);
  assert(out.filter((t) => t === "text").length - ft.filter((t) => t === "text").length === 1, `回车提交后应有 text tag — ${out.join(" │ ")}`);
  assert(!ft.includes("text"), `回车提交后输入框应清空 — ${ft.join(" │ ")}`);
});

test("FileUpload: 交互 — Choose file 回填文件行", async () => {
  await switchTo("upload");
  const browse = await screenPos("story.upload.choose");
  assert(browse.w > 0 && browse.h > 0, "找不到 Choose file 按钮");
  await clickAt(browse.x + browse.w / 2, browse.y + browse.h / 2);
  await sleep(250);
  const out: string[] = [];
  const t1 = await query("story.upload.wrapper");
  if (t1[0]) collectText(t1[0], out);
  appendLog(`  upload after browse: ${out.join(" │ ")}`);
  assert(out.join(" ").includes("demo-file-1.txt"), `Choose file 后应出现文件行 — ${out.join(" │ ")}`);
});

test("FileUpload: 拖放 — Finder 拖入文件（程序化注入）", async () => {
  await switchTo("upload");
  // real Finder drag can't automate: use /drag inject entered -> updated -> dropped, same path into
  // Cx.handleDrag as platform NSDragging.
  const zone = (await query("story.upload.dropzone"))[0];
  assert(zone, "找不到 dropzone");
  const cx0 = zone.rect.x + zone.rect.w / 2;
  const cy0 = zone.rect.y + zone.rect.h / 2;

  // hover highlight: entered, then screenshot (drop zone border/bg should change)
  await dragAt(cx0, cy0, 0);
  await dragAt(cx0, cy0, 1);
  await sleep(120);
  await shot("upload-drag-hover");

  // drop two files (newline-separated), add each
  await dragAt(cx0, cy0, 3, "/tmp/dropped-one.txt\n/tmp/dropped-two.txt");
  await sleep(250);

  const out: string[] = [];
  const tree = await query("story.upload.wrapper");
  if (tree[0]) collectText(tree[0], out);
  appendLog(`  upload after drop: ${out.join(" │ ")}`);
  assert(
    out.join(" ").includes("dropped-one.txt"),
    `拖入后应出现 dropped-one.txt — ${out.join(" │ ")}`,
  );
  assert(
    out.join(" ").includes("dropped-two.txt"),
    `换行分隔的第二个文件也应添加 — ${out.join(" │ ")}`,
  );
  await shot("upload-dropped");
});

test("DataTable: 交互 — 翻页 + 筛选", async () => {
  await switchTo("datatable");
  // page: Next -> Page 2, first row becomes Dave (find Next button rect from data tree)
  const tree0 = await query("story.datatable.table");
  const texts0: string[] = [];
  if (tree0[0]) collectText(tree0[0], texts0);
  assert(texts0.join(" ").includes("Page 1 / 3"), `初始应在第 1 页 — ${texts0.join(" │ ")}`);
  // find Next button node (recursively find text=="Next" parent rect)
  function findRect(node: any, label: string): any {
    if (node?.text === label) return node.rect ?? null;
    for (const c of node?.children ?? []) {
      const r = findRect(c, label);
      if (r) return r;
    }
    return null;
  }
  const nextRect = findRect(tree0[0], "Next");
  assert(nextRect, "找不到 Next 按钮");
  await clickAt(nextRect.x + nextRect.w / 2, nextRect.y + nextRect.h / 2);
  await sleep(250);
  const texts1: string[] = [];
  const tree1 = await query("story.datatable.table");
  if (tree1[0]) collectText(tree1[0], texts1);
  const joined1 = texts1.join(" │ ");
  appendLog(`  datatable after Next: ${joined1}`);
  assert(joined1.includes("Page 2 / 3"), `Next 后应在第 2 页 — ${joined1}`);
  assert(joined1.includes("Dave"), `第 2 页应含 Dave — ${joined1}`);

  // filter: input 'admin' -> only Alice/Frank, Page 1/1
  await clickTestId("story.datatable.filter");
  await type_("admin");
  await sleep(400);
  const texts2: string[] = [];
  const tree2 = await query("story.datatable.table");
  if (tree2[0]) collectText(tree2[0], texts2);
  const joined2 = texts2.join(" │ ");
  appendLog(`  datatable filtered: ${joined2}`);
  assert(joined2.includes("Alice") && joined2.includes("Frank"), `筛选 admin 应含 Alice+Frank — ${joined2}`);
  assert(joined2.includes("Page 1 / 1"), `筛选后应 1 页 — ${joined2}`);
  await shot("datatable-filtered");
});

test("VirtualList hit: rows clicked right after a wheel stream are the rows painted under the pointer", async () => {
  // Fixture list (examples/storybook/vlist_hit_fixture.zig): every row records the data index it
  // was clicked as. Rows are recycled pool slots; the hit index rebuilds only the rebound ones
  // (hit_runtime HitBlock), so a stale block would click the previous binding.
  async function paintedRowAt(x: number, y: number): Promise<number | null> {
    for (const row of await query("review.vlist-hit.row")) {
      const r = row.rect;
      if (!r || row.visible === false) continue;
      if (x < r.x || x >= r.x + r.w || y < r.y || y >= r.y + r.h) continue;
      // Away from row edges: sub-pixel snapping must not decide the answer.
      if (y - r.y < 2 || r.y + r.h - y < 2) return null;
      const label = (row.children ?? []).map((c: any) => c.text).find((t: any) => typeof t === "string") as string | undefined;
      const m = label ? /^VRow (\d+)$/.exec(label) : null;
      return m ? Number(m[1]) : null;
    }
    return null;
  }
  async function clickedAt(x: number, y: number): Promise<number> {
    const before = await request("POST", "/review/vlist-hit-state", {});
    assert((await clickAt(x, y)).ok === true, "click rpc failed");
    const after = await request("POST", "/review/vlist-hit-state", {});
    assert(after.clicks === before.clicks + 1, `click at (${x},${y}) reached no row: ${JSON.stringify(after)}`);
    return after.clicked;
  }
  for (const variant of ["/review/vlist-hit-mount", "/review/vlist-hit-mount-dynamic"]) {
    const setup = await request("POST", variant, {});
    assert(setup.ok === true, `${variant} failed: ${JSON.stringify(setup)}`);
    await settle(300);
    try {
      const q = await query("review.vlist-hit.list");
      assert(q.length === 1 && q[0]?.rect, "fixture list missing");
      const list = q[0].rect;
      const x = list.x + 120;
      const ys = [list.y + 9, list.y + list.h / 2 + 3, list.y + list.h - 9];
      const streams = [[-28, -28, -28], [-7, -9, -13, -5], [-150, -90], [60, 45], [-1200], [-3, -3], [400, -800, 120], [-31, -57, -11, -88]];
      let checked = 0;
      for (let round = 0; round < streams.length * 2; round++) {
        for (const dy of streams[round % streams.length]) await scrollAt(x, list.y + list.h / 2, 0, dy);
        // Straight after the stream, before any settle.
        const y = ys[round % ys.length];
        const got = await clickedAt(x, y);
        await settle(150);
        const want = await paintedRowAt(x, y);
        appendLog(`  ${variant} round ${round}: clicked #${got}, painted #${want}`);
        if (want === null) continue;
        assert(got === want, `${variant} round ${round}: click at y=${y} hit row #${got}, painted row is #${want}`);
        checked++;
      }
      assert(checked >= streams.length, `${variant}: too few unambiguous probes (${checked})`);
      // Both ends after a jump: the end bounce settles first (it moves the rows).
      for (const [dy, y] of [[-1_000_000, ys[2]], [1_000_000, ys[0]]] as const) {
        await scrollAt(x, list.y + list.h / 2, 0, dy);
        await settle(700);
        const want = await paintedRowAt(x, y);
        const got = await clickedAt(x, y);
        appendLog(`  ${variant} end ${dy}: clicked #${got}, painted #${want}`);
        assert(want !== null && got === want, `${variant} end ${dy}: click hit row #${got}, painted row is #${want}`);
      }
    } finally {
      await request("POST", "/review/vlist-hit-unmount", {});
      await settle(200);
    }
  }
});

test("Table(virtual): 虚拟行悬停与直渲行同一声明 — 进出悬停、斑马纹回落、滚动回收不串悬停", async () => {
  await switchTo("table");
  // Visible virtual rows: data index (from the "Name #N" cell) -> sample point in the empty right
  // part of the Role column (no glyphs), in logical coordinates.
  // `hx` is where the pointer goes (Name column, left of the sample point) so the harness's drawn
  // cursor never covers the sampled pixels.
  async function rows(): Promise<Map<number, { x: number; y: number; hx: number }>> {
    const q = await query("story.table.virtual");
    assert(q.length === 1 && q[0]?.rect, "story.table.virtual 不存在");
    const table = q[0].rect;
    const out = new Map<number, { x: number; y: number; hx: number }>();
    const walk = (n: any) => {
      if (n?.hidden) return;
      const m = typeof n?.text === "string" ? /#(\d+)$/.exec(n.text) : null;
      if (m && n.rect) {
        const y = n.rect.y + n.rect.h / 2;
        // fully inside the body viewport (below the 28px header, above the bottom border)
        if (n.rect.y >= table.y + 30 && n.rect.y + n.rect.h <= table.y + table.h - 2) out.set(Number(m[1]), { x: table.x + 1 + 160 + 120 - 14, y, hx: table.x + 1 + 120 });
      }
      for (const c of n?.children ?? []) walk(c);
    };
    walk(q[0]);
    return out;
  }
  const sample = (png: string, p: { x: number; y: number }) => centerPixel(png, { x: p.x - 3, y: p.y - 3, w: 6, h: 6 });
  const diff = (a: number[], b: number[]) => Math.max(Math.abs(a[0] - b[0]), Math.abs(a[1] - b[1]), Math.abs(a[2] - b[2]));

  await mouseMove(-10, -10);
  await settle(300);
  const r0 = await rows();
  assert(r0.has(1) && r0.has(2) && r0.has(3), `虚拟表格应可见第 1-3 行 — ${[...r0.keys()].join(",")}`);
  await shot("table-virtual-idle");
  const idle = `${DIR}/story-table-virtual-idle.png`;
  const oddBase = sample(idle, r0.get(1)!);
  const evenBase = sample(idle, r0.get(2)!);
  appendLog(`  virtual table base: odd=(${oddBase}) even=(${evenBase})`);
  assert(diff(oddBase, evenBase) >= 3, `斑马纹奇偶行底色应可区分: odd=(${oddBase}) even=(${evenBase})`);

  // Hover even row 2: bg_hover after the 150ms ease-out; neighbours keep their stripe.
  assert((await mouseMove(r0.get(2)!.hx, r0.get(2)!.y)).ok === true);
  await settle(400);
  await shot("table-virtual-hover-even");
  const hEven = `${DIR}/story-table-virtual-hover-even.png`;
  const evenHover = sample(hEven, r0.get(2)!);
  appendLog(`  row 2 hovered=(${evenHover})`);
  assert(diff(evenHover, evenBase) >= 3, `悬停第 2 行应变为 bg_hover: (${evenHover}) vs 底色 (${evenBase})`);
  // bg_hover is a light tint: guard against sampling the drawn cursor / text instead of the row.
  assert(Math.min(...evenHover) >= 200, `悬停色应是浅色行底而非光标/字形像素: (${evenHover})`);
  assertColorNear(sample(hEven, r0.get(1)!), oddBase, "悬停第 2 行时第 1 行保持奇数底色", 3);
  assertColorNear(sample(hEven, r0.get(3)!), oddBase, "悬停第 2 行时第 3 行保持奇数底色", 3);

  // Move to odd row 1: same hover colour (shared declaration), row 2 falls back to its stripe.
  assert((await mouseMove(r0.get(1)!.hx, r0.get(1)!.y)).ok === true);
  await settle(400);
  await shot("table-virtual-hover-odd");
  const hOdd = `${DIR}/story-table-virtual-hover-odd.png`;
  assertColorNear(sample(hOdd, r0.get(1)!), evenHover, "奇数行悬停色与偶数行一致（同一 bg_hover）", 3);
  assertColorNear(sample(hOdd, r0.get(2)!), evenBase, "离开第 2 行后回到偶数底色", 3);

  // Scroll under the stationary hovering pointer (wheel only, no pointer move): slots get
  // recycled; hover follows the row that arrives under the pointer (native NSScrollView /
  // browser behaviour), the row that scrolled away no longer hovers, and no other row does.
  const under = r0.get(1)!;
  const hoverBefore = (await stats()).hover!;
  for (let i = 0; i < 6; i++) await scrollAt(under.hx, under.y, 0, -60);
  await settle(600);
  const r1 = await rows();
  assert(!r1.has(1) && r1.size > 0, `滚动后第 1 行应已滚出 — ${[...r1.keys()].join(",")}`);
  await shot("table-virtual-scrolled-hovering");
  const sc = `${DIR}/story-table-virtual-scrolled-hovering.png`;
  let underIdx = -1;
  for (const [idx, p] of r1) if (underIdx < 0 || Math.abs(p.y - under.y) < Math.abs(r1.get(underIdx)!.y - under.y)) underIdx = idx;
  assert(underIdx >= 0 && Math.abs(r1.get(underIdx)!.y - under.y) < 16, `滚动后指针下应有一行 — ${[...r1.entries()].map(([i, p]) => `${i}@${p.y}`).join(",")}`);
  appendLog(`  row under the stationary pointer after scroll: #${underIdx} (${sample(sc, r1.get(underIdx)!)})`);
  assertColorNear(sample(sc, r1.get(underIdx)!), evenHover, `指针不动、滚到指针下的第 ${underIdx} 行应立即进入悬停（bg_hover）`, 3);
  const hoverAfter = (await stats()).hover!;
  assert(hoverAfter.reconcile_changes > hoverBefore.reconcile_changes,
    `滚动应在指针不动时重解析悬停: ${JSON.stringify(hoverBefore)} -> ${JSON.stringify(hoverAfter)}`);
  let checked = 0;
  for (const [idx, p] of r1) {
    if (idx === underIdx) continue;
    assertColorNear(sample(sc, p), idx % 2 === 1 ? oddBase : evenBase, `滚动回收后第 ${idx} 行无残留悬停`, 3);
    checked++;
  }
  assert(checked >= 4, `滚动后应至少校验 4 行，实际 ${checked}`);
  await mouseMove(-10, -10);
  await settle(400);
  await shot("table-virtual-scrolled-idle");
  const sci = `${DIR}/story-table-virtual-scrolled-idle.png`;
  for (const [idx, p] of r1) assertColorNear(sample(sci, p), idx % 2 === 1 ? oddBase : evenBase, `指针离开后第 ${idx} 行回到斑马纹`, 3);
});

test("ComboBox: 交互 — 输入过滤 + 点选写回", async () => {
  await switchTo("combobox");
  await clickTestId("story.combobox.input"); // focus input
  await type_("an");
  await sleep(400);
  await shot("combobox-open");
  // after filter, only Banana/Mango visible (other rows h=0, in tree, text h=0)
  const tree = await query("story.combobox.panel");
  const out: string[] = [];
  if (tree[0]) collectText(tree[0], out);
  const joined = out.join(" │ ");
  appendLog(`  combobox filtered panel texts: ${joined}`);
  assert(joined.includes("Banana"), `combobox 过滤后缺 Banana — 实际: ${joined}`);
  // click select Banana (find visible row position)
  const pos = await screenPos("story.combobox.panel");
  await clickAt(pos.x + 40, pos.y + 20); // first visible row
  await sleep(300);
  const input = await inputState("story.combobox.input");
  appendLog(`  combobox input after select: ${JSON.stringify(input)}`);

  // regression: no matches old only set option row h=0, label still overflowed onto empty state.
  // Newer requires hidden items out of layout/render, only center empty.
  await switchTo("combobox");
  await clickTestId("story.combobox.input");
  // first real input after select-write must filter normally (old suppress flag would eat it).
  await type_("z");
  await sleep(100);
  await type_("zz");
  await sleep(400);
  appendLog(`  combobox no-match input: ${JSON.stringify(await inputState("story.combobox.input"))}`);
  const noMatchTree = await query("story.combobox.panel");
  const noMatchTexts: string[] = [];
  if (noMatchTree[0]) collectText(noMatchTree[0], noMatchTexts);
  appendLog(`  combobox no-match tree texts: ${noMatchTexts.join(" │ ")}`);
  assert(noMatchTexts.includes("No results found"), `无匹配时缺空态 — 实际: ${noMatchTexts.join(" │ ")}`);
  await shot("combobox-no-results");
});

test("Select: RYMhT component family", async () => {
  await switchTo("select");
  const family = await query("story.select.family");
  assert(family.length === 1, `RYMhT family root 缺失 — got ${family.length}`);
  await shot("select-rymht-rest");

  const near = (actual: number, expected: number, label: string, tolerance = 1) => {
    const delta = Math.abs(actual - expected);
    appendLog(`  ${label}: actual=${actual.toFixed(2)} expected=${expected.toFixed(2)} delta=${delta.toFixed(2)}`);
    assert(delta <= tolerance, `${label}: ${actual} != ${expected} (±${tolerance})`);
  };
  const opacityOf = (node: any): number => node.opacity ?? 1;
  const rotateOf = (node: any): number => node.rotate ?? 0;
  // RYMhT: 16px icons, 12px horizontal inset, 6px field gap,
  // and 28px option rows inside a panel with 4px padding.
  const withIconTrigger = (await query("story.select.with-icon"))[0];
  near(withIconTrigger.rect.w, 352, "RYMhT trigger width");
  // spec/json/RYMhT.json replaces puQEf: default md field height is 32px.
  near(withIconTrigger.rect.h, 32, "RYMhT default trigger height");
  near((await screenPos("story.select.multiple-lg")).h, 40, "LG trigger height");

  // real single-select: open Popover -> select Option 2 -> trigger writes.
  await clickTestId("story.select.with-icon");
  await sleep(55);
  const openingChevron = (await query("story.select.with-icon.chevron"))[0];
  appendLog(`  opening chevron captured rotate=${rotateOf(openingChevron).toFixed(3)} rad`);
  await shot("select-rymht-with-icon-opening-rotate-mid");
  await sleep(160);
  const openedChevron = (await query("story.select.with-icon.chevron"))[0];
  near(rotateOf(openedChevron), Math.PI, "opened chevron rotates 180deg", 0.06);
  await shot("select-rymht-with-icon-open");
  const withIconPanel = await query("story.select.with-icon.panel");
  const texts: string[] = [];
  if (withIconPanel[0]) collectText(withIconPanel[0], texts);
  const joined = texts.join(" │ ");
  for (const option of ["Option 1", "Option 2", "Option 3", "Option 4"])
    assert(joined.includes(option), `Select panel 缺 ${option} — 实际: ${joined}`);
  await clickTestId("story.select.with-icon.option-2");
  await sleep(55);
  const closingChevron = (await query("story.select.with-icon.chevron"))[0];
  appendLog(`  closing chevron captured rotate=${rotateOf(closingChevron).toFixed(3)} rad`);
  await shot("select-rymht-with-icon-closing-rotate-mid");
  await sleep(160);
  const closedChevron = (await query("story.select.with-icon.chevron"))[0];
  near(rotateOf(closedChevron), 0, "closed chevron returns to 0deg", 0.06);
  await shot("select-rymht-with-icon-selected-option-2");
  const selectedText = await storyTexts("select");
  assert(selectedText.includes("Option 2"), `单选未写回 trigger: ${selectedText}`);

  // clearable append always one icon slot. Default shows chevron; on hover in selected state,
  // absolute icon-only clear overlays chevron.
  await mouseMove(-10, -10);
  await sleep(100);
  await shot("select-rymht-clearable-selected-rest");
  const clearButtonRest = (await query("story.select.clear"))[0];
  const clearChevronRest = (await query("story.select.clearable.chevron"))[0];
  const clearAppendRest = (await query("story.select.clearable.append"))[0];
  const clearAppendCompRest = (await query("story.select.clearable.append-comp"))[0];
  assert(clearButtonRest.opacity === 0,
    `selected rest 必须只显示 chevron — clear opacity=${clearButtonRest.opacity}`);
  assert(clearChevronRest.opacity === undefined || clearChevronRest.opacity === 1,
    `selected rest chevron 必须可见 — opacity=${clearChevronRest.opacity}`);
  near(clearAppendCompRest.rect.w, 16, "fixed append overlay width", 0.75);
  near(clearAppendRest.rect.w, 16, "shell append remains one icon wide", 0.75);

  const clearablePos = await screenPos("story.select.clearable");
  await mouseMove(clearablePos.x + 48, clearablePos.y + clearablePos.h / 2);
  const clearButtonFadeIn = (await query("story.select.clear"))[0];
  const clearChevronFadeOut = (await query("story.select.clearable.chevron"))[0];
  appendLog(`  fade-in capture: clear=${opacityOf(clearButtonFadeIn).toFixed(3)} chevron=${opacityOf(clearChevronFadeOut).toFixed(3)}`);
  await shot("select-rymht-clearable-fade-in-mid");
  await sleep(180);
  await shot("select-rymht-clearable-selected-trigger-hover");
  const clearButtonHover = (await query("story.select.clear"))[0];
  const clearChevronHover = (await query("story.select.clearable.chevron"))[0];
  near(opacityOf(clearButtonHover), 1, "selected hover clear fade-in settles", 0.02);
  near(opacityOf(clearChevronHover), 0, "selected hover chevron fade-out settles", 0.02);
  near(clearButtonHover.rect.x, clearChevronHover.rect.x, "clear overlays chevron x", 0.75);
  near(clearButtonHover.rect.y, clearChevronHover.rect.y, "clear overlays chevron y", 0.75);
  near(clearButtonHover.rect.w, clearChevronHover.rect.w, "clear matches chevron width", 0.75);
  near(clearButtonHover.rect.h, clearChevronHover.rect.h, "clear matches chevron height", 0.75);
  assert((clearButtonHover.component ?? "").includes("Button"),
    `clear 必须是真正的 icon-only Button — component=${clearButtonHover.component}`);

  await clickTestId("story.select.clearable");
  await sleep(60);
  await shot("select-rymht-clearable-opening-selected");
  await sleep(140);
  await shot("select-rymht-clearable-open-selected");
  const clearButtonOpen = (await query("story.select.clear"))[0];
  const clearChevronOpen = (await query("story.select.clearable.chevron"))[0];
  const clearAppendOpen = (await query("story.select.clearable.append"))[0];
  const clearAppendCompOpen = (await query("story.select.clearable.append-comp"))[0];
  const clearChevronUpOpen = (await query("story.select.clearable.chevron-up"))[0];
  const clearChevronDownOpen = (await query("story.select.clearable.chevron-down"))[0];
  near(clearButtonOpen.rect.x, clearChevronOpen.rect.x, "open clear overlays chevron x", 0.75);
  near(clearButtonOpen.rect.w, clearChevronOpen.rect.w, "open clear matches chevron width", 0.75);
  near(clearAppendCompOpen.rect.w, 16, "selected append stays one icon wide", 0.75);
  near(clearAppendOpen.rect.w, clearAppendCompOpen.rect.w, "shell append contains overlay Box", 0.75);
  assert(opacityOf(clearButtonOpen) > 0.98 && opacityOf(clearChevronOpen) < 0.02,
    `selected open hover 必须由 clear 覆盖 chevron — clear=${opacityOf(clearButtonOpen)} chevron=${opacityOf(clearChevronOpen)}`);
  assert(opacityOf(clearChevronUpOpen) === 0 && opacityOf(clearChevronDownOpen) === 1,
    `Select 必须只使用一个 down chevron — up=${opacityOf(clearChevronUpOpen)} down=${opacityOf(clearChevronDownOpen)}`);
  near(rotateOf(clearChevronDownOpen), Math.PI, "clearable open chevron rotation target", 0.06);
  await clickTestId("story.select.clearable");
  await sleep(200);
  await shot("select-rymht-clearable-reclosed-selected");

  await mouseMove(-10, -10);
  const clearButtonFadeOut = (await query("story.select.clear"))[0];
  const clearChevronFadeIn = (await query("story.select.clearable.chevron"))[0];
  appendLog(`  fade-out capture: clear=${opacityOf(clearButtonFadeOut).toFixed(3)} chevron=${opacityOf(clearChevronFadeIn).toFixed(3)}`);
  await shot("select-rymht-clearable-fade-out-mid");
  await sleep(180);
  await shot("select-rymht-clearable-reclosed-selected-rest");
  const clearButtonReclosedRest = (await query("story.select.clear"))[0];
  const clearChevronReclosedRest = (await query("story.select.clearable.chevron"))[0];
  const clearChevronDownReclosedRest = (await query("story.select.clearable.chevron-down"))[0];
  assert(opacityOf(clearButtonReclosedRest) < 0.02 && opacityOf(clearChevronReclosedRest) > 0.98 &&
    opacityOf(clearChevronDownReclosedRest) === 1,
    `离开 selected trigger 后必须恢复 down chevron — clear=${opacityOf(clearButtonReclosedRest)} chevron=${opacityOf(clearChevronReclosedRest)}`);

  // real icon-only Button hover/pressed/click all screenshot: Option 1 -> hover shows x -> hover x
  // -> press x -> release/click -> placeholder.
  await mouseMove(clearablePos.x + 48, clearablePos.y + clearablePos.h / 2);
  await sleep(80);
  const clearPos = await screenPos("story.select.clear");
  await mouseMove(clearPos.x + clearPos.w / 2, clearPos.y + clearPos.h / 2);
  await sleep(120);
  await shot("select-rymht-clearable-clear-hover");
  await mouseDown(clearPos.x + clearPos.w / 2, clearPos.y + clearPos.h / 2);
  await sleep(80);
  await shot("select-rymht-clearable-clear-pressed");
  await mouseUp(clearPos.x + clearPos.w / 2, clearPos.y + clearPos.h / 2);
  const clearedButtonFadeOut = (await query("story.select.clear"))[0];
  appendLog(`  clear-click fade-out capture: clear=${opacityOf(clearedButtonFadeOut).toFixed(3)}`);
  await shot("select-rymht-clearable-cleared-fade-out-mid");
  await sleep(180);
  await shot("select-rymht-clearable-cleared");
  const clearableTree = await query("story.select.clearable");
  const clearableTexts: string[] = [];
  if (clearableTree[0]) collectText(clearableTree[0], clearableTexts);
  assert(clearableTexts.includes("Select an option..."), `clear 后未恢复 placeholder: ${clearableTexts.join(" │ ")}`);
  const clearAppend = (await query("story.select.clearable.append"))[0];
  const clearedAppendComp = (await query("story.select.clearable.append-comp"))[0];
  const clearChevron = (await query("story.select.clearable.chevron"))[0];
  const clearedTrigger = (await query("story.select.clearable"))[0];
  const clearedButton = (await query("story.select.clear"))[0];
  const clearedChevronDown = (await query("story.select.clearable.chevron-down"))[0];
  near(clearAppend.rect.w, clearChevron.rect.w, "cleared append stays one icon wide", 0.75);
  near(clearedAppendComp.rect.w, clearChevron.rect.w, "empty overlay Box stays one icon wide", 0.75);
  near(clearChevron.rect.x + clearChevron.rect.w, clearedTrigger.rect.x + clearedTrigger.rect.w - 12,
    "cleared MD chevron stays at right padding", 0.75);
  assert(opacityOf(clearedButton) < 0.02, `cleared state 的 clear 必须隐藏 — opacity=${opacityOf(clearedButton)}`);
  assert(opacityOf(clearedChevronDown) === 1,
    `cleared closed state 必须显示 chevron-down — opacity=${opacityOf(clearedChevronDown)}`);
  await clickTestId("story.select.clearable");
  await sleep(55);
  await shot("select-rymht-clearable-opening-empty-rotate-mid");
  await sleep(145);
  await shot("select-rymht-clearable-open-empty");
  await clickTestId("story.select.clearable");
  await sleep(55);
  await shot("select-rymht-clearable-closing-empty-rotate-mid");
  await sleep(145);
  await shot("select-rymht-clearable-reclosed-empty");

  // real search: input 3 to filter, click select, write Input and close.
  await clickTestId("story.select.trigger");
  await sleep(250);
  await shot("select-rymht-search-open-before-hover");
  const searchHover = await screenPos("story.select.search.option-1");
  await mouseMove(searchHover.x - 20, searchHover.y + 12);
  await sleep(60);
  await mouseMove(searchHover.x + 28, searchHover.y + 12);
  await sleep(180);
  await shot("select-rymht-search-open-default");
  const searchDefaultPanel = (await query("story.select.panel"))[0];
  const searchOption1 = (await query("story.select.search.option-1"))[0];
  const searchIcon = (await query("story.select.search.icon"))[0];
  const searchInputAtRest = (await query("story.select.search.input"))[0];
  near(searchDefaultPanel.rect.w, 352, "RYMhT search panel width");
  near(searchDefaultPanel.rect.h, 92, "RYMhT search panel height", 2);
  near(searchInputAtRest.rect.x - (searchIcon.rect.x + searchIcon.rect.w), 6, "RYMhT search icon/text gap", 0.75);
  assertColorNear(
    centerPixel(`${DIR}/story-select-rymht-search-open-default.png`, {
      x: searchOption1.rect.x + searchOption1.rect.w * 0.5,
      y: searchOption1.rect.y + searchOption1.rect.h * 0.5,
      w: 4,
      h: 4,
    }),
    [215, 220, 250], // light list_selection_hover_bg, paired with selection_fg
    "RYMhT searchable selected hover background",
    5,
  );
  await clickTestId("story.select.trigger");
  await sleep(120);
  await shot("select-rymht-search-closed-after-trigger");
  await clickTestId("story.select.search.input");
  await sleep(180);
  await shot("select-rymht-search-focused-open");
  // search box has selected label (Option 1): select-all then input, '3' replaces it to filter.
  // Prior relied on double-click within interval hitting word '1' -> click-busy -> 'Option 13',
  // filter empty.
  await key("a", { cmd: true });
  await sleep(60);
  await type_("3");
  await sleep(220);
  const searchTrigger = (await query("story.select.trigger"))[0];
  const searchPanel = await waitFor(async () => (await query("story.select.panel"))[0] ?? null, 2500, 40);
  near(searchTrigger.rect.w, 352, "search trigger width");
  near(searchPanel.rect.w, 352, "search panel width");
  near(searchTrigger.rect.h, 32, "RYMhT searchable md trigger height");
  await shot("select-rymht-search-open");
  await clickTestId("story.select.search.option-3");
  await sleep(180);
  await shot("select-rymht-search-selected-option-3");
  const searchInput = await inputState("story.select.search.input");
  assert(searchInput.buffer === "Option 3", `search select 未写回 Option 3: ${JSON.stringify(searchInput)}`);
  // Reopen the committed value as a separate transition; this catches stale
  // filter/selection styling that is invisible in the one-way happy path.
  await clickTestId("story.select.trigger");
  await sleep(180);
  await shot("select-rymht-search-reopened-selected-option-3");
  await clickTestId("story.select.trigger");
  await sleep(120);
  await shot("select-rymht-search-reclosed-selected-option-3");

  // real multi-select: check Option 3, panel stays open, tag appears; click tag x to remove.
  await clickSelectChevron("story.select.multiple-lg");
  await sleep(220);
  await shot("select-rymht-multiple-lg-open-before-hover");
  const hoverPos = await screenPos("story.select.multiple-lg.option-1");
  await mouseMove(hoverPos.x + 24, hoverPos.y + 12);
  await sleep(120);
  // Visual baseline first: exactly the two initial tags shown in `RYMhT`.
  await shot("select-rymht-multiple-lg-open");
  const multipleLgPanel = (await query("story.select.multiple-lg.panel"))[0];
  const multipleLgOption1 = (await query("story.select.multiple-lg.option-1"))[0];
  near(multipleLgPanel.rect.w, 352, "RYMhT multiple LG panel width");
  near(multipleLgPanel.rect.h, 120, "RYMhT multiple LG panel height", 2);
  assertColorNear(
    centerPixel(`${DIR}/story-select-rymht-multiple-lg-open.png`, {
      x: multipleLgOption1.rect.x + multipleLgOption1.rect.w * 0.5,
      y: multipleLgOption1.rect.y + multipleLgOption1.rect.h * 0.5,
      w: 4,
      h: 4,
    }),
    [244, 244, 245],
    "RYMhT multiple hover background",
    5,
  );
  await clickTestId("story.select.multiple-lg.option-3");
  await sleep(150);
  let tag3 = await query("story.select.multiple-lg.option-3.tag");
  assert(tag3[0]?.rect.w > 0 && tag3[0]?.rect.h > 0, "多选后 Option 3 tag 未显示");
  await shot("select-rymht-multiple-lg-selected-3");
  await clickTestId("story.select.multiple-lg.option-3.tag-close");
  await sleep(150);
  await shot("select-rymht-multiple-lg-tag-3-removed");
  tag3 = await query("story.select.multiple-lg.option-3.tag");
  assert(!tag3[0] || tag3[0].rect.h === 0, "点 tag close 后 Option 3 仍显示");
  await clickSelectChevron("story.select.multiple-lg");
  await sleep(150);
  await shot("select-rymht-multiple-lg-closed");

  // Searchable multiple LG: open -> close -> focus input -> filter -> select -> close.
  await clickSelectChevron("story.select.multiple-search-lg");
  await sleep(180);
  await shot("select-rymht-multiple-search-lg-open");
  await clickSelectChevron("story.select.multiple-search-lg");
  await sleep(120);
  await shot("select-rymht-multiple-search-lg-closed");
  await clickTestId("story.select.multiple-search-lg.input");
  await sleep(180);
  await shot("select-rymht-multiple-search-lg-focused-open");
  await type_("3");
  await sleep(180);
  await shot("select-rymht-multiple-search-lg-filtered-3");
  await clickTestId("story.select.multiple-search-lg.option-3");
  await sleep(150);
  await shot("select-rymht-multiple-search-lg-selected-option-3");
  const multiSearchLgContent = (await query("story.select.multiple-search-lg.content"))[0];
  const multiSearchLgInput = (await query("story.select.multiple-search-lg.input"))[0];
  const multiSearchLgAppend = (await query("story.select.multiple-search-lg.append"))[0];
  appendLog(`  multiple-search LG slots: content=${JSON.stringify(multiSearchLgContent.rect)} input=${JSON.stringify(multiSearchLgInput.rect)} append=${JSON.stringify(multiSearchLgAppend.rect)}`);
  assert(
    multiSearchLgInput.rect.x >= multiSearchLgContent.rect.x && multiSearchLgInput.rect.x < multiSearchLgAppend.rect.x,
    `multiple searchable input 起点不在 content slot: input=${JSON.stringify(multiSearchLgInput.rect)} content=${JSON.stringify(multiSearchLgContent.rect)}`,
  );
  assert(
    multiSearchLgContent.rect.x + multiSearchLgContent.rect.w <= multiSearchLgAppend.rect.x - 5.5,
    `multiple searchable content 侵入 append slot: content=${JSON.stringify(multiSearchLgContent.rect)} append=${JSON.stringify(multiSearchLgAppend.rect)}`,
  );
  assertColorNear(
    centerPixel(`${DIR}/story-select-rymht-multiple-search-lg-selected-option-3.png`, {
      x: multiSearchLgContent.rect.x + multiSearchLgContent.rect.w + 2,
      y: multiSearchLgAppend.rect.y + multiSearchLgAppend.rect.h * 0.5 - 2,
      w: 4,
      h: 4,
    }),
    [255, 255, 255],
    "multiple searchable content/append paint gap",
    4,
  );
  await clickSelectChevron("story.select.multiple-search-lg");
  await sleep(120);
  await shot("select-rymht-multiple-search-lg-reclosed");

  // MD/XS also open real Popover alone, not just trigger close.
  await clickSelectChevron("story.select.multiple-md");
  await sleep(250);
  const mdPanel = (await query("story.select.multiple-md.panel"))[0];
  appendLog(`  multiple MD panel: rect=${JSON.stringify(mdPanel.rect)} opacity=${mdPanel.opacity}`);
  near(mdPanel.rect.h, 120, "RYMhT multiple MD panel height", 2);
  await shot("select-rymht-multiple-md-open");
  await clickSelectChevron("story.select.multiple-md");
  await sleep(120);
  await shot("select-rymht-multiple-md-closed");

  // Repeat every searchable transition at MD; size-specific reflow bugs have
  // previously only appeared while the query text or a new tag was present.
  await clickSelectChevron("story.select.multiple-search-md");
  await sleep(180);
  await shot("select-rymht-multiple-search-md-open");
  await clickSelectChevron("story.select.multiple-search-md");
  await sleep(120);
  await shot("select-rymht-multiple-search-md-closed");
  await clickTestId("story.select.multiple-search-md.input");
  await sleep(180);
  await shot("select-rymht-multiple-search-md-focused-open");
  await type_("3");
  await sleep(180);
  await shot("select-rymht-multiple-search-md-filtered-3");
  await clickTestId("story.select.multiple-search-md.option-3");
  await sleep(150);
  await shot("select-rymht-multiple-search-md-selected-option-3");
  await clickSelectChevron("story.select.multiple-search-md");
  await sleep(120);
  await shot("select-rymht-multiple-search-md-reclosed");

  await clickSelectChevron("story.select.multiple-xs");
  await sleep(250);
  const xsTrigger = (await query("story.select.multiple-xs"))[0];
  const xsPanel = (await query("story.select.multiple-xs.panel"))[0];
  // control height unified: XS = control scale xs (padding_y*2 + line_height = 20). Design was 23.
  near(xsTrigger.rect.h, 20, "XS trigger height", 0.75);
  near(xsPanel.rect.h, 120, "RYMhT multiple XS panel height", 2);
  await shot("select-rymht-multiple-xs-open");
  await clickSelectChevron("story.select.multiple-xs");
  await sleep(120);
  await shot("select-rymht-multiple-xs-closed");

  // XS searchable gets the same complete state sequence, including the
  // narrow trigger after a second tag is inserted.
  await clickSelectChevron("story.select.multiple-search-xs");
  await sleep(180);
  await shot("select-rymht-multiple-search-xs-open");
  await clickSelectChevron("story.select.multiple-search-xs");
  await sleep(120);
  await shot("select-rymht-multiple-search-xs-closed");
  await clickTestId("story.select.multiple-search-xs.input");
  await sleep(180);
  await shot("select-rymht-multiple-search-xs-focused-open");
  await type_("3");
  await sleep(180);
  await shot("select-rymht-multiple-search-xs-filtered-3");
  await clickTestId("story.select.multiple-search-xs.option-3");
  await sleep(150);
  await shot("select-rymht-multiple-search-xs-selected-option-3");
  await clickSelectChevron("story.select.multiple-search-xs");
  await sleep(120);
  await shot("select-rymht-multiple-search-xs-reclosed");
});

test("Menu: 交互 — 点开显示 items", async () => {
  await switchTo("menu");
  const pos = await screenPos("story.menu.trigger");
  await clickAt(pos.x + 30, pos.y + 12); // click trigger button
  await sleep(350);
  await shot("menu-open");
  // menu items after open are in window portal root (content already portaled), collect from full
  // window tree
  const root = await tree();
  const out: string[] = [];
  collectText(root, out);
  const joined = out.join(" │ ");
  appendLog(`  menu opened, texts: ${joined}`);
  for (const item of ["Cut", "Copy", "Delete"]) {
    assert(joined.includes(item), `menu 打开后缺 item "${item}" — 实际: ${joined}`);
  }
  // click Copy: on_select gets item id, menu closes via open/close pipeline
  const copy = findRectByText(root, "Copy");
  assert(copy != null, "找不到 Copy 菜单项");
  assert((await clickAt(copy.x + copy.w / 2, copy.y + copy.h / 2)).ok === true);
  const status = async () => (await query("story.menu.status"))[0]?.text ?? "";
  await waitFor(async () => ((await status()) === "picked → copy" ? true : null), getE2eTimeoutMs(2000), 40)
    .catch(async () => { throw new Error(`点 Copy 后应为 "picked → copy"，got "${await status()}"`); });
  await waitFor(async () => {
    const after: string[] = [];
    collectText(await tree(), after);
    return after.join(" │ ").includes("Delete") ? null : true;
  }, getE2eTimeoutMs(2000), 40).catch(() => { throw new Error("选中后菜单应关闭"); });
});

test("Menu: items 由 signal 驱动 — 换数组后重建，点新项拿到它的 id", async () => {
  await switchTo("menu");
  const texts = async () => {
    const out: string[] = [];
    collectText(await tree(), out);
    return out.join(" │ ");
  };
  const another = await screenPos("story.menu.another");
  assert((await clickAt(another.x + another.w / 2, another.y + another.h / 2)).ok === true);
  const recent = await screenPos("story.menu.recent");
  await clickAt(recent.x + 30, recent.y + 12);
  await waitFor(async () => ((await texts()).includes("main.zig") ? true : null), getE2eTimeoutMs(2000), 40)
    .catch(async () => { throw new Error(`换数组后 Recent 菜单应有 main.zig — 实际: ${await texts()}`); });
  await sleep(350); // wait popup animation settle before screenshot
  await shot("menu-recent-open");
  const main = findRectByText(await tree(), "main.zig");
  assert(main != null, "找不到 main.zig 菜单项");
  assert((await clickAt(main.x + main.w / 2, main.y + main.h / 2)).ok === true);
  const status = async () => (await query("story.menu.status"))[0]?.text ?? "";
  await waitFor(async () => ((await status()) === "picked → main" ? true : null), getE2eTimeoutMs(2000), 40)
    .catch(async () => { throw new Error(`点 main.zig 后应为 "picked → main"，got "${await status()}"`); });
});

test("damage-rect: modal 内按钮悬停触发部分重绘（retained 层只重画脏区）", async () => {
  // scenario selection: retained only covers promoted overlay (normal content not promoted). Modal
  // content in layer, button hover only small bg delta -> per-item diff small dirty -> partial.
  //
  // The retained texture must still be resident when the hover frame renders. After 1 s without
  // a GPU frame the runtime's idle trim releases the offscreen pool (by design), and the next
  // frame repaints the layer in full. Fixed sleeps let that gap exceed 1 s whenever the machine
  // is loaded (seen in a parallel run: partial 23 -> 23, one unprimed miss; reproduced every time
  // with ZENIT_IDLE_TRIM_MS=300). Keep the frame loop running for the measurement and wait for
  // states instead of sleeping.
  await switchTo("modal");
  const btn = await screenPos("story.modal.open");
  await clickAt(btn.x + btn.w / 2, btn.y + btn.h / 2);
  await request("POST", "/redraw", { continuous: true });
  try {
    const dlg = (await query("story.modal.dialog"))[0];
    assert(dlg != null, "modal dialog 未打开");
    // Settled and primed: the layer composites from its texture (hits grow) with no repaint.
    let before = await stats();
    const settleStart = Date.now();
    const samples: string[] = [];
    await waitFor(async () => {
      await sleep(60); // continuous redraw: a few frames per sample
      const now = await stats();
      samples.push(`f${now.frame_count - before.frame_count}/h${now.retained_hits - before.retained_hits}/m${now.retained_misses - before.retained_misses}`);
      const settled = now.retained_hits > before.retained_hits && now.retained_misses === before.retained_misses;
      before = now;
      return settled ? true : null;
    }, getE2eTimeoutMs(5000), 0);
    appendLog(`  settled in ${Date.now() - settleStart}ms: ${samples.join(" ")}`);
    const okBtn = await screenPos("story.modal.ok");
    await mouseMove(okBtn.x + okBtn.w / 2, okBtn.y + okBtn.h / 2);
    let after = before;
    await waitFor(async () => {
      after = await stats();
      return after.retained_partial_repaints > before.retained_partial_repaints ? true : null;
    }, getE2eTimeoutMs(3000), 30).catch(() => {});
    await shot("modal-hover-partial-repaint");
    appendLog(
      `  partial: ${before.retained_partial_repaints} -> ${after.retained_partial_repaints}; ` +
      `hits ${before.retained_hits} -> ${after.retained_hits}; misses ${before.retained_misses} -> ${after.retained_misses}`,
    );
    assert(
      after.retained_partial_repaints > before.retained_partial_repaints,
      `modal 内按钮悬停应触发 damage-rect 部分重绘 — partial_repaints ${before.retained_partial_repaints} -> ${after.retained_partial_repaints}`,
    );
  } finally {
    await request("POST", "/redraw", { continuous: false });
    // click overlay blank to close modal (close_on_overlay), don't affect next test
    await clickAt(1000, 60);
    // The dialog node is reused across open/close; a closed modal reports visible=false.
    await waitFor(async () => ((await query("story.modal.dialog"))[0]?.visible === false ? true : null), getE2eTimeoutMs(3000), 50)
      .catch(() => appendLog("  modal did not close after the overlay click"));
  }
});

// ── zindex: system z-index manager verification (tier baseline + overflow escape + nesting
// inherit) ──

function rectsOverlap(a: { x: number; y: number; w: number; h: number }, b: { x: number; y: number; w: number; h: number }): boolean {
  return a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h;
}

test("zindex: 兄弟 z_index 覆盖 DOM 顺序（red z=3 最上）", async () => {
  await switchTo("zindex");
  await sleep(400);
  await shot("zindex-static");
  const arena = (await query("story.zindex.siblings"))[0];
  assert(arena != null, "siblings arena 不存在");
  // three 130x80 overlaps: x in [60,130], y in [20,80] (arena local) -> sample center
  const px = centerPixel(`${DIR}/story-zindex-static.png`, { x: arena.rect.x + 60, y: arena.rect.y + 20, w: 70, h: 60 });
  assertColorNear(px, [220, 50, 47], "三兄弟交叠区必须是 red（z=3, DOM 最先）", 20);
});

test("zindex: overflow 容器内 popover 溢出裁剪并盖住障碍物", async () => {
  await switchTo("zindex");
  const click = await clickTestId("story.zindex.pop.trigger");
  assert(click.ok === true, `popover trigger click failed: ${JSON.stringify(click)}`);
  const slab = await waitFor(async () => {
    const node = (await query("story.zindex.pop.slab"))[0];
    return node != null && node.rect.w > 0 && (node.effective_opacity ?? 0) >= 0.99 ? node : null;
  }, getE2eTimeoutMs(2000), 50);
  const obstacle = (await query("story.zindex.obstacle"))[0];
  assert(obstacle != null, "obstacle 不存在");
  // precondition: slab must really overlap obstacles, else pixel assert tests air
  appendLog(`  slab=${JSON.stringify(slab.rect)} obstacle=${JSON.stringify(obstacle.rect)}`);
  assert(rectsOverlap(slab.rect, obstacle.rect), "布局漂移：popover slab 未与 obstacle 交叠，断言失去意义");
  await shot("zindex-popover-open");
  // sample slab-obstacle overlap center, must be indigo (popover on top), broken layering reads
  // orange (obstacle) or yellow (transform diamond).
  const ix = Math.max(slab.rect.x, obstacle.rect.x);
  const iy = Math.max(slab.rect.y, obstacle.rect.y);
  const iw = Math.min(slab.rect.x + slab.rect.w, obstacle.rect.x + obstacle.rect.w) - ix;
  const ih = Math.min(slab.rect.y + slab.rect.h, obstacle.rect.y + obstacle.rect.h) - iy;
  const px = centerPixel(`${DIR}/story-zindex-popover-open.png`, { x: ix, y: iy, w: iw, h: ih });
  assertColorNear(px, [79, 70, 229], "popover slab 必须盖住障碍物", 20);
  // finish: click far blank to close
  await clickAt(1000, 600);
  await sleep(400);
});

test("zindex: tooltip tier 溢出裁剪并盖住障碍物", async () => {
  await switchTo("zindex");
  const trig = await screenPos("story.zindex.tip.trigger");
  await mouseMove(trig.x + trig.w / 2, trig.y + trig.h / 2);
  const tip = await waitFor(async () => {
    const node = (await query("story.zindex.tip.content"))[0];
    return node != null && node.rect.w > 0 && (node.effective_opacity ?? 0) >= 0.99 ? node : null;
  }, getE2eTimeoutMs(2000), 50);
  const obstacle = (await query("story.zindex.obstacle"))[0];
  appendLog(`  tip=${JSON.stringify(tip.rect)} obstacle=${JSON.stringify(obstacle.rect)}`);
  assert(rectsOverlap(tip.rect, obstacle.rect), "布局漂移：tooltip 未与 obstacle 交叠，断言失去意义");
  await shot("zindex-tooltip-open");
  // sample tooltip-obstacle overlap darkest pixel: tooltip dark bubble on top -> near black;
  // covered -> max only pure orange (255,150,40) -> assert red.
  const ix = Math.max(tip.rect.x, obstacle.rect.x);
  const iy = Math.max(tip.rect.y, obstacle.rect.y);
  const iw = Math.min(tip.rect.x + tip.rect.w, obstacle.rect.x + obstacle.rect.w) - ix;
  const ih = Math.min(tip.rect.y + tip.rect.h, obstacle.rect.y + obstacle.rect.h) - iy;
  const dk = darkestPixel(`${DIR}/story-zindex-tooltip-open.png`, { x: ix, y: iy, w: iw, h: ih });
  appendLog(`  tooltip∩obstacle darkest: (${dk.join(",")})`);
  assert(dk[0] < 90 && dk[1] < 90 && dk[2] < 90, `tooltip 气泡未盖住障碍物 — 交叠区最深像素 (${dk.join(",")})`);
  await mouseMove(20, 400);
  await sleep(400);
});

test("zindex: modal 内嵌 popover 压过 dialog（嵌套 tier 继承）", async () => {
  await switchTo("zindex");
  const openClick = await clickTestId("story.zindex.modal.open");
  assert(openClick.ok === true, `modal trigger click failed: ${JSON.stringify(openClick)}`);
  await waitFor(async () => {
    const node = (await query("story.zindex.modal.dialog"))[0];
    return node != null && (node.effective_opacity ?? 0) >= 0.99 ? node : null;
  }, getE2eTimeoutMs(2000), 50);
  const popClick = await clickTestId("story.zindex.modal.pop.trigger");
  assert(popClick.ok === true, `nested popover trigger click failed: ${JSON.stringify(popClick)}`);
  const slab = await waitFor(async () => {
    const node = (await query("story.zindex.modal.pop.slab"))[0];
    return node != null && node.rect.w > 0 && (node.effective_opacity ?? 0) >= 0.99 ? node : null;
  }, getE2eTimeoutMs(2000), 50);
  await shot("zindex-modal-popover");
  const px = centerPixel(`${DIR}/story-zindex-modal-popover.png`, slab.rect);
  assertColorNear(px, [79, 70, 229], "modal 内 popover slab 必须在 dialog 之上", 20);
  // finish: two Escape close popover then modal
  await key("escape");
  await sleep(300);
  await key("escape");
  await sleep(500);
});

test("zindex: modal body 里的 tooltip 恒顶（tooltip tier）", async () => {
  await switchTo("zindex");
  // Prior z-index cases close overlays with Escape without moving the physical
  // hover coordinate. Establish a fresh outside -> trigger edge so this case
  // does not inherit an already-hovered ancestor from the previous case.
  await mouseMove(-10, -10);
  const openClick = await clickTestId("story.zindex.modal.open");
  assert(openClick.ok === true, `modal trigger click failed: ${JSON.stringify(openClick)}`);
  await waitFor(async () => {
    const node = (await query("story.zindex.modal.dialog"))[0];
    return node != null && (node.effective_opacity ?? 0) >= 0.99 ? node : null;
  }, getE2eTimeoutMs(2000), 50);
  const trig = await screenPos("story.zindex.modal.tip.trigger");
  await mouseMove(trig.x + trig.w / 2, trig.y + trig.h / 2);
  // wait bubble fully visible (effective opacity includes ancestor fade-in), not sleep guessing:
  // high load fixed 300ms captures semi-transparent bubble, mispredicts 'blocked/undrawn'.
  const tip = await waitFor(async () => {
    const node = (await query("story.zindex.modal.tip.content"))[0];
    return node != null && node.rect.w > 0 && (node.effective_opacity ?? 0) >= 0.99 ? node : null;
  }, getE2eTimeoutMs(2000), 50);
  await shot("zindex-modal-tooltip");
  // dark bubble drawn over light dialog: bubble area darkest pixel near black
  const dk = darkestPixel(`${DIR}/story-zindex-modal-tooltip.png`, tip.rect);
  appendLog(`  modal tooltip darkest: (${dk.join(",")})`);
  assert(dk[0] < 90 && dk[1] < 90 && dk[2] < 90, `modal 内 tooltip 未画出/被盖 — 最深像素 (${dk.join(",")})`);
  await mouseMove(20, 400);
  await sleep(300);
  await key("escape");
  await sleep(500);
});

test("zindex: 三级嵌套 modal → popover → modal2（tier 链）", async () => {
  await switchTo("zindex");
  const openClick = await clickTestId("story.zindex.modal.open");
  assert(openClick.ok === true, `modal trigger click failed: ${JSON.stringify(openClick)}`);
  await waitFor(async () => {
    const node = (await query("story.zindex.modal.dialog"))[0];
    return node != null && (node.effective_opacity ?? 0) >= 0.99 ? node : null;
  }, getE2eTimeoutMs(2000), 50);
  const popClick = await clickTestId("story.zindex.modal.pop.trigger");
  assert(popClick.ok === true, `nested popover trigger click failed: ${JSON.stringify(popClick)}`);
  await waitFor(async () => {
    const node = (await query("story.zindex.modal.pop.slab"))[0];
    return node != null && node.rect.w > 0 ? node : null;
  }, getE2eTimeoutMs(2000), 50);
  // wait popover entrance done before clicking modal2 trigger: node up early (rect ready) but
  // entrance phase not yet accepting hits, click lands on background modal mask (hit log: hit Modal
  // not button).
  await waitFor(async () => {
    const node = (await query("story.zindex.modal2.open"))[0];
    return node != null && node.rect.w > 0 && (node.effective_opacity ?? 0) >= 0.99 ? node : null;
  }, getE2eTimeoutMs(2000), 50);
  const modal2Click = await clickTestId("story.zindex.modal2.open");
  assert(modal2Click.ok === true, `modal2 trigger click failed: ${JSON.stringify(modal2Click)}`);
  // wait modal2 fully visible (entrance fade-in on ancestor), not sleep.
  const slab2 = await waitFor(async () => {
    const node = (await query("story.zindex.modal2.slab"))[0];
    return node != null && node.rect.w > 0 && (node.effective_opacity ?? 0) >= 0.99 ? node : null;
  }, getE2eTimeoutMs(2000), 50);
  await shot("zindex-modal2");
  const px = centerPixel(`${DIR}/story-zindex-modal2.png`, slab2.rect);
  assertColorNear(px, [20, 150, 140], "popover 里开出的 modal2 必须在最上（teal slab 可见）", 20);
  // finish: Escape each layer
  for (let i = 0; i < 3; i++) {
    await key("escape");
    await sleep(300);
  }
  await sleep(300);
});

function glassRegionRmse(pathA: string, pathB: string, r: {x:number;y:number;w:number;h:number}, exclude?: {x:number;y:number;radius:number}): number {
  const a=decodePng(pathA),b=decodePng(pathB),scale=decodedCaptureScale(a);
  assert(a.width===b.width&&a.height===b.height&&a.channels===b.channels,"glass screenshots dimensions changed");
  const x0=Math.ceil((r.x+6)*scale),x1=Math.floor((r.x+r.w-6)*scale);
  const y0=Math.ceil((r.y+6)*scale),y1=Math.floor((r.y+r.h-6)*scale);
  assert(x0>=0&&y0>=0&&x1<=a.width&&y1<=a.height&&x1>x0&&y1>y0,
    `glass material region must be fully captured: ${JSON.stringify({r,scale,x0,x1,y0,y1,width:a.width,height:a.height})}`);
  let sum=0,n=0;
  for(let y=y0;y<y1;y++) {
    for(let x=x0;x<x1;x++) {
      // the harness draws a virtual cursor into screenshots; keep it out of material comparisons
      if(exclude&&Math.abs(x/scale-exclude.x)<exclude.radius&&Math.abs(y/scale-exclude.y)<exclude.radius) continue;
      for(let c=0;c<3;c++) {const d=a.pixels[(y*a.width+x)*a.channels+c]-b.pixels[(y*b.width+x)*b.channels+c];sum+=d*d;n++;}
    }
  }
  assert(n>100,"glass region is empty");return Math.sqrt(sum/n);
}

test("GlassBox: .glass 按钮按下当帧主体平移（原生 −19.8 色阶）、悬停不变、松开复原", async () => {
  await switchTo("glassbox");
  let r=(await query("story.glassbox.glassbutton"))[0]?.rect;
  assert(r,"glass button missing");
  for(let i=0;i<12&&(r.y<80||r.y+r.h>940);i++){
    await scrollAt(950,700,0,r.y<80?120:-120);await sleep(100);
    r=(await query("story.glassbox.glassbutton"))[0].rect;
  }
  await mouseMove(-10,-10);await sleep(500);
  const shotAt=async(name:string)=>{const p=`${DIR}/glassbutton-${name}.png`;assert((await screenshot(p)).ok===true,`${name} screenshot failed`);return decodePng(p);};
  const x=r.x+r.w/2,y=r.y+r.h/2;
  // main sample: button left 8px band (avoid text + cursor)
  const patch={x:r.x+8,y:r.y+r.h/2-4,w:8,h:8};
  const rest=await shotAt("rest");
  await mouseMove(x,y);await sleep(300);const hover=await shotAt("hover");
  await mouseDown(x,y);await sleep(120);const pressed=await shotAt("pressed");
  await mouseUp(x,y);await mouseMove(-10,-10);await sleep(300);const released=await shotAt("released");
  const L=(png:ReturnType<typeof decodePng>)=>{const c=meanRgbOf(png,patch,decodedCaptureScale(png));return (c[0]+c[1]+c[2])/3;};
  appendLog(`  glass button body: rest ${L(rest).toFixed(1)} hover ${L(hover).toFixed(1)} pressed ${L(pressed).toFixed(1)} released ${L(released).toFixed(1)}`);
  assert(Math.abs(L(hover)-L(rest))<1.5,"hover must not change the glass button body");
  const d=L(rest)-L(pressed);
  assert(d>15&&d<25,`pressed body should darken by ≈19.8 levels (got ${d.toFixed(1)})`);
  assert(Math.abs(L(released)-L(rest))<1.5,"released button must return to rest");
});

test("GlassLab: real pointer drag moves glass and preserves rendered content", async () => {
  await switchTo("glasslab");await settle(500);
  const r=(await query("story.glasslab.drag"))[0]?.rect;
  assert(r&&r.y>=0&&r.y+r.h<1000,"drag glass must be in the window");
  const x=r.x+r.w/2,y=r.y+r.h/2;
  await mouseMove(x,y);await mouseDown(x,y);
  for(let step=1;step<=8;step++){await mouseMove(x+step*10,y+step*3);await sleep(20);}
  await mouseUp(x+80,y+24);await sleep(300);
  const after=(await query("story.glasslab.drag"))[0]?.rect;
  assert(after&&Math.abs(after.x-r.x-80)<1&&Math.abs(after.y-r.y-24)<1,`drag lost geometry: ${JSON.stringify(r)} -> ${JSON.stringify(after)}`);
  const path=`${DIR}/glasslab-dragged.png`;assert((await screenshot(path)).ok===true,"drag screenshot failed");
  const png=decodePng(path),s=decodedCaptureScale(png);
  const inner={x:after.x+20,y:after.y+20,w:after.w-40,h:after.h-40};
  assert(countNonBackgroundPixels(png,inner,s,8)>100,"dragged glass lost its content/material");
  // drag outside container layout box also glass (container surface by union exterior): both ends
  // should light frosted
  const left=meanRgbOf(png,{x:after.x+16,y:after.y+after.h/2-6,w:16,h:12},s), right=meanRgbOf(png,{x:after.x+after.w-32,y:after.y+after.h/2-6,w:16,h:12},s);
  appendLog(`  dragged glass ends: left=${left.map(v=>v.toFixed(0))} right=${right.map(v=>v.toFixed(0))}`);
  const lum=(c:number[])=>0.2126*c[0]+0.7152*c[1]+0.0722*c[2];
  assert(lum(left)>190&&lum(right)>190,`dragged glass clipped by its container: left=${lum(left).toFixed(0)} right=${lum(right).toFixed(0)}`);
  assert((await health()).status==="ok","app died during glass drag");
});

test("GlassBox: 原生 macOS 交互——悬停玻璃不变、按下内容变淡、松开复原", async () => {
  await switchTo("glassbox");
  // Native windows can be clamped to a shorter desktop than the requested
  // test size. Measure the captured client rather than assuming 940px fits.
  const viewportPath=`${DIR}/glassbox-viewport.png`;
  assert((await screenshot(viewportPath)).ok===true,"viewport screenshot failed");
  const viewport=decodePng(viewportPath),scale=decodedCaptureScale(viewport);
  const visibleWidth=viewport.width/scale,visibleBottom=viewport.height/scale-20;
  let r=(await query("story.glassbox.interactive"))[0]?.rect;
  assert(r,"interactive glass missing");
  for(let i=0;i<12&&(r.y<80||r.y+r.h>visibleBottom);i++){
    await scrollAt(Math.min(950,visibleWidth-20),Math.min(700,visibleBottom),0,r.y<80?120:-120);await sleep(100);
    r=(await query("story.glassbox.interactive"))[0].rect;
  }
  assert(r.x>=0&&r.x+r.w<=visibleWidth&&r.y>=80&&r.y+r.h<=visibleBottom,
    `interactive glass offscreen: ${JSON.stringify({r,visibleWidth,visibleBottom})}`);
  await mouseMove(-10,-10);await sleep(700);
  const paths=["rest","hover","press","released"].map(k=>`${DIR}/glassbox-${k}.png`);
  assert((await screenshot(paths[0])).ok===true,"rest screenshot failed");
  const x=r.x+r.w/2,y=r.y+r.h/2;
  await mouseMove(x,y);await sleep(350);assert((await screenshot(paths[1])).ok===true,"hover screenshot failed");
  await mouseDown(x,y);await sleep(350);assert((await screenshot(paths[2])).ok===true,"press screenshot failed");
  await mouseUp(x,y);await mouseMove(-10,-10);await sleep(900);assert((await screenshot(paths[3])).ok===true,"release screenshot failed");
  const cur={x,y,radius:28};
  const hover=glassRegionRmse(paths[0],paths[1],r,cur),press=glassRegionRmse(paths[1],paths[2],r,cur),release=glassRegionRmse(paths[0],paths[3],r,cur);
  appendLog(`  material pixel RMSE: hover=${hover} press=${press} settled=${release}`);
  // native_interactive.swift: .interactive() glass on mouse hover has zero pixel change
  assert(hover<0.3,`hover must not change the glass material (native shows none): ${hover}`);
  assert(press>0.1,"press (content fade) did not change on screen");
  assert(release<2.5,`released glass failed to return to rest (${release})`);
  assert((await health()).status==="ok","app died during material interaction");
});

test("GlassMotion: morph 几何过渡 + scroll-edge + backdrop 亮度实测", async () => {
  await switchTo("glassmotion");
  await settle(500);
  const before = (await query("story.glassmotion.morph"))[0]?.rect;
  assert(before, "morph 玻璃节点应存在");
  await clickTestId("story.glassmotion.morphbtn");
  await sleep(800); // wait 18-frame morph transition complete
  const after = (await query("story.glassmotion.morph"))[0]?.rect;
  appendLog(`  morph rect: ${JSON.stringify(before)} -> ${JSON.stringify(after)}`);
  assert(Math.abs(after.w - before.w) > 50, `morph 应显著改变宽度 (${before.w} -> ${after.w})`);
  await shot("glassmotion-morphed");
  const toolbarText=(await query("story.glassmotion.label"))[0]?.rect;
  assert(toolbarText,"toolbar foreground label missing");
  const ink=darkestPixel(`${DIR}/story-glassmotion-morphed.png`,toolbarText);
  assert(ink[0]+ink[1]+ink[2]<210,`toolbar foreground lost contrast against light glass: ${ink}`);

  // scroll-edge: program scroll glass bar shows edge fade. Regression: Scroll +80 directly wrote
  // ScrollState.scroll_y (bypassed setScrollY), state changed but content translate didn't sync,
  // stationary, old screenshot-only missed.
  const rowBefore = findByText(await tree(), "Content row 2");
  assert(rowBefore, "Content row 2 应可见");
  await clickTestId("story.glassmotion.scrollbtn");
  await sleep(500);
  const rowAfter = findByText(await tree(), "Content row 2");
  appendLog(`  Scroll +80: Content row 2 y ${rowBefore.y} -> ${rowAfter?.y}`);
  assert(rowAfter && Math.abs(rowBefore.y - rowAfter.y - 80) < 1, `Scroll +80 应让内容上移 80px (${rowBefore.y} -> ${rowAfter?.y})`);
  await shot("glassmotion-scrolled");

  // backdrop brightness auto-adapt: glass on screen -> GPU luminance readback should produce
  // measured value
  const st = await stats();
  appendLog(`  backdrop_luminance_milli: ${st.backdrop_luminance_milli}`);
  // per-region brightness pooled after 2026-08-02, global = all glass area average: white scroll
  // area glass + colorful glass mix, average mid-range. Assert converges to 'pipeline alive +
  // physically reasonable' (-1000 = readback offline).
  assert(st.backdrop_luminance_milli > 80 && st.backdrop_luminance_milli < 1000, `backdrop luminance 实测应在合理区间 (got ${st.backdrop_luminance_milli}‰)`);
  assert((await health()).status === "ok", "app died after glassmotion");
});

/// grayscale gradient energy: mean absolute luminance diff of adjacent pixels. Sharp text strokes
/// contribute high-frequency edges, same text through frosted glass -> blur flattens -> energy
/// drops.
function gradientEnergy(pngPath: string, rect: { x: number; y: number; w: number; h: number }): number {
  const png = decodePng(pngPath);
  const s = captureScale(pngPath, png.width);
  const x0 = Math.round(rect.x * s), y0 = Math.round(rect.y * s);
  const x1 = Math.round((rect.x + rect.w) * s), y1 = Math.round((rect.y + rect.h) * s);
  const lum = (x: number, y: number) => {
    const i = (y * png.width + x) * png.channels;
    return 0.299 * png.pixels[i] + 0.587 * png.pixels[i + 1] + 0.114 * png.pixels[i + 2];
  };
  let e = 0, n = 0;
  for (let y = y0; y < y1 - 1; y++) {
    for (let x = x0; x < x1 - 1; x++) {
      const c = lum(x, y);
      e += Math.abs(lum(x + 1, y) - c) + Math.abs(lum(x, y + 1) - c);
      n++;
    }
  }
  return e / Math.max(n, 1);
}

test("GlassMotion: scroll-edge 玻璃条在任意滚动位置都持续模糊背后内容", async () => {
  // regression (2026-09-29 user report): real scroll-wheel scrolls scroll-edge block, glass bar
  // lower half loses blur, 'Content row N' sharp bleed-through, overlaps bar text. Root: GlassBox
  // scroll-edge stops 1->0 (base glossiness to sharp) + shader treats BlurGradient.strength as
  // target blur (str>0.001 means full effect). Criterion: glass bar area gradient energy stays near
  // non-scrolled baseline across positions, far below unblocked content (sharp text energy
  // reference).
  await switchTo("glassmotion");
  await settle(300);
  let bar = (await query("story.glassmotion.bar"))[0]?.rect;
  assert(bar, "scroll-edge 玻璃条节点应存在");
  const wheelX = bar.x + 200, wheelY = bar.y + 150;
  // reset to top first (prior test clicked Scroll +80)
  // scroll up aggressively triggers rebound: wait 'Content row 0' back at top (rebound done)
  await scrollAt(wheelX, wheelY, 0, 2000);
  // scroll-wheel exhausts ScrollArea then overflows main panel (prior test may leave page offset),
  // glass bar follows page position: use post-scroll rect.
  await sleep(200);
  bar = (await query("story.glassmotion.bar"))[0]?.rect;
  assert(bar, "scroll-edge 玻璃条节点应存在（滚后）");
  await waitFor(async () => {
    const r0 = findByText(await tree(), "Content row 0");
    return r0 && Math.abs(r0.y - bar.y) < 1 ? r0 : null;
  }, 4000, 50);
  await sleep(400);
  // Sample below the toolbar's own foreground glyphs. Foreground text must
  // remain sharp; only the content behind the material should lose detail.
  const glassBand = { x: bar.x + 4, y: bar.y + 26, w: 190, h: bar.h - 30 };
  // reference band: glass bar below, same width height, unblocked content (outside shadow)
  const sharpBand = { x: bar.x + 4, y: bar.y + bar.h + 24, w: 190, h: bar.h - 30 };
  const base = `${DIR}/story-glassmotion-scroll-0.png`;
  await screenshot(base);
  const baseE = gradientEnergy(base, glassBand);
  appendLog(`  scroll 0: glass=${baseE.toFixed(2)} sharp=${gradientEnergy(base, sharpBand).toFixed(2)}`);
  // small (just started scroll, edge strength climbing) + mid + large (full strength, deep scroll)
  const steps = [6, 20, 40, 120, 300];
  let total = 0;
  for (const dy of steps) {
    total += dy;
    await scrollAt(wheelX, wheelY, 0, -dy);
    await sleep(450);
    const png = `${DIR}/story-glassmotion-scroll-${total}.png`;
    await screenshot(png);
    const g = gradientEnergy(png, glassBand);
    const sh = gradientEnergy(png, sharpBand);
    appendLog(`  scroll ${total}: glass=${g.toFixed(2)} sharp=${sh.toFixed(2)}`);
    assert(sh > 3, `参照带应是锐利文字（sharp=${sh.toFixed(2)}），否则判据失效`);
    assert(g < sh * 0.35, `滚动 ${total}px 后玻璃条背后文字未被模糊: glass=${g.toFixed(2)} vs sharp=${sh.toFixed(2)}`);
    assert(g < baseE + 1.0, `滚动 ${total}px 后玻璃条高频细节显著上升（blur 失效）: ${g.toFixed(2)} vs 未滚动 ${baseE.toFixed(2)}`);
  }
  assert((await health()).status === "ok", "app died after glassmotion scroll");
});

test("GlassChrome: Scroll ±90 按钮真的滚动画布（经 setScrollY，边界 clamp）", async () => {
  // regression: button callback directly wrote ScrollState.scroll_y, canvas unmoved.
  await switchTo("glasschrome");
  await settle(400);
  const y = async () => (await query("story.glasschrome.canvas"))[0]?.rect.y;
  const y0 = await y();
  assert(y0 !== undefined, "story.glasschrome.canvas 应存在");
  await clickTestId("story.glasschrome.scrolldown");
  await sleep(400);
  const y1 = await y();
  appendLog(`  Scroll +90: canvas y ${y0} -> ${y1}`);
  assert(y1 !== undefined && Math.abs(y0 - y1 - 90) < 1, `Scroll +90 应让画布上移 90px (${y0} -> ${y1})`);
  // titlebar edge (native_titlebar_scroll.swift measured): scroll to edge, note below disappears
  // into background -> top 0.85, ~76pt gone. 'Glass QA' green note spans stage y -4..72: compare
  // text right side y~12 vs y~66 chroma.
  const st = (await query("story.glasschrome.stage"))[0]?.rect;
  assert(st, "story.glasschrome.stage 应存在");
  const edgePath = `${DIR}/glasschrome-scrolled.png`;
  assert((await screenshot(edgePath)).ok === true, "glasschrome screenshot failed");
  const png = decodePng(edgePath);
  const chroma = (yy: number) => { const c = meanRgbOf(png, { x: st.x + 250, y: st.y + yy - 2, w: 20, h: 4 }, decodedCaptureScale(png)); return Math.max(...c) - Math.min(...c); };
  const cTop = chroma(12), cLow = chroma(66);
  appendLog(`  titlebar edge chroma: y12 ${cTop.toFixed(1)} y66 ${cLow.toFixed(1)}`);
  assert(cLow > 60, `边缘带底部应基本露出便签原色 (chroma ${cLow.toFixed(1)})`);
  const ratio = cTop / cLow;
  assert(ratio > 0.08 && ratio < 0.25, `边缘带顶部应洗掉约 85% 而非全遮住 (ratio ${ratio.toFixed(2)}，期望 ≈0.15)`);
  // back to top then scroll up: clamp at 0, no overflow
  await clickTestId("story.glasschrome.scrollup");
  await sleep(400);
  await clickTestId("story.glasschrome.scrollup");
  await sleep(400);
  const y2 = await y();
  assert(y2 !== undefined && Math.abs(y2 - y0) < 1, `Scroll −90 两次应停在顶部 (${y0} vs ${y2})`);
  assert((await health()).status === "ok", "app died after glasschrome scroll");
});

test("PaintReplay: 兄弟变化时 overflow_hidden 容器走缓存回放，父背景不重复发射、不盖住子节点", async () => {
  // regression: legacy overflow cached replay reissued own content after parent, opaque covers
  // child (progress fill gone), translucent darkens, single-frame only when replaying. Create
  // 'parent rerec, container clean' frames via list add/remove + cursor cross, use /stats
  // paint_duplicate_fills, sample post-interaction three child colors (fill/block/dot) always own
  // color.
  await switchTo("paintreplay");
  await sleep(300);
  const base = (await stats()).paint_duplicate_fills;
  const children: [string, [number, number, number]][] = [
    ["story.paintreplay.fill", [76, 195, 138]],
    ["story.paintreplay.swatch", [232, 163, 61]],
  ];
  const check = async (tag: string) => {
    const png = `${DIR}/story-paintreplay-${tag}.png`;
    const r = await screenshot(png);
    assert(r.ok === true, `paintreplay screenshot ${tag} 失败`);
    for (const [id, want] of children) {
      const rect = (await query(id))[0]?.rect;
      assert(rect != null && rect.w > 0, `${id} 应存在`);
      assertColorNear(centerPixel(png, rect), want, `${tag} ${id}`, 24);
    }
  };
  for (let i = 0; i < 4; i++) {
    await clickTestId("story.paintreplay.add");
    await check(`add${i}`);
    // cursor over list row (hover bg) + container: parent rerec, container unchanged
    const rows = (await query("story.paintreplay.rows"))[0]?.rect;
    assert(rows != null, "列表应存在");
    await mouseMove(rows.x + 30, rows.y + 8);
    await check(`hover-top${i}`);
    await mouseMove(rows.x + 30, rows.y + rows.h - 8);
    await check(`hover-bottom${i}`);
  }
  await clickTestId("story.paintreplay.remove");
  await check("remove");
  await mouseMove(-10, -10);
  const st = await stats();
  appendLog(`  paint_duplicate_fills: ${base} → ${st.paint_duplicate_fills} (node ${st.paint_duplicate_node})`);
  assert(st.paint_duplicate_fills === base, `缓存回放重复发射了 ${st.paint_duplicate_fills - base} 条填充矩形（最近的节点 ${st.paint_duplicate_node}）`);
  assert((await health()).status === "ok", "app died after paintreplay");
});

/** Per-row (axis "x": strips are columns; "y": rows) mean luminance of a capture region. */
function meanLuma(pngPath: string, rect: { x: number; y: number; w: number; h: number }): number {
  const png = decodePng(pngPath);
  const scale = captureScale(pngPath, png.width);
  const x0 = Math.max(0, Math.round(rect.x * scale)), y0 = Math.max(0, Math.round(rect.y * scale));
  const x1 = Math.min(png.width, Math.round((rect.x + rect.w) * scale)), y1 = Math.min(png.height, Math.round((rect.y + rect.h) * scale));
  assert(x1 > x0 && y1 > y0, "pixel sample region outside capture");
  let sum = 0, n = 0;
  for (let y = y0; y < y1; y++) for (let x = x0; x < x1; x++) {
    const i = (y * png.width + x) * png.channels;
    sum += 0.2126 * png.pixels[i] + 0.7152 * png.pixels[i + 1] + 0.0722 * png.pixels[i + 2];
    n++;
  }
  return sum / n;
}

test("GlassEdge: 贴窗口边缘的 glass 无黑边", async () => {
  // Regression: the capture pad extending past the window RT is cleared to transparent
  // black; if the glass shader does not normalize by coverage, edge-hugging panels get a black halo
  // (seen on the left/right panels of the canvas app). The story leaves Storybook's sidebar and
  // header alone: the inspector is flush with the right and bottom edges, the toolbar with the
  // bottom edge, over a slowly varying wallpaper.
  await switchTo("glassedge");
  const right = (await query("story.glassedge.right"))[0]?.rect;
  const bottom = (await query("story.glassedge.bottom"))[0]?.rect;
  const st = await stats();
  assert(right && bottom, "贴边玻璃（右 inspector / 底工具栏）应存在");
  const win = { w: right.x + right.w, h: right.y + right.h };
  appendLog(`  panels: right=${JSON.stringify(right)} bottom=${JSON.stringify(bottom)} window_scale=${st.window_scale}`);
  // panels must really meet the window edges, else the pad overflow is not exercised
  assert(right.x > 400 && right.y >= 40, `inspector 应在侧栏与标题栏之外 (x=${right.x}, y=${right.y})`);
  assert(Math.abs(bottom.y + bottom.h - win.h) <= 1, `toolbar 应贴窗口底边 (bottom=${bottom.y + bottom.h}, window=${win.h})`);
  await sleep(400); // wait glass composite stable
  const png = `${DIR}/story-glassedge.png`;
  await shot("glassedge");
  // Over a wallpaper that varies slowly along each edge's normal, the strip at the window edge
  // must not read darker than the glass 30 pt further in (the fringe darkens it by ~100 levels;
  // the rim only brightens).
  const pairs: [string, { x: number; y: number; w: number; h: number }, { x: number; y: number; w: number; h: number }][] = [
    ["right-edge", { x: right.x + right.w - 5, y: right.y + 200, w: 4, h: right.h - 300 }, { x: right.x + right.w - 35, y: right.y + 200, w: 4, h: right.h - 300 }],
    ["right-bottom-edge", { x: right.x + 30, y: right.y + right.h - 5, w: right.w - 60, h: 4 }, { x: right.x + 30, y: right.y + right.h - 35, w: right.w - 60, h: 4 }],
    // (the toolbar's inner strip below its centred label)
    ["toolbar-bottom-edge", { x: bottom.x + 30, y: bottom.y + bottom.h - 5, w: bottom.w - 60, h: 4 }, { x: bottom.x + 30, y: bottom.y + bottom.h - 20, w: bottom.w - 60, h: 4 }],
  ];
  for (const [label, edge, inner] of pairs) {
    const e = meanLuma(png, edge), i = meanLuma(png, inner);
    appendLog(`  ${label}: edge ${e.toFixed(1)} inner ${i.toFixed(1)}`);
    assert(i - e < 40, `${label} 边缘比内侧暗 ${(i - e).toFixed(1)} 级（黑边 fringe）`);
  }
  // and the darkest pixel along the window's right edge stays light (black bug: sum < 150)
  const [r, g, b] = darkestPixel(png, { x: right.x + right.w - 3, y: right.y + 60, w: 2, h: right.h - 120 });
  appendLog(`  right-edge darkest=(${r},${g},${b})`);
  assert(r + g + b > 330, `right-edge 出现黑边 fringe: darkest=(${r},${g},${b})`);
  assert((await health()).status === "ok", "app died after glassedge");
});

// ── CJK weights: every glyph of a semibold Han line is heavier than the regular line ──
// examples/storybook/cjk_weights: one 12-character Han line at 16pt in 400 / 600 / 700, in the UI
// font and in a Latin-only family whose Han glyphs all come from a fallback face. Each full-width
// glyph owns 1/12 of the line; its ink (background minus luma, summed) must grow with the weight
// glyph by glyph. A fallback face shared between weights hands the regular bitmaps rasterized
// first to the bold lines: those glyphs keep the regular ink (ratio ~1.0) while the rest are bold.
test("CJK weights: every glyph of a semibold / bold Han line is heavier than the regular line", async () => {
  await switchTo("cjkweights");
  await settle(300);
  const path = `${DIR}/story-cjkweights.png`;
  await screenshot(path);
  const png = decodePng(path);
  const scale = decodedCaptureScale(png);
  const glyphs = 12;
  const inkPerGlyph = async (id: string): Promise<number[]> => {
    const r = (await query(id))[0]?.rect;
    assert(r != null && r.w > 0, `${id} missing`);
    appendLog(`  ${id} rect=(${r.x},${r.y},${r.w},${r.h})`);
    const bg = pixelRgb(png, scale, r.x - 4, r.y + r.h / 2);
    const bgL = 0.299 * bg[0] + 0.587 * bg[1] + 0.114 * bg[2];
    const out: number[] = [];
    for (let i = 0; i < glyphs; i++) {
      const x0 = Math.round((r.x + (r.w * i) / glyphs) * scale), x1 = Math.round((r.x + (r.w * (i + 1)) / glyphs) * scale);
      const y0 = Math.floor(r.y * scale), y1 = Math.ceil((r.y + r.h) * scale);
      let ink = 0;
      for (let y = y0; y < y1; y++) for (let x = x0; x < x1; x++) {
        const k = (y * png.width + x) * png.channels;
        ink += Math.max(0, bgL - (0.299 * png.pixels[k] + 0.587 * png.pixels[k + 1] + 0.114 * png.pixels[k + 2]));
      }
      out.push(ink);
    }
    return out;
  };
  const failures: string[] = [];
  for (const family of ["system", "latin"]) {
    const regular = await inkPerGlyph(`story.cjkweights.${family}.400`);
    assert(regular.every((v) => v > 0), `${family}.400: a glyph cell has no ink`);
    for (const weight of [600, 700]) {
      const heavy = await inkPerGlyph(`story.cjkweights.${family}.${weight}`);
      const ratios = heavy.map((v, i) => v / regular[i]);
      appendLog(`  ${family} ${weight}/400 per glyph: ${ratios.map((q) => q.toFixed(2)).join(" ")}`);
      ratios.forEach((q, i) => {
        if (q < 1.1) failures.push(`${family} ${weight}: glyph ${i} (${"连接拒绝重新探测同意共享"[i]}) ink ${q.toFixed(2)}x the regular line`);
      });
    }
  }
  assert(failures.length === 0, `Han glyphs not heavier at the heavier weight:\n${failures.join("\n")}`);
});

// ── Per-corner overflow clip: rounded corners cut the square red fill, square corners keep it ──
// Each specimen paints nothing itself; only its overflow clip can round the fill. Probes sit 2pt
// and 5pt in from each corner along the diagonal: 2pt is outside every rounded corner (r >= 10),
// 5pt is outside r=24 but inside r=10, so a swapped / half-turned / mirrored radius set fails.
// The attached group's r=16 corners are probed at 2pt / 7pt instead: 5pt would sit only 0.44pt
// inside that arc, less than a fractional layout origin snapped to the device grid plus the AA
// ramp (seen on a 200% Windows display). The background reference is sampled left of the
// attached group (the panel background).
type Corner = "tl" | "tr" | "br" | "bl";
type CornerExpect = Record<Corner, [boolean, boolean]>; // [clipped at 2pt, clipped at 5pt]
function pixelRgb(png: ReturnType<typeof decodePng>, scale: number, x: number, y: number): [number, number, number] {
  const px = Math.floor(x * scale), py = Math.floor(y * scale);
  const i = (py * png.width + px) * png.channels;
  return [png.pixels[i], png.pixels[i + 1], png.pixels[i + 2]];
}
function rgbDist(a: number[], b: number[]): number {
  return Math.hypot(a[0] - b[0], a[1] - b[1], a[2] - b[2]);
}
/// Scrolls the story area until every listed node lies inside the window: below the title bar /
/// floating toolbar and above the bottom edge, so pixel probes never read outside the capture.
/// The window height is the platform's (about 845pt on a 1440x900 Windows 11 screen, taller on
/// the macOS runners), never a constant.
async function bringIntoView(ids: string[], margin = 8): Promise<void> {
  const top = 60;
  for (let i = 0; i < 30; i++) {
    const vpH = (await tree()).rect.h;
    let minY = Infinity, maxY = -Infinity, x = 0;
    for (const id of ids) {
      const r = (await query(id))[0]?.rect;
      assert(r != null && r.w > 0, `${id} missing`);
      if (r.y < minY) x = r.x + r.w / 2;
      minY = Math.min(minY, r.y);
      maxY = Math.max(maxY, r.y + r.h);
    }
    assert(maxY - minY + 2 * margin <= vpH - top, `nodes span ${(maxY - minY).toFixed(1)}pt; the ${vpH}pt window cannot show them at once`);
    const below = maxY + margin - vpH, above = top + margin - minY;
    if (below <= 0.5 && above <= 0.5) return;
    await scrollAt(x, vpH / 2, 0, below > 0 ? -Math.min(120, below) : Math.min(120, above));
    await sleep(120);
  }
  throw new Error(`could not scroll ${ids.join(", ")} into view`);
}
test("CornerClip: per-corner overflow clip on shader / fold / glass surface / nested layer / turned / mirrored paths", async () => {
  await switchTo("cornerclip");
  await settle(300);
  const path = `${DIR}/story-cornerclip-probe.png`;
  await screenshot(path);
  const png = decodePng(path);
  const scale = decodedCaptureScale(png);
  const tl24_br10: CornerExpect = { tl: [true, true], tr: [false, false], br: [true, false], bl: [false, false] };
  const turned: CornerExpect = { tl: [true, false], tr: [false, false], br: [true, true], bl: [false, false] };
  const mirrored: CornerExpect = { tl: [false, false], tr: [true, true], br: [false, false], bl: [true, false] };
  const groupInsets: [number, number] = [2, 7];
  const cases: Array<[string, CornerExpect, [number, number]?]> = [
    ["story.cornerclip.group.first", { tl: [true, false], tr: [false, false], br: [false, false], bl: [true, false] }, groupInsets],
    ["story.cornerclip.group.middle", { tl: [false, false], tr: [false, false], br: [false, false], bl: [false, false] }, groupInsets],
    ["story.cornerclip.group.last", { tl: [false, false], tr: [true, false], br: [true, false], bl: [false, false] }, groupInsets],
    ["story.cornerclip.shader", tl24_br10],
    ["story.cornerclip.fold", tl24_br10],
    ["story.cornerclip.surface", tl24_br10],
    ["story.cornerclip.nested", tl24_br10],
    ["story.cornerclip.turned", turned],
    ["story.cornerclip.turnedfold", turned],
    ["story.cornerclip.mirrored", mirrored],
  ];
  const failures: string[] = [];
  const groupFirst = (await query("story.cornerclip.group.first"))[0];
  assert(groupFirst != null, "story.cornerclip.group.first missing");
  const outside = pixelRgb(png, scale, groupFirst.rect.x - 6, groupFirst.rect.y + groupFirst.rect.h / 2);
  for (const [id, expect, insets = [2, 5]] of cases) {
    const node = (await query(id))[0];
    assert(node != null && node.rect.w > 0, `${id} missing`);
    const r = node.rect;
    appendLog(`  ${id} rect=(${r.x},${r.y},${r.w},${r.h})`);
    const inside = pixelRgb(png, scale, r.x + r.w / 2, r.y + r.h / 2);
    assert(rgbDist(inside, outside) > 80, `${id}: fill ${inside} vs background ${outside} not distinguishable`);
    const at: Record<Corner, (d: number) => [number, number]> = {
      tl: (d) => [r.x + d, r.y + d],
      tr: (d) => [r.x + r.w - d, r.y + d],
      br: (d) => [r.x + r.w - d, r.y + r.h - d],
      bl: (d) => [r.x + d, r.y + r.h - d],
    };
    for (const corner of ["tl", "tr", "br", "bl"] as Corner[]) {
      insets.forEach((d, k) => {
        const [x, y] = at[corner](d);
        const got = pixelRgb(png, scale, x, y);
        const clipped = expect[corner][k];
        const want = clipped ? outside : inside;
        const other = clipped ? inside : outside;
        const ok = rgbDist(got, want) < 40 && rgbDist(got, other) > 60;
        appendLog(`  ${id} ${corner}@${d}: ${got} expect ${clipped ? "clipped" : "kept"} ${ok ? "ok" : "FAIL"}`);
        if (!ok) failures.push(`${id} ${corner}@${d}pt: got ${got}, want ${clipped ? "background" : "fill"} ${want}`);
      });
    }
  }
  assert(failures.length === 0, `per-corner clip mismatches:\n${failures.join("\n")}`);
  assert((await health()).status === "ok", "app died after cornerclip");
});

// ── Nested shape clips intersect; oversized radii normalise identically on direct / offscreen paths ──
// chain2: uniform r20 parent around a TR10-only child (same 100x40 box). The child's square TL must
// still be cut by the parent's arc at 2pt / 5pt, while the part of that square corner inside the
// parent arc (10pt) survives. chain3 / chain3fold: three nested owners each rounding one different
// corner (TL / TR / BR = 20); every one of the three must cut, BL stays square. Probes at 2pt / 5pt
// fall outside an r=20 arc (cut-off depth 5.86pt), 10pt falls inside it.
// huge / hugefold / hugeblend / hugelayer: TL 9999 must normalise to 20 (half the 40pt side) on
// the shader clip, the opacity-fold composite mask, the blend composite mask and the nested clip
// layer composite mask alike; the TL corner cut-out of each path must match the analytic r=20
// area and the direct path's.
test("CornerClip: nested shape clips intersect and oversized radii normalise on every path", async () => {
  await switchTo("cornerclip");
  await settle(300);
  const chainIds = ["story.cornerclip.chain2", "story.cornerclip.chain3", "story.cornerclip.chain3fold", "story.cornerclip.cross2",
    "story.cornerclip.cross3", "story.cornerclip.huge", "story.cornerclip.hugefold", "story.cornerclip.hugeblend", "story.cornerclip.hugelayer"];
  await bringIntoView(chainIds);
  await settle(300);
  const path = `${DIR}/story-cornerclip-chain.png`;
  await screenshot(path);
  const png = decodePng(path);
  const scale = decodedCaptureScale(png);
  // Background reference: left of chain2, the first specimen of its row (panel background).
  const chainFirst = (await query("story.cornerclip.chain2"))[0];
  assert(chainFirst != null, "story.cornerclip.chain2 missing");
  const outside = pixelRgb(png, scale, chainFirst.rect.x - 6, chainFirst.rect.y + chainFirst.rect.h / 2);
  type Probe = [Corner, number, boolean]; // corner, inset (pt) along the diagonal, clipped?
  const cut = (c: Corner): Probe[] => [[c, 2, true], [c, 5, true], [c, 10, false]];
  const kept = (c: Corner): Probe[] => [[c, 2, false], [c, 5, false]];
  const cases: Array<[string, Probe[]]> = [
    ["story.cornerclip.chain2", [...cut("tl"), ...cut("tr"), ...cut("br"), ...cut("bl")]],
    ["story.cornerclip.chain3", [...cut("tl"), ...cut("tr"), ...cut("br"), ...kept("bl")]],
    ["story.cornerclip.chain3fold", [...cut("tl"), ...cut("tr"), ...cut("br"), ...kept("bl")]],
    // Crossing shapes (probes relative to the innermost owner): r20 parent cuts TL / BL, the
    // child's own TR 12 cuts at 2pt only (reach 3.5pt), BR is square everywhere.
    ["story.cornerclip.cross2", [...cut("tl"), ["tr", 2, true], ["tr", 5, false], ...kept("br"), ...cut("bl")]],
    // Three crossing levels: TL 20 (grandparent), TR 16 of the 84pt middle owner reaching the 80pt
    // child's TR corner (2pt cut, 5pt kept), the child's own BL 12 (2pt cut, 5pt kept).
    ["story.cornerclip.cross3", [...cut("tl"), ["tr", 2, true], ["tr", 5, false], ...kept("br"), ["bl", 2, true], ["bl", 5, false]]],
    ["story.cornerclip.huge", [...cut("tl"), ...kept("tr"), ...kept("br"), ...kept("bl")]],
    ["story.cornerclip.hugefold", [...cut("tl"), ...kept("tr"), ...kept("br"), ...kept("bl")]],
    ["story.cornerclip.hugeblend", [...cut("tl"), ...kept("tr"), ...kept("br"), ...kept("bl")]],
    ["story.cornerclip.hugelayer", [...cut("tl"), ...kept("tr"), ...kept("br"), ...kept("bl")]],
  ];
  const failures: string[] = [];
  const rects: Record<string, { x: number; y: number; w: number; h: number }> = {};
  const fills: Record<string, number[]> = {};
  for (const [id, probes] of cases) {
    const node = (await query(id))[0];
    assert(node != null && node.rect.w > 0, `${id} missing`);
    const r = node.rect;
    rects[id] = r;
    appendLog(`  ${id} rect=(${r.x},${r.y},${r.w},${r.h})`);
    const inside = pixelRgb(png, scale, r.x + r.w / 2, r.y + r.h / 2);
    fills[id] = inside;
    assert(rgbDist(inside, outside) > 80, `${id}: fill ${inside} vs background ${outside} not distinguishable`);
    const at: Record<Corner, (d: number) => [number, number]> = {
      tl: (d) => [r.x + d, r.y + d],
      tr: (d) => [r.x + r.w - d, r.y + d],
      br: (d) => [r.x + r.w - d, r.y + r.h - d],
      bl: (d) => [r.x + d, r.y + r.h - d],
    };
    for (const [corner, d, clipped] of probes) {
      const [x, y] = at[corner](d);
      const got = pixelRgb(png, scale, x, y);
      const want = clipped ? outside : inside;
      const other = clipped ? inside : outside;
      const ok = rgbDist(got, want) < 40 && rgbDist(got, other) > 60;
      appendLog(`  ${id} ${corner}@${d}: ${got} expect ${clipped ? "clipped" : "kept"} ${ok ? "ok" : "FAIL"}`);
      if (!ok) failures.push(`${id} ${corner}@${d}pt: got ${got}, want ${clipped ? "background" : "fill"} ${want}`);
    }
  }
  // TL corner cut-out area, in device px²: sum the fill coverage (0 = background, 1 = fill) over a
  // window that starts in the background above-left of the owner and ends inside its fill; the
  // fill's area there is the window part right/below the owner's (fractional) edge minus the
  // rounded corner's cut-out. Exact up to AA rounding and independent of where the owner falls on
  // the pixel grid, so direct and offscreen paths compare 1:1. r = 20pt: (1 - π/4)·(20·scale)².
  const cutout = (id: string): number => {
    const r = rects[id];
    const fill = fills[id];
    const axis = [fill[0] - outside[0], fill[1] - outside[1], fill[2] - outside[2]];
    const len2 = axis[0] ** 2 + axis[1] ** 2 + axis[2] ** 2;
    const x0 = Math.floor(r.x * scale) - 2, y0 = Math.floor(r.y * scale) - 2;
    const x1 = Math.floor((r.x + 30) * scale), y1 = Math.floor((r.y + 30) * scale);
    let sum = 0;
    for (let py = y0; py < y1; py++) {
      for (let px = x0; px < x1; px++) {
        const k = (py * png.width + px) * png.channels;
        const p = [png.pixels[k] - outside[0], png.pixels[k + 1] - outside[1], png.pixels[k + 2] - outside[2]];
        sum += Math.min(1, Math.max(0, (p[0] * axis[0] + p[1] * axis[1] + p[2] * axis[2]) / len2));
      }
    }
    return (x1 - r.x * scale) * (y1 - r.y * scale) - sum;
  };
  const expected = (1 - Math.PI / 4) * (20 * scale) ** 2;
  const direct = cutout("story.cornerclip.huge");
  appendLog(`  huge TL cut-out ${direct.toFixed(1)}px² (analytic r=20: ${expected.toFixed(1)}px²)`);
  if (Math.abs(direct - expected) > 0.06 * expected) failures.push(`story.cornerclip.huge: TL cut-out ${direct.toFixed(1)}px², want ${expected.toFixed(1)}px² (radius not normalised to 20pt)`);
  for (const id of ["story.cornerclip.hugefold", "story.cornerclip.hugeblend", "story.cornerclip.hugelayer"]) {
    const area = cutout(id);
    appendLog(`  ${id} TL cut-out ${area.toFixed(1)}px² vs direct ${direct.toFixed(1)}px²`);
    if (Math.abs(area - direct) > 0.06 * expected) failures.push(`${id}: TL cut-out ${area.toFixed(1)}px² diverges from the direct clip's ${direct.toFixed(1)}px²`);
  }
  assert(failures.length === 0, `nested / oversized clip mismatches:\n${failures.join("\n")}`);
  assert((await health()).status === "ok", "app died after cornerclip chain");
});

// ── Glass material corners normalise like every clip ──
// The glass shape used to keep its own radius model: a "-1 = uniform" sentinel turned a negative /
// NaN first corner into an all-round glass, and the blur-only glass shader drew only the largest
// corner (TL 9999 -> a full pill). Each specimen is a bright glass (white surface veil) on a dark
// backdrop. Glass-only specimens: the silhouette must cut exactly the corners the radii name.
// "clip" twins add a square red fill under the owner's overflow clip: a cut corner must show the
// backdrop (the glass under it is cut the same way), a kept corner the fill. TL 9999 must cut the
// analytic r=20 area on the glass as on the clip; a 9999 pill must match the exact r=20 pill; 0 / 2
// wide slivers must draw nothing outside their rect and keep the app alive.
test("GlassRadii: glass shape, content clip and oversized / negative radii normalise identically", async () => {
  await switchTo("cornerclip");
  await settle(300);
  await bringIntoView(["story.cornerclip.glassneg", "story.cornerclip.glassnegclip", "story.cornerclip.glasshuge",
    "story.cornerclip.glasshugeclip", "story.cornerclip.glasspillhuge", "story.cornerclip.glasspillexact"], 12);
  await settle(400);
  const path = `${DIR}/story-cornerclip-glass.png`;
  await screenshot(path);
  const png = decodePng(path);
  const scale = decodedCaptureScale(png);
  const rectOf = async (id: string) => {
    const node = (await query(id))[0];
    assert(node != null && node.rect.w >= 0, `${id} missing`);
    return node.rect;
  };
  const neg = await rectOf("story.cornerclip.glassneg");
  const backdrop = pixelRgb(png, scale, neg.x - 5, neg.y + neg.h / 2);
  const glass = pixelRgb(png, scale, neg.x + neg.w / 2, neg.y + neg.h / 2);
  appendLog(`  backdrop=${backdrop} glass=${glass}`);
  assert(rgbDist(glass, backdrop) > 120, `glass ${glass} vs backdrop ${backdrop} not distinguishable`);
  type Probe = [Corner, number, boolean]; // corner, inset (pt) along the diagonal, cut?
  const cut = (c: Corner): Probe[] => [[c, 2, true], [c, 5, true], [c, 10, false]];
  const kept = (c: Corner): Probe[] => [[c, 2, false], [c, 5, false]];
  const negProbes = [...kept("tl"), ...cut("tr"), ...kept("br"), ...kept("bl")];
  const hugeProbes = [...cut("tl"), ...kept("tr"), ...kept("br"), ...kept("bl")];
  const pillProbes = [...cut("tl"), ...cut("tr"), ...cut("br"), ...cut("bl")];
  const cases: Array<[string, Probe[], boolean]> = [
    ["story.cornerclip.glassneg", negProbes, false],
    ["story.cornerclip.glassnegclip", negProbes, true],
    ["story.cornerclip.glasshuge", hugeProbes, false],
    ["story.cornerclip.glasshugeclip", hugeProbes, true],
    ["story.cornerclip.glasspillhuge", pillProbes, false],
    ["story.cornerclip.glasspillexact", pillProbes, false],
  ];
  const failures: string[] = [];
  const rects: Record<string, { x: number; y: number; w: number; h: number }> = {};
  for (const [id, probes, filled] of cases) {
    const r = await rectOf(id);
    rects[id] = r;
    const inside = pixelRgb(png, scale, r.x + r.w / 2, r.y + r.h / 2);
    appendLog(`  ${id} rect=(${r.x},${r.y},${r.w},${r.h}) inside=${inside}`);
    if (rgbDist(inside, backdrop) < 120) failures.push(`${id}: inside ${inside} indistinguishable from backdrop ${backdrop}`);
    const at: Record<Corner, (d: number) => [number, number]> = {
      tl: (d) => [r.x + d, r.y + d],
      tr: (d) => [r.x + r.w - d, r.y + d],
      br: (d) => [r.x + r.w - d, r.y + r.h - d],
      bl: (d) => [r.x + d, r.y + r.h - d],
    };
    for (const [corner, d, isCut] of probes) {
      const [x, y] = at[corner](d);
      const got = pixelRgb(png, scale, x, y);
      const want = isCut ? backdrop : inside;
      const other = isCut ? inside : backdrop;
      const ok = rgbDist(got, want) < 60 && rgbDist(got, other) > 60;
      appendLog(`  ${id} ${corner}@${d}: ${got} expect ${isCut ? "cut" : "kept"} ${ok ? "ok" : "FAIL"}`);
      if (!ok) failures.push(`${id} ${corner}@${d}pt: got ${got}, want ${isCut ? "backdrop" : filled ? "fill" : "glass"} ${want}`);
    }
  }
  // TL cut-out area in device px² (see the oversized clip test above): glass and clip cut r = 20.
  const cutout = (id: string, inside: number[]): number => {
    const r = rects[id];
    const axis = [inside[0] - backdrop[0], inside[1] - backdrop[1], inside[2] - backdrop[2]];
    const len2 = axis[0] ** 2 + axis[1] ** 2 + axis[2] ** 2;
    const x0 = Math.floor(r.x * scale) - 2, y0 = Math.floor(r.y * scale) - 2;
    const x1 = Math.floor((r.x + 30) * scale), y1 = Math.floor((r.y + 30) * scale);
    let sum = 0;
    for (let py = y0; py < y1; py++) {
      for (let px = x0; px < x1; px++) {
        const k = (py * png.width + px) * png.channels;
        const p = [png.pixels[k] - backdrop[0], png.pixels[k + 1] - backdrop[1], png.pixels[k + 2] - backdrop[2]];
        sum += Math.min(1, Math.max(0, (p[0] * axis[0] + p[1] * axis[1] + p[2] * axis[2]) / len2));
      }
    }
    return (x1 - r.x * scale) * (y1 - r.y * scale) - sum;
  };
  const expected = (1 - Math.PI / 4) * (20 * scale) ** 2;
  for (const id of ["story.cornerclip.glasshuge", "story.cornerclip.glasshugeclip"]) {
    const r = rects[id];
    const area = cutout(id, pixelRgb(png, scale, r.x + r.w / 2, r.y + r.h / 2));
    appendLog(`  ${id} TL cut-out ${area.toFixed(1)}px² (analytic r=20: ${expected.toFixed(1)}px²)`);
    if (Math.abs(area - expected) > 0.1 * expected) failures.push(`${id}: TL cut-out ${area.toFixed(1)}px², want ${expected.toFixed(1)}px²`);
  }
  // Pill 9999 == pill 20: same silhouette, pixel for pixel up to grid phase.
  {
    const a = rects["story.cornerclip.glasspillhuge"], b = rects["story.cornerclip.glasspillexact"];
    let sum = 0, n = 0, worst = 0;
    for (let y = 0; y < a.h; y += 0.5) {
      for (let x = 0; x < a.w; x += 0.5) {
        const pa = pixelRgb(png, scale, a.x + x, a.y + y), pb = pixelRgb(png, scale, b.x + x, b.y + y);
        const dd = rgbDist(pa, pb);
        sum += dd; n++; worst = Math.max(worst, dd);
      }
    }
    appendLog(`  pill 9999 vs pill 20: mean ${(sum / n).toFixed(2)} max ${worst.toFixed(1)}`);
    if (sum / n > 3) failures.push(`pill 9999 differs from pill 20: mean ${(sum / n).toFixed(2)}`);
  }
  // Slivers: nothing outside their rect (probe the backdrop 6pt to either side).
  for (const id of ["story.cornerclip.glasssliver0", "story.cornerclip.glasssliver2"]) {
    const r = await rectOf(id);
    for (const dx of [-6, r.w + 6]) {
      const got = pixelRgb(png, scale, r.x + dx, r.y + r.h / 2);
      appendLog(`  ${id} @${dx}: ${got}`);
      if (rgbDist(got, backdrop) > 30) failures.push(`${id}: glass leaked to x${dx >= 0 ? "+" : ""}${dx}pt (${got})`);
    }
  }
  assert(failures.length === 0, `glass corner mismatches:\n${failures.join("\n")}`);
  assert((await health()).status === "ok", "app died after cornerclip glass");
});

test("GlassIslands: 同帧两个 blur+rounded_clip 岛都必须显示内容", async () => {
  // regression (downstream): blur + overflow_hidden + corner_radius same node, rounded_clip surface
  // expects owner-local content frame; lowering only projected opacity layer -> content world
  // coords, texture lost -> shell only.
  await switchTo("glassislands");
  await settle(500); // wait glass composite stable
  const png = `${DIR}/story-glassislands.png`;
  await shot("glassislands");
  for (const name of ["first", "second"]) {
    const slab = (await query(`story.glassislands.${name}.slab`))[0]?.rect;
    assert(slab, `${name} 岛的深色内容块节点应存在`);
    const inner = { x: slab.x + 10, y: slab.y + 10, w: slab.w - 20, h: slab.h - 20 };
    // content block is near-black (24,28,40): lost shows white glass base, dark~0
    assertRegionHasInk(png, inner, `${name} 岛内容块像素`, 5000);
  }
  // gi=0 "blur-only" contract: first island left edge 8px band pressed on near-black
  // vertical bar (story rim_probe); rim_sharp if gi gate missed, black bar shows sharp at
  // edge -> darkest near pure black. Normal blur-only black bar + bright gradient blur to
  // mid-gray.
  const first = (await query("story.glassislands.first"))[0]?.rect;
  assert(first, "first 岛 rect 应存在");
  // differential assert: absolute threshold shifts with theme/bg (alpha 96 era
  // sharp/blur differ only 30 gray, cannot catch variance). Reference band from island
  // inset 11..15px, also on black bar but past rim_sharp 8px band, forever blur.
  // rim band visibly darker than reference = sharp leaked.
  const rimBand = { x: first.x + 1, y: first.y + 40, w: 5, h: first.h - 80 };
  const refBand = { x: first.x + 11, y: first.y + 40, w: 4, h: first.h - 80 };
  const [rr, rg, rb] = darkestPixel(png, rimBand);
  const [fr, fg, fb] = darkestPixel(png, refBand);
  const rimSum = rr + rg + rb, refSum = fr + fg + fb;
  appendLog(`  rim-band darkest=(${rr},${rg},${rb}) ref-band darkest=(${fr},${fg},${fb})`);
  assert(rimSum > refSum - 90, `gi=0 岛边缘出现 sharp 回退带: rim=${rimSum} ref=${refSum}`);
  assert((await health()).status === "ok", "app died after glassislands");
});

/// per-pixel diff of two same-size regions (mean/p99/max of RGB absolute diff).
function regionDiff(pngPath: string, a: { x: number; y: number; w: number; h: number }, b: { x: number; y: number; w: number; h: number }): { mean: number; p99: number; max: number; n: number } {
  const png = decodePng(pngPath);
  const scale = decodedCaptureScale(png);
  const w = Math.round(a.w * scale), h = Math.round(a.h * scale);
  const ax = Math.round(a.x * scale), ay = Math.round(a.y * scale);
  const bx = Math.round(b.x * scale), by = Math.round(b.y * scale);
  const diffs: number[] = [];
  let sum = 0;
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      const ia = ((ay + y) * png.width + (ax + x)) * png.channels;
      const ib = ((by + y) * png.width + (bx + x)) * png.channels;
      const d = Math.max(Math.abs(png.pixels[ia] - png.pixels[ib]), Math.abs(png.pixels[ia + 1] - png.pixels[ib + 1]), Math.abs(png.pixels[ia + 2] - png.pixels[ib + 2]));
      diffs.push(d);
      sum += d;
    }
  }
  diffs.sort((p, q) => p - q);
  return { mean: sum / Math.max(diffs.length, 1), p99: diffs[Math.floor(diffs.length * 0.99)] ?? 0, max: diffs[diffs.length - 1] ?? 0, n: diffs.length };
}

test("GlassGroup: 容器一次采样合成与单体 GlassBox 逐像素等价（M2）", async () => {
  await switchTo("glassgroup");
  await settle(600); // wait for glass composite + brightness readback stable
  const png = `${DIR}/story-glassgroup.png`;
  await shot("glassgroup");
  const single = (await query("story.glassgroup.single"))[0]?.rect;
  const group = (await query("story.glassgroup.group"))[0]?.rect;
  assert(single && group, "两行容器 rect 应存在");
  assert(Math.abs(single!.w - group!.w) < 0.5 && Math.abs(single!.h - group!.h) < 0.5, `两行尺寸应一致: ${JSON.stringify(single)} vs ${JSON.stringify(group)}`);
  assert(Math.abs(single!.x - group!.x) < 0.5, `两行 x 应对齐: ${single!.x} vs ${group!.x}`);
  // rim + shadow spread 24px; both background boards identical, variance from
  // glass path alone.
  const pad = 24;
  const a = { x: single!.x - pad, y: single!.y - pad, w: single!.w + 2 * pad, h: single!.h + 2 * pad };
  const b = { x: group!.x - pad, y: group!.y - pad, w: group!.w + 2 * pad, h: group!.h + 2 * pad };
  const d = regionDiff(png, a, b);
  appendLog(`  glassgroup single-vs-group: mean=${d.mean.toFixed(3)} p99=${d.p99} max=${d.max} n=${d.n} dy=${(group!.y - single!.y).toFixed(1)}`);
  // container members via same capture composite; member move/material diff pushes mean-diff to
  // double digits.
  assert(d.mean < 1.0, `GlassGroup 与单体 GlassBox 像素不等价: mean=${d.mean.toFixed(3)} p99=${d.p99} max=${d.max}`);
  assert(d.p99 <= 16, `GlassGroup 与单体 GlassBox 局部差异过大: p99=${d.p99} max=${d.max}`);
  assert((await health()).status === "ok", "app died after glassgroup");
});

/// neck height between capsules, 2x physical px (native probe measure; Windows VM etc non-2x scale
/// by area): count pixels in band brighter than gray+40, min between inner edges.
function neckHeight(pngPath: string, rect: { x: number; y: number; w: number; h: number }, capsuleW: number, gap: number): number {
  const png = decodePng(pngPath);
  const scale = decodedCaptureScale(png);
  const y0 = Math.max(0, Math.round((rect.y - 8) * scale)), y1 = Math.min(png.height, Math.round((rect.y + rect.h + 8) * scale));
  const x0 = Math.round((rect.x + capsuleW - 2) * scale), x1 = Math.round((rect.x + capsuleW + gap + 2) * scale);
  let neck = Infinity;
  for (let x = x0; x <= x1; x++) {
    let n = 0;
    for (let y = y0; y < y1; y++) {
      const i = (y * png.width + x) * png.channels;
      const l = png.pixels[i] * 0.2126 + png.pixels[i + 1] * 0.7152 + png.pixels[i + 2] * 0.0722;
      if (l > 128 + 40) n++;
    }
    if (n < neck) neck = n;
  }
  return neck === Infinity ? 0 : Math.round(neck * 2 / scale);
}

test("GlassMerge: GlassGroup 融合颈部与原生 GlassEffectContainer 实测一致（M3）", async () => {
  await switchTo("glassmerge");
  await settle(600);
  const png = `${DIR}/story-glassmerge.png`;
  await shot("glassmerge");
  // native measured (physical px, 2x): native_container_merge.swift, gray 128, 120x44 capsule
  const native: Array<[number, number, number]> = [[40, 16, 36], [40, 8, 58], [40, 0, 70], [80, 36, 36], [80, 20, 74], [80, 0, 92], [20, 8, 26], [20, 0, 54]];
  const failures: string[] = [];
  for (const [s, g, expected] of native) {
    const rect = (await query(`story.glassmerge.s${s}.g${g}`))[0]?.rect;
    assert(rect, `GlassMerge 行 s${s} g${g} 应存在`);
    const neck = neckHeight(png, rect!, 120, g);
    appendLog(`  glassmerge s=${s} gap=${g}: neck=${neck}px native=${expected}px`);
    // circular smin model saddle residual: <=3px for normal settings; at the setting where the
    // bridge has just appeared (S=80 gap36) the model itself is ~10px low (see docs).
    const tol = (s === 80 && g === 36) ? 14 : 8;
    if (Math.abs(neck - expected) > tol) failures.push(`s${s} g${g}: zenit ${neck} vs native ${expected} (tol ${tol})`);
  }
  assert(failures.length === 0, `融合颈部偏离原生: ${failures.join("; ")}`);
  assert((await health()).status === "ok", "app died after glassmerge");
});

function regionMeanDiff(pngA: string, pngB: string, rect: { x: number; y: number; w: number; h: number }): number {
  const a = decodePng(pngA), b = decodePng(pngB);
  const scale = decodedCaptureScale(a);
  const x0 = Math.round(rect.x * scale), y0 = Math.round(rect.y * scale), x1 = Math.round((rect.x + rect.w) * scale), y1 = Math.round((rect.y + rect.h) * scale);
  assert(a.width === b.width && a.height === b.height && a.channels === b.channels,
    `pixel comparison requires matching captures: ${a.width}×${a.height} vs ${b.width}×${b.height}`);
  assert(Math.abs(scale - decodedCaptureScale(b)) < 1e-6, "pixel comparison logical scale changed between captures");
  assert(x0 >= 0 && y0 >= 0 && x1 <= a.width && y1 <= a.height && x1 > x0 && y1 > y0,
    `pixel comparison region outside capture: [${x0},${y0},${x1},${y1}] in ${a.width}×${a.height}`);
  let sum = 0, n = 0;
  for (let y = y0; y < y1; y++) for (let x = x0; x < x1; x++) {
    const i = (y * a.width + x) * a.channels;
    sum += Math.abs(a.pixels[i] - b.pixels[i]) + Math.abs(a.pixels[i + 1] - b.pixels[i + 1]) + Math.abs(a.pixels[i + 2] - b.pixels[i + 2]);
    n += 3;
  }
  return sum / Math.max(n, 1);
}

test("GlassMaterialize: glassSetEnabled 按 materialize 曲线消散/成形（M4）", async () => {
  await switchTo("glassmotion");
  await settle(500);
  // Freeze the sampled phase while readback runs. Free stepping can spend
  // most of the transition in click/stats/screenshot RPCs on Windows.
  await useAnimationClock(true);
  const box = (await query("story.glassmotion.materialize"))[0]?.rect;
  assert(box, "materialize 玻璃节点应存在");
  const inner = { x: box!.x + 24, y: box!.y + 6, w: box!.w - 48, h: box!.h - 12 };
  await shot("glassmaterialize-on");
  await clickTestId("story.glassmotion.toggle");
  await animSleep(700); // dissolve 270ms + margin
  await shot("glassmaterialize-off");
  const full = regionMeanDiff(`${DIR}/story-glassmaterialize-on.png`, `${DIR}/story-glassmaterialize-off.png`, inner);
  appendLog(`  materialize: on-vs-off mean diff=${full.toFixed(1)}`);
  assert(full > 20, `玻璃消散后区域应回到背景（on/off 差 ${full.toFixed(1)} 过小）`);
  // Sample the middle of the 420ms appearance, rather than an RPC-dependent
  // "ASAP" image. Keep the original pixel thresholds against both endpoints.
  await clickTestId("story.glassmotion.toggle");
  await animSleep(210);
  const beforeCapture = (await stats() as any).frame_time_ms;
  await shot("glassmaterialize-mid");
  const afterCapture = (await stats() as any).frame_time_ms;
  appendLog(`  materialize frozen midpoint: time=${beforeCapture} capture-advance=${afterCapture-beforeCapture}ms`);
  assert(Math.abs(afterCapture-beforeCapture)<0.1, "materialize screenshot advanced the locked animation clock");
  await animSleep(800);
  await shot("glassmaterialize-back");
  const mid_from_off = regionMeanDiff(`${DIR}/story-glassmaterialize-mid.png`, `${DIR}/story-glassmaterialize-off.png`, inner);
  const mid_from_on = regionMeanDiff(`${DIR}/story-glassmaterialize-mid.png`, `${DIR}/story-glassmaterialize-back.png`, inner);
  const back = regionMeanDiff(`${DIR}/story-glassmaterialize-on.png`, `${DIR}/story-glassmaterialize-back.png`, inner);
  appendLog(`  materialize: mid-vs-off=${mid_from_off.toFixed(1)} mid-vs-on=${mid_from_on.toFixed(1)} back-vs-on=${back.toFixed(1)}`);
  assert(mid_from_off > 0.1 * full && mid_from_on > 0.1 * full, `中途帧应处于部分成形: mid-off=${mid_from_off.toFixed(1)} mid-on=${mid_from_on.toFixed(1)} full=${full.toFixed(1)}`);
  assert(back < 4, `成形完成后应回到初始材质（差 ${back.toFixed(1)}）`);
  assert((await health()).status === "ok", "app died after glassmotion materialize");
});

/// center line luminance (0..255), determines glass (frosted ~230) vs background (~130).
function lumaAt(pngPath: string, x: number, y: number): number {
  const png = decodePng(pngPath); const s = decodedCaptureScale(png);
  const px = Math.round(x * s), py = Math.round(y * s); let sum = 0, n = 0;
  for (let dy = -2; dy <= 2; dy++) for (let dx = -2; dx <= 2; dx++) { const i = ((py + dy) * png.width + (px + dx)) * png.channels; sum += 0.2126 * png.pixels[i] + 0.7152 * png.pixels[i + 1] + 0.0722 * png.pixels[i + 2]; n++; }
  return sum / n;
}

test("GlassSplit: 官方 glassEffectID 展开/收起——合并态单一形状无凸起、过渡期液态桥接、静止不吸附、收起汇集复原（视觉验收）", async () => {
  await switchTo("glasssplit");
  await settle(600);
  await useAnimationClock(true);
  const rects = async () => Promise.all([0, 1, 2].map(async (i) => (await query(`story.glasssplit.bar${i}`))[0]?.rect));
  let [b0, b1, b2] = await rects();
  assert(b0 && b1 && b2, "三个 bar 应存在");
  // native glassEffectUnion: merged is 450x44 shape, others hidden
  assert(Math.abs(b0!.w - 450) < 2, `合并态首成员应是 union（w=${b0!.w.toFixed(1)}）`);
  const cy = b0!.y + b0!.h / 2;
  // old junction (x=150/300) top/bottom must be flat: outer 3px background (no bulge), inner 3px
  // glass (no dent)
  const flatAt = (png: string, tag: string) => {
    for (const jx of [150, 300]) {
      const x = b0!.x + jx;
      const out = Math.max(lumaAt(png, x, b0!.y - 3), lumaAt(png, x, b0!.y + b0!.h + 3));
      const inn = Math.min(lumaAt(png, x, b0!.y + 3), lumaAt(png, x, b0!.y + b0!.h - 3));
      appendLog(`  ${tag} joint ${jx}: outside luma=${out.toFixed(0)} inside luma=${inn.toFixed(0)}`);
      assert(out < 170, `${tag}: 连接处 ${jx} 不应外凸（luma=${out.toFixed(0)}）`);
      assert(inn > 195, `${tag}: 连接处 ${jx} 不应内凹（luma=${inn.toFixed(0)}）`);
    }
  };
  await shot("glasssplit-merged");
  flatAt(`${DIR}/story-glasssplit-merged.png`, "merged");
  // Slow the product transition to 8000ms, then sample every 200ms of
  // animation time. Lock each phase across geometry queries and screenshot
  // readback; retries stagger the sampling phase if the narrow near-gap
  // interval lands between samples. Keep all original pixel/coverage rules.
  let bridgeSeen = false, inWindow = 0, noBridge = 0, near = 0, nearBroken = 0;
  for (let attempt = 0; attempt < 4 && near === 0; attempt++) {
    if (attempt > 0) {
      await clickTestId("story.glasssplit.splitbtn"); // original speed return
      await animSleep(1200);
    }
    await clickTestId("story.glasssplit.slowbtn"); // start slow play
    await clickTestId("story.glasssplit.splitbtn");
    if (attempt > 0) await animSleep(150 * attempt); // stagger screenshot phase
    const tSplit = await animNow();
    for (let i = 1; i <= 80 && (await animNow()) - tSplit < 11000; i++) {
      // Advance between samples; geometry queries and readback must observe
      // the same frozen phase, rather than skipping the bridge window.
      await animSleep(200);
      // query layout before+after screenshot; gap in bridge window both times counts
      const [p0, p1] = await rects();
      const gapBefore = p1!.x - (p0!.x + p0!.w);
      const name = `glasssplit-split-a${attempt}-t${i}`;
      await shot(name);
      const [r0, r1] = await rects();
      const gap = r1!.x - (r0!.x + r0!.w);
      const mid = lumaAt(`${DIR}/story-${name}.png`, r0!.x + r0!.w + Math.max(gap, 0) / 2, cy);
      appendLog(`  split attempt ${attempt} frame ${i} (+${(await animNow()) - tSplit}ms): gap=${gapBefore.toFixed(1)}→${gap.toFixed(1)} mid luma=${mid.toFixed(0)}`);
      if (gapBefore > 2 && gap < 22) { inWindow++; if (mid > 195) bridgeSeen = true; else noBridge++; }
      // nearly stuck (pre-screenshot gap >= 0, post <= 9) members must connect. Real measured: neck
      // in rect gap ~10 in, 11+ breaks
      if (gapBefore >= 0 && gap <= 9) { near++; if (mid <= 195) nearBroken++; }
      if (gap >= 23.5) break;
    }
    await animSleep(9000); // wait slow finish
    await clickTestId("story.glasssplit.slowbtn"); // end slow play
  }
  appendLog(`  frames in bridge window: ${inWindow} (no bridge: ${noBridge}); gap 0–9: ${near} (broken: ${nearBroken})`);
  await shot("glasssplit-split-settled");
  [b0, b1, b2] = await rects();
  const gap = b1!.x - (b0!.x + b0!.w);
  const midSettled = lumaAt(`${DIR}/story-glasssplit-split-settled.png`, b0!.x + b0!.w + gap / 2, cy);
  const tipOut = Math.max(lumaAt(`${DIR}/story-glasssplit-split-settled.png`, b0!.x + b0!.w + 2, cy), lumaAt(`${DIR}/story-glasssplit-split-settled.png`, b1!.x - 2, cy));
  appendLog(`  settled: gap=${gap.toFixed(1)} mid luma=${midSettled.toFixed(0)} tip±2 luma=${tipOut.toFixed(0)} bridgeSeen=${bridgeSeen}`);
  assert(Math.abs(gap - 24) < 2, `分离后间距应为 24（${gap.toFixed(1)}）`);
  assert(Math.abs(b2!.x - b1!.x - 174) < 2, `分离后 bar2 应在 bar1 右侧 174（${(b2!.x - b1!.x).toFixed(1)}）`);
  assert(midSettled < 195, `静止后 bar 之间不应有液态桥（luma=${midSettled.toFixed(0)}）`);
  // product rules (.transitions): stick only during, static after, no point left
  assert(tipOut < 170, `静止后 bar 端部外 2px 应是背景（无吸附尖头，luma=${tipOut.toFixed(0)}）`);
  assert(inWindow >= 3, `慢放下应至少抓到 3 帧 gap 2–22 的过渡帧（实际 ${inWindow}），否则判据失效`);
  assert(bridgeSeen, "落在桥窗口（gap 2–22）内的过渡帧应出现液态桥");
  assert(near >= 1 && nearBroken === 0, `间隙 0–9 的过渡帧都应有液态桥（${near} 帧，其中断开 ${nearBroken}）`);
  await clickTestId("story.glasssplit.splitbtn");
  await animSleep(150); await shot("glasssplit-merge-t1");
  await animSleep(1000); await shot("glasssplit-remerged");
  [b0, b1, b2] = await rects();
  assert(Math.abs(b0!.w - 450) < 2, `合并复原后首成员应长回 union（w=${b0!.w.toFixed(1)}）`);
  flatAt(`${DIR}/story-glasssplit-remerged.png`, "remerged");
  // card
  const cards = async () => Promise.all([0, 1, 2].map(async (i) => (await query(`story.glasssplit.card${i}`))[0]?.rect));
  await shot("glasssplit-card-merged");
  await clickTestId("story.glasssplit.cardbtn");
  await animSleep(90); await shot("glasssplit-card-t1");
  await animSleep(120); await shot("glasssplit-card-t2");
  await animSleep(900); await shot("glasssplit-card-expanded");
  const [c0, c1, c2] = await cards();
  appendLog(`  card expanded: ${JSON.stringify([c0, c1, c2])}`);
  assert(c0 && c1 && Math.abs(c1!.x - c0!.x - 330) < 2 && Math.abs(c0!.w - 150) < 1, "card 应收缩成三个 floating bar");
  await clickTestId("story.glasssplit.cardbtn"); await animSleep(1000); await shot("glasssplit-card-remerged");
  const [m0] = await cards();
  assert(m0 && Math.abs(m0.w - 300) < 2 && Math.abs(m0.h - 146) < 2, `card 合并复原应是 300×146 的单一形状（${m0?.w}×${m0?.h}）`);
  assert((await health()).status === "ok", "app died after glasssplit");
});

test("GlassSplit: card 展开中途再点即折返（不再忽略动画中的点击），收起淡出途中再展开原地反向", async () => {
  await switchTo("glasssplit");
  await settle(600);
  // The 120ms reversal must arrive before fade-out completes even when
  // screenshot/readback or RPC latency varies under the full suite's load.
  await useAnimationClock(true);
  const card = async (i: number) => (await query(`story.glasssplit.card${i}`))[0]?.rect;
  const c0 = (await card(0))!;
  assert(Math.abs(c0.w - 300) < 2, `card 初始应收起为 300 宽（${c0.w}）`);
  // expand 150ms then click: first bar must fold back (width rise to 300), not continue expand to
  // 150
  await clickTestId("story.glasssplit.cardbtn");
  await animSleep(150);
  const mid = (await card(0))!.w;
  await clickTestId("story.glasssplit.cardbtn");
  await animSleep(1200);
  const back = (await card(0))!.w;
  appendLog(`  card reverse: w mid ${mid.toFixed(1)} -> settled ${back.toFixed(1)}`);
  assert(mid < 295, `150 ms 时应已在收窄（${mid.toFixed(1)}）`);
  assert(Math.abs(back - 300) < 2, `中途再点应折返到 300 宽（${back.toFixed(1)}）`);
  // expand fully, retract 120ms (far two bars fading) then expand: bar in-place return, no geometry
  // jump
  await clickTestId("story.glasssplit.cardbtn");
  await animSleep(1200);
  const b1 = (await card(1))!;
  await clickTestId("story.glasssplit.cardbtn");
  await animSleep(120);
  await clickTestId("story.glasssplit.cardbtn");
  let drift = 0;
  for (let k = 0; k < 8; k++) {
    await animSleep(100);
    const r = (await card(1))!;
    drift = Math.max(drift, Math.abs(r.x - b1.x), Math.abs(r.y - b1.y), Math.abs(r.w - b1.w), Math.abs(r.h - b1.h));
  }
  appendLog(`  fade-out reverse: card1 max drift ${drift.toFixed(1)}`);
  assert(drift < 1, `淡出途中再展开，远处 bar 应原地回来（最大偏移 ${drift.toFixed(1)}）`);
  await clickTestId("story.glasssplit.cardbtn");
  await animSleep(1200);
  assert(Math.abs((await card(0))!.w - 300) < 2, "收起后应复原");
  assert((await health()).status === "ok", "app died after card reversal");
});

test("GlassSplit: 连点多次后慢放展开，子 bar 从当前几何长出、不突然变大", async () => {
  // regression (user real): rapid-click Split several times (no wait animation end) -> Slow ×16 ->
  // click Split again, sub bar ~72pt high. Root: resorbed member size->~0, reverse start at
  // 'unlayouted' 220x140.
  await switchTo("glasssplit");
  await settle(600);
  await useAnimationClock(true);
  for (let i = 0; i < 5; i++) { await clickTestId("story.glasssplit.splitbtn"); await animSleep(70 + 25 * (i % 3)); }
  // 6th retract: wait sub bar resorbed (size<1, resorb unfinished) then slow expand -> window only
  // frames
  await clickTestId("story.glasssplit.slowbtn");
  await clickTestId("story.glasssplit.splitbtn");
  let tiny = false;
  const tEnd = (await animNow()) + 10000;
  while (!tiny && (await animNow()) < tEnd) {
    const r = (await query("story.glasssplit.bar1"))[0]?.rect;
    tiny = !!r && r.h < 1;
    if (!tiny) await animSleep(20);
  }
  appendLog(`  reached end-cap absorption: ${tiny}`);
  assert(tiny, "慢放收起应把子 bar 吸到端帽（h<1）");
  await clickTestId("story.glasssplit.splitbtn");
  let maxH = 0, maxW = 0;
  for (let k = 0; k < 10; k++) {
    await animSleep(250);
    for (const i of [1, 2]) {
      const r = (await query(`story.glasssplit.bar${i}`))[0]?.rect;
      if (r) { maxH = Math.max(maxH, r.h); maxW = Math.max(maxW, r.w); }
    }
    if (k === 3) assert((await screenshot(`${DIR}/glasssplit-rapid-slow.png`)).ok === true, "screenshot failed");
  }
  appendLog(`  rapid toggles + slow split: sub-bar max ${maxW.toFixed(1)}×${maxH.toFixed(1)}`);
  assert(maxH <= 44.5, `子 bar 高度不应超过 44（实测最大 ${maxH.toFixed(1)}）`);
  assert(maxW <= 150.5, `子 bar 宽度不应超过 150（实测最大 ${maxW.toFixed(1)}）`);
  // restore: end slow, retract, merged
  await clickTestId("story.glasssplit.slowbtn");
  await clickTestId("story.glasssplit.splitbtn");
  await animSleep(1500);
  const b0 = (await query("story.glasssplit.bar0"))[0]?.rect;
  assert(b0 && Math.abs(b0.w - 450) < 2, `收起后应复原为 450 宽（w=${b0?.w}）`);
  assert((await health()).status === "ok", "app died after rapid glasssplit toggles");
});

test("GlassTintMerge: 容器融合桥无 tint、tint 只铺成员内部、不同 tint 重叠逐层压暗（原生对照锚点）", async () => {
  await switchTo("glasstint");
  await settle(600);
  const white = (await query("story.glasstint.white"))[0]?.rect;
  assert(white, "white stage should exist");
  // white stage fully in viewport, then screenshot
  await shot("glasstint");
  const img = decodePng(`${DIR}/story-glasstint.png`);
  const scale = decodedCaptureScale(img);
  const at = (x: number, y: number) => meanRgbOf(img, { x: white!.x + x - 1, y: white!.y + y - 1, w: 2, h: 2 }, scale).map((v) => Math.round(v));
  // case 3 (blue|orange, gap 12) bridge: native 249 white, colorless
  const bridge = at(475 + 1, 144);
  // case 2 (blue|orange, touching) overlap center: native (215,103,15)
  const junction = at(165, 144);
  // case 4 (none|blue, overlap 30) overlap center: blue not covered by tint-none glass
  const overNone = at(165, 240);
  appendLog(`  bridge ${JSON.stringify(bridge)} junction ${JSON.stringify(junction)} plain-over-blue ${JSON.stringify(overNone)}`);
  const chroma = (c: number[]) => Math.max(...c) - Math.min(...c);
  assert(bridge[0] > 235 && chroma(bridge) < 12, `融合桥应是无 tint 的白玻璃（${bridge}）`);
  assert(junction[0] > 190 && junction[0] < 235 && junction[1] > 80 && junction[1] < 125 && junction[2] < 45, `蓝橙相接处应是压暗的橙棕（${junction}）`);
  assert(overNone[2] > 230 && overNone[0] < 40, `无 tint 玻璃不应盖住蓝色 tint（${overNone}）`);
  assert((await health()).status === "ok", "app died after glasstint");
});

test("GlassUnion: glassEffectUnion 同 id 成员合成整体包围盒形状（原生 native_union.swift 尺寸）", async () => {
  await switchTo("glassunion");
  await settle(600);
  const st = (await query("story.glassunion.stage"))[0]?.rect;
  assert(st, "union stage missing");
  await shot("glassunion");
  const img = decodePng(`${DIR}/story-glassunion.png`);
  const scale = decodedCaptureScale(img);
  const runsAt = (cy: number) => {
    const y = Math.round((st!.y + cy) * scale); const runs: number[] = []; let start = -1;
    for (let x = Math.round(st!.x * scale); x < Math.round((st!.x + 640) * scale); x++) {
      const i = (y * img.width + x) * img.channels; const on = Math.abs(img.pixels[i] - 128) > 40;
      if (on && start < 0) start = x; if (!on && start >= 0) { runs.push((x - start) / scale); start = -1; }
    }
    return runs;
  };
  const expected: Array<[number, number[]]> = [[60, [180, 180]], [150, [380]], [230, [196]], [320, [220]], [420, [294]]];
  for (const [cy, widths] of expected) {
    const got = runsAt(cy);
    appendLog(`  union row y=${cy}: ${JSON.stringify(got)} native ${JSON.stringify(widths)}`);
    assert(got.length === widths.length && got.every((w, k) => Math.abs(w - widths[k]) <= 2), `union row ${cy}: ${JSON.stringify(got)} vs native ${JSON.stringify(widths)}`);
  }
});

test("GlassPopover: 玻璃按钮弹出带箭头的玻璃弹出层——原生 .popover 外形、无投影、Escape 收起（native_menu_morph.swift）", async () => {
  await switchTo("glasspopover");
  await settle(600);
  const st = (await query("story.glasspopover.stage"))[0]?.rect;
  assert(st, "popover stage missing");
  await clickTestId("story.glasspopover.button");
  await mouseMove(-10, -10);
  await sleep(800);
  await shot("glasspopover-open");
  const img = decodePng(`${DIR}/story-glasspopover-open.png`);
  const scale = decodedCaptureScale(img);
  const px = (x: number, y: number) => img.pixels[(Math.round((st!.y + y) * scale) * img.width + Math.round((st!.x + x) * scale)) * img.channels];
  // each line glass coverage width (logical pt; cumulative coverage % from 128->230, antialiasing)
  const coverage = (img2: typeof img, y: number) => {
    const row = Math.round((st!.y + y) * scale); let sum = 0;
    for (let x = Math.round((st!.x + 40) * scale); x < Math.round((st!.x + 280) * scale); x++) {
      const v = img2.pixels[(row * img2.width + x) * img2.channels];
      sum += Math.max(0, Math.min(1.2, (v - 128) / 102));
    }
    return sum / scale;
  };
  // native: body 200w, radius ~19 (6pt from bottom, line 89w 188.1); arrow 90-degree top, line 98w
  // 19.0, line 103w 9.3 (body bottom line 95)
  const body = coverage(img, 89), a98 = coverage(img, 98), a103 = coverage(img, 103);
  appendLog(`  popover widths: body=${body.toFixed(1)} arrow@98=${a98.toFixed(1)} arrow@103=${a103.toFixed(1)} (native 188.1 / 19.0 / 9.3)`);
  assert(Math.abs(body - 188.1) <= 3, `弹出层主体 89 行宽 ${body.toFixed(1)}，原生 188.1`);
  assert(Math.abs(a98 - 19.0) <= 2 && Math.abs(a103 - 9.3) <= 2, `箭头宽 ${a98.toFixed(1)} / ${a103.toFixed(1)}，原生 19.0 / 9.3`);
  // native popup four-edge no shadow: left 10pt, arrow side 20pt, still background 128
  const beside = [px(50, 60), px(140, 100), px(180, 100), px(160, 22)];
  appendLog(`  popover surroundings: ${JSON.stringify(beside)} (native 128)`);
  assert(beside.every((v) => Math.abs(v - 128) <= 3), `弹出层周围应无投影: ${JSON.stringify(beside)}`);
  const glass = px(70, 88);
  assert(Math.abs(glass - 230) <= 5, `弹出层玻璃在灰 128 上应为 230（原生 regular），实测 ${glass}`);
  await key("escape");
  await sleep(600);
  await shot("glasspopover-closed");
  const img2 = decodePng(`${DIR}/story-glasspopover-closed.png`);
  const closed = coverage(img2, 89) + coverage(img2, 98);
  assert(closed < 1, `Escape 后弹出层应完全收起，残余覆盖 ${closed.toFixed(2)}`);
});

test("GlassMenu: 菜单当帧出现、玻璃面板无投影、打开期间触发按钮保持按下、Escape 收起（native_menu_morph.swift menu）", async () => {
  await switchTo("glasspopover");
  await settle(600);
  let st = (await query("story.glassmenu.stage"))[0]?.rect;
  assert(st, "menu stage missing");
  for (let k = 0; k < 20 && st!.y > 160; k++) {
    await scrollAt(500, 500, 0, -Math.min(120, st!.y - 120));
    await sleep(120);
    st = (await query("story.glassmenu.stage"))[0]?.rect;
  }
  await sleep(400);
  const sample = (img: ReturnType<typeof decodePng>, x: number, y: number) => {
    const scale = decodedCaptureScale(img);
    return img.pixels[(Math.round((st!.y + y) * scale) * img.width + Math.round((st!.x + x) * scale)) * img.channels];
  };
  await shot("glassmenu-closed");
  const before = decodePng(`${DIR}/story-glassmenu-closed.png`);
  await clickTestId("story.glassmenu.button");
  await mouseMove(-10, -10);
  await sleep(500);
  await shot("glassmenu-open");
  const open = decodePng(`${DIR}/story-glassmenu-open.png`);
  // native panel 108.25..196.25 x 135..216.5, gray 128 base 230; all four edges 128 (no shadow)
  const inside = sample(open, 114, 210), left = sample(open, 100, 170), right = sample(open, 204, 170), below = sample(open, 150, 224);
  const btnBefore = sample(before, 120, 113), btnOpen = sample(open, 120, 113);
  appendLog(`  menu: inside=${inside} around=${left},${right},${below} button ${btnBefore}->${btnOpen}`);
  assert(Math.abs(inside - 230) <= 5, `菜单玻璃面板应为 230，实测 ${inside}`);
  assert([left, right, below].every((v) => Math.abs(v - 128) <= 3), `菜单面板周围应无投影: ${left},${right},${below}`);
  assert(btnBefore - btnOpen >= 12, `菜单打开期间触发按钮应保持按下（压暗），${btnBefore} -> ${btnOpen}`);
  await key("escape");
  await sleep(600);
  await shot("glassmenu-dismissed");
  const gone = decodePng(`${DIR}/story-glassmenu-dismissed.png`);
  const after = sample(gone, 114, 210), btnAfter = sample(gone, 120, 113);
  assert(Math.abs(after - 128) <= 3, `Escape 后菜单应完全淡出，面板处 ${after}`);
  assert(Math.abs(btnAfter - btnBefore) <= 3, `菜单收起后按钮恢复，${btnBefore} -> ${btnAfter}`);
});

test("GlassToolbar: 首次挂载按回读落族——读数几帧内到达、不靠超时；暗舞台最终是暗族", async () => {
  // native new glass on dark background: appearance (light) family first, ~150 ms later 0.37 s
  // to the dark family; Zenit follows (visible from the first frame). The reading must still
  // arrive within frames, not by timeout. Skip screenshot during switch: screenshot/recording
  // sync GPU at frame end, masks continuous-render starvation (that's exact normal build timeout).
  await switchTo("glasstoolbar");
  await settle(500);
  const r = (await query("story.glasstoolbar.dark.share"))[0]!.rect;
  const stats = async () => {
    const p = ((await request("POST", "/stats", {})) as any).glass_probe;
    assert(p, `/stats 缺 glass_probe（${JSON.stringify(p)}）`);
    return { resolved: Number(p.resolved), timedOut: Number(p.timed_out), maxFrames: Number(p.max_frames) };
  };
  const before = await stats();
  await switchTo("glasssplit");
  await settle(500);
  await mouseMove(-10, -10);
  await clickTestId("nav.glasstoolbar");
  await settle(700);
  const after = await stats();
  appendLog(`  probe stats: ${JSON.stringify(before)} -> ${JSON.stringify(after)}`);
  assert(after.timedOut === before.timedOut, `首帧探测不应靠超时结束（timed out ${before.timedOut} -> ${after.timedOut}）`);
  // global invariant (cumulative from boot, covers all prior story visits): no glass uses timeout
  // fallback, readback arrives frames in. Past leaks: readback only checked last frame done
  // (starvation), region array 32 exhausted, 12 slots by 16 glass fighting, union merge member no
  // readback key.
  assert(after.timedOut === 0, `自启动以来不应有任何探测超时（${after.timedOut}）`);
  assert(after.maxFrames <= 8, `回读应在几帧内到达（自启动最大 ${after.maxFrames} 帧）`);
  assert(after.resolved >= before.resolved + 6, `toolbar 的 6 块小玻璃都应按读数落族（resolved ${before.resolved} -> ${after.resolved}）`);
  const path = `${DIR}/glasstoolbar-mount.png`;
  assert((await screenshot(path)).ok === true, "screenshot failed");
  const v = lumaAt(path, r.x + r.w / 2, r.y + 4);
  assert(v < 60, `暗舞台工具栏应是暗族（${v.toFixed(0)}）`);
  assert((await health()).status === "ok", "app died after glasstoolbar mount");
});

test("GlassToolbar: NSToolbar 玻璃胶囊——悬停/按下/选中底板叠加、分隔线只在未选中段之间、失焦图标变淡（native_appkit_controls.swift）", async () => {
  await switchTo("glasstoolbar");
  await settle(600);
  await mouseMove(-10, -10); await sleep(200);
  const R: Record<string, any> = {};
  for (const id of ["stage", "sidebar", "share", "view.0", "view.1", "view.2", "search"]) R[id] = (await query(`story.glasstoolbar.${id}`))[0]?.rect;
  assert(R.stage && R.sidebar && R["view.2"] && R.search, "toolbar items missing");
  // geometry (native_appkit_controls.swift with the same 24 pt Lucide icons): button group ends
  // 1, split group ends 0, group gap 10 (native second group left 88 from first left), items 38
  const cap1 = R.sidebar.x - 1, cap2 = R["view.0"].x;
  assert(Math.abs(cap2 - cap1 - 88) < 0.6, `分段组左缘应距第一组 88 pt（${(cap2 - cap1).toFixed(2)}）`);
  assert(Math.abs(R.share.x - R.sidebar.x - 38) < 0.1 && Math.abs(R["view.1"].x - R["view.0"].x - 38) < 0.1, "项目宽 38");
  // Plate sampling: item midline, 2 pt below the plate's top edge (icon top is at 9 pt, so
  // avoided); on hover the pointer sits at the item's bottom-right corner so the virtual cursor does
  // not cover the sample point. (Also: 'baseline/selected baseline' elsewhere in this test means the
  // backing plate)
  // Plate sampling: 5 pt inside the plate's left edge at mid height (the plate spans x+3..x+35,
  // the 24 pt icon x+7..x+31), so neither the rounded corner nor the icon is hit.
  const plateAt = (png: string, id: string) => lumaAt(png, R[id].x + 5, R[id].y + R[id].h / 2);
  const corner = (id: string): [number, number] => [R[id].x + R[id].w - 3, R[id].y + R[id].h - 3];
  const sepAt = (png: string, right: string) => {
    const img = decodePng(png); const sc = decodedCaptureScale(img);
    const yy = Math.round((R[right].y + R[right].h / 2) * sc);
    const samples: number[] = [];
    for (let x = Math.floor((R[right].x - 1) * sc); x < Math.ceil((R[right].x + 3) * sc); x++) samples.push(img.pixels[(yy * img.width + x) * img.channels]);
    // A 1pt divider on a half-pixel boundary at 1x covers two pixels by half.
    // Integrate contrast across its full physical width, preserving the native
    // 234 +/- 3 opacity assertion instead of depending on the peak texel. This
    // also rejects missing, half-opacity and double-width separators.
    const background = Math.max(...samples);
    return background - samples.reduce((sum, value) => sum + background - value, 0) / sc;
  };
  const inkIn = (png: string, id: string) => {
    const img = decodePng(png); const sc = decodedCaptureScale(img); let m = 255;
    for (let y = Math.round((R[id].y + 9) * sc); y < Math.round((R[id].y + 27) * sc); y++)
      for (let x = Math.round((R[id].x + 9) * sc); x < Math.round((R[id].x + 27) * sc); x++) m = Math.min(m, img.pixels[(y * img.width + x) * img.channels]);
    return m;
  };
  await shot("glasstoolbar-rest");
  const rest = `${DIR}/story-glasstoolbar-rest.png`;
  const body = lumaAt(rest, R.share.x + 4, R.share.y + 4);
  const sel0 = plateAt(rest, "view.0"), sep12 = sepAt(rest, "view.2"), sep01 = sepAt(rest, "view.1");
  const ink = inkIn(rest, "share");
  appendLog(`  rest: glass ${body.toFixed(0)} selected ${sel0.toFixed(0)} sep 1|2 ${sep12} sep 0|1 ${sep01} icon ${ink} (native 247 / 222 / 234 / hidden / 74)`);
  assert(Math.abs(body - 247) <= 3, `玻璃主体应约 247（${body.toFixed(0)}）`);
  assert(Math.abs(sel0 - 222) <= 3, `选中段底板应约 222（${sel0.toFixed(0)}）`);
  assert(Math.abs(sep12 - 234) <= 3, `两未选中段之间应有 234 分隔线（${sep12}）`);
  assert(sep01 >= body - 3, `与选中段相邻处不应有分隔线（${sep01}）`);
  assert(Math.abs(ink - 74) <= 4, `图标墨色应约 74（${ink}）`);
  // hover/press button: now 234/222
  let [x, y] = corner("share");
  await mouseMove(x, y); await settle(150); await shot("glasstoolbar-hover");
  const hov = plateAt(`${DIR}/story-glasstoolbar-hover.png`, "share");
  await mouseDown(x, y); await settle(150); await shot("glasstoolbar-press");
  const prs = plateAt(`${DIR}/story-glasstoolbar-press.png`, "share");
  await mouseUp(x, y); await sleep(150);
  // hover/press selected: overlay 209/197
  [x, y] = corner("view.0");
  await mouseMove(x, y); await settle(150); await shot("glasstoolbar-hover-sel");
  const hsel = plateAt(`${DIR}/story-glasstoolbar-hover-sel.png`, "view.0");
  await mouseDown(x, y); await settle(150); await shot("glasstoolbar-press-sel");
  const psel = plateAt(`${DIR}/story-glasstoolbar-press-sel.png`, "view.0");
  await mouseUp(x, y); await sleep(150);
  appendLog(`  hover ${hov.toFixed(0)} press ${prs.toFixed(0)} selected+hover ${hsel.toFixed(0)} selected+press ${psel.toFixed(0)} (native 234 / 222 / 209 / 197)`);
  assert(Math.abs(hov - 234) <= 3 && Math.abs(prs - 222) <= 3, `按钮悬停/按下底板应约 234/222（${hov.toFixed(0)}/${prs.toFixed(0)}）`);
  assert(Math.abs(hsel - 209) <= 3 && Math.abs(psel - 197) <= 3, `选中段悬停/按下应叠加到约 209/197（${hsel.toFixed(0)}/${psel.toFixed(0)}）`);
  // click segment 2: release jumps to it; callback + status
  [x, y] = corner("view.2");
  await mouseMove(x, y); await mouseDown(x, y); await sleep(80); await mouseUp(x, y);
  await clickTestId("story.glasstoolbar.share");
  await mouseMove(-10, -10); await sleep(200);
  const status = (await query("story.glasstoolbar.status"))[0]?.text ?? "";
  appendLog(`  status: ${status}`);
  assert(status === "last: share · view: 2 · dark view: 0", `回调应记录 share 与选中第 2 段（${status}）`);
  await shot("glasstoolbar-sel2");
  const sel2 = `${DIR}/story-glasstoolbar-sel2.png`;
  const s01 = sepAt(sel2, "view.1");
  assert(Math.abs(plateAt(sel2, "view.2") - 222) <= 3 && plateAt(sel2, "view.0") >= body - 3, "选中底板应移到第 2 段");
  assert(Math.abs(s01 - 234) <= 3, `选中第 2 段后 0|1 之间应出现分隔线（${s01}）`);
  // unfocus: glass 241, selected baseline 216, icon 176 (story flips cx.window_active)
  await clickTestId("story.glasstoolbar.inactive"); await mouseMove(-10, -10); await sleep(250);
  await shot("glasstoolbar-inactive");
  const ina = `${DIR}/story-glasstoolbar-inactive.png`;
  const ib = lumaAt(ina, R.share.x + 4, R.share.y + 4), ip = plateAt(ina, "view.2"), ii = inkIn(ina, "share");
  // inactive glass flattens: capsule left no highlight, bottom no shadow (active left 254, bottom
  // 227). Highlight 1px wide: per-column max in capsule left ±1.5pt (5x5 mean dilutes it).
  const rimMax = (png: string) => {
    const img = decodePng(png); const sc = decodedCaptureScale(img); let m = 0;
    const yy = Math.round((R.share.y + R.share.h / 2) * sc);
    for (let x = Math.round((cap1 - 1.5) * sc); x <= Math.round((cap1 + 1.5) * sc); x++) m = Math.max(m, img.pixels[(yy * img.width + x) * img.channels]);
    return m;
  };
  const rimI = rimMax(ina), belowI = lumaAt(ina, R.share.x + R.share.w / 2, R.share.y + R.share.h + 3);
  const rimK = rimMax(rest), belowK = lumaAt(rest, R.share.x + R.share.w / 2, R.share.y + R.share.h + 3);
  await clickTestId("story.glasstoolbar.inactive");
  appendLog(`  inactive: glass ${ib.toFixed(0)} selected ${ip.toFixed(0)} icon ${ii} rim ${rimI.toFixed(0)} below ${belowI.toFixed(0)} | key rim ${rimK.toFixed(0)} below ${belowK.toFixed(0)} (native 241 / 216 / 176 / flat / flat)`);
  assert(rimK > 248 && belowK < 235, `获焦时应有边缘高光与投影（rim ${rimK.toFixed(0)} below ${belowK.toFixed(0)}）`);
  assert(rimI < 245 && belowI > 238, `失焦时边缘高光与投影应消失（rim ${rimI.toFixed(0)} below ${belowI.toFixed(0)}）`);
  // dark: 31 deep titlebar capsule flips dark family, baseline/icon/divider overlay white (native
  // darkAqua per-item measured)
  const D: Record<string, any> = {};
  for (const id of ["share", "view.0", "view.1", "view.2"]) D[id] = (await query(`story.glasstoolbar.dark.${id}`))[0]?.rect;
  const dPlate = (png: string, id: string) => lumaAt(png, D[id].x + 5, D[id].y + D[id].h / 2);
  const dCorner = (id: string): [number, number] => [D[id].x + D[id].w - 3, D[id].y + D[id].h - 3];
  const inkMax = (png: string, id: string) => {
    const img = decodePng(png); const sc = decodedCaptureScale(img); let m = 0;
    for (let y = Math.round((D[id].y + 9) * sc); y < Math.round((D[id].y + 27) * sc); y++)
      for (let x = Math.round((D[id].x + 9) * sc); x < Math.round((D[id].x + 27) * sc); x++) m = Math.max(m, img.pixels[(y * img.width + x) * img.channels]);
    return m;
  };
  await mouseMove(-10, -10); await sleep(200);
  await shot("glasstoolbar-dark");
  const dk = `${DIR}/story-glasstoolbar-dark.png`;
  const dBody = lumaAt(dk, D.share.x + 4, D.share.y + 4), dSel = dPlate(dk, "view.0"), dIcon = inkMax(dk, "share");
  [x, y] = dCorner("share");
  await mouseMove(x, y); await settle(150); await shot("glasstoolbar-dark-hover");
  const dHov = dPlate(`${DIR}/story-glasstoolbar-dark-hover.png`, "share");
  await mouseDown(x, y); await settle(150); await shot("glasstoolbar-dark-press");
  const dPrs = dPlate(`${DIR}/story-glasstoolbar-dark-press.png`, "share");
  await mouseUp(x, y); await mouseMove(-10, -10); await sleep(150);
  appendLog(`  dark: glass ${dBody.toFixed(0)} selected ${dSel.toFixed(0)} hover ${dHov.toFixed(0)} press ${dPrs.toFixed(0)} icon ${dIcon} (native 26 / 61 / 46 / 61 / 232)`);
  assert(Math.abs(dBody - 26) <= 4, `暗族玻璃主体应约 26（${dBody.toFixed(0)}）——胶囊没翻进暗族？`);
  assert(Math.abs(dSel - 61) <= 3 && Math.abs(dHov - 46) <= 3 && Math.abs(dPrs - 61) <= 3, `暗族底板应为叠白 61/46/61（${dSel.toFixed(0)}/${dHov.toFixed(0)}/${dPrs.toFixed(0)}）`);
  assert(Math.abs(dIcon - 232) <= 4, `暗族图标应约 90% 白 232（${dIcon}）`);
  await clickTestId("story.glasstoolbar.inactive"); await mouseMove(-10, -10); await sleep(250);
  await shot("glasstoolbar-dark-inactive");
  const dIna = `${DIR}/story-glasstoolbar-dark-inactive.png`;
  const dib = lumaAt(dIna, D.share.x + 4, D.share.y + 4);
  await clickTestId("story.glasstoolbar.inactive");
  appendLog(`  dark inactive: glass ${dib.toFixed(0)} (native 45, flat: 41 + 0.125·backdrop)`);
  assert(Math.abs(dib - 45) <= 3, `暗族失焦玻璃应约 45（${dib.toFixed(0)}）`);
  assert(Math.abs(ib - 241) <= 3 && Math.abs(ip - 216) <= 3 && Math.abs(ii - 176) <= 6, `失焦外观应为 241/216/176（${ib.toFixed(0)}/${ip.toFixed(0)}/${ii}）`);
  assert((await health()).status === "ok", "app died after glasstoolbar");
});

test("GlassAdapt: 滚动白→黑——悬浮玻璃条（36 pt）翻进暗族、回白翻回；大块 regular 面板不翻族；右下锚定面板折行后不出框", async () => {
  await switchTo("glassadapt");
  await settle(700);
  const st = (await query("story.glassadapt.stage"))[0]?.rect;
  assert(st, "stage missing");
  const status = async () => (await query("story.glassadapt.status"))[0]?.text ?? "";
  const cxp = st!.x + st!.w / 2, cyp = st!.y + st!.h / 2;
  // glass bar body sample: button top 5pt, centerline (no baseline when unhovered)
  const barBody = async (name: string) => {
    const b = (await query("story.glassadapt.share"))[0]!.rect;
    return lumaAt(`${DIR}/story-${name}.png`, b.x + b.w / 2, b.y + 5);
  };
  const panelBody = async (name: string) => {
    const p = (await query("story.glassadapt.panel"))[0]!.rect;
    return lumaAt(`${DIR}/story-${name}.png`, p.x + 12, p.y + p.h / 2);
  };
  await mouseMove(-10, -10); await sleep(500);
  await shot("glassadapt-top");
  const top = await status();
  const topBar = await barBody("glassadapt-top");
  // scroll to bottom (pure black): wait family flip (native 0.3s)
  await mouseMove(cxp, cyp);
  for (let i = 0; i < 40; i++) { await scrollAt(cxp, cyp, 0, -120); await sleep(20); }
  await mouseMove(-10, -10); await sleep(900);
  await shot("glassadapt-bottom");
  const bottom = await status();
  const botBar = await barBody("glassadapt-bottom"), botPanel = await panelBody("glassadapt-bottom");
  const pr = (await query("story.glassadapt.panel"))[0]!.rect;
  // scroll back to top (white)
  await mouseMove(cxp, cyp);
  for (let i = 0; i < 40; i++) { await scrollAt(cxp, cyp, 0, 120); await sleep(20); }
  await mouseMove(-10, -10); await sleep(900);
  const back = await status();
  appendLog(`  top: ${top} | bar body ${topBar.toFixed(0)}`);
  appendLog(`  bottom: ${bottom} | bar body ${botBar.toFixed(0)} panel body ${botPanel.toFixed(0)} panel bottom gap ${(st!.y + st!.h - (pr.y + pr.h)).toFixed(1)}`);
  appendLog(`  back: ${back}`);
  assert(top.startsWith("bar: light") && top.includes("panel: light"), `顶部白底：玻璃条与面板都应是亮族（${top}）`);
  assert(topBar > 220, `白底上玻璃条主体应是浅色（${topBar.toFixed(0)}）`);
  assert(bottom.startsWith("bar: dark"), `纯黑上 36 pt 玻璃条应翻进暗族（${bottom}）`);
  assert(botBar < 70, `暗族玻璃条主体应是深色（${botBar.toFixed(0)}）`);
  assert(bottom.includes("panel: light") && botPanel > 150, `大块 regular 面板不翻族，纯黑上仍是浅色玻璃（${bottom} / ${botPanel.toFixed(0)}）`);
  assert(Math.abs(st!.y + st!.h - (pr.y + pr.h) - 20) < 1, `右下锚定的面板底边应距舞台底 20（${(st!.y + st!.h - (pr.y + pr.h)).toFixed(1)}）`);
  assert(back.startsWith("bar: light"), `回到白底玻璃条应翻回亮族（${back}）`);
  assert((await health()).status === "ok", "app died after glassadapt");
});

test("GlassControls: 按住旋钮变成 clear 玻璃透镜并放大、松开恢复白色；开关点击翻转（native_slider_toggle.swift）", async () => {
  await switchTo("glasscontrols");
  await settle(600);
  const st = (await query("story.glasscontrols.stage"))[0]?.rect;
  assert(st, "controls stage missing");
  const at = (img: ReturnType<typeof decodePng>, x: number, y: number) => {
    const scale = decodedCaptureScale(img);
    const i = (Math.round((st!.y + y) * scale) * img.width + Math.round((st!.x + x) * scale)) * img.channels;
    return [img.pixels[i], img.pixels[i + 1], img.pixels[i + 2]];
  };
  // knob above one line (y=73, track 77..83 top) non-background width
  const knobWidth = (img: ReturnType<typeof decodePng>) => {
    const scale = decodedCaptureScale(img); const row = Math.round((st!.y + 73) * scale); let lo = -1, hi = -1;
    for (let x = Math.round((st!.x + 290) * scale); x < Math.round((st!.x + 320) * scale); x++) {
      const v = img.pixels[(row * img.width + x) * img.channels];
      if (Math.abs(v - 128) > 5) { if (lo < 0) lo = x; hi = x; }
    }
    // scan left half only (right may hide under virtual cursor), width = 2 * (center 320 - left
    // edge)
    return lo < 0 ? 0 : 2 * (Math.round((st!.x + 320) * scale) - lo) / scale;
  };
  // press knob right edge (still in, no jump): virtual cursor press ring (~9 radius) on right,
  // doesn't cover sample
  await mouseMove(st!.x + 329, st!.y + 80);
  await mouseDown(st!.x + 329, st!.y + 80);
  await sleep(600);
  await shot("glasscontrols-held");
  const held = decodePng(`${DIR}/story-glasscontrols-held.png`);
  const wHeld = knobWidth(held), inner = at(held, 313, 74)[0];
  await mouseUp(st!.x + 329, st!.y + 80);
  await mouseMove(-10, -10);
  await sleep(600);
  await shot("glasscontrols-rest");
  const rest = decodePng(`${DIR}/story-glasscontrols-rest.png`);
  const wRest = knobWidth(rest), white = at(rest, 320, 75)[0];
  appendLog(`  slider knob: held width ${wHeld.toFixed(1)} interior ${inner} | rest width ${wRest.toFixed(1)} centre ${white} (native at y=73: 20 / 136 | 13 / 255)`);
  // Widths come from one pixel row and double the left-edge distance, so their
  // resolution is two device pixels; the tolerance is three device pixels at
  // every DPI (±1.5 logical at 2×, as calibrated; ±3 at 100%).
  const widthTol = 3 / (decodedCaptureScale(held));
  assert(Math.abs(wHeld - 20) <= widthTol && Math.abs(wRest - 13) <= widthTol, `按住时旋钮应放大成玻璃（y=73 行宽 ${wRest.toFixed(1)} -> ${wHeld.toFixed(1)}，原生 13 -> 20，容差 ${widthTol.toFixed(1)}）`);
  assert(Math.abs(inner - 136) <= 5, `玻璃透镜内部在灰 128 上应约 136（原生 178 灰 16% 涂层、无模糊），实测 ${inner}`);
  assert(white >= 245, `松开后旋钮应恢复白色实心，实测 ${white}`);
  // toggle: click turn on, track blue (0,119,249)
  await clickTestId("story.glasscontrols.toggle");
  await mouseMove(-10, -10);
  await sleep(700);
  await shot("glasscontrols-on");
  const on = decodePng(`${DIR}/story-glasscontrols-on.png`);
  const track = at(on, 298, 176), knob = at(on, 329, 170);
  appendLog(`  toggle on: track ${track} knob ${knob}`);
  assert(track[2] > 230 && track[0] < 20, `开关开启后轨道应为蓝色 (0,119,249)，实测 ${track}`);
  assert(knob[0] >= 245, `开启后旋钮应停在右侧并为白色，实测 ${knob}`);
  // static after: knob/track not dirtied per-frame (idle gating)
  await sleep(800);
  const f0 = (await stats()).frame_count;
  await sleep(1000);
  const f1 = (await stats()).frame_count;
  appendLog(`  glasscontrols idle frames in 1s: ${f1 - f0}`);
  assert(f1 - f0 <= 3, `静止的滑块/开关不应持续出帧（1 s 内 ${f1 - f0} 帧）`);
});

test("GlassAppKit: NSGlassEffectView 参数——tintColor alpha 是 tint 量、contentView 按玻璃形状裁剪（native_tint_alpha.swift / native_appkit_glass_params.swift）", async () => {
  await switchTo("glassappkit");
  await settle(600);
  await shot("glassappkit");
  const img = decodePng(`${DIR}/story-glassappkit.png`);
  const sc = decodedCaptureScale(img);
  const rgb = (x: number, y: number) => { const i = (Math.round(y * sc) * img.width + Math.round(x * sc)) * img.channels; return [img.pixels[i], img.pixels[i + 1], img.pixels[i + 2]]; };
  const magenta = (c: number[]) => c[0] > 200 && c[1] < 80 && c[2] > 200;
  // contentView clip: the overflowing magenta square is cut at the glass edge, rounded corner
  // included ((108,50) is inside both arcs; (119.5,59.5) is outside cornerRadius 8 and the r 30
  // capsule).
  for (const id of ["story.glassappkit.clip.default", "story.glassappkit.clip.capsule"]) {
    const r = (await query(id))[0]?.rect;
    assert(r, `${id} missing`);
    const inside = rgb(r!.x + 108, r!.y + 50), corner = rgb(r!.x + 119.5, r!.y + 59.5), beyond = rgb(r!.x + 125, r!.y + 65);
    appendLog(`  ${id}: inside ${inside} corner ${corner} beyond ${beyond}`);
    assert(magenta(inside), `${id}: 玻璃内的溢出内容应可见 (${inside})`);
    assert(!magenta(corner), `${id}: 圆角外的内容应被裁掉 (${corner})`);
    assert(!magenta(beyond), `${id}: 玻璃外的内容应被裁掉 (${beyond})`);
    // (112, 54) is inside cornerRadius 8 but outside the capsule's r 30 arc: the capsule's clip
    // follows its radius resolved after layout.
    const arc = rgb(r!.x + 112, r!.y + 54);
    appendLog(`  ${id}: arc probe ${arc}`);
    assert(id.endsWith("capsule") ? !magenta(arc) : magenta(arc), `${id}: (112,54) 处裁剪形状错误 (${arc})`);
  }
  // tintColor alpha: native output is lerp(untinted, tinted, alpha) — over the same stripes the
  // green channel of the red row falls monotonically with alpha (white 249 -> 50 natively).
  const g: number[] = [];
  for (const a of [0, 64, 128, 191, 255]) {
    const r = (await query(`story.glassappkit.tint.0.${a}`))[0]?.rect;
    assert(r, `tint ${a} missing`);
    let sum = 0, n = 0;
    for (let dx = -40; dx <= 40; dx += 2) for (let dy = -10; dy <= 10; dy += 2) { sum += rgb(r!.x + r!.w / 2 + dx, r!.y + r!.h / 2 + dy)[1]; n++; }
    g.push(sum / n);
  }
  appendLog(`  red row mean G by alpha 0/64/128/191/255: ${g.map((v) => v.toFixed(0)).join(" / ")}`);
  for (let i = 1; i < g.length; i++) assert(g[i] < g[i - 1] - 15, `tint alpha 应单调加深: ${g.map((v) => v.toFixed(0)).join(" / ")}`);
});

test("GlassIdiom: 同一玻璃按 macOS / iOS 实测 profile 渲染——iOS regular 更透、色度更高、compact 投影更深（baselines/ios-26-5-simulator-iphone-17-pro）", async () => {
  await switchTo("glassidiom");
  await settle(600);
  await shot("glassidiom");
  const img = decodePng(`${DIR}/story-glassidiom.png`);
  const sc = decodedCaptureScale(img);
  const rgb = (x: number, y: number) => { const i = (Math.round(y * sc) * img.width + Math.round(x * sc)) * img.channels; return [img.pixels[i], img.pixels[i + 1], img.pixels[i + 2]]; };
  const mean = (r: any, dx: number, dy: number, f: (c: number[]) => number) => {
    let s = 0, n = 0;
    for (let x = -dx; x <= dx; x += 2) for (let y = -dy; y <= dy; y += 2) { s += f(rgb(r.x + r.w / 2 + x, r.y + r.h / 2 + y)); n++; }
    return s / n;
  };
  const rect = async (id: string) => { const r = (await query(id))[0]?.rect; assert(r, `${id} missing`); return r!; };
  const luma = (c: number[]) => (c[0] + c[1] + c[2]) / 3;
  const chroma = (c: number[]) => Math.max(...c) - Math.min(...c);
  // Over gray 128 (native 200x100: macOS 213 + 0.137 in = 230, iOS 0.71 coating = 216)
  const macGray = mean(await rect("story.glassidiom.macos.gray"), 30, 10, luma);
  const iosGray = mean(await rect("story.glassidiom.ios.gray"), 30, 10, luma);
  // Over colour bars: iOS keeps more of the backdrop chroma
  const macBars = mean(await rect("story.glassidiom.macos.bars"), 60, 10, chroma);
  const iosBars = mean(await rect("story.glassidiom.ios.bars"), 60, 10, chroma);
  // Below the compact capsule: iOS compact glass casts a stronger shadow
  const below = async (id: string) => { const r = await rect(id); return luma(rgb(r.x + r.w / 2, r.y + r.h + 4)); };
  const macShadow = await below("story.glassidiom.macos.compact"), iosShadow = await below("story.glassidiom.ios.compact");
  appendLog(`  gray body mac ${macGray.toFixed(0)} ios ${iosGray.toFixed(0)} | bars chroma mac ${macBars.toFixed(0)} ios ${iosBars.toFixed(0)} | compact shadow mac ${macShadow.toFixed(0)} ios ${iosShadow.toFixed(0)}`);
  assert(Math.abs(macGray - 230) <= 4, `macOS 灰底面板应约 230（${macGray.toFixed(0)}）`);
  assert(Math.abs(iosGray - 216) <= 4, `iOS 灰底面板应约 216（${iosGray.toFixed(0)}）`);
  assert(iosBars > macBars * 1.15, `iOS 色度应高于 macOS（${iosBars.toFixed(0)} vs ${macBars.toFixed(0)}）`);
  assert(iosShadow < macShadow - 3, `iOS compact 投影应更深（${iosShadow.toFixed(0)} vs ${macShadow.toFixed(0)}）`);
});

test("GlassIosBars: iOS 导航栏 / 工具栏 / 标签栏 / 玻璃按钮——几何与材质对齐 UIKit 原生（baselines/ios-26-5-simulator-iphone-17-pro/system）", async () => {
  await switchTo("glassiosbars");
  await settle(600);
  await shot("glassiosbars");
  let img = decodePng(`${DIR}/story-glassiosbars.png`);
  let sc = decodedCaptureScale(img);
  const rgb = (x: number, y: number) => { let s = [0, 0, 0], n = 0; for (let dx = -2; dx <= 2; dx++) for (let dy = -2; dy <= 2; dy++) { const i = (Math.round((y + dy * 0.5) * sc) * img.width + Math.round((x + dx * 0.5) * sc)) * img.channels; s = s.map((v, k) => v + img.pixels[i + k]); n++; } return s.map((v) => v / n); };
  const rect = async (id: string) => { const r = (await query(id))[0]?.rect; assert(r, `${id} missing`); return r!; };
  const near = (c: number[], want: number[], tol: number) => c.every((v, k) => Math.abs(v - want[k]) <= tol);
  const fmt = (c: number[]) => c.map((v) => v.toFixed(0)).join(",");
  // Geometry relative to the 402 pt strip (native: UIKit view hierarchy, iPhone 17 Pro).
  const nav = await rect("story.iosbars.nav");
  const back = await rect("story.iosbars.nav.back"), done = await rect("story.iosbars.nav.done");
  const tab = await rect("story.iosbars.tabbar"), search = await rect("story.iosbars.tab.search"), home = await rect("story.iosbars.tab.home");
  appendLog(`  back x ${(back.x - nav.x).toFixed(1)} w ${back.w} | done x ${(done.x - nav.x).toFixed(1)} w ${done.w.toFixed(1)} | home x ${(home.x - tab.x).toFixed(1)} w ${home.w.toFixed(1)} | search x ${(search.x - tab.x).toFixed(1)} w ${search.w}`);
  assert(Math.abs(back.x - nav.x - 16) < 0.5 && Math.abs(back.w - 44) < 0.5, "返回按钮应为 16 pt 处的 44 pt 圆");
  assert(Math.abs(done.x + done.w - (nav.x + 402 - 16)) < 0.5, "Done 应贴 16 pt 右边距");
  assert(Math.abs(home.x - tab.x - 25) < 0.5 && Math.abs(home.w - 100.7) < 0.2, "首个 tab 应在 25 pt、宽 100.7");
  assert(Math.abs(search.x - tab.x - 319) < 0.5 && Math.abs(search.w - 62) < 0.5, "搜索圆应在 319 pt、62 pt");
  // Material over gray 128 (native light: platter 205, prominent 0,124,235, selection plate 181,
  // clear button 151).
  const more = await rect("story.iosbars.nav.more");
  const platter = rgb(more.x + more.w + 8, more.y + 4);
  const doneBody = rgb(done.x + 6, done.y + done.h / 2);
  const plate = rgb(home.x + 12, home.y + home.h / 2);
  const clear = await rect("story.iosbars.btn.clear");
  const clearBody = rgb(clear.x + 5, clear.y + clear.h / 2);
  appendLog(`  platter ${fmt(platter)} done ${fmt(doneBody)} selection ${fmt(plate)} clear ${fmt(clearBody)} (native 205 / 0,124,235 / 181 / 151)`);
  assert(near(platter, [205, 205, 205], 6), `栏玻璃本体应约 205（${fmt(platter)}）`);
  assert(near(doneBody, [0, 124, 235], 14), `prominent 应约 0,124,235（${fmt(doneBody)}）`);
  assert(near(plate, [181, 181, 181], 8), `选中片应约 181（${fmt(plate)}）`);
  assert(near(clearBody, [151, 151, 151], 8), `clear 按钮应约 151（${fmt(clearBody)}）`);
  // The white-page specimen can sit below the viewport at higher desktop scaling.
  // Scroll it into view and capture its own frame before sampling the two colors.
  await bringIntoView(["story.iosbars.white.tab.home"]);
  await settle(600);
  await shot("glassiosbars-white-page");
  img = decodePng(`${DIR}/story-glassiosbars-white-page.png`);
  sc = decodedCaptureScale(img);
  const whiteHome = await rect("story.iosbars.white.tab.home");
  const whitePlate = rgb(whiteHome.x + 12, whiteHome.y + 6);
  const whiteBody = rgb(whiteHome.x + whiteHome.w + 40, whiteHome.y + 6);
  appendLog(`  white page: body ${fmt(whiteBody)} selection ${fmt(whitePlate)} (native 253 / 235)`);
  assert(near(whiteBody, [253, 253, 253], 4), `白底栏体应约 253（${fmt(whiteBody)}）`);
  assert(near(whitePlate, [235, 235, 235], 4), `白底选中片应约 235（${fmt(whitePlate)}）`);
});

test("GlassIosBars tab lens: 按下即抬起透镜、platter 放大、拖动跟手、松手吸附并提交选中（ios/fit_tab_lens.py 原生轨迹）", async () => {
  await switchTo("glassiosbars");
  await settle(600);
  // Locked clock: each sample lands at a precise animation time.
  animClockStep = 16;
  animClockLocked = true;
  const lock = await request("POST", "/clock", { step_ms: 16, locked: true });
  assert(!lock.error, `animation clock: ${JSON.stringify(lock)}`);
  try {
    const rect = async (id: string) => { const r = (await query(id))[0]?.rect; assert(r, `${id} missing`); return r!; };
    const home = await rect("story.iosbars.tab.home"), lib = await rect("story.iosbars.tab.library"), radio = await rect("story.iosbars.tab.radio");
    const tab = await rect("story.iosbars.tabbar");
    const cy = home.y + home.h / 2;
    // Press low in the button so the harness cursor stays clear of the icons
    const py = home.y + home.h - 4;
    let img: ReturnType<typeof decodePng>;
    const sample = async (name: string) => {
      await shot(name);
      img = decodePng(`${DIR}/story-${name}.png`);
      const sc = decodedCaptureScale(img);
      return (x: number, y: number) => { const i = (Math.round(y * sc) * img.width + Math.round(x * sc)) * img.channels; return [img.pixels[i], img.pixels[i + 1], img.pixels[i + 2]]; };
    };
    const fmt = (c: number[]) => c.map((v) => v.toFixed(0)).join(",");
    // Accent-blue pixels in a tab's icon box (24 pt icon, 5 pt from the button top)
    const blueIn = (r: { x: number; y: number; w: number }) => {
      const sc = decodedCaptureScale(img);
      let n = 0;
      for (let y = Math.round((r.y + 5) * sc); y < Math.round((r.y + 29) * sc); y++)
        for (let x = Math.round((r.x + r.w / 2 - 14) * sc); x < Math.round((r.x + r.w / 2 + 14) * sc); x++) {
          const i = (y * img.width + x) * img.channels;
          if (img.pixels[i + 2] - img.pixels[i] > 90) n++;
        }
      return n;
    };
    // Plain-ink (near black) pixels in the same box
    const darkIn = (r: { x: number; y: number; w: number }) => {
      const sc = decodedCaptureScale(img);
      let n = 0;
      for (let y = Math.round((r.y + 5) * sc); y < Math.round((r.y + 29) * sc); y++)
        for (let x = Math.round((r.x + r.w / 2 - 14) * sc); x < Math.round((r.x + r.w / 2 + 14) * sc); x++) {
          const i = (y * img.width + x) * img.channels;
          if (img.pixels[i] < 70 && img.pixels[i + 2] < 70) n++;
        }
      return n;
    };
    // Platter rest edge at tab.x + 21; 4 pt outside it is the gray 128 backdrop at rest.
    const outside = { x: tab.x + 21 - 4, y: cy };
    // Rest: plate under Home (181), Home ink blue, outside the platter backdrop
    let px = await sample("tablens-rest");
    assert(blueIn(home) > 40 && blueIn(lib) === 0, "静止：只有 Home 为强调色");
    appendLog(`  rest: plate ${fmt(px(home.x + 12, cy))} outside ${fmt(px(outside.x, outside.y))} home icon ${fmt(px(home.x + home.w / 2, home.y + 15))}`);
    assert(Math.abs(px(home.x + 12, cy)[0] - 181) <= 10, "静止：Home 下应有选中片（约 181）");
    assert(px(outside.x, outside.y)[0] < 145, "静止：platter 外应是背景");
    // Press Library and hold: lens lifts there, plate fades (Home now bare platter), platter grows
    await mouseMove(lib.x + lib.w / 2, py);
    await mouseDown(lib.x + lib.w / 2, py);
    await animSleep(800);
    px = await sample("tablens-held");
    appendLog(`  held: home ${fmt(px(home.x + 12, cy))} outside ${fmt(px(outside.x, outside.y))} blue px library ${blueIn(lib)} home ${blueIn(home)}`);
    assert(px(home.x + 12, cy)[0] > 192, `按住：选中片应随透镜离开 Home（${fmt(px(home.x + 12, cy))}）`);
    assert(px(outside.x, outside.y)[0] > 160, `按住：platter 应放大越过静止边缘（${fmt(px(outside.x, outside.y))}）`);
    assert(blueIn(lib) > 40 && blueIn(home) === 0, "按住：强调色应只在透镜内的 Library 上");
    appendLog(`  held: dark px library ${darkIn(lib)} home ${darkIn(home)}`);
    assert(darkIn(lib) < 10 && darkIn(home) > 40, "按住：透镜下的普通（黑）图标应被挖掉，透镜外保留");
    // Drag to Radio: the lens follows the finger
    const x0 = lib.x + lib.w / 2, x1 = radio.x + radio.w / 2;
    for (let i = 1; i <= 10; i++) {
      await mouseMove(x0 + ((x1 - x0) * i) / 10, py);
      await animSleep(32);
    }
    await animSleep(700);
    px = await sample("tablens-drag");
    appendLog(`  drag: blue px radio ${blueIn(radio)} library ${blueIn(lib)}`);
    assert(blueIn(radio) > 40, "拖动：透镜应跟到 Radio");
    assert(blueIn(lib) === 0, "拖动：Library 已不在透镜内");
    // Release: snaps on Radio, which becomes selected; the plate returns there and the platter shrinks back
    await mouseUp(x1, py);
    await animSleep(1800);
    px = await sample("tablens-released");
    appendLog(`  released: radio plate ${fmt(px(radio.x + 12, cy))} home ${fmt(px(home.x + 12, cy))} outside ${fmt(px(outside.x, outside.y))}`);
    assert(Math.abs(px(radio.x + 12, cy)[0] - 181) <= 10, `松手：Radio 下应有选中片（${fmt(px(radio.x + 12, cy))}）`);
    assert(px(home.x + 12, cy)[0] > 192, "松手：Home 不再选中");
    assert(px(outside.x, outside.y)[0] < 145, "松手：platter 应缩回");
    assert(blueIn(radio) > 40 && blueIn(lib) === 0 && blueIn(home) === 0, "松手：只有 Radio 图标为强调色");
    // Restore Home
    await clickTestId("story.iosbars.tab.home");
    await animSleep(1500);
  } finally {
    await useRealtimeClock();
  }
});

test("GlassConcentric: ConcentricRectangle 每角 = max(R − max(dx,dy), minimum)，玻璃同形（native_concentric.swift）", async () => {
  await switchTo("glassconcentric");
  await settle(600);
  const st = (await query("story.glassconcentric.stage"))[0]?.rect;
  assert(st, "concentric stage missing");
  await shot("glassconcentric");
  const img = decodePng(`${DIR}/story-glassconcentric.png`);
  const scale = decodedCaptureScale(img);
  // point within grid (row,col) relative to grid top-left
  const px = (row: number, col: number, x: number, y: number) =>
    img.pixels[(Math.round((st!.y + 20 + 140 * row + y) * scale) * img.width + Math.round((st!.x + 20 + 140 * col + x) * scale)) * img.channels];
  const checks: Array<[string, number, boolean]> = [
    // padding 12 -> radius 18: corner outside is container dark, 20pt along edge already white
    ["pad12 corner", px(0, 1, 13, 13), false],
    ["pad12 edge", px(0, 1, 32, 13), true],
    // padding 36 -> sharp
    ["pad36 corner", px(0, 3, 37, 37), true],
    // minimum 10: padding 36 also keeps 10 radius
    ["min10 pad36 corner", px(1, 3, 37, 37), false],
    // glass same shape: padding 36 sharp, padding 12 round
    ["glass pad36 corner", px(2, 3, 37, 37), true],
    ["glass pad12 corner", px(2, 1, 13, 13), false],
    // asymmetric (lead 6, top 18): left-top radius 12, left-bottom past container bottom 42 ->
    // sharp
    ["asym TL", px(3, 0, 7, 19), false],
    ["asym BL", px(3, 0, 7, 77), true],
    // glass diff corner radii (same geometry 6,18): left-top round, left-bottom sharp
    ["glass asym TL", px(3, 3, 7, 19), false],
    ["glass asym BL", px(3, 3, 7, 77), true],
  ];
  const got = checks.map(([n, v, light]) => `${n}=${v}${light ? "(light)" : "(dark)"}`).join(" ");
  appendLog(`  concentric: ${got}`);
  for (const [n, v, light] of checks) assert(light ? v > 180 : v < 100, `${n}: ${v}（期望${light ? "白/玻璃" : "容器深色"}）`);
});

test("GlassExtension: backgroundExtensionEffect 镜像铺满延伸区、只模糊视图自身安全区、边缘不渗背景（native_bg_extension.swift）", async () => {
  await switchTo("glassextension");
  await settle(600);
  const st = (await query("story.glassextension.stage"))[0]?.rect;
  assert(st, "extension stage missing");
  await shot("glassextension");
  const img = decodePng(`${DIR}/story-glassextension.png`);
  const scale = decodedCaptureScale(img);
  const at = (x: number, y: number) => {
    const i = (Math.round((st!.y + y) * scale) * img.width + Math.round((st!.x + x) * scale)) * img.channels;
    return [img.pixels[i], img.pixels[i + 1], img.pixels[i + 2]];
  };
  const mirrorRed = at(178, 240), blend = at(105, 240), sharp = at(15, 240), topEdge = at(120, 141);
  appendLog(`  extension: mirror ${mirrorRed} blend ${blend} far ${sharp} top edge ${topEdge}`);
  // tight to content is red bar mirror (native (255,56,60))
  assert(mirrorRed[0] > 240 && mirrorRed[1] < 90, `内容左侧应是红条镜像，实测 ${mirrorRed}`);
  // orange/yellow boundary blurred to mid (native x=105 G~186)
  assert(blend[1] > 150 && blend[1] < 200, `安全区内的镜像应被模糊（橙黄过渡中间色），实测 ${blend}`);
  // outside frame (x<40) mirror sharp: mint (0,200,179)
  assert(sharp[0] < 15 && Math.abs(sharp[1] - 200) <= 8, `frame 外的镜像应清晰，实测 ${sharp}`);
  // blur top edge doesn't bleed stage gray
  assert(topEdge[0] > 230, `模糊区边缘不应渗入背景灰，实测 ${topEdge}`);
});

test("CanvasEvents: scroll 修饰键 + magnify + drag + 剪贴板 PNG 回环", async () => {
  await switchTo("canvasevents");
  await sleep(300);
  const canvas = await screenPos("story.canvasevents.canvas");
  const cxp = canvas.x + 100;
  const cyp = canvas.y + 60;

  // scroll Cmd+modifier -> on_scroll gets modifiers
  await scrollAt(cxp, cyp, 0, -12, { cmd: true });
  await sleep(200);
  let texts: string[] = [];
  collectText((await query("story.canvasevents.scroll"))[0], texts);
  appendLog(`  scroll label: ${texts.join(" ")}`);
  assert(texts.join(" ").includes("cmd=true"), `on_scroll 应收到 cmd 修饰键 (got: ${texts.join(" ")})`);

  // magnify began->changed->ended
  await magnifyAt(cxp, cyp, 0, 0);
  await magnifyAt(cxp, cyp, 0.25, 1);
  await magnifyAt(cxp, cyp, 0.25, 1);
  await magnifyAt(cxp, cyp, 0, 2);
  await sleep(200);
  texts = [];
  collectText((await query("story.canvasevents.magnify"))[0], texts);
  appendLog(`  magnify label: ${texts.join(" ")}`);
  assert(texts.join(" ").includes("accum=0.50"), `magnify 应累计 0.50 (got: ${texts.join(" ")})`);
  assert(texts.join(" ").includes("phase=ended"), `magnify 最后 phase 应为 ended (got: ${texts.join(" ")})`);

  // drag entered -> dropped with path
  await dragAt(cxp, cyp, 0);
  await dragAt(cxp, cyp, 3, "/tmp/fake-image.png");
  await sleep(200);
  texts = [];
  collectText((await query("story.canvasevents.drag"))[0], texts);
  appendLog(`  drag label: ${texts.join(" ")}`);
  assert(texts.join(" ").includes("dropped"), `drag 应收到 dropped (got: ${texts.join(" ")})`);
  assert(texts.join(" ").includes("/tmp/fake-image.png"), `dropped 应携带路径 (got: ${texts.join(" ")})`);

  // clipboard PNG loop: write 2x2 red PNG -> probe/count/read full chain. With a private
  // pasteboard (ZENIT_E2E_PASTEBOARD, set per instance by run_storybook_e2e.sh) the round trip
  // must not touch the system clipboard: parallel instances would race on it, and a test run
  // must not overwrite the developer's clipboard.
  const privatePasteboard = process.platform === "darwin" && !!process.env.ZENIT_E2E_PASTEBOARD;
  const generalChangeCount = () => Number(execFileSync("osascript", ["-l", "JavaScript", "-e",
    'ObjC.import("AppKit"); $.NSPasteboard.generalPasteboard.changeCount'], { encoding: "utf8" }).trim());
  const generalBefore = privatePasteboard ? generalChangeCount() : 0;
  await clickTestId("story.canvasevents.clipbtn");
  await sleep(400);
  texts = [];
  collectText((await query("story.canvasevents.clip"))[0], texts);
  appendLog(`  clip label: ${texts.join(" ")}`);
  const clip = texts.join(" ");
  assert(clip.includes("image=true"), `probe 应报告 image (got: ${clip})`);
  assert(clip.includes("2x2"), `应读回 2x2 图片 (got: ${clip})`);
  assert(clip.includes("px_ok=true"), `像素应为纯红 premultiplied (got: ${clip})`);
  if (privatePasteboard) {
    const generalAfter = generalChangeCount();
    appendLog(`  general pasteboard changeCount ${generalBefore} -> ${generalAfter} (private: ${process.env.ZENIT_E2E_PASTEBOARD})`);
    assert(generalAfter === generalBefore, `剪贴板回环写进了系统剪贴板（changeCount ${generalBefore} -> ${generalAfter}），应只写实例私有 pasteboard`);
  }
  await shot("canvasevents");
  assert((await health()).status === "ok", "app died after canvasevents");
});

// -- color emoji pixel acceptance --
//
// The only forcing test for the true-color pipeline: grayscale also draws the emoji shape
// (coverage mask x text color), it just loses color. So don't assert 'drawn'; assert the three
// channels differ. Grayscale has R=G=B; a channel split only comes from a real BGRA sample.
//
// Target: pure-color emoji square. Center is solid, unaffected by size/antialiasing/center offset.
test("Emoji: 像素 — 中心像素三通道不相等（证明是彩色而非灰度）", async () => {
  await switchTo("emoji");
  // switchTo waits 'panel has any text', target node layout may lag (emoji last nav item,
  // ScrollArea still scrolling). Explicitly wait for it.
  await waitFor(async () => {
    const q = await query("story.emoji.red");
    return q.length > 0 && q[0].rect.w > 10 ? q : null;
  }, 6000, 60);
  await sleep(500); // settle: wait glyph into atlas + first frame stable
  await shot("emoji-color");
  const png = `${DIR}/story-emoji-color.png`;

  // [test_id, lead_channel], assert channels unequal PLUS lead channel correct, exclude 'BGRA
  // swapped to RGBA' misprediction.
  const cases: Array<[string, 0 | 1 | 2, string]> = [
    ["story.emoji.red", 0, "red"],
    ["story.emoji.green", 1, "green"],
    ["story.emoji.blue", 2, "blue"],
  ];

  for (const [id, dominant, name] of cases) {
    const nodes = await query(id);
    assert(nodes.length > 0 && nodes[0].rect.w > 10, `${id} 节点没布局出来`);
    const px = centerPixel(png, nodes[0].rect);
    const [r, g, b] = px;
    const spread = Math.max(r, g, b) - Math.min(r, g, b);
    appendLog(`  ${id}: rgb=(${r},${g},${b}) spread=${spread} dominant_expect=${name}`);

    // core: three channels unequal. Grayscale pipeline must have spread=0 here.
    assert(
      spread > 40,
      `${id} 中心像素三通道过于接近 rgb=(${r},${g},${b}) spread=${spread} — ` +
        `说明 emoji 仍走灰度路径（灰度必然三通道相等）`,
    );

    // lead channel assertion: prevent BGRA/RGBA swap.
    const maxIdx = px.indexOf(Math.max(r, g, b));
    assert(
      maxIdx === dominant,
      `${id} 主导通道应为 ${name}（索引${dominant}），实际 rgb=(${r},${g},${b}) ` +
        `主导索引=${maxIdx} — 疑似 BGRA/RGBA 通道顺序写反`,
    );
  }

  // control: normal text same neutral-gray color must still be grayscale (channels near-equal). If
  // also channel-split, color branch hurt grayscale.
  //
  // Can't take center pixel, 'AAAA' center lands between letters on background. Scan rect for
  // darkest (must be stroke interior), assert it's gray.
  const ctrl = await query("story.emoji.control");
  assert(ctrl.length > 0 && ctrl[0].rect.w > 10, "story.emoji.control 节点没布局出来");
  const cpx = darkestPixel(png, ctrl[0].rect);
  const cspread = Math.max(...cpx) - Math.min(...cpx);
  appendLog(`  story.emoji.control darkest: rgb=(${cpx.join(",")}) spread=${cspread}`);
  // really sampled stroke (gray rgb~128), else assertion worthless.
  assert(
    Math.max(...cpx) < 200,
    `灰度对照组没采到笔画像素 rgb=(${cpx.join(",")}) — 文字没画出来？`,
  );
  assert(
    cspread <= 8,
    `灰度对照组 rgb=(${cpx.join(",")}) spread=${cspread} 不再是灰度 — 彩色分支误伤了灰度路径`,
  );

  assert((await health()).status === "ok", "app died after emoji story");
});

// -- RTL bidi text pixel acceptance --
//
// Query output (text + rect) looks normal even when glyphs overlap reversed; only pixels
// distinguish. Criterion: horizontal ink distribution.
//   Correct: N glyphs along the pen, ink spans near node width.
//   Broken: RTL cut/reversed, glyphs squashed, ink span collapsed.
// Pitfall: segmentText cutting each Arabic/Hebrew codepoint into its own segment destroys bidi
// reorder + Arabic ligatures.
test("RTL: 像素 — 墨迹水平铺开（证明未反向重叠/未逐码点切碎）", async () => {
  await switchTo("rtl");
  await waitFor(async () => {
    const q = await query("story.rtl.arabic");
    return q.length > 0 && q[0].rect.w > 10 ? q : null;
  }, 6000, 60);
  await sleep(500); // settle: wait glyph into atlas + first frame stable
  await shot("rtl-bidi");
  const png = `${DIR}/story-rtl-bidi.png`;

  // Note: text in column stretches to column width, rect.w >> text width, can't use span/rect.w.
  // Criterion: ink span vs expected width from glyphs × ~0.5em.
  //
  // Expected: N glyphs × 0.5em estimate; conservative lower bound: any font average char-width >>
  // 0.35em, reversed-stacked glyphs 1-2 wide, misses bound.
  // [test_id, glyph count (visual should spread), font_size]
  const cases: Array<[string, number, number]> = [
    ["story.rtl.ltr_control", 5, 36], // abcde - control, verify criterion works
    ["story.rtl.arabic", 5, 36], // مرحبا
    ["story.rtl.hebrew", 4, 36], // שלום
    ["story.rtl.mixed", 9, 36], // ab + 5 Arabic + cd
  ];

  for (const [id, glyphCount, fontPx] of cases) {
    const nodes = await query(id);
    assert(nodes.length > 0 && nodes[0].rect.w > 10, `${id} 节点没布局出来`);
    const ink = inkColumns(png, nodes[0].rect);
    // inkColumns returns physical pixels; convert logical pt then compare font size.
    const scale = ink.width / nodes[0].rect.w;
    const spanLogical = ink.span / scale;
    const minPerGlyph = 0.35 * fontPx; // conservative lower
    const minExpected = glyphCount * minPerGlyph;
    const density = ink.cols / ink.span;
    appendLog(
      `  ${id} ink: first=${ink.first} last=${ink.last} span=${ink.span}px ` +
        `spanLogical=${spanLogical.toFixed(1)} minExpected=${minExpected.toFixed(1)} ` +
        `cols=${ink.cols} density=${density.toFixed(3)} centroid=${ink.centroid.toFixed(4)}`,
    );

    // really sampled stroke (else span assertion tests air).
    assert(ink.cols > 0, `${id} 没采到任何墨迹 — 文字没画出来？`);

    // core: ink span wide enough. Reversed-stacked glyphs collapse to 1-2 wide.
    assert(
      spanLogical >= minExpected,
      `${id} 墨迹跨度 ${spanLogical.toFixed(1)}px < 期望下界 ${minExpected.toFixed(1)}px` +
        `（${glyphCount} 字形 × ${minPerGlyph}px）— 字形疑似反向重叠或被逐码点切碎堆在一起`,
    );

    // ink density: exclude 'both ends one glyph, center empty' exact-span-OK but mid glyphs
    // missing/stacked.
    assert(
      density > 0.5,
      `${id} 墨迹密度 ${density.toFixed(3)}（cols=${ink.cols} / span=${ink.span}）过低 — ` +
        `中间字形疑似缺失或堆叠`,
    );
  }

  // Joining is tested with four dual-joining BEH letters. Marhaba contains
  // REH (U+0631, Right_Joining), so font-dependent gaps in that word are legal.
  // Unicode joining types: https://www.unicode.org/Public/UCD/latest/ucd/ArabicShaping.txt
  // A ZWNJ control forces isolated forms in the same font and screenshot.
  {
    const joined = (await query("story.rtl.joined_control"))[0];
    const isolated = (await query("story.rtl.isolated_control"))[0];
    assert(joined && isolated, "missing Arabic joining controls");
    const connectedInk = inkColumns(png, joined.rect);
    const isolatedInk = inkColumns(png, isolated.rect);
    const density = connectedInk.cols / connectedInk.span;
    const isolatedDensity = isolatedInk.cols / isolatedInk.span;
    appendLog(`  Arabic BEH joining: density=${density.toFixed(4)} isolated=${isolatedDensity.toFixed(4)} spans=${connectedInk.span}/${isolatedInk.span}`);
    assert(density >= 0.995, `dual-joining Arabic letters have disconnected ink: density=${density}`);
    // Isolated-form ink density is font metrics, not joining behavior: the
    // macOS Arabic font's isolated BEH tails nearly touch (≈0.98) while still
    // being four separate forms. Width is the font-independent evidence —
    // joining replaces wide isolated forms with narrow medial ones.
    assert(connectedInk.span < isolatedInk.span * 0.9, `ZWNJ control unexpectedly joins: spans=${connectedInk.span}/${isolatedInk.span} isolated density=${isolatedDensity}`);
    const nodes = await query("story.rtl.arabic");
    const ink = inkColumns(png, nodes[0].rect);
    // tight width post-ligature: isolated glyphs much wider.
    const scale = ink.width / nodes[0].rect.w;
    const spanLogical = ink.span / scale;
    appendLog(`  story.rtl.arabic cursive-width: spanLogical=${spanLogical.toFixed(1)} (需 < 82)`);
    assert(
      spanLogical < 82,
      `阿拉伯语墨迹跨度 ${spanLogical.toFixed(1)}px 过宽 — 连写形态比孤立形紧凑，` +
        `过宽说明退化成了孤立形（逐码点 shaping）`,
    );
  }

  // complex bidi input first verify story data itself, pixels confirm each case enough horizontal
  // ink. Final visual order from same golden.
  const complexCases: Array<[string, string]> = [
    ["story.rtl.numbers", "abc مرحبا 123 xyz"],
    ["story.rtl.mirrored_parens", "مرحبا (abc) שלום"],
    ["story.rtl.mirrored_brackets", "مرحبا [abc] שלום"],
    ["story.rtl.tashkeel", "مَرْحَبًا"],
    ["story.rtl.switches", "abc مرحبا xyz שלום 123"],
    ["story.rtl.symbols", "مرحبا https://example.com/a-b?q=1:2 test@example.com +12/34 - שלום"],
  ];
  for (const [id, expectedText] of complexCases) {
    const nodes = await query(id);
    assert(nodes.length > 0, `${id} 不存在`);
    assert(nodes[0].text === expectedText, `${id} 测试文本意外变化: ${JSON.stringify(nodes[0].text)}`);
    const ink = inkColumns(png, nodes[0].rect);
    appendLog(`  ${id} complex-bidi ink: span=${ink.span} cols=${ink.cols}`);
    assert(ink.cols >= 12 && ink.span >= 20, `${id} 没有形成可辨识的文字墨迹`);
  }

  // Tashkeel combining marks shouldn't advance like independent chars.
  const tashkeelBaseNode = (await query("story.rtl.tashkeel_base"))[0];
  const tashkeelNode = (await query("story.rtl.tashkeel"))[0];
  const baseInk = inkColumns(png, tashkeelBaseNode.rect);
  const markedInk = inkColumns(png, tashkeelNode.rect);
  const tashkeelRatio = markedInk.span / baseInk.span;
  appendLog(`  tashkeel advance ratio=${tashkeelRatio.toFixed(3)} (${markedInk.span}/${baseInk.span})`);
  assert(
    tashkeelRatio >= 0.8 && tashkeelRatio <= 1.25,
    `tashkeel 把 combining mark 当成独立 advance：宽度比=${tashkeelRatio.toFixed(3)}`,
  );

  assert((await health()).status === "ok", "app died after rtl story");
});

test("RTL: 窄宽换行的 caret、selection rect 与 hit-testing 共用视觉坐标", async () => {
  await switchTo("rtl");
  const rect = await screenPos("story.rtl.editor");
  await sleep(300);

  const initial = await inputState("story.rtl.editor");
  assert((initial.display_line_count ?? 0) >= 2, `RTL 编辑器没有触发 soft wrap: ${initial.display_line_count}`);

  assert(initial.line_height && initial.padding_v != null, "missing textarea line metrics");
  // RYMhT changed padding/line height; fixed y+30 now hits row 0.
  // Derive click centers without changing the story width or weakening row assertions.
  const lineHeight = initial.line_height!;
  const firstY = rect.y + initial.padding_v! + lineHeight / 2;
  const secondY = firstY + lineHeight;
  appendLog(`  RTL geometry: rect=${JSON.stringify(rect)} lineHeight=${lineHeight} padding=${initial.padding_v} rows=${initial.display_line_count}`);

  const graphemeBoundaries = new Set<number>([0]);
  const segmenter = new Intl.Segmenter(undefined, { granularity: "grapheme" });
  const encoder = new TextEncoder();
  for (const part of segmenter.segment(initial.buffer)) {
    graphemeBoundaries.add(encoder.encode(initial.buffer.slice(0, part.index)).length);
  }
  graphemeBoundaries.add(initial.buffer_len);

  const clickAndRead = async (x: number, y: number) => {
    await clickAt(x, y);
    await sleep(120);
    const state = await inputState("story.rtl.editor");
    assert(graphemeBoundaries.has(state.cursor_pos), `hit-test 落在 grapheme 内部: byte=${state.cursor_pos}`);
    assert(state.cursor_rect != null && state.cursor_rect.h > 0, `click (${x},${y}) 后没有 caret rect`);
    const caret = state.cursor_rect!;
    assert(Math.abs(caret.x - x) <= 28, `caret x=${caret.x} 与点击 x=${x} 不一致`);
    assert(Math.abs(caret.y + caret.h / 2 - y) <= 12, `caret y=${caret.y} 与点击 y=${y} 不在同一视觉行`);
    return state;
  };

  // same RTL visual line both sides, soft-wrap next visual line.
  const left = await clickAndRead(rect.x + rect.w * 0.28, firstY);
  const right = await clickAndRead(rect.x + rect.w * 0.72, firstY);
  const wrapped = await clickAndRead(rect.x + rect.w * 0.38, secondY);
  assert(left.cursor_pos !== right.cursor_pos, "同一 RTL 行左右 hit-test 映射到了同一逻辑位置");
  assert(left.cursor_rect!.x < right.cursor_rect!.x, "caret rect 的视觉 x 顺序与点击方向相反");
  assert(wrapped.cursor_rect!.y > left.cursor_rect!.y + 8, "soft-wrap 后行首/行尾仍映射到上一视觉行");

  // Exercise the two physical carets at soft-wrap boundaries as well as interior text.
  // Far-left/right clicks clamp to visual endpoints; they must retain the clicked row.
  for (const y of [firstY, secondY]) {
    for (const x of [rect.x + initial.padding_h!, rect.x + rect.w - initial.padding_h!]) {
      await clickAt(x, y);
      const endpoint = await inputState("story.rtl.editor");
      assert(graphemeBoundaries.has(endpoint.cursor_pos), "endpoint hit split a grapheme");
      assert(endpoint.cursor_rect && Math.abs(endpoint.cursor_rect.y + endpoint.cursor_rect.h / 2 - y) < 3,
        `soft-wrap endpoint mapped to another visual row: click=(${x},${y}) state=${JSON.stringify(endpoint)}`);
    }
  }

  // drag-select across visual lines; selection may split into multiple non-contiguous rects by bidi
  // run.
  const dragStart = { x: rect.x + rect.w * 0.24, y: firstY };
  const dragEnd = { x: rect.x + rect.w * 0.76, y: secondY };
  await mouseDown(dragStart.x, dragStart.y);
  await mouseMove((dragStart.x + dragEnd.x) / 2, (dragStart.y + dragEnd.y) / 2);
  await mouseMove(dragEnd.x, dragEnd.y);
  await mouseUp(dragEnd.x, dragEnd.y);
  await sleep(180);

  const selected = await inputState("story.rtl.editor");
  assert((selected.anchor ?? -1) >= 0, "RTL drag 没有建立 selection anchor");
  assert(selected.anchor !== selected.cursor_pos, "RTL drag 的 selection 为空");
  const selectionRects = selected.selection_rects ?? [];
  assert(selectionRects.length >= 2, `跨行 bidi selection rect 数量不足: ${selectionRects.length}`);
  for (const selection of selectionRects) {
    assert(selection.w > 0 && selection.h > 0, `空 selection rect: ${JSON.stringify(selection)}`);
    assert(
      selection.x >= rect.x - 2 && selection.x + selection.w <= rect.x + rect.w + 2 &&
        selection.y >= rect.y - 2 && selection.y + selection.h <= rect.y + rect.h + 2,
      `selection rect 越出编辑器: ${JSON.stringify(selection)} vs ${JSON.stringify(rect)}`,
    );
  }

  await shot("rtl-bidi-interaction");
  assert((await health()).status === "ok", "app died after RTL interaction test");
});

// CJK (IME marked text) coverage
//
// Covers the IME path (events.zig / event_dispatcher.zig / input/state.zig / input/textarea.zig /
// editable_block.zig) and e2e harness RPC (/ime_preedit /ime_commit).
//
// Dual verification:
//   - Log data: inputState() reads component internals (buffer / cursor_pos /
//     ime_preedit_len / ime_phase) to confirm the state machine;
//   - Visual: query() collects render tree text to confirm marked text is actually ON SCREEN
//     (buildDisplayText inserts preedit at cursor), plus screenshot.
//
// Known gaps (ROADMAP "known unsupported"; if hit, don't fix, just record):
//   Grapheme clusters (emoji backspace / combining chars), RTL edit interaction.
//   Cases below intentionally use CJK only.

/// read input/textarea rendered visible text (collect subtree text nodes).
async function visibleText(testId: string): Promise<string> {
  const q = await query(testId);
  const out: string[] = [];
  if (q[0]) collectText(q[0], out);
  return out.join("");
}

/// Find the caret node in the input subtree (a vertical bar 1px wide), return its x. Returns -1 if
/// not found.
function findCaretRect(node: any): any {
  if (node?.rect && node.rect.w === 1 && node.rect.h > 0) return node;
  for (const c of node?.children ?? []) {
    const r = findCaretRect(c);
    if (r) return r;
  }
  return null;
}

async function caretXOf(testId: string): Promise<number> {
  const q = await query(testId);
  const c = q[0] ? findCaretRect(q[0]) : null;
  return c ? c.rect.x : -1;
}

/// clear Input: focus -> select-all -> delete, assert really empty.
async function clearInput(testId: string): Promise<void> {
  await clickTestId(testId);
  await sleep(150);
  await key("a", { cmd: true });
  await sleep(80);
  await key("backspace");
  await sleep(80);
  for (let i = 0; i < 24; i++) await key("backspace");
  await sleep(150);
  const s = await inputState(testId);
  assert(s.buffer_len === 0, `clear ${testId} 失败: buffer_len=${s.buffer_len} buffer="${s.buffer}"`);
}

test("IME: Input preedit 显示 —— marked text 未上屏但可见，buffer 不变", async () => {
  await switchTo("input");
  await clearInput("story.input.name");

  // lay down some committed text as 'context', preedit should insert at cursor not end.
  await imeCommit("你好");
  await sleep(150);
  const base = await inputState("story.input.name");
  appendLog(`  [preedit] base: buffer="${base.buffer}" len=${base.buffer_len} cursor=${base.cursor_pos} phase=${base.ime_phase}`);
  assert(base.buffer_len === 6, `基线 buffer_len 应为 6（2 CJK×3B），got ${base.buffer_len}`);

  // pinyin input flow: step preedit (simulating 'shi' -> 'world' candidate)
  await imePreedit("shi", 3);
  await sleep(120);
  const p1 = await inputState("story.input.name");
  appendLog(`  [preedit] "shi": buffer="${p1.buffer}" len=${p1.buffer_len} preedit_len=${p1.ime_preedit_len} phase=${p1.ime_phase}`);
  // core assertion 1: preedit not in buffer (not on-screen yet)
  assert(p1.buffer_len === 6, `preedit 期间 buffer 被污染: len=${p1.buffer_len} buffer="${p1.buffer}"`);
  assert(p1.ime_preedit_len === 3, `ime_preedit_len 应为 3，got ${p1.ime_preedit_len}`);
  assert(p1.ime_phase === "composing", `ime_phase 应为 composing，got "${p1.ime_phase}"`);

  // core assertion 2: marked text really renders (visual side)
  const vis1 = await visibleText("story.input.name");
  appendLog(`  [preedit] visible text: "${vis1}"`);
  assert(vis1.includes("你好shi"), `渲染文本未含 marked text "shi"（应插在 cursor 处）— 实际: "${vis1}"`);

  // candidate switch: preedit content replacement ('shi' -> 'world'), must not stack
  await imePreedit("世界", 6);
  await sleep(120);
  const p2 = await inputState("story.input.name");
  appendLog(`  [preedit] "世界": buffer="${p2.buffer}" len=${p2.buffer_len} preedit_len=${p2.ime_preedit_len}`);
  assert(p2.buffer_len === 6, `候选切换后 buffer 被污染: len=${p2.buffer_len}`);
  assert(p2.ime_preedit_len === 6, `替换后 preedit_len 应为 6（不是叠加的 9），got ${p2.ime_preedit_len}`);
  const vis2 = await visibleText("story.input.name");
  appendLog(`  [preedit] visible text: "${vis2}"`);
  assert(vis2.includes("你好世界"), `候选替换后渲染文本错误 — 实际: "${vis2}"`);
  assert(!vis2.includes("shi"), `旧 preedit "shi" 残留在渲染文本里 — 实际: "${vis2}"`);

  const size = await shot("ime-input-preedit");
  assert(size > 3000, `preedit 截图过小 (${size} bytes)`);

  // finish: cancel, don't pollute next test
  await imePreedit("", 0);
  await sleep(100);
});

test("IME: Input commit —— 确认后文本落入 buffer，preedit 清空", async () => {
  await switchTo("input");
  await clearInput("story.input.name");

  await imePreedit("zhong", 5);
  await sleep(120);
  const pre = await inputState("story.input.name");
  assert(pre.buffer_len === 0 && pre.ime_preedit_len === 5, `commit 前状态异常: ${JSON.stringify(pre)}`);

  await imeCommit("中文");
  await sleep(180);
  const post = await inputState("story.input.name");
  appendLog(`  [commit] buffer="${post.buffer}" len=${post.buffer_len} cursor=${post.cursor_pos} preedit_len=${post.ime_preedit_len} phase=${post.ime_phase}`);
  assert(post.buffer === "中文", `commit 后 buffer 应为 "中文"，got "${post.buffer}"`);
  assert(post.buffer_len === 6, `commit 后 buffer_len 应为 6，got ${post.buffer_len}`);
  assert(post.cursor_pos === 6, `commit 后 cursor 应在末尾 6，got ${post.cursor_pos}`);
  assert(post.ime_preedit_len === 0, `commit 后 preedit 未清空: ${post.ime_preedit_len}`);
  assert(post.ime_phase !== "composing", `commit 后仍在 composing`);

  const vis = await visibleText("story.input.name");
  appendLog(`  [commit] visible text: "${vis}"`);
  assert(vis.includes("中文"), `commit 后渲染文本缺 "中文" — 实际: "${vis}"`);
  assert(!vis.includes("zhong"), `commit 后旧 preedit "zhong" 残留 — 实际: "${vis}"`);

  await shot("ime-input-commit");
});

test("IME: Input preedit 期间光标位置 —— caret 落在 preedit 内的 cursor_utf8_offset 处", async () => {
  await switchTo("input");
  await clearInput("story.input.name");

  // baseline: caret x with no preedit
  await imeCommit("ab");
  await sleep(150);
  const caretBase = await caretXOf("story.input.name");
  appendLog(`  [caret] base "ab": caret_x=${caretBase.toFixed(2)}`);
  assert(caretBase > 0, `基线 caret 未找到 (x=${caretBase})`);

  // preedit 'cde', offset 0 in preedit, caret shouldn't move
  await imePreedit("cde", 0);
  await sleep(150);
  const caret0 = await caretXOf("story.input.name");
  appendLog(`  [caret] preedit "cde" offset=0: caret_x=${caret0.toFixed(2)} (base=${caretBase.toFixed(2)})`);
  assert(
    Math.abs(caret0 - caretBase) < 1.5,
    `preedit cursor_offset=0 时 caret 应停在 preedit 起点 ${caretBase.toFixed(2)}，实际 ${caret0.toFixed(2)}`,
  );

  // offset 3 end preedit, caret right ~3 char widths
  await imePreedit("cde", 3);
  await sleep(150);
  const caret3 = await caretXOf("story.input.name");
  const dx = caret3 - caretBase;
  appendLog(`  [caret] preedit "cde" offset=3: caret_x=${caret3.toFixed(2)} Δ=${dx.toFixed(2)}px`);
  assert(dx > 8, `preedit cursor_offset=3 时 caret 应右移过 3 个字符（Δ>8px），实际 Δ=${dx.toFixed(2)}px`);

  // mid (offset 1) strict between both, pin 'caret advances monotonic'
  await imePreedit("cde", 1);
  await sleep(150);
  const caret1 = await caretXOf("story.input.name");
  appendLog(`  [caret] preedit "cde" offset=1: caret_x=${caret1.toFixed(2)}`);
  assert(
    caret1 > caretBase + 1 && caret1 < caret3 - 1,
    `preedit cursor_offset=1 的 caret 应严格位于 offset=0 (${caretBase.toFixed(2)}) 与 offset=3 (${caret3.toFixed(2)}) 之间，实际 ${caret1.toFixed(2)}`,
  );

  await shot("ime-input-preedit-caret");
  await imePreedit("", 0);
  await sleep(100);
});

test("IME: Input preedit 取消 —— 空 preedit / 切走焦点都不留脏文本", async () => {
  await switchTo("input");
  await clearInput("story.input.name");
  await imeCommit("原文");
  await sleep(150);

  // ① empty preedit (IME cancel compose)
  await imePreedit("pinyin", 6);
  await sleep(120);
  assert((await inputState("story.input.name")).ime_preedit_len === 6, "preedit 未建立");
  await imePreedit("", 0);
  await sleep(150);
  const c1 = await inputState("story.input.name");
  appendLog(`  [cancel:empty] buffer="${c1.buffer}" len=${c1.buffer_len} preedit_len=${c1.ime_preedit_len} phase=${c1.ime_phase}`);
  assert(c1.ime_preedit_len === 0, `空 preedit 后未清空: ${c1.ime_preedit_len}`);
  assert(c1.ime_phase === "idle", `空 preedit 后 phase 应回 idle，got "${c1.ime_phase}"`);
  assert(c1.buffer === "原文", `取消后 buffer 被污染: "${c1.buffer}"`);
  const vis1 = await visibleText("story.input.name");
  assert(!vis1.includes("pinyin"), `取消后 marked text "pinyin" 仍在渲染文本里 — 实际: "${vis1}"`);

  // ② blur (on_blur -> cancelImeComposition + discardIme)
  await imePreedit("canceled", 8);
  await sleep(120);
  assert((await inputState("story.input.name")).ime_preedit_len === 8, "第二段 preedit 未建立");
  await clickAt(900, 500); // click panel blank, let Input blur
  await sleep(250);
  const c2 = await inputState("story.input.name");
  appendLog(`  [cancel:blur] buffer="${c2.buffer}" len=${c2.buffer_len} preedit_len=${c2.ime_preedit_len} phase=${c2.ime_phase}`);
  assert(c2.ime_preedit_len === 0, `失焦后 preedit 未清空: ${c2.ime_preedit_len}（脏 marked text 残留）`);
  assert(c2.ime_phase === "idle", `失焦后 phase 应回 idle，got "${c2.ime_phase}"`);
  assert(c2.buffer === "原文", `失焦后 buffer 被污染: "${c2.buffer}"（未上屏文本被误提交）`);
  const vis2 = await visibleText("story.input.name");
  appendLog(`  [cancel:blur] visible text: "${vis2}"`);
  assert(!vis2.includes("canceled"), `失焦后 marked text 仍在渲染文本里 — 实际: "${vis2}"`);

  await shot("ime-input-cancel");
});

// ── Input viewport (LC3 regressions; also the Windows text-input / edge-drag stages) ──
// The editing viewport is the field's content box whatever the value is: the unscrolled long
// value at Home must not widen the content slot (CSS automatic minimum), or End lands on a
// shorter scroll, the text paints past the frame and a held edge drag never scrolls.

async function longInputValue(testId: string, value: string) {
  await clearInput(testId);
  await imeCommit(value);
  await sleep(120);
  const state = await inputState(testId);
  assert(state.buffer === value && state.cursor_pos === value.length, `long value not committed: ${JSON.stringify(state)}`);
  return state;
}

test("Input: long value keeps the field width; Home / End restore the viewport", async () => {
  await switchTo("input");
  const field = (await query("story.input.name.input"))[0].rect;
  const end = await longInputValue("story.input.name", "abcdefghijklmnopqrstuvwxyz".repeat(4));
  assert(end.scroll_x > 100, `caret did not scroll: ${end.scroll_x}`);
  await key("home");
  await sleep(120);
  const home = await inputState("story.input.name");
  assert(home.cursor_pos === 0 && home.scroll_x === 0, `Home did not reset the viewport: ${JSON.stringify(home)}`);
  const atHome = (await query("story.input.name.input"))[0].rect;
  assert(Math.abs(atHome.w - field.w) < 0.5, `field resized with its value: ${field.w} -> ${atHome.w}`);
  await key("end");
  await sleep(120);
  const restored = await inputState("story.input.name");
  assert(restored.cursor_pos === end.cursor_pos && Math.abs(restored.scroll_x - end.scroll_x) < 1,
    `End did not restore the viewport: typed=${end.scroll_x} restored=${restored.scroll_x}`);
  const caret = restored.cursor_rect!;
  assert(caret && caret.w > 0 && caret.x >= field.x && caret.x <= field.x + field.w,
    `caret left the field: ${JSON.stringify({ caret, field })}`);
});

test("Input: pointer drag selects an interior range in both directions", async () => {
  await switchTo("input");
  const value = "abcdefghijklmnopqrstuvwxyz";
  for (const reverse of [false, true]) {
    await longInputValue("story.input.name", value);
    const endCaret = (await inputState("story.input.name")).cursor_rect!;
    await key("home");
    const homeCaret = (await inputState("story.input.name")).cursor_rect!;
    assert(endCaret.x - homeCaret.x > 100, `value too short for the gesture: ${JSON.stringify({ homeCaret, endCaret })}`);
    await sleep(500); // not a double click on the focus click
    const span = endCaret.x - homeCaret.x, y = homeCaret.y + homeCaret.h / 2;
    const left = homeCaret.x + span * 0.2, right = homeCaret.x + span * 0.8;
    const from = reverse ? right : left, to = reverse ? left : right;
    assert((await mouseDown(from, y)).ok, "drag press failed");
    try {
      await mouseMove((from + to) / 2, y);
      await mouseMove(to, y);
    } finally {
      await mouseUp(to, y);
    }
    const state = await inputState("story.input.name");
    const anchor = state.anchor ?? -1;
    assert(anchor >= 0 && (reverse ? anchor > state.cursor_pos : anchor < state.cursor_pos), `drag direction: ${JSON.stringify(state)}`);
    const lo = Math.min(anchor, state.cursor_pos), hi = Math.max(anchor, state.cursor_pos);
    assert(lo > 0 && hi < value.length && hi - lo >= 10, `drag did not select an interior range: ${JSON.stringify(state)}`);
    await key("delete");
    const after = await inputState("story.input.name");
    assert(after.buffer === value.slice(0, lo) + value.slice(hi) && after.cursor_pos === lo && after.anchor === -1,
      `drag deleted a different range: ${JSON.stringify(after)}`);
  }
});

test("Input: a stationary drag past either edge keeps scrolling and stops on release", async () => {
  await switchTo("input");
  await longInputValue("story.input.name", "abcdefghijklmnopqrstuvwxyz".repeat(20));
  const r = (await query("story.input.name.input"))[0].rect, y = r.y + r.h / 2;
  for (const reverse of [false, true]) {
    await key(reverse ? "end" : "home");
    await sleep(500);
    const start = reverse ? r.x + r.w - 40 : r.x + 40, outside = reverse ? r.x - 30 : r.x + r.w + 30;
    assert((await mouseDown(start, y)).ok, "edge drag press failed");
    try {
      await mouseMove(outside, y);
      const before = await inputState("story.input.name");
      await sleep(600); // no pointer events while held outside
      const after = await inputState("story.input.name");
      assert(after.anchor === before.anchor && (after.anchor ?? -1) >= 0, `autoscroll moved the anchor: ${JSON.stringify({ before, after })}`);
      assert(reverse ? after.cursor_pos < before.cursor_pos : after.cursor_pos > before.cursor_pos,
        `stationary drag stopped selecting: ${JSON.stringify({ reverse, before: before.cursor_pos, after: after.cursor_pos, scroll: [before.scroll_x, after.scroll_x] })}`);
      assert(reverse ? after.scroll_x < before.scroll_x : after.scroll_x > before.scroll_x, "viewport did not follow the drag");
    } finally {
      await mouseUp(outside, y);
    }
    const released = await inputState("story.input.name");
    await sleep(250);
    const stopped = await inputState("story.input.name");
    assert(released.cursor_pos === stopped.cursor_pos && released.scroll_x === stopped.scroll_x, "drag continued after release");
  }
});

test("IME: Textarea 多行 —— 换行边界处 preedit/commit 正确", async () => {
  await switchTo("textarea");
  await clickTestId("story.textarea.box");
  await sleep(200);
  // clear
  await key("a", { cmd: true }); await sleep(80);
  await key("backspace"); await sleep(120);
  for (let i = 0; i < 24; i++) await key("backspace");
  await sleep(150);

  // build two lines: 'first\n' then compose on second, newline is tricky boundary
  await imeCommit("第一行");
  await sleep(150);
  await key("enter");
  await sleep(150);
  const base = await inputState("story.textarea.box");
  appendLog(`  [ta] base: buffer=${JSON.stringify(base.buffer)} len=${base.buffer_len} cursor=${base.cursor_pos}`);
  assert(base.buffer.includes("\n"), `换行未插入: ${JSON.stringify(base.buffer)}`);
  const baseLen = base.buffer_len;
  const baseCursor = base.cursor_pos;

  // second line start preedit
  await imePreedit("di er", 5);
  await sleep(150);
  const p = await inputState("story.textarea.box");
  appendLog(`  [ta] preedit: buffer=${JSON.stringify(p.buffer)} len=${p.buffer_len} preedit_len=${p.ime_preedit_len} phase=${p.ime_phase} cursor=${p.cursor_pos}`);
  assert(p.buffer_len === baseLen, `Textarea preedit 污染了 doc: ${baseLen} → ${p.buffer_len}`);
  assert(p.ime_preedit_len === 5, `Textarea preedit_len 应为 5，got ${p.ime_preedit_len}`);
  assert(p.ime_phase === "composing", `Textarea phase 应为 composing，got "${p.ime_phase}"`);
  assert(p.cursor_pos === baseCursor, `preedit 期间 doc cursor 不应移动: ${baseCursor} → ${p.cursor_pos}`);
  const visP = await visibleText("story.textarea.box");
  appendLog(`  [ta] visible during preedit: ${JSON.stringify(visP)}`);
  assert(visP.includes("di er"), `Textarea marked text 未渲染 — 实际: ${JSON.stringify(visP)}`);
  await shot("ime-textarea-preedit");

  // commit: lands second line, first + newline must intact
  await imeCommit("第二行");
  await sleep(200);
  const c = await inputState("story.textarea.box");
  appendLog(`  [ta] commit: buffer=${JSON.stringify(c.buffer)} len=${c.buffer_len} cursor=${c.cursor_pos} preedit_len=${c.ime_preedit_len}`);
  assert(c.ime_preedit_len === 0, `Textarea commit 后 preedit 未清空: ${c.ime_preedit_len}`);
  assert(c.buffer === "第一行\n第二行", `Textarea 换行边界 commit 结果错误: ${JSON.stringify(c.buffer)}`);
  assert(c.cursor_pos === c.buffer_len, `Textarea commit 后 cursor 应在末尾 ${c.buffer_len}，got ${c.cursor_pos}`);
  const visC = await visibleText("story.textarea.box");
  appendLog(`  [ta] visible after commit: ${JSON.stringify(visC)}`);
  assert(visC.includes("第二行"), `Textarea commit 后渲染缺 "第二行" — 实际: ${JSON.stringify(visC)}`);
  assert(!visC.includes("di er"), `Textarea commit 后旧 preedit 残留 — 实际: ${JSON.stringify(visC)}`);

  await shot("ime-textarea-commit");
  assert((await health()).status === "ok", "app died after textarea IME");
});

test("IME: Textarea 取消 —— 失焦不把 marked text 写进 doc", async () => {
  await switchTo("textarea");
  await clickTestId("story.textarea.box");
  await sleep(200);
  const before = await inputState("story.textarea.box");
  appendLog(`  [ta:cancel] before: buffer=${JSON.stringify(before.buffer)} len=${before.buffer_len}`);

  await imePreedit("wo yao qu xiao", 14);
  await sleep(150);
  assert((await inputState("story.textarea.box")).ime_preedit_len === 14, "Textarea preedit 未建立");

  await clickAt(950, 520); // click blank -> blur
  await sleep(300);
  const after = await inputState("story.textarea.box");
  appendLog(`  [ta:cancel] after blur: buffer=${JSON.stringify(after.buffer)} len=${after.buffer_len} preedit_len=${after.ime_preedit_len} phase=${after.ime_phase}`);
  assert(after.ime_preedit_len === 0, `Textarea 失焦后 preedit 未清空: ${after.ime_preedit_len}`);
  assert(after.ime_phase === "idle", `Textarea 失焦后 phase 应为 idle，got "${after.ime_phase}"`);
  assert(
    after.buffer === before.buffer,
    `Textarea 失焦后 doc 被 marked text 污染: ${JSON.stringify(before.buffer)} → ${JSON.stringify(after.buffer)}`,
  );
  const vis = await visibleText("story.textarea.box");
  assert(!vis.includes("wo yao qu xiao"), `Textarea 失焦后 marked text 仍在渲染文本 — 实际: ${JSON.stringify(vis)}`);

  await shot("ime-textarea-cancel");
});

// Harness injection verifies editor/render behavior independently of desktop IME engines.
for (const fixture of [
  { language: "Japanese", text: "こんにちは", cancelled: "日本語", shot: "japanese" },
  { language: "Korean", text: "안녕", cancelled: "한국어", shot: "korean" },
]) {
  test(`IME multilingual: ${fixture.language} replacement, commit and cancellation`, async () => {
    await switchTo("input");
    await clearInput("story.input.name");
    const bytes = new TextEncoder().encode(fixture.text).length;
    await imePreedit(fixture.text, 3);
    await sleep(120);
    const composing = await inputState("story.input.name");
    assert(composing.buffer === "" && composing.ime_preedit_len === bytes,
      `preedit changed document or byte length: ${JSON.stringify(composing)}`);
    assert((await visibleText("story.input.name")).includes(fixture.text), "preedit missing from rendered text");
    await shot(`ime-${fixture.shot}-preedit`);
    await imeCommit(fixture.text);
    await sleep(120);
    const committed = await inputState("story.input.name");
    assert(committed.buffer === fixture.text && committed.cursor_pos === bytes && committed.ime_preedit_len === 0,
      `incorrect multilingual commit: ${JSON.stringify(committed)}`);
    await imePreedit(fixture.cancelled, 3);
    const blurClick = await clickTestId("story.input.email");
    assert(blurClick.ok, `Email focus click failed: ${JSON.stringify(blurClick)}`);
    await sleep(120);
    const cancelled = await inputState("story.input.name");
    assert(cancelled.buffer === fixture.text && cancelled.ime_preedit_len === 0,
      `blur leaked composition: ${JSON.stringify(cancelled)}`);
    assert(!(await visibleText("story.input.name")).includes(fixture.cancelled), "cancelled preedit still rendered");
    await shot(`ime-${fixture.shot}-commit-cancel`);
  });
}

test("IME multilingual: rapid replacement and mixed UTF-8 commit order", async () => {
  await switchTo("input");
  await clearInput("story.input.name");
  // No artificial delays between acknowledged commands: exercise successive owned events.
  for (let i = 0; i < 48; i++) await imePreedit(i % 2 ? "안녕" : "こんにちは", 3);
  await sleep(120);
  const replacement = await inputState("story.input.name");
  assert(replacement.buffer === "" && replacement.ime_preedit_len === 6,
    `rapid replacement accumulated or committed: ${JSON.stringify(replacement)}`);
  for (const text of ["日本語", "한국어", "中文", "café"]) await imeCommit(text);
  await sleep(120);
  const committed = await inputState("story.input.name");
  const expected = "日本語한국어中文café";
  assert(committed.buffer === expected && committed.cursor_pos === new TextEncoder().encode(expected).length && committed.ime_preedit_len === 0,
    `rapid mixed commit lost order/bytes: ${JSON.stringify(committed)}`);
  assert((await visibleText("story.input.name")).includes(expected), "mixed commit missing from rendered text");
  await shot("ime-multilingual-rapid");
});

// 2026-08-16 core review fix batch regression anchors (story + e2e dual verification)

/// read test_id node's own text (no subtree).
async function labelText(id: string): Promise<string> {
  const q = await query(id);
  return q[0]?.text ?? "";
}

test("WordNav: Alt+←/→ 词跳 + 双击选词（希腊/西里尔/家庭 emoji 簇字节偏移）", async () => {
  // Batch A2 regression: 2-byte lead fell into ASCII path -> Alt+word jump stuck, double-click
  // selects empty. Byte ledger see stories.zig WORDNAV_TEXT.
  await switchTo("wordnav");
  const TA = "story.wordnav.ta";
  const pos = await screenPos(TA);
  // click wrapper lower half (field; upper is label), ensure input focused
  await clickAt(pos.x + pos.w / 2, pos.y + pos.h - 30);
  // back to offset 0: Cmd+Left unreliable (display-line, wrap start); Alt+Left ×12 from any point
  // must reach 0 (only 8 words whole text). Old code's Alt+Left got stuck and could not reach 0; the later
  // assertions would still fail, so regression sensitivity is unaffected.
  for (let i = 0; i < 12; i++) await key("left", { alt: true });
  let st = await inputState(TA);
  assert(st.buffer_len === 75, `预置文本字节数不是 75: ${st.buffer_len}（story 文本被改动？）`);
  assert(st.cursor_pos === 0, `12×Alt+Left 后 cursor 应为 0，实际 ${st.cursor_pos}（Alt 词跳可能原地卡死）`);

  // Alt+Right: 0 -> 7 -> 14 -> 27 -> 34 -> 40 -> 46 -> 72 -> 75 (before-fix stuck at 0)
  const rightStops = [7, 14, 27, 34, 40, 46, 72, 75];
  for (const expect of rightStops) {
    await key("right", { alt: true });
    st = await inputState(TA);
    assert(st.cursor_pos === expect, `Alt+Right 词跳落点错误: 期望 ${expect}，实际 ${st.cursor_pos}`);
  }
  appendLog(`  [wordnav] Alt+Right stops OK: ${rightStops.join(" ")}`);

  // Alt+Left: 75 -> 72 -> 46 -> 40 -> 34 -> 27 -> 14 -> 7 -> 0
  const leftStops = [72, 46, 40, 34, 27, 14, 7, 0];
  for (const expect of leftStops) {
    await key("left", { alt: true });
    st = await inputState(TA);
    assert(st.cursor_pos === expect, `Alt+Left 词跳落点错误: 期望 ${expect}，实际 ${st.cursor_pos}`);
  }
  appendLog(`  [wordnav] Alt+Left stops OK: ${leftStops.join(" ")}`);

  // double-click select word: position cursor inside 'привет' (14..26) at byte 20, take cursor_rect
  // screen coords for double-click, not pixel estimate, coords from data.
  // (above Alt+Left sequence already stopped at 0)
  await key("right", { alt: true }); // 7
  await key("right", { alt: true }); // 14
  await key("right"); // 16
  await key("right"); // 18
  await key("right"); // 20
  st = await inputState(TA);
  assert(st.cursor_pos === 20, `预备光标应为 20，实际 ${st.cursor_pos}`);
  assert(st.cursor_rect != null, "cursor_rect 缺失，无法定位双击坐标");
  const cxp = st.cursor_rect!.x + 1;
  const cyp = st.cursor_rect!.y + st.cursor_rect!.h / 2;
  await clickAt(cxp, cyp, 2); // Two consecutive taps in one request -> double-click word selection (not affected by driver roundtrip latency)
  st = await inputState(TA);
  const anchor = st.anchor ?? -1;
  const lo = Math.min(anchor, st.cursor_pos);
  const hi = Math.max(anchor, st.cursor_pos);
  appendLog(`  [wordnav] double-click selection: anchor=${anchor} cursor=${st.cursor_pos}`);
  assert(lo === 14 && hi === 26, `双击选词应选中 "привет" [14,26]，实际 [${lo},${hi}]（修复前为空选区）`);
  await shot("wordnav-selection");
});

test("MultiClick: 双击计数可达 + long_press 按住触发（gesture arena 回归）", async () => {
  // Batch C4: Before fix, reset() cleared click_count on every down, making double counting
  // unreachable. Batch A3: first frame can load story (switchTo succeeds), itself is regression
  // anchor for epoch first-frame panic. Intervals past ~450ms or pointer-cancel injection excluded
  // from assertion scope.
  await switchTo("multiclick");
  const pad = await screenPos("story.multiclick.pad");
  const px = pad.x + pad.w / 2;
  const py = pad.y + pad.h / 2;
  const readCount = async (id: string) => {
    const t = await labelText(id);
    const m = t.match(/(\d+)/);
    assert(m != null, `label ${id} 无计数: ${JSON.stringify(t)}`);
    return Number(m![1]);
  };

  const singles0 = await readCount("story.multiclick.single");
  const doubles0 = await readCount("story.multiclick.double");

  await clickAt(px, py, 2); // Two consecutive taps in one request: interval unaffected by driver roundtrip latency

  await waitFor(async () => (await readCount("story.multiclick.double")) === doubles0 + 1 ? true : null, getE2eTimeoutMs(5000), 60);
  const singles1 = await readCount("story.multiclick.single");
  assert(singles1 === singles0 + 2, `tap 计数应 +2（每击各一），实际 ${singles0} → ${singles1}`);
  appendLog(`  [multiclick] double ${doubles0} → ${doubles0 + 1}, single ${singles0} → ${singles1}`);

  // long_press: hold down, story before_render keeps rendering during press, gesture_arena.tick
  // advances time check each frame; must began after 500ms, ended on lift.
  await mouseDown(px, py);
  await waitFor(async () => (await labelText("story.multiclick.long")).includes("began") ? true : null, getE2eTimeoutMs(5000), 100);
  await mouseUp(px, py);
  await waitFor(async () => (await labelText("story.multiclick.long")).includes("ended") ? true : null, getE2eTimeoutMs(5000), 60);
  appendLog(`  [multiclick] long_press began → ended OK`);
  assert((await health()).status === "ok", "app died during gesture test");
});

test("AnimCtl: yoyo 重放起点 / timeline reverse 终止 / keyframes 批量补齐 / spring 退化参数", async () => {
  // Batch C1/C2/C6/C3. All data read assertions; no mid-animation pixel checks.
  await switchTo("animctl");

  // -- C2 timeline reverse: play ~0.4s then reverse, must complete in finite time and stop at t=0
  // --
  // High-latency driver: reverse must arrive before 2s timeline completes.
  await useAnimationClock();
  await clickTestId("story.animctl.tl_play");
  await animSleep(400);
  const tlMid = await labelText("story.animctl.tl");
  assert(tlMid.includes("state=playing"), `timeline 应在播放中，实际: ${tlMid}`);
  await clickTestId("story.animctl.tl_reverse");
  await animSleep(1200);
  const tlDone = await waitFor(async () => {
    const t = await labelText("story.animctl.tl");
    return t.includes("state=completed") ? t : null;
  }, getE2eTimeoutMs(8000), 100);
  await useRealtimeClock();
  // Completion must be 'rewind to 0' not 'play to end' (t=2.00 means reverse ineffective/too late)
  assert(tlDone.includes("t=0.00"), `reverse 后应停在 t=0.00（旧代码永转不停），实际: ${tlDone}`);
  appendLog(`  [animctl] timeline reverse → ${tlDone}`);

  // -- C1 yoyo: first play -> completed, rewinds to from; bare play() must start from from --
  await clickTestId("story.animctl.yoyo_play");
  const yoyoDone = await waitFor(async () => {
    const t = await labelText("story.animctl.yoyo");
    return t.includes("state=completed") ? t : null;
  }, getE2eTimeoutMs(8000), 100);
  const endVal = Number(yoyoDone.match(/value=([-\d.]+)/)?.[1]);
  assert(Number.isFinite(endVal) && endVal < 40, `yoyo 完成应停回 from(20) 附近，实际: ${yoyoDone}`);
  // Replay (bare play(), not restart()): old code left direction at -1 -> played from to=120
  // backwards
  await clickTestId("story.animctl.yoyo_play");
  const replay = await waitFor(async () => {
    const t = await labelText("story.animctl.yoyo");
    const m = t.match(/replay_first=([-\d.]+)/);
    if (!m) return null;
    const v = Number(m[1]);
    return Number.isFinite(v) && v >= 0 ? v : null; // -1.0 = not yet sampled
  }, getE2eTimeoutMs(5000), 60);
  assert(replay < 70, `yoyo 重放首 tick 应从 from(20) 侧起步（<70），实际 ${replay}（≈120 = 旧代码从 to 倒播）`);
  appendLog(`  [animctl] yoyo end=${endVal} replay_first=${replay}`);

  // -- C6 keyframes: advance 1000ms explicit (400ms period x4 loops), one update must batch 2 full
  // periods and stop at 50% (old code: single-period if -> loops=1, value=100) --
  await clickTestId("story.animctl.kf_reset");
  await clickTestId("story.animctl.kf_step");
  const kf1 = await waitFor(async () => {
    const t = await labelText("story.animctl.kf");
    return t.includes("loops=") && !t.includes("loops=0 value=0.0") ? t : null;
  }, getE2eTimeoutMs(5000), 60);
  assert(kf1.includes("loops=2") && kf1.includes("value=50.0"),
    `帧停滞 1000ms 后应批量补齐 2 周期停在 50%（loops=2 value=50.0），实际: ${kf1}`);
  await clickTestId("story.animctl.kf_step"); // Then +1000ms -> total 2000ms = 5 periods > 4 -> complete
  const kf2 = await waitFor(async () => {
    const t = await labelText("story.animctl.kf");
    return t.includes("completed=true") ? t : null;
  }, getE2eTimeoutMs(5000), 60);
  assert(kf2.includes("loops=4") && kf2.includes("value=100.0"),
    `4 循环跑满后应 loops=4 value=100.0，实际: ${kf2}`);
  appendLog(`  [animctl] keyframes ${kf1} → ${kf2}`);

  // -- C3 spring: negative stiffness ticked several frames, value must be finite (old code: NaN
  // into style) --
  const springTxt = await waitFor(async () => {
    const t = await labelText("story.animctl.spring");
    const m = t.match(/ticks=(\d+)/);
    return m && Number(m[1]) > 30 ? t : null;
  }, getE2eTimeoutMs(5000), 100);
  assert(!springTxt.includes("nan") && !springTxt.includes("inf"),
    `退化 spring 产出了非有限值: ${springTxt}`);
  const springVal = Number(springTxt.match(/value=([-\d.]+)/)?.[1]);
  assert(Number.isFinite(springVal), `spring value 不可解析: ${springTxt}`);
  // Element still visible (finite translate -> rect returns normally)
  const box = (await query("story.animctl.springbox"))[0];
  assert(box != null && box.rect.w > 0, "spring 驱动的元素消失（rect 异常）");
  assert(Number.isFinite(box.translate_x ?? 0), `springbox translate_x 非有限: ${box.translate_x}`);
  appendLog(`  [animctl] spring ${springTxt} translate_x=${box.translate_x}`);
});

test("CleanupHooks: 卸载带 cleanup 的子树计数恰好 +1（双触发回归）", async () => {
  // Batch A4: Before fix, fireCleanupCallbacks + freeNode both fired -> unmount count +2.
  await switchTo("cleanup");
  assert((await labelText("story.cleanup.count")) === "cleanups: 0", "初始计数应为 0");
  assert((await query("story.cleanup.child")).length === 1, "child 初始应挂载");

  const tg1 = await clickTestId("story.cleanup.toggle"); // Unmount
  assert(tg1.ok === true, `toggle click 未命中: ${JSON.stringify(tg1)}`);
  await waitFor(async () => (await labelText("story.cleanup.count")) !== "cleanups: 0" ? true : null, getE2eTimeoutMs(5000), 60);
  await sleep(200); // If second trigger occurs, give it time to show
  const after1 = await labelText("story.cleanup.count");
  assert(after1 === "cleanups: 1", `一次卸载后计数应恰为 1（2 = 双触发回归），实际: ${JSON.stringify(after1)}`);
  assert((await query("story.cleanup.child")).length === 0, "child 应已卸载");

  const tg2 = await clickTestId("story.cleanup.toggle"); // Remount
  assert(tg2.ok === true, `toggle click(remount) 未命中: ${JSON.stringify(tg2)}`);
  await waitFor(async () => (await query("story.cleanup.child")).length === 1 ? true : null, getE2eTimeoutMs(5000), 60);
  const tg3 = await clickTestId("story.cleanup.toggle"); // Unmount again
  assert(tg3.ok === true, `toggle click(2nd unmount) 未命中: ${JSON.stringify(tg3)}`);
  await waitFor(async () => (await labelText("story.cleanup.count")) === "cleanups: 2" ? true : null, getE2eTimeoutMs(5000), 60);
  await sleep(200);
  const after2 = await labelText("story.cleanup.count");
  assert(after2 === "cleanups: 2", `第二轮卸载后计数应恰为 2，实际: ${JSON.stringify(after2)}`);
  appendLog(`  [cleanup] toggle → 1 → remount → toggle → 2 OK`);
});

test("HeavyText: 超 32768 glyph 预算的单帧内容真实画出（overflow 池化路径）", async () => {
  // Sect 5 pooling: text renderer overflow instance buffer retains across frames. 8 layers x ~40
  // visible rows x ~160 chars/row ~= 50k glyph instances, consistently exceeds MAX_INSTANCES=32768,
  // forces overflow path. Assert region non-blank pixels + app alive.
  await switchTo("heavytext");
  await sleep(400); // Heavy content first frame settle
  const path = `${DIR}/story-heavytext-overflow.png`;
  const r = await screenshot(path);
  assert(r.ok === true, `heavytext screenshot 失败: ${JSON.stringify(r)}`);
  const stackPos = await screenPos("story.heavytext.stack");
  // Dense text area must have abundant dark pixels (overflow path drops glyphs -> becomes
  // sparse/blank)
  assertRegionHasInk(path, stackPos, "heavytext dense region", 5000);
  assert((await health()).status === "ok", "app died rendering heavy text");
  // Add frame to confirm cross-frame stability (pool reuse on frame 2)
  await scrollAt(stackPos.x + 10, stackPos.y + 10, 0, 2);
  await sleep(150);
  const path2 = `${DIR}/story-heavytext-overflow-2.png`;
  await screenshot(path2);
  assertRegionHasInk(path2, stackPos, "heavytext dense region (frame 2)", 5000);
});

test("Security Text: 65536 连续空格缩短为 1 byte 后 stale wrap 安全收敛", async () => {
  await switchTo("sectext");
  let focus = await focused();
  for (let i = 0; i < 128 && focus.test_id !== "story.sectext.replace"; i++) {
    await key("tab");
    focus = await focused();
  }
  assert(focus.test_id === "story.sectext.replace", `sectext replacement action was not keyboard reachable: ${JSON.stringify(focus)}`);
  await key("enter");
  const edited = await waitFor(async () => {
    const value = await inputState("story.sectext.input");
    return value.buffer_len === 1 ? value : null;
  }, getE2eTimeoutMs(8000), 80);
  assert(edited.buffer === "x", `sectext edited buffer mismatch: ${JSON.stringify(edited.buffer)}`);
  const status = await waitFor(async () => {
    const value = await labelText("story.sectext.status");
    return value.includes("bytes: 1") ? value : null;
  }, getE2eTimeoutMs(8000), 80);
  assert(status.includes("UTF-8 valid: true"), `缩短后的文本状态异常: ${status}`);
  assert((await health()).status === "ok", "app died after shrinking the long whitespace run");
  appendLog(`  [sectext] ${status}`);
});

test("Lifecycle Stress: Grid 在响应式回调中连续卸载/重挂 10 轮", async () => {
  await switchTo("teardownstress");
  const click = await clickTestId("story.teardownstress.run");
  assert(click.ok === true, `stress button click failed: ${JSON.stringify(click)}`);
  const status = await waitFor(async () => {
    const value = await labelText("story.teardownstress.status");
    return value.includes("completed cycles: 10") ? value : null;
  }, getE2eTimeoutMs(15000), 100);
  assert(status.includes("grid mounted"), `stress 后 Grid 未恢复挂载: ${status}`);
  assert((await query("story.teardownstress.grid")).length === 1, "stress 后 Grid 节点缺失");
  assert((await health()).status === "ok", "app died during reactive Grid teardown stress");
  appendLog(`  [teardownstress] ${status}`);
});

test("Storybook: DevTools shortcut and toolbar open a real window", async () => {
  await shot("storybook-devtools-before-open");

  // macOS Chrome-compatible shortcut: the target Cx flips inspector.enabled,
  // then the Storybook multi-window host materializes the standalone panel.
  await key("i", { cmd: true, alt: true });
  await waitFor(async () => (await query("devtools.header.shell"))[0] ?? null, 3000, 40);
  const shortcutTexts: string[] = [];
  const shortcutHeader = (await query("devtools.header.shell"))[0];
  collectText(shortcutHeader, shortcutTexts);
  assert(shortcutTexts.join(" │ ").includes("Zenit Storybook DevTools"),
    `DevTools 快捷键打开了窗口但标题不对: ${shortcutTexts.join(" │ ")}`);
  await shot("storybook-devtools-open-shortcut");

  await clickTestId("devtools.close");
  await waitFor(async () => (await query("storybook.devtools"))[0] ?? null, 3000, 40);
  await shot("storybook-devtools-closed-shortcut");

  // Toolbar is the discoverable equivalent of Cmd+Option+I.
  await clickTestId("storybook.devtools");
  await waitFor(async () => (await query("devtools.header.shell"))[0] ?? null, 3000, 40);
  await shot("storybook-devtools-open-toolbar");
  await clickTestId("devtools.close");
  await waitFor(async () => (await query("storybook.devtools"))[0] ?? null, 3000, 40);
  await shot("storybook-devtools-closed-toolbar");
});

test("Storybook: DevTools header theme toggle rebuilds panel in the other scheme", async () => {
  await clickTestId("storybook.devtools");
  await waitFor(async () => (await query("devtools.theme.toggle"))[0] ?? null, 3000, 40);
  await shot("storybook-devtools-theme-initial");

  // Click only sets flag; next frame root hook switches theme + rebuilds entire tree, old toggle
  // node replaced.
  const before = (await query("devtools.theme.toggle"))[0];
  const click = await clickTestId("devtools.theme.toggle");
  assert(click.ok === true, `theme toggle click failed: ${JSON.stringify(click)}`);
  await waitFor(async () => {
    const now = (await query("devtools.theme.toggle"))[0];
    return now && now.id !== before.id ? now : null;
  }, 3000, 40);
  assert((await query("devtools.header.shell")).length === 1, "主题切换后 header 未重建");
  await shot("storybook-devtools-theme-toggled");

  // Switch back, panel still intact and usable.
  const mid = (await query("devtools.theme.toggle"))[0];
  await clickTestId("devtools.theme.toggle");
  await waitFor(async () => {
    const now = (await query("devtools.theme.toggle"))[0];
    return now && now.id !== mid.id ? now : null;
  }, 3000, 40);
  assert((await query("devtools.search.input")).length === 1, "切回后搜索栏缺失");
  await shot("storybook-devtools-theme-restored");
  assert((await health()).status === "ok", "app died during DevTools theme toggle");

  await clickTestId("devtools.close");
  await waitFor(async () => (await query("storybook.devtools"))[0] ?? null, 3000, 40);
});

// -- GPU perf regression gate --
//
// Purpose: catch GPU perf regressions in CI (the renderer's real GPU time is surfaced to the
// harness).
//
// Why only gpu_p95_us, not cpu/total:
//   gpu_p95 is stable (1220-1811us over 6 rounds x 2 scenarios) while cpu_p95 swings
//   6309-95847us on the same load: the e2e file-RPC driver's polling/scheduling stalls count as
//   CPU frame time. A cpu_p95 gate would fail randomly. GPU time comes from MTLCommandBuffer
//   timestamps, immune to RPC stalls.
//
// Threshold: observed max 1811us -> 8000us (~4.4x headroom). Deliberately loose: a randomly failing
//   gate equals no gate. Real regressions (drop cache tier, recompile PSO per frame) are 10x
//   larger.
const GPU_P95_BUDGET_US = 8000;
// Sample floor: P95 meaningless with few samples; empty loops return 0.
// Skip sample count -> fake 'always green' gate.
const MIN_TIMING_SAMPLES = 30;

/// The story's scrollable list: the first VirtualList node (rect + its visible row labels).
function findVirtualList(node: any): any {
  if (node?.component === "VirtualList") return node;
  for (const c of node?.children ?? []) {
    const hit = findVirtualList(c);
    if (hit) return hit;
  }
  return null;
}

async function virtualListState(): Promise<{ rect: any; labels: string }> {
  const list = findVirtualList(await tree());
  assert(list?.rect, "story has no VirtualList to scroll");
  const texts: string[] = [];
  collectText(list, texts);
  return { rect: list.rect, labels: texts.join(" | ") };
}

// The wheel goes to the story's own list (virtuallist: the 1000-row VirtualList; table: the
// virtual Table body). A wheel over content that cannot scroll renders no frame, so the load must
// come from content that really moves; the gate first proves it does.
for (const key of ["table", "virtuallist"]) {
  test(`perf gate: ${key} 滚动 GPU 帧时间 P95 < ${GPU_P95_BUDGET_US}us`, async () => {
    await switchTo(key);
    await sleep(700); // Wait entrance/layout settle, avoid first-frame PSO compile tainting sample
    const before = await virtualListState();
    const x = before.rect.x + before.rect.w / 2;
    const y = before.rect.y + before.rect.h / 2;
    await resetTiming(); // Clear loop -> P95 only counts this scenario's frames
    // Generate real scroll load (retained layer repaint + path/text pipeline). Scroll down then up,
    // content always moving: wheel stops at boundary = no frame = insufficient sample.
    for (let i = 0; i < 40; i++) {
      await scrollAt(x, y, 0, i < 20 ? -60 : 60);
      await sleep(25);
      if (i === 19) {
        const moved = await virtualListState();
        assert(moved.labels !== before.labels, `滚轮没有移动 ${key} 的列表内容（目标点 ${x},${y}）— 负载不成立`);
      }
    }
    const s = await stats();
    appendLog(
      `  [perf:${key}] samples=${s.timing_samples} gpu_p95=${s.gpu_p95_us}us ` +
      `cpu_p95=${s.cpu_p95_us}us total_p95=${s.total_p95_us}us ` +
      `(last frame: gpu=${s.gpu_execute_us} layout=${s.layout_us} render_gen=${s.render_gen_us} encode=${s.gpu_encode_us})`,
    );
    // Pre-check gate validity: insufficient samples -> P95 stuck at 0, assertion false-green.
    assert(
      s.timing_samples >= MIN_TIMING_SAMPLES,
      `计时样本不足 ${s.timing_samples} < ${MIN_TIMING_SAMPLES} — P95 不可信（门禁失效而非通过）`,
    );
    assert(
      s.gpu_p95_us > 0,
      `gpu_p95_us 为 0 —— GPU 时间戳管线没出货，门禁形同虚设`,
    );
    assert(
      s.gpu_p95_us < GPU_P95_BUDGET_US,
      `GPU 帧时间回退：${key} 滚动 gpu_p95=${s.gpu_p95_us}us 超预算 ${GPU_P95_BUDGET_US}us ` +
      `(本机基线 ~1.2-1.8ms)。细分见 log 的 layout/render_gen/encode。`,
    );
  }, { serial: "asserts a GPU frame-time P95 budget; other instances sharing the GPU inflate it" });
}

test("Surface: resize 后 screenshot readback 仍有效（usage 单一出口回归）", async () => {
  // Regression: maybeReconfigureSurface hardcoded .color_target_only, resize triggered surface
  // reconfiguration losing test-mode CPU readback, /screenshot all failed or corrupted. Now init
  // and resize share surfaceConfigFor single outlet.
  const before = `${DIR}/resize-readback-before.png`;
  const shotBefore = await screenshot(before);
  assert(shotBefore.ok === true, `resize 前基线截图失败: ${JSON.stringify(shotBefore)}`);
  const pngBefore = decodePng(before);

  const r = await resizeWindow(900, 800);
  assert((r as any).ok === true, `resize 请求失败: ${JSON.stringify(r)}`);
  await sleep(400); // Wait main loop completes surface reconfig + presents new frame

  const after = `${DIR}/resize-readback-after.png`;
  const shotAfter = await screenshot(after);
  assert(shotAfter.ok === true, `resize 后截图失败（readback 能力在重配时丢失）: ${JSON.stringify(shotAfter)}`);
  const pngAfter = decodePng(after);
  assert(pngAfter.width > 0 && pngAfter.height > 0, "resize 后 png 解码失败");
  // Size actually changed (proves reconfig occurred, not testing thin air)
  assert(
    pngAfter.width !== pngBefore.width || pngAfter.height !== pngBefore.height,
    `drawable 尺寸未变化（before=${pngBefore.width}x${pngBefore.height} after=${pngAfter.width}x${pngAfter.height}）— resize 未生效，本用例没测到重配路径`,
  );
  // Content real (not all-black/white corruption): image must have abundant dark pixels
  const dark = countDarkPixels(pngAfter, { x: 0, y: 0, w: 900, h: 800 }, pngAfter.width / 900);
  appendLog(`  [resize-readback] after=${pngAfter.width}x${pngAfter.height} dark=${dark}`);
  assert(dark >= 500, `resize 后截图疑似花屏/空白（dark=${dark}）`);

  // Restore initial size, avoid affecting potential subsequent tests/manual comparison
  await resizeWindow(1100, 1000);
  await sleep(200);
});

// -- Popover autosize: tall content must not cover trigger --
// floating-ui size availableHeight -> max-height alignment. Before fix, caller without explicit
// max_height left popover full height, best-fit only translates, panel bottom crosses trigger and
// covers reference element.
test("popover: tall content shrinks to viewport and never covers its trigger", async () => {
  await switchTo("popoverregress");
  const trigger = (await query("story.popover.tall.trigger"))[0];
  assert(trigger != null && trigger.rect.h > 0, "tall popover trigger 不存在");
  const click = await clickTestId("story.popover.tall.trigger");
  assert(click.ok === true, `tall popover trigger click failed: ${JSON.stringify(click)}`);
  const content = await waitFor(async () => {
    const node = (await query("story.popover.tall.content"))[0];
    return node != null && node.rect.w > 0 && node.rect.h > 0 ? node : null;
  }, getE2eTimeoutMs(2000), 50);
  await sleep(400); // autosize next frame applies max_height + enter animation settles
  const settled = (await query("story.popover.tall.content"))[0];
  assert(settled != null, "tall popover content 消失");
  appendLog(`  trigger=${JSON.stringify(trigger.rect)} content(first)=${JSON.stringify(content.rect)} content(settled)=${JSON.stringify(settled.rect)}`);
  await shot("popover-tall-autosize");
  // Native compositors may choose a different client extent. Check against
  // the same logical viewport used by popover layout, including after resize.
  const vpH = (await tree()).rect.h;
  assert(vpH > 0, "missing native client height");
  // Precondition: content actually exceeds window (else assertion on air)
  assert(settled.rect.h < 1400, `面板高度 ${settled.rect.h} 未被收紧（内容 1400+px）`);
  assert(settled.rect.h <= vpH, `面板高度 ${settled.rect.h} 超出 viewport ${vpH}`);
  assert(settled.rect.y >= 0 && settled.rect.y + settled.rect.h <= vpH, `面板越出 viewport: ${JSON.stringify(settled.rect)}`);
  assert(!rectsOverlap(settled.rect, trigger.rect), `面板盖住了 trigger: content=${JSON.stringify(settled.rect)} trigger=${JSON.stringify(trigger.rect)}`);
  // Child content must be clipped by the panel chrome: 2px below the panel bottom edge
  // must not be an indigo block (shrinking only the shell without clipping children counts as not
  // shrunk)
  const below = { x: settled.rect.x + settled.rect.w / 2 - 2, y: settled.rect.y + settled.rect.h + 2, w: 4, h: 4 };
  assert(below.y + below.h <= vpH, `面板下缘距 viewport 太近，采样点越界: ${JSON.stringify(below)}`);
  const px = centerPixel(`${DIR}/story-popover-tall-autosize.png`, below);
  appendLog(`  pixel below panel=${JSON.stringify(px)}`);
  // Content is high-saturation gradient; panel exterior is gray/white border; high-saturation
  // appearance = overflow
  const saturation = Math.max(...px) - Math.min(...px);
  assert(saturation < 60, `面板下缘外仍是内容色块（未裁切）: ${JSON.stringify(px)}`);
  // fit_or_scroll: content beyond cap scrolls vertically inside panel (scroll moves content up,
  // panel shell stays)
  const scrollBefore = (await query("story.popover.tall.scroll_content"))[0];
  assert(scrollBefore != null && scrollBefore.rect.h > settled.rect.h, `滚动内容应高于面板: ${JSON.stringify(scrollBefore?.rect)}`);
  // Trackpad gesture began in main content area then lost ended (happens on real machine when
  // switching windows), next gesture's began must re-lock to popover by hit, not keep dispatching
  // to main content.
  const mainX = trigger.rect.x + trigger.rect.w / 2, mainY = trigger.rect.y + trigger.rect.h / 2;
  await scrollAt(mainX, mainY, 0, 0, { phase: "began" });
  await scrollAt(mainX, mainY, 0, -2, { phase: "changed" });
  await trackpadScroll(
    settled.rect.x + settled.rect.w / 2,
    settled.rect.y + settled.rect.h / 2,
    Array.from({ length: 10 }, (): [number, number] => [0, -30]),
  );
  const scrollAfter = await waitFor(async () => {
    const node = (await query("story.popover.tall.scroll_content"))[0];
    return node != null && node.rect.y < scrollBefore.rect.y - 100 ? node : null;
  }, getE2eTimeoutMs(2000), 50);
  const panelAfter = (await query("story.popover.tall.content"))[0];
  appendLog(`  scroll_content before=${JSON.stringify(scrollBefore.rect)} after=${JSON.stringify(scrollAfter.rect)} panel=${JSON.stringify(panelAfter?.rect)}`);
  assert(panelAfter != null && Math.abs(panelAfter.rect.y - settled.rect.y) < 1 && Math.abs(panelAfter.rect.h - settled.rect.h) < 1, `面板内滚动不应移动面板外壳: ${JSON.stringify(panelAfter?.rect)}`);
  await key("escape");
  await sleep(300);
});

test("Storybook 搜索: 输入过滤导航、分组标题随行隐藏、无匹配提示、清空恢复", async () => {
  const sidebarText = async (): Promise<string[]> => {
    const out: string[] = [];
    const t = await query("sidebar");
    if (t[0]) collectText(t[0], out);
    return out;
  };
  const clearSearch = async () => {
    await clickTestId("storybook.search");
    await key("a", { cmd: true });
    await key("backspace");
    await sleep(250);
  };

  await clickTestId("storybook.search");
  await type_("glass");
  await sleep(300);
  let out = await sidebarText();
  appendLog(`  search "glass": ${out.join(" │ ")}`);
  assert(out.includes("Liquid Glass") && out.includes("Glass Lab"), `应保留 Glass* 行 — ${out.join(" │ ")}`);
  assert(out.includes("Liquid glass"), `匹配行的分组标题应保留 — ${out.join(" │ ")}`);
  assert(!out.includes("Button") && !out.includes("Actions"), `不匹配的行与空分组应隐藏 — ${out.join(" │ ")}`);
  await shot("search-glass");

  // Filtered rows remain clickable
  await clickTestId("nav.glasslab");
  await sleep(300);
  assert((await query("story.glasslab")).length > 0, "点击过滤结果应切到 GlassLab story");

  await clearSearch();
  await clickTestId("storybook.search");
  await type_("zzzz-nope");
  await sleep(300);
  out = await sidebarText();
  assert(out.includes("No matching components"), `无匹配应显示提示 — ${out.join(" │ ")}`);
  await shot("search-empty");

  await clearSearch();
  out = await sidebarText();
  assert(out.includes("Button") && out.includes("Actions") && out.includes("Liquid Glass"), `清空后应恢复完整列表 — ${out.join(" │ ")}`);
  assert(!out.includes("No matching components"), "清空后不应残留无匹配提示");
  await switchTo("button");
});

// Same tier Input/Select/Button mixed: frame height = ControlSize derived, same-row vertical center
// aligned.
test("View DSL: each/show/match/sva 混排——增删、切页、variant 样式都留在声明位置", async () => {
  // ui.view regression anchor: list area sandwiched between toolbar and footer, three-level nesting
  // (match/show/each). Before fix, Show/Match content always appended to parent tail, page switch
  // moved list below footer.
  await switchTo("viewdsl");
  const ROOT = "story.viewdsl.root";
  const footerText = async () => labelText("story.viewdsl.footer");
  const waitFooter = async (want: string) =>
    waitFor(async () => ((await footerText()) === want ? true : null), getE2eTimeoutMs(5000), 60);

  assert((await footerText()) === "0 of 3 done", `初始 footer: ${await footerText()}`);
  // Row background sample: small block inside right edge (avoid dot and text)
  const rowBg = async (tag: string): Promise<[number, number, number]> => {
    const r = (await query("story.viewdsl.todo.1"))[0];
    assert(r?.rect != null, "第一行应存在");
    const path = `${DIR}/story-viewdsl-row1-${tag}.png`;
    assert((await screenshot(path)).ok === true, "screenshot 失败");
    return centerPixel(path, { x: r.rect.x + r.rect.w - 12, y: r.rect.y + r.rect.h / 2 - 2, w: 4, h: 4 });
  };
  await mouseMove(-10, -10); // Don't let hover style interfere with sample
  const bgBefore = await rowBg("before");

  // Click row toggle done: footer count + row background (sva done variant) both change
  const c1 = await clickTestId("story.viewdsl.todo.1");
  assert(c1.ok === true, `todo.1 click 未命中: ${JSON.stringify(c1)}`);
  await waitFooter("1 of 3 done");
  await mouseMove(-10, -10);
  await sleep(120);
  const bgDone = await rowBg("done");
  const diff = Math.max(...bgBefore.map((c, i) => Math.abs(c - bgDone[i])));
  appendLog(`  [viewdsl] row bg before=(${bgBefore.join(",")}) done=(${bgDone.join(",")}) diff=${diff}`);
  assert(diff >= 5 && bgDone[1] - bgDone[0] >= 8, `done 后行背景应切到 success_subtle（绿色通道领先），实际 diff=${diff} bg=(${bgDone.join(",")})`);

  // New: row 4 appears in list, list still above footer
  await clickText(ROOT, "Add todo");
  await waitFooter("1 of 4 done");
  const row4 = (await query("story.viewdsl.todo.4"))[0];
  const footer = (await query("story.viewdsl.footer"))[0];
  assert(row4?.rect != null && footer?.rect != null, "第 4 行与 footer 应存在");
  assert(row4.rect.y + row4.rect.h <= footer.rect.y, `新行应在 footer 之上: row4=${JSON.stringify(row4.rect)} footer=${JSON.stringify(footer.rect)}`);

  // match page-switch: stats text appears between toolbar and footer; switch back to list, list
  // restores position
  await clickText(ROOT, "Stats");
  await waitFor(async () => ((await query("story.viewdsl.stats")).length === 1 ? true : null), getE2eTimeoutMs(5000), 60);
  const stats = (await query("story.viewdsl.stats"))[0];
  assert(stats.text === "4 total / 1 done", `stats 文本: ${stats.text}`);
  const footer2 = (await query("story.viewdsl.footer"))[0];
  assert(stats.rect.y < footer2.rect.y, "stats 应在 footer 之上（区域锚点定位）");
  assert((await query("story.viewdsl.list")).length === 0, "切到 stats 后列表应卸载");

  await clickText(ROOT, "List");
  await waitFor(async () => ((await query("story.viewdsl.list")).length === 1 ? true : null), getE2eTimeoutMs(5000), 60);
  const list = (await query("story.viewdsl.list"))[0];
  const footer3 = (await query("story.viewdsl.footer"))[0];
  assert(list.rect.y + list.rect.h <= footer3.rect.y, "切回 list 后列表应在 footer 之上");

  // Clear done: todo.1 disappears, count drops
  await clickText(ROOT, "Clear done");
  await waitFooter("0 of 3 done");
  assert((await query("story.viewdsl.todo.1")).length === 0, "清除后 todo.1 应卸载");

  const path = `${DIR}/story-viewdsl-final.png`;
  const shot = await screenshot(path);
  assert(shot.ok === true, `viewdsl screenshot 失败: ${JSON.stringify(shot)}`);
  appendLog(`  [viewdsl] toggle → add → stats → list → clear OK`);
});

test("Form Composition: same-size Input/Select/Button share height and center line", async () => {
  await switchTo("formcompose");
  const expected: Record<string, number> = { xs: 20, sm: 24, md: 32, lg: 40 };
  for (const [size, h] of Object.entries(expected)) {
    const rects: Record<string, { x: number; y: number; w: number; h: number }> = {};
    for (const part of ["input", "status", "owner", "reset", "apply"]) {
      const node = (await query(`story.formcompose.${size}.${part}`))[0];
      assert(node?.rect != null, `缺 story.formcompose.${size}.${part}`);
      rects[part] = node.rect;
    }
    appendLog(`  ${size}: ${Object.entries(rects).map(([k, r]) => `${k} y=${r.y.toFixed(1)} h=${r.h.toFixed(1)}`).join(" | ")}`);
    const cy0 = rects.input.y + rects.input.h / 2;
    for (const [part, r] of Object.entries(rects)) {
      assert(Math.abs(r.h - h) < 0.5, `${size}.${part} 高度 ${r.h} ≠ ControlSize ${h}`);
      assert(Math.abs(r.y + r.h / 2 - cy0) < 0.5, `${size}.${part} 垂直中心 ${r.y + r.h / 2} 与 input ${cy0} 不齐`);
    }
    const row = (await query(`story.formcompose.${size}.row`))[0];
    const panel = (await query("story.formcompose"))[0];
    assert(row.rect.x + row.rect.w <= panel.rect.x + panel.rect.w, `${size} 工具栏超出预览区: ${JSON.stringify(row.rect)}`);
  }
  await shot("formcompose-alignment");
});

test("Form Composition: a long Select label ellipsizes in the trigger and the list keeps its check", async () => {
  await switchTo("formcompose");
  await clickTestId("story.formcompose.md.owner");
  await waitFor(async () => (await query("story.formcompose.md.owner.panel"))[0] ?? null, 2500, 40);
  await settle(250);
  await clickText("story.formcompose.md.owner.panel", "Assigned to me");
  await settle(250);
  const trigger = (await query("story.formcompose.md.owner"))[0];
  const label = findByText(trigger, "Assigned to me");
  assert(label != null, "trigger 里缺 Assigned to me 文本");
  assert(label!.x + label!.w <= trigger.rect.x + trigger.rect.w, `trigger 文本溢出: ${JSON.stringify(label)} vs ${JSON.stringify(trigger.rect)}`);
  await clickTestId("story.formcompose.md.owner");
  const panel = await waitFor(async () => (await query("story.formcompose.md.owner.panel"))[0] ?? null, 2500, 40);
  await settle(250);
  const row = findByText(panel, "Assigned to me");
  assert(row != null, "面板里缺 Assigned to me");
  // The trailing check (16px) must still fit inside the panel after the label ellipsizes.
  assert(row!.x + row!.w + 16 <= panel.rect.x + panel.rect.w, `选项文本把对勾挤出面板: ${JSON.stringify(row)} vs ${JSON.stringify(panel.rect)}`);
  // panel_width = .content: the panel sizes to its rows instead of the 150px trigger.
  assert(panel.rect.w > trigger.rect.w, `内容宽面板应比 trigger 宽: ${panel.rect.w} vs ${trigger.rect.w}`);
  await shot("formcompose-owner-ellipsis");
  await key("Escape");
  await settle(250);
});

test("Select: overflowing multi-select chips scroll sideways inside the trigger", async () => {
  await switchTo("select");
  await bringIntoView(["story.select.multi-open"]);
  await waitFor(async () => (await query("story.select.multi-open.panel"))[0] ?? null, 2500, 40);
  await settle(250);
  await clickText("story.select.multi-open.panel", "Marketing");
  await settle(250);
  const trigger = (await query("story.select.multi-open"))[0];
  const before = findByText(trigger, "Marketing");
  assert(before != null, "trigger 里缺 Marketing 标签");
  assert(before!.x + before!.w > trigger.rect.x + trigger.rect.w - 32, `三个标签应当溢出 trigger: ${JSON.stringify(before)} vs ${JSON.stringify(trigger.rect)}`);
  await scrollAt(trigger.rect.x + 60, trigger.rect.y + trigger.rect.h / 2, -400, 0);
  await settle(250);
  const scrolled = findByText((await query("story.select.multi-open"))[0], "Marketing");
  assert(scrolled!.x < before!.x - 10, `横向滚动后标签应左移: ${before!.x} -> ${scrolled!.x}`);
  await shot("select-multi-open-chips-scrolled");
  await scrollAt(trigger.rect.x + 60, trigger.rect.y + trigger.rect.h / 2, 400, 0);
  await settle(250);
  const back = findByText((await query("story.select.multi-open"))[0], "Marketing");
  assert(Math.abs(back!.x - before!.x) < 0.5, `滚回起点后标签应复位: ${before!.x} -> ${back!.x}`);
  await shot("select-multi-open-chips-start");
});

test("绘制不变式：整轮 storybook 没有任何节点在一帧里重复发射同一填充", async () => {
  // Per-frame self-check cumulative count (see ui core/paint_invariants.zig): after all stories and
  // interactions must remain 0. Non-zero = some cache replay/re-record path sent own content twice
  // (parent background covers children or layers half-transparent).
  const st = await stats();
  appendLog(`  paint_duplicate_fills(total)=${st.paint_duplicate_fills} last_node=${st.paint_duplicate_node}`);
  assert(st.paint_duplicate_fills === 0, `整轮出现 ${st.paint_duplicate_fills} 次重复发射（最近的节点 ${st.paint_duplicate_node}）；用 ZENIT_DEBUG_CMDSTREAM 看是哪帧哪个节点`);
}, { final: true }); // the counter covers everything this app instance ran before it


// Metal's per-command-buffer native counter includes the header host as well
// as the normal renderer. Exercise settled and continuously repainted frames;
// screenshots must use the same render-only retained-present path.
test("Metal render-only frames: glass, opacity, blend and lens", async () => {
  if ((await stats()).renderer_backend !== "metal") { appendLog("Metal engine gate: not applicable on this backend"); return; }
  for (const story of ["glasslab", "glassgroup", "glassmerge", "glassedge", "glassislands", "secopacity", "blend", "blendlab", "glassioslens"]) {
    await switchTo(story);
    await request("POST", "/redraw", { continuous: true });
    try {
      let previous = (await stats()).frame_count;
      for (let i = 0; i < 8; i++) {
        await request("POST", "/wait", { frames: 2 });
        const perf = await stats();
        assert(perf.frame_count > previous, `${story}: no new submitted frame`);
        previous = perf.frame_count;
        assert(perf.render_passes > 0 && perf.blit_passes === 0 && perf.compute_passes === 0,
          `${story}: engines R/B/C=${perf.render_passes}/${perf.blit_passes}/${perf.compute_passes}`);
      }
      await shot(`render-only-${story}`);
    } finally { await request("POST", "/redraw", { continuous: false }); }
  }
});

run();

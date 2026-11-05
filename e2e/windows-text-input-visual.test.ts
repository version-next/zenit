// One Windows App, driven by the host HTTP harness. PNGs stay on the host.
import { clickTestId, imeCommit, inputState, key, mouseDown, mouseMove, mouseUp, query, screenshot, sleep, waitForServerReady, runsOnWindowsWorker } from "./client";
import { decodePng } from "./png";
import { assert, getSessionDir, run, test } from "./runner";

// The text-input window is 600×620 logical. Pixel-count thresholds below were
// calibrated at 175% (1050×1085); scale them by area so 100% hardware and
// fractional-DPI guests apply the same visual criterion.
const LOGICAL_WIDTH = 600, LOGICAL_HEIGHT = 620, CALIBRATED_SCALE = 1.75;
let areaScale = 1;
function px(calibrated: number) {
  return Math.max(1, Math.round(calibrated * areaScale));
}

async function capture(name: string) {
  await sleep(100);
  const path = `${getSessionDir()}/${name}.png`;
  assert((await screenshot(path)).ok, `capture failed: ${path}`);
  const png = decodePng(path);
  const scale = png.width / LOGICAL_WIDTH;
  assert(scale >= 1 && Math.abs(png.height - LOGICAL_HEIGHT * scale) <= 2,
    `screenshot is not the DPI-scaled window: ${png.width}×${png.height}`);
  areaScale = (scale / CALIBRATED_SCALE) ** 2;
  console.log(`  ${path}`);
  return png;
}

function changedPixels(a: ReturnType<typeof decodePng>, b: ReturnType<typeof decodePng>) {
  assert(a.width === b.width && a.height === b.height && a.channels === b.channels, "capture geometry changed");
  let count = 0;
  for (let i = 0; i < a.pixels.length; i += a.channels) {
    if (a.pixels[i] !== b.pixels[i] || a.pixels[i + 1] !== b.pixels[i + 1] || a.pixels[i + 2] !== b.pixels[i + 2]) count++;
  }
  return count;
}

function inputShell(node: any): any {
  if (node?.tag === "input") return node;
  for (const child of node?.children ?? []) {
    const found = inputShell(child);
    if (found) return found;
  }
  return null;
}

function assertTextClipped(empty: ReturnType<typeof decodePng>, painted: ReturnType<typeof decodePng>, rect: any) {
  assert(empty.width === painted.width && empty.height === painted.height && empty.channels === painted.channels,
    "clipping capture geometry changed");
  const scale = painted.width / LOGICAL_WIDTH;
  let changed = 0;
  // Exclude the border/focus-ring fringe; every pixel beyond it must stay clear
  // while long text, selection and the viewport change inside the field.
  for (let y = Math.ceil(rect.y * scale); y < Math.floor((rect.y + rect.h) * scale); y++) {
    for (let x = Math.ceil((rect.x + rect.w + 4) * scale); x < painted.width; x++) {
      const i = (y * painted.width + x) * painted.channels;
      if (empty.pixels[i] !== painted.pixels[i] || empty.pixels[i + 1] !== painted.pixels[i + 1] ||
          empty.pixels[i + 2] !== painted.pixels[i + 2]) changed++;
    }
  }
  assert(changed === 0, `Input text or selection escaped its shell: ${changed} outside pixels changed`);
}

function textLine(node: any): any {
  if (typeof node?.text === "string" && node.text.length > 0) return node;
  for (const child of node?.children ?? []) {
    const found = textLine(child);
    if (found) return found;
  }
  return null;
}

function assertOverflowLeavesPaddingClear(empty: ReturnType<typeof decodePng>, painted: ReturnType<typeof decodePng>, shell: any, line: any, edge: "left" | "right") {
  assert(line && line.rect.y >= shell.rect.y && line.rect.y + line.rect.h <= shell.rect.y + shell.rect.h + 1, "Input text line must be inside the field, not its external label");
  const scale = painted.width / LOGICAL_WIDTH;
  // The lowercase fixture has a blank cap-height margin at the top of its line
  // box. A fade must hide content into the field color, never paint a dark slab
  // across this empty margin. Stay inside the border, away from the caret.
  const y = Math.ceil(line.rect.y * scale);
  let maxDelta = 0;
  for (let inset = 2; inset <= 10; inset++) {
    const x = Math.floor((edge === "left" ? shell.rect.x + inset : shell.rect.x + shell.rect.w - inset) * scale);
    const i = (y * painted.width + x) * painted.channels;
    for (let c = 0; c < 3; c++) maxDelta = Math.max(maxDelta, Math.abs(empty.pixels[i + c] - painted.pixels[i + c]));
  }
  assert(maxDelta <= 1, `Input ${edge} overflow darkened blank line padding: max channel delta=${maxDelta}`);
}

function displayed(node: any): string {
  function firstText(current: any): string | null {
    if (typeof current?.text === "string") return current.text;
    for (const child of current?.children ?? []) {
      const value = firstText(child);
      if (value !== null) return value;
    }
    return null;
  }
  if (node?.tag === "input" || node?.tag === "textarea") return firstText(node) ?? "";
  for (const child of node?.children ?? []) {
    const value = displayed(child);
    if (value) return value;
  }
  return "";
}

async function waitDisplayed(testId: string, expected: string) {
  const deadline = Date.now() + 2000;
  while (Date.now() < deadline) {
    if (displayed((await query(testId))[0]) === expected) return;
    await sleep(20);
  }
  throw new Error(`${testId} display did not reach ${JSON.stringify(expected)}`);
}

test("Windows harness ready", async () => {
  assert(runsOnWindowsWorker(), "run through tools/windows_vm_http.py e2e");
  await waitForServerReady(15000);
});

test("Input caret scrolls, selection paints, Home and End restore viewport", async () => {
  await clickTestId("input.name");
  await key("a", { ctrl: true });
  await key("backspace");
  const shell = inputShell((await query("input.name"))[0]);
  assert(shell, "Input shell missing");
  const emptyPng = await capture("windows-input-empty-clip-reference");
  await imeCommit("abcdefghijklmnopqrstuvwxyz".repeat(4));
  const end = await inputState("input.name");
  assert(end.buffer_len === 104 && end.cursor_pos === 104, "long input cursor mismatch");
  assert(end.scroll_x > 100, `caret did not scroll: ${end.scroll_x}`);
  const endPng = await capture("windows-input-end");
  assertTextClipped(emptyPng, endPng, shell.rect);
  assertOverflowLeavesPaddingClear(emptyPng, endPng, shell, textLine(inputShell((await query("input.name"))[0])), "left");
  await key("a", { ctrl: true });
  const selected = await inputState("input.name");
  assert(selected.anchor === 0 && selected.cursor_pos === 104, "Ctrl+A selection mismatch");
  const selectedPng = await capture("windows-input-selected");
  assertTextClipped(emptyPng, selectedPng, shell.rect);
  assert(changedPixels(endPng, selectedPng) > px(1000), "selection not visibly painted");
  await key("home");
  const home = await inputState("input.name");
  assert(home.cursor_pos === 0 && home.scroll_x === 0, `Home did not reset viewport: ${JSON.stringify(home)}`);
  const homePng = await capture("windows-input-home");
  assertTextClipped(emptyPng, homePng, shell.rect);
  assertOverflowLeavesPaddingClear(emptyPng, homePng, shell, textLine(inputShell((await query("input.name"))[0])), "right");
  assert(changedPixels(endPng, homePng) > px(1000), "Home did not visibly change viewport");
  await key("end");
  const restored = await inputState("input.name");
  assert(restored.cursor_pos === 104 && Math.abs(restored.scroll_x - end.scroll_x) < 1, `End did not restore viewport: initial=${JSON.stringify(end)} restored=${JSON.stringify(restored)}`);
  assertTextClipped(emptyPng, await capture("windows-input-end-restored"), shell.rect);
});

test("Textarea UTF-8 display, caret and selection stay current after edits", async () => {
  await clickTestId("input.notes");
  await key("a", { ctrl: true });
  await key("backspace");
  const before = await capture("windows-notes-empty");
  await imeCommit("你好世界");
  const state = await inputState("input.notes");
  assert(state.buffer === "你好世界" && state.cursor_pos === 12, "UTF-8 state mismatch");
  await waitDisplayed("input.notes", "你好世界");
  const after = await capture("windows-notes-unicode");
  assert(changedPixels(before, after) > px(100), "Textarea text did not visibly update");
  await key("a", { ctrl: true });
  const selection = await capture("windows-notes-selected");
  const selected = await inputState("input.notes");
  assert(selected.anchor === 0 && selected.cursor_pos === 12, "Textarea selection offsets mismatch");
  assert((selected.selection_rects?.length ?? 0) > 0, "Textarea selection geometry missing");
  assert(changedPixels(after, selection) > px(100), "Textarea selection did not visibly paint");
  await key("backspace");
  await capture("windows-notes-cleared");
  const cleared = await inputState("input.notes");
  assert(cleared.buffer_len === 0 && cleared.cursor_pos === 0, "Textarea selection deletion failed");
  assert(cleared.selection_rects?.length === 0, "Textarea retained stale selection geometry");
  await imeCommit("hello");
  await waitDisplayed("input.notes", "hello");
  await capture("windows-notes-replaced");
});

test("Input reverse selection follows viewport and Unicode edits undo and redo", async () => {
  await clickTestId("input.name");
  await key("a", { ctrl: true });
  const longText = "abcdefghijklmnopqrstuvwxyz".repeat(4);
  await imeCommit(longText);
  await key("home", { shift: true });
  const reverse = await inputState("input.name");
  assert(reverse.anchor === longText.length && reverse.cursor_pos === 0 && reverse.scroll_x === 0,
    `reverse selection did not follow Home: ${JSON.stringify(reverse)}`);
  await capture("windows-input-reverse-selection");
  await key("right");
  const collapsed = await inputState("input.name");
  assert(collapsed.anchor === -1 && collapsed.cursor_pos === longText.length && collapsed.scroll_x > 100,
    "Right did not collapse reverse selection to its end and scroll there");
  await key("home");
  await key("end", { shift: true });
  const forward = await inputState("input.name");
  assert(forward.anchor === 0 && forward.cursor_pos === longText.length && forward.scroll_x > 100,
    "forward selection did not follow End");
  await capture("windows-input-forward-selection");
  await imeCommit("A你B好C");
  await key("left", { shift: true });
  await key("left", { shift: true });
  const unicode = await inputState("input.name");
  assert(unicode.anchor === 9 && unicode.cursor_pos === 5, "selection split a UTF-8 character");
  await key("delete");
  assert((await inputState("input.name")).buffer === "A你B", "selected Unicode deletion failed");
  await key("z", { ctrl: true });
  assert((await inputState("input.name")).buffer === "A你B好C", "Unicode undo failed");
  await key("y", { ctrl: true });
  assert((await inputState("input.name")).buffer === "A你B", "Unicode redo failed");
  await capture("windows-input-unicode-redo");
});

test("Input pointer drag selects and deletes the exact range in both directions", async () => {
  await waitForServerReady(15000);
  await clickTestId("input.name");
  const value = "abcdefghijklmnopqrstuvwxyz";
  for (const reverse of [false, true]) {
    await key("a", { ctrl: true });
    await imeCommit(value);
    await key("end");
    const end = (await inputState("input.name")).cursor_rect;
    await key("home");
    const home = (await inputState("input.name")).cursor_rect;
    assert(home && end && home.w > 0 && end.w > 0 && end.x > home.x, "text endpoints missing");
    // Separate the gestures from the preceding focus click / drag so this
    // exercises drag selection rather than double-click word selection.
    await sleep(500);
    const advance = end.x - home.x;
    const left = home.x + advance * 0.15, right = home.x + advance * 0.75, y = home.y + home.h / 2;
    const from = reverse ? right : left, to = reverse ? left : right;
    assert((await mouseDown(from, y)).ok, "drag press failed");
    try {
      assert((await mouseMove((from + to) / 2, y)).ok, "drag midpoint failed");
      assert((await mouseMove(to, y)).ok, "drag endpoint failed");
    } finally {
      await mouseUp(to, y);
    }
    const state = await inputState("input.name");
    const anchor = state.anchor ?? -1;
    assert(anchor >= 0 && (reverse ? anchor > state.cursor_pos : anchor < state.cursor_pos),
      `drag direction or anchor mismatch: ${JSON.stringify(state)}`);
    const lo = Math.min(anchor, state.cursor_pos), hi = Math.max(anchor, state.cursor_pos);
    assert(lo > 0 && hi < value.length && hi - lo >= 5, "drag did not select an interior text range");
    await capture(`windows-input-drag-${reverse ? "reverse" : "forward"}`);
    await key("delete");
    const after = await inputState("input.name");
    assert(after.buffer === value.slice(0, lo) + value.slice(hi), "drag deleted a different range");
    assert(after.cursor_pos === lo && after.anchor === -1, "drag deletion left a stale selection");
  }
});

test("Windows text layout eviction restores identical Input pixels", async () => {
  await clickTestId("input.name");
  await key("a", { ctrl: true });
  await key("backspace");
  const value = "abcdefghijklmnopqrstuvwx".repeat(13);
  await imeCommit(value);
  const baseline = await capture("windows-layout-cache-before-eviction");
  // Each deletion produces a different single-line layout. This exceeds the
  // native 256-entry cache and evicts the original value while labels stay hot.
  for (let i = 0; i < 300; i++) assert((await key("backspace")).ok, "delete failed");
  const shortened = await inputState("input.name");
  assert(shortened.buffer === value.slice(0, 12), "deletion state is stale");
  await key("a", { ctrl: true });
  await imeCommit(value);
  const restored = await inputState("input.name");
  assert(restored.buffer === value && restored.cursor_pos === value.length, "cache churn corrupted restored input");
  const after = await capture("windows-layout-cache-after-eviction");
  // Ignore a small caret blink difference while requiring all text/viewport
  // pixels to return to the same image after the evicted layout is recreated.
  const changed = changedPixels(baseline, after);
  assert(changed < px(500), `restored layout changed ${changed} pixels after eviction`);
});

run();

import { clickTestId, query, request, screenPos, screenshot, stats, waitFor, waitForServerReady } from "./client";
import { appendLog, assert, getSessionDir, run, test } from "./runner";

// Hover liveness with REAL Win32 input on the acceptance machine (tools/windows_batch.py stage
// `hover-native`, --allow-foreground, ZENIT_E2E_ISOLATE_POINTER=0). The owned receiver window
// (tools/windows_native_input.ps1) is another process's window: it takes activation and covers
// the resting cursor. The native Win32 facts these expectations rest on are measured by the
// `hover-probe` stage (tools/windows_hover_probe.c).

async function native(body: Record<string, unknown>) {
  const result = await request("POST", "/windows/native-input", body);
  assert(result.ok !== false && !result.error, `native-input ${body.action} failed: ${JSON.stringify(result)}`);
  return result;
}
async function hover() {
  return (await stats()).hover!;
}
async function waitHover(predicate: (h: any) => boolean, label: string) {
  try {
    return await waitFor(async () => { const h = await hover(); return predicate(h) ? h : null; }, 5000);
  } catch {
    throw new Error(`${label}: ${JSON.stringify(await hover())}`);
  }
}
async function offsetY() {
  const nodes = await query("story.scrolling.vertical.status");
  const match = /y=(-?\d+)/.exec(JSON.stringify(nodes));
  assert(match != null, "missing scrolling status");
  return Number(match![1]);
}
/** The vertical-list row whose rect contains y (geometry is the authority). */
async function rowAt(y: number): Promise<string | null> {
  const tree = await query("story.scrolling.vertical");
  let found: string | null = null;
  const walk = (n: any) => {
    if (typeof n?.test_id === "string" && /^story\.scrolling\.vertical\.row\.\d+$/.test(n.test_id) && n.rect &&
      y >= n.rect.y && y < n.rect.y + n.rect.h) found = n.test_id;
    for (const c of n?.children ?? []) walk(c);
  };
  walk(tree[0]);
  return found;
}

test("Windows hover: inactive window wheel-scroll, covering window, uncover and leave", async () => {
  await waitForServerReady(15000);
  assert((await clickTestId("nav.scrolling")).ok, "scrolling navigation failed");
  assert((await clickTestId("story.scrolling.vertical.reset")).ok, "reset failed");
  await native({ action: "activate" });
  await native({ action: "receiver-start", operations: 1, logical: false });
  await waitFor(async () => ((await request("POST", "/windows/native-input", { action: "receiver-status" })).ready ? true : null), 5000);
  const r = await screenPos("story.scrolling.vertical.row.02");
  const p = { x: r.x + 40, y: r.y + r.h / 2 };
  try {
    // Real WM_MOUSEMOVE onto Row 02 of the active window.
    await native({ action: "hover-pointer-at", x: p.x, y: p.y });
    await waitHover((h) => h.test_id === "story.scrolling.vertical.row.02" && h.pointer_live, "pointer rests on Row 02");

    // Another process takes the foreground: the App is inactive, hover stays.
    await native({ action: "receiver-activate" });
    const status = await request("POST", "/windows/native-input", { action: "status" });
    assert(status.foreground === false, `App must be inactive: ${JSON.stringify(status)}`);
    let h = await waitHover((x) => x.test_id === "story.scrolling.vertical.row.02", "deactivation keeps hover");

    // Real wheel over the inactive window under the resting cursor (Windows routes it to the
    // window under the cursor by default): content scrolls and hover follows the row under it.
    const changes = h.reconcile_changes;
    await native({ action: "hover-wheel", delta: -120 });
    await waitFor(async () => ((await offsetY()) === 40 ? true : null), 5000);
    const under = await rowAt(p.y);
    h = await waitHover((x) => x.test_id === under && x.reconcile_changes > changes, `inactive wheel: hover follows ${under}`);
    appendLog(`  inactive wheel: y=40, row under pointer ${under}, hovered ${h.test_id}`);
    assert((await screenshot(`${getSessionDir()}/hover-inactive-wheel.png`)).ok, "screenshot failed");

    // The receiver is ordered over the resting cursor: WM_MOUSELEAVE -> pointer_left clears hover.
    await native({ action: "receiver-cover", x: p.x, y: p.y });
    h = await waitHover((x) => x.test_id === null && !x.pointer_over_content && !x.pointer_live, "covered: hover cleared");
    assert((await screenshot(`${getSessionDir()}/hover-covered.png`)).ok, "screenshot failed");

    // It moves away: Windows re-delivers WM_MOUSEMOVE at the resting cursor; hover returns.
    await native({ action: "receiver-uncover", x: p.x, y: p.y });
    h = await waitHover((x) => x.test_id === under && x.pointer_live, `uncovered: ${under} hovers again`);

    // The cursor moves onto the receiver (another process's window): leave.
    await native({ action: "receiver-move" }).catch(async () => {
      // receiver-move requires the App in the foreground.
      await native({ action: "activate" });
      await native({ action: "receiver-move" });
    });
    await waitHover((x) => x.test_id === null && !x.pointer_over_content, "cursor off the App: hover cleared");
  } finally {
    await request("POST", "/windows/native-input", { action: "receiver-stop" });
  }
});

run();

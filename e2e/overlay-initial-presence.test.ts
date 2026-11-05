/// Overlays mounted open show their open state at once, and leave with their page.
///
/// A popover whose `open` is already true when its component mounts (a story entered with an open
/// DatePicker) is the open result, not an opening: its first visible frame is fully opaque, with
/// no enter transition. A later close still plays the exit
/// transition (unit tests in src/ui/components/popover/tests.zig).
import { clickTestId, mouseDown, mouseUp, readFrameObservation, screenPos, startFrameObservation, waitForServerReady, sleep } from "./client";
import { assert, appendLog, run, test } from "./runner";

async function observeEntry(storyKey: string, testId: string) {
  assert((await clickTestId("nav.button")).ok === true, "failed to leave to nav.button");
  await sleep(400);
  const started = await startFrameObservation(testId, undefined, `nav.${storyKey}`);
  assert(started.supported, "frame observation unsupported");
  await sleep(700);
  return readFrameObservation();
}

test("an overlay mounted open shows its open state on its first visible frame", async () => {
  await waitForServerReady();
  const obs = await observeEntry("datepicker", "story.datepicker.open.panel");
  const visible = obs.frames.filter((f) => (f.effective_opacity ?? f.opacity ?? 0) > 0.001);
  appendLog(`frames=${obs.frames.length} visible=${visible.length} first=${JSON.stringify(visible.slice(0, 6).map((f) => [Math.round(f.ms), (f.effective_opacity ?? f.opacity)?.toFixed(3)]))}`);
  assert(visible.length > 0, "open DatePicker panel never became visible");
  const first = visible[0].effective_opacity ?? visible[0].opacity ?? 0;
  assert(first > 0.999, `first visible frame opacity ${first.toFixed(3)}: the open panel played an enter transition`);
});

test("a click that leaves the page removes its open overlay without an exit fade", async () => {
  await waitForServerReady();
  assert((await clickTestId("nav.button")).ok === true, "failed to leave to nav.button");
  await sleep(300);
  assert((await clickTestId("nav.datepicker")).ok === true, "failed to enter nav.datepicker");
  await sleep(600);
  // A real press on the nav item: outside the open panel, dismissing it on release; the same
  // release navigates and unmounts the page.
  const nav = await screenPos("nav.button");
  const started = await startFrameObservation("story.datepicker.open.panel");
  assert(started.supported, `frame observation unsupported: ${JSON.stringify(started)}`);
  assert((await mouseDown(nav.x + nav.w / 2, nav.y + nav.h / 2)).ok, "mouse down on nav.button failed");
  await sleep(150);
  assert((await mouseUp(nav.x + nav.w / 2, nav.y + nav.h / 2)).ok, "mouse up on nav.button failed");
  await sleep(600);
  const obs = await readFrameObservation();
  const alpha = (f: { opacity?: number; effective_opacity?: number }) => f.effective_opacity ?? f.opacity ?? 0;
  appendLog(`leave frames=${JSON.stringify(obs.frames.map((f) => [Math.round(f.ms), alpha(f).toFixed(3)]))} missing=${obs.missing}`);
  assert(obs.frames.length > 0, "the panel was not observed before the click");
  const partial = obs.frames.filter((f) => alpha(f) > 0.001 && alpha(f) < 0.999);
  assert(partial.length === 0, `the open panel faded out over ${partial.length} frames as its page unmounted`);
});

run();

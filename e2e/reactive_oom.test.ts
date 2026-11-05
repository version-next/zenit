import { clickTestId, health, query, request, screenshot, sleep, waitFor, waitForServerReady } from "./client";
import { assert, appendLog, getSessionDir, run, test } from "./runner";

test("reactive propagation OOM: one committed write updates the real navigation UI", async () => {
  await waitForServerReady();
  await clickTestId("nav.button");
  await waitFor(async () => (await query("storybook.title"))[0]?.text === "Button" ? true : null);
  assert((await screenshot(`${getSessionDir()}/before.png`)).ok, "baseline capture failed");
  const fault = await request("POST", "/review/reactive-propagation-oom", {});
  appendLog(`fault: ${JSON.stringify(fault)}`);
  assert(fault.allocation_failed && fault.source === fault.target, "failed to commit the faulted write");
  await sleep(500);
  const after = (await query("storybook.title"))[0];
  const panel = (await query("story.emoji.control"))[0];
  appendLog(`after: title=${after?.text} emoji_panel=${!!panel}`);
  assert((await screenshot(`${getSessionDir()}/after.png`)).ok, "recovery capture failed");
  assert(after?.text === "Emoji", `committed navigation write left stale title: ${after?.text}`);
  assert(panel != null && panel.rect.w > 10, "committed write did not mount the Emoji panel");
  assert((await health()).status === "ok", "app died during reactive recovery");
});
run();

import { clickTestId, resetTiming, scrollAt, sleep, stats, tree, waitForServerReady } from "./client";
import { assert, run, test } from "./runner";

test("Windows timing reports CPU work and rejects unreliable GPU samples", async () => {
  await waitForServerReady(15000);
  assert((await clickTestId("nav.datatable")).ok, "datatable navigation failed");
  await sleep(700);
  const viewport = (await tree()).rect;
  await resetTiming();
  for (let i = 0; i < 40; i++) {
    // The navigation sidebar scrolls (the datatable page itself has nothing to
    // scroll, and a wheel that moves nothing renders no frame).
    await scrollAt(120, viewport.h/2, 0, i < 20 ? -60 : 60);
    await sleep(25);
  }
  const measured = await stats();
  console.log(`  Windows timing: ${JSON.stringify(measured)}`);
  assert((measured.cpu_timing_samples ?? 0) >= 30, "CPU timing has too few real rendered frames");
  assert(measured.cpu_frame_us > 0 && measured.cpu_p95_us > 0, "CPU frame timing is empty");
  assert(measured.total_frame_us >= measured.cpu_frame_us, "total frame time excludes CPU work");
  assert(measured.gpu_encode_us > 0, "native encode timing is empty");
  if (measured.timing_samples > 0) {
    assert(measured.gpu_execute_us > 0 && measured.gpu_p95_us > 0, "valid GPU samples have no timestamp duration");
  } else {
    assert(measured.gpu_timing_query_supported === false || (measured.gpu_timing_disjoint_samples ?? 0) + (measured.gpu_timing_failed_samples ?? 0) > 0,
      "GPU produced neither reliable samples nor rejection diagnostics");
    assert(measured.gpu_execute_us === 0 && measured.gpu_p95_us === 0, "CPU timing was substituted for invalid GPU timing");
  }
  await resetTiming();
  const fresh = await stats();
  console.log(`  Windows timing after reset: ${JSON.stringify(fresh)}`);
  assert((fresh.cpu_timing_samples ?? Infinity) < (measured.cpu_timing_samples ?? 0), "CPU samples survived scenario reset");
  assert(fresh.timing_samples < (measured.cpu_timing_samples ?? 0), "old GPU samples survived scenario reset");
});

run();

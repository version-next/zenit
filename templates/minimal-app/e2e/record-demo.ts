import { mkdir } from "node:fs/promises";
import { dirname, resolve } from "node:path";

import {
  type WindowRecordingState,
  mouseDown,
  mouseMove,
  mouseUp,
  screenPos,
  sleep,
  startWindowRecording,
  stopWindowRecording,
  waitForServerReady,
} from "../zig-out/share/zenit/harness/client.ts";

await waitForServerReady();

const output = resolve(process.argv[2] ?? "artifacts/minimal-app.mp4");
await mkdir(dirname(output), { recursive: true });

const started = await startWindowRecording(output, { fps: 60 });
if (!started.ok) throw new Error(started.error ?? "recording did not start");

let stopped: WindowRecordingState;
try {
  const button = await screenPos("counter.increment");
  const x = button.x + button.w / 2;
  const y = button.y + button.h / 2;

  await mouseMove(x, y);
  await sleep(500);

  for (let i = 0; i < 3; i += 1) {
    await mouseDown(x, y);
    await sleep(180);
    await mouseUp(x, y);
    await sleep(420);
  }

  await sleep(800);
} finally {
  stopped = await stopWindowRecording();
}

if (!stopped.ok) throw new Error(stopped.error ?? "recording did not stop cleanly");

console.log(
  `recorded ${stopped.frame_count} frames at ${stopped.width}x${stopped.height} ` +
    `(${stopped.dropped_frames} encoder drops): ${stopped.path}`,
);

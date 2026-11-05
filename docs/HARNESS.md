# Automation Harness

Zenit's Harness lets an external Bun/TypeScript process inspect and drive a
Zenit application. On macOS it can also record the application's completed
Metal drawable directly to H.264/MP4. The recording contains the native Retina
application content and Zenit's virtual cursor, but not the desktop, title bar,
physical cursor, or macOS screen-sharing indicator.

Harness is developer tooling. It is disabled in normal builds and does not
require Screen Recording permission.

## Build wiring

Zig dependency build options are isolated from the parent project. A consumer
must expose its own options and forward them to Zenit:

```zig
const test_mode =
    b.option(bool, "test-mode", "Enable the Zenit automation harness")
    orelse false;
const e2e_port =
    b.option(u16, "e2e-port", "Zenit Harness RPC directory suffix")
    orelse 19816;

const zenit_dep = b.dependency("zenit", .{
    .target = target,
    .optimize = optimize,
    .@"test-mode" = test_mode,
    .@"e2e-port" = e2e_port,
});

zenit.attach(zenit_dep, exe);
zenit.installHarnessClient(b, zenit_dep);
```

`installHarnessClient` places the typed client at the stable install-prefix
path `share/zenit/harness/client.ts`. With the default prefix, an
`e2e/record.ts` script imports it as:

```ts
import {
  waitForServerReady,
  startWindowRecording,
  stopWindowRecording,
} from "../zig-out/share/zenit/harness/client.ts";
```

## Launch and connect

Build the application with Harness enabled:

```bash
zig build -Dtest-mode=true
```

Give the app and controller the same private file-RPC directory. Use a unique
directory for each concurrently running app:

```bash
rpc_dir="$(mktemp -d /tmp/myapp-e2e.XXXXXX)"
ZENIT_E2E_FILE_RPC_DIR="$rpc_dir" ./zig-out/bin/myapp
```

In another terminal:

```bash
ZENIT_E2E_FILE_RPC_DIR="$rpc_dir" bun run e2e/record.ts
```

The environment variable must be set independently in both terminals. An
alternative is to use the default `/tmp/zenit_e2e_rpc_<e2e-port>` directory.

## Input isolation on a shared machine

The harness injects input directly into `ui.Cx`, bypassing the OS. Physical
input from a person using the same machine would otherwise race the injected
events: a moved mouse overwrites the injected hover position, and physical
typing reaches the focused control (space toggles a focused checkbox, Enter
submits a focused input). Two opt-in environment variables drop OS input in
test-mode builds only; harness injection and manual operation of a normal
(non-test-mode) app are unaffected:

```bash
ZENIT_E2E_ISOLATE_POINTER=1   # drop OS mouse move/button/wheel/magnify (default in run_storybook_e2e.sh)
ZENIT_E2E_ISOLATE_KEYBOARD=1  # additionally drop OS key / text_input / IME events
```

Pointer isolation also has a `ZENIT_E2E_BACKGROUND`-driven default on the
Windows worker; keyboard isolation is explicit-only. Window focus, resize and
drag-and-drop sessions are never isolated.

On macOS and Windows, keyboard isolation also drops native keyboard events
before menu accelerators, keyboard window-management actions and IME handling.
The gate is per window and is configured only by test-enabled runtimes.
Programmatic menu actions, mouse-driven window controls and contract injection
remain available. This does not lock the OS keyboard or suppress system-wide
shortcuts. Native-message contracts must explicitly seed owned input rather
than relying on OS keyboard messages while isolation is enabled.

On macOS, `bash scripts/run_storybook_e2e.sh` defaults to background
rendering for `e2e/storybook.test.ts`. Storybook still submits real Metal
frames while another app uses the desktop. Set `ZENIT_E2E_BACKGROUND=0` to
launch the suite in the foreground for inspection. Other test files keep
their requested window mode.

## Select a screenshot window

`GET /windows` returns `{ windows: [{ window_id, native_id, bound, closing }] }`.
`window_id` is a string token for one window instance, unique within a process
session; restarting the app changes the session. `native_id` is a diagnostic
string, not an accepted screenshot identity. Closing and recreating a native
window never reuses its harness identity.

```ts
const { windows: targets } = await windows();
await screenshot("artifacts/secondary.png", targets[1].window_id);
```

The equivalent request is `POST /screenshot` with
`{ "path": "artifacts/secondary.png", "window_id": "<token>" }`. Omitting
`window_id` keeps the currently bound window behavior. An explicit target is
resolved on the UI thread and captured directly from its submitted surface;
it does not activate the window or change the input/tree binding. Windows
capture retains the worker's BMP-to-PNG conversion.

Errors keep the `error` text field and add `code`: `invalid-window-id`,
`window-not-found`, `window-closing`, `no-bound-target`, `capture-unsupported`,
or `capture-failed`. A stale or closing target never falls back to another
window. Successful replies retain `{ "ok": true, "path": "..." }`.
Input, tree inspection, recording, and `frames_*` retain their existing
binding semantics; this selector applies only to screenshots.

## Record the application surface

```ts
import { mkdir } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import {
  waitForServerReady,
  startWindowRecording,
  stopWindowRecording,
  clickTestId,
  sleep,
} from "../zig-out/share/zenit/harness/client.ts";

await waitForServerReady();

const output = resolve("artifacts/run.mp4");
await mkdir(dirname(output), { recursive: true });

const started = await startWindowRecording(output, { fps: 60 });
if (!started.ok) throw new Error(started.error);

let stopped;
try {
  await clickTestId("save-button");
  await sleep(1000);
} finally {
  stopped = await stopWindowRecording();
}

if (!stopped.ok) throw new Error(stopped.error);
console.log(stopped);
```

The output path must be absolute, end in `.mp4`, and have an existing parent
directory. FPS may be 1 through 120. `stopWindowRecording` returns only after
the MP4 is finalized. Do not resize the window during a recording; start a new
recording after a resize instead.

Pointer, text, IME, scroll, and drag Harness commands automatically update the
rendered virtual cursor. Its arrow, pointing-hand, I-beam, pressed, and grabbing
states therefore appear in the video without capturing the physical cursor.

## Paint invariant

In test mode every rendered frame is checked for one node emitting an identical
filled or stroked rectangle twice (same geometry, colour, radius, shape and
stroke width). That is the
signature of a cache-replay path emitting a node's own content a second time:
the extra copy usually lands after the children, so an opaque background covers
them and a translucent one darkens them, for a single frame that screenshot
comparisons do not catch. `/stats` reports the running total as
`paint_duplicate_fills` and the most recent offender as `paint_duplicate_node`;
the storybook suite asserts the total stays 0 after visiting every story, and
the `paintreplay` story reproduces the conditions (an `overflow_hidden`
container with a background and children, outside any scroll area, whose
siblings change). To find the frame and node, rerun with
`ZENIT_DEBUG_CMDSTREAM=1`.

## Runtime integration

Applications using `App.runWith` need no application-code changes. A custom
event loop must call `zenit_app.drainTestCommands()` once per iteration after
processing platform events.

`App.mount` binds Harness to that window. If auxiliary windows are mounted
after the main window, call `main_app.rebindTestHarness()` after creating them
to make the intended main window the automation and recording target.

## Production boundary

Do not pass `-Dtest-mode=true` to release builds. A normal build compiles out
Harness initialization and exposes no file-RPC automation endpoint. The native
recording bridge may still be linked as framework infrastructure, but it is not
registered or reachable without Harness mode.

### Linux native window controls

`POST /window` runs native window operations on the application's UI thread.
The body is `{ "action": "status" }` (default), `maximize`, `restore`, `minimize`,
or `close`. The response reports `decorated`, external `decoration_height`,
compositor `maximized`, `active`, `suspended`, and logical content dimensions.
Requests acknowledge dispatch, not compositor completion: poll status after
maximize/restore. Minimize has no portable Wayland acknowledgement; verify the
compositor image. Close uses the native decoration callback and normal teardown.
Unsupported platforms return an error.

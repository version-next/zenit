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

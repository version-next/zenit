# zenit examples

Ten small applications demonstrating different facets of the framework. **Every one is wired in `build.zig` to use only `ui` and `zenit_app` modules** — they double as the build-time fence that enforces the [open-source boundary](../docs/UI_OSS_BOUNDARY.md).

| example | what it shows | LOC | binary |
|---|---|---|---|
| [`hello_button/`](hello_button/) | Minimal Button + state via `cx.bindState` + `cx.on` | 81 | 5.5 MB |
| [`counter_reactive/`](counter_reactive/) | `Signal` + `Memo` + `createEffect` (responsive UI without manual updates) | 129 | 5.5 MB |
| [`virtual_list_perf/`](virtual_list_perf/) | 100k-row `VirtualList` (constant cost regardless of dataset size) | 100 | 5.4 MB |
| [`text_input/`](text_input/) | `Input` and `Textarea`, including IME (CJK) support — exercises `text_core` integration | 85 | 6.0 MB |
| [`multi_window/`](multi_window/) | Public `MultiWindowApp`: two native windows, isolated routing, single/last-window teardown | ~190 | varies |
| [`storybook/`](storybook/) | Complete component showcase and real-window E2E target | — | varies |
| [`console_probe/`](console_probe/) | `ui.console` diagnostic Console + DevTools console panel verification target | 113 | varies |
| [`devtools_probe/`](devtools_probe/) | DevTools performance panel real-window acceptance probe | 176 | varies |
| [`interop_probe/`](interop_probe/) | Rich clipboard / drag-out real-system interop verification target | 107 | varies |
| [`design_probe/`](design_probe/) | Pixel-accurate rebuild of a pencil design node, for numeric design-diff verification | 103 | varies |

## Run them

```bash
zig build hello-button         # build .app bundle (ad-hoc signed)
zig build run-hello-button     # run unbundled

zig build counter-reactive
zig build run-counter-reactive

zig build virtual-list-perf
zig build run-virtual-list-perf

zig build text-input
zig build run-text-input

zig build multi-window
zig build run-multi-window

zig build storybook
zig build run-storybook
```

After building, each example produces `zig-out/<Display Name>.app` you can double-click.

## Why so small?

5–6 MB for a complete `.app` bundle that draws a window, lays out widgets, handles input, and renders via Metal. There's no language toolchain, no editor engine, no workspace persistence — just the GUI. That's the boundary: "I want a button" should not pull a language server.

## Why are the single-window examples so similar?

All single-window examples follow the same skeleton:

```zig
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const app = try App.init(gpa.allocator(), .{ .window = .{ ... } });
    defer app.deinit();

    try app.runWith(mountUI); // mountUI: fn(*ui.Cx, *ui.Scope) !*ui.Node
}
```

`App.init` does NSApplication setup + window creation + GPU surface + font
loading + UI Cx wiring in a single call. `App.runWith(mountUI)` then creates
the root reactive `Scope`, calls your `mountUI` to build the initial tree,
attaches it to `cx`, and runs the event loop until the window closes. The
differences between examples live entirely inside `mountUI()`.

Multi-window applications use `MultiWindowApp.createWindowWith` and one
application loop. It routes each native event/menu command to the matching
window and owns safe per-window teardown. Low-level `App` fields (`cx`, `sdk`,
`renderer`, `font_selector`, etc.) remain public for genuinely custom host loops.

For a real-window lifecycle smoke (requires a logged-in macOS WindowServer):

```bash
bash scripts/run_multiwindow_smoke.sh 120
```

## Adding a new example

1. Create `examples/your_example/main.zig`.
2. Add an entry to the `examples` array in `build.zig` (look for `"hello_button"`).
3. Run `bash scripts/check_oss_boundary.sh` to confirm the boundary is still intact.

Imports must stay limited to `@import("ui")` and `@import("zenit_app")`. If an example reaches for a language toolchain or a richer document model, it's application code, not framework code — keep it out of this directory.

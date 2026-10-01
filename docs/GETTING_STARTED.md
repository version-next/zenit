# Getting Started with zenit

This guide walks through building a real, runnable zenit application in a
fresh project, independent of the zenit repository.

If you only want to play with the bundled examples, skip ahead to the
"Running the bundled examples" section at the end.

## 1. Create a project

```bash
mkdir myapp && cd myapp
```

Copy the [`templates/minimal-app/`](../templates/minimal-app/) directory from
zenit into your project root. It contains:

```
myapp/
├── build.zig          # uses zenit.attach()
├── build.zig.zon      # declares zenit dep
├── e2e/record-demo.ts # optional Harness recording example
└── src/main.zig       # counter app
```

After copying, adjust the `.path` in `build.zig.zon` to wherever your zenit
checkout actually lives relative to the new location, e.g. if `myapp/` sits
next to the zenit checkout, use `.path = "../zenit"`.

## 2. Wire the dependency

In `build.zig.zon`:

```zig
.dependencies = .{
    // Local dev against a working copy of zenit (recommended while the
    // upstream API is unstable):
    .zenit = .{ .path = "../zenit" },

    // Or pin a specific revision (replace <fork> and <rev>; the easiest way
    // to get the hash is `zig fetch --save=zenit <url>` after pushing):
    // .zenit = .{
    //     .url = "https://github.com/<fork>/zenit/archive/<rev>.tar.gz",
    //     .hash = "...",
    // },
},
```

`zig build` will resolve the dependency and cache it.

## 3. Wire the build

zenit's root `build.zig` is a public build API: once `.zenit` is declared in
your `build.zig.zon`, `const zenit = @import("zenit");` works at the top of
your `build.zig` (Zig 0.15.2), and a single `zenit.attach(zenit_dep, exe)`
call wires everything: the `ui` / `zenit_app` module imports, the five macOS
native ObjC bridges, and the system frameworks:

```zig
const std = @import("std");
const zenit = @import("zenit");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_mode = b.option(bool, "test-mode", "Enable the Zenit automation harness") orelse false;
    const e2e_port = b.option(u16, "e2e-port", "Zenit Harness RPC directory suffix") orelse 19816;

    const zenit_dep = b.dependency("zenit", .{
        .target = target,
        .optimize = optimize,
        .@"test-mode" = test_mode,
        .@"e2e-port" = e2e_port,
    });

    const exe = b.addExecutable(.{
        .name = "myapp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    zenit.attach(zenit_dep, exe);
    zenit.installHarnessClient(b, zenit_dep);

    b.installArtifact(exe);
}
```

This public setup defaults to the ISC-licensed Lucide provider. Icon selection
is part of the dependency build graph and never rewrites Zenit source files.
Reusable framework/package code should use `ui.system_icons.<semantic_name>`;
application artwork can use the complete Lucide catalog through `ui.icons`.

If you want to see (or customize) the manual wiring, read `attach` /
`addNativeLibs` in zenit's `build.zig`. It is the same boilerplate this
helper replaces.

The forwarded Harness options default to disabled and do not affect production
builds. `installHarnessClient` puts the optional TypeScript controller at a
stable path under `zig-out`; see [`HARNESS.md`](HARNESS.md) for automated input,
virtual cursor, screenshot, and application-surface recording examples.

## 4. Application code

Two `@import` lines and a `mountUI` callback:

```zig
const std = @import("std");
const ui = @import("ui");
const App = @import("zenit_app").App;

fn mountUI(cx: *ui.Cx, scope: *ui.Scope) anyerror!*ui.Node {
    const root = try ui.box(cx, .{
        .width = .{ .grow = .{} }, .height = .{ .grow = .{} },
        .align_items = .center, .justify = .center,
    }, .{});

    try root.appendChild(cx.allocator, try ui.text(cx, "Hello, zenit!", .{
        .font_size = 24,
    }));

    return root;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const app = try App.init(gpa.allocator(), .{
        .window = .{ .width = 640, .height = 480, .title = "myapp" },
    });
    defer app.deinit();

    try app.runWith(mountUI);
}
```

`App.runWith(mountUI)` covers:
- Creating the root reactive `Scope` and binding it to the `Cx`
- Calling your `mountUI` once to build the initial tree
- Setting `cx.root` and `cx.is_mounted`
- Running the event loop until the window closes

You only ever write `mountUI`. Anything imperative (cursor, focus, drawing,
GPU surface configuration, font fallback) is internalized.

## 5. State and event handlers

The recommended path uses `cx.bindState` + `cx.on`, with no manual state ids:

```zig
const Counter = struct {
    n: u32 = 0,
    label: ?*ui.Node = null,
    buf: [32]u8 = undefined,

    pub fn increment(self: *Counter) void {
        self.n += 1;
        const node = self.label orelse return;
        const content = std.fmt.bufPrint(&self.buf, "Clicked {d} times", .{self.n}) catch return;
        if (node.getText()) |old| {
            var t = old;
            t.content = content;
            node.setText(t);
        }
        node.markRenderDirty();
    }
};

fn mountUI(cx: *ui.Cx, scope: *ui.Scope) anyerror!*ui.Node {
    const counter = try cx.bindState(Counter, .{});
    const click = cx.on(Counter, counter, Counter.increment);
    // ... use `click` as `on_click` on a Button ...
}
```

`cx.bindState(T, init)` allocates a stable `*T`. The returned pointer survives
across frames; pass it to `cx.on(T, ptr, T.method)` to get a typed click
handler.

**Lifetime caveat**: the framework frees the `T` allocation itself, but it does
**not** call `T.deinit()`. If your state owns heap resources (ArrayList,
HashMap, allocated buffers), register cleanup explicitly or they will leak:

```zig
const Canvas = struct {
    items: std.ArrayList(Item) = .empty,
    pub fn deinit(self: *Canvas) void { self.items.deinit(my_allocator); }
};
const canvas = try cx.bindState(Canvas, .{});
try scope.onCleanup(Canvas, canvas, Canvas.deinit); // ← without this, `items` leaks
```

If your app needs to look up state by a stable identifier across mount cycles
(e.g. routing, hot-reload), use the lower-level `cx.state(T, id, init)` API,
which is the explicit form `bindState` builds on top of.

## 6. Reactive state (Signal / Memo / Effect)

For UI that derives from a value, use the reactive primitives instead of
manual `markRenderDirty`:

```zig
const count = try scope.createSignal(u32, 0);
const doubled = try scope.createMemo(u32, .{ .count = count }, struct {
    fn compute(ctx: anytype) u32 { return ctx.count.get() * 2; }
}.compute);

// `textFmt` binds the signals directly: the node re-renders itself whenever
// any signal it reads changes. No manual effect, buffer or dirty-marking.
try root.appendChild(allocator, try ui.textFmt(
    cx, scope, "count = {d}", .{count}, .{},
));
try root.appendChild(allocator, try ui.textFmt(
    cx, scope, "doubled = {d}", .{doubled}, .{},
));
```

Whenever `count.set(...)` runs, the bound text updates automatically. This is
the pattern in [`examples/counter_reactive/`](../examples/counter_reactive/).

If you do need to drive a node imperatively, use the text accessors rather
than touching fields: `Node` exposes `getText()` / `setText()` /
`setTextContent()`, not a public `text` field:

```zig
try label.setTextContent(allocator, "count = 1");
```

Both setters schedule repaint automatically. Changes to text or font metrics also
remeasure the node and its parent layout; color-only changes only repaint. When
using borrowed content or spans, call `setText()` after mutating their bytes.
Repeated writes with the same content and properties do not schedule more work.

## 7. Bundling (.app on macOS)

`zenit.bundleApp` produces a complete `.app`:

```zig
if (target.result.os.tag == .macos) {
    const bundle = zenit.bundleApp(b, .{
        .exe = exe,
        .display_name = "My App",
        .bundle_id = "com.example.myapp",
        .version = "0.1.0",
        .signing = .ad_hoc,
        .clear_quarantine = true,
    });
    const app_step = b.step("app", "Build .app bundle");
    app_step.dependOn(bundle.final_step);
}
```

Ad-hoc signing works out of the box; Developer ID signing / notarization
docs are planned.

## 8. Inspecting your UI

When something doesn't look the way you expect, the inspector overlay is
the fastest way to see why. One line in your `mountUI` turns it on:

```zig
fn mountUI(cx: *ui.Cx, scope: *ui.Scope) anyerror!*ui.Node {
    const root = try ui.box(cx, .{ ... }, .{});
    // ... build your tree ...

    // Optional, dev only: dashed-rect hover highlighting + dimension label.
    _ = try ui.devtools.overlay.attach(cx, scope, root, .{});

    return root;
}
```

Now hovering over any node draws a cyan dashed rectangle around it and
shows `120 × 32  Button` (dimensions and component name) just above. The
overlay does not intercept pointer events (`hit_behavior = .pass_through`),
so clicks/scrolls go through to the real node.

Common uses:

- **"Why isn't this aligned?"**: hover at the suspect spot and read the
  rect. Often the parent's padding/gap is off, not the child.
- **"What component am I looking at?"**: the label shows
  `component_name`, which widget builders set automatically (`"Button"`,
  `"Popover"`, `"DatePicker"`, ...).
- **"Why is this huge invisible area capturing clicks?"**: hover over it.
  An overflow node or absolute-positioned overlay will become obvious.

You can pass a custom config:

```zig
_ = try ui.devtools.overlay.attach(cx, scope, root, .{
    .border_color = ui.Color.rgba(255, 80, 80, 220), // red instead of cyan
    .border_width = 2.0,
    .label_bg = ui.Color.rgba(0, 0, 0, 230),
});
```

For the heavier "elements / components / performance" tabs (a separate
window with state inspection), use `ui.devtools.mountPanel` instead; it's
designed to live in a second window mounted alongside the app you're
debugging.

## Running the bundled examples

If you cloned the zenit repo itself and just want to see things move:

```bash
zig build run-hello-button
zig build run-counter-reactive
zig build run-virtual-list-perf
zig build run-text-input
```

Or build a signed `.app`:

```bash
zig build hello-button
open "zig-out/Hello Button.app"
```

Each of the four examples is wired in `build.zig` with **only** `ui` and
`zenit_app` as imports, so they double as the build-time fence enforcing the
[open-source boundary](UI_OSS_BOUNDARY.md).

## Troubleshooting

### Build / setup

| Symptom | Likely cause / fix |
|---|---|
| `zig version too old` | zenit needs `0.15.2`; check `build.zig.zon`. |
| `framework not found: Cocoa` | Install Xcode Command Line Tools (`xcode-select --install`). |
| `error: import of file outside module path` running `zig test` on a single file | zenit modules use relative `@import("../X.zig")` paths. Run tests via `zig build test-ui` (or whichever step), not standalone `zig test`. |
| `@import("zenit")` fails in your `build.zig` | Works on Zig 0.15.2, but only when `.zenit` is declared in your `build.zig.zon` dependencies. Check the dep is named exactly `zenit` and the `.path`/`.url` resolves. See [`templates/minimal-app/build.zig`](../templates/minimal-app/build.zig). |
| `error: expected path relative to build root; found absolute path` | `.path` in `build.zig.zon` must be relative to that file. Convert your absolute path. |
| `invalid fingerprint: 0x0` | Replace the placeholder with a unique value. Easiest: delete the `.fingerprint` line, run `zig build` once. Zig prints the value to paste back. |

### Runtime / visuals

| Symptom | Likely cause / fix |
|---|---|
| Black window / no text | Default font fallback chain (Helvetica Neue -> Arial -> Helvetica -> Inter -> Menlo) missed. Override via `App.init(.{ .font = .{ .fallback_families = &.{"YourFont"} } })`. |
| Layout looks wrong / element in unexpected position | Use the inspector overlay (see "Inspecting your UI" above). The dashed rect + dimension label nearly always reveals the issue. |
| Click goes to the wrong node | Same: hover overlay shows you the actual hit-test target. If a transparent ancestor is capturing clicks, set `hit_behavior = .pass_through` on it via `style.ensureExt(allocator).hit_behavior`. |
| Hover/pressed state never resets | Make sure you're calling `app.processEvents()` each frame (or using `app.run()` / `app.runWith()`, which does it for you). |
| Text appears clipped to a wrong line count | `text(...)` defaults to single-line. Pass `.wrap = .word` and an explicit `width` (or grow). |
| Frame rate drops on large lists | Use `ui.widgets.VirtualList`. Plain `box` with thousands of children layouts every node every frame. |

### Reactive / state

| Symptom | Likely cause / fix |
|---|---|
| `error: StateNotFound` from `cx.handler(...)` | You used the explicit-id form without a prior `cx.state(T, id, init)`. Prefer `cx.bindState(T, init)` + `cx.on(T, ptr, T.method)`; no id needed. |
| Effect never re-runs after `signal.set(...)` | Effects only track signals **read inside the compute closure** during their first run. Make sure `signal.get()` is on the read path, not stashed in a captured local. |
| Memo recomputes every frame | Same: the memo's compute fn must read its inputs via `.get()`. If you accidentally captured a value snapshot, dependency tracking can't see the read. |

### Quarantined tests / known issues

If `zig build test-ui` reports skips, see the [issue tracker](https://github.com/version-next/zenit/issues) for the
list of currently-quarantined tests and their failure modes. None of them
affect the four bundled examples.

If you hit something not listed, please file an issue. Repro snippets are
welcome; the smaller, the better.

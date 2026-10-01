# zenit

A Zig GUI framework for native desktop apps. GPU-rendered (Metal), retained node
tree, reactive state, flexbox-style layout, and a component library.

Manual and component gallery: [zenit.z.express](https://zenit.z.express)

## Status

| | |
|---|---|
| **Maturity** | Alpha (`0.1.0-alpha`). The API will break before v1, so pin a revision. |
| **Platforms** | macOS only, tested on Apple Silicon. Linux/Windows backends are compile-only stubs. |
| **Accessibility** | Not supported. See [Accessibility](#accessibility). |
| **Zig** | `0.15.2` |

## How zenit is built

Most of the code, docs and tests in this repo were written with AI coding
agents. Architecture, review and acceptance are done by a human. We say this up
front so nobody has to guess.

Because of that, we don't treat "it compiles and looks right" as evidence. What
CI actually checks:

- About 2,700 deterministic unit tests (`zig build test`), plus a separate run
  on a null GPU backend and one against a real Metal device.
- An allocation-failure campaign (`zig build test-allocation-campaign`) that
  fails each allocation in turn and checks for leaks and broken state, not just
  the happy path.
- Real-window E2E against the storybook: screenshots are compared as pixels,
  not only node trees.
- Module boundary, API-removal and formatting ratchets that fail the build.
- Benchmarks compared against the `main` baseline on every run.

If you find a bug, a design problem or a security issue, please
[open an issue](https://github.com/version-next/zenit/issues) (or use
[`SECURITY.md`](SECURITY.md) for security). Concrete reports are the most
useful thing you can send.

## Prerequisites

- macOS, Apple Silicon recommended
- Zig `0.15.2` on `PATH` (or `ZIG=/path/to/zig` for repo scripts)
- Xcode Command Line Tools: `xcode-select --install`
- `bun`, only if you run the E2E suite

## Quick start

```zig
const std = @import("std");
const ui = @import("ui");
const App = @import("zenit_app").App;

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

    const root = try ui.box(cx, .{
        .width = .{ .grow = .{} }, .height = .{ .grow = .{} },
        .direction = .column, .gap = 16,
        .align_items = .center, .justify = .center,
    }, .{});

    try root.appendChild(cx.allocator, try ui.text(cx, "Hello, zenit!", .{ .font_size = 24 }));
    try root.appendChild(cx.allocator, try ui.widgets.Button(.{ .label = "Click me", .on_click = click }).mount(scope, cx));

    const label = try ui.text(cx, "Clicked 0 times", .{ .font_size = 14 });
    try root.appendChild(cx.allocator, label);
    counter.label = label;

    return root;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const app = try App.init(gpa.allocator(), .{
        .window = .{ .title = "Hello", .width = 640, .height = 480 },
    });
    defer app.deinit();

    try app.runWith(mountUI);
}
```

The full example is in [`examples/hello_button/`](examples/hello_button/):

```bash
zig build hello-button       # .app bundle, ad-hoc signed
zig build run-hello-button   # run unbundled
```

The bundle is 1.7 MB with `-Doptimize=ReleaseSmall` (7.8 MB in Debug).

## Using zenit in your project

Add the dependency:

```zig
// build.zig.zon
.dependencies = .{
    .zenit = .{ .path = "../path/to/zenit" },
},
```

Then attach it to your executable. This adds the `ui` and `zenit_app` modules,
the macOS ObjC bridges and the system frameworks:

```zig
// build.zig
const zenit = @import("zenit");

const zenit_dep = b.dependency("zenit", .{ .target = target, .optimize = optimize });
const exe = b.addExecutable(.{ ... });
zenit.attach(zenit_dep, exe);
```

The quickest start is copying [`templates/minimal-app/`](templates/minimal-app/).
The full walkthrough is [`docs/GETTING_STARTED.md`](docs/GETTING_STARTED.md).
Icons default to [Lucide](https://lucide.dev); `zenit.attachWithOptions` lets
you plug in another provider.

## What's in it

`ui.X` holds the ~50 names every app uses: `Cx`, `Node`, `Scope`, `Style`,
builders (`box`, `text`, `image`, `icon`, `grid`, ...), reactive primitives
(`Signal`, `Memo`, `createEffect`), and control flow (`Show`, `For`, `Match`).

Everything else is grouped by namespace:

| namespace | contents |
|---|---|
| `ui.widgets` | Components: `Button`, `Input`, `Modal`, `Tabs`, `VirtualList`, `Calendar`, `Form`, ... |
| `ui.fx` | Animation and transitions: `Tween`, `Spring`, `AnimatedValue`, `Easing`, `Router`, ... |
| `ui.events` | Event enum and payloads |
| `ui.hooks` | `useHover`, `useFocusRing`, `useToggle`, `onMount`, `onCleanup`, ... |
| `ui.reactive` | `Context`, `Store`, `SignalOwner` |
| `ui.focus`, `ui.actions` | Focus scopes and tab order; actions and key bindings |
| `ui.theme`, `ui.arb` | Theme tokens; escape hatches for off-token values ([`docs/STYLING.md`](docs/STYLING.md)) |
| `ui.icons`, `ui.system_icons` | Full icon catalog; the semantic subset components use |
| `ui.hit`, `ui.path`, `ui.gesture` | Hit testing, path geometry, gesture recognition |
| `ui.console`, `ui.devtools` | Diagnostics console and inspector ([`CONSOLE.md`](docs/CONSOLE.md), [`DEVTOOLS.md`](docs/DEVTOOLS.md)) |

Modules under `core/`, `reactive/`, `i18n/` etc. are internal and unstable.

`zenit_app` provides the native window, the Metal surface and renderers, IME,
clipboard, file dialogs, and `.app` bundling.

### Module layout

```
your app
  └─ zenit_app        App runtime, UI commands to GPU
       ├─ ui          node tree, reactivity, layout, components, animation
       ├─ system_sdk  platform layer (NSWindow / Metal / IME on macOS)
       ├─ render      SDF, text and image renderers
       ├─ gpu         thin Metal wrapper
       └─ text        font loading and shaping
            └─ text_core, icon_ir
```

`ui` produces a flat display list and contains no GPU code.

## Out of scope

zenit is a GUI framework. Language tooling (tree-sitter, LSP, regex), editor
surfaces, document models and app shells (sidebars, palettes, file trees)
belong in applications. The `hello-button` example only links `ui` and
`zenit_app`, so a forbidden import fails the build.
[`scripts/check_oss_boundary.sh`](scripts/check_oss_boundary.sh) runs the
stricter check. Details: [`docs/UI_OSS_BOUNDARY.md`](docs/UI_OSS_BOUNDARY.md).

## Accessibility

Not supported in this release. There is an accessibility tree, roles on
components and an NSAccessibility bridge, with tests that simulate bridge calls.
None of the 61 components has been tested with VoiceOver by a person, and we
make no WCAG claim. Don't use zenit where accessibility is a requirement yet.

VoiceOver test notes for any single component are a very welcome contribution.

## Multiple windows

`MultiWindowApp` gives each window its own `Cx`, Metal surface, renderer, event
route and IME context:

```zig
var application = zenit_app.MultiWindowApp.init(allocator, .{});
defer application.deinit();

const editor = try application.createWindowWith(.{
    .window = .{ .width = 900, .height = 700, .title = "Editor" },
}, mountEditor);
_ = try application.createWindowWith(.{
    .window = .{ .width = 480, .height = 700, .title = "Preview" },
}, mountPreview);

_ = application.activateWindow(editor.windowId());
try application.run();
```

Up to 16 windows (`error.TooManyWindows` beyond that). `closeWindow(id)` is safe
inside callbacks; teardown happens at the end of the iteration. See
[`examples/multi_window/`](examples/multi_window/).

For a custom loop, `App.run()` is just `pump` / `processEvents` / `frame`, and
all `App` fields are public.

## Bundling

```zig
_ = zenit.bundleApp(b, .{
    .exe = my_exe,
    .display_name = "My App",
    .bundle_id = "com.acme.myapp",
    .version = "1.0.0",
    .signing = .ad_hoc, // .none / .ad_hoc / .developer_id
    .icon = b.path("assets/icon.icns"),
});
```

This generates `Info.plist`, copies resources and signs the bundle. Developer ID
signing and notarization are available through `.developer_id` and
`zenit.notarizeBundle`. DMG, auto-update and crash reporting are not included.

## Performance

The target is 60 fps in Debug builds for basic interaction (typing, cursor
movement, scrolling) on M-series Macs, including virtual lists with tens of
thousands of rows. This relies on triple-buffered GPU instances, subtree
caching of the display list, layout isolation boundaries, and splitting heavy
work across frames.

## License

GPL-3.0-only, or a commercial license for closed-source use (contact
zongyi.xzy@gmail.com). `templates/` and `examples/` are also 0BSD. See
[LICENSING.md](LICENSING.md).

## Stability

`ui.X`, the namespaces listed above and `zenit_app.App` are the proposed v1
surface. Until `v1.0.0`, breaking changes can land in minor releases and are
recorded in [`docs/MIGRATION.md`](docs/MIGRATION.md).

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md) for the gates a PR has to pass. Open
render bugs in the [issue tracker](https://github.com/version-next/zenit/issues)
are a good place to start. Designers are welcome too: component visuals, motion
timing and interaction details all need review.

Security issues go through [`SECURITY.md`](SECURITY.md).
[Code of Conduct](CODE_OF_CONDUCT.md).

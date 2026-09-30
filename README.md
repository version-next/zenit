# zenit

A Zig GUI framework for building native desktop applications.

**Website & developer manual:** [zenit.z.express](https://zenit.z.express) · [Components](https://zenit.z.express/components) · [AI dev Skill](https://zenit.z.express/docs/guide/ai-skill)

> **Join us — designers and developers alike.** If you care obsessively about UI performance and motion, you are exactly who we are looking for.
> Help us polish zenit into the most loved GPU-native UI framework, with the best DX and performance —
> see [Join the open-source effort](#join-the-open-source-effort).
>
> 非常欢迎对 UI 性能和动效有极致追求的你加入 zenit 开源计划，设计师和开发者都可以参与，一起把 zenit 打磨成最受欢迎、拥有最好 DX 与性能的 GPU 原生 UI 框架。

## Status

| | |
|---|---|
| **Maturity** | Alpha (`0.1.0-alpha`, first public release). API may break before v1; pin a specific revision. |
| **Platforms** | macOS only (Apple Silicon tested). Linux/Windows backends are stubbed; not yet usable. |
| **Accessibility** | **Not supported yet.** The a11y tree, roles, and the NSAccessibility bridge are implemented, but **zero components have passed VoiceOver acceptance** — treat a11y as unverified scaffolding, not a feature. Do not ship zenit where accessibility is a requirement. See [below](#accessibility-status). |
| **Zig** | `0.15.2` (declared in `build.zig.zon`). |
| **Stability target** | The `v0.x` line (first public release: `v0.1.0-alpha`) is pre-1.0; the documented public surface freezes at `v1.0.0`. |

## Prerequisites

- macOS (Apple Silicon recommended — x86_64 not regularly tested)
- Zig `0.15.2` on `PATH` (or set `ZIG=/abs/path/to/zig` for repo scripts)
- Xcode Command Line Tools (`xcode-select --install`) — for the macOS frameworks
- Optional, only for inspecting bundles: `codesign`, `xattr` (both ship with macOS)

- Optional, only for running the e2e suite: `bun`

The repo's `scripts/check_oss_boundary.sh` uses the `zig` on your `PATH` by
default; set `ZIG=/path/to/zig` to override.

---

## Use zenit in your own project

See [`docs/GETTING_STARTED.md`](docs/GETTING_STARTED.md) or the
[online manual](https://zenit.z.express/docs) for the full walkthrough. The fastest path is copying
[`templates/minimal-app/`](templates/minimal-app/) and pointing its
`build.zig.zon` at your zenit checkout.

zenit's root `build.zig` is a public build API. Declare the `.zenit` dep in
your `build.zig.zon`, then one call wires everything — the `ui` / `zenit_app`
module imports, the five macOS native ObjC bridges, and the system frameworks:

```zig
// your build.zig (Zig 0.15.2)
const zenit = @import("zenit");

// inside pub fn build(b: *std.Build):
const zenit_dep = b.dependency("zenit", .{ .target = target, .optimize = optimize });
const exe = b.addExecutable(.{ ... });
zenit.attach(zenit_dep, exe);
```

Public builds use Lucide by default. The three internal applications inject the
separately packaged Untitled provider—without changing the Zenit worktree:

```zig
const zenit_dep = b.dependency("zenit", .{
    .target = target,
    .optimize = optimize,
});
const icons_dep = b.dependency("zenit_icons_untitled", .{
    .target = target,
    .optimize = optimize,
});
zenit.attachWithOptions(zenit_dep, exe, .{
    .icon_provider = .{
        .icons = icons_dep.module("icons"),
        .system_icons = icons_dep.module("system_icons"),
    },
});
```

The private package currently lives at `private/zenit-icons-untitled` and is
excluded from Zenit's public Zig package payload; it ships its own
`build.zig.zon` declaration. Zenit's reusable components use
`ui.system_icons`; `ui.icons` remains the selected provider's full,
provider-specific catalog.

For automated input, a rendered virtual cursor, screenshots, and Retina
application-surface recording, see [`docs/HARNESS.md`](docs/HARNESS.md).

```zig
// your build.zig.zon — dependencies block
.dependencies = .{
    .zenit = .{ .path = "../path/to/zenit" }, // or .url + .hash once published
},
```

---

## 5-minute Quick Start

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

A complete, working version is in [`examples/hello_button/`](examples/hello_button/). Run it with:

```bash
zig build hello-button       # bundle + ad-hoc codesign
zig build run-hello-button   # run unbundled
```

Output: a 640×480 macOS window with a clickable button. The `.app` bundle is **1.7 MB** with `-Doptimize=ReleaseSmall` (about 7.8 MB in the default Debug build).

---

## What you get

The public surface is split into two tiers:

### Tier 1 — top-level (`ui.X`)

The minimum every app uses. Intentionally small (~50 names) so newcomers
can scan `ui.zig` end-to-end:

- **Runtime:** `Cx`, `Node`, `Scope`, `Style`, `BoxStyle`, `DisplayItem`, `DrawContext`
- **Layout primitives:** `Color`, `Padding`, `Margin`, `Border`, `Outline`, `Sizing`, `Size`, `Point`, `Direction`, `FlexWrap`, `TextWrap`, `CursorShape`, `TextProps`, `ImageProps`
- **Builders:** `box`, `hstack`, `vstack`, `text`, `image`, `imageTint`, `imageSvgHit`, `imageTintSvgHit`, `icon`, `iconTint`, `svg`, `svgTint`, `spacer`, `clickable`, `grid`, `GridStyle`, `SvgAsset`
- **Reactive essentials:** `Signal`, `Memo`, `createEffect`, `createMemo`
- **Control flow:** `Show`, `For`, `Match`
- **A11y:** `A11yRole`, `A11yProps` (declarative only — see [Accessibility status](#accessibility-status))
- **Handlers:** `HandlerRef`, `EventCallback`

### Tier 2 — sub-namespaces (`ui.<group>.X`)

Grouped by concern. Reach for these when you need more than the basics:

| namespace | what it holds |
|---|---|
| `ui.widgets`     | Component library: `Button`, `Input`, `Modal`, `Tabs`, `VirtualList`, `Calendar`, `Form`, … |
| `ui.fx`          | Animation, physics, view transitions, router (`Tween`, `Spring`, `AnimatedValue`, `Easing`, `Transition`, `Router`, `RubberBand`, …) |
| `ui.events`      | Full `Event` enum + every payload struct (`KeyCode`, `Modifiers`, `MouseButton`, `KeyEvent`, `ScrollEvent`, `ImePreeditEvent`, …) |
| `ui.hooks`       | `useHover`, `useFocusRing`, `useAnimatedBackground`, `useToggle`, `useArrowNavigation`, `onMount`, `onCleanup` |
| `ui.reactive`    | Full reactive system (`Signal`/`Memo`/`Scope` also at top level), plus `Context`, `Store`, `SignalOwner` |
| `ui.focus`       | `FocusManager`, focus scopes, tab order |
| `ui.actions`     | `Action`, `KeyBinding`, `ActionDispatcher` |
| `ui.theme`       | `ThemeTokens` + built-in light/dark palettes |
| `ui.theme_schema`| Semantic token namespace for custom palettes |
| `ui.control_flow`| Same `Show`/`For`/`Match` (also at top level) |
| `ui.assets`      | `SvgAsset` registry, built-in icons |
| `ui.icons`       | Selected provider's full catalog. Public default: 2,026 [Lucide](https://lucide.dev) entries (ISC), with named constants, `get`, `all`, and `count` |
| `ui.system_icons`| Stable semantic subset used by reusable components; implemented by Lucide publicly and Untitled internally |
| `ui.hit`         | Hit-testing types (`HitQuery`, `HitShapeSpec`, `HitBehavior`, `HitProxySpec`, `HitRoles`) |
| `ui.path`        | Path geometry (`PathCommand`, `Transform2D`, `PathFillRule`, `PathGeometry`, …) |
| `ui.console`     | Per-`Cx` bounded diagnostic Console: levels, scopes, groups, counters, timers, source locations, snapshots, and DevTools/E2E capture. See [`docs/CONSOLE.md`](docs/CONSOLE.md). |
| `ui.devtools`    | `Inspector`, accessibility bridge, debug-trace, the in-window inspector `overlay`, and the standalone Elements / Components / Console / Performance panel. See [`docs/DEVTOOLS.md`](docs/DEVTOOLS.md). |
| `ui.interaction` | Interaction primitives — the drag machine/manager/binding (`ui.interaction.drag`) |
| `ui.gesture`     | Gesture recognition (pan, magnify, rotate) on top of raw events |
| `ui.arb`         | Arbitrary-value escape hatches (`arb.px`, `arb.hex`) for intentionally off-token values — see [`docs/STYLING.md`](docs/STYLING.md) |
| `ui.frame`       | Read-only frame clock (`timeMs`, `dtSeconds`, `dtMs`) for `before_render` hooks that cannot reach a `Cx` |
| `ui.select_headless` | Unstyled Select behaviour (state + keyboard) for custom-rendered pickers |
| `ui.components_controlled` | Controlled-mode variants of the widgets that own state by default |
| `ui.a11y_tree`   | Accessibility tree construction and queries — **unverified**, see [Accessibility status](#accessibility-status) |
| `ui.a11y_router` | Per-window accessibility routing — **unverified**, see [Accessibility status](#accessibility-status) |
| `ui.perf_overlay`| In-window performance HUD |

Anything else (`core/...`, `reactive/...`, `i18n/...` and the other internal
modules) is internal — reach for it only when prototyping a fix to the
framework itself.

### Platform integration (`@import("zenit_app").App`)
- Native window (NSWindow on macOS today, Linux/Windows planned)
- GPU surface (Metal) + per-frame triple-buffered SDF/text/image renderers
- IME pre-edit & commit, clipboard, file dialogs (plus an accessibility bridge — [unverified](#accessibility-status))
- Optional `.app` bundle helper with parametric `Info.plist` generation + ad-hoc codesign

---

## What's *not* in zenit

By design, this framework draws a sharp line between "GUI building blocks" and "editor / language tooling." The following are **explicitly out of scope** and must never be reachable through `@import("ui")` or `@import("zenit_app")`:

- **Language runtimes** — tree-sitter, LSP clients, regex engines (PCRE2), fuzzy matchers. A GUI framework should not pull in a language toolkit.
- **Editor surfaces** — WYSIWYG markdown, code editors with syntax highlighting / find-replace / foldings. That's application code that *uses* zenit.
- **App-side document models** — anything richer than the generic `PieceTree` already in `text_core`. Application data layers belong in the application.
- **App shell** — sidebars, command palettes, file trees, multi-file workspace persistence, hot-reload, dev test harnesses. Application concerns.

The boundary is enforced at build time via the `hello-button` example: it's wired in `build.zig` to only allow `ui` and `zenit_app`. If a forbidden import is ever introduced, `zig build hello-button` will fail to compile.

Audit it yourself:
```bash
zig build hello-button --verbose 2>&1 | grep -oE '\-M[a-z_]+=' | sort -u
```
The list should contain only: `ui`, `zenit_app`, `system_sdk`, `render`, `gpu`, `platform`, `text`, `text_core`, `icon_ir`, `trace`, `root`. Nothing else.

For a stricter check that also greps `src/ui/` for forbidden imports, run
[`scripts/check_oss_boundary.sh`](scripts/check_oss_boundary.sh).

---

## Accessibility status

**Accessibility is not supported in this release.** Please read this before
adopting zenit for anything with an accessibility requirement.

What exists:

- An accessibility tree (`src/ui/a11y/tree.zig`) built from the node tree
- Roles and state on components (`A11yRole`, `A11yProps` — `role`, `label`,
  `required`, `invalid`, and friends)
- An NSAccessibility bridge and per-window routing
  (`src/ui/a11y/nsaccessibility_router.zig`, `macos_bridge.zig`)
- Automated tests covering tree construction and the bridge's simulated calls

What does **not** exist:

- **Any acceptance against real assistive technology.** Of the 61 components in
  the component quality matrix, the a11y column reads `not_run` for **all 61**. Zero have been driven with
  VoiceOver by a human.
- Verified keyboard-only operation of every widget
- Focus-order and announcement guarantees
- Any WCAG or Section 508 conformance claim

Simulated bridge tests are not equivalent to assistive-technology acceptance:
they prove the code path runs, not that a VoiceOver user can complete a task.
We would rather say this plainly than let the `ui.a11y_*` namespaces imply a
working feature.

**Practical guidance:** if accessibility is a requirement for your product, zenit
is not ready for you yet. If you want to help, real VoiceOver acceptance notes
on any single component are one of the most valuable contributions available —
[open an issue](https://github.com/version-next/zenit/issues) and we will share the evidence format the gate requires.

---

## Dependency Graph

```
your app
    │
    ▼
┌─────────────────────────────────────┐
│ zenit_app — App runtime helper       │
│         AppRenderer (UI cmd → GPU)   │
└──┬──────────────────────────────────┘
   │
   ▼
┌──────┬─────────────┬────────┬──────┬───────┐
│ ui   │ system_sdk  │ render │ gpu  │ text  │
└──┬───┴─────────────┴────────┴──────┴───────┘
   │
   ▼
┌──────────────┬────────────┐
│ text_core    │ icon_ir    │
└──────────────┴────────────┘
```

- **`ui`** — node tree + reactive system + layout engine + components + animation. Outputs a flat `DisplayItem[]` — no GPU code lives here.
- **`zenit_app`** — convenience wrapper. The `App` struct does platform/GPU/font setup + main loop in 9 lines. Optional; advanced apps can use the lower layers directly.
- **`system_sdk`** — platform abstraction. macOS today (`NSWindow` / `Metal` / `CAMetalLayer` / `IME` via `BackendVTable`); Linux & Windows backends are stubbed out.
- **`render`** — GPU renderers (Metal SDF, Metal text shaper via CoreText, image atlas). Consumes `DisplayItem[]` from `ui`.
- **`gpu`** — thin Metal abstraction (`Surface`, `Device`, `Queue`, `CommandEncoder`).
- **`platform`** — native window handle + display link.
- **`text`** — font loading & shaping (FreeType + HarfBuzz).
- **`text_core`** — `PieceTree`, `DocCursor`, `WrapMap`, `Anchor`, `SumTree`, `FenwickTree` — the data structures `Input`/`Textarea` need for text editing. Pure algorithms, no IO, no language awareness.
- **`icon_ir`** — SVG asset metadata format used by the icon system.

---

## Native multi-window applications (macOS)

`MultiWindowApp` is the public application/window lifecycle API. Each `*App`
returned from `createWindowWith` owns an independent native window, `ui.Cx`, font
context, Metal surface/renderer/device/queue, SystemSdk event route, IME input
context, and accessibility route. The application loop captures the active
window for custom menu commands, isolates pointer/keyboard/IME/drag events by
native `window_id`, tears down one window without touching its peers, and exits
after the last window closes. The existing single-window `App` API is unchanged.

```zig
const zenit_app = @import("zenit_app");

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

The runtime supports at most `MultiWindowApp.max_windows` (currently 16) live
windows. This is an explicit bound for its allocation-free lifecycle ledger;
the next `createWindow*` call returns `error.TooManyWindows`.

`closeWindow(id)` is safe from event/menu/render callbacks (teardown is deferred
to the iteration boundary). After it returns outside a callback, that window's
`*App` pointer is invalid. The runnable [`multi_window`](examples/multi_window/)
example and `bash scripts/run_multiwindow_smoke.sh` exercise two real windows,
both public creation styles, explicit activation, single-window teardown with a
surviving render loop, last-window exit, and app-wide quit/deinit cleanup.
WindowServer execution proves the native path; deterministic lifecycle/menu
routing tests remain part of `zig build test-headless`. Real VoiceOver, Finder
cross-window drag, and menu interaction still require the supervised release
matrix.

Cmd-Q, the standard Quit menu item, and `application.quit()` stop `run()` but do
not destroy live windows inside an event callback. The required deferred
`application.deinit()` performs the unified native/GPU/UI teardown afterward.

This shipped surface is macOS-only. Linux and Windows platform backends remain
unsupported stubs.

## Advanced: skipping `App.run()`

If you need custom event routing or your own frame pacing, all `App` fields are `pub`:

```zig
const app = try App.init(allocator, .{ ... });
defer app.deinit();
try mountUI(app.cx);

while (custom_condition) {
    _ = try app.sdk.pump(16);
    app.processEvents();
    if (app.should_quit) break;
    try app.maybeReconfigureSurface();
    try app.frame();
}
```

For custom host loops, hot-reload, or devtools integration, `App.run()` remains a
convenience over `pump` / `processEvents` / `frame`; bypassing it is supported.
Prefer `MultiWindowApp` over hand-pumping multiple `App` instances so global
AppKit events and menu commands keep their target-window identity.

---

## Bundling (.app)

`zenit.bundleApp` (a public API of zenit's root `build.zig`, alongside
`attach`) produces a complete macOS `.app`:

```zig
// in your build.zig
const zenit = @import("zenit");

_ = zenit.bundleApp(b, .{
    .exe = my_exe,
    .display_name = "My App",
    .bundle_id = "com.acme.myapp",
    .version = "1.0.0",
    .signing = .ad_hoc,                                    // .none / .ad_hoc / .developer_id
    .icon = b.path("assets/icon.icns"),                    // optional
    .file_types = &.{                                      // optional
        .{ .name = "My Document", .extensions = &.{"myx"}, .uti = "com.acme.myapp.document" },
    },
    .resources = &.{                                       // optional
        .{ .src = b.path("assets/Roboto.ttf"), .dst = "fonts/Roboto.ttf" },
    },
});
```

Output:
```
zig-out/My App.app/
├── Contents/
│   ├── Info.plist           ← generated from spec
│   ├── PkgInfo              ← "APPL????" (from spec.signature)
│   ├── MacOS/My App
│   ├── Resources/icon.icns
│   ├── Resources/fonts/Roboto.ttf
│   └── _CodeSignature/      ← from codesign
```

### Public release: Developer ID + notarization

For shipping to end users without the "unidentified developer" warning, switch
to `.signing = .developer_id { ... }` and add a `notarize` build step:

```zig
const result = zenit.bundleApp(b, .{
    // ...
    .signing = .{ .developer_id = .{
        .identity = "Developer ID Application: ACME Corp (TEAM12345)",
        .entitlements = b.path("macos/MyApp.entitlements"),
    }},
});

const notarize_inner = zenit.notarizeBundle(b, .{
    .bundle_path = result.bundle_path,
    .auth = .{ .keychain_profile = "AC_PASSWORD" },  // see notarytool store-credentials
});
notarize_inner.dependOn(result.final_step);
b.step("notarize", "Submit to Apple notarization (5-10 min)").dependOn(notarize_inner);
```

Ad-hoc signing works out of the box; Developer ID signing / notarization
docs are planned.

### What's not included

DMG creation, Sparkle auto-update, crash reporting — those are app-author concerns and intentionally out of scope here.

---

## Performance

The framework targets **60 fps under Debug builds for basic interactions** (cursor move, scroll, typing) on M-series Apple silicon, including in scenes with virtualized lists in the tens of thousands of rows.

Key techniques:
- Triple-buffered Metal SDF/text instances; `frame_sync.waitForNextFrame` overlaps GPU completion with CPU layout
- Display list with subtree caching; static subtrees skip layout/render
- `layout_isolation` boundaries cut render-dirty cascades
- Deferred scheduler chunks heavy work (e.g. virtual list slot rebuilds) across frames

---

## License

zenit is dual-licensed under [GPL-3.0-only](LICENSE) **or** a commercial
license. Open-source projects under GPL-3.0 can use it for free; closed-source
/ proprietary use requires a commercial license — contact
zongyi.xzy@gmail.com. `templates/` and `examples/` are additionally 0BSD.
See [LICENSING.md](LICENSING.md) for details and third-party notices.

## Stability

- **Public API:** Tier 1 (`ui.X`) and the documented Tier 2 sub-namespaces
  (`ui.widgets`, `ui.fx`, `ui.events`, `ui.hooks`, `ui.reactive`, `ui.focus`,
  `ui.actions`, `ui.theme`, `ui.control_flow`, `ui.assets`, `ui.hit`,
  `ui.path`, `ui.devtools`) plus `zenit_app.App` are the proposed v1 surface.
  The current package version is `0.1.0-alpha`. Breaking changes remain allowed in
  v0 minor releases and must be recorded in MIGRATION. The compatibility
  freeze begins at `v1.0.0`.
- **Internal APIs** (anything inside `core/`, `reactive/`, `i18n/`, and the
  render engine): unstable; do not depend on.
- **Breaking changes** are tracked in [`docs/MIGRATION.md`](docs/MIGRATION.md)
  with mechanical sed snippets for each rename.

## Join the open-source effort

zenit is built by people who notice a dropped frame, a caret that lags by one
tick, or a transition that eases the wrong way — and cannot leave it alone.
You do not have to write Zig to contribute: designers and developers are both
welcome. If you care obsessively about UI performance and motion, we would love
to have you. Help us polish zenit into the most loved GPU-native UI framework, with
the best developer experience and the best performance.

Good places to start:

- **Designers** — component visuals, motion curves and timing, interaction
  details, and design reviews of the storybook against your own standards.
- **Developers** — frame-time and idle-cost work, animation and transition
  internals, text and IME edge cases, and real-device acceptance of components.

Say hello in the [issue tracker](https://github.com/version-next/zenit/issues).

非常欢迎对 UI 性能和动效有极致追求的你加入 zenit 开源计划，**设计师和开发者都可以
参与**：设计师可以打磨组件视觉、动效曲线与交互细节，开发者可以深入渲染、布局、文本
引擎与性能。一帧掉帧、一次光标延迟、一条不对劲的缓动曲线都放不下的人，正是我们在找
的伙伴。一起把 zenit 打磨成最受欢迎、拥有最好开发体验（DX）与性能的 GPU 原生 UI
框架。

## Contributing

Issues and PRs welcome — see [`CONTRIBUTING.md`](CONTRIBUTING.md) for the build
prerequisites, the gates CI will run against your PR, and the house rules.

Two things worth knowing before you start:

- [`docs/UI_OSS_BOUNDARY.md`](docs/UI_OSS_BOUNDARY.md) defines what belongs in
  this repo. It is enforced at build time, not in review.
- The open render bugs in the [issue tracker](https://github.com/version-next/zenit/issues) are the highest-leverage
  place to start — they cluster, so fixing one often fixes several.

Security issues go through the private channel in [`SECURITY.md`](SECURITY.md),
not the public tracker. Participation is covered by our
[Code of Conduct](CODE_OF_CONDUCT.md).

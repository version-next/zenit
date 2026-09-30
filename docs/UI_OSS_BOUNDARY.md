# zenit Open-Source Boundary Contract

This document defines what does and does not belong in the zenit GUI framework. Every contributor working in `src/ui/`, `src/zenit_app/`, `src/system_sdk/`, `src/render/`, `src/gpu/`, `src/platform/`, `src/text/`, `src/text_core/`, or `src/icon_ir.zig` must understand this boundary before sending changes.

## TL;DR

zenit is a **GUI framework**. It draws windows, lays out widgets, dispatches events, ships a component library, and exposes a 9-line "hello window" runtime helper. It is NOT an editor, NOT a language toolkit, NOT a workspace manager. Those are application concerns, and they belong in code that *uses* zenit, not in zenit itself.

The line is enforced at **build time**: `zig build hello-button` only allows the framework's own modules to be reachable. Anything that breaks the boundary causes the build to fail.

## What's IN

| Module | Path | Role |
|---|---|---|
| `ui` | `src/ui/` | Declarative tree, reactive primitives, layout engine, components, hit-test, animation, focus, accessibility, dispatcher |
| `app` | `src/zenit_app/` | `AppRenderer` (UI → GPU encoding), `App` runtime helper (one-call init + main loop) |
| `system_sdk` | `src/system_sdk/` | Platform abstraction (events, IME, clipboard, dialogs) — backed by per-OS backends |
| `render` | `src/render/` | Metal renderers (SDF, text via CoreText, image atlas, icon) |
| `gpu` | `src/gpu/` | Thin Metal abstraction (Surface, Device, Queue, CommandEncoder) |
| `platform` | `src/platform/` | NSWindow + display link wrapper |
| `text` | `src/text/` | Font loading, shaping (FreeType + HarfBuzz) |
| `text_core` | `src/text_core/` | PieceTree, DocCursor, WrapMap, Anchor, SumTree, FenwickTree — pure text data structures |
| `icon_ir` | `src/icon_ir.zig` | SVG asset metadata format |
| `zenit_icons` | build-selected provider module | Full provider catalog (`ui.icons`); Lucide is the public default |
| `zenit_system_icons` | `src/ui/system_icons_*.zig` | Provider-neutral semantic icons used by framework components |

## What's OUT

By policy, none of the following may appear in any module above:

- **Language runtimes** — tree-sitter, LSP clients, regex engines (e.g. PCRE2), fuzzy matchers. A GUI framework should not pull in a language toolkit.
- **Editor surfaces** — WYSIWYG document editors, code editors with syntax highlighting / find-replace / foldings, completion engines.
- **App-side document models** — anything richer than the generic `PieceTree` already in `text_core`. Application data layers belong in the application.
- **App shell** — sidebars, command palettes, file trees, multi-file workspace persistence, hot-reload, dev test harnesses, component showcases.

If you need any of these, build them in your application on top of the public `ui` / `app` surface. The boundary exists so a "give me a button" app doesn't drag in a language server.

## Why the boundary matters

A minimal `hello-button` `.app` is **1.7 MB** (`-Doptimize=ReleaseSmall`) — a complete window, layout engine, Metal renderer, font fallback chain, IME handling. Open-source users of zenit should pay only for what they use.

It also means the framework can stay small enough to *understand*. New contributors need to read a manageable codebase to feel comfortable changing it.

## Direction of allowed dependencies

```
ui ─────► system_sdk, icon_ir, zenit_icons, zenit_system_icons, text_core
app ────► ui, system_sdk, render, gpu, platform, text
render ─► gpu, text, icon_ir
text ───► (freetype, harfbuzz — vendored C libs)
text_core ── no module dependencies
system_sdk ─► platform
icon_ir ─── no module dependencies
```

Because there is no path from `ui` to a forbidden module through allowed modules, no `@import` inside `ui` can reach one.

## How the boundary is enforced

### 1. Build-time fence: `examples/hello_button/`

In `build.zig`, the `hello_button` executable is wired with **only** `ui` and `app` as imports. If any of those modules transitively reach a forbidden module, `zig build hello-button` fails to compile.

### 2. Audit command

```bash
zig build hello-button --verbose 2>&1 | grep -oE '\-M[a-z_]+=' | sort -u
```

Current framework modules include (order is not significant):
- `-Mbuild_options=`
- `-Mgpu=`
- `-Micon_ir=`
- `-Mzenit_icons=`
- `-Mzenit_system_icons=`
- `-Mplatform=`
- `-Mrender=`
- `-Mroot=`
- `-Msystem_sdk=`
- `-Mtest_harness=` (present in the graph but verified absent from the shipped binary when test mode is false)
- `-Mtext=`
- `-Mtext_core=`
- `-Mtrace=`
- `-Mui=`
- `-Mzenit_app=`

The authoritative gate checks forbidden modules rather than freezing this
diagnostic list; adding a legitimate framework layer still requires updating
the boundary contract. It separately inspects the linked binary to prove the
test harness was removed by compile-time configuration.

### 3. CI check: `scripts/check_oss_boundary.sh`

Run this in CI on every PR. It does two things:
1. Fails if `grep -rn '@import("X")' src/ui/` finds any X not in the allow-list.
2. Fails if `zig build hello-button --verbose` lists any -M for a forbidden module.

```bash
bash scripts/check_oss_boundary.sh
```

## How to make changes that touch the boundary

### Adding a new feature to a UI component

If the component needs new data structures, prefer:
1. Inline in the component file (most cases).
2. A new file in `src/ui/` (broader utility).
3. A new file in `src/text_core/` (text-related data structure that's truly generic, e.g., a new B-tree variant).

**Don't** introduce dependencies on a language toolchain or an app-side document model from inside `src/ui/`. If you find yourself wanting to, you're probably building application logic — push it to the application layer.

### Adding a new system service (e.g., audio, file system)

Decide which side of the boundary it belongs:
- **Generic platform service** (e.g., file picker, system clipboard, audio playback): add to `system_sdk` with a vtable entry, implement per-backend.
- **Application-specific service** (e.g., LSP, syntax highlighting, git integration): keep in the application layer.

### Adding a new component

Components go in `src/ui/components/`. They can use `text_core` for text-editing components (Input, Textarea), but otherwise should not import outside `ui`.

If you're tempted to add a rich-text component that pulls a parser: don't. Define a generic rich-text protocol in `ui` (or `text_core`), and let consumers implement it as an adapter.

### Refactoring

Whenever you move code, run the audit command to confirm the boundary is intact:

```bash
zig build hello-button --verbose 2>&1 | grep -oE '\-M[a-z_]+=' | sort -u
```

## When the boundary needs to change

If you find a genuine reason a piece of "OUT" functionality should move IN (or vice versa), this is an architecture-level decision. Open an issue with:
- The functionality in question
- Why it should move
- What downstream users would gain or lose
- Whether the move is reversible

Boundary changes should be rare.

## Appendix: test status

`zig build test-ui` passes cleanly on main (713 passed / 14 skipped /
0 failed). The render tests, Textarea segfault, and the entire DatePicker /
DateRangePicker / Calendar UAF cluster (a real bug in
`freeDetachedNodeAfterScopeDispose`) have all been fixed.

CI runs the full `test` step which includes `test-system-sdk`,
`test-text-core`, `test-reactive`, **and `test-ui`**.

**The 14 remaining skipped tests are quarantined failures**, not platform-
gated skips. Most are first-open-render expectations that drifted as the
popover prewarm pipeline evolved; the rest are SnapshotLayer/Grid render
paths. See the [issue tracker](https://github.com/version-next/zenit/issues) for the full list and recommended fix
order. A new contributor wanting to make a real difference should pick
the first-open-render group from there — fixing one likely fixes ten.

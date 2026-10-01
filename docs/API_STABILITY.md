# zenit API Stability (v1.0 Freeze Audit)

**Date**: 2026-07-30 (A2 audit deliverable; text capability update 2026-08-01)
**Semantics**: `v0.14.x` is the current pre-1.0 semver development track; minor versions
may still break (must be recorded in `MIGRATION.md`). This document describes the API
surface planned to be frozen at `v1.0.0`; it does not mean the existing tag already
carries a v1 compatibility promise.

## Tiers

| Tier | Promise |
|---|---|
| **Stable** | Frozen at v1.0; breaking changes require a major. props structs may **gain new fields with defaults** (not a break). |
| **Unstable** | May break within a v1.x minor; changes are recorded in `docs/MIGRATION.md`. |
| **Internal** | No promise. Anything not re-exported at the top level of `ui` / `zenit_app` counts as Internal. |

## Stable (the v1 frozen surface)

### Runtime (`zenit_app`)
- `App.init / deinit / mount / runWith / run / quit / processEvents / maybeReconfigureSurface / frame`
- `App.Config` (`window` / `font` / `clear_color` / `pump_timeout_ms` / `frame_pacing` / `idle_wait_ms` / `idle_skip_frames`)
- `FrameStats` **existence and the getLastFrameStats() entry point** (the field set is under Unstable)

### Builders and core types (`ui`)
- `box / hstack / vstack / text / textFmt / image / imageTint / svg / svgTint / icon / iconTint / spacer / clickable / grid`
- `Cx` (public method subset: `setTheme` / `themeSignal` / `bindState` / `on` / `setViewport` / `handleMouse* / handleKey*` event entries)
- `Node` (public methods such as `appendChild / removeChild / setText / getText / setStyle / markLayoutDirty / markRenderDirty`)
- `Scope` (`childScope / createSignal / createEffect / registerResource / dispose`)
- Style types: `Style / Color / Padding / Margin / Border / Outline / Sizing / Shadow / Gradient / CornerRadius / BlendMode / Direction / FlexWrap / TextWrap / CursorShape / TextProps / ImageProps`
- Reactivity: `Signal / Memo / createEffect / createMemo`
- Control flow: `Show / For / Match`
- Events: `HandlerRef` (the uniform widget-callback shape) / `EventCallback`
- Theming: `ui.theme.light / dark / high_contrast`; new `ThemeTokens` fields are allowed
- a11y props: `A11yRole / A11yProps`
- Icons: the `ui.system_icons.*` semantic set, `ui.icons.get`, the interface shape of
  `ui.icons.all / count`, and `ui.assets`. The concrete named constants of `ui.icons`
  belong to the selected provider's catalog; the same names across providers are not
  promised.

### widgets (`ui.widgets`, 45 components)
Button / Input / Textarea / Checkbox / Switch / Radio / Slider / SelectHeadless /
ComboBox / Badge / Tag / Chip / Card / Alert / Notifier / Progress / Spinner /
Skeleton / Timeline / Breadcrumb / Steps / Rate / Tabs / Accordion / Tree / Table /
DataTable / NumberStepper / TagsInput / FileUpload / Menu / DropdownMenu / Tooltip /
Popover / Modal / Sheet / Calendar / DatePicker / DateRangePicker / Markdown /
VirtualList / ScrollArea / Grid / Form / GlassBox

What is frozen: **the props struct + the mount entry signature + the existing fields of
the returned struct**.

## Unstable (explicitly exempted in v1)

- `ui.hit` (hit-test queries): bound to internal index structures
- `ui.path` (path geometry): ~~pipeline Phase C unfinished~~ Phase C (cross-frame mesh
  cache: keyed by geometry hash + scale + stroke params; on a hit it skips
  flatten/earclip/stroke expand) landed on 2026-07-30; the API stays labeled Unstable
  for one more release of observation
- `ui.devtools` / `ui.Inspector`
- `ui.a11y_tree` / `ui.a11y_router` / `ui.a11y_macos_bridge`
- `ui.gesture`
- The slot-customization surface of `ui.select_headless` (`render_trigger` / `render_item` ctx structs)
- The `FrameStats` **field set** (observability is still expanding: encode/flush breakdown, draw counts added on 2026-07-30)
- `ui.theme_schema`, the recipe system (`ConditionalStyle` parsing details)
- `ui.fx`, `GlassParams / GlassSurface` (Liquid Glass is still iterating)
- `ui.control_flow` (exports beyond `Show/For/Match`)
- Fields labeled "internal" in mount results (e.g. `InputResult.state`)
- Harness developer entry points: `installHarnessClient` in `build.zig`, the installed
  TypeScript client API, and the file-RPC protocol (`-Dtest-mode=true` only; may evolve
  per minor; production builds do not provide this capability)
- Icon provider build entry points: the `icon-set` dependency option, `IconProvider`,
  `attachWithOptions`. Shipping Lucide as the public default is the stable direction,
  but until the private-package split is done, the provider injection structure may
  still converge across minors.

## Internal

- Everything in `ui.core` not re-exported at the top level (render_engine / lowering / layerize / hit_runtime …)
- `src/render`, `src/gpu`, `src/platform`, `src/system_sdk` (below the `App` abstraction)
- The `test_harness` Zig module and its queue/executor implementation (externally you
  only use the TypeScript facade above)

## Naming conventions (v1 convergence decisions)

- **Callbacks**: always `?core.HandlerRef`. **Converged on 2026-07-31.**
  This entry previously claimed "already unified, Input is the exception"; measurement
  showed a half-and-half split of 16 HandlerRef-style vs 17 bare `fn(T, *anyopaque)`,
  with incompatible signatures: migrating directly would **silently drop the payload**
  (callers still compile; the value is gone).

  The approach adds an optional payload channel to `HandlerRef` instead of cutting the
  ability to carry values:

  | Need | Constructor | Widget-side trigger |
  |---|---|---|
  | Only "it changed" | `cx.handlerFrom(S, ptr, m)` | `h.invoke()` |
  | Need the new bool value | `cx.boolHandlerFrom(S, ptr, m)` | `h.invokeWithBool(v)` |
  | Need the new text/id | `cx.strHandlerFrom(S, ptr, m)` | `h.invokeWithStr(v)` |

  Widgets may call `invokeWith*` unconditionally: if the registrant used a no-arg
  handler, it **degrades to a no-arg call rather than dropping the event**. All 54
  existing `.invoke()` call sites required zero changes.

  Payloads support only `bool` / `[]const u8` (measured across the whole repo, the
  payloads of value-carrying callbacks are exactly these two kinds). Deliberately no
  generics: HandlerRef is stored in Node, and generics would turn `EventHandlers` into
  a comptime type parameter, polluting the types of the entire tree.

  **Exception**: `ControlledProp(T)` keeps its bare function pointer: it is a comptime
  generic container whose T can be any type, which conflicts with the trade-off above.
  See the header of `components/controlled.zig`.

  ⚠ The slice from `invokeWithStr` is **valid only during the callback** (it usually
  points into the widget's internal buffer); dupe it yourself if you need to keep it.
- **Text props**: the widget's primary content = `label` (Button/Chip); a form field's
  attached label = `label_text` (Input/Switch/ComboBox).
  Corrected 2026-07-31: this entry previously said "already consistent today"; in fact
  `form/form_field.zig` used `label` for the attached label, contradicting the rule;
  it has been renamed to `label_text`.

- **mount-only props always take the `initial_` prefix** (added 2026-07-31).
  A prop that is read once at mount and ignored afterwards must carry the prefix
  explicitly, or callers will mistake it for controlled ("I changed the props, why
  didn't the UI move?"). Renamed:

  | Widget | Old name | New name |
  |---|---|---|
  | Checkbox / Switch | `checked` | `initial_checked` |
  | Slider | `value` | `initial_value` |
  | Steps | `current` | `initial_current` |
  | Input | `value` | `initial_value` |

  Exception: `Radio.checked` keeps its original name; it is a purely presentational
  leaf driven by RadioGroup on every render, a genuine render input rather than
  mount-only state.

  To change content after the first frame, use the widget's imperative API (below).

- **Imperative setter convention** (filled in 2026-07-31).
  A `state` exposed in the mount result must be paired with a write entry that
  **actually works**. Widgets where writing the state field directly does not repaint
  are a trap ("looks like it drives something but has no effect"). Added:

  | Widget | setter |
  |---|---|
  | Input / Textarea | `setText(...)` / `clearText()` |
  | Slider | `setValue(v)` (syncs visuals + the a11y value) |
  | Rate | `setValue(v)` (clamps to [0, count]) |
  | DatePicker | `setSelectedDate(?d)` / `clearSelection()` |
  | Table | `setSort(col, dir)` / `clearSort()` |
  | Calendar / NumberStepper / Tree | already existed |

  Semantics unified: **programmatic sets do not fire on_change** (that is the semantics
  of user interaction); call the callback yourself if you need to notify.
- **mount paradigms**: three coexist, each with its own role:
  1. `Widget(props).mount(scope, cx)` (Builder; the primary form for single-node widgets)
  2. `mountXxx(props, scope, cx) -> XxxMount` (composite / multi-return nodes:
     ScrollArea, SelectHeadless, ComboBox, DataTable, NumberStepper, TagsInput, FileUpload)
  3. `XxxOf(T).create(...)` (comptime generic: Form)
  v1 does not force a merge; new widgets pick one of 1/2, and no 4th form will be added.

## Escape hatch

`Node.style.ensureExt()` and writing `behavior.events.*` directly are escape hatches
kept deliberately. What is Stable is the **existence** of the fields; deep
customization done through them is not protected by semver.

## Known not supported (explicitly not promised in v1)

This is written down so users can judge "can this framework build my project" up front,
instead of finding out only after stepping in. Everything below is an
**architectural gap**, not a bug waiting to be fixed.

### ~~RTL / bidirectional text editing~~: **the deterministic path is supported as of 2026-08-01**

The macOS configuration path hands the whole text to a single CoreText `CTLine`.
Static drawing, visual caret order in Input and Textarea, click hit-testing, cross-line
preferred-x, split selection rectangles, IME preedit, and the candidate-window caret all
read the `VisualLine` / `TextPosition+affinity` exported by that line; there is no
longer an assumption that "UTF-8 prefix width is monotonic in the logical offset". The
two carets that share one logical byte at a soft-wrap boundary or a bidi boundary are
distinguished by affinity. The selection/IME nodes of a standalone Textarea are
dynamically sized; long documents are no longer truncated at 16 rectangles, and the
composed display text is no longer truncated at 2048 bytes.

The boundary must be kept clear: `src/i18n/bidi.zig` is a complete Unicode 17.0.0
UAX #9 paragraph/line resolver (including isolates, explicit embedding/override,
brackets, L1/L2), gated by the official full `BidiTest.txt` and
`BidiCharacterTest.txt`; CoreText remains the authority for production glyph shaping,
fallback, run placement, and caret-x. CoreText results that are already in visual order
are not re-reordered by the framework. The framework's own UAX #9 resolver handles
portable text properties, paragraph base direction, deterministic mapping/tests, and
the non-CoreText layers; it does not replace the macOS shaper.

This is not physical acceptance complete: candidate windows under real
Arabic/Hebrew/CJK input sources, VoiceOver editing, and the storybook RTL pixel matrix
are still `NOT RUN` at the current release revision. The degraded path without a Font provider is still usable, but its
estimated coordinates are not part of the macOS production correctness claim.

### ~~Grapheme cluster~~: **supported as of 2026-07-31**

`src/text_core/grapheme.zig` implements UAX #29 extended grapheme clusters
(GB1-GB999: CRLF / Hangul syllables / Extend / ZWJ / SpacingMark / Prepend /
ExtPict ZWJ sequences / Regional Indicator pairs / skin-tone modifiers).
All four boundary functions for caret movement, deletion, and selection go through it,
covering both single-line and multi-line paths.

⚠ The property tables are a **hand-written interval approximation**, not generated from
UCD: SpacingMark / Prepend for rare scripts may be missing, degrading to "one extra
break" (the caret stops one extra cell; it does not crash).
No legacy grapheme cluster definition and no ICU-style tailoring.

### ~~Color emoji~~: **supported as of 2026-07-31**

Color glyphs are detected from the font tables (sbix / COLR / CBDT +
`kCTFontTraitColorGlyphs`) and rasterized as BGRA premultiplied; the atlas gains BGRA8
pages coexisting with R8 grayscale pages (they share the page_index numbering; the
format is uniquely determined by the number); the shader branches on the per-instance
`is_color` flag: color output takes the sampled RGBA directly, without multiplying the
text color.

The decision is per **font**, not per code point: the same code point may still be
single-channel coverage in text-presentation (VS15) or in a monochrome font, and vice
versa. What determines the rasterization result is whichever font CoreText fallback
finally selects.

### Single-line Input length limit

The text limit of a single-line `Input` is `editable_block.MAX_INPUT_BYTES`
(currently **2048 bytes**). The canonical buffer is still inlined in `TextInputState`;
undo/redo snapshots are allocated dynamically to the current text length and freed by
the state, no longer copying the whole 2048-byte buffer. A failed snapshot allocation
is a transactional no-op and does not corrupt existing history. For long text use
`Textarea` (piece tree, no such limit).

### Drag and drop: platform capability in both directions implemented, full product acceptance not complete

**Supported** (2026-07-31): dragging files from Finder / the browser into the window.
Attach `on_drag_enter` / `on_drag_leave` / `on_drop` to any node and it becomes a drop
target:

```zig
node.behavior.events.on_drop =
    core.Cx.strHandlerFrom(MyState, state, MyState.onDrop);
// fn onDrop(self: *MyState, paths: []const u8) void
// paths = newline-separated path list; iterate with std.mem.splitScalar(u8, paths, '\n')
```

⚠ The `paths` slice is **valid only during the callback** (it points into the backend's
per-frame buffer); you must dupe it yourself if you need to keep it. This is the same general
rule as `invokeWithStr`.

Per-node enter/leave is synthesized by the framework from the position stream (the
platform only reports entered/exited at the **window** boundary), so dragging across
multiple targets inside the window delivers correct enter and exit to each of them.
The hint area of `FileUpload` is already a ready-made drop zone.

**Drag source implementation**: `SystemSdk.beginDrag` is wired to AppKit's
`beginDraggingSessionWithItems`, supporting text / file URL / internal payloads,
copy/move/link operations, preview/hotspot, and a completion token. It is currently a
platform-SDK capability; the widget layer does not yet provide a high-level hook for
"any node declares itself draggable", so applications must start the session from
pointer events themselves.

**Still not a production claim**: the real manual matrix for Finder drag-out,
cross-zenit-window drags, cancellation, operation negotiation, and source window
teardown has not been completed at the same release revision. mock/link tests only
prove that the contract and the bridge exist; they do not substitute for these
scenarios.

### Platforms

macOS only. The RHI migration is mid-flight: renderer orchestration uses the typed
resource/pass/binding contract of `gpu.Backend`, Renderer Core's native Metal references
are locked to zero by the boundary gate, and a standalone Null RHI covers resources,
surfaces, and the pass state machine. But `gpu.zig` still selects the single Metal
production backend at compile time; the Null RHI is not yet a swappable, complete render
backend, and non-macOS hits `@compileError`.
`platform/linux.zig` and `windows.zig` are mock scaffolding only; do not claim
portability from them.

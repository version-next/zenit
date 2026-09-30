# Decoupling Styling from Business Logic — the zenit Styling Layering Guide

> For the operations manual (rules for writing new UI / migration steps for
> existing code / the pitfall list), use the zenit UI dev Agent Skill
> ([download](https://zenit.z.express/docs/guide/ai-skill)). This document is the design doc
> and decision record.

zenit has no separate styling file format (CSS/DSL). Style objects are plain
Zig data structures (`BoxStyle` / `TextStyle` / `ConditionalStyle`); the
decoupling is achieved through a three-layer convention that mirrors the
division of labor between design tokens / CSS Modules / CVA (Panda CSS) in
the web ecosystem.

## The three-layer model

### Layer 1: tokens are the only bridge between styles and code

All colors, font sizes, spacing, radii, and control metrics are taken from
`ThemeTokens` (`src/ui/theme.zig`): `t.color.*`, `t.space.*`,
`t.font_size.*`, `t.radius.*`, `t.control.get(size).*`.

**Convention: bare color and font-size literals are forbidden in view-building
code** (`Color.hex(...)`, `.font_size = 24`). Literals bypass the token
scale — themes cannot swap them and global changes cannot reach them.
`scripts/check_style_literals.sh` enforces a ratchet over examples/ that only
lets the count go down, never up.

**Escape hatch (arbitrary values)**: tokens cannot possibly cover every
design — matching a specific mockup, one-off brand colors, and pixel-level
nudges are all legitimate needs (cf. Panda's `[18px]` / `[#316ff6]`). In
those cases mark the value explicitly with `ui.arb.*` instead of writing a
bare literal:

```zig
.font_size = ui.arb.px(18),          // intentionally off-scale
.background = ui.arb.hex(0x316FF6),  // one-off brand color
.border_color = ui.arb.hexA(0x000000, 0.12),
```

`ui.arb` is an inline identity wrapper with zero runtime cost; the difference
is entirely semantic and toolchain-facing: readers can tell at a glance an
"intentional arbitrary value" apart from a "lazy literal that should have
migrated to a token"; the ratchet only catches bare literals and lets `arb`
through by construction; a global grep for `ui.arb` inventories every
off-token value — once the same value shows up more than three times,
consider promoting it to a token.

Control metrics (height / padding / radius / icon size — nine values in all)
live on `tokens.control` (`ControlScale` → one `ControlMetrics` per step);
a theme can replace the control scale wholesale. The legacy methods on the
`ControlSize` enum (`.height()` etc.) are deprecated — they return the
default scale and do not track the theme.

### Layer 2: named style functions (styles.zig) — the Zig equivalent of CSS Modules

Each feature/example gets one `styles.zig` that exports pure functions:

```zig
// styles.zig
const ui = @import("ui");

pub fn card(t: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .background = t.color.bg_secondary, .padding = ui.Padding.all(t.space._4) };
}
pub fn title(t: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = t.font_size.xxl, .font_weight = 600, .color = t.color.fg_primary };
}
```

Business code consumes them through **styled constructors**:

```zig
const S = @import("styles.zig");
const root = try ui.boxStyled(cx, S.card, .{});
try root.appendChild(a, try ui.textStyled(cx, S.title, "Hello"));
```

Styles are named, reusable, and unit-testable; grepping a name finds every
usage site.

**Theme-safe**: `boxStyled/hstackStyled/vstackStyled/textStyled` attach an
`on_theme` hook to the node — the full-tree walk performed by `Cx.setTheme`
replays the style function with the new tokens (including background/opacity
via paint_state, and marks layout dirty). By contrast, a plain
`ui.box(cx, .{ .background = cx.tokens.color.X })` is a token snapshot taken
at mount time and becomes a dead value once the theme changes.

`on_theme` is not a before_render hook: it does not run every frame and does
not affect eligibility for the promoted render cache (the
`promoted_cache_safe` predicate is unaware of it), so it is safe to use on
large containers. Limitation: `setTheme` only walks the `cx.root` subtree;
nodes in separate overlay trees are not covered.

### Layer 3: recipes — styles with variants/interaction states (the CVA / Panda equivalent)

`ui.recipe` (`src/ui/recipe.zig`) is public API; applications can define
their own recipes:

- `ui.ConditionalStyle`: a style bundle that declares base plus seven
  condition states in one place
  (selected/expanded/hover/active/focus/invalid/disabled, see the
  "Condition system" section below);
- `ui.recipe.recipe(Config)`: single-node recipe; resolve order is
  **base < variants < derived < compounds** (external style overrides come
  last);
- `ui.recipe.slotRecipe(Config)`: multi-part recipe (cf. Panda sva);
- `ui.transition("background 200ms ease-out")`: a transition declaration
  parsed at comptime.

`derived(variants, tokens)` receives the full Variants and carries
cross-dimensional composition logic (e.g. padding = f(size, icon mode)) — a
"continuous function-style composition" that neither a single-dimension
resolver nor the enum-AND-matched compounds can express. **Convention:
derived must only produce geometric fields (padding/radius/height/width/gap)
and must never touch background** (doing so would pollute the three-state
color selection of `bgColors()`).

Freeze recipe variants into theme-safe style functions (a function taking a
comptime parameter and returning a function):

```zig
pub fn panel(comptime emphasis: PanelEmphasis) fn (*const ui.ThemeTokens) ui.BoxStyle {
    return struct {
        fn f(t: *const ui.ThemeTokens) ui.BoxStyle {
            return PanelRecipe.resolveBase(.{ .emphasis = emphasis }, t);
        }
    }.f;
}
// usage: ui.boxStyled(cx, S.panel(.highlight), .{})
```

### Condition system (the curated subset of Panda conditions)

The condition flags of `ConditionalStyle` are the subset of Panda's built-in
conditions for which the component library has real consumers:

| Condition flag field | InteractionState bit | Panda equivalent | Semantics |
|---|---|---|---|
| `selected` | `is_selected` | `_checked`/`_selected` | Persistent selected/checked state (the two merged into one: they never coexist on the same node) |
| `expanded` | `is_expanded` | `_expanded` | Expanded state (accordion/tree/chevron) |
| `hover`/`active`/`focus` | `is_hovered`/`is_pressed`/`is_focused` | `_hover`/`_active`/`_focus` | Interaction states |
| `invalid` | `is_invalid` | `_invalid` | Validation failure |
| `disabled` | `is_disabled` | `_disabled` | Disabled (short-circuits; mutually exclusive with all the others) |

The resolve precedence chain is
**base ← selected ← expanded ← hover ← active ← focus ← invalid**, with
disabled short-circuiting everything. Reasons for this order:
- selected/expanded are persistent base states that interaction states layer
  on top of (a selected row can still be hover-highlighted);
- focus coming after active is an existing, deliberate design: zenit's focus
  visuals primarily go through `useFocusRing` (a separate ring layer), and
  `ConditionalStyle.focus` is the fallback channel for scenes without a
  ring; placing it later guarantees the fields it sets are not eaten by the
  interaction states;
- invalid overrides all interaction states: an error border must win over
  hover/focus (aligning with Input semantics).

**Light/dark theme is not a condition.** Theme differences are handled first
by swapping the token layer wholesale (light/dark are two complete sets of
token values, so style functions naturally receive the correct value); when
an individual style genuinely needs to branch on light/dark and it is not
worth minting a token, use the `t.scheme` escape hatch
(`ThemeTokens.ColorScheme`):

```zig
.shadow = if (t.scheme == .dark) heavy_shadow else soft_shadow,
```

No dark condition is added to ConditionalStyle — two sources of dark values
would fight each other. By the same reasoning there is no group/peer hover
(needs event-system support, tracked separately) and no pseudo-elements/media
queries (no CSS-engine counterpart).

## Reference examples

- `examples/counter_reactive/`: the full styles.zig + boxStyled/textStyled
  setup; main.zig is left with only Signal/Memo, event bindings, and the
  tree structure.
- `examples/hello_button/`: additionally contains an application-level
  custom recipe (`PanelRecipe`).
- Inside the framework: `ControlShellRecipe`
  (`src/ui/components/control_shell/`) is the most complete derived use case
  (variant × size × pill × icon_only × leading_icon).

## Decision record

- No separate styling file format: the parser, error reporting, and drift
  from the comptime type system are three costs that buy only hot reload;
  Zig struct literals are already declarative enough.
- `on_theme` kept separate from before_render: a before_render hook would
  cost the subtree its promoted content cache eligibility (render_engine
  `promoted_cache_safe`); theme replay is a low-frequency, setTheme-only
  event and should not pay a per-frame cost.
- **The component library is currently not theme-safe (a known boundary,
  not a bug)**: `ui.widgets.*` components snapshot tokens at mount time, and
  `boxStyled/textStyled` are currently used only by examples — after a
  runtime `setTheme` the component library's static colors do not update;
  the component tree has to be rebuilt. If runtime theme switching becomes
  a product requirement, rolling out on_theme replay across the component
  library is a separately scheduled migration of its own (see ROADMAP).

## `styles.zig` test collection

Every component that has its own `styles.zig` ends its `mod.zig` with:

```zig
// styles.zig 的测试收集 — 见 docs/STYLING.md
test {
    _ = @import("styles.zig");
}
```

This line is load-bearing. `const styles = @import("styles.zig")` at the top
of `mod.zig` does **not** cause the tests inside `styles.zig` to be collected:
`refAllDecls` only recurses into `pub` decls that are actually referenced, and
the import binding is not `pub`. Without the explicit `_ = @import(...)`,
tests added to `styles.zig` later are silently never run — the file compiles,
the suite is green, and the assertions never execute.

The repo has a gate for exactly this failure mode:
`bash scripts/check_orphan_tests.sh` plants a runtime failure in each test
file and verifies the suite actually goes red.

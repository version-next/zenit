//! zenit, Zig GUI Framework
//!
//! **This file is the entire public API.** Consumers use `ui.*` and
//! `ui.<group>.*` only, reaching into `core/`, `reactive/`, `i18n/` or any
//! other internal module is unsupported. Breaking either namespace is an
//! API break (see docs/API_STABILITY.md).
//!
//! Public surface organized in two layers:
//!
//! ## Tier 1, top-level (`ui.X`)
//!
//! The minimum set every app needs. Intentionally short so newcomers can
//! scroll this file end-to-end in 60 seconds:
//!
//!   - **Runtime**:  `Cx`, `Node`, `Scope`, `Style`
//!   - **Layout**:   `Padding`, `Margin`, `Border`, `Sizing`, `Color`,
//!                   `Direction`, `FlexWrap`, `CursorShape`
//!   - **Builders**: `box`, `hstack`, `vstack`, `text`, `image`, `imageTint`,
//!                   `icon`, `iconTint`, `svg`, `svgTint`, `spacer`,
//!                   `clickable`, `grid`, `GridStyle`
//!   - **Reactive**: `Signal`, `Memo`, `createEffect`, `createMemo`
//!   - **A11y**:     `A11yRole`, `A11yProps`
//!   - **Control flow**: `Show`, `For`, `Match`
//!
//! ## Tier 2, sub-namespaces (`ui.<group>.X`)
//!
//! Grouped by concern. Reach for these when you need more than the basics:
//!
//!   - `ui.widgets`, full component library: `Button`, `Input`, `Modal`,
//!                        `Tabs`, `VirtualList`, `Calendar`, `Form`, ...
//!   - `ui.fx`, animation, physics, router, view transitions
//!   - `ui.events`, full `Event` enum + every event payload type
//!   - `ui.hooks`, `useHover`, `useFocusRing`, `useHoverHighlight`, ...
//!   - `ui.reactive`, full reactive system (`Signal` etc. also at top)
//!   - `ui.focus`, `FocusManager`, focus scopes, tab order
//!   - `ui.actions`, keybinding / command dispatch
//!   - `ui.theme`, `ThemeTokens` + builtin light/dark themes
//!   - `ui.control_flow`, `Show`/`For`/`Match` (also top-level)
//!   - `ui.assets`, `SvgAsset` registry, builtin icons
//!   - `ui.hit`, hit-testing types (`HitQuery`, `HitShapeSpec`, ...)
//!   - `ui.path`, path geometry types (`PathCommand`, `Transform2D`, ...)
//!   - `ui.devtools`, `Inspector`, debug tracing
//!
//! Everything not on these two tiers is internal. Reach for `ui.core.*` only
//! when prototyping a fix to the framework itself.
const std = @import("std");

const core = @import("core.zig");
const reactive_mod = @import("reactive.zig");
const bind_mod = @import("bind.zig");
const events_mod = @import("events.zig");
const theme_mod = @import("theme.zig");
const hooks_mod = @import("hooks.zig");
const focus_mod = @import("focus.zig");
const actions_mod = @import("actions.zig");
const control_flow_mod = @import("control_flow.zig");
const svg_assets_mod = @import("svg_assets.zig");

// ============================================================================
// Tier 2: sub-namespaces, grouped public API
// ============================================================================

/// Full component library. See `components/mod.zig`.
pub const widgets = @import("components/mod.zig");

/// Animation / physics / view transitions / router. See `fx.zig`.
pub const fx = @import("fx.zig");

/// Full event types: `Event`, `KeyCode`, `Modifiers`, every payload struct.
pub const events = events_mod;

/// Built-in `useX` hooks (`useHover`, `useFocusRing`, ...).
pub const hooks = hooks_mod;

/// Configuration for focus outlines (logical pixels, not a blurred halo).
pub const FocusRingConfig = hooks_mod.FocusRingConfig;

/// Reactive system: `Signal`, `Memo`, `Scope`, `createEffect`, `Context`, `Store`.
/// (The most common four are also re-exported at the top level for convenience.)
pub const reactive = reactive_mod;

/// Focus manager + tab order + focus scopes.
pub const focus = focus_mod;

/// Keybinding and command dispatch.
pub const actions = actions_mod;

/// Theme tokens + built-in light/dark palettes.
pub const theme = theme_mod;

/// `Show` / `For` / `Match` declarative control-flow components.
/// (Also re-exported at the top level for convenience.)
pub const control_flow = control_flow_mod;

/// Headless interaction primitives (`interaction.drag`, `interaction.range_hover`).
/// They own event routing only, no Node output, no business state.
pub const interaction = @import("interaction/mod.zig");

/// SVG asset registry (the icon system) and built-in icon set.
pub const assets = svg_assets_mod;

/// Full icon provider catalog. Public builds default to Lucide (ISC); internal
/// applications may select or inject a separately licensed provider in their
/// build graph. Names in this namespace are provider-specific. Dynamic callers
/// can use `ui.icons.get("kebab-name")` or enumerate `ui.icons.all`.
pub const icons = @import("zenit_icons");

/// Stable semantic icon subset used by Zenit's own components. Prefer this
/// namespace in reusable framework/package code that must compile with every
/// provider; application-specific artwork should use the full `ui.icons`
/// catalog or its private provider module directly.
pub const system_icons = @import("zenit_system_icons");

/// Hit-testing query API (`HitQuery`, `HitShapeSpec`, `HitBehavior`, ...).
/// Most apps don't need this directly, `Button`/`Input` already wire hit-test.
/// System clipboard / file dialogs. These functions take `?*SystemSdk` rather than
/// hanging off `Cx`: `ui.platform_services.clipboardSetText(cx.system_sdk, text)`.
pub const platform_services = core.platform_services;

pub const hit = struct {
    pub const NodeHandle = core.NodeHandle;
    pub const HitQuery = core.HitQuery;
    pub const HitQueryKind = core.HitQueryKind;
    pub const HitResult = core.HitResult;
    pub const HitShapeSpec = core.HitShapeSpec;
    pub const ClipShapeSpec = core.ClipShapeSpec;
    pub const HitBehavior = core.HitBehavior;
    pub const HitRoles = core.HitRoles;
    pub const HitProxySpec = core.HitProxySpec;
};

/// Path geometry types, used by custom drawing & SVG hit shapes.
pub const path = struct {
    pub const Transform2D = core.Transform2D;
    pub const PathFillRule = core.PathFillRule;
    pub const LineJoin = core.LineJoin;
    pub const PathCommand = core.PathCommand;
    pub const QuadraticPathCommand = core.QuadraticPathCommand;
    pub const CubicPathCommand = core.CubicPathCommand;
    pub const PathGeometry = core.PathGeometry;
    pub const createSvgDocumentPathGeometry = core.createSvgDocumentPathGeometry;
};

/// Inspector / debug-trace surface.
///
/// `ui.devtools.overlay` is the in-window inspector overlay (a one-line
/// `attach(...)` adds dashed-rect hover highlighting). The rest of `devtools`
/// is the standalone DevTools panel, mount it in a second window for a full
/// elements / components / performance inspector.
pub const devtools = @import("devtools.zig");

/// Per-Cx Chrome-style diagnostic console. Use `cx.console()` to obtain the
/// console attached to a window.
pub const console = @import("console.zig");

/// Phase 6 gesture recognition + arbitration layer (tap/pan/long_press/triple_tap
/// + requireFailure relationships).
pub const gesture = @import("input/gesture_recognizer.zig");

/// Platform a11y wiring. **Not for app authors**: component a11y uses
/// `node.behavior.interaction.a11y` (see A11yRole / A11yProps).
///
/// Only exposes the one entry point the platform runtime needs: zenit_app registers native
/// `zenit_a11y_push_*` implementations in App.init. Tree and router consumers are all
/// internal to src/ui and import directly.
pub const a11y = struct {
    pub const wordBoundaries = @import("a11y/tree.zig").wordBoundaries;
    pub const paragraphBoundaries = @import("a11y/tree.zig").paragraphBoundaries;
    pub const characterBoundaries = @import("a11y/tree.zig").characterBoundaries;
    /// AX element identity (64-bit handle). Platform bridge (Windows UIA) queries tree by it.
    pub const AXId = @import("a11y/tree.zig").AXId;
    pub const macos_bridge = @import("a11y/macos_bridge.zig");
    /// System accessibility display preferences (reduce motion, lower transparency...).
    /// Components read via `cx.a11yPreferencesSignal()`; platform runtime injects
    /// read function here.
    pub const preferences = @import("a11y/preferences.zig");
};

/// Phase 7 Radix-style controlled/uncontrolled props types.
/// v0.2-P8 Select headless skeleton (Radix-style slot decoupling).
pub const select_headless = @import("components/select_headless/mod.zig");

/// Inspector data structure (used by the panel + accessible programmatically).
// Read-only types for text layout output below (TextLayout / LineInfo). Full
// `core.text_layout` module no longer exported; hosts need only these two types,
// module contains internal functions like computeTextLayout.
/// System font directory (font selector data layer): enumerate families +
/// determine what to draw per line.
/// WARNING: enumeration and metadata only; the font family axis doesn't exist in the render
/// pipeline yet. Selecting a family doesn't draw it; TextProps/text_run/FontSelector
/// must add family together.
/// GlyphRun shape pipeline font resolution entry. App must install its FontSelector,
/// else cursor/selection and drawing use different fonts (see
/// zenit_app.App.setFontSelector).
///
/// Exports a narrow namespace, not all of `core.layout_engine`: the layout engine is
/// internal and shouldn't appear publicly.
pub const text_shaping = struct {
    pub const ShapeFontResolveFn = core.layout_engine.ShapeFontResolveFn;
    pub const setShapeFontResolver = core.layout_engine.setShapeFontResolver;
    pub const setDrawnTextMeasure = core.layout_engine.setDrawnTextMeasure;
};
/// Text line-breaking layout output (read-only). Hosts (e.g., whiteboard apps) at
/// 'text too small, redraw layout block' degradation need per-line geometry (byte
/// range + measured width): use this type to reuse the **same glyph shaping measurement**
/// rather than writing a separate character-width estimate.
///
/// Access via `node.getLayoutOutput().artifacts.text_layout`, no module import needed.
pub const TextLayout = core.text_layout.TextLayout;
/// Single line geometry within `TextLayout`.
pub const LineInfo = core.text_layout.LineInfo;
/// Per-visual-line start offset of `TextProps.text_align`. Hosts computing own
/// cursor/hit/selection must use this formula (same source as drawing); else cursor
/// misaligns with glyphs on centered text.
pub const textAlignLineOffset = core.text_layout.alignLineOffset;
/// Baseline of a text's first line, relative to the top of its line box
/// (`font_size * line_height`): CSS half-leading over the resolved face's
/// pixel-rounded ascent/descent, the one formula layout and paint share. Hosts
/// that draw their own text beside text nodes (editor gutters, sticky headers,
/// row labels) must use it to land on the same baseline as the node's glyphs.
pub const textFirstBaseline = core.layout_engine.firstTextBaseline;
/// Accessibility bridge, wires nodes' `a11y` props to the platform.

// ============================================================================
// Tier 1: top-level, the minimum every app uses
// ============================================================================

// ── Runtime ──
pub const Cx = core.Cx;
pub const AfterLayoutResult = core.AfterLayoutResult;
pub const AfterLayoutFn = core.AfterLayoutFn;
pub const max_after_layout_rounds = core.max_after_layout_rounds;
/// Batch rectangle submission unit (see core.BulkQuad / Cx.setBulkQuads).
pub const BulkQuad = core.BulkQuad;
pub const Node = core.Node;
pub const BeforeRenderScope = core.BeforeRenderScope;
pub const PointerDownFocus = core.PointerDownFocus;
pub const Scope = reactive_mod.Scope;
pub const Style = core.Style;
pub const BoxStyle = core.BoxStyle;

// ── Layout primitives ──
pub const Color = core.Color;
pub const BlendMode = core.BlendMode;
pub const Padding = core.Padding;
pub const ComputedRect = core.ComputedRect;
pub const Margin = core.Margin;
pub const Border = core.Border;
pub const Outline = core.Outline;
pub const Sizing = core.Sizing;
pub const FlexBasis = core.FlexBasis;
pub const Size = core.Size;
pub const Point = core.Point;
pub const Direction = core.Direction;
pub const FlexWrap = core.FlexWrap;
pub const TextWrap = core.TextWrap;
pub const OverflowWrap = core.OverflowWrap;
pub const WordBreak = core.WordBreak;
pub const TextAlign = core.TextAlign;
pub const CursorShape = core.CursorShape;
pub const CursorRegion = core.CursorRegion;
pub const CursorToken = core.CursorToken;
pub const CustomCursorDesc = core.CustomCursorDesc;
pub const TextProps = core.TextProps;
pub const ImageProps = core.ImageProps;
pub const CornerRadius = core.CornerRadius;
pub const Shadow = core.Shadow;
pub const ShadowList = core.ShadowList;
pub const InsetShadowList = core.InsetShadowList;
pub const Inset = core.Inset;
pub const InsetValue = core.InsetValue;
pub const InsetShadow = core.InsetShadow;
pub const Gradient = core.Gradient;
pub const GradientStop = core.GradientStop;
pub const MultiGradient = core.MultiGradient;
pub const GradientDirection = core.GradientDirection;
pub const GlassParams = core.GlassParams;
pub const BlurGradient = core.BlurGradient;
pub const GlassSurface = core.GlassSurface;

// ── Node constructors ──
pub const box = core.box;
pub const animateNode = core.animateNode;
pub const hstack = core.hstack;
pub const vstack = core.vstack;
pub const text = core.text;
pub const textFmt = core.textFmt;

// ── Styled constructors (theme-safe named style function consumer, see docs/STYLING.md) ──
pub const boxStyled = core.boxStyled;
pub const hstackStyled = core.hstackStyled;
pub const vstackStyled = core.vstackStyled;
pub const textStyled = core.textStyled;
pub const TextStyle = core.TextStyle;
/// Style declaration: which properties declared at layer (sparse, immutable; see style_decl.zig).
pub const StyleDecl = @import("style_decl.zig").StyleDecl;

// ── Recipe (CVA/Panda-style style variant system, see docs/STYLING.md) ──
/// Module namespace: `ui.recipe.recipe(...)` / `ui.recipe.slotRecipe(...)`
pub const recipe = core.recipe;
/// Object-style styling (parallels Panda css / cva, zero runtime parsing; tokens are
/// named references, compile-time lookup):
/// `ui.css(.{ .padding = .space400, ._hover = .{ .background = .bg_hover } })`
/// or `ui.cva(.{ .base, .variants, .compound, .defaults })`.
/// See docs/STYLING.md.
pub const css = @import("css.zig").css;
pub const cva = @import("css.zig").cva;
pub const previewCss = @import("css.zig").previewCss;
pub const previewCva = @import("css.zig").previewCva;
pub const template_reload = if (@import("zenit_environment").dev_preview) @import("template_reload.zig") else struct {};
pub const style_reload = if (@import("zenit_environment").dev_preview) @import("style_reload.zig") else struct {};
pub const sva = @import("css.zig").sva;
/// Parameterized styling (.yss `style name($p: T) { ... }` output): put
/// `S.name.of(.{ .p = source })` into style; hand-written Zig uses
/// `S.name.resolve(args, t)`.
pub const paramStyle = @import("css.zig").paramStyle;
/// Fallback value for optional parameters (parameterized style `$p ?? value`).
pub const orElse = @import("css.zig").orElse;
/// Style literal -> box style (parse token by current theme; parameterized style
/// output).
pub const boxFrom = @import("css.zig").boxFrom;
/// Token color mix: `ui.mix(T.color.bg_primary, T.color.accent, 0.25)`, evaluated
/// at apply time, follows theme change.
pub const mix = @import("css.zig").mix;
pub const ColorMix = @import("css.zig").ColorMix;
/// Style field name -> token category (which token table for enum literals in
/// css/cva/sva). Toolchain: .yss schema generated by reflection.
pub const styleCategory = @import("css.zig").catOf;
pub const StyleCategory = @import("css.zig").Category;
/// Get token reference by name (same parsing as enum literals in css/cva/sva:
/// original name first, then with `-` replaced by `_`). .yss mix() operands looked up via it.
pub const tokenRef = @import("css.zig").tokenRef;
/// CSS-style transition declaration: write `.transition = ui.transition("background
/// 150ms ease-out")` in style object.
pub const transition = @import("recipe.zig").transition;
pub const ConditionalStyle = core.ConditionalStyle;
pub const ThemeTokens = theme_mod.ThemeTokens;
pub const ColorScheme = theme_mod.ColorScheme;

/// Arbitrary value escape hatch, parallel to Panda CSS arbitrary values (`[18px]` / `[#316ff6]`).
/// Tokens are the default, but designs do include off-scale values (matching specific mockups,
/// one-off brand colors, pixel-level tweaks). Don't write bare literals; wrap with `ui.arb.*`:
///
/// ```zig
/// .font_size = ui.arb.px(18),          // deliberately off-scale, not laziness
/// .background = ui.arb.hex(0x316FF6),  // one-off brand color
/// ```
///
/// Zero runtime cost (always inline); semantic and tooling value:
///   - readers distinguish "intentional arbitrary value" from "lazy literal needing token
///     migration";
///   - scripts/check_style_literals.sh ratchet catches bare literals, arb passes naturally;
///   - global `grep ui.arb` inventories all off-token values for promotion evaluation.
pub const arb = struct {
    /// Arbitrary size/font size (px).
    pub inline fn px(v: f32) f32 {
        return v;
    }
    /// Arbitrary color (0xRRGGBB).
    pub inline fn hex(rgb: u24) Color {
        return Color.hex(rgb);
    }
    /// Arbitrary color (0xRRGGBB + alpha 0..1).
    pub inline fn hexA(rgb: u24, alpha: f32) Color {
        const a: u8 = @intFromFloat(@round(std.math.clamp(alpha, 0.0, 1.0) * 255.0));
        return Color.hex(rgb).withAlpha(a);
    }
};
pub const image = core.image;
pub const imageTint = core.imageTint;
pub const svg = core.svg;
pub const svgTint = core.svgTint;
pub const spacer = core.spacer;
pub const clickable = core.clickable;
pub const grid = core.grid;
pub const GridStyle = core.GridStyle;
pub const GridTrackSize = core.GridTrackSize;
pub const GridPlacement = core.GridPlacement;

pub const SvgAsset = svg_assets_mod.Asset;

pub fn icon(cx: *Cx, asset: SvgAsset, style: Style) !*Node {
    return core.icon(cx, asset, applyAssetSizeDefaults(asset, style));
}

pub fn iconTint(cx: *Cx, asset: SvgAsset, tint: Color, style: Style) !*Node {
    return core.iconTint(cx, asset, tint, applyAssetSizeDefaults(asset, style));
}

/// BoxStyle icon constructor with background/opacity paint overrides.
/// Kept additive so existing callers that pass a concrete Style remain source
/// compatible; new code that needs opacity should use this entry point.
pub fn iconTintStyled(cx: *Cx, asset: SvgAsset, tint: Color, style: core.BoxStyle) !*Node {
    return core.iconTintStyled(cx, asset, tint, applyAssetBoxSizeDefaults(asset, style));
}

pub fn iconStyled(cx: *Cx, asset: SvgAsset, style: core.BoxStyle) !*Node {
    return core.iconStyled(cx, asset, applyAssetBoxSizeDefaults(asset, style));
}

fn applyAssetSizeDefaults(asset: SvgAsset, style: Style) Style {
    var resolved = style;
    if (!isFixedPxSizing(resolved.width)) {
        resolved.width = .{ .px = @floatFromInt(asset.default_width) };
    }
    if (!isFixedPxSizing(resolved.height)) {
        resolved.height = .{ .px = @floatFromInt(asset.default_height) };
    }
    return resolved;
}

fn applyAssetBoxSizeDefaults(asset: SvgAsset, style: core.BoxStyle) core.BoxStyle {
    var resolved = style;
    if (resolved.width == null or !isFixedPxSizing(resolved.width.?)) {
        resolved.width = .{ .px = @floatFromInt(asset.default_width) };
    }
    if (resolved.height == null or !isFixedPxSizing(resolved.height.?)) {
        resolved.height = .{ .px = @floatFromInt(asset.default_height) };
    }
    return resolved;
}

fn isFixedPxSizing(sizing: Sizing) bool {
    return switch (sizing) {
        .px => true,
        else => false,
    };
}

// -- Reactive essentials (full surface lives in `ui.reactive`) --
// App code always creates via Scope: `scope.createSignal / createMemo /
// createEffect`, lifetime follows scope (disposed on component unmount). Owner-level
// free functions (`ui.reactive.createEffect/createMemo`,
// `Signal(T).create(owner, ...)`) are low-level primitives not released with scope,
// not exported at top level.
pub const Signal = reactive_mod.Signal;
pub const Memo = reactive_mod.Memo;

// -- Signal-first component props (docs/SIGNAL_API_DESIGN.md) --
// Component props: read-only use `Source(T)`, controlled values (component proposes
// write-back, data source decides) use `Model(T)`, events use `Handler(T)`.
// Call sites write literals / `*Signal` / derived values; `props.coerce` normalizes
// at comptime.
pub const Source = reactive_mod.Source;
pub const Model = reactive_mod.Model;
pub const Handler = core.Handler;
pub const Derived = reactive_mod.Derived;
pub const split = reactive_mod.split;
pub const derive = reactive_mod.derive;
pub const not = reactive_mod.not;
pub const eq = reactive_mod.eq;
pub const map = reactive_mod.map;
pub const map2 = reactive_mod.map2;
pub const field = reactive_mod.field;
pub const assumeOutlives = reactive_mod.assumeOutlives;
pub const bind = bind_mod.bind;
pub const bindText = bind_mod.bindText;
pub const bindTextLabel = bind_mod.bindTextLabel;
pub const bindTextA11y = bind_mod.bindTextA11y;
pub const rebuildOn = bind_mod.rebuildOn;
pub const bindOptionalTextRow = bind_mod.bindOptionalTextRow;

// ── Control flow (full surface lives in `ui.control_flow`) ──
pub const Show = control_flow_mod.Show;
pub const For = control_flow_mod.For;
pub const Match = control_flow_mod.Match;

// ── Declarative view tree (Solid-style JSX Zig version; see docs/VIEW_DSL.md) ──
// `const v = ui.view;` then `v.render(scope, cx, v.col(.{ .style = S.root }, .{ ... }))`.
pub const view = @import("view.zig");
/// Component protocol for `ui.view` (mount returns Result; component implements
/// `viewParts`).
pub const ViewParts = @import("view_parts.zig").ViewParts;
/// Event composer: `.on_click = ui.on.set(sig, v) / toggle / update / assign / call /
/// bind`. (Keyboard binding Action system is `ui.actions`, separate.)
pub const on = @import("on.zig");

// ── A11y ──
pub const A11yRole = core.A11yRole;
pub const A11yProps = core.A11yProps;
pub const A11yOrientation = core.A11yOrientation;
pub const A11ySortDirection = core.A11ySortDirection;
pub const A11yRect = core.A11yRect;
pub const A11yValueRange = core.A11yValueRange;
pub const TextInputClient = core.TextInputClient;
pub const TextInputSelection = core.TextInputSelection;

// ── Handler / event types most apps need at the top level ──
// (Full `Event` enum + payload structs live in `ui.events`.)
pub const HandlerRef = core.HandlerRef;

// Note: original `core_internal` top-level export removed in Phase 7 (OSS boundary discipline).
// Framework contributors directly @import("core.zig") (inside ui module);
// external consumers should only use `ui.*` namespace public API.

// addNativeLibs links window_bridge.m on macOS, and it calls the zenit_a11y_*
// functions exported from macos_bridge.zig. Analyse that file whenever ui is in
// the graph: a consumer that never reaches Cx (an app's unit tests) still links.
comptime {
    if (@import("builtin").os.tag == .macos) {
        _ = @import("a11y/macos_bridge.zig");
        _ = @import("a11y/preferences.zig");
    }
}

// Load internal contract tests independently of the unnamed API smoke test.
// A narrow --test-filter can exclude that smoke test before these modules are
// reached through public functions, otherwise returning success with no cases.
comptime {
    if (@import("builtin").is_test) {
        _ = @import("core/cx_a11y.zig");
        _ = @import("core/a11y_projection.zig");
        _ = @import("core/a11y_geometry.zig");
        _ = @import("components/input/textarea.zig");
        _ = @import("components/input/render.zig");
    }
}

test {
    _ = @import("hooks_test.zig");
    _ = @import("bind.zig");
    // refAllDecls doesn't collect test blocks in subfiles; new modules need explicit
    // import (see docs/STYLING.md).
    _ = @import("view.zig");
    _ = @import("on.zig");
    _ = @import("style_decl.zig");
    std.testing.refAllDecls(@This());
}

test "公共命名空间不泄漏渲染引擎内部（发布后删 pub 是 break-API）" {
    // ui.zig's top-level declarations are a locked two-level namespace. Internal modules
    // (e.g. render_engine, which exposes mutable globals current_frame_* clock +
    // setFrameClock that let consumers corrupt the clock) must not leak into it; this
    // contradicts API_STABILITY.md listing render_engine as Internal.
    //
    // check_oss_boundary.sh can't catch this: it checks what src/ui/ imports and
    // hello_button links, never root-module pub. Guard here.
    //
    // Hooks needing frame time use read-only `ui.frame.*` (can't reach Cx) or
    // `cx.frame_time_ms` (multi-window correct).
    //
    // Whitelist, not blacklist: a new top-level namespace must be registered here,
    // forcing the author to answer 'why show app authors this'. Only namespaces (pub
    // const x = @import(...)) are covered, not value types/functions; those are abundant
    // and per-item cost exceeds gain.
    @setEvalBranchQuota(4000);
    const allowed_namespaces = [_][]const u8{
        // Components and effects.
        "widgets",      "fx",                "interaction",     "select_headless",
        // Resources.
        "icons",        "system_icons",      "assets",
        // Capability domains.
                 "theme",
        "reactive",     "control_flow",      "actions",         "focus",
        // Declarative view tree and event composer: app author main UI entry
        // (docs/VIEW_DSL.md).
        "view",         "on",                "hit",             "path",
        "a11y",         "recipe",            "styles",          "arb",
        "text_shaping", "platform_services", "gesture",         "input",
        // Preview protocol bridge for zenit_app and custom UI-thread hosts only.
        // Unstable development capability; both namespaces are empty without dev-preview.
        "style_reload", "theme_reload",      "template_reload",
        // Tools and diagnostics.
        "devtools",
        "console",      "frame",             "router",          "animation",
        "hooks",        "events",            "math",
    };
    inline for (@typeInfo(@This()).@"struct".decl_names) |name| {
        const T = @TypeOf(@field(@This(), name));
        if (T == type and @typeInfo(@field(@This(), name)) == .@"struct") {
            // Only check 'looks like namespace': struct type, lowercase start.
            if (name[0] >= 'a' and name[0] <= 'z') {
                var ok = false;
                inline for (allowed_namespaces) |allowed| {
                    if (std.mem.eql(u8, name, allowed)) ok = true;
                }
                if (!ok) {
                    std.debug.print(
                        "ui.{s} 是个未登记的顶层命名空间。\n" ++
                            "  内部实现不该进公共面；确实要公开就加进 ui.zig 的 " ++
                            "allowed_namespaces，并在那里说明它面向谁。\n",
                        .{name},
                    );
                    return error.UnregisteredPublicNamespace;
                }
            }
        }
    }
    // The read-only frame clock must be present (it is the replacement path for the removed
    // render_engine clock).
    try std.testing.expect(@hasDecl(@This(), "frame"));
    _ = frame.timeMs();
    _ = frame.dtSeconds();
    _ = frame.dtMs();
    _ = frame.estimateTimeMs();
    // debug_trace **capability** public (DevTools Render/Trace data source;
    // host custom inspector needs); just shouldn't top-level. Move under devtools.
    try std.testing.expect(@hasDecl(devtools, "trace"));
    try std.testing.expect(@hasDecl(devtools.trace, "setGlobalTraceTarget"));
    try std.testing.expect(@hasDecl(devtools.trace, "clearGlobalTraceTarget"));
}

// Sliced work scheduler: only export `Cx.enqueueTask` / `Cx.cancelTask` truly
// need types.
//
// The work family (work / WorkPriority / WorkKey / WorkSpec / WorkResult / WorkHandle /
// Task) is **not usable from outside**: `WorkResult.step` is `WorkStep`, which is not
// exported, so callers can't construct the `Task.runSlice` return. Not a designed
// public surface.
//
// Hosts needing custom-sliced tasks: file an issue for `WorkStep`, then export this
// vocab set in one coordinated change (internal dual Task/TaskPriority and Work* naming).
pub const Task = core.Task;
pub const WorkKey = core.WorkKey;
/// Flattened render-output instruction item, `ui` layer final product (`render` layer
/// consumes). Custom-draw callbacks receive this.
pub const DisplayItem = core.DisplayItem;

/// Four-corner corner radius (`CornerRadii.fromArray([4]f32)`).
///
/// A host appending a screen-space diagnostic item to `cx.lowering.main_paint` after
/// `Cx.render()` needs it to build `.radii`. paint_table is internal, but this type is
/// required on the public path; export the type alone, not the whole module.
pub const CornerRadii = core.paint_table.CornerRadii;
pub const DrawContext = core.DrawContext;
pub const IconProps = core.IconProps;
pub const AlignItems = core.AlignItems;
pub const AlignContent = core.AlignContent;
pub const JustifyContent = core.JustifyContent;
/// Frame clock **read-only** view.
///
/// `before_render` hook gets `*Node`, can't reach `Cx`, but time-driven animation
/// (blur sweep, Spinner direct-style) needs the current time. Exposes only a read-only
/// view, not `ui.render_engine` (mutable clock globals + setFrameClock).
///
/// Have `Cx` -> prefer `cx.frame_time_ms` (per-context, multi-window correct);
/// use this namespace where callbacks can't reach Cx.
pub const frame = struct {
    /// Current frame absolute timestamp (ms), monotonic, relative app start.
    pub inline fn timeMs() f64 {
        return core.render_engine.current_frame_time_ms;
    }
    /// Current frame dt (seconds).
    pub inline fn dtSeconds() f32 {
        return core.render_engine.current_frame_dt_seconds;
    }
    /// Current frame dt (ms); Spring-type incremental consumers use.
    pub inline fn dtMs() f32 {
        return core.render_engine.current_frame_dt_ms;
    }
    /// Estimate 'now' timestamp (ms).
    ///
    /// Events may fire between frames; `timeMs()` stops at last frame. This adds
    /// elapsed in-frame from real monotonic clock; input-driven animation (tap
    /// highlight, blink) uses to avoid frame-worth skew.
    pub inline fn estimateTimeMs() f64 {
        return core.render_engine.estimateTimeMs();
    }
};

/// Token parsing and transaction storage are unreachable in release builds.
pub const theme_reload = if (@import("zenit_environment").dev_preview) @import("theme_reload.zig") else struct {};

test {
    const environment = @import("zenit_environment");
    if (environment.lp3_gate) {
        _ = @import("template.zig");
        _ = @import("template_equivalence_tests.zig");
    }
    if (environment.lp4_gate) {
        _ = @import("template_reload_tests.zig");
    }
    if (environment.lp2_gate) {
        _ = @import("style_reload_tests.zig");
        _ = @import("style_reload_manifest.zig");
    }
}

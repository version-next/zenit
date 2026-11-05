/// Recipe: style variant system
///
/// Inspired by Panda CSS (cva/sva) and CVA (Class Variance Authority);
/// uses Zig comptime for zero-runtime-cost declarative style variants.
///
/// Three-layer architecture:
///   1. ConditionalStyle: style bundle with interaction conditions (maps to Panda Conditions:
///      _hover/_active/_disabled)
///   2. recipe(): single-node recipe (maps to CVA cva())
///   3. slotRecipe(): multi-slot recipe (maps to Panda sva())
///
/// CSS Transition parser:
///   4. transition(): comptime-parse CSS-style transition strings
///
/// Usage example:
/// ```zig
/// // CSS transition string -> compile-time parse
/// try node.applyTransition(allocator, comptime transition("background 200ms ease-out, opacity 150ms"));
///
/// // Recipe definition
/// const ButtonRecipe = recipe(struct {
///     pub const Variants = struct { variant: ControlVariant = .primary, size: ControlSize = .md };
///     pub fn base(t: *const ThemeTokens) ConditionalStyle { ... }
///     pub const variants = .{ .variant = resolveVariant, .size = resolveSize };
/// });
///
/// // Usage
/// const styles = ButtonRecipe.resolve(.{ .variant = .primary, .size = .md }, cx.tokens);
/// ```
const std = @import("std");
const types = @import("core/types.zig");
const theme = @import("theme.zig");

pub const Color = types.Color;
pub const StyleOverride = types.StyleOverride;
pub const TransitionProp = types.TransitionProp;
pub const TransitionSpec = types.TransitionSpec;
pub const Easing = types.Easing;
pub const InteractionState = types.InteractionState;
pub const ThemeTokens = theme.ThemeTokens;

// ============================================================================
// 1. ConditionalStyle: style bundle with interaction conditions
// ============================================================================

/// Declarative style set: base + seven conditional states.
///
/// Aligns with Panda CSS conditions:
///   css({ bg: "red.500", _hover: { bg: "red.700" }, _disabled: { opacity: 0.5 } })
/// Supported: _hover/_active/_focus/_disabled + _checked(->selected)/_expanded/_invalid.
/// Excluded: _dark (theme diff via token swap + t.scheme in style functions, no style-level
/// condition to avoid conflicts), group/peer hover (needs event system support),
/// pseudo-elements/media queries (no CSS engine analogue).
///
/// Each variant value self-contains all interaction-state styles.
pub const ConditionalStyle = struct {
    /// Base state (always applied)
    base: StyleOverride = .{},
    /// Persistent selected/checked state (selected and checked unified, see
    /// InteractionState.is_selected)
    selected: ?StyleOverride = null,
    /// Expanded state (accordion item / tree node / chevron)
    expanded: ?StyleOverride = null,
    /// Hover state (merged over base on mouse hover)
    hover: ?StyleOverride = null,
    /// Active / pressed state
    active: ?StyleOverride = null,
    /// Focus state
    focus: ?StyleOverride = null,
    /// Focus-visible state: focus via keyboard etc, not click (layers after focus)
    focus_visible: ?StyleOverride = null,
    /// Invalid state (after interaction states in chain: error visual overrides hover/focus,
    /// aligns with Input semantics, suppresses focus/hover border changes on error)
    invalid: ?StyleOverride = null,
    /// Disabled state (when disabled, no other conditional states layer)
    disabled: ?StyleOverride = null,

    /// Runtime resolution: final StyleOverride per state. Priority (low to high):
    ///   base <- selected <- expanded <- hover <- active <- focus <- focus_visible <- invalid <-
    ///   disabled
    /// - selected/expanded persistent base states; interaction states layer over;
    /// - invalid overrides interaction states; disabled short-circuits (no state stacking).
    pub fn resolve(self: ConditionalStyle, state: InteractionState) StyleOverride {
        var result = self.base;
        if (state.is_disabled) {
            if (self.disabled) |d| result = result.merge(d);
            return result;
        }
        if (state.is_selected) {
            if (self.selected) |s| result = result.merge(s);
        }
        if (state.is_expanded) {
            if (self.expanded) |e| result = result.merge(e);
        }
        if (state.is_hovered) {
            if (self.hover) |h| result = result.merge(h);
        }
        if (state.is_pressed) {
            if (self.active) |a| result = result.merge(a);
        }
        if (state.is_focused) {
            if (self.focus) |f| result = result.merge(f);
        }
        if (state.is_focus_visible) {
            if (self.focus_visible) |f| result = result.merge(f);
        }
        if (state.is_invalid) {
            if (self.invalid) |iv| result = result.merge(iv);
        }
        return result;
    }

    /// Deep merge two ConditionalStyle objects (aligns with Panda mergeCss recursive merge)
    ///
    /// Latter overrides former (non-null fields override)
    pub fn merge(self: ConditionalStyle, other: ConditionalStyle) ConditionalStyle {
        return .{
            .base = self.base.merge(other.base),
            .selected = mergeOptionalOverride(self.selected, other.selected),
            .expanded = mergeOptionalOverride(self.expanded, other.expanded),
            .hover = mergeOptionalOverride(self.hover, other.hover),
            .active = mergeOptionalOverride(self.active, other.active),
            .focus = mergeOptionalOverride(self.focus, other.focus),
            .focus_visible = mergeOptionalOverride(self.focus_visible, other.focus_visible),
            .invalid = mergeOptionalOverride(self.invalid, other.invalid),
            .disabled = mergeOptionalOverride(self.disabled, other.disabled),
        };
    }

    /// Override base state with external StyleOverride (for component style prop to override recipe
    /// output)
    ///
    /// Typical case: Button style/hover_style/pressed_style props
    pub fn override(self: ConditionalStyle, overrides: struct {
        style: StyleOverride = .{},
        selected_style: ?StyleOverride = null,
        expanded_style: ?StyleOverride = null,
        hover_style: ?StyleOverride = null,
        pressed_style: ?StyleOverride = null,
        focus_style: ?StyleOverride = null,
        invalid_style: ?StyleOverride = null,
        disabled_style: ?StyleOverride = null,
    }) ConditionalStyle {
        var result = self;
        if (!overrides.style.isEmpty()) {
            result.base = result.base.merge(overrides.style);
        }
        if (overrides.selected_style) |s| {
            result.selected = mergeOptionalOverride(result.selected, s);
        }
        if (overrides.expanded_style) |e| {
            result.expanded = mergeOptionalOverride(result.expanded, e);
        }
        if (overrides.hover_style) |h| {
            result.hover = mergeOptionalOverride(result.hover, h);
        }
        if (overrides.pressed_style) |a| {
            result.active = mergeOptionalOverride(result.active, a);
        }
        if (overrides.focus_style) |f| {
            result.focus = mergeOptionalOverride(result.focus, f);
        }
        if (overrides.invalid_style) |iv| {
            result.invalid = mergeOptionalOverride(result.invalid, iv);
        }
        if (overrides.disabled_style) |d| {
            result.disabled = mergeOptionalOverride(result.disabled, d);
        }
        return result;
    }

    /// Check if completely empty
    pub fn isEmpty(self: ConditionalStyle) bool {
        return self.base.isEmpty() and
            self.selected == null and
            self.expanded == null and
            self.hover == null and
            self.active == null and
            self.focus == null and
            self.focus_visible == null and
            self.invalid == null and
            self.disabled == null;
    }

    fn mergeOptionalOverride(a: ?StyleOverride, b: ?StyleOverride) ?StyleOverride {
        if (a == null and b == null) return null;
        if (a == null) return b;
        if (b == null) return a;
        return a.?.merge(b.?);
    }
};

// ============================================================================
// 2. recipe(): single-node recipe (maps to CVA cva())
// ============================================================================

/// comptime Recipe factory function
///
/// Core algorithm follows CVA:
///   resolve(props) = merge(base, ...variants[dim][props[dim]], ...matchedCompounds)
///
/// Config:
///   - Variants: struct type, each field a variant dimension (enum or bool) with default
///   - base(tokens) -> ConditionalStyle (optional)
///   - variants: tuple of fn(value, tokens) -> ConditionalStyle (optional)
///   - derived(variants, tokens) -> ConditionalStyle (optional): cross-dimension logic over
///     the full Variants (e.g. padding = f(size, icon mode)). Prefer for continuous geometry;
///     not a field whitelist.
///   - compounds: tuple of { matches: fn(Variants) -> bool, style: fn(tokens) -> ConditionalStyle }
pub fn recipe(comptime Config: type) type {
    comptime {
        if (!@hasDecl(Config, "Variants")) @compileError("Recipe Config 必须有 Variants 类型");
    }

    return struct {
        pub const Variants = Config.Variants;

        /// Core resolve, aligns with CVA resolve(props)
        ///
        /// Merge priority: base < variants < derived < compounds (latter overrides)
        pub fn resolve(variants: Variants, tokens: *const ThemeTokens) ConditionalStyle {
            if (@import("zenit_environment").dev_preview) @import("style_reload.zig").observeGeneration();
            // Step 1: base
            var result: ConditionalStyle = if (@hasDecl(Config, "base"))
                Config.base(tokens)
            else
                .{};

            // Step 2: iterate each variant dimension, merge its selected value's style
            if (@hasDecl(Config, "variants")) {
                inline for (@import("zenit_reflection").fields(@TypeOf(Config.variants))) |field| {
                    const dim_resolver = @field(Config.variants, field.name);
                    const variant_value = @field(variants, field.name);
                    const variant_style = dim_resolver(variant_value, tokens);
                    result = result.merge(variant_style);
                }
            }

            // Step 2.5: derived, cross-dimension combo (full Variants)
            if (@hasDecl(Config, "derived")) {
                result = result.merge(Config.derived(variants, tokens));
            }

            // Step 3: compound variants, AND match
            if (@hasDecl(Config, "compounds")) {
                inline for (Config.compounds) |compound| {
                    if (compound.matches(variants)) {
                        result = result.merge(compound.style(tokens));
                    }
                }
            }

            return result;
        }

        /// Convenience method: extract base-state StyleOverride only
        pub fn resolveBase(variants: Variants, tokens: *const ThemeTokens) StyleOverride {
            return resolve(variants, tokens).base;
        }
    };
}

// ============================================================================
// 3. slotRecipe(): multi-slot recipe (maps to Panda sva())
// ============================================================================

/// comptime SlotRecipe factory function
///
/// Follows Panda getSlotRecipes() + sva(): run recipe resolve independently per slot, so one
/// variant value yields styles for all slots.
///
/// Config:
///   - Slots: struct type, each field a ConditionalStyle (one component part)
///   - Variants: struct type (same as recipe)
///   - base(tokens) -> Slots (optional)
///   - variants: tuple of fn(value, tokens) -> Slots (optional)
///   - compounds: tuple of { matches, style -> Slots } (optional)
pub fn slotRecipe(comptime Config: type) type {
    comptime {
        if (!@hasDecl(Config, "Slots")) @compileError("SlotRecipe Config 必须有 Slots 类型");
        if (!@hasDecl(Config, "Variants")) @compileError("SlotRecipe Config 必须有 Variants 类型");
        // Validate each Slots field is ConditionalStyle
        for (@import("zenit_reflection").fields(Config.Slots)) |field| {
            if (field.type != ConditionalStyle) {
                @compileError("Slots." ++ field.name ++ " 必须是 ConditionalStyle 类型");
            }
        }
    }

    return struct {
        pub const Slots = Config.Slots;
        pub const Variants = Config.Variants;

        /// Core resolve, returns ConditionalStyle per slot
        pub fn resolve(variants: Variants, tokens: *const ThemeTokens) Slots {
            if (@import("zenit_environment").dev_preview) @import("style_reload.zig").observeGeneration();
            // Step 1: base
            var result: Slots = if (@hasDecl(Config, "base"))
                Config.base(tokens)
            else
                .{};

            // Step 2: iterate variant dimensions
            if (@hasDecl(Config, "variants")) {
                inline for (@import("zenit_reflection").fields(@TypeOf(Config.variants))) |field| {
                    const dim_resolver = @field(Config.variants, field.name);
                    const variant_value = @field(variants, field.name);
                    const slot_styles: Slots = dim_resolver(variant_value, tokens);
                    // merge each slot
                    inline for (@import("zenit_reflection").fields(Slots)) |sf| {
                        @field(result, sf.name) = @field(result, sf.name)
                            .merge(@field(slot_styles, sf.name));
                    }
                }
            }

            // Step 2.5: derived, cross-dimension combo (full Variants, same convention as recipe)
            if (@hasDecl(Config, "derived")) {
                const derived_slots: Slots = Config.derived(variants, tokens);
                inline for (@import("zenit_reflection").fields(Slots)) |sf| {
                    @field(result, sf.name) = @field(result, sf.name)
                        .merge(@field(derived_slots, sf.name));
                }
            }

            // Step 3: compound variants
            if (@hasDecl(Config, "compounds")) {
                inline for (Config.compounds) |compound| {
                    if (compound.matches(variants)) {
                        const compound_slots: Slots = compound.style(tokens);
                        inline for (@import("zenit_reflection").fields(Slots)) |sf| {
                            @field(result, sf.name) = @field(result, sf.name)
                                .merge(@field(compound_slots, sf.name));
                        }
                    }
                }
            }

            return result;
        }
    };
}

// ============================================================================
// 4. transition(): CSS-style transition string comptime parser
// ============================================================================

/// Parse result: array of (property, config) tuples
pub const TransitionEntry = struct {
    prop: TransitionProp,
    spec: TransitionSpec,
};

/// Compile-time parse a CSS transition string into a fixed-size array.
///
/// Supported formats (CSS transition syntax):
///   "background 200ms ease-out"
///   "background 200ms ease-out, opacity 150ms"
///   "background 200ms, opacity 150ms linear"
///   "all 200ms ease-out"               <- all animatable properties
///   "background 0.2s ease-in-out"       <- second units
///   "background 200ms"                  <- omit easing -> default ease-out-quad
///   "background"                        <- omit duration -> default 150ms
///
/// Property name mapping (CSS -> TransitionProp):
///   background / background-color / bg    -> .background
///   opacity                               -> .opacity
///   border-color                          -> .border_color
///   border-width                          -> .border_width
///   translate-x / translateX / transform-x -> .translate_x
///   translate-y / translateY / transform-y -> .translate_y
///   scale-x / scaleX                      -> .scale_x
///   scale-y / scaleY                      -> .scale_y
///   rotate / rotation                     -> .rotate
///   corner-radius / border-radius         -> .corner_radius
///   all                                   -> all 11 properties
///
/// Easing name mapping (CSS -> Easing):
///   linear                                -> .linear
///   ease / ease-out / ease-in / ease-in-out -> quad versions
///   ease-out-cubic / ease-in-cubic / ...   -> corresponding Easing enum
///   spring / bounce                       -> ease_out_back / ease_out_bounce
///
/// Example:
/// ```zig
/// const spec = comptime transition("background 200ms ease-out, opacity 150ms");
/// try node.applyTransition(allocator, &spec);
/// ```
pub fn transition(comptime input: []const u8) [countTransitionEntries(input)]TransitionEntry {
    @setEvalBranchQuota(10000);
    return comptime parseTransition(input);
}

/// Comptime compute result array size
fn countTransitionEntries(comptime input: []const u8) usize {
    @setEvalBranchQuota(10000);
    comptime {
        var count: usize = 0;
        const segments = splitByComma(input);
        for (segments.items[0..segments.len]) |segment| {
            const prop_str = firstToken(segment);
            if (eqlIgnoreCase(prop_str, "all")) {
                count += 11; // all transitionable properties
            } else {
                count += 1;
            }
        }
        return count;
    }
}

/// Comptime-parse transition string
fn parseTransition(comptime input: []const u8) [countTransitionEntries(input)]TransitionEntry {
    @setEvalBranchQuota(10000);
    comptime {
        const N = countTransitionEntries(input);
        var result: [N]TransitionEntry = undefined;
        var idx: usize = 0;

        const segments = splitByComma(input);

        for (segments.items[0..segments.len]) |segment| {
            const tokens = tokenize(segment);

            // First token is property name
            const prop_str = tokens.items[0];
            // Find duration and easing in following tokens
            // Words other than duration/easing are typos (previously silently ignored, reverted to
            // defaults)
            for (tokens.items[1..tokens.len]) |w| {
                if (parseDurationValue(w) == null and parseEasingName(w) == null)
                    @compileError("transition \"" ++ segment ++ "\": `" ++ w ++ "` is neither a duration (200ms, 0.2s, a duration token such as fast) nor an easing");
            }
            const duration = findDuration(tokens);
            const easing = findEasing(tokens);
            const spec = TransitionSpec{
                .duration_ms = duration,
                .easing = easing,
            };

            if (eqlIgnoreCase(prop_str, "all")) {
                // "all" -> expands to all 11 properties
                const all_props = [_]TransitionProp{
                    .background,   .opacity,     .border_color,
                    .translate_x,  .translate_y, .scale_x,
                    .scale_y,      .rotate,      .corner_radius,
                    .border_width, .width,
                };
                for (all_props) |prop| {
                    result[idx] = .{ .prop = prop, .spec = spec };
                    idx += 1;
                }
            } else {
                const prop = parsePropName(prop_str) orelse
                    @compileError("未知的 transition 属性: \"" ++ prop_str ++ "\"\n支持的属性: background, opacity, border-color, border-width, translate-x, translate-y, scale-x, scale-y, rotate, corner-radius, width, all");
                result[idx] = .{ .prop = prop, .spec = spec };
                idx += 1;
            }
        }

        return result;
    }
}

// -- Property name parsing ----------------

fn parsePropName(comptime name: []const u8) ?TransitionProp {
    // background family
    if (eqlIgnoreCase(name, "background") or
        eqlIgnoreCase(name, "background-color") or
        eqlIgnoreCase(name, "bg")) return .background;

    // opacity
    if (eqlIgnoreCase(name, "opacity")) return .opacity;

    // border-color
    if (eqlIgnoreCase(name, "border-color") or
        eqlIgnoreCase(name, "borderColor") or
        eqlIgnoreCase(name, "border_color")) return .border_color;

    // border-width
    if (eqlIgnoreCase(name, "border-width") or
        eqlIgnoreCase(name, "borderWidth") or
        eqlIgnoreCase(name, "border_width")) return .border_width;

    // translate-x
    if (eqlIgnoreCase(name, "translate-x") or
        eqlIgnoreCase(name, "translateX") or
        eqlIgnoreCase(name, "translate_x") or
        eqlIgnoreCase(name, "transform-x")) return .translate_x;

    // translate-y
    if (eqlIgnoreCase(name, "translate-y") or
        eqlIgnoreCase(name, "translateY") or
        eqlIgnoreCase(name, "translate_y") or
        eqlIgnoreCase(name, "transform-y")) return .translate_y;

    // scale-x
    if (eqlIgnoreCase(name, "scale-x") or
        eqlIgnoreCase(name, "scaleX") or
        eqlIgnoreCase(name, "scale_x")) return .scale_x;

    // scale-y
    if (eqlIgnoreCase(name, "scale-y") or
        eqlIgnoreCase(name, "scaleY") or
        eqlIgnoreCase(name, "scale_y")) return .scale_y;

    // rotate
    if (eqlIgnoreCase(name, "rotate") or
        eqlIgnoreCase(name, "rotation")) return .rotate;

    // corner-radius
    if (eqlIgnoreCase(name, "corner-radius") or
        eqlIgnoreCase(name, "border-radius") or
        eqlIgnoreCase(name, "borderRadius") or
        eqlIgnoreCase(name, "corner_radius")) return .corner_radius;

    // width
    if (eqlIgnoreCase(name, "width")) return .width;

    // text color
    if (eqlIgnoreCase(name, "color") or
        eqlIgnoreCase(name, "text-color") or
        eqlIgnoreCase(name, "text_color")) return .text_color;

    return null;
}

// -- Duration parsing ----------------

/// Find duration value in tokens (number + ms/s suffix)
fn findDuration(comptime tokens: Tokens) f32 {
    comptime {
        // Start from second token (first is property name)
        for (tokens.items[1..tokens.len]) |token| {
            if (parseDurationValue(token)) |d| return d;
        }
        return 150; // default 150ms
    }
}

/// Try parsing "200ms" / "0.2s" / "200" as milliseconds
fn parseDurationValue(comptime token: []const u8) ?f32 {
    comptime {
        if (token.len == 0) return null;

        // Check suffix
        if (endsWith(token, "ms")) {
            return parseFloat(token[0 .. token.len - 2]);
        } else if (endsWith(token, "s") and !isAlpha(token[0])) {
            // "0.2s" -> 200ms
            if (parseFloat(token[0 .. token.len - 1])) |secs| {
                return secs * 1000;
            }
            return null;
        } else {
            // Pure number -> treat as ms
            if (isDigit(token[0])) {
                return parseFloat(token);
            }
            // Design system duration token (`fast`/`normal`/`slow`, units seconds): comptime
            // resolves per design system (duration not theme-dependent)
            return durationToken(token);
        }
    }
}

fn durationToken(comptime name: []const u8) ?f32 {
    if (!@hasField(@TypeOf(theme.light.tokens), "duration")) return null;
    const D = @TypeOf(theme.light.tokens.duration);
    if (@hasField(D, name)) return @field(theme.light.tokens.duration, name) * 1000;
    var snake: [name.len]u8 = name[0..name.len].*;
    for (&snake) |*ch| {
        if (ch.* == '-') ch.* = '_';
    }
    const s = snake;
    if (@hasField(D, &s)) return @field(theme.light.tokens.duration, &s) * 1000;
    return null;
}

// -- Easing parsing ----------------

/// Find easing name in tokens
fn findEasing(comptime tokens: Tokens) Easing {
    comptime {
        for (tokens.items[1..tokens.len]) |token| {
            if (parseDurationValue(token) != null) continue; // skip duration
            if (parseEasingName(token)) |e| return e;
        }
        return .ease_out_quad; // default
    }
}

fn parseEasingName(comptime name: []const u8) ?Easing {
    // cubic-bezier(x1,y1,x2,y2), comma-separated inside parens, no spaces
    if (name.len > 13 and eqlIgnoreCase(name[0..13], "cubic-bezier(") and name[name.len - 1] == ')') {
        const inner = name[13 .. name.len - 1];
        const params = parseBezierParams(inner);
        return .{ .cubic_bezier = .{
            .x1 = params[0],
            .y1 = params[1],
            .x2 = params[2],
            .y2 = params[3],
        } };
    }

    // CSS standard easing
    if (eqlIgnoreCase(name, "linear")) return .linear;
    if (eqlIgnoreCase(name, "ease") or eqlIgnoreCase(name, "ease-out")) return .ease_out_quad;
    if (eqlIgnoreCase(name, "ease-in")) return .ease_in_quad;
    if (eqlIgnoreCase(name, "ease-in-out")) return .ease_in_out_quad;

    // quad
    if (eqlIgnoreCase(name, "ease-in-quad")) return .ease_in_quad;
    if (eqlIgnoreCase(name, "ease-out-quad")) return .ease_out_quad;
    if (eqlIgnoreCase(name, "ease-in-out-quad")) return .ease_in_out_quad;

    // cubic
    if (eqlIgnoreCase(name, "ease-in-cubic")) return .ease_in_cubic;
    if (eqlIgnoreCase(name, "ease-out-cubic")) return .ease_out_cubic;
    if (eqlIgnoreCase(name, "ease-in-out-cubic")) return .ease_in_out_cubic;

    // quart
    if (eqlIgnoreCase(name, "ease-in-quart")) return .ease_in_quart;
    if (eqlIgnoreCase(name, "ease-out-quart")) return .ease_out_quart;
    if (eqlIgnoreCase(name, "ease-in-out-quart")) return .ease_in_out_quart;

    // quint
    if (eqlIgnoreCase(name, "ease-in-quint")) return .ease_in_quint;
    if (eqlIgnoreCase(name, "ease-out-quint")) return .ease_out_quint;
    if (eqlIgnoreCase(name, "ease-in-out-quint")) return .ease_in_out_quint;

    // sine
    if (eqlIgnoreCase(name, "ease-in-sine")) return .ease_in_sine;
    if (eqlIgnoreCase(name, "ease-out-sine")) return .ease_out_sine;
    if (eqlIgnoreCase(name, "ease-in-out-sine")) return .ease_in_out_sine;

    // expo
    if (eqlIgnoreCase(name, "ease-in-expo")) return .ease_in_expo;
    if (eqlIgnoreCase(name, "ease-out-expo")) return .ease_out_expo;
    if (eqlIgnoreCase(name, "ease-in-out-expo")) return .ease_in_out_expo;

    // circ
    if (eqlIgnoreCase(name, "ease-in-circ")) return .ease_in_circ;
    if (eqlIgnoreCase(name, "ease-out-circ")) return .ease_out_circ;
    if (eqlIgnoreCase(name, "ease-in-out-circ")) return .ease_in_out_circ;

    // elastic
    if (eqlIgnoreCase(name, "ease-in-elastic")) return .ease_in_elastic;
    if (eqlIgnoreCase(name, "ease-out-elastic")) return .ease_out_elastic;
    if (eqlIgnoreCase(name, "ease-in-out-elastic")) return .ease_in_out_elastic;

    // back
    if (eqlIgnoreCase(name, "ease-in-back")) return .ease_in_back;
    if (eqlIgnoreCase(name, "ease-out-back") or eqlIgnoreCase(name, "spring")) return .ease_out_back;
    if (eqlIgnoreCase(name, "ease-in-out-back")) return .ease_in_out_back;

    // bounce
    if (eqlIgnoreCase(name, "ease-in-bounce")) return .ease_in_bounce;
    if (eqlIgnoreCase(name, "ease-out-bounce") or eqlIgnoreCase(name, "bounce")) return .ease_out_bounce;
    if (eqlIgnoreCase(name, "ease-in-out-bounce")) return .ease_in_out_bounce;

    return null;
}

// -- CubicBezier parameter parsing --------

/// Parse Bezier params in "x1,y1,x2,y2" format (comptime)
fn parseBezierParams(comptime inner: []const u8) [4]f32 {
    comptime {
        var result: [4]f32 = undefined;
        var param_idx: usize = 0;
        var start: usize = 0;
        var i: usize = 0;
        while (i <= inner.len) : (i += 1) {
            if (i == inner.len or inner[i] == ',') {
                const token = trimWhitespace(inner[start..i]);
                if (token.len > 0) {
                    if (param_idx >= 4) @compileError("cubic-bezier() 需要 4 个参数");
                    result[param_idx] = parseSignedFloat(token) orelse
                        @compileError("cubic-bezier() 参数解析失败: \"" ++ token ++ "\"");
                    param_idx += 1;
                }
                start = i + 1;
            }
        }
        if (param_idx != 4) @compileError("cubic-bezier() 需要 4 个参数");
        return result;
    }
}

/// comptime signed float parse (supports minus prefix)
fn parseSignedFloat(comptime s: []const u8) ?f32 {
    comptime {
        if (s.len == 0) return null;
        if (s[0] == '-') {
            if (parseFloat(s[1..])) |v| return -v;
            return null;
        }
        return parseFloat(s);
    }
}

// -- Comptime string utilities --------

const MAX_SEGMENTS = 16;
const MAX_TOKENS = 8;

const Segments = struct {
    items: [MAX_SEGMENTS][]const u8,
    len: usize,
};

const Tokens = struct {
    items: [MAX_TOKENS][]const u8,
    len: usize,
};

/// Split by comma, trim whitespace (skip commas inside parens, support cubic-bezier(...))
fn splitByComma(comptime input: []const u8) Segments {
    comptime {
        var result = Segments{ .items = undefined, .len = 0 };
        var start: usize = 0;
        var i: usize = 0;
        var paren_depth: u32 = 0;
        while (i < input.len) : (i += 1) {
            if (input[i] == '(') {
                paren_depth += 1;
            } else if (input[i] == ')') {
                if (paren_depth > 0) paren_depth -= 1;
            } else if (input[i] == ',' and paren_depth == 0) {
                const seg = trimWhitespace(input[start..i]);
                if (seg.len > 0) {
                    result.items[result.len] = seg;
                    result.len += 1;
                }
                start = i + 1;
            }
        }
        const last = trimWhitespace(input[start..]);
        if (last.len > 0) {
            result.items[result.len] = last;
            result.len += 1;
        }
        return result;
    }
}

/// Split by whitespace
fn tokenize(comptime input: []const u8) Tokens {
    comptime {
        var result = Tokens{ .items = undefined, .len = 0 };
        var i: usize = 0;
        while (i < input.len) {
            // Skip whitespace
            while (i < input.len and isWhitespace(input[i])) : (i += 1) {}
            if (i >= input.len) break;
            // Find token end
            const start = i;
            while (i < input.len and !isWhitespace(input[i])) : (i += 1) {}
            if (result.len < MAX_TOKENS) {
                result.items[result.len] = input[start..i];
                result.len += 1;
            }
        }
        return result;
    }
}

/// Get first token
fn firstToken(comptime input: []const u8) []const u8 {
    comptime {
        const tokens = tokenize(input);
        if (tokens.len == 0) @compileError("transition 段为空");
        return tokens.items[0];
    }
}

fn trimWhitespace(comptime s: []const u8) []const u8 {
    comptime {
        var start: usize = 0;
        while (start < s.len and isWhitespace(s[start])) : (start += 1) {}
        var end: usize = s.len;
        while (end > start and isWhitespace(s[end - 1])) : (end -= 1) {}
        return s[start..end];
    }
}

fn isWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isAlpha(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

fn endsWith(comptime s: []const u8, comptime suffix: []const u8) bool {
    if (s.len < suffix.len) return false;
    return eqlIgnoreCase(s[s.len - suffix.len ..], suffix);
}

fn eqlIgnoreCase(comptime a: []const u8, comptime b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (toLower(ca) != toLower(cb)) return false;
    }
    return true;
}

fn toLower(c: u8) u8 {
    if (c >= 'A' and c <= 'Z') return c + 32;
    return c;
}

/// comptime float parse (integers and decimals)
fn parseFloat(comptime s: []const u8) ?f32 {
    comptime {
        if (s.len == 0) return null;
        var integer_part: f32 = 0;
        var i: usize = 0;
        var has_digit = false;

        while (i < s.len and isDigit(s[i])) : (i += 1) {
            integer_part = integer_part * 10 + @as(f32, @floatFromInt(s[i] - '0'));
            has_digit = true;
        }

        var frac_part: f32 = 0;
        if (i < s.len and s[i] == '.') {
            i += 1;
            var divisor: f32 = 10;
            while (i < s.len and isDigit(s[i])) : (i += 1) {
                frac_part += @as(f32, @floatFromInt(s[i] - '0')) / divisor;
                divisor *= 10;
                has_digit = true;
            }
        }

        if (!has_digit) return null;
        if (i != s.len) return null; // remaining characters, not pure number
        return integer_part + frac_part;
    }
}

// ============================================================================
// Tests
// ============================================================================

test "transition: 单属性 + duration + easing" {
    const spec = comptime transition("background 200ms ease-out");
    try std.testing.expectEqual(@as(usize, 1), spec.len);
    try std.testing.expectEqual(TransitionProp.background, spec[0].prop);
    try std.testing.expectEqual(@as(f32, 200), spec[0].spec.duration_ms);
    try std.testing.expectEqual(Easing.ease_out_quad, spec[0].spec.easing);
}

test "transition: 多属性逗号分隔" {
    const spec = comptime transition("background 200ms ease-out, opacity 150ms linear");
    try std.testing.expectEqual(@as(usize, 2), spec.len);
    try std.testing.expectEqual(TransitionProp.background, spec[0].prop);
    try std.testing.expectEqual(@as(f32, 200), spec[0].spec.duration_ms);
    try std.testing.expectEqual(TransitionProp.opacity, spec[1].prop);
    try std.testing.expectEqual(@as(f32, 150), spec[1].spec.duration_ms);
    try std.testing.expectEqual(Easing.linear, spec[1].spec.easing);
}

test "transition: 秒单位" {
    const spec = comptime transition("opacity 0.3s");
    try std.testing.expectEqual(@as(usize, 1), spec.len);
    try std.testing.expectEqual(@as(f32, 300), spec[0].spec.duration_ms);
}

test "transition: 省略 easing 使用默认值" {
    const spec = comptime transition("border-color 100ms");
    try std.testing.expectEqual(@as(usize, 1), spec.len);
    try std.testing.expectEqual(TransitionProp.border_color, spec[0].prop);
    try std.testing.expectEqual(@as(f32, 100), spec[0].spec.duration_ms);
    try std.testing.expectEqual(Easing.ease_out_quad, spec[0].spec.easing);
}

test "transition: 省略 duration 使用默认值" {
    const spec = comptime transition("opacity");
    try std.testing.expectEqual(@as(usize, 1), spec.len);
    try std.testing.expectEqual(@as(f32, 150), spec[0].spec.duration_ms);
}

test "transition: all 展开为所有属性" {
    const spec = comptime transition("all 200ms ease-out-cubic");
    try std.testing.expectEqual(@as(usize, 11), spec.len);
    // Verify all properties present
    try std.testing.expectEqual(TransitionProp.background, spec[0].prop);
    try std.testing.expectEqual(TransitionProp.opacity, spec[1].prop);
    try std.testing.expectEqual(TransitionProp.border_color, spec[2].prop);
    try std.testing.expectEqual(TransitionProp.translate_x, spec[3].prop);
    try std.testing.expectEqual(TransitionProp.translate_y, spec[4].prop);
    try std.testing.expectEqual(TransitionProp.scale_x, spec[5].prop);
    try std.testing.expectEqual(TransitionProp.scale_y, spec[6].prop);
    try std.testing.expectEqual(TransitionProp.rotate, spec[7].prop);
    try std.testing.expectEqual(TransitionProp.corner_radius, spec[8].prop);
    try std.testing.expectEqual(TransitionProp.border_width, spec[9].prop);
    try std.testing.expectEqual(TransitionProp.width, spec[10].prop);
    // All specs identical
    for (spec) |entry| {
        try std.testing.expectEqual(@as(f32, 200), entry.spec.duration_ms);
        try std.testing.expectEqual(Easing.ease_out_cubic, entry.spec.easing);
    }
}

test "transition: rotate alias" {
    const spec = comptime transition("rotation 120ms linear");
    try std.testing.expectEqual(@as(usize, 1), spec.len);
    try std.testing.expectEqual(TransitionProp.rotate, spec[0].prop);
    try std.testing.expectEqual(@as(f32, 120), spec[0].spec.duration_ms);
    try std.testing.expectEqual(Easing.linear, spec[0].spec.easing);
}

test "transition: CSS 别名" {
    const spec = comptime transition("border-radius 300ms, bg 100ms, translateX 200ms");
    try std.testing.expectEqual(@as(usize, 3), spec.len);
    try std.testing.expectEqual(TransitionProp.corner_radius, spec[0].prop);
    try std.testing.expectEqual(TransitionProp.background, spec[1].prop);
    try std.testing.expectEqual(TransitionProp.translate_x, spec[2].prop);
}

test "transition: spring 和 bounce 别名" {
    const spec = comptime transition("translate-x 300ms spring, opacity 200ms bounce");
    try std.testing.expectEqual(Easing.ease_out_back, spec[0].spec.easing);
    try std.testing.expectEqual(Easing.ease_out_bounce, spec[1].spec.easing);
}

test "transition: 混合格式" {
    const spec = comptime transition("background 0.2s ease-in-out, translate-y 400ms ease-out-expo, opacity 100ms");
    try std.testing.expectEqual(@as(usize, 3), spec.len);
    try std.testing.expectEqual(@as(f32, 200), spec[0].spec.duration_ms);
    try std.testing.expectEqual(Easing.ease_in_out_quad, spec[0].spec.easing);
    try std.testing.expectEqual(@as(f32, 400), spec[1].spec.duration_ms);
    try std.testing.expectEqual(Easing.ease_out_expo, spec[1].spec.easing);
    try std.testing.expectEqual(@as(f32, 100), spec[2].spec.duration_ms);
}

test "ConditionalStyle: resolve 基础" {
    const s = ConditionalStyle{
        .base = .{ .background = Color.hex(0xFF0000), .opacity = 1.0 },
        .hover = .{ .background = Color.hex(0x00FF00) },
        .disabled = .{ .opacity = 0.5 },
    };

    // Normal state
    const normal = s.resolve(.{});
    try std.testing.expect(normal.background != null);
    try std.testing.expectEqual(Color.hex(0xFF0000), normal.background.?);

    // Hover state
    const hovered = s.resolve(.{ .is_hovered = true });
    try std.testing.expectEqual(Color.hex(0x00FF00), hovered.background.?);
    try std.testing.expectEqual(@as(f32, 1.0), hovered.opacity.?);

    // Disabled state (no hover stacking)
    const disabled = s.resolve(.{ .is_disabled = true, .is_hovered = true });
    try std.testing.expectEqual(Color.hex(0xFF0000), disabled.background.?); // base bg, hover doesn't stack
    try std.testing.expectEqual(@as(f32, 0.5), disabled.opacity.?);
}

test "ConditionalStyle: selected 底态与 hover 叠加, hover 覆盖重叠字段" {
    const s = ConditionalStyle{
        .base = .{ .background = Color.hex(0x111111) },
        .selected = .{ .background = Color.hex(0x222222), .border_width = 2 },
        .hover = .{ .background = Color.hex(0x333333) },
    };

    // Selected only: selected overrides base bg, includes border_width
    const sel = s.resolve(.{ .is_selected = true });
    try std.testing.expectEqual(Color.hex(0x222222), sel.background.?);
    try std.testing.expectEqual(@as(f32, 2), sel.border_width.?);

    // selected + hover: hover bg overrides selected, selected's border_width preserved
    const sel_hover = s.resolve(.{ .is_selected = true, .is_hovered = true });
    try std.testing.expectEqual(Color.hex(0x333333), sel_hover.background.?);
    try std.testing.expectEqual(@as(f32, 2), sel_hover.border_width.?);

    // Unselected doesn't stack
    const plain = s.resolve(.{});
    try std.testing.expectEqual(Color.hex(0x111111), plain.background.?);
    try std.testing.expect(plain.border_width == null);
}

test "ConditionalStyle: invalid 压过 hover/focus" {
    const s = ConditionalStyle{
        .base = .{ .border_color = Color.hex(0x888888) },
        .hover = .{ .border_color = Color.hex(0x00FF00) },
        .focus = .{ .border_color = Color.hex(0x0000FF) },
        .invalid = .{ .border_color = Color.hex(0xFF0000) },
    };
    const r = s.resolve(.{ .is_hovered = true, .is_focused = true, .is_invalid = true });
    try std.testing.expectEqual(Color.hex(0xFF0000), r.border_color.?);
}

test "ConditionalStyle: expanded 底态在 hover 之前" {
    const s = ConditionalStyle{
        .base = .{ .background = Color.hex(0x111111) },
        .expanded = .{ .background = Color.hex(0x222222) },
        .hover = .{ .background = Color.hex(0x333333) },
    };
    const r = s.resolve(.{ .is_expanded = true, .is_hovered = true });
    try std.testing.expectEqual(Color.hex(0x333333), r.background.?);
    const r2 = s.resolve(.{ .is_expanded = true });
    try std.testing.expectEqual(Color.hex(0x222222), r2.background.?);
}

test "ConditionalStyle: disabled 短路忽略 selected/invalid" {
    const s = ConditionalStyle{
        .base = .{ .opacity = 1.0, .background = Color.hex(0x111111) },
        .selected = .{ .background = Color.hex(0x222222) },
        .invalid = .{ .border_color = Color.hex(0xFF0000) },
        .disabled = .{ .opacity = 0.5 },
    };
    const r = s.resolve(.{ .is_disabled = true, .is_selected = true, .is_invalid = true });
    try std.testing.expectEqual(@as(f32, 0.5), r.opacity.?);
    try std.testing.expectEqual(Color.hex(0x111111), r.background.?); // selected doesn't stack
    try std.testing.expect(r.border_color == null); // invalid doesn't stack
}

test "ConditionalStyle: merge 与 override 覆盖新条件字段" {
    const a = ConditionalStyle{
        .selected = .{ .background = Color.hex(0x111111) },
    };
    const b = ConditionalStyle{
        .selected = .{ .border_width = 2 },
        .invalid = .{ .border_color = Color.hex(0xFF0000) },
    };
    const merged = a.merge(b);
    try std.testing.expect(merged.selected.?.background != null);
    try std.testing.expect(merged.selected.?.border_width != null);
    try std.testing.expect(merged.invalid != null);

    const overridden = merged.override(.{
        .selected_style = .{ .background = Color.hex(0x999999) },
        .invalid_style = .{ .opacity = 0.9 },
    });
    try std.testing.expectEqual(Color.hex(0x999999), overridden.selected.?.background.?);
    try std.testing.expectEqual(@as(f32, 0.9), overridden.invalid.?.opacity.?);
}

test "ConditionalStyle: merge" {
    const a = ConditionalStyle{
        .base = .{ .background = Color.hex(0xFF0000) },
        .hover = .{ .opacity = 0.8 },
    };
    const b = ConditionalStyle{
        .base = .{ .text_color = Color.hex(0x000000) },
        .hover = .{ .background = Color.hex(0x00FF00) },
        .disabled = .{ .opacity = 0.5 },
    };
    const merged = a.merge(b);

    // base merges both
    try std.testing.expect(merged.base.background != null);
    try std.testing.expect(merged.base.text_color != null);

    // hover merges both
    try std.testing.expect(merged.hover != null);
    try std.testing.expect(merged.hover.?.opacity != null); // from a
    try std.testing.expect(merged.hover.?.background != null); // from b

    // disabled only from b
    try std.testing.expect(merged.disabled != null);
    try std.testing.expectEqual(@as(f32, 0.5), merged.disabled.?.opacity.?);
}

test "ConditionalStyle: merge keeps margin_spec semantics" {
    const a = ConditionalStyle{
        .base = .{ .margin_spec = (types.Margin{ .left = 8 }).withAutoLeft() },
        .hover = .{ .margin_spec = types.Margin.autoHorizontal() },
    };
    const b = ConditionalStyle{
        .base = .{ .margin_spec = (types.Margin{ .right = 12 }).withAutoRight() },
        .hover = .{ .opacity = 0.8 },
    };
    const merged = a.merge(b);

    try std.testing.expect(merged.base.margin_spec != null);
    try std.testing.expectEqual(@as(f32, 12), merged.base.margin_spec.?.right);
    try std.testing.expect(merged.base.margin_spec.?.rightIsAuto());
    try std.testing.expect(!merged.base.margin_spec.?.leftIsAuto());
    try std.testing.expect(merged.hover.?.margin_spec != null);
    try std.testing.expect(merged.hover.?.margin_spec.?.leftIsAuto());
    try std.testing.expect(merged.hover.?.margin_spec.?.rightIsAuto());
    try std.testing.expectEqual(@as(f32, 0.8), merged.hover.?.opacity.?);
}

test "recipe: 基础 resolve" {
    const TestSize = enum { sm, lg };
    const TestRecipe = recipe(struct {
        pub const Variants = struct {
            size: TestSize = .sm,
        };

        pub fn base(_: *const ThemeTokens) ConditionalStyle {
            return .{ .base = .{ .cursor = .pointer } };
        }

        pub const variants = .{
            .size = struct {
                fn resolve(s: TestSize, _: *const ThemeTokens) ConditionalStyle {
                    return switch (s) {
                        .sm => .{ .base = .{ .height = .{ .px = 28 } } },
                        .lg => .{ .base = .{ .height = .{ .px = 42 } } },
                    };
                }
            }.resolve,
        };
    });

    const tokens = &theme.dark;

    const sm = TestRecipe.resolve(.{ .size = .sm }, tokens);
    try std.testing.expectEqual(types.CursorShape.pointer, sm.base.cursor.?);
    try std.testing.expectEqual(@as(f32, 28), sm.base.height.?.px);

    const lg = TestRecipe.resolve(.{ .size = .lg }, tokens);
    try std.testing.expectEqual(@as(f32, 42), lg.base.height.?.px);
}

test "recipe: compound variants" {
    const TestVariant = enum { primary, secondary, danger };
    const TestSize = enum { sm, md };
    const CompoundRecipe = recipe(struct {
        pub const Variants = struct {
            variant: TestVariant = .primary,
            size: TestSize = .md,
        };

        pub fn base(_: *const ThemeTokens) ConditionalStyle {
            return .{ .base = .{ .cursor = .pointer } };
        }

        pub const variants = .{
            .variant = struct {
                fn resolve(v: TestVariant, _: *const ThemeTokens) ConditionalStyle {
                    return switch (v) {
                        .primary => .{ .base = .{ .background = Color.hex(0x0000FF) } },
                        .secondary => .{ .base = .{ .background = Color.hex(0xCCCCCC) } },
                        .danger => .{ .base = .{ .background = Color.hex(0xFF0000) } },
                    };
                }
            }.resolve,
            .size = struct {
                fn resolve(s: TestSize, _: *const ThemeTokens) ConditionalStyle {
                    return switch (s) {
                        .sm => .{ .base = .{ .height = .{ .px = 28 } } },
                        .md => .{ .base = .{ .height = .{ .px = 36 } } },
                    };
                }
            }.resolve,
        };

        // compound: danger + sm -> special text color
        pub const compounds = .{
            .{
                .matches = struct {
                    fn f(v: Variants) bool {
                        return v.variant == .danger and v.size == .sm;
                    }
                }.f,
                .style = struct {
                    fn f(_: *const ThemeTokens) ConditionalStyle {
                        return .{ .base = .{ .text_color = Color.hex(0xFFFF00) } };
                    }
                }.f,
            },
        };
    });

    const tokens = &theme.dark;

    // non-compound combo -> no extra style
    const primary_md = CompoundRecipe.resolve(.{ .variant = .primary, .size = .md }, tokens);
    try std.testing.expect(primary_md.base.text_color == null);

    // compound matches -> danger + sm has special text_color
    const danger_sm = CompoundRecipe.resolve(.{ .variant = .danger, .size = .sm }, tokens);
    try std.testing.expect(danger_sm.base.text_color != null);
    try std.testing.expectEqual(Color.hex(0xFFFF00), danger_sm.base.text_color.?);
    try std.testing.expectEqual(Color.hex(0xFF0000), danger_sm.base.background.?); // variant bg also present

    // danger + md -> compound doesn't match
    const danger_md = CompoundRecipe.resolve(.{ .variant = .danger, .size = .md }, tokens);
    try std.testing.expect(danger_md.base.text_color == null);
}

test "recipe: derived 跨维度组合与优先级 base<variants<derived<compounds" {
    const TestSize = enum { sm, lg };
    const DerivedRecipe = recipe(struct {
        pub const Variants = struct {
            size: TestSize = .sm,
            icon_only: bool = false,
        };

        pub fn base(_: *const ThemeTokens) ConditionalStyle {
            // base gap overridden by variants; opacity unoverridden preserves
            return .{ .base = .{ .gap = 1, .opacity = 0.9 } };
        }

        pub const variants = .{
            .size = struct {
                fn resolve(s: TestSize, _: *const ThemeTokens) ConditionalStyle {
                    // variants height overridden by derived; gap overrides base
                    return switch (s) {
                        .sm => .{ .base = .{ .height = .{ .px = 1 }, .gap = 4 } },
                        .lg => .{ .base = .{ .height = .{ .px = 1 }, .gap = 8 } },
                    };
                }
            }.resolve,
        };

        // derived takes full Variants, cross-dimension combo (padding = f(size, icon_only))
        pub fn derived(v: Variants, _: *const ThemeTokens) ConditionalStyle {
            const h: f32 = switch (v.size) {
                .sm => 28,
                .lg => 42,
            };
            return .{
                .base = .{
                    .height = .{ .px = h },
                    .padding = if (v.icon_only) types.Padding.all(h / 4) else types.Padding.symmetric(4, 12),
                    // derived corner_radius overridden by compound (on lg+icon_only)
                    .corner_radius = 6,
                },
            };
        }

        pub const compounds = .{
            .{
                .matches = struct {
                    fn f(v: Variants) bool {
                        return v.size == .lg and v.icon_only;
                    }
                }.f,
                .style = struct {
                    fn f(_: *const ThemeTokens) ConditionalStyle {
                        return .{ .base = .{ .corner_radius = 999 } };
                    }
                }.f,
            },
        };
    });

    const tokens = &theme.dark;

    // derived overrides variants height; variants overrides base gap; base opacity preserved
    const sm = DerivedRecipe.resolve(.{ .size = .sm }, tokens);
    try std.testing.expectEqual(@as(f32, 28), sm.base.height.?.px);
    try std.testing.expectEqual(@as(f32, 4), sm.base.gap.?);
    try std.testing.expectEqual(@as(f32, 0.9), sm.base.opacity.?);
    try std.testing.expectEqual(@as(f32, 12), sm.base.padding.?.right);
    try std.testing.expectEqual(@as(f32, 6), sm.base.corner_radius.?);

    // Cross-dimension: icon_only changes padding shape (single-dimension resolver can't do)
    const sm_icon = DerivedRecipe.resolve(.{ .size = .sm, .icon_only = true }, tokens);
    try std.testing.expectEqual(@as(f32, 7), sm_icon.base.padding.?.right);

    // compounds override derived corner_radius
    const lg_icon = DerivedRecipe.resolve(.{ .size = .lg, .icon_only = true }, tokens);
    try std.testing.expectEqual(@as(f32, 999), lg_icon.base.corner_radius.?);
    try std.testing.expectEqual(@as(f32, 42), lg_icon.base.height.?.px);
}

test "ConditionalStyle: override" {
    const base_style = ConditionalStyle{
        .base = .{ .background = Color.hex(0xFF0000), .text_color = Color.hex(0x000000) },
        .hover = .{ .background = Color.hex(0x00FF00) },
    };

    // external override overwrites base background, preserves text_color
    const overridden = base_style.override(.{
        .style = .{ .background = Color.hex(0x0000FF) },
        .hover_style = .{ .opacity = 0.9 },
    });

    try std.testing.expectEqual(Color.hex(0x0000FF), overridden.base.background.?); // overridden
    try std.testing.expectEqual(Color.hex(0x000000), overridden.base.text_color.?); // preserved
    try std.testing.expect(overridden.hover.?.background != null); // original hover bg preserved
    try std.testing.expect(overridden.hover.?.opacity != null); // new hover opacity added
}

test "ConditionalStyle: override preserves margin_spec overrides" {
    const base_style = ConditionalStyle{
        .base = .{ .margin_spec = (types.Margin{ .left = 6 }).withAutoLeft() },
        .hover = .{ .margin_spec = (types.Margin{ .right = 10 }).withAutoRight() },
    };

    const overridden = base_style.override(.{
        .style = .{ .margin_spec = types.Margin.autoHorizontal() },
        .hover_style = .{ .margin_spec = (types.Margin{ .left = 4, .right = 2 }).withAutoLeft() },
    });

    try std.testing.expect(overridden.base.margin_spec != null);
    try std.testing.expect(overridden.base.margin_spec.?.leftIsAuto());
    try std.testing.expect(overridden.base.margin_spec.?.rightIsAuto());
    try std.testing.expect(overridden.hover != null);
    try std.testing.expectEqual(@as(f32, 4), overridden.hover.?.margin_spec.?.left);
    try std.testing.expect(overridden.hover.?.margin_spec.?.leftIsAuto());
    try std.testing.expect(!overridden.hover.?.margin_spec.?.rightIsAuto());
}

test "slotRecipe: 多 slot resolve" {
    const TestVariant = enum { primary, ghost };
    const TestSlots = slotRecipe(struct {
        pub const Slots = struct {
            root: ConditionalStyle = .{},
            label: ConditionalStyle = .{},
        };

        pub const Variants = struct {
            variant: TestVariant = .primary,
        };

        pub fn base(_: *const ThemeTokens) Slots {
            return .{
                .root = .{ .base = .{ .cursor = .pointer } },
                .label = .{},
            };
        }

        pub const variants = .{
            .variant = struct {
                fn resolve(v: TestVariant, _: *const ThemeTokens) Slots {
                    return switch (v) {
                        .primary => .{
                            .root = .{ .base = .{ .background = Color.hex(0x000000) } },
                            .label = .{ .base = .{ .text_color = Color.hex(0xFFFFFF) } },
                        },
                        .ghost => .{
                            .root = .{},
                            .label = .{ .base = .{ .text_color = Color.hex(0x666666) } },
                        },
                    };
                }
            }.resolve,
        };
    });

    const tokens = &theme.dark;

    const primary = TestSlots.resolve(.{ .variant = .primary }, tokens);
    try std.testing.expectEqual(types.CursorShape.pointer, primary.root.base.cursor.?);
    try std.testing.expect(primary.root.base.background != null);
    try std.testing.expect(primary.label.base.text_color != null);

    const ghost = TestSlots.resolve(.{ .variant = .ghost }, tokens);
    try std.testing.expectEqual(types.CursorShape.pointer, ghost.root.base.cursor.?); // base still has
    try std.testing.expect(ghost.root.base.background == null); // ghost has no bg
    try std.testing.expect(ghost.label.base.text_color != null);
}

test "transition：duration token（按选定设计系统取值，单位换成毫秒）" {
    const spec = transition("background fast ease-out, opacity slow");
    try std.testing.expectEqual(@as(f32, theme.light.tokens.duration.fast * 1000), spec[0].spec.duration_ms);
    try std.testing.expectEqual(@as(f32, theme.light.tokens.duration.slow * 1000), spec[1].spec.duration_ms);
}

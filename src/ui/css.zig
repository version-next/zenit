//! Object-literal styles: `ui.css(...)` / `ui.cva(...)` (like Panda CSS css() / cva()),
//! zero-runtime parsing.
//!
//! ```zig
//! const card = ui.css(.{
//!     .background = .bg_secondary,          // color field: check Values.tokens.color.*
//!     .padding = .space400,                       // spacing field: check Values.tokens.space.*
//!     .corner_radius = .md,                 // radius: check Values.tokens.radius.*
//!     .width = 420,                         // number = arbitrary value (STYLING escape hatch)
//!     ._hover = .{ .background = .bg_hover },
//! });
//! v.col(.{ .style = card }, .{ ... })
//!
//! const Btn = ui.cva(.{
//!     .base = .{ .corner_radius = .md },
//!     .variants = .{ .intent = .{ .primary = .{ .background = .accent }, .ghost = .{ ._hover = .{
//!     .background = .bg_hover } } } },
//!     .compound = .{ .{ .when = .{ .intent = .ghost }, .style = .{ .padding = .{ .x = .space100 }
//!     } } },
//!     .defaults = .{ .intent = .primary },
//! });
//! v.box(.{ .style = Btn.of(.{ .intent = intent_signal }) }, .{ ... })
//! ```
//!
//! - Field names are `BoxStyle` / `TextStyle` field names; `color` and `text_color` are
//!   aliases (text_color on box, color on text).
//! - Enum literals look up by **token category of the field** (see `catOf`); missing names
//!   are compile errors listing available options. Tokens resolve at apply time, so theme
//!   changes follow (view layer registers token-using styles as theme-reading).
//! - Shortcuts: `padding` / `margin` accept a single spacing (all sides) or
//!   `.{ .x, .y, .top, .right, .bottom, .left }`; `width` / `height` accept numbers (fixed
//!   pixels), `.fill`, `.fit`; `font_weight` accepts `.regular` / `.medium` / `.semibold` /
//!   `.bold` etc.
//! - Conditions: `_selected _expanded _hover _active _focus _focus_visible _invalid _disabled`,
//!   the condition set of `ConditionalStyle`; priority is fixed by the condition system, not
//!   write order. On regular boxes `_hover` and `_active` (pressed with pointer still in
//!   node) have state sources; other conditions are applied by the component (via `conditional()` /
//!   `cva.resolve()` obtaining `ConditionalStyle`) from its own state; on boxes use cva / sva
//!   reactive variants for data-driven switching.
const std = @import("std");
const core = @import("core.zig");
const theme = @import("theme.zig");
const view = @import("view.zig");

const BoxStyle = core.BoxStyle;
const TextStyle = core.TextStyle;
const ConditionalStyle = core.ConditionalStyle;
const Color = core.Color;
const Padding = core.Padding;
const Sizing = core.Sizing;
const Border = core.Border;
const ThemeTokens = theme.ThemeTokens;
const sv = @import("zenit_style_values");
const recipe_mod = @import("recipe.zig");

const EnumLiteral = @TypeOf(.enum_literal);

/// Condition name (no underscore) 1:1 with `ConditionalStyle` fields.
const conditions = [_][]const u8{ "selected", "expanded", "hover", "active", "focus", "focus_visible", "invalid", "disabled" };

// ============================================================================
// css()
// ============================================================================

/// Style object: compile-time constant, can go directly into `.style` (alone, tuple, or in
/// `v.when`).
pub fn css(comptime spec: anytype) if (preview_enabled and isCss(@TypeOf(spec))) @TypeOf(spec) else Css(specOf(spec)) {
    if (comptime preview_enabled and isCss(@TypeOf(spec))) return spec;
    return .{};
}

pub fn Css(comptime spec_value: anytype) type {
    return CssImpl(spec_value, null, false);
}

const preview_enabled = @import("zenit_environment").dev_preview;
const reload = if (preview_enabled) @import("style_reload.zig") else struct {};
const PreviewDescriptor = struct { path: []const u8, name: []const u8, source: []const u8 };

/// Generated YSS keeps its compiled type shell; only value resolution changes in preview.
pub fn previewCss(comptime path: []const u8, comptime name: []const u8, comptime source: []const u8, comptime spec_value: anytype) CssImpl(specOf(spec_value), if (preview_enabled) .{ .path = path, .name = name, .source = source } else null, false) {
    return .{};
}

fn CssImpl(comptime spec_value: anytype, comptime descriptor: ?PreviewDescriptor, comptime box_projection: bool) type {
    comptime if (specError(@TypeOf(spec_value), true)) |msg| @compileError("ui.css: " ++ msg);
    return struct {
        pub const zenit_style_part = .css;
        pub const spec = spec_value;
        pub const preview_id = if (descriptor) |d| d.path ++ ":" ++ d.name ++ ":root" else null;
        pub const preview_compiled = if (descriptor != null) Css(spec_value) else @This();
        pub const has_hover = @hasField(@TypeOf(spec_value), "_hover");
        /// `_active`: pressed on node, pointer still inside node (native button press highlight)
        pub const has_active = @hasField(@TypeOf(spec_value), "_active");
        pub const needs_ext = specNeedsExt(@TypeOf(spec_value));
        pub const transitions = transitionsOf(spec_value);
        /// Conditions other than `_hover` / `_active`
        pub const state_condition: ?[]const u8 = firstStateCondition(@TypeOf(spec_value));
        pub const state_conditions = stateConditionsOf(@TypeOf(spec_value));
        /// Spec lists icon_color (icon tint): mutually exclusive with media element's tint=
        pub const sets_icon_color = mentionsField(@TypeOf(spec_value), "icon_color");

        fn declaration() if (preview_enabled) ?*const reload.ir.Declaration else void {
            if (comptime descriptor) |d| {
                reload.observeGeneration();
                return reload.lookup(d.path, d.name, d.source);
            }
            if (comptime preview_enabled) return null;
        }

        /// base layer
        pub fn box(t: *const ThemeTokens) BoxStyle {
            if (comptime descriptor != null) if (declaration()) |d| return reload.evaluateBox(d.base, t, box_projection) catch unreachable;
            return boxFrom(spec_value, t);
        }

        /// `_hover` layer (empty if absent)
        pub fn hoverBox(t: *const ThemeTokens) BoxStyle {
            if (!has_hover) return .{};
            if (comptime descriptor != null) if (declaration()) |d| return reload.evaluateCondition(d.base, "hover", t, box_projection);
            return boxFrom(spec_value._hover, t);
        }

        /// `_active` layer (empty if absent)
        pub fn activeBox(t: *const ThemeTokens) BoxStyle {
            if (!has_active) return .{};
            if (comptime descriptor != null) if (declaration()) |d| return reload.evaluateCondition(d.base, "active", t, box_projection);
            return boxFrom(spec_value._active, t);
        }

        /// All condition layers: defer to component to apply by its state (`cs.resolve(state)`).
        pub fn conditional(t: *const ThemeTokens) ConditionalStyle {
            if (comptime descriptor != null) if (declaration()) |d| return reload.evaluateConditional(d.base, t, box_projection) catch unreachable;
            return conditionalFrom(spec_value, t);
        }

        /// Text: stack declared fields onto `base`. Text has only `_hover` condition (text node's
        /// own hover, e.g. link hover color). Box fields (padding / background …) not here: when
        /// used on `<text>`, view applies to text node's own box style per `box_part`.
        pub fn text(base: TextStyle, t: *const ThemeTokens) TextStyle {
            comptime if (firstStateCondition(@TypeOf(spec_value)) != null or has_active) @compileError("ui.css on text: only _hover applies to text (the text node's own hover); switch other text states with cva / sva variants");
            if (comptime descriptor != null) if (declaration()) |d| return reload.evaluateText(d.base, base, t) catch unreachable;
            return textFrom(comptime textSpec(spec_value), base, t);
        }

        /// Text `_hover` layer stacked onto `base` (returned as-is if absent)
        pub fn textHover(base: TextStyle, t: *const ThemeTokens) TextStyle {
            if (!has_hover) return base;
            if (comptime descriptor != null) if (declaration()) |d| {
                for (d.base.conditions) |c| if (reload.conditionEqual(c.name, "hover")) return reload.evaluateText(c.layer.*, base, t) catch unreachable;
                return base;
            };
            return textFrom(spec_value._hover, base, t);
        }

        /// Box part when used on `<text>` (only box fields); null if no box fields
        pub const box_part: ?type = if (hasBoxOnlyFields(@TypeOf(spec_value))) CssImpl(boxSpec(spec_value), descriptor, true) else null;
    };
}

/// css value or style literal -> literal itself (cva's layers accept both forms).
fn specOf(comptime x: anytype) SpecType(@TypeOf(x)) {
    if (comptime isCss(@TypeOf(x))) return @TypeOf(x).spec;
    return x;
}

fn SpecType(comptime X: type) type {
    return if (isCss(X)) @TypeOf(X.spec) else X;
}

fn isCss(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "zenit_style_part") and T.zenit_style_part == .css;
}

// ============================================================================
// Parser
// ============================================================================

/// base layer fields in literal -> BoxStyle (skip condition keys). Also for view-layer parsing
/// `.style = .{ ... }` inline literals.
pub fn boxFrom(spec: anytype, t: *const ThemeTokens) BoxStyle {
    var out: BoxStyle = .{};
    applyBoxSpec(&out, spec, t);
    return out;
}

/// Storage required by any declared field, including inactive conditions.
pub fn specNeedsExt(comptime S: type) bool {
    for (@import("zenit_reflection").fields(S)) |f| {
        if (isMetaKey(f.name)) continue;
        if (isConditionKey(f.name)) {
            if (specNeedsExt(f.type)) return true;
        } else if (std.mem.eql(u8, f.name, "typography")) {
            return true;
        } else if (BoxStyle.fieldNeedsExt(boxName(f.name))) return true;
    }
    return false;
}

fn recipeNeedsExt(comptime config: anytype, comptime slot: ?[]const u8) bool {
    // Derived functions may return a different set of fields after any update.
    if (@hasField(@TypeOf(config), "derived")) return true;
    if (@hasField(@TypeOf(config), "base")) {
        if (specNeedsExt(@TypeOf(layerSpec(config.base, slot)))) return true;
    }
    if (@hasField(@TypeOf(config), "variants")) {
        for (@import("zenit_reflection").fields(@TypeOf(config.variants))) |d| {
            const options = @field(config.variants, d.name);
            for (@import("zenit_reflection").fields(@TypeOf(options))) |o| {
                if (specNeedsExt(@TypeOf(layerSpec(@field(options, o.name), slot)))) return true;
            }
        }
    }
    if (@hasField(@TypeOf(config), "compound")) {
        for (config.compound) |c| if (specNeedsExt(@TypeOf(layerSpec(c.style, slot)))) return true;
    }
    return false;
}

/// Emit assignments only for declared properties. Null means “no override”,
/// exactly as in BoxStyle.merge; no full intermediate BoxStyle is constructed.
fn applyBoxSpec(out: *BoxStyle, spec: anytype, t: *const ThemeTokens) void {
    comptime if (colorAliasError(@TypeOf(spec))) |msg| @compileError("ui.css: " ++ msg);
    inline for (@import("zenit_reflection").fields(@TypeOf(spec))) |f| {
        if (comptime isConditionKey(f.name) or isMetaKey(f.name)) continue;
        const name = comptime boxName(f.name);
        const value = resolveInto(@FieldType(BoxStyle, name), comptime catOf(name), @field(spec, f.name), t);
        if (value != null) @field(out, name) = value;
    }
}

/// Fields in literal stacked onto `base` -> TextStyle.
pub fn textFrom(spec: anytype, base: TextStyle, t: *const ThemeTokens) TextStyle {
    var out = base;
    applyTextSpec(&out, spec, t);
    return out;
}

fn applyTextSpec(out: *TextStyle, spec: anytype, t: *const ThemeTokens) void {
    const S = @TypeOf(spec);
    comptime if (colorAliasError(S)) |msg| @compileError("ui.css: " ++ msg);
    // Expand partial typography first, so explicit fields always win.
    if (@hasField(S, "typography")) {
        const patch = resolveInto(sv.TypographyPatch, .typography, spec.typography, t);
        inline for (@import("zenit_reflection").fields(sv.TypographyPatch)) |f| {
            if (@field(patch, f.name)) |value| {
                @field(out, f.name) = value;
                markDeclared(out, f.name);
            }
        }
    }
    inline for (@import("zenit_reflection").fields(S)) |f| {
        if (comptime isConditionKey(f.name) or isMetaKey(f.name) or std.mem.eql(u8, f.name, "typography")) continue;
        const name = comptime textName(f.name);
        @field(out, name) = resolveInto(@FieldType(TextStyle, name), comptime catOf(name), @field(spec, f.name), t);
        markDeclared(out, name);
    }
}

/// An inheritable text property the style states itself: the ancestor's value yields to it
/// (TextProps.color_set / font_size_set / font_weight_set).
fn markDeclared(out: *TextStyle, comptime name: []const u8) void {
    if (comptime @hasField(TextStyle, name ++ "_set")) @field(out, name ++ "_set") = true;
}

fn conditionalFrom(comptime spec: anytype, t: *const ThemeTokens) ConditionalStyle {
    var out: ConditionalStyle = .{};
    applyConditionalSpec(&out, spec, t);
    return out;
}

fn applyConditionalSpec(out: *ConditionalStyle, comptime spec: anytype, t: *const ThemeTokens) void {
    applyBoxSpec(&out.base, spec, t);
    inline for (conditions) |c| {
        if (@hasField(@TypeOf(spec), "_" ++ c)) {
            if (@field(out, c) == null) @field(out, c) = .{};
            applyBoxSpec(&@field(out, c).?, @field(spec, "_" ++ c), t);
        }
    }
}

/// A slot projection stays comptime: reading one slot never resolves its siblings.
fn layerSpec(comptime specs: anytype, comptime slot: ?[]const u8) blk: {
    if (slot) |name| {
        if (@hasField(@TypeOf(specs), name)) break :blk SpecType(@TypeOf(@field(specs, name)));
        break :blk @TypeOf(.{});
    }
    break :blk SpecType(@TypeOf(specs));
} {
    if (slot) |name| {
        if (@hasField(@TypeOf(specs), name)) return specOf(@field(specs, name));
        return .{};
    }
    return specOf(specs);
}

fn applyRecipeLayer(out: anytype, comptime specs: anytype, comptime slot: ?[]const u8, t: *const ThemeTokens) void {
    const Out = @TypeOf(out.*);
    // Keep generated CSS descriptors when composed into handwritten recipes.
    // Metadata remains comptime, while the actual layer resolves this generation.
    if (comptime preview_enabled and (Out == ConditionalStyle or Out == TextStyle)) {
        const layer = comptime if (slot) |name| (if (@hasField(@TypeOf(specs), name)) @field(specs, name) else .{}) else specs;
        if (comptime isCss(@TypeOf(layer))) {
            const S = @TypeOf(layer);
            if (comptime @TypeOf(S.preview_id) != @TypeOf(null)) {
                if (Out == TextStyle) {
                    comptime if (hasAnyCondition(@TypeOf(S.spec)))
                        @compileError("ui.cva / ui.sva on text: conditions apply to boxes; use a variant for text state");
                    out.* = S.text(out.*, t);
                } else {
                    out.* = out.merge(S.conditional(t));
                }
                return;
            }
        }
    }
    if (Out == ConditionalStyle) {
        applyConditionalSpec(out, comptime layerSpec(specs, slot), t);
    } else if (Out == TextStyle) {
        const spec = comptime layerSpec(specs, slot);
        comptime if (hasAnyCondition(@TypeOf(spec)))
            @compileError("ui.cva / ui.sva on text: conditions apply to boxes; use a variant for text state");
        applyTextSpec(out, spec, t);
    } else {
        inline for (@import("zenit_reflection").fields(@TypeOf(specs))) |f| {
            if (comptime preview_enabled)
                applyRecipeLayer(&@field(out, f.name), @field(specs, f.name), null, t)
            else
                applyConditionalSpec(&@field(out, f.name), comptime specOf(@field(specs, f.name)), t);
        }
    }
}

fn matches(variants: anytype, comptime when: anytype) bool {
    inline for (@import("zenit_reflection").fields(@TypeOf(when))) |f| {
        const D = @FieldType(@TypeOf(variants), f.name);
        if (@field(variants, f.name) != comptime convert(D, @field(when, f.name))) return false;
    }
    return true;
}

/// Shared lowering for cva, whole sva records and individual box/text slots.
/// Declaration traversal is comptime; only variant tests, token reads and
/// declared-property writes remain at runtime. No Cartesian product of variants.
fn applyRecipe(out: anytype, comptime config: anytype, comptime slot: ?[]const u8, variants: anytype, t: *const ThemeTokens) void {
    const C = @TypeOf(config);
    if (@hasField(C, "base")) applyRecipeLayer(out, config.base, slot, t);
    if (@hasField(C, "variants")) {
        inline for (@import("zenit_reflection").fields(@TypeOf(config.variants))) |d| {
            const opts = @field(config.variants, d.name);
            inline for (@import("zenit_reflection").fields(@TypeOf(opts))) |o| {
                if (@field(variants, d.name) == comptime optionValue(@FieldType(@TypeOf(variants), d.name), o.name))
                    applyRecipeLayer(out, @field(opts, o.name), slot, t);
            }
        }
    }
    if (@hasField(C, "derived")) {
        // Explicit runtime geometry is outside the static object fast path.
        const Extra = @TypeOf(config.derived(variants, t));
        comptime for (@import("zenit_reflection").fields(Extra)) |f| {
            var declared = false;
            for (config.slots) |name| {
                if (std.mem.eql(u8, @tagName(name), f.name)) declared = true;
            }
            if (!declared) @compileError("ui.sva .derived: undeclared slot ." ++ f.name);
        };
        if (comptime slot == null or @hasField(Extra, slot.?)) {
            if (@TypeOf(out.*) == TextStyle) @compileError("ui.sva on text: derived supplies box geometry; omit this text slot from derived");
            const extra = config.derived(variants, t);
            inline for (@import("zenit_reflection").fields(Extra)) |f| {
                if (comptime slot == null or std.mem.eql(u8, slot.?, f.name)) {
                    const geometry: BoxStyle = @field(extra, f.name);
                    const target = if (slot == null) &@field(out, f.name) else out;
                    target.base = target.base.merge(geometry);
                }
            }
        }
    }
    if (@hasField(C, "compound")) {
        inline for (config.compound) |c| {
            if (matches(variants, c.when)) applyRecipeLayer(out, c.style, slot, t);
        }
    }
}

fn boxName(comptime name: []const u8) []const u8 {
    const n = if (std.mem.eql(u8, name, "color")) "text_color" else name;
    if (!@hasField(BoxStyle, n)) @compileError("ui.css: a box style has no field ." ++ name ++ suggest(BoxStyle, name));
    return n;
}

fn textName(comptime name: []const u8) []const u8 {
    const n = if (std.mem.eql(u8, name, "text_color")) "color" else name;
    if (!@hasField(TextStyle, n)) @compileError("ui.css: a text style has no field ." ++ name ++ suggest(TextStyle, name) ++
        " (layout fields such as .gap / .padding belong on a box)");
    return n;
}

/// token category: which table enum literal goes to.
pub const Category = enum { none, color, space, radius, font_size, font_weight, line_height, border_width, size, opacity, shadow, typography };

/// Top-level field name -> token category.
pub fn catOf(comptime name: []const u8) Category {
    const eql = std.mem.eql;
    if (eql(u8, name, "background") or eql(u8, name, "color") or std.mem.endsWith(u8, name, "_color")) return .color;
    if (eql(u8, name, "gap") or eql(u8, name, "padding") or eql(u8, name, "margin")) return .space;
    if (eql(u8, name, "corner_radius")) return .radius;
    if (eql(u8, name, "font_size")) return .font_size;
    if (eql(u8, name, "font_weight")) return .font_weight;
    if (eql(u8, name, "border_width") or (std.mem.startsWith(u8, name, "border_") and std.mem.endsWith(u8, name, "_width"))) return .border_width;
    if (eql(u8, name, "shadow")) return .shadow;
    if (eql(u8, name, "line_height")) return .line_height;
    if (eql(u8, name, "opacity")) return .opacity;
    if (eql(u8, name, "typography")) return .typography;
    if (eql(u8, name, "width") or eql(u8, name, "height") or eql(u8, name, "min_width") or eql(u8, name, "max_width") or eql(u8, name, "min_height") or eql(u8, name, "max_height")) return .size;
    return .none;
}

/// Field in nested literal -> token category (`.padding = .{ .x = .space200 }`, `.border = .{
/// .color = .border, .width = .thin }`).
fn subCat(comptime Parent: type, comptime name: []const u8) Category {
    const eql = std.mem.eql;
    if (Parent == Padding) return .space;
    if (Parent == Border) {
        if (eql(u8, name, "color")) return .color;
        if (eql(u8, name, "width")) return .border_width;
        if (eql(u8, name, "radius")) return .radius;
        return .none;
    }
    if (eql(u8, name, "color") or std.mem.endsWith(u8, name, "_color")) return .color;
    return .none;
}

fn resolveInto(comptime Target: type, comptime cat: Category, v: anytype, t: *const ThemeTokens) Target {
    const V = @TypeOf(v);
    if (comptime isOrElse(V)) {
        if (v.value) |x| return resolveInto(Target, cat, x, t);
        return resolveInto(Target, cat, V.fallback, t);
    }
    if (@typeInfo(Target) == .optional) {
        if (V == @TypeOf(null)) return null;
        if (@typeInfo(V) == .optional) {
            const x = v orelse return null;
            return resolveInto(@typeInfo(Target).optional.child, cat, x, t);
        }
        return resolveInto(@typeInfo(Target).optional.child, cat, v, t);
    }
    if (comptime isColorMix(V)) {
        if (comptime cat != .color) @compileError("ui.mix: only color fields take a color mix, got a " ++ @tagName(cat) ++ " field");
        return fromScalar(Target, v.resolve(t));
    }
    if (comptime refCategory(V)) |actual| {
        if (comptime cat == .none or !std.mem.eql(u8, @tagName(actual), @tagName(cat)))
            @compileError("ui.css: expected " ++ @tagName(cat) ++ " token, got " ++ @tagName(actual));
        return fromScalar(Target, theme.resolve(actual, v, t));
    }
    if (V == EnumLiteral) {
        if (Target == Sizing) {
            if (v == .fill) return Sizing.fill();
            if (v == .fit) return .{ .fit = .{} };
        }
        if (comptime cat != .none) return fromScalar(Target, token(cat, v, t));
        return view.literalAs(Target, v);
    }
    // Multi-layer shadow: each layer parsed as shadow (token or custom shadow literal)
    if (comptime Target == core.ShadowList and @typeInfo(V) == .@"struct" and @typeInfo(V).@"struct".is_tuple) {
        const n = @import("zenit_reflection").fields(V).len;
        if (comptime n > @typeInfo(@FieldType(core.ShadowList, "items")).array.len) @compileError("ui.css: too many shadow layers (at most " ++ std.fmt.comptimePrint("{d}", .{@typeInfo(@FieldType(core.ShadowList, "items")).array.len}) ++ ")");
        var layers: [n]core.Shadow = undefined;
        inline for (@import("zenit_reflection").fields(V), 0..) |f, i| layers[i] = resolveInto(core.Shadow, .shadow, @field(v, f.name), t);
        return core.ShadowList.of(&layers);
    }
    if (comptime isNumber(V)) {
        if (Target == Sizing) return .{ .px = v };
        if (Target == Padding) return Padding.all(v);
    }
    if (comptime @typeInfo(V) == .@"struct" and !@typeInfo(V).@"struct".is_tuple and
        @typeInfo(Target) == .@"struct" and allFieldsDefaulted(Target))
    {
        var out: Target = .{};
        if (comptime Target == Padding) {
            if (@hasField(V, "x")) {
                out.left = resolveInto(f32, .space, v.x, t);
                out.right = out.left;
            }
            if (@hasField(V, "y")) {
                out.top = resolveInto(f32, .space, v.y, t);
                out.bottom = out.top;
            }
        }
        inline for (@import("zenit_reflection").fields(V)) |f| {
            if (comptime Target == Padding and (std.mem.eql(u8, f.name, "x") or std.mem.eql(u8, f.name, "y"))) {
                continue;
            } else {
                if (!@hasField(Target, f.name)) @compileError("ui.css: " ++ @typeName(Target) ++ " has no field ." ++ f.name ++ suggest(Target, f.name));
                @field(out, f.name) = resolveInto(@FieldType(Target, f.name), comptime subCat(Target, f.name), @field(v, f.name), t);
            }
        }
        return out;
    }
    return view.literalAs(Target, v);
}

fn fromScalar(comptime Target: type, x: anytype) Target {
    if (Target == Padding and @TypeOf(x) == f32) return Padding.all(x);
    if (Target == Sizing and @TypeOf(x) == f32) return .{ .px = x };
    const out: Target = x;
    return out;
}

fn token(comptime cat: Category, comptime lit: EnumLiteral, t: *const ThemeTokens) TokenType(cat) {
    const name = @tagName(lit);
    if (comptime tokenError(cat, name)) |msg| @compileError("ui.css: " ++ msg);
    const sc = @field(sv.Category, @tagName(cat));
    return theme.resolve(sc, @field(theme.Token(sc), resolveTokenName(theme.Token(sc), name).?), t);
}

/// Get token ref by name (`ui.tokenRef(.color, "bg-primary")`). Name parsing same as ui.css enum
/// literals: exact match first (the design system allows names like `text-hairline`, `2xl`), then
/// replace `-` with `_` (`.yss` `bg-primary` matches `bg_primary`). If neither exists it is a
/// compile error that lists the available names.
pub fn tokenRef(comptime cat: sv.Category, comptime name: []const u8) theme.Token(cat) {
    // Each token value in .yss is one tokenRef: one big recipe calls tokenRef dozens of times in
    // same compile-time evaluation, supply quota per call
    @setEvalBranchQuota(100_000);
    if (comptime tokenError(@field(Category, @tagName(cat)), name)) |msg| @compileError("ui.css: " ++ msg);
    return @field(theme.Token(cat), resolveTokenName(theme.Token(cat), name).?);
}

/// Field name in token enum E corresponding to `name`: original name, or name with `-` replaced by
/// `_`; null if neither.
fn resolveTokenName(comptime E: type, comptime name: []const u8) ?[]const u8 {
    comptime {
        @setEvalBranchQuota(100_000);
        if (@hasField(E, name)) return name;
        var snake: [name.len]u8 = name[0..name.len].*;
        for (&snake) |*ch| {
            if (ch.* == '-') ch.* = '_';
        }
        const s = snake;
        if (@hasField(E, &s)) return &s;
        return null;
    }
}

/// Error text when token name doesn't exist (with alternate names); null if exists. Unit tests
/// assert text directly.
pub fn tokenError(comptime cat: Category, comptime name: []const u8) ?[]const u8 {
    return comptime tokenErrorImpl(cat, name);
}

fn tokenErrorImpl(comptime cat: Category, comptime name: []const u8) ?[]const u8 {
    // Alternate names from token enum itself (actual parseable set), include closest match on typo
    const E = theme.Token(@field(sv.Category, @tagName(cat)));
    if (dualSpelling(E, name)) |snake| return "ambiguous " ++ @tagName(cat) ++ " token ." ++ name ++ ": the theme defines both " ++ name ++ " and " ++ snake ++ "; rename one of them";
    if (resolveTokenName(E, name) != null) return null;
    return "no " ++ @tagName(cat) ++ " token ." ++ name ++ suggest(E, name) ++ " (available: " ++ fieldList(E) ++ ")";
}

/// When both original and `-` -> `_` exist in E, return latter. If theme has both `a-b` and `a_b`,
/// using `a-b` silently rebinds (fallback would bind to `a_b`, adding `a-b` silently changes
/// binding), so coexistence is direct error.
fn dualSpelling(comptime E: type, comptime name: []const u8) ?[]const u8 {
    comptime {
        if (std.mem.indexOfScalar(u8, name, '-') == null or !@hasField(E, name)) return null;
        var snake: [name.len]u8 = name[0..name.len].*;
        for (&snake) |*ch| {
            if (ch.* == '-') ch.* = '_';
        }
        const s = snake;
        return if (@hasField(E, &s)) &s else null;
    }
}

test "token 名解析：原名优先，其次 - 换成 _；数字开头与连字符名都能精确对上" {
    const E = enum { bg_primary, @"text-hairline", @"2xl", @"a-b", a_b };
    try std.testing.expectEqualStrings("bg_primary", comptime resolveTokenName(E, "bg-primary").?);
    try std.testing.expectEqualStrings("bg_primary", comptime resolveTokenName(E, "bg_primary").?);
    try std.testing.expectEqualStrings("text-hairline", comptime resolveTokenName(E, "text-hairline").?);
    try std.testing.expectEqualStrings("2xl", comptime resolveTokenName(E, "2xl").?);
    try std.testing.expect(comptime resolveTokenName(E, "missing") == null);
    // Both `a-b` and `a_b` present: using `a-b` reports ambiguity (tokenError reports this); single
    // spelling like `a_b` or `bg-primary` doesn't count
    try std.testing.expectEqualStrings("a_b", comptime dualSpelling(E, "a-b").?);
    try std.testing.expect(comptime dualSpelling(E, "a_b") == null);
    try std.testing.expect(comptime dualSpelling(E, "bg-primary") == null);
    try std.testing.expect(comptime dualSpelling(E, "text-hairline") == null);
}

fn TokenType(comptime cat: Category) type {
    return sv.Value(@field(sv.Category, @tagName(cat)));
}

// ============================================================================
// Parameterized styles (.yss `style name($p: T) { ... }` codegen)
// ============================================================================

/// Fallback for optional values: `ui.orElse(width, .fit)` = use width if non-null, else fallback;
/// fallback parsed per field's token category (same value syntax as regular styles: `.fit`,
/// `.bg_secondary`, `0`, `Color.TRANSPARENT`).
pub fn orElse(value: anytype, comptime fallback: anytype) OrElse(@TypeOf(value), fallback) {
    return .{ .value = value };
}

pub fn OrElse(comptime V: type, comptime fallback_value: anytype) type {
    if (@typeInfo(V) != .optional) @compileError("ui.orElse: the value must be optional, got " ++ @typeName(V));
    return struct {
        value: V,
        pub const zenit_or_else = true;
        pub const fallback = fallback_value;
    };
}

fn isOrElse(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "zenit_or_else");
}

/// Parameterized style: `A`'s fields are parameters (optional with defaults), `A.resolve(args, t)`
/// produces box style per params, `A.declared` is all declared field names (regardless of
/// condition, StyleExt reserves by this). In views use `S.name.of(.{ .width = w })`: arguments may
/// be values or reactive sources; reading a source registers a dependency, and when all are
/// static the style is recomputed only on theme change. In hand-written Zig use
/// `S.name.resolve(.{ .width = 120 }, t)`.
pub fn paramStyle(comptime A: type) type {
    comptime {
        if (!@hasDecl(A, "resolve") or !@hasDecl(A, "declared")) @compileError("ui.paramStyle: expects the struct generated from a .yss `style name($p: T) { … }`");
    }
    return struct {
        const Self = @This();
        pub const Args = A;
        pub const needs_ext = blk: {
            for (A.declared) |n| {
                if (std.mem.eql(u8, n, "typography") or BoxStyle.fieldNeedsExt(boxName(n))) break :blk true;
            }
            break :blk false;
        };
        pub const sets_icon_color = blk: {
            for (A.declared) |n| if (std.mem.eql(u8, n, "icon_color")) break :blk true;
            break :blk false;
        };

        pub fn resolve(args: A, t: *const ThemeTokens) BoxStyle {
            if (preview_enabled) reload.observeGeneration();
            return A.resolve(args, t);
        }

        /// Component put into `.style`
        pub fn of(args: anytype) Part(@TypeOf(args)) {
            return .{ .args = args };
        }

        pub fn Part(comptime X: type) type {
            comptime {
                for (@import("zenit_reflection").fields(X)) |f| {
                    if (!@hasField(A, f.name)) @compileError("ui.paramStyle .of: no parameter ." ++ f.name ++ suggest(A, f.name) ++ " (available: " ++ fieldList(A) ++ ")");
                }
                for (@import("zenit_reflection").fields(A)) |f| {
                    if (f.default_value_ptr == null and !@hasField(X, f.name)) @compileError("ui.paramStyle .of: missing parameter ." ++ f.name ++ " (it has no default)");
                }
            }
            return struct {
                args: X,
                pub const zenit_style_part = .param;
                pub const R = Self;
            };
        }
    };
}

// ============================================================================
// Color blending
// ============================================================================

/// Linear mix of two colors: `ui.mix(T.color.bg_primary, T.color.accent, 0.25)` = 25% toward accent
/// from bg_primary. Operands can be color token, `Color` value or another mix; evaluated at apply
/// time like token ref, follows theme change.
pub fn mix(a: anytype, b: anytype, comptime weight: f32) ColorMix(@TypeOf(a), @TypeOf(b)) {
    comptime if (weight < 0 or weight > 1) @compileError("ui.mix: weight must be within 0..1");
    comptime checkMixOperand(@TypeOf(a));
    comptime checkMixOperand(@TypeOf(b));
    return .{ .a = a, .b = b, .weight = weight };
}

pub fn ColorMix(comptime A: type, comptime B: type) type {
    return struct {
        a: A,
        b: B,
        weight: f32,
        pub const zenit_color_mix = true;

        pub fn resolve(self: @This(), t: *const ThemeTokens) Color {
            return Color.lerp(mixOperand(self.a, t), mixOperand(self.b, t), self.weight);
        }
    };
}

fn isColorMix(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "zenit_color_mix");
}

fn checkMixOperand(comptime T: type) void {
    if (T == Color or isColorMix(T)) return;
    if (refCategory(T)) |c| if (c == .color) return;
    @compileError("ui.mix: operands are color tokens (T.color.*), Color values or another ui.mix, got " ++ @typeName(T));
}

fn mixOperand(x: anytype, t: *const ThemeTokens) Color {
    const X = @TypeOf(x);
    if (X == Color) return x;
    if (comptime isColorMix(X)) return x.resolve(t);
    return theme.resolve(.color, x, t);
}

fn refCategory(comptime T: type) ?sv.Category {
    if (@typeInfo(T) != .@"enum") return null;
    inline for (@import("zenit_reflection").fields(sv.Category)) |f| {
        const category = @field(sv.Category, f.name);
        if (T == theme.Token(category)) return category;
    }
    return null;
}

// ============================================================================
// Validation
// ============================================================================

/// Not a style field, view-layer-only key: `transition` (property transition on the node, see
/// `ui.transition`).
/// Whether spec (including variants / conditions / slot layers) has field `name`
fn mentionsField(comptime S: type, comptime name: []const u8) bool {
    @setEvalBranchQuota(100_000);
    if (@typeInfo(S) != .@"struct") return false;
    for (@import("zenit_reflection").fields(S)) |f| {
        if (std.mem.eql(u8, f.name, name)) return true;
        if (mentionsField(f.type, name)) return true;
    }
    return false;
}

/// Fields only in box style (text style doesn't have): padding, background, corner_radius, border,
/// ...
fn isBoxOnly(comptime name: []const u8) bool {
    if (isConditionKey(name) or isMetaKey(name) or std.mem.eql(u8, name, "typography")) return false;
    const as_text = if (std.mem.eql(u8, name, "text_color")) "color" else name;
    if (@hasField(TextStyle, as_text)) return false;
    return @hasField(BoxStyle, name);
}

fn hasBoxOnlyFields(comptime S: type) bool {
    for (@import("zenit_reflection").fields(S)) |f| if (isBoxOnly(f.name)) return true;
    return false;
}

/// Text part / box part in spec (comptime fields copied as-is). Condition blocks only modify text
/// fields (text node only has _hover condition).
fn textSpec(comptime spec: anytype) SplitSpec(@TypeOf(spec), false) {
    return .{};
}
fn boxSpec(comptime spec: anytype) SplitSpec(@TypeOf(spec), true) {
    return .{};
}

fn SplitSpec(comptime S: type, comptime want_box: bool) type {
    var fields: []const @import("zenit_reflection").StructField = &.{};
    for (@import("zenit_reflection").fields(S)) |f| {
        if (isConditionKey(f.name) and hasBoxOnlyFields(f.type))
            @compileError("ui.css on text: condition ." ++ f.name ++ " changes box fields; on text, conditions can only change text fields");
        if (isBoxOnly(f.name) == want_box) {
            if (!f.is_comptime) @compileError("ui.css: style values are compile-time");
            fields = fields ++ &[_]@import("zenit_reflection").StructField{f};
        }
    }
    return @import("zenit_reflection").Struct(fields);
}

fn isMetaKey(comptime name: []const u8) bool {
    return std.mem.eql(u8, name, "transition");
}

/// Transition declared on style object (`.transition = ui.transition("background", ...)`).
pub fn transitionsOf(comptime spec: anytype) []const recipe_mod.TransitionEntry {
    if (!@hasField(@TypeOf(spec), "transition")) return &.{};
    const entries = spec.transition;
    return &entries;
}

fn isConditionKey(comptime name: []const u8) bool {
    return name.len > 0 and name[0] == '_';
}

fn hasAnyCondition(comptime S: type) bool {
    for (@import("zenit_reflection").fields(S)) |f| if (isConditionKey(f.name)) return true;
    return false;
}

/// Which conditions besides `_hover` / `_active` were used (normal box only accepts used state
/// sources).
pub const StateConditions = struct {
    focus: bool = false,
    focus_visible: bool = false,
    disabled: bool = false,
    invalid: bool = false,
    selected: bool = false,
    expanded: bool = false,

    pub fn any(self: StateConditions) bool {
        inline for (@import("zenit_reflection").fields(StateConditions)) |f| if (@field(self, f.name)) return true;
        return false;
    }

    pub fn merge(a: StateConditions, b: StateConditions) StateConditions {
        var out = a;
        inline for (@import("zenit_reflection").fields(StateConditions)) |f| @field(out, f.name) = @field(a, f.name) or @field(b, f.name);
        return out;
    }
};

pub fn stateConditionsOf(comptime S: type) StateConditions {
    var out: StateConditions = .{};
    inline for (@import("zenit_reflection").fields(StateConditions)) |f| {
        if (@hasField(S, "_" ++ f.name)) @field(out, f.name) = true;
    }
    return out;
}

fn slotStateConditions(comptime specs: anytype, comptime name: []const u8) StateConditions {
    if (!@hasField(@TypeOf(specs), name)) return .{};
    return stateConditionsOf(@TypeOf(specOf(@field(specs, name))));
}

fn firstStateCondition(comptime S: type) ?[]const u8 {
    for (@import("zenit_reflection").fields(S)) |f| {
        if (isConditionKey(f.name) and !std.mem.eql(u8, f.name, "_hover") and !std.mem.eql(u8, f.name, "_active")) return f.name;
    }
    return null;
}

/// Struct error in style literal (unknown condition, condition nesting, not a struct literal); null
/// if none.
pub fn specError(comptime S: type, comptime allow_conditions: bool) ?[]const u8 {
    return comptime specErrorImpl(S, allow_conditions);
}

fn colorAliasError(comptime S: type) ?[]const u8 {
    return if (@hasField(S, "color") and @hasField(S, "text_color"))
        ".color and .text_color name the same property; specify only one"
    else
        null;
}

fn specErrorImpl(comptime S: type, comptime allow_conditions: bool) ?[]const u8 {
    if (@typeInfo(S) != .@"struct" or @typeInfo(S).@"struct".is_tuple and @import("zenit_reflection").fields(S).len != 0)
        return "expected a style object like .{ .padding = .space400 }, got " ++ @typeName(S);
    if (colorAliasError(S)) |msg| return msg;
    for (@import("zenit_reflection").fields(S)) |f| {
        if (!isConditionKey(f.name)) continue;
        if (!allow_conditions) return "condition ." ++ f.name ++ " cannot be nested inside another condition";
        var known = false;
        for (conditions) |c| {
            if (std.mem.eql(u8, f.name[1..], c)) known = true;
        }
        if (!known) return "unknown condition ." ++ f.name ++ " (available: _selected, _expanded, _hover, _active, _focus, _focus_visible, _invalid, _disabled)";
        if (specErrorImpl(f.type, false)) |msg| return msg;
    }
    return null;
}

/// Whether style literal (type) has token refs: if yes, read theme, re-evaluate on theme change.
pub fn usesTokens(comptime S: type) bool {
    @setEvalBranchQuota(100_000);
    return comptime usesTokensIn(S, null);
}

fn usesTokensIn(comptime S: type, comptime Parent: ?type) bool {
    if (@typeInfo(S) != .@"struct" or @typeInfo(S).@"struct".is_tuple) return false;
    for (@import("zenit_reflection").fields(S)) |f| {
        const cat = if (Parent) |P| subCat(P, f.name) else catOf(f.name);
        if (refCategory(f.type) != null or isColorMix(f.type)) return true;
        if (f.type == EnumLiteral and cat != .none) return true;
        if (@typeInfo(f.type) == .@"struct") {
            // Nested literal: padding / border etc. categorize per target type
            const Target = if (Parent == null and @hasField(BoxStyle, f.name)) unwrap(@FieldType(BoxStyle, f.name)) else Padding;
            const P2: ?type = if (Parent == null and (std.mem.eql(u8, f.name, "padding") or std.mem.eql(u8, f.name, "margin"))) Padding else if (@typeInfo(Target) == .@"struct") Target else null;
            if (usesTokensIn(f.type, P2)) return true;
        }
    }
    return false;
}

fn unwrap(comptime T: type) type {
    return if (@typeInfo(T) == .optional) @typeInfo(T).optional.child else T;
}

fn isNumber(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .int, .float, .comptime_int, .comptime_float => true,
        else => false,
    };
}

fn allFieldsDefaulted(comptime T: type) bool {
    for (@import("zenit_reflection").fields(T)) |f| if (f.defaultValue() == null) return false;
    return true;
}

fn fieldList(comptime S: type) []const u8 {
    comptime var out: []const u8 = "";
    inline for (comptime @import("zenit_reflection").fields(S), 0..) |f, i| out = out ++ (if (i == 0) "" else ", ") ++ "." ++ f.name;
    return out;
}

/// On typo, give closest field name (edit distance <= 2).
fn suggest(comptime S: type, comptime name: []const u8) []const u8 {
    return comptime suggestImpl(S, name);
}

fn suggestImpl(comptime S: type, comptime name: []const u8) []const u8 {
    @setEvalBranchQuota(200_000);
    var best: ?[]const u8 = null;
    var best_d: usize = 3;
    for (@import("zenit_reflection").fields(S)) |f| {
        const d = editDistance(name, f.name);
        if (d < best_d) {
            best_d = d;
            best = f.name;
        }
    }
    return if (best) |b| " (did you mean ." ++ b ++ "?)" else "";
}

fn editDistance(comptime a: []const u8, comptime b: []const u8) usize {
    var prev: [b.len + 1]usize = undefined;
    for (&prev, 0..) |*p, j| p.* = j;
    for (a, 0..) |ca, i| {
        var cur: [b.len + 1]usize = undefined;
        cur[0] = i + 1;
        for (b, 0..) |cb, j| {
            const sub = prev[j] + @intFromBool(ca != cb);
            cur[j + 1] = @min(sub, @min(prev[j + 1] + 1, cur[j] + 1));
        }
        prev = cur;
    }
    return prev[b.len];
}

// ============================================================================
// cva()
// ============================================================================

/// Recipe with variants (like Panda / CVA's cva). Returns a type:
/// - `Variants`: one field per dimension (enum generated from option names; bool when the options
///   are `true` / `false`); defaults come from `.defaults`, else the first option;
/// - `resolve(variants, tokens) ConditionalStyle`: merge order base < variants < compound, same
///   as `ui.recipe.recipe`;
/// - `of(.{ .dim = value or reactive source })`: a style part to put in `.style`; the value may
///   be an enum literal, any enum with the same option names, or a reactive source of those.
pub fn cva(comptime config: anytype) type {
    return CvaImpl(config, null);
}

pub fn previewCva(comptime path: []const u8, comptime name: []const u8, comptime source: []const u8, comptime config: anytype) type {
    return CvaImpl(config, if (preview_enabled) .{ .path = path, .name = name, .source = source } else null);
}

fn CvaImpl(comptime config: anytype, comptime descriptor: ?PreviewDescriptor) type {
    @setEvalBranchQuota(200_000);
    const C = @TypeOf(config);
    comptime {
        for (@import("zenit_reflection").fields(C)) |f| {
            const ok = std.mem.eql(u8, f.name, "base") or std.mem.eql(u8, f.name, "variants") or
                std.mem.eql(u8, f.name, "compound") or std.mem.eql(u8, f.name, "defaults");
            if (!ok) @compileError("ui.cva: unknown key ." ++ f.name ++ " (available: .base, .variants, .compound, .defaults)");
        }
    }
    const base_spec = if (@hasField(C, "base")) specOf(config.base) else .{};
    const variants_cfg = if (@hasField(C, "variants")) config.variants else .{};
    const compound_cfg = if (@hasField(C, "compound")) config.compound else .{};
    const defaults_cfg = if (@hasField(C, "defaults")) config.defaults else .{};
    const dims = @import("zenit_reflection").fields(@TypeOf(variants_cfg));

    comptime {
        if (specError(@TypeOf(base_spec), true)) |msg| @compileError("ui.cva .base: " ++ msg);
        for (dims) |d| {
            for (@import("zenit_reflection").fields(@TypeOf(@field(variants_cfg, d.name)))) |o| {
                if (specError(@TypeOf(specOf(@field(@field(variants_cfg, d.name), o.name))), true)) |msg|
                    @compileError("ui.cva .variants." ++ d.name ++ "." ++ o.name ++ ": " ++ msg);
            }
        }
        for (@import("zenit_reflection").fields(@TypeOf(defaults_cfg))) |f| {
            if (!@hasField(@TypeOf(variants_cfg), f.name)) @compileError("ui.cva .defaults: no variant ." ++ f.name);
        }
    }

    const VariantsT = variantsType(variants_cfg, defaults_cfg);
    comptime for (compound_cfg) |c| {
        if (specError(@TypeOf(specOf(c.style)), true)) |msg| @compileError("ui.cva .compound: " ++ msg);
        for (@import("zenit_reflection").fields(@TypeOf(c.when))) |f| {
            if (!@hasField(VariantsT, f.name)) @compileError("ui.cva .compound: no variant ." ++ f.name);
            _ = convert(@FieldType(VariantsT, f.name), @field(c.when, f.name));
        }
    };

    const any_hover, const state_cond, const any_active, const all_conds = comptime blk: {
        @setEvalBranchQuota(100_000);
        var hover = @hasField(@TypeOf(base_spec), "_hover");
        var active = @hasField(@TypeOf(base_spec), "_active");
        var state: ?[]const u8 = firstStateCondition(@TypeOf(base_spec));
        var conds = stateConditionsOf(@TypeOf(base_spec));
        for (dims) |d| {
            for (@import("zenit_reflection").fields(@TypeOf(@field(variants_cfg, d.name)))) |o| {
                const S = @TypeOf(specOf(@field(@field(variants_cfg, d.name), o.name)));
                if (@hasField(S, "_hover")) hover = true;
                if (@hasField(S, "_active")) active = true;
                if (state == null) state = firstStateCondition(S);
                conds = conds.merge(stateConditionsOf(S));
            }
        }
        for (compound_cfg) |c| {
            const S = @TypeOf(specOf(c.style));
            if (@hasField(S, "_hover")) hover = true;
            if (@hasField(S, "_active")) active = true;
            if (state == null) state = firstStateCondition(S);
            conds = conds.merge(stateConditionsOf(S));
        }
        break :blk .{ hover, state, active, conds };
    };

    return struct {
        const Recipe = @This();
        pub const preview_id = if (descriptor) |d| d.path ++ ":" ++ d.name ++ ":root" else null;
        pub const preview_compiled = if (descriptor != null) cva(config) else @This();
        pub const Variants = VariantsT;
        pub const has_hover = any_hover;
        pub const has_active = any_active;
        pub const needs_ext = recipeNeedsExt(config, null);
        pub const state_condition: ?[]const u8 = state_cond;
        pub const state_conditions = all_conds;
        pub const sets_icon_color = mentionsField(@TypeOf(config), "icon_color");
        /// Transition declared only on base (variant switch, hover both use same tween)
        pub const transitions = transitionsOf(base_spec);

        /// Type of one dimension: component props can declare it directly
        /// (`size: Btn.Dim(.size) = .md`).
        pub fn Dim(comptime name: EnumLiteral) type {
            return @FieldType(Variants, @tagName(name));
        }

        pub fn resolve(variants: Variants, t: *const ThemeTokens) ConditionalStyle {
            if (preview_enabled) reload.observeGeneration();
            if (comptime descriptor) |d| {
                reload.observeGeneration();
                if (reload.lookup(d.path, d.name, d.source)) |decl| return reload.evaluateRecipe(decl, variants, t) catch unreachable;
            }
            var out: ConditionalStyle = .{};
            applyRecipe(&out, config, null, variants, t);
            return out;
        }

        pub fn resolveText(variants: Variants, base: TextStyle, t: *const ThemeTokens) TextStyle {
            if (preview_enabled) reload.observeGeneration();
            if (comptime descriptor) |d| {
                reload.observeGeneration();
                if (reload.lookup(d.path, d.name, d.source)) |decl| return reload.evaluateRecipeText(decl, variants, base, t) catch unreachable;
            }
            var out = base;
            applyRecipe(&out, config, null, variants, t);
            return out;
        }

        pub fn resolveBase(variants: Variants, t: *const ThemeTokens) BoxStyle {
            return resolve(variants, t).base;
        }

        /// Component put into `.style`.
        pub fn of(args: anytype) Part(@TypeOf(args)) {
            return .{ .args = args };
        }

        pub fn Part(comptime Args: type) type {
            comptime for (@import("zenit_reflection").fields(Args)) |f| {
                if (!@hasField(Variants, f.name)) @compileError("ui.cva .of: no variant ." ++ f.name ++ " (available: " ++ fieldList(Variants) ++ ")");
            };
            return struct {
                args: Args,
                pub const zenit_style_part = .cva;
                pub const R = Recipe;

                /// Runtime per-state layers merged onto the recipe's before the node's state
                /// resolves them (ConditionalStyle.merge: base onto base, hover onto hover, …):
                /// a caller's base sits under the recipe's :hover / :active / :disabled, where a
                /// later part of a style tuple would win over every state of this one. `layers`
                /// is a ConditionalStyle or a source of one; since any condition may appear, the
                /// element must give every semantic state (state= or a11y).
                pub fn merge(self: @This(), layers: anytype) Merged(Args, @TypeOf(layers)) {
                    return .{ .args = self.args, .layers = layers };
                }
            };
        }

        pub fn Merged(comptime Args: type, comptime Layers: type) type {
            return struct {
                args: Args,
                layers: Layers,
                pub const zenit_style_part = .cva;
                pub const R = Recipe;
            };
        }

        /// Value from any source -> value for this dimension (enum literal, another enum with same
        /// option name, bool).
        pub fn toDim(comptime D: type, x: anytype) D {
            return convert(D, x);
        }
    };
}

/// Multi-part recipe. Each variant option is a map from slot names to css specs.
/// `resolve(.{}, tokens).root` returns ConditionalStyle for component authors;
/// `of(.{ .size = source }).root` is a normal reactive view style part.
pub fn sva(comptime config: anytype) type {
    const C = @TypeOf(config);
    comptime {
        if (!@hasField(C, "slots")) @compileError("ui.sva: .slots = .{ .root, .label, ... } is required");
        if (config.slots.len == 0) @compileError("ui.sva: at least one slot is required");
        for (@import("zenit_reflection").fields(C)) |f| {
            var valid = false;
            for (.{ "slots", "base", "variants", "defaults", "compound", "derived" }) |key|
                valid = valid or std.mem.eql(u8, f.name, key);
            if (!valid) @compileError("ui.sva: unknown key ." ++ f.name);
        }
        for (config.slots, 0..) |slot_name, i| {
            for (config.slots, 0..) |prev, j| {
                if (j < i and std.mem.eql(u8, @tagName(prev), @tagName(slot_name)))
                    @compileError("ui.sva: duplicate slot ." ++ @tagName(slot_name));
            }
        }
    }
    const base = if (@hasField(C, "base")) config.base else .{};
    const variants = if (@hasField(C, "variants")) config.variants else .{};
    const defaults = if (@hasField(C, "defaults")) config.defaults else .{};
    const compounds = if (@hasField(C, "compound")) config.compound else .{};
    const V = variantsType(variants, defaults);
    comptime {
        // Validation work grows with slot × dimension × option (e.g. Tag: 4 slots × 6 colors × 2
        // variants × 2 sizes)
        @setEvalBranchQuota(100_000);
        validateSlots(config.slots, base);
        for (@import("zenit_reflection").fields(@TypeOf(defaults))) |f| {
            if (!@hasField(V, f.name)) @compileError("ui.sva .defaults: no variant ." ++ f.name);
        }
        for (@import("zenit_reflection").fields(@TypeOf(variants))) |d| {
            const opts = @field(variants, d.name);
            for (@import("zenit_reflection").fields(@TypeOf(opts))) |o| validateSlots(config.slots, @field(opts, o.name));
        }
        for (compounds) |c| {
            validateSlots(config.slots, c.style);
            for (@import("zenit_reflection").fields(@TypeOf(c.when))) |f| {
                if (!@hasField(V, f.name)) @compileError("ui.sva .compound: no variant ." ++ f.name);
                _ = convert(@FieldType(V, f.name), @field(c.when, f.name));
            }
        }
    }
    return struct {
        pub const Variants = V;
        pub const Slots = slotRecord(config.slots, ConditionalStyle, true);
        /// Derived styles supply base geometry only, never condition layers.
        pub const Derived = slotRecord(config.slots, BoxStyle, true);

        pub fn Dim(comptime name: EnumLiteral) type {
            return @FieldType(V, @tagName(name));
        }

        pub fn resolve(vs: V, t: *const ThemeTokens) Slots {
            if (preview_enabled) reload.observeGeneration();
            var out: Slots = .{};
            applyRecipe(&out, config, null, vs, t);
            return out;
        }

        /// Select a slot as a view style. Conditions and signal variants follow
        /// exactly the same view plan as cva; no separate runtime is needed.
        pub fn slot(comptime name: EnumLiteral, args: anytype) Slot(name).Part(@TypeOf(args)) {
            return Slot(name).of(args);
        }

        pub fn Slot(comptime name: EnumLiteral) type {
            const n = @tagName(name);
            if (!@hasField(Slots, n)) @compileError("ui.sva: no slot ." ++ n ++ " (available: " ++ fieldList(Slots) ++ ")");
            const flags = comptime blk: {
                @setEvalBranchQuota(100_000);
                var h = slotHasHover(base, n);
                var a = slotHasKey(base, n, "_active");
                var state = slotCondition(base, n);
                var conds = slotStateConditions(base, n);
                for (@import("zenit_reflection").fields(@TypeOf(variants))) |d| {
                    const opts = @field(variants, d.name);
                    for (@import("zenit_reflection").fields(@TypeOf(opts))) |o| {
                        const specs = @field(opts, o.name);
                        h = h or slotHasHover(specs, n);
                        a = a or slotHasKey(specs, n, "_active");
                        if (state == null) state = slotCondition(specs, n);
                        conds = conds.merge(slotStateConditions(specs, n));
                    }
                }
                for (compounds) |c| {
                    h = h or slotHasHover(c.style, n);
                    a = a or slotHasKey(c.style, n, "_active");
                    if (state == null) state = slotCondition(c.style, n);
                    conds = conds.merge(slotStateConditions(c.style, n));
                }
                break :blk .{ h, state, a, conds };
            };
            return struct {
                const SlotRecipe = @This();
                pub const Variants = V;
                pub const has_hover = flags[0];
                pub const has_active = flags[2];
                pub const needs_ext = recipeNeedsExt(config, n);
                pub const state_condition = flags[1];
                pub const state_conditions = flags[3];
                pub const sets_icon_color = mentionsField(@TypeOf(config), "icon_color");
                pub const toDim = convert;
                pub const transitions = transitionsOf(layerSpec(base, n));
                pub fn resolve(vs: V, t: *const ThemeTokens) ConditionalStyle {
                    if (preview_enabled) reload.observeGeneration();
                    var out: ConditionalStyle = .{};
                    applyRecipe(&out, config, n, vs, t);
                    return out;
                }
                pub fn resolveText(vs: V, base_text: TextStyle, t: *const ThemeTokens) TextStyle {
                    if (preview_enabled) reload.observeGeneration();
                    var out = base_text;
                    applyRecipe(&out, config, n, vs, t);
                    return out;
                }
                pub fn of(args: anytype) Part(@TypeOf(args)) {
                    return .{ .args = args };
                }
                pub fn Part(comptime Args: type) type {
                    comptime for (@import("zenit_reflection").fields(Args)) |f| {
                        if (!@hasField(V, f.name)) @compileError("ui.sva .of: no variant ." ++ f.name);
                    };
                    return struct {
                        args: Args,
                        pub const zenit_style_part = .cva;
                        pub const R = SlotRecipe;
                    };
                }
            };
        }

        pub fn Parts(comptime Args: type) type {
            var fs: [config.slots.len]@import("zenit_reflection").StructField = undefined;
            for (config.slots, 0..) |n, i| {
                const T = Slot(n).Part(Args);
                fs[i] = .{ .name = @tagName(n), .type = T, .default_value_ptr = null, .is_comptime = false, .alignment = @alignOf(T) };
            }
            return @import("zenit_reflection").Struct(&fs);
        }

        pub fn of(args: anytype) Parts(@TypeOf(args)) {
            var out: Parts(@TypeOf(args)) = undefined;
            inline for (config.slots) |n| @field(out, @tagName(n)) = slot(n, args);
            return out;
        }
    };
}

fn validateSlots(comptime slots: anytype, comptime specs: anytype) void {
    for (@import("zenit_reflection").fields(@TypeOf(specs))) |f| {
        var found = false;
        for (slots) |s| found = found or std.mem.eql(u8, f.name, @tagName(s));
        if (!found) @compileError("ui.sva: undeclared slot ." ++ f.name);
        if (specError(@TypeOf(specOf(@field(specs, f.name))), true)) |msg| @compileError("ui.sva ." ++ f.name ++ ": " ++ msg);
    }
}

fn slotRecord(comptime slots: anytype, comptime T: type, comptime defaults: bool) type {
    var fs: [slots.len]@import("zenit_reflection").StructField = undefined;
    const Holder = struct {
        const value: T = .{};
    };
    for (slots, 0..) |s, i| fs[i] = .{
        .name = @tagName(s),
        .type = T,
        .default_value_ptr = if (defaults) @ptrCast(&Holder.value) else null,
        .is_comptime = false,
        .alignment = @alignOf(T),
    };
    return @import("zenit_reflection").Struct(&fs);
}

fn slotHasHover(comptime specs: anytype, comptime name: []const u8) bool {
    return slotHasKey(specs, name, "_hover");
}

fn slotHasKey(comptime specs: anytype, comptime name: []const u8, comptime key: []const u8) bool {
    if (!@hasField(@TypeOf(specs), name)) return false;
    return @hasField(@TypeOf(specOf(@field(specs, name))), key);
}

fn slotCondition(comptime specs: anytype, comptime name: []const u8) ?[]const u8 {
    if (!@hasField(@TypeOf(specs), name)) return null;
    return firstStateCondition(@TypeOf(specOf(@field(specs, name))));
}

fn variantsType(comptime variants_cfg: anytype, comptime defaults_cfg: anytype) type {
    const dims = @import("zenit_reflection").fields(@TypeOf(variants_cfg));
    var fields: [dims.len]@import("zenit_reflection").StructField = undefined;
    for (dims, 0..) |d, i| {
        const D = DimType(@TypeOf(@field(variants_cfg, d.name)));
        const default: D = if (@hasField(@TypeOf(defaults_cfg), d.name))
            convert(D, @field(defaults_cfg, d.name))
        else
            firstOption(D, @TypeOf(@field(variants_cfg, d.name)));
        const holder = struct {
            const value: D = default;
        };
        fields[i] = .{
            .name = d.name,
            .type = D,
            .default_value_ptr = @ptrCast(&holder.value),
            .is_comptime = false,
            .alignment = @alignOf(D),
        };
    }
    return @import("zenit_reflection").Struct(&fields);
}

fn isBoolDim(comptime Opts: type) bool {
    const fs = @import("zenit_reflection").fields(Opts);
    if (fs.len == 0) return false;
    for (fs) |f| {
        if (!std.mem.eql(u8, f.name, "true") and !std.mem.eql(u8, f.name, "false")) return false;
    }
    return true;
}

fn DimType(comptime Opts: type) type {
    const fs = @import("zenit_reflection").fields(Opts);
    if (fs.len == 0) @compileError("ui.cva: a variant needs at least one option");
    if (isBoolDim(Opts)) return bool;
    var efields: [fs.len]@import("zenit_reflection").EnumField = undefined;
    for (fs, 0..) |f, i| efields[i] = .{ .name = f.name, .value = i };
    return @import("zenit_reflection").Enum(std.math.IntFittingRange(0, fs.len - 1), &efields);
}

fn firstOption(comptime D: type, comptime Opts: type) D {
    return optionValue(D, @import("zenit_reflection").fields(Opts)[0].name);
}

fn optionValue(comptime D: type, comptime name: []const u8) D {
    if (D == bool) return std.mem.eql(u8, name, "true");
    return @field(D, name);
}

fn convert(comptime D: type, x: anytype) D {
    const X = @TypeOf(x);
    if (X == D) return x;
    if (X == EnumLiteral) {
        if (D == bool) @compileError("ui.cva: this variant is a bool; pass true / false");
        if (!@hasField(D, @tagName(x))) @compileError("ui.cva: no option ." ++ @tagName(x) ++ " (available: " ++ fieldList(D) ++ ")");
        return @field(D, @tagName(x));
    }
    if (D == bool) {
        const b: bool = x;
        return b;
    }
    if (@typeInfo(X) == .@"enum") {
        comptime for (@import("zenit_reflection").fields(X)) |f| {
            if (!@hasField(D, f.name)) @compileError("ui.cva: " ++ @typeName(X) ++ "." ++ f.name ++ " has no matching option (available: " ++ fieldList(D) ++ ")");
        };
        return switch (x) {
            inline else => |tag| @field(D, @tagName(tag)),
        };
    }
    @compileError("ui.cva: cannot use " ++ @typeName(X) ++ " as a variant value");
}

// ============================================================================
// Tests (pure parsing, no node building; node-mounted behavior see view_tests.zig)
// ============================================================================

const testing = std.testing;
const light = &theme.light;
const dark = &theme.dark;

test "css: token 按字段类别查表，数值直通，便捷写法展开" {
    const s = boxFrom(.{
        .background = .bg_secondary,
        .padding = .{ .x = .space300, .y = .space100 },
        .margin = .space200,
        .gap = .space200,
        .corner_radius = .md,
        .width = 420,
        .height = .fill,
        .font_weight = .semibold,
        .color = .fg_tertiary,
        .border = .{ .color = .border, .width = .thin, .radius = .lg },
        .align_items = .center,
    }, light);
    try testing.expect(Color.eql(light.tokens.color.bg_secondary, s.background.?));
    try testing.expectEqual(light.tokens.space.space300, s.padding.?.left);
    try testing.expectEqual(light.tokens.space.space300, s.padding.?.right);
    try testing.expectEqual(light.tokens.space.space100, s.padding.?.top);
    try testing.expectEqual(light.tokens.space.space100, s.padding.?.bottom);
    try testing.expectEqual(light.tokens.space.space200, s.margin.?.left);
    try testing.expectEqual(light.tokens.space.space200, s.gap.?);
    try testing.expectEqual(light.tokens.radius.md, s.corner_radius.?);
    try testing.expectEqual(@as(f32, 420), s.width.?.px);
    try testing.expect(s.height.? == .grow);
    try testing.expectEqual(@as(u16, 600), s.font_weight.?);
    try testing.expect(Color.eql(light.tokens.color.fg_tertiary, s.text_color.?));
    try testing.expect(Color.eql(light.tokens.color.border, s.border.?.color));
    try testing.expectEqual(light.tokens.border_width.thin, s.border.?.width);
    try testing.expectEqual(light.tokens.radius.lg, s.border.?.radius);
    try testing.expectEqual(core.AlignItems.center, s.align_items.?);
    // Same declaration, different theme, get different value set
    try testing.expect(Color.eql(dark.tokens.color.bg_secondary, boxFrom(.{ .background = .bg_secondary }, dark).background.?));
}

test "css: 未知 token / 条件报错文本带可选名" {
    try testing.expect(tokenError(.space, "space400") == null);
    const msg = comptime tokenError(.radius, "huge").?;
    try testing.expect(std.mem.indexOf(u8, msg, "no radius token .huge") != null);
    try testing.expect(std.mem.indexOf(u8, comptime tokenError(.space, "spaec400").?, "(did you mean .space400?)") != null);
    try testing.expect(std.mem.indexOf(u8, msg, ".md") != null);
    const cond = comptime specError(@TypeOf(.{ ._hovered = .{} }), true).?;
    try testing.expect(std.mem.indexOf(u8, cond, "unknown condition ._hovered") != null);
    const nested = comptime specError(@TypeOf(.{ ._hover = .{ ._focus = .{} } }), true).?;
    try testing.expect(std.mem.indexOf(u8, nested, "cannot be nested") != null);
    try testing.expectEqualStrings(" (did you mean .padding?)", comptime suggest(BoxStyle, "paddin"));
}

test "css: 条件层进 ConditionalStyle；文本按字段叠加到 base" {
    const card = css(.{ .background = .bg_secondary, ._hover = .{ .background = .bg_hover }, ._selected = .{ .background = .accent } });
    const C = @TypeOf(card);
    try testing.expect(C.has_hover);
    try testing.expectEqualStrings("_selected", C.state_condition.?);
    const cs = C.conditional(light);
    try testing.expect(Color.eql(light.tokens.color.bg_hover, cs.resolve(.{ .is_hovered = true }).background.?));
    try testing.expect(Color.eql(light.tokens.color.accent, cs.resolve(.{ .is_selected = true }).background.?));
    try testing.expect(cs.focus == null);

    const title = css(.{ .font_size = .xl, .font_weight = .bold, .color = .fg_tertiary });
    const base: TextStyle = .{ .color = light.tokens.color.fg_primary, .font_size = 1, .max_lines = 2 };
    const ts = @TypeOf(title).text(base, light);
    try testing.expectEqual(light.tokens.font_size.xl, ts.font_size);
    try testing.expectEqual(@as(u16, 700), ts.font_weight);
    try testing.expect(Color.eql(light.tokens.color.fg_tertiary, ts.color));
    try testing.expectEqual(@as(u16, 2), ts.max_lines); // Undeclared field stays base
}

test "css: usesTokens 只在有 token 引用时为真" {
    try testing.expect(usesTokens(@TypeOf(.{ .background = .bg_hover })));
    try testing.expect(usesTokens(@TypeOf(.{ .padding = .{ .x = .space200 } })));
    try testing.expect(usesTokens(@TypeOf(.{ .border = .{ .color = .border } })));
    try testing.expect(usesTokens(@TypeOf(.{ .gap = 4, .align_items = .center, .font_weight = .bold })));
    try testing.expect(!usesTokens(@TypeOf(.{ .width = .{ .px = 3 }, .padding = .{ .top = 4 } })));
}

const Size = enum { sm, md, lg };

const Btn = cva(.{
    .base = .{ .corner_radius = .md, .padding = .{ .x = .space300 } },
    .variants = .{
        .intent = .{
            .primary = .{ .background = .accent },
            .ghost = css(.{ .background = Color.TRANSPARENT, ._hover = .{ .background = .bg_hover } }),
        },
        .size = .{ .sm = .{ .gap = .space100 }, .md = .{ .gap = .space200 } },
        .block = .{ .true = .{ .width = .fill }, .false = .{} },
    },
    .compound = .{
        .{ .when = .{ .intent = .ghost, .size = .sm }, .style = .{ .padding = .{ .x = .space100 } } },
    },
    .defaults = .{ .size = .md },
});

test "cva: 默认值、合并顺序 base < variants < compound、bool 维度" {
    const d: Btn.Variants = .{};
    try testing.expect(d.intent == .primary); // No default given, take first option
    try testing.expect(d.size == .md);
    try testing.expect(d.block == true);

    const a = Btn.resolveBase(.{}, light);
    try testing.expectEqual(light.tokens.radius.md, a.corner_radius.?);
    try testing.expectEqual(light.tokens.space.space300, a.padding.?.left);
    try testing.expect(Color.eql(light.tokens.color.accent, a.background.?));
    try testing.expect(a.width.? == .grow);

    const g = Btn.resolve(.{ .intent = .ghost, .size = .sm, .block = false }, light);
    try testing.expectEqual(light.tokens.space.space100, g.base.padding.?.left); // compound overrides base
    try testing.expect(Color.eql(Color.TRANSPARENT, g.base.background.?));
    try testing.expect(Color.eql(light.tokens.color.bg_hover, g.hover.?.background.?));
    try testing.expect(g.base.width == null);
    try testing.expect(Btn.has_hover);
    try testing.expect(Btn.state_condition == null);

    // Only size matches, intent doesn't -> compound ineffective
    const p = Btn.resolveBase(.{ .intent = .primary, .size = .sm }, light);
    try testing.expectEqual(light.tokens.space.space300, p.padding.?.left);
}

test "cva: 维度值可来自同名选项的其它枚举" {
    const S2 = enum { sm, md };
    try testing.expect(Btn.toDim(Btn.Dim(.size), S2.sm) == .sm);
    try testing.expect(Btn.toDim(Btn.Dim(.size), .md) == .md);
    try testing.expect(Btn.toDim(Btn.Dim(.block), false) == false);
    _ = Size;
}

test "sva: shared dimensions resolve each slot independently, compound wins" {
    const R = sva(.{
        .slots = .{ .root, .label, .icon },
        .base = .{ .root = .{ .padding = .space100, ._hover = .{ .background = .bg_hover } }, .label = css(.{ .color = .fg_secondary }) },
        .variants = .{
            .size = .{ .sm = .{ .root = .{ .gap = .space100 } }, .lg = .{ .root = .{ .gap = .space300 }, .icon = .{ .width = 24 } } },
            .selected = .{ .false = .{}, .true = .{ .label = .{ .color = .accent, ._disabled = .{ .opacity = 0.5 } } } },
        },
        .defaults = .{ .size = .lg },
        .compound = .{.{ .when = .{ .size = .lg, .selected = true }, .style = .{ .root = .{ .gap = .space400 } } }},
    });
    const a = R.resolve(.{}, light);
    try testing.expectEqual(light.tokens.space.space300, a.root.base.gap.?);
    try testing.expectEqual(@as(f32, 24), a.icon.base.width.?.px);
    try testing.expect(a.icon.hover == null);
    try testing.expect(Color.eql(light.tokens.color.bg_hover, a.root.resolve(.{ .is_hovered = true }).background.?));
    const b = R.resolve(.{ .selected = true }, dark);
    try testing.expectEqual(dark.tokens.space.space400, b.root.base.gap.?);
    try testing.expect(Color.eql(dark.tokens.color.accent, b.label.base.text_color.?));
    try testing.expectEqual(@as(f32, 0.5), b.label.resolve(.{ .is_disabled = true }).opacity.?);
    const p = R.of(.{ .size = .sm });
    try testing.expect(@TypeOf(p.root).R.has_hover);
    try testing.expect(!@TypeOf(p.icon).R.has_hover);
    try testing.expectEqualStrings("_disabled", @TypeOf(p.label).R.state_condition.?);
    try testing.expectEqual(@as(R.Dim(.size), .sm), R.Slot(.root).toDim(R.Dim(.size), .sm));
}

test "sva: derived geometry runs before compound and unspecified slots stay empty" {
    const DerivedFn = struct {
        fn f(_: anytype, t: *const ThemeTokens) struct { root: BoxStyle } {
            return .{ .root = .{ .gap = t.tokens.space.space200 } };
        }
    };
    const R = sva(.{
        .slots = .{ .root, .label },
        .base = .{ .root = .{ .gap = .space100 } },
        .derived = DerivedFn.f,
        .compound = .{.{ .when = .{}, .style = .{ .root = .{ .gap = .space300 } } }},
    });
    try testing.expectEqual(light.tokens.space.space300, R.resolve(.{}, light).root.base.gap.?);
    try testing.expectEqual(ConditionalStyle{}, R.resolve(.{}, light).label);
}

test "object recipes: sparse lowering matches layered reference for every variant and theme" {
    const base = .{ .background = .bg_secondary, .gap = .space100, .border = .{ .width = .thin, .color = .border }, ._hover = .{ .opacity = 0.8, .background = .bg_hover } };
    const large = .{ .gap = .space400, .border_color = .accent, ._hover = .{ .background = .accent } };
    const marked = .{ .gap = @as(?f32, null), .opacity = 0.5, ._disabled = .{ .opacity = 0.2 } };
    const compound = .{ .gap = .space200, ._hover = .{ .opacity = 1.0 } };
    const R = cva(.{
        .base = base,
        .variants = .{ .large = .{ .false = .{}, .true = large }, .marked = .{ .false = .{}, .true = marked } },
        .compound = .{.{ .when = .{ .large = true, .marked = true }, .style = compound }},
    });
    for ([_]*const ThemeTokens{ light, dark }) |t| {
        for ([_]bool{ false, true }) |is_large| {
            for ([_]bool{ false, true }) |is_marked| {
                var expected = conditionalFrom(base, t);
                if (is_large) expected = expected.merge(conditionalFrom(large, t));
                if (is_marked) expected = expected.merge(conditionalFrom(marked, t));
                if (is_large and is_marked) expected = expected.merge(conditionalFrom(compound, t));
                try testing.expectEqualDeep(expected, R.resolve(.{ .large = is_large, .marked = is_marked }, t));
            }
        }
    }
}

test "sva: project mixed box and text slots without resolving incompatible siblings" {
    const R = sva(.{
        .slots = .{ .root, .label },
        .base = .{ .root = .{ .padding = .space200, ._hover = .{ .opacity = 0.8 } }, .label = .{ .max_lines = 2, .color = .fg_secondary } },
        .variants = .{ .large = .{ .false = .{}, .true = .{ .root = .{ .gap = .space400 }, .label = .{ .font_size = .xl, .strikethrough = true } } } },
        .compound = .{.{ .when = .{ .large = true }, .style = .{ .label = .{ .color = .accent } } }},
    });
    const box = R.Slot(.root).resolve(.{ .large = true }, dark);
    try testing.expectEqual(dark.tokens.space.space400, box.base.gap.?);
    try testing.expectEqual(@as(f32, 0.8), box.hover.?.opacity.?);
    const text = R.Slot(.label).resolveText(.{ .large = true }, .{}, dark);
    try testing.expectEqual(@as(u16, 2), text.max_lines);
    try testing.expectEqual(dark.tokens.font_size.xl, text.font_size);
    try testing.expect(text.strikethrough);
    try testing.expect(Color.eql(dark.tokens.color.accent, text.color));
}

test "css: explicit padding edges override axes independent of field order" {
    const a = boxFrom(.{ .padding = .{ .left = .space400, .top = .space300, .x = .space100, .y = .space200 } }, light);
    const b = boxFrom(.{ .padding = .{ .x = .space100, .y = .space200, .left = .space400, .top = .space300 } }, light);
    try testing.expectEqualDeep(a, b);
    try testing.expectEqual(light.tokens.space.space400, a.padding.?.left);
    try testing.expectEqual(light.tokens.space.space100, a.padding.?.right);
    try testing.expectEqual(light.tokens.space.space300, a.padding.?.top);
    try testing.expectEqual(light.tokens.space.space200, a.padding.?.bottom);
}

test "sva: derived runs once for a whole recipe and is skipped for unrelated text slots" {
    const Geometry = struct {
        var calls: usize = 0;
        fn compute(_: anytype, _: *const ThemeTokens) struct { root: BoxStyle } {
            calls += 1;
            return .{ .root = .{ .gap = 7 } };
        }
    };
    const R = sva(.{
        .slots = .{ .root, .label },
        .base = .{ .label = .{ .color = .fg_secondary } },
        .derived = Geometry.compute,
        .compound = .{.{ .when = .{}, .style = .{ .root = .{ .gap = 9 } } }},
    });
    Geometry.calls = 0;
    const label = R.Slot(.label).resolveText(.{}, .{}, light);
    try testing.expect(Color.eql(light.tokens.color.fg_secondary, label.color));
    try testing.expectEqual(@as(usize, 0), Geometry.calls);
    const whole = R.resolve(.{}, light);
    try testing.expectEqual(@as(usize, 1), Geometry.calls);
    try testing.expectEqual(@as(f32, 9), whole.root.base.gap.?);
    const projected = R.Slot(.root).resolve(.{}, light);
    try testing.expectEqual(@as(usize, 2), Geometry.calls);
    try testing.expectEqualDeep(whole.root, projected);
}

test "ui.mix: token 颜色混合在应用时求值，换主题跟随，可用于条件层" {
    const T = theme.refs;
    const S = @TypeOf(css(.{ .background = mix(T.color.bg_primary, T.color.accent, 0.25), ._hover = .{ .background = mix(Color.hex(0xff0000), Color.TRANSPARENT, 0.8) } }));
    try testing.expect(usesTokens(@TypeOf(S.spec)));
    try testing.expectEqual(Color.lerp(light.tokens.color.bg_primary, light.tokens.color.accent, 0.25), S.box(light).background.?);
    try testing.expectEqual(Color.lerp(dark.tokens.color.bg_primary, dark.tokens.color.accent, 0.25), S.box(dark).background.?);
    try testing.expectEqual(Color.lerp(Color.hex(0xff0000), Color.TRANSPARENT, 0.8), S.hoverBox(light).background.?);
    const nested = mix(mix(T.color.bg_primary, T.color.danger, 0.5), T.color.fg_primary, 0.1);
    try testing.expectEqual(Color.lerp(Color.lerp(light.tokens.color.bg_primary, light.tokens.color.danger, 0.5), light.tokens.color.fg_primary, 0.1), nested.resolve(light));
}

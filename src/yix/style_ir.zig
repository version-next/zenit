//! Runtime YSS data. Storage is owned by the caller's arena, never by a node.
const std = @import("std");
const schema = @import("style_schema_generated.zig");

pub const StyleIR = struct {
    declarations: []const Declaration = &.{},
    dependency_fingerprint: u64 = 0,
};
pub const Kind = enum { style, recipe, param_style, slot_recipe };
pub const Declaration = struct {
    name: []const u8,
    kind: Kind,
    base: Layer = .{},
    dimensions: []const Dimension = &.{},
    compounds: []const Compound = &.{},
    slots: []const []const u8 = &.{},
    /// Frozen source of unsupported parameter/slot declarations.
    signature: []const u8 = "",
    offset: usize = 0,
};
pub const Layer = struct {
    properties: []const Property = &.{},
    /// State conditions use the generated `_hover` spelling; slot names are unchanged.
    conditions: []const Condition = &.{},
};
pub const Property = struct { name: []const u8, value: Value, offset: usize = 0 };
pub const Condition = struct { name: []const u8, layer: *const Layer };
pub const Dimension = struct { name: []const u8, flag: bool, default: []const u8, options: []const Option };
pub const Option = struct { name: []const u8, layer: Layer };
pub const Predicate = struct { dimension: []const u8, option: []const u8 };
pub const Compound = struct { when: []const Predicate, layer: Layer };
pub const Value = union(enum) {
    number: f64,
    name: []const u8,
    hex: []const u8,
    call: struct { name: []const u8, args: []const Value },
    list: []const Value,
    /// A compiled thunk's identity. Runtime must bind to the compiled thunk, never interpret Zig.
    frozen: []const u8,
};

/// Stable machine-readable fallback reasons; the first incompatibility wins.
pub const Reason = enum { kind, names, variant, default, slot, param, conditions, needs_ext, transition, box_text, icon, compound, dependency, thunk };

pub fn compatibility(old: StyleIR, new: StyleIR) ?Reason {
    if (old.dependency_fingerprint != new.dependency_fingerprint) return .dependency;
    // New unused names are safe; deletion/renaming any compiled API is not.
    for (old.declarations) |before| {
        const after = findDeclaration(new, before.name) orelse return .names;
        if (before.kind != after.kind) return .kind;
        if (before.slots.len != after.slots.len) return .slot;
        for (before.slots, after.slots) |a, b| if (!eq(a, b)) return .slot;
        if (before.kind == .param_style and !eq(before.signature, after.signature)) return .param;
        if (before.kind == .slot_recipe and !eq(before.signature, after.signature)) return .slot;
        if (before.dimensions.len != after.dimensions.len) return .variant;
        for (before.dimensions, after.dimensions) |a, b| {
            if (!eq(a.name, b.name) or a.flag != b.flag or a.options.len != b.options.len) return .variant;
            if (!eq(a.default, b.default)) return .default;
            for (a.options, b.options) |ao, bo| {
                if (!eq(ao.name, bo.name)) return .variant;
                if (layerCompatibility(ao.layer, bo.layer)) |reason| return reason;
            }
        }
        if (before.compounds.len != after.compounds.len) return .compound;
        for (before.compounds, after.compounds) |a, b| {
            if (a.when.len != b.when.len) return .compound;
            for (a.when, b.when) |ap, bp| if (!eq(ap.dimension, bp.dimension) or !eq(ap.option, bp.option)) return .compound;
            if (layerCompatibility(a.layer, b.layer)) |reason| return reason;
        }
        if (layerCompatibility(before.base, after.base)) |reason| return reason;
    }
    return null;
}

pub fn findDeclaration(doc: StyleIR, name: []const u8) ?*const Declaration {
    for (doc.declarations) |*d| if (eq(d.name, name)) return d;
    return null;
}
pub fn findProperty(layer: Layer, name: []const u8) ?*const Property {
    for (layer.properties) |*p| if (eq(p.name, name)) return p;
    return null;
}
pub fn layerCompatibility(a: Layer, b: Layer) ?Reason {
    if (a.conditions.len != b.conditions.len) return .conditions;
    for (a.conditions, b.conditions) |ac, bc| {
        if (!eq(ac.name, bc.name)) return .conditions;
        if (layerCompatibility(ac.layer.*, bc.layer.*)) |reason| return reason;
    }
    if (needsExt(a) != needsExt(b)) return .needs_ext;
    if (hasBox(a) != hasBox(b) or hasText(a) != hasText(b) or hasTextOnly(a) != hasTextOnly(b)) return .box_text;
    if ((findProperty(a, "icon_color") != null) != (findProperty(b, "icon_color") != null)) return .icon;
    const at = findProperty(a, "transition");
    const bt = findProperty(b, "transition");
    if ((at != null) != (bt != null)) return .transition;
    if (at != null and !valueEqual(at.?.value, bt.?.value)) return .transition;
    for (a.properties) |p| {
        if (!hasFrozen(p.value)) continue;
        const other = findProperty(b, p.name) orelse return .thunk;
        if (!valueEqual(p.value, other.value)) return .thunk;
    }
    for (b.properties) |p| {
        if (!hasFrozen(p.value)) continue;
        const other = findProperty(a, p.name) orelse return .thunk;
        if (!valueEqual(p.value, other.value)) return .thunk;
    }
    return null;
}

pub fn hasFrozen(v: Value) bool {
    return switch (v) {
        .frozen => true,
        .call => |c| blk: {
            for (c.args) |x| if (hasFrozen(x)) break :blk true;
            break :blk false;
        },
        .list => |xs| blk: {
            for (xs) |x| if (hasFrozen(x)) break :blk true;
            break :blk false;
        },
        else => false,
    };
}
pub fn valueEqual(a: Value, b: Value) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .number => |n| n == b.number,
        .name => |s| eq(s, b.name),
        .hex => |s| eq(s, b.hex),
        .frozen => |s| eq(s, b.frozen),
        .call => |c| eq(c.name, b.call.name) and valuesEqual(c.args, b.call.args),
        .list => |xs| valuesEqual(xs, b.list),
    };
}
fn valuesEqual(a: []const Value, b: []const Value) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!valueEqual(x, y)) return false;
    return true;
}
fn hasBox(layer: Layer) bool {
    for (layer.properties) |p| if (schema.prop(p.name)) |prop| {
        if (prop.box and !prop.text) return true;
    };
    return false;
}
fn hasTextOnly(layer: Layer) bool {
    for (layer.properties) |p| if (schema.prop(p.name)) |prop| {
        if (prop.text and !prop.box) return true;
    };
    return false;
}
fn hasText(layer: Layer) bool {
    for (layer.properties) |p| if (schema.prop(p.name)) |prop| {
        if (prop.text) return true;
    };
    return false;
}
/// Mirrors BoxStyle.needsExt; property schema is compiler-owned to avoid importing UI into YSS.
/// A schema-difference gate must keep this capability list aligned with the UI field reflection.
pub fn needsExt(layer: Layer) bool {
    const fields = [_][]const u8{
        "typography",                      "margin_spec",           "border_top_color",    "border_right_color", "border_bottom_color", "border_left_color",
        "corner_radius",                   "shadow",                "shadows",             "scale_x",            "scale_y",             "rotate",
        "transform_origin",                "flex_wrap",             "blend_mode",          "z_index",            "inset",               "gradient",
        "clip_shape",                      "glass",                 "multi_gradient",      "composited_group",   "content_warp",        "grid_placement",
        "corner_radii",                    "inset_shadows",         "text_color",          "color",              "font_size",           "font_weight",
        "outline",                         "flex_basis",            "align_self",          "no_cross_stretch",   "sticky_insets",       "tab_index",
        "aspect_ratio",                    "min_width",             "max_width",           "min_height",         "max_height",          "hit_shape",
        "shape",                           "hit_behavior",          "hit_roles",           "noise",              "inset_shadow",        "overflow_fade",
        "keep_rendering_when_transparent", "will_change_transform", "will_change_opacity",
    };
    for (layer.properties) |p| for (fields) |field| {
        if (eq(p.name, field)) return true;
    };
    for (layer.conditions) |condition| if (needsExt(condition.layer.*)) return true;
    return false;
}
fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

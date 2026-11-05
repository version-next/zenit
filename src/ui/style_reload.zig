//! Preview-only immutable style generations. Readers never allocate; preparation owns all
//! parsing/validation and a failed preparation cannot change a registered declaration.
const std = @import("std");
const compiler = @import("zenit_environment").preview.compiler;
pub const ir = compiler.ir;
const core = @import("core.zig");
const theme = @import("theme.zig");
const css = @import("css.zig");
const sv = @import("zenit_style_values");
const A = std.mem.Allocator;
pub const File = struct { path: []const u8, source: []const u8 };
pub var generation: u64 = 0;
pub var observer: ?*const fn () void = null;
pub fn observeGeneration() void {
    if (observer) |f| f();
}

const Entry = struct {
    path: []const u8,
    name: []const u8,
    source: []const u8,
    active: ?*const ir.Declaration = null,
    next: ?*Entry = null,
    registered: bool = false,
};
var entries: ?*Entry = null;
var generations: ?*Preparation = null;

/// A static intrusive descriptor makes the initial compiled fallback allocation-free.
pub fn lookup(comptime path: []const u8, comptime name: []const u8, comptime source: []const u8) ?*const ir.Declaration {
    const Holder = struct {
        var entry: Entry = .{ .path = path, .name = name, .source = source };
    };
    const e = &Holder.entry;
    if (!e.registered) {
        e.next = entries;
        entries = e;
        e.registered = true;
        // A previously unmounted style can first appear after a successful generation.
        var g = generations;
        while (g) |p| : (g = p.next) {
            for (p.documents) |doc| if (std.mem.eql(u8, doc.path, path)) {
                const d = ir.findDeclaration(doc.ir_value, name);
                if (d != null and declarationSupported(d.?)) e.active = d;
                return e.active;
            };
        }
    }
    return e.active;
}
const Update = struct { entry: *Entry, declaration: *const ir.Declaration };
const Document = struct { path: []const u8, ir_value: ir.StyleIR };
pub const Diagnostic = struct { file: []const u8, line: usize, message: []const u8 };
pub const Fallback = struct { file: []const u8, reason: []const u8 };
pub const Preparation = struct {
    allocator: A,
    arena: std.heap.ArenaAllocator,
    result: union(enum) { ready, fallback: Fallback, diagnostic: Diagnostic } = .ready,
    updates: []const Update = &.{},
    documents: []const Document = &.{},
    next: ?*Preparation = null,
    committed: bool = false,

    pub fn commit(self: *Preparation) u64 {
        std.debug.assert(self.result == .ready and !self.committed);
        for (self.updates) |u| u.entry.active = u.declaration;
        generation += 1;
        self.committed = true;
        self.next = generations;
        generations = self;
        return generation;
    }
    pub fn deinit(self: *Preparation) void {
        std.debug.assert(!self.committed);
        const a = self.allocator;
        self.arena.deinit();
        a.destroy(self);
    }
};

pub fn deinit() void {
    var e = entries;
    while (e) |p| {
        e = p.next;
        p.active = null;
        p.next = null;
        p.registered = false;
    }
    entries = null;
    while (generations) |p| {
        generations = p.next;
        p.committed = false;
        p.deinit();
    }
    generation = 0;
    observer = null;
}

/// Reclaim superseded immutable batches at a UI quiescent point. The caller must
/// have exited every style resolver and generation notification callback before
/// entering this function. No declaration pointer returned by lookup may cross
/// that boundary. The current head stays alive for its publishing stack's defers.
/// A file's latest document is retained even when none of its styles is mounted,
/// so a later first mount observes the latest saved values.
pub fn collect() void {
    const newest = generations orelse return;
    var link = &newest.next;
    while (link.*) |candidate| {
        var superseded = true;
        for (candidate.documents) |document| {
            var newer = generations;
            var covered = false;
            while (newer) |version| : (newer = version.next) {
                if (version == candidate) break;
                for (version.documents) |replacement| {
                    if (std.mem.eql(u8, document.path, replacement.path)) {
                        covered = true;
                        break;
                    }
                }
                if (covered) break;
            }
            if (!covered) {
                superseded = false;
                break;
            }
        }
        // This check also makes an accidentally stale descriptor conservative:
        // retain its storage instead of turning an invariant breach into a UAF.
        if (superseded) {
            var entry = entries;
            while (entry) |e| : (entry = e.next) {
                const active = e.active orelse continue;
                for (candidate.documents) |document| {
                    for (document.ir_value.declarations) |*declaration| {
                        if (active == declaration) {
                            superseded = false;
                            break;
                        }
                    }
                    if (!superseded) break;
                }
                if (!superseded) break;
            }
        }
        if (superseded) {
            link.* = candidate.next;
            candidate.committed = false;
            candidate.deinit();
        } else link = &candidate.next;
    }
}

pub fn retainedGenerationCount() usize {
    var count: usize = 0;
    var current = generations;
    while (current) |p| : (current = p.next) count += 1;
    return count;
}

pub fn prepare(allocator: A, files: []const File) !*Preparation {
    const p = try allocator.create(Preparation);
    p.* = .{ .allocator = allocator, .arena = std.heap.ArenaAllocator.init(allocator) };
    errdefer p.deinit();
    const a = p.arena.allocator();
    var updates: std.ArrayList(Update) = .empty;
    var documents: std.ArrayList(Document) = .empty;
    for (files, 0..) |file, fi| {
        const path = try a.dupe(u8, file.path);
        for (files[0..fi]) |previous| if (std.mem.eql(u8, previous.path, path)) {
            p.result = .{ .fallback = .{ .file = path, .reason = "duplicate_file" } };
            return p;
        };
        var baseline: ?[]const u8 = null;
        var e = entries;
        while (e) |entry| : (e = entry.next) if (std.mem.eql(u8, entry.path, path)) {
            baseline = entry.source;
            break;
        };
        const old_source = baseline orelse {
            p.result = .{ .fallback = .{ .file = path, .reason = "unregistered_file" } };
            return p;
        };
        const source = try a.dupe(u8, file.source);
        const parsed = try compiler.compileIR(a, source);
        const next_ir = switch (parsed) {
            .diagnostic => |d| {
                p.result = .{ .diagnostic = .{ .file = path, .line = lineAt(source, d.offset), .message = d.message } };
                return p;
            },
            .ir => |v| v,
        };
        const old_result = try compiler.compileIR(a, old_source);
        const old_ir = switch (old_result) {
            .ir => |v| v,
            .diagnostic => unreachable,
        };
        if (ir.compatibility(old_ir, next_ir)) |reason| {
            p.result = .{ .fallback = .{ .file = path, .reason = @tagName(reason) } };
            return p;
        }
        for (next_ir.declarations) |d| {
            if (d.kind == .param_style or d.kind == .slot_recipe) {
                // These compiled APIs retain their complete behavior until the next L3 build.
                // Never claim a successful L1 edit to an unsupported declaration.
                const old = ir.findDeclaration(old_ir, d.name);
                if (old == null or !std.mem.eql(u8, old.?.signature, d.signature)) {
                    p.result = .{ .fallback = .{ .file = path, .reason = if (d.kind == .param_style) "param" else "slot" } };
                    return p;
                }
                continue;
            }
            validateDeclaration(&d) catch |err| {
                if (err == error.UnsupportedValue) {
                    if (ir.findDeclaration(old_ir, d.name)) |old| {
                        // An unchanged compiled thunk (or unsupported declaration) keeps its
                        // original compiled implementation; siblings can still reload.
                        if (declarationValuesEqual(old, &d)) continue;
                    }
                    p.result = .{ .fallback = .{ .file = path, .reason = "unsupported_value" } };
                } else p.result = .{ .diagnostic = .{ .file = path, .line = lineAt(source, d.offset), .message = "invalid runtime style value or token" } };
                return p;
            };
        }
        try documents.append(a, .{ .path = path, .ir_value = next_ir });
        e = entries;
        while (e) |entry| : (e = entry.next) if (std.mem.eql(u8, entry.path, path)) {
            const d = ir.findDeclaration(next_ir, entry.name) orelse unreachable;
            if (!declarationSupported(d)) continue;
            try updates.append(a, .{ .entry = entry, .declaration = d });
        };
    }
    p.updates = try updates.toOwnedSlice(a);
    p.documents = try documents.toOwnedSlice(a);
    return p;
}
fn lineAt(source: []const u8, offset: usize) usize {
    var line: usize = 1;
    for (source[0..@min(offset, source.len)]) |c| if (c == '\n') {
        line += 1;
    };
    return line;
}

const E = error{ UnsupportedValue, InvalidValue };
/// Token names permit either exact spelling or the YSS '-' -> '_' spelling.
pub fn nameEqual(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if ((if (x == '-') @as(u8, '_') else x) != (if (y == '-') @as(u8, '_') else y)) return false;
    return true;
}
pub fn conditionEqual(a: []const u8, b: []const u8) bool {
    return nameEqual(if (a.len > 0 and a[0] == '_') a[1..] else a, if (b.len > 0 and b[0] == '_') b[1..] else b);
}

/// Runtime counterpart of css.tokenError + resolveTokenName. Exact names win;
/// only the query's hyphens may normalize to underscores. A hyphenated query
/// with both exact and normalized declarations is ambiguous, as at comptime.
pub fn tokenName(comptime Enum: type, name: []const u8) E!Enum {
    var exact: ?Enum = null;
    var normalized: ?Enum = null;
    const has_hyphen = std.mem.indexOfScalar(u8, name, '-') != null;
    inline for (@import("zenit_reflection").fields(Enum)) |field| {
        if (std.mem.eql(u8, name, field.name)) exact = @field(Enum, field.name);
        if (name.len == field.name.len) {
            var matches = true;
            for (name, field.name) |query, declared| {
                if ((if (query == '-') @as(u8, '_') else query) != declared) {
                    matches = false;
                    break;
                }
            }
            if (matches) normalized = @field(Enum, field.name);
        }
    }
    if (has_hyphen and exact != null and normalized != null) return error.InvalidValue;
    if (exact) |value| return value;
    return normalized orelse error.InvalidValue;
}

fn token(comptime T: type, comptime cat: css.Category, name: []const u8, t: *const theme.ThemeTokens) E!T {
    if (comptime cat == .none) return error.InvalidValue;
    const c = comptime @field(sv.Category, @tagName(cat));
    const reference = try tokenName(theme.Token(c), name);
    const value = theme.resolve(c, reference, t);
    if (comptime T == core.Padding and @TypeOf(value) == f32) return core.Padding.all(value);
    if (comptime T == core.Sizing and @TypeOf(value) == f32) return .{ .px = value };
    if (comptime T == @TypeOf(value)) return value;
    return error.InvalidValue;
}

fn convert(comptime T: type, comptime cat: css.Category, value: ir.Value, t: *const theme.ThemeTokens) E!T {
    if (comptime @typeInfo(T) == .optional) return try convert(@typeInfo(T).optional.child, cat, value, t);
    if (value == .frozen) return error.UnsupportedValue;
    if (comptime T == core.Color) return color(value, t);
    if (comptime T == core.Padding) {
        if (value == .list) {
            const v = value.list;
            if (v.len != 2 and v.len != 4) return error.InvalidValue;
            const top = try convert(f32, .space, v[0], t);
            const right = try convert(f32, .space, v[1], t);
            return .{ .top = top, .right = right, .bottom = if (v.len == 4) try convert(f32, .space, v[2], t) else top, .left = if (v.len == 4) try convert(f32, .space, v[3], t) else right };
        }
        return core.Padding.all(try convert(f32, .space, value, t));
    }
    if (comptime T == core.Sizing) {
        if (value == .number) return .{ .px = try convert(f32, .none, value, t) };
        if (value == .name) {
            if (nameEqual(value.name, "grow") or nameEqual(value.name, "fill")) return .{ .grow = .{} };
            if (nameEqual(value.name, "fit")) return .{ .fit = .{} };
            return token(T, .size, value.name, t);
        }
        return error.UnsupportedValue;
    }
    if (comptime T == core.Shadow) {
        if (value == .name) return token(T, .shadow, value.name, t);
        if (value != .list or (value.list.len != 4 and value.list.len != 5)) return error.UnsupportedValue;
        const v = value.list;
        return .{ .offset_x = try convert(f32, .none, v[0], t), .offset_y = try convert(f32, .none, v[1], t), .blur = try convert(f32, .none, v[2], t), .spread = if (v.len == 5) try convert(f32, .none, v[3], t) else 0, .color = try color(v[v.len - 1], t) };
    }
    if (comptime T == core.ShadowList) {
        if (value != .call or !nameEqual(value.call.name, "shadow_stack") or value.call.args.len > @typeInfo(@FieldType(core.ShadowList, "items")).array.len) return error.UnsupportedValue;
        var out: T = .{};
        for (value.call.args, 0..) |v, i| out.items[i] = try convert(core.Shadow, .shadow, v, t);
        out.len = @intCast(value.call.args.len);
        return out;
    }
    if (comptime T == sv.TypographyPatch) {
        if (value == .name) return token(T, .typography, value.name, t);
        return error.UnsupportedValue;
    }
    switch (@typeInfo(T)) {
        .float => {
            if (value == .number) {
                const n: T = @floatCast(value.number);
                if (!std.math.isFinite(n)) return error.InvalidValue;
                return n;
            }
            if (value == .name) return token(T, cat, value.name, t);
        },
        .int => {
            if (value == .number) {
                const n = value.number;
                if (!std.math.isFinite(n) or @floor(n) != n or n < std.math.minInt(T) or n > std.math.maxInt(T)) return error.InvalidValue;
                return @intFromFloat(n);
            }
            if (value == .name) return token(T, cat, value.name, t);
        },
        .bool => if (value == .name) {
            if (nameEqual(value.name, "true")) return true;
            if (nameEqual(value.name, "false")) return false;
        },
        .@"enum" => if (value == .name) {
            inline for (@import("zenit_reflection").fields(T)) |f| if (nameEqual(f.name, value.name)) return @field(T, f.name);
            return error.InvalidValue;
        },
        else => {},
    }
    return error.UnsupportedValue;
}
fn color(value: ir.Value, t: *const theme.ThemeTokens) E!core.Color {
    switch (value) {
        .name => |name| {
            if (nameEqual(name, "transparent")) return core.Color.TRANSPARENT;
            return token(core.Color, .color, name, t);
        },
        .hex => |h| {
            if (h.len != 6 and h.len != 8) return error.InvalidValue;
            const n = std.fmt.parseInt(u32, h, 16) catch return error.InvalidValue;
            return if (h.len == 6) core.Color.hex(@truncate(n)) else core.Color.rgba(@truncate(n >> 24), @truncate(n >> 16), @truncate(n >> 8), @truncate(n));
        },
        .call => |c| {
            if (nameEqual(c.name, "mix") and c.args.len == 3) return core.Color.lerp(try color(c.args[0], t), try color(c.args[1], t), try convert(f32, .none, c.args[2], t));
            if ((nameEqual(c.name, "rgb") and c.args.len == 3) or (nameEqual(c.name, "rgba") and c.args.len == 4)) {
                var ch: [4]u8 = .{ 0, 0, 0, 255 };
                for (c.args[0..3], 0..) |v, i| ch[i] = try convert(u8, .none, v, t);
                if (c.args.len == 4) {
                    const alpha = if (c.args[3] == .number) c.args[3].number else return error.InvalidValue;
                    if (alpha < 0 or alpha > 1) return error.InvalidValue;
                    ch[3] = @intFromFloat(alpha * 255 + 0.5);
                }
                return core.Color.rgba(ch[0], ch[1], ch[2], ch[3]);
            }
        },
        else => {},
    }
    return error.UnsupportedValue;
}

pub fn evaluateBox(layer: ir.Layer, t: *const theme.ThemeTokens, box_projection: bool) E!core.BoxStyle {
    @setEvalBranchQuota(200_000);
    var out: core.BoxStyle = .{};
    for (layer.properties) |p| {
        if (nameEqual(p.name, "transition")) continue;
        if (nameEqual(p.name, "border")) {
            const vs = if (p.value == .list) p.value.list else &[_]ir.Value{p.value};
            if (vs.len < 1 or vs.len > 2) return error.InvalidValue;
            out.border_width = try convert(f32, .border_width, vs[0], t);
            if (vs.len == 2) out.border_color = try color(vs[1], t);
            continue;
        }
        var handled = false;
        inline for (@import("zenit_reflection").fields(core.BoxStyle)) |f| {
            const match = if (comptime std.mem.eql(u8, f.name, "text_color")) nameEqual(p.name, "color") or nameEqual(p.name, f.name) else nameEqual(p.name, f.name);
            if (match) {
                handled = true;
                const text_name = comptime if (std.mem.eql(u8, f.name, "text_color")) "color" else f.name;
                if (!box_projection or !@hasField(core.TextStyle, text_name)) {
                    if (comptime std.mem.eql(u8, f.name, "shadow")) {
                        if (p.value == .call and nameEqual(p.value.call.name, "shadow_stack")) {
                            out.shadows = try convert(core.ShadowList, .shadow, p.value, t);
                        } else {
                            @field(out, f.name) = try convert(f.type, comptime css.catOf(f.name), p.value, t);
                        }
                    } else if (comptime std.mem.eql(u8, f.name, "flex_basis")) {
                        // flex_basis remains f32 in the public API, but its YSS
                        // keyword vocabulary is field-specific, not a token.
                        if (p.value == .name) {
                            var found = false;
                            inline for (core.FlexBasis.keywords) |name| {
                                if (nameEqual(p.value.name, name)) {
                                    out.flex_basis = @field(core.FlexBasis, name);
                                    found = true;
                                }
                            }
                            if (!found) return error.InvalidValue;
                        } else {
                            const basis = try convert(f32, .none, p.value, t);
                            if (basis < 0) return error.InvalidValue;
                            out.flex_basis = basis;
                        }
                    } else {
                        @field(out, f.name) = try convert(f.type, comptime css.catOf(f.name), p.value, t);
                    }
                }
            }
        }
        // Text-only properties are projected onto TextPlan and do not affect its box.
        inline for (@import("zenit_reflection").fields(core.TextStyle)) |f| if (nameEqual(p.name, f.name)) {
            handled = true;
        };
        if (nameEqual(p.name, "typography")) {
            const patch = try convert(sv.TypographyPatch, .typography, p.value, t);
            if (!box_projection) {
                out.font_size = patch.font_size;
                out.font_weight = patch.font_weight;
            }
            handled = true;
        }
        if (!handled) return error.UnsupportedValue;
    }
    return out;
}
pub fn evaluateConditional(layer: ir.Layer, t: *const theme.ThemeTokens, box_projection: bool) E!core.ConditionalStyle {
    var out: core.ConditionalStyle = .{ .base = try evaluateBox(layer, t, box_projection) };
    for (layer.conditions) |c| {
        var handled = false;
        inline for (@import("zenit_reflection").fields(core.ConditionalStyle)) |f| {
            if (comptime std.mem.eql(u8, f.name, "base")) continue;
            if (conditionEqual(c.name, f.name)) {
                @field(out, f.name) = try evaluateBox(c.layer.*, t, box_projection);
                handled = true;
            }
        }
        if (!handled) return error.UnsupportedValue;
    }
    return out;
}
pub fn evaluateCondition(layer: ir.Layer, name: []const u8, t: *const theme.ThemeTokens, box_projection: bool) core.BoxStyle {
    for (layer.conditions) |c| if (conditionEqual(c.name, name)) return evaluateBox(c.layer.*, t, box_projection) catch unreachable;
    return .{};
}
pub fn evaluateText(layer: ir.Layer, base: core.TextStyle, t: *const theme.ThemeTokens) E!core.TextStyle {
    @setEvalBranchQuota(200_000);
    var out = base;
    // Typography always precedes individual text declarations, independent of source ordering.
    for (layer.properties) |p| if (nameEqual(p.name, "typography")) {
        const patch = try convert(sv.TypographyPatch, .typography, p.value, t);
        inline for (@import("zenit_reflection").fields(sv.TypographyPatch)) |f| if (@field(patch, f.name)) |v| {
            @field(out, f.name) = v;
            if (comptime @hasField(core.TextStyle, f.name ++ "_set")) @field(out, f.name ++ "_set") = true;
        };
    };
    for (layer.properties) |p| {
        inline for (@import("zenit_reflection").fields(core.TextStyle)) |f| {
            const match = if (comptime std.mem.eql(u8, f.name, "color")) nameEqual(p.name, "text_color") or nameEqual(p.name, "color") else nameEqual(p.name, f.name);
            if (match) {
                @field(out, f.name) = try convert(f.type, comptime css.catOf(f.name), p.value, t);
                if (comptime @hasField(core.TextStyle, f.name ++ "_set")) @field(out, f.name ++ "_set") = true;
            }
        }
    }
    return out;
}
fn validateLayer(layer: ir.Layer, t: *const theme.ThemeTokens) E!void {
    if (ir.findProperty(layer, "color") != null and ir.findProperty(layer, "text_color") != null)
        return error.InvalidValue;
    _ = try evaluateConditional(layer, t, false);
    _ = try evaluateText(layer, .{}, t);
    for (layer.conditions) |c| try validateLayer(c.layer.*, t);
}
fn validateDeclaration(d: *const ir.Declaration) E!void {
    for ([_]*const theme.ThemeTokens{ &theme.light, &theme.dark }) |t| {
        try validateLayer(d.base, t);
        for (d.dimensions) |dim| for (dim.options) |option| {
            try validateLayer(option.layer, t);
        };
        for (d.compounds) |compound| try validateLayer(compound.layer, t);
    }
}
fn optionMatches(variants: anytype, dim: []const u8, option0: []const u8) bool {
    var option = option0;
    if (std.mem.startsWith(u8, option, ".@\"") and std.mem.endsWith(u8, option, "\"")) option = option[3 .. option.len - 1] else if (std.mem.startsWith(u8, option, ".")) option = option[1..];
    inline for (@import("zenit_reflection").fields(@TypeOf(variants))) |f| {
        if (nameEqual(f.name, dim)) {
            const v = @field(variants, f.name);
            return if (comptime f.type == bool) nameEqual(option, if (v) "true" else "false") else nameEqual(option, @tagName(v));
        }
    }
    return false;
}
fn compoundMatches(variants: anytype, predicates: []const ir.Predicate) bool {
    for (predicates) |p| if (!optionMatches(variants, p.dimension, p.option)) return false;
    return true;
}
pub fn evaluateRecipe(d: *const ir.Declaration, variants: anytype, t: *const theme.ThemeTokens) E!core.ConditionalStyle {
    var out = try evaluateConditional(d.base, t, false);
    for (d.dimensions) |dim| for (dim.options) |option| if (optionMatches(variants, dim.name, option.name)) {
        out = out.merge(try evaluateConditional(option.layer, t, false));
    };
    for (d.compounds) |compound| if (compoundMatches(variants, compound.when)) {
        out = out.merge(try evaluateConditional(compound.layer, t, false));
    };
    return out;
}
pub fn evaluateRecipeText(d: *const ir.Declaration, variants: anytype, base: core.TextStyle, t: *const theme.ThemeTokens) E!core.TextStyle {
    var out = try evaluateText(d.base, base, t);
    for (d.dimensions) |dim| for (dim.options) |option| if (optionMatches(variants, dim.name, option.name)) {
        out = try evaluateText(option.layer, out, t);
    };
    for (d.compounds) |compound| if (compoundMatches(variants, compound.when)) {
        out = try evaluateText(compound.layer, out, t);
    };
    return out;
}

fn declarationSupported(d: *const ir.Declaration) bool {
    if (d.kind != .style and d.kind != .recipe) return false;
    validateDeclaration(d) catch return false;
    return true;
}
fn layerValuesEqual(a: ir.Layer, b: ir.Layer) bool {
    if (a.properties.len != b.properties.len or a.conditions.len != b.conditions.len) return false;
    for (a.properties, b.properties) |x, y| if (!std.mem.eql(u8, x.name, y.name) or !ir.valueEqual(x.value, y.value)) return false;
    for (a.conditions, b.conditions) |x, y| if (!std.mem.eql(u8, x.name, y.name) or !layerValuesEqual(x.layer.*, y.layer.*)) return false;
    return true;
}
fn declarationValuesEqual(a: *const ir.Declaration, b: *const ir.Declaration) bool {
    if (!layerValuesEqual(a.base, b.base) or a.dimensions.len != b.dimensions.len or a.compounds.len != b.compounds.len) return false;
    for (a.dimensions, b.dimensions) |x, y| {
        if (x.options.len != y.options.len) return false;
        for (x.options, y.options) |xo, yo| if (!layerValuesEqual(xo.layer, yo.layer)) return false;
    }
    for (a.compounds, b.compounds) |x, y| if (!layerValuesEqual(x.layer, y.layer)) return false;
    return true;
}

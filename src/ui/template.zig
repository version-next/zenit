//! A static template schema and its one-source stack builder. Runtime templates
//! contain data and bounded factory indices; all factories are compiled against
//! concrete Zig receivers and capture types. No expression evaluator lives here.
const std = @import("std");
const v = @import("view.zig");
const core = @import("core.zig");
const Scope = core.Scope;
const Cx = core.Cx;
const Node = core.Node;
const reflection = @import("zenit_reflection");

pub const preview_enabled = @import("zenit_environment").dev_preview;
pub const MeasurementAllocator = core.CountingAllocator;
pub const Mode = @import("reactive/owner.zig").SignalOwner.TestTemplateMode;
pub const Literal = union(enum) {
    boolean: bool,
    number: f64,
    text: []const u8,
    enum_name: []const u8,

    fn eql(a: Literal, b: Literal) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .boolean => |x| x == b.boolean,
            .number => |x| x == b.number,
            .text => |x| std.mem.eql(u8, x, b.text),
            .enum_name => |x| std.mem.eql(u8, x, b.enum_name),
        };
    }
};
pub const Attribute = struct {
    name: []const u8,
    tokens: []const u8,
    kind: enum { property, event, reference, style },
    literal: ?Literal = null,
};
pub const Metadata = struct {
    module: []const u8 = "manual",
    source: ?[]const u8 = null,
    catalog: type = void,
    attributes: []const Attribute = &.{},
    path: []const u8,
    receiver: []const u8,
    tokens: []const u8,
    literal_text: ?[]const u8 = null,
};
pub const Capture = struct { id: u64, name: []const u8, type_name: []const u8 };
pub const Receiver = struct { name: []const u8, expected_type: []const u8, ownership: enum { view } = .view, evaluation: enum { once_per_view } = .once_per_view };
pub const Hole = struct {
    module: []const u8,
    edges: []const Receiver = &.{},
    site: u64,
    path: []const u8,
    captures: []const Capture,
    type_name: []const u8,
    receiver: Receiver,
    token_fingerprint: u64,
    tokens: []const u8,
    occurrence: u32 = 0,
};
pub const max_depth = 128;
pub const Kind = enum { open, emit, close, literal_open, literal_emit };
pub const LiteralContainer = struct {
    layout: enum { box, row, col } = .box,
    style: core.BoxStyle = .{},
    test_id: ?[]const u8 = null,
    visible: bool = true,
    focusable: bool = false,
    hit_test: bool = true,
    style_slot: ?u32 = null,
};
/// Borrowed descriptor: literal_text, container.test_id, attributes and fragments
/// may point into the preparation arena. Readers must finish before that arena
/// retires; never retain these slices in nodes, devtools or a11y projections.
/// Builder.step owns runtime test IDs in the view scope; text emission copies
/// literal_text into node storage. Future consumers must copy before retaining.
pub const Instruction = struct {
    kind: Kind,
    binding: u32 = 0,
    abi: u64 = 0,
    element: []const u8 = "opaque",
    attributes: []const Attribute = &.{},
    literal_text: ?[]const u8 = null,
    container: LiteralContainer = .{},
    catalog_style: ?u32 = null,
    inline_style: ?core.BoxStyle = null,
    fragments: []const []const u8 = &.{},
    relocate: bool = false,
};
const EmitFn = *const fn (*const anyopaque, *Scope, *Cx, v.Sink, Instruction) anyerror!?*Node;
const Factory = struct { emit: EmitFn, kind: Kind, hole: Hole, style_allowed: *const fn (u32) bool, fragment_count: usize = 0 };
const StyleFactory = struct {
    tokens: []const u8,
    emit: *const fn (*Scope, *Cx, v.Sink, LiteralContainer) anyerror!*Node,
};
const Entry = struct { op: Instruction, factory: ?Factory = null, style_factory: ?StyleFactory = null, preview_isolated: bool = false };

// Catalogs contain compiled style types, never evaluated source expressions.
const CatalogStyle = struct { tokens: []const u8, Style: type };
pub fn styleCatalog(comptime roots: anytype) type {
    return struct {
        pub const styles = blk: {
            @setEvalBranchQuota(100000);
            var out: []const CatalogStyle = &.{};
            for (reflection.fields(@TypeOf(roots))) |field| {
                const value = @field(roots, field.name);
                if (@TypeOf(value) == type) out = out ++ collectStyles(std.mem.trim(u8, field.name, " "), value, &.{}) else if (has(@TypeOf(value), "zenit_style_part")) out = out ++ collectStyles(std.mem.trim(u8, field.name, " "), @TypeOf(value), &.{});
            }
            break :blk out;
        };
    };
}
fn collectStyles(comptime prefix: []const u8, comptime T: type, comptime ancestors: []const type) []const CatalogStyle {
    if (!has(T, "zenit_style_part")) {
        if (@typeInfo(T) != .@"struct" or reflection.fields(T).len != 0) return &.{};
        if (T == std or T == core or T == v or T == @import("ui.zig")) return &.{};
        for (ancestors) |ancestor| if (ancestor == T) return &.{};
        var out: []const CatalogStyle = &.{};
        for (@typeInfo(T).@"struct".decl_names) |name| {
            const value = @field(T, name);
            if (@TypeOf(value) == type) out = out ++ collectStyles(prefix ++ " . " ++ name, value, ancestors ++ .{T}) else if (has(@TypeOf(value), "zenit_style_part")) out = out ++ collectStyles(prefix ++ " . " ++ name, @TypeOf(value), ancestors ++ .{T});
        }
        return out;
    }
    if (T.zenit_style_part != .css or reflection.fields(T).len != 0) return &.{};
    return &.{.{ .tokens = prefix ++ " ", .Style = T }};
}
pub fn catalogStyles(comptime T: type) []const CatalogStyle {
    if (!has(T, "template_site") or T.template_site.catalog == void) return &.{};
    return T.template_site.catalog.styles;
}

/// View scopes own every runtime string that can outlive the publication call.
/// The parser arena can consequently be retired independently of unchanged trees.
fn ownText(scope: *Scope, bytes: []const u8) ![]const u8 {
    const Text = struct {
        bytes: []u8,
        fn destroy(raw: *anyopaque, a: std.mem.Allocator) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            a.free(self.bytes);
            a.destroy(self);
        }
    };
    const text = try scope.allocator.create(Text);
    text.* = .{ .bytes = scope.allocator.dupe(u8, bytes) catch |err| {
        scope.allocator.destroy(text);
        return err;
    } };
    try scope.adoptResource(text, Text.destroy);
    return text.bytes;
}

pub fn site(comptime meta: Metadata, captures: anytype, value: anytype) Site(meta, @TypeOf(captures), @TypeOf(value)) {
    return .{ .value = value };
}

fn Site(comptime meta: Metadata, comptime Captures: type, comptime Value: type) type {
    return struct {
        value: Value,
        pub const zenit_view_element = true;
        pub const view_single = if (@hasDecl(Value, "view_single")) Value.view_single else true;
        pub const template_site = meta;
        pub const template_captures = Captures;
        pub fn viewEmit(self: @This(), scope: *Scope, cx: *Cx, sink: v.Sink) anyerror!void {
            // Retain the original production entry, including its call graph:
            // preview's emitBody forwarding layer is not a release hot path.
            if (comptime !preview_enabled and !@import("builtin").is_test and !@import("zenit_environment").lp3b_template)
                return v.emit(scope, cx, sink, self.value);
            if (comptime preview_enabled) {
                const flow = @import("control_flow.zig");
                if (flow.template_region_pending and std.mem.indexOf(u8, meta.path, "/keyword_") != null and !std.mem.eql(u8, meta.receiver, "control")) {
                    flow.template_region_pending = false;
                    if (comptime regionRoot(Value, meta)) return self.emitRegion(scope, cx, sink, meta.path);
                }
                if (slot_region_pending) {
                    slot_region_pending = false;
                    if (comptime regionRoot(Value, meta)) {
                        const region_scope = try scope.childScope();
                        if (comptime @import("builtin").is_test) region_scope.test_preview_boundary = .slot_setup;
                        return self.emitRegion(region_scope, cx, sink, if (comptime std.mem.indexOf(u8, meta.path, "/slot:") != null) meta.path else meta.path ++ "/slot:children");
                    }
                }
            }
            try self.emitBody(scope, cx, sink);
        }
        fn emitRegion(self: @This(), scope: *Scope, cx: *Cx, sink: v.Sink, comptime key: []const u8) anyerror!void {
            const Context = struct {
                value: Site(meta, Captures, Value),
                identity: @import("control_flow.zig").TemplateRegionIdentity,
                pub const template_region_value = true;
            };
            const root = try v.renderComponentView(scope, cx, Context{ .value = self, .identity = @import("control_flow.zig").template_region_identity }, struct {
                fn render(ctx: Context, vs: *Scope, context: *Cx, at: v.Sink) anyerror!*Node {
                    if (comptime preview_enabled) {
                        const entry = try @import("template_reload.zig").lookupRegion(Site(meta, Captures, Value), meta, key);
                        if (v.templateInstanceForScope(vs)) |instance| {
                            instance.preview_template = entry;
                            if (comptime @import("builtin").is_test) vs.test_preview_boundary = .region_view;
                        }
                        if (entry.active) |ops| {
                            try build(.runtime_template, Site(meta, Captures, Value), ops, &ctx.value, vs, context, at);
                            return at.root.?.* orelse return error.ViewEmptyRoot;
                        }
                    }
                    try ctx.value.emitBody(vs, context, at);
                    return at.root.?.* orelse return error.ViewEmptyRoot;
                }
            }.render);
            try sink.insert(cx, root);
        }
        fn emitBody(self: @This(), scope: *Scope, cx: *Cx, sink: v.Sink) anyerror!void {
            if (comptime @import("zenit_environment").dev_preview and meta.source != null) {
                const entry = try @import("template_reload.zig").lookup(@This(), meta);
                if (v.templateInstanceForScope(scope)) |instance| instance.preview_template = entry;
                if (entry.active) |ops| return build(.runtime_template, @This(), ops, &self, scope, cx, sink);
            }
            if (comptime !@import("builtin").is_test) {
                if (comptime !@import("zenit_environment").dev_preview) {
                    if (comptime @import("zenit_environment").lp3b_template) return build(.comptime_template, @This(), Schema(@This()).instructions[0..], &self, scope, cx, sink);
                    return v.emit(scope, cx, sink, self.value);
                }
                return build(.runtime_template, @This(), Schema(@This()).instructions[0..], &self, scope, cx, sink);
            }
            const mode = if (comptime @import("builtin").is_test) cx.owner.template_builder else Mode.configured;
            const selected = if (mode == .configured) (if (@import("zenit_environment").dev_preview) Mode.runtime_template else Mode.release_tree) else mode;
            if (comptime @import("builtin").is_test and std.mem.eql(u8, meta.module, "tests/yix/equivalence_sequence.yix") and std.mem.eql(u8, meta.path, "Sequence") and std.mem.eql(u8, meta.receiver, "col")) {
                if (cx.owner.test_template_wrap and cx.owner.test_template_depth == 0) {
                    cx.owner.test_template_depth += 1;
                    defer cx.owner.test_template_depth -= 1;
                    // Reference trees and static templates instantiate the new
                    // row from their typed value. Runtime uses an edited data
                    // stream, with every existing opaque hole unchanged.
                    if (selected == .runtime_template) {
                        const original = Schema(@This()).instructions;
                        var edited: [original.len + 2]Instruction = undefined;
                        edited[0] = .{ .kind = .literal_open, .container = .{ .layout = .row, .test_id = "lp3-template-b" } };
                        @memcpy(edited[1 .. original.len + 1], &original);
                        edited[original.len + 1] = .{ .kind = .close };
                        return build(.runtime_template, @This(), &edited, &self, scope, cx, sink);
                    }
                    const wrapped = site(.{
                        .module = meta.module,
                        .path = meta.path,
                        .receiver = "row",
                        .tokens = "row",
                        .attributes = &.{.{ .name = "test_id", .tokens = "lp3-template-b", .kind = .property, .literal = .{ .text = "lp3-template-b" } }},
                    }, .{}, v.row(.{ .test_id = "lp3-template-b" }, .{self}));
                    comptime {
                        @setEvalBranchQuota(500_000);
                        std.debug.assert(Schema(@This()).holes.len == Schema(@TypeOf(wrapped)).holes.len);
                        for (Schema(@This()).holes, Schema(@TypeOf(wrapped)).holes) |before, after|
                            std.debug.assert(fingerprint(before) == fingerprint(after));
                    }
                    if (selected == .comptime_template)
                        return build(.comptime_template, @TypeOf(wrapped), Schema(@TypeOf(wrapped)).instructions[0..], &wrapped, scope, cx, sink);
                    return v.emit(scope, cx, sink, wrapped);
                }
            }
            switch (selected) {
                .release_tree => try v.emit(scope, cx, sink, self.value),
                .comptime_template => try build(.comptime_template, @This(), Schema(@This()).instructions[0..], &self, scope, cx, sink),
                .runtime_template => try build(.runtime_template, @This(), Schema(@This()).instructions[0..], &self, scope, cx, sink),
                .configured => unreachable,
            }
        }
    };
}

// In dev preview, a slot's first template root gets an independent setup/view
// boundary. Release emits directly; the flag has no release storage.
pub var slot_region_pending: if (preview_enabled) bool else void = if (preview_enabled) false else {};
pub fn emitSlot(scope: *Scope, cx: *Cx, sink: v.Sink, content: anytype) !void {
    if (comptime !preview_enabled) return v.emit(scope, cx, sink, content);
    const pending = slot_region_pending;
    const flow = @import("control_flow.zig");
    const identity = flow.template_region_identity;
    flow.template_region_identity = .{};
    slot_region_pending = comptime singleSlotSite(@TypeOf(content));
    defer {
        slot_region_pending = pending;
        flow.template_region_identity = identity;
    }
    try v.emit(scope, cx, sink, content);
}

fn regionRoot(comptime T: type, comptime meta: Metadata) bool {
    @setEvalBranchQuota(100000);
    const receiver = meta.receiver;
    if (std.mem.eql(u8, receiver, "box") or std.mem.eql(u8, receiver, "row") or std.mem.eql(u8, receiver, "col") or std.mem.eql(u8, receiver, "text")) return isolatedFactory(T, meta);
    if (!componentReceiver(receiver) or @typeInfo(T) != .@"struct") return false;
    if (@hasField(T, "child")) return regionRoot(@FieldType(T, "child"), meta);
    if (@hasField(T, "builder")) return regionRoot(@FieldType(T, "builder"), meta);
    if (@hasField(T, "props")) return has(@FieldType(T, "props"), "__yix_preview_builder");
    return false;
}

fn singleSlotSite(comptime T: type) bool {
    if (has(T, "template_site")) return true;
    if (@typeInfo(T) == .@"struct" and @typeInfo(T).@"struct".is_tuple) {
        const fields = reflection.fields(T);
        return fields.len == 1 and singleSlotSite(fields[0].type);
    }
    return false;
}

fn has(comptime T: type, comptime name: []const u8) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum" => @hasDecl(T, name),
        else => false,
    };
}
fn count(comptime T: type) usize {
    if (has(T, "template_site")) return count(@FieldType(T, "value"));
    if (has(T, "template_container")) {
        var n: usize = 2;
        const Children = @FieldType(T, "children");
        inline for (reflection.fields(Children)) |f| n += count(f.type);
        return n;
    }
    return 1;
}
fn get(comptime path: []const u8, root: anytype) Get(@TypeOf(root), path) {
    if (path.len == 0) return root;
    const dot = comptime std.mem.indexOfScalar(u8, path, '.');
    const first = comptime if (dot) |i| path[0..i] else path;
    const tail = comptime if (dot) |i| path[i + 1 ..] else "";
    return get(tail, @field(root, first));
}
fn Get(comptime T: type, comptime path: []const u8) type {
    if (path.len == 0) return T;
    const dot = std.mem.indexOfScalar(u8, path, '.');
    const first = if (dot) |i| path[0..i] else path;
    const tail = if (dot) |i| path[i + 1 ..] else "";
    return Get(@FieldType(T, first), tail);
}
fn join(comptime a: []const u8, comptime b: []const u8) []const u8 {
    return if (a.len == 0) b else a ++ "." ++ b;
}
fn captureDescriptors(comptime C: type) [reflection.fields(C).len]Capture {
    var out: [reflection.fields(C).len]Capture = undefined;
    for (reflection.fields(C), 0..) |f, i| out[i] = .{ .id = std.hash.Wyhash.hash(0, f.name), .name = f.name, .type_name = @typeName(f.type) };
    return out;
}
fn receiverEdges(comptime T: type) []const Receiver {
    if (@typeInfo(T) != .@"struct" and @typeInfo(T) != .@"union") return &.{};
    if (!@hasField(T, "props")) return &.{};
    return &struct {
        const values = blk: {
            const fields = reflection.fields(@FieldType(T, "props"));
            var out: [fields.len]Receiver = undefined;
            for (fields, 0..) |field, i| out[i] = .{ .name = field.name, .expected_type = @typeName(field.type) };
            break :blk out;
        };
    }.values;
}

fn literalContainer(comptime T: type, comptime meta: Metadata) ?LiteralContainer {
    if (!has(T, "template_container")) return null;
    var out: LiteralContainer = .{};
    if (std.mem.eql(u8, meta.receiver, "row")) out.layout = .row else if (std.mem.eql(u8, meta.receiver, "col")) out.layout = .col else if (!std.mem.eql(u8, meta.receiver, "box")) return null;
    if (reflection.fields(@FieldType(T, "props")).len != meta.attributes.len) return null;
    for (meta.attributes) |attribute| {
        if (std.mem.eql(u8, attribute.name, "style") and staticCss(T)) continue;
        if (std.mem.eql(u8, attribute.name, "style")) {
            out.style = literalStyle(attribute.tokens) orelse return null;
            continue;
        }
        if (attribute.kind != .property) return null;
        const value = attribute.literal orelse return null;
        if (std.mem.eql(u8, attribute.name, "test_id") and value == .text) {
            out.test_id = value.text;
        } else if (std.mem.eql(u8, attribute.name, "visible") and value == .boolean) {
            out.visible = value.boolean;
        } else if (std.mem.eql(u8, attribute.name, "focusable") and value == .boolean) {
            out.focusable = value.boolean;
        } else if (std.mem.eql(u8, attribute.name, "hit_test") and value == .boolean) {
            out.hit_test = value.boolean;
        } else return null;
    }
    return out;
}

/// Bounded scalar style data, deliberately excluding calls, tokens, functions,
/// struct constructors and arbitrary Zig. Unknown grammar always uses L3.
pub fn literalStyle(tokens: []const u8) ?core.BoxStyle {
    var words = std.mem.tokenizeAny(u8, tokens, " \t\r\n");
    if (!std.mem.eql(u8, words.next() orelse return null, ".") or !std.mem.eql(u8, words.next() orelse return null, "{")) return null;
    var out: core.BoxStyle = .{};
    var seen: [reflection.fields(core.BoxStyle).len]bool = @splat(false);
    while (true) {
        const marker = words.next() orelse return null;
        if (std.mem.eql(u8, marker, "}")) return if (words.next() == null) out else null;
        if (!std.mem.eql(u8, marker, ".")) return null;
        const name = words.next() orelse return null;
        if (!std.mem.eql(u8, words.next() orelse return null, "=")) return null;
        var value = words.next() orelse return null;
        const enum_value = std.mem.eql(u8, value, ".");
        if (enum_value) value = words.next() orelse return null;
        var matched = false;
        inline for (reflection.fields(core.BoxStyle), 0..) |field, index| {
            if (std.mem.eql(u8, field.name, name)) {
                if (seen[index]) return null;
                seen[index] = true;
                @field(out, field.name) = scalar(field.type, value, enum_value) orelse return null;
                matched = true;
            }
        }
        if (!matched) return null;
        const delimiter = words.next() orelse return null;
        if (std.mem.eql(u8, delimiter, "}")) return if (words.next() == null) out else null;
        if (!std.mem.eql(u8, delimiter, ",")) return null;
    }
}
fn scalar(comptime T: type, value: []const u8, enum_value: bool) ?T {
    if (comptime @typeInfo(T) == .optional) {
        const inner = scalar(@typeInfo(T).optional.child, value, enum_value) orelse return null;
        return @as(T, inner);
    }
    switch (@typeInfo(T)) {
        .@"enum" => return if (enum_value) std.meta.stringToEnum(T, value) else null,
        .bool => {
            if (enum_value) return null;
            return if (std.mem.eql(u8, value, "true")) true else if (std.mem.eql(u8, value, "false")) false else null;
        },
        .float => {
            if (enum_value) return null;
            const n = std.fmt.parseFloat(T, value) catch return null;
            return if (std.math.isFinite(n) and n >= 0) n else null;
        },
        .int => return if (!enum_value) std.fmt.parseInt(T, value, 0) catch null else null,
        else => {
            if (comptime T == core.Sizing) {
                if (enum_value) return null;
                const n = scalar(f32, value, false) orelse return null;
                return .{ .px = n };
            }
            if (comptime T == core.Padding) return core.Padding.all(scalar(f32, value, enum_value) orelse return null);
            return null;
        },
    }
}

fn plainFormatType(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .int, .float, .comptime_int, .comptime_float, .bool, .null => true,
        .@"enum" => !has(T, "format"),
        .optional => |optional| plainFormatType(optional.child),
        .array => |array| array.child == u8,
        .pointer => |pointer| pointer.child == u8 or (@typeInfo(pointer.child) == .array and @typeInfo(pointer.child).array.child == u8),
        else => false,
    };
}
fn safeData(value: anytype) bool {
    const T = @TypeOf(value);
    if (comptime has(T, "zenit_source")) return switch (value) {
        .value => |x| safeData(x),
        .signal => plainCandidateType(T.Value),
        .memo, .derived => false,
    };
    if (comptime @typeInfo(T) == .pointer and has(@typeInfo(T).pointer.child, "zenit_reactive")) {
        const S = @typeInfo(T).pointer.child;
        return S.zenit_reactive == .signal and plainCandidateType(S.Value);
    }
    if (comptime has(T, "zenit_view_fmt")) {
        inline for (reflection.fields(@TypeOf(value.args))) |field| if (!safeData(@field(value.args, field.name))) return false;
        return true;
    }
    if (comptime @typeInfo(T) == .pointer and has(@typeInfo(T).pointer.child, "view_preview_ref")) return true;
    if (comptime T == core.HandlerRef) return true;
    return plainCandidateType(T);
}
fn plainCandidateType(comptime T: type) bool {
    if (plainFormatType(T)) return true;
    return switch (@typeInfo(T)) {
        .array => |a| plainCandidateType(a.child),
        .pointer => |p| if (p.size == .slice) plainCandidateType(p.child) else false,
        .@"struct" => blk: {
            if (has(T, "format")) break :blk false;
            inline for (reflection.fields(T)) |field| if (!plainCandidateType(field.type)) break :blk false;
            break :blk true;
        },
        else => false,
    };
}
/// Called before generated view expressions allocate or read any Sources.
/// A late factory check cannot undo side effects of a derived getter.
pub fn validatePreviewContext(ctx: anytype) !void {
    const T = @TypeOf(ctx);
    if (comptime @typeInfo(T) == .@"struct") {
        inline for (reflection.fields(T)) |field| {
            if (!safeData(@field(ctx, field.name))) return error.TemplateCandidateSideEffects;
        }
    } else if (!safeData(ctx)) return error.TemplateCandidateSideEffects;
}

/// A retained factory's old captures must outlive the destination, even when
/// the freshly evaluated factory has new, superficially identical bindings.
pub fn retainedValueSafe(value: anytype, consumer: *Scope) bool {
    const T = @TypeOf(value);
    if (comptime T == void or T == @TypeOf(null)) return true;
    if (comptime T == core.HandlerRef) return false;
    if (comptime has(T, "zenit_source")) return switch (value) {
        .value => |data| retainedValueSafe(data, consumer),
        .signal => |signal| retainedValueSafe(signal, consumer),
        .memo, .derived => false,
    };
    if (comptime @typeInfo(T) == .pointer and has(@typeInfo(T).pointer.child, "zenit_reactive")) {
        if (comptime @typeInfo(T).pointer.child.zenit_reactive != .signal) return false;
        if (value.owner != consumer.owner) return false;
        if (value.base.scope_allocator == null) return true;
        var scope: ?*Scope = consumer;
        while (scope) |s| : (scope = s.parent) {
            for (s.signals.items) |signal| if (signal == &value.base) return true;
        }
        return false;
    }
    if (comptime @typeInfo(T) == .pointer and has(@typeInfo(T).pointer.child, "view_preview_ref")) {
        var scope: ?*Scope = consumer;
        while (scope) |s| : (scope = s.parent) if (s == value.owner) return true;
        return false;
    }
    if (comptime @typeInfo(T) == .@"struct") {
        inline for (reflection.fields(T)) |field| if (!retainedValueSafe(@field(value, field.name), consumer)) return false;
        return true;
    }
    if (comptime @typeInfo(T) == .optional) return if (value) |data| retainedValueSafe(data, consumer) else true;
    if (comptime @typeInfo(T) == .array) {
        for (value) |data| if (!retainedValueSafe(data, consumer)) return false;
        return true;
    }
    // Plain bytes are safe to read during preparation, but that does not prove
    // the old capture outlives its retiring view. Empty slices borrow no bytes.
    if (comptime @typeInfo(T) == .pointer) return if (@typeInfo(T).pointer.size == .slice and @typeInfo(T).pointer.sentinel_ptr == null) value.len == 0 else false;
    return safeData(value);
}

/// Static metadata provides a storage identity to compare with a property.
/// Equal contents alone never authorize retaining borrowed storage.
pub fn retainedFactorySafe(value: anytype, consumer: *Scope, comptime meta: Metadata) bool {
    const T = @TypeOf(value);
    if (comptime @typeInfo(T) == .@"struct" and !has(T, "zenit_source")) {
        inline for (reflection.fields(T)) |field| {
            const data = @field(value, field.name);
            if (comptime std.mem.eql(u8, field.name, "props") and @typeInfo(field.type) == .@"struct" and has(field.type, "__yix_preview_mount")) {
                inline for (reflection.fields(field.type)) |property| {
                    if (!retainedPropertySafe(@field(data, property.name), consumer, meta, property.name, comptime defaultText(property))) return false;
                }
            } else if (!retainedFactorySafe(data, consumer, meta)) return false;
        }
        return true;
    }
    return retainedValueSafe(value, consumer);
}

fn defaultText(comptime property: reflection.StructField) ?[]const u8 {
    const value = property.defaultValue() orelse return null;
    if (property.type == []const u8) return value;
    if (has(property.type, "zenit_source") and property.type.Value == []const u8) return switch (value) {
        .value => |data| data,
        else => null,
    };
    return null;
}

fn retainedPropertySafe(value: anytype, consumer: *Scope, comptime meta: Metadata, comptime name: []const u8, comptime default: ?[]const u8) bool {
    const T = @TypeOf(value);
    if (comptime has(T, "zenit_source")) return switch (value) {
        .value => |data| retainedPropertySafe(data, consumer, meta, name, default),
        else => retainedValueSafe(value, consumer),
    };
    if (comptime T == []const u8) {
        inline for (meta.attributes) |attribute| {
            if (comptime std.mem.eql(u8, attribute.name, name)) {
                if (comptime attribute.literal) |literal| {
                    if (comptime literal == .text) return value.ptr == literal.text.ptr and value.len == literal.text.len;
                }
                return retainedValueSafe(value, consumer);
            }
        }
        // An omitted property uses the actual static default, not an equal
        // runtime allocation. Explicit expressions never use this exception.
        if (comptime default) |bytes| if (value.ptr == bytes.ptr and value.len == bytes.len) return true;
    }
    return retainedValueSafe(value, consumer);
}

pub fn attachmentContextSafe(value: anytype) bool {
    const T = @TypeOf(value);
    if (comptime T == void or T == @TypeOf(null)) return true;
    if (comptime @typeInfo(T) == .@"struct" and !has(T, "zenit_source") and !has(T, "zenit_model")) {
        inline for (reflection.fields(T)) |field| {
            if (comptime std.mem.eql(u8, field.name, "style")) {
                const S = field.type;
                if (comptime has(S, "zenit_style_part")) {
                    if (comptime S.zenit_style_part != .css or reflection.fields(S).len != 0) return false;
                } else if (comptime S != core.BoxStyle) return false;
            }
            if (!attachmentContextSafe(@field(value, field.name))) return false;
        }
        return true;
    }
    return safeData(value);
}

pub fn isRegionContext(comptime T: type) bool {
    return has(T, "template_region_value");
}
pub fn validateRegionContext(ctx: anytype) !void {
    if (!previewValueSafe(ctx.value.value)) return error.TemplateCandidateSideEffects;
}

fn previewValueSafe(value: anytype) bool {
    const T = @TypeOf(value);
    if (comptime @typeInfo(T) != .@"struct" and @typeInfo(T) != .@"union") return false;
    if (comptime @hasField(T, "child")) if (!previewValueSafe(value.child)) return false;
    if (comptime @hasField(T, "builder")) if (!previewValueSafe(value.builder)) return false;
    if (comptime @hasField(T, "trigger_children")) {
        if (comptime @TypeOf(value.trigger_children) != void or @TypeOf(value.part_ids) != void or @TypeOf(value.named) != void) return false;
        if (comptime reflection.fields(@TypeOf(value.children)).len != 0) return false;
    }
    if (comptime @hasField(T, "cond")) if (!safeData(value.cond)) return false;
    if (comptime @hasField(T, "src")) if (!safeData(value.src)) return false;
    if (comptime @hasField(T, "items")) if (!safeData(value.items)) return false;
    if (comptime @hasField(T, "ctx")) if (!attachmentContextSafe(value.ctx)) return false;
    if (comptime @hasField(T, "content")) if (!safeData(value.content)) return false;
    if (comptime @hasField(T, "props")) {
        inline for (reflection.fields(@TypeOf(value.props))) |field| {
            if (comptime std.mem.eql(u8, field.name, "style")) {
                const style = @field(value.props, field.name);
                const S = @TypeOf(style);
                if (comptime has(S, "zenit_style_part")) {
                    if (comptime S.zenit_style_part != .css or reflection.fields(S).len != 0) return false;
                } else if (!safeData(style)) return false;
            } else if (comptime !std.mem.eql(u8, field.name, "on_click")) {
                if (!safeData(@field(value.props, field.name))) return false;
            }
        }
    }
    return true;
}

fn staticCss(comptime T: type) bool {
    if (!@hasField(T, "props")) return false;
    const P = @FieldType(T, "props");
    if (!@hasField(P, "style")) return false;
    const S = @FieldType(P, "style");
    return has(S, "zenit_style_part") and S.zenit_style_part == .css and reflection.fields(S).len == 0;
}

fn controlTokensSafe(comptime tokens: []const u8) bool {
    @setEvalBranchQuota(100000);
    var tokenizer = std.zig.Tokenizer.init(tokens ++ "");
    var previous: std.zig.Token.Tag = .eof;
    while (true) {
        const token = tokenizer.next();
        switch (token.tag) {
            .eof => return true,
            .builtin, .period_asterisk => return false,
            .l_paren => if (previous == .identifier or previous == .r_paren or previous == .r_bracket or previous == .r_brace or previous == .asterisk or previous == .period) return false,
            else => {},
        }
        previous = token.tag;
    }
}

fn isolatedFactory(comptime T: type, comptime meta: Metadata) bool {
    if (std.mem.eql(u8, meta.receiver, "control")) return controlTokensSafe(meta.tokens);
    // Component wrappers are guarded by generated builder/setup checks before
    // evaluation. Their complete syntax, including attrs/ref/slots, is one hole.
    if (meta.receiver.len != 0 and (std.ascii.isUpper(meta.receiver[0]) or std.mem.indexOfScalar(u8, meta.receiver, '.') != null)) return true;
    if (has(T, "view_preview_ref")) return true;
    if (!has(T, "template_container") and !has(T, "template_text")) return false;
    for (meta.attributes) |attribute| {
        const name = attribute.name;
        if (std.mem.eql(u8, name, "style")) {
            if (!staticCss(T) and literalStyle(attribute.tokens) == null) return false;
        } else if (!std.mem.eql(u8, name, "key") and !std.mem.eql(u8, name, "test_id") and !std.mem.eql(u8, name, "visible") and !std.mem.eql(u8, name, "focusable") and !std.mem.eql(u8, name, "hit_test") and !std.mem.eql(u8, name, "on_click")) return false;
    }
    return true;
}

fn argumentFormats(comptime F: type) [reflection.fields(@FieldType(F, "args")).len][]const u8 {
    const text = F.format;
    var out: [reflection.fields(@FieldType(F, "args")).len][]const u8 = undefined;
    var cursor: usize = 0;
    var n: usize = 0;
    while (cursor < text.len) {
        if (text[cursor] != '{') {
            cursor += 1;
            continue;
        }
        if (cursor + 1 < text.len and text[cursor + 1] == '{') {
            cursor += 2;
            continue;
        }
        const end = std.mem.indexOfScalarPos(u8, text, cursor, '}') orelse @compileError("invalid Yix format");
        if (n >= out.len) @compileError("Yix format argument mismatch");
        out[n] = text[cursor .. end + 1];
        n += 1;
        cursor = end + 1;
    }
    if (n != out.len) @compileError("Yix format argument mismatch");
    return out;
}
fn formatValue(value: anytype) if (has(@TypeOf(value), "zenit_source")) @TypeOf(value).Value else if (@typeInfo(@TypeOf(value)) == .pointer and has(@typeInfo(@TypeOf(value)).pointer.child, "zenit_reactive")) @typeInfo(@TypeOf(value)).pointer.child.Value else @TypeOf(value) {
    if (comptime has(@TypeOf(value), "zenit_source")) return value.get();
    if (comptime @typeInfo(@TypeOf(value)) == .pointer and has(@typeInfo(@TypeOf(value)).pointer.child, "zenit_reactive")) return value.get();
    return value;
}
fn FormatValues(comptime Args: type) type {
    const fields = reflection.fields(Args);
    var types: [fields.len]type = undefined;
    for (fields, 0..) |field, i| types[i] = @TypeOf(formatValue(@as(field.type, undefined)));
    return @Tuple(&types);
}
fn readFormatValues(args: anytype) FormatValues(@TypeOf(args)) {
    var values: FormatValues(@TypeOf(args)) = undefined;
    inline for (reflection.fields(@TypeOf(args)), 0..) |field, i| values[i] = formatValue(@field(args, field.name));
    return values;
}
fn PreviewFormat(comptime F: type) type {
    const formats = argumentFormats(F);
    return struct {
        pub const zenit_preview_fmt = true;
        args: @FieldType(F, "args"),
        fragments: [formats.len + 1][]const u8,
        pub fn createNode(self: @This(), scope: *Scope, cx: *Cx, style: core.TextStyle) !*Node {
            const State = struct {
                value: @TypeOf(self),
                node: *Node,
                allocator: std.mem.Allocator,
                buffers: [2][256]u8 = undefined,
                active: u1 = 0,
                overflow: ?[]u8 = null,
                failed: bool = false,
                fn cleanup(state: *@This()) void {
                    if (state.overflow) |bytes| state.allocator.free(bytes);
                }
                fn write(state: *@This(), writer: *std.Io.Writer, args: FormatValues(@FieldType(F, "args"))) !void {
                    inline for (formats, 0..) |format, i| {
                        try writer.writeAll(state.value.fragments[i]);
                        try writer.print(format, .{args[i]});
                    }
                    try writer.writeAll(state.value.fragments[formats.len]);
                }
                fn run(state: *@This()) void {
                    state.failed = true;
                    // Track every source before formatting can fail. Otherwise
                    // an OOM before the first placeholder removes dependencies
                    // and the text can never recover on a later source update.
                    const args = readFormatValues(state.value.args);
                    const target = state.active ^ 1;
                    var fixed = std.Io.Writer.fixed(&state.buffers[target]);
                    var next_overflow: ?[]u8 = null;
                    const content = blk: {
                        state.write(&fixed, args) catch {
                            var heap = std.Io.Writer.Allocating.init(state.allocator);
                            state.write(&heap.writer, args) catch {
                                heap.deinit();
                                return;
                            };
                            const bytes = heap.toOwnedSlice() catch {
                                heap.deinit();
                                return;
                            };
                            next_overflow = bytes;
                            break :blk bytes;
                        };
                        break :blk fixed.buffered();
                    };
                    var text = state.node.getText().?;
                    text.content = content;
                    text.owned = false;
                    state.node.setText(text);
                    const previous_overflow = state.overflow;
                    state.overflow = next_overflow;
                    state.active = target;
                    if (previous_overflow) |old| state.allocator.free(old);
                    state.node.markRenderDirty();
                    state.failed = false;
                }
            };
            const node = try core.text(cx, "", style);
            errdefer cx.freeDetachedNodeAfterScopeDispose(node);
            const state = try scope.createState(State, .{ .value = self, .node = node, .allocator = scope.allocator });
            try scope.onCleanup(State, state, State.cleanup);
            try scope.createEffect(state, State.run);
            if (state.failed) return error.OutOfMemory;
            return node;
        }
    };
}
fn previewFormat(scope: *Scope, value: anytype, fragments: []const []const u8) !PreviewFormat(@TypeOf(value)) {
    var result: PreviewFormat(@TypeOf(value)) = .{ .args = value.args, .fragments = undefined };
    if (fragments.len != result.fragments.len) return error.TemplateReceiverMismatch;
    for (fragments, 0..) |fragment, i| result.fragments[i] = try ownText(scope, fragment);
    return result;
}

fn PatchedProps(comptime P: type, comptime meta: Metadata, comptime S: type) type {
    var fields: [reflection.fields(P).len]reflection.StructField = undefined;
    for (reflection.fields(P), 0..) |field, i| {
        fields[i] = field;
        if (S != void and std.mem.eql(u8, field.name, "style")) {
            fields[i].type = S;
            fields[i].is_comptime = false;
            fields[i].default_value_ptr = null;
        } else for (meta.attributes) |attribute| {
            if (!std.mem.eql(u8, attribute.name, field.name) or attribute.literal == null) continue;
            if (std.mem.eql(u8, field.name, "test_id")) fields[i].type = ?[]const u8 else if (std.mem.eql(u8, field.name, "visible") or std.mem.eql(u8, field.name, "focusable") or std.mem.eql(u8, field.name, "hit_test")) fields[i].type = bool else continue;
            fields[i].is_comptime = false;
            fields[i].default_value_ptr = null;
        }
    }
    return reflection.Struct(&fields);
}
fn patchedProps(props: anytype, comptime meta: Metadata, comptime S: type, scope: *Scope, op: Instruction) !PatchedProps(@TypeOf(props), meta, S) {
    var out: PatchedProps(@TypeOf(props), meta, S) = undefined;
    inline for (reflection.fields(@TypeOf(props))) |field| {
        if (comptime S != void and std.mem.eql(u8, field.name, "style")) {
            @field(out, field.name) = if (comptime S == core.BoxStyle) op.inline_style.? else S{};
        } else if (comptime @FieldType(@TypeOf(out), field.name) != field.type or for (meta.attributes) |a| {
            if (std.mem.eql(u8, a.name, field.name) and a.literal != null and (std.mem.eql(u8, a.name, "visible") or std.mem.eql(u8, a.name, "focusable") or std.mem.eql(u8, a.name, "hit_test"))) break true;
        } else false) {
            for (op.attributes) |attribute| {
                if (!std.mem.eql(u8, attribute.name, field.name)) continue;
                const literal = attribute.literal orelse return error.TemplateLiteralMissing;
                if (comptime std.mem.eql(u8, field.name, "test_id")) @field(out, field.name) = try ownText(scope, literal.text) else @field(out, field.name) = literal.boolean;
                break;
            } else return error.TemplateLiteralMissing;
        } else @field(out, field.name) = @field(props, field.name);
    }
    return out;
}
fn emitPatched(value: anytype, comptime meta: Metadata, comptime S: type, scope: *Scope, cx: *Cx, sink: v.Sink, op: Instruction) !?*Node {
    const props = try patchedProps(value.props, meta, S, scope, op);
    if (comptime has(@TypeOf(value), "template_container")) {
        return switch (meta.receiver[0]) {
            'r' => try v.row(props, .{}).viewShallow(scope, cx, sink),
            'c' => try v.col(props, .{}).viewShallow(scope, cx, sink),
            else => try v.box(props, .{}).viewShallow(scope, cx, sink),
        };
    }
    if (op.literal_text) |text| try v.emit(scope, cx, sink, v.text(props, text)) else if (comptime has(@TypeOf(value.content), "zenit_view_fmt") and std.mem.indexOf(u8, meta.tokens, "@interpolation") != null) {
        if (op.fragments.len != 0) {
            const content = try previewFormat(scope, value.content, op.fragments);
            try v.emit(scope, cx, sink, v.text(props, content));
        } else try v.emit(scope, cx, sink, v.text(props, value.content));
    } else try v.emit(scope, cx, sink, v.text(props, value.content));
    return null;
}

fn cssSpecCompatible(comptime Spec: type, comptime text: bool, comptime allow_box: bool, comptime condition: bool) bool {
    for (reflection.fields(Spec)) |field| {
        const name = field.name;
        if (std.mem.eql(u8, name, "transition")) continue;
        if (name.len > 0 and name[0] == '_') {
            if (text and !std.mem.eql(u8, name, "_hover")) return false;
            if (!cssSpecCompatible(field.type, text, if (text) false else true, true)) return false;
            continue;
        }
        if (text) {
            if (std.mem.eql(u8, name, "typography")) continue;
            const mapped = if (std.mem.eql(u8, name, "text_color")) "color" else name;
            if (@hasField(core.TextStyle, mapped)) continue;
            if (!allow_box or condition or !@hasField(core.BoxStyle, name)) return false;
        } else {
            const mapped = if (std.mem.eql(u8, name, "color")) "text_color" else name;
            if (!@hasField(core.BoxStyle, mapped)) return false;
        }
    }
    return true;
}
fn semanticStylesAvailable(comptime P: type, comptime S: type) bool {
    for (.{ "disabled", "invalid", "selected", "expanded" }) |name| {
        if (!@field(S.state_conditions, name)) continue;
        if (@hasField(P, "state")) {
            const State = @FieldType(P, "state");
            if (@typeInfo(State) == .@"struct" and @hasField(State, name)) continue;
        }
        if (@hasField(P, "a11y")) {
            const A11y = @FieldType(P, "a11y");
            if (@typeInfo(A11y) == .@"struct" and @hasField(A11y, name)) continue;
        }
        return false;
    }
    return true;
}
fn literalCatalogCompatible(comptime S: type) bool {
    return cssSpecCompatible(@TypeOf(S.spec), false, true, false) and semanticStylesAvailable(struct {}, S);
}
fn catalogStyleCompatible(comptime T: type, comptime S: type) bool {
    if (@typeInfo(T) != .@"struct" and @typeInfo(T) != .@"union") return false;
    if (!@hasField(T, "props") or !@hasField(@FieldType(T, "props"), "style")) return false;
    if (has(T, "template_container")) return cssSpecCompatible(@TypeOf(S.spec), false, true, false) and semanticStylesAvailable(@FieldType(T, "props"), S);
    if (has(T, "template_text")) return cssSpecCompatible(@TypeOf(S.spec), true, !@hasField(@FieldType(T, "props"), "box"), false);
    return false;
}
fn catalogBoxAllowed(comptime T: type, slot: u32) bool {
    inline for (comptime catalogStyles(T), 0..) |style, i| {
        if (slot == i) return comptime literalCatalogCompatible(style.Style);
    }
    return false;
}

pub fn componentReceiver(name: []const u8) bool {
    return name.len != 0 and (std.ascii.isUpper(name[0]) or std.mem.indexOfScalar(u8, name, '.') != null);
}
fn holeFor(comptime T: type, binding: u32) Hole {
    return Schema(T).entries[binding].factory.?.hole;
}
pub fn relocatableHole(hole: Hole, attributes: []const Attribute) bool {
    if (!componentReceiver(hole.receiver.name)) return false;
    // Event binding contexts can belong to the retiring view rather than setup.
    // A stable expression token alone cannot extend that context's lifetime.
    for (attributes) |attribute| if (attribute.kind == .event) return false;
    return true;
}

fn fill(comptime Root: type, comptime T: type, comptime path: []const u8, comptime meta: Metadata, comptime C: type, entries: anytype, cursor: *usize) void {
    if (has(T, "template_site")) {
        fill(Root, @FieldType(T, "value"), join(path, "value"), T.template_site, T.template_captures, entries, cursor);
        return;
    }
    const container = has(T, "template_container");
    const index = cursor.*;
    const cs = captureDescriptors(C);
    const edges = receiverEdges(T);
    const hole: Hole = .{
        .module = meta.module,
        .edges = edges,
        .site = std.hash.Wyhash.hash(std.hash.Wyhash.hash(std.hash.Wyhash.hash(0, meta.module), meta.path), meta.receiver),
        .path = meta.path,
        .captures = &cs,
        .type_name = @typeName(T),
        .receiver = .{ .name = meta.receiver, .expected_type = @typeName(T) },
        .token_fingerprint = std.hash.Wyhash.hash(0, meta.tokens),
        .tokens = meta.tokens,
    };
    entries[index] = .{
        .preview_isolated = isolatedFactory(T, meta),
        .op = .{ .kind = if (container) .open else .emit, .binding = @intCast(index), .literal_text = if (has(T, "template_text")) meta.literal_text else null, .element = meta.receiver, .attributes = meta.attributes },
        .factory = .{ .kind = if (container) .open else .emit, .hole = hole, .emit = struct {
            fn emit(raw: *const anyopaque, scope: *Scope, cx: *Cx, sink: v.Sink, op: Instruction) anyerror!?*Node {
                const root: *const Root = @ptrCast(@alignCast(raw));
                const value = get(path, root.*);
                if (comptime preview_enabled) if (@import("template_reload.zig").preparing()) {
                    if (comptime !isolatedFactory(T, meta)) return error.TemplateCandidateSideEffects;
                    if (!previewValueSafe(value)) return error.TemplateCandidateSideEffects;
                };
                if (comptime preview_enabled and (has(T, "template_container") or has(T, "template_text"))) if (op.fragments.len != 0 or op.catalog_style != null or op.inline_style != null or !attributesEqual(meta.attributes, op.attributes)) {
                    if (comptime container) {
                        if (op.inline_style != null) return emitPatched(value, meta, core.BoxStyle, scope, cx, sink, op);
                    } else if (op.inline_style != null) return error.TemplateReceiverMismatch;
                    if (op.catalog_style) |slot| inline for (comptime catalogStyles(Root), 0..) |style, i| {
                        if (slot == i) {
                            if (comptime catalogStyleCompatible(T, style.Style)) return emitPatched(value, meta, style.Style, scope, cx, sink, op);
                            return error.TemplateStyleReceiverMismatch;
                        }
                    };
                    return emitPatched(value, meta, void, scope, cx, sink, op);
                };
                if (comptime preview_enabled) if (@import("template_reload.zig").preparing() and (op.relocate or v.retainRelocatedTemplateChild(scope, holeFor(Root, op.binding)))) {
                    try v.stageTemplateChild(scope, cx, sink, Schema(Root).entries[op.binding].factory.?.hole);
                    return null;
                };
                const scope_start = scope.children.items.len;
                if (comptime container) return try value.viewShallow(scope, cx, sink);
                if (comptime has(T, "template_text") and meta.literal_text != null) {
                    try v.emit(scope, cx, sink, v.text(value.props, op.literal_text orelse return error.TemplateLiteralMissing));
                } else try v.emit(scope, cx, sink, value);
                if (comptime preview_enabled and componentReceiver(meta.receiver)) {
                    try v.recordTemplateChild(scope, cx, scope_start, holeFor(Root, op.binding), value, meta);
                }
                return null;
            }
        }.emit, .style_allowed = struct {
            fn allowed(slot: u32) bool {
                inline for (comptime catalogStyles(Root), 0..) |style, i| if (slot == i) return comptime catalogStyleCompatible(T, style.Style);
                return false;
            }
        }.allowed, .fragment_count = if (has(T, "template_text")) blk: {
            const Content = @FieldType(T, "content");
            if (has(Content, "zenit_view_fmt") and std.mem.indexOf(u8, meta.tokens, "@interpolation") != null) break :blk reflection.fields(@FieldType(Content, "args")).len + 1;
            break :blk 0;
        } else 0 },
    };
    if (literalContainer(T, meta)) |literal| {
        var data = literal;
        var style_factory: ?StyleFactory = null;
        if (staticCss(T)) {
            data.style_slot = @intCast(index);
            const S = @FieldType(@FieldType(T, "props"), "style");
            const tokens = for (meta.attributes) |attribute| {
                if (std.mem.eql(u8, attribute.name, "style")) break attribute.tokens;
            } else unreachable;
            style_factory = .{ .tokens = tokens, .emit = struct {
                fn emit(scope: *Scope, cx: *Cx, sink: v.Sink, c: LiteralContainer) anyerror!*Node {
                    return literalBox(scope, cx, sink, c.layout, .{ .test_id = c.test_id, .visible = c.visible, .focusable = c.focusable, .hit_test = c.hit_test, .style = S{} });
                }
            }.emit };
        }
        entries[index] = .{ .op = .{ .kind = .literal_open, .element = meta.receiver, .attributes = meta.attributes, .container = data }, .style_factory = style_factory, .preview_isolated = true };
    } else if (has(T, "template_text") and meta.literal_text != null and reflection.fields(@FieldType(T, "props")).len == 0) {
        entries[index] = .{ .op = .{ .kind = .literal_emit, .element = "text", .literal_text = meta.literal_text } };
    }
    cursor.* += 1;
    if (container) {
        inline for (reflection.fields(@FieldType(T, "children"))) |f|
            fill(Root, f.type, join(join(path, "children"), f.name), .{ .path = meta.path ++ "/" ++ f.name, .receiver = "opaque", .tokens = @typeName(f.type) }, C, entries, cursor);
        entries[cursor.*] = .{ .op = .{ .kind = .close } };
        cursor.* += 1;
    }
}
pub fn Schema(comptime T: type) type {
    return struct {
        pub const entries = blk: {
            @setEvalBranchQuota(1000000);
            var out: [count(T)]Entry = undefined;
            var cursor: usize = 0;
            fill(T, T, "", .{ .path = "view", .receiver = "root", .tokens = "" }, @TypeOf(.{}), &out, &cursor);
            for (&out, 0..) |*entry, i| if (entry.factory) |*factory| {
                for (out[0..i]) |previous| if (previous.factory) |p| {
                    if (p.hole.site == factory.hole.site and p.hole.token_fingerprint == factory.hole.token_fingerprint and std.mem.eql(u8, p.hole.type_name, factory.hole.type_name)) factory.hole.occurrence += 1;
                };
            };
            for (&out) |*entry| if (entry.factory) |factory| {
                entry.op.abi = fingerprint(factory.hole);
            };
            break :blk out;
        };
        pub const holes = blk: {
            const n = count_holes: {
                var total: usize = 0;
                for (entries) |entry| if (entry.factory != null) {
                    total += 1;
                };
                break :count_holes total;
            };
            var out: [n]Hole = undefined;
            var index: usize = 0;
            for (entries) |entry| if (entry.factory) |factory| {
                out[index] = factory.hole;
                index += 1;
            };
            break :blk out;
        };
        pub const instructions = blk: {
            var out: [entries.len]Instruction = undefined;
            for (entries, 0..) |entry, i| out[i] = entry.op;
            break :blk out;
        };
    };
}

pub fn fingerprint(hole: Hole) u64 {
    var hash = std.hash.Wyhash.init(hole.site);
    hash.update(hole.module);
    hash.update(hole.path);
    hash.update(hole.tokens);
    hash.update(hole.type_name);
    hash.update(hole.receiver.name);
    hash.update(hole.receiver.expected_type);
    hash.update(std.mem.asBytes(&hole.occurrence));
    for (hole.edges) |edge| {
        hash.update(edge.name);
        hash.update(edge.expected_type);
    }
    for (hole.captures) |capture| {
        hash.update(capture.name);
        hash.update(capture.type_name);
    }
    return hash.final();
}

/// Hashes accelerate validation but never authorize a preview edit by themselves.
pub fn holeEqual(a: Hole, b: Hole) bool {
    if (a.site != b.site or a.occurrence != b.occurrence or a.token_fingerprint != b.token_fingerprint or !std.mem.eql(u8, a.module, b.module) or !std.mem.eql(u8, a.path, b.path) or !std.mem.eql(u8, a.type_name, b.type_name) or !std.mem.eql(u8, a.tokens, b.tokens)) return false;
    if (!receiverEqual(a.receiver, b.receiver) or a.edges.len != b.edges.len or a.captures.len != b.captures.len) return false;
    for (a.edges, b.edges) |x, y| if (!receiverEqual(x, y)) return false;
    for (a.captures, b.captures) |x, y| if (x.id != y.id or !std.mem.eql(u8, x.name, y.name) or !std.mem.eql(u8, x.type_name, y.type_name)) return false;
    return true;
}
fn receiverEqual(a: Receiver, b: Receiver) bool {
    return a.ownership == b.ownership and a.evaluation == b.evaluation and std.mem.eql(u8, a.name, b.name) and std.mem.eql(u8, a.expected_type, b.expected_type);
}
pub fn matchHoles(a: std.mem.Allocator, before: []const Hole, after: []const Hole) ![]usize {
    if (before.len != after.len) return error.TemplateHoleChanged;
    const used = try a.alloc(bool, before.len);
    defer a.free(used);
    @memset(used, false);
    const mapping = try a.alloc(usize, after.len);
    errdefer a.free(mapping);
    for (after, 0..) |hole, index| {
        var match: ?usize = null;
        for (before, 0..) |candidate, bi| {
            if (used[bi] or !holeEqual(hole, candidate)) continue;
            if (match != null) return error.TemplateAmbiguousHole;
            match = bi;
        }
        const bi = match orelse return error.TemplateHoleChanged;
        used[bi] = true;
        mapping[index] = bi;
    }
    return mapping;
}

/// Validate the complete instruction stream before executing any factory. Missing,
/// duplicate, foreign or mis-typed bindings cannot partially build a view.
fn attributesEqual(a: []const Attribute, b: []const Attribute) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x.kind != y.kind or !std.mem.eql(u8, x.name, y.name) or !std.mem.eql(u8, x.tokens, y.tokens)) return false;
        if ((x.literal == null) != (y.literal == null)) return false;
        if (x.literal) |value| if (!value.eql(y.literal.?)) return false;
    }
    return true;
}

fn attributesCompatible(a: []const Attribute, b: []const Attribute) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x.kind != y.kind or !std.mem.eql(u8, x.name, y.name)) return false;
        if (x.kind == .style) continue;
        if (x.literal != null and y.literal != null) {
            if (std.meta.activeTag(x.literal.?) != std.meta.activeTag(y.literal.?)) return false;
        } else if (!attributesEqual(&.{x}, &.{y})) return false;
    }
    return true;
}

pub fn validate(comptime T: type, instructions: []const Instruction) !void {
    const entries = Schema(T).entries;
    var used: [entries.len]bool = @splat(false);
    var depth: usize = 0;
    var roots: usize = 0;
    if (instructions.len == 0) return error.TemplateEmpty;
    for (instructions) |op| {
        if (op.catalog_style != null and op.inline_style != null) return error.TemplateReceiverMismatch;
        if (op.catalog_style) |index| if (index >= catalogStyles(T).len) return error.TemplateReceiverMismatch;
        switch (op.kind) {
            .literal_open => {
                if (op.fragments.len != 0 or op.inline_style != null) return error.TemplateReceiverMismatch;
                if (op.catalog_style) |slot| if (!catalogBoxAllowed(T, slot)) return error.TemplateStyleReceiverMismatch;
                if (op.literal_text != null) return error.TemplateReceiverMismatch;
                for (op.attributes) |attribute| {
                    if (attribute.kind == .style and (op.container.style_slot != null or literalStyle(attribute.tokens) != null)) continue;
                    if (attribute.kind != .property or attribute.literal == null) return error.TemplateReceiverMismatch;
                }
                if (op.container.style_slot) |slot| {
                    if (slot >= entries.len or entries[slot].style_factory == null) return error.TemplateReceiverMismatch;
                }
                if (depth == 0) roots += 1;
                if (op.binding != 0 or op.abi != 0) return error.TemplateForeignHole;
                depth += 1;
                if (depth > max_depth) return error.TemplateTooDeep;
            },
            .literal_emit => {
                if (op.fragments.len != 0 or op.catalog_style != null or op.inline_style != null) return error.TemplateReceiverMismatch;
                if (!std.meta.eql(op.container, LiteralContainer{}) or op.attributes.len != 0) return error.TemplateReceiverMismatch;
                if (depth == 0) roots += 1;
                if (op.binding != 0 or op.abi != 0) return error.TemplateForeignHole;
                if (op.literal_text == null) return error.TemplateLiteralMissing;
            },
            .close => {
                if (op.fragments.len != 0 or op.catalog_style != null or op.inline_style != null) return error.TemplateReceiverMismatch;
                if (op.binding != 0 or op.abi != 0 or op.literal_text != null or op.attributes.len != 0 or !std.meta.eql(op.container, LiteralContainer{})) return error.TemplateReceiverMismatch;
                if (depth == 0) return error.TemplateUnbalanced;
                depth -= 1;
            },
            .open, .emit => {
                if (!std.meta.eql(op.container, LiteralContainer{})) return error.TemplateReceiverMismatch;
                if (depth == 0) roots += 1;
                if (op.binding >= entries.len) return error.TemplateForeignHole;
                const factory = entries[op.binding].factory orelse return error.TemplateForeignHole;
                if (op.relocate and !relocatableHole(factory.hole, op.attributes)) return error.TemplateChildRelocation;
                if (op.fragments.len != 0 and op.fragments.len != factory.fragment_count) return error.TemplateReceiverMismatch;
                if (op.inline_style != null and (!std.mem.eql(u8, op.element, "box") and !std.mem.eql(u8, op.element, "row") and !std.mem.eql(u8, op.element, "col"))) return error.TemplateReceiverMismatch;
                if (op.catalog_style) |slot| if (!factory.style_allowed(slot)) return error.TemplateStyleReceiverMismatch;
                if (factory.kind != op.kind or op.abi != fingerprint(factory.hole) or !std.mem.eql(u8, op.element, factory.hole.receiver.name)) return error.TemplateReceiverMismatch;
                if (!attributesCompatible(op.attributes, entries[op.binding].op.attributes)) return error.TemplateReceiverMismatch;
                if ((entries[op.binding].op.literal_text == null) != (op.literal_text == null)) return error.TemplateReceiverMismatch;
                if (used[op.binding]) return error.TemplateDuplicateHole;
                used[op.binding] = true;
                if (op.kind == .open) {
                    depth += 1;
                    if (depth > max_depth) return error.TemplateTooDeep;
                }
            },
        }
    }
    if (depth != 0) return error.TemplateUnbalanced;
    if (comptime has(T, "view_single")) if (T.view_single and roots != 1) return error.TemplateRootArity;
    for (entries, 0..) |entry, i| if (entry.factory != null and !used[i]) return error.TemplateMissingHole;
}

/// The same step routine drives both instantiations. Only iteration over the
/// static instruction stream is specialized; node/props/cleanup semantics match.
pub fn build(comptime mode: Mode, comptime T: type, instructions: []const Instruction, value: *const T, scope: *Scope, cx: *Cx, sink: v.Sink) !void {
    try validate(T, instructions);
    if (comptime mode == .comptime_template) {
        const original = Schema(T).instructions;
        if (instructions.len != original.len) return error.TemplateStaticMismatch;
        for (instructions, original) |a, b| {
            if (a.kind != b.kind or a.binding != b.binding or a.abi != b.abi) return error.TemplateStaticMismatch;
            if ((a.literal_text == null) != (b.literal_text == null)) return error.TemplateStaticMismatch;
            if (a.literal_text) |text| if (!std.mem.eql(u8, text, b.literal_text.?)) return error.TemplateStaticMismatch;
            if (!std.meta.eql(a.container, b.container)) return error.TemplateStaticMismatch;
        }
    }
    var state = Builder{ .sink = sink };
    if (comptime mode == .comptime_template) {
        inline for (Schema(T).instructions) |op| try state.step(T, value, scope, cx, op);
    } else {
        for (instructions) |op| try state.step(T, value, scope, cx, op);
    }
}
fn literalNode(scope: *Scope, cx: *Cx, sink: v.Sink, literal: LiteralContainer) !*Node {
    const props = .{ .test_id = literal.test_id, .visible = literal.visible, .focusable = literal.focusable, .hit_test = literal.hit_test };
    const decl = @import("style_decl.zig").StyleDecl(core.BoxStyle).fromBorrowed(&literal.style);
    if (decl.isEmpty()) return literalBox(scope, cx, sink, literal.layout, props);
    return literalBox(scope, cx, sink, literal.layout, .{ .test_id = literal.test_id, .visible = literal.visible, .focusable = literal.focusable, .hit_test = literal.hit_test, .style = literal.style });
}
fn literalBox(scope: *Scope, cx: *Cx, sink: v.Sink, layout: @FieldType(LiteralContainer, "layout"), props: anytype) !*Node {
    return switch (layout) {
        .box => v.box(props, .{}).viewShallow(scope, cx, sink),
        .row => v.row(props, .{}).viewShallow(scope, cx, sink),
        .col => v.col(props, .{}).viewShallow(scope, cx, sink),
    };
}

const Builder = struct {
    sink: v.Sink,
    stack: [max_depth]v.Sink = undefined,
    depth: usize = 0,
    inline fn step(self: *Builder, comptime T: type, value: *const T, scope: *Scope, cx: *Cx, op: Instruction) !void {
        switch (op.kind) {
            .literal_open => {
                var data = op.container;
                if (data.test_id) |id| if (comptime preview_enabled) {
                    data.test_id = try ownText(scope, id);
                    // A live runtime ID must not borrow the retiring descriptor.
                    std.debug.assert(id.len == 0 or data.test_id.?.ptr != id.ptr);
                };
                const node = if (op.catalog_style) |slot| blk: {
                    inline for (comptime catalogStyles(T), 0..) |style, i| if (slot == i) {
                        if (comptime literalCatalogCompatible(style.Style)) {
                            break :blk try literalBox(scope, cx, self.sink, data.layout, .{ .test_id = data.test_id, .visible = data.visible, .focusable = data.focusable, .hit_test = data.hit_test, .style = style.Style{} });
                        } else return error.TemplateStyleReceiverMismatch;
                    };
                    return error.TemplateReceiverMismatch;
                } else if (data.style_slot) |slot|
                    try Schema(T).entries[slot].style_factory.?.emit(scope, cx, self.sink, data)
                else
                    try literalNode(scope, cx, self.sink, data);
                self.stack[self.depth] = self.sink;
                self.depth += 1;
                self.sink = self.sink.child(node);
            },
            .literal_emit => try v.emit(scope, cx, self.sink, v.text(.{}, op.literal_text.?)),
            .close => {
                self.depth -= 1;
                self.sink = self.stack[self.depth];
            },
            .open, .emit => {
                const factory = Schema(T).entries[op.binding].factory.?;
                const node = try factory.emit(@ptrCast(value), scope, cx, self.sink, op);
                if (op.kind == .open) {
                    self.stack[self.depth] = self.sink;
                    self.depth += 1;
                    self.sink = self.sink.child(node.?);
                }
            },
        }
    }
};

test "LP3 template ABI rejects missing duplicate foreign and wrong receiver holes" {
    const t = std.testing;
    const TextProps = struct { test_id: []const u8 };
    const value = site(.{ .path = "test", .receiver = "col", .tokens = "col" }, .{}, v.col(.{}, .{
        site(.{ .path = "test", .receiver = "text", .tokens = "same", .literal_text = "a" }, .{}, v.text(TextProps{ .test_id = "a" }, "a")),
        site(.{ .path = "test", .receiver = "text", .tokens = "same", .literal_text = "b" }, .{}, v.text(TextProps{ .test_id = "b" }, "b")),
    }));
    const T = @TypeOf(value);
    const original = Schema(T).instructions;
    try validate(T, &original);
    try t.expectError(error.TemplateEmpty, validate(T, &.{}));
    try t.expectError(error.TemplateRootArity, validate(T, &.{ original[1], original[2] }));
    var unsupported = original;
    unsupported[3].literal_text = "ignored";
    try t.expectError(error.TemplateReceiverMismatch, validate(T, &unsupported));
    try t.expectEqual(@as(u32, 0), Schema(T).entries[1].factory.?.hole.occurrence);
    try t.expectEqual(@as(u32, 1), Schema(T).entries[2].factory.?.hole.occurrence);
    var changed = original;
    changed[2].binding = 1;
    changed[2].abi = original[1].abi;
    try t.expectError(error.TemplateDuplicateHole, validate(T, &changed));
    changed = original;
    changed[2].binding = 10000;
    try t.expectError(error.TemplateForeignHole, validate(T, &changed));
    changed = original;
    changed[2].binding = 1;
    try t.expectError(error.TemplateReceiverMismatch, validate(T, &changed));
    try t.expectError(error.TemplateMissingHole, validate(T, &.{ original[0], original[1], original[3] }));
    try t.expectError(error.TemplateUnbalanced, validate(T, original[1..]));
}

test "LP3 template runtime data drives text and both instantiations use the same builder" {
    const t = std.testing;
    const value = site(.{ .path = "test", .receiver = "col", .tokens = "col" }, .{}, v.col(.{}, .{
        site(.{ .path = "test", .receiver = "text", .tokens = "text", .literal_text = "original" }, .{}, v.text(.{ .test_id = "literal-factory" }, "original")),
    }));
    const T = @TypeOf(value);
    const cx = try Cx.init(t.allocator, t.io);
    defer cx.deinit();
    const scope = try Scope.init(t.allocator, null, cx.owner);
    defer scope.dispose();
    var ops = Schema(T).instructions;
    // Reverse literal mismatch must fail before even the preceding container
    // factory runs: no partial root, graph resources, or emitted nodes.
    ops[1].literal_text = null;
    var rejected: ?*Node = null;
    var rejected_stray: ?*Node = null;
    const before = cx.world.elements.count();
    try t.expectError(error.TemplateReceiverMismatch, build(.runtime_template, T, &ops, &value, scope, cx, v.Sink.capture(&rejected, &rejected_stray)));
    try t.expect(rejected == null and rejected_stray == null);
    try t.expectEqual(before, cx.world.elements.count());
    ops[1].literal_text = "runtime";
    var root: ?*Node = null;
    var stray: ?*Node = null;
    try t.expectError(error.TemplateStaticMismatch, build(.comptime_template, T, &ops, &value, scope, cx, v.Sink.capture(&root, &stray)));
    try t.expect(root == null and stray == null);
    try build(.runtime_template, T, &ops, &value, scope, cx, v.Sink.capture(&root, &stray));
    defer cx.freeNode(root.?);
    try t.expectEqualStrings("runtime", root.?.children.items[0].getText().?.content);
    var wrapped: [6]Instruction = undefined;
    wrapped[0] = .{ .kind = .literal_open, .container = .{ .layout = .row, .style = .{ .gap = 4 }, .test_id = "inserted", .visible = false, .focusable = true, .hit_test = false } };
    @memcpy(wrapped[1..4], &ops);
    wrapped[4] = .{ .kind = .literal_emit, .literal_text = "new sibling" };
    wrapped[5] = .{ .kind = .close };
    var extra: ?*Node = null;
    try build(.runtime_template, T, &wrapped, &value, scope, cx, v.Sink.capture(&extra, &stray));
    defer cx.freeNode(extra.?);
    try t.expectEqualStrings("inserted", extra.?.meta.ownership.meta.test_id.?);
    try t.expectEqual(core.Direction.row, extra.?.style.direction);
    try t.expectEqual(@as(f32, 4), extra.?.style.gap);
    try t.expectEqual(core.Display.none, extra.?.style.display);
    try t.expect(extra.?.behavior.interaction.focusable);
    try t.expect(!extra.?.frame_state.state_bits.flags.hit_test_visible);
    try t.expectEqualStrings("new sibling", extra.?.children.items[1].getText().?.content);
    try t.expectEqualStrings("runtime", extra.?.children.items[0].children.items[0].getText().?.content);
}

test "LP3 template ABI carries typed captures and receiver edges" {
    const t = std.testing;
    const cx = try Cx.init(t.allocator, t.io);
    defer cx.deinit();
    const scope = try Scope.init(t.allocator, null, cx.owner);
    defer scope.dispose();
    const signal = try scope.createSignal(i32, 9);
    const value = site(.{ .path = "C/view", .receiver = "box", .tokens = "onClick count += 1" }, .{ .count = signal }, v.box(.{ .on_click = @import("on.zig").set(signal, 10) }, .{}));
    const hole = Schema(@TypeOf(value)).holes[0];
    try t.expectEqualStrings("count", hole.captures[0].name);
    try t.expectEqualStrings(@typeName(@TypeOf(signal)), hole.captures[0].type_name);
    try t.expectEqualStrings("on_click", hole.edges[0].name);
    try t.expectEqualStrings(@typeName(core.HandlerRef), hole.edges[0].expected_type);
    try t.expectEqual(@as(u32, 0), hole.occurrence);
}

//! Incremental == full check (debug switch `ZENIT_VERIFY_INCREMENTAL=1`).
//!
//! The frame is rendered twice: once on the normal path (cross-frame subtree payload splice,
//! cache writes, paint-cursor resume) and once in reference mode (none of them), and the two
//! lowered paint streams are compared item by item. Frame-local identities are excluded: node /
//! surface ids, content versions, resource handles, blob byte ranges (the cache materializes
//! text, so its range is zero while a fresh run carries one). Text is compared by the resolved
//! bytes, spans by value, and pointer-backed payloads (path geometry, icon rep, polygon, glass
//! params) by pointee (nested pointers by presence). Floats compare with a small tolerance.
const std = @import("std");
const paint_table = @import("../paint_table.zig");
const types = @import("../types.zig");
const reflection = @import("zenit_reflection");
const property_tree = @import("../property_tree.zig");
const scene_runtime = @import("../scene_runtime.zig");

pub const Item = paint_table.DisplayItem;

pub const Mismatch = struct {
    index: usize,
    field: []const u8,
};

pub const Result = struct {
    /// Items that differ (a length difference counts every unmatched item).
    mismatches: usize = 0,
    first: ?Mismatch = null,
    lhs_len: usize = 0,
    rhs_len: usize = 0,
};

/// Deep-copies text bytes and spans so the snapshot survives the next renderNode (which clears
/// the text blob store the lowered items borrow from).
pub fn snapshot(allocator: std.mem.Allocator, items: []const Item) ![]Item {
    const out = try allocator.alloc(Item, items.len);
    for (items, 0..) |item, i| {
        out[i] = item;
        if (item.text_content.len > 0) out[i].text_content = try allocator.dupe(u8, item.text_content);
        if (item.text_spans) |spans| out[i].text_spans = try allocator.dupe(types.TextSpan, spans);
    }
    return out;
}

const skipped_fields = [_][]const u8{
    "resource_handle",
    "glass_owner_id",
    "surface_stable_id",
    "surface_content_version",
    "text_blob_byte_start",
    "text_blob_byte_end",
    // An identity, exact where this comparison tolerates 0.001: the incremental
    // and reference passes reach an item's transform by different products
    // (replay base inverse * world vs content), whose last bits may differ.
    // ZENIT_VERIFY_PAINT_DIGEST checks it against the items exactly.
    "paint_digest",
};

fn isSkipped(comptime name: []const u8) bool {
    @setEvalBranchQuota(100_000);
    inline for (skipped_fields) |s| {
        if (comptime std.mem.eql(u8, s, name)) return true;
    }
    return false;
}

pub fn eqlValue(comptime T: type, a: T, b: T) bool {
    switch (@typeInfo(T)) {
        .float => {
            if (std.math.isNan(a) and std.math.isNan(b)) return true;
            return @abs(a - b) <= 0.001;
        },
        .int, .bool, .@"enum" => return a == b,
        .array => |info| {
            for (a, b) |x, y| {
                if (!eqlValue(info.child, x, y)) return false;
            }
            return true;
        },
        .@"struct" => {
            inline for (reflection.fields(T)) |f| {
                if (!eqlValue(@FieldType(T, f.name), @field(a, f.name), @field(b, f.name))) return false;
            }
            return true;
        },
        .optional => |info| {
            if (a == null or b == null) return (a == null) == (b == null);
            return switch (@typeInfo(info.child)) {
                .pointer => |p| if (p.size == .slice)
                    eqlSlice(info.child, a.?, b.?)
                else if (@typeInfo(p.child) == .@"struct")
                    // Lowering duplicates these payloads into the frame arena: compare pointees.
                    eqlValue(p.child, a.?.*, b.?.*)
                else
                    true,
                else => eqlValue(info.child, a.?, b.?),
            };
        },
        .pointer => |p| {
            if (p.size == .slice) return eqlSlice(T, a, b);
            return true;
        },
        else => return std.mem.eql(u8, std.mem.asBytes(&a), std.mem.asBytes(&b)),
    }
}

fn eqlSlice(comptime S: type, a: S, b: S) bool {
    const Child = @typeInfo(S).pointer.child;
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!eqlValue(Child, x, y)) return false;
    }
    return true;
}

/// Name of the first differing field, null when the items are equivalent.
pub fn firstDifference(a: Item, b: Item) ?[]const u8 {
    @setEvalBranchQuota(100_000);
    inline for (reflection.fields(Item)) |f| {
        if (comptime isSkipped(f.name)) continue;
        if (!eqlValue(@FieldType(Item, f.name), @field(a, f.name), @field(b, f.name))) return f.name;
    }
    return null;
}

pub fn compare(lhs: []const Item, rhs: []const Item) Result {
    var result: Result = .{ .lhs_len = lhs.len, .rhs_len = rhs.len };
    const n = @min(lhs.len, rhs.len);
    for (0..n) |i| {
        if (firstDifference(lhs[i], rhs[i])) |field| {
            result.mismatches += 1;
            if (result.first == null) result.first = .{ .index = i, .field = field };
        }
    }
    const extra = @max(lhs.len, rhs.len) - n;
    if (extra > 0) {
        result.mismatches += extra;
        if (result.first == null) result.first = .{ .index = n, .field = "<length>" };
    }
    return result;
}

test "incremental verify ignores frame-local ids and compares text by bytes" {
    var a: Item = .{ .kind = .text, .text_content = "hello", .resource_handle = 7, .glass_owner_id = 3 };
    var b: Item = .{ .kind = .text, .text_content = "hello", .resource_handle = 9, .glass_owner_id = 4, .text_blob_byte_end = 5 };
    try std.testing.expect(firstDifference(a, b) == null);
    b.text_content = "hellp";
    try std.testing.expectEqualStrings("text_content", firstDifference(a, b).?);
    b.text_content = "hello";
    a.geom.x = 10;
    try std.testing.expectEqualStrings("geom", firstDifference(a, b).?);
    const r = compare(&.{a}, &.{ b, b });
    try std.testing.expectEqual(@as(usize, 2), r.mismatches);
}

/// Retained-build output of one frame: the property trees and the scene records' fields that
/// buildRetainedSubtree writes (later passes fill in the rest). The incremental pass may replay
/// it from retained subtree memos; the reference pass always recomputes it.
pub const RetainedSnapshot = struct {
    transforms: []const property_tree.TransformNode,
    clips: []const property_tree.ClipNode,
    effects: []const property_tree.EffectNode,
    records: []const RetainedRecord,
};

pub const RetainedRecord = struct {
    node_id: u32,
    local_rect: types.ComputedRect,
    world_bounds: types.ComputedRect,
    content_transform: types.Transform2D,
    content_bounds: types.ComputedRect,
    transform_id: u32,
    clip_id: u32,
    clip_bounds_fallback: bool,
    effect_id: u32,
    paint_order: u64,
    content_version: u32,
    composite_version: u32,
    content_flags: scene_runtime.ContentFlags,
    is_overlay_candidate: bool,
    has_active_composite_animation: bool,
    has_active_transform_animation: bool,
    has_active_opacity_animation: bool,
    will_change_transform: bool,
    will_change_opacity: bool,
    // Not compared: has_promoted_surface_cache / promoted_surface_*. They mirror the node's
    // promoted command cache, which the incremental pass writes or drops after its retained build,
    // so the reference pass reads a different cache state (the memo re-reads them on replay).
};

pub fn snapshotRetained(
    allocator: std.mem.Allocator,
    pt: *const property_tree.PropertyTree,
    sr: *const scene_runtime.SceneRuntime,
) !RetainedSnapshot {
    const records = try allocator.alloc(RetainedRecord, sr.nodes.count());
    var it = sr.nodes.iterator();
    var i: usize = 0;
    while (it.next()) |e| : (i += 1) {
        const r = e.value_ptr.*;
        var out: RetainedRecord = undefined;
        inline for (reflection.fields(RetainedRecord)) |f| @field(out, f.name) = @field(r, f.name);
        records[i] = out;
    }
    std.mem.sort(RetainedRecord, records, {}, struct {
        fn lt(_: void, a: RetainedRecord, b: RetainedRecord) bool {
            return a.node_id < b.node_id;
        }
    }.lt);
    return .{
        .transforms = try allocator.dupe(property_tree.TransformNode, pt.transforms.items),
        .clips = try allocator.dupe(property_tree.ClipNode, pt.clips.items),
        .effects = try allocator.dupe(property_tree.EffectNode, pt.effects.items),
        .records = records,
    };
}

pub const RetainedDiff = struct {
    mismatches: usize = 0,
    /// "transforms" / "clips" / "effects" / "records", the index and field of the first difference.
    first_table: []const u8 = "",
    first_index: usize = 0,
    first_field: []const u8 = "",
    /// Scene record: node id of the first differing record.
    first_node: u32 = 0,
};

fn firstFieldDiff(comptime T: type, a: T, b: T) []const u8 {
    @setEvalBranchQuota(100_000);
    inline for (reflection.fields(T)) |f| {
        if (!eqlValue(@FieldType(T, f.name), @field(a, f.name), @field(b, f.name))) return f.name;
    }
    return "<length>";
}

fn diffSlices(comptime T: type, name: []const u8, a: []const T, b: []const T, out: *RetainedDiff) void {
    const n = @min(a.len, b.len);
    for (0..n) |i| {
        if (!eqlValue(T, a[i], b[i])) {
            if (out.mismatches == 0) {
                out.first_table = name;
                out.first_index = i;
                out.first_field = firstFieldDiff(T, a[i], b[i]);
                if (T == RetainedRecord) out.first_node = a[i].node_id;
            }
            out.mismatches += 1;
        }
    }
    const extra = @max(a.len, b.len) - n;
    if (extra > 0) {
        if (out.mismatches == 0) {
            out.first_table = name;
            out.first_index = n;
        }
        out.mismatches += extra;
    }
}

pub fn compareRetained(a: RetainedSnapshot, b: RetainedSnapshot) RetainedDiff {
    var out: RetainedDiff = .{};
    diffSlices(property_tree.TransformNode, "transforms", a.transforms, b.transforms, &out);
    diffSlices(property_tree.ClipNode, "clips", a.clips, b.clips, &out);
    diffSlices(property_tree.EffectNode, "effects", a.effects, b.effects, &out);
    diffSlices(RetainedRecord, "records", a.records, b.records, &out);
    return out;
}

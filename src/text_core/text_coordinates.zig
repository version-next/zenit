//! Typed coordinate domains and the pure VisualLine caret/selection contract.
//! This is a sidecar until shaping/layout consumers migrate to it.

const std = @import("std");
const grapheme = @import("grapheme.zig");

pub const ByteOffset = struct {
    value: usize,
    pub fn init(value: usize) ByteOffset {
        return .{ .value = value };
    }
};

pub const GraphemeIndex = struct { value: usize };
pub const LineIndex = struct { value: usize };
pub const LineX = struct { value: f32 };
pub const LocalPoint = struct { x: f32, y: f32 };
pub const WorldPoint = struct { x: f32, y: f32 };
pub const DevicePoint = struct { x: i32, y: i32 };

pub const Affinity = enum { upstream, downstream };
pub const Direction = enum { ltr, rtl };
pub const BoundaryBias = enum { backward, forward, nearest };

pub const TextPosition = struct {
    byte: ByteOffset,
    affinity: Affinity = .downstream,
};

pub const CaretStop = struct {
    position: TextPosition,
    x: LineX,
    strong_direction: Direction,
};

pub const SelectionRect = struct {
    x: f32,
    width: f32,
};

pub const VisualLine = struct {
    source_start: ByteOffset,
    source_end: ByteOffset,
    caret_stops: []const CaretStop,
    width: f32 = 0,
    ascent: f32 = 0,
    descent: f32 = 0,
    leading: f32 = 0,
    base_direction: Direction = .ltr,

    pub fn validate(self: VisualLine, source: []const u8) !void {
        if (self.source_start.value > self.source_end.value or self.source_end.value > source.len)
            return error.InvalidSourceRange;
        if (self.caret_stops.len == 0) return error.MissingCaretStops;

        var previous_x = -std.math.floatMax(f32);
        for (self.caret_stops) |stop| {
            const byte = stop.position.byte.value;
            if (!std.math.isFinite(stop.x.value) or stop.x.value < previous_x)
                return error.NonMonotonicVisualCaret;
            if (byte < self.source_start.value or byte > self.source_end.value)
                return error.CaretOutsideLine;
            if (!isGraphemeBoundary(source, byte)) return error.CaretSplitsGrapheme;
            previous_x = stop.x.value;
        }
    }

    pub fn positionToCaret(self: VisualLine, position: TextPosition) !CaretStop {
        for (self.caret_stops) |stop| {
            if (stop.position.byte.value == position.byte.value and stop.position.affinity == position.affinity)
                return stop;
        }
        return error.PositionNotOnLine;
    }

    pub fn xToPosition(self: VisualLine, x: LineX) TextPosition {
        var best = self.caret_stops[0];
        var best_distance = @abs(x.value - best.x.value);
        for (self.caret_stops[1..]) |stop| {
            const distance = @abs(x.value - stop.x.value);
            if (distance < best_distance or
                (distance == best_distance and stop.position.affinity == .downstream))
            {
                best = stop;
                best_distance = distance;
            }
        }
        return best.position;
    }

    /// Convert a logical byte selection to one or more visual x segments.
    /// The caller owns storage; mixed bidi may return disjoint rectangles.
    pub fn selectionRects(
        self: VisualLine,
        logical_start: ByteOffset,
        logical_end: ByteOffset,
        output: []SelectionRect,
    ) ![]SelectionRect {
        const lo = @min(logical_start.value, logical_end.value);
        const hi = @max(logical_start.value, logical_end.value);
        if (lo == hi or self.caret_stops.len < 2) return output[0..0];

        var count: usize = 0;
        for (self.caret_stops[0 .. self.caret_stops.len - 1], self.caret_stops[1..]) |left, right| {
            const seg_lo = @min(left.position.byte.value, right.position.byte.value);
            const seg_hi = @max(left.position.byte.value, right.position.byte.value);
            if (seg_hi <= lo or seg_lo >= hi or seg_lo == seg_hi) continue;
            const x0 = @min(left.x.value, right.x.value);
            const x1 = @max(left.x.value, right.x.value);
            if (count > 0 and output[count - 1].x + output[count - 1].width == x0) {
                output[count - 1].width = x1 - output[count - 1].x;
            } else {
                if (count >= output.len) return error.BufferTooSmall;
                output[count] = .{ .x = x0, .width = x1 - x0 };
                count += 1;
            }
        }
        return output[0..count];
    }
};

/// Caller-owned immutable VisualLine sidecar. The source text remains borrowed;
/// only caret geometry is allocated here.
pub const OwnedVisualLine = struct {
    allocator: std.mem.Allocator,
    value: VisualLine,

    pub fn deinit(self: *OwnedVisualLine) void {
        self.allocator.free(self.value.caret_stops);
        self.* = undefined;
    }
};

pub fn isGraphemeBoundary(text: []const u8, byte: usize) bool {
    if (byte > text.len) return false;
    if (byte == 0 or byte == text.len) return true;
    const previous = grapheme.prevBoundary(text, byte);
    return grapheme.nextBoundary(text, previous) == byte;
}

/// Clamp an arbitrary byte offset into the source domain and onto an extended
/// grapheme boundary. Editing consumers use this at all native/event ingress
/// points so a cursor, IME offset, or deletion endpoint cannot split a user-
/// perceived character.
pub fn clampByteOffset(text: []const u8, offset: ByteOffset, bias: BoundaryBias) ByteOffset {
    const byte = @min(offset.value, text.len);
    if (isGraphemeBoundary(text, byte)) return .{ .value = byte };
    const before = grapheme.prevBoundary(text, byte);
    const after = grapheme.nextBoundary(text, before);
    return .{ .value = switch (bias) {
        .backward => before,
        .forward => after,
        .nearest => if (byte - before < after - byte) before else after,
    } };
}

/// Largest prefix no longer than `max_bytes` that ends at a grapheme boundary.
/// This is stricter than UTF-8 scalar truncation: it keeps ZWJ emoji, combining
/// sequences, flags, and CRLF intact.
pub fn truncateToGraphemeBoundary(text: []const u8, max_bytes: usize) usize {
    if (text.len <= max_bytes) return text.len;
    return clampByteOffset(text, .{ .value = max_bytes }, .backward).value;
}

test "typed positions reject a caret inside a grapheme" {
    const testing = std.testing;
    const text = "e\u{301}x";
    const stops = [_]CaretStop{
        .{ .position = .{ .byte = .{ .value = 0 } }, .x = .{ .value = 0 }, .strong_direction = .ltr },
        .{ .position = .{ .byte = .{ .value = 1 } }, .x = .{ .value = 5 }, .strong_direction = .ltr },
        .{ .position = .{ .byte = .{ .value = 4 } }, .x = .{ .value = 10 }, .strong_direction = .ltr },
    };
    const line = VisualLine{ .source_start = .{ .value = 0 }, .source_end = .{ .value = text.len }, .caret_stops = &stops };
    try testing.expectError(error.CaretSplitsGrapheme, line.validate(text));
}

test "boundary clamp and truncation preserve extended graphemes" {
    const testing = std.testing;
    const text = "A👩‍💻e\u{301}B";
    const emoji_start = 1;
    const emoji_end = grapheme.nextBoundary(text, emoji_start);
    try testing.expect(emoji_end > emoji_start + 1);
    try testing.expectEqual(emoji_start, clampByteOffset(text, .{ .value = emoji_start + 2 }, .backward).value);
    try testing.expectEqual(emoji_end, clampByteOffset(text, .{ .value = emoji_start + 2 }, .forward).value);
    try testing.expectEqual(emoji_start, truncateToGraphemeBoundary(text, emoji_end - 1));
    try testing.expectEqual(text.len, truncateToGraphemeBoundary(text, text.len));
}

test "VisualLine permits visual-x monotonic and logical-byte nonmonotonic bidi stops" {
    const testing = std.testing;
    const text = "abc \u{5D0}\u{5D1}\u{5D2}";
    const stops = [_]CaretStop{
        .{ .position = .{ .byte = .{ .value = 0 } }, .x = .{ .value = 0 }, .strong_direction = .ltr },
        .{ .position = .{ .byte = .{ .value = 1 } }, .x = .{ .value = 10 }, .strong_direction = .ltr },
        .{ .position = .{ .byte = .{ .value = 2 } }, .x = .{ .value = 20 }, .strong_direction = .ltr },
        .{ .position = .{ .byte = .{ .value = 3 } }, .x = .{ .value = 30 }, .strong_direction = .ltr },
        .{ .position = .{ .byte = .{ .value = 4 }, .affinity = .upstream }, .x = .{ .value = 40 }, .strong_direction = .rtl },
        .{ .position = .{ .byte = .{ .value = 10 } }, .x = .{ .value = 40 }, .strong_direction = .rtl },
        .{ .position = .{ .byte = .{ .value = 8 } }, .x = .{ .value = 50 }, .strong_direction = .rtl },
        .{ .position = .{ .byte = .{ .value = 6 } }, .x = .{ .value = 60 }, .strong_direction = .rtl },
        .{ .position = .{ .byte = .{ .value = 4 } }, .x = .{ .value = 70 }, .strong_direction = .rtl },
    };
    const line = VisualLine{ .source_start = .{ .value = 0 }, .source_end = .{ .value = text.len }, .caret_stops = &stops };
    try line.validate(text);
    try testing.expectEqual(@as(usize, 8), line.xToPosition(.{ .value = 51 }).byte.value);
    try testing.expectEqual(@as(f32, 40), (try line.positionToCaret(.{ .byte = .{ .value = 4 }, .affinity = .upstream })).x.value);
    try testing.expectEqual(@as(f32, 70), (try line.positionToCaret(.{ .byte = .{ .value = 4 }, .affinity = .downstream })).x.value);

    var rect_storage: [4]SelectionRect = undefined;
    const rects = try line.selectionRects(.{ .value = 6 }, .{ .value = 10 }, &rect_storage);
    try testing.expectEqual(@as(usize, 1), rects.len);
    try testing.expectEqual(@as(f32, 40), rects[0].x);
    try testing.expectEqual(@as(f32, 20), rects[0].width);
}

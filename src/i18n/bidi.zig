//! Unicode Bidirectional Algorithm (UAX #9, Unicode 17.0.0).
//!
//! This module is the platform-independent authority for bidi properties,
//! embedding levels, per-line visual order, and logical/visual mappings.  On
//! macOS CoreText remains the shaping authority: callers must not reorder an
//! already-shaped CTLine a second time.  The pure implementation is used for
//! deterministic conformance, non-CoreText backends, and coordinate contracts.

const std = @import("std");
const data = @import("bidi_data_generated.zig");

pub const unicode_version = data.unicode_version;
pub const BidiClass = data.BidiClass;
pub const BracketType = data.BracketType;
pub const Direction = enum(u1) { ltr, rtl };
pub const removed_level: u8 = std.math.maxInt(u8);
pub const max_explicit_depth: u8 = 125;

/// A logical source run with one resolved embedding level.  Byte ranges are
/// half-open UTF-8 ranges.  The parity of `level` is the run direction.
pub const Run = struct {
    start: u32,
    end: u32,
    direction: Direction,
    level: u8 = 0,
};

pub const ParagraphRange = struct {
    start: u32,
    end: u32,
    level: u8,
};

/// Owned result for one or more UAX #9 paragraphs.
///
/// `resolved_levels` are the post-I1/I2 paragraph levels. `levels` additionally
/// has L1 applied as if every paragraph were one line. Use `reorderLine` when a
/// paragraph has been wrapped: UAX #9 requires L1/L2 after line breaking.
pub const ResolvedText = struct {
    allocator: std.mem.Allocator,
    codepoints: []u21,
    byte_offsets: []u32,
    original_types: []BidiClass,
    resolved_levels: []u8,
    levels: []u8,
    paragraphs: []ParagraphRange,
    visual_to_logical: []u32,
    logical_to_visual: []u32,

    pub fn deinit(self: *ResolvedText) void {
        self.allocator.free(self.codepoints);
        self.allocator.free(self.byte_offsets);
        self.allocator.free(self.original_types);
        self.allocator.free(self.resolved_levels);
        self.allocator.free(self.levels);
        self.allocator.free(self.paragraphs);
        self.allocator.free(self.visual_to_logical);
        self.allocator.free(self.logical_to_visual);
        self.* = undefined;
    }

    pub fn visualIndex(self: ResolvedText, logical_index: usize) ?usize {
        if (logical_index >= self.logical_to_visual.len) return null;
        const index = self.logical_to_visual[logical_index];
        return if (index == std.math.maxInt(u32)) null else index;
    }

    pub fn logicalIndex(self: ResolvedText, visual_index: usize) ?usize {
        if (visual_index >= self.visual_to_logical.len) return null;
        return self.visual_to_logical[visual_index];
    }

    /// Resolve one already-wrapped line. `start` and `end` are codepoint indices
    /// within `paragraph_index`; `levels_out` needs `end-start` entries and
    /// `order_out` needs space for every non-X9 character in the line.
    pub fn reorderLine(
        self: ResolvedText,
        paragraph_index: usize,
        start: usize,
        end: usize,
        levels_out: []u8,
        order_out: []u32,
    ) !LineOrder {
        if (paragraph_index >= self.paragraphs.len) return error.InvalidParagraph;
        const paragraph = self.paragraphs[paragraph_index];
        if (start < paragraph.start or end > paragraph.end or start > end)
            return error.InvalidLineRange;
        if (levels_out.len < end - start) return error.LevelBufferTooSmall;

        @memcpy(levels_out[0 .. end - start], self.resolved_levels[start..end]);
        applyL1(
            self.original_types,
            paragraph.level,
            start,
            end,
            levels_out[0 .. end - start],
            start,
        );

        var count: usize = 0;
        for (start..end) |logical| {
            if (levels_out[logical - start] == removed_level) continue;
            if (count >= order_out.len) return error.OrderBufferTooSmall;
            order_out[count] = @intCast(logical);
            count += 1;
        }
        reorderByLevels(order_out[0..count], levels_out[0 .. end - start], start);
        return .{ .levels = levels_out[0 .. end - start], .visual_to_logical = order_out[0..count] };
    }
};

pub const LineOrder = struct {
    levels: []const u8,
    visual_to_logical: []const u32,
};

pub fn classify(cp: u32) BidiClass {
    if (cp > 0x10FFFF) return .l;
    return data.classify(@intCast(cp));
}

pub fn bracket(cp: u32) ?data.BracketInfo {
    if (cp > 0x10FFFF) return null;
    return data.bracket(@intCast(cp));
}

/// Character-based L4 fallback. Real shaping should prefer the font's mirrored
/// glyph when one exists; not every mirrored glyph has a Unicode counterpart.
pub fn mirroredCodepoint(cp: u32, level: u8) ?u21 {
    if (level & 1 == 0 or cp > 0x10FFFF) return null;
    return data.mirrored(@intCast(cp));
}

pub fn detectParagraphDirection(text: []const u8) Direction {
    return detectParagraphDirectionStrict(text) catch .ltr;
}

pub fn detectParagraphDirectionStrict(text: []const u8) !Direction {
    if (text.len > std.math.maxInt(u32)) return error.TextTooLong;
    const view = std.unicode.Utf8View.init(text) catch return error.InvalidUtf8;
    var iterator = view.iterator();
    var isolate_depth: usize = 0;
    while (iterator.nextCodepoint()) |cp| {
        const kind = data.classify(cp);
        if (kind == .b) break;
        if (isIsolateInitiator(kind)) {
            isolate_depth +|= 1;
            continue;
        }
        if (kind == .pdi) {
            isolate_depth -|= 1;
            continue;
        }
        if (isolate_depth != 0) continue;
        switch (kind) {
            .l => return .ltr,
            .r, .al => return .rtl,
            else => {},
        }
    }
    return .ltr;
}

/// Resolve UTF-8 text. Invalid UTF-8 is rejected before allocation proportional
/// to scalar count; byte offsets remain stable for logical/visual conversion.
pub fn resolve(
    allocator: std.mem.Allocator,
    text: []const u8,
    paragraph_direction: ?Direction,
) !ResolvedText {
    if (text.len > std.math.maxInt(u32)) return error.TextTooLong;
    var decoded = try decodeUtf8(allocator, text);
    errdefer decoded.deinit(allocator);
    return resolveOwned(
        allocator,
        decoded.codepoints,
        decoded.byte_offsets,
        decoded.types,
        paragraph_direction,
    );
}

/// Conformance entry point for BidiTest.txt, whose input is a sequence of bidi
/// classes rather than Unicode scalars. Codepoints are deliberately zero, so N0
/// finds no bracket pairs (the official BidiTest contract excludes them).
pub fn resolveClasses(
    allocator: std.mem.Allocator,
    classes: []const BidiClass,
    paragraph_direction: ?Direction,
) !ResolvedText {
    if (classes.len > std.math.maxInt(u32)) return error.TextTooLong;
    const codepoints = try allocator.alloc(u21, classes.len);
    errdefer allocator.free(codepoints);
    @memset(codepoints, 0);
    const byte_offsets = try allocator.alloc(u32, classes.len + 1);
    errdefer allocator.free(byte_offsets);
    for (byte_offsets, 0..) |*offset, index| offset.* = @intCast(index);
    const types = try allocator.dupe(BidiClass, classes);
    errdefer allocator.free(types);
    return resolveOwned(allocator, codepoints, byte_offsets, types, paragraph_direction);
}

/// Character-level conformance entry point. Offsets in the returned object are
/// scalar indices (not UTF-8 byte offsets); production callers should use
/// `resolve`, which preserves real storage offsets.
pub fn resolveCodepointsForConformance(
    allocator: std.mem.Allocator,
    input: []const u21,
    paragraph_direction: ?Direction,
) !ResolvedText {
    if (input.len > std.math.maxInt(u32)) return error.TextTooLong;
    const codepoints = try allocator.dupe(u21, input);
    errdefer allocator.free(codepoints);
    const byte_offsets = try allocator.alloc(u32, input.len + 1);
    errdefer allocator.free(byte_offsets);
    for (byte_offsets, 0..) |*offset, index| offset.* = @intCast(index);
    const types = try allocator.alloc(BidiClass, input.len);
    errdefer allocator.free(types);
    for (input, types) |cp, *kind| {
        if (cp > 0x10FFFF) return error.InvalidCodepoint;
        kind.* = data.classify(cp);
    }
    return resolveOwned(allocator, codepoints, byte_offsets, types, paragraph_direction);
}

/// Compatibility API: append logical runs, now backed by the complete UBA
/// rather than nearest-strong heuristics.
pub fn splitRuns(
    text: []const u8,
    paragraph_dir: Direction,
    out_runs: *std.ArrayListUnmanaged(Run),
    allocator: std.mem.Allocator,
) !void {
    var resolved = try resolve(allocator, text, paragraph_dir);
    defer resolved.deinit();
    if (resolved.codepoints.len == 0) return;

    for (resolved.paragraphs) |paragraph| {
        const paragraph_start: usize = paragraph.start;
        const paragraph_end: usize = paragraph.end;
        if (paragraph_start == paragraph_end) continue;
        var start_index = paragraph_start;
        var current_level = effectiveLevel(resolved, start_index);
        for (paragraph_start + 1..paragraph_end) |index| {
            const level = effectiveLevel(resolved, index);
            if (level == current_level) continue;
            try out_runs.append(allocator, runForRange(resolved, start_index, index, current_level));
            start_index = index;
            current_level = level;
        }
        try out_runs.append(allocator, runForRange(resolved, start_index, paragraph_end, current_level));
    }
}

fn effectiveLevel(resolved: ResolvedText, index: usize) u8 {
    if (resolved.levels[index] != removed_level) return resolved.levels[index];
    var paragraph_start: usize = 0;
    var paragraph_level: u8 = 0;
    for (resolved.paragraphs) |paragraph| {
        if (index >= paragraph.start and index < paragraph.end) {
            paragraph_start = paragraph.start;
            paragraph_level = paragraph.level;
            break;
        }
    }
    var previous = index;
    while (previous > paragraph_start) {
        previous -= 1;
        if (resolved.levels[previous] != removed_level) return resolved.levels[previous];
    }
    return paragraph_level;
}

fn runForRange(resolved: ResolvedText, start: usize, end: usize, level: u8) Run {
    return .{
        .start = resolved.byte_offsets[start],
        .end = resolved.byte_offsets[end],
        .direction = directionForLevel(level),
        .level = level,
    };
}

fn directionForLevel(level: u8) Direction {
    return if (level & 1 == 0) .ltr else .rtl;
}

const Decoded = struct {
    codepoints: []u21,
    byte_offsets: []u32,
    types: []BidiClass,

    fn deinit(self: *Decoded, allocator: std.mem.Allocator) void {
        allocator.free(self.codepoints);
        allocator.free(self.byte_offsets);
        allocator.free(self.types);
        self.* = undefined;
    }
};

fn decodeUtf8(allocator: std.mem.Allocator, text: []const u8) !Decoded {
    const view = std.unicode.Utf8View.init(text) catch return error.InvalidUtf8;
    var count: usize = 0;
    var counter = view.iterator();
    while (counter.nextCodepoint() != null) count += 1;

    const codepoints = try allocator.alloc(u21, count);
    errdefer allocator.free(codepoints);
    const byte_offsets = try allocator.alloc(u32, count + 1);
    errdefer allocator.free(byte_offsets);
    const types = try allocator.alloc(BidiClass, count);
    errdefer allocator.free(types);

    var iterator = view.iterator();
    var byte: u32 = 0;
    var index: usize = 0;
    while (iterator.nextCodepoint()) |cp| : (index += 1) {
        codepoints[index] = cp;
        byte_offsets[index] = byte;
        types[index] = data.classify(cp);
        byte += std.unicode.utf8CodepointSequenceLength(cp) catch unreachable;
    }
    byte_offsets[count] = byte;
    return .{ .codepoints = codepoints, .byte_offsets = byte_offsets, .types = types };
}

fn resolveOwned(
    allocator: std.mem.Allocator,
    codepoints: []u21,
    byte_offsets: []u32,
    original_types: []BidiClass,
    paragraph_direction: ?Direction,
) !ResolvedText {
    const count = original_types.len;
    const resolved_levels = try allocator.alloc(u8, count);
    errdefer allocator.free(resolved_levels);
    @memset(resolved_levels, 0);
    const mutable_types = try allocator.dupe(BidiClass, original_types);
    defer allocator.free(mutable_types);
    const matching_pdi = try allocator.alloc(u32, count);
    defer allocator.free(matching_pdi);
    @memset(matching_pdi, std.math.maxInt(u32));
    const matching_stack = try allocator.alloc(u32, count);
    defer allocator.free(matching_stack);

    var paragraph_list: std.ArrayListUnmanaged(ParagraphRange) = .{};
    defer paragraph_list.deinit(allocator);
    var paragraph_start: usize = 0;
    for (original_types, 0..) |kind, index| {
        if (kind != .b) continue;
        const end = index + 1;
        buildMatchingPdi(original_types, paragraph_start, end, matching_pdi, matching_stack);
        const level = paragraphLevel(
            original_types,
            matching_pdi,
            paragraph_start,
            end,
            paragraph_direction,
        );
        try paragraph_list.append(allocator, .{
            .start = @intCast(paragraph_start),
            .end = @intCast(end),
            .level = level,
        });
        paragraph_start = end;
    }
    if (paragraph_start < count or paragraph_list.items.len == 0) {
        buildMatchingPdi(original_types, paragraph_start, count, matching_pdi, matching_stack);
        const level = paragraphLevel(
            original_types,
            matching_pdi,
            paragraph_start,
            count,
            paragraph_direction,
        );
        try paragraph_list.append(allocator, .{
            .start = @intCast(paragraph_start),
            .end = @intCast(count),
            .level = level,
        });
    }

    for (paragraph_list.items) |paragraph| {
        try resolveParagraph(
            allocator,
            codepoints,
            original_types,
            mutable_types,
            matching_pdi,
            resolved_levels,
            paragraph,
        );
    }

    const levels = try allocator.dupe(u8, resolved_levels);
    errdefer allocator.free(levels);
    var visible_count: usize = 0;
    for (resolved_levels) |level| if (level != removed_level) {
        visible_count += 1;
    };
    const visual_to_logical = try allocator.alloc(u32, visible_count);
    errdefer allocator.free(visual_to_logical);
    const logical_to_visual = try allocator.alloc(u32, count);
    errdefer allocator.free(logical_to_visual);
    @memset(logical_to_visual, std.math.maxInt(u32));

    var visual_offset: usize = 0;
    for (paragraph_list.items) |paragraph| {
        applyL1(
            original_types,
            paragraph.level,
            paragraph.start,
            paragraph.end,
            levels[paragraph.start..paragraph.end],
            paragraph.start,
        );
        const order_start = visual_offset;
        for (paragraph.start..paragraph.end) |logical| {
            if (levels[logical] == removed_level) continue;
            visual_to_logical[visual_offset] = @intCast(logical);
            visual_offset += 1;
        }
        reorderByLevels(
            visual_to_logical[order_start..visual_offset],
            levels[paragraph.start..paragraph.end],
            paragraph.start,
        );
    }
    for (visual_to_logical, 0..) |logical, visual| {
        logical_to_visual[logical] = @intCast(visual);
    }

    const paragraphs = try allocator.dupe(ParagraphRange, paragraph_list.items);
    errdefer allocator.free(paragraphs);
    return .{
        .allocator = allocator,
        .codepoints = codepoints,
        .byte_offsets = byte_offsets,
        .original_types = original_types,
        .resolved_levels = resolved_levels,
        .levels = levels,
        .paragraphs = paragraphs,
        .visual_to_logical = visual_to_logical,
        .logical_to_visual = logical_to_visual,
    };
}

fn buildMatchingPdi(
    types: []const BidiClass,
    start: usize,
    end: usize,
    output: []u32,
    stack: []u32,
) void {
    if (start >= end) return;
    @memset(output[start..end], std.math.maxInt(u32));
    // Matching is independent of the explicit-depth limit (BD9).
    var stack_len: usize = 0;
    for (start..end) |index| {
        if (isIsolateInitiator(types[index])) {
            stack[stack_len] = @intCast(index);
            stack_len += 1;
        } else if (types[index] == .pdi and stack_len > 0) {
            stack_len -= 1;
            const initiator = stack[stack_len];
            output[initiator] = @intCast(index);
        }
    }
}

fn paragraphLevel(
    types: []const BidiClass,
    matching_pdi: []const u32,
    start: usize,
    end: usize,
    forced: ?Direction,
) u8 {
    if (forced) |direction| return if (direction == .ltr) 0 else 1;
    var index = start;
    while (index < end) {
        const kind = types[index];
        if (isIsolateInitiator(kind)) {
            const match = matching_pdi[index];
            if (match == std.math.maxInt(u32) or match >= end) return 0;
            index = match + 1;
            continue;
        }
        switch (kind) {
            .l => return 0,
            .r, .al => return 1,
            else => {},
        }
        index += 1;
    }
    return 0;
}

const Override = enum { neutral, ltr, rtl };
const Status = struct { level: u8, override: Override, isolate: bool };

fn resolveParagraph(
    allocator: std.mem.Allocator,
    codepoints: []const u21,
    original_types: []const BidiClass,
    types: []BidiClass,
    matching_pdi: []const u32,
    levels: []u8,
    paragraph: ParagraphRange,
) !void {
    const start: usize = paragraph.start;
    const end: usize = paragraph.end;
    if (start == end) return;

    var stack: [127]Status = undefined;
    stack[0] = .{ .level = paragraph.level, .override = .neutral, .isolate = false };
    var stack_len: usize = 1;
    var overflow_isolate_count: usize = 0;
    var overflow_embedding_count: usize = 0;
    var valid_isolate_count: usize = 0;

    for (start..end) |index| {
        const original = original_types[index];
        var top = stack[stack_len - 1];
        levels[index] = top.level;
        switch (original) {
            .rle, .rlo, .lre, .lro => {
                const rtl = original == .rle or original == .rlo;
                const next_level = if (rtl) leastGreaterOdd(top.level) else leastGreaterEven(top.level);
                if (next_level <= max_explicit_depth and overflow_isolate_count == 0 and overflow_embedding_count == 0) {
                    const override: Override = switch (original) {
                        .rlo => .rtl,
                        .lro => .ltr,
                        else => .neutral,
                    };
                    stack[stack_len] = .{ .level = next_level, .override = override, .isolate = false };
                    stack_len += 1;
                } else if (overflow_isolate_count == 0) {
                    overflow_embedding_count +|= 1;
                }
            },
            .rli, .lri, .fsi => {
                if (top.override != .neutral)
                    types[index] = if (top.override == .ltr) .l else .r;
                const rtl = if (original == .fsi) blk: {
                    const matching = matching_pdi[index];
                    const isolate_end = if (matching == std.math.maxInt(u32) or matching > end) end else matching;
                    break :blk paragraphLevel(
                        original_types,
                        matching_pdi,
                        index + 1,
                        isolate_end,
                        null,
                    ) == 1;
                } else original == .rli;
                const next_level = if (rtl) leastGreaterOdd(top.level) else leastGreaterEven(top.level);
                if (next_level <= max_explicit_depth and overflow_isolate_count == 0 and overflow_embedding_count == 0) {
                    valid_isolate_count += 1;
                    stack[stack_len] = .{ .level = next_level, .override = .neutral, .isolate = true };
                    stack_len += 1;
                } else {
                    overflow_isolate_count +|= 1;
                }
            },
            .pdi => {
                if (overflow_isolate_count > 0) {
                    overflow_isolate_count -= 1;
                } else if (valid_isolate_count > 0) {
                    overflow_embedding_count = 0;
                    while (!stack[stack_len - 1].isolate) stack_len -= 1;
                    stack_len -= 1;
                    valid_isolate_count -= 1;
                }
                top = stack[stack_len - 1];
                levels[index] = top.level;
                if (top.override != .neutral)
                    types[index] = if (top.override == .ltr) .l else .r;
            },
            .pdf => {
                if (overflow_isolate_count > 0) {
                    // Ignored inside an overflow isolate.
                } else if (overflow_embedding_count > 0) {
                    overflow_embedding_count -= 1;
                } else if (!top.isolate and stack_len >= 2) {
                    stack_len -= 1;
                }
            },
            .b => levels[index] = paragraph.level,
            .bn => {},
            else => {
                if (top.override != .neutral)
                    types[index] = if (top.override == .ltr) .l else .r;
            },
        }
    }

    const visible = try allocator.alloc(u32, end - start);
    defer allocator.free(visible);
    var visible_count: usize = 0;
    for (start..end) |index| {
        if (isRemovedByX9(original_types[index])) continue;
        visible[visible_count] = @intCast(index);
        visible_count += 1;
    }
    for (start..end) |index| {
        if (isRemovedByX9(original_types[index])) levels[index] = removed_level;
    }
    if (visible_count == 0) return;
    // X10 sos/eos are defined from the explicit levels before any IRS applies
    // I1/I2. Preserve that snapshot because IRS processing order is arbitrary.
    const explicit_levels = try allocator.dupe(u8, levels[start..end]);
    defer allocator.free(explicit_levels);

    const LevelRun = struct { start: usize, end: usize, level: u8 };
    var run_list: std.ArrayListUnmanaged(LevelRun) = .{};
    defer run_list.deinit(allocator);
    var run_start: usize = 0;
    var run_level = levels[visible[0]];
    for (visible[1..visible_count], 1..) |logical, position| {
        if (levels[logical] == run_level) continue;
        try run_list.append(allocator, .{ .start = run_start, .end = position, .level = run_level });
        run_start = position;
        run_level = levels[logical];
    }
    try run_list.append(allocator, .{ .start = run_start, .end = visible_count, .level = run_level });

    const run_of = try allocator.alloc(u32, end - start);
    defer allocator.free(run_of);
    @memset(run_of, std.math.maxInt(u32));
    for (run_list.items, 0..) |run, run_index| {
        for (visible[run.start..run.end]) |logical| run_of[logical - start] = @intCast(run_index);
    }
    const next_run = try allocator.alloc(u32, run_list.items.len);
    defer allocator.free(next_run);
    @memset(next_run, std.math.maxInt(u32));
    const incoming = try allocator.alloc(bool, run_list.items.len);
    defer allocator.free(incoming);
    @memset(incoming, false);

    for (run_list.items, 0..) |run, run_index| {
        const last = visible[run.end - 1];
        if (!isIsolateInitiator(types[last])) continue;
        const matching = matching_pdi[last];
        if (matching == std.math.maxInt(u32) or matching < start or matching >= end) continue;
        const target = run_of[matching - start];
        if (target == std.math.maxInt(u32) or target == run_index) continue;
        next_run[run_index] = target;
        incoming[target] = true;
    }

    var sequence: std.ArrayListUnmanaged(u32) = .{};
    defer sequence.deinit(allocator);
    for (run_list.items, 0..) |_, first_run| {
        if (incoming[first_run]) continue;
        sequence.clearRetainingCapacity();
        var current: u32 = @intCast(first_run);
        while (current != std.math.maxInt(u32)) {
            const run = run_list.items[current];
            try sequence.appendSlice(allocator, visible[run.start..run.end]);
            current = next_run[current];
        }
        try resolveIsolatingRunSequence(
            allocator,
            codepoints,
            original_types,
            types,
            levels,
            explicit_levels,
            start,
            paragraph,
            sequence.items,
        );
    }
}

fn leastGreaterOdd(level: u8) u8 {
    return if (level & 1 == 0) level +| 1 else level +| 2;
}

fn leastGreaterEven(level: u8) u8 {
    return if (level & 1 == 0) level +| 2 else level +| 1;
}

fn resolveIsolatingRunSequence(
    allocator: std.mem.Allocator,
    codepoints: []const u21,
    original_types: []const BidiClass,
    types: []BidiClass,
    levels: []u8,
    explicit_levels: []const u8,
    explicit_base: usize,
    paragraph: ParagraphRange,
    sequence: []const u32,
) !void {
    if (sequence.len == 0) return;
    const first = sequence[0];
    const last = sequence[sequence.len - 1];
    const preceding_level = previousVisibleLevel(original_types, explicit_levels, explicit_base, first, paragraph.start) orelse paragraph.level;
    const following_level = if (isIsolateInitiator(types[last]))
        paragraph.level
    else
        nextVisibleLevel(original_types, explicit_levels, explicit_base, last + 1, paragraph.end) orelse paragraph.level;
    const sos: BidiClass = if (@max(explicit_levels[first - explicit_base], preceding_level) & 1 == 0) .l else .r;
    const eos: BidiClass = if (@max(explicit_levels[last - explicit_base], following_level) & 1 == 0) .l else .r;

    // W1
    var previous = sos;
    for (sequence) |logical| {
        if (types[logical] == .nsm) {
            types[logical] = if (isIsolateInitiator(previous) or previous == .pdi) .on else previous;
        }
        previous = types[logical];
    }

    // W2
    var last_strong = sos;
    for (sequence) |logical| {
        const kind = types[logical];
        if (kind == .en and last_strong == .al) types[logical] = .an;
        if (kind == .r or kind == .l or kind == .al) last_strong = kind;
    }
    // W3
    for (sequence) |logical| if (types[logical] == .al) {
        types[logical] = .r;
    };
    // W4
    if (sequence.len >= 3) {
        for (1..sequence.len - 1) |position| {
            const before = types[sequence[position - 1]];
            const current = types[sequence[position]];
            const after = types[sequence[position + 1]];
            if (current == .es and before == .en and after == .en) {
                types[sequence[position]] = .en;
            } else if (current == .cs and before == after and (before == .en or before == .an)) {
                types[sequence[position]] = before;
            }
        }
    }
    // W5
    var position: usize = 0;
    while (position < sequence.len) {
        if (types[sequence[position]] != .et) {
            position += 1;
            continue;
        }
        const et_start = position;
        while (position < sequence.len and types[sequence[position]] == .et) position += 1;
        const adjacent_en = (et_start > 0 and types[sequence[et_start - 1]] == .en) or
            (position < sequence.len and types[sequence[position]] == .en);
        if (adjacent_en) for (sequence[et_start..position]) |logical| {
            types[logical] = .en;
        };
    }
    // W6
    for (sequence) |logical| switch (types[logical]) {
        .es, .et, .cs => types[logical] = .on,
        else => {},
    };
    // W7
    last_strong = sos;
    for (sequence) |logical| {
        if (types[logical] == .en and last_strong == .l) types[logical] = .l;
        if (types[logical] == .r or types[logical] == .l) last_strong = types[logical];
    }

    try resolveBrackets(allocator, codepoints, original_types, types, levels, sequence, sos);

    // N1/N2
    position = 0;
    while (position < sequence.len) {
        if (!isNeutralOrIsolate(types[sequence[position]])) {
            position += 1;
            continue;
        }
        const neutral_start = position;
        while (position < sequence.len and isNeutralOrIsolate(types[sequence[position]])) position += 1;
        const before = if (neutral_start == 0) sos else strongForNeutral(types[sequence[neutral_start - 1]]);
        const after = if (position == sequence.len) eos else strongForNeutral(types[sequence[position]]);
        if (before == after) {
            for (sequence[neutral_start..position]) |logical| types[logical] = before;
        } else {
            for (sequence[neutral_start..position]) |logical| {
                types[logical] = if (levels[logical] & 1 == 0) .l else .r;
            }
        }
    }

    // I1/I2
    for (sequence) |logical| {
        if (levels[logical] & 1 == 0) {
            if (types[logical] == .r) levels[logical] += 1 else if (types[logical] == .en or types[logical] == .an) levels[logical] += 2;
        } else if (types[logical] == .l or types[logical] == .en or types[logical] == .an) {
            levels[logical] += 1;
        }
    }
}

fn previousVisibleLevel(
    original_types: []const BidiClass,
    explicit_levels: []const u8,
    explicit_base: usize,
    before: usize,
    paragraph_start: usize,
) ?u8 {
    var index = before;
    while (index > paragraph_start) {
        index -= 1;
        if (!isRemovedByX9(original_types[index])) return explicit_levels[index - explicit_base];
    }
    return null;
}

fn nextVisibleLevel(
    original_types: []const BidiClass,
    explicit_levels: []const u8,
    explicit_base: usize,
    after: usize,
    paragraph_end: usize,
) ?u8 {
    var index = after;
    while (index < paragraph_end) : (index += 1) {
        if (!isRemovedByX9(original_types[index])) return explicit_levels[index - explicit_base];
    }
    return null;
}

const BracketStackEntry = struct { pair: u21, sequence_position: u32 };
const BracketPair = struct { open: u32, close: u32 };

fn canonicalBracket(cp: u21) u21 {
    return switch (cp) {
        0x2329 => 0x3008,
        0x232A => 0x3009,
        else => cp,
    };
}

fn resolveBrackets(
    allocator: std.mem.Allocator,
    codepoints: []const u21,
    original_types: []const BidiClass,
    types: []BidiClass,
    levels: []const u8,
    sequence: []const u32,
    sos: BidiClass,
) !void {
    var stack: [63]BracketStackEntry = undefined;
    var stack_len: usize = 0;
    var pairs: std.ArrayListUnmanaged(BracketPair) = .{};
    defer pairs.deinit(allocator);
    var overflowed = false;

    for (sequence, 0..) |logical, sequence_position| {
        if (types[logical] != .on) continue;
        const info = data.bracket(codepoints[logical]) orelse continue;
        if (info.kind == .open) {
            if (stack_len == stack.len) {
                overflowed = true;
                break;
            }
            stack[stack_len] = .{
                .pair = canonicalBracket(info.pair),
                .sequence_position = @intCast(sequence_position),
            };
            stack_len += 1;
        } else if (info.kind == .close) {
            const closing = canonicalBracket(codepoints[logical]);
            var candidate = stack_len;
            while (candidate > 0) {
                candidate -= 1;
                if (stack[candidate].pair != closing) continue;
                try pairs.append(allocator, .{
                    .open = stack[candidate].sequence_position,
                    .close = @intCast(sequence_position),
                });
                stack_len = candidate;
                break;
            }
        }
    }
    if (overflowed) return;
    std.mem.sort(BracketPair, pairs.items, {}, struct {
        fn lessThan(_: void, a: BracketPair, b: BracketPair) bool {
            return a.open < b.open;
        }
    }.lessThan);

    for (pairs.items) |pair| {
        const open_logical = sequence[pair.open];
        const close_logical = sequence[pair.close];
        const embedding: BidiClass = if (levels[open_logical] & 1 == 0) .l else .r;
        const opposite: BidiClass = if (embedding == .l) .r else .l;
        var found_embedding = false;
        var found_opposite = false;
        for (sequence[pair.open + 1 .. pair.close]) |logical| {
            const strong = optionalStrongForBracket(types[logical]) orelse continue;
            if (strong == embedding) found_embedding = true else found_opposite = true;
        }

        var resolved: ?BidiClass = null;
        if (found_embedding) {
            resolved = embedding;
        } else if (found_opposite) {
            var preceding = sos;
            var scan: usize = pair.open;
            while (scan > 0) {
                scan -= 1;
                if (optionalStrongForBracket(types[sequence[scan]])) |strong| {
                    preceding = strong;
                    break;
                }
            }
            resolved = if (preceding == opposite) opposite else embedding;
        }
        if (resolved) |kind| {
            types[open_logical] = kind;
            types[close_logical] = kind;
            propagateBracketNsm(original_types, types, sequence, pair.open, kind);
            propagateBracketNsm(original_types, types, sequence, pair.close, kind);
        }
    }
}

fn propagateBracketNsm(
    original_types: []const BidiClass,
    types: []BidiClass,
    sequence: []const u32,
    bracket_position: usize,
    kind: BidiClass,
) void {
    var position = bracket_position + 1;
    while (position < sequence.len and original_types[sequence[position]] == .nsm) : (position += 1) {
        types[sequence[position]] = kind;
    }
}

fn optionalStrongForBracket(kind: BidiClass) ?BidiClass {
    return switch (kind) {
        .l => .l,
        .r, .en, .an => .r,
        else => null,
    };
}

fn strongForNeutral(kind: BidiClass) BidiClass {
    return switch (kind) {
        .l => .l,
        .r, .en, .an => .r,
        else => kind,
    };
}

fn isNeutralOrIsolate(kind: BidiClass) bool {
    return switch (kind) {
        .b, .s, .ws, .on, .fsi, .lri, .rli, .pdi => true,
        else => false,
    };
}

fn isIsolateInitiator(kind: BidiClass) bool {
    return kind == .lri or kind == .rli or kind == .fsi;
}

fn isRemovedByX9(kind: BidiClass) bool {
    return switch (kind) {
        .rle, .lre, .rlo, .lro, .pdf, .bn => true,
        else => false,
    };
}

fn isL1WhitespaceOrIsolate(kind: BidiClass) bool {
    return switch (kind) {
        .ws, .fsi, .lri, .rli, .pdi => true,
        else => false,
    };
}

fn applyL1(
    original_types: []const BidiClass,
    paragraph_level: u8,
    start: usize,
    end: usize,
    line_levels: []u8,
    level_base: usize,
) void {
    if (start >= end) return;
    for (start..end) |logical| {
        const local = logical - level_base;
        if (line_levels[local] == removed_level) continue;
        if (original_types[logical] != .b and original_types[logical] != .s) continue;
        line_levels[local] = paragraph_level;
        var previous = logical;
        while (previous > start) {
            previous -= 1;
            const previous_local = previous - level_base;
            if (line_levels[previous_local] == removed_level) continue;
            if (!isL1WhitespaceOrIsolate(original_types[previous])) break;
            line_levels[previous_local] = paragraph_level;
        }
    }
    var trailing = end;
    while (trailing > start) {
        trailing -= 1;
        const local = trailing - level_base;
        if (line_levels[local] == removed_level) continue;
        if (!isL1WhitespaceOrIsolate(original_types[trailing])) break;
        line_levels[local] = paragraph_level;
    }
}

fn reorderByLevels(order: []u32, line_levels: []const u8, level_base: usize) void {
    if (order.len < 2) return;
    var maximum: u8 = 0;
    var minimum_odd: u8 = removed_level;
    for (order) |logical| {
        const level = line_levels[logical - level_base];
        maximum = @max(maximum, level);
        if (level & 1 == 1) minimum_odd = @min(minimum_odd, level);
    }
    if (minimum_odd == removed_level) return;

    var level = maximum;
    while (true) {
        var position: usize = 0;
        while (position < order.len) {
            while (position < order.len and line_levels[order[position] - level_base] < level) position += 1;
            const reverse_start = position;
            while (position < order.len and line_levels[order[position] - level_base] >= level) position += 1;
            std.mem.reverse(u32, order[reverse_start..position]);
        }
        if (level == minimum_odd) break;
        level -= 1;
    }
}

// ---------------------------------------------------------------------------
// Deterministic regressions. Full BidiTest-17.0.0 is a separate build gate.
// ---------------------------------------------------------------------------

const testing = std.testing;

test "Unicode 17 bidi properties cover controls, scripts, and brackets" {
    try testing.expectEqualStrings("17.0.0", unicode_version);
    try testing.expectEqual(BidiClass.lre, classify(0x202A));
    try testing.expectEqual(BidiClass.rli, classify(0x2067));
    try testing.expectEqual(BidiClass.al, classify(0x061C));
    try testing.expectEqual(BidiClass.r, classify(0x05E9));
    try testing.expectEqual(BidiClass.an, classify(0x0660));
    try testing.expectEqual(BracketType.open, bracket('(').?.kind);
    try testing.expectEqual(@as(u21, ')'), bracket('(').?.pair);
    try testing.expectEqual(@as(?u21, ')'), mirroredCodepoint('(', 1));
    try testing.expectEqual(@as(?u21, null), mirroredCodepoint('(', 0));
}

test "paragraph detection skips isolate contents" {
    try testing.expectEqual(Direction.ltr, detectParagraphDirection("\u{2067}\u{05D0}\u{2069}abc"));
    try testing.expectEqual(Direction.rtl, detectParagraphDirection("\u{2066}abc\u{2069}\u{05D0}"));
    try testing.expectEqual(Direction.ltr, detectParagraphDirection("abc\n\u{05D0}"));
}

test "explicit override produces non-monotonic visual order" {
    var result = try resolve(testing.allocator, "a\u{202E}12\u{202C}b", .ltr);
    defer result.deinit();
    const expected = [_]u32{ 0, 3, 2, 5 };
    try testing.expectEqualSlices(u32, &expected, result.visual_to_logical);
    try testing.expectEqual(removed_level, result.levels[1]);
    try testing.expectEqual(removed_level, result.levels[4]);
}

test "FSI and PDI isolate nested strong text from paragraph direction" {
    var result = try resolve(testing.allocator, "\u{2068}\u{05D0}1\u{2069} abc", null);
    defer result.deinit();
    try testing.expectEqual(@as(u8, 0), result.paragraphs[0].level);
    try testing.expect(result.levels[1] & 1 == 1);
    try testing.expect(result.visualIndex(1).? != 1);
}

test "N0 resolves paired brackets around opposite-direction text" {
    var result = try resolve(testing.allocator, "\u{05D0} abc (def) \u{05D1}", .rtl);
    defer result.deinit();
    const open_index: usize = 6;
    const close_index: usize = 10;
    try testing.expectEqual(result.levels[open_index], result.levels[close_index]);
    try testing.expect(result.levels[open_index] & 1 == 0);
}

test "numbers and common separators remain a level-two LTR run in RTL" {
    var result = try resolve(testing.allocator, "\u{05D0} 12,345 \u{05D1}", .rtl);
    defer result.deinit();
    for (2..8) |index| try testing.expectEqual(@as(u8, 2), result.levels[index]);
}

test "explicit depth overflow is deterministic and bounded" {
    const depth = 140;
    var bytes: std.ArrayListUnmanaged(u8) = .{};
    defer bytes.deinit(testing.allocator);
    for (0..depth) |_| try bytes.appendSlice(testing.allocator, "\u{202B}");
    try bytes.append(testing.allocator, 'a');
    for (0..depth) |_| try bytes.appendSlice(testing.allocator, "\u{202C}");
    var result = try resolve(testing.allocator, bytes.items, .ltr);
    defer result.deinit();
    try testing.expect(result.levels[depth] <= max_explicit_depth + 1);
    try testing.expectEqual(@as(usize, 1), result.visual_to_logical.len);
}

test "multiple paragraphs reorder independently and wrapped lines reapply L1" {
    var result = try resolve(testing.allocator, "abc\n\u{05D0}\u{05D1}  ", null);
    defer result.deinit();
    try testing.expectEqual(@as(usize, 2), result.paragraphs.len);
    try testing.expectEqual(@as(u8, 0), result.paragraphs[0].level);
    try testing.expectEqual(@as(u8, 1), result.paragraphs[1].level);
    var levels_buf: [4]u8 = undefined;
    var order_buf: [4]u32 = undefined;
    const line = try result.reorderLine(1, 4, 8, &levels_buf, &order_buf);
    try testing.expectEqual(@as(u8, 1), line.levels[2]);
    try testing.expectEqual(@as(u8, 1), line.levels[3]);
}

test "invalid UTF-8 fails closed and long RTL input stays linear" {
    try testing.expectError(error.InvalidUtf8, resolve(testing.allocator, "\xF0\x28\x8C\x28", null));
    const repetitions = 20_000;
    const text = try testing.allocator.alloc(u8, repetitions * 2);
    defer testing.allocator.free(text);
    for (0..repetitions) |index| @memcpy(text[index * 2 ..][0..2], "\u{05D0}");
    var result = try resolve(testing.allocator, text, null);
    defer result.deinit();
    try testing.expectEqual(repetitions, result.codepoints.len);
    try testing.expectEqual(@as(u32, repetitions - 1), result.visual_to_logical[0]);
}

test "splitRuns preserves UTF-8 byte ranges and resolved numeric direction" {
    const text = "abc \u{05D0} 12";
    var runs: std.ArrayListUnmanaged(Run) = .{};
    defer runs.deinit(testing.allocator);
    try splitRuns(text, .ltr, &runs, testing.allocator);
    try testing.expect(runs.items.len >= 3);
    try testing.expectEqual(@as(u32, 0), runs.items[0].start);
    try testing.expectEqual(@as(u32, text.len), runs.items[runs.items.len - 1].end);
    try testing.expectEqual(Direction.rtl, runs.items[1].direction);
    try testing.expectEqual(Direction.ltr, runs.items[runs.items.len - 1].direction);
}

test "splitRuns never merges adjacent paragraphs" {
    const text = "a\nb";
    var runs: std.ArrayListUnmanaged(Run) = .{};
    defer runs.deinit(testing.allocator);
    try splitRuns(text, .ltr, &runs, testing.allocator);
    try testing.expectEqual(@as(usize, 2), runs.items.len);
    try testing.expectEqual(@as(u32, 2), runs.items[0].end);
    try testing.expectEqual(@as(u32, 2), runs.items[1].start);
    try testing.expectEqual(@as(u32, text.len), runs.items[1].end);
}

//! T0 serialized contract for text coordinate migration.

const std = @import("std");
const grapheme = @import("grapheme.zig");

pub const GeometryStatus = enum {
    not_captured,
    known_incomplete,
    captured,
};

pub const CoordinateUnits = struct {
    storage: []const u8,
    editing: []const u8,
    geometry: []const u8,
};

pub const Case = struct {
    id: []const u8,
    category: []const u8,
    mode: []const u8,
    text: []const u8,
    utf8_bytes: usize,
    grapheme_boundaries: []const usize,
    geometry_status: GeometryStatus,
    limitation: []const u8,
};

pub const Corpus = struct {
    schema_version: u32,
    unicode_baseline: []const u8,
    coordinate_units: CoordinateUnits,
    cases: []const Case,
};

pub const json = @embedFile("testdata/text_coordinate_corpus.json");

pub fn parse(allocator: std.mem.Allocator) !std.json.Parsed(Corpus) {
    return std.json.parseFromSlice(Corpus, allocator, json, .{});
}

test "T0 coordinate corpus is valid UTF-8 and matches committed grapheme goldens" {
    const testing = std.testing;
    var parsed = try parse(testing.allocator);
    defer parsed.deinit();

    try testing.expectEqual(@as(u32, 1), parsed.value.schema_version);
    try testing.expect(parsed.value.cases.len >= 20);

    for (parsed.value.cases) |case| {
        try testing.expect(case.id.len > 0);
        try testing.expect(case.limitation.len > 0);
        try testing.expectEqual(case.utf8_bytes, case.text.len);
        try testing.expect(std.unicode.utf8ValidateSlice(case.text));
        try testing.expect(case.grapheme_boundaries.len >= 1);
        try testing.expectEqual(@as(usize, 0), case.grapheme_boundaries[0]);
        try testing.expectEqual(case.text.len, case.grapheme_boundaries[case.grapheme_boundaries.len - 1]);

        var expected_index: usize = 1;
        var byte: usize = 0;
        while (byte < case.text.len) {
            const next = grapheme.nextBoundary(case.text, byte);
            try testing.expect(next > byte);
            try testing.expect(expected_index < case.grapheme_boundaries.len);
            try testing.expectEqual(case.grapheme_boundaries[expected_index], next);
            try testing.expectEqual(byte, grapheme.prevBoundary(case.text, next));
            byte = next;
            expected_index += 1;
        }
        try testing.expectEqual(case.grapheme_boundaries.len, expected_index);
    }
}

test "T0 corpus names every required risk family" {
    const testing = std.testing;
    var parsed = try parse(testing.allocator);
    defer parsed.deinit();

    const required = [_][]const u8{
        "latin",    "combining", "cjk_wrap",       "newline",            "arabic",             "hebrew",
        "bidi",     "emoji_zwj", "emoji_modifier", "regional_indicator", "variation_selector", "indic",
        "thai",     "khmer",     "hangul",         "font_fallback",      "whitespace",         "empty_line",
        "password", "ime",
    };
    for (required) |category| {
        var found = false;
        for (parsed.value.cases) |case| {
            if (std.mem.eql(u8, case.category, category)) {
                found = true;
                break;
            }
        }
        try testing.expect(found);
    }
}

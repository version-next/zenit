//! Run the complete Unicode 17.0.0 UAX #9 conformance corpus.

const std = @import("std");
const i18n = @import("i18n");
const bidi = i18n.bidi;

const ExpectedLevel = i16;

fn trim(text: []const u8) []const u8 {
    return std.mem.trim(u8, text, " \t\r\n");
}

fn parseLevels(text: []const u8, output: *std.ArrayListUnmanaged(ExpectedLevel), allocator: std.mem.Allocator) !void {
    output.clearRetainingCapacity();
    var tokens = std.mem.tokenizeAny(u8, text, " \t");
    while (tokens.next()) |token| {
        if (std.mem.eql(u8, token, "x")) {
            try output.append(allocator, -1);
        } else {
            try output.append(allocator, try std.fmt.parseUnsigned(u8, token, 10));
        }
    }
}

fn parseOrder(text: []const u8, output: *std.ArrayListUnmanaged(u32), allocator: std.mem.Allocator) !void {
    output.clearRetainingCapacity();
    var tokens = std.mem.tokenizeAny(u8, text, " \t");
    while (tokens.next()) |token| {
        try output.append(allocator, try std.fmt.parseUnsigned(u32, token, 10));
    }
}

fn parseClass(token: []const u8) !bidi.BidiClass {
    inline for (std.meta.fields(bidi.BidiClass)) |field| {
        if (std.ascii.eqlIgnoreCase(token, field.name)) return @enumFromInt(field.value);
    }
    return error.UnknownBidiClass;
}

fn compareResult(
    result: bidi.ResolvedText,
    expected_levels: []const ExpectedLevel,
    expected_order: []const u32,
    path: []const u8,
    line_number: usize,
    direction_name: []const u8,
) !void {
    if (result.levels.len != expected_levels.len) {
        std.debug.print("{s}:{d} ({s}): level length expected {d}, got {d}\n", .{
            path, line_number, direction_name, expected_levels.len, result.levels.len,
        });
        return error.BidiConformanceFailure;
    }
    for (expected_levels, result.levels, 0..) |expected, actual, index| {
        const matches = if (expected < 0) actual == bidi.removed_level else actual == expected;
        if (!matches) {
            std.debug.print("{s}:{d} ({s}): level[{d}] expected {d}, got {d}\n", .{
                path, line_number, direction_name, index, expected, actual,
            });
            std.debug.print("  expected levels={any}\n  actual levels={any}\n", .{ expected_levels, result.levels });
            return error.BidiConformanceFailure;
        }
    }
    if (!std.mem.eql(u32, result.visual_to_logical, expected_order)) {
        std.debug.print("{s}:{d} ({s}): visual order mismatch\n", .{ path, line_number, direction_name });
        std.debug.print("  expected order={any}\n  actual order={any}\n", .{ expected_order, result.visual_to_logical });
        return error.BidiConformanceFailure;
    }
}

fn runBidiTest(allocator: std.mem.Allocator, path: []const u8) !usize {
    const contents = try std.fs.cwd().readFileAlloc(allocator, path, 16 * 1024 * 1024);
    defer allocator.free(contents);
    if (!std.mem.endsWith(u8, trim(contents), "# EOF")) return error.TruncatedConformanceData;

    var expected_levels: std.ArrayListUnmanaged(ExpectedLevel) = .{};
    defer expected_levels.deinit(allocator);
    var expected_order: std.ArrayListUnmanaged(u32) = .{};
    defer expected_order.deinit(allocator);
    var classes: std.ArrayListUnmanaged(bidi.BidiClass) = .{};
    defer classes.deinit(allocator);

    var case_count: usize = 0;
    var sequence_count: usize = 0;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    var line_number: usize = 0;
    while (lines.next()) |raw_line| {
        line_number += 1;
        const line = trim(raw_line);
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.startsWith(u8, line, "@Levels:")) {
            try parseLevels(line["@Levels:".len..], &expected_levels, allocator);
            continue;
        }
        if (std.mem.startsWith(u8, line, "@Reorder:")) {
            try parseOrder(line["@Reorder:".len..], &expected_order, allocator);
            continue;
        }
        if (line[0] == '@') continue;

        var fields = std.mem.splitScalar(u8, line, ';');
        const class_field = trim(fields.next() orelse return error.InvalidConformanceData);
        const bitset_field = trim(fields.next() orelse return error.InvalidConformanceData);
        classes.clearRetainingCapacity();
        var class_tokens = std.mem.tokenizeAny(u8, class_field, " \t");
        while (class_tokens.next()) |token| try classes.append(allocator, try parseClass(token));
        const bitset = try std.fmt.parseUnsigned(u8, bitset_field, 16);
        sequence_count += 1;

        const DirectionCase = struct { bit: u8, value: ?bidi.Direction, name: []const u8 };
        const directions = [_]DirectionCase{
            .{ .bit = 1, .value = null, .name = "auto" },
            .{ .bit = 2, .value = .ltr, .name = "ltr" },
            .{ .bit = 4, .value = .rtl, .name = "rtl" },
        };
        for (directions) |direction| {
            if (bitset & direction.bit == 0) continue;
            var result = try bidi.resolveClasses(allocator, classes.items, direction.value);
            defer result.deinit();
            try compareResult(result, expected_levels.items, expected_order.items, path, line_number, direction.name);
            case_count += 1;
        }
    }
    if (sequence_count != 490_846 or case_count != 770_241) {
        std.debug.print("BidiTest count mismatch: sequences={d}, directional evaluations={d}\n", .{ sequence_count, case_count });
        return error.UnexpectedBidiTestCount;
    }
    return sequence_count;
}

fn runBidiCharacterTest(allocator: std.mem.Allocator, path: []const u8) !usize {
    const contents = try std.fs.cwd().readFileAlloc(allocator, path, 16 * 1024 * 1024);
    defer allocator.free(contents);
    if (!std.mem.endsWith(u8, trim(contents), "# EOF")) return error.TruncatedConformanceData;

    var codepoints: std.ArrayListUnmanaged(u21) = .{};
    defer codepoints.deinit(allocator);
    var expected_levels: std.ArrayListUnmanaged(ExpectedLevel) = .{};
    defer expected_levels.deinit(allocator);
    var expected_order: std.ArrayListUnmanaged(u32) = .{};
    defer expected_order.deinit(allocator);

    var case_count: usize = 0;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    var line_number: usize = 0;
    while (lines.next()) |raw_line| {
        line_number += 1;
        const line = trim(raw_line);
        if (line.len == 0 or line[0] == '#') continue;
        var fields = std.mem.splitScalar(u8, line, ';');
        const codepoint_field = trim(fields.next() orelse return error.InvalidConformanceData);
        const direction_field = trim(fields.next() orelse return error.InvalidConformanceData);
        const paragraph_level_field = trim(fields.next() orelse return error.InvalidConformanceData);
        const levels_field = trim(fields.next() orelse return error.InvalidConformanceData);
        const order_field = trim(fields.next() orelse return error.InvalidConformanceData);

        codepoints.clearRetainingCapacity();
        var cp_tokens = std.mem.tokenizeAny(u8, codepoint_field, " \t");
        while (cp_tokens.next()) |token| {
            try codepoints.append(allocator, try std.fmt.parseUnsigned(u21, token, 16));
        }
        try parseLevels(levels_field, &expected_levels, allocator);
        try parseOrder(order_field, &expected_order, allocator);

        const direction_value = try std.fmt.parseUnsigned(u8, direction_field, 10);
        const direction: ?bidi.Direction = switch (direction_value) {
            0 => .ltr,
            1 => .rtl,
            2 => null,
            else => return error.InvalidConformanceData,
        };
        const direction_name = switch (direction_value) {
            0 => "ltr",
            1 => "rtl",
            2 => "auto",
            else => unreachable,
        };
        const expected_paragraph_level = try std.fmt.parseUnsigned(u8, paragraph_level_field, 10);
        var result = try bidi.resolveCodepointsForConformance(allocator, codepoints.items, direction);
        defer result.deinit();
        if (result.paragraphs.len != 1 or result.paragraphs[0].level != expected_paragraph_level) {
            std.debug.print("{s}:{d} ({s}): paragraph level expected {d}, got {any}\n", .{
                path,
                line_number,
                direction_name,
                expected_paragraph_level,
                if (result.paragraphs.len == 1) result.paragraphs[0].level else null,
            });
            return error.BidiConformanceFailure;
        }
        try compareResult(result, expected_levels.items, expected_order.items, path, line_number, direction_name);
        case_count += 1;
    }
    if (case_count != 91_707) return error.UnexpectedBidiCharacterTestCount;
    return case_count;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len != 3) {
        std.debug.print("usage: bidi-conformance BidiTest.txt BidiCharacterTest.txt\n", .{});
        return error.InvalidArguments;
    }
    const class_cases = try runBidiTest(allocator, args[1]);
    const character_cases = try runBidiCharacterTest(allocator, args[2]);
    std.debug.print(
        "Unicode {s} bidi conformance: PASS (BidiTest={d} sequences/770241 evaluations, BidiCharacterTest={d})\n",
        .{ bidi.unicode_version, class_cases, character_cases },
    );
}

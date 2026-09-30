//! Print the committed T0 corpus in a stable, review-friendly line format.

const std = @import("std");
const text_core = @import("text_core");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var parsed = try text_core.text_coordinate_corpus.parse(allocator);
    defer parsed.deinit();

    var out_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&out_buffer);
    const out = &stdout_writer.interface;
    for (parsed.value.cases) |case| {
        try out.print("{s}\tbytes={d}\tgraphemes=", .{ case.id, case.utf8_bytes });
        for (case.grapheme_boundaries, 0..) |boundary, i| {
            if (i != 0) try out.writeByte(',');
            try out.print("{d}", .{boundary});
        }
        try out.print("\tgeometry={s}\tlimitation={s}\n", .{ @tagName(case.geometry_status), case.limitation });
    }
    try out.flush();
}

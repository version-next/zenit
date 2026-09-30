const std = @import("std");
const text_core = @import("text_core");

const atoms = [_][]const u8{
    "a",
    "Z",
    " ",
    "\r\n",
    "e\u{301}",
    "中",
    "العَرَبِيَّة",
    "שָׁ",
    "👩‍💻",
    "👍🏽",
    "🇯🇵",
    "क्",
    "ก้",
    "한",
};

const Rng = struct {
    state: u64,

    fn next(self: *Rng) u64 {
        var value = self.state;
        value ^= value << 13;
        value ^= value >> 7;
        value ^= value << 17;
        self.state = value;
        return value;
    }

    fn lessThan(self: *Rng, limit: usize) usize {
        return @intCast(self.next() % @as(u64, @intCast(limit)));
    }
};

fn parseSeed() u64 {
    const value = std.posix.getenv("ZENIT_TEST_SEED") orelse return 0x5eed_cafe_2026_0731;
    const text: []const u8 = value;
    const base: u8 = if (std.mem.startsWith(u8, text, "0x")) 16 else 10;
    const digits = if (base == 16) text[2..] else text;
    return std.fmt.parseUnsigned(u64, digits, base) catch 0x5eed_cafe_2026_0731;
}

fn checkCase(text: []const u8) !void {
    const coordinates = text_core.text_coordinates;
    const grapheme = text_core.grapheme;
    if (!std.unicode.utf8ValidateSlice(text)) return error.GeneratedInvalidUtf8;

    var offset: usize = 0;
    while (offset < text.len) {
        const next = grapheme.nextBoundary(text, offset);
        if (next <= offset or next > text.len) return error.NonMonotonicBoundary;
        if (!coordinates.isGraphemeBoundary(text, offset) or
            !coordinates.isGraphemeBoundary(text, next) or
            grapheme.prevBoundary(text, next) != offset)
        {
            return error.BoundaryRoundTripFailed;
        }
        offset = next;
    }
    if (offset != text.len) return error.SourceCoverageFailed;

    for (0..text.len + 1) |byte| {
        const backward = coordinates.clampByteOffset(text, .{ .value = byte }, .backward).value;
        const forward = coordinates.clampByteOffset(text, .{ .value = byte }, .forward).value;
        if (backward > byte or forward < byte or forward > text.len)
            return error.ClampOrderingFailed;
        if (!coordinates.isGraphemeBoundary(text, backward) or
            !coordinates.isGraphemeBoundary(text, forward))
        {
            return error.ClampNotBoundary;
        }
        const truncated = coordinates.truncateToGraphemeBoundary(text, byte);
        if (truncated > byte or !coordinates.isGraphemeBoundary(text, truncated))
            return error.TruncationFailed;
    }
}

pub fn main() !void {
    const seed = parseSeed();
    var rng = Rng{ .state = if (seed == 0) 1 else seed };
    var storage: [4096]u8 = undefined;
    const iterations: usize = 2000;

    for (0..iterations) |_| {
        var length: usize = 0;
        const atom_count = 1 + rng.lessThan(48);
        for (0..atom_count) |_| {
            const atom = atoms[rng.lessThan(atoms.len)];
            if (length + atom.len > storage.len) break;
            @memcpy(storage[length .. length + atom.len], atom);
            length += atom.len;
        }
        checkCase(storage[0..length]) catch |err| {
            std.debug.print("text coordinate property failure seed=0x{x} text={any}: {}\n", .{ seed, storage[0..length], err });
            return err;
        };
    }
    std.debug.print("text coordinate properties: PASS (seed=0x{x}, cases={d})\n", .{ seed, iterations });
}

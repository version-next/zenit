const coordinates = @import("text_core").text_coordinates;

/// The canonical document remains unchanged until commit. Offsets are canonical
/// UTF-8 bytes; the saved selection belongs to the start of reconversion.
pub const ImeReplacement = struct {
    start: usize,
    end: usize,
    cursor: usize,
    anchor: ?usize,

    pub fn removedInSegment(self: ImeReplacement, offset: usize, len: usize) usize {
        const start = @min(self.start -| offset, len);
        const end = @min(self.end -| offset, len);
        return end - start;
    }

    pub fn compose(self: ImeReplacement, source: []const u8, offset: usize, preedit: []const u8, insert: bool, out: []u8) []const u8 {
        const start = @min(self.start -| offset, source.len);
        const end = @min(self.end -| offset, source.len);
        var written: usize = 0;
        const parts = [_][]const u8{ source[0..start], if (insert) preedit else "", source[end..] };
        for (parts) |part| {
            const n = coordinates.truncateToGraphemeBoundary(part, out.len - written);
            @memcpy(out[written .. written + n], part[0..n]);
            written += n;
            if (n != part.len) break;
        }
        return out[0..written];
    }
};

test "reconversion display removes every overlapping segment and keeps complete graphemes" {
    const t = @import("std").testing;
    const replacement: ImeReplacement = .{ .start = 2, .end = 8, .cursor = 10, .anchor = null };
    var buffer: [32]u8 = undefined;
    try t.expectEqualStrings("ab候选ij", replacement.compose("abcdefghij", 0, "候选", true, &buffer));
    try t.expectEqualStrings("ab", replacement.compose("ab", 0, "", false, &buffer));
    try t.expectEqualStrings("候选", replacement.compose("cdef", 2, "候选", true, &buffer));
    try t.expectEqualStrings("", replacement.compose("gh", 6, "", false, &buffer));
    try t.expectEqualStrings("ij", replacement.compose("ij", 8, "", false, &buffer));
    try t.expectEqualStrings("ab", replacement.compose("abcdefghij", 0, "候选", true, buffer[0..4]));
}

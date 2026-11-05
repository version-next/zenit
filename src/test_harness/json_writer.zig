/// json_writer, lightweight JSON writer (no third-party dependency)
///
/// Support streaming write of object/array/string/number/bool/null.
const std = @import("std");

pub const JsonWriter = struct {
    buf: []u8,
    pos: usize = 0,
    overflow: bool = false,

    // Track commas: each nesting level record if first element written
    depth: usize = 0,
    needs_comma: [64]bool = @as([64]bool, @splat(false)),
    // Set true after ":" follow key, next value entry skip comma and reset
    after_key: bool = false,

    pub fn init(buf: []u8) JsonWriter {
        return .{ .buf = buf };
    }

    pub fn getWritten(self: *const JsonWriter) []const u8 {
        return self.buf[0..self.pos];
    }

    pub fn hasOverflowed(self: *const JsonWriter) bool {
        return self.overflow;
    }

    // --- Write primitives ---

    fn writeRaw(self: *JsonWriter, data: []const u8) void {
        if (self.overflow) return;
        if (self.pos + data.len > self.buf.len) {
            const remaining = self.buf.len - self.pos;
            @memcpy(self.buf[self.pos..][0..remaining], data[0..remaining]);
            self.pos = self.buf.len;
            self.overflow = true;
            return;
        }
        @memcpy(self.buf[self.pos..][0..data.len], data);
        self.pos += data.len;
    }

    fn writeByte(self: *JsonWriter, b: u8) void {
        if (self.overflow) return;
        if (self.pos >= self.buf.len) {
            self.overflow = true;
            return;
        }
        self.buf[self.pos] = b;
        self.pos += 1;
    }

    /// Insert comma before value (if needed); value following key needs no comma (after_key=true
    /// skip)
    fn commaBeforeValue(self: *JsonWriter) void {
        if (self.after_key) {
            // Key value: no comma, clear flag
            self.after_key = false;
            return;
        }
        // Normal value (array element or impossible: object value always follow key)
        if (self.depth > 0 and self.depth < 64) {
            if (self.needs_comma[self.depth]) {
                self.writeByte(',');
            }
            self.needs_comma[self.depth] = true;
        }
    }

    // --- Object ---

    pub fn beginObject(self: *JsonWriter) void {
        self.commaBeforeValue();
        self.writeByte('{');
        self.depth += 1;
        if (self.depth < 64) {
            self.needs_comma[self.depth] = false;
        }
    }

    pub fn endObject(self: *JsonWriter) void {
        self.writeByte('}');
        if (self.depth > 0) self.depth -= 1;
    }

    /// Write key (auto handle comma + quotes)
    pub fn key(self: *JsonWriter, k: []const u8) void {
        // Comma needed between keys (skip first)
        if (self.depth > 0 and self.depth < 64) {
            if (self.needs_comma[self.depth]) {
                self.writeByte(',');
            }
            self.needs_comma[self.depth] = true;
        }
        self.writeByte('"');
        self.writeEscapedString(k);
        self.writeByte('"');
        self.writeByte(':');
        // Mark next value is key's value, no comma
        self.after_key = true;
    }

    // --- Array ---

    pub fn beginArray(self: *JsonWriter) void {
        self.commaBeforeValue();
        self.writeByte('[');
        self.depth += 1;
        if (self.depth < 64) {
            self.needs_comma[self.depth] = false;
        }
    }

    pub fn endArray(self: *JsonWriter) void {
        self.writeByte(']');
        if (self.depth > 0) self.depth -= 1;
    }

    // --- Values ---

    /// String with comma prefix (array element)
    pub fn string(self: *JsonWriter, s: []const u8) void {
        self.commaBeforeValue();
        self.writeByte('"');
        self.writeEscapedString(s);
        self.writeByte('"');
    }

    /// String without comma (key's value)
    pub fn stringValue(self: *JsonWriter, s: []const u8) void {
        self.commaBeforeValue();
        self.writeByte('"');
        self.writeEscapedString(s);
        self.writeByte('"');
    }

    pub fn number(self: *JsonWriter, n: i64) void {
        self.commaBeforeValue();
        var num_buf: [24]u8 = undefined;
        const len = formatInt(n, &num_buf);
        self.writeRaw(num_buf[0..len]);
    }

    pub fn numberValue(self: *JsonWriter, n: i64) void {
        self.commaBeforeValue();
        var num_buf: [24]u8 = undefined;
        const len = formatInt(n, &num_buf);
        self.writeRaw(num_buf[0..len]);
    }

    pub fn float(self: *JsonWriter, f: f32) void {
        self.commaBeforeValue();
        self.writeFloat(f);
    }

    pub fn floatValue(self: *JsonWriter, f: f32) void {
        self.commaBeforeValue();
        self.writeFloat(f);
    }

    fn writeFloat(self: *JsonWriter, f: f32) void {
        // JSON has no NaN/Infinity representation. Keep unknown geometry or
        // metrics explicit; never turn it into a plausible zero or invalid JSON.
        if (!std.math.isFinite(f)) {
            self.writeRaw("null");
            return;
        }
        // Check the range before converting: ReleaseFast treats an out-of-range
        // float-to-int conversion as illegal behavior too.
        if (f >= -1e15 and f <= 1e15) {
            const i: i64 = @intFromFloat(f);
            if (f - @as(f32, @floatFromInt(i)) == 0) {
                var num_buf: [24]u8 = undefined;
                const len = formatInt(i, &num_buf);
                self.writeRaw(num_buf[0..len]);
                return;
            }
        }
        // Preserve f32 values across the wire. Rounding to three decimals made
        // a submitted entering opacity such as 0.000484 look fully hidden.
        // Scientific notation also keeps large values JSON floating numbers
        // rather than overflowing the parser's integer representation.
        var float_buf: [64]u8 = undefined;
        const s = std.fmt.bufPrint(&float_buf, "{e}", .{f}) catch unreachable;
        self.writeRaw(s);
    }

    pub fn boolean(self: *JsonWriter, b: bool) void {
        self.commaBeforeValue();
        self.writeBoolRaw(b);
    }

    pub fn booleanValue(self: *JsonWriter, b: bool) void {
        self.commaBeforeValue();
        self.writeBoolRaw(b);
    }

    fn writeBoolRaw(self: *JsonWriter, b: bool) void {
        if (b) {
            self.writeRaw("true");
        } else {
            self.writeRaw("false");
        }
    }

    pub fn null_(self: *JsonWriter) void {
        self.commaBeforeValue();
        self.writeRaw("null");
    }

    pub fn nullValue(self: *JsonWriter) void {
        self.commaBeforeValue();
        self.writeRaw("null");
    }

    pub fn rawValue(self: *JsonWriter, raw: []const u8) void {
        self.commaBeforeValue();
        self.writeRaw(raw);
    }

    // --- Helpers ---

    fn writeEscapedString(self: *JsonWriter, s: []const u8) void {
        for (s) |c| {
            switch (c) {
                '"' => self.writeRaw("\\\""),
                '\\' => self.writeRaw("\\\\"),
                '\n' => self.writeRaw("\\n"),
                '\r' => self.writeRaw("\\r"),
                '\t' => self.writeRaw("\\t"),
                else => {
                    if (c < 0x20) {
                        self.writeRaw("\\u00");
                        const hex = "0123456789abcdef";
                        self.writeByte(hex[c >> 4]);
                        self.writeByte(hex[c & 0xf]);
                    } else {
                        self.writeByte(c);
                    }
                },
            }
        }
    }

    fn formatInt(val: i64, buf: *[24]u8) usize {
        if (val == 0) {
            buf[0] = '0';
            return 1;
        }
        var v = val;
        var neg = false;
        if (v < 0) {
            neg = true;
            v = -v;
        }
        var pos: usize = 24;
        while (v > 0) {
            pos -= 1;
            buf[pos] = @intCast(@as(u64, @intCast(@rem(v, 10))) + '0');
            v = @divTrunc(v, 10);
        }
        if (neg) {
            pos -= 1;
            buf[pos] = '-';
        }
        const len = 24 - pos;
        if (pos > 0) {
            std.mem.copyForwards(u8, buf[0..len], buf[pos..24]);
        }
        return len;
    }
};

test "JSON floating values preserve small entering opacity and transition boundaries" {
    for ([_]f32{ 0.022 * 0.022, 0.000001, -0.000001, 0.998999, 0.999999, 1.40129846e-45 }) |value| {
        var buf: [256]u8 = undefined;
        var writer = JsonWriter.init(&buf);
        writer.floatValue(value);
        var parsed = try std.json.parseFromSlice(f32, std.testing.allocator, writer.getWritten(), .{});
        defer parsed.deinit();
        try std.testing.expectEqual(value, parsed.value);
    }
}

test "JSON floating values preserve unknown nonfinite values as null" {
    var buf: [256]u8 = undefined;
    var writer = JsonWriter.init(&buf);
    writer.beginArray();
    for ([_]f32{ std.math.nan(f32), std.math.inf(f32), -std.math.inf(f32) }) |value| {
        writer.float(value);
        writer.floatValue(value);
    }
    writer.endArray();
    try std.testing.expectEqualStrings("[null,null,null,null,null,null]", writer.getWritten());
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, writer.getWritten(), .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 6), parsed.value.array.items.len);
    for (parsed.value.array.items) |value| try std.testing.expect(value == .null);
}

test "JSON large finite floats stay numeric without integer conversion overflow" {
    for ([_]f32{ std.math.floatMax(f32), -std.math.floatMax(f32), 1e30, -1e30, 1e18, -1e18, 1e15, -1e15 }) |value| {
        var buf: [256]u8 = undefined;
        var writer = JsonWriter.init(&buf);
        writer.floatValue(value);
        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, writer.getWritten(), .{});
        defer parsed.deinit();
        const observed: f64 = switch (parsed.value) {
            .float => |v| v,
            .integer => |v| @floatFromInt(v),
            else => return error.TestUnexpectedResult,
        };
        try std.testing.expect(std.math.isFinite(observed));
        try std.testing.expect(std.math.approxEqRel(f64, @as(f64, value), observed, 1e-6));
    }
}

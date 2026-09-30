/// json_writer — 轻量 JSON writer（无第三方依赖）
///
/// 支持 object/array/string/number/bool/null 的流式写入。
const std = @import("std");

pub const JsonWriter = struct {
    buf: []u8,
    pos: usize = 0,
    overflow: bool = false,

    // 用于跟踪逗号：每层 nesting 记录是否已写过第一个元素
    depth: usize = 0,
    needs_comma: [64]bool = [_]bool{false} ** 64,
    // key 写完 ":" 后设为 true，下一个 value 写入时跳过逗号并重置
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

    // --- 写入原语 ---

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

    /// 在值之前插入逗号（如果需要的话）
    /// key 后面紧跟的值不需要逗号（after_key=true 时跳过）
    fn commaBeforeValue(self: *JsonWriter) void {
        if (self.after_key) {
            // key 的 value：不需要逗号，清除标记
            self.after_key = false;
            return;
        }
        // 普通值（array 元素 或 这是不可能的情况 — object 中 value 总是跟在 key 后面）
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

    /// 写入 key（自动处理逗号 + 引号）
    pub fn key(self: *JsonWriter, k: []const u8) void {
        // key 之间需要逗号（第一个 key 除外）
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
        // 标记下一个值是 key 的 value，不需要逗号
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

    /// 带逗号前缀的字符串（array 元素）
    pub fn string(self: *JsonWriter, s: []const u8) void {
        self.commaBeforeValue();
        self.writeByte('"');
        self.writeEscapedString(s);
        self.writeByte('"');
    }

    /// 不带逗号的字符串值（key 的 value）
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
        const i: i64 = @intFromFloat(f);
        const diff = f - @as(f32, @floatFromInt(i));
        if (diff == 0 and f >= -1e15 and f <= 1e15) {
            var num_buf: [24]u8 = undefined;
            const len = formatInt(i, &num_buf);
            self.writeRaw(num_buf[0..len]);
        } else {
            var float_buf: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&float_buf, "{d:.3}", .{f}) catch "0";
            self.writeRaw(s);
        }
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

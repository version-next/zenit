const std = @import("std");

pub fn skipNumberSeparators(s: []const u8, index: *usize) void {
    while (index.* < s.len) : (index.* += 1) {
        const c = s[index.*];
        if (c == ',' or std.ascii.isWhitespace(c)) continue;
        break;
    }
}

pub fn nextIsNumber(s: []const u8, index: usize) bool {
    var i = index;
    skipNumberSeparators(s, &i);
    if (i >= s.len) return false;
    const c = s[i];
    return c == '+' or c == '-' or c == '.' or std.ascii.isDigit(c);
}

/// Parse one SVG number and reject malformed exponents plus non-finite f32
/// results. Both SVG ingestion pipelines use this implementation so parser
/// security fixes cannot silently drift apart again.
pub fn parseFiniteNumber(s: []const u8, index: *usize) ?f32 {
    var i = index.*;
    skipNumberSeparators(s, &i);
    if (i >= s.len) return null;
    const start = i;

    if (s[i] == '+' or s[i] == '-') i += 1;

    var has_digit = false;
    while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) has_digit = true;
    if (i < s.len and s[i] == '.') {
        i += 1;
        while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) has_digit = true;
    }
    if (!has_digit) return null;

    if (i < s.len and (s[i] == 'e' or s[i] == 'E')) {
        i += 1;
        if (i < s.len and (s[i] == '+' or s[i] == '-')) i += 1;
        var exponent_has_digit = false;
        while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) exponent_has_digit = true;
        if (!exponent_has_digit) return null;
    }

    const parsed = std.fmt.parseFloat(f32, s[start..i]) catch return null;
    if (!std.math.isFinite(parsed)) return null;
    index.* = i;
    return parsed;
}

/// Clamp a finite tessellation estimate before float-to-int conversion.
pub fn boundedSegmentCount(value: f32, min: usize, max: usize) usize {
    std.debug.assert(min <= max);
    if (!std.math.isFinite(value) or value <= @as(f32, @floatFromInt(min))) return min;
    if (value >= @as(f32, @floatFromInt(max))) return max;
    return @intFromFloat(@ceil(value));
}

test "SVG numeric helpers reject malformed and non-finite input" {
    var i: usize = 0;
    try std.testing.expectEqual(@as(?f32, 12.5), parseFiniteNumber(" , 12.5e0", &i));
    try std.testing.expectEqual(@as(usize, 9), i);

    for ([_][]const u8{ "1e", "+", ".", "1e999" }) |input| {
        i = 0;
        try std.testing.expect(parseFiniteNumber(input, &i) == null);
        try std.testing.expectEqual(@as(usize, 0), i);
    }
    try std.testing.expectEqual(@as(usize, 4), boundedSegmentCount(std.math.nan(f32), 4, 128));
    try std.testing.expectEqual(@as(usize, 4), boundedSegmentCount(std.math.inf(f32), 4, 128));
}

// ── 模糊测试 ───────────────────────────────────────────────────────────
//
// 这里是**外部输入的解析边界**（SVG 文件内容），所以除了「结果对不对」还要
// 锁两条更基本的不变式，否则畸形输入能把整个宿主进程带走：
//
//   1. 任何字节序列都不得 panic / 越界 / 死循环
//   2. index 只能前进或不变，**绝不能倒退** —— 调用方普遍写成
//      `while (i < s.len) { ... parseFiniteNumber(s, &i) ... }`，
//      index 倒退一次就是无限循环（挂死，不是崩溃，更难查）

fn fuzzOne(bytes: []const u8) void {
    var i: usize = 0;
    var guard: usize = 0;
    while (i < bytes.len) {
        const before = i;
        _ = nextIsNumber(bytes, i);
        _ = parseFiniteNumber(bytes, &i);
        // 不变式 2：index 不得倒退
        std.debug.assert(i >= before);
        if (i == before) {
            // 解析不动就手工推进一格，模拟真实调用方的跳过逻辑
            i += 1;
        }
        guard += 1;
        // 不变式 1 的推论：循环次数不可能超过输入长度
        std.debug.assert(guard <= bytes.len + 1);
    }
}

test "fuzz: parseFiniteNumber 对任意字节序列不崩溃且 index 不倒退" {
    var prng = std.Random.DefaultPrng.init(0x5A9E_0000_0001);
    const rand = prng.random();
    var buf: [64]u8 = undefined;

    var round: usize = 0;
    while (round < 20000) : (round += 1) {
        const len = rand.uintLessThan(usize, buf.len);
        for (buf[0..len]) |*b| {
            // 偏向数字语法字符，让输入更容易走进深层分支，而不是几乎全被
            // 首字符判据挡掉（纯随机字节里 99% 的用例连第一个 if 都进不去）
            b.* = switch (rand.uintLessThan(u8, 10)) {
                0...5 => "0123456789+-.eE, \t".*[rand.uintLessThan(usize, 19)],
                else => rand.int(u8),
            };
        }
        fuzzOne(buf[0..len]);
    }
}

test "fuzz: 已知的畸形形状不得通过" {
    const bad = [_][]const u8{
        "e5", "E",    "+",   "-",   ".",        "+.",        "-.",   "1e",       "1e+", "1e-",
        "..", "1..2", "--1", "++1", "1e999999", "-1e999999", "\x00", "\xff\xfe", ",,,", "   ",
    };
    for (bad) |b| {
        var i: usize = 0;
        const r = parseFiniteNumber(b, &i);
        if (r) |v| {
            // 允许解析成功的必须是有限值（如 "1..2" 会吃掉前面的 "1."）
            try std.testing.expect(std.math.isFinite(v));
        }
    }
}

test "fuzz: boundedSegmentCount 对任意 f32 都落在 [min,max]" {
    var prng = std.Random.DefaultPrng.init(0x5A9E_0000_0002);
    const rand = prng.random();
    const specials = [_]f32{
        0,                 -0.0,                   1,                       -1,                     std.math.inf(f32), -std.math.inf(f32),
        std.math.nan(f32), std.math.floatMax(f32), -std.math.floatMax(f32), std.math.floatMin(f32), 1e30,              -1e30,
    };
    for (specials) |v| {
        const got = boundedSegmentCount(v, 4, 256);
        try std.testing.expect(got >= 4 and got <= 256);
    }
    var round: usize = 0;
    while (round < 10000) : (round += 1) {
        const v: f32 = @bitCast(rand.int(u32));
        const got = boundedSegmentCount(v, 4, 256);
        try std.testing.expect(got >= 4 and got <= 256);
    }
}

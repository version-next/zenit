//! Script detection + run split, Phase 6 文本流水线
//!
//! 在 bidi.splitRuns 之后再按 script（拉丁/CJK/阿拉伯/希伯来等）切分；
//! 同 direction + 同 script 的连续 codepoint 形成一个 shaping run。
//!
//! 简化版：覆盖最常见 6 种 script + Common（标点等）。
//! 完整 ISO 15924 / Unicode Script Extensions 留 v0.3+。
//!
//! 设计参照：
//! - ICU u_getScript / hb_unicode_script
//! - Skia SkShaper RunIterator 内部 script run 切分

const std = @import("std");
const testing = std.testing;

pub const Script = enum(u8) {
    /// 通用（数字、ASCII 标点、空格，跟前一个真 script 走）
    common,
    /// 拉丁
    latin,
    /// 希腊
    greek,
    /// 西里尔
    cyrillic,
    /// 阿拉伯
    arabic,
    /// 希伯来
    hebrew,
    /// CJK（中日韩统一表意 + Hiragana + Katakana + Hangul）
    cjk,
    /// 天城（印地等）
    devanagari,
    /// 泰文
    thai,
    /// 其他（fallback）
    other,
};

/// codepoint -> Script
pub fn classify(cp: u32) Script {
    // ASCII 控制 + 标点 + 数字
    if (cp < 0x80) {
        if ((cp >= 'A' and cp <= 'Z') or (cp >= 'a' and cp <= 'z')) return .latin;
        return .common;
    }
    // Latin Extended
    if (cp >= 0x0080 and cp <= 0x024F) return .latin;
    // Greek
    if (cp >= 0x0370 and cp <= 0x03FF) return .greek;
    // Cyrillic
    if (cp >= 0x0400 and cp <= 0x04FF) return .cyrillic;
    // Hebrew
    if (cp >= 0x0590 and cp <= 0x05FF) return .hebrew;
    // Arabic
    if (cp >= 0x0600 and cp <= 0x06FF) return .arabic;
    if (cp >= 0x0750 and cp <= 0x077F) return .arabic;
    if (cp >= 0xFB50 and cp <= 0xFDFF) return .arabic;
    if (cp >= 0xFE70 and cp <= 0xFEFF) return .arabic;
    // Devanagari
    if (cp >= 0x0900 and cp <= 0x097F) return .devanagari;
    // Thai
    if (cp >= 0x0E00 and cp <= 0x0E7F) return .thai;
    // CJK
    if (cp >= 0x3000 and cp <= 0x303F) return .common; // CJK 标点
    if (cp >= 0x3040 and cp <= 0x309F) return .cjk; // Hiragana
    if (cp >= 0x30A0 and cp <= 0x30FF) return .cjk; // Katakana
    if (cp >= 0x3400 and cp <= 0x4DBF) return .cjk; // CJK Ext A
    if (cp >= 0x4E00 and cp <= 0x9FFF) return .cjk; // CJK Unified
    if (cp >= 0xAC00 and cp <= 0xD7A3) return .cjk; // Hangul
    if (cp >= 0xF900 and cp <= 0xFAFF) return .cjk; // CJK Compat
    return .other;
}

pub const ScriptRun = struct {
    /// utf-8 byte offset 起始
    start: u32,
    /// 结束（exclusive）
    end: u32,
    /// 主导 script
    script: Script,
};

/// 在已知 byte range 内（来自 bidi.splitRuns 后的单个 direction run）按 script 切分。
/// common（数字/标点）不开新 run，跟前一个真 script。如果开头就是 common，
/// 会等到第一个真 script 才确定 run 起点的 script。
pub fn splitScriptRuns(
    text: []const u8,
    bidi_start: u32,
    bidi_end: u32,
    out: *std.ArrayListUnmanaged(ScriptRun),
    allocator: std.mem.Allocator,
) !void {
    if (bidi_start >= bidi_end) return;
    const slice = text[bidi_start..bidi_end];
    var view = std.unicode.Utf8View.init(slice) catch return error.InvalidUtf8;
    var iter = view.iterator();

    var current_script: ?Script = null;
    var current_start: u32 = bidi_start;
    var byte_pos: u32 = bidi_start;

    while (iter.nextCodepoint()) |cp| {
        const cp_byte_len = std.unicode.utf8CodepointSequenceLength(cp) catch 1;
        const cls = classify(cp);
        const real_script: ?Script = if (cls == .common) null else cls;

        if (real_script) |s| {
            if (current_script == null) {
                // 头一个真 script
                current_script = s;
            } else if (s != current_script.?) {
                // flush
                try out.append(allocator, .{
                    .start = current_start,
                    .end = byte_pos,
                    .script = current_script.?,
                });
                current_script = s;
                current_start = byte_pos;
            }
        }
        // common: 不切；跟当前 run 走

        byte_pos += cp_byte_len;
    }

    if (byte_pos > current_start) {
        try out.append(allocator, .{
            .start = current_start,
            .end = byte_pos,
            .script = current_script orelse .common,
        });
    }
}

// ============================================================================
// Tests
// ============================================================================

test "classify: ASCII letters → latin" {
    try testing.expectEqual(Script.latin, classify('a'));
    try testing.expectEqual(Script.latin, classify('Z'));
}

test "classify: digits + punctuation → common" {
    try testing.expectEqual(Script.common, classify('5'));
    try testing.expectEqual(Script.common, classify(','));
    try testing.expectEqual(Script.common, classify(' '));
}

test "classify: Hebrew" {
    try testing.expectEqual(Script.hebrew, classify(0x05E9)); // ש
}

test "classify: Arabic" {
    try testing.expectEqual(Script.arabic, classify(0x0627)); // ا
}

test "classify: CJK" {
    try testing.expectEqual(Script.cjk, classify(0x4E2D)); // 中
    try testing.expectEqual(Script.cjk, classify(0x3042)); // あ Hiragana
    try testing.expectEqual(Script.cjk, classify(0xAC00)); // 가 Hangul
}

test "classify: Devanagari" {
    try testing.expectEqual(Script.devanagari, classify(0x0915)); // क
}

test "splitScriptRuns: pure latin → 1 latin run" {
    var runs: std.ArrayListUnmanaged(ScriptRun) = .{};
    defer runs.deinit(testing.allocator);
    try splitScriptRuns("Hello World", 0, 11, &runs, testing.allocator);
    try testing.expectEqual(@as(usize, 1), runs.items.len);
    try testing.expectEqual(Script.latin, runs.items[0].script);
}

test "splitScriptRuns: latin + CJK + latin → 3 runs" {
    var runs: std.ArrayListUnmanaged(ScriptRun) = .{};
    defer runs.deinit(testing.allocator);

    // "Hi 中文 Bye" (utf-8): "Hi " latin + common, "中文" CJK 6 bytes, " Bye" common + latin
    // bytes: H=72, i=69, ' '=20 (3 bytes) + E4 B8 AD E6 96 87 (6 bytes) + ' Bye' (4 bytes) = 13 total
    const text = "Hi \xE4\xB8\xAD\xE6\x96\x87 Bye";
    try splitScriptRuns(text, 0, @intCast(text.len), &runs, testing.allocator);
    // 期望：latin run（含尾随空格 common）-> CJK run -> latin run（含 ' ' 前导 common）
    try testing.expectEqual(@as(usize, 3), runs.items.len);
    try testing.expectEqual(Script.latin, runs.items[0].script);
    try testing.expectEqual(Script.cjk, runs.items[1].script);
    try testing.expectEqual(Script.latin, runs.items[2].script);
}

test "splitScriptRuns: pure common (digits) → 1 common run" {
    var runs: std.ArrayListUnmanaged(ScriptRun) = .{};
    defer runs.deinit(testing.allocator);
    try splitScriptRuns("123 456", 0, 7, &runs, testing.allocator);
    try testing.expectEqual(@as(usize, 1), runs.items.len);
    try testing.expectEqual(Script.common, runs.items[0].script);
}

test "splitScriptRuns: hebrew run" {
    var runs: std.ArrayListUnmanaged(ScriptRun) = .{};
    defer runs.deinit(testing.allocator);
    // ש = D7 A9
    try splitScriptRuns("\xD7\xA9", 0, 2, &runs, testing.allocator);
    try testing.expectEqual(@as(usize, 1), runs.items.len);
    try testing.expectEqual(Script.hebrew, runs.items[0].script);
}

test "splitScriptRuns: empty range → 0 runs" {
    var runs: std.ArrayListUnmanaged(ScriptRun) = .{};
    defer runs.deinit(testing.allocator);
    try splitScriptRuns("hello", 2, 2, &runs, testing.allocator);
    try testing.expectEqual(@as(usize, 0), runs.items.len);
}

//! 文本脚本判定 / ASCII 分类 —— 与 encoder 状态零耦合的纯函数簇。
//!
//! 从 command_encoder.zig 析出（2026-08-05）。这一簇的共同点是**只看字节，
//! 不看 encoder**：入参全是 `[]const u8` + 标量，返回 bool/f32，不触
//! self、不分配、无副作用。它们回答的是同一个问题域 ——
//! “这段文本属于哪个书写系统 / 能不能走定宽 ASCII 快路径”，
//! 供 encoder 的字体回退选择（selectCjkFallbackFont）和定宽推进
//! （fixedMonospaceAdvance）决策使用。
//!
//! 与 font_selector.zig 的分工：那边挑**字体档位**（拿到 Font 句柄），
//! 这边只做**脚本判定**（纯谓词），font_selector 自己那份 isAllAscii 是
//! inline 的热路径私有副本，两边刻意不互相依赖。
//!
//! command_encoder.zig 保留同名 re-export，公共 API 与既有调用点不变。

const std = @import("std");

/// 整段是否全 ASCII（无 0x80+ 字节）。定宽快路径的前置条件。
pub fn isAllAscii(content: []const u8) bool {
    for (content) |b| {
        if (b >= 0x80) return false;
    }
    return true;
}

/// 定宽字体下每字符的固定推进宽度；不适用时返回 0。
///
/// monospace 长行路径的测量、滚动、命中、选区都按同一个固定 ASCII 单元格算，
/// 渲染必须用同一个宽度，否则大横向偏移下会累积 glyph-advance 漂移。
pub fn fixedMonospaceAdvance(content: []const u8, use_monospace_font: bool, monospace_char_width: f32) f32 {
    if (!use_monospace_font or monospace_char_width <= 0) return 0;
    return if (isAllAscii(content)) monospace_char_width else 0;
}

/// 韩文优先回退：含谚文且不含汉字/假名。
///
/// 混排（韩 + 中/日）时不走韩文档位 —— 韩文字体的汉字字形与中日排版不一致。
pub fn preferKoreanFallback(text: []const u8) bool {
    return containsHangul(text) and !containsHanOrKana(text);
}

/// CJK 回退：含汉字或假名即可。
pub fn preferCjkFallback(text: []const u8) bool {
    return containsHanOrKana(text);
}

/// 逐码点扫描的公共骨架：非法 UTF-8 字节跳过而非报错（渲染路径不能因为
/// 一个坏字节整段失败），truncated 尾序列直接停。
fn anyCodepoint(text: []const u8, comptime pred: fn (u21) bool) bool {
    var i: usize = 0;
    while (i < text.len) {
        const seq_len = std.unicode.utf8ByteSequenceLength(text[i]) catch {
            i += 1;
            continue;
        };
        if (i + seq_len > text.len) break;
        const cp = std.unicode.utf8Decode(text[i .. i + seq_len]) catch {
            i += seq_len;
            continue;
        };
        if (pred(cp)) return true;
        i += seq_len;
    }
    return false;
}

fn isHangulCodepoint(cp: u21) bool {
    return (cp >= 0x1100 and cp <= 0x11FF) or // Hangul Jamo
        (cp >= 0x3130 and cp <= 0x318F) or // Hangul Compatibility Jamo
        (cp >= 0xAC00 and cp <= 0xD7AF); // Hangul Syllables
}

fn isHanOrKanaCodepoint(cp: u21) bool {
    return (cp >= 0x3000 and cp <= 0x303F) or // CJK Symbols and Punctuation
        (cp >= 0x3040 and cp <= 0x309F) or // Hiragana
        (cp >= 0x30A0 and cp <= 0x30FF) or // Katakana
        (cp >= 0x3400 and cp <= 0x4DBF) or // CJK Ext A
        (cp >= 0x4E00 and cp <= 0x9FFF) or // CJK Unified Ideographs
        (cp >= 0xF900 and cp <= 0xFAFF); // CJK Compatibility Ideographs
}

pub fn containsHangul(text: []const u8) bool {
    return anyCodepoint(text, isHangulCodepoint);
}

pub fn containsHanOrKana(text: []const u8) bool {
    return anyCodepoint(text, isHanOrKanaCodepoint);
}

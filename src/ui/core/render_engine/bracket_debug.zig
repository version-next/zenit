//! display_list_lowering 的 PT-BRACKET 文本调试子系统。
//!
//! 由 `ZENIT_TEXT_BRACKET_DEBUG` env 启用；可选 `ZENIT_TEXT_BRACKET_NODE` 限定到
//! 某个 node id。lowering 路径每段 1-char text 命中时打印 origin / clip / effect /
//! 文字内容，给 PT-glitch 重现用。
//!
//! 从 display_list_lowering.zig (旧名 display_list_replay.zig) 拆出（v0.5 §5
//! GpuDraw epic B-3 子项），让主文件聚焦 lowering 核心；env 解析 + dedup 状态机
//! 本就独立，无 lowering 业务耦合。

const std = @import("std");

var bracket_debug_enabled_cache: ?bool = null;
var bracket_debug_last_frame: u64 = std.math.maxInt(u64);
var bracket_debug_last_node: u32 = 0;
var bracket_debug_last_start: u32 = 0;
var bracket_debug_last_end: u32 = 0;
var bracket_debug_node_cache: ?u32 = null;

pub fn bracketRenderDebugEnabled() bool {
    if (bracket_debug_enabled_cache) |v| return v;
    const raw = std.c.getenv("ZENIT_TEXT_BRACKET_DEBUG");
    if (raw == null) {
        bracket_debug_enabled_cache = false;
        return false;
    }
    const value = std.mem.span(raw.?);
    const enabled = !(value.len == 0 or std.mem.eql(u8, value, "0") or std.ascii.eqlIgnoreCase(value, "false"));
    bracket_debug_enabled_cache = enabled;
    return enabled;
}

pub fn shouldLogBracketReplay(frame: u64, node_id: u32, start: u32, end: u32) bool {
    if (bracket_debug_last_frame == frame and
        bracket_debug_last_node == node_id and
        bracket_debug_last_start == start and
        bracket_debug_last_end == end)
    {
        return false;
    }
    bracket_debug_last_frame = frame;
    bracket_debug_last_node = node_id;
    bracket_debug_last_start = start;
    bracket_debug_last_end = end;
    return true;
}

pub fn bracketDebugNodeFilter() ?u32 {
    if (bracket_debug_node_cache) |v| return if (v == std.math.maxInt(u32)) null else v;
    const raw = std.c.getenv("ZENIT_TEXT_BRACKET_NODE") orelse {
        bracket_debug_node_cache = std.math.maxInt(u32);
        return null;
    };
    const value = std.mem.span(raw);
    const parsed = std.fmt.parseInt(u32, value, 10) catch {
        bracket_debug_node_cache = std.math.maxInt(u32);
        return null;
    };
    bracket_debug_node_cache = parsed;
    return parsed;
}

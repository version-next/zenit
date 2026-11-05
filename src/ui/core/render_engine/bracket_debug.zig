//! PT-BRACKET text debug subsystem for display_list_lowering.
//!
//! Enabled by ZENIT_TEXT_BRACKET_DEBUG env var; optionally ZENIT_TEXT_BRACKET_NODE limits to
//! a node id. The lowering path prints origin / clip / effect / text content on each 1-char
//! text match, for PT-glitch reproduction.
//!
//! Split out of display_list_lowering.zig so that file focuses on lowering core; env parsing
//! + dedup state machine is independent with no lowering business coupling.

const std = @import("std");

var bracket_debug_enabled_cache: ?bool = null;
var bracket_debug_last_frame: u64 = std.math.maxInt(u64);
var bracket_debug_last_node: u32 = 0;
var bracket_debug_last_start: u32 = 0;
var bracket_debug_last_end: u32 = 0;
var bracket_debug_node_cache: ?u32 = null;

pub fn bracketRenderDebugEnabled() bool {
    if (bracket_debug_enabled_cache) |v| return v;
    const raw = @import("zenit_environment").getNative("ZENIT_TEXT_BRACKET_DEBUG");
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
    const raw = @import("zenit_environment").getNative("ZENIT_TEXT_BRACKET_NODE") orelse {
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

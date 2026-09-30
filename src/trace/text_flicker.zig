const std = @import("std");

var enabled_cache: ?bool = null;
var frame_budget_frame: u64 = std.math.maxInt(u64);
var frame_budget_used: u32 = 0;

const FRAME_LOG_BUDGET: u32 = 96;

pub fn enabled() bool {
    if (enabled_cache) |value| return value;

    const raw = std.c.getenv("ZENIT_TEXT_FLICKER_TRACE") orelse std.c.getenv("ZENIT_MD_FLICKER_DEBUG");
    if (raw == null) {
        enabled_cache = false;
        return false;
    }

    const text = std.mem.span(raw.?);
    const value = !(text.len == 0 or std.mem.eql(u8, text, "0") or std.ascii.eqlIgnoreCase(text, "false"));
    enabled_cache = value;
    return value;
}

fn allowForFrame(frame_id: u64) bool {
    if (!enabled()) return false;
    if (frame_budget_frame != frame_id) {
        frame_budget_frame = frame_id;
        frame_budget_used = 0;
    }
    if (frame_budget_used >= FRAME_LOG_BUDGET) return false;
    frame_budget_used += 1;
    return true;
}

pub fn log(frame_id: u64, comptime fmt: []const u8, args: anytype) void {
    if (!allowForFrame(frame_id)) return;
    std.debug.print("[TextFlickerTrace f={d}] ", .{frame_id});
    std.debug.print(fmt ++ "\n", args);
}

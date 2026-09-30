/// ScrollArea 调试日志
///
/// 调试专用日志开关（默认关闭，设置环境变量 ZENIT_SCROLL_DEBUG=1 可开启）
const std = @import("std");

var debug_scroll_log_cached: ?bool = null;
var log_base_time: ?std.time.Instant = null;
var log_last_time: ?std.time.Instant = null;
var log_last_emit_time: ?std.time.Instant = null;
var min_interval_ns_cache: ?u64 = null;

pub fn scrollDebugEnabled() bool {
    const root = @import("root");
    if (comptime @hasDecl(root, "build_options")) {
        if (comptime root.build_options.test_mode) return true;
    }
    if (debug_scroll_log_cached) |v| return v;
    const raw = std.c.getenv("ZENIT_SCROLL_DEBUG");
    if (raw == null) {
        debug_scroll_log_cached = false;
        return false;
    }
    const value = std.mem.span(raw.?);
    if (value.len == 0) {
        debug_scroll_log_cached = false;
        return false;
    }
    if (std.mem.eql(u8, value, "0") or std.ascii.eqlIgnoreCase(value, "false")) {
        debug_scroll_log_cached = false;
        return false;
    }
    debug_scroll_log_cached = true;
    return true;
}

fn minIntervalNs() u64 {
    if (min_interval_ns_cache) |v| return v;
    const raw = std.c.getenv("ZENIT_SCROLL_DEBUG_MIN_INTERVAL_MS");
    if (raw) |ptr| {
        const value = std.mem.span(ptr);
        if (std.fmt.parseInt(u64, value, 10)) |parsed_ms| {
            const parsed = parsed_ms * std.time.ns_per_ms;
            min_interval_ns_cache = parsed;
            return parsed;
        } else |_| {}
    }
    const default_ns = 33 * std.time.ns_per_ms;
    min_interval_ns_cache = default_ns;
    return default_ns;
}

pub fn logScroll(comptime fmt: []const u8, args: anytype) void {
    if (!scrollDebugEnabled()) return;
    const now = std.time.Instant.now() catch return;
    if (log_last_emit_time) |last_emit| {
        const since_emit_ns = now.since(last_emit);
        const min_interval = minIntervalNs();
        if (min_interval > 0 and since_emit_ns < min_interval) return;
    }
    if (log_base_time == null) log_base_time = now;
    const since_base_ns: u64 = now.since(log_base_time.?);
    const delta_ns: u64 = if (log_last_time) |last| now.since(last) else 0;
    log_last_time = now;
    log_last_emit_time = now;
    const since_ms: f64 = @as(f64, @floatFromInt(since_base_ns)) / 1_000_000.0;
    const delta_ms: f64 = @as(f64, @floatFromInt(delta_ns)) / 1_000_000.0;
    std.debug.print("[ScrollArea t={d:.1}ms +{d:.1}ms] ", .{ since_ms, delta_ms });
    std.debug.print(fmt ++ "\n", args);
}

//! Per-Cx diagnostic console.
//!
//! Messages are written to stderr and to a bounded in-memory store. DevTools
//! and the E2E harness consume the store using a monotonic sequence cursor.
const std = @import("std");
const utf8 = @import("text_core").utf8;
const builtin = @import("builtin");

pub const Level = enum(u8) {
    debug,
    log,
    info,
    warn,
    err,

    pub fn label(self: Level) []const u8 {
        return switch (self) {
            .debug => "debug",
            .log => "log",
            .info => "info",
            .warn => "warn",
            .err => "error",
        };
    }

    fn passes(self: Level, minimum: ?Level) bool {
        const min = minimum orelse return false;
        return @intFromEnum(self) >= @intFromEnum(min);
    }
};

pub const Kind = enum(u8) {
    message,
    assertion,
    group,
    group_collapsed,
    counter,
    timer,
    trace,
};

pub const SourceLocation = struct {
    file: []const u8,
    fn_name: []const u8,
    line: u32,
    column: u32,

    pub fn from(src: std.builtin.SourceLocation) SourceLocation {
        return .{ .file = src.file, .fn_name = src.fn_name, .line = src.line, .column = src.column };
    }
};

pub const Event = struct {
    seq: u64,
    monotonic_us: u64,
    thread_id: u64,
    level: Level,
    kind: Kind,
    scope: []u8,
    group_depth: u16,
    message: []u8,
    source: ?SourceLocation,
    truncated: bool = false,

    pub fn deinit(self: *Event, allocator: std.mem.Allocator) void {
        allocator.free(self.scope);
        allocator.free(self.message);
        self.* = undefined;
    }

    fn clone(self: *const Event, allocator: std.mem.Allocator) !Event {
        const scope = try allocator.dupe(u8, self.scope);
        errdefer allocator.free(scope);
        const message = try allocator.dupe(u8, self.message);
        return .{
            .seq = self.seq,
            .monotonic_us = self.monotonic_us,
            .thread_id = self.thread_id,
            .level = self.level,
            .kind = self.kind,
            .scope = scope,
            .group_depth = self.group_depth,
            .message = message,
            .source = self.source,
            .truncated = self.truncated,
        };
    }
};

pub const Config = struct {
    /// null disables the corresponding sink.
    terminal_level: ?Level = .debug,
    capture_level: ?Level = .debug,
    max_entries: usize = 10_000,
    max_bytes: usize = 8 * 1024 * 1024,
    max_entry_bytes: usize = 64 * 1024,
};

/// Privacy-conscious application defaults. Plain `Cx.init` remains
/// deterministic for tests, while `zenit_app.Config` uses this policy.
pub fn defaultConfig() Config {
    return switch (builtin.mode) {
        .Debug => .{},
        .ReleaseSafe => .{ .terminal_level = .info, .capture_level = .info },
        .ReleaseFast, .ReleaseSmall => .{ .terminal_level = .warn, .capture_level = null },
    };
}

pub const Stats = struct {
    oldest_seq: u64 = 0,
    newest_seq: u64 = 0,
    live_entries: usize = 0,
    live_bytes: usize = 0,
    evicted_total: u64 = 0,
    dropped_oom: u64 = 0,
    dropped_oversize: u64 = 0,
    clear_generation: u64 = 0,
};

pub const Snapshot = struct {
    events: []Event,
    next_cursor: u64,
    oldest_seq: u64,
    newest_seq: u64,
    gap: bool,
    has_more: bool,
    evicted_total: u64,
    dropped_oom: u64,
    dropped_oversize: u64,
    clear_generation: u64,

    pub fn deinit(self: *Snapshot, allocator: std.mem.Allocator) void {
        for (self.events) |*event| event.deinit(allocator);
        allocator.free(self.events);
        self.* = undefined;
    }
};

const CounterState = struct { value: u64 };

/// Address-stable diagnostic store. Do not copy after initialization.
pub const Console = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    config: Config,
    events: std.ArrayList(Event) = .empty,
    head: usize = 0,
    live_bytes: usize = 0,
    next_seq: u64 = 1,
    started_ns: i128,
    revision_value: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    evicted_total: u64 = 0,
    dropped_oom: u64 = 0,
    dropped_oversize: u64 = 0,
    clear_generation: u64 = 0,
    group_depths: std.AutoHashMap(std.Thread.Id, u16),
    counters: std.StringHashMap(CounterState),
    timers: std.StringHashMap(i128),

    threadlocal var in_emit: bool = false;

    pub fn init(allocator: std.mem.Allocator, config: Config) Console {
        return .{
            .allocator = allocator,
            .config = normalizedConfig(config),
            .started_ns = std.time.nanoTimestamp(),
            .group_depths = std.AutoHashMap(std.Thread.Id, u16).init(allocator),
            .counters = std.StringHashMap(CounterState).init(allocator),
            .timers = std.StringHashMap(i128).init(allocator),
        };
    }

    pub fn deinit(self: *Console) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.freeAllEventsLocked();
        self.events.deinit(self.allocator);
        self.group_depths.deinit();
        freeStringMapKeys(CounterState, self.allocator, &self.counters);
        self.counters.deinit();
        freeStringMapKeys(i128, self.allocator, &self.timers);
        self.timers.deinit();
    }

    pub fn configure(self: *Console, config: Config) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.config = normalizedConfig(config);
        self.enforceBoundsLocked();
        self.bumpRevisionLocked();
    }

    pub fn revision(self: *const Console) u64 {
        return self.revision_value.load(.monotonic);
    }

    pub inline fn debug(self: *Console, comptime fmt: []const u8, args: anytype) void {
        self.emitFmt(.debug, .message, "", fmt, args, null);
    }
    pub inline fn log(self: *Console, comptime fmt: []const u8, args: anytype) void {
        self.emitFmt(.log, .message, "", fmt, args, null);
    }
    pub inline fn info(self: *Console, comptime fmt: []const u8, args: anytype) void {
        self.emitFmt(.info, .message, "", fmt, args, null);
    }
    pub inline fn warn(self: *Console, comptime fmt: []const u8, args: anytype) void {
        self.emitFmt(.warn, .message, "", fmt, args, null);
    }
    pub inline fn err(self: *Console, comptime fmt: []const u8, args: anytype) void {
        self.emitFmt(.err, .message, "", fmt, args, null);
    }
    pub inline fn assert(self: *Console, condition: bool, comptime fmt: []const u8, args: anytype) void {
        if (!condition) self.emitFmt(.err, .assertion, "", fmt, args, null);
    }
    pub inline fn trace(self: *Console, comptime fmt: []const u8, args: anytype) void {
        self.emitFmt(.debug, .trace, "", fmt, args, null);
    }
    pub inline fn inspect(self: *Console, comptime label: []const u8, value: anytype) void {
        self.emitFmt(.log, .message, "", label ++ " = {any}", .{value}, null);
    }
    /// Structured rendering can be added without changing the storage model;
    /// the initial implementation intentionally matches `console.table` with
    /// a readable text fallback.
    pub inline fn table(self: *Console, value: anytype) void {
        self.emitFmt(.log, .message, "", "{any}", .{value}, null);
    }
    pub inline fn group(self: *Console, comptime fmt: []const u8, args: anytype) void {
        self.emitFmt(.log, .group, "", fmt, args, null);
        self.adjustGroupDepth(1);
    }
    pub inline fn groupCollapsed(self: *Console, comptime fmt: []const u8, args: anytype) void {
        self.emitFmt(.log, .group_collapsed, "", fmt, args, null);
        self.adjustGroupDepth(1);
    }

    /// Zig has no default function arguments/macros, so callers that want a
    /// clickable source location pass `@src()` explicitly.
    pub inline fn writeAt(self: *Console, level: Level, comptime src: std.builtin.SourceLocation, comptime fmt: []const u8, args: anytype) void {
        self.emitFmt(level, .message, "", fmt, args, SourceLocation.from(src));
    }
    pub fn groupEnd(self: *Console) void {
        self.adjustGroupDepth(-1);
    }

    pub fn count(self: *Console, label: []const u8) void {
        self.countScoped("", label);
    }

    fn countScoped(self: *Console, scope: []const u8, label: []const u8) void {
        const value = self.incrementCounter(scope, label) catch {
            self.noteOom();
            return;
        };
        self.emitFmt(.info, .counter, scope, "{s}: {d}", .{ label, value }, null);
    }

    pub fn countReset(self: *Console, label: []const u8) void {
        self.countResetScoped("", label);
    }

    fn countResetScoped(self: *Console, scope: []const u8, label: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const key = self.stateKeyLocked(scope, label) catch {
            self.dropped_oom += 1;
            self.bumpRevisionLocked();
            return;
        };
        defer self.allocator.free(key);
        if (self.counters.fetchRemove(key)) |entry| self.allocator.free(entry.key);
    }

    pub fn time(self: *Console, label: []const u8) void {
        self.timeScoped("", label);
    }

    fn timeScoped(self: *Console, scope: []const u8, label: []const u8) void {
        var already_exists = false;
        self.mutex.lock();
        const key = self.stateKeyLocked(scope, label) catch {
            self.dropped_oom += 1;
            self.bumpRevisionLocked();
            self.mutex.unlock();
            return;
        };
        if (self.timers.contains(key)) {
            self.allocator.free(key);
            already_exists = true;
        } else self.timers.put(key, std.time.nanoTimestamp()) catch {
            self.allocator.free(key);
            self.dropped_oom += 1;
            self.bumpRevisionLocked();
        };
        self.mutex.unlock();
        if (already_exists) self.emitFmt(.warn, .timer, scope, "Timer '{s}' already exists", .{label}, null);
    }

    pub fn timeLog(self: *Console, label: []const u8) void {
        self.timeLogScoped("", label);
    }

    fn timeLogScoped(self: *Console, scope: []const u8, label: []const u8) void {
        const elapsed = self.elapsedTimerMs(scope, label, false) orelse {
            self.emitFmt(.warn, .timer, scope, "Timer '{s}' does not exist", .{label}, null);
            return;
        };
        self.emitFmt(.info, .timer, scope, "{s}: {d:.3} ms", .{ label, elapsed }, null);
    }

    pub fn timeEnd(self: *Console, label: []const u8) void {
        self.timeEndScoped("", label);
    }

    fn timeEndScoped(self: *Console, scope: []const u8, label: []const u8) void {
        const elapsed = self.elapsedTimerMs(scope, label, true) orelse {
            self.emitFmt(.warn, .timer, scope, "Timer '{s}' does not exist", .{label}, null);
            return;
        };
        self.emitFmt(.info, .timer, scope, "{s}: {d:.3} ms", .{ label, elapsed }, null);
    }

    pub fn scoped(self: *Console, scope: []const u8) ScopedConsole {
        return .{ .parent = self, .scope_name = scope };
    }

    pub fn clear(self: *Console) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.freeAllEventsLocked();
        self.clear_generation +%= 1;
        self.bumpRevisionLocked();
    }

    pub fn stats(self: *Console) Stats {
        self.mutex.lock();
        defer self.mutex.unlock();
        const live = self.liveCountLocked();
        return .{
            .oldest_seq = if (live == 0) 0 else self.events.items[self.head].seq,
            .newest_seq = if (live == 0) 0 else self.events.items[self.events.items.len - 1].seq,
            .live_entries = live,
            .live_bytes = self.live_bytes,
            .evicted_total = self.evicted_total,
            .dropped_oom = self.dropped_oom,
            .dropped_oversize = self.dropped_oversize,
            .clear_generation = self.clear_generation,
        };
    }

    pub fn snapshotSince(self: *Console, allocator: std.mem.Allocator, after_seq: u64, max_events: usize) !Snapshot {
        self.mutex.lock();
        defer self.mutex.unlock();
        const live = self.liveCountLocked();
        const oldest = if (live == 0) 0 else self.events.items[self.head].seq;
        const newest = if (live == 0) 0 else self.events.items[self.events.items.len - 1].seq;
        const gap = after_seq != 0 and live != 0 and after_seq +| 1 < oldest;
        var start = self.head;
        while (start < self.events.items.len and self.events.items[start].seq <= after_seq) : (start += 1) {}
        const available = self.events.items.len - start;
        const take = @min(available, max_events);
        const out = try allocator.alloc(Event, take);
        errdefer allocator.free(out);
        var initialized: usize = 0;
        errdefer for (out[0..initialized]) |*event| event.deinit(allocator);
        for (self.events.items[start .. start + take], 0..) |*event, i| {
            out[i] = try event.clone(allocator);
            initialized += 1;
        }
        return .{
            .events = out,
            .next_cursor = if (take == 0) after_seq else out[take - 1].seq,
            .oldest_seq = oldest,
            .newest_seq = newest,
            .gap = gap,
            .has_more = available > take,
            .evicted_total = self.evicted_total,
            .dropped_oom = self.dropped_oom,
            .dropped_oversize = self.dropped_oversize,
            .clear_generation = self.clear_generation,
        };
    }

    fn emitFmt(self: *Console, level: Level, kind: Kind, scope: []const u8, comptime fmt: []const u8, args: anytype, source: ?SourceLocation) void {
        if (in_emit) {
            std.debug.print("[console/reentrant][{s}] " ++ fmt ++ "\n", .{level.label()} ++ args);
            return;
        }
        in_emit = true;
        defer in_emit = false;
        self.mutex.lock();
        defer self.mutex.unlock();
        // Configuration is mutable, so sink thresholds must be read under the
        // same lock as configure(). This keeps logging safe while a harness
        // changes capture limits from another thread.
        if (!level.passes(self.config.capture_level) and !level.passes(self.config.terminal_level)) return;
        const message = std.fmt.allocPrint(self.allocator, fmt, args) catch {
            self.dropped_oom += 1;
            self.bumpRevisionLocked();
            std.debug.print("[console][{s}] <format allocation failed>\n", .{level.label()});
            return;
        };
        defer self.allocator.free(message);
        if (level.passes(self.config.capture_level)) self.captureLocked(level, kind, scope, message, source);
        if (level.passes(self.config.terminal_level)) {
            if (scope.len == 0) std.debug.print("[{s}] {s}\n", .{ level.label(), message }) else std.debug.print("[{s}][{s}] {s}\n", .{ level.label(), scope, message });
        }
    }

    fn captureLocked(self: *Console, level: Level, kind: Kind, scope_text: []const u8, raw_message: []const u8, source: ?SourceLocation) void {
        if (self.config.max_entries == 0 or self.config.max_bytes == 0) {
            self.dropped_oversize += 1;
            self.bumpRevisionLocked();
            return;
        }
        const max_len = @min(self.config.max_entry_bytes, self.config.max_bytes);
        const message_len = validUtf8PrefixLen(raw_message, @min(raw_message.len, max_len));
        const scope_copy = self.allocator.dupe(u8, scope_text) catch {
            self.dropped_oom += 1;
            self.bumpRevisionLocked();
            return;
        };
        const message_copy = self.allocator.dupe(u8, raw_message[0..message_len]) catch {
            self.allocator.free(scope_copy);
            self.dropped_oom += 1;
            self.bumpRevisionLocked();
            return;
        };
        const event_bytes = scope_copy.len + message_copy.len;
        if (event_bytes > self.config.max_bytes) {
            self.allocator.free(scope_copy);
            self.allocator.free(message_copy);
            self.dropped_oversize += 1;
            self.bumpRevisionLocked();
            return;
        }
        const thread_id = std.Thread.getCurrentId();
        const now = std.time.nanoTimestamp();
        const delta = @max(@as(i128, 0), now - self.started_ns);
        const event: Event = .{
            .seq = self.next_seq,
            .monotonic_us = @intCast(@divTrunc(delta, std.time.ns_per_us)),
            .thread_id = @intCast(thread_id),
            .level = level,
            .kind = kind,
            .scope = scope_copy,
            .group_depth = self.group_depths.get(thread_id) orelse 0,
            .message = message_copy,
            .source = source,
            .truncated = message_len < raw_message.len,
        };
        self.events.append(self.allocator, event) catch {
            var mutable = event;
            mutable.deinit(self.allocator);
            self.dropped_oom += 1;
            self.bumpRevisionLocked();
            return;
        };
        self.next_seq +%= 1;
        self.live_bytes += event_bytes;
        self.enforceBoundsLocked();
        self.bumpRevisionLocked();
    }

    fn enforceBoundsLocked(self: *Console) void {
        while (self.liveCountLocked() > self.config.max_entries or self.live_bytes > self.config.max_bytes) {
            const event = &self.events.items[self.head];
            self.live_bytes -= event.scope.len + event.message.len;
            event.deinit(self.allocator);
            self.head += 1;
            self.evicted_total += 1;
        }
        self.compactLocked();
    }

    fn compactLocked(self: *Console) void {
        if (self.head == 0) return;
        if (self.head < 256 and self.head * 2 < self.events.items.len) return;
        const live = self.liveCountLocked();
        std.mem.copyForwards(Event, self.events.items[0..live], self.events.items[self.head..]);
        self.events.items.len = live;
        self.head = 0;
    }

    fn freeAllEventsLocked(self: *Console) void {
        for (self.events.items[self.head..]) |*event| event.deinit(self.allocator);
        self.events.clearRetainingCapacity();
        self.head = 0;
        self.live_bytes = 0;
    }
    fn liveCountLocked(self: *const Console) usize {
        return self.events.items.len - self.head;
    }
    fn bumpRevisionLocked(self: *Console) void {
        _ = self.revision_value.fetchAdd(1, .monotonic);
    }

    fn adjustGroupDepth(self: *Console, delta: i8) void {
        const thread_id = std.Thread.getCurrentId();
        self.mutex.lock();
        defer self.mutex.unlock();
        const old = self.group_depths.get(thread_id) orelse 0;
        if (delta > 0) {
            self.group_depths.put(thread_id, old +| 1) catch {
                self.dropped_oom += 1;
            };
        } else if (old <= 1) {
            _ = self.group_depths.remove(thread_id);
        } else {
            self.group_depths.put(thread_id, old - 1) catch {
                self.dropped_oom += 1;
            };
        }
    }

    fn incrementCounter(self: *Console, scope: []const u8, label: []const u8) !u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const key = try self.stateKeyLocked(scope, label);
        if (self.counters.getPtr(key)) |state| {
            self.allocator.free(key);
            state.value +|= 1;
            return state.value;
        }
        errdefer self.allocator.free(key);
        try self.counters.put(key, .{ .value = 1 });
        return 1;
    }

    fn elapsedTimerMs(self: *Console, scope: []const u8, label: []const u8, remove: bool) ?f64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const key = self.stateKeyLocked(scope, label) catch {
            self.dropped_oom += 1;
            self.bumpRevisionLocked();
            return null;
        };
        defer self.allocator.free(key);
        const start = self.timers.get(key) orelse return null;
        if (remove) {
            const entry = self.timers.fetchRemove(key).?;
            self.allocator.free(entry.key);
        }
        const elapsed_ns = @max(@as(i128, 0), std.time.nanoTimestamp() - start);
        return @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, std.time.ns_per_ms);
    }

    fn stateKeyLocked(self: *Console, scope: []const u8, label: []const u8) ![]u8 {
        return std.fmt.allocPrint(self.allocator, "{d}:{d}:{s}:{s}", .{ std.Thread.getCurrentId(), scope.len, scope, label });
    }

    fn noteOom(self: *Console) void {
        self.mutex.lock();
        self.dropped_oom += 1;
        self.bumpRevisionLocked();
        self.mutex.unlock();
    }
};

pub const ScopedConsole = struct {
    parent: *Console,
    scope_name: []const u8,

    pub inline fn debug(self: ScopedConsole, comptime fmt: []const u8, args: anytype) void {
        self.parent.emitFmt(.debug, .message, self.scope_name, fmt, args, null);
    }
    pub inline fn log(self: ScopedConsole, comptime fmt: []const u8, args: anytype) void {
        self.parent.emitFmt(.log, .message, self.scope_name, fmt, args, null);
    }
    pub inline fn info(self: ScopedConsole, comptime fmt: []const u8, args: anytype) void {
        self.parent.emitFmt(.info, .message, self.scope_name, fmt, args, null);
    }
    pub inline fn warn(self: ScopedConsole, comptime fmt: []const u8, args: anytype) void {
        self.parent.emitFmt(.warn, .message, self.scope_name, fmt, args, null);
    }
    pub inline fn err(self: ScopedConsole, comptime fmt: []const u8, args: anytype) void {
        self.parent.emitFmt(.err, .message, self.scope_name, fmt, args, null);
    }
    pub inline fn assert(self: ScopedConsole, condition: bool, comptime fmt: []const u8, args: anytype) void {
        if (!condition) self.parent.emitFmt(.err, .assertion, self.scope_name, fmt, args, null);
    }
    pub inline fn trace(self: ScopedConsole, comptime fmt: []const u8, args: anytype) void {
        self.parent.emitFmt(.debug, .trace, self.scope_name, fmt, args, null);
    }
    pub inline fn inspect(self: ScopedConsole, comptime label: []const u8, value: anytype) void {
        self.parent.emitFmt(.log, .message, self.scope_name, label ++ " = {any}", .{value}, null);
    }
    pub inline fn table(self: ScopedConsole, value: anytype) void {
        self.parent.emitFmt(.log, .message, self.scope_name, "{any}", .{value}, null);
    }
    pub inline fn group(self: ScopedConsole, comptime fmt: []const u8, args: anytype) void {
        self.parent.emitFmt(.log, .group, self.scope_name, fmt, args, null);
        self.parent.adjustGroupDepth(1);
    }
    pub inline fn groupCollapsed(self: ScopedConsole, comptime fmt: []const u8, args: anytype) void {
        self.parent.emitFmt(.log, .group_collapsed, self.scope_name, fmt, args, null);
        self.parent.adjustGroupDepth(1);
    }
    pub fn groupEnd(self: ScopedConsole) void {
        self.parent.groupEnd();
    }
    pub fn count(self: ScopedConsole, label: []const u8) void {
        self.parent.countScoped(self.scope_name, label);
    }
    pub fn countReset(self: ScopedConsole, label: []const u8) void {
        self.parent.countResetScoped(self.scope_name, label);
    }
    pub fn time(self: ScopedConsole, label: []const u8) void {
        self.parent.timeScoped(self.scope_name, label);
    }
    pub fn timeLog(self: ScopedConsole, label: []const u8) void {
        self.parent.timeLogScoped(self.scope_name, label);
    }
    pub fn timeEnd(self: ScopedConsole, label: []const u8) void {
        self.parent.timeEndScoped(self.scope_name, label);
    }
};

fn normalizedConfig(config: Config) Config {
    var out = config;
    out.max_entry_bytes = @max(@as(usize, 1), out.max_entry_bytes);
    return out;
}

/// 统一走 text_core.utf8（此前这里是同一个扫描的第三份拷贝）
fn validUtf8PrefixLen(text: []const u8, limit: usize) usize {
    return utf8.validPrefixLen(text, limit);
}

fn freeStringMapKeys(comptime V: type, allocator: std.mem.Allocator, map: *std.StringHashMap(V)) void {
    var it = map.keyIterator();
    while (it.next()) |key| allocator.free(key.*);
}

test "console captures levels, source and monotonic sequence" {
    var console = Console.init(std.testing.allocator, .{ .terminal_level = null });
    defer console.deinit();
    console.writeAt(.info, @src(), "hello {d}", .{42});
    console.warn("careful", .{});
    var snapshot = try console.snapshotSince(std.testing.allocator, 0, 20);
    defer snapshot.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), snapshot.events.len);
    try std.testing.expectEqualStrings("hello 42", snapshot.events[0].message);
    try std.testing.expectEqual(Level.warn, snapshot.events[1].level);
    try std.testing.expect(snapshot.events[0].source != null);
    try std.testing.expectEqual(@as(u64, 2), snapshot.next_cursor);
}

test "console eviction is bounded" {
    var console = Console.init(std.testing.allocator, .{ .terminal_level = null, .max_entries = 2, .max_bytes = 1024 });
    defer console.deinit();
    console.log("one", .{});
    console.log("two", .{});
    console.log("three", .{});
    const stats = console.stats();
    try std.testing.expectEqual(@as(usize, 2), stats.live_entries);
    try std.testing.expectEqual(@as(u64, 1), stats.evicted_total);
    var snapshot = try console.snapshotSince(std.testing.allocator, 1, 20);
    defer snapshot.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("two", snapshot.events[0].message);
}

test "console clear keeps sequence monotonic" {
    var console = Console.init(std.testing.allocator, .{ .terminal_level = null });
    defer console.deinit();
    console.log("before", .{});
    console.clear();
    console.log("after", .{});
    var snapshot = try console.snapshotSince(std.testing.allocator, 0, 20);
    defer snapshot.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), snapshot.events.len);
    try std.testing.expectEqual(@as(u64, 2), snapshot.events[0].seq);
    try std.testing.expectEqual(@as(u64, 1), snapshot.clear_generation);
}

test "console group counter and timer helpers emit events" {
    var console = Console.init(std.testing.allocator, .{ .terminal_level = null });
    defer console.deinit();
    console.group("work", .{});
    console.count("retry");
    console.count("retry");
    console.time("load");
    console.timeLog("load");
    console.timeEnd("load");
    console.groupEnd();
    var snapshot = try console.snapshotSince(std.testing.allocator, 0, 20);
    defer snapshot.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 5), snapshot.events.len);
    try std.testing.expectEqual(@as(u16, 1), snapshot.events[1].group_depth);
    try std.testing.expectEqualStrings("retry: 2", snapshot.events[2].message);
}

test "two consoles never share events" {
    var a = Console.init(std.testing.allocator, .{ .terminal_level = null });
    defer a.deinit();
    var b = Console.init(std.testing.allocator, .{ .terminal_level = null });
    defer b.deinit();
    a.info("only-a", .{});
    b.err("only-b", .{});
    var sa = try a.snapshotSince(std.testing.allocator, 0, 10);
    defer sa.deinit(std.testing.allocator);
    var sb = try b.snapshotSince(std.testing.allocator, 0, 10);
    defer sb.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("only-a", sa.events[0].message);
    try std.testing.expectEqualStrings("only-b", sb.events[0].message);
}

test "console truncation preserves valid UTF-8 and reports truncation" {
    var console = Console.init(std.testing.allocator, .{ .terminal_level = null, .max_entry_bytes = 5 });
    defer console.deinit();
    console.log("ééé", .{});
    var snapshot = try console.snapshotSince(std.testing.allocator, 0, 10);
    defer snapshot.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), snapshot.events.len);
    try std.testing.expectEqualStrings("éé", snapshot.events[0].message);
    try std.testing.expect(snapshot.events[0].truncated);
    try std.testing.expect(std.unicode.utf8ValidateSlice(snapshot.events[0].message));
}

test "console invalid UTF-8 prefix scan is linear and stops at first bad byte" {
    var invalid = [_]u8{0x80} ** (64 * 1024);
    try std.testing.expectEqual(@as(usize, 0), validUtf8PrefixLen(&invalid, invalid.len / 2));

    const mixed = "ok" ++ [_]u8{ 0xF0, 0x28, 0x8C, 0x28 };
    try std.testing.expectEqual(@as(usize, 2), validUtf8PrefixLen(mixed, mixed.len));
}

test "console snapshot pagination and eviction gap are explicit" {
    var console = Console.init(std.testing.allocator, .{ .terminal_level = null, .max_entries = 3 });
    defer console.deinit();
    for (0..5) |i| console.log("event-{d}", .{i});

    var first = try console.snapshotSince(std.testing.allocator, 1, 2);
    defer first.deinit(std.testing.allocator);
    try std.testing.expect(first.gap);
    try std.testing.expect(first.has_more);
    try std.testing.expectEqual(@as(usize, 2), first.events.len);
    try std.testing.expectEqual(@as(u64, 3), first.events[0].seq);

    var second = try console.snapshotSince(std.testing.allocator, first.next_cursor, 2);
    defer second.deinit(std.testing.allocator);
    try std.testing.expect(!second.has_more);
    try std.testing.expectEqual(@as(usize, 1), second.events.len);
    try std.testing.expectEqual(@as(u64, 5), second.events[0].seq);
}

test "console accepts concurrent writers without losing sequence uniqueness" {
    var console = Console.init(std.testing.allocator, .{ .terminal_level = null, .max_entries = 1000 });
    defer console.deinit();

    const Writer = struct {
        fn run(target: *Console, writer_id: usize) void {
            for (0..100) |i| target.debug("writer-{d}:{d}", .{ writer_id, i });
        }
    };
    var threads: [4]std.Thread = undefined;
    for (&threads, 0..) |*thread, i| thread.* = try std.Thread.spawn(.{}, Writer.run, .{ &console, i });
    for (&threads) |thread| thread.join();

    var snapshot = try console.snapshotSince(std.testing.allocator, 0, 1000);
    defer snapshot.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 400), snapshot.events.len);
    for (snapshot.events, 0..) |event, i| try std.testing.expectEqual(@as(u64, @intCast(i + 1)), event.seq);
}

test "counter labels are isolated by thread and scope" {
    var console = Console.init(std.testing.allocator, .{ .terminal_level = null });
    defer console.deinit();
    const CounterWriter = struct {
        fn run(target: *Console, scope_name: []const u8) void {
            target.scoped(scope_name).count("retry");
        }
    };
    const a = try std.Thread.spawn(.{}, CounterWriter.run, .{ &console, "network" });
    const b = try std.Thread.spawn(.{}, CounterWriter.run, .{ &console, "storage" });
    a.join();
    b.join();

    var snapshot = try console.snapshotSince(std.testing.allocator, 0, 10);
    defer snapshot.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), snapshot.events.len);
    for (snapshot.events) |event| try std.testing.expectEqualStrings("retry: 1", event.message);
}

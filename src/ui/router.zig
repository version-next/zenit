/// 声明式路由系统 — 基于 Signal + Match 的页面导航
///
/// 用法:
/// ```zig
/// const Page = enum { welcome, editor, settings };
/// var router = try Router(Page).init(scope, .welcome);
/// var params: RouteParams = .{};
/// try params.set("file", "test.md");
/// router.navigate(.editor, params);
/// router.back(); // 回到 welcome
/// // mount 时内部自动用 Match 切换页面
/// ```
const std = @import("std");
const Scope = @import("reactive/scope.zig").Scope;
const Signal = @import("reactive/signal.zig").Signal;
const SignalOwner = @import("reactive/owner.zig").SignalOwner;

/// 路由参数
pub const RouteParams = struct {
    pub const max_params = 8;
    pub const max_key_len = 64;
    pub const max_value_len = 512;
    pub const Error = error{
        TooManyParams,
        KeyTooLong,
        ValueTooLong,
    };

    entries: [max_params]ParamEntry = [_]ParamEntry{.{}} ** max_params,
    count: u8 = 0,

    const ParamEntry = struct {
        key_buf: [max_key_len]u8 = [_]u8{0} ** max_key_len,
        key_len: u8 = 0,
        value_buf: [max_value_len]u8 = [_]u8{0} ** max_value_len,
        value_len: u16 = 0,

        fn init(param_key: []const u8, param_value: []const u8) Error!ParamEntry {
            if (param_key.len > max_key_len) return error.KeyTooLong;
            if (param_value.len > max_value_len) return error.ValueTooLong;

            var entry = ParamEntry{};
            @memcpy(entry.key_buf[0..param_key.len], param_key);
            entry.key_len = @intCast(param_key.len);
            @memcpy(entry.value_buf[0..param_value.len], param_value);
            entry.value_len = @intCast(param_value.len);
            return entry;
        }

        fn key(self: *const ParamEntry) []const u8 {
            return self.key_buf[0..self.key_len];
        }

        fn value(self: *const ParamEntry) []const u8 {
            return self.value_buf[0..self.value_len];
        }
    };

    pub fn get(self: *const RouteParams, key: []const u8) ?[]const u8 {
        for (self.entries[0..self.count]) |entry| {
            if (std.mem.eql(u8, entry.key(), key)) return entry.value();
        }
        return null;
    }

    pub fn set(self: *RouteParams, key: []const u8, value: []const u8) Error!void {
        if (key.len > max_key_len) return error.KeyTooLong;
        if (value.len > max_value_len) return error.ValueTooLong;

        // 更新已有
        for (self.entries[0..self.count]) |*entry| {
            if (std.mem.eql(u8, entry.key(), key)) {
                @memcpy(entry.value_buf[0..value.len], value);
                entry.value_len = @intCast(value.len);
                return;
            }
        }
        // 添加新的
        if (self.count >= max_params) return error.TooManyParams;

        self.entries[self.count] = try ParamEntry.init(key, value);
        self.count += 1;
    }
};

/// 历史记录条目
fn HistoryEntry(comptime PageEnum: type) type {
    return struct {
        page: PageEnum,
        params: RouteParams,
    };
}

/// 泛型路由器
pub fn Router(comptime PageEnum: type) type {
    return struct {
        const Self = @This();
        const Entry = HistoryEntry(PageEnum);

        /// 当前页面（响应式 Signal）
        current: *Signal(PageEnum),
        /// 当前路由参数（响应式 Signal）
        params: *Signal(RouteParams),
        /// 导航历史栈
        history: [max_history]Entry = undefined,
        history_len: u16 = 0,
        /// 当前在历史栈中的位置
        history_pos: u16 = 0,

        const max_history = 64;

        /// 创建路由器
        pub fn init(scope: *Scope, initial_page: PageEnum) !Self {
            const current = try scope.createSignal(PageEnum, initial_page);
            const params = try scope.createSignal(RouteParams, .{});
            var router = Self{
                .current = current,
                .params = params,
                .history = undefined,
            };
            // 初始页面压入历史
            router.pushHistory(initial_page, .{});
            return router;
        }

        /// 导航到新页面
        pub fn navigate(self: *Self, page: PageEnum, route_params: RouteParams) void {
            // 如果不在历史栈顶（因为 back() 过），截断前面的历史
            if (self.history_pos + 1 < self.history_len) {
                self.history_len = self.history_pos + 1;
            }
            self.pushHistory(page, route_params);
            self.current.set(page);
            self.params.set(route_params);
        }

        /// 导航到新页面（无参数）
        pub fn navigateTo(self: *Self, page: PageEnum) void {
            self.navigate(page, .{});
        }

        /// 回退
        pub fn back(self: *Self) bool {
            if (self.history_pos == 0) return false;
            self.history_pos -= 1;
            const entry = self.history[self.history_pos];
            self.current.set(entry.page);
            self.params.set(entry.params);
            return true;
        }

        /// 前进
        pub fn forward(self: *Self) bool {
            if (self.history_pos + 1 >= self.history_len) return false;
            self.history_pos += 1;
            const entry = self.history[self.history_pos];
            self.current.set(entry.page);
            self.params.set(entry.params);
            return true;
        }

        /// 是否可以回退
        pub fn canGoBack(self: *const Self) bool {
            return self.history_pos > 0;
        }

        /// 是否可以前进
        pub fn canGoForward(self: *const Self) bool {
            return self.history_pos + 1 < self.history_len;
        }

        fn pushHistory(self: *Self, page: PageEnum, route_params: RouteParams) void {
            if (self.history_len >= max_history) {
                // 栈满：丢弃最旧的一半历史
                const keep = max_history / 2;
                const discard = self.history_len - keep;
                var i: u16 = 0;
                while (i < keep) : (i += 1) {
                    self.history[i] = self.history[i + discard];
                }
                self.history_len = keep;
                self.history_pos = if (self.history_pos >= discard) self.history_pos - discard else 0;
            }
            self.history[self.history_len] = .{ .page = page, .params = route_params };
            self.history_len += 1;
            self.history_pos = self.history_len - 1;
        }
    };
}

test "RouteParams owns copied key/value bytes" {
    var params: RouteParams = .{};
    var key_buf = [_]u8{ 'f', 'i', 'l', 'e' };
    var value_buf = [_]u8{ 'd', 'r', 'a', 'f', 't', '.', 'm', 'd' };

    try params.set(key_buf[0..], value_buf[0..]);
    key_buf[0] = 'x';
    value_buf[0] = 'x';

    try std.testing.expectEqualStrings("draft.md", params.get("file").?);
}

test "RouteParams rejects overflow instead of truncating" {
    var params: RouteParams = .{};

    var i: usize = 0;
    while (i < RouteParams.max_params) : (i += 1) {
        var key_buf: [8]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "k{d}", .{i});
        try params.set(key, "value");
    }

    try std.testing.expectError(error.TooManyParams, params.set("overflow", "value"));
}

test "RouteParams validates key and value lengths" {
    var params: RouteParams = .{};
    const long_key = [_]u8{'k'} ** (RouteParams.max_key_len + 1);
    const long_value = [_]u8{'v'} ** (RouteParams.max_value_len + 1);

    try std.testing.expectError(error.KeyTooLong, params.set(long_key[0..], "value"));
    try std.testing.expectError(error.ValueTooLong, params.set("key", long_value[0..]));
}

test "Router works with enums that do not start at zero" {
    const Page = enum(u8) {
        welcome = 1,
        editor = 2,
        settings = 3,
    };

    const owner = try SignalOwner.init(std.testing.allocator);
    defer owner.deinit();

    const scope = try Scope.init(std.testing.allocator, null, owner);
    defer scope.dispose();

    var router = try Router(Page).init(scope, .welcome);

    var route_params: RouteParams = .{};
    try route_params.set("file", "draft.md");
    router.navigate(.editor, route_params);

    try route_params.set("file", "mutated.md");

    try std.testing.expectEqual(Page.editor, router.current.peek());
    try std.testing.expectEqualStrings("draft.md", router.params.peek().get("file").?);
    try std.testing.expect(router.canGoBack());
    try std.testing.expect(!router.canGoForward());

    try std.testing.expect(router.back());
    try std.testing.expectEqual(Page.welcome, router.current.peek());
    try std.testing.expect(router.canGoForward());

    try std.testing.expect(router.forward());
    try std.testing.expectEqual(Page.editor, router.current.peek());
    try std.testing.expectEqualStrings("draft.md", router.params.peek().get("file").?);
}

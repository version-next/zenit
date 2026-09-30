const std = @import("std");
const t = std.testing;
const core = @import("../../core.zig");
const sdk_mod = @import("system_sdk");
const input = @import("state.zig");
const input_events = @import("events.zig");
const textarea = @import("textarea.zig");
const Event = @import("../../events.zig").Event;

const Backend = struct {
    text: []const u8 = "",
    read_error: ?sdk_mod.SdkError = null,
    length_error: ?sdk_mod.SdkError = null,
    grow_to: ?[]const u8 = null,
    reads: usize = 0,
    queries: usize = 0,
    fn deinit(_: *anyopaque, _: std.mem.Allocator) void {}
    fn pump(_: *anyopaque, _: *sdk_mod.EventQueue, _: u32) sdk_mod.SdkError!sdk_mod.PumpResult {
        return .{ .should_continue = true };
    }
    fn set(_: *anyopaque, _: []const u8) sdk_mod.SdkError!void {}
    fn len(ctx: *anyopaque) sdk_mod.SdkError!usize {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.queries += 1;
        if (self.length_error) |err| return err;
        return self.text.len;
    }
    fn get(ctx: *anyopaque, buffer: []u8) sdk_mod.SdkError![]const u8 {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.reads += 1;
        if (self.read_error) |err| return err;
        if (self.grow_to) |text| {
            self.text = text;
            self.grow_to = null;
        }
        // Match macOS: reserve a NUL and reject an incomplete read.
        if (buffer.len <= self.text.len) return error.BufferTooSmall;
        @memcpy(buffer[0..self.text.len], self.text);
        buffer[self.text.len] = 0;
        return buffer[0..self.text.len];
    }
    const vtable: sdk_mod.BackendVTable = .{
        .name = "input-clipboard-test",
        .deinit = deinit,
        .pump_events = pump,
        .clipboard = .{ .set_text = set, .get_text = get, .get_text_len = len },
    };
    const basic_vtable: sdk_mod.BackendVTable = .{
        .name = "input-basic-clipboard-test",
        .deinit = deinit,
        .pump_events = pump,
        .clipboard = .{ .set_text = set, .get_text = get },
    };
};

// 0: bounded single line, 1: shared dynamic multiline, 2: independent textarea.
fn Fixture(comptime kind: u8) type {
    return struct {
        backend: Backend,
        sdk: sdk_mod.SystemSdk,
        cx: *core.Cx,
        doc: input.TextareaDocument,
        wrap: input.TextareaWrapMap,
        state: if (kind == 2) textarea.TextareaState else input.TextInputState,
        calls: usize,
        fn notify(ctx: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.calls += 1;
        }
        fn init(self: *@This(), state_allocator: std.mem.Allocator, doc_allocator: std.mem.Allocator) !void {
            self.calls = 0;
            self.backend = .{};
            self.sdk = sdk_mod.SystemSdk.init(t.allocator, &self.backend, &Backend.vtable, .{ .clipboard = true });
            errdefer self.sdk.deinit();
            self.doc = input.TextareaDocument.init(doc_allocator);
            errdefer self.doc.deinit();
            self.wrap = input.TextareaWrapMap.init(t.allocator);
            errdefer self.wrap.deinit();
            self.cx = try core.Cx.init(t.allocator);
            errdefer self.cx.deinit();
            self.cx.system_sdk = &self.sdk;
            const handler: core.HandlerRef = .{ .callback = notify, .context = self };
            self.state = if (kind == 2)
                .{ .allocator = state_allocator, .doc = &self.doc, .wrap_map = &self.wrap, .cx_ref = self.cx, .on_change = handler }
            else
                .{ .allocator = state_allocator, .multiline = kind == 1, .accept_newline = kind == 1, .textarea_doc = if (kind == 1) &self.doc else null, .cx_ref = self.cx, .on_change = handler };
            errdefer self.state.deinit();
            if (kind == 2) try self.doc.setTextChecked("seed") else _ = try self.state.setTextChecked("seed");
            self.select(4, null);
            try self.state.insertTextChecked("!");
            self.state.undo();
            self.select(4, 0);
        }
        fn deinit(self: *@This()) void {
            self.state.deinit();
            self.cx.deinit();
            self.wrap.deinit();
            self.doc.deinit();
            self.sdk.deinit();
        }
        fn select(self: *@This(), cursor: usize, anchor: ?usize) void {
            if (kind == 2) {
                self.state.cursor.offset = cursor;
                self.state.cursor.anchor = anchor;
            } else {
                self.state.cursor_pos = cursor;
                self.state.selection_anchor = anchor;
            }
        }
        fn event(self: *@This(), event_value: Event) void {
            if (kind == 2) {
                _ = textarea.textareaEventHandler(event_value, &self.state);
            } else {
                _ = input_events.inputEventHandler(event_value, &self.state);
            }
        }
        fn paste(self: *@This()) void {
            self.event(.{ .key_down = .{ .key = .v, .modifiers = .{ .super = true } } });
        }
        fn undoCount(self: *@This()) u8 {
            return if (kind == 1) self.state.ta_undo_count else self.state.undo_count;
        }
        fn redoCount(self: *@This()) u8 {
            return if (kind == 1) self.state.ta_redo_count else self.state.redo_count;
        }
        fn expectUnchanged(self: *@This(), undo: u8, redo: u8) !void {
            try t.expectEqualStrings("seed", self.state.getText());
            try t.expectEqual(undo, self.undoCount());
            try t.expectEqual(redo, self.redoCount());
            try t.expectEqual(@as(usize, 0), self.calls);
            try t.expectEqual(@as(usize, 4), if (kind == 2) self.state.cursor.offset else self.state.cursor_pos);
            try t.expectEqual(@as(?usize, 0), if (kind == 2) self.state.cursor.anchor else self.state.selection_anchor);
        }
    };
}

fn longPaste(comptime kind: u8) !void {
    var f: Fixture(kind) = undefined;
    try f.init(t.allocator, t.allocator);
    defer f.deinit();
    f.backend.text = "漢" ** 2000 ++ "\r\ntail";
    f.paste();
    try t.expectEqualStrings("漢" ** 2000 ++ "\ntail", f.state.getText());
    try t.expectEqual(@as(usize, 1), f.calls);
    f.state.undo();
    try t.expectEqualStrings("seed", f.state.getText());
    f.state.redo();
    try t.expectEqualStrings("漢" ** 2000 ++ "\ntail", f.state.getText());
}

test "shared multiline clipboard accepts complete text beyond fixed input capacity" {
    try longPaste(1);
}

test "independent textarea clipboard accepts complete text beyond 4096 bytes" {
    try longPaste(2);
}

test "clipboard empty filtered and failed reads preserve selection histories and notification" {
    inline for (.{ 0, 1, 2 }) |kind| {
        for (0..5) |scenario| {
            var f: Fixture(kind) = undefined;
            try f.init(t.allocator, t.allocator);
            defer f.deinit();
            f.backend.text = switch (scenario) {
                0 => "",
                1 => "\x00\x01",
                else => "replacement",
            };
            if (scenario == 2) f.backend.length_error = error.BackendFailure;
            if (scenario == 3) f.backend.read_error = error.BackendFailure;
            if (scenario == 4) f.backend.read_error = error.BufferTooSmall;
            const undo = f.undoCount();
            const redo = f.redoCount();
            f.paste();
            try f.expectUnchanged(undo, redo);
            f.state.redo();
            try t.expectEqualStrings("seed!", f.state.getText());
        }
    }
}

test "clipboard grows between query and read and basic backends keep working" {
    inline for (.{ 0, 1, 2 }) |kind| {
        var f: Fixture(kind) = undefined;
        try f.init(t.allocator, t.allocator);
        defer f.deinit();
        f.backend.text = "small";
        f.backend.grow_to = "漢" ** 2000;
        f.paste();
        try t.expectEqualStrings(if (kind == 0) "漢" ** 682 else "漢" ** 2000, f.state.getText());
        try t.expectEqual(@as(usize, 2), f.backend.reads);
        f.state.undo();
        f.select(4, 0);
        f.sdk.vtable = &Backend.basic_vtable;
        f.backend.text = "basic";
        f.paste();
        try t.expectEqualStrings("basic", f.state.getText());
        f.state.undo();
        f.select(4, 0);
        f.calls = 0;
        const undo = f.undoCount();
        const redo = f.redoCount();
        f.backend.text = "x" ** 6000;
        f.paste();
        try f.expectUnchanged(undo, redo);
    }
}

test "clipboard paste is one undo step separate from adjacent typing" {
    inline for (.{ 0, 1, 2 }) |kind| {
        var f: Fixture(kind) = undefined;
        try f.init(t.allocator, t.allocator);
        defer f.deinit();
        f.select(4, null);
        f.event(.{ .text_input = .{ .text = "a" } });
        f.backend.text = "paste";
        f.paste();
        f.event(.{ .text_input = .{ .text = "b" } });
        try t.expectEqualStrings("seedapasteb", f.state.getText());
        f.state.undo();
        try t.expectEqualStrings("seedapaste", f.state.getText());
        f.state.undo();
        try t.expectEqualStrings("seeda", f.state.getText());
        f.state.undo();
        try t.expectEqualStrings("seed", f.state.getText());
    }
}

test "clipboard allocation failure is atomic across read filtering document and history" {
    inline for (.{ 0, 1, 2 }) |kind| {
        for ([_]bool{ false, true }) |fail_model| {
            var succeeded = false;
            for (0..80) |failure| {
                var failing = t.FailingAllocator.init(t.allocator, .{});
                var f: Fixture(kind) = undefined;
                try f.init(if (fail_model) t.allocator else failing.allocator(), if (fail_model) failing.allocator() else t.allocator);
                defer f.deinit();
                f.backend.text = "漢" ** 2000 ++ "\r\ntail";
                const undo = f.undoCount();
                const redo = f.redoCount();
                failing.fail_index = failing.alloc_index + failure;
                failing.resize_fail_index = failing.resize_index;
                f.paste();
                failing.fail_index = std.math.maxInt(usize);
                failing.resize_fail_index = std.math.maxInt(usize);
                if (std.mem.eql(u8, "seed", f.state.getText())) {
                    try t.expect(failing.has_induced_failure);
                    try f.expectUnchanged(undo, redo);
                    f.paste();
                } else {
                    succeeded = true;
                }
                try t.expectEqualStrings(if (kind == 0) "漢" ** 682 else "漢" ** 2000 ++ "\ntail", f.state.getText());
                try t.expectEqual(@as(usize, 1), f.calls);
                f.state.undo();
                try t.expectEqualStrings("seed", f.state.getText());
                f.state.redo();
                try t.expectEqualStrings(if (kind == 0) "漢" ** 682 else "漢" ** 2000 ++ "\ntail", f.state.getText());
                if (succeeded) break;
            }
            try t.expect(succeeded);
        }
    }
}

test "failed clipboard paste preserves the typing coalescing chain" {
    inline for (.{ 0, 1 }) |kind| {
        var failing = t.FailingAllocator.init(t.allocator, .{});
        var f: Fixture(kind) = undefined;
        try f.init(failing.allocator(), failing.allocator());
        defer f.deinit();
        f.select(4, null);
        f.event(.{ .text_input = .{ .text = "a" } });
        const old_kind = f.state.undo_coalesce_kind;
        const old_time = f.state.undo_coalesce_at;
        const old_cursor = f.state.undo_coalesce_cursor;
        f.backend.text = "paste";
        // Clipboard allocation succeeds; force later document/history preparation to fail.
        failing.fail_index = failing.alloc_index + 1;
        f.paste();
        failing.fail_index = std.math.maxInt(usize);
        try t.expect(failing.has_induced_failure);
        try t.expectEqualStrings("seeda", f.state.getText());
        try t.expectEqual(old_kind, f.state.undo_coalesce_kind);
        try t.expectEqual(old_time, f.state.undo_coalesce_at);
        try t.expectEqual(old_cursor, f.state.undo_coalesce_cursor);
        f.event(.{ .text_input = .{ .text = "b" } });
        try t.expectEqualStrings("seedab", f.state.getText());
        f.state.undo();
        try t.expectEqualStrings("seed", f.state.getText());
    }
}

test "password input: Cmd+C / Cmd+X 不写剪贴板、不删文本" {
    const Rec = struct {
        sets: usize = 0,
        fn deinit(_: *anyopaque, _: std.mem.Allocator) void {}
        fn pump(_: *anyopaque, _: *sdk_mod.EventQueue, _: u32) sdk_mod.SdkError!sdk_mod.PumpResult {
            return .{ .should_continue = true };
        }
        fn set(ctx: *anyopaque, _: []const u8) sdk_mod.SdkError!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.sets += 1;
        }
        fn get(_: *anyopaque, _: []u8) sdk_mod.SdkError![]const u8 {
            return "";
        }
        const vtable: sdk_mod.BackendVTable = .{
            .name = "input-password-clipboard-test",
            .deinit = deinit,
            .pump_events = pump,
            .clipboard = .{ .set_text = set, .get_text = get },
        };
    };
    var rec: Rec = .{};
    var sdk = sdk_mod.SystemSdk.init(t.allocator, &rec, &Rec.vtable, .{ .clipboard = true });
    defer sdk.deinit();
    const cx = try core.Cx.init(t.allocator);
    defer cx.deinit();
    cx.system_sdk = &sdk;

    inline for (.{ input.InputType.password, input.InputType.text }) |ty| {
        rec.sets = 0;
        var s: input.TextInputState = .{ .allocator = t.allocator, .cx_ref = cx, .input_type = ty };
        defer s.deinit();
        _ = try s.setTextChecked("secret");
        s.selection_anchor = 0;
        s.cursor_pos = 6;
        _ = input_events.inputEventHandler(.{ .key_down = .{ .key = .c, .modifiers = .{ .super = true } } }, &s);
        _ = input_events.inputEventHandler(.{ .key_down = .{ .key = .x, .modifiers = .{ .super = true } } }, &s);
        if (ty == .password) {
            try t.expectEqual(@as(usize, 0), rec.sets);
            try t.expectEqualStrings("secret", s.getText());
        } else {
            // 对照组：普通输入框照常复制 + 剪切
            try t.expectEqual(@as(usize, 2), rec.sets);
            try t.expectEqualStrings("", s.getText());
        }
    }
}

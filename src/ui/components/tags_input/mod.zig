/// TagsInput，标签输入（B5）：Chip 列表 + 内嵌输入框
///
/// 提交方式：输入文本以逗号结尾（"foo," -> 提交 "foo"）或点 Add 按钮。
/// tag 文本从输入框拷贝到 scope allocator（用户输入非静态），删除时释放。
const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../../core.zig");
const Cx = core.Cx;
const Node = core.Node;
const box = core.box;
const Padding = core.Padding;
const Scope = @import("../../reactive.zig").Scope;
const events = @import("../../events.zig");
const Event = events.Event;
const EventResult = events.EventResult;
const chip_mod = @import("../chip/mod.zig");
const input_mod = @import("../input/mod.zig");
const button_mod = @import("../button/mod.zig");
const DeferredEntry = @import("../../reactive/deferred_disposal.zig").Entry;

pub const TagsInputProps = struct {
    initial_tags: []const []const u8 = &.{},
    max_tags: usize = 16,
    width: f32 = 360,
    placeholder: []const u8 = "Add tag, end with comma",
    on_change: ?core.HandlerRef = null,
};

const TagEntry = struct {
    text: []u8,
    chip_node: *Node,
    /// false = 已删除但文本仍归 state（仅延迟释放分配失败时的降级路径：该 slot
    /// 不复用，text 在 scope cleanup 释放）。正常删除会把 slot 置 null 供复用，
    /// text 经 DeferredBytes 排在 chip 节点之后释放。
    active: bool = true,
};

const ChipCloseCtx = struct {
    state: *TagsInputState,
    slot: usize,
};

/// 移除后释放用户文本：chip/行节点的 TextProps 仍借用这段字节，而 freeNode 在
/// reactive / tick 深度里只是排队，必须排进与 freeNode 同一条延迟队列，节点在前、文本在后。
const DeferredBytes = struct {
    entry: DeferredEntry = .{},
    alloc: Allocator,
    bytes: []u8,

    fn dispose(ptr: *anyopaque) void {
        const d: *DeferredBytes = @ptrCast(@alignCast(ptr));
        d.alloc.free(d.bytes);
        d.alloc.destroy(d);
    }

    /// 紧跟在对应的 freeNode 之后调用。分配失败返回 false（调用方保留所有权）。
    fn freeAfterNode(cx: *Cx, alloc: Allocator, bytes: []u8) bool {
        const d = alloc.create(DeferredBytes) catch return false;
        d.* = .{ .alloc = alloc, .bytes = bytes };
        cx.deferDisposalLikeFreeNode(&d.entry, @ptrCast(d), dispose);
        return true;
    }
};

pub const TagsInputState = struct {
    alloc: Allocator,
    scope: *Scope,
    cx: *Cx,
    tags: [64]?TagEntry = [_]?TagEntry{null} ** 64,
    /// 每 slot 一个稳定的 close ctx（state 堆分配 -> 元素指针稳定）
    close_ctxs: [64]ChipCloseCtx = undefined,
    count: usize = 0,
    max_tags: usize,
    chips_row: *Node,
    input_state: *input_mod.TextInputState,
    on_change: ?core.HandlerRef = null,
    suppress_change: bool = false,

    pub fn tagCount(self: *const TagsInputState) usize {
        return self.count;
    }

    pub fn hasTag(self: *const TagsInputState, text: []const u8) bool {
        for (self.tags[0..]) |maybe| {
            if (maybe) |e| {
                if (e.active and std.mem.eql(u8, e.text, text)) return true;
            }
        }
        return false;
    }

    /// 提交一个 tag（拷贝文本 + 挂 Chip）。重复/空/超上限时 no-op。
    pub fn addTag(self: *TagsInputState, text: []const u8) !void {
        const trimmed = std.mem.trim(u8, text, " \t");
        if (trimmed.len == 0 or self.count >= self.max_tags) return;
        if (self.hasTag(trimmed)) return;

        const slot = blk: {
            for (&self.tags, 0..) |*s, i| {
                if (s.* == null) break :blk i;
            }
            return;
        };

        const copy = try self.alloc.dupe(u8, trimmed);
        errdefer self.alloc.free(copy);

        self.close_ctxs[slot] = .{ .state = self, .slot = slot };
        const chip = try chip_mod.Chip(.{
            .label = copy,
            .closable = true,
            .readonly = false,
            .on_close = .{ .callback = onChipClose, .context = @ptrCast(&self.close_ctxs[slot]) },
        }).mount(self.scope, self.cx);
        // chip 插到输入框之前（输入框是 chips_row 最后一个 child）
        // sweep：appendChild 失败时 chip 整棵（13 个节点）会漏，建好即 adopt
        _ = try core.adoptChild(self.cx, self.alloc, self.chips_row, chip);

        self.tags[slot] = .{ .text = copy, .chip_node = chip };
        self.count += 1;
        self.chips_row.markLayoutDirty();
        if (self.on_change) |h| h.invoke();
    }

    pub fn removeSlot(self: *TagsInputState, slot: usize) void {
        if (self.tags[slot]) |*e| {
            if (!e.active) return;
            self.chips_row.removeChild(e.chip_node);
            self.cx.freeNode(e.chip_node);
            if (DeferredBytes.freeAfterNode(self.cx, self.alloc, e.text)) {
                self.tags[slot] = null; // slot 可复用（此前永不复用，64 次 add 后静默丢输入）
            } else {
                e.active = false;
            }
            if (self.count > 0) self.count -= 1;
            self.chips_row.markLayoutDirty();
            if (self.on_change) |h| h.invoke();
        }
    }

    /// 删除最后一个（最近添加的）active tag。返回是否真的删了。
    pub fn removeLastTag(self: *TagsInputState) bool {
        // slot 会复用，下标大小不再代表先后；chips_row 的末尾 chip 才是最近添加的。
        const children = self.chips_row.children.items;
        if (children.len > 0) {
            const last = children[children.len - 1];
            for (self.tags, 0..) |maybe, slot| {
                if (maybe) |e| {
                    if (e.active and e.chip_node == last) {
                        self.removeSlot(slot);
                        return true;
                    }
                }
            }
        }
        var i: usize = self.tags.len;
        while (i > 0) {
            i -= 1;
            if (self.tags[i]) |e| {
                if (e.active) {
                    self.removeSlot(i);
                    return true;
                }
            }
        }
        return false;
    }

    fn clearInput(self: *TagsInputState) void {
        // insertText 不触发 on_change，旗标若不在这里复位会一直挂着，
        // 吞掉用户下一次真实输入（"metal," 之后的 "go," 不提交）。
        self.suppress_change = true;
        defer self.suppress_change = false;
        self.input_state.selectAll();
        self.input_state.insertText("");
    }
};

/// 输入框为空时按 Backspace 删除最后一个 tag（tags input 标配键盘行为）。
///
/// 为什么走 capture 而不是 bubble：Input 的 on_event 对 Backspace
/// （KeyCode.delete）无条件返回 handled，即使 buffer 已空
/// （TextInputState.handleKeyDown `.delete` 分支恒 return true），事件到不了
/// bubble 阶段。capture 阶段 root->target 先于 target 派发（event_dispatcher
/// invokeHandler 注释点名的"祖先抢先拦截"场景），wrapper 在这里抢先消费。
fn onWrapperKeyCapture(event: Event, context: ?*anyopaque) EventResult {
    const state: *TagsInputState = @ptrCast(@alignCast(context orelse return .ignored));
    switch (event) {
        .key_down => |e| {
            const m = e.modifiers;
            if (e.key == .delete and !m.shift and !m.ctrl and !m.alt and !m.super and
                state.input_state.buffer_len == 0)
            {
                // 没 tag 可删时也放行给 input（no-op，但别吞事件）
                if (state.removeLastTag()) return .stop;
            }
        },
        else => {},
    }
    return .ignored;
}

fn onChipClose(ctx: *anyopaque) void {
    const c: *ChipCloseCtx = @ptrCast(@alignCast(ctx));
    c.state.removeSlot(c.slot);
}

fn onInputChanged(state: *TagsInputState, text: []const u8) void {
    if (state.suppress_change) {
        state.suppress_change = false;
        return;
    }
    // 以逗号结尾 -> 提交逗号前内容并清空输入
    if (text.len > 0 and text[text.len - 1] == ',') {
        // 失败后若仍 clearInput，用户输入既没变成 tag 也没留在输入框里 = 静默丢数据。
        state.addTag(text[0 .. text.len - 1]) catch @panic("OOM: TagsInput 逗号提交 tag 失败");
        state.clearInput();
    }
}

fn onAddClick(ctx: *anyopaque) void {
    const state: *TagsInputState = @ptrCast(@alignCast(ctx));
    const s = state.input_state;
    // 同上：失败仍 clearInput 会让用户输入凭空消失。
    state.addTag(s.buffer[0..s.buffer_len]) catch @panic("OOM: TagsInput 点击添加 tag 失败");
    state.clearInput();
}

pub const TagsInputMount = struct {
    wrapper: *Node,
    state: *TagsInputState,
    input: *Node,
};

pub fn mountTagsInput(props: TagsInputProps, scope: *Scope, cx: *Cx) !TagsInputMount {
    const my_scope = try scope.childScope();
    const allocator = cx.allocator;
    const t = cx.tokens;

    const state = try my_scope.allocator.create(TagsInputState);
    // sweep：adoptResource 失败当场跑 cleanup、之后任何一步失败也会经 scope 级联跑到它，
    // 而 cleanup 会遍历 tags 释放 text, state 此刻还没初始化（0xaa），必须先把 tags 清空。
    state.tags = [_]?TagEntry{null} ** 64;
    try my_scope.adoptResource(@ptrCast(state), struct {
        fn cleanup(ptr: *anyopaque, alloc: Allocator) void {
            const s: *TagsInputState = @ptrCast(@alignCast(ptr));
            for (&s.tags) |*maybe| {
                if (maybe.*) |e| {
                    alloc.free(e.text);
                    maybe.* = null;
                }
            }
            alloc.destroy(s);
        }
    }.cleanup);

    const wrapper = try box(cx, .{
        .width = .{ .px = props.width },
        .height = .{ .fit = .{} },
        .direction = .column,
        .gap = 6,
    }, .{});
    wrapper.meta.ownership.meta.component_name = "TagsInput";
    // sweep：wrapper 守到 return（freeNode 会连带 dispose 绑上的 my_scope）；子节点建好即 adopt
    errdefer cx.freeNode(wrapper);
    try core.bindScopeToNode(my_scope, wrapper);
    // role=group：把"已有 chips + 输入框 + Add 按钮"绑成一个有名字的整体，
    // 否则 AT 用户 tab 进输入框时不知道自己在编辑什么。
    wrapper.behavior.interaction.a11y = .{ .role = .group, .label = "Tags" };

    // chips 换行流
    const chips_row = try core.adoptChild(cx, allocator, wrapper, try box(cx, .{
        .width = .{ .grow = .{} },
        .height = .{ .fit = .{} },
        .direction = .row,
        .gap = 6,
        .align_items = .center,
    }, .{}));
    (try chips_row.style.ensureExtFallible(allocator)).flex_wrap = .wrap;
    // 已提交的 tag 是一份列表，AT 才会播报"共 N 项"。
    chips_row.behavior.interaction.a11y = .{ .role = .list, .label = "Current tags" };

    // 输入行：Input + Add 按钮
    const input_row = try core.adoptChild(cx, allocator, wrapper, try box(cx, .{
        .width = .{ .grow = .{} },
        .height = .{ .fit = .{} },
        .direction = .row,
        .gap = 6,
        .align_items = .center,
    }, .{}));

    const input_result = try input_mod.Input(.{
        .placeholder = props.placeholder,
        .width = props.width - 70,
        .on_change = core.Cx.strHandlerFrom(TagsInputState, state, onInputChanged),
    }).mountResult(my_scope, cx);
    _ = try core.adoptChild(cx, allocator, input_row, input_result.node);

    const add_btn = try button_mod.Button(.{
        .label = "Add",
        .variant = .secondary,
        .size = .sm,
        .on_click = .{ .callback = onAddClick, .context = @ptrCast(state) },
    }).mount(my_scope, cx);
    _ = try core.adoptChild(cx, allocator, input_row, add_btn);

    state.* = .{
        .alloc = my_scope.allocator,
        .scope = my_scope,
        .cx = cx,
        .max_tags = props.max_tags,
        .chips_row = chips_row,
        .input_state = input_result.state,
        .on_change = props.on_change,
    };
    _ = t;

    // Backspace 删末 tag：capture 挂在 wrapper 上（原因见 onWrapperKeyCapture 注释）
    wrapper.behavior.events.on_event_capture = onWrapperKeyCapture;
    wrapper.behavior.events.event_context = @ptrCast(state);

    for (props.initial_tags) |tag| {
        try state.addTag(tag);
    }

    return .{ .wrapper = wrapper, .state = state, .input = input_result.node };
}

// ============================================================================

test "TagsInput: 初始 tags + 逗号提交 + 去重 + 删除" {
    const testing = std.testing;
    var cx = try Cx.init(testing.allocator);
    defer cx.deinit();
    const root = try box(cx, .{ .width = .{ .px = 600 }, .height = .{ .px = 400 } }, .{});
    cx.root = root;
    const scope = try Scope.init(testing.allocator, null, cx.owner);
    defer scope.dispose();

    const ti = try mountTagsInput(.{ .initial_tags = &.{ "zig", "gui" } }, scope, cx);
    try root.appendChild(testing.allocator, ti.wrapper);
    try testing.expectEqual(@as(usize, 2), ti.state.tagCount());

    // 逗号提交
    onInputChanged(ti.state, "metal,");
    try testing.expectEqual(@as(usize, 3), ti.state.tagCount());
    try testing.expect(ti.state.hasTag("metal"));

    // 连续第二次逗号提交也生效（clearInput 的 suppress 旗标不能卡住）
    onInputChanged(ti.state, "go,");
    try testing.expectEqual(@as(usize, 4), ti.state.tagCount());
    try testing.expect(ti.state.hasTag("go"));

    // 去重 + 空白 no-op。输入框先放入文本：处理后被清空 = 这次 on_change 真的被
    // 评估过（而不是被残留的 suppress 旗标吞掉，旧断言就是这样假绿的）。
    _ = ti.state.input_state.setText("zig,");
    onInputChanged(ti.state, "zig,");
    try testing.expectEqual(@as(usize, 0), ti.state.input_state.buffer_len);
    _ = ti.state.input_state.setText("  ,");
    onInputChanged(ti.state, "  ,");
    try testing.expectEqual(@as(usize, 0), ti.state.input_state.buffer_len);
    try testing.expectEqual(@as(usize, 4), ti.state.tagCount());

    // 删除 slot 0
    ti.state.removeSlot(0);
    try testing.expectEqual(@as(usize, 3), ti.state.tagCount());
    try testing.expect(!ti.state.hasTag("zig"));
}

test "TagsInput: 输入框空时 Backspace 删除最后一个 tag（capture 拦截）" {
    const testing = std.testing;
    var cx = try Cx.init(testing.allocator);
    defer cx.deinit();
    const root = try box(cx, .{ .width = .{ .px = 600 }, .height = .{ .px = 400 } }, .{});
    cx.root = root;
    const scope = try Scope.init(testing.allocator, null, cx.owner);
    defer scope.dispose();

    const ti = try mountTagsInput(.{ .initial_tags = &.{ "zig", "gui" } }, scope, cx);
    try root.appendChild(testing.allocator, ti.wrapper);

    // 接线护栏：capture handler 真的挂上了
    try testing.expect(ti.wrapper.behavior.events.on_event_capture != null);
    const cap = ti.wrapper.behavior.events.on_event_capture.?;
    const ctx_ptr = ti.wrapper.behavior.events.event_context;
    const backspace = Event{ .key_down = .{ .key = .delete, .modifiers = .{} } };

    // 输入框空 -> 删最后一个 tag（后加的 "gui" 先删）并吞事件
    try testing.expectEqual(EventResult.stop, cap(backspace, ctx_ptr));
    try testing.expectEqual(@as(usize, 1), ti.state.tagCount());
    try testing.expect(!ti.state.hasTag("gui"));
    try testing.expect(ti.state.hasTag("zig"));

    // 输入框非空 -> 放行给 input 正常删字符
    ti.state.input_state.insertText("dr");
    try testing.expectEqual(EventResult.ignored, cap(backspace, ctx_ptr));
    try testing.expectEqual(@as(usize, 1), ti.state.tagCount());
    ti.state.clearInput();

    // 带修饰键（Alt+Backspace 按词删）不劫持
    const alt_backspace = Event{ .key_down = .{ .key = .delete, .modifiers = .{ .alt = true } } };
    try testing.expectEqual(EventResult.ignored, cap(alt_backspace, ctx_ptr));
    try testing.expectEqual(@as(usize, 1), ti.state.tagCount());

    // 删空后：无 tag 可删 -> ignored（不吞事件）
    try testing.expectEqual(EventResult.stop, cap(backspace, ctx_ptr));
    try testing.expectEqual(@as(usize, 0), ti.state.tagCount());
    try testing.expectEqual(EventResult.ignored, cap(backspace, ctx_ptr));
}

test "TagsInput: max_tags 上限" {
    const testing = std.testing;
    var cx = try Cx.init(testing.allocator);
    defer cx.deinit();
    const root = try box(cx, .{ .width = .{ .px = 600 }, .height = .{ .px = 400 } }, .{});
    cx.root = root;
    const scope = try Scope.init(testing.allocator, null, cx.owner);
    defer scope.dispose();

    const ti = try mountTagsInput(.{ .max_tags = 2 }, scope, cx);
    try root.appendChild(testing.allocator, ti.wrapper);
    try ti.state.addTag("a");
    try ti.state.addTag("b");
    try ti.state.addTag("c");
    try testing.expectEqual(@as(usize, 2), ti.state.tagCount());
}

test "TagsInput: 删除后 slot 复用，增删超过 64 次仍能添加" {
    const testing = std.testing;
    var cx = try Cx.init(testing.allocator);
    defer cx.deinit();
    const root = try box(cx, .{ .width = .{ .px = 600 }, .height = .{ .px = 400 } }, .{});
    cx.root = root;
    const scope = try Scope.init(testing.allocator, null, cx.owner);
    defer scope.dispose();

    const ti = try mountTagsInput(.{}, scope, cx);
    try root.appendChild(testing.allocator, ti.wrapper);
    var buf: [16]u8 = undefined;
    var i: usize = 0;
    while (i < 80) : (i += 1) {
        const name = try std.fmt.bufPrint(&buf, "t{d}", .{i});
        try ti.state.addTag(name);
        try testing.expectEqual(@as(usize, 1), ti.state.tagCount());
        try testing.expect(ti.state.removeLastTag());
    }
    // 复用后"删最后一个"仍按添加先后
    try ti.state.addTag("a");
    try ti.state.addTag("b");
    ti.state.removeSlot(0);
    try ti.state.addTag("c"); // 复用 slot 0
    try testing.expect(ti.state.removeLastTag());
    try testing.expect(!ti.state.hasTag("c"));
    try testing.expect(ti.state.hasTag("b"));
}

// 逐分配点 OOM sweep，见 src/ui/components/oom_sweep.zig
test "tags_input: mount 在任意分配点失败时不泄漏（sweep）" {
    const sw = @import("../oom_sweep.zig");
    try sw.sweepMount("tags_input", struct {
        fn m(scope: *sw.Scope, cx: *sw.Cx) anyerror!?*sw.Node {
            return (try mountTagsInput(.{ .initial_tags = &.{ "zig", "gui" } }, scope, cx)).wrapper;
        }
    }.m);
}

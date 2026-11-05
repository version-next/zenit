/// TagsInput: tag input, Chip list + inline input.
///
/// Data: `tags: Model([]const []const u8)`; `*Signal` must be created via `scope.createList([]const
/// u8, ...)`
/// (tag text copied by signal). Chips rebuild per `tags` (`ui.rebuildOn`, Chips copy tag text);
/// submit / delete only propose a new tag list.
///
/// Submit: Return, input text ending with comma ('foo,' -> submit 'foo') or Add button.
/// Leading/trailing whitespace stripped; empty / duplicate / over-limit submits ignored (input
/// still cleared).
const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../../core.zig");
const view = @import("../../view.zig");
const Cx = core.Cx;
const Node = core.Node;
const box = core.box;
const reactive = @import("../../reactive.zig");
const Scope = reactive.Scope;
const Signal = reactive.Signal;
const Source = reactive.Source;
const Model = reactive.Model;
const Handler = core.Handler;
const bind_mod = @import("../../bind.zig");
const events = @import("../../events.zig");
const Event = events.Event;
const EventResult = events.EventResult;
const icons = @import("zenit_system_icons");
const input_mod = @import("../input/mod.zig");
const button_mod = @import("../button/mod.zig");

pub const TagsInputProps = struct {
    show_add_button: bool = true,
    /// Tag list
    tags: Model([]const []const u8) = .{ .local = &.{} },
    max_tags: usize = 16,
    width: f32 = 360,
    placeholder: Source([]const u8) = .{ .value = "Add tag, end with comma" },
    /// Called after user adds / removes tags and lands (landed value; slice valid only during
    /// callback)
    on_change: ?Handler([]const []const u8) = null,
};

/// Create TagsInput: `W.TagsInput(.{ .tags = topics, .max_tags = 8 }).mount(scope, cx)`
pub fn TagsInput(props: anytype) TagsInputBuilder {
    return .{ .props = reactive.props.coerce(TagsInputProps, props) };
}

pub const TagsInputBuilder = struct {
    props: TagsInputProps,

    pub fn mount(self: TagsInputBuilder, scope: *Scope, cx: *Cx) !TagsInputResult {
        cx.owner.enterMount();
        defer cx.owner.exitMount();
        return mountImpl(self.props, scope, cx);
    }
};

pub const TagsInputResult = struct {
    wrapper: *Node,
    /// Inline input wrapper
    input: *Node,
    /// Tags list signal (`ui.split` when null)
    tags: ?*Signal([]const []const u8),
    state: *TagsInputState,
    /// Default Add action; null when show_add_button is false.
    add_button: ?*Node = null,

    /// `ui.view` entry (see src/ui/view_parts.zig).
    pub fn viewParts(self: TagsInputResult) core.ViewParts {
        return .{ .root = self.wrapper };
    }
};

const ChipCloseCtx = struct {
    state: *TagsInputState,
    index: usize,

    fn fire(ptr: *anyopaque) void {
        const c: *ChipCloseCtx = @ptrCast(@alignCast(ptr));
        c.state.removeAt(c.index);
    }
};

/// Runtime (scope-owned). View = f(tags): chips rebuild with tags
pub const TagsInputState = struct {
    cx: *Cx,
    tags: reactive.Bound([]const []const u8),
    on_change: ?Handler([]const []const u8),
    max_tags: usize,
    chips_row: *Node,
    input_state: *input_mod.TextInputState,
    /// Input text value (owned signal for inline Input): clears via it, no on_change trigger
    input_value: *Signal([]const u8),

    pub fn tagCount(self: *const TagsInputState) usize {
        return self.tags.peek().len;
    }

    pub fn hasTag(self: *const TagsInputState, text: []const u8) bool {
        for (self.tags.peek()) |t| {
            if (std.mem.eql(u8, t, text)) return true;
        }
        return false;
    }

    pub const AddResult = enum {
        /// Tag landed to data source
        added,
        /// Local judgment prevents add (whitespace / duplicate / over-limit), no proposal
        ignored,
        /// Proposed but not landed (ui.split parent rejected, or rewrote without that tag)
        rejected,
    };

    /// Propose appending one tag (strip leading/trailing whitespace). Caller decides input by
    /// result:
    /// `added` / `ignored` clear, `rejected` keeps user text. Allocation failure returns error
    /// (keeps input).
    pub fn addTag(self: *TagsInputState, text: []const u8) !AddResult {
        const trimmed = std.mem.trim(u8, text, " \t");
        const cur = self.tags.peek();
        if (trimmed.len == 0 or cur.len >= self.max_tags or self.hasTag(trimmed)) return .ignored;
        const buf = try self.cx.allocator.alloc([]const u8, cur.len + 1);
        defer self.cx.allocator.free(buf);
        @memcpy(buf[0..cur.len], cur);
        buf[cur.len] = trimmed;
        self.propose(buf);
        return if (self.hasTag(trimmed)) .added else .rejected;
    }

    /// Propose removing tag at index
    pub fn removeAt(self: *TagsInputState, index: usize) void {
        const cur = self.tags.peek();
        if (index >= cur.len) return;
        const buf = self.cx.allocator.alloc([]const u8, cur.len - 1) catch |err| {
            std.log.err("[TagsInput] remove failed: {}", .{err});
            return;
        };
        defer self.cx.allocator.free(buf);
        @memcpy(buf[0..index], cur[0..index]);
        @memcpy(buf[index..], cur[index + 1 ..]);
        self.propose(buf);
    }

    /// Remove last (most recently added) tag. Returns whether any tag was removable
    pub fn removeLastTag(self: *TagsInputState) bool {
        const n = self.tags.peek().len;
        if (n == 0) return false;
        self.removeAt(n - 1);
        return true;
    }

    fn propose(self: *TagsInputState, v: []const []const u8) void {
        const on_change = self.on_change;
        const landed = self.tags.commit(v) orelse return;
        if (on_change) |h| h.call(landed);
    }

    fn clearInput(self: *TagsInputState) void {
        // External write doesn't trigger on_change
        self.input_value.set("");
    }

    // ---- chips (ui.rebuildOn) ----

    fn tagsKey(tags: []const []const u8) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.asBytes(&tags.len));
        for (tags) |t| {
            h.update(std.mem.asBytes(&t.len));
            h.update(t);
        }
        return h.final();
    }

    const Ctxs = struct {
        items: []ChipCloseCtx = &.{},

        fn destroy(ptr: *anyopaque, alloc: Allocator) void {
            const c: *Ctxs = @ptrCast(@alignCast(ptr));
            alloc.free(c.items);
            alloc.destroy(c);
        }
    };

    fn buildChips(self: *TagsInputState, child: *Scope, row: *Node, tags: []const []const u8) !void {
        const ctxs = try child.allocator.create(Ctxs);
        ctxs.* = .{};
        try child.adoptResource(@ptrCast(ctxs), Ctxs.destroy);
        ctxs.items = try child.allocator.alloc(ChipCloseCtx, tags.len);
        for (ctxs.items, 0..) |*c, i| c.* = .{ .state = self, .index = i };
        try view.mount(child, self.cx, row, view.items(ctxs.items, tags, chipElement));
    }

    const ChipArgs = struct { close: *ChipCloseCtx, label: []const u8 };
    fn chipElement(ctxs: []ChipCloseCtx, tag: []const u8, i: usize) view.ComponentOf(buildChip) {
        return view.component(buildChip, ChipArgs{ .close = &ctxs[i], .label = tag });
    }
    fn buildChip(args: ChipArgs, scope: *Scope, cx: *Cx) !*Node {
        const S = @import("styles.zig");
        return view.render(scope, cx, view.row(.{ .style = S.chip, .a11y = .{ .role = .listitem, .label = args.label } }, .{
            view.text(.{ .style = S.chipText }, args.label),
            view.box(.{ .style = S.closeButton, .a11y = .{ .role = .button, .label = "Remove tag" }, .on_click = core.Cx.simpleHandler(ChipCloseCtx.fire, args.close) }, view.icon(.{ .style = S.closeIcon, .tint = cx.tokens.tokens.color.fg_primary }, icons.close)),
        }));
    }
};

/// Empty input + Backspace deletes last tag (standard tags input keyboard behavior).
///
/// Why capture, not bubble: Input's on_event returns handled unconditionally for Backspace
/// (KeyCode.delete), even with an empty buffer (TextInputState.handleKeyDown `.delete` branch
/// always true), so the event never bubbles. Capture runs root->target before target dispatch
/// (event_dispatcher invokeHandler note 'ancestor intercepts'), so the wrapper consumes it first.
fn onWrapperKeyCapture(event: Event, context: ?*anyopaque) EventResult {
    const state: *TagsInputState = @ptrCast(@alignCast(context orelse return .ignored));
    switch (event) {
        .key_down => |e| {
            const m = e.modifiers;
            if (e.key == .delete and !m.shift and !m.ctrl and !m.alt and !m.super and
                state.input_state.getText().len == 0)
            {
                // No tag to delete: pass to input (no-op, but don't consume event)
                if (state.removeLastTag()) return .stop;
            }
        },
        else => {},
    }
    return .ignored;
}

fn onInputChanged(state: *TagsInputState, text: []const u8) void {
    // Ends with comma -> submit content before comma, clear input
    if (text.len > 0 and text[text.len - 1] == ',') {
        const result = state.addTag(text[0 .. text.len - 1]) catch |err| {
            // Allocation fails: keep input text, user doesn't lose input
            std.log.err("[TagsInput] add failed: {}", .{err});
            return;
        };
        if (result != .rejected) state.clearInput();
    }
}

fn onInputSubmit(state: *TagsInputState, text: []const u8) void {
    const result = state.addTag(text) catch |err| {
        std.log.err("[TagsInput] add failed: {}", .{err});
        return;
    };
    if (result != .rejected) state.clearInput();
}

fn onAddClick(ctx: *anyopaque) void {
    const state: *TagsInputState = @ptrCast(@alignCast(ctx));
    const result = state.addTag(state.input_state.getText()) catch |err| {
        std.log.err("[TagsInput] add failed: {}", .{err});
        return;
    };
    if (result != .rejected) state.clearInput();
}

fn mountImpl(props: TagsInputProps, scope: *Scope, cx: *Cx) !TagsInputResult {
    const my_scope = try scope.childScope();
    var scope_bound = false;
    errdefer if (!scope_bound) my_scope.dispose();

    const tags = try reactive.resolveListModel([]const u8, my_scope, props.tags);
    const state = try my_scope.allocator.create(TagsInputState);
    try my_scope.adoptResource(@ptrCast(state), struct {
        fn destroy(ptr: *anyopaque, alloc: Allocator) void {
            alloc.destroy(@as(*TagsInputState, @ptrCast(@alignCast(ptr))));
        }
    }.destroy);

    var chips_row: *Node = undefined;
    var input_result: input_mod.InputResult = undefined;
    var add_button: ?*Node = null;
    const wrapper = try view.render(my_scope, cx, view.col(.{
        .style = .{ @import("styles.zig").shell, .{ .width = .{ .px = props.width }, .height = .{ .fit = .{} }, .gap = 6 } },
        // role=group: binds 'existing chips + input + Add button' as single named unit,
        // else AT users tab into input unaware of context.
        .a11y = .{ .role = .group, .label = "Tags" },
    }, .{
        // Chips flow wrap; submitted tags are a list, AT speaks 'N items total'.
        view.capture(&chips_row, view.row(.{
            .style = .{ .width = .{ .grow = .{} }, .height = .{ .fit = .{} }, .gap = 6, .align_items = .center, .flex_wrap = .wrap },
            .a11y = .{ .role = .list, .label = "Current tags" },
        }, {})),
        // Input line: Input + Add button
        view.row(.{ .style = @import("styles.zig").inputRow(props.show_add_button, cx.tokens) }, .{
            view.capture(&input_result, input_mod.Input(.{
                .placeholder = props.placeholder,
                .width = props.width - (if (props.show_add_button) @as(f32, 86) else 16),
                .embedded = !props.show_add_button,
                .on_change = cx.on(TagsInputState, state, onInputChanged),
                .on_submit = cx.on(TagsInputState, state, onInputSubmit),
            })),
            if (props.show_add_button) view.capture(&add_button, button_mod.Button(.{
                .label = "Add",
                .variant = .secondary,
                .size = .sm,
                .on_click = core.Cx.simpleHandler(onAddClick, state),
            })) else null,
        }),
    }));
    wrapper.meta.ownership.meta.component_name = "TagsInput";
    // sweep: wrapper guards to return (freeNode carries dispose of bound my_scope)
    errdefer cx.freeNode(wrapper);
    try core.bindScopeToNode(my_scope, wrapper);
    scope_bound = true;

    state.* = .{
        .cx = cx,
        .tags = tags,
        .on_change = props.on_change,
        .max_tags = props.max_tags,
        .chips_row = chips_row,
        .input_state = input_result.state,
        .input_value = input_result.value.?,
    };
    wrapper.addDebugState(@ptrCast(state));

    // Backspace delete last tag: capture on wrapper (reason in onWrapperKeyCapture note)
    wrapper.behavior.events.on_event_capture = onWrapperKeyCapture;
    wrapper.behavior.events.event_context = @ptrCast(state);

    // tags is Model: chips rebuild with it
    try bind_mod.rebuildOn(cx, my_scope, tags.read, chips_row, state, TagsInputState.tagsKey, TagsInputState.buildChips);

    return .{ .wrapper = wrapper, .input = input_result.node, .tags = tags.asSignal(), .state = state, .add_button = add_button };
}

// ============================================================================

const testing = std.testing;

/// Simulate user typing in input: swap buffer to `text`, take Input edit outlet (submit to value
/// signal then call on_change). Direct setText breaks buffer/value signal sync.
fn typeText(ti: TagsInputResult, text: []const u8) void {
    const st = ti.state.input_state;
    _ = st.setText(text);
    st.on_change.?.invokeWithStr(st.getText());
}

const TEnv = struct {
    cx: *Cx,
    scope: *Scope,

    fn init() !TEnv {
        const cx = try Cx.init(testing.allocator, std.testing.io);
        errdefer cx.deinit();
        cx.root = try box(cx, .{ .width = .{ .px = 600 }, .height = .{ .px = 400 } }, .{});
        return .{ .cx = cx, .scope = try Scope.init(testing.allocator, null, cx.owner) };
    }

    fn deinit(self: TEnv) void {
        self.scope.dispose();
        self.cx.deinit();
    }
};

test "TagsInput: 初始 tags + 逗号提交 + 去重 + 删除" {
    const env = try TEnv.init();
    defer env.deinit();
    const ti = try TagsInput(.{ .tags = &[_][]const u8{ "zig", "gui" } }).mount(env.scope, env.cx);
    defer env.cx.freeNode(ti.wrapper);
    try testing.expectEqual(@as(usize, 2), ti.state.tagCount());
    try testing.expectEqual(@as(usize, 2), ti.state.chips_row.children.items.len);

    // Comma submit
    typeText(ti, "metal,");
    try testing.expectEqual(@as(usize, 3), ti.state.tagCount());
    try testing.expect(ti.state.hasTag("metal"));
    try testing.expectEqual(@as(usize, 0), ti.state.input_state.getText().len);

    // Second consecutive comma submit works
    typeText(ti, "go,");
    try testing.expectEqual(@as(usize, 4), ti.state.tagCount());

    // Dedup + whitespace no-op, input still clears
    typeText(ti, "zig,");
    try testing.expectEqual(@as(usize, 0), ti.state.input_state.getText().len);
    typeText(ti, "  ,");
    try testing.expectEqual(@as(usize, 0), ti.state.input_state.getText().len);
    try testing.expectEqual(@as(usize, 4), ti.state.tagCount());

    // Click close on first chip
    ti.state.removeAt(0);
    try testing.expectEqual(@as(usize, 3), ti.state.tagCount());
    try testing.expect(!ti.state.hasTag("zig"));
    try testing.expectEqual(@as(usize, 3), ti.state.chips_row.children.items.len);
    try testing.expectEqualStrings("gui", ti.tags.?.peek()[0]);
}

test "TagsInput: 输入框空时 Backspace 删除最后一个 tag（capture 拦截）" {
    const env = try TEnv.init();
    defer env.deinit();
    const ti = try TagsInput(.{ .tags = &[_][]const u8{ "zig", "gui" } }).mount(env.scope, env.cx);
    defer env.cx.freeNode(ti.wrapper);

    // Capture handler really hooked
    try testing.expect(ti.wrapper.behavior.events.on_event_capture != null);
    const cap = ti.wrapper.behavior.events.on_event_capture.?;
    const ctx_ptr = ti.wrapper.behavior.events.event_context;
    const backspace = Event{ .key_down = .{ .key = .delete, .modifiers = .{} } };

    // Empty input -> delete last tag (recently added 'gui' deleted first) and consume event
    try testing.expectEqual(EventResult.stop, cap(backspace, ctx_ptr));
    try testing.expectEqual(@as(usize, 1), ti.state.tagCount());
    try testing.expect(!ti.state.hasTag("gui"));
    try testing.expect(ti.state.hasTag("zig"));

    // Non-empty input -> pass to input for normal char delete
    typeText(ti, "dr");
    try testing.expectEqual(EventResult.ignored, cap(backspace, ctx_ptr));
    try testing.expectEqual(@as(usize, 1), ti.state.tagCount());
    ti.state.clearInput();

    // Modifiers (Alt+Backspace word-delete) not hijacked
    const alt_backspace = Event{ .key_down = .{ .key = .delete, .modifiers = .{ .alt = true } } };
    try testing.expectEqual(EventResult.ignored, cap(alt_backspace, ctx_ptr));
    try testing.expectEqual(@as(usize, 1), ti.state.tagCount());

    // Delete exhausted: ignored (don't consume event)
    try testing.expectEqual(EventResult.stop, cap(backspace, ctx_ptr));
    try testing.expectEqual(@as(usize, 0), ti.state.tagCount());
    try testing.expectEqual(EventResult.ignored, cap(backspace, ctx_ptr));
}

test "TagsInput: max_tags 上限" {
    const env = try TEnv.init();
    defer env.deinit();
    const ti = try TagsInput(.{ .max_tags = 2 }).mount(env.scope, env.cx);
    defer env.cx.freeNode(ti.wrapper);
    _ = try ti.state.addTag("a");
    _ = try ti.state.addTag("b");
    _ = try ti.state.addTag("c");
    try testing.expectEqual(@as(usize, 2), ti.state.tagCount());
}

test "TagsInput: 外部写入 tags 重建 chips；ui.split 拒绝时输入保持；非 createList 的 signal 被拒" {
    const env = try TEnv.init();
    defer env.deinit();
    const tags = try env.scope.createList([]const u8, &.{"a"});
    const Spy = struct {
        n: usize = 0,
        fn f(self: *@This(), _: []const []const u8) void {
            self.n += 1;
        }
    };
    var spy = Spy{};
    const ti = try TagsInput(.{ .tags = tags, .on_change = env.cx.on(Spy, &spy, Spy.f) }).mount(env.scope, env.cx);
    defer env.cx.freeNode(ti.wrapper);
    tags.set(&.{ "x", "y", "z" });
    try testing.expectEqual(@as(usize, 3), ti.state.chips_row.children.items.len);
    try testing.expectEqual(@as(usize, 0), spy.n);
    typeText(ti, "w,");
    try testing.expectEqual(@as(usize, 4), tags.peek().len);
    try testing.expectEqual(@as(usize, 1), spy.n);

    const Parent = struct {
        sig: *Signal([]const []const u8),
        fn write(_: *@This(), _: []const []const u8) void {}
    };
    var parent = Parent{ .sig = try env.scope.createList([]const u8, &.{}) };
    const ti2 = try TagsInput(.{ .tags = reactive.split(parent.sig, env.cx.on(Parent, &parent, Parent.write)) }).mount(env.scope, env.cx);
    defer env.cx.freeNode(ti2.wrapper);
    try testing.expect(ti2.tags == null);
    typeText(ti2, "q,");
    try testing.expectEqual(@as(usize, 0), ti2.state.chips_row.children.items.len);
    // Parent rejected: keep user text in input (prior claim unverified, actually cleared)
    try testing.expectEqualStrings("q,", ti2.state.input_state.getText());

    const borrowed = try env.scope.createSignal([]const []const u8, &.{});
    try testing.expectError(error.ListModelNotOwned, TagsInput(.{ .tags = borrowed }).mount(env.scope, env.cx));
}

// Per-alloc OOM sweep, see src/ui/components/oom_sweep.zig
test "tags_input: mount 在任意分配点失败时不泄漏（sweep）" {
    try @import("../oom_sweep.zig").sweepMount("tags_input", struct {
        fn m(scope: *Scope, cx: *Cx) anyerror!?*Node {
            const tags = try scope.createList([]const u8, &.{ "zig", "gui" });
            return (try TagsInput(.{ .tags = tags }).mount(scope, cx)).wrapper;
        }
    }.m);
}

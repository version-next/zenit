const std = @import("std");
const testing = std.testing;
const ui = @import("ui");
const graph_assertions = @import("graph_assertions.zig");
const stories = @import("_stories.yix.zig");
const counter = @import("yix_counter");
/// docs/YIX_REFERENCE.md §2.1 example: code in docs must compile and run
const doc_chip = @import("_doc_chip.yix.zig");
const tokens_probe = @import("_tokens_probe.yss.zig");
const params = @import("_params.yss.zig");
const review_style = @import("_review_style.yss.zig");

comptime {
    _ = @import("review_reactive_tests.zig");
    _ = @import("lifecycle_split_tests.zig");
}

const Env = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    root: ?*ui.Node = null,
    fn init() !Env {
        const cx = try ui.Cx.init(testing.allocator, std.testing.io);
        errdefer cx.deinit();
        const scope = try ui.Scope.init(testing.allocator, null, cx.owner);
        return .{ .cx = cx, .scope = scope };
    }
    fn deinit(e: *Env) void {
        e.scope.dispose();
        if (e.root) |r| e.cx.freeNode(r);
        e.cx.deinit();
    }
    fn mount(e: *Env, element: anytype) !void {
        e.root = try ui.view.render(e.scope, e.cx, element);
    }
    fn find(e: *Env, text: []const u8) ?*ui.Node {
        return findText(e.root.?, text);
    }
    fn click(e: *Env, text: []const u8) !void {
        var n = e.find(text) orelse return error.TextNotFound;
        while (n.behavior.events.on_click == null) n = n.parent orelse return error.HandlerNotFound;
        const h = n.behavior.events.on_click.?;
        h.callback(h.context);
    }
};
fn findText(n: *ui.Node, text: []const u8) ?*ui.Node {
    if (n.getText()) |t| if (std.mem.eql(u8, t.content, text)) return n;
    for (n.children.items) |c| if (findText(c, text)) |r| return r;
    return null;
}

test "YSS shadow styles replace the entire shadow stack across composition layers" {
    const multi = ui.css(.{ .shadows = .{ .{ .blur = 1 }, .{ .blur = 2 } } });
    const single = ui.css(.{ .shadow = .{ .blur = 9 } });
    var e = try Env.init();
    defer e.deinit();
    try e.mount(ui.view.box(.{ .style = .{ multi, single } }, .{}));
    try testing.expectEqual(@as(usize, 1), e.root.?.style.shadowSlice().len);
    try testing.expectEqual(@as(f32, 9), e.root.?.style.shadowSlice()[0].blur);
    var reverse = try Env.init();
    defer reverse.deinit();
    try reverse.mount(ui.view.box(.{ .style = .{ single, multi } }, .{}));
    try testing.expectEqual(@as(usize, 2), reverse.root.?.style.shadowSlice().len);
    try testing.expectEqual(@as(f32, 1), reverse.root.?.style.shadowSlice()[0].blur);
}

test "YSS aliased bool and optional types retain runtime style semantics" {
    var e = try Env.init();
    defer e.deinit();
    const enabled = try e.scope.createSignal(bool, false);
    const width = try e.scope.createSignal(?f32, null);
    try e.mount(ui.view.box(.{ .style = review_style.aliased.of(.{ .enabled = enabled, .width = width }) }, .{}));
    try testing.expect(e.root.?.style.width == .fit);
    try testing.expectEqual(@as(f32, 0), e.root.?.style.gap);
    enabled.set(true);
    width.set(24);
    try testing.expectEqual(@as(f32, 3), e.root.?.style.gap);
    try testing.expectEqual(ui.Sizing{ .px = 24 }, e.root.?.style.width);
    enabled.set(false);
    width.set(null);
    try testing.expectEqual(@as(f32, 0), e.root.?.style.gap);
    try testing.expect(e.root.?.style.width == .fit);
}

test "Yix generated counter has reactive text, inferred computed and batched events" {
    var e = try Env.init();
    defer e.deinit();
    try e.mount(counter.Counter(.{}));
    try testing.expect(e.find("count = 0") != null);
    try testing.expect(e.find("even") != null);
    try e.click("+1");
    try testing.expect(e.find("count = 1") != null);
    try testing.expect(e.find("doubled = 2") != null);
    try testing.expect(e.find("odd") != null);
    try testing.expect(e.find("even") == null);
    try e.click("Reset");
    try testing.expect(e.find("count = 0") != null);
}

test "Yix generated story layout and component child protocol" {
    var a = try Env.init();
    defer a.deinit();
    try a.mount(stories.Layout(.{}));
    try testing.expectEqual(ui.Direction.row, a.root.?.style.direction);
    try testing.expect(a.find("Before") != null and a.find("After") != null);
    try testing.expectEqual(@as(f32, 21), a.find("Before").?.parent.?.style.gap);
    var b = try Env.init();
    defer b.deinit();
    try b.mount(stories.CardStory(.{}));
    try testing.expect(b.find("Card body") != null);
    try testing.expectEqual(@as(f32, 0.5), b.root.?.getOpacity());
    var c = try Env.init();
    defer c.deinit();
    try c.mount(stories.ButtonStory(.{}));
    try c.click("Increment");
    try testing.expect(c.find("Count 1; double 2") != null);
}

test "Yix generated if switch and Unicode branches update in place" {
    var a = try Env.init();
    defer a.deinit();
    try a.mount(stories.BranchStory(.{}));
    {
        var t = try Env.init();
        defer t.deinit();
        try t.mount(stories.TypedAttrStory(.{}));
        // Controlled (read-only): checked follows row field; click only calls onChange, parent
        // changes data then display follows; display unchanged if parent doesn't change
        var k = try Env.init();
        defer k.deinit();
        try k.mount(stories.ControlledStory(.{}));
        const a11yChecked = struct {
            fn of(e: *Env, label: []const u8) bool {
                var n = e.find(label).?;
                while (n.behavior.events.on_click == null) n = n.parent.?;
                return n.behavior.interaction.a11y.?.checked.?;
            }
        }.of;
        try testing.expect(!a11yChecked(&k, "a") and a11yChecked(&k, "b"));
        try k.click("a");
        try testing.expectEqual(@as(usize, 1), stories.toggles);
        try testing.expect(a11yChecked(&k, "a") and stories.task_store[0].done);
        try k.click("freeze");
        try k.click("b");
        try testing.expect(a11yChecked(&k, "b") and stories.task_store[1].done);
        var g = try Env.init();
        defer g.deinit();
        try g.mount(stories.GeneratedNameStory(.{}));
        try testing.expect(g.find("b=1 row=2") != null and g.find("first12") != null);
        try g.click("bump");
        try testing.expect(g.find("b=2 row=2") != null and g.find("first22") != null);
        try testing.expect(t.find("todo") != null and t.find("no") != null);
        try t.click("todo");
        try testing.expect(t.find("done") != null and t.find("yes") != null and t.find("todo") == null);
    }
    try testing.expect(a.find("Collapsed") != null);
    try a.click("Toggle");
    try testing.expect(a.find("Expanded") != null and a.find("Collapsed") == null);
    var b = try Env.init();
    defer b.deinit();
    try b.mount(stories.TabsStory(.{}));
    try testing.expect(b.find("Home") != null);
    try b.click("Settings");
    try testing.expect(b.find("Settings body") != null and b.find("Home") == null);
    var c = try Env.init();
    defer c.deinit();
    try c.mount(stories.UnicodeStory(.{}));
    try testing.expect(c.find("中文 😀") != null);
    try c.click("隐藏");
    try testing.expect(c.find("空") != null);
}

test "Yix generated keyed list and empty fallback follow owned list state" {
    var e = try Env.init();
    defer e.deinit();
    try e.mount(stories.ListStory(.{}));
    try testing.expect(e.find("first") != null and e.find("second") != null);
    try e.click("Clear");
    try testing.expect(e.find("Empty") != null and e.find("first") == null);
}

test "Yix generated props normalize a signal and remain reactive" {
    var e = try Env.init();
    defer e.deinit();
    try e.mount(stories.PropsStory(.{}));
    try testing.expect(e.find("Prop 3") != null);
    try e.click("Increment prop");
    try testing.expect(e.find("Prop 4") != null);
}

test "Yix generated multistatement event applies all writes together" {
    stories.batch_updates = 0;
    stories.batch_values = @splat(-1);
    var e = try Env.init();
    defer e.deinit();
    try e.mount(stories.BatchStory(.{}));
    try testing.expect(e.find("0") != null);
    try e.click("Batch");
    try testing.expect(e.find("3") != null);
    try testing.expectEqual(@as(usize, 2), stories.batch_updates);
    try testing.expectEqualSlices(i32, &.{ 0, 3 }, stories.batch_values[0..2]);
}

test "Yix generated keyed row captures stay reactive and events capture the item" {
    var e = try Env.init();
    defer e.deinit();
    try e.mount(stories.RowCaptureStory(.{}));
    try e.click("second");
    try testing.expect(e.find("Selected 2") != null);
    try testing.expect(e.find("first: 2") != null and e.find("second: 2") != null);
    try e.click("Reverse");
    try e.click("first");
    try testing.expect(e.find("Selected 1") != null);
    try testing.expect(e.find("first: 1") != null and e.find("second: 1") != null);
}

fn allocationSweep(comptime component: anytype) !void {
    var failures: usize = 0;
    for (0..1500) |fail_index| {
        const cx = try ui.Cx.init(testing.allocator, std.testing.io);
        defer cx.deinit();
        const scope = try ui.Scope.init(testing.allocator, null, cx.owner);
        var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        cx.allocator = failing.allocator();
        scope.allocator = failing.allocator();
        const result = ui.view.render(scope, cx, component(.{}));
        const induced = failing.has_induced_failure;
        failing.fail_index = std.math.maxInt(usize);
        cx.allocator = testing.allocator;
        scope.allocator = testing.allocator;
        if (result) |root| {
            scope.dispose();
            cx.freeNode(root);
            if (!induced) {
                try testing.expect(failures > 20);
                return;
            }
        } else |err| {
            scope.dispose();
            try testing.expectEqual(error.OutOfMemory, err);
            failures += 1;
        }
    }
    return error.AllocationSweepDidNotFinish;
}

test "Yix generated counter rolls back at every allocation failure" {
    try allocationSweep(counter.Counter);
}

const TOKENS = ui.theme.refs;

test "application JSON tokens: typography is partial and explicit fields win in either order" {
    var e = try Env.init();
    defer e.deinit();
    try e.mount(ui.view.col(.{}, .{
        ui.view.text(.{ .style = ui.css(.{ .font_size = TOKENS.font_size.counterValue, .typography = TOKENS.typography.counterTitle, .line_height = 1.9 }) }, "first"),
        ui.view.text(.{ .style = ui.css(.{ .typography = TOKENS.typography.counterTitle, .font_size = TOKENS.font_size.counterValue, .line_height = 1.9 }) }, "second"),
    }));
    for (e.root.?.children.items) |node| {
        try testing.expectEqual(@as(f32, 18), node.getText().?.font_size);
        try testing.expectEqual(@as(u16, 600), node.getText().?.font_weight);
        try testing.expectEqual(@as(f32, 1.9), node.getText().?.line_height);
    }
    try testing.expectEqual(@as(f32, 24), ui.theme.resolve(.font_size, TOKENS.font_size.counterHeading, &ui.theme.modes.dark));
}

test "application JSON tokens: sva retains current variant and hover across modes" {
    var e = try Env.init();
    defer e.deinit();
    const spacious = try e.scope.createSignal(bool, false);
    const R = ui.sva(.{
        .slots = .{ .root, .content },
        .base = .{
            .root = .{ .background = TOKENS.color.bg_primary, ._hover = .{ .background = TOKENS.color.bg_hover } },
            .content = .{ .width = TOKENS.size.checkbox },
        },
        .variants = .{ .spacious = .{
            .false = .{ .root = .{ .padding = TOKENS.space.space100 } },
            .true = .{ .root = .{ .padding = TOKENS.space.space400 } },
        } },
    });
    const parts = R.of(.{ .spacious = spacious });
    try e.mount(ui.view.box(.{ .style = parts.root }, .{ui.view.box(.{ .style = parts.content }, .{})}));
    e.cx.root = e.root;
    defer e.cx.root = null;
    spacious.set(true);
    const enter = e.root.?.behavior.events.on_hover.?;
    enter.callback(enter.context);
    e.cx.setTheme(&ui.theme.modes.light);
    try testing.expectEqual(ui.theme.modes.light.tokens.color.bg_hover, e.root.?.getBackground());
    try testing.expectEqual(ui.theme.modes.light.tokens.space.space400, e.root.?.style.padding.top);
    try testing.expectEqual(ui.theme.modes.light.tokens.size.checkbox, e.root.?.children.items[0].style.width.px);
    const leave = e.root.?.behavior.events.on_leave.?;
    leave.callback(leave.context);
    try testing.expectEqual(ui.theme.modes.light.tokens.color.bg_primary, e.root.?.getBackground());
}

test "application JSON tokens: detached overlay and portal replay without an app root" {
    var e = try Env.init();
    defer e.deinit();
    try e.mount(ui.view.box(.{ .style = .{ .background = TOKENS.color.bg_primary } }, .{}));
    const handle = try e.cx.overlay_stack.push(.{ .kind = .non_modal, .enter_transition = .none });
    defer e.cx.overlay_stack.removePermanently(handle);
    e.cx.overlay_stack.bindContentNode(e.cx.allocator, handle, e.root.?);
    e.cx.setTheme(&ui.theme.modes.light);
    try testing.expectEqual(ui.theme.modes.light.tokens.color.bg_primary, e.root.?.getBackground());
    // Same node exposed via a portal and a layer must receive one notification.
    const Probe = struct {
        var calls: usize = 0;
        fn hook(_: *ui.Node, _: *const ui.theme.Values, _: std.mem.Allocator) void {
            calls += 1;
        }
    };
    Probe.calls = 0;
    e.root.?.meta.per_frame.hooks.on_theme = Probe.hook;
    e.cx.popover_portal_root = e.root;
    defer e.cx.popover_portal_root = null;
    e.cx.setTheme(&ui.theme.modes.dark);
    try testing.expectEqual(@as(usize, 1), Probe.calls);
}

test "Yix owned text signal compiles and updates" {
    var e = try Env.init();
    defer e.deinit();
    try e.mount(stories.TextSignalStory(.{}));
    try testing.expect(e.find("before") != null);
    try e.click("Change text");
    try testing.expect(e.find("before") == null);
    try testing.expect(e.find("after") != null);
}

test "Yix computed over props stays static for static props and follows signal props" {
    var a = try Env.init();
    defer a.deinit();
    const before = try graph_assertions.staticCounts(a.cx);
    try a.mount(stories.Doubled(.{ .n = 4 }));
    try testing.expect(a.find("double 8") != null);
    try testing.expectEqualStrings("Doubled", a.root.?.meta.ownership.meta.component_name.?);
    // Static prop: no memo, no effect (matches hand-written component 'static props zero effect')
    const after = try graph_assertions.staticCounts(a.cx);
    try testing.expectEqual(before.get(.memo), after.get(.memo));
    try testing.expectEqual(before.get(.effect), after.get(.effect));

    var b = try Env.init();
    defer b.deinit();
    const n = try b.scope.createSignal(i32, 1);
    try b.mount(stories.Doubled(.{ .n = n }));
    try testing.expect(b.find("double 2") != null);
    n.set(5);
    try testing.expect(b.find("double 10") != null);
}

test "Yix children slot: content lands in the slot node and stays reactive" {
    var a = try Env.init();
    defer a.deinit();
    try a.mount(stories.PanelUse(.{}));
    const title = a.find("Settings").?;
    const body = a.find("value 1").?;
    // Slot is second col: content nested under it, not under root
    try testing.expect(body.parent != title.parent);
    // Outer component root is Panel root: component name by outermost (matches hand-written
    // component render naming)
    try testing.expectEqual(a.root.?, body.parent.?.parent.?);
    try testing.expectEqualStrings("PanelUse", a.root.?.meta.ownership.meta.component_name.?);
    try a.click("More");
    try testing.expect(a.find("value 2") != null);
}

test "Yix slotted component mounts without children and via .mount" {
    var a = try Env.init();
    defer a.deinit();
    try a.mount(ui.view.col(.{}, .{stories.Panel(.{ .title = "Empty" })}));
    try testing.expect(a.find("Empty") != null);
    const n = try stories.Panel(.{ .title = "Direct" }).mount(a.scope, a.cx);
    defer a.cx.freeNode(n);
    try testing.expectEqualStrings("Direct", n.children.items[0].getText().?.content);
}

test "Yix Handler props pass through to child components; inline statements bind in the parent" {
    var a = try Env.init();
    defer a.deinit();
    try a.mount(stories.ClosableUse(.{}));
    try testing.expect(a.find("open") != null);
    try a.click("x");
    try testing.expect(a.find("closed") != null);
    // Component mounts normally when callback not provided
    var b = try Env.init();
    defer b.deinit();
    try b.mount(stories.Closable(.{ .label = "solo" }));
    try testing.expect(b.find("solo") != null);
}

test "Yix for (0..n): rows expand once, capture outer sources and the index" {
    var a = try Env.init();
    defer a.deinit();
    try a.mount(stories.Stars(.{}));
    try testing.expect(a.find("0/2") != null);
    try testing.expect(a.find("4/2") != null);
    try a.click("More");
    try testing.expect(a.find("3/3") != null);
    // 5 text lines + 3 spacers + button
    try testing.expectEqual(@as(usize, 9), a.root.?.children.items.len);
}

test "Yix for (0..n): a count that depends on props and signals re-expands when it changes" {
    var a = try Env.init();
    defer a.deinit();
    try a.mount(stories.GrowingStars(.{}));
    try testing.expect(a.find("star 1") != null);
    try testing.expect(a.find("star 2") == null);
    try a.click("Add");
    try testing.expect(a.find("star 2") != null);
    try a.click("Add");
    try testing.expect(a.find("star 3") != null);
    try testing.expect(a.find("star 4") == null);
}

test "Yix event statements forward to the component's callbacks: gated, valued, optional" {
    var a = try Env.init();
    defer a.deinit();
    try a.mount(stories.ForwardUse(.{}));
    try a.click("Go");
    try testing.expect(a.find("presses 1") != null);
    try a.click("Seven");
    try testing.expect(a.find("presses 7") != null);
    try a.click("Lock");
    try a.click("Go"); // After disable, no forward
    try testing.expect(a.find("presses 7") != null);

    var b = try Env.init();
    defer b.deinit();
    try b.mount(stories.Forward(.{})); // No callback passed: click does nothing
    try b.click("Go");
    try b.click("Seven");
}

test "Yix for |item, i|: the index follows reused rows after a reorder" {
    var a = try Env.init();
    defer a.deinit();
    try a.mount(stories.Numbered(.{}));
    try testing.expect(a.find("0. first") != null);
    try testing.expect(a.find("1. second") != null);
    const first = a.find("0. first").?;
    try a.click("Reverse");
    try testing.expect(a.find("0. second") != null);
    try testing.expect(a.find("1. first") == first); // Same node, index updated
}

test "Yix control flow nests directly inside a branch (if … for …)" {
    var a = try Env.init();
    defer a.deinit();
    try a.mount(stories.NestedFlow(.{}));
    try testing.expect(a.find("row first") != null);
    try testing.expect(a.find("row second") != null);
    try a.click("Hide");
    try testing.expect(a.find("row first") == null);
}

test "Yix Model params: uncontrolled local value, parent-bound signal, onChange reports landed values" {
    var a = try Env.init();
    defer a.deinit();
    try a.mount(stories.Toggle(.{}));
    try testing.expect(a.find("off") != null);
    try a.click("Flip");
    try testing.expect(a.find("on") != null);

    var b = try Env.init();
    defer b.deinit();
    try b.mount(stories.ToggleBound(.{}));
    try testing.expect(b.find("flag true changes 0") != null);
    try testing.expect(b.find("on") != null);
    try b.click("Flip");
    // Proposal writes directly to parent signal, after landing calls onChange
    try testing.expect(b.find("flag false changes 1") != null);
    try testing.expect(b.find("off") != null);
}

test "Yix |v| captures the event value of a component event" {
    var a = try Env.init();
    defer a.deinit();
    try a.mount(stories.ToggleEcho(.{}));
    try a.click("Flip");
    try testing.expect(a.find("last true count 1") != null);
    try a.click("Flip");
    try testing.expect(a.find("last false count 2") != null);
}

test "Yix event statements support if / else with blocks and nesting" {
    var a = try Env.init();
    defer a.deinit();
    try a.mount(stories.Guarded(.{}));
    try a.click("Step");
    try a.click("Step");
    try testing.expect(a.find("n 2") != null);
    try a.click("Step");
    try testing.expect(a.find("n 0") != null);
    var b = try Env.init();
    defer b.deinit();
    try b.mount(stories.Guarded(.{ .locked = true }));
    try b.click("Step");
    try testing.expect(b.find("n -1") != null);
}

test "Yix event forms: else after a semicolon, if expressions on the right-hand side" {
    var e = try Env.init();
    defer e.deinit();
    try e.mount(stories.EventForms(.{}));
    try e.click("Go");
    try testing.expect(e.find("a 1 b 20") != null);
    try e.click("Go");
    try testing.expect(e.find("a 2 b 10") != null);
}

test "Yix rows: a field access .title is not confused with a captured prop named title" {
    var a = try Env.init();
    defer a.deinit();
    try a.mount(stories.FieldNamedLikeProp(.{}));
    try testing.expect(a.find("first-prop 9") != null);
    try testing.expect(a.find("second-prop 10") != null);
}

test "Yix keyed rows write a Model captured from the component; onChange gets the unwrapped landed value" {
    var a = try Env.init();
    defer a.deinit();
    try a.mount(stories.PickerUse(.{}));
    try testing.expect(a.find("Apple false") != null);
    try a.click("Apple");
    try testing.expect(a.find("Apple true") != null);
    try testing.expect(a.find("count 1") != null);
    try a.click("Banana");
    try testing.expect(a.find("Banana true") != null);
    try testing.expect(a.find("Apple false") != null);
    try testing.expect(a.find("count 2") != null);
    // Value unchanged: no callback (only lands values)
    try a.click("Banana");
    try testing.expect(a.find("count 2") != null);
}

test "文档示例 Chip（YIX_REFERENCE §2.1）：挂载、点击切换选中描边、没有 onRemove 时不显示移除按钮" {
    var e = try Env.init();
    defer e.deinit();
    try e.mount(doc_chip.Chip(.{ .label = "Zig", .tone = .accent }));
    try testing.expect(e.find("Zig") != null);
    try testing.expect(e.find("×") == null);
    try testing.expectEqual(@as(f32, 0), e.root.?.style.border.width);
    try e.click("Zig");
    try testing.expectEqual(@as(f32, 1), e.root.?.style.border.width);
    try e.click("Zig");
    try testing.expectEqual(@as(f32, 0), e.root.?.style.border.width);
}

test ".yss 的 typography 取 theme.json 的排版 token（字号经引用链解析）；单项属性覆盖它" {
    const t = &ui.theme.light;
    const want = t.tokens.typography.counterTitle;
    const h = @TypeOf(tokens_probe.heading).text(.{}, t);
    try testing.expectEqual(want.font_size.?, h.font_size);
    try testing.expectEqual(want.font_weight.?, h.font_weight);
    try testing.expectEqual(t.tokens.font_size.xxxl, h.font_size);
    const l = @TypeOf(tokens_probe.heading_light).text(.{}, t);
    try testing.expectEqual(want.font_size.?, l.font_size);
    try testing.expectEqual(t.tokens.font_weight.regular, l.font_weight);
}

test "B1 静态提升按实际依赖收缩：静态参数 + 函数调用里读的外部 store 照样跟随；无外部读取时稳态零 memo" {
    var e = try Env.init();
    defer e.deinit();
    const store = try e.scope.createSignal(i32, 10);
    stories.external_count = store;
    defer stories.external_count = null;
    try e.mount(stories.ExternalSum(.{ .n = 1 }));
    try testing.expect(e.find("sum 11") != null);
    store.set(20);
    try testing.expect(e.find("sum 21") != null);

    var f = try Env.init();
    defer f.deinit();
    const before = try graph_assertions.staticCounts(f.cx);
    try f.mount(stories.StaticTwice(.{ .n = 4 }));
    const after = try graph_assertions.staticCounts(f.cx);
    try testing.expect(f.find("twice 8") != null);
    try testing.expectEqual(before.get(.memo), after.get(.memo));
    try testing.expectEqual(before.get(.effect), after.get(.effect));
}

test "P2：<X>文字</X> 按组件参数判断（别名同样当 label，带插槽的组件当子元素）；不写默认值的参数必填" {
    var a = try Env.init();
    defer a.deinit();
    try a.mount(stories.AliasLabel(.{}));
    try a.click("Aliased");
    try testing.expect(a.find("n 1") != null);

    var b = try Env.init();
    defer b.deinit();
    try b.mount(stories.TextIntoSlot(.{}));
    try testing.expect(b.find("plain words") != null);

    var c = try Env.init();
    defer c.deinit();
    try c.mount(stories.RequiredUse(.{}));
    try c.click("Go there");
    try testing.expect(c.find("went 1") != null);
}

test "P3a I6：{if (x) |v|} 可选值捕获——值变化不重建分支，变 null 走 else" {
    var e = try Env.init();
    defer e.deinit();
    try e.mount(stories.PickedName(.{}));
    try testing.expect(e.find("none") != null);
    try e.click("A");
    const first = e.find("picked a") orelse return error.TestUnexpectedResult;
    try e.click("B");
    const second = e.find("picked b") orelse return error.TestUnexpectedResult;
    try testing.expect(first == second); // Same text node: branch not rebuilt
    try e.click("Clear");
    try testing.expect(e.find("none") != null);
    try testing.expect(e.find("picked b") == null);
}

test "P3a I6：switch 分支 => |p| 捕获联合载荷，同一标签内载荷变化不重建" {
    var e = try Env.init();
    defer e.deinit();
    try e.mount(stories.ShapeLabel(.{}));
    const c1 = e.find("circle 1") orelse return error.TestUnexpectedResult;
    try e.click("Grow");
    const c2 = e.find("circle 2") orelse return error.TestUnexpectedResult;
    try testing.expect(c1 == c2);
    try e.click("Square");
    try testing.expect(e.find("square 5") != null);
    try e.click("None");
    try testing.expect(e.find("no shape") != null);
}

test "P3a I6：错误联合的 |v| / else |e| 捕获" {
    var a = try Env.init();
    defer a.deinit();
    try a.mount(stories.Parsed(.{ .result = 7 }));
    try testing.expect(a.find("value 7") != null);
    var b = try Env.init();
    defer b.deinit();
    try b.mount(stories.Parsed(.{ .result = error.Bad }));
    try testing.expect(b.find("error Bad") != null);
}

test "P3a I12：分支惰性构造——隐藏分支里的派生值不建 memo，显示时才建，隐藏时随分支释放" {
    var e = try Env.init();
    defer e.deinit();
    const n = try e.scope.createSignal(i32, 3);
    const base = e.cx.owner.graph.countByKind();
    try e.mount(stories.LazyBranch(.{ .n = n }));
    const hidden = e.cx.owner.graph.countByKind();
    try e.click("Toggle");
    try testing.expect(e.find("7") != null);
    const shown = e.cx.owner.graph.countByKind();
    try testing.expect(shown.get(.memo) > hidden.get(.memo)); // n * 2 + 1 memo built only when shown
    try e.click("Toggle");
    const again = e.cx.owner.graph.countByKind();
    try testing.expectEqual(hidden.get(.memo), again.get(.memo)); // After hide released with branch scope
    _ = base;
}

fn findTestId(n: *ui.Node, id: []const u8) ?*ui.Node {
    if (n.meta.ownership.meta.test_id) |t| if (std.mem.eql(u8, t, id)) return n;
    for (n.children.items) |c| if (findTestId(c, id)) |r| return r;
    return null;
}

test "P3a B2：宿主元素类型化事件——onKeyDown 带 KeyPress、consume 才拦截；指针坐标与 move；onScroll 的 stop" {
    var e = try Env.init();
    defer e.deinit();
    try e.mount(stories.KeyPad(.{}));
    const pad = findTestId(e.root.?, "pad") orelse return error.TestUnexpectedResult;
    const ev = pad.behavior.events;
    const dispatch = ev.on_event.?;
    try testing.expectEqual(ui.events.EventResult.handled, dispatch(.{ .key_down = .{ .key = .escape } }, ev.event_context));
    try testing.expect(e.find("key escape") != null);
    try testing.expectEqual(ui.events.EventResult.ignored, dispatch(.{ .key_down = .{ .key = .tab } }, ev.event_context));
    try testing.expect(e.find("key other") != null);
    try testing.expectEqual(ui.events.EventResult.ignored, dispatch(.{ .key_up = .{ .key = .escape } }, ev.event_context));
    const r = pad.rectFromWorldOrFallback();
    _ = dispatch(.{ .mouse_down = .{ .x = r.x + 12, .y = r.y + 3 } }, ev.event_context);
    try testing.expect(e.find("x 12") != null);
    _ = dispatch(.{ .mouse_move = .{ .x = 1, .y = 1 } }, ev.event_context);
    _ = dispatch(.{ .mouse_move = .{ .x = 2, .y = 1 } }, ev.event_context);
    try testing.expect(e.find("moves 2") != null);
    try testing.expectEqual(ui.events.EventResult.stop, dispatch(.{ .scroll = .{ .dx = 0, .dy = 1, .x = 0, .y = 0 } }, ev.event_context));
}

test "P3a B2：effect 跟随源、onMount 时 ref 已挂上、onUnmount 卸载时执行" {
    stories.lifecycle_len = 0;
    var e = try Env.init();
    const n = try e.scope.createSignal(i32, 3);
    try e.mount(stories.Lifecycle(.{ .n = n }));
    try testing.expect(e.find("doubled 6") != null);
    n.set(5);
    try testing.expect(e.find("doubled 10") != null);
    try testing.expectEqual(@as(usize, 1), stories.lifecycle_len);
    try testing.expectEqual(@as(i32, 1), stories.lifecycle_log[0]); // After mount, ref has node
    e.deinit();
    try testing.expectEqual(@as(usize, 2), stories.lifecycle_len);
    try testing.expectEqual(@as(i32, -1), stories.lifecycle_log[1]);
}

test "P3a B2：事件里 try 失败经 ui.on.reportError 上报（后面的语句不执行），const 局部可用" {
    ui.on.suppress_error_log = true;
    defer ui.on.suppress_error_log = false;
    var e = try Env.init();
    defer e.deinit();
    try e.mount(stories.TryEvent(.{}));
    try e.click("Ok");
    try testing.expect(e.find("n 5") != null);
    const before = ui.on.handler_error_count;
    try e.click("Fail");
    try testing.expectEqual(before + 1, ui.on.handler_error_count);
    try testing.expect(e.find("n 5") != null);
}

test "P3a：普通 box 的 :focus / :focus-visible 由节点焦点驱动，:disabled 取 a11y.disabled（YSS）" {
    var e = try Env.init();
    defer e.deinit();
    const disabled = try e.scope.createSignal(bool, false);
    try e.mount(stories.StateBox(.{ .disabled = disabled }));
    const sb = findTestId(e.root.?, "sb") orelse return error.TestUnexpectedResult;
    try testing.expectApproxEqAbs(@as(f32, 1), sb.getOpacity(), 0.001);
    // Focus through the manager: :focus-visible follows its resolved visibility (pointer focus
    // hides the ring, keyboard focus shows it), not a raw focus reason.
    e.cx.focus_manager.setFocusWithVisibility(sb, .click, .hide);
    try testing.expectApproxEqAbs(@as(f32, 0.9), sb.getOpacity(), 0.001);
    e.cx.focus_manager.clearFocus();
    e.cx.focus_manager.setFocusWithVisibility(sb, .tab, .show);
    try testing.expectApproxEqAbs(@as(f32, 0.8), sb.getOpacity(), 0.001);
    e.cx.focus_manager.clearFocus();
    try testing.expectApproxEqAbs(@as(f32, 1), sb.getOpacity(), 0.001);
    disabled.set(true);
    try testing.expectApproxEqAbs(@as(f32, 0.5), sb.getOpacity(), 0.001);
}

test "P3a B2：scope 释放时类型化事件适配器从节点上摘除（卸载摘链时的 blur 不会进到已释放的状态）" {
    var e = try Env.init();
    try e.mount(stories.KeyPad(.{}));
    const pad = findTestId(e.root.?, "pad") orelse return error.TestUnexpectedResult;
    try testing.expect(pad.behavior.events.on_event != null);
    e.scope.dispose();
    try testing.expect(pad.behavior.events.on_event == null);
    try testing.expect(pad.behavior.events.event_context == null);
    if (e.root) |r| e.cx.freeNode(r);
    e.cx.deinit();
}

test "P3b：具名插槽与 {children} 在容器中间（子元素插在锚点前，顺序与模板一致）" {
    var e = try Env.init();
    defer e.deinit();
    try e.mount(stories.FrameUse(.{}));
    const head = e.find("head") orelse return error.TestUnexpectedResult;
    const title = e.find("T") orelse return error.TestUnexpectedResult;
    try testing.expect(head.parent == title.parent);
    try testing.expect(indexIn(head) < indexIn(title)); // Named slot content before title
    const body = e.find("body 0") orelse return error.TestUnexpectedResult;
    const after = e.find("after body") orelse return error.TestUnexpectedResult;
    try testing.expect(body.parent == after.parent);
    try testing.expect(indexIn(body) < indexIn(after)); // Default slot in middle: inserted before anchor
    try e.click("More"); // Event in footer named slot writes caller signal
    try testing.expect(e.find("body 1") != null);
}

test "可选具名插槽：缺席不建槽盒、不占 gap；传入时位置正确、事件写调用方信号" {
    {
        var e = try Env.init();
        defer e.deinit();
        try e.mount(stories.FieldBare(.{}));
        const field = findTestId(e.root.?, "field") orelse return error.TestUnexpectedResult;
        try testing.expectEqual(@as(usize, 1), field.children.items.len); // only content
        try testing.expect(findTestId(e.root.?, "field.icon") == null);
        try testing.expect(findTestId(e.root.?, "field.append") == null);
        try testing.expect(e.find("body") != null);
    }
    {
        var e = try Env.init();
        defer e.deinit();
        try e.mount(stories.FieldFull(.{}));
        const field = findTestId(e.root.?, "field") orelse return error.TestUnexpectedResult;
        try testing.expectEqual(@as(usize, 3), field.children.items.len);
        const icon = findTestId(e.root.?, "field.icon") orelse return error.TestUnexpectedResult;
        const append = findTestId(e.root.?, "field.append") orelse return error.TestUnexpectedResult;
        try testing.expect(icon == field.children.items[0]);
        try testing.expect(append == field.children.items[2]);
        const ico = e.find("ico") orelse return error.TestUnexpectedResult;
        try testing.expect(ico.parent == icon);
        // Slot at the end of its box: appended after the box's own children.
        const bracket = e.find("[") orelse return error.TestUnexpectedResult;
        try testing.expect(bracket.parent == append and indexIn(bracket) == 0);
        try testing.expect(e.find("body 0") != null);
        try e.click("go");
        try testing.expect(e.find("body 1") != null);
    }
}

test "可选具名插槽：Zig 调用方 .slots(.{ .icon = null }) 与可选值同样按缺席处理" {
    var e = try Env.init();
    defer e.deinit();
    const no_icon: ?@TypeOf(ui.view.text(.{}, "x")) = null;
    try e.mount(ui.view.with(stories.Field(.{}), .{ui.view.text(.{}, "body")}).slots(.{ .icon = no_icon, .append = null }));
    const field = findTestId(e.root.?, "field") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 1), field.children.items.len);
    try testing.expect(e.find("body") != null);
}

fn indexIn(n: *ui.Node) usize {
    for (n.parent.?.children.items, 0..) |c, i| if (c == n) return i;
    unreachable;
}

test "P4：icon-color 随变体切换、自定义阴影的 token 颜色按主题解析" {
    var e = try Env.init();
    defer e.deinit();
    const hot = try e.scope.createSignal(bool, false);
    try e.mount(stories.GlyphBox(.{ .hot = hot }));
    const g = findTestId(e.root.?, "glyph") orelse return error.TestUnexpectedResult;
    const t = e.cx.tokens;
    const tintOf = struct {
        fn f(n: *ui.Node) ui.Color {
            return if (n.getIcon()) |ic| ic.tint else n.getImage().?.tint;
        }
    }.f;
    try testing.expect(tintOf(g).eql(t.tokens.color.fg_secondary));
    hot.set(true);
    try testing.expect(tintOf(g).eql(t.tokens.color.accent));
    hot.set(false);
    try testing.expect(tintOf(g).eql(t.tokens.color.fg_secondary));
    const sh = g.style.ext.?.shadows[0];
    try testing.expect(sh.color.eql(t.tokens.color.accent));
    try testing.expectEqual(@as(f32, 6), sh.blur);
}

test "P4：样式不再给 icon-color 时回到挂载时的着色（没有 tint= 时是默认白色；tint= 与 icon-color 互斥）" {
    var e = try Env.init();
    defer e.deinit();
    const hot = try e.scope.createSignal(bool, false);
    try e.mount(stories.GlyphTinted(.{ .hot = hot }));
    const g = findTestId(e.root.?, "glyph") orelse return error.TestUnexpectedResult;
    try testing.expect(g.getIcon().?.tint.eql(ui.Color.WHITE));
    hot.set(true);
    try testing.expect(g.getIcon().?.tint.eql(e.cx.tokens.tokens.color.accent));
    hot.set(false);
    try testing.expect(g.getIcon().?.tint.eql(ui.Color.WHITE));
}

test "P4：文本的 :hover——悬停时换色，离开恢复" {
    var e = try Env.init();
    defer e.deinit();
    try e.mount(stories.LinkText(.{}));
    const link = e.find("Open docs") orelse return error.TestUnexpectedResult;
    const c = e.cx.tokens.tokens.color;
    try testing.expect(link.getText().?.color.eql(c.accent));
    link.behavior.events.on_hover.?.invoke();
    try testing.expect(link.getText().?.color.eql(c.fg_primary));
    link.behavior.events.on_leave.?.invoke();
    try testing.expect(link.getText().?.color.eql(c.accent));
}

test "P4：盒 + 文字合一的 style 用在 <text> 上：文字字段进文本样式，盒字段落到文本节点自身" {
    var e = try Env.init();
    defer e.deinit();
    try e.mount(stories.PillText(.{}));
    const pill = findTestId(e.root.?, "pill") orelse return error.TestUnexpectedResult;
    const t = e.cx.tokens.tokens;
    try testing.expect(pill.getText().?.color.eql(t.color.accent));
    try testing.expectEqual(t.font_size.sm, pill.getText().?.font_size);
    try testing.expect(pill.getBackground().eql(t.color.bg_secondary));
    try testing.expectEqual(@as(f32, 8), pill.style.padding.left);
    try testing.expectEqual(@as(f32, 4), pill.style.padding.top);
}

test "P5：列表行原地更新——同 key 改标题后行节点不变、文字更新、焦点保持，事件读到最新数据" {
    var e = try Env.init();
    defer e.deinit();
    const Item = @typeInfo(@FieldType(stories.EditableRowsProps, "rows").Value).pointer.child;
    const a = [_]Item{ .{ .id = 1, .title = "one" }, .{ .id = 2, .title = "two" } };
    const b = [_]Item{ .{ .id = 1, .title = "one" }, .{ .id = 2, .title = "TWO" } };
    const c = [_]Item{ .{ .id = 2, .title = "TWO" }, .{ .id = 1, .title = "one" } };
    const rows = try e.scope.createSignal([]const Item, &a);
    try e.mount(stories.EditableRows(.{ .rows = rows }));
    const before = e.find("1:two") orelse return error.TestUnexpectedResult;
    const row_before = before.parent.?;
    e.cx.focus_manager.setFocusWithReason(row_before, .programmatic);
    rows.set(&b);
    const after = e.find("1:TWO") orelse return error.TestUnexpectedResult;
    try testing.expect(after == before); // Same text node: line not rebuilt
    try testing.expect(e.cx.focus_manager.getFocused() == row_before);
    try e.click("1:TWO");
    try testing.expectEqualStrings("TWO", stories.picked_title);
    rows.set(&c); // Reorder: reused rows follow new index
    try testing.expect(e.find("0:TWO") == before);
    try testing.expect(e.find("1:one") != null);
}

test "P5：调和时内容相同的行也换成新数组的值（不通知）——旧数组的字符串释放后，行里读到的仍有效" {
    var e = try Env.init();
    defer e.deinit();
    const Item = @typeInfo(@FieldType(stories.EditableRowsProps, "rows").Value).pointer.child;
    const old_title = try testing.allocator.dupe(u8, "two");
    var a = [_]Item{ .{ .id = 1, .title = "one" }, .{ .id = 2, .title = old_title } };
    const rows = try e.scope.createSignal([]const Item, &a);
    try e.mount(stories.EditableRows(.{ .rows = rows }));
    const before = e.find("1:two") orelse return error.TestUnexpectedResult;
    const new_title = try testing.allocator.dupe(u8, "two");
    defer testing.allocator.free(new_title);
    // First row changed (triggers reconcile); second row content same, string in new buffer
    const b = [_]Item{ .{ .id = 1, .title = "ONE" }, .{ .id = 2, .title = new_title } };
    rows.set(&b);
    testing.allocator.free(old_title); // Caller frees old array string
    try testing.expect(e.find("1:two") == before);
    try e.click("1:two");
    try testing.expectEqualStrings("two", stories.picked_title);
    try testing.expect(stories.picked_title.ptr == new_title.ptr);
}

fn findFocusable(n: *ui.Node) ?*ui.Node {
    if (n.behavior.events.on_event != null and n.behavior.events.event_context != null) return n;
    for (n.children.items) |c| if (findFocusable(c)) |r| return r;
    return null;
}
test "组件元素上的 onKeyDown 装在组件根的 capture 槽：焦点在组件内部时先收到按键，consume 拦下组件的处理，不覆盖组件根的 on_event" {
    var e = try Env.init();
    defer e.deinit();
    try e.mount(stories.ComponentKeys(.{}));
    const root = findTestId(e.root.?, "field") orelse return error.TestUnexpectedResult;
    try testing.expect(root.behavior.events.on_event_capture != null and root.behavior.events.capture_context != null);
    const inner = findFocusable(root) orelse return error.TestUnexpectedResult;
    // Mount as window root and run one frame: nodes enter registry, dispatch on real capture /
    // target / bubble paths
    e.cx.setViewport(400, 300);
    e.cx.root = e.root;
    defer e.cx.root = null;
    e.cx.layout();
    _ = e.cx.render();
    e.cx.setFocus(inner);
    try testing.expectEqual(ui.events.EventResult.stop, e.cx.dispatcher.dispatchKeyDown(inner, .{ .key = .delete, .modifiers = .{} }));
    try testing.expect(e.find("keys 1 text ab") != null); // Intercept: Input didn't delete char
    _ = e.cx.dispatcher.dispatchKeyDown(inner, .{ .key = .delete, .modifiers = .{} });
    try testing.expect(e.find("keys 11 text a") != null); // Not intercept: Input normally deletes one char
}

test "组件根的类型化事件：所在分支反复卸载 / 重挂，新根上照常生效，旧表随组件 scope 释放" {
    var e = try Env.init();
    defer e.deinit();
    try e.mount(stories.ToggledKeys(.{}));
    e.cx.setViewport(400, 300);
    e.cx.root = e.root;
    defer e.cx.root = null;
    for (0..3) |_| {
        try e.click("toggle");
        try testing.expect(findTestId(e.root.?, "tfield") == null);
        try e.click("toggle");
    }
    e.cx.layout();
    _ = e.cx.render();
    const root = findTestId(e.root.?, "tfield") orelse return error.TestUnexpectedResult;
    const inner = findFocusable(root) orelse return error.TestUnexpectedResult;
    _ = e.cx.dispatcher.dispatchKeyDown(inner, .{ .key = .tab, .modifiers = .{} });
    try testing.expect(e.find("tk 1") != null);
}

test "受控值收到只读源 + onChange：合成 split，父组件改写的值回到 Input 缓冲（强制大写）" {
    var e = try Env.init();
    defer e.deinit();
    try e.mount(stories.UpperInput(.{}));
    const root = findTestId(e.root.?, "up") orelse return error.TestUnexpectedResult;
    const inner = findFocusable(root) orelse return error.TestUnexpectedResult;
    const h = inner.behavior.events.on_event.?;
    _ = h(.{ .ime_commit = .{ .text = "c" } }, inner.behavior.events.event_context);
    try testing.expect(e.find("code ABC") != null);
    try testing.expect(e.find("ABC") != null); // Input's own displayed text is also rewritten
}

test "参数化样式：静态参数不建 effect；可选参数为 null 时取 ?? 后备值" {
    var e = try Env.init();
    defer e.deinit();
    const before = (try graph_assertions.staticCounts(e.cx)).get(.effect);
    try e.mount(ui.view.box(.{ .style = params.panel.of(.{ .width = 120, .background = ui.Color.hex(0x112233) }) }, .{}));
    try testing.expectEqual(before, (try graph_assertions.staticCounts(e.cx)).get(.effect));
    try testing.expectEqual(ui.Sizing{ .px = 120 }, e.root.?.style.width);
    try testing.expectEqual(ui.Color.hex(0x112233), e.root.?.getBackground());
    try testing.expectEqual(@as(f32, 1), e.root.?.getOpacity());
    // Hand-written Zig: resolve directly produces box style from params
    const s = params.panel.resolve(.{ .width = null, .background = null, .tone = .loud }, e.cx.tokens);
    try testing.expect(s.width.? == .fit);
    try testing.expect(s.background == null);
    try testing.expectEqual(@as(f32, 0.5), s.opacity.?);
}

test "参数化样式：参数来自信号时逐项跟随；背景从有色变 null 时被抹除（回到默认透明），when 块随条件撤销" {
    var e = try Env.init();
    defer e.deinit();
    const width = try e.scope.createSignal(?f32, 100);
    const bg = try e.scope.createSignal(?ui.Color, ui.Color.hex(0xff0000));
    const tone = try e.scope.createSignal(params.Tone, .calm);
    const pad = try e.scope.createSignal(bool, false);
    try e.mount(ui.view.box(.{ .style = params.panel.of(.{ .width = width, .background = bg, .tone = tone, .pad = pad }) }, .{}));
    const n = e.root.?;
    try testing.expectEqual(ui.Sizing{ .px = 100 }, n.style.width);
    try testing.expectEqual(ui.Color.hex(0xff0000), n.getBackground());
    width.set(null);
    try testing.expect(n.style.width == .fit);
    bg.set(null);
    try testing.expectEqual(ui.Color.TRANSPARENT, n.getBackground());
    bg.set(ui.Color.hex(0x00ff00));
    try testing.expectEqual(ui.Color.hex(0x00ff00), n.getBackground());
    tone.set(.loud);
    try testing.expectEqual(@as(f32, 0.5), n.getOpacity());
    tone.set(.calm);
    try testing.expectEqual(@as(f32, 1), n.getOpacity());
    pad.set(true);
    try testing.expectEqual(@as(f32, 4), n.style.padding.top);
    try testing.expectEqual(ui.FlexWrap.wrap, n.style.flex_wrap());
    pad.set(false);
    try testing.expectEqual(@as(f32, 0), n.style.padding.top);
    try testing.expectEqual(ui.FlexWrap.no_wrap, n.style.flex_wrap());
}

test "参数化样式：多层阴影（token + 自定义）与 token 后备值随主题重算" {
    var e = try Env.init();
    defer e.deinit();
    try e.mount(ui.view.box(.{ .style = params.framed.of(.{ .fill = null }) }, .{}));
    e.cx.root = e.root;
    defer e.cx.root = null;
    const n = e.root.?;
    e.cx.setTheme(&ui.theme.modes.light);
    try testing.expectEqual(ui.theme.modes.light.tokens.color.bg_secondary, n.getBackground());
    const list = n.style.shadowSlice();
    try testing.expectEqual(@as(usize, 2), list.len);
    try testing.expectEqual(ui.theme.modes.light.tokens.shadow.md.blur, list[0].blur);
    try testing.expect(list[1].color.eql(ui.theme.modes.light.tokens.color.accent));
    e.cx.setTheme(&ui.theme.modes.dark);
    try testing.expectEqual(ui.theme.modes.dark.tokens.color.bg_secondary, n.getBackground());
    try testing.expect(n.style.shadowSlice()[1].color.eql(ui.theme.modes.dark.tokens.color.accent));
}

test "YSS 普通样式的 {zig} 读主题 t：按当前主题解析，换主题跟随" {
    var e = try Env.init();
    defer e.deinit();
    try e.mount(ui.view.box(.{ .style = params.themed_ring }, .{}));
    e.cx.root = e.root;
    defer e.cx.root = null;
    const n = e.root.?;
    e.cx.setTheme(&ui.theme.modes.light);
    try testing.expect(n.style.ext.?.outline.?.color.eql(ui.theme.modes.light.tokens.color.accent));
    e.cx.setTheme(&ui.theme.modes.dark);
    try testing.expect(n.style.ext.?.outline.?.color.eql(ui.theme.modes.dark.tokens.color.accent));
}

test "组件参数名以 on 开头但类型是数据（onTop: bool）：字面量与信号按值传；事件参数收到标识符时调用它" {
    var e = try Env.init();
    defer e.deinit();
    const pinned = try e.scope.createSignal(bool, false);
    try e.mount(stories.PinBoard(.{ .pinned = pinned }));
    const col = e.root.?;
    try testing.expect(col.children.items[0].style.display == .flex);
    const second = col.children.items[1];
    try testing.expect(second.style.display == .none);
    pinned.set(true);
    try testing.expect(second.style.display == .flex);
    const before = stories.saved_count;
    const h = second.behavior.events.on_click.?;
    h.callback(h.context);
    try testing.expectEqual(before + 1, stories.saved_count);
    // Value expression (!pinned) to data param; call (save()) to event param
    const third = col.children.items[2];
    try testing.expect(third.style.display == .none);
    pinned.set(false);
    try testing.expect(third.style.display == .flex);
    const h3 = third.behavior.events.on_click.?;
    h3.callback(h3.context);
    try testing.expectEqual(before + 2, stories.saved_count);
}

test "Text 参数：<Caption>Hello</Caption> 的文字进组件声明为 Text 的参数（参数叫 title 也行，不按名字猜）" {
    var e = try Env.init();
    defer e.deinit();
    try e.mount(stories.Captions(.{}));
    try testing.expect(e.find("Hello") != null);
}

test "嵌套 for：内层列表是外层行的派生值，内层行引用外层行的字段；类型位置里名字代表值（@TypeOf(n) 是值的类型）" {
    var e = try Env.init();
    defer e.deinit();
    const members = [_]stories.Item{ .{ .id = 1, .title = "x" }, .{ .id = 2, .title = "y" } };
    const groups = [_]stories.Group{.{ .id = 7, .name = "A", .members = &members }};
    try e.mount(stories.Groups(.{ .groups = &groups }));
    try testing.expect(e.find("A/x") != null);
    try testing.expect(e.find("A/y") != null);
    var e2 = try Env.init();
    defer e2.deinit();
    try e2.mount(stories.TypeOfProbe(.{ .n = 21 }));
    try testing.expect(e2.find("42") != null);
}

test "LP3 setup/view: generated hooks and refs roll back at every allocation failure" {
    const fixture = @import("_lifecycle_split.yix.zig");
    // Reset the bounded hook log for each mount attempted by the sweep.
    const Probe = struct {
        fn component(args: anytype) @TypeOf(fixture.Split(args)) {
            fixture.log_len = 0;
            fixture.last_ref = null;
            return fixture.Split(args);
        }
    };
    try allocationSweep(Probe.component);
}

test "LP3 setup/view: initial slotted components roll back every allocation failure" {
    const fixture = @import("_lifecycle_split.yix.zig");
    try allocationSweep(fixture.SlottedForOom);
}

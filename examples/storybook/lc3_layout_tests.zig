const std = @import("std");
const ui = @import("ui");
const stories = @import("stories.zig");
const glass = ui.widgets.glass_box;

fn find(n: *ui.Node, id: []const u8) ?*ui.Node {
    if (n.meta.ownership.meta.test_id) |s| if (std.mem.eql(u8, s, id)) return n;
    for (n.children.items) |c| if (find(c, id)) |r| return r;
    return null;
}
fn hooks(n: *ui.Node) void {
    glass.runBeforeRenderHooks(n);
    for (n.children.items) |c| hooks(c);
}
fn state(n: *ui.Node) *glass.AdaptiveGlassBoxState {
    return @ptrCast(@alignCast(n.meta.per_frame.hooks.slots.anim_state.?));
}
fn click(n: *ui.Node) void {
    n.behavior.events.on_click.?.invoke();
}
const Rig = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    fn init(builder: anytype) !Rig {
        return initSized(builder, 760, 900);
    }
    fn initSized(builder: anytype, width: f32, height: f32) !Rig {
        const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
        errdefer cx.deinit();
        const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
        errdefer scope.dispose();
        const root = try ui.box(cx, .{ .width = .{ .px = width }, .height = .{ .px = height } }, .{});
        cx.root = root;
        try root.appendChild(cx.allocator, try builder(scope, cx));
        cx.layout();
        cx.frame_time_ms = 1000;
        hooks(root);
        cx.layout();
        return .{ .cx = cx, .scope = scope };
    }
    fn deinit(self: Rig) void {
        self.scope.dispose();
        self.cx.deinit();
    }
    fn get(self: Rig, id: []const u8) *ui.Node {
        return (find(self.cx.root.?, id) orelse if (self.cx.popover_portal_root) |portal| find(portal, id) else null).?;
    }
    fn tick(self: Rig, dt: f64) void {
        self.cx.frame_time_ms += dt;
        self.cx.frame_dt_ms = @floatCast(dt);
        if (self.cx.test_frame_step_ms != null) {
            self.cx.setFramePresentationSample(.{ .tick = @intFromFloat(self.cx.frame_time_ms * 2), .target_time_ms = self.cx.frame_time_ms * 2, .period_ms = 16 });
        }
        hooks(self.cx.root.?);
        self.cx.layout();
        hooks(self.cx.root.?);
    }
};

fn compareGeometry(a: *ui.Node, b: *ui.Node, dy: f32) !void {
    const ar = a.globalRect();
    const br = b.globalRect();
    try std.testing.expectApproxEqAbs(ar.x, br.x, 0.01);
    try std.testing.expectApproxEqAbs(ar.y + dy, br.y, 0.01);
    try std.testing.expectApproxEqAbs(ar.w, br.w, 0.01);
    try std.testing.expectApproxEqAbs(ar.h, br.h, 0.01);
    for (a.children.items, b.children.items) |ac, bc| try compareGeometry(ac, bc, dy);
}

test "LC3 story GlassGroup preserves sampling geometry" {
    const r = try Rig.init(stories.buildGlassGroup);
    defer r.deinit();
    const single = r.get("story.glassgroup.single").globalRect();
    const group = r.get("story.glassgroup.group").globalRect();
    std.debug.print("group single={any} group={any}\n", .{ single, group });
    try std.testing.expectApproxEqAbs(@as(f32, 144), group.y - single.y, 0.01);
    try std.testing.expectApproxEqAbs(single.w, group.w, 0.01);
    const sn = r.get("story.glassgroup.single");
    const gn = r.get("story.glassgroup.group");
    for (sn.children.items, 0..) |n, i| {
        const other = if (i < 3) gn.children.items[0].children.items[i + 1] else gn.children.items[1].children.items[1];
        try compareGeometry(n, other, 144);
        try std.testing.expectApproxEqAbs(n.globalRect().h, n.children.items[0].globalRect().h, 0.01);
        try std.testing.expectApproxEqAbs(n.children.items[0].globalRect().h, other.children.items[0].globalRect().h, 0.01);
    }
}

test "LC3 story GlassMaterialize keeps geometry through midpoint" {
    const r = try Rig.init(stories.buildGlassMotion);
    defer r.deinit();
    try r.cx.setTestFrameStep(16);
    const n = r.get("story.glassmotion.materialize");
    const before = n.globalRect();
    std.debug.print("materialize before={any} surface={any}\n", .{ before, n.children.items[0].globalRect() });
    click(r.get("story.glassmotion.toggle"));
    r.tick(0);
    r.tick(700);
    click(r.get("story.glassmotion.toggle"));
    r.tick(0);
    r.tick(210);
    std.debug.print("materialize mid={any} level={d}\n", .{ n.globalRect(), state(n).materialize_level });
    try std.testing.expectApproxEqAbs(@as(f32, 56), before.h, 0.01);
    try std.testing.expectApproxEqAbs(before.h, n.children.items[0].globalRect().h, 0.01);
    try std.testing.expect(state(n).materialize_level > 0.4 and state(n).materialize_level < 0.6);
}

test "LC3 story GlassSplit samples bridge and absorbs to cap" {
    const r = try Rig.init(stories.buildGlassSplit);
    defer r.deinit();
    try r.cx.setTestFrameStep(16);
    click(r.get("story.glasssplit.slowbtn"));
    click(r.get("story.glasssplit.splitbtn"));
    r.tick(0);
    var near: usize = 0;
    for (0..480) |_| {
        r.tick(1000.0 / 60.0);
        const a = r.get("story.glasssplit.bar0").globalRect();
        const b = r.get("story.glasssplit.bar1").globalRect();
        const gap = b.x - a.x - a.w;
        if (gap >= 0 and gap < 9) near += 1;
    }
    std.debug.print("split bridge samples={d}\n", .{near});
    try std.testing.expect(near > 0);
    click(r.get("story.glasssplit.splitbtn"));
    r.tick(0);
    var tiny = false;
    for (0..480) |i| {
        r.tick(1000.0 / 60.0);
        const b = r.get("story.glasssplit.bar1");
        if (i == 479) try std.testing.expect(state(b).matched != null and state(b).enabled);
        if (b.globalRect().h < 1 and state(b).enabled) tiny = true;
    }
    try std.testing.expect(tiny);
}

test "LC3 story GlassPopover preserves native body geometry" {
    const r = try Rig.init(stories.buildGlassPopover);
    defer r.deinit();
    // The portal is installed by the app. The mounted chrome/content can also be
    // measured directly without presentation transforms or a GPU.
    var trigger = r.get("story.glasspopover.button");
    while (trigger.behavior.events.on_click == null) trigger = trigger.parent.?;
    click(trigger);
    r.tick(0);
    r.tick(800);
    const panel = r.get("story.glasspopover.panel");
    panel.style.display = .flex;
    panel.style.width = .{ .fit = .{} };
    panel.style.height = .{ .fit = .{} };
    panel.style.position = .relative;
    if (panel.parent) |parent| parent.removeChild(panel);
    try r.cx.root.?.appendChild(r.cx.allocator, panel);
    panel.markLayoutDirty();
    r.cx.layout();
    const body = panel.children.items[0];
    std.debug.print("popover panel={any} body={any}\n", .{ panel.globalRect(), body.globalRect() });
    try std.testing.expectApproxEqAbs(@as(f32, 200), body.globalRect().w, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 74.55), body.globalRect().h, 0.01);
    try std.testing.expectApproxEqAbs(body.globalRect().h, body.children.items[0].globalRect().h, 0.01);
}

const notification_story = @import("notification_story.zig");
const story_styles = @import("styles.zig");
fn notificationChrome(scope: *ui.Scope, cx: *ui.Cx) !*ui.Node {
    _ = try cx.ensurePopoverPortalRoot();
    const v = ui.view;
    return v.render(scope, cx, v.row(.{ .style = story_styles.content_layer }, .{
        v.box(.{ .style = story_styles.contentGutter, .test_id = "lc3.gutter" }, .{}),
        v.col(.{ .style = story_styles.workspace, .test_id = "lc3.workspace" }, v.with(ui.widgets.ScrollArea(.{
            .direction = .vertical,
            .padding = .{ .top = 84, .right = 32, .bottom = 32, .left = 32 },
        }), v.col(.{ .style = story_styles.contentColumn }, v.col(.{ .style = story_styles.panelHug }, v.component(notification_story.build, {}))))),
        // The actual macOS sidebar overlays the content gutter. A control behind
        // this region receives a sidebar hit, so invoking its handler directly
        // would miss the regression that produced missing notification test ids.
        v.box(.{ .style = .{ .position = .absolute, .width = ui.Sizing.fixed(216), .height = ui.Sizing.fill(), .inset = .{ .left = .{ .px = 0 }, .top = .{ .px = 0 } }, .cursor = .pointer }, .on_click = ui.on.call(cx, struct {
            fn absorb(_: *ui.Cx) void {}
        }.absorb) }, .{}),
    }));
}
fn notificationRig() !Rig {
    const r = try Rig.init(notificationChrome);
    r.cx.root.?.style.width = ui.Sizing.fixed(1100);
    r.cx.root.?.style.height = ui.Sizing.fixed(1000);
    r.cx.setViewport(1100, 1000);
    r.cx.root.?.markLayoutDirty();
    r.cx.layout();
    r.tick(16);
    return r;
}
fn physicalClick(r: Rig, id: []const u8) void {
    const rect = r.get(id).globalRect();
    r.cx.handleClick(rect.x + rect.w / 2, rect.y + rect.h / 2);
    r.tick(16);
}
fn expectFiniteRect(rect: anytype) !void {
    try std.testing.expect(std.math.isFinite(rect.x) and std.math.isFinite(rect.y) and std.math.isFinite(rect.w) and std.math.isFinite(rect.h));
}

test "LC3 story Notification burst clicks create four finite stacked cards" {
    const r = try notificationRig();
    defer r.deinit();
    const gutter = r.get("lc3.gutter").globalRect();
    const button_rect = r.get("story.notify.btn.burst").globalRect();
    std.debug.print("notification gutter={any} burst={any}\n", .{ gutter, button_rect });
    physicalClick(r, "story.notify.btn.burst");
    r.tick(700);
    const newest = find(r.cx.root.?, "story.notify.stack.3");
    try std.testing.expect(newest != null);
    const older = r.get("story.notify.stack.2").globalRect();
    const front = newest.?.globalRect();
    std.debug.print("notification stack front={any} older={any}\n", .{ front, older });
    try expectFiniteRect(front);
    try expectFiniteRect(older);
    try std.testing.expectApproxEqAbs(@as(f32, 216), gutter.w, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 1000), gutter.h, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 9), front.y + front.h - older.y - older.h, 0.6);
}

test "LC3 story Notification hint click creates 36 high capsule" {
    const r = try notificationRig();
    defer r.deinit();
    physicalClick(r, "story.notify.hint.btn.success");
    r.tick(600);
    const hint = find(r.cx.root.?, "story.notify.hint.success");
    try std.testing.expect(hint != null);
    const rect = hint.?.globalRect();
    std.debug.print("notification hint={any}\n", .{rect});
    try expectFiniteRect(rect);
    try std.testing.expectApproxEqAbs(@as(f32, 36), rect.h, 0.5);
    try std.testing.expect(rect.w > 60 and rect.w < 200);
}

fn countTestId(n: *ui.Node, id: []const u8) usize {
    var count: usize = 0;
    if (n.meta.ownership.meta.test_id) |s| if (std.mem.eql(u8, s, id)) {
        count += 1;
    };
    for (n.children.items) |child| count += countTestId(child, id);
    return count;
}
fn containsText(n: *ui.Node, text: []const u8) bool {
    if (n.getText()) |t| if (std.mem.indexOf(u8, t.content, text) != null) return true;
    for (n.children.items) |child| if (containsText(child, text)) return true;
    return false;
}

test "LC3 story Notification reply retains tagged shell after physical input" {
    const r = try notificationRig();
    defer r.deinit();
    // The failing e2e had an older Person card because the clear button was
    // hidden behind the sidebar. Repeating the Person action then produced
    // two identical test ids; the error label said 'rebuilt' but no shell was
    // actually replaced. Exercise that clear/recreate transition explicitly.
    physicalClick(r, "story.notify.btn.person");
    r.tick(700);
    physicalClick(r, "story.notify.btn.clear");
    r.tick(600);
    physicalClick(r, "story.notify.btn.person");
    r.tick(700);
    const before = find(r.cx.root.?, "story.notify.person");
    try std.testing.expect(before != null);
    const rect = before.?.globalRect();
    std.debug.print("notification person={any}\n", .{rect});
    try expectFiniteRect(rect);
    // The card's stable shell must survive replacement of the reply content.
    // Dispatch the same Enter action as the interactive story after focusing
    // the reply field; no direct call into a private Notifier implementation.
    r.cx.handleClick(rect.x + 120, rect.y + rect.h - 25);
    r.cx.handleTextInput("好的，马上看");
    r.cx.handleKeyDown(.@"return", .{});
    r.tick(16);
    r.tick(500);
    try std.testing.expect(find(r.cx.root.?, "story.notify.person") == before);
    try std.testing.expectEqual(@as(usize, 1), countTestId(r.cx.root.?, "story.notify.person"));
    try std.testing.expect(containsText(before.?, "好的，马上看"));
}

test "LC3 story GlassSplit capture keeps the locked pose" {
    const r = try Rig.init(stories.buildGlassSplit);
    defer r.deinit();
    r.cx.setFramePresentationSample(.{ .tick = 1, .target_time_ms = 50000, .period_ms = 16 });
    try std.testing.expect(r.cx.frame_presentation_sample != null);
    try r.cx.setTestFrameStep(16);
    try std.testing.expect(r.cx.frame_presentation_sample == null);
    click(r.get("story.glasssplit.slowbtn"));
    click(r.get("story.glasssplit.splitbtn"));
    r.tick(0);
    r.tick(1400);
    const b = r.get("story.glasssplit.bar1");
    const before = b.globalRect();
    // A screenshot redraw may arrive at a later real display target while the
    // manual clock budget is exhausted. Its geometry must remain frozen.
    r.cx.setFramePresentationSample(.{ .tick = 100000, .target_time_ms = 100000, .period_ms = 16 });
    hooks(r.cx.root.?);
    r.cx.layout();
    const after = b.globalRect();
    try std.testing.expectApproxEqAbs(before.x, after.x, 0.01);
    try std.testing.expectApproxEqAbs(before.w, after.w, 0.01);
    try std.testing.expectApproxEqAbs(before.h, after.h, 0.01);
}

test "LC3 story gate requires every reported regression" {
    const required = [_][]const u8{
        "LC3 story closed popup border floors stay outside visible paint",
        "LC3 story GlassGroup preserves sampling geometry",
        "LC3 story GlassMaterialize keeps geometry through midpoint",
        "LC3 story GlassSplit samples bridge and absorbs to cap",
        "LC3 story GlassPopover preserves native body geometry",
        "LC3 story Notification burst clicks create four finite stacked cards",
        "LC3 story Notification hint click creates 36 high capsule",
        "LC3 story Notification reply retains tagged shell after physical input",
        "LC3 story GlassSplit capture keeps the locked pose",
        "LC3 story CornerClip scrolls GlassRadii into the viewport",
        "LC3 story embedded Textarea fits a resized compound control",
        "LC3 story Scrolling keeps fixed row heights and overflow",
        "LC3 story all registered stories have finite layout",
        "LC3 story Morph group fills its start-aligned backdrop",
        "LC3 story centered Steps numbers retain main painted origin across updates",
        "LC3 story centered component text rectangles and paint inventory",
        "LC3 story centered Badge and Calendar labels preserve main paint offsets",
    };
    for (required) |name| {
        var found = false;
        for (@import("builtin").test_functions) |function| {
            if (std.mem.endsWith(u8, function.name, name)) found = true;
        }
        try std.testing.expect(found);
    }
}

fn cornerClipChrome(scope: *ui.Scope, cx: *ui.Cx) !*ui.Node {
    cx.setTheme(&ui.theme.modes.light);
    cx.text.measure_fn = cornerMeasure;
    const v = ui.view;
    // Include the outer viewport root, not only content_layer: its automatic
    // minimum used to enlarge the ScrollArea and remove its scroll range.
    return v.render(scope, cx, v.col(.{ .style = story_styles.root, .test_id = "lc3.viewport" }, v.row(.{ .style = story_styles.content_layer }, .{
        v.box(.{ .style = story_styles.contentGutter, .test_id = "lc3.gutter" }, .{}),
        v.col(.{ .style = story_styles.workspace, .test_id = "lc3.workspace" }, v.with(ui.widgets.ScrollArea(.{
            .direction = .vertical,
            .padding = .{ .top = 84, .right = 32, .bottom = 32, .left = 32 },
        }), v.col(.{ .style = story_styles.contentColumn, .test_id = "content" }, .{
            v.text(.{ .style = story_styles.storyNote }, "Overflow clip with four corner radii: rounded corners cut the square red fills, square corners keep them, on every clip path (shader mask, opacity fold, glass clip surface, nested clip layer, half-turned and mirrored owners)"),
            v.col(.{ .style = story_styles.panelHug, .test_id = "story.cornerclip" }, v.component(stories.buildCornerClip, {})),
        }))),
    })));
}
// The macOS story gate already links the CoreText bridge. Inject its measurement
// without a native window: the test fallback's equal-width estimate wraps the
// note into four lines instead of Storybook's three, shifting every sample.
extern fn coretext_measure_text_width_weighted(text: [*]const u8, len: c_int, font_size: f32, font_weight: c_int) f32;
fn cornerMeasure(text: [*]const u8, len: usize, font_size: f32, font_weight: u16, _: bool) f32 {
    return coretext_measure_text_width_weighted(text, @intCast(len), font_size, @intCast(font_weight));
}

fn dirtyLayoutTree(n: *ui.Node) void {
    n.markLayoutDirty();
    for (n.children.items) |child| dirtyLayoutTree(child);
}

test "LC3 story CornerClip scrolls GlassRadii into the viewport" {
    const r = try Rig.initSized(cornerClipChrome, 1100, 1000);
    defer r.deinit();
    r.cx.setViewport(1100, 1000);
    _ = r.cx.render();
    // Exercise reflow after the note's wrapped height is available. Without the
    // root constraint its initial 1079.4 height grows to 1113, eliminating scroll.
    for (0..2) |_| {
        dirtyLayoutTree(r.cx.root.?);
        r.cx.layout();
        _ = r.cx.render();
    }
    try std.testing.expectApproxEqAbs(@as(f32, 1000), r.get("lc3.viewport").globalRect().h, 0.01);
    const area = r.get("lc3.workspace").children.items[0];
    const ec: *ui.widgets.scroll_area.ScrollEventCtx = @ptrCast(@alignCast(area.behavior.events.event_context.?));
    try std.testing.expectApproxEqAbs(@as(f32, 216), r.get("lc3.gutter").globalRect().w, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 884), r.get("lc3.workspace").globalRect().w, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 820), r.get("content").globalRect().w, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 997), ec.state.content_height, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 884), ec.state.viewport_height, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 113), ec.state.maxScrollY(), 0.01);
    const neg = r.get("story.cornerclip.glassneg").globalRect();
    const pill = r.get("story.cornerclip.glasspillhuge").globalRect();
    try std.testing.expectApproxEqAbs(@as(f32, 923.6), neg.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 1031), pill.y, 0.01);

    // Same point, wheel deltas and iteration limit as GlassRadii. Use Cx hit
    // testing and dispatch; calling ScrollArea's handler directly hides routing
    // failures. Geometry at scroll zero must not be compared to a scrolled main.
    var i: usize = 0;
    while (i < 20 and r.get("story.cornerclip.glasspillhuge").globalRect().y + pill.h > 900) : (i += 1) {
        const bottom = r.get("story.cornerclip.glasspillhuge").globalRect().y + pill.h;
        r.cx.handleScroll(.{ .x = 700, .y = 600, .dx = 0, .dy = -@min(120, bottom - 860) });
        r.tick(120);
        _ = r.cx.render();
    }
    try std.testing.expectApproxEqAbs(@as(f32, 113), ec.state.scroll_y, 0.01);
    const scrolled_neg = r.get("story.cornerclip.glassneg").globalRect();
    const scrolled_pill = r.get("story.cornerclip.glasspillhuge").globalRect();
    try std.testing.expectApproxEqAbs(@as(f32, 810.6), scrolled_neg.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 918), scrolled_pill.y, 0.01);
    try std.testing.expectApproxEqAbs(neg.x, scrolled_neg.x, 0.01);
    try std.testing.expectApproxEqAbs(neg.w, scrolled_neg.w, 0.01);
    try std.testing.expectApproxEqAbs(neg.h, scrolled_neg.h, 0.01);
    try std.testing.expect(scrolled_pill.y + scrolled_pill.h <= 1000 - 32);

    // The public programmatic path returns to exactly the unscrolled geometry.
    ui.widgets.scroll_area.setScrollY(ec.state, ec.content.?, 0);
    _ = r.cx.render();
    try std.testing.expectApproxEqAbs(neg.y, r.get("story.cornerclip.glassneg").globalRect().y, 0.01);
}

fn embeddedTextarea(scope: *ui.Scope, cx: *ui.Cx) !*ui.Node {
    return ui.view.render(scope, cx, ui.view.row(.{ .style = .{ .width = 300, .height = 72 }, .test_id = "lc3.compound" }, .{
        ui.view.box(.{ .style = .{ .width = 40, .height = 24, .flex_shrink = 0 }, .test_id = "lc3.adornment" }, .{}),
        ui.view.attrs(.{ .test_id = "lc3.textarea", .style = .{ .height = 72 } }, ui.widgets.Textarea(.{ .embedded = true, .value = "a very long unbroken line that must wrap inside the compound field", .rows = 1 })),
    }));
}

test "LC3 story embedded Textarea fits a resized compound control" {
    const r = try Rig.init(embeddedTextarea);
    defer r.deinit();
    const compound = r.get("lc3.compound");
    const wrapper = r.get("lc3.textarea");
    const field = wrapper.children.items[0];
    for ([_]f32{ 300, 120, 300 }) |width| {
        try compound.setStyleInlineFallible(r.cx.allocator, .{ .width = .{ .px = width } });
        r.cx.layout();
        _ = r.cx.render();
        try std.testing.expectApproxEqAbs(width - 40, wrapper.globalRect().w, 0.01);
        try std.testing.expectApproxEqAbs(@as(f32, 72), wrapper.globalRect().h, 0.01);
        try std.testing.expectApproxEqAbs(wrapper.globalRect().w, field.globalRect().w, 0.01);
        try std.testing.expectApproxEqAbs(wrapper.globalRect().h, field.globalRect().h, 0.01);
        try std.testing.expectApproxEqAbs(@as(f32, 40), r.get("lc3.adornment").globalRect().w, 0.01);
    }
}

test "LC3 story Scrolling keeps fixed row heights and overflow" {
    const r = try Rig.init(@import("scrolling_story.zig").build);
    defer r.deinit();
    _ = r.cx.render();
    const content = r.get("story.scrolling.vertical.content");
    try std.testing.expectApproxEqAbs(@as(f32, 1200), content.globalRect().h, 0.01);
    for (content.children.items, 0..) |row, i| {
        try std.testing.expectApproxEqAbs(@as(f32, 30), row.globalRect().h, 0.01);
        try std.testing.expectApproxEqAbs(content.globalRect().y + @as(f32, @floatFromInt(i)) * 30, row.globalRect().y, 0.01);
    }
}

// All registered stories mount their public components. Emit every local rectangle,
// with a structural path so repeated/missing test ids cannot hide a difference.
fn inventoryRect(n: *ui.Node, story: []const u8, path: []const u8, width: u32) !void {
    const r = n.rectFromWorldOrFallback();
    try expectFiniteRect(r);
    if (@import("zenit_environment").has("ZENIT_LC3_INVENTORY")) std.debug.print("LC3B_RECT\t{s}\t{d}\t{s}\t{s}\t{d:.4}\t{d:.4}\t{d:.4}\t{d:.4}\n", .{ story, width, path, n.meta.ownership.meta.test_id orelse "", r.x, r.y, r.w, r.h });
    if (@import("zenit_environment").has("ZENIT_LC3_INVENTORY")) std.debug.print("LC3B_STYLE\t{s}\t{d}\t{s}\t{s}\t{any}\t{any}\t{s}\t{s}\t{any}\t{}\n", .{ story, width, path, @tagName(n.tag), n.style.width, n.style.height, @tagName(n.style.direction), @tagName(n.style.align_items), n.style.align_self(), n.style.no_cross_stretch() });
    if (@import("zenit_environment").has("ZENIT_LC3_INVENTORY")) {
        var hidden = false;
        var min_opacity: f32 = 1;
        var clipped_empty = false;
        var ancestor: ?*ui.Node = n;
        while (ancestor) |a| : (ancestor = a.parent) {
            hidden = hidden or a.isPaintSkipped();
            min_opacity = @min(min_opacity, a.getOpacity());
            const ar = a.rectFromWorldOrFallback();
            clipped_empty = clipped_empty or (a.style.overflow_hidden and (ar.w <= 0 or ar.h <= 0));
        }
        std.debug.print("LC3C_BOX\t{s}\t{d}\t{s}\t{}\t{any}\t{any}\t{}\t{d:.6}\t{}\n", .{ story, width, path, hidden, n.style.padding, n.style.border.resolvedWidths(), n.style.border.overlay, min_opacity, clipped_empty });
    }
    for (n.children.items, 0..) |child, i| {
        var buf: [2048]u8 = undefined;
        const child_path = try std.fmt.bufPrint(&buf, "{s}/{d}", .{ path, i });
        try inventoryRect(child, story, child_path, width);
    }
}
const inventory_builders = .{
    "buildControls",
    "buildButton",
    "buildCheckbox",
    "buildSwitch",
    "buildRadio",
    "buildSlider",
    "buildRate",
    "buildNumberStepper",
    "buildGroup",
    "buildInput",
    "buildTextarea",
    "buildEditableText",
    "buildSelect",
    "buildComboBox",
    "buildTagsInput",
    "buildFileUpload",
    "buildDateTimePicker",
    "buildDatePicker",
    "buildDateRangePicker",
    "buildForm",
    "buildFormComposition",
    "buildBadge",
    "buildTag",
    "buildChip",
    "buildCard",
    "buildAlert",
    "buildProgress",
    "buildSpinner",
    "buildSkeleton",
    "buildTimeline",
    "buildTable",
    "buildDataTable",
    "buildTree",
    "buildCalendar",
    "buildMarkdown",
    "buildIconGallery",
    "buildTabs",
    "buildAccordion",
    "buildMenu",
    "buildBreadcrumb",
    "buildSteps",
    "buildNotification",
    "buildTooltip",
    "buildPopover",
    "buildModal",
    "buildSheet",
    "buildZIndex",
    "buildDivider",
    "buildStack",
    "buildLayoutBoxModel",
    "buildVirtualList",
    "buildVirtualListDynamic",
    "buildScrolling",
    "buildScrollArea",
    "buildGrid",
    "buildGlassBox",
    "buildGlassLab",
    "buildGlassControls",
    "buildGlassControlsIos",
    "buildGlassToolbar",
    "buildGlassIosBars",
    "buildGlassPopover",
    "buildGlassChrome",
    "buildGlassMotion",
    "buildGlassSplit",
    "buildGlassUnion",
    "buildGlassAdapt",
    "buildGlassConcentric",
    "buildGlassExtension",
    "buildCanvasEvents",
    "buildDrag",
    "buildMultiClick",
    "buildAnimCtl",
    "buildVectorPath",
    "buildBlend",
    "buildEmoji",
    "buildRtl",
    "buildWordNav",
    "buildViewDsl",
    "buildComponentWall",
    "buildGlassGroup",
    "buildGlassMerge",
    "buildGlassTintMerge",
    "buildGlassIslands",
    "buildGlassAppKit",
    "buildGlassIdiom",
    "buildGlassIosLens",
    "buildBlendLab",
    "buildGlassEdge",
    "buildPopoverRegressions",
    "buildCjkWeights",
    "buildPopoverText",
    "buildCornerClip",
    "buildPaintReplay",
    "buildHeavyText",
    "buildTextAnimJitter",
    "buildCleanup",
    "buildInteractionLifecycle",
    "buildTeardownStress",
    "buildSecuritySvg",
    "buildSecurityOpacity",
    "buildSecurityText",
};

fn inventoryCovers(registry: []const u8) bool {
    var rest = registry;
    var count: usize = 0;
    var seen: [inventory_builders.len]bool = @splat(false);
    const marker = ".builder = \"";
    while (std.mem.indexOf(u8, rest, marker)) |at| {
        rest = rest[at + marker.len ..];
        const end = std.mem.indexOfScalar(u8, rest, '"') orelse return false;
        var matches: usize = 0;
        inline for (inventory_builders, 0..) |builder, index| if (std.mem.eql(u8, builder, rest[0..end])) {
            if (seen[index]) return false;
            seen[index] = true;
            matches += 1;
        };
        if (matches != 1) return false;
        count += 1;
        rest = rest[end + 1 ..];
    }
    return count == inventory_builders.len;
}

test "LC3 story all registered stories have finite layout" {
    // The registry is deliberately lazy (string builder names). Verify that
    // additions/removals/unknown entries cannot silently escape this inventory.
    try std.testing.expect(inventoryCovers(@embedFile("main.zig")));
    try std.testing.expect(!inventoryCovers(""));
    try std.testing.expect(!inventoryCovers(".builder = \"missing\""));
    inline for (inventory_builders) |builder| {
        for ([_]u32{ 760, 1100 }) |width| {
            const r = try Rig.initSized(@field(stories, builder), @floatFromInt(width), 1000);
            defer r.deinit();
            r.cx.setViewport(@floatFromInt(width), 1000);
            // Storybook uses panelHug (start), except the wide GlassIslands story.
            r.cx.root.?.style.align_items = if (comptime std.mem.eql(u8, builder, "buildGlassIslands")) .stretch else .start;
            // Settle wrap/fit backfill using the same headless hook path as above.
            for (0..2) |_| {
                dirtyLayoutTree(r.cx.root.?);
                r.cx.layout();
            }
            try inventoryRect(r.cx.root.?, builder, "0", width);
        }
    }
}

test "LC3 story Morph group fills its start-aligned backdrop" {
    const r = try Rig.init(stories.buildGlassMotion);
    defer r.deinit();
    const morph = r.get("story.glassmotion.morph");
    const content = morph.parent.?;
    const group = content.parent.?;
    const backdrop = group.parent.?;
    try std.testing.expect(group.globalRect().w > 400);
    try std.testing.expectApproxEqAbs(backdrop.globalRect().w, group.globalRect().w, 0.01);
    try std.testing.expectApproxEqAbs(group.globalRect().w, content.globalRect().w, 0.01);
}

// Public helpers not mounted by a registered story's content (the real
// Storybook window header lives outside that content) need their own inventory.
fn inventorySupplement(scope: *ui.Scope, cx: *ui.Cx) !*ui.Node {
    const W = ui.widgets;
    (try cx.windowChrome()).set(.{
        .effective_mode = .custom,
        .controls_owner = .framework,
        .appearance = .windows,
        .capabilities = .{ .custom = true, .minimize = true, .maximize = true, .fullscreen = true },
    });
    const options = [_]ui.select_headless.Option(i32){
        .{ .value = 1, .label = "First" },
        .{ .value = 2, .label = "Second" },
    };
    const selected = try ui.select_headless.SelectHeadless(i32, .{ .options = &options, .value = @as(?i32, 1) }).mount(scope, cx);
    selected.trigger.meta.ownership.meta.test_id = "lc3b.supplement.select-trigger";
    const region = try ui.view.render(scope, cx, W.WindowHeader(.{ .style = ui.BoxStyle{ .width = .{ .grow = .{} }, .height = .{ .px = 52 }, .align_items = .center } }, .{
        W.DragRegion(.{}, .{ui.view.text(.{}, "Header")}),
        W.ClientRegion(.{}, .{W.WindowControls(.{ .appearance = .windows, .native_regions = false })}),
    }));
    const source = try ui.box(cx, .{ .width = .{ .px = 40 }, .height = .{ .px = 24 }, .background = ui.Color.rgb(220, 40, 40) }, .{});
    source.meta.ownership.meta.test_id = "lc3b.supplement.snapshot-source";
    return ui.box(cx, .{ .width = .{ .grow = .{} }, .gap = 8 }, .{ region, selected.wrapper, source });
}

test "LC3 story component helpers outside registered story content have finite layout" {
    for ([_]u32{ 760, 1100 }) |width| {
        const r = try Rig.initSized(inventorySupplement, @floatFromInt(width), 1000);
        defer r.deinit();
        r.cx.setViewport(@floatFromInt(width), 1000);
        r.cx.layout();
        const trigger = r.get("lc3b.supplement.select-trigger");
        try std.testing.expectEqual(@as(f32, 240), trigger.rectFromWorldOrFallback().w);
        try std.testing.expectEqual(@as(f32, 240), trigger.children.items[0].rectFromWorldOrFallback().w);
        _ = r.cx.render();
        const Snapshot = @typeInfo(@FieldType(ui.widgets.SnapshotLayerProps, "snapshot")).pointer.child;
        const snapshot = (try Snapshot.capture(r.cx, r.get("lc3b.supplement.snapshot-source"))) orelse return error.ExpectedSnapshot;
        _ = try ui.widgets.SnapshotLayer(.{ .snapshot = snapshot, .anchor = .{ .x = 96, .y = 80 } }).mount(r.scope, r.cx);
        hooks(r.cx.root.?);
        r.cx.layout();
        try inventoryRect(r.cx.root.?, "component-helpers", "0", width);
    }
}

// Rect-only inventories cannot detect a fixed text block losing its implicit
// paint offset. Check the emitted first-line baseline as well as the circle.
fn centeredStepLabels(r: Rig, n: *ui.Node, count: *usize) !void {
    if (n.getText()) |text| {
        if (std.mem.eql(u8, text.content, "2") or std.mem.eql(u8, text.content, "3")) {
            var circle: ?*ui.Node = n;
            while (circle) |c| : (circle = c.parent) {
                const cr = c.globalRect();
                if (@abs(cr.w - 24) > 0.01 or @abs(cr.h - 24) > 0.01) continue;
                const nr = n.globalRect();
                const line_h = text.font_size * text.line_height;
                try std.testing.expectApproxEqAbs(cr.x + cr.w / 2, nr.x + nr.w / 2, 0.01);
                var painted = false;
                for (r.cx.display_list.items.items) |item| switch (item) {
                    .text_run => |run| if (run.header.node_id == n.id) {
                        painted = true;
                        // No host font resolver in this rig: baseline is 0.75
                        // of the line height, matching the main paint contract.
                        try std.testing.expectApproxEqAbs(cr.y + (cr.h - line_h) / 2 + line_h * 0.75, nr.y + run.y, 0.01);
                    },
                    else => {},
                };
                try std.testing.expect(painted);
                count.* += 1;
                break;
            }
        }
    }
    for (n.children.items) |child| try centeredStepLabels(r, child, count);
}

test "LC3 story centered Steps numbers retain main painted origin across updates" {
    const r = try Rig.init(stories.buildSteps);
    defer r.deinit();
    r.cx.setViewport(760, 900);
    for (0..3) |phase| {
        _ = r.cx.render();
        var count: usize = 0;
        try centeredStepLabels(r, r.cx.root.?, &count);
        try std.testing.expect(count >= 2);
        if (phase == 0) click(r.get("story.steps.back"));
        if (phase == 1) click(r.get("story.steps.next"));
        r.tick(16);
    }
}

fn labelInventory(r: Rig, n: *ui.Node, story: []const u8, width: u32, ordinal: *usize) void {
    if (n.getText()) |text| {
        const rect = n.globalRect();
        var baseline: f32 = std.math.nan(f32);
        for (r.cx.display_list.items.items) |item| switch (item) {
            .text_run => |run| if (run.header.node_id == n.id) {
                baseline = rect.y + run.y;
            },
            else => {},
        };
        if (@import("zenit_environment").has("ZENIT_LC3_INVENTORY")) std.debug.print("LC3B_LABEL\t{s}\t{d}\t{d}\t{x}\t{d:.4}\t{d:.4}\t{d:.4}\t{d:.4}\t{d:.4}\n", .{ story, width, ordinal.*, std.hash.Wyhash.hash(0, text.content), rect.x, rect.y, rect.w, rect.h, baseline });
        ordinal.* += 1;
    }
    for (n.children.items) |child| labelInventory(r, child, story, width, ordinal);
}

test "LC3 story centered component text rectangles and paint inventory" {
    inline for (.{ "buildSteps", "buildBadge", "buildTag", "buildChip", "buildCheckbox", "buildRadio", "buildCalendar", "buildNotification" }) |builder| {
        for ([_]u32{ 760, 1100 }) |width| {
            const r = try Rig.initSized(@field(stories, builder), @floatFromInt(width), 1000);
            defer r.deinit();
            r.cx.setViewport(@floatFromInt(width), 1000);
            r.cx.root.?.style.align_items = .start;
            for (0..2) |_| {
                dirtyLayoutTree(r.cx.root.?);
                r.cx.layout();
            }
            _ = r.cx.render();
            if (comptime std.mem.eql(u8, builder, "buildNotification")) {
                physicalClick(r, "story.notify.btn.person");
                r.tick(700);
                _ = r.cx.render();
                try std.testing.expect(find(r.cx.root.?, "story.notify.person") != null);
            }
            var count: usize = 0;
            labelInventory(r, r.cx.root.?, builder, width, &count);
            try std.testing.expect(count > 0);
        }
    }
}

fn expectCenteredPaint(r: Rig, n: *ui.Node, outer: *ui.Node) !void {
    const text = n.getText().?;
    const nr = n.globalRect();
    const cr = outer.globalRect();
    const line_h = text.font_size * text.line_height;
    var painted = false;
    for (r.cx.display_list.items.items) |item| switch (item) {
        .text_run => |run| if (run.header.node_id == n.id) {
            painted = true;
            try std.testing.expectApproxEqAbs(cr.y + (cr.h - line_h) / 2 + line_h * 0.75, nr.y + run.y, 0.01);
        },
        else => {},
    };
    try std.testing.expect(painted);
}
fn checkBadgePaint(r: Rig, n: *ui.Node, count: *usize) !void {
    if (n.meta.ownership.meta.component_name) |name| if (std.mem.eql(u8, name, "Badge")) {
        if (n.getText()) |text| if (text.content.len > 0) {
            try expectCenteredPaint(r, n, n);
            count.* += 1;
        };
    };
    for (n.children.items) |child| try checkBadgePaint(r, child, count);
}
fn checkWeekdayPaint(r: Rig, n: *ui.Node, count: *usize) !void {
    if (n.getText() != null) {
        var cell: ?*ui.Node = n;
        while (cell) |c| : (cell = c.parent) {
            const rect = c.globalRect();
            if (@abs(rect.w - 36) > 0.01 or @abs(rect.h - 28) > 0.01) continue;
            try expectCenteredPaint(r, n, c);
            try std.testing.expectApproxEqAbs(rect.x, n.globalRect().x, 0.01);
            count.* += 1;
            break;
        }
    }
    for (n.children.items) |child| try checkWeekdayPaint(r, child, count);
}
test "LC3 story centered Badge and Calendar labels preserve main paint offsets" {
    const badge = try Rig.init(stories.buildBadge);
    defer badge.deinit();
    badge.cx.setViewport(760, 900);
    for (0..3) |phase| {
        _ = badge.cx.render();
        var count: usize = 0;
        try checkBadgePaint(badge, badge.cx.root.?, &count);
        try std.testing.expect(count >= 8);
        if (phase == 0) click(badge.get("story.badge.clear"));
        if (phase == 1) click(badge.get("story.badge.add"));
        badge.tick(16);
    }
    const calendar = try Rig.init(stories.buildCalendar);
    defer calendar.deinit();
    calendar.cx.setViewport(760, 900);
    _ = calendar.cx.render();
    var count: usize = 0;
    try checkWeekdayPaint(calendar, calendar.cx.root.?, &count);
    try std.testing.expectEqual(@as(usize, 7), count);
}

test "LC3 story closed popup border floors stay outside visible paint" {
    inline for (.{ stories.buildSelect, stories.buildComboBox, stories.buildSheet }) |builder| {
        const r = try Rig.init(builder);
        defer r.deinit();
        _ = r.cx.render();
        const portal = r.cx.popover_portal_root orelse return error.ExpectedOverlayPortal;
        for (portal.children.items) |child| {
            // Specimens mounted open (MultiSelect open, ComboBox open) show at once; only closed
            // (suspended) popups must stay out of visible paint.
            const layer = r.cx.overlay_stack.findLayerForNode(child) orelse return error.ExpectedOverlayLayer;
            if (!layer.suspended) continue;
            const rect = child.rectFromWorldOrFallback();
            std.debug.print("LC3C_CLOSED name={s} rect={any} opacity={d:.6} clip={} skip={}\n", .{ child.meta.ownership.meta.component_name orelse "", rect, child.getOpacity(), child.style.overflow_hidden, child.isPaintSkipped() });
            // Prewarming may deliberately keep work alive at exactly zero
            // opacity. That is invisible even when isPaintSkipped is false.
            try std.testing.expect(child.getOpacity() == 0 or child.isPaintSkipped() or (child.style.overflow_hidden and (rect.w <= 0 or rect.h <= 0)));
        }
    }
}

/// Steps Component
///
/// Step indicator. View in steps.yix, style in styles.yss.
///
/// Features:
/// - horizontal (each step an even column, connector passes through circle centers,
///   completed section ends at the current circle) / vertical (each step one row)
/// - items / current can come from signals: reconcile by row key (content + borrowed
///   string address); current only changes state appearance
/// - each step reports to AT: selected (current) / checked (completed) / disabled (not reached)
const std = @import("std");
const core = @import("../../core.zig");
const Cx = core.Cx;
const Node = core.Node;
const box = core.box;
const reactive = @import("../../reactive.zig");
const Scope = reactive.Scope;
const styles = @import("_styles.yss.zig");
const svg_assets = @import("../../svg_assets.zig");

/// step item
pub const StepItem = struct {
    title: []const u8,
    description: ?[]const u8 = null,
};

/// layout direction
pub const StepsDirection = enum { horizontal, vertical };

/// create Steps: `W.Steps(.{ .items = &items, .current = step })`
pub const Steps = @import("_steps.yix.zig").Steps;
pub const StepsProps = @import("_steps.yix.zig").StepsProps;

// ========== tests ==========

const test_steps = [_]StepItem{
    .{ .title = "Setup", .description = "Initialize project" },
    .{ .title = "Develop", .description = "Write code" },
    .{ .title = "Test" },
    .{ .title = "Deploy" },
};

test "Steps: basic horizontal" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 600 }, .height = .{ .px = 200 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const steps = try Steps(.{
        .items = &test_steps,
        .current = 1,
    }).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, steps);
    try std.testing.expectEqual(@as(usize, 6), steps.children.items.len);
}

fn collectStepDigits(n: *Node, out: *std.ArrayList(u8)) !void {
    if (n.getText()) |txt| {
        if (txt.content.len == 1 and std.ascii.isDigit(txt.content[0])) try out.append(std.testing.allocator, txt.content[0]);
    }
    for (n.children.items) |c| try collectStepDigits(c, out);
}

test "Steps: 圆圈序号在 mount 返回后仍正确（不引用循环内栈缓冲）" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 600 }, .height = .{ .px = 400 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    inline for (.{ StepsDirection.horizontal, StepsDirection.vertical }) |dir| {
        const steps = try Steps(.{ .items = &test_steps, .current = 0, .direction = dir }).mount(scope, ctx);
        try root.appendChild(std.testing.allocator, steps);
        var digits: std.ArrayList(u8) = .empty;
        defer digits.deinit(std.testing.allocator);
        try collectStepDigits(steps, &digits);
        try std.testing.expectEqualStrings("1234", digits.items);
    }
}

/// Compare rendered geometry, including the marker offset for tall titles.
fn absRect(n: *Node) core.ComputedRect {
    return n.globalRect();
}
/// circle in one step (fixed circle_size width; skip control-flow anchor etc. zero-size nodes)
fn circleIn(step: *Node) *Node {
    for (step.children.items) |c| switch (c.style.width) {
        .px => |w| if (w == styles.circle_size) return c,
        else => {},
    };
    @panic("no step circle");
}

fn centerX(n: *Node) f32 {
    const r = absRect(n);
    return r.x + r.w / 2;
}
fn centerY(n: *Node) f32 {
    const r = absRect(n);
    return r.y + r.h / 2;
}

test "Steps: 水平连接线从首圆心贯穿到末圆心，进度段止于当前圆心" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 600 }, .height = .{ .px = 200 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const steps = try Steps(.{ .items = &test_steps, .current = 2 }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, steps);
    ctx.layout();

    const kids = steps.children.items;
    const track = kids[0];
    const progress = kids[1];
    const first_circle = kids[2].children.items[0];
    const current_circle = kids[2 + 2].children.items[0];
    const last_circle = kids[kids.len - 1].children.items[0];

    const tr = absRect(track);
    try std.testing.expect(tr.w > 0);
    try std.testing.expectApproxEqAbs(centerX(first_circle), tr.x, 0.5);
    try std.testing.expectApproxEqAbs(centerX(last_circle), tr.x + tr.w, 0.5);
    try std.testing.expectApproxEqAbs(centerY(first_circle), centerY(track), 0.5);

    const pr = absRect(progress);
    try std.testing.expectApproxEqAbs(centerX(first_circle), pr.x, 0.5);
    try std.testing.expectApproxEqAbs(centerX(current_circle), pr.x + pr.w, 0.5);
    try std.testing.expectApproxEqAbs(centerY(first_circle), centerY(progress), 0.5);
}

fn expectVerticalConnectorsJoined(big_fonts: bool) !void {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 300 }, .height = .{ .px = 400 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    var big = ctx.tokens.*;
    if (big_fonts) {
        // text column (title+description) taller than 'circle + shortest connector', connector must
        // stretch with row
        // The title alone must exceed the 24px marker (20 * 1.4 = 28).
        big.tokens.font_size.sm = 20;
        big.tokens.font_size.xs = 20;
        ctx.tokens = &big;
    }
    // last step with description (storybook same): text column taller than circle, was original
    // align=center pushing last circle down, breaking connector to previous segment
    const items = [_]StepItem{
        .{ .title = "Setup", .description = "Initialize project" },
        .{ .title = "Develop", .description = "Write code" },
        .{ .title = "Test" },
        .{ .title = "Deploy", .description = "Ship it" },
    };
    const steps = try Steps(.{ .items = &items, .current = 3, .direction = .vertical }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, steps);
    ctx.layout();
    const rows = steps.children.items;
    if (big_fonts) {
        // precondition: row truly taller than 'circle + shortest connector', else can't measure
        // stretch
        try std.testing.expect(rows[0].children.items[1].children.items[0].rectFromWorldOrFallback().h > styles.circle_size);
        try std.testing.expect(rows[0].rectFromWorldOrFallback().h > styles.circle_size + styles.v_connector_min + 1);
    }

    for (rows, 0..) |row, i| {
        const indicator = row.children.items[0];
        const circle = indicator.children.items[0];
        const cr = absRect(circle);
        if (i + 1 < rows.len) {
            const conn = indicator.children.items[1];
            const kr = absRect(conn);
            const next_circle = rows[i + 1].children.items[0].children.items[0];
            try std.testing.expectApproxEqAbs(centerX(circle), centerX(conn), 0.5);
            try std.testing.expectApproxEqAbs(cr.y + cr.h, kr.y, 0.5);
            try std.testing.expectApproxEqAbs(absRect(next_circle).y, kr.y + kr.h, 0.5);
            try std.testing.expect(kr.h >= styles.v_connector_min - 0.5);
        }
        // title first line center ~= circle center (row align=start then align via padding)
        const title = row.children.items[1].children.items[0];
        try std.testing.expectApproxEqAbs(centerY(circle), centerY(title), 1.0);
    }
}

test "Steps: 垂直连接线首尾贴住相邻圆圈（含最后一段），标题与圆圈竖向居中" {
    try expectVerticalConnectorsJoined(false);
}

test "Steps: 垂直连接线在文本高于最短线时随行拉长" {
    try expectVerticalConnectorsJoined(true);
}

test "Steps: 圆圈内序号文本居中于圆心（横竖两向）" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 600 }, .height = .{ .px = 400 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    inline for (.{ StepsDirection.horizontal, StepsDirection.vertical }) |dir| {
        const steps = try Steps(.{ .items = &test_steps, .current = 1, .direction = dir }).mount(scope, ctx);
        try root.appendChild(std.testing.allocator, steps);
        ctx.layout();
        const kids = steps.children.items;
        // horizontal: first two children are connector rails; vertical: circle under row ->
        // indicator
        const first_step: usize = if (dir == .horizontal) 2 else 0;
        var checked: usize = 0;
        for (kids[first_step..]) |step| {
            const circle = if (dir == .horizontal) step.children.items[0] else step.children.items[0].children.items[0];
            // Index remains the circle's own text. Horizontal centering uses
            // text_align; vertical centering is now an explicit line inset.
            // E2E additionally checks native glyph ink.
            try std.testing.expectEqual(@as(usize, 0), circle.children.items.len);
            const txt = circle.getText() orelse return error.TestUnexpectedResult;
            try std.testing.expect(txt.content.len > 0);
            try std.testing.expectEqual(core.TextAlign.center, txt.text_align);
            try std.testing.expectApproxEqAbs(@max(0, (styles.circle_size - txt.font_size * txt.line_height) / 2), circle.style.padding.top, 0.01);
            checked += 1;
        }
        try std.testing.expectEqual(test_steps.len, checked);
        root.removeChild(steps);
        ctx.freeNode(steps);
    }
}

test "Steps: vertical" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 300 }, .height = .{ .px = 400 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const steps = try Steps(.{
        .items = &test_steps,
        .current = 2,
        .direction = .vertical,
    }).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, steps);
    try std.testing.expectEqual(@as(usize, 4), steps.children.items.len);
}

test "Steps: single step" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 300 }, .height = .{ .px = 200 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const single = [_]StepItem{
        .{ .title = "Only Step" },
    };

    const steps = try Steps(.{
        .items = &single,
        .current = 0,
    }).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, steps);
    // single step no connector: only this step
    try std.testing.expectEqual(@as(usize, 1), steps.children.items.len);

    const empty = try Steps(.{ .items = &[_]StepItem{} }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, empty);
    try std.testing.expectEqual(@as(usize, 0), empty.children.items.len); // 0 steps: don't draw empty rails
}

// styles.yss test collection, this line required; see docs/STYLING.md
fn activeIndex(steps: *Node) ?usize {
    var idx: usize = 0;
    for (steps.children.items) |child| {
        const a = child.behavior.interaction.a11y orelse continue;
        if (a.role != .listitem) continue;
        if (a.selected) return idx;
        idx += 1;
    }
    return null;
}

test "Steps: current from a signal moves the active step; static props build no effect" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const before = ctx.owner.graph.countByKind().get(.effect);
    const fixed = try Steps(.{ .items = &test_steps, .current = 1 }).mount(scope, ctx);
    defer ctx.freeNode(fixed);
    try std.testing.expectEqual(before, ctx.owner.graph.countByKind().get(.effect));

    const step = try scope.createSignal(usize, 0);
    for ([_]StepsDirection{ .horizontal, .vertical }) |dir| {
        step.set(0);
        const steps = try Steps(.{ .items = &test_steps, .current = step, .direction = dir }).mount(scope, ctx);
        defer ctx.freeNode(steps);
        try std.testing.expectEqual(@as(?usize, 0), activeIndex(steps));
        step.set(2);
        try std.testing.expectEqual(@as(?usize, 2), activeIndex(steps));
        var completed: usize = 0;
        for (steps.children.items) |child| {
            if (child.behavior.interaction.a11y) |a| {
                if (a.role == .listitem and a.checked == true) completed += 1;
            }
        }
        try std.testing.expectEqual(@as(usize, 2), completed);
    }
}

/// each step (a11y listitem node, skip connector and control-flow anchor)
fn stepNodes(steps: *Node, out: []*Node) usize {
    var n: usize = 0;
    for (steps.children.items) |c| {
        const a = c.behavior.interaction.a11y orelse continue;
        if (a.role != .listitem) continue;
        out[n] = c;
        n += 1;
    }
    return n;
}

fn firstElement(n: *Node) *Node {
    for (n.children.items) |c| if (c.tag != .anchor) return c;
    unreachable;
}

/// one step's circle (horizontal: first element of step; vertical: first element of indicator
/// column)
fn circleOf(step: *Node, dir: StepsDirection) *Node {
    return if (dir == .horizontal) firstElement(step) else firstElement(firstElement(step));
}

test "Steps: items from a signal rebuild the steps" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const two = [_]StepItem{ .{ .title = "A" }, .{ .title = "B" } };
    const items = try scope.createSignal([]const StepItem, &two);
    const steps = try Steps(.{ .items = items, .current = 1, .direction = .vertical }).mount(scope, ctx);
    defer ctx.freeNode(steps);
    var buf: [8]*Node = undefined;
    try std.testing.expectEqual(@as(usize, 2), stepNodes(steps, &buf));
    items.set(&test_steps);
    try std.testing.expectEqual(@as(usize, 4), stepNodes(steps, &buf));
    try std.testing.expectEqualStrings("Develop", buf[1].behavior.interaction.a11y.?.label.?);
    try std.testing.expect(buf[1].behavior.interaction.a11y.?.selected);
}

test "steps: 动态 current 的 mount 在任意分配点失败时不泄漏（sweep）" {
    try @import("../oom_sweep.zig").sweepMount("steps(dynamic)", struct {
        fn m(scope: *Scope, cx: *Cx) anyerror!?*Node {
            const step = try scope.createSignal(usize, 1);
            return try Steps(.{ .items = &test_steps, .current = step }).mount(scope, cx);
        }
    }.m);
}

test "Steps: current 变化只改状态（步不重建）；给了对勾图标时已完成步的圆圈换成图标" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const step = try scope.createSignal(usize, 0);
    for ([_]StepsDirection{ .horizontal, .vertical }) |dir| {
        step.set(0);
        const steps = try Steps(.{ .items = &test_steps, .current = step, .direction = dir, .check_icon_asset = svg_assets.common.check }).mount(scope, ctx);
        defer ctx.freeNode(steps);
        var buf: [8]*Node = undefined;
        _ = stepNodes(steps, &buf);
        const row0 = buf[0];
        try std.testing.expectEqualStrings("1", circleOf(row0, dir).getText().?.content);

        step.set(2);
        _ = stepNodes(steps, &buf);
        try std.testing.expectEqual(row0, buf[0]); // same step node, only changed state
        const done = circleOf(row0, dir);
        try std.testing.expect(done.getText() == null);
        try std.testing.expectEqual(core.ElementTag.image, firstElement(done).tag);
        try std.testing.expectEqual(ctx.tokens.tokens.color.accent, done.getBackground());
        // mjlUR: pending marker is bg_secondary with a border_strong outline.
        try std.testing.expectEqual(ctx.tokens.tokens.color.bg_secondary, circleOf(buf[3], dir).getBackground());

        // step backward: checkmark retracts, index returns
        step.set(0);
        try std.testing.expectEqualStrings("1", circleOf(row0, dir).getText().?.content);
        try std.testing.expectEqual(@as(?usize, 0), activeIndex(steps));
    }
}

test "Steps: 水平进度段在 current=0 时隐藏，越过末步时止于最后一个圆心" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 600 }, .height = .{ .px = 200 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const step = try scope.createSignal(usize, 0);
    const steps = try Steps(.{ .items = &test_steps, .current = step }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, steps);
    const progress = steps.children.items[1];
    try std.testing.expectEqual(core.Display.none, progress.style.display);

    step.set(99);
    ctx.layout();
    const kids = steps.children.items;
    // current from signal: circle is reactive branch, control-flow anchor before it, recognize
    // circle by size
    const first_circle = circleIn(kids[2]);
    const last_circle = circleIn(kids[kids.len - 1]);
    const pr = absRect(progress);
    try std.testing.expectEqual(core.Display.flex, progress.style.display);
    try std.testing.expectApproxEqAbs(centerX(first_circle), pr.x, 0.5);
    try std.testing.expectApproxEqAbs(centerX(last_circle), pr.x + pr.w, 0.5);
}

test "Steps: rebuilt items take the current step; items and current changed together stay consistent" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const two = [_]StepItem{ .{ .title = "A" }, .{ .title = "B" } };
    const items = try scope.createSignal([]const StepItem, &two);
    const step = try scope.createSignal(usize, 1);
    const steps = try Steps(.{ .items = items, .current = step, .direction = .vertical }).mount(scope, ctx);
    defer ctx.freeNode(steps);

    items.set(&test_steps);
    try std.testing.expectEqual(@as(?usize, 1), activeIndex(steps));

    const Both = struct {
        items: *reactive.Signal([]const StepItem),
        step: *reactive.Signal(usize),
        fn run(self: @This()) void {
            self.items.set(&two);
            self.step.set(0);
        }
    };
    try ctx.owner.batch(Both.run, Both{ .items = items, .step = step });
    var buf: [8]*Node = undefined;
    try std.testing.expectEqual(@as(usize, 2), stepNodes(steps, &buf));
    try std.testing.expectEqual(@as(?usize, 0), activeIndex(steps));
}

test {
    _ = @import("_styles.yss.zig");
}

// OOM sweep per allocation point; see src/ui/components/oom_sweep.zig
test "steps: mount 在任意分配点失败时不泄漏（sweep）" {
    try @import("../oom_sweep.zig").sweepMount("steps", struct {
        fn m(scope: *Scope, cx: *Cx) anyerror!?*Node {
            const items = [_]StepItem{ .{ .title = "One", .description = "first" }, .{ .title = "Two" }, .{ .title = "Three", .description = "last" } };
            return try Steps(.{ .items = &items, .current = 1 }).mount(scope, cx);
        }
    }.m);
}

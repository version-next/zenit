/// Steps Component
///
/// 步骤指示器，显示流程进度
///
/// 特性:
/// - 步骤编号/✓ 圆圈 + 连接线
/// - 完成/进行中/待办三种状态
/// - 标题 + 描述
const std = @import("std");
const core = @import("../../core.zig");
const Cx = core.Cx;
const Node = core.Node;
const box = core.box;
const Color = core.Color;
const svg_assets = @import("../../svg_assets.zig");
const Scope = @import("../../reactive.zig").Scope;

// 样式层已析出到 styles.zig
const styles = @import("styles.zig");

/// 步骤项
pub const StepItem = struct {
    title: []const u8,
    description: ?[]const u8 = null,
};

/// Steps 属性
pub const StepsProps = struct {
    items: []const StepItem = &.{},
    /// 当前步骤索引。**只在 mount 时读取一次**, Steps 是纯静态渲染
    /// （无内部 state），改这个值不会让已挂载的实例更新。
    /// 需要动态步进请重新 mount，或用 ui.Show/For 驱动。
    initial_current: usize = 0,
    direction: Direction = .horizontal,
    check_icon_asset: ?svg_assets.Asset = null,

    pub const Direction = enum { horizontal, vertical };
};

/// 每一步的 a11y 声明。
///
/// 圆圈里画的是数字/对勾，全是纯视觉信号：AT 用户看不到颜色，也读不出
/// "第 2 步是实心的"。所以必须把三种状态显式说出来,
/// selected = 当前步（"你在这儿"），checked = 已完成，disabled = 还没走到。
/// 缺了这些，Steps 在 AT 侧就只剩一串没有先后关系的标题。
fn stepA11y(item: StepItem, is_completed: bool, is_active: bool) core.A11yProps {
    return .{
        .role = .listitem,
        .label = item.title,
        .description = item.description,
        .selected = is_active,
        .checked = is_completed,
        .disabled = !is_completed and !is_active,
    };
}

/// 圆圈里的序号/对勾字符：直接作为圆圈自身文本，text_align = .center 横向居中，
/// 单行文本在定高盒内由渲染纵向居中（框架原生能力，不需要包子节点）。
fn setCircleLabel(cx: *Cx, circle: *Node, label: []const u8, t: *const core.ThemeTokens) !void {
    var circle_txt = styles.circleTextProps(t);
    try circle_txt.setContent(cx.allocator, label); // label 可能指向调用方循环内栈缓冲，必须拷贝
    circle.setText(circle_txt);
}

/// 创建 Steps
pub fn Steps(props: StepsProps) StepsBuilder {
    return StepsBuilder{ .props = props };
}

pub const StepsBuilder = struct {
    props: StepsProps,

    pub fn items(self: StepsBuilder, its: []const StepItem) StepsBuilder {
        var new = self;
        new.props.items = its;
        return new;
    }

    /// 设置初始步骤索引（mount-only，见 StepsProps.initial_current）。
    pub fn initialCurrent(self: StepsBuilder, c: usize) StepsBuilder {
        var new = self;
        new.props.initial_current = c;
        return new;
    }

    pub fn direction(self: StepsBuilder, d: StepsProps.Direction) StepsBuilder {
        var new = self;
        new.props.direction = d;
        return new;
    }

    pub fn checkIconAsset(self: StepsBuilder, asset: svg_assets.Asset) StepsBuilder {
        var new = self;
        new.props.check_icon_asset = asset;
        return new;
    }

    /// 保留模式: mount
    pub fn mount(self: StepsBuilder, scope: *Scope, cx: *Cx) !*Node {
        const my_scope = try scope.childScope();
        const allocator = cx.allocator;
        const t = cx.tokens;
        const p = self.props;

        const is_horizontal = (p.direction == .horizontal);
        const layout_dir: core.Direction = if (is_horizontal) .row else .column;
        const container_width: core.Sizing = if (is_horizontal) .{ .grow = .{} } else .{ .fit = .{} };

        const container = try box(cx, .{
            .width = container_width,
            .height = .{ .fit = .{} },
            .direction = layout_dir,
            .gap = 0,
        }, .{});
        container.meta.ownership.meta.component_name = "Steps";
        // sweep：container 守卫一直武装到 return；所有子节点建好即 adopt
        errdefer cx.freeNode(container);
        try core.bindScopeToNode(my_scope, container);
        // role=list 让 AT 播报"共 N 步"，配合每步的 selected 就能说出
        // "第 2 步，共 4 步"。
        container.behavior.interaction.a11y = .{ .role = .list, .label = "Steps" };

        // ── 水平布局 ──
        // 参考 Web Steps 组件: 每个 Step 是 grow 均分列，连接线用 absolute 一条贯穿
        //
        // container (row, grow):
        //   ├─ Step 0 (grow, column, center): circle + gap + title + desc
        //   ├─ Step 1 (grow, column, center): circle + gap + title + desc
        //   └─ Step 2 (grow, column, center): circle + gap + title + desc
        //   └─ [absolute] connector_track: 从 padding_left 到 padding_right, y=圆心
        //
        // connector_track 分段着色由 on_before_render 在 layout 完成后动态计算

        if (is_horizontal) {
            const circle_size = styles.circle_size;
            const n = p.items.len;

            // 连接线轨道 (absolute + inset)：
            // 从第一个圆心到最后一个圆心的水平线
            // 每个 step 均分宽度 = 1/N，圆心在每个 step 的正中间
            // 第一个圆心 x = step_width/2 = container_width/(2*N)
            // 最后一个圆心 x = container_width - step_width/2
            // 用 inset.left / inset.right 精确裁剪（百分比）
            const half_step_pct: f32 = if (n > 0) 50.0 / @as(f32, @floatFromInt(n)) else 0;

            const track_bg = try core.adoptChild(cx, allocator, container, try box(cx, styles.hTrackStyle(t), .{}));
            const track_ext = try track_bg.style.ensureExtFallible(cx.allocator);
            track_ext.inset = .{
                .top = .{ .px = circle_size / 2 - 1 },
                .left = .{ .percent = half_step_pct },
                .right = .{ .percent = half_step_pct },
            };

            // 已完成段（覆盖在轨道上方）
            // 进度线从第一个圆心到第 current 个圆心
            if (p.initial_current > 0 and n > 1) {
                const progress_end_pct = half_step_pct + @as(f32, @floatFromInt(p.initial_current)) / @as(f32, @floatFromInt(n)) * 100.0;
                const track_fg = try core.adoptChild(cx, allocator, container, try box(cx, styles.hTrackProgressStyle(t), .{}));
                const track_fg_ext = try track_fg.style.ensureExtFallible(cx.allocator);
                track_fg_ext.inset = .{
                    .top = .{ .px = circle_size / 2 - 1 },
                    .left = .{ .percent = half_step_pct },
                    .right = .{ .percent = 100.0 - progress_end_pct },
                };
            }

            // 每个 Step 是 grow 均分列
            for (p.items, 0..) |item, i| {
                const is_completed = i < p.initial_current;
                const is_active = i == p.initial_current;
                const circle_bg = styles.circleBg(is_completed, is_active, t);
                const circle_fg = styles.circle_fg;

                const step_col = try core.adoptChild(cx, allocator, container, try box(cx, .{
                    .width = .{ .grow = .{} },
                    .height = .{ .fit = .{} },
                    .direction = .column,
                    .align_items = .center,
                    .gap = 6,
                }, .{}));
                step_col.behavior.interaction.a11y = stepA11y(item, is_completed, is_active);

                // 圆圈（z_index 确保在线上方）
                if (is_completed and p.check_icon_asset != null) {
                    const circle = try core.adoptChild(cx, allocator, step_col, try box(cx, styles.circleStyle(circle_bg), .{}));
                    _ = try core.adoptChild(cx, allocator, circle, try core.iconTint(cx, p.check_icon_asset.?, circle_fg, .{
                        .width = .{ .px = 14 },
                        .height = .{ .px = 14 },
                    }));
                } else {
                    var num_buf: [4]u8 = undefined;
                    const circle_text = if (is_completed) "v" else std.fmt.bufPrint(&num_buf, "{d}", .{i + 1}) catch "?";

                    const circle = try core.adoptChild(cx, allocator, step_col, try box(cx, styles.circleStyle(circle_bg), .{}));
                    try setCircleLabel(cx, circle, circle_text, t);
                }

                // 标题
                const title_node = try core.adoptChild(cx, allocator, step_col, try box(cx, .{
                    .width = .{ .fit = .{} },
                    .height = .{ .fit = .{} },
                }, .{}));
                var title_txt = styles.titleTextProps(is_active, is_completed, t);
                title_txt.content = item.title;
                title_node.setText(title_txt);

                // 描述
                if (item.description) |desc| {
                    const desc_node = try core.adoptChild(cx, allocator, step_col, try box(cx, .{
                        .width = .{ .fit = .{} },
                        .height = .{ .fit = .{} },
                    }, .{}));
                    var desc_txt = styles.descTextProps(t);
                    desc_txt.content = desc;
                    desc_node.setText(desc_txt);
                }
            }
        } else {
            // ── 垂直布局 ──
            for (p.items, 0..) |item, i| {
                const is_last = (i == p.items.len - 1);
                const is_completed = i < p.initial_current;
                const is_active = i == p.initial_current;
                const circle_bg = styles.circleBg(is_completed, is_active, t);
                const circle_fg = styles.circle_fg;

                // align_items=start：圆圈钉在行顶。原先 center 会让「无连接线的最后一步」
                // （指示器只有圆圈高）在比圆圈高的行里被居中下移，与上一段连接线断开。
                const step = try core.adoptChild(cx, allocator, container, try box(cx, .{
                    .width = .{ .fit = .{} },
                    .height = .{ .fit = .{} },
                    .direction = .row,
                    .align_items = .start,
                    .gap = 4,
                }, .{}));
                step.behavior.interaction.a11y = stepA11y(item, is_completed, is_active);

                // 指示器列撑满整行高度，连接线（grow）再填满圆圈下方剩余部分，
                // 保证线段底端正好是下一步圆圈顶端。
                const indicator = try core.adoptChild(cx, allocator, step, try box(cx, .{
                    .width = .{ .fit = .{} },
                    .height = .{ .grow = .{} },
                    .direction = .column,
                    .align_items = .center,
                }, .{}));

                if (is_completed and p.check_icon_asset != null) {
                    const circle = try core.adoptChild(cx, allocator, indicator, try box(cx, styles.circleStyle(circle_bg), .{}));
                    _ = try core.adoptChild(cx, allocator, circle, try core.iconTint(cx, p.check_icon_asset.?, circle_fg, .{
                        .width = .{ .px = 14 },
                        .height = .{ .px = 14 },
                    }));
                } else {
                    var num_buf: [4]u8 = undefined;
                    const circle_text = if (is_completed) "v" else std.fmt.bufPrint(&num_buf, "{d}", .{i + 1}) catch "?";

                    const circle = try core.adoptChild(cx, allocator, indicator, try box(cx, styles.circleStyle(circle_bg), .{}));
                    try setCircleLabel(cx, circle, circle_text, t);
                }

                if (!is_last) {
                    _ = try core.adoptChild(cx, allocator, indicator, try box(cx, styles.vConnectorStyle(is_completed, t), .{}));
                }

                const text_box = try core.adoptChild(cx, allocator, step, try box(cx, .{
                    .width = .{ .fit = .{} },
                    .height = .{ .fit = .{} },
                    .direction = .column,
                    .align_items = .start,
                    .gap = 2,
                    .padding = .{ .top = styles.vTitleTopPad(t) },
                }, .{}));

                const title_node = try core.adoptChild(cx, allocator, text_box, try box(cx, .{
                    .width = .{ .fit = .{} },
                    .height = .{ .fit = .{} },
                }, .{}));
                var title_txt = styles.titleTextProps(is_active, is_completed, t);
                title_txt.content = item.title;
                title_node.setText(title_txt);

                if (item.description) |desc| {
                    const desc_node = try core.adoptChild(cx, allocator, text_box, try box(cx, .{
                        .width = .{ .fit = .{} },
                        .height = .{ .fit = .{} },
                    }, .{}));
                    var desc_txt = styles.descTextProps(t);
                    desc_txt.content = desc;
                    desc_node.setText(desc_txt);
                }
            }
        }

        return container;
    }
};

// ========== 测试 ==========

const test_steps = [_]StepItem{
    .{ .title = "Setup", .description = "Initialize project" },
    .{ .title = "Develop", .description = "Write code" },
    .{ .title = "Test" },
    .{ .title = "Deploy" },
};

test "Steps: basic horizontal" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 600 }, .height = .{ .px = 200 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const steps = try Steps(.{
        .items = &test_steps,
        .initial_current = 1,
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
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 600 }, .height = .{ .px = 400 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    inline for (.{ StepsProps.Direction.horizontal, StepsProps.Direction.vertical }) |dir| {
        const steps = try Steps(.{ .items = &test_steps, .initial_current = 0, .direction = dir }).mount(scope, ctx);
        try root.appendChild(std.testing.allocator, steps);
        var digits: std.ArrayList(u8) = .empty;
        defer digits.deinit(std.testing.allocator);
        try collectStepDigits(steps, &digits);
        try std.testing.expectEqualStrings("1234", digits.items);
    }
}

/// 布局 rect 是父局部坐标；测试里比较跨子树的几何需要累加到同一坐标系。
fn absRect(n: *Node) core.ComputedRect {
    var r = n.rectFromWorldOrFallback();
    var p = n.parent;
    while (p) |pp| : (p = pp.parent) {
        const pr = pp.rectFromWorldOrFallback();
        r.x += pr.x;
        r.y += pr.y;
    }
    return r;
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
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 600 }, .height = .{ .px = 200 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const steps = try Steps(.{ .items = &test_steps, .initial_current = 2 }).mount(scope, ctx);
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
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 300 }, .height = .{ .px = 400 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    var big = ctx.tokens.*;
    if (big_fonts) {
        // 文本列（标题+描述）高于「圆圈 + 最短连接线」，连接线必须随行拉长
        big.font_size.sm = 19; // 标题行高 26.6 < 圆圈 28，仍可与圆圈居中
        big.font_size.xs = 20;
        ctx.tokens = &big;
    }
    // 最后一步带描述（storybook 同款）：文本列比圆圈高，是原先 align=center
    // 把最后一个圆圈下移、与上一段连接线断开的触发条件
    const items = [_]StepItem{
        .{ .title = "Setup", .description = "Initialize project" },
        .{ .title = "Develop", .description = "Write code" },
        .{ .title = "Test" },
        .{ .title = "Deploy", .description = "Ship it" },
    };
    const steps = try Steps(.{ .items = &items, .initial_current = 3, .direction = .vertical }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, steps);
    ctx.layout();
    const rows = steps.children.items;
    if (big_fonts) {
        // 前提：行确实比「圆圈 + 最短连接线」高，否则测不到拉伸
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
        // 标题首行中心 ≈ 圆心（行 align=start 后靠 padding 对齐）
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
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 600 }, .height = .{ .px = 400 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    inline for (.{ StepsProps.Direction.horizontal, StepsProps.Direction.vertical }) |dir| {
        const steps = try Steps(.{ .items = &test_steps, .initial_current = 1, .direction = dir }).mount(scope, ctx);
        try root.appendChild(std.testing.allocator, steps);
        ctx.layout();
        const kids = steps.children.items;
        // 横向：前两个孩子是连接线轨道；纵向：圆圈在 row -> indicator 下
        const first_step: usize = if (dir == .horizontal) 2 else 0;
        var checked: usize = 0;
        for (kids[first_step..]) |step| {
            const circle = if (dir == .horizontal) step.children.items[0] else step.children.items[0].children.items[0];
            // 序号是圆圈自身文本（不包子节点），靠 text_align = .center + 渲染纵向居中；
            // 视觉居中由 e2e「Steps 连接线连贯 + 序号居中」按墨迹像素断言守护。
            try std.testing.expectEqual(@as(usize, 0), circle.children.items.len);
            const txt = circle.getText() orelse return error.TestUnexpectedResult;
            try std.testing.expect(txt.content.len > 0);
            try std.testing.expectEqual(core.TextAlign.center, txt.text_align);
            checked += 1;
        }
        try std.testing.expectEqual(test_steps.len, checked);
        root.removeChild(steps);
        ctx.freeNode(steps);
    }
}

test "Steps: vertical" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 300 }, .height = .{ .px = 400 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const steps = try Steps(.{
        .items = &test_steps,
        .initial_current = 2,
        .direction = .vertical,
    }).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, steps);
    try std.testing.expectEqual(@as(usize, 4), steps.children.items.len);
}

test "Steps: single step" {
    var ctx = try Cx.init(std.testing.allocator);
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
        .initial_current = 0,
    }).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, steps);
    try std.testing.expectEqual(@as(usize, 2), steps.children.items.len);
}

// styles.zig 的测试收集，这行是必需的，见 docs/STYLING.md
test {
    _ = @import("styles.zig");
}

// 逐分配点 OOM sweep，见 src/ui/components/oom_sweep.zig
test "steps: mount 在任意分配点失败时不泄漏（sweep）" {
    try @import("../oom_sweep.zig").sweepMount("steps", struct {
        fn m(scope: *Scope, cx: *Cx) anyerror!?*Node {
            const items = [_]StepItem{ .{ .title = "One", .description = "first" }, .{ .title = "Two" }, .{ .title = "Three", .description = "last" } };
            return try Steps(.{ .items = &items, .initial_current = 1 }).mount(scope, cx);
        }
    }.m);
}

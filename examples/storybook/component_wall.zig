//! Component Wall — 官网首页 "组件" 区的整墙截图用。
//!
//! 不演示单个组件的全部状态，而是把常用组件按真实界面的样子摆成四列
//! 卡片墙（每张卡片是一小块能交互的真实 UI），一次截图就能看到框架的
//! 组件面貌。窗口需放大到能容下整墙（capture 脚本会 resize 到 1860 宽）。

const ui = @import("ui");

const W = ui.widgets;
const icons = ui.assets.common;

const col_width: f32 = 344;

fn tag(node: *ui.Node, comptime id: []const u8) void {
    node.meta.ownership.meta.test_id = id;
}

fn column(cx: *ui.Cx) !*ui.Node {
    return ui.box(cx, .{ .width = .{ .px = col_width }, .direction = .column, .gap = 16 }, .{});
}

fn row(cx: *ui.Cx, gap: f32) !*ui.Node {
    return ui.box(cx, .{ .direction = .row, .gap = gap, .align_items = .center }, .{});
}

/// One card of the wall: white surface, hairline border, large radius.
fn tile(cx: *ui.Cx, title: []const u8) !*ui.Node {
    const t = cx.tokens;
    const node = try ui.box(cx, .{
        .width = .{ .grow = .{} },
        .direction = .column,
        .gap = 14,
        .padding = ui.Padding.all(18),
        .background = t.color.bg_primary,
        .border = .{ .width = 1, .color = t.color.border, .radius = t.radius.lg },
    }, .{});
    try node.appendChild(cx.allocator, try ui.text(cx, title, .{ .font_size = 12, .font_weight = 600, .color = t.color.fg_tertiary }));
    return node;
}

fn body(cx: *ui.Cx, value: []const u8) !*ui.Node {
    return ui.text(cx, value, .{ .font_size = 13, .color = cx.tokens.color.fg_secondary });
}

// ── Column 1: actions & form controls ──

const region_options = [_]W.SelectOption{
    .{ .value = "apac", .label = "Asia Pacific" },
    .{ .value = "emea", .label = "Europe & Middle East" },
    .{ .value = "amer", .label = "Americas" },
};

fn columnControls(scope: *ui.Scope, cx: *ui.Cx) !*ui.Node {
    const a = cx.allocator;
    const c = try column(cx);

    const actions = try tile(cx, "Actions");
    const r1 = try row(cx, 8);
    try r1.appendChild(a, try W.Button(.{ .label = "Deploy", .variant = .primary, .icon_asset = icons.plus }).mount(scope, cx));
    try r1.appendChild(a, try W.Button(.{ .label = "Preview", .variant = .secondary }).mount(scope, cx));
    try r1.appendChild(a, try W.Button(.{ .label = "Delete", .variant = .danger }).mount(scope, cx));
    try actions.appendChild(a, r1);
    const r2 = try row(cx, 8);
    inline for (.{ W.ButtonSize.xs, .sm, .md, .lg }, .{ "XS", "SM", "MD", "LG" }) |sz, t| {
        try r2.appendChild(a, try W.Button(.{ .label = t, .variant = .secondary, .size = sz }).mount(scope, cx));
    }
    try r2.appendChild(a, try W.Button(.{ .label = "Ghost", .variant = .ghost }).mount(scope, cx));
    try actions.appendChild(a, r2);
    try c.appendChild(a, actions);

    const fields = try tile(cx, "Input · Select");
    try fields.appendChild(a, try W.Input(.{ .placeholder = "Search components…", .leading_icon_asset = icons.search, .width = col_width - 38 }).mount(scope, cx));
    const region = try W.Select(.{ .options = &region_options, .initial_selected = &.{0}, .width = col_width - 38 }, scope, cx);
    try fields.appendChild(a, region.wrapper);
    try fields.appendChild(a, try W.Input(.{ .placeholder = "0.00", .append_text = "USD", .width = col_width - 38 }).mount(scope, cx));
    try c.appendChild(a, fields);

    const toggles = try tile(cx, "Switch · Checkbox · Radio");
    try toggles.appendChild(a, try W.Switch(.{ .label_text = "Sync over iCloud", .initial_checked = true }).mount(scope, cx));
    try toggles.appendChild(a, try W.Switch(.{ .label_text = "Low power mode", .initial_checked = false }).mount(scope, cx));
    const checks = try row(cx, 16);
    try checks.appendChild(a, try W.Checkbox(.{ .label_text = "Metal", .initial_checked = true }).mount(scope, cx));
    try checks.appendChild(a, try W.Checkbox(.{ .label_text = "CoreText", .initial_checked = true }).mount(scope, cx));
    try checks.appendChild(a, try W.Checkbox(.{ .label_text = "IME" }).mount(scope, cx));
    try toggles.appendChild(a, checks);
    const radio_opts = [_]W.checkbox.RadioOption{
        .{ .value = "light", .label_text = "Light" },
        .{ .value = "dark", .label_text = "Dark" },
        .{ .value = "auto", .label_text = "Auto" },
    };
    try toggles.appendChild(a, try W.RadioGroup(.{ .options = &radio_opts, .value = "auto" }).mount(scope, cx));
    try c.appendChild(a, toggles);

    const ranges = try tile(cx, "Slider · Progress · Stepper");
    const slider = try W.Slider(.{ .min = 0, .max = 100, .initial_value = 64, .width = col_width - 38, .show_value = true }).mount(scope, cx);
    try ranges.appendChild(a, slider.wrapper);
    try ranges.appendChild(a, try W.Progress(.{ .value = 72, .width = col_width - 38, .show_text = true }).mount(scope, cx));
    const r3 = try row(cx, 16);
    const stepper = try W.NumberStepper(.{ .value = 3, .min = 0, .max = 10 }, scope, cx);
    try r3.appendChild(a, stepper.wrapper);
    try r3.appendChild(a, try W.Spinner(.{ .size = 20 }).mount(scope, cx));
    try ranges.appendChild(a, r3);
    try c.appendChild(a, ranges);
    return c;
}

// ── Column 2: navigation & dates ──

fn columnNavigation(scope: *ui.Scope, cx: *ui.Cx) !*ui.Node {
    const a = cx.allocator;
    const c = try column(cx);

    const tabs = try tile(cx, "Tabs");
    const tab_items = [_]W.tabs.TabItem{
        .{ .id = "overview", .label_text = "Overview" },
        .{ .id = "activity", .label_text = "Activity", .badge = 3 },
        .{ .id = "settings", .label_text = "Settings" },
    };
    try tabs.appendChild(a, try W.Tabs(.{ .items = &tab_items, .variant = .underline }).mount(scope, cx));
    try tabs.appendChild(a, try W.Tabs(.{ .items = &tab_items, .variant = .pill, .size = .sm }).mount(scope, cx));
    try c.appendChild(a, tabs);

    const cal = try tile(cx, "Calendar");
    const calendar = try W.Calendar(.{ .initial_year = 2026, .initial_month = 9 }).mount(scope, cx);
    try cal.appendChild(a, calendar.wrapper);
    try c.appendChild(a, cal);

    const steps = try tile(cx, "Steps · Breadcrumb");
    const step_items = [_]W.StepItem{
        .{ .title = "Account", .description = "Sign in" },
        .{ .title = "Project", .description = "Pick a template" },
        .{ .title = "Ship", .description = "Bundle .app" },
    };
    try steps.appendChild(a, try W.Steps(.{ .items = &step_items, .initial_current = 1, .check_icon_asset = icons.check }).mount(scope, cx));
    const crumbs = [_]W.BreadcrumbItem{
        .{ .id = "home", .label_text = "Home" },
        .{ .id = "lib", .label_text = "Library" },
        .{ .id = "comp", .label_text = "Components" },
    };
    try steps.appendChild(a, try W.Breadcrumb(.{ .items = &crumbs }).mount(scope, cx));
    try c.appendChild(a, steps);

    const tags_input = try tile(cx, "TagsInput");
    const ti = try W.TagsInput(.{ .initial_tags = &.{ "signals", "retained", "gpu" }, .width = col_width - 38 }, scope, cx);
    try tags_input.appendChild(a, ti.wrapper);
    try c.appendChild(a, tags_input);
    return c;
}

// ── Column 3: data display ──

const NAMES = [_][]const u8{ "Aurora", "Nebula", "Solstice", "Tidal", "Ember" };
const KINDS = [_][]const u8{ "Shader", "Particles", "Glass UI", "Springs", "Vectors" };
const FPS = [_][]const u8{ "120", "118", "120", "96", "120" };

fn tableCell(cell: *ui.Node, row_i: usize, col_i: usize, c: *ui.Cx) void {
    const txt: []const u8 = switch (col_i) {
        0 => NAMES[row_i % NAMES.len],
        1 => KINDS[row_i % KINDS.len],
        else => FPS[row_i % FPS.len],
    };
    const child = ui.text(c, txt, .{ .font_size = 13, .color = c.tokens.color.fg_primary }) catch return;
    cell.appendChild(c.allocator, child) catch {};
}

fn columnData(scope: *ui.Scope, cx: *ui.Cx) !*ui.Node {
    const a = cx.allocator;
    const c = try column(cx);

    const table = try tile(cx, "Table");
    const cols = [_]W.ColumnDef{
        .{ .id = "name", .header = "Name", .width = 118 },
        .{ .id = "kind", .header = "Kind", .width = 110 },
        .{ .id = "fps", .header = "FPS", .width = 78, .sortable = true },
    };
    const t = try W.Table(.{ .columns = &cols, .row_count = 5, .table_height = 40 + 5 * 36, .striped = true, .render_cell = tableCell }).mount(scope, cx);
    try table.appendChild(a, t.wrapper);
    try c.appendChild(a, table);

    const alerts = try tile(cx, "Alert");
    try alerts.appendChild(a, try W.Alert(.{ .variant = .success, .title = "Build succeeded", .message = "Hello Button.app · 1.7 MB" }).mount(scope, cx));
    try alerts.appendChild(a, try W.Alert(.{ .variant = .warning, .title = "API may change", .message = "Pin an exact version before 1.0." }).mount(scope, cx));
    try c.appendChild(a, alerts);

    const labels = try tile(cx, "Tag · Badge · Chip");
    const tags = try row(cx, 6);
    inline for (.{ W.TagColor.accent, .success, .warning, .danger, .neutral }, .{ "zig", "metal", "beta", "breaking", "macOS" }) |color, txt| {
        try tags.appendChild(a, try W.Tag(.{ .text = txt, .color = color }).mount(scope, cx));
    }
    try labels.appendChild(a, tags);
    const badges = try row(cx, 8);
    inline for (.{ "info", "success", "warning", "error" }, .{ W.badge.BadgeStatus.info, .success, .warning, .@"error" }) |txt, st| {
        try badges.appendChild(a, try W.Badge(.{ .text = txt, .status = st }).mount(scope, cx));
    }
    try badges.appendChild(a, try W.Badge(.{ .count = 120, .max_count = 99 }).mount(scope, cx));
    try labels.appendChild(a, badges);
    const chips = try row(cx, 6);
    try chips.appendChild(a, try W.Chip(.{ .label = "All", .variant = .active }).mount(scope, cx));
    try chips.appendChild(a, try W.Chip(.{ .label = "Layout" }).mount(scope, cx));
    try chips.appendChild(a, try W.Chip(.{ .label = "Text" }).mount(scope, cx));
    try chips.appendChild(a, try W.Chip(.{ .label = "Glass", .closable = true }).mount(scope, cx));
    try labels.appendChild(a, chips);
    try c.appendChild(a, labels);

    const rating = try tile(cx, "Rate · Skeleton");
    const rate = try W.Rate(.{ .count = 5, .value = 4 }).mount(scope, cx);
    try rating.appendChild(a, rate.wrapper);
    try rating.appendChild(a, try W.Skeleton(.{ .variant = .text, .width = col_width - 38, .height = 12 }).mount(scope, cx));
    try rating.appendChild(a, try W.Skeleton(.{ .variant = .text, .width = 200, .height = 12 }).mount(scope, cx));
    try c.appendChild(a, rating);

    return c;
}

// ── Column 4: structure & feedback ──

fn columnStructure(scope: *ui.Scope, cx: *ui.Cx) !*ui.Node {
    const a = cx.allocator;
    const c = try column(cx);

    const timeline = try tile(cx, "Timeline");
    const events = [_]W.TimelineItem{
        .{ .title = "Committed", .description = "feat(select): keyboard nav", .time = "09:12", .status = .completed },
        .{ .title = "E2E running", .description = "storybook.test.ts · 64 stories", .time = "09:14", .status = .active },
        .{ .title = "Release", .description = "v0.1.0-alpha", .status = .pending },
    };
    try timeline.appendChild(a, try W.Timeline(.{ .items = &events }).mount(scope, cx));
    try c.appendChild(a, timeline);

    const tree = try tile(cx, "Tree");
    const ui_files = [_]W.TreeNodeData{
        .{ .id = "button", .label_text = "button.zig" },
        .{ .id = "select", .label_text = "select.zig" },
    };
    const src_dirs = [_]W.TreeNodeData{
        .{ .id = "components", .label_text = "components", .children = &ui_files },
        .{ .id = "main", .label_text = "main.zig" },
    };
    const nodes = [_]W.TreeNodeData{
        .{ .id = "src", .label_text = "src", .children = &src_dirs },
        .{ .id = "build", .label_text = "build.zig" },
    };
    const tr = try W.Tree(.{ .nodes = &nodes }).mount(scope, cx);
    // Open src/ and src/components/ and select select.zig (flat order:
    // src, components, button, select, main, build).
    tr.state.toggleExpand(0);
    tr.state.toggleExpand(1);
    tr.state.selectNode(3);
    try tree.appendChild(a, tr.wrapper);
    try c.appendChild(a, tree);

    const acc_tile = try tile(cx, "Accordion");
    const acc = try W.Accordion(.{ .exclusive = true, .gap = 6 }).mount(scope, cx);
    inline for (.{ "What is a retained tree?", "Does it use a WebView?", "Which platforms?" }, .{
        "Nodes are built once and updated in place.",
        "No. Metal draws every pixel.",
        "macOS today.",
    }, 0..) |q, ans, i| {
        const item = try W.AccordionItem(.{ .title = q, .expanded = (i == 0) }).mount(scope, cx);
        try item.body.appendChild(a, try body(cx, ans));
        try acc.container.appendChild(a, item.item);
    }
    try acc_tile.appendChild(a, acc.container);
    try c.appendChild(a, acc_tile);

    return c;
}

pub fn build(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const a = cx.allocator;
    const root = try ui.box(cx, .{ .direction = .row, .gap = 16, .align_items = .start }, .{});
    tag(root, "story.wall.root");
    try root.appendChild(a, try columnControls(scope, cx));
    try root.appendChild(a, try columnNavigation(scope, cx));
    try root.appendChild(a, try columnData(scope, cx));
    try root.appendChild(a, try columnStructure(scope, cx));
    return root;
}

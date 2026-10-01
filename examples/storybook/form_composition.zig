//! Form Composition，同档 Input / Select / Button 混排的业务示意。
//!
//! 三者共用 `ControlSize`（外框高度 = padding_y × 2 + 行高：XS 20 / SM 24 /
//! MD 32 / LG 40）。这个 story 不演示单个组件，而是把它们按真实业务场景
//! 拼在一起，看同一档位下高度、圆角、字号、图标与间距是否协调：
//!   1. 筛选工具栏：四档各一行，Input + Select × 2 + Button × 2 横排；
//!   2. 新建订单表单：MD 档两列字段 + 底部操作区。

const ui = @import("ui");

const W = ui.widgets;
const ControlSize = ui.theme.ControlSize;

const status_options = [_]W.SelectOption{
    .{ .value = "all", .label = "All statuses" },
    .{ .value = "pending", .label = "Pending" },
    .{ .value = "paid", .label = "Paid" },
    .{ .value = "refunded", .label = "Refunded" },
};

const owner_options = [_]W.SelectOption{
    .{ .value = "anyone", .label = "Anyone", .icon = ui.icons.globe },
    .{ .value = "me", .label = "Assigned to me", .icon = ui.icons.user },
    .{ .value = "team", .label = "My team", .icon = ui.icons.settings },
};

const region_options = [_]W.SelectOption{
    .{ .value = "apac", .label = "Asia Pacific" },
    .{ .value = "emea", .label = "Europe & Middle East" },
    .{ .value = "amer", .label = "Americas" },
};

const priority_options = [_]W.SelectOption{
    .{ .value = "low", .label = "Low" },
    .{ .value = "normal", .label = "Normal" },
    .{ .value = "high", .label = "High" },
    .{ .value = "urgent", .label = "Urgent" },
};

const SizeSpec = struct { size: ControlSize, key: []const u8, title: []const u8 };

const sizes = [_]SizeSpec{
    .{ .size = .xs, .key = "xs", .title = "XS" },
    .{ .size = .sm, .key = "sm", .title = "SM" },
    .{ .size = .md, .key = "md", .title = "MD" },
    .{ .size = .lg, .key = "lg", .title = "LG" },
};

fn heading(cx: *ui.Cx, value: []const u8) !*ui.Node {
    return ui.text(cx, value, .{ .font_size = 13, .font_weight = 600, .color = cx.tokens.color.fg_primary });
}

fn caption(cx: *ui.Cx, value: []const u8) !*ui.Node {
    return ui.text(cx, value, .{ .font_size = 12, .color = cx.tokens.color.fg_tertiary });
}

fn tag(node: *ui.Node, comptime id: []const u8) void {
    node.meta.ownership.meta.test_id = id;
}

fn filterToolbar(comptime spec: SizeSpec, scope: *ui.Scope, cx: *ui.Cx) !*ui.Node {
    const a = cx.allocator;
    const prefix = "story.formcompose." ++ spec.key;
    const block = try ui.box(cx, .{ .direction = .column, .gap = 6 }, .{});
    try block.appendChild(a, try caption(cx, spec.title));

    const bar = try ui.box(cx, .{ .direction = .row, .gap = 8, .align_items = .center }, .{});
    tag(bar, prefix ++ ".row");

    const search = try W.Input(.{
        .size = spec.size,
        .placeholder = "Search orders…",
        .leading_icon_asset = ui.assets.common.search,
        .width = 180,
    }).mount(scope, cx);
    tag(search, prefix ++ ".input");
    try bar.appendChild(a, search);

    const status = try W.Select(.{
        .size = spec.size,
        .options = &status_options,
        .placeholder = "Status",
        .width = 130,
    }, scope, cx);
    tag(status.trigger, prefix ++ ".status");
    try bar.appendChild(a, status.wrapper);

    const owner = try W.Select(.{
        .size = spec.size,
        .options = &owner_options,
        .placeholder = "Owner",
        .leading_icon = ui.icons.user,
        .width = 150,
    }, scope, cx);
    tag(owner.trigger, prefix ++ ".owner");
    try bar.appendChild(a, owner.wrapper);

    const reset = try W.Button(.{ .label = "Reset", .variant = .secondary, .size = spec.size }).mount(scope, cx);
    tag(reset, prefix ++ ".reset");
    try bar.appendChild(a, reset);

    const apply = try W.Button(.{
        .label = "Apply filters",
        .variant = .primary,
        .size = spec.size,
        .icon_asset = ui.assets.common.search,
    }).mount(scope, cx);
    tag(apply, prefix ++ ".apply");
    try bar.appendChild(a, apply);

    try block.appendChild(a, bar);
    return block;
}

const field_width: f32 = 280;

fn field(cx: *ui.Cx, label: []const u8, control: *ui.Node) !*ui.Node {
    const node = try ui.box(cx, .{ .width = .{ .px = field_width }, .direction = .column, .gap = 6 }, .{});
    try node.appendChild(cx.allocator, try ui.text(cx, label, .{
        .font_size = 12,
        .font_weight = 600,
        .color = cx.tokens.color.fg_secondary,
    }));
    try node.appendChild(cx.allocator, control);
    return node;
}

fn fieldRow(cx: *ui.Cx, left: *ui.Node, right: *ui.Node) !*ui.Node {
    const r = try ui.box(cx, .{ .direction = .row, .gap = 16, .align_items = .start }, .{});
    try r.appendChild(cx.allocator, left);
    try r.appendChild(cx.allocator, right);
    return r;
}

fn orderForm(scope: *ui.Scope, cx: *ui.Cx) !*ui.Node {
    const a = cx.allocator;
    const t = cx.tokens;
    const card = try ui.box(cx, .{
        .direction = .column,
        .gap = 16,
        .padding = ui.Padding.all(20),
        .background = t.color.bg_primary,
        .border = .{ .width = 1, .color = t.color.border, .radius = t.radius.lg },
    }, .{});
    tag(card, "story.formcompose.order");

    const head = try ui.box(cx, .{ .direction = .column, .gap = 4 }, .{});
    try head.appendChild(a, try ui.text(cx, "New order", .{ .font_size = 16, .font_weight = 600, .color = t.color.fg_primary }));
    try head.appendChild(a, try caption(cx, "Orders are billed in the customer's region currency."));
    try card.appendChild(a, head);

    const customer = try W.Input(.{ .placeholder = "Acme Inc.", .width = field_width }).mount(scope, cx);
    tag(customer, "story.formcompose.order.customer");
    const email = try W.Input(.{ .input_type = .email, .placeholder = "billing@acme.com", .width = field_width }).mount(scope, cx);
    try card.appendChild(a, try fieldRow(cx, try field(cx, "Customer", customer), try field(cx, "Billing email", email)));

    const region = try W.Select(.{ .options = &region_options, .placeholder = "Select region", .width = field_width }, scope, cx);
    tag(region.trigger, "story.formcompose.order.region");
    const priority = try W.Select(.{ .options = &priority_options, .initial_selected = &.{1}, .width = field_width }, scope, cx);
    try card.appendChild(a, try fieldRow(cx, try field(cx, "Region", region.wrapper), try field(cx, "Priority", priority.wrapper)));

    const amount = try W.Input(.{ .placeholder = "0.00", .append_text = "USD", .width = field_width }).mount(scope, cx);
    const due = try W.Input(.{ .placeholder = "YYYY-MM-DD", .leading_icon_asset = ui.assets.common.calendar, .width = field_width }).mount(scope, cx);
    try card.appendChild(a, try fieldRow(cx, try field(cx, "Amount", amount), try field(cx, "Due date", due)));

    const footer = try ui.box(cx, .{
        .width = .{ .grow = .{} },
        .direction = .row,
        .gap = 8,
        .align_items = .center,
        .justify = .end,
        .padding = .{ .top = 16 },
        .border_top_width = t.border_width.thin,
        .border_top_color = t.color.border,
    }, .{});
    try footer.appendChild(a, try W.Button(.{ .label = "Save draft", .variant = .ghost }).mount(scope, cx));
    try footer.appendChild(a, try W.Button(.{ .label = "Cancel", .variant = .secondary }).mount(scope, cx));
    const submit = try W.Button(.{ .label = "Create order", .variant = .primary }).mount(scope, cx);
    tag(submit, "story.formcompose.order.submit");
    try footer.appendChild(a, submit);
    try card.appendChild(a, footer);
    return card;
}

pub fn build(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const a = cx.allocator;
    const root = try ui.box(cx, .{ .direction = .column, .gap = 16 }, .{});
    tag(root, "story.formcompose.root");

    try root.appendChild(a, try heading(cx, "Filter toolbar · same size"));
    try root.appendChild(a, try caption(cx, "Input / Select / Button share ControlSize: XS 20 · SM 24 · MD 32 · LG 40 px"));
    inline for (sizes) |spec| {
        try root.appendChild(a, try filterToolbar(spec, scope, cx));
    }

    try root.appendChild(a, try heading(cx, "Business form · MD"));
    try root.appendChild(a, try orderForm(scope, cx));
    return root;
}

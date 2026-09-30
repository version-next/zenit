//! Interactive Storybook coverage for the real `ui.widgets.Select` component.
//! The visual contract comes from Pencil node `puQEf`; no specimen here is a
//! hand-drawn replacement for the component.

const ui = @import("ui");

const icon_options = [_]ui.widgets.SelectOption{
    .{ .value = "one", .label = "Option 1", .icon = ui.icons.user },
    .{ .value = "two", .label = "Option 2", .icon = ui.icons.settings },
    .{ .value = "three", .label = "Option 3", .icon = ui.icons.globe },
    .{ .value = "four", .label = "Option 4" },
};

const options = [_]ui.widgets.SelectOption{
    .{ .value = "one", .label = "Option 1" },
    .{ .value = "two", .label = "Option 2" },
    .{ .value = "three", .label = "Option 3" },
    .{ .value = "four", .label = "Option 4" },
};

// Searchable specimens in `puQEf` intentionally show a three-row result set.
const search_options = [_]ui.widgets.SelectOption{
    .{ .value = "one", .label = "Option 1" },
    .{ .value = "two", .label = "Option 2" },
    .{ .value = "three", .label = "Option 3" },
};

fn caption(cx: *ui.Cx, value: []const u8) !*ui.Node {
    return ui.text(cx, value, .{
        .font_size = 11,
        .font_weight = 600,
        .line_height = 1.2,
        .color = ui.Color.hex(0x787878),
    });
}

fn specimen(cx: *ui.Cx, label: []const u8) !*ui.Node {
    const node = try ui.box(cx, .{
        .width = .{ .px = 352 },
        .direction = .column,
        .gap = 6,
    }, .{});
    try node.appendChild(cx.allocator, try caption(cx, label));
    return node;
}

fn appendSelect(
    root: *ui.Node,
    label: []const u8,
    props: ui.widgets.SelectProps,
    test_id: []const u8,
    scope: *ui.Scope,
    cx: *ui.Cx,
) !ui.widgets.select.SelectMount {
    const block = try specimen(cx, label);
    const result = try ui.widgets.Select(props, scope, cx);
    result.trigger.meta.ownership.meta.test_id = test_id;
    try block.appendChild(cx.allocator, result.wrapper);
    try root.appendChild(cx.allocator, block);
    return result;
}

pub fn build(scope: *ui.Scope, cx: *ui.Cx) !*ui.Node {
    const root = try ui.box(cx, .{
        .width = .{ .px = 352 },
        .direction = .column,
        .gap = 16,
    }, .{});
    root.meta.ownership.meta.test_id = "story.select.family";
    try root.appendChild(cx.allocator, try ui.text(cx, "Select", .{
        .font_size = 12,
        .font_weight = 600,
        .line_height = 1.2,
        .color = ui.Color.hex(0x1A1A1A),
    }));

    const with_icon = try appendSelect(root, "With icon", .{
        .size = .lg, // puQEf 设计稿为 LG；Select 默认已统一为 md
        .options = &icon_options,
        .leading_icon = ui.icons.globe,
    }, "story.select.with-icon", scope, cx);
    with_icon.panel.meta.ownership.meta.test_id = "story.select.with-icon.panel";
    with_icon.state.chevron_down.meta.ownership.meta.test_id = "story.select.with-icon.chevron";
    for (with_icon.state.option_nodes, 0..) |node, i| {
        node.meta.ownership.meta.test_id = switch (i) {
            0 => "story.select.with-icon.option-1",
            1 => "story.select.with-icon.option-2",
            2 => "story.select.with-icon.option-3",
            else => "story.select.with-icon.option-4",
        };
    }

    const clearable = try appendSelect(root, "Clearable", .{
        .size = .lg, // puQEf 设计稿为 LG；Select 默认已统一为 md
        .options = &options,
        .clearable = true,
        .initial_selected = &.{0},
    }, "story.select.clearable", scope, cx);
    clearable.panel.meta.ownership.meta.test_id = "story.select.clearable.panel";
    clearable.state.clear_button.?.meta.ownership.meta.test_id = "story.select.clear";
    clearable.state.append_slot.meta.ownership.meta.test_id = "story.select.clearable.append";
    clearable.state.append_comp.meta.ownership.meta.test_id = "story.select.clearable.append-comp";
    clearable.state.chevron_slot.meta.ownership.meta.test_id = "story.select.clearable.chevron";
    clearable.state.chevron_up.meta.ownership.meta.test_id = "story.select.clearable.chevron-up";
    clearable.state.chevron_down.meta.ownership.meta.test_id = "story.select.clearable.chevron-down";

    const searchable = try appendSelect(root, "Searchable", .{
        .size = .lg, // puQEf 设计稿为 LG；Select 默认已统一为 md
        .options = &search_options,
        .searchable = true,
        .placeholder = "Search options...",
        .initial_selected = &.{0},
        .show_selected_value_in_search = false,
    }, "story.select.trigger", scope, cx);
    searchable.panel.meta.ownership.meta.test_id = "story.select.panel";
    searchable.state.leading_icon_node.?.meta.ownership.meta.test_id = "story.select.search.icon";
    searchable.state.append_slot.meta.ownership.meta.test_id = "story.select.search.append";
    searchable.state.input_state.?.input_container_node.?.meta.ownership.meta.test_id = "story.select.search.input";
    for (searchable.state.option_nodes, 0..) |node, i| {
        node.meta.ownership.meta.test_id = switch (i) {
            0 => "story.select.search.option-1",
            1 => "story.select.search.option-2",
            2 => "story.select.search.option-3",
            else => unreachable,
        };
    }

    const multi_lg = try appendSelect(root, "Multiple · LG", .{
        .size = .lg, // puQEf 设计稿为 LG；Select 默认已统一为 md
        .options = &options,
        .mode = .multiple,
        .initial_selected = &.{ 0, 1 },
    }, "story.select.multiple-lg", scope, cx);
    multi_lg.panel.meta.ownership.meta.test_id = "story.select.multiple-lg.panel";
    for (multi_lg.state.option_nodes, 0..) |node, i| {
        node.meta.ownership.meta.test_id = switch (i) {
            0 => "story.select.multiple-lg.option-1",
            1 => "story.select.multiple-lg.option-2",
            2 => "story.select.multiple-lg.option-3",
            else => "story.select.multiple-lg.option-4",
        };
    }
    multi_lg.state.tag_nodes[2].meta.ownership.meta.test_id = "story.select.multiple-lg.tag-3";
    multi_lg.state.tag_nodes[2].children.items[1].meta.ownership.meta.test_id = "story.select.multiple-lg.tag-3-close";

    const multi_search_lg = try appendSelect(root, "Multiple searchable · LG", .{
        .size = .lg, // puQEf 设计稿为 LG；Select 默认已统一为 md
        .options = &search_options,
        .mode = .multiple,
        .searchable = true,
        .initial_selected = &.{0},
    }, "story.select.multiple-search-lg", scope, cx);
    multi_search_lg.panel.meta.ownership.meta.test_id = "story.select.multiple-search-lg.panel";
    multi_search_lg.state.content_slot.meta.ownership.meta.test_id = "story.select.multiple-search-lg.content";
    multi_search_lg.state.append_slot.meta.ownership.meta.test_id = "story.select.multiple-search-lg.append";
    multi_search_lg.state.input_state.?.input_container_node.?.meta.ownership.meta.test_id = "story.select.multiple-search-lg.input";
    multi_search_lg.state.option_nodes[2].meta.ownership.meta.test_id = "story.select.multiple-search-lg.option-3";

    const multi_md = try appendSelect(root, "Multiple · MD", .{
        .options = &options,
        .mode = .multiple,
        .size = .md,
        .initial_selected = &.{ 0, 1 },
    }, "story.select.multiple-md", scope, cx);
    multi_md.panel.meta.ownership.meta.test_id = "story.select.multiple-md.panel";

    const multi_search_md = try appendSelect(root, "Multiple searchable · MD", .{
        .options = &search_options,
        .mode = .multiple,
        .size = .md,
        .searchable = true,
        .initial_selected = &.{0},
    }, "story.select.multiple-search-md", scope, cx);
    multi_search_md.panel.meta.ownership.meta.test_id = "story.select.multiple-search-md.panel";
    multi_search_md.state.input_state.?.input_container_node.?.meta.ownership.meta.test_id = "story.select.multiple-search-md.input";
    multi_search_md.state.option_nodes[2].meta.ownership.meta.test_id = "story.select.multiple-search-md.option-3";

    const multi_xs = try appendSelect(root, "Multiple · XS", .{
        .options = &options,
        .mode = .multiple,
        .size = .xs,
        .initial_selected = &.{ 0, 1 },
    }, "story.select.multiple-xs", scope, cx);
    multi_xs.panel.meta.ownership.meta.test_id = "story.select.multiple-xs.panel";

    const multi_search_xs = try appendSelect(root, "Multiple searchable · XS", .{
        .options = &search_options,
        .mode = .multiple,
        .size = .xs,
        .searchable = true,
        .initial_selected = &.{0},
    }, "story.select.multiple-search-xs", scope, cx);
    multi_search_xs.panel.meta.ownership.meta.test_id = "story.select.multiple-search-xs.panel";
    multi_search_xs.state.input_state.?.input_container_node.?.meta.ownership.meta.test_id = "story.select.multiple-search-xs.input";
    multi_search_xs.state.option_nodes[2].meta.ownership.meta.test_id = "story.select.multiple-search-xs.option-3";
    return root;
}

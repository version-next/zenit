//! Control height contract (cross-component): Button / Input / Select /
//! DatePicker / DateRangePicker at same ControlSize have identical outer height =
//! padding_y*2 + font_size*line_height, sized by content, no hardcoded height.
const control_shell = @import("control_shell/mod.zig");
const std = @import("std");
const testing = std.testing;
const core = @import("../core.zig");
const theme = core.theme;
const Cx = core.Cx;
const Scope = core.Scope;
const Node = core.Node;
const button = @import("button/mod.zig");
const input = @import("input/mod.zig");
const select = @import("select/mod.zig");
const date_picker = @import("date_picker/mod.zig");
const date_range_picker = @import("date_range_picker/mod.zig");

const Heights = struct { button: f32, input: f32, select: f32, date: f32, range: f32 };

fn measure(tokens: *const theme.ThemeTokens, size: control_shell.ControlSize) !Heights {
    var ctx = try Cx.init(testing.allocator, std.testing.io);
    defer ctx.deinit();
    ctx.setTheme(tokens);
    ctx.setViewport(900, 600);
    const root = try core.box(ctx, .{ .width = .{ .px = 900 }, .height = .{ .px = 600 }, .direction = .column, .gap = 8 }, .{});
    ctx.root = root;
    const scope = try Scope.init(testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const b = try button.Button(.{ .label = "Button", .size = size }).mount(scope, ctx);
    try root.appendChild(testing.allocator, b);
    const in = try input.Input(.{ .placeholder = "Input", .size = size, .width = 240 }).mountResult(scope, ctx);
    try root.appendChild(testing.allocator, in.node);
    const sel = try select.Select(.{ .placeholder = "Select", .size = size, .width = 240 }).mount(scope, ctx);
    try root.appendChild(testing.allocator, sel.wrapper);
    const dp = try date_picker.DatePicker(.{ .placeholder = "Pick a date", .size = size }).mount(scope, ctx);
    try root.appendChild(testing.allocator, dp.wrapper);
    const dr = try date_range_picker.DateRangePicker(.{ .size = size }).mount(scope, ctx);
    try root.appendChild(testing.allocator, dr.wrapper);
    ctx.layout();

    return .{
        .button = b.rectFromWorldOrFallback().h,
        .input = in.input_container.rectFromWorldOrFallback().h,
        .select = select.stateOf(sel).trigger.rectFromWorldOrFallback().h,
        .date = @as(*date_picker.DatePickerState, @ptrCast(@alignCast(dp.wrapper.meta.ownership.debug_slots.state_ptrs[0].?))).trigger_node.rectFromWorldOrFallback().h,
        .range = @as(*date_range_picker.DateRangePickerState, @ptrCast(@alignCast(dr.wrapper.meta.ownership.debug_slots.state_ptrs[0].?))).trigger_node.rectFromWorldOrFallback().h,
    };
}

fn expectAllEqual(h: Heights, want: f32) !void {
    inline for (.{ "button", "input", "select", "date", "range" }) |f| {
        testing.expectApproxEqAbs(want, @field(h, f), 0.01) catch |err| {
            std.debug.print("control height mismatch: {s} = {d}, want {d}\n", .{ f, @field(h, f), want });
            return err;
        };
    }
}

test "控件高度合同：各尺寸下 Button/Input/Select/DatePicker/DateRangePicker 外框等高 = padding_y×2 + 行高" {
    inline for (.{ control_shell.ControlSize.xs, .sm, .md, .lg }) |size| {
        const h = try measure(&theme.light, size);
        try expectAllEqual(h, control_shell.metrics(&theme.light, size).derivedHeight());
    }
    // Default theme values (visual no fallback)
    try testing.expectEqual(@as(f32, 32), control_shell.metrics(&theme.light, .md).derivedHeight());
    try testing.expectEqual(@as(f32, 40), control_shell.metrics(&theme.light, .lg).derivedHeight());
}

test "控件高度合同：改基础 font_size，所有控件高度一起跟着变（证明未写死）" {
    var custom = theme.light;
    // LKxqO: all sizes use font_size.md, control line-height 1.2, md padding 8.2.
    custom.tokens.font_size.md = 18;
    const want: f32 = 18 * 1.2 + 8.2 * 2;
    const h = try measure(&custom, .md);
    try expectAllEqual(h, want);
}

test "shell recipe preserves all measurements for every size and mode" {
    // LKxqO controls; lg outer height follows Foundations (40px).
    const expected = [_]control_shell.ControlMetrics{
        .{ .font_size = 13, .line_height = 1.2, .radius = 6, .padding_y = 2.2, .padding_h = 12, .padding_leading_icon = 10, .icon_size = 15.6, .gap = 8 },
        .{ .font_size = 13, .line_height = 1.2, .radius = 6, .padding_y = 4.2, .padding_h = 12, .padding_leading_icon = 10, .icon_size = 15.6, .gap = 8 },
        .{ .font_size = 13, .line_height = 1.2, .radius = 6, .padding_y = 8.2, .padding_h = 12, .padding_leading_icon = 10, .icon_size = 15.6, .gap = 8 },
        .{ .font_size = 13, .line_height = 1.2, .radius = 6, .padding_y = 12.2, .padding_h = 16, .padding_leading_icon = 14, .icon_size = 15.6, .gap = 8 },
    };
    inline for (.{ &theme.light, &theme.dark, &theme.high_contrast }) |tokens| {
        inline for (.{ control_shell.ControlSize.xs, .sm, .md, .lg }, expected) |size, want| {
            try testing.expectEqualDeep(want, control_shell.metrics(tokens, size));
        }
    }
}

test "shell geometry adapts to material scales and keeps icons inside the line box" {
    var custom = theme.light;
    custom.tokens.space.space300 = 17;
    custom.tokens.space.space50 = 3;
    // LKxqO: shell radius follows the control role, not the legacy xl scale.
    custom.tokens.radius.control = 11;
    custom.tokens.size.md = 30;
    const m = control_shell.metrics(&custom, .md);
    try testing.expectEqual(@as(f32, 17), m.padding_h);
    try testing.expectEqual(@as(f32, 14), m.padding_leading_icon);
    try testing.expectEqual(@as(f32, 11), m.radius);
    try testing.expectEqual(m.lineHeightPx(), m.icon_size);
    try expectAllEqual(try measure(&custom, .md), 32);
}

test "Yix components: theme follow dies with the component scope after root scope rebinding" {
    const badge = @import("badge/mod.zig");
    const tag = @import("tag/mod.zig");
    inline for (.{ badge.Badge(.{ .label = "Badge" }), badge.StatusBadge(.{ .label = "Status" }), tag.Tag(.{ .label = "Tag", .closable = true }) }) |element| {
        var ctx = try Cx.init(testing.allocator, std.testing.io);
        defer ctx.deinit();
        const outer = try Scope.init(testing.allocator, null, ctx.owner);
        defer outer.dispose();
        const node = try element.mount(outer, ctx);
        ctx.root = node;
        const state_scope = node.meta.ownership.scope.scope.?;
        try core.bindScopeToNode(outer, node);
        // Runtime style theme-follow is component scope effect; any on_theme on node
        // only from compile-time constant styles, no component state. After state scope
        // destroyed, theme switch can't touch freed state.
        state_scope.dispose();
        ctx.setTheme(&theme.dark);
        ctx.setTheme(&theme.light);
    }
}

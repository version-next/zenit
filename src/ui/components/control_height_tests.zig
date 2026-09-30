//! 控件高度合同（跨组件）：同一 ControlSize 下 Button / Input / Select /
//! DatePicker / DateRangePicker 的外框高度完全一致，且等于
//! padding_y × 2 + font_size × line_height —— 由内容撑出，没有任何控件写死 height。
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

fn measure(tokens: *const theme.ThemeTokens, size: theme.ControlSize) !Heights {
    var ctx = try Cx.init(testing.allocator);
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
    const sel = try select.mountSelect(.{ .placeholder = "Select", .size = size, .width = 240 }, scope, ctx);
    try root.appendChild(testing.allocator, sel.wrapper);
    const dp = try date_picker.DatePicker(.{ .placeholder = "Pick a date", .size = size }).mount(scope, ctx);
    try root.appendChild(testing.allocator, dp.wrapper);
    const dr = try date_range_picker.DateRangePicker(.{ .size = size }).mount(scope, ctx);
    try root.appendChild(testing.allocator, dr.wrapper);
    ctx.layout();

    return .{
        .button = b.rectFromWorldOrFallback().h,
        .input = in.input_container.rectFromWorldOrFallback().h,
        .select = sel.state.trigger.rectFromWorldOrFallback().h,
        .date = dp.state.trigger_node.rectFromWorldOrFallback().h,
        .range = dr.state.trigger_node.rectFromWorldOrFallback().h,
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
    inline for (.{ theme.ControlSize.xs, .sm, .md, .lg }) |size| {
        const h = try measure(&theme.light, size);
        try expectAllEqual(h, theme.light.control.get(size).derivedHeight());
    }
    // 默认主题数值（视觉不回退）
    try testing.expectEqual(@as(f32, 32), theme.light.control.get(.md).derivedHeight());
    try testing.expectEqual(@as(f32, 40), theme.light.control.get(.lg).derivedHeight());
}

test "控件高度合同：改 font_size / line_height / padding_y，所有控件高度一起跟着变（证明未写死）" {
    var custom = theme.light;
    custom.control.md.font_size = 18;
    custom.control.md.line_height = 1.5;
    custom.control.md.padding_y = 9;
    const want: f32 = 18 * 1.5 + 9 * 2; // 45
    const h = try measure(&custom, .md);
    try expectAllEqual(h, want);
}

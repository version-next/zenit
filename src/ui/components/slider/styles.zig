//! Slider 样式层，轨道/填充/thumb 的样式声明（几何随 props 参数化）。
const core = @import("../../core.zig");
const Color = core.Color;
const SliderProps = @import("mod.zig").SliderProps;

pub fn trackStyle(p: SliderProps, t: *const core.ThemeTokens) core.BoxStyle {
    return .{
        .width = .{ .grow = .{} },
        .height = .{ .px = p.track_height },
        .background = t.color.bg_tertiary,
        .border = .{ .radius = p.track_height / 2 },
    };
}

pub fn fillStyle(p: SliderProps, accent: Color, ratio: f32) core.BoxStyle {
    return .{
        .width = .{ .percent = ratio * 100 },
        .height = .{ .px = p.track_height },
        .background = accent,
        .border = .{ .radius = p.track_height / 2 },
    };
}

pub fn thumbStyle(p: SliderProps, accent: Color, t: *const core.ThemeTokens) core.BoxStyle {
    return .{
        .position = .absolute,
        .width = .{ .px = p.thumb_size },
        .height = .{ .px = p.thumb_size },
        .background = if (p.disabled) t.color.fg_disabled else Color.hex(0xffffff),
        .border = .{ .radius = p.thumb_size / 2, .width = 2, .color = accent },
        // 拖拽手柄阴影：比通用 shadow.sm 更实一点，让 thumb 从轨道上"浮起"。
        // 小尺寸悬浮控件用更高不透明度 + 紧凑 blur，避免在浅色轨道上糊成一团看不见。
        .shadow = .{ .color = Color.rgba(0, 0, 0, 56), .blur = 3, .offset_x = 0, .offset_y = 1 },
    };
}

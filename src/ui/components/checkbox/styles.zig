//! Checkbox/Radio/Switch 样式层，recipe 条件声明 + 具名样式函数
//! 业务逻辑（State/Builder/mount/事件/动画进度计算）在 mod.zig。
const core = @import("../../core.zig");
const theme = core.theme;
const Color = core.Color;
const ConditionalStyle = core.ConditionalStyle;
const StyleOverride = core.StyleOverride;
const recipe_mod = @import("../../recipe.zig");

// ==================== CheckboxRecipe, checked/disabled 的声明式来源 ====================
//
// checked 用 ConditionalStyle 的 `selected` 条件位表达（selected 与 checked
// 合一，见 InteractionState.is_selected）。唯一静态表达不了的是
// disabled×checked 二维组合：resolve() 里 disabled 短路、不再叠加 selected，
// 所以 disabled+checked 的差异色（checkbox_disabled_checked_bg）留在
// CheckboxColors 的最小分支里，并注明缘由。

pub const CheckboxRecipe = recipe_mod.recipe(struct {
    /// 无变体维度，状态全部由条件位承载；将来加 size/variant 从这里扩展。
    pub const Variants = struct {};

    pub fn base(t: *const theme.ThemeTokens) ConditionalStyle {
        return .{
            .base = .{
                .background = t.color.checkbox_bg,
                .border_color = t.color.checkbox_border,
                .text_color = t.color.fg_primary,
            },
            .selected = .{
                .background = t.color.accent,
                .border_color = t.color.accent,
            },
            .disabled = .{
                .background = t.color.checkbox_disabled_bg,
                .border_color = t.color.checkbox_disabled_border,
                .text_color = t.color.fg_secondary,
            },
        };
    }
});

/// Checkbox/Radio 颜色访问器，单一取色源是 CheckboxRecipe；
/// 本层只保留 recipe 表达不了的 disabled×checked 二维分支。
/// （签名保持 (checked, disabled)，mount 与运行时更新点共用。）
pub const CheckboxColors = struct {
    fn resolved(t: *const theme.ThemeTokens, checked: bool, disabled: bool) StyleOverride {
        return CheckboxRecipe.resolve(.{}, t)
            .resolve(.{ .is_selected = checked, .is_disabled = disabled });
    }

    /// 方框/圆圈背景色
    pub fn background(t: *const theme.ThemeTokens, checked: bool, disabled: bool) Color {
        // disabled 在 resolve 里短路吞掉 selected -> disabled+checked 差异色只能在此分支
        if (disabled and checked) return t.color.checkbox_disabled_checked_bg;
        return resolved(t, checked, disabled).background.?;
    }

    /// 方框/圆圈边框色
    pub fn borderColor(t: *const theme.ThemeTokens, checked: bool, disabled: bool) Color {
        if (disabled and checked) return t.color.checkbox_disabled_checked_bg;
        return resolved(t, checked, disabled).border_color.?;
    }

    /// 标签文字色
    pub fn labelColor(t: *const theme.ThemeTokens, disabled: bool) Color {
        return resolved(t, false, disabled).text_color.?;
    }
};

// ==================== SwitchRecipe + SwitchColors ====================
//
// 离散端点（off/on = base/selected 条件）由 SwitchRecipe 按 slot 声明；
// track/thumb/label 颜色随 thumb 位移进度 (0..1) 在两端点间连续插值,
// 插值本身不是离散条件，保留 lerp 辅助函数，但端点色一律取自 recipe，
// 保证单一取色源；updateSwitchThumbPosition 只做进度计算。

pub const SwitchRecipe = recipe_mod.slotRecipe(struct {
    pub const Slots = struct {
        track: ConditionalStyle = .{},
        thumb: ConditionalStyle = .{},
        label: ConditionalStyle = .{},
    };
    pub const Variants = struct {};

    pub fn base(t: *const theme.ThemeTokens) Slots {
        return .{
            .track = .{
                .base = .{ .background = t.color.switch_track_off },
                .selected = .{ .background = t.color.accent },
            },
            .thumb = .{
                .base = .{ .background = t.color.switch_thumb },
                // on 态 thumb 刻意固定白色不随主题（与 switch_thumb off 色区分）
                .selected = .{ .background = Color.hex(0xFFFFFF) },
            },
            .label = .{
                .base = .{ .text_color = t.color.fg_secondary },
                .selected = .{ .text_color = t.color.fg_primary },
            },
        };
    }
});

pub const SwitchColors = struct {
    /// off/on 端点对（0 = base 态，1 = selected 态）
    fn endpoints(cs: ConditionalStyle) struct { off: StyleOverride, on: StyleOverride } {
        return .{
            .off = cs.resolve(.{}),
            .on = cs.resolve(.{ .is_selected = true }),
        };
    }

    /// on 态 thumb 色（recipe thumb slot 的 selected 端点）
    pub fn thumbOn(t: *const theme.ThemeTokens) Color {
        return SwitchRecipe.resolve(.{}, t).thumb
            .resolve(.{ .is_selected = true }).background.?;
    }

    /// track 颜色（progress: 0=off, 1=on）
    pub fn track(t: *const theme.ThemeTokens, progress: f32) Color {
        const e = endpoints(SwitchRecipe.resolve(.{}, t).track);
        return Color.lerp(e.off.background.?, e.on.background.?, progress);
    }

    /// thumb 颜色（progress: 0=off, 1=on）
    pub fn thumb(t: *const theme.ThemeTokens, progress: f32) Color {
        const e = endpoints(SwitchRecipe.resolve(.{}, t).thumb);
        return Color.lerp(e.off.background.?, e.on.background.?, progress);
    }

    /// 标签颜色（progress: 0=off, 1=on）
    pub fn label(t: *const theme.ThemeTokens, progress: f32) Color {
        const e = endpoints(SwitchRecipe.resolve(.{}, t).label);
        return Color.lerp(e.off.text_color.?, e.on.text_color.?, progress);
    }

    /// disabled track：向 bg_primary 方向压淡
    /// （disabled×checked 二维 + 连续阻尼系数，recipe 条件位之外的最小函数）
    pub fn disabledTrack(t: *const theme.ThemeTokens, checked: bool) Color {
        return Color.lerp(
            track(t, if (checked) 1 else 0),
            t.color.bg_primary,
            if (checked) 0.32 else 0.22,
        );
    }

    /// disabled thumb：向 bg_primary 方向压淡
    pub fn disabledThumb(t: *const theme.ThemeTokens, checked: bool) Color {
        return Color.lerp(thumb(t, if (checked) 1 else 0), t.color.bg_primary, 0.18);
    }
};

// ==================== 具名样式函数，mount 逻辑只消费这些声明 ====================

/// Checkbox/Radio/Switch 共用的外层行容器（控件 + 标签）
pub fn controlRowStyle() core.BoxStyle {
    return .{
        .width = .{ .fit = .{} },
        .height = .{ .fit = .{} },
        .direction = .row,
        .gap = 8,
        .align_items = .center,
    };
}

/// 复选框方框（18×18, 1.5px 边框, 4px 圆角）
pub fn checkboxBoxStyle(t: *const theme.ThemeTokens, effectively_checked: bool, disabled: bool) core.BoxStyle {
    return .{
        .width = .{ .px = 18 },
        .height = .{ .px = 18 },
        .background = CheckboxColors.background(t, effectively_checked, disabled),
        .border = .{
            .width = 1.5,
            .color = CheckboxColors.borderColor(t, effectively_checked, disabled),
            .radius = 4,
        },
        .justify = .center,
        .align_items = .center,
    };
}

/// checkmark / indeterminate 图标尺寸（14×14），iconTint 消费，故为 Style
pub fn checkIconStyle() core.Style {
    return .{ .width = .{ .px = 14 }, .height = .{ .px = 14 } };
}

/// indeterminate 覆盖层（absolute, 与方框同尺寸, 居中）
pub fn indetOverlayStyle() core.BoxStyle {
    return .{
        .position = .absolute,
        .width = .{ .px = 18 },
        .height = .{ .px = 18 },
        .justify = .center,
        .align_items = .center,
    };
}

/// Checkbox/Radio/Switch 标签文本
pub fn controlLabelStyle(t: *const theme.ThemeTokens, disabled: bool) core.TextProps {
    return .{
        .content = "",
        .color = CheckboxColors.labelColor(t, disabled),
        .font_size = 14,
    };
}

/// Radio 圆圈（18×18, 1.5px 边框, 全圆角）
pub fn radioCircleStyle(t: *const theme.ThemeTokens, checked: bool) core.BoxStyle {
    return .{
        .width = .{ .px = 18 },
        .height = .{ .px = 18 },
        // Radio 的 disabled 态保留正常 checked/unchecked 颜色，只用整体 opacity 降级
        .background = CheckboxColors.background(t, checked, false),
        .border = .{
            .width = 1.5,
            .color = CheckboxColors.borderColor(t, checked, false),
            .radius = 9,
        },
        .justify = .center,
        .align_items = .center,
    };
}

/// Radio 内部圆点（9×9 白点）
pub fn radioDotStyle(t: *const theme.ThemeTokens) core.BoxStyle {
    return .{
        .width = .{ .px = 9 },
        .height = .{ .px = 9 },
        .background = t.color.fg_inverse,
        .border = .{ .radius = 4.5 },
    };
}

/// RadioGroup 容器（横排 16 间距 / 竖排 8 间距）
pub fn radioGroupContainerStyle(horizontal: bool) core.BoxStyle {
    return .{
        .direction = if (horizontal) core.Direction.row else core.Direction.column,
        .gap = if (horizontal) 16 else 8,
        .height = .{ .fit = .{} },
    };
}

/// Switch 轨道（40×22, 全圆角）
pub fn switchTrackStyle(t: *const theme.ThemeTokens, checked: bool) core.BoxStyle {
    return .{
        .position = .relative,
        .width = .{ .px = 40 },
        .height = .{ .px = 22 },
        .background = SwitchColors.track(t, if (checked) 1 else 0),
        .border = .{ .radius = 11 },
    };
}

/// Switch thumb（18×18 圆, absolute, translate_x 控制左右）
pub fn switchThumbStyle(t: *const theme.ThemeTokens, checked: bool, init_translate: f32) core.BoxStyle {
    return .{
        .position = .absolute,
        .width = .{ .px = 18 },
        .height = .{ .px = 18 },
        .background = SwitchColors.thumb(t, if (checked) 1 else 0),
        .border = .{ .radius = 9 },
        .translate_x = init_translate,
        .translate_y = 2,
        .shadow = .{ .color = Color.rgba(0, 0, 0, 32), .blur = 2, .offset_x = 0, .offset_y = 1 },
    };
}

/// Switch 标签（disabled 恒 fg_secondary；否则随开关态 off/on 取色）
pub fn switchLabelStyle(t: *const theme.ThemeTokens, checked: bool, disabled: bool) core.TextProps {
    return .{
        .content = "",
        .color = if (disabled) t.color.fg_secondary else SwitchColors.label(t, if (checked) 1 else 0),
        .font_size = 14,
    };
}

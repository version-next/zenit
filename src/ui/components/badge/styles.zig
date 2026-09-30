//! Badge 样式层 — BadgeRecipe + dot/StatusBadge 具名样式函数
//! 业务逻辑在 mod.zig；BadgeStatus/BadgeSize 是公共 API，循环 import 取用。
const core = @import("../../core.zig");
const theme = core.theme;
const Color = core.Color;
const ConditionalStyle = core.ConditionalStyle;
const recipe_mod = @import("../../recipe.zig");
const mod = @import("mod.zig");

const BadgeStatus = mod.BadgeStatus;
const BadgeSize = mod.BadgeSize;

// ============================================================================
// BadgeRecipe — recipe(status × size) 统一管理两个维度
//
// base:        字重（状态/尺寸无关）
// status 维度: 提供 background / text_color
// derived:     height / padding / font_size（几何，来自 BadgeSize spec 方法）
//
// pill 圆角 = height/2 在 mount 里从 resolved 高度折算进 Border。
// ============================================================================
pub const BadgeRecipe = recipe_mod.recipe(struct {
    pub const Variants = struct {
        status: BadgeStatus = .info,
        size: BadgeSize = .md,
    };

    pub fn base(_: *const theme.ThemeTokens) ConditionalStyle {
        return .{ .base = .{ .font_weight = 600 } };
    }

    pub const variants = .{
        .status = struct {
            fn resolve(s: BadgeStatus, t: *const theme.ThemeTokens) ConditionalStyle {
                return .{
                    .base = .{
                        .background = switch (s) {
                            .info => t.color.accent,
                            .success => t.color.success,
                            .warning => t.color.warning,
                            .@"error" => t.color.danger,
                        },
                        .text_color = switch (s) {
                            .info, .success, .warning => t.color.button_primary_fg,
                            .@"error" => Color.hex(0xffffff),
                        },
                        // pill 圆角固定 999，mount 里用 height/2 覆盖以精确匹配
                        .corner_radius = 999,
                    },
                };
            }
        }.resolve,
    };

    /// 跨维度几何 — 只产出几何字段，禁碰 background
    pub fn derived(v: Variants, _: *const theme.ThemeTokens) ConditionalStyle {
        return .{ .base = .{
            .height = .{ .px = v.size.height() },
            .padding = v.size.padding(),
            .font_size = v.size.fontSize(),
        } };
    }
});

// ============================================================================
// 具名样式函数 — dot 模式与 StatusBadge 的静态样式
// ============================================================================

/// 8×8 状态圆点（Badge dot 模式与 StatusBadge 共用）
pub fn badgeDotStyle(bg: Color) core.BoxStyle {
    return .{
        .width = .{ .px = 8 },
        .height = .{ .px = 8 },
        .background = bg,
        .border = .{ .radius = 4 },
    };
}

/// StatusBadge 外层行容器
pub fn statusBadgeContainerStyle() core.BoxStyle {
    return .{
        .width = .{ .fit = .{} },
        .height = .{ .fit = .{} },
        .direction = .row,
        .gap = 6,
        .align_items = .center,
    };
}

/// StatusBadge 标签文本
pub fn statusBadgeLabelStyle(t: *const theme.ThemeTokens) core.TextProps {
    return .{
        .content = "",
        .color = t.color.fg_primary,
        .font_size = 12,
    };
}

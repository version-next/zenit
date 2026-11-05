// GENERATED FILE, do not edit: generated from styles.yss; after editing the source run `zig build gen-yix` (yix-lsp regenerates it on save).
/// Skeleton styles: skeleton block shape determined by variant and size, shimmer is sinusoidal
/// cycle over time between base and highlight color.
/// View in skeleton.yix; SkeletonVariant is public API defined in mod.zig.
const ui = @import("../../ui.zig");
const core = @import("../../core.zig");
const theme = core.theme;
const Color = core.Color;
const std = @import("std");
const mod = @import("mod.zig");

/// Multiple skeleton blocks stacked vertically
pub const stack = ui.paramStyle(struct { gap: f32, pub const declared = &[_][]const u8{ "no_cross_stretch", "width", "height", "direction", "gap", }; pub fn resolve(args: @This(), t: *const ui.theme.Values) ui.BoxStyle { return ui.boxFrom(.{ .no_cross_stretch = true, .width = .fit, .height = .fit, .direction = .column, .gap = args.gap, }, t); } });

/// Skeleton block: circle takes width as side length; static background is shimmer's base color
/// (see baseColor)
pub const bone = ui.paramStyle(struct { variant: mod.SkeletonVariant, width: f32, height: f32, pub const declared = &[_][]const u8{ "width", "height", "background", "corner_radius", }; pub fn resolve(args: @This(), t: *const ui.theme.Values) ui.BoxStyle { var out = ui.boxFrom(.{ .width = args.width, .height = args.height, .background = ui.tokenRef(.color, "skeleton"), }, t); if (args.variant == .text) out = out.merge(ui.boxFrom(.{ .corner_radius = ui.tokenRef(.radius, "md"), }, t)); if (args.variant == .circular) out = out.merge(ui.boxFrom(.{ .height = args.width, .corner_radius = ui.tokenRef(.radius, "dialog"), }, t)); if (args.variant == .rectangular) out = out.merge(ui.boxFrom(.{ .corner_radius = ui.tokenRef(.radius, "md"), }, t)); return out; } });

/// Shimmer one full cycle duration (hand-written version is 120 frames at 60fps = 2s)
pub const shimmer_period_ms: f32 = 2000;

/// Base color <-> highlight color sinusoidal cycle
pub fn shimmer(phase: f32, t: *const theme.ThemeTokens) ui.BoxStyle {
    const k = (1.0 + @sin(phase * std.math.pi * 2.0)) * 0.5;
    return .{ .background = Color.lerp(baseColor(t), highlightColor(t), k) };
}

fn baseColor(t: *const theme.ThemeTokens) Color {
    return t.tokens.color.skeleton;
}

fn highlightColor(t: *const theme.ThemeTokens) Color {
    return Color.lerp(t.tokens.color.skeleton, t.tokens.color.bg_primary, 0.25);
}

//# yix-map styles.yss

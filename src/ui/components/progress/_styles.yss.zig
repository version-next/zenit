// GENERATED FILE, do not edit: generated from styles.yss; after editing the source run `zig build gen-yix` (yix-lsp regenerates it on save).
//! Progress styles and rendering: state color, track, determined mode fill (vertical three-stop
//! gradient), undetermined mode gloss bar (sweeps left-right per frame clock; see `barAt`). View in
//! progress.yix.
const std = @import("std");
const math = std.math;
const ui = @import("../../ui.zig");
const core = @import("../../core.zig");
const theme = core.theme;
const Color = core.Color;
const ProgressStatus = @import("mod.zig").ProgressStatus;

const white = Color.rgba(255, 255, 255, 255);
const black = Color.rgba(0, 0, 0, 255);

/// State -> semantic fill color.
pub fn statusColor(s: ProgressStatus, t: *const theme.ThemeTokens) Color {
    const base = switch (s) {
        .normal => t.tokens.color.accent,
        .success => t.tokens.color.success,
        .@"error" => t.tokens.color.danger,
    };
    return base;
}

/// Outer: track + percentage text horizontal; fill full width if no width given
pub const container = ui.paramStyle(struct { width: ?f32, pub const declared = &[_][]const u8{ "width", "height", "direction", "align_items", "gap", }; pub fn resolve(args: @This(), t: *const ui.theme.Values) ui.BoxStyle { return ui.boxFrom(.{ .width = ui.orElse(args.width, .{ .grow = .{} }), .height = .fit, .direction = .row, .align_items = .center, .gap = 8, }, t); } });

/// Track: rounded capsule, clip filled / gloss bar
pub const track = ui.paramStyle(struct { height: f32, pub const declared = &[_][]const u8{ "width", "height", "background", "corner_radius", "overflow_hidden", }; pub fn resolve(args: @This(), t: *const ui.theme.Values) ui.BoxStyle { return ui.boxFrom(.{ .width = .{ .grow = .{} }, .height = args.height, .background = ui.tokenRef(.color, "progress-track"), .corner_radius = ui.tokenRef(.radius, "md"), .overflow_hidden = true, }, t); } });

/// Determined mode fill: capsule per percentage width; color see fillGradient
pub const fill = ui.paramStyle(struct { percent: f32, height: f32, pub const declared = &[_][]const u8{ "width", "height", "corner_radius", }; pub fn resolve(args: @This(), t: *const ui.theme.Values) ui.BoxStyle { return ui.boxFrom(.{ .width = .{ .percent = args.percent }, .height = args.height, .corner_radius = ui.tokenRef(.radius, "md"), }, t); } });

/// Determinate fill stays flat at the semantic state color.
pub fn fillGradient(status: ProgressStatus, t: *const theme.ThemeTokens) ui.BoxStyle {
    const c = statusColor(status, t);
    const stops = [_]core.GradientStop{
        .{ .color = c, .position = 0.0 },
        .{ .color = c, .position = 0.5 },
        .{ .color = c, .position = 1.0 },
    };
    return .{ .multi_gradient = core.MultiGradient.fromSlice(&stops, .vertical) };
}

/// Undetermined mode draw node fills track
pub const sweep_area = ui.previewCss("src/ui/components/progress/styles.yss", "sweep_area", @embedFile("styles.yss"), .{ .width = .{ .grow = .{} }, .height = .{ .grow = .{} }, });

pub const percent_text = ui.previewCss("src/ui/components/progress/styles.yss", "percent_text", @embedFile("styles.yss"), .{ .color = ui.tokenRef(.color, "fg-secondary"), .font_size = ui.tokenRef(.font_size, "sm"), });

// -- Undetermined mode: gloss bar --

/// One sweep duration (seconds)
pub const cycle_seconds: f32 = 2.0;

pub const Bar = struct { status: ProgressStatus, height: f32 };

/// Quintic smoothstep (approx cubic-bezier(0.65, 0, 0.35, 1): mid fast, ends slow)
fn ease(t: f32) f32 {
    const t2 = t * t;
    const t3 = t2 * t;
    return 6.0 * t2 * t3 - 15.0 * t2 * t2 + 10.0 * t3;
}

pub const Edges = struct { left: f32, right: f32 };

/// Gloss bar left and right edges at time now_ms (relative track width 0~1). Right leads, left
/// lags; time difference creates width change: entry expand -> mid widest -> exit contract. Depends
/// only on absolute time, framerate-independent.
pub fn barAt(now_ms: f64) Edges {
    const cycle_ms: f64 = cycle_seconds * 1000.0;
    const p: f32 = @floatCast(@mod(now_ms, cycle_ms) / cycle_ms);
    return .{
        .left = ease(math.clamp((p - 0.2) / 0.9, 0, 1)),
        .right = ease(math.clamp((p + 0.1) / 0.9, 0, 1)),
    };
}

/// Gloss bar: horizontal three-stop gradient, peak (white mix 35%) left-biased, right decays to
/// dark (black mix 15%)
pub fn drawBar(ctx: ui.DrawContext, b: Bar, frame: ui.view.Frame) anyerror!void {
    const e = barAt(frame.now_ms);
    const left = e.left * ctx.render_w;
    const w = e.right * ctx.render_w - left;
    if (w < 0.5) return; // Too small not to draw
    const dl = ctx.display_list orelse return;
    const header = ctx.display_header orelse return;
    const c = statusColor(b.status, frame.tokens);
    var colors = @as([16]Color, @splat(Color.rgba(0, 0, 0, 0)));
    var positions = @as([16]f32, @splat(0));
    colors[0] = Color.lerp(c, white, 0.35);
    colors[1] = c;
    colors[2] = Color.lerp(c, black, 0.15);
    positions[1] = 0.55;
    positions[2] = 1.0;
    const r = b.height / 2;
    try dl.append(.{ .multi_gradient_rect = .{
        .header = header,
        .x = left,
        .y = 0,
        .w = w,
        .h = ctx.local_h,
        .direction = .horizontal,
        .radius = .{ r, r, r, r },
        .stop_colors = colors,
        .stop_positions = positions,
        .stop_count = 3,
    } });
}

//# yix-map styles.yss

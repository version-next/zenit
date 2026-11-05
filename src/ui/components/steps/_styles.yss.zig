// GENERATED FILE, do not edit: generated from styles.yss; after editing the source run `zig build gen-yix` (yix-lsp regenerates it on save).
//! Steps styling: circles / numbers / titles / connectors change appearance by step state (done /
//! current); horizontal and vertical layouts share the same structure.
//! Views in steps.yix; StepItem / StepsDirection are public API, defined in mod.zig.
const core = @import("../../core.zig");
const ui = @import("../../ui.zig");
const mod = @import("mod.zig");

pub const circle_size: f32 = 24;
/// Min length of vertical connector line (also min vertical spacing between steps)
pub const v_connector_min: f32 = 24;

/// One step: circle with number (number text or checkmark icon); num is the number within circle;
/// icon is checkmark; title is the label; connector is the line to next step in vertical layout
/// (grow fills remaining height below circle). Done and current steps have accent color circles;
/// current step title is primary color + bold, done step accent, others secondary.
pub const Step = ui.sva(.{ .slots = .{ .circle, .num, .icon, .title, .connector, }, .base = .{ .circle = .{ .width = 24, .height = 24, .corner_radius = 12, .justify = .center, .align_items = .center, .background = ui.tokenRef(.color, "bg-secondary"), .border_overlay = true, .border_width = 1, .border_color = ui.tokenRef(.color, "border-strong"), }, .num = .{ .color = ui.tokenRef(.color, "fg-secondary"), .font_size = ui.tokenRef(.font_size, "sm"), .font_weight = 600, .text_align = .center, .line_height = 1.4, }, .icon = .{ .width = 14, .height = 14, .icon_color = ui.tokenRef(.color, "status-fg"), }, .title = .{ .color = ui.tokenRef(.color, "fg-secondary"), .font_size = ui.tokenRef(.font_size, "sm"), .font_weight = 400, .line_height = 1.4, }, .connector = .{ .width = 1, .height = .{ .grow = .{ .min = v_connector_min } }, .background = ui.tokenRef(.color, "border"), }, }, .variants = .{ .completed = .{ .false = .{ }, .true = .{ .circle = .{ .background = ui.tokenRef(.color, "accent"), .border_overlay = true, .border_width = 0, }, .num = .{ .color = ui.tokenRef(.color, "status-fg"), }, .title = .{ .color = ui.tokenRef(.color, "fg-secondary"), }, .connector = .{ .background = ui.tokenRef(.color, "accent"), }, }, }, .active = .{ .false = .{ }, .true = .{ .circle = .{ .background = ui.tokenRef(.color, "accent"), .border_overlay = true, .border_width = 0, }, .num = .{ .color = ui.tokenRef(.color, "status-fg"), }, .title = .{ .color = ui.tokenRef(.color, "fg-primary"), .font_weight = 600, }, }, }, }, .defaults = .{ .completed = false, .active = false, }, });

pub const desc = ui.previewCss("src/ui/components/steps/styles.yss", "desc", @embedFile("styles.yss"), .{ .color = ui.tokenRef(.color, "fg-secondary"), .font_size = ui.tokenRef(.font_size, "xs"), });

/// Container: fills horizontal row (equal width per step), vertical follows content
pub const Container = ui.previewCva("src/ui/components/steps/styles.yss", "Container", @embedFile("styles.yss"), .{ .base = .{ .height = .fit, .gap = 0, }, .variants = .{ .horizontal = .{ .false = .{ .width = .fit, .direction = .column, .no_cross_stretch = true, }, .true = .{ .width = .{ .grow = .{} }, .direction = .row, .align_self = .stretch, }, }, }, .defaults = .{ .horizontal = false, }, });

// Equal step cells are intentional; CSS auto basis would weight them by label content.
pub const h_step = ui.previewCss("src/ui/components/steps/styles.yss", "h_step", @embedFile("styles.yss"), .{ .width = .{ .grow = .{} }, .flex_basis = 0, .min_width = 0, .height = .fit, .direction = .column, .align_items = .center, .gap = 6, });
/// Vertical row: align_items = start pins circle to top (centering would lower last step
/// circle, breaking from prior connector)
pub const v_step = ui.previewCss("src/ui/components/steps/styles.yss", "v_step", @embedFile("styles.yss"), .{ .no_cross_stretch = true, .width = .fit, .height = .fit, .direction = .row, .align_items = .start, .gap = 4, });
/// Indicator column fills row height; connector (grow) fills space below circle; line bottom
/// meets next step circle top
pub fn vIndicator(t: *const core.ThemeTokens) core.BoxStyle {
    return .{ .width = .{ .fit = .{} }, .height = .{ .grow = .{} }, .align_self = .stretch, .direction = .column, .align_items = .center,
        .translate_y = @max(0, (t.tokens.font_size.sm * 1.4 - circle_size) / 2) };
}

/// Vertical text column: top margin centers title first line with circle (row uses
/// align_items = start, circle pinned to top); margin based on theme font size
pub fn vText(t: *const core.ThemeTokens) core.BoxStyle {
    // mjlUR: label typography uses 1.4 line height, including vertical alignment.
    const title_line_h = t.tokens.font_size.sm * 1.4;
    return .{ .width = .{ .fit = .{} }, .height = .{ .fit = .{} }, .direction = .column, .align_items = .start, .gap = 2, .padding = .{ .top = @max(0, (circle_size - title_line_h) / 2) } };
}

/// Horizontal connector: track from first circle center to last (each step equal width,
/// center at midpoint). left/right inset only stretch when width = grow (default fit parses as
/// 0 width, line not drawn)
pub const track = ui.paramStyle(struct { steps: usize, pub const declared = &[_][]const u8{ "position", "width", "height", "background", "inset", }; pub fn resolve(args: @This(), t: *const ui.theme.Values) ui.BoxStyle { return ui.boxFrom(.{ .position = .absolute, .width = .{ .grow = .{} }, .height = 1, .background = ui.tokenRef(.color, "border-strong"), .inset = lineInset(args.steps, args.steps -| 1), }, t); } });

/// Completed segment: from first circle center to current circle center (stops at last if past
/// end; not shown when current = 0)
pub const progress = ui.paramStyle(struct { steps: usize, current: usize, pub const declared = &[_][]const u8{ "position", "width", "height", "background", "inset", "display", }; pub fn resolve(args: @This(), t: *const ui.theme.Values) ui.BoxStyle { var out = ui.boxFrom(.{ .position = .absolute, .width = .{ .grow = .{} }, .height = 1, .background = ui.tokenRef(.color, "accent"), .inset = lineInset(args.steps, @min(args.current, args.steps -| 1)), }, t); if (@min(args.current, args.steps -| 1) == 0) out = out.merge(ui.boxFrom(.{ .display = .none, }, t)); return out; } });

/// Horizontal line position from first circle center to circle #reached (0-indexed)
fn lineInset(n: usize, reached: usize) core.Inset {
    const half = halfStepPct(n);
    const nf: f32 = @floatFromInt(@max(n, 1));
    const end_pct = half + @as(f32, @floatFromInt(reached)) / nf * 100.0;
    return .{ .top = .{ .px = circle_size / 2 - 0.5 }, .left = .{ .percent = half }, .right = .{ .percent = 100.0 - end_pct } };
}

fn halfStepPct(n: usize) f32 {
    return if (n > 0) 50.0 / @as(f32, @floatFromInt(n)) else 0;
}

// Preserve the text-bearing circle while expressing the formerly implicit
// vertical paint offset as an actual inset, recomputed with the theme.
pub const num_box = ui.paramStyle(struct { pub const declared = &[_][]const u8{ "padding", }; pub fn resolve(args: @This(), t: *const ui.theme.Values) ui.BoxStyle { _ = args; return ui.boxFrom(.{ .padding = core.Padding.symmetric(@max(0, (circle_size - t.tokens.font_size.sm * 1.4) / 2), 0), }, t); } }).of(.{});

//# yix-map styles.yss

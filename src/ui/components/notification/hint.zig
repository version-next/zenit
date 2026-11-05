//! Text hint (spec 16.13 Text Toast): light card form (kind = .hint).
//! One-line instant feedback (copy OK / saved / replaced N places / press Esc to close).
//! Same glass as card, 36-high full-round capsule: no title / timestamp / close button / progress.
//! Same stack as card (fold/peek, hover expands + pause timer, swipe close, in-place convert all
//! shared);
//! width fits content (max 480; overflow single-line truncate + ellipsis).
//! This file: capsule content layer only; shell in card.applyShellForm; stack/timer in mod.zig.
const std = @import("std");
const core = @import("../../core.zig");
const view = @import("../../view.zig");
const Cx = core.Cx;
const Node = core.Node;
const box = core.box;
const Color = core.Color;
const Scope = @import("../../reactive.zig").Scope;
const icons = @import("zenit_system_icons");
const render_engine = @import("../../core/render_engine/mod.zig");
const DrawContext = render_engine.DrawContext;

const model = @import("model.zig");
const styles = @import("styles.zig");
const card_mod = @import("card.zig");
const Card = card_mod.Card;
const H = styles.HintMetrics;
const fixed = core.Sizing.fixed;
const fit: core.Sizing = .{ .fit = .{} };

/// Line-start icon.
pub const Mark = enum {
    none,
    /// 18-circle chip + check (ntf-success).
    success,
    /// 18-circle chip (ntf-error); a11y announces assertive.
    @"error",
    /// 16-circle rotating indicator; doesn't auto-dismiss; convert in-place to success with same id
    /// when done.
    loading,
};

/// Keycap line: "text · press [Esc] to close".
pub const Keycap = struct {
    prefix: []const u8 = "",
    key: []const u8,
    suffix: []const u8 = "",
};

/// One hint message (Notifier.hint param). String copied by Notifier.
pub const Hint = struct {
    /// Existing id converts in-place (in-progress -> success; undo then swap to result).
    id: ?u64 = null,
    text: []const u8,
    mark: Mark = .none,
    keycap: ?Keycap = null,
    /// Button on capsule right (e.g. "Undo Cmd+Z"); click emits `.action` event.
    action: ?card_mod.Action = null,
    /// Override default duration (text/success 2s; error/keycap 3s; with button 4s; in-progress
    /// stays).
    duration_ms: ?u32 = null,
};

/// Default duration; null = persistent (in-progress).
pub fn durationOf(mark: Mark, has_keycap: bool, has_action: bool) ?u32 {
    if (mark == .loading) return null;
    if (has_action) return model.HintDurations.action;
    if (mark == .@"error" or has_keycap) return model.HintDurations.emphasis;
    return model.HintDurations.plain;
}

pub fn toneOf(mark: Mark) model.Tone {
    return switch (mark) {
        .success => .success,
        .@"error" => .@"error",
        .none, .loading => .info,
    };
}

/// Build capsule content layer (not mounted to surface; card.buildContent mounts).
pub fn buildContent(card: *Card, p: card_mod.BuildParams) !card_mod.Content {
    const cx = p.cx;
    const pal = p.palette;
    const spec = card.spec;
    const marked = spec.hint_mark != .none;
    const action: ?card_mod.Action = if (spec.actions.len > 0) spec.actions[0] else null;
    const act = action orelse card_mod.Action{ .label = "" };
    const keycap = spec.keycap orelse Keycap{ .key = "" };
    const has_keycap = spec.keycap != null;

    const scope = try Scope.init(p.scope.allocator, null, p.scope.owner);
    errdefer scope.dispose();

    // Text limit = 480 - padding - icon: overflow single-line truncate + ellipsis
    // (fit-width container with max_width doesn't compress children; must limit text).
    const pad_l: f32 = if (marked) H.pad_marked else H.pad_plain;
    const pad_r: f32 = if (action != null) H.pad_action else H.pad_plain;
    const mark_w: f32 = switch (spec.hint_mark) {
        .none => 0,
        .loading => H.spinner + H.gap,
        .success, .@"error" => H.chip + H.gap,
    };
    const tone = pal.tone(toneOf(spec.hint_mark));
    const chip = spec.hint_mark == .success or spec.hint_mark == .@"error";

    var content = card_mod.Content{ .scope = scope, .root = undefined, .title = undefined };
    var btn: ?*Node = null;
    const root = try view.render(scope, cx, view.row(.{
        .style = .{
            .width = fit,
            .height = fixed(H.height),
            .align_items = .center,
            .gap = if (spec.keycap != null) H.keycap_gap else H.gap,
            .padding = core.Padding{ .top = 0, .bottom = 0, .left = pad_l, .right = pad_r },
            // Max width 480: overflow text single-line truncate + ellipsis.
            .max_width = H.max_width,
            .flex_shrink = 0,
        },
    }, .{
        // Line-start icon: success/error are semantic-color circle + glyph; in-progress is rotating
        // indicator.
        if (chip) view.box(.{ .style = .{
            .width = fixed(H.chip),
            .height = fixed(H.chip),
            .align_items = .center,
            .justify = .center,
            .background = Color.TRANSPARENT,
            .border = .{ .overlay = true, .width = 0, .color = tone, .radius = H.chip / 2 },
            .corner_radius = H.chip / 2,
            .flex_shrink = 0,
        } }, view.icon(.{
            .style = .{ .width = fixed(H.glyph), .height = fixed(H.glyph) },
            .tint = pal.ink,
        }, spec.glyph orelse card_mod.defaultGlyph(spec.tone))) else null,
        if (spec.hint_mark == .loading) view.capture(&content.spinner, view.setup(view.box(.{ .style = .{
            .width = fixed(H.spinner),
            .height = fixed(H.spinner),
            .flex_shrink = 0,
        } }, {}), card, setSpinnerDraw)) else null,
        view.capture(&content.title, card_mod.styledText(spec.title, .{
            .color = pal.ink,
            .font_size = H.font,
            .font_weight = H.weight,
            .line_height = 1.4,
            .text_overflow = .ellipsis,
        }, .{ .flex_shrink = 0, .max_width = H.max_width - pad_l - pad_r - mark_w })),
        // Keycap line: "text · press [Esc] to close".
        if (has_keycap) shrinkless("·", pal.ink_3, H.font, 400) else null,
        if (has_keycap and keycap.prefix.len > 0) shrinkless(keycap.prefix, pal.ink_2, H.font, H.weight) else null,
        if (has_keycap) view.box(.{ .style = .{
            .height = fixed(H.keycap_height),
            .align_items = .center,
            .justify = .center,
            .padding = core.Padding.symmetric(0, 6),
            .background = pal.keycap_bg,
            .border = .{ .overlay = true, .width = 0.5, .color = pal.keycap_edge, .radius = H.keycap_radius },
            .corner_radius = H.keycap_radius,
            .flex_shrink = 0,
        } }, shrinkless(keycap.key, pal.ink_2, H.keycap_font, 600)) else null,
        if (has_keycap and keycap.suffix.len > 0) shrinkless(keycap.suffix, pal.ink_2, H.font, H.weight) else null,
        // Button on capsule right.
        if (action != null) view.box(.{ .style = .{ .width = fixed(H.action_lead), .height = fixed(1), .flex_shrink = 0 } }, {}) else null,
        if (action != null) view.capture(&btn, view.row(.{
            .style = .{
                .height = fixed(H.action_height),
                .align_items = .center,
                .gap = 6,
                .padding = H.action_padding,
                .background = pal.button_primary,
                .border = .{ .overlay = true, .width = 0, .color = pal.button_primary, .radius = H.action_radius },
                .corner_radius = H.action_radius,
                .flex_shrink = 0,
                .cursor = .pointer,
            },
            .focusable = true,
            .a11y = .{ .role = .button, .label = act.label },
        }, .{
            shrinkless(act.label, pal.ink, H.action_font, 600),
            if (act.shortcut.len > 0) view.box(.{ .style = .{
                .height = fixed(H.action_kbd_height),
                .align_items = .center,
                .justify = .center,
                .padding = core.Padding.symmetric(0, 4),
                .background = pal.hint_kbd_bg,
                .border = .{ .overlay = true, .width = 0, .color = pal.hint_kbd_bg, .radius = H.action_kbd_radius },
                .corner_radius = H.action_kbd_radius,
            } }, shrinkless(act.shortcut, pal.ink_2, H.action_kbd_font, 600)) else null,
        })) else null,
    }));
    errdefer cx.freeNode(root);
    root.meta.ownership.meta.component_name = "Notification.hint";
    content.root = root;

    if (btn) |b| {
        // Raw event: hover tint + click/Enter/Space (DSL has on_click only).
        // Context routed by card.rebindButtons to stable addr inside card after content placed.
        b.behavior.events.on_event = actionEvent;
        b.meta.ownership.meta.component_name = "Notification.hint.action";
        content.buttons[0] = b;
    }
    return content;
}

fn setSpinnerDraw(card: *Card, node: *Node) void {
    node.setCustomDraw(spinnerDraw, @ptrCast(card));
}

/// Non-shrinking single-line text (capsule text keeps natural width).
fn shrinkless(content: []const u8, color: Color, size: f32, weight: u16) card_mod.StyledText {
    return card_mod.styledText(content, .{ .color = color, .font_size = size, .font_weight = weight }, .{ .flex_shrink = 0 });
}

/// Capsule button: hover darkens tint; click/Enter/Space via card button channel (processed next
/// frame).
fn actionEvent(event: core.Event, context: ?*anyopaque) core.EventResult {
    const bctx: *card_mod.ButtonContext = @ptrCast(@alignCast(context orelse return .ignored));
    const btn = bctx.card.content.buttons[bctx.index] orelse return .ignored;
    switch (event) {
        .mouse_enter, .mouse_leave => {
            const pal = styles.palette(bctx.card.cx.tokens);
            const bg = if (event == .mouse_enter) pal.button_primary_hover else pal.button_primary;
            btn.setBackgroundRaw(bg);
            btn.style.border.color = bg;
            btn.markRenderDirty();
            bctx.card.cx.requestRedraw();
        },
        .click => |c| if (c.button == .left) {
            bctx.card.button_sink(bctx.card, bctx.index);
            return .stop;
        },
        .key_down => |k| if (k.key == .@"return" or k.key == .space) {
            bctx.card.button_sink(bctx.card, bctx.index);
            return .stop;
        },
        else => {},
    }
    return .ignored;
}

/// In-progress: 16-circle (ntf-track track + ntf-info 110-degree arc), 0.9s per rotation.
fn spinnerDraw(ctx: DrawContext, context: ?*anyopaque) anyerror!void {
    const card: *Card = @ptrCast(@alignCast(context orelse return));
    const dl = ctx.display_list orelse return;
    const header = ctx.display_header orelse return;
    const pal = styles.palette(card.cx.tokens);
    const r = H.spinner / 2;
    try dl.append(.{ .arc = .{
        .header = header,
        .cx = ctx.local_w / 2,
        .cy = ctx.local_h / 2,
        .outer_radius = r,
        .stroke_width = H.spinner_stroke,
        .start_angle = 0,
        .end_angle = std.math.tau,
        .color = pal.track,
    } });
    const turn: f32 = @floatCast(@mod(card.draw_now_ms, 900.0) / 900.0);
    const start = -std.math.pi / 2.0 + turn * std.math.tau;
    try dl.append(.{ .arc = .{
        .header = header,
        .cx = ctx.local_w / 2,
        .cy = ctx.local_h / 2,
        .outer_radius = r,
        .stroke_width = H.spinner_stroke,
        .start_angle = start,
        .end_angle = start + H.spinner_sweep_deg / 360.0 * std.math.tau,
        .color = pal.info,
    } });
}

test "durationOf: 设计稿默认时长" {
    try std.testing.expectEqual(@as(?u32, 2000), durationOf(.none, false, false));
    try std.testing.expectEqual(@as(?u32, 2000), durationOf(.success, false, false));
    try std.testing.expectEqual(@as(?u32, 3000), durationOf(.@"error", false, false));
    try std.testing.expectEqual(@as(?u32, 3000), durationOf(.none, true, false));
    try std.testing.expectEqual(@as(?u32, 4000), durationOf(.success, false, true));
    try std.testing.expectEqual(@as(?u32, null), durationOf(.loading, false, false));
}

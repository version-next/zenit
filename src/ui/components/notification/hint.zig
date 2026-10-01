//! 文案提示（设计稿 16.13 · Text Toast），卡片的轻量形态（kind = .hint）。
//!
//! 只有一句话的即时反馈（复制成功、已保存、替换了几处、按 Esc 退出）。
//! 与卡片同一种玻璃，做成 36 高的全圆角胶囊：没有标题、时间戳、关闭钮和生命条。
//! 与卡片进同一个堆叠（折叠露边、悬停展开并暂停计时、横扫关闭、原地转换都共用），
//! 宽度随内容（最大 480，超出单行截断加省略号）。
//!
//! 本文件只负责胶囊的内容层；外壳见 card.applyShellForm，堆叠与计时见 mod.zig。
const std = @import("std");
const core = @import("../../core.zig");
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

/// 行首标记。
pub const Mark = enum {
    none,
    /// 18 圆形芯片 + ✓（ntf-success）。
    success,
    /// 18 圆形芯片（ntf-error），无障碍按 assertive 播报。
    @"error",
    /// 16 圆环旋转指示器；不自动消失，完成后用同一 id 原地转成 success。
    loading,
};

/// 键帽行：「文案 · 按 [Esc] 退出」。
pub const Keycap = struct {
    prefix: []const u8 = "",
    key: []const u8,
    suffix: []const u8 = "",
};

/// 一条文案提示（Notifier.hint 的参数）。字符串由 Notifier 复制持有。
pub const Hint = struct {
    /// 已存在的 id 会原地转换（进行中 -> 成功、撤销后换成结果）。
    id: ?u64 = null,
    text: []const u8,
    mark: Mark = .none,
    keycap: ?Keycap = null,
    /// 胶囊右端的按钮（如「撤销 ⌘Z」）；点击走 `.action` 事件。
    action: ?card_mod.Action = null,
    /// 覆盖默认停留时长（纯文案 / 成功 2s；失败 / 键帽 3s；带按钮 4s；进行中常驻）。
    duration_ms: ?u32 = null,
};

/// 默认停留时长；null = 常驻（进行中）。
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

/// 构建胶囊内容层（未挂到 surface；由 card.buildContent 负责挂载）。
pub fn buildContent(card: *Card, p: card_mod.BuildParams) !card_mod.Content {
    const cx = p.cx;
    const pal = p.palette;
    const spec = card.spec;
    const marked = spec.hint_mark != .none;
    const action: ?card_mod.Action = if (spec.actions.len > 0) spec.actions[0] else null;

    const scope = try Scope.init(p.scope.allocator, null, p.scope.owner);
    errdefer scope.dispose();

    const root = try box(cx, .{
        .width = .{ .fit = .{} },
        .height = .fixed(H.height),
        .direction = .row,
        .align_items = .center,
        .gap = if (spec.keycap != null) H.keycap_gap else H.gap,
        .padding = .{
            .top = 0,
            .bottom = 0,
            .left = if (marked) H.pad_marked else H.pad_plain,
            .right = if (action != null) H.pad_action else H.pad_plain,
        },
    }, .{});
    errdefer cx.freeNode(root);
    // 最大宽度 480：超出时正文单行截断加省略号。
    (try root.style.ensureExtFallible(cx.allocator)).max_width = H.max_width;
    root.style.flex_shrink = 0;
    root.meta.ownership.meta.component_name = "Notification.hint";

    var spinner: ?*Node = null;
    switch (spec.hint_mark) {
        .none => {},
        .success, .@"error" => {
            const tone = pal.tone(toneOf(spec.hint_mark));
            const chip = try box(cx, .{
                .width = .fixed(H.chip),
                .height = .fixed(H.chip),
                .align_items = .center,
                .justify = .center,
                .background = tone,
                .border = .{ .width = 0, .color = tone, .radius = H.chip / 2 },
            }, .{});
            try appendOwned(cx, root, chip);
            (try chip.style.ensureExtFallible(cx.allocator)).corner_radius = core.CornerRadius.uniform(H.chip / 2);
            chip.style.flex_shrink = 0;
            const glyph = try core.iconTint(cx, spec.glyph orelse card_mod.defaultGlyph(spec.tone), pal.on_semantic, .{
                .width = .fixed(H.glyph),
                .height = .fixed(H.glyph),
            });
            try appendOwned(cx, chip, glyph);
        },
        .loading => {
            const s = try box(cx, .{ .width = .fixed(H.spinner), .height = .fixed(H.spinner) }, .{});
            try appendOwned(cx, root, s);
            s.style.flex_shrink = 0;
            s.setCustomDraw(spinnerDraw, @ptrCast(card));
            spinner = s;
        },
    }

    const label = try textNode(cx, spec.title, pal.ink, H.font, H.weight);
    try appendOwned(cx, root, label);
    // 正文上限 = 480 − 内边距 − 标记：超出时单行截断加省略号（fit 宽容器被
    // max_width 夹住时不会压缩子节点，只能给正文自己设上限）。
    const pad_l: f32 = if (marked) H.pad_marked else H.pad_plain;
    const pad_r: f32 = if (action != null) H.pad_action else H.pad_plain;
    const mark_w: f32 = switch (spec.hint_mark) {
        .none => 0,
        .loading => H.spinner + H.gap,
        .success, .@"error" => H.chip + H.gap,
    };
    (try label.style.ensureExtFallible(cx.allocator)).max_width = H.max_width - pad_l - pad_r - mark_w;
    if (label.getText()) |t| {
        var tt = t;
        tt.text_overflow = .ellipsis;
        label.setText(tt);
    }

    if (spec.keycap) |k| {
        try appendOwned(cx, root, try textNode(cx, "·", pal.ink_3, H.font, 400));
        if (k.prefix.len > 0) try appendOwned(cx, root, try textNode(cx, k.prefix, pal.ink_2, H.font, H.weight));
        const kbd = try box(cx, .{
            .height = .fixed(H.keycap_height),
            .align_items = .center,
            .justify = .center,
            .padding = core.Padding.symmetric(0, 6),
            .background = pal.keycap_bg,
            .border = .{ .width = 0.5, .color = pal.keycap_edge, .radius = H.keycap_radius },
        }, .{});
        try appendOwned(cx, root, kbd);
        (try kbd.style.ensureExtFallible(cx.allocator)).corner_radius = core.CornerRadius.uniform(H.keycap_radius);
        kbd.style.flex_shrink = 0;
        try appendOwned(cx, kbd, try textNode(cx, k.key, pal.ink_2, H.keycap_font, 600));
        if (k.suffix.len > 0) try appendOwned(cx, root, try textNode(cx, k.suffix, pal.ink_2, H.font, H.weight));
    }

    var content = card_mod.Content{ .scope = scope, .root = root, .title = label, .spinner = spinner };

    if (action) |a| {
        const spacer = try box(cx, .{ .width = .fixed(H.action_lead), .height = .fixed(1) }, .{});
        try appendOwned(cx, root, spacer);
        spacer.style.flex_shrink = 0;
        const btn = try box(cx, .{
            .height = .fixed(H.action_height),
            .direction = .row,
            .align_items = .center,
            .gap = 6,
            .padding = H.action_padding,
            .background = pal.button_primary,
            .border = .{ .width = 0, .color = pal.button_primary, .radius = H.action_radius },
        }, .{});
        try appendOwned(cx, root, btn);
        (try btn.style.ensureExtFallible(cx.allocator)).corner_radius = core.CornerRadius.uniform(H.action_radius);
        btn.style.flex_shrink = 0;
        btn.style.cursor = .pointer;
        btn.behavior.interaction.focusable = true;
        btn.behavior.interaction.a11y = .{ .role = .button, .label = a.label };
        // 上下文由 card.rebindButtons 在 content 落位后指向 card 内的稳定地址。
        btn.behavior.events.on_event = actionEvent;
        btn.meta.ownership.meta.component_name = "Notification.hint.action";
        try appendOwned(cx, btn, try textNode(cx, a.label, pal.ink, H.action_font, 600));
        if (a.shortcut.len > 0) {
            const kbd = try box(cx, .{
                .height = .fixed(H.action_kbd_height),
                .align_items = .center,
                .justify = .center,
                .padding = core.Padding.symmetric(0, 4),
                .background = pal.hint_kbd_bg,
                .border = .{ .width = 0, .color = pal.hint_kbd_bg, .radius = H.action_kbd_radius },
            }, .{});
            try appendOwned(cx, btn, kbd);
            (try kbd.style.ensureExtFallible(cx.allocator)).corner_radius = core.CornerRadius.uniform(H.action_kbd_radius);
            try appendOwned(cx, kbd, try textNode(cx, a.shortcut, pal.ink_2, H.action_kbd_font, 600));
        }
        content.buttons[0] = btn;
    }
    return content;
}

/// 胶囊按钮：悬停加深底色；点击 / 回车 / 空格走卡片的按钮通道（下一帧处理）。
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

fn textNode(cx: *Cx, content: []const u8, color: Color, size: f32, weight: u16) !*Node {
    const node = try core.text(cx, content, .{ .color = color, .font_size = size, .font_weight = weight });
    node.style.flex_shrink = 0;
    return node;
}

fn appendOwned(cx: *Cx, parent: *Node, child: *Node) !void {
    errdefer cx.freeNode(child);
    try parent.appendChild(cx.allocator, child);
}

/// 进行中：16 圆环（ntf-track 轨道 + ntf-info 110° 弧），0.9s 一圈。
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

/// Alert Component
///
/// Alert: 静态消息提示条（全局提醒见 components/notification —— Notifier）
///
/// 特性:
/// - info/success/warning/error 四种变体
/// - 可关闭
const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../../core.zig");
const Cx = core.Cx;
const Node = core.Node;
const box = core.box;
const Color = core.Color;
const theme = core.theme;
const Padding = core.Padding;
const svg_assets = @import("../../svg_assets.zig");
const Scope = @import("../../reactive.zig").Scope;
const hooks = @import("../../hooks.zig");
const overlay_stack_mod = @import("../../overlay_stack.zig");
const system_icons = @import("zenit_system_icons");
const button_mod = @import("../button/mod.zig");

const ConditionalStyle = core.ConditionalStyle;
const Border = core.Border;
const recipe_mod = @import("../../recipe.zig");
const styles = @import("styles.zig");

/// Alert 变体
pub const AlertVariant = enum {
    info,
    success,
    warning,
    @"error",
};

pub const AlertRecipe = styles.AlertRecipe;

/// Alert 属性
pub const AlertProps = struct {
    variant: AlertVariant = .info,
    title: ?[]const u8 = null,
    message: []const u8 = "",
    closable: bool = false,
    on_close: ?core.HandlerRef = null,
    close_icon_asset: ?svg_assets.Asset = null,
};

/// 创建 Alert
pub fn Alert(props: AlertProps) AlertBuilder {
    return AlertBuilder{ .props = props };
}

pub const AlertBuilder = struct {
    props: AlertProps,

    pub fn variant(self: AlertBuilder, v: AlertVariant) AlertBuilder {
        var new = self;
        new.props.variant = v;
        return new;
    }

    pub fn title(self: AlertBuilder, t: []const u8) AlertBuilder {
        var new = self;
        new.props.title = t;
        return new;
    }

    pub fn message(self: AlertBuilder, m: []const u8) AlertBuilder {
        var new = self;
        new.props.message = m;
        return new;
    }

    pub fn closable(self: AlertBuilder, c: bool) AlertBuilder {
        var new = self;
        new.props.closable = c;
        return new;
    }

    pub fn onClose(self: AlertBuilder, handler_ref: core.HandlerRef) AlertBuilder {
        var new = self;
        new.props.on_close = handler_ref;
        return new;
    }

    /// 保留模式: mount
    pub fn mount(self: AlertBuilder, scope: *Scope, cx: *Cx) !*Node {
        const my_scope = try scope.childScope();
        const allocator = cx.allocator;
        const t = cx.tokens;
        const p = self.props;

        // Recipe resolve：variant 维度（background / border / accent color）
        const cs = AlertRecipe.resolve(.{ .variant = p.variant }, t);
        const resolved = cs.resolve(.{});
        const accent = resolved.text_color orelse t.color.info;
        const bg = resolved.background orelse Color.TRANSPARENT;
        const alert_border = resolved.border orelse Border{ .radius = t.radius.md };

        // 外层容器 — 几何来自具名样式函数，颜色来自 recipe resolve
        var container_style = styles.alertContainerStyle(p.title != null);
        container_style.background = bg;
        container_style.border = alert_border;
        const alert_node = try box(cx, container_style, .{});
        // sweep：alert_node 守卫一直武装到 return；子节点建好即 adopt
        errdefer cx.freeNode(alert_node);
        alert_node.meta.ownership.meta.component_name = "Alert";
        try core.bindScopeToNode(my_scope, alert_node);
        // role=alert 光有角色不会被朗读——AT 只在 live region 非 off 时才主动
        // 播报新出现的内容。此前 live 是 null（=off），于是 Alert 从来只有
        // 视觉效果，屏幕阅读器用户根本收不到通知。
        // error/warning 打断当前朗读（assertive），info/success 等说完再播（polite）。
        alert_node.behavior.interaction.a11y = .{
            .role = .alert,
            .live = switch (p.variant) {
                .@"error", .warning => "assertive",
                .info, .success => "polite",
            },
            .live_text = if (p.message.len > 0) p.message else p.title,
        };

        // 左侧强调条
        const accent_bar = try core.adoptChild(cx, allocator, alert_node, try box(cx, styles.alertAccentBarStyle(accent), .{}));
        (try accent_bar.style.ensureExtFallible(allocator)).align_self = .stretch;

        // 内容区
        const content = try core.adoptChild(cx, allocator, alert_node, try box(cx, styles.alertContentStyle(t), .{}));

        if (p.title) |title_text| {
            const title_node = try core.adoptChild(cx, allocator, content, try box(cx, .{
                .width = .{ .fit = .{} },
                .height = .{ .fit = .{} },
            }, .{}));
            var title_txt = styles.alertTitleText(t);
            title_txt.content = title_text;
            title_node.setText(title_txt);
        }

        if (p.message.len > 0) {
            const msg_node = try core.adoptChild(cx, allocator, content, try box(cx, .{
                .width = .{ .fit = .{} },
                .height = .{ .fit = .{} },
            }, .{}));
            var msg_txt = styles.alertMessageText(t);
            msg_txt.content = p.message;
            msg_node.setText(msg_txt);
        }

        // 关闭按钮
        if (p.closable) {
            const close_btn = try core.adoptChild(cx, allocator, alert_node, try box(cx, styles.alertCloseButtonStyle(t), .{}));

            if (p.close_icon_asset) |asset| {
                _ = try core.adoptChild(cx, allocator, close_btn, try core.iconTint(cx, asset, t.color.fg_secondary, .{
                    .width = .{ .px = styles.alert_close_icon_size },
                    .height = .{ .px = styles.alert_close_icon_size },
                }));
            } else {
                const txt_node = try core.adoptChild(cx, allocator, close_btn, try box(cx, .{
                    .width = .{ .fit = .{} },
                    .height = .{ .fit = .{} },
                }, .{}));
                txt_node.setText(styles.alertCloseLabelText(t));
            }

            _ = try hooks.useAnimatedBackground(my_scope, cx, close_btn, .{
                .normal = Color.TRANSPARENT,
                .hover = t.color.bg_hover,
            });

            close_btn.behavior.events.on_click = p.on_close;
        }

        return alert_node;
    }
};

// ========== 测试 ==========

test "Alert: basic" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 200 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const alert = try Alert(.{})
        .variant(.info)
        .message("This is an info alert")
        .mount(scope, ctx);

    try root.appendChild(std.testing.allocator, alert);

    // alert 有 2 个子节点: accent_bar + content
    try std.testing.expectEqual(@as(usize, 2), alert.children.items.len);
}

test "Alert: with title" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 200 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const alert = try Alert(.{})
        .variant(.success)
        .title("Success!")
        .message("Operation completed")
        .mount(scope, ctx);

    try root.appendChild(std.testing.allocator, alert);

    // content 有 2 个子节点: title + message
    const content = alert.children.items[1];
    try std.testing.expectEqual(@as(usize, 2), content.children.items.len);
}

test "Alert: closable" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 200 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const alert = try Alert(.{})
        .variant(.warning)
        .message("Warning!")
        .closable(true)
        .mount(scope, ctx);

    try root.appendChild(std.testing.allocator, alert);

    // 3 个子节点: accent_bar + content + close_btn
    try std.testing.expectEqual(@as(usize, 3), alert.children.items.len);
}

test "Alert: all variants" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 400 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    inline for (.{ AlertVariant.info, AlertVariant.success, AlertVariant.warning, AlertVariant.@"error" }) |v| {
        const a = try Alert(.{}).variant(v).message("Test").mount(scope, ctx);
        try root.appendChild(std.testing.allocator, a);
    }

    try std.testing.expectEqual(@as(usize, 4), root.children.items.len);
}

test "Alert: variant backgrounds stay visually distinct" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const info_cs = AlertRecipe.resolve(.{ .variant = .info }, ctx.tokens);
    const warn_cs = AlertRecipe.resolve(.{ .variant = .warning }, ctx.tokens);
    const info_bg = info_cs.resolve(.{}).background.?;
    const warn_bg = warn_cs.resolve(.{}).background.?;
    const info_border = info_cs.resolve(.{}).border.?;
    const warn_border = warn_cs.resolve(.{}).border.?;

    try std.testing.expect(!Color.eql(info_bg, warn_bg));
    try std.testing.expect(!Color.eql(info_border.color, warn_border.color));
}

test "Alert: render emits left accent bar" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();
    ctx.setViewport(360, 80);

    const root = try box(ctx, .{
        .width = .{ .px = 360 },
        .height = .{ .px = 80 },
        .background = ctx.tokens.color.bg_primary,
    }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const alert = try Alert(.{
        .variant = .warning,
        .message = "Careful",
    }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, alert);

    ctx.layout();
    _ = ctx.render();
    const commands = ctx.lowerForEncoderPaintTable();

    var saw_accent_bar = false;
    for (commands) |cmd| if (cmd.isFillRect()) {
        const r = cmd;
        if (Color.eql(r.color.toColor(), ctx.tokens.color.warning) and r.geom.w <= 4 and r.geom.h >= 24) {
            saw_accent_bar = true;
        }
    };

    try std.testing.expect(saw_accent_bar);
}

// styles.zig 的测试收集 —— 这行是必需的，见 docs/STYLING.md
test {
    _ = @import("styles.zig");
}

// 逐分配点 OOM sweep — 见 src/ui/components/oom_sweep.zig
test "alert(closable): mount 在任意分配点失败时不泄漏（sweep）" {
    try @import("../oom_sweep.zig").sweepMount("alert(closable)", struct {
        fn m(scope: *Scope, cx: *Cx) anyerror!?*Node {
            return try Alert(.{ .variant = .warning, .title = "Title", .message = "message body", .closable = true }).mount(scope, cx);
        }
    }.m);
}

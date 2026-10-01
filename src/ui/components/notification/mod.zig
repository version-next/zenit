//! Notifier，应用内全局提醒（设计稿 § 16 · In-App Notifications）。
//!
//! 一条提醒 = 一个 Card 对象；渲染层每帧只根据它算 transform 与 alpha，
//! 所有时间量都从 born / left_at / deadline 三个墙钟派生的时间戳推导。
//!
//! 关键不变量（16.8 实现注意）：
//! ① 每条提醒独占自己的节点（固定槽位）。删除中间一条不会让其它卡片的节点
//!    前移复用，上方卡片不会重放入场。
//! ② 入场 / 退场逐帧插值，不用关键帧动画。
//! ③ 逐帧驱动与补间不叠加：有卡片在退场、本卡入场未满 620ms、或正在
//!    展开 / 折叠时，位置直接跟随逐帧目标；其余时候目标跳变走 540ms 补间。
//! ④ 悬停 = 对整组外接矩形（外扩 18px）逐帧做命中测试，不用进出事件。
//!    退场期间冻结展开状态；退场结束后按指针真实坐标重新判定。
//! ⑥ z 序与层序相反：层序 0（最新、最靠近锚点）z 最高。
//!
//! 文案提示（hint，16.13）是卡片的轻量形态（kind = .hint）：一句话的玻璃胶囊，
//! 与卡片进同一个堆叠，见 hint.zig 与 Notifier.hint。
//!
//! 通知中心（历史、勿扰、铃铛入口）是业务层：宿主在自己调用 show 的地方记历史、
//! 决定是否弹出，并通过 Listener 事件得知关闭 / 到期 / 按钮操作。
const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../../core.zig");
const Cx = core.Cx;
const Node = core.Node;
const box = core.box;
const Color = core.Color;
const Scope = @import("../../reactive.zig").Scope;
const svg_assets = @import("../../svg_assets.zig");
const overlay_stack_mod = @import("../../overlay_stack.zig");
const icons = @import("zenit_system_icons");
const drag = @import("../../interaction/drag.zig");
const events = @import("../../events.zig");

pub const model = @import("model.zig");
pub const styles = @import("styles.zig");
const card_mod = @import("card.zig");
const Card = card_mod.Card;
const hint_mod = @import("hint.zig");
const M = styles.Metrics;
const Spec = model.Spec;

pub const Kind = model.Kind;
pub const Tone = model.Tone;
pub const Position = model.Position;
pub const Lead = card_mod.Lead;
pub const Action = card_mod.Action;
pub const Progress = card_mod.Progress;
pub const Strings = card_mod.Strings;
pub const NotificationCard = Card;
pub const Hint = hint_mod.Hint;
pub const HintMark = hint_mod.Mark;
pub const HintKeycap = hint_mod.Keycap;

pub const Id = u64;

/// 一条提醒的内容与行为。字符串由 Notifier 复制持有。
pub const Notification = struct {
    /// 已存在的 id 会原地转换（保留 born，不重放入场）。
    id: ?Id = null,
    kind: Kind = .default,
    tone: Tone = .info,
    title: []const u8 = "",
    body: []const u8 = "",
    /// 覆盖语义色调的默认字形（✓ / ✕ / △ …）。
    glyph: ?svg_assets.Asset = null,
    /// 覆盖行首图标位的默认呈现（由 kind / tone / avatar 推导）。
    lead: ?Lead = null,
    /// 人员消息的头像首字。
    avatar: []const u8 = "",
    /// 分隔线下方的等宽按钮（最多 2 个）。undo 类型缺省为「撤销」。
    actions: []const Action = &.{},
    /// 内联回复框（Enter 或「发送」提交）。
    reply: bool = false,
    /// 回复已发出后的引用行（原地转换用）。
    quote: ?[]const u8 = null,
    progress: ?Progress = null,
    /// 常驻：不自动消失。
    sticky: bool = false,
    /// 覆盖类型默认停留时长。
    duration_ms: ?u32 = null,
    /// 覆盖生命条显示（默认：有时限且非 progress 时显示）。
    life_bar: ?bool = null,
    /// kind = .hint：行首标记与键帽行（title 为胶囊正文）。一般用 Notifier.hint 构造。
    hint_mark: HintMark = .none,
    keycap: ?HintKeycap = null,
};

pub const EventKind = enum {
    /// 点了操作按钮（tag / index 标识哪个）。
    action,
    /// 点了撤销（倒计时环已原地换成 ✓）。
    undo,
    /// 回复框提交（text 为回复内容）。
    reply,
    /// 用户关闭（✕ 或拖拽甩出）。
    dismissed,
    /// 到期自动收起。
    expired,
};

pub const Event = struct {
    id: Id,
    kind: EventKind,
    tag: []const u8 = "",
    index: u8 = 0,
    text: []const u8 = "",
};

pub const Listener = struct {
    context: ?*anyopaque = null,
    callback: *const fn (context: ?*anyopaque, notifier: *Notifier, event: Event) void,
};

pub const Insets = struct {
    top: f32 = 0,
    right: f32 = 0,
    bottom: f32 = 0,
    left: f32 = 0,
};

pub const Options = struct {
    position: Position = .bottom_center,
    /// 展开时最多显示条数（2–6）。
    max_visible: u8 = Spec.default_max_visible,
    /// false：悬停只暂停计时，不展开。
    expand_on_hover: bool = true,
    /// 内容区相对窗口的内缩（标题栏 / 状态栏），停靠边距 22 从这里起算。
    content_insets: Insets = .{},
    width: f32 = Spec.card_width,
    strings: Strings = .{},
    listener: ?Listener = null,
};

const PendingOp = union(enum) {
    button: struct { id: Id, seq: u64, revision: u64, index: u8 },
    close: struct { id: Id, seq: u64, revision: u64 },
    /// 角标旁「全部清除」：所有在屏提醒按用户关闭退场。
    clear_all,
};

pub const Notifier = struct {
    cx: *Cx,
    scope: *Scope,
    allocator: Allocator,
    /// 覆盖整窗的透明 portal 根；只让子节点接收命中。
    container: *Node,
    portaled: bool = false,
    pill: *Node,
    pill_icon_more: *Node,
    pill_icon_paused: *Node,
    pill_label: *Node,
    /// 角标右侧的「全部清除」圆钮（悬停展开出文字，iOS 通知中心同款）。
    clear_btn: *Node,
    /// 包住文字的揭示层：宽度在 0 ↔ 文字自然宽之间动画（overflow 裁切）。
    clear_reveal: *Node,
    clear_label: *Node,
    clear_alpha: f32 = 0,
    /// 第一下点击「武装」：圆钮展开出「全部清除」，第二下才真正清除；移开即收回。
    clear_armed: bool = false,
    /// 展开进度 0..1（逐帧逼近 clear_armed）。
    clear_reveal_t: f32 = 0,
    layer_handle: overlay_stack_mod.LayerHandle,

    options: Options,
    strings: Strings,
    cards: std.ArrayListUnmanaged(*Card) = .{},
    pending: std.ArrayListUnmanaged(PendingOp) = .{},
    next_id: Id = 1,
    next_seq: u64 = 1,

    hovered: bool = false,
    paused: bool = false,
    expand_value: f32 = 0,
    expand_from: f32 = 0,
    expand_to: f32 = 0,
    expand_start_ms: f64 = 0,
    pill_alpha: f32 = 0,
    pill_shown_count: i64 = -1,
    pill_shown_paused: bool = false,
    last_now_ms: f64 = 0,
    ran_once: bool = false,
    /// 正处于一个帧时钟已推进的 frame() 内：此时 last_now_ms 可直接用来盖戳。
    in_frame: bool = false,
    reclaimed_this_frame: bool = false,
    last_frame_ms: f64 = 0,
    /// 上一帧锚点中随视口变化的那部分（竖直方向）；视口变了就把各卡的
    /// follow_y 整体平移同样的量（见 model.Follow.shift）。
    last_anchor_ref: ?f32 = null,

    refs: usize = 1,
    container_alive: bool = false,
    layer_removed: bool = false,
    closed: bool = false,

    // ────────────────────────────────────────────────────────────────────
    // 生命周期
    // ────────────────────────────────────────────────────────────────────

    pub fn init(scope: *Scope, cx: *Cx, options: Options) !*Notifier {
        const my_scope = try scope.childScope();
        errdefer my_scope.dispose();
        const allocator = cx.allocator;
        const pal = styles.palette(cx.tokens);

        const container = try box(cx, .{ .position = .absolute, .width = .fill(), .height = .fill() }, .{});
        errdefer cx.freeNode(container);
        const cext = try container.style.ensureExtFallible(allocator);
        cext.inset = .{ .top = .{ .px = 0 }, .right = .{ .px = 0 }, .bottom = .{ .px = 0 }, .left = .{ .px = 0 } };
        cext.hit_behavior = .children_only;
        container.meta.ownership.meta.component_name = "NotificationViewport";

        // 角标（StackPill）：折叠态「还有 N 条 · 悬停展开」/ 展开态「悬停中 · 已暂停」。
        const pill = try box(cx, .{
            .position = .absolute,
            .height = .fixed(M.pill_height),
            .direction = .row,
            .align_items = .center,
            .gap = 6,
            .padding = core.Padding.symmetric(0, 11),
            .background = pal.pill_bg,
            .border = .{ .width = 0, .color = pal.pill_bg, .radius = M.pill_height / 2 },
        }, .{});
        try appendOwned(cx, container, pill);
        const pext = try pill.style.ensureExtFallible(allocator);
        pext.inset = .{ .left = .{ .px = 0 }, .top = .{ .px = 0 } };
        pext.corner_radius = core.CornerRadius.uniform(M.pill_height / 2);
        pext.glass = .{ .backdrop_blur = 12, .glass_intensity = 0 };
        pext.hit_behavior = .pass_through;
        pext.z_index = 200;
        pill.meta.ownership.meta.component_name = "Notification.pill";
        const icon_more = try core.iconTint(cx, icons.chevrons_up, pal.pill_icon, .{ .width = .fixed(M.pill_icon), .height = .fixed(M.pill_icon) });
        try appendOwned(cx, pill, icon_more);
        const icon_paused = try core.iconTint(cx, icons.pause, pal.pill_icon, .{ .width = .fixed(0), .height = .fixed(M.pill_icon) });
        try appendOwned(cx, pill, icon_paused);
        const pill_label = try core.text(cx, "", .{ .color = pal.pill_fg, .font_size = M.pill_font, .font_weight = 550 });
        try appendOwned(cx, pill, pill_label);

        // 「全部清除」：与角标同高同材质的圆钮；悬停展开出文字，点一下清掉所有提醒。
        const clear_btn = try box(cx, .{
            .position = .absolute,
            .height = .fixed(M.pill_height),
            .direction = .row,
            .align_items = .center,
            .justify = .center,
            .gap = 0,
            .padding = core.Padding.symmetric(0, (M.pill_height - M.pill_icon) / 2),
            .background = pal.pill_bg,
            .border = .{ .width = 0, .color = pal.pill_bg, .radius = M.pill_height / 2 },
        }, .{});
        try appendOwned(cx, container, clear_btn);
        const cbext = try clear_btn.style.ensureExtFallible(allocator);
        cbext.inset = .{ .left = .{ .px = 0 }, .top = .{ .px = 0 } };
        cbext.corner_radius = core.CornerRadius.uniform(M.pill_height / 2);
        cbext.min_width = M.pill_height;
        cbext.glass = .{ .backdrop_blur = 12, .glass_intensity = 0 };
        cbext.z_index = 200;
        clear_btn.style.cursor = .pointer;
        clear_btn.style.overflow_hidden = true;
        clear_btn.setOpacityRaw(0);
        clear_btn.setHitTestVisible(false);
        clear_btn.meta.ownership.meta.component_name = "Notification.clearAll";
        clear_btn.behavior.interaction.a11y = .{ .role = .button, .label = options.strings.clear_all };
        try appendOwned(cx, clear_btn, try core.iconTint(cx, icons.close, pal.pill_icon, .{ .width = .fixed(M.pill_icon), .height = .fixed(M.pill_icon) }));
        const clear_reveal = try box(cx, .{ .width = .fixed(0), .height = .fixed(M.pill_height), .direction = .row, .align_items = .center }, .{});
        try appendOwned(cx, clear_btn, clear_reveal);
        clear_reveal.style.overflow_hidden = true;
        clear_reveal.style.flex_shrink = 0;
        const clear_label = try core.text(cx, options.strings.clear_all, .{ .color = pal.pill_fg, .font_size = M.pill_font, .font_weight = 550 });
        try appendOwned(cx, clear_reveal, clear_label);
        clear_label.style.flex_shrink = 0;
        clear_label.style.margin = .{ .left = 5, .right = 3 };
        clear_label.setOpacityRaw(0);

        const layer_handle = try cx.overlay_stack.push(.{
            .kind = .toast,
            .dismiss = .{ .outside_click = .none, .escape = false },
            .enter_transition = .none,
            .exit_transition = .none,
        });
        var layer_owned = true;
        errdefer if (layer_owned) cx.overlay_stack.removePermanently(layer_handle);
        cx.overlay_stack.bindFloatingContent(allocator, layer_handle, container);

        const self = try allocator.create(Notifier);
        var registered = false;
        errdefer if (!registered) allocator.destroy(self);
        self.* = .{
            .cx = cx,
            .scope = my_scope,
            .allocator = allocator,
            .container = container,
            .pill = pill,
            .pill_icon_more = icon_more,
            .pill_icon_paused = icon_paused,
            .pill_label = pill_label,
            .clear_btn = clear_btn,
            .clear_reveal = clear_reveal,
            .clear_label = clear_label,
            .layer_handle = layer_handle,
            .options = options,
            .strings = options.strings,
            // 以当前帧时钟为基线：首个 hook 若是命中测试的重入 tick（时钟未推进）也会被去重。
            .last_now_ms = cx.frame_time_ms,
            .ran_once = true,
        };
        self.options.max_visible = std.math.clamp(options.max_visible, 2, 6);
        try my_scope.registerResource(@ptrCast(self), struct {
            fn cleanup(ptr: *anyopaque, _: Allocator) void {
                const n: *Notifier = @ptrCast(@alignCast(ptr));
                n.closeFromScope();
                n.release();
            }
        }.cleanup);
        registered = true;
        layer_owned = false;

        if (cx.popover_portal_root) |portal| {
            try portal.appendChild(allocator, container);
            self.portaled = true;
        }
        // scope 与 container 各持一份引用，任一先销毁都安全。
        self.refs += 1;
        self.container_alive = true;
        container.meta.ownership.hooks.on_cleanup = Cx.simpleHandler(struct {
            fn cleanup(ptr: *anyopaque) void {
                const n: *Notifier = @ptrCast(@alignCast(ptr));
                n.container_alive = false;
                n.closed = true;
                n.removeLayer();
                n.releaseCards(false);
                n.release();
            }
        }.cleanup, @ptrCast(self));
        container.meta.per_frame.hooks.slots.anim_state = @ptrCast(self);
        container.meta.per_frame.hooks.before_render.main = frameHook;
        clear_btn.behavior.events.on_event = clearAllEvent;
        clear_btn.behavior.events.event_context = @ptrCast(self);
        return self;
    }

    fn removeLayer(self: *Notifier) void {
        if (self.layer_removed) return;
        self.layer_removed = true;
        self.cx.overlay_stack.removePermanently(self.layer_handle);
    }

    fn release(self: *Notifier) void {
        std.debug.assert(self.refs > 0);
        self.refs -= 1;
        if (self.refs == 0) {
            self.cards.deinit(self.allocator);
            self.pending.deinit(self.allocator);
            self.allocator.destroy(self);
        }
    }

    fn closeFromScope(self: *Notifier) void {
        if (self.closed and !self.container_alive) return;
        self.closed = true;
        self.removeLayer();
        if (!self.container_alive) return;
        self.container.meta.per_frame.hooks.slots.anim_state = null;
        self.container.meta.per_frame.hooks.before_render.main = null;
        self.releaseCards(true);
        if (self.portaled) {
            if (self.container.parent) |parent| self.cx.detachChildRetained(parent, self.container);
            self.cx.freeNode(self.container);
        }
    }

    /// 释放全部卡片状态。free_nodes=false 时节点随容器一起回收（容器 cleanup 路径）。
    fn releaseCards(self: *Notifier, free_nodes: bool) void {
        for (self.cards.items) |card| self.destroyCard(card, free_nodes);
        self.cards.clearRetainingCapacity();
    }

    // ────────────────────────────────────────────────────────────────────
    // 公共 API
    // ────────────────────────────────────────────────────────────────────

    /// 弹出一条提醒；id 已存在时原地转换。同屏超过 6 条时最旧一条走正常退场。
    pub fn show(self: *Notifier, n: Notification) !Id {
        if (self.closed) return error.NotifierClosed;
        if (n.id) |id| {
            if (self.findLive(id)) |card| {
                try self.transformCard(card, n);
                return id;
            }
        }
        const id = n.id orelse self.allocateId();
        const card = try self.createCard(id, n);
        errdefer self.destroyCard(card, true);
        try self.cards.append(self.allocator, card);
        self.enforceScreenLimit();
        self.container.markRenderDirty();
        return id;
    }

    /// 原地转换：改写 kind / tone / title / body，重置 life，换图标，不销毁、
    /// 不重建卡片，born 不变，不重放入场（16.6）。
    pub fn update(self: *Notifier, id: Id, n: Notification) !void {
        const card = self.findLive(id) orelse return error.NotificationNotFound;
        try self.transformCard(card, n);
    }

    /// 更新进度卡的进度（不重建内容层）。
    pub fn setProgress(self: *Notifier, id: Id, value: f32, label: ?[]const u8, count_text: ?[]const u8) void {
        const card = self.findLive(id) orelse return;
        const fill = card.content.progress_fill orelse return;
        fill.setStyle(self.allocator, .width, core.Sizing.pct(model.clamp01(value) * 100));
        const block = card.content.progress_block orelse return;
        const meta = block.children.items[block.children.items.len - 1];
        if (label) |l| meta.children.items[0].setTextContent(self.allocator, l) catch {};
        if (count_text) |c| meta.children.items[1].setTextContent(self.allocator, c) catch {};
        self.container.markRenderDirty();
    }

    pub fn dismiss(self: *Notifier, id: Id) void {
        const card = self.findLive(id) orelse return;
        self.beginLeave(card, false);
    }

    pub fn dismissAll(self: *Notifier) void {
        for (self.cards.items) |card| if (!card.leaving) self.beginLeave(card, false);
    }

    /// 位置切换不重建卡片，只改锚点参数；退场中的沿新方向继续完成退场。
    pub fn setPosition(self: *Notifier, position: Position) void {
        self.options.position = position;
        // 换停靠位置是重排（要补间过去），不是视口平移：清掉锚点基准，
        // 免得下一帧把锚点类型切换误当成窗口尺寸变化整体平移。
        self.last_anchor_ref = null;
        self.container.markRenderDirty();
    }

    pub fn setListener(self: *Notifier, listener: ?Listener) void {
        self.options.listener = listener;
    }

    pub fn setExpandOnHover(self: *Notifier, on: bool) void {
        self.options.expand_on_hover = on;
    }

    pub fn setMaxVisible(self: *Notifier, n: u8) void {
        self.options.max_visible = std.math.clamp(n, 2, 6);
    }

    /// 在场（未退场）的条数。
    pub fn count(self: *const Notifier) usize {
        var c: usize = 0;
        for (self.cards.items) |card| {
            if (!card.leaving) c += 1;
        }
        return c;
    }

    pub fn isExpanded(self: *const Notifier) bool {
        return self.expand_value > 0.5;
    }

    pub fn isPaused(self: *const Notifier) bool {
        return self.paused;
    }

    // ── 文案提示（16.13）──

    /// 弹出一条文案提示（36 高玻璃胶囊），与卡片进同一个堆叠。
    /// 传入已存在的 id 时原地转换（进行中 -> 成功）。按钮点击走 `.action` 事件，
    /// 宿主没有在回调里原地转换它时，点过即收起。
    pub fn hint(self: *Notifier, h: Hint) !Id {
        const actions: []const Action = if (h.action) |*a| a[0..1] else &.{};
        return self.show(.{
            .id = h.id,
            .kind = .hint,
            .tone = hint_mod.toneOf(h.mark),
            .title = h.text,
            .actions = actions,
            .duration_ms = h.duration_ms,
            .hint_mark = h.mark,
            .keycap = h.keycap,
        });
    }

    /// 等同于点最新一条带按钮的文案提示的按钮：宿主在 ⌘Z 等快捷键里先调它，
    /// 返回 true 表示已被提示消费（没有这样的提示时返回 false，⌘Z 回到编辑器自己的撤销栈）。
    pub fn triggerHintAction(self: *Notifier) bool {
        var newest: ?*Card = null;
        for (self.cards.items) |card| {
            if (card.leaving or card.spec.kind != .hint or card.spec.actions.len == 0) continue;
            if (newest == null or card.seq > newest.?.seq) newest = card;
        }
        const card = newest orelse return false;
        onButton(card, 0);
        self.cx.requestRedraw();
        return true;
    }

    /// 取卡片（测试 id、埋点、截图断言用）。
    pub fn cardForId(self: *Notifier, id: Id) ?*Card {
        for (self.cards.items) |card| if (card.id == id) return card;
        return null;
    }

    // ────────────────────────────────────────────────────────────────────
    // 卡片创建 / 转换 / 销毁
    // ────────────────────────────────────────────────────────────────────

    fn allocateId(self: *Notifier) Id {
        while (self.cardForId(self.next_id) != null) self.next_id +%= 1;
        const id = self.next_id;
        self.next_id +%= 1;
        return id;
    }

    fn findLive(self: *Notifier, id: Id) ?*Card {
        for (self.cards.items) |card| if (card.id == id and !card.leaving) return card;
        return null;
    }

    const Resolved = struct { spec: card_mod.ContentSpec, sticky: bool, duration_ms: u32 };

    /// 类型默认值（16.2）：停留时长、常驻、生命条、行首图标、撤销按钮。
    fn resolve(self: *Notifier, n: Notification, arena: Allocator) !Resolved {
        const has_avatar = n.avatar.len > 0;
        var actions = n.actions;
        if (n.kind == .undo and actions.len == 0) {
            actions = &.{.{ .label = self.strings.undo, .primary = true, .tag = "undo" }};
        }
        const is_hint = n.kind == .hint;
        const hint_duration = hint_mod.durationOf(n.hint_mark, n.keycap != null, actions.len > 0);
        const auto_sticky = if (is_hint) hint_duration == null else n.kind == .progress or n.reply or n.tone == .@"error" or
            (n.kind == .default and n.tone == .violet and actions.len > 0);
        const sticky = n.sticky or (n.duration_ms == null and auto_sticky);
        const duration: u32 = n.duration_ms orelse switch (n.kind) {
            .hint => hint_duration orelse 0,
            .undo => model.Durations.undo,
            .progress => model.Durations.progress_done,
            .default => switch (n.tone) {
                .success => model.Durations.success,
                .warning => model.Durations.warning,
                .quiet => model.Durations.quiet,
                .@"error", .info, .violet => model.Durations.info,
            },
        };

        // 胶囊只放一个按钮。
        const owned_actions = try arena.alloc(Action, @min(actions.len, @as(usize, if (is_hint) 1 else 2)));
        for (owned_actions, actions[0..owned_actions.len]) |*dst, src| {
            dst.* = .{
                .label = try arena.dupe(u8, src.label),
                .primary = src.primary,
                .tag = try arena.dupe(u8, src.tag),
                .shortcut = try arena.dupe(u8, src.shortcut),
            };
        }
        var keycap = n.keycap;
        if (keycap) |*k| {
            k.prefix = try arena.dupe(u8, k.prefix);
            k.key = try arena.dupe(u8, k.key);
            k.suffix = try arena.dupe(u8, k.suffix);
        }
        var progress = n.progress;
        if (progress) |*p| {
            p.label = try arena.dupe(u8, p.label);
            p.count = try arena.dupe(u8, p.count);
        } else if (n.kind == .progress) {
            progress = .{};
        }
        return .{
            .spec = .{
                .kind = n.kind,
                .tone = n.tone,
                .lead = n.lead orelse card_mod.defaultLead(n.kind, n.tone, has_avatar),
                .glyph = n.glyph,
                .avatar = try arena.dupe(u8, n.avatar),
                .title = try arena.dupe(u8, n.title),
                .body = try arena.dupe(u8, n.body),
                .actions = owned_actions,
                .reply = n.reply,
                .quote = if (n.quote) |q| try arena.dupe(u8, q) else null,
                .progress = progress,
                .life_bar = !is_hint and (n.life_bar orelse (!sticky and n.kind != .progress)),
                .hint_mark = n.hint_mark,
                .keycap = keycap,
            },
            .sticky = sticky,
            .duration_ms = duration,
        };
    }

    fn buildParams(self: *Notifier) card_mod.BuildParams {
        return .{
            .cx = self.cx,
            .scope = self.scope,
            .palette = styles.palette(self.cx.tokens),
            .strings = &self.strings,
            .width = self.options.width,
        };
    }

    fn createCard(self: *Notifier, id: Id, n: Notification) !*Card {
        // content 建好之后卡片已完整成形，之后的失败统一交给 destroyCard 一次收拾；
        // 在那之前才由下面这些逐项 errdefer 各自回收（二者互斥，避免重复释放）。
        var complete = false;
        const card = try self.allocator.create(Card);
        errdefer if (!complete) self.allocator.destroy(card);
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer if (!complete) arena.deinit();
        const r = try self.resolve(n, arena.allocator());
        const card_scope = try Scope.init(self.scope.allocator, null, self.scope.owner);
        errdefer if (!complete) card_scope.dispose();
        card.* = .{
            .allocator = self.allocator,
            .cx = self.cx,
            .id = id,
            .seq = self.next_seq,
            .positioner = undefined,
            .surface = undefined,
            .sheen = undefined,
            .highlight = undefined,
            .lifebar = undefined,
            .close = undefined,
            .close_glyph_dark = undefined,
            .close_glyph_light = undefined,
            .content = undefined,
            .arena = arena,
            .scope = card_scope,
            .spec = r.spec,
            .sticky = r.sticky,
            .life = if (r.sticky) model.Life.sticky() else .{ .duration_ms = @floatFromInt(r.duration_ms) },
            .button_sink = onButton,
            .close_sink = onClose,
            .strings = &self.strings,
            .full_width = self.options.width,
        };
        self.next_seq +%= 1;
        const params = self.buildParams();
        try card_mod.buildShell(card, params);
        errdefer if (!complete) self.cx.freeNode(card.positioner);
        card.content = try card_mod.buildContent(card, params);
        // content.scope 是独立根 scope（见 buildContent），freeNode(positioner) 不会
        // 释放它；此后 drag attach / appendChild 失败曾因此漏掉整个 content scope。
        complete = true;
        errdefer self.destroyCard(card, true);
        card_mod.rebindButtons(card);
        card.positioner.meta.ownership.hooks.on_cleanup = null;
        card.positioner.behavior.interaction.a11y = .{
            .role = if (r.spec.tone == .@"error" or r.spec.tone == .warning) .alert else .status,
            .live = if (r.spec.tone == .@"error") "assertive" else "polite",
            .live_text = card.spec.title,
        };
        // 水平拖拽关闭（阈值 84px）；✕ / 按钮区 / 回复框是不可拖拽区。
        card.drag_binding = try drag.Binding.attach(card.scope, self.cx, card.positioner, .{
            .axis = .horizontal,
            .activation_distance = 4,
            .can_start = dragCanStart,
        }, dragCallback, @ptrCast(card));
        // 触控板双指横扫等同于拖拽（挂在 surface：拖拽源已占用 positioner 的事件槽）。
        card.surface.behavior.events.on_scroll = scrollHandler;
        card.surface.behavior.events.event_context = @ptrCast(card);
        // 首帧只布局不显示：拿到真实高度后才开始入场。
        applyHidden(card);
        try self.container.appendChild(self.allocator, card.positioner);
        card.born_wall_ms = std.time.milliTimestamp();
        return card;
    }

    fn transformCard(self: *Notifier, card: *Card, n: Notification) !void {
        var old_arena = card.swapArena();
        errdefer {
            card.arena.deinit();
            card.arena = old_arena;
        }
        const r = try self.resolve(n, card.arena.allocator());
        const old_spec = card.spec;
        card.spec = r.spec;
        const params = self.buildParams();
        const form_changed = (old_spec.kind == .hint) != (r.spec.kind == .hint);
        if (form_changed) card_mod.applyShellForm(card, params);
        const new_content = card_mod.buildContent(card, params) catch |err| {
            card.spec = old_spec;
            if (form_changed) card_mod.applyShellForm(card, params);
            return err;
        };
        var old_content = card.content;
        card.content = new_content;
        card.revision +%= 1;
        card_mod.rebindButtons(card);
        card_mod.destroyContent(self.cx, card.surface, &old_content);
        old_arena.deinit();

        card.sticky = r.sticky;
        // 寿命等新内容层量到高度的那一帧再开始（frame 第 1 步）：update() 可能在帧外调用，
        // 此刻的帧时钟未必是新的。
        card.life = model.Life.sticky();
        card.life_pending_ms = if (r.sticky) null else @floatFromInt(r.duration_ms);
        card.positioner.behavior.interaction.a11y.?.live_text = card.spec.title;
        // 图标换新走一次 460ms 弹入；其余内容 200ms 交叉淡入。等量出新高度后再开始。
        card.icon_pop_at_ms = null;
        card.crossfade_at_ms = null;
        card.content.root.setOpacityRaw(0);
        card.content_pending = true;
        self.container.markRenderDirty();
    }

    fn destroyCard(self: *Notifier, card: *Card, free_nodes: bool) void {
        // 先解绑手势：scope dispose 可能派发 .cancel，此时节点仍然存活。
        card.destroying = true;
        card.drag_binding = null;
        if (!card.scope.disposed) card.scope.dispose();
        // live_text 指向 arena 里的标题；tick 期间节点释放是延迟的，先断开再释放 arena。
        if (free_nodes) {
            if (card.positioner.behavior.interaction.a11y) |*a| a.live_text = null;
        }
        if (free_nodes) {
            card_mod.destroyContent(self.cx, card.surface, &card.content);
            if (card.positioner.parent) |parent| self.cx.detachChildRetained(parent, card.positioner);
            self.cx.freeNode(card.positioner);
        } else {
            if (!card.content.scope.disposed) card.content.scope.dispose();
        }
        if (card.last_reply) |r| self.allocator.free(r);
        card.arena.deinit();
        self.allocator.destroy(card);
    }

    fn enforceScreenLimit(self: *Notifier) void {
        while (self.count() > Spec.max_on_screen) {
            var oldest: ?*Card = null;
            for (self.cards.items) |card| {
                if (card.leaving) continue;
                if (oldest == null or card.seq < oldest.?.seq) oldest = card;
            }
            self.beginLeave(oldest orelse return, false);
        }
    }

    fn beginLeave(self: *Notifier, card: *Card, by_user: bool) void {
        if (card.leaving) return;
        card.leaving = true;
        card.closed_by_user = by_user;
        // 退场时终止进行中的手势（被挤出同屏上限 / 到期时用户可能正按着）。
        if (card.dragging and !card.scroll_dragging) {
            if (card.drag_binding) |b| b.cancel(.explicit);
        }
        card.dragging = false;
        card.scroll_dragging = false;
        // 不在这里取时间：可能身处事件回调或命中测试的重入 tick，帧时钟是旧的。
        // 下一个真实帧再盖戳（frame 第 0 步）。
        card.left_at_ms = if (self.in_frame) self.last_now_ms else null;
        card.positioner.setHitTestVisible(false);
        card.close.setHitTestVisible(false);
        if (!card.measured) card.instant_exit = true; // 从未显示过：直接收掉
        self.container.markRenderDirty();
    }

    // ────────────────────────────────────────────────────────────────────
    // 事件（按钮 / 关闭），点击发生在事件栈里，挪到下一帧处理：处理可能
    // 移除被点的按钮本身（原地转换换掉按钮区）。
    // ────────────────────────────────────────────────────────────────────

    fn onButton(card: *Card, index: u8) void {
        const self = notifierOf(card) orelse return;
        self.pending.append(self.allocator, .{ .button = .{ .id = card.id, .seq = card.seq, .revision = card.revision, .index = index } }) catch return;
        self.container.markRenderDirty();
    }

    fn clearAllEvent(event: events.Event, context: ?*anyopaque) events.EventResult {
        const self: *Notifier = @ptrCast(@alignCast(context orelse return .ignored));
        if (self.closed) return .ignored;
        switch (event) {
            // 移开即收回（未确认的清除不保留）。
            .mouse_leave => self.setClearArmed(false),
            .click => |c| if (c.button == .left) {
                self.activateClear();
                return .stop;
            },
            .key_down => |k| if (k.key == .@"return" or k.key == .space) {
                self.activateClear();
                return .stop;
            },
            else => {},
        }
        return .ignored;
    }

    /// 第一下展开确认，第二下清除（iOS 通知中心同款两步）。
    fn activateClear(self: *Notifier) void {
        if (self.clear_armed) {
            self.setClearArmed(false);
            self.clearAll();
        } else {
            self.setClearArmed(true);
        }
    }

    fn setClearArmed(self: *Notifier, armed: bool) void {
        if (self.clear_armed == armed) return;
        self.clear_armed = armed;
        self.container.markRenderDirty();
        self.cx.requestRedraw();
    }

    /// 用户「全部清除」：所有在屏提醒按用户关闭退场（逐条回调 `.dismissed`）。
    pub fn clearAll(self: *Notifier) void {
        if (self.closed) return;
        self.pending.append(self.allocator, .clear_all) catch return;
        self.container.markRenderDirty();
        self.cx.requestRedraw();
    }

    fn onClose(card: *Card) void {
        const self = notifierOf(card) orelse return;
        self.pending.append(self.allocator, .{ .close = .{ .id = card.id, .seq = card.seq, .revision = card.revision } }) catch return;
        self.container.markRenderDirty();
    }

    fn notifierOf(card: *Card) ?*Notifier {
        const portal_child = card.positioner.parent orelse return null;
        const ptr = portal_child.meta.per_frame.hooks.slots.anim_state orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    fn emit(self: *Notifier, event: Event) void {
        const l = self.options.listener orelse return;
        l.callback(l.context, self, event);
    }

    fn processPending(self: *Notifier) void {
        var i: usize = 0;
        while (i < self.pending.items.len) : (i += 1) {
            const op = self.pending.items[i];
            switch (op) {
                .close => |target| if (self.findLive(target.id)) |card| {
                    if (card.seq != target.seq or card.revision != target.revision) continue;
                    self.beginLeave(card, true);
                    self.emit(.{ .id = target.id, .kind = .dismissed });
                },
                .clear_all => {
                    // 先收 id：emit 的回调里可能再 show / dismiss 改动卡片表。
                    var ids: [Spec.max_on_screen * 2]Id = undefined;
                    var n: usize = 0;
                    for (self.cards.items) |card| {
                        if (card.leaving or n >= ids.len) continue;
                        ids[n] = card.id;
                        n += 1;
                    }
                    for (ids[0..n]) |id| {
                        const card = self.findLive(id) orelse continue;
                        // 一次清空不补位：每张卡在原位淡出，避免退场中重排出叠影。
                        card.hold_space = true;
                        self.beginLeave(card, true);
                        self.emit(.{ .id = id, .kind = .dismissed });
                        if (self.closed) return;
                    }
                },
                .button => |b| if (self.findLive(b.id)) |card| {
                    if (card.seq != b.seq or card.revision != b.revision) continue;
                    if (b.index == card_mod.send_index) {
                        self.sendReply(card);
                        continue;
                    }
                    if (b.index >= card.spec.actions.len) continue;
                    const action = card.spec.actions[b.index];
                    if (card.spec.kind == .undo and std.mem.eql(u8, action.tag, "undo")) {
                        self.settleUndo(card);
                        self.emit(.{ .id = b.id, .kind = .undo, .tag = "undo", .index = b.index });
                    } else {
                        const revision = card.revision;
                        self.emit(.{ .id = b.id, .kind = .action, .tag = action.tag, .index = b.index });
                        if (self.closed) return;
                        // 文案提示：宿主没在回调里原地转换它，点过即收起。
                        if (self.findLive(b.id)) |c| {
                            if (c == card and c.spec.kind == .hint and c.revision == revision) self.beginLeave(c, false);
                        }
                    }
                },
            }
        }
        self.pending.clearRetainingCapacity();
    }

    /// 发送回复：回复框换成回复内容的引用，头像换成 ✓，2200ms 后收起（16.6）。
    /// 发送失败时调用方用 replyFailed() 把卡片原地转成错误并恢复输入。
    fn sendReply(self: *Notifier, card: *Card) void {
        const state = card.content.reply_state orelse return;
        const raw = std.mem.trim(u8, state.getText(), " \t\r\n");
        if (raw.len == 0) return;
        // 先复制全部需要的字符串，最后才替换 last_reply：任一步失败都不丢旧状态。
        const title = self.allocator.dupe(u8, card.spec.title) catch return;
        defer self.allocator.free(title);
        const body = self.allocator.dupe(u8, card.spec.body) catch return;
        defer self.allocator.free(body);
        const owned = self.allocator.dupe(u8, raw) catch return;
        if (card.last_reply) |old| self.allocator.free(old);
        card.last_reply = owned;
        self.transformCard(card, .{
            .tone = .success,
            .title = title,
            .body = body,
            .quote = owned,
            .duration_ms = model.Durations.reply_settle,
        }) catch return;
        self.emit(.{ .id = card.id, .kind = .reply, .text = owned });
    }

    /// 回复发送失败：原地转为错误类型并把刚才的内容恢复进回复框。
    pub fn replyFailed(self: *Notifier, id: Id, title: []const u8, body: []const u8) void {
        const card = self.findLive(id) orelse return;
        self.transformCard(card, .{
            .tone = .@"error",
            .avatar = "",
            .title = title,
            .body = body,
            .reply = true,
        }) catch return;
        if (card.last_reply) |text| {
            if (card.content.reply_state) |st| _ = st.setText(text);
        }
    }

    /// 点「撤销」：倒计时环停止并换成 ✓，2400ms 后收起（16.6）。
    fn settleUndo(self: *Notifier, card: *Card) void {
        self.transformCard(card, .{
            .kind = .default,
            .tone = .success,
            .title = card.spec.title,
            .body = card.spec.body,
            .duration_ms = model.Durations.undo_settle,
        }) catch {};
    }

    // ────────────────────────────────────────────────────────────────────
    // 拖拽 / 横扫关闭（16.7）
    // ────────────────────────────────────────────────────────────────────

    fn dragCanStart(req: drag.StartRequest, ctx: *anyopaque) bool {
        _ = req;
        const card: *Card = @ptrCast(@alignCast(ctx));
        if (card.leaving) return false;
        // 在不可拖拽区按下不开始滑动手势：✕、按钮区、回复框。
        var node = card.cx.dispatcher.mouseDownNode();
        while (node) |nd| : (node = nd.parent) {
            if (nd == card.positioner) break;
            if (nd == card.close) return false;
            if (card.content.footer) |f| if (nd == f) return false;
        }
        return true;
    }

    fn dragCallback(ev: drag.Event, ctx: *anyopaque) void {
        const card: *Card = @ptrCast(@alignCast(ctx));
        // 销毁 / 退场中（含 scope dispose 派发的 .cancel）：只复位，不碰 Notifier 与节点。
        if (card.destroying or card.leaving) {
            card.dragging = false;
            card.scroll_dragging = false;
            return;
        }
        const self = notifierOf(card) orelse return;
        switch (ev.phase) {
            .start => {
                // 鼠标接管横扫：从当前位移继续，并结束横扫状态（否则横扫的静默超时会在
                // 用户仍按住时替他「松手」）。
                card.drag_base = if (card.scroll_dragging) card.drag_dx else 0;
                card.scroll_dragging = false;
                card.dragging = true;
                card.spring_at_ms = null;
                card.spring_pending = false;
                card.drag_dx = card.drag_base + ev.delta.x;
            },
            .move => {
                card.dragging = true;
                card.drag_dx = card.drag_base + ev.delta.x;
            },
            .end => {
                card.drag_dx = card.drag_base + ev.delta.x;
                self.releaseDrag(card);
            },
            .cancel => {
                card.drag_dx = card.drag_base + ev.delta.x;
                self.springBack(card);
            },
        }
        self.container.markRenderDirty();
    }

    fn scrollHandler(ev: events.ScrollEvent, ctx: ?*anyopaque) core.EventResult {
        const card: *Card = @ptrCast(@alignCast(ctx orelse return .ignored));
        const self = notifierOf(card) orelse return .ignored;
        if (card.leaving or card.dragging and !card.scroll_dragging) return .ignored;
        // 惯性阶段不驱动（松手判定已在静默超时里完成）。
        if (ev.isMomentum()) return if (card.scroll_dragging) .stop else .ignored;
        if (!card.scroll_dragging and @abs(ev.dx) <= @abs(ev.dy) * 1.2) return .ignored;
        card.scroll_dragging = true;
        card.dragging = true;
        card.spring_at_ms = null;
        card.spring_pending = false;
        card.drag_dx += ev.dx;
        card.last_scroll_wall_ms = std.time.milliTimestamp();
        if (ev.phaseEnded()) self.releaseDrag(card);
        self.container.markRenderDirty();
        return .stop;
    }

    fn releaseDrag(self: *Notifier, card: *Card) void {
        const dx = model.constrainSwipe(self.options.position, card.drag_dx);
        card.dragging = false;
        card.scroll_dragging = false;
        if (model.swipeCommits(self.options.position, dx)) {
            // 超过 84px：关闭并沿方向甩出（退场里按 flingX × (1 + 1.1p) 继续外飞）。
            card.fling_x = dx;
            card.drag_dx = 0;
            self.beginLeave(card, true);
            self.emit(.{ .id = card.id, .kind = .dismissed });
        } else {
            self.springBack(card);
        }
    }

    fn springBack(self: *Notifier, card: *Card) void {
        card.dragging = false;
        card.scroll_dragging = false;
        // 从显示位置（橡皮筋阻尼后）弹回，而不是原始位移，否则反方向拖动松手时先跳后回。
        card.drag_dx = model.constrainSwipe(self.options.position, card.drag_dx);
        card.spring_from = card.drag_dx;
        card.spring_at_ms = if (self.in_frame) self.last_now_ms else null;
        card.spring_pending = !self.in_frame;
    }

    // ────────────────────────────────────────────────────────────────────
    // 逐帧驱动
    // ────────────────────────────────────────────────────────────────────

    fn frameHook(node: *Node) void {
        const self: *Notifier = @ptrCast(@alignCast(node.meta.per_frame.hooks.slots.anim_state orelse return));
        if (self.closed) return;
        self.frame();
    }

    fn frame(self: *Notifier) void {
        const now = self.cx.frame_time_ms;
        // 只在帧时钟真正推进过的帧里做事：命中测试的重入 tick 会用旧时钟再跑一次
        // hook（实测：idle 停帧期间点 ✕，退场起点盖了 470ms 前的旧戳，下一真实帧时钟
        // 一步跳过整段空档，退场一帧走完）。所有时间戳都在这里统一盖。
        if (self.ran_once and now == self.last_now_ms) return;
        self.ran_once = true;
        self.last_now_ms = now;
        self.in_frame = true;
        defer self.in_frame = false;
        for (self.cards.items) |card| {
            if (card.leaving and card.left_at_ms == null) card.left_at_ms = now;
            if (card.spring_pending) {
                card.spring_pending = false;
                card.spring_at_ms = now;
            }
        }
        self.processPending();
        // listener 回调里可能关掉整个 Notifier（dispose scope / 关窗）。
        if (self.closed) return;

        // 触控板横扫没有 up：真实静默 140ms 视为松手。
        const wall = std.time.milliTimestamp();
        for (self.cards.items) |card| {
            if (card.scroll_dragging and wall - card.last_scroll_wall_ms > 140) self.releaseDrag(card);
        }

        // 1. 量高度：首帧拿到真实高度后才诞生（born = 此刻），入场从这一帧开始。
        for (self.cards.items) |card| {
            const content_h = card.content.root.rectFromWorldOrFallback().h;
            if (content_h <= 0) continue;
            const h = content_h + (if (card.lifebar.style.height == .px) card.lifebar.style.height.px else 0);
            if (!card.measured) {
                card.measured = true;
                card.born_ms = now;
                if (!card.sticky) card.life = model.Life.start(card.life.duration_ms, now);
                if (self.paused) card.life.pause(now);
                card.icon_pop_at_ms = now;
            }
            if (card.content_pending) {
                card.content_pending = false;
                if (card.life_pending_ms) |d| {
                    card.life = model.Life.start(d, now);
                    if (self.paused) card.life.pause(now);
                    card.life_pending_ms = null;
                }
                card.icon_pop_at_ms = now;
                card.crossfade_at_ms = now;
            }
            card.natural_height = h;
            card.natural_width = if (card.spec.kind == .hint) card.content.root.rectFromWorldOrFallback().w else self.options.width;
        }

        // 2. 悬停：对整组外接矩形 +18px 做命中测试；退场期间冻结。
        var any_leaving = false;
        for (self.cards.items) |card| {
            if (card.leaving) any_leaving = true;
        }
        // 指针停在角标 / 全部清除圆钮上时冻结展开状态：它们的位置跟着堆叠外沿走，
        // 若照常判定，展开 -> 控件上移离开指针 -> 收起 -> 控件回到指针下 … 来回闪烁。
        if (!any_leaving and !self.pointerOverControls()) {
            const want = self.hitTestStack() or self.anyDragging();
            if (want != self.hovered) self.setHovered(want, now);
        }
        if (self.hovered and self.count() == 0 and !any_leaving) self.setHovered(false, now);

        // 3. 到期：按剩余寿命收起。
        // 先收集再回调：listener 里可能 show()，追加 self.cards 会让正在遍历的切片失效。
        if (!self.paused) {
            var expired_ids: [64]Id = undefined;
            var n_expired: usize = 0;
            for (self.cards.items) |card| {
                if (!card.measured or card.leaving) continue;
                if (card.life.expired(now)) {
                    self.beginLeave(card, false);
                    if (n_expired < expired_ids.len) {
                        expired_ids[n_expired] = card.id;
                        n_expired += 1;
                    }
                }
            }
            for (expired_ids[0..n_expired]) |id| {
                self.emit(.{ .id = id, .kind = .expired });
                if (self.closed) return;
            }
        }

        // 4. 展开进度（540ms，重排曲线）。
        const expanding = self.stepExpand(now);

        // 5. 求解堆叠并写入节点。
        self.layoutAndApply(now, any_leaving or expanding);

        // 6. 回收退场完毕的卡片；随后下一帧按指针真实坐标复核悬停。
        var i: usize = 0;
        while (i < self.cards.items.len) {
            const card = self.cards.items[i];
            if (card.leaving and (card.instant_exit or model.exitMotion(card.exitElapsed(now)).done)) {
                _ = self.cards.orderedRemove(i);
                self.destroyCard(card, true);
                // tick 内的摘除 / 释放由框架推迟到后续遍历执行：再要一帧让它落地，
                // 否则此刻就停帧的话节点会一直留在树上（实测：退场完卡片文字仍可查到）。
                self.reclaimed_this_frame = true;
                continue;
            }
            i += 1;
        }

        // 帧调度：容器自身不画东西，只 markRenderDirty 产生不了实际变化，
        // idle 门控会停帧（实测：悬停暂停后按 Enter 发送，新内容层要等下一个
        // 外部事件才出现）。仍在动时显式请求下一帧；完全静止时交给 idle 停帧，
        // 只安排 1s 后唤醒一次刷新相对时间戳。
        if (self.reclaimed_this_frame) {
            self.reclaimed_this_frame = false;
            self.cx.requestRedraw();
            self.container.markRenderDirty();
        }
        if (self.isAnimating(now)) {
            self.cx.requestRedraw();
            // 容器挂在 portal 根下（不在 cx.root 里）：portal 树的 before_render 遍历
            // 按它自己的脏位门控，不标脏，下一帧本 hook 不执行，动画停在半路（实测：
            // 退场卡片停在淡出中途、永不回收）。容器自身不绘制、子树走缓存，开销很小。
            self.container.markRenderDirty();
        } else if (self.cards.items.len > 0) {
            self.cx.scheduleRedrawAfterNs(std.time.ns_per_s);
        }
    }

    fn isAnimating(self: *const Notifier, now: f64) bool {
        if (self.expand_value != self.expand_to) return true;
        if (self.pending.items.len > 0) return true;
        const pill_target: f32 = if (self.pill_alpha > 0.001 and self.pill_alpha < 0.999) 0.5 else self.pill_alpha;
        if (pill_target == 0.5) return true;
        if (self.clear_alpha > 0.001 and self.clear_alpha < 0.999) return true;
        if (self.clear_reveal_t != (if (self.clear_armed) @as(f32, 1) else 0)) return true;
        for (self.cards.items) |card| {
            if (!card.measured or card.content_pending or card.leaving or card.dragging) return true;
            if (card.crossfade_at_ms != null or card.icon_pop_at_ms != null or card.spring_at_ms != null) return true;
            if (now - card.born_ms < Spec.young_ms) return true;
            if (card.follow_y.active) return true;
            if (card.close_alpha > 0.001 and card.close_alpha < 0.999) return true;
            // 旋转指示器常转；生命条 / 倒计时环在计时（未暂停）时每帧推进。
            if (card.content.spinner != null) return true;
            if (!self.paused and !card.sticky) return true;
        }
        return false;
    }

    fn anyDragging(self: *const Notifier) bool {
        for (self.cards.items) |card| if (card.dragging) return true;
        return false;
    }

    fn setHovered(self: *Notifier, hovered: bool, now: f64) void {
        self.hovered = hovered;
        // 命中即暂停所有计时；生命条与倒计时环同时停住，移开后从停住处继续。
        if (hovered and !self.paused) {
            self.paused = true;
            for (self.cards.items) |card| card.life.pause(now);
        } else if (!hovered and self.paused) {
            self.paused = false;
            for (self.cards.items) |card| card.life.@"resume"(now);
        }
        const target: f32 = if (hovered and self.options.expand_on_hover) 1 else 0;
        if (target != self.expand_to) {
            self.expand_from = self.expand_value;
            self.expand_to = target;
            self.expand_start_ms = now;
        }
    }

    fn stepExpand(self: *Notifier, now: f64) bool {
        if (self.expand_value == self.expand_to) return false;
        const p = model.progressOf(now - self.expand_start_ms, Spec.expand_ms);
        self.expand_value = model.lerp(self.expand_from, self.expand_to, model.reflowEase(p));
        if (p >= 1) self.expand_value = self.expand_to;
        return true;
    }

    fn pointerInWindow(self: *const Notifier) ?struct { x: f32, y: f32 } {
        const x = self.cx.mouse_x;
        const y = self.cx.mouse_y;
        const vp = self.container.rectFromWorldOrFallback();
        if (x < 0 or y < 0 or x >= vp.w or y >= vp.h) return null;
        return .{ .x = x, .y = y };
    }

    fn pointerOverControls(self: *const Notifier) bool {
        const ptr = self.pointerInWindow() orelse return false;
        const controls = [_]struct { node: *Node, alpha: f32 }{
            .{ .node = self.pill, .alpha = self.pill_alpha },
            .{ .node = self.clear_btn, .alpha = self.clear_alpha },
        };
        for (controls) |c| {
            if (c.alpha < 0.5) continue;
            const r = c.node.rectFromWorldOrFallback();
            const x = c.node.style.translate_x;
            const y = c.node.style.translate_y;
            if (ptr.x >= x and ptr.x <= x + r.w and ptr.y >= y and ptr.y <= y + r.h) return true;
        }
        return false;
    }

    fn hitTestStack(self: *const Notifier) bool {
        const ptr = self.pointerInWindow() orelse return false;
        var any = false;
        var x0: f32 = std.math.inf(f32);
        var y0: f32 = std.math.inf(f32);
        var x1: f32 = -std.math.inf(f32);
        var y1: f32 = -std.math.inf(f32);
        for (self.cards.items) |card| {
            if (!card.rect_visible or card.leaving) continue;
            any = true;
            x0 = @min(x0, card.rect_x);
            y0 = @min(y0, card.rect_y);
            x1 = @max(x1, card.rect_x + card.rect_w);
            y1 = @max(y1, card.rect_y + card.rect_h);
        }
        if (!any) return false;
        const s = Spec.hover_slop;
        return ptr.x >= x0 - s and ptr.x <= x1 + s and ptr.y >= y0 - s and ptr.y <= y1 + s;
    }

    fn layoutAndApply(self: *Notifier, now: f64, continuous_all: bool) void {
        const pal = styles.palette(self.cx.tokens);
        const position = self.options.position;
        const W = self.options.width;

        // 按层序（最新在前）排列已测量的卡片。
        var order: [64]*Card = undefined;
        var n: usize = 0;
        for (self.cards.items) |card| {
            if (!card.measured) continue;
            if (n == order.len) break;
            order[n] = card;
            n += 1;
        }
        std.mem.sort(*Card, order[0..n], {}, struct {
            fn newerFirst(_: void, a: *Card, b: *Card) bool {
                return a.seq > b.seq;
            }
        }.newerFirst);

        var inputs: [64]model.StackInput = undefined;
        var outs: [64]model.StackOutput = undefined;
        for (order[0..n], 0..) |card, i| {
            const exit = if (card.leaving) model.exitMotion(card.exitElapsed(now)) else null;
            inputs[i] = .{
                .height = card.natural_height,
                .width = if (card.natural_width > 0) card.natural_width else W,
                .weight = if (exit) |x| (if (card.hold_space) 1 else x.weight) else 1,
                .leaving = card.leaving,
                .quiet = card.spec.tone == .quiet and card.spec.lead == .dot,
            };
        }
        model.solveStack(inputs[0..n], .{ .expand = self.expand_value, .max_visible = self.options.max_visible }, outs[0..n]);

        // 锚点（窗口坐标）。
        const vp = self.container.rectFromWorldOrFallback();
        const ins = self.options.content_insets;
        const area_x = ins.left;
        const area_y = ins.top;
        const area_w = @max(0, vp.w - ins.left - ins.right);
        const area_h = @max(0, vp.h - ins.top - ins.bottom);
        const inset = Spec.edge_inset;
        const base_x: f32 = switch (position.hAlign()) {
            .left => area_x + inset,
            .center => area_x + (area_w - W) / 2,
            .right => area_x + area_w - inset - W,
        };
        const extent = model.stackExtent(outs[0..n]);
        const sign = position.sign();

        const anchor_ref: f32 = switch (position.vAnchor()) {
            .top => area_y,
            .bottom => area_y + area_h,
            .middle => area_y + area_h / 2,
        };
        if (self.last_anchor_ref) |prev| {
            const delta = anchor_ref - prev;
            if (delta != 0) {
                for (self.cards.items) |card| card.follow_y.shift(delta);
            }
        }
        self.last_anchor_ref = anchor_ref;

        var ptr_card: ?*Card = null;
        const ptr = self.pointerInWindow();

        var stack_min_y: f32 = std.math.inf(f32);
        var stack_max_y: f32 = -std.math.inf(f32);
        var shown: usize = 0;

        for (order[0..n], 0..) |card, i| {
            const o = outs[i];
            const age = now - card.born_ms;
            const enter = model.enterMotion(age);
            const exit = if (card.leaving) model.exitMotion(card.exitElapsed(now)) else null;

            // 近锚点边 -> 卡片顶边。
            const top: f32 = switch (position.vAnchor()) {
                .top => area_y + inset + o.offset,
                .bottom => area_y + area_h - inset - o.offset - o.clip_height,
                .middle => area_y + (area_h - extent) / 2 + o.offset,
            };
            const young = age < Spec.young_ms;
            const continuous = continuous_all or young or card.dragging;
            const y = card.follow_y.step(top, now, continuous);

            // 附加位移：入场、退场漂移、拖拽 / 甩出。
            const entry_offset = position.entryOffset(Spec.enter_distance);
            var dx: f32 = entry_offset.x * enter.offset;
            var dy: f32 = entry_offset.y * enter.offset;
            var scale = enter.scale;
            var alpha = enter.alpha * o.visibility;
            if (exit) |x| {
                dy += sign * x.drift;
                scale *= x.scale;
                alpha *= x.alpha;
                dx += card.fling_x * x.fling_gain;
            } else {
                dx += self.stepSpring(card, now);
                alpha *= model.swipeAlpha(card.drag_dx);
            }

            // 原地转换的交叉淡入。
            var content_alpha = o.content_alpha;
            if (card.content_pending) {
                content_alpha = 0;
            } else if (card.crossfade_at_ms) |t0| {
                const p = model.progressOf(now - t0, Spec.crossfade_ms);
                content_alpha *= p;
                if (p >= 1) card.crossfade_at_ms = null;
            }

            // 胶囊比卡片窄：按停靠方向对齐到卡片列（居中 / 贴左 / 贴右）。
            // 可见宽度：折叠态后层收拢到最前那张的宽度，展开时恢复自身宽度。
            const cw = if (o.clip_width > 0) o.clip_width else W;
            const align_dx: f32 = switch (position.hAlign()) {
                .left => 0,
                .center => (W - cw) / 2,
                .right => W - cw,
            };
            const x_pos = base_x + align_dx + dx;
            const y_pos = y + dy;
            applyCard(card, pal, .{
                .x = x_pos,
                .y = y_pos,
                .scale_x = o.scale * scale,
                .scale_y = scale,
                .alpha = alpha,
                .glass_alpha = o.glass_alpha,
                .content_alpha = content_alpha,
                .clip_height = o.clip_height,
                .clip_width = cw,
                .rank = @intCast(@min(i, 60)),
                .now = now,
                .age = age,
            });

            // 命中矩形：盒子尺寸围绕中心收缩，按视觉尺寸记录。
            const vis_w = cw * o.scale * scale;
            const vis_h = o.clip_height * scale;
            card.rect_x = x_pos + (cw - vis_w) / 2;
            card.rect_y = y_pos + (o.clip_height - vis_h) / 2;
            card.rect_w = vis_w;
            card.rect_h = vis_h;
            card.rect_visible = alpha > 0.02;
            card.rank = @intCast(@min(i, 60));

            if (card.rect_visible and !card.leaving) {
                shown += 1;
                stack_min_y = @min(stack_min_y, card.rect_y);
                stack_max_y = @max(stack_max_y, card.rect_y + card.rect_h);
                if (ptr) |pp| {
                    if (ptr_card == null and pp.x >= card.rect_x and pp.x <= card.rect_x + card.rect_w and
                        pp.y >= card.rect_y and pp.y <= card.rect_y + card.rect_h) ptr_card = card;
                }
            }
        }

        // 关闭钮两档：指针正压着的那张实心深色白叉，其余浅色芯片（16.7）。
        const dt: f32 = @floatCast(@max(0, @min(64, now - self.last_frame_ms)));
        self.last_frame_ms = now;
        for (order[0..n]) |card| {
            // 文案提示没有关闭钮（横扫仍可关）。
            const want: f32 = if (self.hovered and card.spec.kind != .hint and !card.leaving and card.rect_visible and card.content.root.getOpacity() > 0.5) 1 else 0;
            const step = dt / @as(f32, @floatCast(Spec.close_fade_ms));
            card.close_alpha = if (want > card.close_alpha) @min(want, card.close_alpha + step) else @max(want, card.close_alpha - step);
            applyClose(card, pal, card == ptr_card);
        }

        self.applyPill(pal, now, dt, shown, base_x, W, stack_min_y, stack_max_y);
    }

    fn stepSpring(self: *Notifier, card: *Card, now: f64) f32 {
        if (card.dragging) return model.constrainSwipe(self.options.position, card.drag_dx);
        if (card.spring_at_ms) |t0| {
            const p = model.progressOf(now - t0, Spec.reflow_ms);
            card.drag_dx = model.lerp(card.spring_from, 0, model.reflowEase(p));
            if (p >= 1) {
                card.spring_at_ms = null;
                card.drag_dx = 0;
            }
            return card.drag_dx;
        }
        return 0;
    }

    fn applyPill(self: *Notifier, pal: *const styles.Palette, now: f64, dt: f32, shown: usize, base_x: f32, W: f32, min_y: f32, max_y: f32) void {
        _ = now;
        const live = self.count();
        const want_paused = self.hovered and live >= 1;
        const want_more = !self.hovered and live >= 2;
        const want: f32 = if ((want_paused or want_more) and shown > 0) 1 else 0;
        const step = dt / @as(f32, @floatCast(Spec.close_fade_ms));
        self.pill_alpha = if (want > self.pill_alpha) @min(want, self.pill_alpha + step) else @max(want, self.pill_alpha - step);

        // 文案随状态切换（仅在变化时换文本）。
        if (want > 0) {
            const count_key: i64 = if (want_paused) -2 else @intCast(live - 1);
            if (count_key != self.pill_shown_count) {
                self.pill_shown_count = count_key;
                var buf: [96]u8 = undefined;
                const label = if (want_paused) self.strings.paused else card_mod.formatCount(&buf, self.strings.more, live - 1);
                self.pill_label.setTextContent(self.allocator, label) catch {};
                self.pill_label.markSizingDirty();
                self.pill.markSizingDirty();
                self.pill_icon_more.style.width = .fixed(if (want_paused) 0 else M.pill_icon);
                self.pill_icon_paused.style.width = .fixed(if (want_paused) M.pill_icon else 0);
                self.pill_icon_more.markSizingDirty();
                self.pill_icon_paused.markSizingDirty();
            }
        }

        const a = self.pill_alpha;
        // 「全部清除」：同屏 ≥2 条时与角标并排出现。
        const want_clear: f32 = if (live >= 2 and shown > 0) 1 else 0;
        self.clear_alpha = if (want_clear > self.clear_alpha) @min(want_clear, self.clear_alpha + step) else @max(want_clear, self.clear_alpha - step);
        const pill_rect = self.pill.rectFromWorldOrFallback();
        const clear_rect = self.clear_btn.rectFromWorldOrFallback();
        if (shown > 0) {
            // 角标与圆钮作为一组，按停靠方向对齐到卡片列：居中停靠居中，左右停靠贴边
            // （文案提示胶囊比卡片窄且贴边，居中会让角标悬在胶囊旁边的空处）。
            const pill_w: f32 = if (want > 0) pill_rect.w else 0;
            const clear_w: f32 = if (want_clear > 0) clear_rect.w else 0;
            const gap: f32 = if (pill_w > 0 and clear_w > 0) M.clear_gap else 0;
            const group_w = pill_w + gap + clear_w;
            const px = switch (self.options.position.hAlign()) {
                .left => base_x,
                .center => base_x + (W - group_w) / 2,
                .right => base_x + W - group_w,
            };
            const py = if (self.options.position.pillAbove()) min_y - M.pill_gap - M.pill_height else max_y + M.pill_gap;
            if (@abs(self.pill.style.translate_x - px) > 0.001 or @abs(self.pill.style.translate_y - py) > 0.001) {
                self.pill.style.translate_x = px;
                self.pill.style.translate_y = py;
                self.pill.markCompositeAnimFrameDirty();
            }
            const cx_ = px + pill_w + gap;
            if (@abs(self.clear_btn.style.translate_x - cx_) > 0.001 or @abs(self.clear_btn.style.translate_y - py) > 0.001) {
                self.clear_btn.style.translate_x = cx_;
                self.clear_btn.style.translate_y = py;
                self.clear_btn.markCompositeAnimFrameDirty();
            }
        }
        // 角标也是玻璃：用节点 opacity 整体淡入淡出，模糊与底色保持恒定。
        animBackground(self.pill, pal.pill_bg);
        animOpacity(self.pill, a);
        // 展开 / 收回：200ms，宽度用强减速，文字在后半段淡入（收回时先淡出）。
        if (self.clear_alpha < 0.5 and self.clear_armed) self.clear_armed = false;
        const reveal_target: f32 = if (self.clear_armed) 1 else 0;
        const rstep = dt / @as(f32, @floatCast(Spec.clear_reveal_ms));
        // 夹在目标值上：已到目标时不能按收回方向再走一步（空闲唤醒帧 dt 大，曾把 1 砍到 0.68 -> 周期性闪烁）。
        self.clear_reveal_t = if (reveal_target > self.clear_reveal_t) @min(reveal_target, self.clear_reveal_t + rstep) else @max(reveal_target, self.clear_reveal_t - rstep);
        const label_w = self.clear_label.rectFromWorldOrFallback().w + 8; // + margin 5 / 3
        const rw = label_w * model.enterEase(self.clear_reveal_t);
        if (self.clear_reveal.style.width != .px or @abs(self.clear_reveal.style.width.px - rw) > 0.05) {
            self.clear_reveal.style.width = .fixed(rw);
            self.clear_reveal.markSizingDirty();
        }
        animOpacity(self.clear_label, model.clamp01((self.clear_reveal_t - 0.35) / 0.65));
        animBackground(self.clear_btn, pal.pill_bg);
        animOpacity(self.clear_btn, self.clear_alpha);
        self.clear_btn.setHitTestVisible(self.clear_alpha > 0.5);
    }
};

// ============================================================================
// 节点写入
// ============================================================================

const Frame = struct {
    x: f32,
    y: f32,
    scale_x: f32,
    scale_y: f32,
    /// 整卡可见度（入场 × 退场 × 层可见 × 拖拽）。
    alpha: f32,
    glass_alpha: f32,
    content_alpha: f32,
    clip_height: f32,
    clip_width: f32,
    rank: u8,
    now: f64,
    age: f64,
};

/// 逐帧写 opacity：值变了才写；从不可见变为可见按一次性状态切换标脏（作废渲染缓存，
/// 否则 opacity 0 时被跳过绘制的子树会被当作干净子树沿用空的显示内容，实测：悬停
/// 暂停后原地转换的新内容层整块不显示）；其余按动画帧标脏（保留 surface 复用）。
fn animOpacity(node: *Node, value: f32) void {
    const old = node.getOpacity();
    if (@abs(old - value) < 0.001) return;
    node.setOpacityRaw(value);
    if (old < 0.001) node.markCompositePropDirty() else node.markCompositeAnimFrameDirty();
}

fn animBackground(node: *Node, color: Color) void {
    if (Color.eql(node.getBackground(), color)) return;
    node.setBackgroundRaw(color);
    node.markRenderDirty();
}

fn applyHidden(card: *Card) void {
    card.positioner.style.translate_x = -10_000;
    card.positioner.style.translate_y = -10_000;
    card.positioner.setOpacityRaw(0);
    card.content.root.setOpacityRaw(0);
    card.positioner.setHitTestVisible(false);
}

fn applyCard(card: *Card, pal: *const styles.Palette, f: Frame) void {
    const a = model.clamp01(f.alpha);
    card.draw_alpha = a;
    card.draw_now_ms = f.now;

    // 整卡用真实的 transform scale + 节点 opacity：玻璃在离屏合成层里按世界坐标
    // 采样背景（框架已修，见 render/backdrop_blur.zig offscreenLocalRectToWorld），
    // 模糊半径与底色保持恒定，淡出时整块玻璃（含模糊背板）一起按 opacity 合成。
    // alpha == 1 且 scale == 1 时不开离屏层，零额外开销。
    const p = card.positioner;
    // 只在值真的变化时标脏：静止卡片不应让整张卡每帧重新生成。
    var moved = @abs(p.style.translate_x - f.x) > 0.001 or @abs(p.style.translate_y - f.y) > 0.001;
    p.style.translate_x = f.x;
    p.style.translate_y = f.y;
    if (p.style.ext) |e| {
        const z = @as(i16, 100) - @as(i16, f.rank);
        if (e.z_index != z) {
            e.z_index = z;
            p.markRenderDirty();
        }
        if (@abs(e.scale_x - f.scale_x) > 0.0001 or @abs(e.scale_y - f.scale_y) > 0.0001) {
            e.scale_x = f.scale_x;
            e.scale_y = f.scale_y;
            moved = true;
        }
    }
    if (moved) p.markCompositeAnimFrameDirty();
    animOpacity(p, a);
    p.setHitTestVisible(!card.leaving and a > 0.5);

    // 玻璃密度 A（折叠后层更实，避免下层文字透出）。
    const s = card.surface;
    animBackground(s, pal.glass(f.glass_alpha));
    // 裁切高度：折叠态非最前层被裁到最前那张的高度。
    const natural = card.natural_height;
    const want_fixed = @abs(f.clip_height - natural) > 0.5;
    const cur_fixed = s.style.height == .px;
    if (want_fixed) {
        if (!cur_fixed or @abs(s.style.height.px - f.clip_height) > 0.25) {
            s.style.height = .fixed(@max(0, f.clip_height));
            s.markSizingDirty();
        }
    } else if (cur_fixed) {
        s.style.height = .{ .fit = .{} };
        s.markSizingDirty();
    }

    applyClipWidth(card, f.clip_width);

    // 内容层（折叠后层隐藏 / 原地转换交叉淡入）+ 分层错峰入场。
    const c = &card.content;
    const content_a = model.clamp01(f.content_alpha);
    animOpacity(c.root, content_a);
    c.root.setHitTestVisible(content_a > 0.5);
    applyStagger(card, f.age);

    // 图标弹入（入场与原地换图标共用曲线）。
    if (card.icon_pop_at_ms) |t0| icon: {
        const lead = c.lead orelse {
            card.icon_pop_at_ms = null;
            break :icon;
        };
        const dur: f64 = if (t0 == card.born_ms) Spec.enter_ms else Spec.icon_pop_ms;
        const pop = model.iconPop(f.now - t0, dur);
        if (lead.style.ext) |e| {
            e.scale_x = pop.scale;
            e.scale_y = pop.scale;
            e.rotate = pop.rotate_deg * std.math.pi / 180.0;
        } else if (lead.style.ensureExtFallible(card.allocator)) |e| {
            e.scale_x = pop.scale;
            e.scale_y = pop.scale;
            e.rotate = pop.rotate_deg * std.math.pi / 180.0;
        } else |_| {}
        lead.markCompositeAnimFrameDirty();
        if (f.now - t0 >= dur) card.icon_pop_at_ms = null;
    }

    // 生命条 / 倒计时环 / 时间戳。
    const frac = card.life.fraction(f.now);
    if (card.spec.life_bar and !card.sticky) {
        animBackground(card.lifebar, pal.lifeBar(card.spec.tone));
        // 用左端为原点的 scale_x 缩短：只动合成属性，不触发布局 / 重新生成。
        if (card.lifebar.style.ext) |e| {
            if (@abs(e.scale_x - frac) > 0.0005) {
                e.scale_x = frac;
                card.lifebar.markCompositeAnimFrameDirty();
            }
        }
    } else {
        animBackground(card.lifebar, Color.TRANSPARENT);
    }
    if (c.ring_secs) |secs| {
        const remaining = card.life.remaining(f.now);
        const shown: i32 = if (std.math.isInf(remaining)) 0 else @intFromFloat(@ceil(remaining / 1000.0));
        if (shown != c.ring_secs_shown) {
            c.ring_secs_shown = shown;
            var buf: [8]u8 = undefined;
            const txt = std.fmt.bufPrint(&buf, "{d}", .{shown}) catch "";
            secs.setTextContent(card.allocator, txt) catch {};
        }
        // 倒计时环只在计时推进时重画（悬停暂停时静止）。
        if (card.life.frozen_remaining_ms == null) if (c.lead) |l| l.markRenderDirty();
    }
    if (c.spinner) |sp| sp.markRenderDirty();
    updateTimestamp(card);
}

/// 可见宽度偏离自然宽度时把外壳钉成固定宽（surface 跟随，内容居中、超出被裁掉）；
/// 回到自然宽度时恢复原来的尺寸规则（卡片满宽 / 胶囊随内容）。
fn applyClipWidth(card: *Card, clip_w: f32) void {
    const p = card.positioner;
    const s = card.surface;
    const is_hint = card.spec.kind == .hint;
    const natural = card.natural_width;
    if (natural <= 0) return;
    if (@abs(clip_w - natural) > 0.5) {
        if (p.style.width != .px or @abs(p.style.width.px - clip_w) > 0.25) {
            p.style.width = .fixed(@max(0, clip_w));
            p.markSizingDirty();
        }
        if (is_hint and s.style.width != .grow) {
            s.style.width = .fill();
            s.style.align_items = .center;
            s.markSizingDirty();
        }
    } else if (is_hint) {
        if (p.style.width != .fit or s.style.width != .fit) {
            p.style.width = .{ .fit = .{} };
            s.style.width = .{ .fit = .{} };
            p.markSizingDirty();
            s.markSizingDirty();
        }
    } else if (p.style.width != .px or @abs(p.style.width.px - natural) > 0.25) {
        p.style.width = .fixed(natural);
        p.markSizingDirty();
    }
}

fn applyStagger(card: *Card, age: f64) void {
    const c = &card.content;
    const Item = struct { node: ?*Node, delay: f64 };
    const items = [_]Item{
        .{ .node = c.title_row, .delay = Spec.title_delay_ms },
        .{ .node = c.body, .delay = Spec.body_delay_ms },
        .{ .node = c.progress_block, .delay = Spec.progress_delay_ms },
        .{ .node = c.footer, .delay = Spec.footer_delay_ms },
    };
    for (items) |item| {
        const node = item.node orelse continue;
        const m = model.staggerMotion(age, item.delay);
        if (@abs(node.style.translate_y - m.offset) > 0.001) {
            node.style.translate_y = m.offset;
            node.markCompositeAnimFrameDirty();
        }
        animOpacity(node, m.alpha);
    }
}

fn applyClose(card: *Card, pal: *const styles.Palette, under_pointer: bool) void {
    const a = card.close_alpha;
    const close = card.close;
    animOpacity(close, a);
    close.setHitTestVisible(a > 0.5);
    if (under_pointer != card.close_dark) {
        card.close_dark = under_pointer;
        if (under_pointer) {
            animBackground(close, pal.close_dark);
            close.style.border.color = pal.close_dark_edge;
            close.markRenderDirty();
            animOpacity(card.close_glyph_dark, 1);
            animOpacity(card.close_glyph_light, 0);
        } else {
            animBackground(close, pal.close_light);
            close.style.border.color = pal.close_light_edge;
            close.markRenderDirty();
            animOpacity(card.close_glyph_dark, 0);
            animOpacity(card.close_glyph_light, 1);
        }
    }
}

fn updateTimestamp(card: *Card) void {
    const elapsed = std.time.milliTimestamp() - card.born_wall_ms;
    const rt = model.relativeTime(elapsed);
    if (std.meta.eql(rt, card.last_ts) and card.ts_initialized) return;
    card.last_ts = rt;
    card.ts_initialized = true;
    var buf: [48]u8 = undefined;
    const s = card.strings;
    const label = switch (rt) {
        .now => s.now,
        .minutes => |m| card_mod.formatCount(&buf, s.minutes_ago, m),
        .hours => |h| card_mod.formatCount(&buf, s.hours_ago, h),
        .days => |d| card_mod.formatCount(&buf, s.days_ago, d),
    };
    const ts = card.content.timestamp orelse return;
    ts.setTextContent(card.allocator, label) catch {};
}

fn appendOwned(cx: *Cx, parent: *Node, child: *Node) !void {
    errdefer cx.freeNode(child);
    try parent.appendChild(cx.allocator, child);
}

// ============================================================================
// 测试
// ============================================================================

test {
    _ = @import("model.zig");
    _ = @import("styles.zig");
    _ = @import("hint.zig");
}

const testing = std.testing;

const TestRig = struct {
    ctx: *Cx,
    scope: *Scope,
    root: *Node,
    n: *Notifier,

    fn init(position: Position) !TestRig {
        const ctx = try Cx.init(testing.allocator);
        errdefer ctx.deinit();
        ctx.setViewport(1200, 800);
        const root = try box(ctx, .{ .width = .fixed(1200), .height = .fixed(800) }, .{});
        ctx.root = root;
        const scope = try Scope.init(testing.allocator, null, ctx.owner);
        // 初始化发生在「上一帧」：真实应用里第一个真实帧的时钟总是晚于 init。
        ctx.frame_time_ms = -16;
        const n = try Notifier.init(scope, ctx, .{ .position = position });
        if (!n.portaled) try root.appendChild(testing.allocator, n.container);
        return .{ .ctx = ctx, .scope = scope, .root = root, .n = n };
    }

    fn deinit(self: *TestRig) void {
        self.scope.dispose();
        self.ctx.deinit();
    }

    /// 推进帧时钟并跑一帧（layout -> before_render）。
    fn step(self: *TestRig, now_ms: f64) void {
        self.ctx.frame_time_ms = now_ms;
        self.ctx.layout();
        self.n.frame();
        self.ctx.layout();
    }

    fn card(self: *TestRig, id: Id) *Card {
        return self.n.cardForId(id).?;
    }
};

test "Notifier: show measures, enters, then settles at the bottom-center anchor" {
    var rig = try TestRig.init(.bottom_center);
    defer rig.deinit();
    const id = try rig.n.show(.{ .tone = .success, .title = "Saved to iCloud", .body = "3 files synced" });
    rig.step(1000);
    const c = rig.card(id);
    try testing.expect(c.measured);
    try testing.expect(c.natural_height > 40);
    try testing.expectEqual(@as(f64, 1000), c.born_ms);
    rig.step(1000 + 700);
    // 入场完成：卡片底边 = 800 − 22。
    try testing.expectApproxEqAbs(@as(f32, 800 - 22), c.rect_y + c.rect_h, 0.5);
    try testing.expectApproxEqAbs(@as(f32, (1200 - 392) / 2), c.rect_x, 0.5);
    try testing.expectApproxEqAbs(@as(f32, 1), c.draw_alpha, 1e-3);
}

test "Notifier: 窗口变矮时堆叠刚性跟随锚点，同一帧到位（不补间拖尾）" {
    // 回归：视口变化曾被 follow_y 当成重排目标跳变，启动 540ms 补间。普通 resize
    // 拖尾；live resize 拖动停住后 AppKit 不再出帧，堆叠卡在半路（掉出窗口底部）。
    var rig = try TestRig.init(.bottom_center);
    defer rig.deinit();
    const id = try rig.n.show(.{ .tone = .success, .title = "Saved", .sticky = true });
    rig.step(1000);
    rig.step(2000); // 入场与 young 期都已结束
    const c = rig.card(id);
    try testing.expectApproxEqAbs(@as(f32, 800 - 22), c.rect_y + c.rect_h, 0.5);

    rig.root.style.height = .fixed(600);
    rig.ctx.setViewport(1200, 600);
    rig.root.markLayoutDirty();
    rig.step(2016);
    try testing.expectApproxEqAbs(@as(f32, 600 - 22), c.rect_y + c.rect_h, 0.5);
    try testing.expect(!c.follow_y.active);

    // 换停靠位置仍是补间（不被当成视口平移吞掉）。
    rig.n.setPosition(.top_center);
    rig.step(2032);
    try testing.expect(c.follow_y.active);
}

test "Notifier: collapsed stack peeks 9px per layer, newest nearest the anchor" {
    var rig = try TestRig.init(.bottom_center);
    defer rig.deinit();
    const a = try rig.n.show(.{ .tone = .success, .title = "A", .sticky = true });
    const b = try rig.n.show(.{ .tone = .warning, .title = "B", .sticky = true });
    const c = try rig.n.show(.{ .tone = .info, .title = "C", .sticky = true });
    rig.step(0);
    rig.step(2000);
    const ca = rig.card(a);
    const cb = rig.card(b);
    const cc = rig.card(c);
    try testing.expectEqual(@as(u8, 0), cc.rank);
    // 后层视觉顶边比前一层高 9px（折叠露边）。
    try testing.expectApproxEqAbs(@as(f32, 9), cc.rect_y - cb.rect_y, 0.6);
    try testing.expectApproxEqAbs(@as(f32, 9), cb.rect_y - ca.rect_y, 0.6);
    // z 序与层序相反。
    try testing.expect(cc.positioner.style.ext.?.z_index > ca.positioner.style.ext.?.z_index);
    // 折叠态后层内容不透出。
    try testing.expectApproxEqAbs(@as(f32, 0), ca.content.root.getOpacity(), 1e-3);
}

test "Notifier: dismissing the middle card collapses its height smoothly, others keep their nodes" {
    var rig = try TestRig.init(.top_right);
    defer rig.deinit();
    const a = try rig.n.show(.{ .title = "A", .sticky = true });
    const b = try rig.n.show(.{ .title = "B", .sticky = true });
    const c = try rig.n.show(.{ .title = "C", .sticky = true });
    rig.step(0);
    rig.step(2000);
    // 悬停展开后再删中间那条。
    rig.n.setHovered(true, 2000);
    rig.step(2000);
    rig.step(2600);
    const a_node = rig.card(a).positioner;
    const a_before = rig.card(a).rect_y;
    const c_before = rig.card(c).rect_y;
    rig.n.dismiss(b);
    var prev = a_before;
    var t: f64 = 2600;
    while (t <= 2600 + 420) : (t += 20) {
        rig.step(t);
        const y = rig.card(a).rect_y;
        // 单调、连续补位（top 锚点向上补）。
        try testing.expect(y <= prev + 0.01);
        try testing.expect(prev - y < 20);
        prev = y;
    }
    rig.step(3100);
    try testing.expect(rig.n.cardForId(b) == null);
    try testing.expect(rig.card(a).positioner == a_node);
    try testing.expectApproxEqAbs(c_before, rig.card(c).rect_y, 0.5);
    // 入场不重放：born 不变。
    try testing.expectApproxEqAbs(@as(f64, 0), rig.card(a).born_ms, 1e-6);
}

test "Notifier: hovering pauses life and expands; leaving resumes from the frozen point" {
    var rig = try TestRig.init(.bottom_center);
    defer rig.deinit();
    const id = try rig.n.show(.{ .tone = .success, .title = "Saved", .duration_ms = 3000 });
    rig.step(0);
    rig.step(1000);
    const c = rig.card(id);
    rig.ctx.mouse_x = c.rect_x + 20;
    rig.ctx.mouse_y = c.rect_y + 20;
    rig.step(1100);
    try testing.expect(rig.n.hovered and rig.n.paused);
    const frozen = c.life.remaining(1100);
    rig.step(9000);
    try testing.expectApproxEqAbs(frozen, c.life.remaining(9000), 1e-6);
    try testing.expect(rig.n.cardForId(id) != null);
    // 指针落在外扩 18px 的空隙里仍算命中。
    rig.ctx.mouse_y = c.rect_y - 10;
    rig.step(9100);
    try testing.expect(rig.n.hovered);
    rig.ctx.mouse_x = 5;
    rig.ctx.mouse_y = 5;
    rig.step(9200);
    try testing.expect(!rig.n.paused);
    try testing.expectApproxEqAbs(frozen, c.life.remaining(9200), 1e-6);
}

test "Notifier: expiry, screen limit of 6 and upsert-by-id" {
    var rig = try TestRig.init(.bottom_right);
    defer rig.deinit();
    const quick = try rig.n.show(.{ .tone = .quiet, .title = "Quiet", .duration_ms = 500 });
    rig.step(0);
    rig.step(10);
    rig.step(600);
    try testing.expect(rig.card(quick).leaving);
    rig.step(1100);
    try testing.expect(rig.n.cardForId(quick) == null);

    var ids: [7]Id = undefined;
    for (ids[0..6]) |*slot| slot.* = try rig.n.show(.{ .title = "x", .sticky = true });
    rig.step(1500);
    ids[6] = try rig.n.show(.{ .title = "x", .sticky = true });
    // 超出同屏上限：最旧一条走正常退场（不是瞬间消失）。
    try testing.expectEqual(@as(usize, 6), rig.n.count());
    try testing.expect(rig.card(ids[0]).leaving);
    rig.step(1600);
    try testing.expect(rig.n.cardForId(ids[0]) != null);

    // 同 id 再 show = 原地转换：positioner 与 born 不变。
    rig.step(3000);
    const target = ids[3];
    const node = rig.card(target).positioner;
    const born = rig.card(target).born_ms;
    _ = try rig.n.show(.{ .id = target, .tone = .success, .title = "Done", .duration_ms = 3400 });
    rig.step(3020);
    rig.step(3040);
    try testing.expect(rig.card(target).positioner == node);
    try testing.expectEqual(born, rig.card(target).born_ms);
    try testing.expectEqual(Tone.success, rig.card(target).spec.tone);
    try testing.expect(!rig.card(target).sticky);
}

test "Notifier: undo action settles in place and reports the event" {
    var rig = try TestRig.init(.bottom_center);
    defer rig.deinit();
    const Sink = struct {
        var last: ?EventKind = null;
        fn cb(_: ?*anyopaque, _: *Notifier, e: Event) void {
            last = e.kind;
        }
    };
    rig.n.setListener(.{ .callback = Sink.cb });
    const id = try rig.n.show(.{ .kind = .undo, .tone = .info, .title = "Moved 4 items to Trash" });
    rig.step(0);
    rig.step(100);
    try testing.expectEqual(Lead.ring, rig.card(id).spec.lead);
    try testing.expect(rig.card(id).content.buttons[0] != null);
    Notifier.onButton(rig.card(id), 0);
    rig.step(200);
    try testing.expectEqual(@as(?EventKind, .undo), Sink.last);
    try testing.expectEqual(Lead.chip, rig.card(id).spec.lead);
    try testing.expect(rig.card(id).content.buttons[0] == null);
    // 新寿命从新内容层量到高度的那一帧起算。
    rig.step(220);
    try testing.expectApproxEqAbs(@as(f64, 2400), rig.card(id).life.remaining(220), 1e-6);
}

test "Notifier: hint 胶囊与卡片进同一个堆叠，宽度随内容并居中于卡片列" {
    var rig = try TestRig.init(.bottom_center);
    defer rig.deinit();
    const card_id = try rig.n.show(.{ .tone = .warning, .title = "Disk almost full", .sticky = true });
    const hint_id = try rig.n.hint(.{ .text = "Saved", .mark = .success });
    rig.step(0);
    rig.step(1000);
    try testing.expectEqual(@as(usize, 2), rig.n.count());
    const h = rig.card(hint_id);
    try testing.expect(h.measured);
    try testing.expectApproxEqAbs(@as(f32, styles.HintMetrics.height), h.natural_height, 0.5);
    try testing.expect(h.natural_width > 0 and h.natural_width < Spec.card_width);
    // 最新的胶囊在最前（贴锚点），卡片折叠在它后面。
    const c = rig.card(card_id);
    try testing.expect(h.rank < c.rank);
    const card_center = c.rect_x + c.rect_w / 2;
    try testing.expectApproxEqAbs(card_center, h.rect_x + h.rect_w / 2, 0.5);
    // 胶囊没有生命条、没有关闭钮。
    try testing.expectEqual(@as(f32, 0), rig.card(hint_id).lifebar.style.height.px);
    rig.ctx.mouse_x = h.rect_x + h.rect_w / 2;
    rig.ctx.mouse_y = h.rect_y + h.rect_h / 2;
    var t: f64 = 1016;
    while (t < 1600) : (t += 16) rig.step(t);
    try testing.expect(rig.n.hovered);
    // 悬停时卡片出现关闭钮，胶囊不出现。
    try testing.expect(c.close_alpha > 0.99);
    try testing.expectEqual(@as(f32, 0), h.close_alpha);
}

test "Notifier: hint 按钮点过即收起；宿主原地转换时保留；triggerHintAction 转发 ⌘Z" {
    var rig = try TestRig.init(.bottom_center);
    defer rig.deinit();
    const Sink = struct {
        var actions: usize = 0;
        var replace: bool = false;
        fn cb(_: ?*anyopaque, n: *Notifier, e: Event) void {
            if (e.kind != .action) return;
            actions += 1;
            if (replace) _ = n.hint(.{ .id = e.id, .text = "Undone" }) catch {};
        }
    };
    Sink.actions = 0;
    Sink.replace = false;
    rig.n.setListener(.{ .callback = Sink.cb });
    const undo = Action{ .label = "Undo", .shortcut = "⌘Z", .tag = "undo-replace" };
    const a = try rig.n.hint(.{ .text = "Replaced 8", .mark = .success, .action = undo });
    rig.step(0);
    rig.step(100);
    try testing.expect(rig.card(a).content.buttons[0] != null);
    try testing.expectApproxEqAbs(@as(f64, 4000), rig.card(a).life.remaining(0), 1e-6);
    try testing.expect(rig.n.triggerHintAction());
    rig.step(200);
    try testing.expectEqual(@as(usize, 1), Sink.actions);
    try testing.expect(rig.card(a).leaving);
    // 已在退场：⌘Z 回到宿主自己的撤销栈。
    try testing.expect(!rig.n.triggerHintAction());

    Sink.replace = true;
    const b = try rig.n.hint(.{ .text = "Replaced 3", .action = undo });
    rig.step(300);
    rig.step(400);
    Notifier.onButton(rig.card(b), 0);
    rig.step(500);
    try testing.expectEqual(@as(usize, 2), Sink.actions);
    try testing.expect(!rig.card(b).leaving);
    try testing.expect(rig.card(b).content.buttons[0] == null);
}

test "Notifier: 左右停靠时角标组贴边对齐（不再悬在卡片列中间）" {
    for ([_]Position{ .bottom_left, .bottom_right, .bottom_center }) |pos| {
        var rig = try TestRig.init(pos);
        defer rig.deinit();
        _ = try rig.n.hint(.{ .text = "Focus mode", .keycap = .{ .key = "Esc" } });
        _ = try rig.n.hint(.{ .text = "Saved", .mark = .success });
        rig.step(0);
        var t: f64 = 16;
        while (t < 800) : (t += 16) rig.step(t);
        const pill = rig.n.pill;
        const pw = pill.rectFromWorldOrFallback().w;
        const clear_right = rig.n.clear_btn.style.translate_x + rig.n.clear_btn.rectFromWorldOrFallback().w;
        try testing.expect(pw > 0);
        switch (pos) {
            .bottom_left => try testing.expectApproxEqAbs(Spec.edge_inset, pill.style.translate_x, 0.5),
            .bottom_right => try testing.expectApproxEqAbs(1200 - Spec.edge_inset, clear_right, 0.5),
            else => try testing.expectApproxEqAbs(@as(f32, 600), (pill.style.translate_x + clear_right) / 2, 0.5),
        }
    }
}

test "Notifier: 折叠时后层胶囊宽度收拢到最前那条，展开时过渡回自身宽度" {
    var rig = try TestRig.init(.bottom_right);
    defer rig.deinit();
    const wide = try rig.n.hint(.{ .text = "Focus mode on", .keycap = .{ .prefix = "press", .key = "Esc", .suffix = "to exit" } });
    const narrow = try rig.n.hint(.{ .text = "Saved", .mark = .success });
    var t: f64 = 0;
    while (t < 800) : (t += 16) rig.step(t);
    const back = rig.card(wide);
    const front = rig.card(narrow);
    try testing.expect(back.natural_width > front.natural_width + 40);
    // 折叠：后层可见宽 = 最前那条的宽（右停靠时右沿对齐，不从左侧露出）。
    try testing.expectApproxEqAbs(front.natural_width, back.positioner.style.width.px, 0.5);
    // 比较缩放前的布局框（后层另有折叠缩放，以中心为原点）。
    const front_right = front.positioner.style.translate_x + front.natural_width;
    const back_right = back.positioner.style.translate_x + back.positioner.style.width.px;
    try testing.expectApproxEqAbs(front_right, back_right, 0.5);
    // 展开：过渡中途介于两者之间，结束后恢复自身宽度（尺寸规则回到 fit）。
    rig.ctx.mouse_x = front.rect_x + front.rect_w / 2;
    rig.ctx.mouse_y = front.rect_y + front.rect_h / 2;
    rig.step(t);
    try testing.expect(rig.n.hovered);
    rig.step(t + Spec.expand_ms / 2);
    const mid = back.positioner.style.width.px;
    try testing.expect(mid > front.natural_width + 5 and mid < back.natural_width - 5);
    rig.step(t + Spec.expand_ms + 16);
    rig.step(t + Spec.expand_ms + 32);
    try testing.expect(back.positioner.style.width == .fit);
    try testing.expectApproxEqAbs(back.natural_width, back.rect_w, 0.5);
}

test "Notifier: 卡片与胶囊之间原地转换切换外壳，进行中常驻、完成后按成功计时" {
    var rig = try TestRig.init(.bottom_center);
    defer rig.deinit();
    const id = try rig.n.hint(.{ .text = "Exporting PDF…", .mark = .loading });
    rig.step(0);
    rig.step(100);
    try testing.expect(rig.card(id).sticky);
    try testing.expect(rig.card(id).content.spinner != null);
    try testing.expect(rig.card(id).positioner.style.width == .fit);
    _ = try rig.n.hint(.{ .id = id, .text = "Exported PDF", .mark = .success });
    rig.step(200);
    try testing.expect(!rig.card(id).sticky);
    try testing.expectApproxEqAbs(@as(f64, 2000), rig.card(id).life.remaining(200), 1e-6);
    try rig.n.update(id, .{ .tone = .info, .title = "Export finished", .body = "notes.pdf", .sticky = true });
    rig.step(300);
    try testing.expect(rig.card(id).positioner.style.width == .px);
    try testing.expectApproxEqAbs(Spec.card_width, rig.card(id).natural_width, 0.5);
    try testing.expect(rig.card(id).natural_height > styles.HintMetrics.height);
}

test "Notifier: teardown with scope first releases cards, content scopes and buttons once" {
    var rig = try TestRig.init(.bottom_center);
    const id = try rig.n.show(.{ .tone = .@"error", .title = "Upload failed", .actions = &.{ .{ .label = "Retry", .primary = true }, .{ .label = "Logs" } } });
    rig.step(0);
    rig.step(100);
    // 原地转换一次：旧内容层（含按钮 scope）必须被释放。
    try rig.n.update(id, .{ .kind = .progress, .title = "Retrying" });
    rig.step(200);
    rig.deinit(); // scope.dispose() → 子 scope 先于资源回调销毁；testing allocator 检查泄漏 / 重复释放。
}

test "Notifier: teardown with container first (window closing) is also clean" {
    const ctx = try Cx.init(testing.allocator);
    defer ctx.deinit();
    ctx.setViewport(800, 600);
    const root = try box(ctx, .{ .width = .fixed(800), .height = .fixed(600) }, .{});
    ctx.root = root;
    const scope = try Scope.init(testing.allocator, null, ctx.owner);
    const n = try Notifier.init(scope, ctx, .{});
    if (!n.portaled) try root.appendChild(testing.allocator, n.container);
    _ = try n.show(.{ .tone = .violet, .title = "Invite", .actions = &.{ .{ .label = "Accept", .primary = true }, .{ .label = "Ignore" } } });
    ctx.frame_time_ms = 0;
    ctx.layout();
    n.frame();
    // 容器先被释放（portal 根随窗口销毁）：on_cleanup 在子节点全部释放之后才调用。
    if (n.container.parent) |parent| ctx.detachChildRetained(parent, n.container);
    ctx.freeNode(n.container);
    scope.dispose();
}

fn fakeDrag(phase: drag.Phase, dx: f32) drag.Event {
    return .{
        .phase = phase,
        .source = undefined,
        .pointer_id = 0,
        .origin_window = .{ .x = 0, .y = 0 },
        .position_window = .{ .x = dx, .y = 0 },
        .raw_delta = .{ .x = dx, .y = 0 },
        .delta = .{ .x = dx, .y = 0 },
        .step_delta = .{ .x = 0, .y = 0 },
        .elapsed_ns = 0,
        .button = .left,
        .start_modifiers = .{},
        .modifiers = .{},
    };
}

test "Notifier: swipe under 84px springs back, over 84px flings out and reports dismissed" {
    var rig = try TestRig.init(.bottom_center);
    defer rig.deinit();
    const Sink = struct {
        var dismissed: usize = 0;
        fn cb(_: ?*anyopaque, _: *Notifier, e: Event) void {
            if (e.kind == .dismissed) dismissed += 1;
        }
    };
    Sink.dismissed = 0;
    rig.n.setListener(.{ .callback = Sink.cb });
    const id = try rig.n.show(.{ .title = "Swipe me", .sticky = true });
    rig.step(0);
    rig.step(800);
    const c = rig.card(id);
    const x0 = c.rect_x;

    Notifier.dragCallback(fakeDrag(.start, 10), @ptrCast(c));
    Notifier.dragCallback(fakeDrag(.move, 40), @ptrCast(c));
    rig.step(820);
    try testing.expectApproxEqAbs(x0 + 40, c.rect_x, 0.5);
    // 拖拽中透明度 = max(0.25, 1 − |dx| / 190)。
    try testing.expectApproxEqAbs(1 - 40.0 / 190.0, c.draw_alpha, 1e-3);
    Notifier.dragCallback(fakeDrag(.end, 40), @ptrCast(c));
    rig.step(900); // 帧外松手：弹回起点在下一个真实帧盖戳
    rig.step(1500);
    try testing.expect(!c.leaving);
    try testing.expectApproxEqAbs(x0, c.rect_x, 0.5);

    Notifier.dragCallback(fakeDrag(.start, 10), @ptrCast(c));
    Notifier.dragCallback(fakeDrag(.end, -120), @ptrCast(c));
    try testing.expect(c.leaving and c.closed_by_user);
    try testing.expectEqual(@as(usize, 1), Sink.dismissed);
    rig.step(1600);
    rig.step(1600 + 210);
    try testing.expect(c.rect_x < x0 - 120); // 沿方向甩出（1 + 1.1p）
}

test "Notifier: right-anchored stack only flings rightward; trackpad swipe releases after silence" {
    var rig = try TestRig.init(.bottom_right);
    defer rig.deinit();
    const id = try rig.n.show(.{ .title = "Edge", .sticky = true });
    rig.step(0);
    rig.step(800);
    const c = rig.card(id);
    Notifier.dragCallback(fakeDrag(.start, -10), @ptrCast(c));
    Notifier.dragCallback(fakeDrag(.end, -150), @ptrCast(c));
    try testing.expect(!c.leaving);
    // 反方向拖动被阻尼到 0.2 倍：弹回从显示位置 −30 开始，不先跳到 −150。
    try testing.expectApproxEqAbs(@as(f32, -30), c.spring_from, 1e-4);
    rig.step(900);
    rig.step(1500);

    // 双指横扫：累计 dx，静默 140ms 视为松手。
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        _ = Notifier.scrollHandler(.{ .dx = 20, .dy = 0, .x = 0, .y = 0, .phase = .changed, .modifiers = .{} }, @ptrCast(c));
    }
    try testing.expect(c.scroll_dragging);
    rig.step(1520);
    try testing.expect(!c.leaving);
    // 静默按真实墙钟判定：模拟 140ms 没有新的横扫事件。
    c.last_scroll_wall_ms -= 200;
    rig.step(1540);
    try testing.expect(c.leaving);
}

test "Notifier: reply sends in place as a quote and replyFailed restores the text" {
    var rig = try TestRig.init(.bottom_center);
    defer rig.deinit();
    const Sink = struct {
        var text: [64]u8 = undefined;
        var len: usize = 0;
        fn cb(_: ?*anyopaque, _: *Notifier, e: Event) void {
            if (e.kind != .reply) return;
            len = @min(e.text.len, text.len);
            @memcpy(text[0..len], e.text[0..len]);
        }
    };
    rig.n.setListener(.{ .callback = Sink.cb });
    const id = try rig.n.show(.{ .tone = .violet, .avatar = "L", .title = "Lin", .body = "Take a look?", .reply = true });
    rig.step(0);
    rig.step(700);
    const c = rig.card(id);
    const node = c.positioner;
    try testing.expect(c.sticky);
    const state = c.content.reply_state.?;
    _ = state.setText("  Looks good  ");
    Notifier.onButton(c, card_mod.send_index);
    rig.step(720);
    try testing.expectEqualStrings("Looks good", Sink.text[0..Sink.len]);
    try testing.expect(c.content.reply_state == null);
    try testing.expect(c.content.quote != null);
    try testing.expect(c.positioner == node);
    try testing.expect(!c.sticky);

    rig.n.replyFailed(id, "Send failed", "Network offline");
    rig.step(740);
    try testing.expectEqual(Tone.@"error", c.spec.tone);
    try testing.expectEqualStrings("Looks good", c.content.reply_state.?.getText());
}

test "Notifier: mouse drag takes over a trackpad swipe without jumping or auto-release" {
    var rig = try TestRig.init(.bottom_center);
    defer rig.deinit();
    const id = try rig.n.show(.{ .title = "Swipe", .sticky = true });
    rig.step(0);
    rig.step(800);
    const c = rig.card(id);
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        _ = Notifier.scrollHandler(.{ .dx = 20, .dy = 0, .x = 0, .y = 0, .phase = .changed, .modifiers = .{} }, @ptrCast(c));
    }
    Notifier.dragCallback(fakeDrag(.start, 10), @ptrCast(c));
    try testing.expectApproxEqAbs(@as(f32, 70), c.drag_dx, 1e-4);
    try testing.expect(!c.scroll_dragging);
    // 横扫的静默超时不能在鼠标仍按住时替用户松手。
    c.last_scroll_wall_ms -= 500;
    rig.step(820);
    try testing.expect(c.dragging and !c.leaving);
    Notifier.dragCallback(fakeDrag(.end, 10), @ptrCast(c));
    try testing.expect(!c.leaving); // 70 < 84：弹回
}

test "Notifier: a card dismissed mid-drag ignores late drag events and is reclaimed cleanly" {
    var rig = try TestRig.init(.bottom_center);
    defer rig.deinit();
    const id = try rig.n.show(.{ .title = "Busy", .sticky = true });
    rig.step(0);
    rig.step(800);
    const c = rig.card(id);
    Notifier.dragCallback(fakeDrag(.start, 20), @ptrCast(c));
    rig.n.dismiss(id);
    try testing.expect(c.leaving and !c.dragging);
    Notifier.dragCallback(fakeDrag(.move, 60), @ptrCast(c));
    Notifier.dragCallback(fakeDrag(.end, 200), @ptrCast(c));
    try testing.expect(!c.dragging);
    rig.step(820);
    rig.step(1300);
    try testing.expect(rig.n.cardForId(id) == null);
}

const Event_ = events.Event;

test "Notifier: clear-all button appears with 2+ cards and dismisses every card as a user close" {
    var rig = try TestRig.init(.bottom_center);
    defer rig.deinit();
    const Rec = struct {
        dismissed: usize = 0,
        fn cb(ctx: ?*anyopaque, _: *Notifier, ev: Event) void {
            const r: *@This() = @ptrCast(@alignCast(ctx.?));
            if (ev.kind == .dismissed) r.dismissed += 1;
        }
    };
    var rec: Rec = .{};
    rig.n.setListener(.{ .context = &rec, .callback = Rec.cb });
    _ = try rig.n.show(.{ .title = "one", .sticky = true });
    rig.step(0);
    rig.step(400);
    // 只有一条：没有全部清除。
    try testing.expect(rig.n.clear_alpha < 0.01);
    _ = try rig.n.show(.{ .title = "two", .sticky = true });
    _ = try rig.n.show(.{ .title = "three", .sticky = true });
    var t: f64 = 400;
    for (0..20) |_| {
        t += 32;
        rig.step(t);
    }
    try testing.expect(rig.n.clear_alpha > 0.99);
    try testing.expect(rig.n.clear_btn.getOpacity() > 0.99);
    // 与角标并排：在角标右侧。
    try testing.expect(rig.n.clear_btn.style.translate_x > rig.n.pill.style.translate_x);

    const click: Event_ = .{ .click = .{ .x = 0, .y = 0 } };
    // 第一下：展开确认（宽度逐帧长大，不跳变），不清除。
    const w0 = rig.n.clear_btn.rectFromWorldOrFallback().w;
    _ = Notifier.clearAllEvent(click, @ptrCast(rig.n));
    t += 16;
    rig.step(t);
    const w1 = rig.n.clear_btn.rectFromWorldOrFallback().w;
    for (0..10) |_| {
        t += 32;
        rig.step(t);
    }
    const w2 = rig.n.clear_btn.rectFromWorldOrFallback().w;
    try testing.expect(w1 > w0 and w1 < w2);
    try testing.expectEqual(@as(usize, 0), rec.dismissed);
    // 移开：收回。
    _ = Notifier.clearAllEvent(.mouse_leave, @ptrCast(rig.n));
    for (0..10) |_| {
        t += 32;
        rig.step(t);
    }
    try testing.expectApproxEqAbs(w0, rig.n.clear_btn.rectFromWorldOrFallback().w, 0.5);
    // 再展开，第二下清除：卡片原地淡出，不补位。
    _ = Notifier.clearAllEvent(click, @ptrCast(rig.n));
    _ = Notifier.clearAllEvent(click, @ptrCast(rig.n));
    var ys: [3]f32 = undefined;
    for (rig.n.cards.items, 0..) |card, i| ys[i] = card.positioner.style.translate_y;
    t += 16;
    rig.step(t);
    try testing.expectEqual(@as(usize, 3), rec.dismissed);
    for (rig.n.cards.items) |card| try testing.expect(card.leaving);
    t += 100;
    rig.step(t);
    for (rig.n.cards.items, 0..) |card, i| try testing.expectApproxEqAbs(ys[i], card.positioner.style.translate_y, 6);
    for (0..20) |_| {
        t += 32;
        rig.step(t);
    }
    try testing.expectEqual(@as(usize, 0), rig.n.count());
    try testing.expect(rig.n.clear_alpha < 0.01);
}

test "Notifier: armed clear-all stays fully revealed across idle wake frames" {
    // 实测闪烁：展开完成后空闲停帧，每 1s 唤醒一帧刷新时间戳；该帧 dt 大，
    // 进度在「已到目标」时仍按收回方向减一步（1 -> 0.68），文字变淡、整组重新居中。
    var rig = try TestRig.init(.bottom_center);
    defer rig.deinit();
    _ = try rig.n.show(.{ .title = "one", .sticky = true });
    _ = try rig.n.show(.{ .title = "two", .sticky = true });
    _ = try rig.n.show(.{ .title = "three", .sticky = true });
    var t: f64 = 0;
    for (0..30) |_| {
        t += 32;
        rig.step(t);
    }
    _ = Notifier.clearAllEvent(.{ .click = .{ .x = 0, .y = 0 } }, @ptrCast(rig.n));
    for (0..30) |_| {
        t += 16;
        rig.step(t);
    }
    try testing.expectEqual(@as(f32, 1), rig.n.clear_reveal_t);
    const w = rig.n.clear_btn.rectFromWorldOrFallback().w;
    const x = rig.n.clear_btn.style.translate_x;
    for (0..3) |_| {
        t += 1000;
        rig.step(t);
        try testing.expectEqual(@as(f32, 1), rig.n.clear_reveal_t);
        try testing.expectEqual(@as(f32, 1), rig.n.clear_label.getOpacity());
        try testing.expectApproxEqAbs(w, rig.n.clear_btn.rectFromWorldOrFallback().w, 0.01);
        try testing.expectApproxEqAbs(x, rig.n.clear_btn.style.translate_x, 0.01);
    }
}

test "Notifier: resting the pointer on the clear-all button does not oscillate the stack" {
    var rig = try TestRig.init(.bottom_center);
    defer rig.deinit();
    _ = try rig.n.show(.{ .title = "one", .sticky = true });
    _ = try rig.n.show(.{ .title = "two", .sticky = true });
    _ = try rig.n.show(.{ .title = "three", .sticky = true });
    var t: f64 = 0;
    for (0..30) |_| {
        t += 32;
        rig.step(t);
    }
    // 真实路径：先悬停到卡片上让堆叠展开，再移到（已随展开上移的）圆钮上。
    const front = rig.n.cards.items[rig.n.cards.items.len - 1];
    rig.ctx.mouse_x = front.rect_x + front.rect_w / 2;
    rig.ctx.mouse_y = front.rect_y + front.rect_h / 2;
    for (0..30) |_| {
        t += 16;
        rig.step(t);
    }
    try testing.expect(rig.n.hovered);
    const b = rig.n.clear_btn;
    const r = b.rectFromWorldOrFallback();
    rig.ctx.mouse_x = b.style.translate_x + r.w / 2;
    rig.ctx.mouse_y = b.style.translate_y + r.h / 2;
    const y0 = b.style.translate_y;
    for (0..40) |_| {
        t += 16;
        rig.step(t);
        // 停在圆钮上：堆叠不收起，圆钮不从指针下跑开。
        try testing.expect(rig.n.hovered);
        try testing.expectApproxEqAbs(y0, b.style.translate_y, 0.5);
    }
}

// ── 逐分配点 OOM sweep ──────────────────────────────────────────────────────
// init 在 registerResource 成功之后还有一次可失败的 portal.appendChild；那条
// 路径上 errdefer freeNode(container) 与 scope cleanup（removeLayer + release）
// 同时生效，只有注入分配失败才走得到。每个注入点一个独立 GPA：泄漏看
// deinit()==.leak，二次释放由 GPA 安全检查报错（test 里 log.err 即失败）。

/// 被 sweep 的一次完整使用：init -> 两条提醒（带正文与操作按钮）-> 同 id 原地转换。
fn oomSweepUse(scope: *Scope, ctx: *Cx) !void {
    const n = try Notifier.init(scope, ctx, .{ .position = .bottom_right });
    _ = try n.show(.{ .tone = .success, .title = "Saved", .body = "3 files synced" });
    const id = try n.show(.{ .tone = .violet, .title = "Invite", .actions = &.{ .{ .label = "Accept", .primary = true }, .{ .label = "Ignore" } } });
    _ = try n.show(.{ .id = id, .tone = .@"error", .title = "Declined", .body = "Invite expired" });
}

const OomSweepResult = struct { total: usize, induced: usize, leaked: usize, first_leak: ?usize };

fn oomSweepCase(gpa_alloc: Allocator, failure_index: ?usize, total_out: ?*usize) !bool {
    var failing = testing.FailingAllocator.init(gpa_alloc, .{});
    const ctx = try Cx.init(failing.allocator());
    defer ctx.deinit();
    ctx.setViewport(800, 600);
    ctx.root = try box(ctx, .{ .width = .fixed(800), .height = .fixed(600) }, .{});
    // 预热：World 元素表 / 样式来源表等摊还扩容，首轮比之后多分配；不预热的话
    // 注入序号与分配点的对应会随 k 漂移，恰好跳过后段分配点。
    {
        _ = try ctx.ensurePopoverPortalRoot();
        const warm = try Scope.init(failing.allocator(), null, ctx.owner);
        try oomSweepUse(warm, ctx);
        warm.dispose();
    }
    // 换一个全新 portal：children 容量归零，init 末尾的 portal.appendChild
    // 才真的要分配（否则预热留下的容量让那一步永远不会失败）。
    {
        const old = ctx.popover_portal_root.?;
        ctx.detachChildRetained(old.parent.?, old);
        ctx.freeNode(old);
        ctx.popover_portal_root = null;
        _ = try ctx.ensurePopoverPortalRoot();
    }
    const scope = try Scope.init(failing.allocator(), null, ctx.owner);
    defer scope.dispose();
    const before = failing.alloc_index;
    if (failure_index) |k| {
        failing.fail_index = before + k;
        failing.resize_fail_index = failing.resize_index + k;
    }
    const result = oomSweepUse(scope, ctx);
    failing.fail_index = std.math.maxInt(usize);
    failing.resize_fail_index = std.math.maxInt(usize);
    if (total_out) |t| t.* = failing.alloc_index - before;
    if (result) |_| return false else |err| {
        try testing.expectEqual(error.OutOfMemory, err);
        return true;
    }
}

fn runOomSweep() !OomSweepResult {
    var total: usize = 0;
    {
        var gpa = std.heap.GeneralPurposeAllocator(.{ .safety = true }){};
        _ = try oomSweepCase(gpa.allocator(), null, &total);
        try testing.expect(gpa.deinit() == .ok);
    }
    var res: OomSweepResult = .{ .total = total, .induced = 0, .leaked = 0, .first_leak = null };
    for (0..total) |k| {
        var gpa = std.heap.GeneralPurposeAllocator(.{ .safety = true }){};
        if (try oomSweepCase(gpa.allocator(), k, null)) res.induced += 1;
        if (gpa.deinit() == .leak) {
            res.leaked += 1;
            if (res.first_leak == null) res.first_leak = k;
        }
    }
    return res;
}

test "Notifier: init/show 逐分配点 OOM sweep 无泄漏无二次释放" {
    const res = try runOomSweep();
    try testing.expect(res.total > 20);
    // 覆盖防护按比例卡（口径同 components/oom_sweep.zig）。
    if (res.induced < res.total / 2 or res.leaked != 0) {
        std.debug.print("\n[notifier oom sweep] total={d} induced={d} leaked={d} first_leak={?d}\n", .{ res.total, res.induced, res.leaked, res.first_leak });
    }
    try testing.expect(res.induced >= res.total / 2);
    try testing.expectEqual(@as(usize, 0), res.leaked);
}

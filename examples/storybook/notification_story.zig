//! Notification story，设计稿 § 16 应用内全局提醒。
//! 所有卡片都由 Notifier 真实创建；九种类型、堆叠、八个位置与原地转换各有入口。
const std = @import("std");
const ui = @import("ui");

const W = ui.widgets;
const Notifier = W.Notifier;
const Id = W.NotificationId;

const zh_strings = W.NotificationStrings{
    .now = "刚刚",
    .minutes_ago = "{d} 分钟前",
    .hours_ago = "{d} 小时前",
    .days_ago = "{d} 天前",
    .undo = "撤销",
    .reply_placeholder = "回复…",
    .send = "发送",
    .close = "关闭提醒",
    .more = "还有 {d} 条 · 悬停展开",
    .paused = "悬停中 · 全部计时已暂停",
    .clear_all = "全部清除",
};

const Story = struct {
    n: *Notifier,
    /// 双实例演示：第二个 Notifier 固定在下中，只放文案提示（主实例放卡片）。
    hints_n: *Notifier,
    cx: *ui.Cx,
    status: *ui.Node,
    /// 正在模拟的进度卡（id + 起始帧时刻 + 时长）。
    progress_id: ?Id = null,
    progress_start_ms: f64 = 0,
    progress_duration_ms: f64 = 5200,
    progress_title_done: []const u8 = "上传完成",
    progress_body_done: []const u8 = "assets/hero-shot.png · 5 / 5",
    hint_loading_id: ?Id = null,
    hint_loading_start_ms: f64 = 0,

    fn tag(self: *Story, id: Id, test_id: []const u8) void {
        tagIn(self.n, id, test_id);
    }

    fn tagIn(n: *Notifier, id: Id, test_id: []const u8) void {
        const card = n.cardForId(id) orelse return;
        card.positioner.meta.ownership.meta.test_id = test_id;
        card.close.meta.ownership.meta.test_id = closeTestId(test_id);
        for (card.content.buttons, 0..) |maybe, i| {
            if (maybe) |btn| btn.meta.ownership.meta.test_id = buttonTestId(test_id, i);
        }
    }

    var close_ids: [16][64]u8 = undefined;
    var close_lens: [16]usize = .{0} ** 16;
    var close_next: usize = 0;
    var button_ids: [32][64]u8 = undefined;
    var button_next: usize = 0;

    fn closeTestId(base: []const u8) []const u8 {
        const slot = close_next % close_ids.len;
        close_next += 1;
        return std.fmt.bufPrint(&close_ids[slot], "{s}.close", .{base}) catch base;
    }

    fn buttonTestId(base: []const u8, index: usize) []const u8 {
        const slot = button_next % button_ids.len;
        button_next += 1;
        return std.fmt.bufPrint(&button_ids[slot], "{s}.action.{d}", .{ base, index }) catch base;
    }

    fn setStatus(self: *Story, text: []const u8) void {
        self.status.setTextContent(self.cx.allocator, text) catch {};
    }

    // ── 九种类型（16.2）──

    fn success(self: *Story) void {
        const id = self.n.show(.{ .tone = .success, .title = "已保存到 iCloud", .body = "3 个文件已同步 · 2.1 MB" }) catch return;
        self.tag(id, "story.notify.success");
    }

    fn failure(self: *Story) void {
        const id = self.n.show(.{
            .tone = .@"error",
            .title = "上传失败",
            .body = "network timeout · dist/app.zip",
            .actions = &.{ .{ .label = "重试", .primary = true, .tag = "retry" }, .{ .label = "查看日志", .tag = "log" } },
        }) catch return;
        self.tag(id, "story.notify.error");
    }

    fn warning(self: *Story) void {
        const id = self.n.show(.{ .tone = .warning, .title = "磁盘空间不足", .body = "剩余 1.2 GB,继续导出可能中断。" }) catch return;
        self.tag(id, "story.notify.warning");
    }

    fn progress(self: *Story) void {
        const id = self.n.show(.{
            .kind = .progress,
            .tone = .info,
            .title = "正在上传附件",
            .body = "assets/hero-shot.png",
            .progress = .{ .value = 0, .label = "上传中 · 预计 5 秒", .count = "0 / 5" },
        }) catch return;
        self.tag(id, "story.notify.progress");
        self.startProgress(id, 5200);
    }

    fn action(self: *Story) void {
        const id = self.n.show(.{
            .tone = .violet,
            .title = "林可可 邀请你加入文档",
            .body = "《2026 编辑器路线图》· 可编辑权限",
            .actions = &.{ .{ .label = "接受", .primary = true, .tag = "accept" }, .{ .label = "忽略", .tag = "ignore" } },
        }) catch return;
        self.tag(id, "story.notify.action");
    }

    fn person(self: *Story) void {
        const id = self.n.show(.{
            .tone = .violet,
            .avatar = "林",
            .title = "林可可",
            .body = "第三节的表格宽度那段我改完了,你看一下?",
            .reply = true,
        }) catch return;
        self.tag(id, "story.notify.person");
    }

    fn undo(self: *Story) void {
        const id = self.n.show(.{ .kind = .undo, .tone = .info, .title = "已移动 4 个项目到废纸篓", .body = "可在 7 秒内撤销此操作。" }) catch return;
        self.tag(id, "story.notify.undo");
    }

    fn quiet(self: *Story) void {
        const id = self.n.show(.{ .tone = .quiet, .title = "已切换到分支 feat/notify", .body = "工作区无未提交更改。" }) catch return;
        self.tag(id, "story.notify.quiet");
    }

    fn digest(self: *Story) void {
        const id = self.n.show(.{
            .tone = .quiet,
            .title = "勿扰期间收到 7 条提醒",
            .body = "已全部保存,可稍后查看。",
            .actions = &.{.{ .label = "查看", .tag = "view" }},
            .duration_ms = 4200,
        }) catch return;
        self.tag(id, "story.notify.digest");
    }

    // ── 文案提示（16.13）：与卡片同一个堆叠 ──

    fn hintPlain(self: *Story) void {
        const id = self.n.hint(.{ .text = "已复制链接到剪贴板" }) catch return;
        self.tag(id, "story.notify.hint.plain");
    }

    fn hintSuccess(self: *Story) void {
        const id = self.n.hint(.{ .text = "已保存", .mark = .success }) catch return;
        self.tag(id, "story.notify.hint.success");
    }

    fn hintError(self: *Story) void {
        const id = self.n.hint(.{ .text = "无法写入 notes.md：磁盘空间不足", .mark = .@"error" }) catch return;
        self.tag(id, "story.notify.hint.error");
    }

    fn hintKeycap(self: *Story) void {
        const id = self.n.hint(.{ .text = "已进入专注模式", .keycap = .{ .prefix = "按", .key = "Esc", .suffix = "退出" } }) catch return;
        self.tag(id, "story.notify.hint.keycap");
    }

    fn hintLoading(self: *Story) void {
        const id = self.n.hint(.{ .text = "正在导出 PDF…", .mark = .loading }) catch return;
        self.tag(id, "story.notify.hint.loading");
        self.hint_loading_id = id;
        self.hint_loading_start_ms = self.cx.frame_time_ms;
    }

    fn hintUndo(self: *Story) void {
        const id = self.n.hint(.{ .text = "已在当前文件替换 8 处", .mark = .success, .action = .{ .label = "撤销", .shortcut = "⌘Z", .tag = "undo-replace" } }) catch return;
        self.tag(id, "story.notify.hint.undo");
    }

    fn hintLong(self: *Story) void {
        const id = self.n.hint(.{ .text = "已将 notes/2026/roadmap/editor-architecture-and-rendering-pipeline-overview-final-v3.md 移动到归档文件夹" }) catch return;
        self.tag(id, "story.notify.hint.long");
    }

    /// 进行中 -> 2.4s 后同一 id 原地转成功（再显示 2 秒）。
    fn tickHint(self: *Story) void {
        const id = self.hint_loading_id orelse return;
        // 已被收起（全部收起 / 横扫关闭）：不再原地转换，否则会用同一 id 新弹一条。
        const card = self.n.cardForId(id) orelse {
            self.hint_loading_id = null;
            return;
        };
        if (card.leaving) {
            self.hint_loading_id = null;
            return;
        }
        if (self.n.isPaused()) {
            self.hint_loading_start_ms += self.cx.frame_dt_seconds * 1000;
            return;
        }
        if (self.cx.frame_time_ms - self.hint_loading_start_ms < 2400) return;
        self.hint_loading_id = null;
        _ = self.n.hint(.{ .id = id, .text = "已导出 PDF", .mark = .success }) catch return;
    }

    // ── 堆叠 / 清除 ──

    fn burst(self: *Story) void {
        self.n.dismissAll();
        const specs = [_]struct { W.Notification, []const u8 }{
            .{ .{ .tone = .warning, .title = "磁盘空间不足", .body = "剩余 1.2 GB,继续导出可能中断。", .sticky = true }, "story.notify.stack.0" },
            .{ .{ .tone = .@"error", .title = "上传失败", .body = "network timeout · dist/app.zip", .actions = &.{ .{ .label = "重试", .primary = true, .tag = "retry" }, .{ .label = "查看日志", .tag = "log" } } }, "story.notify.stack.1" },
            .{ .{ .tone = .violet, .avatar = "林", .title = "林可可", .body = "第三节的表格宽度那段我改完了,你看一下?", .sticky = true }, "story.notify.stack.2" },
            .{ .{ .tone = .success, .title = "已保存到 iCloud", .body = "3 个文件已同步 · 2.1 MB", .sticky = true }, "story.notify.stack.3" },
        };
        for (specs) |spec| {
            const id = self.n.show(spec[0]) catch return;
            self.tag(id, spec[1]);
        }
    }

    fn clear(self: *Story) void {
        self.n.dismissAll();
        self.hints_n.dismissAll();
    }

    // ── 双实例：卡片在右上（主实例），文案提示在下中（第二个实例）──

    fn dualCards(self: *Story) void {
        self.setPos(.top_right);
        const id = self.n.show(.{ .tone = .success, .title = "已保存到 iCloud", .body = "3 个文件已同步 · 2.1 MB" }) catch return;
        self.tag(id, "story.notify.dual.card");
    }

    fn dualHint(self: *Story) void {
        const id = self.hints_n.hint(.{ .text = "已复制链接到剪贴板", .mark = .success }) catch return;
        tagIn(self.hints_n, id, "story.notify.dual.hint");
    }

    fn dualHintUndo(self: *Story) void {
        const id = self.hints_n.hint(.{ .text = "已在当前文件替换 8 处", .mark = .success, .action = .{ .label = "撤销", .shortcut = "⌘Z", .tag = "undo-replace" } }) catch return;
        tagIn(self.hints_n, id, "story.notify.dual.hint.undo");
    }

    fn setPos(self: *Story, p: W.NotificationPosition) void {
        self.n.setPosition(p);
        self.setStatus(@tagName(p));
    }
    fn posTL(self: *Story) void {
        self.setPos(.top_left);
    }
    fn posTC(self: *Story) void {
        self.setPos(.top_center);
    }
    fn posTR(self: *Story) void {
        self.setPos(.top_right);
    }
    fn posRC(self: *Story) void {
        self.setPos(.right_center);
    }
    fn posBR(self: *Story) void {
        self.setPos(.bottom_right);
    }
    fn posBC(self: *Story) void {
        self.setPos(.bottom_center);
    }
    fn posBL(self: *Story) void {
        self.setPos(.bottom_left);
    }
    fn posLC(self: *Story) void {
        self.setPos(.left_center);
    }

    // ── 原地转换（16.6）──

    fn startProgress(self: *Story, id: Id, duration_ms: f64) void {
        self.progress_id = id;
        self.progress_start_ms = self.cx.frame_time_ms;
        self.progress_duration_ms = duration_ms;
    }

    fn tickProgress(self: *Story) void {
        const id = self.progress_id orelse return;
        if (self.n.cardForId(id) == null) {
            self.progress_id = null;
            return;
        }
        // 悬停暂停所有计时，进度模拟也跟着停（演示用：按剩余推进）。
        if (self.n.isPaused()) {
            self.progress_start_ms += self.cx.frame_dt_seconds * 1000;
            return;
        }
        const p: f32 = @floatCast(@min(1, (self.cx.frame_time_ms - self.progress_start_ms) / self.progress_duration_ms));
        var label_buf: [64]u8 = undefined;
        var count_buf: [16]u8 = undefined;
        const done: u32 = @intFromFloat(@floor(p * 5));
        const secs: u32 = @intFromFloat(@ceil((1 - p) * self.progress_duration_ms / 1000));
        const label = std.fmt.bufPrint(&label_buf, "上传中 · 预计 {d} 秒", .{secs}) catch "";
        const count = std.fmt.bufPrint(&count_buf, "{d} / 5", .{done}) catch "";
        self.n.setProgress(id, p, label, count);
        if (p >= 1) {
            self.progress_id = null;
            // 进度跑满：图标换成 ✓，标题改写，life 重置 3400ms。
            self.n.update(id, .{ .tone = .success, .title = self.progress_title_done, .body = self.progress_body_done, .duration_ms = 3400 }) catch {};
        }
    }

    fn onEvent(ctx: ?*anyopaque, n: *Notifier, e: W.NotificationEvent) void {
        const self: *Story = @ptrCast(@alignCast(ctx orelse return));
        var buf: [96]u8 = undefined;
        self.setStatus(std.fmt.bufPrint(&buf, "event · {s} · {s}", .{ @tagName(e.kind), e.tag }) catch "event");
        if (e.kind != .action) return;
        if (std.mem.eql(u8, e.tag, "undo-replace")) {
            // 撤销后原地换成结果提示。
            _ = n.hint(.{ .id = e.id, .text = "已撤销替换" }) catch return;
            return;
        }
        if (std.mem.eql(u8, e.tag, "retry")) {
            // 常驻的错误卡当场变成进度卡：born 不变，不重新入场。
            n.update(e.id, .{
                .kind = .progress,
                .tone = .info,
                .title = "正在重新上传",
                .body = "dist/app.zip",
                .progress = .{ .value = 0, .label = "上传中", .count = "0 / 5" },
            }) catch return;
            self.startProgress(e.id, 5200);
        } else if (std.mem.eql(u8, e.tag, "accept")) {
            // 按钮区整体移除，高度随之收缩；2600ms 后自动收起。
            n.update(e.id, .{ .tone = .success, .title = "已加入文档", .body = "《2026 编辑器路线图》· 可编辑权限", .duration_ms = 2600 }) catch return;
        } else if (std.mem.eql(u8, e.tag, "ignore") or std.mem.eql(u8, e.tag, "log") or std.mem.eql(u8, e.tag, "view")) {
            n.dismiss(e.id);
        }
    }
};

fn storyHook(node: *ui.Node) void {
    const self: *Story = @ptrCast(@alignCast(node.meta.per_frame.hooks.slots.anim_state orelse return));
    self.tickProgress();
    self.tickHint();
    if (self.progress_id != null or self.hint_loading_id != null) node.markRenderDirty();
}

fn sectionLabel(cx: *ui.Cx, title: []const u8, description: []const u8) !*ui.Node {
    const t = cx.tokens;
    const copy = try ui.box(cx, .{ .direction = .column, .gap = 3 }, .{});
    try copy.appendChild(cx.allocator, try ui.text(cx, title, .{ .font_size = 13, .font_weight = 700, .color = t.color.fg_primary }));
    try copy.appendChild(cx.allocator, try ui.text(cx, description, .{ .font_size = 12, .font_weight = 400, .color = t.color.fg_tertiary }));
    return copy;
}

fn controlRow(cx: *ui.Cx) !*ui.Node {
    const row = try ui.box(cx, .{ .width = .{ .grow = .{} }, .direction = .row, .align_items = .center, .gap = 8 }, .{});
    (try row.style.ensureExtFallible(cx.allocator)).flex_wrap = .wrap;
    return row;
}

fn addButton(scope: *ui.Scope, cx: *ui.Cx, row: *ui.Node, state: *Story, label: []const u8, test_id: []const u8, comptime method: *const fn (*Story) void, variant: W.ButtonVariant) !void {
    const button = try W.Button(.{ .label = label, .variant = variant, .size = .sm, .on_click = cx.on(Story, state, method) }).mount(scope, cx);
    button.meta.ownership.meta.test_id = test_id;
    try row.appendChild(cx.allocator, button);
}

fn group(cx: *ui.Cx, heading: *ui.Node, controls: *ui.Node) !*ui.Node {
    const t = cx.tokens;
    const card = try ui.box(cx, .{
        .width = .{ .grow = .{} },
        .direction = .column,
        .gap = 10,
        .padding = ui.Padding.all(14),
        .background = t.color.bg_secondary,
        .border = .{ .width = 1, .color = t.color.border, .radius = t.radius.lg },
    }, .{});
    try card.appendChild(cx.allocator, heading);
    try card.appendChild(cx.allocator, controls);
    return card;
}

pub fn build(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const t = cx.tokens;
    const root = try ui.box(cx, .{ .width = .{ .grow = .{} }, .direction = .column, .gap = 12 }, .{});

    const n = try Notifier.init(scope, cx, .{
        .position = .bottom_center,
        // storybook 顶部 56px 工具栏。
        .content_insets = .{ .top = 56 },
        .strings = zh_strings,
    });
    const status = try ui.text(cx, "event · idle", .{ .font_size = 12, .font_weight = 550, .color = t.color.fg_secondary });
    status.meta.ownership.meta.test_id = "story.notify.status";
    // 第二个实例：固定下中，只放文案提示；与主实例各自独立堆叠 / 悬停 / 清除。
    const hints_n = try Notifier.init(scope, cx, .{
        .position = .bottom_center,
        .content_insets = .{ .top = 56 },
        .strings = zh_strings,
    });
    const state = try cx.bindState(Story, .{ .n = n, .hints_n = hints_n, .cx = cx, .status = status });
    n.setListener(.{ .context = @ptrCast(state), .callback = Story.onEvent });
    hints_n.setListener(.{ .context = @ptrCast(state), .callback = Story.onEvent });
    root.meta.per_frame.hooks.slots.anim_state = @ptrCast(state);
    root.meta.per_frame.hooks.before_render.main = storyHook;

    const kinds = try controlRow(cx);
    try addButton(scope, cx, kinds, state, "成功 Success", "story.notify.btn.success", Story.success, .secondary);
    try addButton(scope, cx, kinds, state, "错误 Error", "story.notify.btn.error", Story.failure, .secondary);
    try addButton(scope, cx, kinds, state, "警告 Warning", "story.notify.btn.warning", Story.warning, .secondary);
    try addButton(scope, cx, kinds, state, "进行中 Progress", "story.notify.btn.progress", Story.progress, .secondary);
    try addButton(scope, cx, kinds, state, "需要操作 Action", "story.notify.btn.action", Story.action, .secondary);
    try addButton(scope, cx, kinds, state, "人员消息 Person", "story.notify.btn.person", Story.person, .secondary);
    try addButton(scope, cx, kinds, state, "撤销 Undo", "story.notify.btn.undo", Story.undo, .secondary);
    try addButton(scope, cx, kinds, state, "静默 Quiet", "story.notify.btn.quiet", Story.quiet, .secondary);
    try addButton(scope, cx, kinds, state, "汇总 Digest", "story.notify.btn.digest", Story.digest, .secondary);
    try root.appendChild(cx.allocator, try group(cx, try sectionLabel(cx, "九种类型 Nine kinds", "卡片 392 宽 · 圆角 18 · 液态玻璃；按钮在分隔线下方，中性灰底不上色。"), kinds));

    const hints = try controlRow(cx);
    try addButton(scope, cx, hints, state, "纯文案", "story.notify.hint.btn.plain", Story.hintPlain, .secondary);
    try addButton(scope, cx, hints, state, "成功", "story.notify.hint.btn.success", Story.hintSuccess, .secondary);
    try addButton(scope, cx, hints, state, "失败", "story.notify.hint.btn.error", Story.hintError, .secondary);
    try addButton(scope, cx, hints, state, "键帽", "story.notify.hint.btn.keycap", Story.hintKeycap, .secondary);
    try addButton(scope, cx, hints, state, "进行中 → 成功", "story.notify.hint.btn.loading", Story.hintLoading, .secondary);
    try addButton(scope, cx, hints, state, "可撤销", "story.notify.hint.btn.undo", Story.hintUndo, .secondary);
    try addButton(scope, cx, hints, state, "超长截断", "story.notify.hint.btn.long", Story.hintLong, .secondary);
    try root.appendChild(cx.allocator, try group(cx, try sectionLabel(cx, "文案提示 Text Toast", "36 高玻璃胶囊 · 与卡片同一个堆叠（折叠、悬停展开、横扫关闭）· 宽度随内容，最大 480。"), hints));

    const dual = try controlRow(cx);
    try addButton(scope, cx, dual, state, "卡片 → 右上（主实例）", "story.notify.dual.btn.card", Story.dualCards, .secondary);
    try addButton(scope, cx, dual, state, "提示 → 下中（第二实例）", "story.notify.dual.btn.hint", Story.dualHint, .secondary);
    try addButton(scope, cx, dual, state, "可撤销提示 → 下中", "story.notify.dual.btn.undo", Story.dualHintUndo, .secondary);
    try root.appendChild(cx.allocator, try group(cx, try sectionLabel(cx, "双实例 Two notifiers", "卡片要停右上、提示要停下中：建两个 Notifier。各自独立堆叠、悬停暂停与「全部清除」。"), dual));

    const stack = try controlRow(cx);
    try addButton(scope, cx, stack, state, "连发 4 条", "story.notify.btn.burst", Story.burst, .primary);
    try addButton(scope, cx, stack, state, "全部收起", "story.notify.btn.clear", Story.clear, .ghost);
    try stack.appendChild(cx.allocator, status);
    try root.appendChild(cx.allocator, try group(cx, try sectionLabel(cx, "堆叠 Stack", "折叠露边 9px · 悬停展开并暂停所有计时 · 删除中间一条平滑补位。"), stack));

    const pos = try controlRow(cx);
    try addButton(scope, cx, pos, state, "上左", "story.notify.pos.tl", Story.posTL, .secondary);
    try addButton(scope, cx, pos, state, "上中", "story.notify.pos.tc", Story.posTC, .secondary);
    try addButton(scope, cx, pos, state, "上右", "story.notify.pos.tr", Story.posTR, .secondary);
    try addButton(scope, cx, pos, state, "右中", "story.notify.pos.rc", Story.posRC, .secondary);
    try addButton(scope, cx, pos, state, "右下", "story.notify.pos.br", Story.posBR, .secondary);
    try addButton(scope, cx, pos, state, "下中", "story.notify.pos.bc", Story.posBC, .secondary);
    try addButton(scope, cx, pos, state, "下左", "story.notify.pos.bl", Story.posBL, .secondary);
    try addButton(scope, cx, pos, state, "左中", "story.notify.pos.lc", Story.posLC, .secondary);
    try root.appendChild(cx.allocator, try group(cx, try sectionLabel(cx, "八个停靠位置 Positions", "位置只改锚点、增长方向、入场位移方向；切换不重建卡片。"), pos));

    // 玻璃需要有内容的背景才看得出来：模拟卡片身后的正文（设计稿里提醒浮在编辑器正文上）。
    const backdrop = try ui.box(cx, .{ .width = .{ .grow = .{} }, .direction = .column, .gap = 0 }, .{});
    backdrop.meta.ownership.meta.test_id = "story.notify.backdrop";
    const tints = [_]u24{ 0xE4572E, 0x17BEBB, 0xFFC914, 0x2E282A, 0x76B041, 0x8059BB };
    var li: usize = 0;
    while (li < 36) : (li += 1) {
        const line = try ui.box(cx, .{ .width = .{ .grow = .{} }, .height = .{ .px = 22 }, .direction = .row, .gap = 28, .padding = ui.Padding.symmetric(0, 12), .align_items = .center, .background = ui.arb.hex(tints[li % tints.len]) }, .{});
        var k: usize = 0;
        while (k < 6) : (k += 1) try line.appendChild(cx.allocator, try ui.text(cx, "The foundation of any great editor", .{ .font_size = 13, .color = ui.arb.hex(0xFFFFFF) }));
        try backdrop.appendChild(cx.allocator, line);
    }
    try root.appendChild(cx.allocator, backdrop);

    if (!n.portaled) try root.appendChild(cx.allocator, n.container);
    if (!hints_n.portaled) try root.appendChild(cx.allocator, hints_n.container);
    return root;
}

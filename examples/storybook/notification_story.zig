//! Notification story: design spec section 16 in-app global alerts.
//! All cards created by Notifier; nine types, stacking, eight positions + in-place conversion each
//! has entry.
const std = @import("std");
const ui = @import("ui");

const v = ui.view;
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
    /// Dual instance demo: second Notifier fixed at bottom-center, text hints only (primary
    /// instance has cards).
    hints_n: *Notifier,
    cx: *ui.Cx,
    /// Status line text (owned: event callback stacks compose text copied by signal).
    status: *ui.Signal([]const u8),
    /// Simulated progress card (id + start frame time + duration).
    progress_id: ?Id = null,
    progress_start_ms: f64 = 0,
    /// Wall-clock start of the current hover pause. The hook can run several times per frame
    /// (hit-test refreshes), so the pause is settled once on resume instead of accumulating dt.
    progress_paused_at: ?f64 = null,
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
    var close_lens: [16]usize = @splat(0);
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
        self.status.set(text);
    }

    // -- Nine types (16.2) --

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

    // -- Text hints (16.13): same stack as cards --

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

    /// In-progress -> 2.4s later same id in-place convert to success (show 2 more seconds).
    fn tickHint(self: *Story) void {
        const id = self.hint_loading_id orelse return;
        // Collapsed (all-collapse / sweep-close): won't convert in-place, else new card with same
        // id.
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

    // -- Stacking / clear --

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

    // -- Dual instance: cards top-right (primary), text hints bottom-center (second) --

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

    // -- In-place conversion (16.6) --

    fn startProgress(self: *Story, id: Id, duration_ms: f64) void {
        self.progress_id = id;
        self.progress_start_ms = self.cx.frame_time_ms;
        self.progress_paused_at = null;
        self.progress_duration_ms = duration_ms;
    }

    fn tickProgress(self: *Story) void {
        const id = self.progress_id orelse return;
        if (self.n.cardForId(id) == null) {
            self.progress_id = null;
            return;
        }
        // Hover pauses all timers, progress simulation also pauses (demo: advance by remaining).
        const now = self.cx.frame_time_ms;
        if (self.n.isPaused()) {
            if (self.progress_paused_at == null) self.progress_paused_at = now;
            return;
        }
        if (self.progress_paused_at) |paused_at| {
            self.progress_start_ms += @max(0, now - paused_at);
            self.progress_paused_at = null;
        }
        const p: f32 = @floatCast(std.math.clamp((now - self.progress_start_ms) / self.progress_duration_ms, 0, 1));
        var label_buf: [64]u8 = undefined;
        var count_buf: [16]u8 = undefined;
        const done: u32 = @intFromFloat(@floor(p * 5));
        const secs: u32 = @intFromFloat(@ceil((1 - p) * self.progress_duration_ms / 1000));
        const label = std.fmt.bufPrint(&label_buf, "上传中 · 预计 {d} 秒", .{secs}) catch "";
        const count = std.fmt.bufPrint(&count_buf, "{d} / 5", .{done}) catch "";
        self.n.setProgress(id, p, label, count);
        if (p >= 1) {
            self.progress_id = null;
            // Progress full: icon -> checkmark, title rewritten, life reset to 3400ms.
            self.n.update(id, .{ .tone = .success, .title = self.progress_title_done, .body = self.progress_body_done, .duration_ms = 3400 }) catch {};
        }
    }

    fn onEvent(ctx: ?*anyopaque, n: *Notifier, e: W.NotificationEvent) void {
        const self: *Story = @ptrCast(@alignCast(ctx orelse return));
        var buf: [96]u8 = undefined;
        self.setStatus(std.fmt.bufPrint(&buf, "event · {s} · {s}", .{ @tagName(e.kind), e.tag }) catch "event");
        if (e.kind != .action) return;
        if (std.mem.eql(u8, e.tag, "undo-replace")) {
            // After undo convert in-place to result hint.
            _ = n.hint(.{ .id = e.id, .text = "已撤销替换" }) catch return;
            return;
        }
        if (std.mem.eql(u8, e.tag, "retry")) {
            // Persisted error card becomes progress card in-place: born unchanged, no re-entrance.
            n.update(e.id, .{
                .kind = .progress,
                .tone = .info,
                .title = "正在重新上传",
                .body = "dist/app.zip",
                .progress = .{ .value = 0, .label = "上传中", .count = "0 / 5" },
            }) catch return;
            self.startProgress(e.id, 5200);
        } else if (std.mem.eql(u8, e.tag, "accept")) {
            // Button area wholly removed, height shrinks; auto-collapse after 2600ms.
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

/// Escape hatch: progress simulation / hint in-place conversion advance per-frame,
/// needs before_render hook on root node.
fn installHook(state: *Story, root: *ui.Node) void {
    root.meta.per_frame.hooks.slots.anim_state = @ptrCast(state);
    root.meta.per_frame.hooks.before_render.main = storyHook;
}

const NotifyS = struct {
    fn root(_: *const ui.theme.Values) ui.BoxStyle {
        return .{ .width = .{ .grow = .{} }, .align_self = .stretch, .gap = 12 };
    }
    fn group(t: *const ui.theme.Values) ui.BoxStyle {
        return .{
            .width = .{ .grow = .{} },
            .gap = 10,
            .padding = ui.Padding.all(14),
            .background = t.tokens.color.bg_secondary,
            .border = .{ .overlay = true, .width = 1, .color = t.tokens.color.border, .radius = t.tokens.radius.lg },
        };
    }
    fn section(_: *const ui.theme.Values) ui.BoxStyle {
        return .{ .gap = 3 };
    }
    fn sectionTitle(t: *const ui.theme.Values) ui.TextStyle {
        return .{ .font_size = 13, .font_weight = 700, .color = t.tokens.color.fg_primary };
    }
    fn sectionDesc(t: *const ui.theme.Values) ui.TextStyle {
        return .{ .font_size = 12, .font_weight = 400, .color = t.tokens.color.fg_tertiary };
    }
    fn controlRow(_: *const ui.theme.Values) ui.BoxStyle {
        return .{ .width = .{ .grow = .{} }, .align_items = .center, .gap = 8, .flex_wrap = .wrap };
    }
    fn status(t: *const ui.theme.Values) ui.TextStyle {
        return .{ .font_size = 12, .font_weight = 550, .color = t.tokens.color.fg_secondary };
    }
    fn backdrop(_: *const ui.theme.Values) ui.BoxStyle {
        return .{ .width = .{ .grow = .{} }, .gap = 0 };
    }
    fn backdropLine(tint: u24) ui.BoxStyle {
        return .{
            .width = .{ .grow = .{} },
            .height = .{ .px = 22 },
            .gap = 28,
            .padding = ui.Padding.symmetric(0, 12),
            .align_items = .center,
            .background = ui.arb.hex(tint),
        };
    }
    fn backdropText(_: *const ui.theme.Values) ui.TextStyle {
        return .{ .font_size = 13, .color = ui.arb.hex(0xFFFFFF) };
    }
};

const section_props = .{ .style = NotifyS.section };
const title_props = .{ .style = NotifyS.sectionTitle };
const desc_props = .{ .style = NotifyS.sectionDesc };
const SectionLabel = v.Box(@TypeOf(section_props), struct { v.Text(@TypeOf(title_props), []const u8), v.Text(@TypeOf(desc_props), []const u8) }, .column);

fn sectionLabel(title: []const u8, description: []const u8) SectionLabel {
    return v.col(section_props, .{ v.text(title_props, title), v.text(desc_props, description) });
}

const group_props = .{ .style = NotifyS.group };

fn group(title: []const u8, description: []const u8, controls: anytype) v.Box(@TypeOf(group_props), struct { SectionLabel, @TypeOf(controls) }, .column) {
    return v.col(group_props, .{ sectionLabel(title, description), controls });
}

const control_props = .{ .style = NotifyS.controlRow };

const ButtonAttrs = struct { test_id: []const u8 };
const StoryButton = v.Attrs(ButtonAttrs, @TypeOf(W.Button(.{})));

fn button(state: *Story, label: []const u8, test_id: []const u8, comptime method: fn (*Story) void, variant: W.ButtonVariant) StoryButton {
    return v.attrs(ButtonAttrs{ .test_id = test_id }, W.Button(.{ .label = label, .variant = variant, .size = .sm, .on_click = ui.on.call(state, method) }));
}

// Glass needs content background to show: simulate body text behind card
// (spec shows reminder floating over editor body).
/// 36 lines body text, background color alternates by row.
const backdrop_rows = @as([36]void, @splat({}));
const backdrop_tints = [_]u24{ 0xE4572E, 0x17BEBB, 0xFFC914, 0x2E282A, 0x76B041, 0x8059BB };
const backdrop_word = v.text(.{ .style = NotifyS.backdropText }, "The foundation of any great editor");
const BackdropWord = @TypeOf(backdrop_word);
const BackdropLineProps = struct { style: ui.BoxStyle };

fn backdropLine(_: void, index: usize) v.Box(BackdropLineProps, [6]BackdropWord, .row) {
    return v.row(BackdropLineProps{ .style = NotifyS.backdropLine(backdrop_tints[index % backdrop_tints.len]) }, @as([6]BackdropWord, @splat(backdrop_word)));
}

pub fn build(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const n = try Notifier.init(scope, cx, .{
        .position = .bottom_center,
        // Storybook top toolbar 56px.
        .content_insets = .{ .top = 56 },
        .strings = zh_strings,
    });
    // Second instance: fixed bottom-center, text hints only; each independent
    // stacking / hover / clear from primary.
    const hints_n = try Notifier.init(scope, cx, .{
        .position = .bottom_center,
        .content_insets = .{ .top = 56 },
        .strings = zh_strings,
    });
    const status = try scope.createText("event · idle", .{});
    const state = try scope.createState(Story, .{ .n = n, .hints_n = hints_n, .cx = cx, .status = status });
    n.setListener(.{ .context = @ptrCast(state), .callback = Story.onEvent });
    hints_n.setListener(.{ .context = @ptrCast(state), .callback = Story.onEvent });

    return v.render(scope, cx, v.setup(v.col(.{ .style = NotifyS.root }, .{
        group("九种类型 Nine kinds", "卡片 392 宽 · 圆角 18 · regular 液态玻璃（GlassBox，同 AppKit NSGlassEffectView）；内容 12px padding / 8px gap；按钮使用语义色（主操作 accent，次操作 1px border）。", v.row(control_props, .{
            button(state, "成功 Success", "story.notify.btn.success", Story.success, .secondary),
            button(state, "错误 Error", "story.notify.btn.error", Story.failure, .secondary),
            button(state, "警告 Warning", "story.notify.btn.warning", Story.warning, .secondary),
            button(state, "进行中 Progress", "story.notify.btn.progress", Story.progress, .secondary),
            button(state, "需要操作 Action", "story.notify.btn.action", Story.action, .secondary),
            button(state, "人员消息 Person", "story.notify.btn.person", Story.person, .secondary),
            button(state, "撤销 Undo", "story.notify.btn.undo", Story.undo, .secondary),
            button(state, "静默 Quiet", "story.notify.btn.quiet", Story.quiet, .secondary),
            button(state, "汇总 Digest", "story.notify.btn.digest", Story.digest, .secondary),
        })),
        group("文案提示 Text Toast", "36 高玻璃胶囊 · 与卡片同一个堆叠（折叠、悬停展开、横扫关闭）· 宽度随内容，最大 480。", v.row(control_props, .{
            button(state, "纯文案", "story.notify.hint.btn.plain", Story.hintPlain, .secondary),
            button(state, "成功", "story.notify.hint.btn.success", Story.hintSuccess, .secondary),
            button(state, "失败", "story.notify.hint.btn.error", Story.hintError, .secondary),
            button(state, "键帽", "story.notify.hint.btn.keycap", Story.hintKeycap, .secondary),
            button(state, "进行中 → 成功", "story.notify.hint.btn.loading", Story.hintLoading, .secondary),
            button(state, "可撤销", "story.notify.hint.btn.undo", Story.hintUndo, .secondary),
            button(state, "超长截断", "story.notify.hint.btn.long", Story.hintLong, .secondary),
        })),
        group("双实例 Two notifiers", "卡片要停右上、提示要停下中：建两个 Notifier。各自独立堆叠、悬停暂停与「全部清除」。", v.row(control_props, .{
            button(state, "卡片 → 右上（主实例）", "story.notify.dual.btn.card", Story.dualCards, .secondary),
            button(state, "提示 → 下中（第二实例）", "story.notify.dual.btn.hint", Story.dualHint, .secondary),
            button(state, "可撤销提示 → 下中", "story.notify.dual.btn.undo", Story.dualHintUndo, .secondary),
        })),
        group("堆叠 Stack", "折叠露边 9px · 悬停展开并暂停所有计时 · 删除中间一条平滑补位。", v.row(control_props, .{
            button(state, "连发 4 条", "story.notify.btn.burst", Story.burst, .primary),
            button(state, "全部收起", "story.notify.btn.clear", Story.clear, .ghost),
            v.text(.{ .style = NotifyS.status, .test_id = "story.notify.status" }, status),
        })),
        group("八个停靠位置 Positions", "位置只改锚点、增长方向、入场位移方向；切换不重建卡片。", v.row(control_props, .{
            button(state, "上左", "story.notify.pos.tl", Story.posTL, .secondary),
            button(state, "上中", "story.notify.pos.tc", Story.posTC, .secondary),
            button(state, "上右", "story.notify.pos.tr", Story.posTR, .secondary),
            button(state, "右中", "story.notify.pos.rc", Story.posRC, .secondary),
            button(state, "右下", "story.notify.pos.br", Story.posBR, .secondary),
            button(state, "下中", "story.notify.pos.bc", Story.posBC, .secondary),
            button(state, "下左", "story.notify.pos.bl", Story.posBL, .secondary),
            button(state, "左中", "story.notify.pos.lc", Story.posLC, .secondary),
        })),
        v.col(.{ .style = NotifyS.backdrop, .test_id = "story.notify.backdrop" }, v.list(&backdrop_rows, backdropLine)),
        // Notifier without portal (no overlay host) container attached to story root.
        if (!n.portaled) n.container else null,
        if (!hints_n.portaled) hints_n.container else null,
    }), state, installHook));
}

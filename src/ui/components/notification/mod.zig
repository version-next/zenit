//! Notifier: app-wide alerts (design spec 16 In-App Notifications).
//!
//! Alert = one Card object; render each frame computes transform and alpha only;
//! all time quantities derive from born/left_at/deadline wall-clock timestamps.
//!
//! Key invariants (16.8 implementation notes):
//! 1. Each alert owns its node (fixed slot). Deleting a middle card does not shift siblings'
//!    nodes; cards above do not replay entrance.
//! 2. Entry/exit lerp per frame, no keyframe animation.
//! 3. Per-frame drive and tween don't stack: while a card is exiting, this card's entrance is
//!    < 620ms, or expanding/collapsing, position tracks the per-frame target directly; else a
//!    target jump tweens for 540ms.
//! 4. Hover = per-frame hit test on the group bounding box (expanded 18px), no enter/exit events.
//!    Expand state is frozen during exit; after exit it is re-judged by the pointer's real coords.
//! 5. z order is reversed from layer order: layer 0 (newest, closest to anchor) has highest z.
//!
//! Hint text (16.13) is a lightweight card form (kind=.hint): one-line glass capsule, same
//! stack as cards; see hint.zig and Notifier.hint.
//!
//! Notification center (history, do-not-disturb, bell entry) is app layer: the host logs history
//! at its own show site, decides whether to popup, and learns close/expire/button via Listener
//! events.
const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../../core.zig");
const view = @import("../../view.zig");
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
const glass_box = @import("../glass_box/mod.zig");
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

/// Alert content and behavior. Strings copied and owned by Notifier.
pub const Notification = struct {
    /// Existing id: in-place convert (keep born, no entrance replay).
    id: ?Id = null,
    kind: Kind = .default,
    tone: Tone = .info,
    title: []const u8 = "",
    body: []const u8 = "",
    /// Override semantic tone default glyph (check/X/triangle ...).
    glyph: ?svg_assets.Asset = null,
    /// Override leading icon position default presentation (derived from kind/tone/avatar).
    lead: ?Lead = null,
    /// Personnel message avatar initials.
    avatar: []const u8 = "",
    /// Monospace buttons below divider (max 2). undo type defaults to "undo".
    actions: []const Action = &.{},
    /// Inline reply box (Enter or "send" button submits).
    reply: bool = false,
    /// Quoted line after reply sent (for in-place convert).
    quote: ?[]const u8 = null,
    progress: ?Progress = null,
    /// Persistent: no auto-dismiss.
    sticky: bool = false,
    /// Override type default dwell duration.
    duration_ms: ?u32 = null,
    /// Override progress bar display (default: show when time-limited and not progress kind).
    life_bar: ?bool = null,
    /// kind=.hint: leading mark and keycap row (title = capsule body). Usually constructed via
    /// Notifier.hint.
    hint_mark: HintMark = .none,
    keycap: ?HintKeycap = null,
};

pub const EventKind = enum {
    /// Clicked action button (tag/index identifies which).
    action,
    /// Clicked undo (countdown ring now shows check in place).
    undo,
    /// Reply box submitted (text = reply content).
    reply,
    /// User closed (X or drag-flick away).
    dismissed,
    /// Expired auto-dismiss.
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
    /// Max cards shown when expanded (2-6).
    max_visible: u8 = Spec.default_max_visible,
    /// false: hover only pauses timer, no expand.
    expand_on_hover: bool = true,
    /// Content area inset from window (title bar/status bar); dock margin 22 starts here.
    content_insets: Insets = .{},
    width: f32 = Spec.card_width,
    strings: Strings = .{},
    listener: ?Listener = null,
};

const PendingOp = union(enum) {
    button: struct { id: Id, seq: u64, revision: u64, index: u8 },
    close: struct { id: Id, seq: u64, revision: u64 },
    /// Badge-adjacent "clear all": all on-screen alerts exit by user close.
    clear_all,
};

pub const Notifier = struct {
    cx: *Cx,
    scope: *Scope,
    allocator: Allocator,
    /// Transparent portal root over full window; only children receive hits.
    container: *Node,
    portaled: bool = false,
    pill: *Node,
    /// Badge/clear button glass state: read family_dark to decide text and icon color
    pill_glass: *glass_box.AdaptiveGlassBoxState,
    clear_glass: *glass_box.AdaptiveGlassBoxState,
    clear_icon: *Node,
    pill_icon_more: *Node,
    pill_icon_paused: *Node,
    pill_label: *Node,
    /// Clear-all button to the right of the badge pill (expands text on hover, iOS Notification
    /// Center style).
    clear_btn: *Node,
    /// Disclosure layer wrapping the text: width animates between 0 and natural text width
    /// (overflow clipped).
    clear_reveal: *Node,
    clear_label: *Node,
    clear_alpha: f32 = 0,
    /// First click 'arms' the button: pill expands to show 'clear all', second click actually
    /// clears; moving away retracts.
    clear_armed: bool = false,
    /// Expansion progress 0..1 (per-frame approach to clear_armed).
    clear_reveal_t: f32 = 0,
    layer_handle: overlay_stack_mod.LayerHandle,

    options: Options,
    strings: Strings,
    cards: std.ArrayListUnmanaged(*Card) = .empty,
    pending: std.ArrayListUnmanaged(PendingOp) = .empty,
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
    /// Inside a frame() call after frame clock advances: last_now_ms can be used directly for
    /// timestamping.
    in_frame: bool = false,
    reclaimed_this_frame: bool = false,
    last_frame_ms: f64 = 0,
    /// Previous frame's anchor point portion that changes with viewport (vertical); when viewport
    /// changes, shift all card follow_y by the same amount (see model.Follow.shift).
    last_anchor_ref: ?f32 = null,

    refs: usize = 1,
    container_alive: bool = false,
    layer_removed: bool = false,
    closed: bool = false,

    // --------
    // Lifecycle
    // --------

    pub fn init(scope: *Scope, cx: *Cx, options: Options) !*Notifier {
        const my_scope = try scope.childScope();
        errdefer my_scope.dispose();
        const allocator = cx.allocator;
        const pal = styles.palette(cx.tokens);

        const Parts = struct { pill: glass_box.GlassBoxMount, clear: glass_box.GlassBoxMount, icon_more: *Node, icon_paused: *Node, pill_label: *Node, clear_icon: *Node, clear_reveal: *Node, clear_label: *Node };
        var parts: Parts = undefined;
        const pill_icon = core.Sizing.fixed(M.pill_icon);
        const pill_h = core.Sizing.fixed(M.pill_height);
        const container = try view.render(my_scope, cx, view.box(.{ .style = .{
            .position = .absolute,
            .width = core.Sizing.fill(),
            .height = core.Sizing.fill(),
            .inset = .{ .top = .{ .px = 0 }, .right = .{ .px = 0 }, .bottom = .{ .px = 0 }, .left = .{ .px = 0 } },
            .hit_behavior = .children_only,
        } }, .{
            // Badge pill (StackPill): collapsed 'N more · hover to expand' / expanded 'hovering ·
            // paused'.
            // Regular glass capsule (GlassBox): material, shadow, and tone managed by glass; text
            // and icon colors follow glass tone per frame (24pt height uses small-size inversion,
            // see applyPill).
            view.capture(&parts.pill, view.with(pillGlass(.none), .{
                view.capture(&parts.icon_more, view.icon(.{ .style = .{ .width = pill_icon, .height = pill_icon }, .tint = pal.pill_icon }, icons.chevrons_up)),
                view.capture(&parts.icon_paused, view.icon(.{ .style = .{ .width = core.Sizing.fixed(0), .height = pill_icon }, .tint = pal.pill_icon }, icons.pause)),
                view.capture(&parts.pill_label, card_mod.plainText("", .{ .color = pal.pill_fg, .font_size = M.pill_font, .font_weight = 550 })),
            })),
            // Clear-all button: .glass button capsule (darkens on press per native testing);
            // expands text on hover, one click clears all notifications. GlassBox press feedback
            // occupies root's event slot; click handling attached to body filling the capsule.
            view.capture(&parts.clear, view.with(pillGlass(.glass_button), .{
                view.capture(&parts.clear_icon, view.icon(.{ .style = .{ .width = pill_icon, .height = pill_icon }, .tint = pal.pill_icon }, icons.close)),
                // Disclosure layer wrapping text: width animates between 0 and natural text width
                // (overflow clipped).
                view.capture(&parts.clear_reveal, view.row(.{ .style = .{
                    .width = core.Sizing.fixed(0),
                    .height = pill_h,
                    .align_items = .center,
                    .overflow_hidden = true,
                    .flex_shrink = 0,
                } }, view.capture(&parts.clear_label, card_mod.styledText(
                    options.strings.clear_all,
                    .{ .color = pal.pill_fg, .font_size = M.pill_font, .font_weight = 550 },
                    .{ .flex_shrink = 0, .margin = .{ .left = 5, .right = 3 }, .opacity = 0 },
                )))),
            })),
        }));
        errdefer cx.freeNode(container);
        container.meta.ownership.meta.component_name = "NotificationViewport";
        // Capsule absolutely positioned at z-index 200; body horizontal center, fills capsule
        // (padding on body; event and hit cover entire capsule).
        const pill = parts.pill.box;
        const pill_body = parts.pill.body;
        try placePillGlass(cx, parts.pill);
        pill_body.style.gap = 6;
        pill_body.style.padding = core.Padding.symmetric(0, 11);
        (try pill.style.ensureExtFallible(allocator)).hit_behavior = .pass_through;
        pill.meta.ownership.meta.component_name = "Notification.pill";
        const icon_more = parts.icon_more;
        const icon_paused = parts.icon_paused;
        const pill_label = parts.pill_label;

        const clear_btn = parts.clear.box;
        const clear_body = parts.clear.body;
        try placePillGlass(cx, parts.clear);
        clear_body.style.justify = .center;
        clear_body.style.padding = core.Padding.symmetric(0, (M.pill_height - M.pill_icon) / 2);
        (try clear_btn.style.ensureExtFallible(allocator)).min_width = M.pill_height;
        parts.clear.state.surface.style.overflow_hidden = true;
        clear_body.style.cursor = .pointer;
        clear_btn.setOpacityRaw(0);
        clear_btn.setHitTestVisible(false);
        clear_btn.meta.ownership.meta.component_name = "Notification.clearAll";
        clear_body.behavior.interaction.a11y = .{ .role = .button, .label = options.strings.clear_all };
        const clear_reveal = parts.clear_reveal;
        const clear_label = parts.clear_label;

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
            .pill_glass = parts.pill.state,
            .clear_glass = parts.clear.state,
            .clear_icon = parts.clear_icon,
            .pill_icon_more = icon_more,
            .pill_icon_paused = icon_paused,
            .pill_label = pill_label,
            .clear_btn = clear_btn,
            .clear_reveal = clear_reveal,
            .clear_label = clear_label,
            .layer_handle = layer_handle,
            .options = options,
            .strings = options.strings,
            // Using current frame clock as baseline: first hook dedup reentry tick (clock not
            // advanced) on hit test also deduped.
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
        // scope and container each hold a reference; either can be destroyed first safely.
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
        clear_body.behavior.events.on_event = clearAllEvent;
        clear_body.behavior.events.event_context = @ptrCast(self);
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

    /// Free all card state. When free_nodes=false, nodes reclaimed with container (container
    /// cleanup path).
    fn releaseCards(self: *Notifier, free_nodes: bool) void {
        for (self.cards.items) |card| self.destroyCard(card, free_nodes);
        self.cards.clearRetainingCapacity();
    }

    // --------
    // Public API
    // --------

    /// Pop a notification; existing id transforms in-place. Over 6 on-screen: oldest exits
    /// normally.
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

    /// In-place transform: rewrite kind/tone/title/body, reset life, swap icon, no destroy/rebuild
    /// card, born unchanged, no entry replay (16.6).
    pub fn update(self: *Notifier, id: Id, n: Notification) !void {
        const card = self.findLive(id) orelse return error.NotificationNotFound;
        try self.transformCard(card, n);
    }

    /// Update progress card's progress (no content rebuild).
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

    /// Position switch without rebuild; changes anchor parameters only; exiting card continues exit
    /// in new direction.
    pub fn setPosition(self: *Notifier, position: Position) void {
        self.options.position = position;
        // Anchoring position change is reflow (interpolate), not viewport pan: clear anchor
        // baseline to prevent next frame mistaking anchor-type switch for window-size change pan.
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

    /// Count of on-screen (non-exiting) notifications.
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

    // -- Text hint (16.13) --

    /// Pop a text hint (36pt glass capsule), joins same stack as cards. Existing id transforms
    /// in-place (in-progress -> success). Button click emits .action event; if host does not
    /// in-place transform it in callback, it closes after click.
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

    /// Equivalent to clicking the button on the latest button-bearing text hint: call in Cmd+Z and
    /// similar shortcuts; return true if hint consumed (false if no such hint exists, Cmd+Z
    /// delegates to editor undo stack).
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

    /// Fetch card (for test ids, telemetry, screenshot assertions).
    pub fn cardForId(self: *Notifier, id: Id) ?*Card {
        for (self.cards.items) |card| if (card.id == id) return card;
        return null;
    }

    // --------
    // Card creation/transformation/destruction
    // --------

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

    /// Type defaults (16.2): duration, persistent, life, leading icon, undo button.
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

        // Capsule holds one button only.
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
        // Card complete after content builds; later failures defer to destroyCard for cleanup;
        // before that, items below errdefer individually (mutually exclusive, prevent double-free).
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
            .glass_root = undefined,
            .surface = undefined,
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
        // content.scope is independent root scope (see buildContent); freeNode(positioner) does not
        // release it; drag attach/appendChild failures previously leaked entire content scope here.
        complete = true;
        errdefer self.destroyCard(card, true);
        card_mod.rebindButtons(card);
        card.positioner.meta.ownership.hooks.on_cleanup = null;
        card.positioner.behavior.interaction.a11y = .{
            .role = if (r.spec.tone == .@"error" or r.spec.tone == .warning) .alert else .status,
            .live = if (r.spec.tone == .@"error") "assertive" else "polite",
            .live_text = card.spec.title,
        };
        // Horizontal drag-to-dismiss (84px threshold); X / button area / reply box are
        // non-draggable.
        card.drag_binding = try drag.Binding.attach(card.scope, self.cx, card.positioner, .{
            .axis = .horizontal,
            .activation_distance = 4,
            .can_start = dragCanStart,
        }, dragCallback, @ptrCast(card));
        // Trackpad two-finger swipe equals drag (hung on surface: drag source already occupies
        // positioner event slot).
        card.surface.behavior.events.on_scroll = scrollHandler;
        card.surface.behavior.events.event_context = @ptrCast(card);
        // First frame: layout only, no display; entry begins after measuring true height.
        applyHidden(card);
        try self.container.appendChild(self.allocator, card.positioner);
        card.born_wall_ms = @as(i64, @intCast(@divFloor(@import("zenit_time").nanoTimestamp(card.cx.io), std.time.ns_per_ms)));
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
        // Life and new content layer measure happens in frame step 1: update() may be called
        // outside frame, frame clock may not be fresh.
        card.life = model.Life.sticky();
        card.life_pending_ms = if (r.sticky) null else @floatFromInt(r.duration_ms);
        card.positioner.behavior.interaction.a11y.?.live_text = card.spec.title;
        // Icon swap: 460ms spring-in; other content: 200ms cross-fade. Begin after measuring new
        // height.
        card.icon_pop_at_ms = null;
        card.crossfade_at_ms = null;
        card.content.root.setOpacityRaw(0);
        card.content_pending = true;
        self.container.markRenderDirty();
    }

    fn destroyCard(self: *Notifier, card: *Card, free_nodes: bool) void {
        // Unbind gesture first: scope dispose may emit .cancel while node still alive.
        card.destroying = true;
        card.drag_binding = null;
        if (!card.scope.disposed) card.scope.dispose();
        // live_text points to title in arena; node release deferred during tick, disconnect first
        // then free arena.
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
        // Cancel in-progress gesture on exit (user may hold when squeezed by on-screen limit or
        // expiration).
        if (card.dragging and !card.scroll_dragging) {
            if (card.drag_binding) |b| b.cancel(.explicit);
        }
        card.dragging = false;
        card.scroll_dragging = false;
        // Don't timestamp here: may be in event callback or hit-test reentry tick, clock is stale.
        // Timestamp in next real frame (frame step 0).
        card.left_at_ms = if (self.in_frame) self.last_now_ms else null;
        card.positioner.setHitTestVisible(false);
        card.close.setHitTestVisible(false);
        if (!card.measured) card.instant_exit = true; // Never displayed: dismiss immediately.
        self.container.markRenderDirty();
    }

    // Events (button/close); clicks occur on event stack, deferred to next
    // frame for handling: handling may remove the clicked button itself
    // (in-place transformation swaps button area).

    fn onButton(card: *Card, index: u8) void {
        const self = notifierOf(card) orelse return;
        self.pending.append(self.allocator, .{ .button = .{ .id = card.id, .seq = card.seq, .revision = card.revision, .index = index } }) catch return;
        self.container.markRenderDirty();
    }

    fn clearAllEvent(event: events.Event, context: ?*anyopaque) events.EventResult {
        const self: *Notifier = @ptrCast(@alignCast(context orelse return .ignored));
        if (self.closed) return .ignored;
        switch (event) {
            // Move away to retract (unconfirmed clear doesn't persist).
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

    /// First tap: expand and confirm; second tap: clear (iOS Notification Center two-step).
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

    /// User 'clear all': all on-screen notifications dismiss by user action, each triggers
    /// `.dismissed`.
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
                    // Collect ids first: callback may show/dismiss, modifying card table.
                    var ids: [Spec.max_on_screen * 2]Id = undefined;
                    var n: usize = 0;
                    for (self.cards.items) |card| {
                        if (card.leaving or n >= ids.len) continue;
                        ids[n] = card.id;
                        n += 1;
                    }
                    for (ids[0..n]) |id| {
                        const card = self.findLive(id) orelse continue;
                        // Clear batch doesn't reposition: each card fades in place, avoid
                        // reordering during exit.
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
                        // Hint: if host doesn't in-place-transform in callback, dismiss after tap.
                        if (self.findLive(b.id)) |c| {
                            if (c == card and c.spec.kind == .hint and c.revision == revision) self.beginLeave(c, false);
                        }
                    }
                },
            }
        }
        self.pending.clearRetainingCapacity();
    }

    /// Send reply: replace input with quoted content, avatar -> checkmark, dismiss 2200ms later
    /// (16.6).
    /// On failure, caller uses replyFailed() to in-place-transform to error and restore input.
    fn sendReply(self: *Notifier, card: *Card) void {
        const state = card.content.reply_state orelse return;
        const raw = std.mem.trim(u8, state.getText(), " \t\r\n");
        if (raw.len == 0) return;
        // Copy all needed strings first, only then replace last_reply: any step's failure keeps old
        // state.
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

    /// Reply send failed: in-place-transform to error type and restore previous content to input.
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
            if (card.content.reply_value) |v| v.set(text);
        }
    }

    /// Click undo: countdown ring stops and becomes checkmark, dismiss 2400ms later (16.6).
    fn settleUndo(self: *Notifier, card: *Card) void {
        self.transformCard(card, .{
            .kind = .default,
            .tone = .success,
            .title = card.spec.title,
            .body = card.spec.body,
            .duration_ms = model.Durations.undo_settle,
        }) catch {};
    }

    // --------
    // Drag/swipe-to-close (16.7)
    // --------

    fn dragCanStart(req: drag.StartRequest, ctx: *anyopaque) bool {
        _ = req;
        const card: *Card = @ptrCast(@alignCast(ctx));
        if (card.leaving) return false;
        // Pressing non-draggable areas doesn't start swipe: close button, button area, input.
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
        // During destroy/exit (including .cancel from scope dispose): only reset, don't touch
        // Notifier or nodes.
        if (card.destroying or card.leaving) {
            card.dragging = false;
            card.scroll_dragging = false;
            return;
        }
        const self = notifierOf(card) orelse return;
        switch (ev.phase) {
            .start => {
                // Mouse takes over swipe: continue from current offset, end swipe state (trackpad
                // ended/cancelled can't release mouse-holding user).
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

    /// Trackpad two-finger swipe: gesture-driven only. Changed accumulates offset, ended
    /// decides close or bounce, cancelled (interrupt / blur / new gesture) always bounces.
    /// Mouse wheel has no gesture phase, can't judge release, doesn't drive swipe (like macOS).
    fn scrollHandler(ev: events.ScrollEvent, ctx: ?*anyopaque) core.EventResult {
        const card: *Card = @ptrCast(@alignCast(ctx orelse return .ignored));
        const self = notifierOf(card) orelse return .ignored;
        if (card.leaving or card.dragging and !card.scroll_dragging) return .ignored;
        // Inertia after release; swipe already ended.
        if (ev.isMomentum()) return .ignored;
        switch (ev.phase) {
            .none, .may_begin, .began => return .ignored,
            .ended, .cancelled => {
                if (!card.scroll_dragging) return .ignored;
                card.drag_dx += ev.dx;
                if (ev.phase == .ended) self.releaseDrag(card) else self.springBack(card);
                self.container.markRenderDirty();
                return .stop;
            },
            .changed => {},
        }
        if (!card.scroll_dragging and @abs(ev.dx) <= @abs(ev.dy) * 1.2) return .ignored;
        card.scroll_dragging = true;
        card.dragging = true;
        card.spring_at_ms = null;
        card.spring_pending = false;
        card.drag_dx += ev.dx;
        self.container.markRenderDirty();
        return .stop;
    }

    fn releaseDrag(self: *Notifier, card: *Card) void {
        const dx = model.constrainSwipe(self.options.position, card.drag_dx);
        card.dragging = false;
        card.scroll_dragging = false;
        if (model.swipeCommits(self.options.position, dx)) {
            // Over 84px: close and fling (during exit, continue as flingX × (1 + 1.1p)).
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
        // Bounce from display position (after rubber-band damping), not raw offset,
        // else reverse-drag release bounces then returns.
        card.drag_dx = model.constrainSwipe(self.options.position, card.drag_dx);
        card.spring_from = card.drag_dx;
        card.spring_at_ms = if (self.in_frame) self.last_now_ms else null;
        card.spring_pending = !self.in_frame;
    }

    // --------
    // Per-frame driving
    // --------

    fn frameHook(node: *Node) void {
        const self: *Notifier = @ptrCast(@alignCast(node.meta.per_frame.hooks.slots.anim_state orelse return));
        if (self.closed) return;
        self.frame();
    }

    fn frame(self: *Notifier) void {
        const now = self.cx.frame_time_ms;
        // Only act when clock truly advances: hit-test reentry runs hook with stale clock
        // (measured: close during idle pause, exit timestamped 470ms old, next real frame jumps
        // gap in one step). All timestamps set here.
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
        // Callback may close entire Notifier (dispose scope / close window).
        if (self.closed) return;

        // 1. Measure height: born when first frame gets real height (born = now), entry starts.
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

        // 2. Hover: hit-test bounding rect + 18px pad; frozen during exit.
        var any_leaving = false;
        for (self.cards.items) |card| {
            if (card.leaving) any_leaving = true;
        }
        // Freeze expand state when pointer on badge / clear button: their position follows
        // stack edge, normal test causes expand -> move away -> collapse -> return -> flicker.
        if (!any_leaving and !self.pointerOverControls()) {
            const want = self.hitTestStack() or self.anyDragging();
            if (want != self.hovered) self.setHovered(want, now);
        }
        if (self.hovered and self.count() == 0 and !any_leaving) self.setHovered(false, now);

        // 3. Expiration: dismiss by remaining lifetime. Collect first, then callback:
        // callback may show(), appending to self.cards invalidates active slice.
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

        // 4. Expand progress (540ms, reposition curve).
        const expanding = self.stepExpand(now);

        // 5. Solve stack layout and write nodes.
        self.layoutAndApply(now, any_leaving or expanding);

        // 6. Reclaim exited cards; next frame re-check hover by pointer position.
        var i: usize = 0;
        while (i < self.cards.items.len) {
            const card = self.cards.items[i];
            if (card.leaving and (self.reducedMotion() or card.instant_exit or model.exitMotion(card.exitElapsed(now)).done)) {
                _ = self.cards.orderedRemove(i);
                self.destroyCard(card, true);
                // Removal/release within tick deferred to later traversal: need one more frame,
                // else frame-gating now leaves nodes in tree (measured: after exit, text still
                // findable).
                self.reclaimed_this_frame = true;
                continue;
            }
            i += 1;
        }

        // Frame scheduling: container doesn't render, markRenderDirty alone changes nothing,
        // idle-gating freezes frame (measured: hover-pause then Enter waits for next event).
        // While moving, request next frame; when still, let idle freeze, wake once per 1s.
        if (self.reclaimed_this_frame) {
            self.reclaimed_this_frame = false;
            self.cx.requestRedraw();
            self.container.markRenderDirty();
        }
        if (self.isAnimating(now)) {
            self.cx.requestRedraw();
            // Container under portal root (not in cx.root): before_render gating follows portal's
            // dirty flag, unmarked means hook doesn't run, animation freezes (measured: exit card
            // freezes mid-fade). Container doesn't render, children cached, low overhead.
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
            if (!self.reducedMotion() and now - card.born_ms < Spec.young_ms) return true;
            if (card.follow_y.active) return true;
            if (card.close_alpha > 0.001 and card.close_alpha < 0.999) return true;
            // Spinner always spins; life bar / countdown ring advances per frame while timing.
            if (!self.reducedMotion() and card.content.spinner != null) return true;
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
        // Hit pauses all timing; life bar and ring stop together, resume from stop when moved.
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

    fn reducedMotion(self: *const Notifier) bool {
        return self.cx.reduced_motion or self.cx.renderer_reduced_motion;
    }

    fn stepExpand(self: *Notifier, now: f64) bool {
        if (self.reducedMotion()) {
            self.expand_value = self.expand_to;
            return false;
        }
        if (self.expand_value == self.expand_to) return false;
        const p = model.progressOf(now - self.expand_start_ms, Spec.expand_ms);
        self.expand_value = model.lerp(self.expand_from, self.expand_to, model.reflowEase(p));
        if (p >= 1) self.expand_value = self.expand_to;
        return true;
    }

    fn pointerInWindow(self: *const Notifier) ?struct { x: f32, y: f32 } {
        // A pointer that left the window or sits under another window keeps its last position;
        // that position must not keep the stack hovered (paused and expanded).
        if (!self.cx.pointerLive()) return null;
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

        // Sort measured cards by stack order (newest first).
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
            const exit = if (card.leaving) model.exitMotion(if (self.reducedMotion()) Spec.exit_ms else card.exitElapsed(now)) else null;
            inputs[i] = .{
                .height = card.natural_height,
                .width = if (card.natural_width > 0) card.natural_width else W,
                .weight = if (exit) |x| (if (card.hold_space) 1 else x.weight) else 1,
                .leaving = card.leaving,
            };
        }
        model.solveStack(inputs[0..n], .{ .expand = self.expand_value, .max_visible = self.options.max_visible }, outs[0..n]);

        // Anchor (window coordinates).
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
            const enter = model.enterMotion(if (self.reducedMotion()) Spec.enter_ms else age);
            const exit = if (card.leaving) model.exitMotion(if (self.reducedMotion()) Spec.exit_ms else card.exitElapsed(now)) else null;

            // Near-anchor edge -> card top edge.
            const top: f32 = switch (position.vAnchor()) {
                .top => area_y + inset + o.offset,
                .bottom => area_y + area_h - inset - o.offset - o.clip_height,
                .middle => area_y + (area_h - extent) / 2 + o.offset,
            };
            const young = age < Spec.young_ms;
            const continuous = self.reducedMotion() or continuous_all or young or card.dragging;
            const y = card.follow_y.step(top, now, continuous);

            // Extra offset: entry, exit drift, drag / fling.
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

            // Cross-fade on in-place transform.
            var content_alpha = o.content_alpha;
            if (card.content_pending) {
                content_alpha = 0;
            } else if (card.crossfade_at_ms) |t0| {
                const p = if (self.reducedMotion()) 1 else model.progressOf(now - t0, Spec.crossfade_ms);
                content_alpha *= p;
                if (p >= 1) card.crossfade_at_ms = null;
            }

            // Pill narrower than card: align to card column by anchor (center / left / right).
            // Visible width: collapsed cards narrow to frontmost width, expand back to natural.
            const cw = if (o.clip_width > 0) o.clip_width else W;
            const align_dx: f32 = switch (position.hAlign()) {
                .left => 0,
                .center => (W - cw) / 2,
                .right => W - cw,
            };
            const x_pos = base_x + align_dx + dx;
            const y_pos = y + dy;
            applyCard(card, &pal, .{
                .x = x_pos,
                .y = y_pos,
                .scale_x = o.scale * scale,
                .scale_y = scale,
                .alpha = alpha,
                .content_alpha = content_alpha,
                .clip_height = o.clip_height,
                .clip_width = cw,
                .rank = @intCast(@min(i, 60)),
                .now = now,
                .age = if (self.reducedMotion()) Spec.enter_ms else age,
            });

            // Hit rect: box shrinks around center, record visual bounds.
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

        // Close button states: solid dark cross on pointer hit card, light chips elsewhere (16.7).
        const dt: f32 = @floatCast(@max(0, @min(64, now - self.last_frame_ms)));
        self.last_frame_ms = now;
        for (order[0..n]) |card| {
            // Hint has no close button (swipe still works).
            const want: f32 = if (self.hovered and card.spec.kind != .hint and !card.leaving and card.rect_visible and card.content.root.getOpacity() > 0.5) 1 else 0;
            const step = if (self.reducedMotion()) 1 else dt / @as(f32, @floatCast(Spec.close_fade_ms));
            card.close_alpha = if (want > card.close_alpha) @min(want, card.close_alpha + step) else @max(want, card.close_alpha - step);
            applyClose(card, &pal, card == ptr_card);
        }

        self.applyPill(now, dt, shown, base_x, W, stack_min_y, stack_max_y);
    }

    fn stepSpring(self: *Notifier, card: *Card, now: f64) f32 {
        if (card.dragging) return model.constrainSwipe(self.options.position, card.drag_dx);
        if (self.reducedMotion()) {
            card.spring_at_ms = null;
            card.drag_dx = 0;
            return 0;
        }
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

    fn applyPill(self: *Notifier, now: f64, dt: f32, shown: usize, base_x: f32, W: f32, min_y: f32, max_y: f32) void {
        _ = now;
        const live = self.count();
        const want_paused = self.hovered and live >= 1;
        const want_more = !self.hovered and live >= 2;
        const want: f32 = if ((want_paused or want_more) and shown > 0) 1 else 0;
        const step = if (self.reducedMotion()) 1 else dt / @as(f32, @floatCast(Spec.close_fade_ms));
        self.pill_alpha = if (want > self.pill_alpha) @min(want, self.pill_alpha + step) else @max(want, self.pill_alpha - step);

        // Text follows state (update only on change).
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
        // 'Clear all': appears alongside badge when >= 2 on-screen.
        const want_clear: f32 = if (live >= 2 and shown > 0) 1 else 0;
        self.clear_alpha = if (want_clear > self.clear_alpha) @min(want_clear, self.clear_alpha + step) else @max(want_clear, self.clear_alpha - step);
        const pill_rect = self.pill.rectFromWorldOrFallback();
        const clear_rect = self.clear_btn.rectFromWorldOrFallback();
        if (shown > 0) {
            // Badge and button form group, align to column by anchor: center-dock aligns center,
            // left/right-dock aligns edge (hint narrower and edge-aligned; center leaves badge
            // floating).
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
        // Badge is glass: fade in/out with node opacity, material constant; color follows glass
        // tone.
        animOpacity(self.pill, a);
        setTextColor(self.pill_label, glassInk(self.pill_glass, true));
        setIconTint(self.pill_icon_more, glassInk(self.pill_glass, false));
        setIconTint(self.pill_icon_paused, glassInk(self.pill_glass, false));
        setTextColor(self.clear_label, glassInk(self.clear_glass, true));
        setIconTint(self.clear_icon, glassInk(self.clear_glass, false));
        // Expand/collapse: 200ms, width strong deceleration, text fades in during second half
        // (fades out when collapsing).
        if (self.clear_alpha < 0.5 and self.clear_armed) self.clear_armed = false;
        const reveal_target: f32 = if (self.clear_armed) 1 else 0;
        const rstep = if (self.reducedMotion()) 1 else dt / @as(f32, @floatCast(Spec.clear_reveal_ms));
        // Clamp to target: can't step backward at target (idle wake has large dt,
        // shrunk 1 to 0.68 -> periodic flicker).
        self.clear_reveal_t = if (reveal_target > self.clear_reveal_t) @min(reveal_target, self.clear_reveal_t + rstep) else @max(reveal_target, self.clear_reveal_t - rstep);
        const label_w = self.clear_label.rectFromWorldOrFallback().w + 8; // + margin 5 / 3
        const rw = label_w * model.enterEase(self.clear_reveal_t);
        if (self.clear_reveal.style.width != .px or @abs(self.clear_reveal.style.width.px - rw) > 0.05) {
            self.clear_reveal.style.width = .fixed(rw);
            self.clear_reveal.markSizingDirty();
        }
        animOpacity(self.clear_label, model.clamp01((self.clear_reveal_t - 0.35) / 0.65));
        animOpacity(self.clear_btn, self.clear_alpha);
        self.clear_btn.setHitTestVisible(self.clear_alpha > 0.5);
    }
};

// ============================================================================
// Node write
// ============================================================================

const Frame = struct {
    x: f32,
    y: f32,
    scale_x: f32,
    scale_y: f32,
    /// Card visibility (entry x exit x layer visibility x drag).
    alpha: f32,
    content_alpha: f32,
    clip_height: f32,
    clip_width: f32,
    rank: u8,
    now: f64,
    age: f64,
};

/// Write opacity per frame if changed; invisible-to-visible one-time marks dirty
/// (invalidates cache, else opacity 0 skip looks clean and reuses empty display;
/// measured: new layer after pause doesn't show); others mark on animation frame.
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

    // Card uses real transform scale + node opacity: glass samples world coords in
    // offscreen composite (see render/backdrop_blur.zig offscreenLocalRectToWorld), blur
    // and base constant, fade-out composes whole glass by opacity. No offscreen when
    // alpha==1 and scale==1, zero overhead.
    const p = card.positioner;
    // Only mark dirty if changed: static cards shouldn't regenerate every frame.
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

    // Clip height: collapsed later cards clip to frontmost height (clip GlassBox root,
    // glass clips content by radius). Material constant, no per-layer whitening.
    const s = card.glass_root;
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

    // Content layer (later hidden when collapsed / cross-fade on transform) + staggered.
    const c = &card.content;
    const content_a = model.clamp01(f.content_alpha);
    animOpacity(c.root, content_a);
    c.root.setHitTestVisible(content_a > 0.5);
    applyStagger(card, f.age);

    // Icon bounces in (entry and swap use same curve).
    if (card.icon_pop_at_ms) |t0| icon: {
        const lead = c.lead orelse {
            card.icon_pop_at_ms = null;
            break :icon;
        };
        const dur: f64 = if (t0 == card.born_ms) Spec.enter_ms else Spec.icon_pop_ms;
        const reduced = @import("../../core/render_engine/mod.zig").current_reduced_motion;
        const pop = model.iconPop(if (reduced) dur else f.now - t0, dur);
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
        if (reduced or f.now - t0 >= dur) card.icon_pop_at_ms = null;
    }

    // Life bar / countdown ring / timestamp.
    const frac = card.life.fraction(f.now);
    if (card.spec.life_bar and !card.sticky) {
        animBackground(card.lifebar, pal.lifeBar(card.spec.tone));
        // Shorten with left-origin scale_x: only move composition, no layout/regenerate.
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
        // Countdown redraws only when time advances (static during hover pause).
        if (card.life.frozen_remaining_ms == null) if (c.lead) |l| l.markRenderDirty();
    }
    if (c.spinner) |sp| sp.markRenderDirty();
    updateTimestamp(card);
}

/// When visible width diverges from natural, pin shell to fixed width (surface
/// follows, center content, crop); back to natural restores rules (card full / pill fit).
fn applyClipWidth(card: *Card, clip_w: f32) void {
    const p = card.positioner;
    // Width on glass root; when narrowing, center content in glass.
    const g = card.glass_root;
    const body = card.surface;
    const is_hint = card.spec.kind == .hint;
    const natural = card.natural_width;
    if (natural <= 0) return;
    if (@abs(clip_w - natural) > 0.5) {
        if (p.style.width != .px or @abs(p.style.width.px - clip_w) > 0.25) {
            p.style.width = .fixed(@max(0, clip_w));
            p.markSizingDirty();
        }
        if (is_hint and g.style.width != .grow) {
            g.style.width = .fill();
            body.style.align_items = .center;
            g.markSizingDirty();
            body.markSizingDirty();
        }
    } else if (is_hint) {
        if (p.style.width != .fit or g.style.width != .fit) {
            p.style.width = .{ .fit = .{} };
            g.style.width = .{ .fit = .{} };
            p.markSizingDirty();
            g.markSizingDirty();
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
    const elapsed = @as(i64, @intCast(@divFloor(@import("zenit_time").nanoTimestamp(card.cx.io), std.time.ns_per_ms))) - card.born_wall_ms;
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

/// Badge / clear button share regular glass pill (height pill_height); children in body.
fn pillGlass(press: glass_box.GlassPressFeedback) glass_box.GlassBoxBuilder {
    return glass_box.GlassBox(.{
        .height = M.pill_height,
        .shape = .capsule,
        .corner_radius = M.pill_height / 2,
        .padding = core.Padding.all(0),
        .body_gap = 0,
        .press_feedback = press,
    });
}

/// Pill root absolute positioned, z 200; body row-center fills pill (padding on body).
fn placePillGlass(cx: *Cx, g: glass_box.GlassBoxMount) !void {
    g.box.style.position = .absolute;
    const e = try g.box.style.ensureExtFallible(cx.allocator);
    e.inset = .{ .left = .{ .px = 0 }, .top = .{ .px = 0 } };
    e.z_index = 200;
    g.body.style.direction = .row;
    g.body.style.align_items = .center;
}

/// Text/icon on glass follow tone (like GlassToolbar test: light family black 85%,
/// icon 70%; dark family white 90%).
fn glassInk(state: *const glass_box.AdaptiveGlassBoxState, text: bool) Color {
    return glass_box.familyInk(state, Color.rgba(0, 0, 0, if (text) 217 else 179), Color.rgba(255, 255, 255, 230));
}

fn setTextColor(node: *Node, color: Color) void {
    var t = node.getText() orelse return;
    if (Color.eql(t.color, color)) return;
    t.color = color;
    node.setText(t);
    node.markRenderDirty();
}

fn setIconTint(node: *Node, color: Color) void {
    if (node.setTint(color)) node.markRenderDirty();
}

// ============================================================================
// Tests
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
        const ctx = try Cx.init(testing.allocator, std.testing.io);
        errdefer ctx.deinit();
        ctx.setViewport(1200, 800);
        const root = try box(ctx, .{ .width = .fixed(1200), .height = .fixed(800) }, .{});
        ctx.root = root;
        const scope = try Scope.init(testing.allocator, null, ctx.owner);
        // Init on 'previous frame': real app's first real frame always after init clock.
        ctx.frame_time_ms = -16;
        // Tests place the pointer by writing mouse_x/mouse_y: start from a live pointer over the
        // content, as after a platform pointer move.
        ctx.cursor_state.pointer_valid = true;
        ctx.hover_sync.pointer_over_content = true;
        const n = try Notifier.init(scope, ctx, .{ .position = position });
        if (!n.portaled) try root.appendChild(testing.allocator, n.container);
        return .{ .ctx = ctx, .scope = scope, .root = root, .n = n };
    }

    fn deinit(self: *TestRig) void {
        self.scope.dispose();
        self.ctx.deinit();
    }

    /// Advance frame clock and run one frame (layout -> before_render).
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
    // Entry complete: card bottom edge = 800 - 22.
    try testing.expectApproxEqAbs(@as(f32, 800 - 22), c.rect_y + c.rect_h, 0.5);
    try testing.expectApproxEqAbs(@as(f32, (1200 - 392) / 2), c.rect_x, 0.5);
    try testing.expectApproxEqAbs(@as(f32, 1), c.draw_alpha, 1e-3);
}

test "Notifier: 窗口变矮时堆叠刚性跟随锚点，同一帧到位（不补间拖尾）" {
    // Regression: viewport change mistaken for reposition jump by follow_y, starting
    // 540ms tween. Normal resize lags; live resize after drag-stop, AppKit stops frames,
    // stack freezes mid-way (falls off bottom).
    var rig = try TestRig.init(.bottom_center);
    defer rig.deinit();
    const id = try rig.n.show(.{ .tone = .success, .title = "Saved", .sticky = true });
    rig.step(1000);
    rig.step(2000); // Entry and young period both complete.
    const c = rig.card(id);
    try testing.expectApproxEqAbs(@as(f32, 800 - 22), c.rect_y + c.rect_h, 0.5);

    rig.root.style.height = .fixed(600);
    rig.ctx.setViewport(1200, 600);
    rig.root.markLayoutDirty();
    rig.step(2016);
    try testing.expectApproxEqAbs(@as(f32, 600 - 22), c.rect_y + c.rect_h, 0.5);
    try testing.expect(!c.follow_y.active);

    // Switch anchor still tweens (not consumed as viewport shift).
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
    // Later card visual top 9px higher than previous (collapsed peek).
    try testing.expectApproxEqAbs(@as(f32, 9), cc.rect_y - cb.rect_y, 0.6);
    try testing.expectApproxEqAbs(@as(f32, 9), cb.rect_y - ca.rect_y, 0.6);
    // Z-order reverse to stack order.
    try testing.expect(cc.positioner.style.ext.?.z_index > ca.positioner.style.ext.?.z_index);
    // Later content hidden when collapsed.
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
    // Delete middle card after hover-expanded.
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
        // Monotonic, continuous repositioning (top anchor moves up).
        try testing.expect(y <= prev + 0.01);
        try testing.expect(prev - y < 20);
        prev = y;
    }
    rig.step(3100);
    try testing.expect(rig.n.cardForId(b) == null);
    try testing.expect(rig.card(a).positioner == a_node);
    try testing.expectApproxEqAbs(c_before, rig.card(c).rect_y, 0.5);
    // No entry replay: born unchanged.
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
    // Pointer in 18px pad still counts as hit.
    rig.ctx.mouse_y = c.rect_y - 10;
    rig.step(9100);
    try testing.expect(rig.n.hovered);
    rig.ctx.mouse_x = 5;
    rig.ctx.mouse_y = 5;
    rig.step(9200);
    try testing.expect(!rig.n.paused);
    try testing.expectApproxEqAbs(frozen, c.life.remaining(9200), 1e-6);
}

test "Notifier: a pointer that leaves the window (or is covered) stops hovering at its last position" {
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
    // Platform pointer_left (or a window covering the pointer): the position is unchanged but
    // no longer describes the pointer, so the stack resumes like a native mouseExited.
    rig.ctx.handlePointerLeave();
    rig.step(1200);
    try testing.expect(!rig.n.hovered and !rig.n.paused);
    // The next pointer event at the same point hovers again.
    rig.ctx.handleMouseMove(c.rect_x + 20, c.rect_y + 20);
    rig.step(1300);
    try testing.expect(rig.n.hovered and rig.n.paused);
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
    // Exceeds on-screen limit: oldest exits normally (not instant).
    try testing.expectEqual(@as(usize, 6), rig.n.count());
    try testing.expect(rig.card(ids[0]).leaving);
    rig.step(1600);
    try testing.expect(rig.n.cardForId(ids[0]) != null);

    // Same id show again = in-place: positioner and born unchanged.
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
    // New lifetime starts when new content layer measures height.
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
    // Newest pill in front (at anchor), cards collapsed behind.
    const c = rig.card(card_id);
    try testing.expect(h.rank < c.rank);
    const card_center = c.rect_x + c.rect_w / 2;
    try testing.expectApproxEqAbs(card_center, h.rect_x + h.rect_w / 2, 0.5);
    // Pill has no life bar, no close button.
    try testing.expectEqual(@as(f32, 0), rig.card(hint_id).lifebar.style.height.px);
    rig.ctx.mouse_x = h.rect_x + h.rect_w / 2;
    rig.ctx.mouse_y = h.rect_y + h.rect_h / 2;
    var t: f64 = 1016;
    while (t < 1600) : (t += 16) rig.step(t);
    try testing.expect(rig.n.hovered);
    // Close button appears on card hover, not on pill.
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
    // Already exiting: Cmd+Z goes to host's own undo stack.
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
    // Collapsed: later card visible width = frontmost (right-dock aligns edges, no left).
    try testing.expectApproxEqAbs(front.natural_width, back.positioner.style.width.px, 0.5);
    // Compare layout bounds before scaling (later cards scale separately, center origin).
    const front_right = front.positioner.style.translate_x + front.natural_width;
    const back_right = back.positioner.style.translate_x + back.positioner.style.width.px;
    try testing.expectApproxEqAbs(front_right, back_right, 0.5);
    // Expanded: midway between both, end restores natural width (rules back to fit).
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
    // In-place transform once: old content layer (buttons scope) must free.
    try rig.n.update(id, .{ .kind = .progress, .title = "Retrying" });
    rig.step(200);
    rig.deinit(); // scope.dispose() -> child scopes before resource callbacks; testing allocator checks.
}

test "Notifier: teardown with container first (window closing) is also clean" {
    const ctx = try Cx.init(testing.allocator, std.testing.io);
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
    // Container destroyed first (portal with window): on_cleanup after children freed.
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
    // Drag opacity = max(0.25, 1 - |dx| / 190).
    try testing.expectApproxEqAbs(1 - 40.0 / 190.0, c.draw_alpha, 1e-3);
    Notifier.dragCallback(fakeDrag(.end, 40), @ptrCast(c));
    rig.step(900); // Release outside frame: bounce start timestamped next real frame.
    rig.step(1500);
    try testing.expect(!c.leaving);
    try testing.expectApproxEqAbs(x0, c.rect_x, 0.5);

    Notifier.dragCallback(fakeDrag(.start, 10), @ptrCast(c));
    Notifier.dragCallback(fakeDrag(.end, -120), @ptrCast(c));
    try testing.expect(c.leaving and c.closed_by_user);
    try testing.expectEqual(@as(usize, 1), Sink.dismissed);
    rig.step(1600);
    rig.step(1600 + Spec.exit_ms / 2);
    try testing.expect(c.rect_x < x0 - 120); // Fling along direction (1 + 1.1p).
    rig.step(1600 + Spec.exit_ms);
    try testing.expect(rig.n.cardForId(id) == null);
}

test "Notifier: right-anchored stack only flings rightward; trackpad swipe releases on ended" {
    var rig = try TestRig.init(.bottom_right);
    defer rig.deinit();
    const id = try rig.n.show(.{ .title = "Edge", .sticky = true });
    rig.step(0);
    rig.step(800);
    const c = rig.card(id);
    Notifier.dragCallback(fakeDrag(.start, -10), @ptrCast(c));
    Notifier.dragCallback(fakeDrag(.end, -150), @ptrCast(c));
    try testing.expect(!c.leaving);
    // Reverse drag damped 0.2x: bounce from display -30, not jump to -150.
    try testing.expectApproxEqAbs(@as(f32, -30), c.spring_from, 1e-4);
    rig.step(900);
    rig.step(1500);

    // Two-finger swipe: accumulate dx; never auto-release, only ended matters.
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        _ = Notifier.scrollHandler(.{ .dx = 20, .dy = 0, .x = 0, .y = 0, .phase = .changed, .modifiers = .{} }, @ptrCast(c));
    }
    try testing.expect(c.scroll_dragging);
    rig.step(1520);
    rig.step(4000);
    try testing.expect(c.scroll_dragging and !c.leaving);
    _ = Notifier.scrollHandler(.{ .dx = 0, .dy = 0, .x = 0, .y = 0, .phase = .ended, .modifiers = .{} }, @ptrCast(c));
    try testing.expect(c.leaving);
}

test "Notifier: a cancelled trackpad swipe springs back instead of dismissing" {
    var rig = try TestRig.init(.bottom_center);
    defer rig.deinit();
    const id = try rig.n.show(.{ .title = "Swipe", .sticky = true });
    rig.step(0);
    rig.step(800);
    const c = rig.card(id);
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        _ = Notifier.scrollHandler(.{ .dx = 20, .dy = 0, .x = 0, .y = 0, .phase = .changed, .modifiers = .{} }, @ptrCast(c));
    }
    // 120 > 84, would close if ended.
    _ = Notifier.scrollHandler(.{ .dx = 0, .dy = 0, .x = 0, .y = 0, .phase = .cancelled, .modifiers = .{} }, @ptrCast(c));
    try testing.expect(!c.leaving);
    try testing.expect(!c.scroll_dragging and !c.dragging);
}

test "Notifier: mouse wheel does not drive the swipe" {
    var rig = try TestRig.init(.bottom_center);
    defer rig.deinit();
    const id = try rig.n.show(.{ .title = "Wheel", .sticky = true });
    rig.step(0);
    rig.step(800);
    const c = rig.card(id);
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        try testing.expectEqual(core.EventResult.ignored, Notifier.scrollHandler(.{ .dx = 30, .dy = 0, .x = 0, .y = 0, .modifiers = .{} }, @ptrCast(c)));
    }
    try testing.expect(!c.scroll_dragging);
    try testing.expectEqual(@as(f32, 0), c.drag_dx);
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
    const send = c.content.send_button.?;
    const label_node = findReviewSendText(send).?;
    try testing.expectEqual(rig.ctx.tokens.tokens.color.button_primary_fg, paintedTextColor(label_node));
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
    // Trackpad ended arriving later can't release mouse-holding user.
    _ = Notifier.scrollHandler(.{ .dx = 0, .dy = 0, .x = 0, .y = 0, .phase = .ended, .modifiers = .{} }, @ptrCast(c));
    rig.step(820);
    try testing.expect(c.dragging and !c.leaving);
    Notifier.dragCallback(fakeDrag(.end, 10), @ptrCast(c));
    try testing.expect(!c.leaving); // 70 < 84: bounce.
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
    // Only one card: no clear all.
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
    // Alongside badge: right of badge.
    try testing.expect(rig.n.clear_btn.style.translate_x > rig.n.pill.style.translate_x);

    const click: Event_ = .{ .click = .{ .x = 0, .y = 0 } };
    // First tap: expand and confirm (width grows per frame, no jump), no clear.
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
    // Move away: collapse.
    _ = Notifier.clearAllEvent(.mouse_leave, @ptrCast(rig.n));
    for (0..10) |_| {
        t += 32;
        rig.step(t);
    }
    try testing.expectApproxEqAbs(w0, rig.n.clear_btn.rectFromWorldOrFallback().w, 0.5);
    // Expand again, second tap clear: card fades in place, no reposition.
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
    // Measured flicker: after expand, idle pauses, wakes once per 1s to refresh;
    // large dt, progress toward target still steps back (1->0.68), text fades, re-centers.
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
    // Real flow: hover on card to expand, then move to button (higher after expand).
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
        // Hover on button: stack doesn't collapse, button doesn't escape pointer.
        try testing.expect(rig.n.hovered);
        try testing.expectApproxEqAbs(y0, b.style.translate_y, 0.5);
    }
}

// -- Per-allocation OOM sweep --
// init has one fallible portal.appendChild after registerResource; both errdefer
// freeNode and scope cleanup apply on failure. Each injection one GPA: leaks seen as
// deinit()==.leak, double-free caught by checks (log.err in test fails).

/// Full sweep sequence: init -> two notifications (text + buttons) -> same-id transform.
fn oomSweepUse(scope: *Scope, ctx: *Cx) !void {
    const n = try Notifier.init(scope, ctx, .{ .position = .bottom_right });
    _ = try n.show(.{ .tone = .success, .title = "Saved", .body = "3 files synced" });
    const id = try n.show(.{ .tone = .violet, .title = "Invite", .actions = &.{ .{ .label = "Accept", .primary = true }, .{ .label = "Ignore" } } });
    _ = try n.show(.{ .id = id, .tone = .@"error", .title = "Declined", .body = "Invite expired" });
}

const OomSweepResult = struct { total: usize, induced: usize, leaked: usize, first_leak: ?usize };

fn oomSweepCase(gpa_alloc: Allocator, failure_index: ?usize, total_out: ?*usize) !bool {
    var failing = testing.FailingAllocator.init(gpa_alloc, .{});
    const ctx = try Cx.init(failing.allocator(), std.testing.io);
    defer ctx.deinit();
    ctx.setViewport(800, 600);
    ctx.root = try box(ctx, .{ .width = .fixed(800), .height = .fixed(600) }, .{});
    // Warmup: World table / style table etc. amortized realloc, allocates more after
    // first run; without, injection index drifts with k, skipping later points.
    {
        _ = try ctx.ensurePopoverPortalRoot();
        const warm = try Scope.init(failing.allocator(), null, ctx.owner);
        try oomSweepUse(warm, ctx);
        warm.dispose();
    }
    // Switch fresh portal: children capacity resets, portal.appendChild at init end
    // really needs allocation (else warmup capacity prevents failure).
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
        var gpa = std.heap.DebugAllocator(.{ .safety = true }){};
        _ = try oomSweepCase(gpa.allocator(), null, &total);
        try testing.expect(gpa.deinit() == .ok);
    }
    var res: OomSweepResult = .{ .total = total, .induced = 0, .leaked = 0, .first_leak = null };
    for (0..total) |k| {
        var gpa = std.heap.DebugAllocator(.{ .safety = true }){};
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
    // Guard by ratio (same caliber as components/oom_sweep.zig).
    if (res.induced < res.total / 2 or res.leaked != 0) {
        std.debug.print("\n[notifier oom sweep] total={d} induced={d} leaked={d} first_leak={?d}\n", .{ res.total, res.induced, res.leaked, res.first_leak });
    }
    try testing.expect(res.induced >= res.total / 2);
    try testing.expectEqual(@as(usize, 0), res.leaked);
}

test "Notifier: reduced motion preserves lifetime and immediately reclaims dismissed cards" {
    var rig = try TestRig.init(.bottom_center);
    defer rig.deinit();
    rig.ctx.renderer_reduced_motion = true;
    const id = try rig.n.show(.{ .tone = .success, .title = "Still readable", .duration_ms = 3000 });
    rig.step(1000);
    const card = rig.card(id);
    try testing.expect(card.measured);
    try testing.expectEqual(@as(f32, 1), card.draw_alpha);
    rig.step(1100);
    try testing.expectEqual(@as(usize, 1), rig.n.count());
    rig.n.dismiss(id);
    rig.step(1101);
    try testing.expect(rig.n.cardForId(id) == null);
}

fn findReviewSendText(node: *Node) ?*Node {
    if (node.getText()) |txt| {
        if (std.mem.eql(u8, txt.content, "Send")) return node;
    }
    for (node.children.items) |child| {
        if (findReviewSendText(child)) |found| return found;
    }
    return null;
}

/// Text color as painted: the Send label inherits the button's foreground (ControlShell tone).
fn paintedTextColor(n: *Node) Color {
    return @import("../../core/render_engine/text_render.zig").resolveNodeLogicalTextProps(n).?.color;
}

test "Notifier: the reply field keeps its frame through focus, hover and theme changes (acceptance)" {
    // The reply field is an embedded Input whose shell carries declarative style layers (size
    // recipe, field tone, the Input frame overlay). Its height, border width and padding must
    // survive every recompute of those layers, not only the first mount.
    var rig = try TestRig.init(.bottom_center);
    defer rig.deinit();
    const id = try rig.n.show(.{ .title = "Reply", .body = "Message", .reply = true });
    rig.step(0);
    rig.step(700);
    const field = rig.card(id).content.reply_input.?;
    const expectFrame = struct {
        fn check(n: *Node) !void {
            try testing.expectEqual(core.Sizing{ .px = M.reply_height - 2 }, n.style.height);
            try testing.expectEqual(@as(f32, 0), n.style.border.width);
            try testing.expectEqual(@as(f32, 0), n.style.padding.top);
            try testing.expectEqual(@as(f32, 0), n.style.padding.left);
            try testing.expectEqual(@as(f32, 0), n.style.padding.right);
            try testing.expectEqual(@as(f32, 0), n.style.padding.bottom);
        }
    }.check;
    try expectFrame(field);
    rig.ctx.setFocus(field);
    rig.step(720);
    try expectFrame(field);
    if (field.behavior.events.on_hover) |h| h.invoke();
    rig.step(740);
    try expectFrame(field);
    if (field.behavior.events.on_leave) |h| h.invoke();
    rig.ctx.clearFocus();
    for ([_]*const core.ThemeTokens{ &core.theme.dark, &core.theme.high_contrast, &core.theme.light }) |t| {
        rig.ctx.setTheme(t);
        rig.step(760);
        try expectFrame(field);
    }
}

test "review regression 2: reply Send uses primary foreground in all themes" {
    for ([_]*const core.ThemeTokens{ &core.theme.light, &core.theme.dark, &core.theme.high_contrast }) |t| {
        var rig = try TestRig.init(.bottom_center);
        defer rig.deinit();
        rig.ctx.setTheme(t);
        const id = try rig.n.show(.{ .title = "Reply", .body = "Message", .reply = true });
        rig.step(0);
        const send = rig.card(id).content.send_button.?;
        try testing.expectEqual(t.tokens.color.button_primary_fg, paintedTextColor(findReviewSendText(send).?));
    }
}

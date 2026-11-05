//! LP0 host integration. This entire module is unreachable when enabled=false.
const std = @import("std");
const ui = @import("ui");
const env = @import("zenit_environment");
const transport = @import("session.zig");
pub const snapshot = @import("snapshot.zig");
pub const enabled = @import("build_options").dev_preview;
const A = std.mem.Allocator;
const allocator = std.heap.page_allocator;
/// A restored scroll offset that the first layout could not reach yet (content
/// extent still growing). Retried on later layouts until met, superseded by a
/// different offset (the user or app scrolled), or `scroll_retry_limit` layouts.
const PendingScroll = struct { key: []const u8, x: f32, y: f32, last_x: f32, last_y: f32 };
const max_pending_scrolls = 8;
const scroll_retry_limit = 120;
const Host = struct {
    ptr: *anyopaque,
    key: []const u8,
    capture: *const fn (*anyopaque, A, []const u8) anyerror!snapshot.Window,
    restore_frame: *const fn (*anyopaque, snapshot.Window) void,
    context: *const fn (*anyopaque) *ui.Cx,
    quit: *const fn (*anyopaque) void,
    overlay: ?*ui.Node = null,
    overlay_id: u32 = 0,
    overlay_generation: u32 = 0,
    layout_ready: bool = false,
    pending_scroll: [max_pending_scrolls]PendingScroll = undefined,
    pending_scroll_len: u8 = 0,
    scroll_retry_layouts: u16 = 0,
    submitted_generation: u64 = 0,
    submitted_frame: u64 = 0,
    template_submitted_generation: u64 = 0,
    template_submitted_frame: u64 = 0,
    template_after_submit_ns: i96 = 0,
    template_layout_us: u64 = 0,
    template_encode_submit_us: u64 = 0,
    after_submit_ns: i96 = 0,
    layout_us: u64 = 0,
    encode_submit_us: u64 = 0,
};
const State = struct {
    session: transport.Session,
    registry: snapshot.Registry,
    restored: ?std.json.Parsed(snapshot.Snapshot) = null,
    hosts: std.ArrayList(Host) = .empty,
    next_window: u64 = 0,
    ever_attached: bool = false,
    mutation_epoch: u64 = 0,
    dirty: bool = true,
    draining: bool = false,
    callback_depth: u32 = 0,
    last_write: i96 = 0,
    ready: bool = false,
};
var state: ?*State = null;
/// Public for custom-loop hosts. No rendering/readback/surface API is imported here.
pub fn active() bool {
    return enabled and state != null;
}
pub fn markDirty() void {
    if (enabled) if (state) |s| {
        s.dirty = true;
        s.mutation_epoch +%= 1;
    };
}
pub fn persist(key: []const u8, version: u32, ctx: *anyopaque, encode: snapshot.Registry.Encode, decode: snapshot.Registry.Decode) !void {
    if (!enabled) return;
    const s = state orelse return;
    const had_hosts = s.hosts.items.len > 0;
    s.callback_depth += 1;
    defer {
        s.callback_depth -= 1;
        if (s.callback_depth == 0 and !s.draining and s.ever_attached and s.hosts.items.len == 0) destroyState(s);
    }
    try s.registry.persist(key, version, ctx, encode, decode, if (s.restored) |r| r.value.application else &.{});
    if (had_hosts and s.hosts.items.len == 0) return error.RestoreHostClosed;
    markDirty();
}
pub fn unpersist(key: []const u8) !void {
    if (!enabled) return;
    if (state) |s| {
        try s.registry.remove(key);
        markDirty();
    }
}
/// Optional application-model phase, before creating native windows. The runtime
/// also calls this lazily. A launcher supplies the same environment in both cases.
pub fn prepare(io: std.Io) !void {
    if (!enabled) return;
    _ = try ensure(io);
}
/// Cancel preparation if no native window was created. Normal App teardown owns
/// shutdown once windows exist; this never frees a live window's session.
pub fn cancelPreparation() !void {
    if (!enabled) return;
    const s = state orelse return;
    if (s.hosts.items.len != 0 or s.draining or s.callback_depth != 0) return error.SessionBusy;
    destroyState(s);
}
fn ensure(io: std.Io) !?*State {
    if (state) |s| {
        ui.style_reload.observer = observeStyleGeneration;
        return s;
    }
    const root = env.getOwned(allocator, "ZENIT_DEV_SESSION_DIR") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return null,
        else => return err,
    };
    defer allocator.free(root);
    const fail_start = env.getOwned(allocator, "ZENIT_DEV_FAIL_START") catch null;
    defer if (fail_start) |value| allocator.free(value);
    if (fail_start) |value| if (std.mem.eql(u8, value, "1")) return error.DevPreviewInjectedStartFailure;
    const revision = try env.getOwned(allocator, "ZENIT_DEV_REVISION");
    defer allocator.free(revision);
    const generation = try env.getOwned(allocator, "ZENIT_DEV_GENERATION");
    defer allocator.free(generation);
    const s = try allocator.create(State);
    errdefer allocator.destroy(s);
    s.* = .{ .session = try transport.Session.init(allocator, io, root, revision, generation), .registry = .{ .allocator = allocator } };
    errdefer s.session.deinit();
    const restore_path = env.getOwned(allocator, "ZENIT_DEV_RESTORE") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    defer if (restore_path) |p| allocator.free(p);
    if (restore_path) |path| {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(snapshot.max_bytes));
        defer allocator.free(bytes);
        s.restored = try snapshot.decode(allocator, bytes);
    }
    errdefer if (s.restored) |r| r.deinit();
    try s.session.start();
    state = s;
    ui.style_reload.observer = observeStyleGeneration;
    return s;
}
/// Called only after native App initialization succeeds, before application mount.
pub fn attach(app: anytype) !void {
    if (!enabled) return;
    const T = @TypeOf(app.*);
    const Adapter = struct {
        fn cx(raw: *anyopaque) *ui.Cx {
            const p: *T = @ptrCast(@alignCast(raw));
            return p.cx;
        }
        fn quit(raw: *anyopaque) void {
            const p: *T = @ptrCast(@alignCast(raw));
            p.should_quit = true;
        }
        fn capture(raw: *anyopaque, a: A, key: []const u8) !snapshot.Window {
            const p: *T = @ptrCast(@alignCast(raw));
            var w: snapshot.Window = .{ .key = try a.dupe(u8, key) };
            if (@hasDecl(@TypeOf(p.win), "previewGeometry")) {
                if (p.win.previewGeometry(0)) |g| {
                    w.frame = .{ .x = g[0], .y = g[1], .w = g[2], .h = g[3] };
                    w.screen = try std.fmt.allocPrint(a, "{d:.0}", .{g[8]});
                }
            } else {
                const size = p.win.getSize();
                w.frame.w = @floatFromInt(size[0]);
                w.frame.h = @floatFromInt(size[1]);
            }
            var scroll: std.ArrayList(snapshot.Scroll) = .empty;
            if (p.cx.root) |root| try captureScroll(root, a, &scroll);
            w.scroll = scroll.items;
            if (p.cx.focused_node) |node| if (node.meta.ownership.meta.test_id) |id| {
                w.focus = try a.dupe(u8, id);
            };
            if (@hasDecl(@TypeOf(p.win), "isFocused")) w.active = p.win.isFocused();
            return w;
        }
        fn restore(raw: *anyopaque, w: snapshot.Window) void {
            const p: *T = @ptrCast(@alignCast(raw));
            if (@hasDecl(@TypeOf(p.win), "previewGeometry")) {
                const screen = std.fmt.parseInt(u64, w.screen, 10) catch 0;
                if (p.win.previewGeometry(screen)) |g| {
                    const f = snapshot.clampFrame(w.frame, .{ .x = g[4], .y = g[5], .w = g[6], .h = g[7] });
                    p.win.restorePreviewFrame(.{ f.x, f.y, f.w, f.h });
                }
            }
        }
    };
    const s = (try ensure(app.config.io)) orelse return;
    errdefer if (s.hosts.items.len == 0 and !s.draining and s.callback_depth == 0) destroyState(s);
    if (ui.theme_reload.latestMode(app.cx.tokens.name)) |tokens| app.cx.tokens = tokens;
    app.cx.style_generation = ui.style_reload.generation;
    if (app.cx.theme_signal) |sig| sig.value = app.cx.tokens;
    if (app.cx.style_signal) |sig| sig.value = app.cx.style_generation;

    const key = if (app.config.window.persist_key) |k| try allocator.dupe(u8, k) else try std.fmt.allocPrint(allocator, "window-{d}", .{s.next_window});
    errdefer allocator.free(key);
    if (key.len == 0) return error.EmptyWindowKey;
    for (s.hosts.items) |h| if (std.mem.eql(u8, h.key, key)) return error.DuplicateWindowKey;
    try s.hosts.append(allocator, .{ .ptr = app, .key = key, .capture = Adapter.capture, .restore_frame = Adapter.restore, .context = Adapter.cx, .quit = Adapter.quit });
    s.next_window += 1;
    s.ever_attached = true;
    if (s.restored) |r| for (r.value.windows) |w| if (std.mem.eql(u8, w.key, key)) {
        Adapter.restore(app, w);
        break;
    };
    markDirty();
}
pub fn beginTeardown() void {
    if (enabled) if (state) |s| {
        s.callback_depth += 1;
    };
}
pub fn endTeardown() void {
    if (!enabled) return;
    const s = state orelse return;
    std.debug.assert(s.callback_depth > 0);
    s.callback_depth -= 1;
    if (s.callback_depth == 0 and !s.draining and s.ever_attached and s.hosts.items.len == 0) destroyState(s);
}
/// Detach before on_destroy/scope cleanup can release any captured context.
pub fn detach(app: anytype) void {
    if (!enabled) return;
    const s = state orelse return;
    for (s.hosts.items, 0..) |h, i| if (h.ptr == @as(*anyopaque, app)) {
        clearOverlay(h);
        const cx = h.context(h.ptr);
        if (ui.theme_reload.owns(cx.tokens)) {
            cx.tokens = ui.theme_reload.compiledMode(cx.tokens.name);
            // Session versions can be reclaimed before this Cx's scope cleanup runs.
            // Invalidate only session-owned pointers; application custom tokens
            // retain their original identity through on_destroy and scope cleanup.
            if (cx.theme_signal) |signal| signal.value = cx.tokens;
        }
        allocator.free(h.key);
        _ = s.hosts.orderedRemove(i);
        break;
    };
    if (s.hosts.items.len == 0 and !s.draining and s.callback_depth == 0) destroyState(s) else markDirty();
}
fn destroyState(s: *State) void {
    state = null;
    if (enabled) {
        ui.template_reload.deinit();
        ui.style_reload.deinit();
        ui.theme_reload.deinit();
    }
    s.session.deinit();
    s.registry.deinit();
    if (s.restored) |r| r.deinit();
    s.hosts.deinit(allocator);
    allocator.destroy(s);
}
fn captureScroll(node: *ui.Node, a: A, list: *std.ArrayList(snapshot.Scroll)) !void {
    if (ui.widgets.scroll_area.persistView(node)) |view| if (view.key) |key| {
        if (!view.anchor_required) try list.append(a, .{ .key = try a.dupe(u8, key), .x = view.x, .y = view.y });
    };
    for (node.children.items) |child| try captureScroll(child, a, list);
}
fn scrollMet(a: f32, b: f32) bool {
    return @abs(a - b) < 0.5;
}
fn restoreScroll(host: *Host, node: *ui.Node, saved: []const snapshot.Scroll) void {
    if (ui.widgets.scroll_area.persistView(node)) |view| if (view.key) |key| {
        for (saved) |v| if (std.mem.eql(u8, key, v.key)) {
            // Virtual-list item anchors are reserved; never treat them as raw offsets.
            if (v.item_key == null and !view.anchor_required) {
                ui.widgets.scroll_area.restorePersistOffset(node, v.x, v.y);
                // The first layout may not have the final content extent yet, so the
                // offset can be clamped short. Keep the target and retry later.
                if (ui.widgets.scroll_area.persistView(node)) |after| {
                    if ((!scrollMet(after.x, v.x) or !scrollMet(after.y, v.y)) and host.pending_scroll_len < max_pending_scrolls) {
                        host.pending_scroll[host.pending_scroll_len] = .{ .key = v.key, .x = v.x, .y = v.y, .last_x = after.x, .last_y = after.y };
                        host.pending_scroll_len += 1;
                        host.scroll_retry_layouts = 0;
                    }
                }
            }
            break;
        };
    };
    for (node.children.items) |child| restoreScroll(host, child, saved);
}
fn retryPendingScroll(host: *Host, node: *ui.Node) void {
    if (host.pending_scroll_len == 0) return;
    if (ui.widgets.scroll_area.persistView(node)) |view| if (view.key) |key| {
        var i: usize = 0;
        while (i < host.pending_scroll_len) : (i += 1) {
            const p = &host.pending_scroll[i];
            if (!std.mem.eql(u8, key, p.key)) continue;
            var done = false;
            if (!scrollMet(view.x, p.last_x) or !scrollMet(view.y, p.last_y)) {
                // Someone else moved it since our last attempt; their offset wins.
                done = true;
            } else {
                ui.widgets.scroll_area.restorePersistOffset(node, p.x, p.y);
                const after = ui.widgets.scroll_area.persistView(node) orelse view;
                p.last_x = after.x;
                p.last_y = after.y;
                done = scrollMet(after.x, p.x) and scrollMet(after.y, p.y);
            }
            if (done) {
                host.pending_scroll[i] = host.pending_scroll[host.pending_scroll_len - 1];
                host.pending_scroll_len -= 1;
            }
            break;
        }
    };
    for (node.children.items) |child| retryPendingScroll(host, child);
}
// Resolve first, mutate once: duplicate keys and anchor-managed containers fail.
fn findScroll(node: *ui.Node, key: []const u8, found: *?*ui.Node) !void {
    if (ui.widgets.scroll_area.persistView(node)) |view| if (view.key) |id| {
        if (std.mem.eql(u8, key, id)) {
            if (view.anchor_required) return error.ScrollAnchorRequired;
            if (found.* != null) return error.AmbiguousScrollKey;
            found.* = node;
        }
    };
    for (node.children.items) |child| try findScroll(child, key, found);
}
fn setScroll(s: *State, a: A, text: []const u8) !void {
    const parsed = try std.json.parseFromSlice(struct { key: []const u8, x: f32, y: f32 }, a, text, .{});
    defer parsed.deinit();
    const value = parsed.value;
    if (value.key.len == 0 or !std.math.isFinite(value.x) or !std.math.isFinite(value.y)) return error.InvalidScroll;
    var found: ?*ui.Node = null;
    for (s.hosts.items) |h| if (h.context(h.ptr).root) |root| try findScroll(root, value.key, &found);
    const node = found orelse return error.UnknownScrollKey;
    ui.widgets.scroll_area.restorePersistOffset(node, value.x, value.y);
    markDirty();
}
fn windowHost(s: *State, key: []const u8) !Host {
    for (s.hosts.items) |h| if (std.mem.eql(u8, h.key, key)) return h;
    return error.UnknownWindowKey;
}
fn setFrame(s: *State, a: A, text: []const u8) !void {
    const parsed = try std.json.parseFromSlice(struct { key: []const u8, frame: snapshot.Frame }, a, text, .{});
    defer parsed.deinit();
    const value = parsed.value;
    const f = value.frame;
    if (!std.math.isFinite(f.x) or !std.math.isFinite(f.y) or !std.math.isFinite(f.w) or !std.math.isFinite(f.h) or f.w <= 0 or f.h <= 0) return error.InvalidFrame;
    const h = try windowHost(s, value.key);
    h.restore_frame(h.ptr, .{ .key = value.key, .frame = f });
    markDirty();
}
fn setFocus(s: *State, a: A, text: []const u8) !void {
    const parsed = try std.json.parseFromSlice(struct { key: []const u8, id: []const u8 }, a, text, .{});
    defer parsed.deinit();
    const h = try windowHost(s, parsed.value.key);
    const cx = h.context(h.ptr);
    const root = cx.root orelse return error.UnknownFocusId;
    const node = findFocus(cx, root, parsed.value.id, cx.viewport.width, cx.viewport.height) orelse return error.UnknownFocusId;
    cx.setFocus(node);
    markDirty();
}
fn focusVisible(cx: *ui.Cx, node: *ui.Node, width: f32, height: f32) bool {
    const local = node.rectFromWorldOrFallback();
    const bounds = node.worldTransform().transformRect(.{ .x = 0, .y = 0, .w = local.w, .h = local.h });
    var left = @max(@as(f32, 0), bounds.x);
    var top = @max(@as(f32, 0), bounds.y);
    var right = @min(width, bounds.x + bounds.w);
    var bottom = @min(height, bounds.y + bounds.h);
    var ancestor: ?*ui.Node = node;
    while (ancestor) |current| : (ancestor = current.parent) {
        if (current != node and current.style.overflow_hidden) {
            const r = current.rectFromWorldOrFallback();
            const clip = current.worldTransform().transformRect(.{ .x = 0, .y = 0, .w = r.w, .h = r.h });
            left = @max(left, clip.x);
            top = @max(top, clip.y);
            right = @min(right, clip.x + clip.w);
            bottom = @min(bottom, clip.y + clip.h);
        }
        if (cx.external_clip_rects.get(current.id)) |clip| {
            left = @max(left, clip[0]);
            top = @max(top, clip[1]);
            right = @min(right, clip[0] + clip[2]);
            bottom = @min(bottom, clip[1] + clip[3]);
        }
    }
    return std.math.isFinite(bounds.x) and std.math.isFinite(bounds.y) and bounds.w > 0 and bounds.h > 0 and right > left and bottom > top;
}
fn findFocus(cx: *ui.Cx, node: *ui.Node, id: []const u8, width: f32, height: f32) ?*ui.Node {
    if (node.isPaintSkipped() or !node.isDisplayedInTree()) return null;
    if (node.meta.ownership.meta.test_id) |key| if (std.mem.eql(u8, id, key) and node.behavior.interaction.focusable and focusVisible(cx, node, width, height)) return node;
    for (node.children.items) |child| if (findFocus(cx, child, id, width, height)) |found| return found;
    return null;
}
/// First completed layout is the restore barrier. Application decode has already
/// happened while mounting; scroll and then focus only run once per live window.
pub fn afterLayout(app: anytype) void {
    if (!enabled) return;
    const s = state orelse return;
    s.callback_depth += 1;
    defer {
        s.callback_depth -= 1;
        if (s.callback_depth == 0 and !s.draining and s.ever_attached and s.hosts.items.len == 0) destroyState(s);
    }
    // Correlate the first submitted native frame with the style generation.
    // Actual display time comes from Metal's existing opt-in presented trace.
    if (@hasField(@TypeOf(app.*), "renderer")) {
        if (app.renderer.last_frame_presented) {
            for (s.hosts.items) |*h| if (h.ptr == @as(*anyopaque, app)) {
                const cx = h.context(h.ptr);
                if (ui.template_reload.generation > h.template_submitted_generation) {
                    h.template_submitted_generation = ui.template_reload.generation;
                    h.template_submitted_frame = app.renderer.frame_count;
                    h.template_after_submit_ns = std.Io.Clock.awake.now(s.session.io).nanoseconds;
                    h.template_layout_us = app.renderer.last_frame_stats.layout_us;
                    h.template_encode_submit_us = app.renderer.last_frame_stats.gpu_encode_us;
                }
                if (cx.style_generation > h.submitted_generation) {
                    h.submitted_generation = cx.style_generation;
                    h.submitted_frame = app.renderer.frame_count;
                    h.after_submit_ns = std.Io.Clock.awake.now(s.session.io).nanoseconds;
                    h.layout_us = app.renderer.last_frame_stats.layout_us;
                    h.encode_submit_us = app.renderer.last_frame_stats.gpu_encode_us;
                }
                break;
            };
        }
    }
    for (s.hosts.items) |*h| if (h.ptr == @as(*anyopaque, app) and h.layout_ready and h.pending_scroll_len > 0) {
        const cx = h.context(h.ptr);
        h.scroll_retry_layouts += 1;
        if (h.scroll_retry_layouts > scroll_retry_limit) {
            h.pending_scroll_len = 0;
        } else if (cx.root) |root| {
            retryPendingScroll(h, root);
            cx.needs_redraw = true;
        }
        break;
    };
    for (s.hosts.items) |*h| if (h.ptr == @as(*anyopaque, app) and !h.layout_ready) {
        h.layout_ready = true;
        s.dirty = true;
        const cx = h.context(h.ptr);
        if (s.restored) |r| for (r.value.windows) |w| if (std.mem.eql(u8, w.key, h.key)) {
            if (cx.root) |root| {
                restoreScroll(h, root, w.scroll);
                cx.needs_redraw = true;
                // Focus can invoke application callbacks. Do not touch the
                // borrowed host, tree or host-list iterator after it returns.
                if (w.focus) |id| if (findFocus(cx, root, id, cx.viewport.width, cx.viewport.height)) |node| cx.setFocus(node);
            }
            return;
        };
        return;
    };
}
fn clearOverlay(h: Host) void {
    const node = h.overlay orelse return;
    const cx = h.context(h.ptr);
    if (!cx.node_registry.isCurrentIdentity(.{ .id = h.overlay_id, .generation = h.overlay_generation }, node)) return;
    if (node.parent) |parent| cx.detachChild(parent, node);
    cx.freeNode(node);
    cx.needs_redraw = true;
}
fn showOverlay(h: *Host, text: []const u8) !void {
    const cx = h.context(h.ptr);
    const portal = try cx.ensurePopoverPortalRoot();
    // Construct fully before replacing the old error. No focus trap, handlers,
    // barrier, or interactive descendants; pointer hits pass through the subtree.
    const node = try ui.box(cx, .{ .position = .absolute, .direction = .column, .width = .{ .percent = 100 }, .background = ui.Color.hex(0x501c24), .padding = .{ .top = 12, .bottom = 12, .left = 16, .right = 16 } }, .{});
    errdefer cx.freeNode(node);
    const label = try ui.text(cx, "", .{ .color = ui.Color.hex(0xffeeee), .font_size = 13, .wrap = .word, .selectable = false });
    var orphan = true;
    errdefer if (orphan) cx.freeNode(label);
    try label.setTextContent(cx.allocator, text);
    label.setHitTestVisible(false);
    try node.appendChild(cx.allocator, label);
    orphan = false;
    (try node.style.ensureExtFallible(cx.allocator)).z_index = 32760;
    node.setHitTestVisible(false);
    const generation = try cx.node_registry.trackGeneration(node);
    try portal.appendChild(cx.allocator, node);
    clearOverlay(h.*);
    h.overlay = node;
    h.overlay_id = node.id;
    h.overlay_generation = generation;
    cx.needs_redraw = true;
}
// Called by the dev CSS facade inside a tracked manual .resolve() evaluation.
// Reading every live Cx signal also covers cross-window shared computations.
fn observeStyleGeneration() void {
    const s = state orelse return;
    for (s.hosts.items) |h| {
        const cx = h.context(h.ptr);
        if (cx.style_signal) |signal| _ = signal.get();
    }
}

fn safeSourcePath(path: []const u8) bool {
    if (path.len == 0 or std.fs.path.isAbsolute(path) or path[0] == '/' or path[0] == '\\') return false;
    // Reject Windows drive prefixes on every platform, and traversal in either separator form.
    if (path.len > 1 and path[1] == ':') return false;
    var parts = std.mem.tokenizeAny(u8, path, "/\\");
    while (parts.next()) |part| if (std.mem.eql(u8, part, "..")) return false;
    return true;
}
fn reloadFallback(a: A, file: []const u8, reason: []const u8) ![]const u8 {
    return std.json.Stringify.valueAlloc(a, .{ .result = "fallback", .file = file, .reason = reason }, .{});
}
fn reloadDiagnostic(s: *State, a: A, file: []const u8, line: usize, message: []const u8) ![]const u8 {
    const diagnostic = try std.fmt.allocPrint(a, "{s}:{d}: {s}", .{ file, line, message });
    // Serialize the response before mutating UI state, so a response allocation cannot fail
    // after a successful transaction or clear an existing diagnostic.
    const reply = try std.json.Stringify.valueAlloc(a, .{ .result = "error", .diagnostic = diagnostic, .file = file, .line = line }, .{});
    for (s.hosts.items) |*h| {
        if (h.context(h.ptr).root != null) try showOverlay(h, diagnostic);
    }
    return reply;
}
fn reloadDiagnosticUntil(s: *State, a: A, file: []const u8, line: usize, message: []const u8, deadline: i96) ![]const u8 {
    if (std.Io.Clock.awake.now(s.session.io).nanoseconds >= deadline) return error.Timeout;
    return reloadDiagnostic(s, a, file, line, message);
}
// The transaction's last-resort error response must work even when allocating
// the diagnostic overlay failed. Keep the reload envelope without allocating.
fn reloadFailure(buf: []u8, err: anyerror) []const u8 {
    if (err == error.Timeout) return "{\"result\":\"fallback\",\"file\":\"<reload>\",\"reason\":\"deadline\"}";
    return std.fmt.bufPrint(buf, "{{\"result\":\"error\",\"file\":\"<reload>\",\"line\":1,\"diagnostic\":\"<reload>:1: {s}\"}}", .{@errorName(err)}) catch
        "{\"result\":\"error\",\"file\":\"<reload>\",\"line\":1,\"diagnostic\":\"reload failed\"}";
}
const ReloadHost = struct {
    ptr: *anyopaque,
    cx: *ui.Cx,
    token: *ui.Cx.LifetimeToken,
    values: ?*const ui.theme.Values = null,
};
fn reloadHostAttached(s: *State, h: ReloadHost) bool {
    if (!h.token.isAlive()) return false;
    for (s.hosts.items) |host| if (host.ptr == h.ptr and host.context(host.ptr) == h.cx) return true;
    return false;
}
fn reloadStyles(s: *State, a: A, text: []const u8, deadline: i96) ![]const u8 {
    const started = std.Io.Clock.awake.now(s.session.io).nanoseconds;
    const parsed = try std.json.parseFromSlice(struct { files: []const []const u8 }, a, text, .{});
    defer parsed.deinit();
    const paths = parsed.value.files;
    if (paths.len == 0) return reloadFallback(a, "", "empty_files");
    if (s.hosts.items.len == 0) return reloadFallback(a, "", "no_live_windows");
    var styles: std.ArrayList(ui.style_reload.File) = .empty;
    var token_version: ?*ui.theme_reload.Version = null;
    var theme_file: []const u8 = "";
    defer if (token_version) |version| if (!version.committed) version.deinit();
    for (paths, 0..) |path, i| {
        if (!safeSourcePath(path)) return reloadFallback(a, path, "invalid_path");
        for (paths[0..i]) |previous| if (std.mem.eql(u8, previous, path)) return reloadFallback(a, path, "duplicate_file");
        const is_yss = std.mem.endsWith(u8, path, ".yss");
        const is_theme = std.mem.eql(u8, std.fs.path.basename(path), "theme.json") or std.mem.eql(u8, path, "src/tokens/default.json");
        if (!is_yss and !is_theme) return reloadFallback(a, path, "unsupported_file");
        const source = std.Io.Dir.cwd().readFileAlloc(s.session.io, path, a, .limited(8 * 1024 * 1024)) catch |err| {
            if (err == error.FileNotFound) return reloadFallback(a, path, "source_deleted");
            return reloadDiagnosticUntil(s, a, path, 1, @errorName(err), deadline);
        };
        if (is_yss) {
            try styles.append(a, .{ .path = path, .source = source });
        } else {
            if (token_version != null) return reloadFallback(a, path, "multiple_themes");
            theme_file = path;
            const version = try ui.theme_reload.prepare(allocator, source);
            token_version = version;
            switch (version.result) {
                .ready => {},
                .fallback => |reason| return reloadFallback(a, path, reason),
                .diagnostic => |diagnostic| return reloadDiagnosticUntil(s, a, path, diagnostic.line, diagnostic.message, deadline),
            }
        }
    }
    const preparation = try ui.style_reload.prepare(allocator, styles.items);
    defer if (!preparation.committed) preparation.deinit();
    switch (preparation.result) {
        .ready => {},
        .fallback => |fallback| return reloadFallback(a, fallback.file, fallback.reason),
        .diagnostic => |diagnostic| return reloadDiagnosticUntil(s, a, diagnostic.file, diagnostic.line, diagnostic.message, deadline),
    }

    // Snapshot contexts, not borrowed host-array slots. A replay callback can close a
    // different window or remove its host; tokens stay valid after Cx destruction.
    const hosts = try a.alloc(ReloadHost, s.hosts.items.len);
    var retained: usize = 0;
    defer for (hosts[0..retained]) |h| h.token.release();
    for (s.hosts.items, hosts) |h, *record| {
        const cx = h.context(h.ptr);
        record.* = .{ .ptr = h.ptr, .cx = cx, .token = cx.retainLifetimeToken() };
        retained += 1;
        if (token_version) |version| {
            for (&version.values) |*values| if (std.mem.eql(u8, values.name, cx.tokens.name)) {
                record.values = values;
                break;
            };
            if (record.values == null) return reloadFallback(a, theme_file, "token_mode");
        }
        try cx.reserveStyleNotification();
    }
    // Allocate the complete response buffer before publication. elapsed_ms is formatted
    // into this fixed buffer afterward; the reported interval ends at application,
    // never claims that the GPU has presented a frame.
    const reply = try a.alloc(u8, 256);
    // Cancellation remains reversible through the entire prepare/reservation phase.
    // Once publication starts it is one synchronous, non-failing transaction.
    if (std.Io.Clock.awake.now(s.session.io).nanoseconds >= deadline) return error.Timeout;
    for (hosts) |h| {
        h.cx.beginActiveUse();
        h.cx.owner.beginBatch();
    }
    const prepared_at = std.Io.Clock.awake.now(s.session.io).nanoseconds;
    const generation = preparation.commit();
    if (token_version) |version| version.commit();
    for (hosts) |h| if (reloadHostAttached(s, h)) {
        if (h.values) |values| h.cx.setTheme(values);
    };
    for (hosts) |h| if (reloadHostAttached(s, h)) h.cx.publishStyleGeneration(generation);
    for (hosts) |h| if (h.token.isAlive()) h.cx.owner.endBatch();
    for (hosts) |h| if (h.token.isAlive()) h.cx.endActiveUse();
    for (s.hosts.items) |*h| {
        clearOverlay(h.*);
        h.overlay = null;
    }
    ui.style_reload.collect();
    ui.theme_reload.collect();
    const elapsed_ms = @as(f64, @floatFromInt(std.Io.Clock.awake.now(s.session.io).nanoseconds - started)) / std.time.ns_per_ms;
    const parse_ms = @as(f64, @floatFromInt(prepared_at - started)) / std.time.ns_per_ms;
    return std.fmt.bufPrint(reply, "{{\"result\":\"applied\",\"generation\":{d},\"elapsed_ms\":{d:.3},\"parse_ms\":{d:.3},\"apply_ms\":{d:.3}}}", .{ generation, elapsed_ms, parse_ms, elapsed_ms - parse_ms }) catch unreachable;
}
// Reserved before the irreversible boundary. Even response-allocation OOM
// must not turn a required restart into the launcher's recoverable error path.
fn templateFallbackInto(buf: []u8, err: anyerror) []const u8 {
    var writer = std.Io.Writer.fixed(buf);
    std.json.Stringify.value(.{ .result = "fallback", .file = "<reload>", .reason = @errorName(err) }, .{}, &writer) catch
        return "{\"result\":\"fallback\",\"file\":\"<reload>\",\"reason\":\"TemplateNeedsRemount\"}";
    return writer.buffered();
}

fn reloadTemplates(s: *State, a: A, text: []const u8, deadline: i96) ![]const u8 {
    const started = std.Io.Clock.awake.now(s.session.io).nanoseconds;
    const parsed = try std.json.parseFromSlice(struct { files: []const []const u8, fail_after: ?usize = null, fail_commit_at: ?usize = null }, a, text, .{});
    defer parsed.deinit();
    if (parsed.value.files.len == 0 or s.hosts.items.len == 0) return reloadFallback(a, "", "empty_batch_or_windows");
    var files: std.ArrayList(ui.template_reload.File) = .empty;
    for (parsed.value.files) |path| {
        if (!safeSourcePath(path) or !std.mem.endsWith(u8, path, ".yix")) return reloadFallback(a, path, "invalid_template_path");
        const source = std.Io.Dir.cwd().readFileAlloc(s.session.io, path, a, .limited(8 * 1024 * 1024)) catch |err| {
            if (err == error.FileNotFound) return reloadFallback(a, path, "source_deleted");
            return reloadDiagnosticUntil(s, a, path, 1, @errorName(err), deadline);
        };
        try files.append(a, .{ .path = path, .source = source });
    }
    const p = try ui.template_reload.prepare(allocator, files.items);
    defer if (!p.committed) p.deinit();
    switch (p.result) {
        .ready => {},
        .fallback => |f| return reloadFallback(a, f.file, f.reason),
        .diagnostic => |d| return reloadDiagnosticUntil(s, a, d.file, d.line, d.message, deadline),
    }
    const owners = try a.alloc(*ui.Cx, s.hosts.items.len);
    for (s.hosts.items, owners) |h, *cx| cx.* = h.context(h.ptr);
    const reply = try a.alloc(u8, 384);
    p.fail_after = parsed.value.fail_after;
    p.fail_commit_at = parsed.value.fail_commit_at;
    p.deadline = deadline;
    const prepared = std.Io.Clock.awake.now(s.session.io).nanoseconds;
    const refreshed = p.apply(owners) catch |err| {
        // Candidate failure preserves the old view; commit failure is already
        // needs_remount. Both require the launcher's existing stateful L3 path.
        std.log.warn("[preview] template refresh requests L3: {s} (needs_remount={})", .{ @errorName(err), ui.template_reload.needs_remount });
        return templateFallbackInto(reply, err);
    };
    for (s.hosts.items) |*h| {
        h.context(h.ptr).needs_redraw = true;
        clearOverlay(h.*);
        h.overlay = null;
    }
    const end = std.Io.Clock.awake.now(s.session.io).nanoseconds;
    const parse_ms = @as(f64, @floatFromInt(prepared - started)) / std.time.ns_per_ms;
    const elapsed_ms = @as(f64, @floatFromInt(end - started)) / std.time.ns_per_ms;
    return std.fmt.bufPrint(reply, "{{\"result\":\"applied\",\"generation\":{d},\"refreshed\":{d},\"elapsed_ms\":{d:.3},\"parse_ms\":{d:.3},\"apply_ms\":{d:.3},\"state_contract\":\"setup retained; descendants remount\"}}", .{ ui.template_reload.generation, refreshed, elapsed_ms, parse_ms, elapsed_ms - parse_ms }) catch unreachable;
}

fn closePreviewWindow(s: *State, a: A, text: []const u8) ![]const u8 {
    const parsed = try std.json.parseFromSlice(struct { key: []const u8 }, a, text, .{});
    defer parsed.deinit();
    for (s.hosts.items) |h| if (std.mem.eql(u8, h.key, parsed.value.key)) {
        h.quit(h.ptr);
        return "{\"ok\":true}";
    };
    return error.WindowKeyNotFound;
}
fn activateTemplate(s: *State, a: A, text: []const u8) ![]const u8 {
    const parsed = try std.json.parseFromSlice(struct { test_id: []const u8, occurrence: ?usize = null }, a, text, .{});
    defer parsed.deinit();
    var found: ?*ui.Node = null;
    var owner: ?*ui.Cx = null;
    var matches: usize = 0;
    for (s.hosts.items) |h| if (h.context(h.ptr).root) |root| {
        const previous = found;
        if (parsed.value.occurrence) |which| findTemplateOccurrence(root, parsed.value.test_id, which, &matches, &found) else try findStyleNode(root, parsed.value.test_id, &found);
        if (previous == null and found != null) owner = h.context(h.ptr);
    };
    const node = found orelse return error.TestIdNotFound;
    const handler = node.behavior.events.on_click orelse return error.TemplateHandlerMissing;
    const cx = owner.?;
    cx.beginActiveUse();
    defer cx.endActiveUse();
    cx.owner.beginReactiveCallback();
    handler.callback(handler.context);
    cx.owner.endReactiveCallback();
    return "{\"ok\":true}";
}

fn queryTemplate(s: *State, a: A, text: []const u8) ![]const u8 {
    const parsed = try std.json.parseFromSlice(struct { test_id: []const u8, occurrence: ?usize = null }, a, text, .{});
    defer parsed.deinit();
    var found: ?*ui.Node = null;
    var matches: usize = 0;
    for (s.hosts.items) |h| if (h.context(h.ptr).root) |root| {
        if (parsed.value.occurrence) |which| findTemplateOccurrence(root, parsed.value.test_id, which, &matches, &found) else try findStyleNode(root, parsed.value.test_id, &found);
    };
    const node = found orelse return error.TestIdNotFound;
    return std.json.Stringify.valueAlloc(a, .{ .generation = ui.template_reload.generation, .text = if (node.getText()) |value| value.content else "", .style_gap = node.style.gap, .font_size = if (node.getText()) |value| value.font_size else @as(f32, 0), .children = node.children.items.len, .matches = if (parsed.value.occurrence != null) matches else @as(usize, 1) }, .{});
}

fn findTemplateOccurrence(node: *ui.Node, id: []const u8, which: usize, count: *usize, found: *?*ui.Node) void {
    if (node.meta.ownership.meta.test_id) |value| if (std.mem.eql(u8, value, id)) {
        if (count.* == which) found.* = node;
        count.* += 1;
    };
    for (node.children.items) |child| findTemplateOccurrence(child, id, which, count, found);
}

fn findStyleNode(node: *ui.Node, test_id: []const u8, found: *?*ui.Node) !void {
    if (node.meta.ownership.meta.test_id) |id| if (std.mem.eql(u8, id, test_id)) {
        if (found.* != null) return error.AmbiguousTestId;
        found.* = node;
    };
    for (node.children.items) |child| try findStyleNode(child, test_id, found);
}
fn queryStyle(s: *State, a: A, text: []const u8) ![]const u8 {
    const parsed = try std.json.parseFromSlice(struct { test_id: []const u8 }, a, text, .{});
    defer parsed.deinit();
    if (parsed.value.test_id.len == 0) return error.EmptyTestId;
    var found: ?*ui.Node = null;
    for (s.hosts.items) |h| {
        const cx = h.context(h.ptr);
        const capacity = 2 + 2 * @TypeOf(cx.overlay_stack).MAX_LAYERS;
        var roots: [capacity]*ui.Node = undefined;
        var count: usize = 0;
        var candidates: [capacity]?*ui.Node = undefined;
        candidates[0] = cx.root;
        candidates[1] = cx.popover_portal_root;
        var n: usize = 2;
        for (cx.overlay_stack.layers.items) |maybe| if (maybe) |layer| {
            candidates[n] = layer.content_node;
            candidates[n + 1] = layer.barrier_node;
            n += 2;
        };
        for (candidates[0..n]) |candidate| {
            var root = candidate orelse continue;
            while (root.parent) |parent| root = parent;
            var duplicate = false;
            for (roots[0..count]) |previous| if (previous == root) {
                duplicate = true;
                break;
            };
            if (duplicate) continue;
            roots[count] = root;
            count += 1;
            try findStyleNode(root, parsed.value.test_id, &found);
        }
    }
    const node = found orelse return error.UnknownTestId;
    const color = node.getBackground();
    const font_size: ?f32 = if (node.resolveTextProps()) |props| props.font_size else node.resolveTextFontSize();
    return std.json.Stringify.valueAlloc(a, .{
        .test_id = parsed.value.test_id,
        .generation = ui.style_reload.generation,
        .background = .{ .r = color.r, .g = color.g, .b = color.b, .a = color.a },
        .corner_radius = node.style.effectiveRadius(),
        .padding = node.style.padding,
        .font_size = font_size,
    }, .{});
}

fn writeSnapshot(s: *State, a: A) ![]const u8 {
    const epoch = s.mutation_epoch;
    const windows = try a.alloc(snapshot.Window, s.hosts.items.len);
    for (s.hosts.items, windows) |h, *w| {
        w.* = try h.capture(h.ptr, a, h.key);
        // A restore still waiting for its content extent must not be persisted as
        // the clamped interim offset, or the next handoff would lose the target.
        if (h.pending_scroll_len > 0) {
            const scroll = try a.dupe(snapshot.Scroll, w.scroll);
            for (h.pending_scroll[0..h.pending_scroll_len]) |p| for (scroll) |*sc| if (std.mem.eql(u8, sc.key, p.key)) {
                sc.x = p.x;
                sc.y = p.y;
            };
            w.scroll = scroll;
        }
    }
    const application = try s.registry.capture(a);
    if (epoch != s.mutation_epoch) return error.SnapshotInvalidated;
    const bytes = try snapshot.encode(a, .{ .revision = s.session.revision, .generation = s.session.generation, .application = application, .windows = windows });
    // Content-addressed snapshots keep path+hash stable even after a later periodic write.
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const hash = std.fmt.bytesToHex(digest, .lower);
    const name = try std.fmt.allocPrint(a, "snapshot-{s}.json", .{hash});
    try transport.atomicWrite(s.session.dir, s.session.io, name, bytes);
    const path = try std.fs.path.join(a, &.{ s.session.path, name });
    const result = try std.json.Stringify.valueAlloc(a, .{ .path = path, .hash = hash[0..] }, .{});
    try transport.atomicWrite(s.session.dir, s.session.io, "latest.json", result);
    s.dirty = false;
    s.last_write = std.Io.Clock.awake.now(s.session.io).nanoseconds;
    return result;
}
fn health(s: *State, a: A) ![]const u8 {
    var overlays: usize = 0;
    for (s.hosts.items) |h| if (h.overlay) |node| {
        if (h.context(h.ptr).node_registry.isCurrentIdentity(.{ .id = h.overlay_id, .generation = h.overlay_generation }, node)) overlays += 1;
    };
    const Frame = struct { key: []const u8, window_id: u64, generation: u64, frame: u64, after_submit_ns: i96, layout_us: u64, encode_submit_us: u64 };
    const frames = try a.alloc(Frame, s.hosts.items.len);
    defer a.free(frames);
    for (s.hosts.items, frames) |h, *f| f.* = .{ .key = h.key, .window_id = h.context(h.ptr).window_id, .generation = h.submitted_generation, .frame = h.submitted_frame, .after_submit_ns = h.after_submit_ns, .layout_us = h.layout_us, .encode_submit_us = h.encode_submit_us };
    const template_frames = try a.alloc(Frame, s.hosts.items.len);
    defer a.free(template_frames);
    for (s.hosts.items, template_frames) |h, *f| f.* = .{ .key = h.key, .window_id = h.context(h.ptr).window_id, .generation = h.template_submitted_generation, .frame = h.template_submitted_frame, .after_submit_ns = h.template_after_submit_ns, .layout_us = h.template_layout_us, .encode_submit_us = h.template_encode_submit_us };
    return std.json.Stringify.valueAlloc(a, .{ .retained_template_versions = ui.template_reload.retainedVersionCount(), .retained_template_bytes = ui.template_reload.retainedBytes(), .template_generation = ui.template_reload.generation, .template_needs_remount = ui.template_reload.needs_remount, .template_remount_reason = ui.template_reload.remount_reason, .template_frames = template_frames, .status = "ok", .ready = s.ready, .revision = s.session.revision, .generation = s.session.generation, .windows = s.hosts.items.len, .error_overlay = overlays > 0, .overlay_windows = overlays, .style_frames = frames, .retained_token_versions = ui.theme_reload.retainedVersionCount(), .retained_token_bytes = ui.theme_reload.retainedBytes(), .ui_heartbeat_ns = std.Io.Clock.awake.now(s.session.io).nanoseconds }, .{});
}
/// UI-thread safe point, after dispatch and before rendering. Reentrant calls
/// are ignored. Transport has no UI pointer and is joined before state is freed.
pub fn drain() void {
    if (!enabled) return;
    const s = state orelse return;
    if (s.draining) return;
    s.draining = true;
    defer {
        s.draining = false;
        if (s.ever_attached and s.hosts.items.len == 0 and s.callback_depth == 0) destroyState(s);
    }
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    if (s.session.channel.take()) |work| {
        const result: anyerror![]const u8 = switch (work.command) {
            .health => health(s, a),
            .reload_templates => reloadTemplates(s, a, work.text[0..work.len], work.deadline),
            .activate_template => activateTemplate(s, a, work.text[0..work.len]),
            .close_preview_window => closePreviewWindow(s, a, work.text[0..work.len]),
            .query_template => queryTemplate(s, a, work.text[0..work.len]),
            .reload_styles => reloadStyles(s, a, work.text[0..work.len], work.deadline),
            .query_style => queryStyle(s, a, work.text[0..work.len]),
            .snapshot => writeSnapshot(s, a),
            .show_error => blk: {
                for (s.hosts.items) |*h| showOverlay(h, work.text[0..work.len]) catch |err| break :blk err;
                break :blk "{\"ok\":true}";
            },
            .clear_error => blk: {
                for (s.hosts.items) |*h| {
                    clearOverlay(h.*);
                    h.overlay = null;
                }
                break :blk "{\"ok\":true}";
            },
            .set_persist => blk: {
                const parsed = std.json.parseFromSlice(snapshot.Entry, a, work.text[0..work.len], .{}) catch |err| break :blk err;
                defer parsed.deinit();
                s.registry.apply(parsed.value) catch |err| break :blk err;
                markDirty();
                break :blk "{\"ok\":true}";
            },
            .set_scroll, .set_frame, .set_focus => blk: {
                const text = work.text[0..work.len];
                const action: anyerror!void = switch (work.command) {
                    .set_scroll => setScroll(s, a, text),
                    .set_frame => setFrame(s, a, text),
                    .set_focus => setFocus(s, a, text),
                    else => unreachable,
                };
                action catch |err| break :blk err;
                break :blk "{\"ok\":true}";
            },
            .quit => blk: {
                for (s.hosts.items) |h| h.quit(h.ptr);
                break :blk "{\"ok\":true}";
            },
        };
        var error_buf: [256]u8 = undefined;
        s.session.channel.complete(result catch |err| if (work.command == .reload_styles or work.command == .reload_templates) reloadFailure(&error_buf, err) else transport.errorJson(&error_buf, err) catch "{\"error\":\"Internal\"}");
    }
    var all_ready = s.hosts.items.len > 0;
    for (s.hosts.items) |h| all_ready = all_ready and h.layout_ready;
    if (all_ready) {
        const now = std.Io.Clock.awake.now(s.session.io).nanoseconds;
        if (s.dirty or now - s.last_write >= std.time.ns_per_s) {
            _ = writeSnapshot(s, a) catch return;
            const status = health(s, a) catch return;
            transport.atomicWrite(s.session.dir, s.session.io, "health", status) catch return;
        }
        if (!s.ready) {
            s.ready = true;
            const status = health(s, a) catch return;
            transport.atomicWrite(s.session.dir, s.session.io, "ready", status) catch {
                s.ready = false;
            };
        }
    }
}

const TestWindow = struct {
    restored: ?[4]f64 = null,
    pub fn previewGeometry(_: *TestWindow, _: u64) ?[9]f64 {
        return .{ -200, 20, 800, 600, -1000, 20, 1000, 700, 7 };
    }
    pub fn restorePreviewFrame(self: *TestWindow, frame: [4]f64) void {
        self.restored = frame;
    }
};
const TestHost = struct {
    config: struct { io: std.Io, window: struct { persist_key: ?[]const u8 = null } },
    win: TestWindow = .{},
    cx: *ui.Cx,
    should_quit: bool = false,
};
fn testState(root: []const u8) !*State {
    const s = try allocator.create(State);
    errdefer allocator.destroy(s);
    s.* = .{ .session = try transport.Session.init(allocator, std.testing.io, root, "test-revision", "1"), .registry = .{ .allocator = allocator } };
    state = s;
    return s;
}
test "preview multi-window restore barrier, overlay focus isolation, snapshot hash, quit and close" {
    // SKIP-REASON: dev-control runs only in -Ddev-preview=true builds (test-dev-control step).
    if (!enabled) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root_path);
    const s = try testState(root_path);
    defer if (state != null) destroyState(s);
    const cx1 = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx1.deinit();
    const cx2 = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx2.deinit();
    var first: TestHost = .{ .config = .{ .io = std.testing.io, .window = .{ .persist_key = "main" } }, .cx = cx1 };
    var second: TestHost = .{ .config = .{ .io = std.testing.io, .window = .{} }, .cx = cx2 };
    cx1.root = try ui.box(cx1, .{}, .{});
    cx2.root = try ui.box(cx2, .{}, .{});
    const input = try ui.box(cx1, .{}, .{});
    try cx1.root.?.appendChild(cx1.allocator, input);
    input.setFocusable(true);
    input.meta.ownership.meta.test_id = "input";
    input.setLayoutRect(.{ .x = 0, .y = 0, .w = 20, .h = 20 });
    cx1.setFocus(input);
    cx1.root.?.setLayoutRect(.{ .x = 0, .y = 0, .w = 100, .h = 100 });
    try std.testing.expect(findFocus(cx1, cx1.root.?, "input", 100, 100) == input);
    input.setDisplay(.none);
    try std.testing.expect(findFocus(cx1, cx1.root.?, "input", 100, 100) == null);
    input.setDisplay(.flex);
    input.setLayoutRect(.{ .x = 200, .y = 200, .w = 20, .h = 20 });
    try std.testing.expect(findFocus(cx1, cx1.root.?, "input", 100, 100) == null);
    input.setLayoutRect(.{ .x = 0, .y = 0, .w = 20, .h = 20 });
    cx1.root.?.style.translate_x = 200;
    try std.testing.expect(findFocus(cx1, cx1.root.?, "input", 100, 100) == null);
    cx1.root.?.style.translate_x = 0;
    cx1.root.?.style.overflow_hidden = true;
    cx1.root.?.setLayoutRect(.{ .x = 0, .y = 0, .w = 50, .h = 50 });
    input.setLayoutRect(.{ .x = 60, .y = 0, .w = 20, .h = 20 });
    try std.testing.expect(findFocus(cx1, cx1.root.?, "input", 100, 100) == null);
    input.setLayoutRect(.{ .x = 0, .y = 0, .w = 20, .h = 20 });
    try cx1.external_clip_rects.put(cx1.allocator, input.id, .{ 50, 50, 10, 10 });
    try std.testing.expect(findFocus(cx1, cx1.root.?, "input", 100, 100) == null);
    _ = cx1.external_clip_rects.remove(input.id);
    const saved = try snapshot.encode(std.testing.allocator, .{ .revision = "old", .generation = "0", .windows = &.{.{ .key = "main", .frame = .{ .x = 9999, .y = 9999 }, .focus = "gone" }} });
    defer std.testing.allocator.free(saved);
    s.restored = try snapshot.decode(allocator, saved);
    try attach(&first);
    try attach(&second);
    try std.testing.expectEqualStrings("window-1", s.hosts.items[1].key);
    try std.testing.expectEqual([4]f64{ -800, 120, 800, 600 }, first.win.restored.?);
    afterLayout(&first);
    drain();
    try std.testing.expect(!s.ready);
    afterLayout(&second);
    drain();
    try std.testing.expect(s.ready);
    try std.testing.expect(cx1.focused_node == input); // Missing saved id never steals focus.
    try s.session.channel.submit(.{ .command = .show_error, .text = "main.zig:42\ncompile error\nsecond line" });
    drain();
    var response: [16384]u8 = undefined;
    _ = try s.session.channel.poll(&response);
    for (s.hosts.items) |h| {
        try std.testing.expect(!h.overlay.?.frame_state.state_bits.flags.hit_test_visible);
        try std.testing.expect(!h.overlay.?.children.items[0].frame_state.state_bits.flags.hit_test_visible);
    }
    try std.testing.expect(cx1.focused_node == input);
    const with_overlay = try health(s, std.testing.allocator);
    defer std.testing.allocator.free(with_overlay);
    try std.testing.expect(std.mem.indexOf(u8, with_overlay, "\"error_overlay\":true") != null);
    try s.session.channel.submit(.{ .command = .snapshot });
    drain();
    const reply = (try s.session.channel.poll(&response)).?;
    const result = try std.json.parseFromSlice(struct { path: []const u8, hash: []const u8 }, std.testing.allocator, reply, .{});
    defer result.deinit();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, result.value.path, std.testing.allocator, .limited(1024 * 1024));
    defer std.testing.allocator.free(bytes);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    try std.testing.expectEqualStrings(&std.fmt.bytesToHex(digest, .lower), result.value.hash);
    const parsed = try snapshot.decode(std.testing.allocator, bytes);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.value.windows.len);
    try s.session.channel.submit(.{ .command = .clear_error });
    drain();
    _ = try s.session.channel.poll(&response);
    for (s.hosts.items) |h| try std.testing.expect(h.overlay == null);
    try s.session.channel.submit(.{ .command = .quit });
    drain();
    _ = try s.session.channel.poll(&response);
    try std.testing.expect(first.should_quit and second.should_quit);
    try showOverlay(&s.hosts.items[0], "remount.zig:1");
    cx1.unmount(); // Unmount owns the portal, invalidating the overlay's generation.
    clearOverlay(s.hosts.items[0]); // A stale cached pointer must never be dereferenced.
    s.hosts.items[0].overlay = null;
    detach(&first);
    try std.testing.expectEqual(@as(usize, 1), s.hosts.items.len);
    detach(&second);
    try std.testing.expect(state == null);
}

test "preview callback can close its last host and reenter drain" {
    // SKIP-REASON: dev-control runs only in -Ddev-preview=true builds (test-dev-control step).
    if (!enabled) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(path);
    const s = try testState(path);
    defer if (state != null) destroyState(s);
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    var host: TestHost = .{ .config = .{ .io = std.testing.io, .window = .{} }, .cx = cx };
    cx.root = try ui.box(cx, .{}, .{});
    try attach(&host);
    const Callback = struct {
        fn encode(raw: *anyopaque, a: A) ![]u8 {
            const app: *TestHost = @ptrCast(@alignCast(raw));
            drain();
            try unpersist("close");
            detach(app);
            return a.dupe(u8, "closed");
        }
        fn decode(_: *anyopaque, _: ?u32, _: ?[]const u8) !void {}
    };
    try persist("close", 1, &host, Callback.encode, Callback.decode);
    try s.session.channel.submit(.{ .command = .snapshot });
    drain();
    try std.testing.expect(state == null);
}

fn overlayOOM(a: A) !void {
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    cx.root = try ui.box(cx, .{}, .{});
    var app: TestHost = .{ .config = .{ .io = std.testing.io, .window = .{} }, .cx = cx };
    var host: Host = .{ .ptr = &app, .key = "main", .capture = undefined, .restore_frame = undefined, .quit = undefined, .context = struct {
        fn context(raw: *anyopaque) *ui.Cx {
            const p: *TestHost = @ptrCast(@alignCast(raw));
            return p.cx;
        }
    }.context };
    try showOverlay(&host, "file.zig:1\nerror");
    clearOverlay(host);
}
test "preview error overlay partial construction OOM sweep" {
    // SKIP-REASON: dev-control runs only in -Ddev-preview=true builds (test-dev-control step).
    if (!enabled) return error.SkipZigTest;
    try std.testing.checkAllAllocationFailures(std.testing.allocator, overlayOOM, .{});
}

test "persist decoder may close its host without freeing the active registry callback" {
    // SKIP-REASON: dev-control runs only in -Ddev-preview=true builds (test-dev-control step).
    if (!enabled) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(path);
    const s = try testState(path);
    defer if (state != null) destroyState(s);
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    var app: TestHost = .{ .config = .{ .io = std.testing.io, .window = .{} }, .cx = cx };
    try attach(&app);
    const Callback = struct {
        fn encode(_: *anyopaque, a: A) ![]u8 {
            return a.dupe(u8, "unused");
        }
        fn decode(raw: *anyopaque, _: ?u32, _: ?[]const u8) !void {
            const host: *TestHost = @ptrCast(@alignCast(raw));
            try unpersist("close-on-decode");
            detach(host);
        }
    };
    try std.testing.expectError(error.RestoreHostClosed, persist("close-on-decode", 1, &app, Callback.encode, Callback.decode));
    try std.testing.expect(state == null);
}

test "application model and route may restore before any native window is created" {
    // SKIP-REASON: dev-control runs only in -Ddev-preview=true builds (test-dev-control step).
    if (!enabled) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(path);
    const s = try testState(path);
    defer if (state != null) destroyState(s);
    s.restored = try snapshot.decode(allocator, "{\"revision\":\"old\",\"generation\":\"0\",\"application\":[{\"key\":\"route\",\"schema_version\":1,\"data\":\"route\"}]}");
    const Model = struct {
        restored: bool = false,
        fn encode(_: *anyopaque, a: A) ![]u8 {
            return a.dupe(u8, "route");
        }
        fn decode(raw: *anyopaque, version: ?u32, data: ?[]const u8) !void {
            const model: *@This() = @ptrCast(@alignCast(raw));
            model.restored = version == 1 and data != null and std.mem.eql(u8, data.?, "route");
        }
    };
    var model: Model = .{};
    try prepare(std.testing.io);
    try persist("route", 1, &model, Model.encode, Model.decode);
    try std.testing.expect(model.restored);
    try std.testing.expectEqual(@as(usize, 0), s.hosts.items.len);
    try std.testing.expect(state != null);
    try cancelPreparation();
    try std.testing.expect(state == null);
}

test "first layout restores scroll and focus; dev commands mutate only at UI safe points" {
    // SKIP-REASON: dev-control runs only in -Ddev-preview=true builds (test-dev-control step).
    if (!enabled) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(path);
    const s = try testState(path);
    defer if (state != null) destroyState(s);
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(300, 200);
    const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
    cx.root_scope = scope;
    cx.root = try ui.box(cx, .{ .width = .{ .px = 300 }, .height = .{ .px = 200 } }, .{});
    const scroll = try ui.widgets.ScrollArea(.{ .width = 100, .height = 80, .persist_key = "list" }).mount(scope, cx);
    try cx.root.?.appendChild(cx.allocator, scroll.container);
    const content = try ui.box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 500 }, .flex_shrink = 0 }, .{});
    try scroll.content.appendChild(cx.allocator, content);
    const input = try ui.box(cx, .{ .width = .{ .px = 20 }, .height = .{ .px = 20 } }, .{});
    input.setFocusable(true);
    input.meta.ownership.meta.test_id = "focus-target";
    try cx.root.?.appendChild(cx.allocator, input);
    var host: TestHost = .{ .config = .{ .io = std.testing.io, .window = .{ .persist_key = "main" } }, .cx = cx };
    const bytes = try snapshot.encode(std.testing.allocator, .{ .revision = "old", .generation = "0", .windows = &.{.{ .key = "main", .scroll = &.{.{ .key = "list", .y = 120 }}, .focus = "focus-target" }} });
    defer std.testing.allocator.free(bytes);
    s.restored = try snapshot.decode(allocator, bytes);
    try attach(&host);
    _ = cx.render();
    afterLayout(&host);
    try std.testing.expectEqual(@as(f32, 120), ui.widgets.scroll_area.persistView(scroll.container).?.y);
    try std.testing.expect(cx.focused_node == input);
    drain();
    try std.testing.expect(s.ready);
    _ = cx.render();
    afterLayout(&host);
    try std.testing.expectEqual(@as(f32, 120), ui.widgets.scroll_area.persistView(scroll.container).?.y);
    // Producer submission must not touch the UI before drain; after drain the
    // real persist API clamps to actual content extents and survives a render.
    try s.session.channel.submit(.{ .command = .set_scroll, .text = "{\"key\":\"list\",\"x\":0,\"y\":240}" });
    try std.testing.expectEqual(@as(f32, 120), ui.widgets.scroll_area.persistView(scroll.container).?.y);
    drain();
    var response: [256]u8 = undefined;
    try std.testing.expectEqualStrings("{\"ok\":true}", (try s.session.channel.poll(&response)).?);
    _ = cx.render();
    try std.testing.expectEqual(@as(f32, 240), ui.widgets.scroll_area.persistView(scroll.container).?.y);
    try s.session.channel.submit(.{ .command = .set_scroll, .text = "{\"key\":\"missing\",\"x\":0,\"y\":120}" });
    drain();
    try std.testing.expectEqualStrings("{\"error\":\"UnknownScrollKey\"}", (try s.session.channel.poll(&response)).?);
    try std.testing.expectEqual(@as(f32, 240), ui.widgets.scroll_area.persistView(scroll.container).?.y);
    try s.session.channel.submit(.{ .command = .set_scroll, .text = "{\"key\":\"list\",\"x\":0,\"y\":9999}" });
    drain();
    _ = try s.session.channel.poll(&response);
    const clamped = ui.widgets.scroll_area.persistView(scroll.container).?.y;
    try std.testing.expect(clamped > 240 and clamped < 9999);
    try s.session.channel.submit(.{ .command = .set_focus, .text = "{\"key\":\"main\",\"id\":\"focus-target\"}" });
    cx.setFocus(null);
    drain();
    try std.testing.expectEqualStrings("{\"ok\":true}", (try s.session.channel.poll(&response)).?);
    try std.testing.expect(cx.focused_node == input);
    try s.session.channel.submit(.{ .command = .set_frame, .text = "{\"key\":\"main\",\"frame\":{\"x\":10,\"y\":30,\"w\":600,\"h\":400}}" });
    drain();
    try std.testing.expectEqualStrings("{\"ok\":true}", (try s.session.channel.poll(&response)).?);
    try std.testing.expectEqual(@as(f64, 30), host.win.restored.?[1]);
    try s.session.channel.submit(.{ .command = .set_scroll, .text = "{\"key\":\"list\",\"x\":0,\"y\":10}" });
    s.session.channel.work.deadline = 0;
    drain();
    try std.testing.expectError(error.Timeout, s.session.channel.poll(&response));
    try std.testing.expectEqual(clamped, ui.widgets.scroll_area.persistView(scroll.container).?.y);
    const duplicate = try ui.widgets.ScrollArea(.{ .width = 100, .height = 80, .persist_key = "list" }).mount(scope, cx);
    try cx.root.?.appendChild(cx.allocator, duplicate.container);
    try s.session.channel.submit(.{ .command = .set_scroll, .text = "{\"key\":\"list\",\"x\":0,\"y\":10}" });
    drain();
    try std.testing.expectEqualStrings("{\"error\":\"AmbiguousScrollKey\"}", (try s.session.channel.poll(&response)).?);
    try std.testing.expectEqual(clamped, ui.widgets.scroll_area.persistView(scroll.container).?.y);
    detach(&host);
}

test "scroll restore waits for late content extent, persists the target, and yields to user scrolling" {
    // SKIP-REASON: dev-control runs only in -Ddev-preview=true builds (test-dev-control step).
    if (!enabled) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(path);
    const s = try testState(path);
    defer if (state != null) destroyState(s);
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(300, 200);
    const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
    cx.root_scope = scope;
    cx.root = try ui.box(cx, .{ .width = .{ .px = 300 }, .height = .{ .px = 200 } }, .{});
    const late = try ui.widgets.ScrollArea(.{ .width = 100, .height = 80, .persist_key = "late" }).mount(scope, cx);
    try cx.root.?.appendChild(cx.allocator, late.container);
    // Content is still short on the first layout (e.g. stories still loading).
    const content = try ui.box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 }, .flex_shrink = 0 }, .{});
    try late.content.appendChild(cx.allocator, content);
    const user = try ui.widgets.ScrollArea(.{ .width = 100, .height = 80, .persist_key = "user" }).mount(scope, cx);
    try cx.root.?.appendChild(cx.allocator, user.container);
    const user_content = try ui.box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 }, .flex_shrink = 0 }, .{});
    try user.content.appendChild(cx.allocator, user_content);
    var host: TestHost = .{ .config = .{ .io = std.testing.io, .window = .{ .persist_key = "main" } }, .cx = cx };
    const bytes = try snapshot.encode(std.testing.allocator, .{ .revision = "old", .generation = "0", .windows = &.{.{ .key = "main", .scroll = &.{ .{ .key = "late", .y = 120 }, .{ .key = "user", .y = 120 } } }} });
    defer std.testing.allocator.free(bytes);
    s.restored = try snapshot.decode(allocator, bytes);
    try attach(&host);
    _ = cx.render();
    s.hosts.items[0].scroll_retry_layouts = scroll_retry_limit;
    afterLayout(&host);
    try std.testing.expectEqual(@as(u16, 0), s.hosts.items[0].scroll_retry_layouts);
    // Clamped short (100 - 80 = 20) but both targets are still pending.
    try std.testing.expectEqual(@as(f32, 20), ui.widgets.scroll_area.persistView(late.container).?.y);
    try std.testing.expectEqual(@as(u8, 2), s.hosts.items[0].pending_scroll_len);
    // A snapshot taken now keeps the target, not the clamped interim value.
    {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const latest = try writeSnapshot(s, arena.allocator());
        const pointer = try std.json.parseFromSliceLeaky(struct { path: []const u8, hash: []const u8 }, arena.allocator(), latest, .{});
        const written = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, pointer.path, arena.allocator(), .limited(1 << 20));
        const parsed = try snapshot.decode(arena.allocator(), written);
        var seen = false;
        for (parsed.value.windows[0].scroll) |sc| if (std.mem.eql(u8, sc.key, "late")) {
            seen = true;
            try std.testing.expectEqual(@as(f32, 120), sc.y);
        };
        try std.testing.expect(seen);
    }
    // The user scrolls "user" themselves before its content grows.
    ui.widgets.scroll_area.restorePersistOffset(user.container, 5, 5);
    // Content arrives; the next layouts reach the "late" target, and "user" keeps the user's offset.
    content.style.height = .{ .px = 500 };
    user_content.style.height = .{ .px = 500 };
    content.markLayoutDirty();
    user_content.markLayoutDirty();
    _ = cx.render();
    afterLayout(&host);
    _ = cx.render();
    afterLayout(&host);
    try std.testing.expectEqual(@as(f32, 120), ui.widgets.scroll_area.persistView(late.container).?.y);
    try std.testing.expectEqual(@as(f32, 0), ui.widgets.scroll_area.persistView(user.container).?.x);
    try std.testing.expect(ui.widgets.scroll_area.persistView(user.container).?.y < 120);
    try std.testing.expectEqual(@as(u8, 0), s.hosts.items[0].pending_scroll_len);
    detach(&host);
}

test "dev navigation file command can close the last host during decode" {
    // SKIP-REASON: dev-control runs only in -Ddev-preview=true builds (test-dev-control step).
    if (!enabled) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(path);
    const s = try testState(path);
    defer if (state != null) destroyState(s);
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    var app: TestHost = .{ .config = .{ .io = std.testing.io, .window = .{} }, .cx = cx };
    try attach(&app);
    const Callback = struct {
        fn encode(_: *anyopaque, a: A) ![]u8 {
            return a.dupe(u8, "route");
        }
        fn decode(raw: *anyopaque, version: ?u32, _: ?[]const u8) !void {
            if (version == null) return;
            const host: *TestHost = @ptrCast(@alignCast(raw));
            try unpersist("close-on-command");
            detach(host);
        }
    };
    try persist("close-on-command", 1, &app, Callback.encode, Callback.decode);
    try s.session.channel.submit(.{ .command = .set_persist, .text = "{\"key\":\"close-on-command\",\"schema_version\":1,\"data\":\"close\"}" });
    drain();
    try std.testing.expect(state == null);
}

test "non-preview safe point is erased and cannot initialize control state" {
    if (enabled) return;
    drain();
    try std.testing.expect(state == null);
    try std.testing.expect(!active());
    try std.testing.expect(std.meta.stringToEnum(@import("channel.zig").Command, "set_scroll") == null);
}

test "preview LP2 file transaction publishes both modes and new windows inherit it" {
    // SKIP-REASON: dev-control runs only in -Ddev-preview=true builds (test-dev-control step).
    if (!enabled) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = std.testing.allocator;
    const root_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(root_path);
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(cwd);
    const theme_path = try std.fs.path.join(a, &.{ root_path, "theme.json" });
    defer a.free(theme_path);
    const relative = try std.fs.path.relativeAlloc(a, cwd, null, cwd, theme_path);
    defer a.free(relative);
    const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "src/tokens/default.json", a, .limited(8 * 1024 * 1024));
    defer a.free(source);
    const edited = try std.mem.replaceOwned(u8, a, source, "\"panel\": 8", "\"panel\": 11");
    defer a.free(edited);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "theme.json", .data = edited });
    const s = try testState(root_path);
    defer if (state != null) destroyState(s);
    const cx1 = try ui.Cx.init(a, std.testing.io);
    defer cx1.deinit();
    const cx2 = try ui.Cx.init(a, std.testing.io);
    defer cx2.deinit();
    cx1.tokens = &ui.theme.light;
    cx2.tokens = &ui.theme.dark;
    var first: TestHost = .{ .config = .{ .io = std.testing.io, .window = .{ .persist_key = "first" } }, .cx = cx1 };
    var second: TestHost = .{ .config = .{ .io = std.testing.io, .window = .{ .persist_key = "second" } }, .cx = cx2 };
    try attach(&first);
    defer detach(&first);
    try attach(&second);
    defer detach(&second);
    const scope1 = try ui.Scope.init(a, null, cx1.owner);
    cx1.root_scope = scope1;
    const scope2 = try ui.Scope.init(a, null, cx2.owner);
    cx2.root_scope = scope2;
    const style = ui.css(.{ .background = .bg_primary, .corner_radius = .panel, .padding = 2 });
    cx1.root = try ui.view.render(scope1, cx1, ui.view.box(.{ .style = style, .test_id = "lp2-target" }, .{}));
    cx2.root = try ui.view.render(scope2, cx2, ui.view.box(.{ .style = style }, .{}));
    const before = cx1.tokens;
    try s.session.channel.submit(.{ .command = .reload_styles, .files = &.{relative} });
    try std.testing.expect(cx1.tokens == before);
    drain();
    var response: [16384]u8 = undefined;
    const reply = (try s.session.channel.poll(&response)).?;
    try std.testing.expect(std.mem.indexOf(u8, reply, "\"result\":\"applied\"") != null);
    try std.testing.expect(cx1.tokens != before);
    try std.testing.expectEqualStrings("light", cx1.tokens.name);
    try std.testing.expectEqualStrings("dark", cx2.tokens.name);
    try std.testing.expectEqual(@as(f32, 11), cx1.root.?.style.effectiveRadius());
    try std.testing.expectEqual(@as(f32, 11), cx2.root.?.style.effectiveRadius());
    try std.testing.expect(cx1.style_generation > 0 and cx1.style_generation == cx2.style_generation);
    try s.session.channel.submit(.{ .command = .query_style, .test_id = "lp2-target" });
    drain();
    const query = (try s.session.channel.poll(&response)).?;
    const parsed = try std.json.parseFromSlice(struct { corner_radius: f32 }, a, query, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqual(@as(f32, 11), parsed.value.corner_radius);
    const cx3 = try ui.Cx.init(a, std.testing.io);
    defer cx3.deinit();
    var third: TestHost = .{ .config = .{ .io = std.testing.io, .window = .{ .persist_key = "third" } }, .cx = cx3 };
    try attach(&third);
    defer detach(&third);
    try std.testing.expectEqual(@as(f32, 11), cx3.tokens.tokens.radius.panel);
    try std.testing.expectEqual(cx1.style_generation, cx3.style_generation);
    // A bad follow-up must keep both modes and generation intact while showing the overlay.
    const generation = cx1.style_generation;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "theme.json", .data = "{ invalid" });
    try s.session.channel.submit(.{ .command = .reload_styles, .files = &.{relative} });
    drain();
    const failed = (try s.session.channel.poll(&response)).?;
    try std.testing.expect(std.mem.indexOf(u8, failed, "\"result\":\"error\"") != null);
    try std.testing.expectEqual(generation, cx1.style_generation);
    try std.testing.expectEqual(@as(f32, 11), cx2.tokens.tokens.radius.panel);
    // Deletion is a shape fallback, even after a valid theme was prepared in
    // the same batch. No partial token commit or error overlay may occur.
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "theme.json", .data = edited });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "deleted.yss", .data = "style x { gap: 1; }" });
    try tmp.dir.deleteFile(std.testing.io, "deleted.yss");
    const deleted = try std.mem.replaceOwned(u8, a, relative, "theme.json", "deleted.yss");
    defer a.free(deleted);
    const retained = ui.theme_reload.retainedVersionCount();
    try s.session.channel.submit(.{ .command = .reload_styles, .files = &.{ relative, deleted } });
    drain();
    const missing = (try s.session.channel.poll(&response)).?;
    try std.testing.expect(std.mem.indexOf(u8, missing, "\"result\":\"fallback\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, missing, "source_deleted") != null);
    try std.testing.expectEqual(generation, cx1.style_generation);
    try std.testing.expectEqual(retained, ui.theme_reload.retainedVersionCount());
    // The runtime and launcher both accept this repository-default token path.
    try s.session.channel.submit(.{ .command = .reload_styles, .files = &.{"src/tokens/default.json"} });
    drain();
    const defaults = (try s.session.channel.poll(&response)).?;
    try std.testing.expect(std.mem.indexOf(u8, defaults, "\"result\":\"applied\"") != null);
    try std.testing.expectEqual(@as(f32, 8), cx1.tokens.tokens.radius.panel);
    try std.testing.expectEqual(retained + 1, ui.theme_reload.retainedVersionCount());
    const status = try health(s, a);
    defer a.free(status);
    const metrics = try std.json.parseFromSlice(struct { retained_token_versions: usize, retained_token_bytes: usize }, a, status, .{ .ignore_unknown_fields = true });
    defer metrics.deinit();
    try std.testing.expectEqual(ui.theme_reload.retainedVersionCount(), metrics.value.retained_token_versions);
    try std.testing.expectEqual(ui.theme_reload.retainedBytes(), metrics.value.retained_token_bytes);
}

test "preview LP2 custom theme identity survives attach and detach without reload" {
    // SKIP-REASON: dev-control runs only in -Ddev-preview=true builds (test-dev-control step).
    if (!enabled) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = std.testing.allocator;
    const root_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(root_path);
    const s = try testState(root_path);
    defer if (state != null) destroyState(s);
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    var custom = ui.theme.dark;
    custom.tokens.radius.panel = 123;
    cx.tokens = &custom;
    cx.root_scope = try ui.Scope.init(a, null, cx.owner);
    const theme_signal = try cx.themeSignal();
    var app: TestHost = .{ .config = .{ .io = std.testing.io, .window = .{ .persist_key = "custom" } }, .cx = cx };
    try attach(&app);
    defer detach(&app);
    try std.testing.expect(cx.tokens == &custom);
    try std.testing.expect(theme_signal.peek() == &custom);
    try std.testing.expectEqual(@as(f32, 123), cx.tokens.tokens.radius.panel);
    try std.testing.expect(!ui.theme_reload.owns(&custom));
    try std.testing.expect(ui.theme_reload.latestMode(custom.name) == null);
    detach(&app);
    try std.testing.expect(state == null);
    try std.testing.expect(cx.tokens == &custom);
    try std.testing.expect(theme_signal.peek() == &custom);
    try std.testing.expectEqual(@as(f32, 123), cx.tokens.tokens.radius.panel);
}

test "preview LP2 borrowed token versions survive collect until session teardown" {
    // SKIP-REASON: dev-control runs only in -Ddev-preview=true builds (test-dev-control step).
    if (!enabled) return error.SkipZigTest;
    const a = std.testing.allocator;
    defer ui.theme_reload.deinit();
    const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "src/tokens/default.json", a, .limited(8 * 1024 * 1024));
    defer a.free(source);
    const original = try ui.theme_reload.prepare(a, source);
    defer if (!original.committed) original.deinit();
    try std.testing.expect(original.result == .ready);
    original.commit();
    const borrowed = ui.theme_reload.latestMode("dark").?;
    const old_radius = borrowed.tokens.radius.panel;
    const edited = try std.mem.replaceOwned(u8, a, source, "\"panel\": 8", "\"panel\": 11");
    defer a.free(edited);
    const next = try ui.theme_reload.prepare(a, edited);
    defer if (!next.committed) next.deinit();
    try std.testing.expect(next.result == .ready);
    next.commit();
    ui.theme_reload.collect();
    try std.testing.expect(ui.theme_reload.owns(borrowed));
    try std.testing.expectEqual(old_radius, borrowed.tokens.radius.panel);
    const current = ui.theme_reload.latestMode("dark").?;
    try std.testing.expect(current != borrowed);
    try std.testing.expectEqual(@as(f32, 11), current.tokens.radius.panel);
    try std.testing.expect(ui.theme_reload.latestMode("not-a-provider-mode") == null);
}

test "preview LP2 allocation failure preserves the reload response envelope" {
    // SKIP-REASON: dev-control runs only in -Ddev-preview=true builds (test-dev-control step).
    if (!enabled) return error.SkipZigTest;
    var buf: [256]u8 = undefined;
    const parsed = try std.json.parseFromSlice(struct { result: []const u8, file: []const u8, line: usize, diagnostic: []const u8 }, std.testing.allocator, reloadFailure(&buf, error.OutOfMemory), .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("error", parsed.value.result);
    try std.testing.expectEqualStrings("<reload>", parsed.value.file);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.line);
    try std.testing.expect(std.mem.indexOf(u8, parsed.value.diagnostic, "OutOfMemory") != null);
    try std.testing.expect(std.mem.indexOf(u8, reloadFailure(&buf, error.Timeout), "\"result\":\"fallback\"") != null);
}

test "preview LP4 dev-control registration is absent until candidate commit" {
    // SKIP-REASON: the candidate queue and control registry require dev-preview=true.
    if (!enabled) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(path);
    const s = try testState(path);
    defer if (state != null) destroyState(s);
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const root = try ui.Scope.init(std.testing.allocator, null, cx.owner);
    defer root.dispose();
    const Model = struct {
        registered: bool = false,
        decodes: usize = 0,
        fn encode(_: *anyopaque, a: A) ![]u8 {
            return a.dupe(u8, "7");
        }
        fn decode(raw: *anyopaque, _: ?u32, _: ?[]const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.decodes += 1;
        }
        fn unregister(self: *@This()) void {
            if (self.registered) unpersist("lp4.registration") catch {};
        }
        fn register(self: *@This(), scope: *ui.Scope) !void {
            try scope.onCleanup(@This(), self, unregister);
            try persist("lp4.registration", 1, self, encode, decode);
            self.registered = true;
        }
    };
    const queue = ui.template_reload.mount_effects;
    for (0..3) |commit| {
        const scope = try root.childScope();
        var model: Model = .{};
        var tx = queue.Transaction.init(std.testing.allocator);
        defer tx.deinit();
        queue.current = &tx;
        defer queue.current = null;
        const ctx = .{ .model = &model, .scope = scope };
        const callback = struct {
            fn run(c: @TypeOf(ctx)) anyerror!void {
                try Model.register(c.model, c.scope);
            }
        }.run;
        try ui.view.runMountAction(scope, ctx, callback);
        if (commit == 2) try ui.view.runMountAction(scope, ctx, callback);
        try std.testing.expectEqual(@as(usize, 0), model.decodes);
        const before = try s.registry.capture(std.testing.allocator);
        defer std.testing.allocator.free(before);
        try std.testing.expectEqual(@as(usize, 0), before.len);
        queue.current = null;
        if (commit != 0) {
            if (commit == 2) try std.testing.expectError(error.DuplicatePersistKey, tx.run()) else try tx.run();
            try std.testing.expect(model.registered);
            try std.testing.expectEqual(@as(usize, 1), model.decodes);
            try std.testing.expectError(error.DuplicatePersistKey, persist("lp4.registration", 1, &model, Model.encode, Model.decode));
        }
        scope.dispose();
        const after = try s.registry.capture(std.testing.allocator);
        defer std.testing.allocator.free(after);
        try std.testing.expectEqual(@as(usize, 0), after.len);
    }
}

test "preview LP4 commit fallback uses only the reserved response buffer" {
    var buf: [384]u8 = undefined;
    const reply = templateFallbackInto(&buf, error.@"quoted\"reason");
    const parsed = try std.json.parseFromSlice(struct { result: []const u8, file: []const u8, reason: []const u8 }, std.testing.allocator, reply, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("fallback", parsed.value.result);
    try std.testing.expectEqualStrings("quoted\"reason", parsed.value.reason);
    var tiny: [0]u8 = .{};
    const exhausted = templateFallbackInto(&tiny, error.OutOfMemory);
    try std.testing.expect(std.mem.indexOf(u8, exhausted, "\"result\":\"fallback\"") != null);
}

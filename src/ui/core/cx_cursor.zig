//! Cx 光标：cursor lease（acquire/update/release/replay）、命中决策、
//! 自定义光标 / override / 自动化虚拟光标，以及最终 cursor shape 同步到平台。

const std = @import("std");
const core = @import("../core.zig");
const Cx = core.Cx;
const cx_render = @import("cx_render.zig");
const custom_cursor_mod = @import("custom_cursor.zig");
const svg_mod = @import("svg");
const CursorShape = core.CursorShape;
const CursorToken = core.CursorToken;
const CustomCursorDesc = core.CustomCursorDesc;
const Node = core.Node;
const cursor = core.cursor;
const cursorChangeDebugEnabled = debug_env.cursorChangeDebugEnabled;
const debug_env = @import("debug_env.zig");

fn pruneCursorLeases(self: *Cx) void {
    self.cursor_state.prune(&self.node_registry, self.dispatcher.pointer_capture_handle, self.dispatcher.pointer_capture_epoch);
}

pub fn acquireCursor(self: *Cx, owner: *Node, shape: CursorShape) !CursorToken {
    const handle = self.node_registry.handleFor(owner);
    const captured = self.dispatcher.pointer_capture_handle orelse return error.NoPointerCapture;
    if (!std.meta.eql(handle, captured) or self.node_registry.resolve(handle, null) != owner) return error.NoPointerCapture;
    pruneCursorLeases(self);
    const token = try self.cursor_state.acquire(self.allocator, handle, self.dispatcher.pointer_capture_epoch, shape);
    updateCursorShape(self);
    return token;
}

pub fn updateCursor(self: *Cx, token: CursorToken, shape: CursorShape) void {
    pruneCursorLeases(self);
    self.cursor_state.update(token, shape);
    updateCursorShape(self);
}

pub fn releaseCursor(self: *Cx, token: CursorToken) void {
    self.cursor_state.release(token);
    updateCursorShape(self);
}

pub fn refreshCursor(self: *Cx) void {
    cx_render.ensureHitTestSceneFresh(self);
    updateCursorShape(self);
}

pub fn replayCursor(self: *Cx) void {
    self.cursor_state.submitted = false;
    self.refreshCursor();
}

fn cursorDecisionAt(self: *Cx, x: f32, y: f32, spatial: bool) cursor.Decision {
    pruneCursorLeases(self);
    var decision = cursor.Decision{ .x = x, .y = y, .revision = self.cursor_state.decision.revision +% 1 };
    if (self.cursor_state.leases.items.len > 0) {
        const lease = self.cursor_state.leases.items[self.cursor_state.leases.items.len - 1];
        decision.shape = lease.shape;
        decision.source = .capture;
        decision.owner = lease.owner;
        decision.token = lease.token;
        return decision;
    }
    if (self.cursor_override) |shape| {
        decision.shape = shape;
        decision.source = .override;
        return decision;
    }
    if (!spatial or self.root == null) return decision;
    // Cursor queries never use capture routing or sticky-hover fallback.
    self.perf.cursor_hit_test_count += 1;
    const result = self.interaction_index.hitTestQuery(.{ .kind = .pointer, .world_x = x, .world_y = y }, &self.node_registry, null) orelse return decision;
    const leaf = self.node_registry.resolve(result.handle, null);
    var current = leaf;
    while (current) |node| : (current = node.parent) {
        if (node.cursor_query) |query| {
            if (query(node, x, y, node.cursor_query_context)) |region| {
                if (region.shape == .inherit) continue;
                decision.shape = region.shape;
                decision.source = .region;
                decision.owner = self.node_registry.handleFor(node);
                decision.region_id = region.id;
                return decision;
            }
        }
    }
    current = leaf;
    while (current) |node| : (current = node.parent) {
        if (node.style.cursor == .inherit) continue;
        decision.shape = node.style.cursor;
        decision.source = .style;
        decision.owner = self.node_registry.handleFor(node);
        return decision;
    }
    return decision;
}

pub fn setCursorOverride(self: *Cx, shape: ?CursorShape) void {
    if (self.cursor_override == shape) return;
    self.cursor_override = shape;
    updateCursorShape(self);
}

pub fn setCustomCursor(self: *Cx, desc: CustomCursorDesc) void {
    self.custom_cursor.set(self.allocator, desc, rasterizeCursorSvg);
    // store 只管缓存与 active 选择；下发是 Cx 的职责，必须在这里推一次，
    // 否则「shape 停在 .custom 期间换位图内容」不会重新下发到系统。
    updateCursorShape(self);
}

pub fn activeCustomCursorKey(self: *const Cx) ?u64 {
    return self.custom_cursor.activeKey();
}

pub fn updateAutomationCursor(self: *Cx, x: f32, y: f32, pressed: ?bool) void {
    cx_render.ensureHitTestSceneFresh(self);
    const resolved = cursorDecisionAt(self, x, y, true).shape;
    if (self.virtual_cursor.update(x, y, pressed, resolved, self.frame_time_ms)) {
        self.needs_redraw = true;
    }
}

/// Reconcile the committed hit scene and live capture leases, independently
/// of hover notifications. Presentation retries until the adapter accepts.
pub fn updateCursorShape(self: *Cx) void {
    if (self.cursor_state.reconciling) return;
    self.cursor_state.reconciling = true;
    defer self.cursor_state.reconciling = false;
    const previous_decision = self.cursor_state.decision;
    self.cursor_state.decision = cursorDecisionAt(self, self.mouse_x, self.mouse_y, self.cursor_state.pointer_valid);
    const decision_changed = previous_decision.shape != self.cursor_state.decision.shape or
        previous_decision.source != self.cursor_state.decision.source or
        !std.meta.eql(previous_decision.owner, self.cursor_state.decision.owner) or
        previous_decision.region_id != self.cursor_state.decision.region_id or
        !std.meta.eql(previous_decision.token, self.cursor_state.decision.token);
    if (decision_changed and cursorChangeDebugEnabled()) {
        const d = self.cursor_state.decision;
        std.debug.print("[cursor-decision] win={d} seq={d} xy=({d},{d}) source={s} owner={any} region={d} token={any} desired={s}\n", .{
            self.window_id, d.revision, d.x, d.y, @tagName(d.source), d.owner, d.region_id, d.token, @tagName(d.shape),
        });
    }
    const resolved = self.cursor_state.decision.shape;
    // .custom：解析到当前激活位图；未注册或后端不支持位图光标时
    // 降级到 custom_cursor_fallback（走固定形状路径）。
    var shape = resolved;
    var custom_key: ?u64 = null;
    if (resolved == .custom) {
        if (self.custom_cursor.activeKey()) |key| {
            var supported = false;
            if (self.system_sdk) |sdk| supported = sdk.customCursorSupported();
            if (supported) custom_key = key;
        }
        if (custom_key == null) shape = self.custom_cursor.fallback;
    }
    const shape_changed = shape != self.current_cursor;
    const custom_changed = custom_key != null and custom_key != self.custom_cursor.submitted;
    if (shape_changed or custom_changed or !self.cursor_state.submitted) {
        const old = self.current_cursor;
        self.current_cursor = shape;
        self.custom_cursor.submitted = custom_key;
        self.cursor_state.submitted = false;
        self.cursor_state.submission = .none;
        if (self.system_sdk) |sdk| {
            var accepted = true;
            // Failed submissions remain dirty and retry at the next
            // reconciliation, even when the logical shape is unchanged.
            if (custom_key) |key| {
                if (self.custom_cursor.entries.get(key)) |entry| {
                    sdk.setCustomCursor(self.window_id, .{
                        .rgba = entry.pixels,
                        .width = entry.width,
                        .height = entry.height,
                        .scale = entry.scale,
                        .hot_x = entry.hot_x,
                        .hot_y = entry.hot_y,
                        .key = key,
                    }) catch {
                        accepted = false;
                    };
                }
            } else {
                sdk.setCursorShape(self.window_id, @intFromEnum(shape)) catch {
                    accepted = false;
                };
            }
            self.cursor_state.submitted = accepted;
            self.cursor_state.submission = if (!accepted) .failed else if (shape == .uncontrolled) .handoff else .accepted;
        }
        if (cursorChangeDebugEnabled()) {
            var custom_buf: [24]u8 = undefined;
            const custom_suffix = if (custom_key) |key|
                std.fmt.bufPrint(&custom_buf, " custom=0x{x}", .{key}) catch ""
            else
                "";
            if (self.node_registry.resolve(self.cursor_state.decision.owner, null)) |hn| {
                std.debug.print("[cursor-change] {s} -> {s}{s} | hovered: id={d} comp={s} test_id={s} node_cursor={s}\n", .{
                    @tagName(old),
                    @tagName(shape),
                    custom_suffix,
                    hn.id,
                    hn.meta.ownership.meta.component_name orelse "(nil)",
                    hn.meta.ownership.meta.test_id orelse "(nil)",
                    @tagName(hn.style.cursor),
                });
            } else {
                std.debug.print("[cursor-change] {s} -> {s}{s} | hovered: null\n", .{
                    @tagName(old),
                    @tagName(shape),
                    custom_suffix,
                });
            }
        }
    }
}

/// 把 `svg.rasterize` 适配成 CustomCursorStore 要的注入签名。
fn rasterizeCursorSvg(
    allocator: std.mem.Allocator,
    svg_data: []const u8,
    target_width: u32,
) anyerror!custom_cursor_mod.CustomCursorStore.Raster {
    const img = try svg_mod.rasterize(allocator, svg_data, .{
        .target_width = target_width,
        .supersample = 2,
    });
    return .{ .width = img.width, .height = img.height, .pixels = img.pixels };
}

const std = @import("std");
const Allocator = std.mem.Allocator;

const events_mod = @import("../events.zig");
const types = @import("types.zig");
const node_mod = @import("node.zig");
const retained_scene = @import("retained_scene.zig");
const display_list_mod = @import("display_list.zig");
const paint_table_mod = @import("paint_table.zig");
const property_tree_mod = @import("property_tree.zig");
pub const debug_trace = @import("debug_trace.zig");

const Color = types.Color;
const ComputedRect = types.ComputedRect;
const Size = types.Size;
const TextSpan = types.TextSpan;
const Transform2D = types.Transform2D;
const KeyCode = events_mod.KeyCode;
const Modifiers = events_mod.Modifiers;
const Node = node_mod.Node;
const DisplayItem = display_list_mod.DisplayItem;
const ItemHeader = display_list_mod.ItemHeader;
const PaintItem = paint_table_mod.DisplayItem;
const PaintItemKind = paint_table_mod.DisplayItemKind;

/// Inspector overlay 写到 lowering.main (DisplayItem 流) 时的 header — 占位 INVALID。
const INSPECTOR_HEADER: ItemHeader = .{ .transform_id = property_tree_mod.INVALID_ID, .node_id = std.math.maxInt(u32) };

/// 把 fill_rect 写为 paint_table.DisplayItem 直接 append 到 main_paint
/// (encoder 主路径)。inspector overlay 不再依赖 union DisplayItem 中转。
///
/// 【OOM 策略】本文件下面三个 appendInspector* 的 `catch {}` 都是诊断路径：
/// inspector overlay 是**叠在真实界面之上的调试可视化**，不参与布局、命中、
/// 状态。append 失败只是少画一条调试框线，真实 UI 的正确性不受影响，故意吞掉
/// 分配失败而不是让调试工具把 app 拖崩。
fn appendInspectorFillRect(cx: anytype, x: f32, y: f32, w: f32, h: f32, color: Color, radius: [4]f32) void {
    const paint_color: paint_table_mod.RGBA = .{ .r = color.r, .g = color.g, .b = color.b, .a = color.a };
    _ = cx.lowering.main_paint.append(cx.allocator, .{
        .kind = .rect,
        .local_bounds = .{ .min_x = x, .min_y = y, .max_x = x + w, .max_y = y + h },
        .geom = .{ .x = x, .y = y, .w = w, .h = h },
        .color = paint_color,
        .radii = .{ .tl = radius[0], .tr = radius[1], .br = radius[2], .bl = radius[3] },
    }) catch {};
}

fn appendInspectorStrokeRect(cx: anytype, x: f32, y: f32, w: f32, h: f32, color: Color, radius: [4]f32, stroke_width: f32) void {
    const paint_color: paint_table_mod.RGBA = .{ .r = color.r, .g = color.g, .b = color.b, .a = color.a };
    _ = cx.lowering.main_paint.append(cx.allocator, .{
        .kind = .rect,
        .local_bounds = .{ .min_x = x, .min_y = y, .max_x = x + w, .max_y = y + h },
        .geom = .{ .x = x, .y = y, .w = w, .h = h },
        .color = paint_color,
        .radii = .{ .tl = radius[0], .tr = radius[1], .br = radius[2], .bl = radius[3] },
        .stroke_width = stroke_width,
    }) catch {};
}

fn appendInspectorTextRun(cx: anytype, x: f32, y: f32, content: []const u8, color: Color, font_size: f32, font_weight: u16, spans: ?[]const TextSpan) void {
    const paint_color: paint_table_mod.RGBA = .{ .r = color.r, .g = color.g, .b = color.b, .a = color.a };
    _ = cx.lowering.main_paint.append(cx.allocator, .{
        .kind = .text,
        .local_bounds = .{ .min_x = x, .min_y = y, .max_x = x + 1, .max_y = y + 1 },
        .geom = .{ .x = x, .y = y, .w = 0, .h = 0 },
        .color = paint_color,
        .text_font_size = font_size,
        .text_font_weight = font_weight,
        .text_content = content,
        .text_spans = spans,
    }) catch {};
}

/// Debug Paint 模式位域
pub const DebugPaintMode = struct {
    show_margins: bool = false,
    show_padding: bool = false,
    show_borders: bool = false,
    show_overflow_clip: bool = false,
    show_layout_islands: bool = false,

    pub fn anyActive(self: DebugPaintMode) bool {
        return self.show_margins or self.show_padding or self.show_borders or
            self.show_overflow_clip or self.show_layout_islands;
    }
};

pub const Inspector = struct {
    enabled: bool = false,
    /// pick 模式：点击 DevTools 的"选择元素"按钮后激活，
    /// hover 时高亮节点，点击后选中并自动退出 pick 模式（一次性）。
    pick_mode: bool = false,
    show_selected: bool = true,

    /// Debug Paint 布局调试可视化
    debug_paint: DebugPaintMode = .{},

    hover_node_id: ?u32 = null,
    selected_node_id: ?u32 = null,

    // 视觉样式
    hover_outline: Color = Color.rgba(90, 160, 255, 255),
    hover_fill: Color = Color.rgba(90, 160, 255, 40),
    selected_outline: Color = Color.rgba(255, 180, 0, 255),
    selected_fill: Color = Color.rgba(255, 180, 0, 40),
    label_bg: Color = Color.rgba(55, 55, 60, 240),
    label_tag_fg: Color = Color.rgba(150, 200, 255, 255), // tag 名：浅蓝
    label_id_fg: Color = Color.rgba(230, 175, 255, 255), // #id：浅紫
    label_dim_fg: Color = Color.rgba(180, 180, 185, 255), // 尺寸：浅灰
    label_font_size: f32 = 11,

    label_buf: [160]u8 = undefined,
    label_len: usize = 0,
    tag_buf: [32]u8 = undefined,
    tag_len: usize = 0,
    id_buf: [16]u8 = undefined,
    id_len: usize = 0,
    dim_buf: [64]u8 = undefined,
    dim_len: usize = 0,
    label_spans: [3]TextSpan = undefined,

    /// Debug trace store（按需堆分配，DevTools 关闭时为 null）
    trace_store: ?*debug_trace.DebugTraceStore = null,

    pub fn ensureTraceStore(self: *Inspector, allocator: Allocator) ?*debug_trace.DebugTraceStore {
        if (self.trace_store) |store| return store;
        const store = allocator.create(debug_trace.DebugTraceStore) catch return null;
        store.* = .{};
        self.trace_store = store;
        return store;
    }

    pub fn deinitTraceStore(self: *Inspector, allocator: Allocator) void {
        if (self.trace_store) |store| {
            allocator.destroy(store);
            self.trace_store = null;
            debug_trace.clearGlobalTraceTarget();
        }
    }

    pub fn handleMouseMove(self: *Inspector, cx: anytype, x: f32, y: f32) void {
        // 只在 pick 模式下 hover 高亮
        if (!self.enabled or !self.pick_mode) {
            self.hover_node_id = null;
            return;
        }
        if (cx.root != null) {
            const hit = cx.hitTestInspect(x, y);
            self.hover_node_id = if (hit) |node| node.id else null;
        } else {
            self.hover_node_id = null;
        }
    }

    /// 返回 true 表示拦截输入（不再派发到 UI）
    pub fn handleMouseDown(self: *Inspector, cx: anytype, x: f32, y: f32) bool {
        // 只在 pick 模式下拦截点击
        if (!self.enabled or !self.pick_mode) return false;
        // 坐标在视口外（如用户在 DevTools 窗口点击）→ 忽略，不消费 pick 模式
        if (x < 0 or y < 0 or x > cx.viewport.width or y > cx.viewport.height) return false;
        if (cx.root != null) {
            const hit = cx.hitTestInspect(x, y);
            if (hit) |node| {
                self.selected_node_id = node.id;
            } else {
                // 点击空白区域也消费 pick 模式（与 Chrome 一致）
                self.selected_node_id = null;
            }
        } else {
            self.selected_node_id = null;
        }
        // 选中后退出 pick 模式（一次性）
        self.pick_mode = false;
        self.hover_node_id = null;
        return true; // 拦截点击，不传递到应用
    }

    pub fn clearSelection(self: *Inspector) void {
        self.selected_node_id = null;
    }

    pub fn renderOverlay(self: *Inspector, cx: anytype) void {
        if (!self.enabled and !self.debug_paint.anyActive()) return;
        const root = cx.root orelse return;

        // Debug Paint: 布局调试可视化
        if (self.debug_paint.anyActive()) {
            self.renderDebugPaint(cx, root, Transform2D.identity());
        }
        if (!self.enabled) return;

        var hover_node: ?*Node = null;
        var selected_node: ?*Node = null;

        // pick 模式下才显示 hover 高亮
        if (self.pick_mode) {
            if (self.hover_node_id) |hid| {
                hover_node = findNodeById(root, hid);
            }
        }
        if (self.show_selected) {
            if (self.selected_node_id) |sid| {
                selected_node = findNodeById(root, sid);
                if (selected_node == null) self.selected_node_id = null;
            }
        }

        if (selected_node != null) {
            const rect = computeRenderRect(selected_node.?);
            appendHighlight(cx, rect, self.selected_fill, self.selected_outline, 2);
        }

        if (hover_node != null and hover_node != selected_node) {
            const rect = computeRenderRect(hover_node.?);
            appendHighlight(cx, rect, self.hover_fill, self.hover_outline, 1);
        }

        // 标签优先显示选中节点，否则 hover
        const label_node = if (selected_node) |s| s else hover_node;
        if (label_node) |node| {
            self.drawLabel(cx, node);
        }
    }

    fn drawLabel(self: *Inspector, cx: anytype, node: *Node) void {
        const rect = computeRenderRect(node);
        const tag_name = @tagName(node.tag);

        // 分段格式化到持久化 buffer（lowering_buffer 在帧末消费，局部变量会悬空）
        const tag_str = std.fmt.bufPrint(&self.tag_buf, "{s}", .{tag_name}) catch return;
        self.tag_len = tag_str.len;

        const id_str = std.fmt.bufPrint(&self.id_buf, " #{d}", .{node.id}) catch return;
        self.id_len = id_str.len;

        const dim_str = std.fmt.bufPrint(&self.dim_buf, "  {d:.0} x {d:.0}", .{ rect.w, rect.h }) catch return;
        self.dim_len = dim_str.len;

        const label_str = std.fmt.bufPrint(&self.label_buf, "{s}{s}{s}", .{ tag_str, id_str, dim_str }) catch return;
        self.label_len = label_str.len;

        const tag_end: u32 = @intCast(tag_str.len);
        const id_end: u32 = @intCast(tag_str.len + id_str.len);
        const label_end: u32 = @intCast(label_str.len);
        self.label_spans[0] = .{ .start = 0, .end = tag_end, .color = self.label_tag_fg };
        self.label_spans[1] = .{ .start = tag_end, .end = id_end, .color = self.label_id_fg };
        self.label_spans[2] = .{ .start = id_end, .end = label_end, .color = self.label_dim_fg };

        const font_size = self.label_font_size;
        const padding_x: f32 = 8;
        const padding_y: f32 = 4;
        const text_w = estimateTextWidth(label_str.len, font_size);
        const text_h = font_size * 1.2;

        var label_x = rect.x;
        const bg_w = text_w + padding_x * 2;
        const bg_h = text_h + padding_y * 2;

        // 水平方向：确保标签不超出视口右边
        if (label_x + bg_w > cx.viewport.width and cx.viewport.width > bg_w) {
            label_x = cx.viewport.width - bg_w;
        }
        if (label_x < 0) label_x = 0;

        // 垂直方向：优先放节点上方，放不下则放下方
        var label_y = rect.y - bg_h - 4;
        if (label_y < 0) {
            label_y = rect.y + rect.h + 4;
        }
        if (label_y + bg_h > cx.viewport.height) {
            label_y = rect.y + 2;
        }

        // 背景
        appendInspectorFillRect(cx, label_x, label_y, bg_w, bg_h, self.label_bg, .{ 4, 4, 4, 4 });

        const text_y = label_y + padding_y;
        appendInspectorTextRun(cx, label_x + padding_x, text_y, label_str, self.label_tag_fg, font_size, 500, self.label_spans[0..]);
    }

    /// Debug Paint: 递归遍历可见节点，渲染 margin/padding/border overlay
    fn renderDebugPaint(self: *Inspector, cx: anytype, node: *Node, parent_transform: Transform2D) void {
        const world_transform = retained_scene.buildNodeWorldTransform(node, parent_transform, .{ .include_rotation = true });
        // 全局 hook 读 rect。
        const r = node.rectFromWorldOrFallback();
        const world_rect = world_transform.transformRect(ComputedRect.init(0, 0, r.w, r.h));
        const x = world_rect.x;
        const y = world_rect.y;
        const w = world_rect.w;
        const h = world_rect.h;

        // 零尺寸只跳过自画，不能整棵 return：0 尺寸容器完全可以有
        // overflow-visible / absolute 定位的可见子节点。
        if (w <= 0 or h <= 0) {
            for (node.children.items) |child| {
                if (child.getOpacity() == 0) continue;
                self.renderDebugPaint(cx, child, world_transform);
            }
            return;
        }

        const sx = @abs(world_transform.a);
        const sy = @abs(world_transform.d);

        const margin_color = Color.rgba(255, 155, 0, 50); // 橙色 20% alpha
        const padding_color = Color.rgba(0, 200, 100, 40); // 绿色 15% alpha
        const border_color = Color.rgba(60, 120, 255, 180); // 蓝色边框
        const clip_color = Color.rgba(255, 40, 40, 120); // 红色 clip 边界
        const island_color = Color.rgba(200, 0, 255, 60); // 紫色 layout island

        // Margin overlay（四边各一个矩形，尺寸乘以缩放）
        if (self.debug_paint.show_margins) {
            const m = node.style.margin;
            const ml = m.left * sx;
            const mr = m.right * sx;
            const mt = m.top * sy;
            const mb = m.bottom * sy;
            if (mt > 0) appendInspectorFillRect(cx, x - ml, y - mt, w + ml + mr, mt, margin_color, .{ 0, 0, 0, 0 });
            if (mb > 0) appendInspectorFillRect(cx, x - ml, y + h, w + ml + mr, mb, margin_color, .{ 0, 0, 0, 0 });
            if (ml > 0) appendInspectorFillRect(cx, x - ml, y, ml, h, margin_color, .{ 0, 0, 0, 0 });
            if (mr > 0) appendInspectorFillRect(cx, x + w, y, mr, h, margin_color, .{ 0, 0, 0, 0 });
        }

        // Padding overlay
        if (self.debug_paint.show_padding) {
            const p = node.style.padding;
            const pl = p.left * sx;
            const pr = p.right * sx;
            const pt = p.top * sy;
            const pb = p.bottom * sy;
            if (pt > 0) appendInspectorFillRect(cx, x, y, w, pt, padding_color, .{ 0, 0, 0, 0 });
            if (pb > 0) appendInspectorFillRect(cx, x, y + h - pb, w, pb, padding_color, .{ 0, 0, 0, 0 });
            if (pl > 0) appendInspectorFillRect(cx, x, y + pt, pl, h - pt - pb, padding_color, .{ 0, 0, 0, 0 });
            if (pr > 0) appendInspectorFillRect(cx, x + w - pr, y + pt, pr, h - pt - pb, padding_color, .{ 0, 0, 0, 0 });
        }

        // Border outline
        const bws = node.style.border.resolvedWidths();
        if (self.debug_paint.show_borders and
            (bws[0] > 0 or bws[1] > 0 or bws[2] > 0 or bws[3] > 0))
        {
            appendHighlight(cx, ComputedRect.init(x, y, w, h), Color.TRANSPARENT, border_color, 1);
        }

        // Overflow clip boundary
        if (self.debug_paint.show_overflow_clip and node.style.overflow_hidden) {
            appendHighlight(cx, ComputedRect.init(x, y, w, h), Color.TRANSPARENT, clip_color, 2);
        }

        // Layout island marker
        if (self.debug_paint.show_layout_islands and node.style.layout_isolation) {
            appendInspectorFillRect(cx, x, y, w, h, island_color, .{ 0, 0, 0, 0 });
        }

        // Recurse children
        for (node.children.items) |child| {
            if (child.getOpacity() == 0) continue;
            self.renderDebugPaint(cx, child, world_transform);
        }
    }
};

fn appendHighlight(cx: anytype, rect: ComputedRect, fill_color: Color, outline: Color, border_width: f32) void {
    if (rect.w <= 0 or rect.h <= 0) return;
    appendInspectorFillRect(cx, rect.x, rect.y, rect.w, rect.h, fill_color, .{ 0, 0, 0, 0 });
    appendInspectorStrokeRect(cx, rect.x, rect.y, rect.w, rect.h, outline, .{ 0, 0, 0, 0 }, border_width);
}

fn computeRenderRect(node: *Node) ComputedRect {
    // 全变换 world rect：节点是被含完整变换的 hit-test 选中的，高亮必须用
    // 同一坐标口径 —— globalRect 只累计 translate，节点在 scaled/rotated
    // 子树里时（GlassBox interactive 微放大、transition 中途）高亮会脱位。
    return nodeWorldRect(node);
}

/// 含祖先 scale/rotate 的 world rect（renderDebugPaint 同款口径）。
/// 供 inspector 高亮与 devtools_overlay 共用。
pub fn nodeWorldRect(node: *Node) ComputedRect {
    const world = nodeWorldTransform(node);
    const r = node.rectFromWorldOrFallback();
    return world.transformRect(ComputedRect.init(0, 0, r.w, r.h));
}

fn nodeWorldTransform(node: *Node) Transform2D {
    const parent_t = if (node.parent) |p| nodeWorldTransform(p) else Transform2D.identity();
    return retained_scene.buildNodeWorldTransform(node, parent_t, .{ .include_rotation = true });
}

fn findNodeById(node: *Node, id: u32) ?*Node {
    if (node.id == id) return node;
    for (node.children.items) |child| {
        if (findNodeById(child, id)) |hit| return hit;
    }
    return null;
}

fn estimateTextWidth(chars: usize, font_size: f32) f32 {
    const c = @as(f32, @floatFromInt(chars));
    return c * font_size * 0.6;
}

pub fn isToggleShortcut(key: KeyCode, modifiers: Modifiers) bool {
    if (key != .i) return false;
    // macOS Chrome: Cmd + Option + I
    if (modifiers.super and modifiers.alt) return true;
    // Windows/Linux Chrome: Ctrl + Shift + I
    if (modifiers.ctrl and modifiers.shift) return true;
    return false;
}

test "inspector label renders as one spanned text command" {
    const allocator = std.testing.allocator;

    const root = try Node.create(allocator, 1, .box, .{});
    defer root.destroy(allocator);
    root.setLayoutRect(ComputedRect.init(0, 0, 400, 300));

    const child = try Node.create(allocator, 2, .box, .{});
    child.setLayoutRect(ComputedRect.init(16, 24, 180, 48));
    try root.appendChild(allocator, child);

    const FakeLowering = struct {
        main_paint: std.ArrayList(PaintItem) = .{},
    };
    const FakeCx = struct {
        allocator: std.mem.Allocator,
        viewport: Size,
        root: ?*Node,
        lowering: FakeLowering,
    };

    var cx = FakeCx{
        .allocator = allocator,
        .viewport = Size.init(400, 300),
        .root = root,
        .lowering = .{},
    };
    defer cx.lowering.main_paint.deinit(allocator);

    var inspector = Inspector{
        .enabled = true,
        .selected_node_id = child.id,
    };
    inspector.renderOverlay(&cx);

    // inspector 写 paint_table.DisplayItem 到 main_paint。
    // selected_node 输出: fill + stroke (highlight) + bg_fill + text_run = 4 items
    try std.testing.expectEqual(@as(usize, 4), cx.lowering.main_paint.items.len);

    const txt = cx.lowering.main_paint.items[3];
    try std.testing.expectEqual(PaintItemKind.text, txt.kind);
    try std.testing.expectEqualStrings("box #2  180 x 48", txt.text_content);
    try std.testing.expectEqual(@as(u16, 500), txt.text_font_weight);
    try std.testing.expect(txt.text_spans != null);

    const spans = txt.text_spans.?;
    try std.testing.expectEqual(@as(usize, 3), spans.len);
    try std.testing.expectEqual(@as(u32, 0), spans[0].start);
    try std.testing.expectEqual(@as(u32, 3), spans[0].end);
    try std.testing.expectEqual(inspector.label_tag_fg, spans[0].color.?);
    try std.testing.expectEqual(@as(u32, 3), spans[1].start);
    try std.testing.expectEqual(@as(u32, 6), spans[1].end);
    try std.testing.expectEqual(inspector.label_id_fg, spans[1].color.?);
    try std.testing.expectEqual(@as(u32, 6), spans[2].start);
    try std.testing.expectEqual(@as(u32, 16), spans[2].end);
    try std.testing.expectEqual(inspector.label_dim_fg, spans[2].color.?);
}

/// tree_serializer — Node 树 → JSON 序列化
///
/// 递归遍历 UI Node 树，输出 JSON 结构供 AI Agent 读取。
/// (zenit v0.5 适配：用 meta.ownership.meta.test_id / behavior.interaction.focusable /
/// visuals.content.text / frame_state.rect 路径)
const std = @import("std");
const ui = @import("ui");
const Node = ui.Node;
const ComputedRect = ui.ComputedRect;
const JsonWriter = @import("json_writer.zig").JsonWriter;
const OverlayStack = @FieldType(ui.Cx, "overlay_stack");

const MAX_DEPTH = 20;

// ── zenit v0.5 字段访问 helper ──

inline fn nodeTestId(node: *const Node) ?[]const u8 {
    return node.meta.ownership.meta.test_id;
}

inline fn nodeComponentName(node: *const Node) ?[]const u8 {
    return node.meta.ownership.meta.component_name;
}

inline fn nodeFocusable(node: *const Node) bool {
    return node.behavior.interaction.focusable;
}

inline fn nodeText(node: *const Node) ?ui.TextProps {
    return node.getText();
}

inline fn nodeRect(node: *const Node) ComputedRect {
    return node.rectFromWorldOrFallback();
}

fn writeColorRgba(jw: *JsonWriter, color: ui.Color) void {
    var buf: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d},{d},{d},{d}", .{ color.r, color.g, color.b, color.a }) catch return;
    jw.stringValue(text);
}

/// 序列化整棵 Node 树到 JSON buffer。
/// `overlays`：所属 Cx 的浮层栈，用于把挂起层里的节点计作不可见（见 effectiveOpacity）。
pub fn serializeTree(root: *Node, overlays: ?*const OverlayStack, buf: []u8) error{TreeTooLarge}![]const u8 {
    var jw = JsonWriter.init(buf);
    serializeNode(&jw, root, overlays, 0);
    if (jw.hasOverflowed()) return error.TreeTooLarge;
    return jw.getWritten();
}

/// 按 test_id 查找节点，返回匹配列表的 JSON
pub fn queryByTestId(root: *Node, overlays: ?*const OverlayStack, test_id: []const u8, buf: []u8) error{TreeTooLarge}![]const u8 {
    var jw = JsonWriter.init(buf);
    jw.beginArray();
    queryByTestIdRecursive(&jw, root, overlays, test_id, 0);
    jw.endArray();
    if (jw.hasOverflowed()) return error.TreeTooLarge;
    return jw.getWritten();
}

/// 按 test_id 查找单个节点，返回其指针
pub fn findByTestId(root: *Node, test_id: []const u8) ?*Node {
    return findByTestIdRecursive(root, test_id, 0);
}

fn findByTestIdRecursive(node: *Node, test_id: []const u8, depth: usize) ?*Node {
    if (depth > MAX_DEPTH) return null;
    if (nodeTestId(node)) |tid| {
        if (std.mem.eql(u8, tid, test_id)) return node;
    }
    const children = node.children.items;
    for (children) |child| {
        if (findByTestIdRecursive(child, test_id, depth + 1)) |found| {
            return found;
        }
    }
    return null;
}

fn queryByTestIdRecursive(jw: *JsonWriter, node: *Node, overlays: ?*const OverlayStack, test_id: []const u8, depth: usize) void {
    if (depth > MAX_DEPTH) return;
    if (nodeTestId(node)) |tid| {
        if (std.mem.eql(u8, tid, test_id)) {
            serializeNode(jw, node, overlays, 0);
        }
    }
    const children = node.children.items;
    for (children) |child| {
        queryByTestIdRecursive(jw, child, overlays, test_id, depth + 1);
    }
}

/// 精简版布局摘要：只输出有 test_id/component_name/text 或 focusable 的节点
pub fn serializeLayout(root: *Node, buf: []u8) []const u8 {
    var jw = JsonWriter.init(buf);
    jw.beginArray();
    serializeLayoutRecursive(&jw, root, 0, 0);
    jw.endArray();
    return jw.getWritten();
}

fn isInterestingNode(node: *Node) bool {
    if (nodeTestId(node) != null) return true;
    if (nodeComponentName(node) != null) return true;
    if (nodeFocusable(node)) return true;
    if (nodeText(node)) |t| {
        if (t.content.len > 0) return true;
    }
    return false;
}

fn serializeLayoutRecursive(jw: *JsonWriter, node: *Node, depth: usize, indent: usize) void {
    if (depth > MAX_DEPTH) return;
    const rect = nodeRect(node);
    if (rect.w <= 0 or rect.h <= 0 or node.getOpacity() == 0) return;

    if (isInterestingNode(node)) {
        const global = node.globalRect();
        jw.beginObject();
        if (nodeTestId(node)) |tid| {
            jw.key("test_id");
            jw.stringValue(tid);
        }
        if (nodeComponentName(node)) |cn| {
            jw.key("component");
            jw.stringValue(cn);
        }
        jw.key("tag");
        jw.stringValue(@tagName(node.tag));
        jw.key("rect");
        jw.beginObject();
        jw.key("x");
        jw.floatValue(global.x);
        jw.key("y");
        jw.floatValue(global.y);
        jw.key("w");
        jw.floatValue(global.w);
        jw.key("h");
        jw.floatValue(global.h);
        jw.endObject();
        if (nodeFocusable(node)) {
            jw.key("focusable");
            jw.booleanValue(true);
        }
        if (nodeText(node)) |t| {
            if (t.content.len > 0) {
                jw.key("text");
                const tlen = @min(t.content.len, 100);
                jw.stringValue(t.content[0..tlen]);
                if (t.font_size != 14) {
                    jw.key("font_size");
                    jw.floatValue(t.font_size);
                }
                if (t.font_weight != 400) {
                    jw.key("font_weight");
                    jw.numberValue(@intCast(t.font_weight));
                }
                if (t.use_italic_font) {
                    jw.key("italic");
                    jw.booleanValue(true);
                }
            }
        }
        if (node.getOpacity() != 1.0) {
            jw.key("opacity");
            jw.floatValue(node.getOpacity());
        }
        if (node.style.translate_x != 0 or node.style.translate_y != 0) {
            jw.key("translate_x");
            jw.floatValue(node.style.translate_x);
            jw.key("translate_y");
            jw.floatValue(node.style.translate_y);
        }
        if (node.getBackground().a > 0) {
            jw.key("has_bg");
            jw.booleanValue(true);
            jw.key("bg_rgba");
            writeColorRgba(jw, node.getBackground());
        }
        if (node.children.items.len > 0) {
            jw.key("children_count");
            jw.numberValue(@intCast(node.children.items.len));
        }
        jw.key("depth");
        jw.numberValue(@intCast(indent));
        jw.endObject();
    }

    const children = node.children.items;
    for (children) |child| {
        serializeLayoutRecursive(jw, child, depth + 1, indent + 1);
    }
}

/// 有效不透明度：自身 × 所有祖先 opacity，以下情形直接计 0（节点不呈现）：
/// - 自身或祖先 display:none；
/// - 落在挂起（已关闭）浮层的 content / barrier 子树里 —— Modal 关闭时只把 barrier
///   缩成 0×0 + overflow_hidden + 层挂起，dialog 及祖先 opacity 仍是 1；
/// - 自身或祖先 overflow_hidden 且盒子退化到 0 宽/高 —— 渲染侧同判据整棵跳过
///   （render_engine/tick.zig 的 `overflow_hidden and w/h <= 0.1`），裁剪对
///   absolute / z_index 子节点同样生效（只有 portal 能逃出）。
fn effectiveOpacity(node: *Node, overlays: ?*const OverlayStack) f32 {
    if (overlays) |stack| {
        if (stack.isNodeInSuspendedLayer(node)) return 0;
    }
    var o: f32 = 1;
    var cur: ?*Node = node;
    while (cur) |n| : (cur = n.parent) {
        if (n.style.display == .none) return 0;
        if (n.style.overflow_hidden) {
            const r = nodeRect(n);
            if (r.w <= 0.1 or r.h <= 0.1) return 0;
        }
        o *= n.getOpacity();
    }
    return o;
}

fn serializeNode(jw: *JsonWriter, node: *Node, overlays: ?*const OverlayStack, depth: usize) void {
    if (depth > MAX_DEPTH) {
        jw.null_();
        return;
    }

    const global = node.globalRect();
    jw.beginObject();

    jw.key("id");
    jw.numberValue(@intCast(node.id));

    jw.key("tag");
    jw.stringValue(@tagName(node.tag));

    if (nodeTestId(node)) |tid| {
        jw.key("test_id");
        jw.stringValue(tid);
    }

    if (nodeComponentName(node)) |cn| {
        jw.key("component");
        jw.stringValue(cn);
    }

    // display:none（节点仍在树上但不呈现）：查询方据此排除不可见内容。
    if (node.style.display == .none) {
        jw.key("hidden");
        jw.booleanValue(true);
    }

    // 查询命中的顶层节点附带"有效不透明度"（自身 × 所有祖先；display:none 计 0）：
    // 浮层淡入等过渡挂在祖先上时，测试据此等"真正完全可见"，而不是 sleep 猜时长。
    if (depth == 0) {
        jw.key("effective_opacity");
        jw.floatValue(effectiveOpacity(node, overlays));
    }

    jw.key("rect");
    jw.beginObject();
    jw.key("x");
    jw.floatValue(global.x);
    jw.key("y");
    jw.floatValue(global.y);
    jw.key("w");
    jw.floatValue(global.w);
    jw.key("h");
    jw.floatValue(global.h);
    jw.endObject();

    if (nodeText(node)) |t| {
        if (t.content.len > 0) {
            jw.key("text");
            if (t.content.len > 200) {
                jw.stringValue(t.content[0..200]);
            } else {
                jw.stringValue(t.content);
            }
        }
    }

    if (node.getOpacity() != 1.0) {
        jw.key("opacity");
        jw.floatValue(node.getOpacity());
    }
    if (node.style.translate_x != 0 or node.style.translate_y != 0) {
        jw.key("translate_x");
        jw.floatValue(node.style.translate_x);
        jw.key("translate_y");
        jw.floatValue(node.style.translate_y);
    }
    if (@abs(node.style.rotate()) > 0.0001) {
        jw.key("rotate");
        jw.floatValue(node.style.rotate());
    }

    if (nodeFocusable(node)) {
        jw.key("focusable");
        jw.booleanValue(true);
    }

    const rect = nodeRect(node);
    const visible = rect.w > 0 and rect.h > 0 and node.getOpacity() != 0;
    if (!visible) {
        jw.key("visible");
        jw.booleanValue(false);
    }

    const children = node.children.items;
    if (children.len > 0) {
        jw.key("children");
        jw.beginArray();
        // 全量输出：曾经每层只输出前 50 个子节点（长列表后半段"查不到"，客户端从不
        // 处理 truncated 标记 —— 静默丢失）。体积由调用方缓冲兜底，溢出显式报错。
        for (children) |child| {
            serializeNode(jw, child, overlays, depth + 1);
        }
        jw.endArray();
    }

    jw.endObject();
}

// ── 测试 ──

const testing = std.testing;

fn queryEffectiveOpacity(root: *Node, overlays: ?*const OverlayStack, test_id: []const u8) !f64 {
    var buf: [256 * 1024]u8 = undefined;
    const json = try queryByTestId(root, overlays, test_id, &buf);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    const items = parsed.value.array.items;
    try testing.expectEqual(@as(usize, 1), items.len);
    const v = items[0].object.get("effective_opacity") orelse return error.TestUnexpectedResult;
    return switch (v) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => error.TestUnexpectedResult,
    };
}

fn pumpFrames(ctx: *ui.Cx, n: usize) void {
    for (0..n) |_| {
        ctx.frame_time_ms += 16;
        ctx.layout();
        _ = ctx.render();
    }
}

test "effective_opacity: 关闭的 Modal 内容计 0，打开后计 1，关回去再计 0" {
    const allocator = testing.allocator;
    var ctx = try ui.Cx.init(allocator);
    defer ctx.deinit();
    ctx.setViewport(800, 600);
    const root = try ui.box(ctx, .{ .width = .{ .px = 800 }, .height = .{ .px = 600 } }, .{});
    ctx.root = root;
    const scope = try ui.Scope.init(allocator, null, ctx.owner);
    defer scope.dispose();
    const vis = try ctx.createSignal(bool, false);
    const result = try ui.widgets.Modal(.{ .title = "Probe" }).visible(vis).mount(scope, ctx);
    if (!result.portaled) try root.appendChild(allocator, result.overlay);
    result.dialog.meta.ownership.meta.test_id = "probe.dialog";

    // 初始关闭：barrier 0×0 + 层挂起，但 dialog 自身及祖先 opacity 全是 1。
    pumpFrames(ctx, 3);
    try testing.expectEqual(@as(f64, 0), try queryEffectiveOpacity(root, &ctx.overlay_stack, "probe.dialog"));

    vis.set(true);
    pumpFrames(ctx, 60);
    try testing.expectApproxEqAbs(@as(f64, 1), try queryEffectiveOpacity(root, &ctx.overlay_stack, "probe.dialog"), 0.001);

    vis.set(false);
    pumpFrames(ctx, 60);
    try testing.expectEqual(@as(f64, 0), try queryEffectiveOpacity(root, &ctx.overlay_stack, "probe.dialog"));
}

test "effective_opacity: 挂起层里的节点计 0（与几何无关）" {
    const allocator = testing.allocator;
    var stack = OverlayStack{};
    const handle = try stack.push(.{ .kind = .non_modal, .enter_transition = .none, .exit_transition = .none });
    const content = try Node.create(allocator, 901, .box, .{ .width = .{ .px = 120 }, .height = .{ .px = 60 } });
    defer content.destroy(allocator);
    const child = try Node.create(allocator, 902, .box, .{ .width = .{ .px = 80 }, .height = .{ .px = 24 } });
    try content.appendChild(allocator, child);
    stack.bindFloatingContent(allocator, handle, content);

    try testing.expectEqual(@as(f32, 1), effectiveOpacity(child, &stack));
    // 只挂起、不动 opacity / 尺寸：仍须计 0。
    stack.findLayer(handle).?.suspended = true;
    try testing.expectEqual(@as(f32, 0), effectiveOpacity(child, &stack));
    try testing.expectEqual(@as(f32, 0), effectiveOpacity(content, &stack));
    // 不传浮层栈时退化为纯节点判定。
    try testing.expectEqual(@as(f32, 1), effectiveOpacity(child, null));
}

test "effective_opacity: 0×0 的 overflow_hidden 祖先把子树计 0" {
    const allocator = testing.allocator;
    var ctx = try ui.Cx.init(allocator);
    defer ctx.deinit();
    ctx.setViewport(400, 300);
    const root = try ui.box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;
    const clipper = try ui.box(ctx, .{ .width = .{ .px = 0 }, .height = .{ .px = 0 } }, .{});
    clipper.style.overflow_hidden = true;
    try root.appendChild(allocator, clipper);
    const leaf = try ui.box(ctx, .{ .width = .{ .px = 50 }, .height = .{ .px = 20 } }, .{});
    try clipper.appendChild(allocator, leaf);
    pumpFrames(ctx, 1);
    try testing.expectEqual(@as(f32, 0), effectiveOpacity(leaf, null));

    // 对照：同样 0×0 但不裁剪 —— 子节点照常溢出可见。
    clipper.style.overflow_hidden = false;
    clipper.markRenderDirty();
    pumpFrames(ctx, 1);
    try testing.expectEqual(@as(f32, 1), effectiveOpacity(leaf, null));
}

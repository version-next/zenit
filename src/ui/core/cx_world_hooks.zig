//! 进程级 Node → World 路由钩子：Node 的 content / paint / layout-output / rect
//! 读写与 dirty / structure 通知经这里转发到当前 active World（SoA 表）。
//! Cx.init 注册这些回调并维护 g_active_world*；多 Cx 并存时用 Cx.createNode
//! 显式归属，不依赖这里的全局。

const core = @import("../core.zig");
const Cx = core.Cx;
const ComputedRect = core.ComputedRect;
const ElementTag = core.ElementTag;
const Node = core.Node;
const Style = core.Style;
const core_node = @import("node.zig");
const core_types = @import("types.zig");
const cx_world_sync = @import("cx_world_sync.zig");
const layout_table = core.layout_table;
const world = core.world;

/// 当前 active World（v0.2-P3 全局静态；v0.3 per-Cx）
pub var g_active_world: ?*world.World = null;

/// 当前 active World 的 id —— 与 g_active_world 同步维护，
/// onNodeCreate 用它给 Node.world_id 盖章。
pub var g_active_world_id: u16 = core_node.INVALID_WORLD_ID;

/// 单调递增的 World id 分配器。每个 Cx 拿一个唯一 id（不复用 —— 复用会让
/// 已释放 Cx 的陈旧 Node 与新 Cx 假匹配，正是本字段要防的问题）。
pub var g_next_world_id: u16 = 0;

pub fn onPaintBackgroundWrite(element_id_raw: u32, c: core_types.Color) void {
    const w = g_active_world orelse return;
    if (element_id_raw == 0xFFFFFFFF) return;
    const eid = world.ElementId.fromRaw(element_id_raw);
    w.paint_state.ensureSlot(eid) catch return;
    w.paint_state.setBackground(eid, c);
}

pub fn onPaintOpacityWrite(element_id_raw: u32, o: f32) void {
    const w = g_active_world orelse return;
    if (element_id_raw == 0xFFFFFFFF) return;
    const eid = world.ElementId.fromRaw(element_id_raw);
    w.paint_state.ensureSlot(eid) catch return;
    w.paint_state.setOpacity(eid, o);
}

pub fn onPaintBackgroundRead(element_id_raw: u32) ?core_types.Color {
    const w = g_active_world orelse return null;
    if (element_id_raw == 0xFFFFFFFF) return null;
    const eid = world.ElementId.fromRaw(element_id_raw);
    return (w.paint_state.get(eid) orelse return null).background;
}

pub fn onPaintOpacityRead(element_id_raw: u32) ?f32 {
    const w = g_active_world orelse return null;
    if (element_id_raw == 0xFFFFFFFF) return null;
    const eid = world.ElementId.fromRaw(element_id_raw);
    return (w.paint_state.get(eid) orelse return null).opacity;
}

/// 镜像 Node.setLayoutOutput 写到 World.layout_output。
pub fn onLayoutOutputWrite(element_id_raw: u32, v: core_node.NodeLayoutOutput) void {
    const w = g_active_world orelse return;
    if (element_id_raw == 0xFFFFFFFF) return;
    const eid = world.ElementId.fromRaw(element_id_raw);
    w.layout_output.ensureSlot(eid) catch return;
    w.layout_output.set(eid, v);
}

pub fn onLayoutOutputRead(element_id_raw: u32) ?core_node.NodeLayoutOutput {
    const w = g_active_world orelse return null;
    if (element_id_raw == 0xFFFFFFFF) return null;
    const eid = world.ElementId.fromRaw(element_id_raw);
    return w.layout_output.get(eid);
}

pub fn onLayoutOutputPtr(element_id_raw: u32) ?*core_node.NodeLayoutOutput {
    const w = g_active_world orelse return null;
    if (element_id_raw == 0xFFFFFFFF) return null;
    const eid = world.ElementId.fromRaw(element_id_raw);
    w.layout_output.ensureSlot(eid) catch return null;
    return w.layout_output.getPtr(eid);
}

/// 镜像 Node.setText 写到 World.content (ContentTable)。
/// element_id_raw == 0xFFFFFFFF 的 standalone Node 暂不镜像（fallback storage 留 stage 2）。
pub fn onContentTextWrite(element_id_raw: u32, t: ?core_types.TextProps) void {
    const w = g_active_world orelse return;
    if (element_id_raw == 0xFFFFFFFF) return;
    const eid = world.ElementId.fromRaw(element_id_raw);
    w.content.ensureSlot(eid) catch return;
    w.content.setText(eid, t);
}

pub fn onContentImageWrite(element_id_raw: u32, img: ?core_types.ImageProps) void {
    const w = g_active_world orelse return;
    if (element_id_raw == 0xFFFFFFFF) return;
    const eid = world.ElementId.fromRaw(element_id_raw);
    w.content.ensureSlot(eid) catch return;
    w.content.setImage(eid, img);
}

pub fn onContentIconWrite(element_id_raw: u32, ic: ?core_types.IconProps) void {
    const w = g_active_world orelse return;
    if (element_id_raw == 0xFFFFFFFF) return;
    const eid = world.ElementId.fromRaw(element_id_raw);
    w.content.ensureSlot(eid) catch return;
    w.content.setIcon(eid, ic);
}

// read 端 — Node.getText/getImage/getIcon 从 World.content 拿值。
pub fn onContentTextRead(element_id_raw: u32) ?core_types.TextProps {
    const w = g_active_world orelse return null;
    if (element_id_raw == 0xFFFFFFFF) return null;
    const eid = world.ElementId.fromRaw(element_id_raw);
    return w.content.getText(eid);
}

pub fn onContentImageRead(element_id_raw: u32) ?core_types.ImageProps {
    const w = g_active_world orelse return null;
    if (element_id_raw == 0xFFFFFFFF) return null;
    const eid = world.ElementId.fromRaw(element_id_raw);
    if (w.content.get(eid)) |c| return c.image;
    return null;
}

pub fn onContentIconRead(element_id_raw: u32) ?core_types.IconProps {
    const w = g_active_world orelse return null;
    if (element_id_raw == 0xFFFFFFFF) return null;
    const eid = world.ElementId.fromRaw(element_id_raw);
    if (w.content.get(eid)) |c| return c.icon;
    return null;
}

/// v0.5-P3 N-2 (2026-05-03): Node.create hook，自动注册新 node 到 active World。
/// 让所有 Node.create 路径（包括 test mock）都有 element_id，
/// setLayoutRect 真写 World，frame_state.rect fallback 字段不再被消费。
pub fn onNodeCreate(node: *Node) void {
    const w = g_active_world orelse return;
    if (node.element_id_raw != 0xFFFFFFFF) return;
    const eid = w.createElement(.{
        .tag = cx_world_sync.nodeTagToWorldTag(node.tag),
        .key = node.id,
    }) catch return;
    node.element_id_raw = eid.raw();
    // 同时记下 owner —— element_id 本身不含 World 标识（两个 World 都从
    // index 0 分配），只有这个字段能区分"窗口 A 的 0x8"和"窗口 B 的 0x8"。
    node.world_id = g_active_world_id;
    node.world_ref = w;
}

/// 组件 paint 期 setLayoutRect 的 World 同步。
/// 写入 LayoutTable 让"自己改 rect"的子节点（cursor / selection / 等）也
/// 透明走 World 表，read path 命中 World 而非 fallback。
pub fn onRectWrite(element_id_raw: u32, r: ComputedRect) void {
    const w = g_active_world orelse return;
    if (element_id_raw == 0xFFFFFFFF) return;
    const eid = world.ElementId.fromRaw(element_id_raw);
    w.layout.ensureSlot(eid) catch return;
    const lr: layout_table.Rect = .{ .x = r.x, .y = r.y, .width = r.w, .height = r.h };
    w.layout.markLaidOut(eid, .{ .width = r.w, .height = r.h }, lr);
}

/// v0.5-P3 Stage 4-2 (session 27): 全局 rect 查询，给不带 cx 的 fn 用。
pub fn onRectQuery(element_id_raw: u32) ?ComputedRect {
    const w = g_active_world orelse return null;
    if (element_id_raw == 0xFFFFFFFF) return null;
    const eid = world.ElementId.fromRaw(element_id_raw);
    // Stage 4-2 关键：World.createElement 自动 seed layout slot（默认全 0），
    // 所以 layout.rect() 几乎总返回 Some。我们必须靠 epoch == 0 来识别"slot
    // 存在但还没 markLaidOut" 的情况，回退到 node.rect。否则手动 `node.rect =`
    // 的测试 + Stage 4-2 切换会读到 0。
    if (w.layout.epoch(eid) == 0) return null;
    if (w.layout.rect(eid)) |r| {
        return ComputedRect.init(r.x, r.y, r.width, r.height);
    }
    return null;
}

pub fn createNode(self: *Cx, tag: ElementTag, style: Style) !*Node {
    return core_node.createIn(self.allocator, &self.world, self.world_id, self.nextId(), tag, style);
}

pub fn nodeBelongsToActiveWorldForTest(node: *const Node) bool {
    return nodeBelongsToActiveWorld(node);
}

/// 校验：node 是否属于当前 active World。
/// 返回 false 意味着**跨 Cx 串台** —— 拿 A 窗口的节点去改 B 窗口的 World。
/// world_id == INVALID 的节点是 cx-less mock（测试直接 Node.create），
/// 它们本就走 standalone fallback，不参与 World 路由，放行。
pub fn nodeBelongsToActiveWorld(node: *const Node) bool {
    if (node.world_id == core_node.INVALID_WORLD_ID) return true;
    return node.world_id == g_active_world_id;
}

pub fn onNodeDirty(element_id_raw: u32, kind: core_node.DirtyKind) void {
    const w = g_active_world orelse return;
    if (element_id_raw == 0xFFFFFFFF) return;
    const eid = world.ElementId.fromRaw(element_id_raw);
    const flags: world.DirtyFlags = switch (kind) {
        .layout => .{ .input = .{ .geometry_changed = true } },
        .style => .{ .input = .{ .style_changed = true } },
        .structure => .{ .input = .{ .structure_changed = true } },
        .interaction => .{ .input = .{ .interaction_changed = true } },
    };
    w.markDirty(eid, flags) catch {}; // OOM 容错——dirty 丢一次 frame 仍跑旧路径
}

/// Node.appendChild / unlink 时同步 World.elements 父子链表。
/// 任一端 element_id_raw == 0xFFFFFFFF 即为旧路径节点，hook 直接 return（旧路径仍跑）。
pub fn onNodeStructure(parent_raw: u32, child_raw: u32, kind: core_node.StructureKind) void {
    const w = g_active_world orelse return;
    if (parent_raw == 0xFFFFFFFF or child_raw == 0xFFFFFFFF) return;
    const parent_eid = world.ElementId.fromRaw(parent_raw);
    const child_eid = world.ElementId.fromRaw(child_raw);
    if (!w.elements.isValid(parent_eid) or !w.elements.isValid(child_eid)) return;
    switch (kind) {
        .append => {
            // 如果 child 已有 parent（reparent 场景），先 unlink。
            const existing = w.elements.links(child_eid) orelse return;
            if (!existing.parent.isNull()) w.elements.unlink(child_eid);
            w.elements.appendChild(parent_eid, child_eid);
        },
        .unlink => w.elements.unlink(child_eid),
    }
}

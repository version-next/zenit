//! World — Phase 3 拆 Node 后的统一根容器
//!
//! 取代当前 Cx 内嵌的多个 owned 字段（lowering_buffer、display_list、scene_runtime、
//! property_tree、compositor_plan 等都散落在 Cx）。新的 World 把所有跨帧保留的
//! 数据结构聚拢，并按 ElementId 索引。
//!
//! 当前 Phase 3 阶段：World 是**新的 source of truth 的容器壳子**——结构就位，
//! 但 Cx 仍保留旧 Node 路径（4 examples 不挂）。Phase 4 起渐进迁移：
//!   - paint pass 改写 PaintTable
//!   - layout pass 改写 LayoutTable
//!   - 旧 Node 字段成为 World 的 view（getter/setter 委托）
//!
//! 4 个表 + property tree + reactive graph + dirty set，构成完整保留态。
//!
//! 历史债避免：
//! - 不让任何成员持有"父级 World 指针"——传 *World 给操作；避免 retain cycle
//! - dirty set 在此层做"全局 dirty queue"，子系统只 push 到集合，不递归 push
//!   （吸取 Chromium cc 历史："single layer hierarchy" 18 布尔状态混乱教训）

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const element_id_mod = @import("element_id.zig");
const element_table_mod = @import("element_table.zig");
const layout_table_mod = @import("layout_table.zig");
const paint_table_mod = @import("paint_table.zig");
const interaction_table_mod = @import("interaction_table.zig");
const dirty_flags_mod = @import("dirty_flags.zig");
const content_table_mod = @import("content_table.zig");
const paint_state_table_mod = @import("paint_state_table.zig");
const layout_output_table_mod = @import("layout_output_table.zig");

// 注意：World 不持有 ReactiveGraph。reactive 是 *状态端* 数据；World 是 *渲染端* 数据。
// 两者通过 dirty_set 通信：reactive effect 调 world.markDirty(id, flags)，渲染管线
// 在 begin_frame 后消费 dirty_set。这种解耦避免 world.deinit 时与 reactive
// 生命周期纠缠，也让 World 更易做单测。

pub const ElementId = element_id_mod.ElementId;
pub const Element = element_table_mod.Element;
pub const ElementTable = element_table_mod.ElementTable;
pub const ElementTag = element_table_mod.ElementTag;
pub const LayoutTable = layout_table_mod.LayoutTable;
pub const PaintTable = paint_table_mod.PaintTable;
pub const InteractionTable = interaction_table_mod.InteractionTable;
pub const InteractionData = interaction_table_mod.InteractionData;
pub const DirtyFlags = dirty_flags_mod.DirtyFlags;
pub const ContentTable = content_table_mod.ContentTable;
pub const ContentData = content_table_mod.ContentData;
pub const PaintStateTable = paint_state_table_mod.PaintStateTable;
pub const PaintStateData = paint_state_table_mod.PaintStateData;
pub const LayoutOutputTable = layout_output_table_mod.LayoutOutputTable;

/// DevTools 样式来源。地址指向：
/// - styled：具名样式函数入口；
/// - inline_builder / set_style：调用点附近的返回地址。
///
/// 这里只存代码地址，不在热路径解析 DWARF；用户点 DevTools 的跳转按钮时才
/// 由 source_link 做符号化。Release 去掉 debug info 后解析自然降级为无结果。
pub const StyleOriginKind = enum(u8) {
    inline_builder,
    styled,
    set_style,
};

pub const StyleOrigin = struct {
    address: usize,
    kind: StyleOriginKind,
};

const NodeStyleOrigins = struct {
    /// boxStyled/textStyled 或 inline builder 的公共来源。
    base: ?StyleOrigin = null,
    /// base 实际声明了哪些 StyleField；bit index = @intFromEnum(StyleField)。
    base_fields: u64 = 0,
    /// setStyle 的逐字段 last-writer 覆盖。绝大多数节点为空，不分配。
    field_overrides: std.AutoHashMapUnmanaged(u8, StyleOrigin) = .{},

    fn deinit(self: *NodeStyleOrigins, allocator: std.mem.Allocator) void {
        self.field_overrides.deinit(allocator);
        self.* = undefined;
    }
};

pub const World = struct {
    allocator: std.mem.Allocator,
    elements: ElementTable,
    layout: LayoutTable,
    paint: PaintTable,
    interaction: InteractionTable,
    /// NodeContent SoA mirror（双写期；stage 3 才成 source of truth）
    content: ContentTable,
    /// PaintState SoA mirror (background + opacity 等 paint 字段)
    paint_state: PaintStateTable,
    /// NodeLayoutOutput SoA mirror (vector + artifacts；双写期)
    layout_output: LayoutOutputTable,
    /// dirty set：本帧待处理；end_frame 时按阶段消费
    dirty_set: std.AutoHashMapUnmanaged(u32, DirtyFlags),
    /// DevTools-only 稀疏来源表。Node 本体不为 50+ 个 StyleField 扩容；只有
    /// styled/被 setStyle 修改过的节点才占一个条目。
    style_origins: std.AutoHashMapUnmanaged(u32, NodeStyleOrigins),

    pub fn init(allocator: std.mem.Allocator) World {
        return .{
            .allocator = allocator,
            .elements = ElementTable.init(allocator),
            .layout = LayoutTable.init(allocator),
            .paint = PaintTable.init(allocator),
            .interaction = InteractionTable.init(allocator),
            .content = ContentTable.init(allocator),
            .paint_state = PaintStateTable.init(allocator),
            .layout_output = LayoutOutputTable.init(allocator),
            .dirty_set = .{},
            .style_origins = .{},
        };
    }

    pub fn deinit(self: *World) void {
        var origin_it = self.style_origins.valueIterator();
        while (origin_it.next()) |origins| origins.deinit(self.allocator);
        self.style_origins.deinit(self.allocator);
        self.dirty_set.deinit(self.allocator);
        self.layout_output.deinit();
        self.paint_state.deinit();
        self.content.deinit();
        self.interaction.deinit();
        self.paint.deinit();
        self.layout.deinit();
        self.elements.deinit();
        self.* = undefined;
    }

    /// 创建一个 element，并同步在 layout/paint/content/paint_state 表里分配 slot。
    pub fn createElement(self: *World, e: Element) !ElementId {
        const id = try self.elements.create(e);
        errdefer self.destroyElement(id);
        try self.layout.ensureSlot(id);
        try self.paint.ensureSlot(id);
        try self.content.ensureSlot(id);
        try self.paint_state.ensureSlot(id);
        try self.layout_output.ensureSlot(id);
        // element slot 可能是从 free_list 复用的旧 slot（generation++）。content
        // 镜像表按 index 存、不校验 generation，ensureSlot 对已存在的 slot 直接
        // return 不清，于是复用 slot 会残留上一个 owner 的 text → 新节点 getText
        // 读到旧内容（典型：Menu 弹层项 "Cut/Copy/Delete" 漏进新挂载的 DatePicker
        // trigger → content 串台/空白）。destroyElement 已在销毁侧 clear，但裸
        // elements.destroy / Node.destroy 路径绕过它，故在分配侧也清 content 双保险。
        // 注：不清 layout_output —— 那是布局 source of truth，清了会让 mount 后首个
        // 未经 layout 的 query 读到 0 rect。content 由节点紧接着 setText 覆盖，安全。
        self.content.clear(id);
        return id;
    }

    /// 销毁 element 并清理所有 dirty 标记（不递归子树——caller 决定）。
    pub fn destroyElement(self: *World, id: ElementId) void {
        if (!self.elements.isValid(id)) return;
        self.clearStyleOrigins(id.raw());
        self.elements.destroy(id);
        _ = self.interaction.remove(id);
        _ = self.dirty_set.remove(id.raw());
        self.content.clear(id);
        self.paint_state.clear(id);
        self.layout_output.clear(id); // v0.10-§L stage 1: 非 owning 镜像，clear 不 free path
        self.layout.clear(id);
        // paint chunk 必须清内容（释放 display_items + 归零 hash/epoch/property_state），
        // 否则 slot 复用 + hash 撞车时 beginRecord 吐旧 owner 的显示项（见 release 注释）。
        self.paint.release(id);
        // layout / paint 槽不立即回收（保持 dense by index；空 slot 占少量内存）。
    }

    /// 记录声明式/inline builder 的公共来源及它实际设置的字段。
    /// DevTools 是诊断能力；OOM 时丢一条来源，不能拖垮目标应用。
    pub fn recordStyleBase(self: *World, element_raw: u32, fields: u64, origin: StyleOrigin) void {
        if (builtin.strip_debug_info) return;
        if (element_raw == 0xFFFFFFFF or origin.address == 0 or fields == 0) return;
        const gop = self.style_origins.getOrPut(self.allocator, element_raw) catch return;
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.base = origin;
        gop.value_ptr.base_fields = fields;
    }

    /// 记录 setStyle 的逐字段 last-writer。
    pub fn recordStyleField(self: *World, element_raw: u32, field_index: u8, origin: StyleOrigin) void {
        if (builtin.strip_debug_info) return;
        if (element_raw == 0xFFFFFFFF or origin.address == 0) return;
        const gop = self.style_origins.getOrPut(self.allocator, element_raw) catch return;
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.field_overrides.put(self.allocator, field_index, origin) catch {};
    }

    /// 查逐字段覆盖，未覆盖时仅在 base 确实声明过该字段的情况下回退 base。
    /// field_index=null 用于 TextStyle.line_height 等尚未进入 StyleField 的属性。
    pub fn styleOrigin(self: *const World, element_raw: u32, field_index: ?u8) ?StyleOrigin {
        const origins = self.style_origins.get(element_raw) orelse return null;
        if (field_index) |index| {
            if (origins.field_overrides.get(index)) |origin| return origin;
            if (index >= 64) return null;
            if ((origins.base_fields & (@as(u64, 1) << @intCast(index))) == 0) return null;
        }
        return origins.base;
    }

    pub fn clearStyleOrigins(self: *World, element_raw: u32) void {
        const removed = self.style_origins.fetchRemove(element_raw) orelse return;
        var origins = removed.value;
        origins.deinit(self.allocator);
    }

    /// 标记 element 脏。flag 通过 union 合并到现有条目。
    pub fn markDirty(self: *World, id: ElementId, flags: DirtyFlags) !void {
        if (id.isNull()) return;
        const gop = try self.dirty_set.getOrPut(self.allocator, id.raw());
        if (!gop.found_existing) {
            gop.value_ptr.* = flags;
        } else {
            gop.value_ptr.input = gop.value_ptr.input.unionWith(flags.input);
            gop.value_ptr.output = gop.value_ptr.output.unionWith(flags.output);
            gop.value_ptr.subtree = gop.value_ptr.subtree.unionWith(flags.subtree);
        }
    }

    pub fn dirtyCount(self: *const World) usize {
        return self.dirty_set.count();
    }

    /// 帧开始：清 dirty set（消费方已处理）。
    /// PropertyTree 的 beginFrameRetained 由 Cx.property_tree 主路径调用，World 不再
    /// 持有副本（v0.5-P3 stage 1 去重，2026-04-30）。
    pub fn beginFrame(self: *World) void {
        self.dirty_set.clearRetainingCapacity();
    }
};

// ============================================================================
// Tests
// ============================================================================

test "World: init/deinit" {
    var w = World.init(testing.allocator);
    defer w.deinit();
    try testing.expectEqual(@as(usize, 0), w.elements.count());
    try testing.expectEqual(@as(usize, 0), w.dirtyCount());
}

test "World: createElement allocates slots in all dense tables" {
    var w = World.init(testing.allocator);
    defer w.deinit();

    const id = try w.createElement(.{ .tag = .container, .key = 1 });
    try testing.expect(w.elements.isValid(id));
    // layout / paint 已分配
    try testing.expect(w.layout.get(id) != null);
    try testing.expect(w.paint.get(id) != null);
    // interaction 是 sparse，未自动分配
    try testing.expect(w.interaction.get(id) == null);
}

test "World: style origins use base declarations with per-field last-writer overrides" {
    var w = World.init(testing.allocator);
    defer w.deinit();

    const element_raw: u32 = 0x0100002A;
    const padding_index: u8 = 2;
    const gap_index: u8 = 7;
    w.recordStyleBase(element_raw, @as(u64, 1) << padding_index, .{
        .address = 0x1111,
        .kind = .styled,
    });

    try testing.expectEqual(@as(usize, 0x1111), w.styleOrigin(element_raw, padding_index).?.address);
    try testing.expect(w.styleOrigin(element_raw, gap_index) == null);

    w.recordStyleField(element_raw, gap_index, .{
        .address = 0x2222,
        .kind = .set_style,
    });
    const override = w.styleOrigin(element_raw, gap_index).?;
    try testing.expectEqual(@as(usize, 0x2222), override.address);
    try testing.expectEqual(StyleOriginKind.set_style, override.kind);

    w.clearStyleOrigins(element_raw);
    try testing.expect(w.styleOrigin(element_raw, padding_index) == null);
}

test "World: markDirty unions flags" {
    var w = World.init(testing.allocator);
    defer w.deinit();

    const id = try w.createElement(.{ .tag = .container, .key = 0 });

    try w.markDirty(id, .{ .input = .{ .style_changed = true } });
    try w.markDirty(id, .{ .input = .{ .geometry_changed = true } });

    const got = w.dirty_set.get(id.raw()).?;
    try testing.expect(got.input.style_changed);
    try testing.expect(got.input.geometry_changed);
}

test "World: destroyElement removes dirty entry + interaction" {
    var w = World.init(testing.allocator);
    defer w.deinit();

    const id = try w.createElement(.{ .tag = .container, .key = 0 });
    try w.interaction.put(id, .{ .tab_index = 5 });
    try w.markDirty(id, .{ .input = .{ .style_changed = true } });

    w.destroyElement(id);
    try testing.expect(w.interaction.get(id) == null);
    try testing.expect(w.dirty_set.get(id.raw()) == null);
}

test "World: destroyElement 清 paint chunk —— slot 复用 + hash 撞车不得吐旧显示项" {
    var w = World.init(testing.allocator);
    defer w.deinit();

    const id = try w.createElement(.{ .tag = .container, .key = 0 });
    // 录制一份显示项（hash=42）
    try testing.expect(try w.paint.beginRecord(id, 42));
    try w.paint.pushItem(id, .{ .kind = .rect, .local_bounds = .{ .min_x = 0, .min_y = 0, .max_x = 10, .max_y = 10 } });
    w.paint.endRecord(id, .NONE);
    try testing.expectEqual(@as(usize, 1), w.paint.get(id).?.display_items.items.len);

    w.destroyElement(id);

    // 复用同一 slot（LIFO free list），新 owner 的 content_hash 恰好撞上旧值：
    // beginRecord 必须真的重录（返回 true），不得 cache-hit 吐旧 owner 的显示项
    const id2 = try w.createElement(.{ .tag = .container, .key = 1 });
    try testing.expectEqual(id.index, id2.index); // 前提：slot 真的被复用
    try testing.expect(try w.paint.beginRecord(id2, 42));
    try testing.expectEqual(@as(usize, 0), w.paint.get(id2).?.display_items.items.len);
    // property_state 也必须归零——全表扫描按 idx 消费它
    try testing.expectEqual(paint_table_mod.PropertyStateRef.NONE, w.paint.get(id2).?.property_state);
}

test "World: destroyElement clears LayoutTable before slot reuse" {
    var w = World.init(testing.allocator);
    defer w.deinit();

    const id = try w.createElement(.{ .tag = .container, .key = 0 });
    w.layout.markLaidOut(id, .{ .width = 80, .height = 40 }, .{ .x = 12, .y = 34, .width = 80, .height = 40 });
    try testing.expect(w.layout.epoch(id) != 0);
    w.destroyElement(id);

    const reused = try w.createElement(.{ .tag = .container, .key = 1 });
    try testing.expectEqual(id.index, reused.index);
    try testing.expectEqual(layout_table_mod.Rect.ZERO, w.layout.rect(reused).?);
    try testing.expectEqual(@as(u64, 0), w.layout.epoch(reused));
}

test "World: beginFrame clears dirty" {
    var w = World.init(testing.allocator);
    defer w.deinit();

    const id = try w.createElement(.{ .tag = .container, .key = 0 });
    try w.markDirty(id, .{ .input = .{ .style_changed = true } });
    try testing.expectEqual(@as(usize, 1), w.dirtyCount());

    w.beginFrame();
    try testing.expectEqual(@as(usize, 0), w.dirtyCount());
}

test "World: combined element creation + tree linking" {
    var w = World.init(testing.allocator);
    defer w.deinit();

    const root = try w.createElement(.{ .tag = .container, .key = 0 });
    const c1 = try w.createElement(.{ .tag = .text, .key = 1 });
    const c2 = try w.createElement(.{ .tag = .text, .key = 2 });

    w.elements.appendChild(root, c1);
    w.elements.appendChild(root, c2);

    try testing.expectEqual(@as(u32, 2), w.elements.childCount(root));
}

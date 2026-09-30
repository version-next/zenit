/// Property Trees — Transform / Clip / Effect / Scroll 的保留式数据结构。
///
/// 设计参照 Chromium RenderingNG 的 4 棵 property tree：
///   transform / clip / effect / scroll
/// （https://developer.chrome.com/docs/chromium/renderingng-data-structures）
///
/// Phase 2 目标：4 棵齐全 + 跨帧保留（通过 epoch 跟踪节点改动而非每帧 clear）。
/// 当前向后兼容 `clear()` API；新代码使用 `beginFrameRetained()` 路径。
const std = @import("std");
const types = @import("types.zig");
const display_list_mod = @import("display_list.zig");

const Allocator = std.mem.Allocator;
const Transform2D = types.Transform2D;
const ComputedRect = types.ComputedRect;

/// 无效 ID 哨兵值（表示无父节点 / 无关联）
pub const INVALID_ID: u32 = std.math.maxInt(u32);

// =========== Transform Tree ===========

pub const TransformFlags = packed struct(u8) {
    is_axis_aligned: bool = true,
    is_integer_translation: bool = false,
    has_animation: bool = false,
    has_translation: bool = false,
    has_scale: bool = false,
    has_rotation: bool = false,
    _padding: u2 = 0,
};

pub const TransformNode = struct {
    /// 父节点在 transforms 数组中的索引（root 节点 parent = 0 自引用）
    parent: u32,
    /// 对应 UI Node.id
    node_id: u32,
    /// 本节点局部变换
    local: Transform2D,
    /// 累积世界变换 (parent.world × local)
    world: Transform2D,
    /// world 的逆矩阵（用于 hit-test / 坐标反算）
    inverse_world: Transform2D,
    /// Stage B S5.2: display_list ItemHeader.transform_id 指向此 transform 时
    /// 用于 lower 的"内容空间"变换。
    /// - 顶层节点：content == world（与 paint pass 等价）
    /// - surface (opacity layer / scale layer 等) 内 child：
    ///   content == inverse_layer_world * world，即在 surface-local 坐标系下
    ///   叠加 child 自身 transform。这样 lower 出来的 DisplayItem 与 paint
    ///   pass subtree replay (inverse_replay_base * world) 字节等价。
    /// - 默认值 == world（无 surface 时不需要区分）
    content: Transform2D,
    flags: TransformFlags = .{},
};

// =========== Clip Tree ===========

pub const ClipNode = struct {
    /// 该 clip 来自 tag==.scroll 的容器(ScrollArea/VirtualList)。
    /// effect(玻璃/opacity 层)内部只发射这类 clip —— 全量发射会把
    /// Input 等小 clip 以错误投影裁没(placeholder 文字消失,实测)。
    from_scroll: bool = false,
    /// 父 clip 节点索引（INVALID_ID = 无父裁剪）
    parent: u32,
    /// 关联的 transform 节点索引
    transform_id: u32,
    /// 对应 UI Node.id
    node_id: u32,
    /// 本节点局部空间的裁剪矩形
    local_rect: ComputedRect,
    /// 世界空间 AABB
    world_aabb: ComputedRect,
    /// Render runtime 侧实际消费的 clip 形状。
    shape_kind: display_list_mod.ClipShapeKind = .rect,
    radius: f32 = 0,
    polygon: display_list_mod.ClipPolygon = .{},
    /// true 表示当前只是用 bounds 做保守退化，不是精确 shape clip。
    bounds_fallback: bool = false,
    /// CSS overflow 语义：clip 只裁 owner（`node_id`）的**后代**，owner 自己的
    /// shadow / background / border 不受自身 clip 约束（它们本来就画在 border-box
    /// 上甚至之外——阴影被自身 overflow clip 裁成矩形，圆角外露出方形灰块）。
    /// 外部裁剪（external_clip_rects：宿主声明"本节点受此矩形裁剪"）要裁 owner
    /// 本身，此时为 false。lowering 在 item.node_id == node_id 时跳过本层。
    owner_content_exempt: bool = false,
    /// owner 有画在 children clip 之外的自身内容（阴影 / outline / 可见描边），
    /// 本 clip 只能以 children 包围的 node-local push_clip 实现（render_engine
    /// emitScrollClipBegin）。effect owner 的 compositor apply_clip 因此不取本层
    /// 而取父 clip（apply_clip 在 begin_layer 后立即 push，会裁到 owner 自身）。
    owner_wraps_children: bool = false,
};

// =========== Effect Tree ===========

pub const EffectKind = enum(u8) {
    opacity,
    composited_group,
    backdrop_blur,
    rounded_clip,
};

pub const EffectNode = struct {
    /// 父 effect 节点索引（INVALID_ID = 无父效果）
    parent: u32,
    /// 关联的 transform 节点索引
    transform_id: u32,
    /// 对应 UI Node.id
    node_id: u32,
    kind: EffectKind,
    opacity: f32 = 1.0,
    /// 非 normal 时合成走 W3C blend（仅 opacity/composited_group kind 消费）。
    blend_mode: types.BlendMode = .normal,
    /// 液态玻璃效果参数（GPU 就绪格式）
    glass: types.ResolvedGlassParams = .{},
    corner_radius: [4]f32 = .{ 0, 0, 0, 0 },
    requires_offscreen: bool = false,
    /// 效果影响的局部区域
    local_bounds: ComputedRect,
};

// =========== Scroll Tree (Phase 2 新增；对齐 Chromium RenderingNG) ===========

/// Scroll 节点 —— 用于复合层位移而非内容重画。
/// 每个 overflow:scroll/auto 容器对应一个 ScrollNode；动画 / 拖拽时仅更新
/// `scroll_offset`，下游 layer transform 由此 offset 应用，paint chunk 不变。
pub const ScrollNode = struct {
    /// 父 scroll 节点索引（INVALID_ID = root）
    parent: u32,
    /// 关联的 transform 节点索引
    transform_id: u32,
    /// 对应 UI Node.id
    node_id: u32,
    /// 当前滚动偏移（正值表示内容向左/上移动，等同视口向右/下）
    scroll_offset: types.Point = .{ .x = 0, .y = 0 },
    /// 内容尺寸（可滚动的总区域）
    content_size: types.Size = types.Size.ZERO,
    /// 视口尺寸（可见区域）
    viewport_size: types.Size = types.Size.ZERO,
    /// 当前帧是否处于滚动动画中（用于 layer 提升决策）
    is_scrolling: bool = false,
};

// =========== PropertyTree 容器 ===========

/// 节点改动 epoch —— 跨帧保留模式下，调用方可以读这个值决定 layer 是否需要重建。
pub const NodeEpoch = u64;

pub const PropertyTree = struct {
    allocator: Allocator,
    transforms: std.ArrayList(TransformNode),
    clips: std.ArrayList(ClipNode),
    effects: std.ArrayList(EffectNode),
    /// Phase 2: scroll 树
    scrolls: std.ArrayList(ScrollNode),

    /// 跨帧保留模式状态。`current_epoch` 在每次 beginFrameRetained 时 ++，
    /// caller 通过比对消费方记录的 epoch 判断是否需要重新读取节点。
    current_epoch: NodeEpoch = 0,
    /// 上一次树结构变化（增/删节点）所在的 epoch；layer cache 据此判失效。
    last_structural_change: NodeEpoch = 0,
    /// 是否启用跨帧保留模式。false（默认）= 旧的"每帧 clear" 路径，向后兼容。
    /// Phase 4 layer tree 上线后切到 true。
    retained_mode: bool = false,

    pub fn init(allocator: Allocator) PropertyTree {
        return .{
            .allocator = allocator,
            .transforms = .{},
            .clips = .{},
            .effects = .{},
            .scrolls = .{},
        };
    }

    pub fn deinit(self: *PropertyTree) void {
        self.transforms.deinit(self.allocator);
        self.clips.deinit(self.allocator);
        self.effects.deinit(self.allocator);
        self.scrolls.deinit(self.allocator);
    }

    /// 旧路径：每帧清空。等 Phase 4 layer tree 接入后，render_engine 改调
    /// beginFrameRetained()，此函数仅作过渡兼容存在。
    pub fn clear(self: *PropertyTree) void {
        self.transforms.clearRetainingCapacity();
        self.clips.clearRetainingCapacity();
        self.effects.clearRetainingCapacity();
        self.scrolls.clearRetainingCapacity();
        // 在非 retained 模式下，每次 clear 视作"全树重建"，等同结构变化
        if (!self.retained_mode) {
            self.current_epoch +%= 1;
            self.last_structural_change = self.current_epoch;
        }
    }

    /// 跨帧保留模式：开始一帧。不清空节点，只前进 epoch。
    /// 调用方负责对真正变更的节点用 mutateXxx 系列 API 推进 last_structural_change。
    pub fn beginFrameRetained(self: *PropertyTree) void {
        self.retained_mode = true;
        self.current_epoch +%= 1;
    }

    /// 通知 PropertyTree 发生了拓扑变化（增删节点），让消费方失效缓存。
    pub fn markStructuralChange(self: *PropertyTree) void {
        self.last_structural_change = self.current_epoch;
    }

    /// 追加 transform 节点，返回其索引
    pub fn appendTransform(self: *PropertyTree, node: TransformNode) !u32 {
        const id: u32 = @intCast(self.transforms.items.len);
        try self.transforms.append(self.allocator, node);
        if (self.retained_mode) self.markStructuralChange();
        return id;
    }

    /// 追加 clip 节点，返回其索引
    pub fn appendClip(self: *PropertyTree, node: ClipNode) !u32 {
        const id: u32 = @intCast(self.clips.items.len);
        try self.clips.append(self.allocator, node);
        if (self.retained_mode) self.markStructuralChange();
        return id;
    }

    /// 追加 effect 节点，返回其索引
    pub fn appendEffect(self: *PropertyTree, node: EffectNode) !u32 {
        const id: u32 = @intCast(self.effects.items.len);
        try self.effects.append(self.allocator, node);
        if (self.retained_mode) self.markStructuralChange();
        return id;
    }

    /// 追加 scroll 节点，返回其索引
    pub fn appendScroll(self: *PropertyTree, node: ScrollNode) !u32 {
        const id: u32 = @intCast(self.scrolls.items.len);
        try self.scrolls.append(self.allocator, node);
        if (self.retained_mode) self.markStructuralChange();
        return id;
    }

    /// 更新 scroll offset（动画/拖拽热路径）。**不**触发结构变化 epoch，
    /// 只是 in-place 修改；layer 据此应用平移而无需重 paint。
    pub fn updateScrollOffset(self: *PropertyTree, scroll_id: u32, offset: types.Point) void {
        if (scroll_id >= self.scrolls.items.len) return;
        self.scrolls.items[scroll_id].scroll_offset = offset;
    }
};

// =========== Tests ===========

const testing = std.testing;

test "PropertyTree: 4 trees including scroll" {
    var pt = PropertyTree.init(testing.allocator);
    defer pt.deinit();

    _ = try pt.appendTransform(.{
        .parent = INVALID_ID,
        .node_id = 1,
        .local = Transform2D.identity(),
        .world = Transform2D.identity(),
        .inverse_world = Transform2D.identity(),
        .content = Transform2D.identity(),
    });
    _ = try pt.appendClip(.{
        .parent = INVALID_ID,
        .transform_id = 0,
        .node_id = 1,
        .local_rect = .{ .x = 0, .y = 0, .w = 100, .h = 100 },
        .world_aabb = .{ .x = 0, .y = 0, .w = 100, .h = 100 },
    });
    _ = try pt.appendEffect(.{
        .parent = INVALID_ID,
        .transform_id = 0,
        .node_id = 1,
        .kind = .opacity,
        .opacity = 0.5,
        .local_bounds = .{ .x = 0, .y = 0, .w = 100, .h = 100 },
    });
    const scroll_id = try pt.appendScroll(.{
        .parent = INVALID_ID,
        .transform_id = 0,
        .node_id = 1,
        .content_size = .{ .width = 1000, .height = 5000 },
        .viewport_size = .{ .width = 1000, .height = 800 },
    });

    try testing.expectEqual(@as(u32, 0), scroll_id);
    try testing.expectEqual(@as(usize, 1), pt.scrolls.items.len);
}

test "PropertyTree: updateScrollOffset does not change structure epoch" {
    var pt = PropertyTree.init(testing.allocator);
    defer pt.deinit();
    pt.beginFrameRetained();
    const epoch_before_create = pt.current_epoch;

    _ = try pt.appendScroll(.{
        .parent = INVALID_ID,
        .transform_id = 0,
        .node_id = 1,
        .content_size = .{ .width = 1000, .height = 5000 },
        .viewport_size = .{ .width = 1000, .height = 800 },
    });
    // 创建节点是结构变化
    try testing.expect(pt.last_structural_change >= epoch_before_create);

    // 推进帧
    pt.beginFrameRetained();
    const epoch_at_anim = pt.current_epoch;
    const struct_at_anim = pt.last_structural_change;

    // 动画期间只改 offset
    pt.updateScrollOffset(0, .{ .x = 0, .y = 100 });
    pt.updateScrollOffset(0, .{ .x = 0, .y = 200 });

    // 结构 epoch 没变 —— layer 缓存可继续命中
    try testing.expectEqual(struct_at_anim, pt.last_structural_change);
    try testing.expectEqual(epoch_at_anim, pt.current_epoch);

    // 但 offset 真的更新了
    try testing.expectEqual(@as(f32, 200), pt.scrolls.items[0].scroll_offset.y);
}

test "PropertyTree: clear in legacy mode bumps structural epoch" {
    var pt = PropertyTree.init(testing.allocator);
    defer pt.deinit();
    // legacy mode（默认）
    const before = pt.last_structural_change;
    pt.clear();
    try testing.expect(pt.last_structural_change != before);
}

test "PropertyTree: appendTransform in retained mode marks structural change" {
    var pt = PropertyTree.init(testing.allocator);
    defer pt.deinit();
    pt.beginFrameRetained();
    const struct_before = pt.last_structural_change;

    _ = try pt.appendTransform(.{
        .parent = INVALID_ID,
        .node_id = 1,
        .local = Transform2D.identity(),
        .world = Transform2D.identity(),
        .inverse_world = Transform2D.identity(),
        .content = Transform2D.identity(),
    });

    try testing.expect(pt.last_structural_change > struct_before);
}

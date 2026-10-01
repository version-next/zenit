//! LayerTree，保留式合成层（retained plan，2026-07-21 落地）
//!
//! plan layer 按 (root_node_id, effect_kind) 键控跨帧持久（plan_by_node）：
//! planAppendLayer 命中时原地更新 per-frame descriptor 并保留 surface_valid，
//! planClear 只清 ops/ordinal 索引，退场由 planBuildFromPropertyTree 末尾的
//! plan_epoch sweep 销毁。**跨帧身份 = CompositedLayer.stable_id**（LayerId
//! packed raw，generation 提供 ABA 防护）；layer_id 是帧内序号，仅供本帧
//! ops/planMark* API 使用，任何跨帧比较必须走 stable_id。
//! 内容级跨帧缓存载体仍是 Node 侧命令缓存（caches.commands.promoted），
//! surface_valid 由 canReusePromotedSurface（stable_id+content_version+transform）
//! 逐帧推导。
//!
//! 设计参照：
//! - Chromium cc::LayerImpl + PaintArtifactCompositor::LayerizeGroup
//! - Flutter Layer / EngineLayer
//! - WebKit GraphicsLayer
//!
//! 历史债避免：
//! - **不**让 Layer 同时承载几何 + 内容 + 合成语义（cc::Layer 早期 18 布尔状态教训）
//!   -> Layer 只持 (gpu_texture_handle, transform_id, clip_id, effect_id, scroll_id, paint_chunks)
//! - **不**用线性扫描查 layer by id（zenit 现有 CompositorPlan O(N·M) 教训）
//!   -> AutoHashMap by layer_id；遍历用 layers ArrayList
//! - **不**为每个 paint chunk 创一 layer（内存爆炸）
//!   -> 阈值化：min_area / max_layer_count 配置；不达标则合并到父 layer
//!
//! Layer 提升（promoted，即缓存资格）实际判定见 shouldPromoteLayer：backdrop_blur /
//! composited_group / text+transform 动画 / will_change / overlay 候选动画中 /
//! rounded_clip 动画中。注意：非 overlay 普通节点 transform 动画**不**提升；
//! scroll 提升未实现（CompositedPromotionReason.is_scroll_container 从未置位）。
//!
//! Phase 6+ 再加：filter、mask、blend-mode、3D transform。

const std = @import("std");
const testing = std.testing;
const element_id_mod = @import("element_id.zig");
const paint_table_mod = @import("paint_table.zig");
const property_tree_mod = @import("property_tree.zig");
const types = @import("types.zig");
const scene_runtime_mod = @import("scene_runtime.zig");
const display_list_mod = @import("display_list.zig");

pub const ElementId = element_id_mod.ElementId;
pub const PaintChunk = paint_table_mod.PaintChunk;
pub const PropertyStateRef = paint_table_mod.PropertyStateRef;
pub const Bounds = paint_table_mod.Bounds;
pub const ComputedRect = types.ComputedRect;
pub const EffectKind = property_tree_mod.EffectKind;
pub const INVALID_ID = property_tree_mod.INVALID_ID;

/// Layer 提升原因，用于调试/devtools 显示
pub const PromotionReason = enum(u8) {
    root,
    transform_animating,
    opacity_animating,
    scroll,
    will_change,
    filter, // Phase 6+
    mask,
    blend_mode,
    transform_3d,
};

pub const LayerId = packed struct(u32) {
    index: u24,
    generation: u8,

    pub const NULL: LayerId = .{ .index = 0xFFFFFF, .generation = 0xFF };

    pub fn isNull(self: LayerId) bool {
        return self.index == 0xFFFFFF;
    }

    pub fn eql(a: LayerId, b: LayerId) bool {
        return a.index == b.index and a.generation == b.generation;
    }
};

/// Layer 帧状态机（取代 CompositorPlan.LayerFlags）
/// 由 render_engine 在 paint pass 内 mark；devtools / hit-test 等读取。
pub const LayerFrameFlags = packed struct(u8) {
    /// surface 内容是否仍有效（未被脏标记失效）
    surface_valid: bool = false,
    /// 本帧是否命中并复用了已有 promoted surface
    reused_this_frame: bool = false,
    /// 本帧是否重建了 promoted surface 内容
    rebuilt_this_frame: bool = false,
    /// 本帧 surface 是否因后代内容变化而失效
    invalidated_by_descendant_this_frame: bool = false,
    /// 本帧 surface 是否因根节点自身变化而失效
    invalidated_by_self_this_frame: bool = false,
    /// 本帧是否命中"后代失效且子树内仍含 promoted descendants"的局部化 rebuild 候选
    descendant_scoped_rebuild_candidate_this_frame: bool = false,
    _reserved: u2 = 0,
};

/// Surface 失效原因
pub const SurfaceInvalidationReason = enum {
    self,
    descendant,
};

/// 单个合成层
pub const Layer = struct {
    /// 创建/复用此 layer 的根 ElementId（debug + reconcile）
    root_element: ElementId = ElementId.NULL,
    /// 父 layer
    parent: LayerId = LayerId.NULL,
    /// 提升原因
    reason: PromotionReason = .root,
    /// 引用 PropertyTree 的 4 棵树（决定 layer 渲染时的 transform/clip/effect/scroll）
    property_state: PropertyStateRef = .NONE,
    /// GPU surface 句柄（来自 ResourcePool；NULL = 与父共享 surface）
    /// ⚠️ **当前未被生产 renderer 消费**（2026-07-30 核实）。
    ///
    /// 审查报告 P1 指出 LayerTree 已备好 gpu_texture_handle / damage_rect /
    /// needs_repaint，但"生产 renderer 尚未消费它们"，属实。
    /// 需要说明的是：**这并不等于没有 GPU 端复用**。当前的复用走的是另一条
    /// 独立通路，`SceneRuntime.promoted_surface_flags`（rebuilt/reused/
    /// surface_valid）配合 offscreen texture pool，promoted surface 在内容
    /// 未变时确实跨帧复用（有回归测试：popover.zig 的
    /// "scale_fade open animation reuses promoted surface" 逐帧断言
    /// 首帧 rebuilt、其后 reused）。
    ///
    /// **当前到底省了什么、还没省什么**（2026-07-30 实测确认，避免误读）：
    ///
    /// 已省（CPU 侧）：promoted surface 命中缓存时，
    /// `render_engine/mod.zig:1668` 起的路径**直接 splice 上一帧的命令区段**，
    /// 不再重走子树，这就是 "CPU retained" 已经生效的部分。
    /// 离屏纹理也已按尺寸跨帧复用（offscreen_texture.zig 的
    /// REUSE_LAG_FRAMES + LRU），不会每帧 create/destroy。
    ///
    /// **GPU 侧（2026-07-30 已落地）**：曾经即便命令来自缓存、纹理来自池，
    /// `beginOpacityLayer` 仍会把命令**重新光栅化**进那张复用纹理，内容没变
    /// 也照画。现在按 **layer 身份**（`CompositedLayer.stable_id`）持有专属
    /// 纹理，内容未变时整段内容命令跳过，只留一次带 transform/opacity 的合成
    /// draw。实现在 `render/offscreen_texture.zig`（retained 所有权）+
    /// `render/opacity_layer.zig`（`tryBeginRetainedOpacityLayer`）。
    ///
    /// 三项子工作的现状：
    ///   1. 按 layer 身份持有专属纹理，✅ 已做；
    ///   2. `damage_rect` 裁剪重绘到脏区，✅ **已做（2026-07-30）**：encoder
    ///      侧 per-item 指纹 diff 出脏区，load+scissor+clear draw 部分重绘
    ///      （含非平坦层：path/clip/嵌套 opacity 子树折叠捕获 + scissor 栈）。
    ///      damage 通路已合流：addDamage 申报会并入脏区（captureLayerTreeDamage），
    ///      encoder 决策经 noteEncoderOutcome 写回本结构的
    ///      damage_rect/needs_repaint，字段已被生产 renderer 消费。
    ///   3. composite 侧跳过内容 pass, ✅ 已做。
    ///
    /// ⚠️ 缓存键**不是** `content_version`（它只是 layer 根节点自己的版本，
    /// descendant 内容变化不会让它变），而是 encoder 侧对该层实际要编码的命令
    /// 取的内容指纹，见 `command_encoder.computeRetainedContentHashes`。
    ///
    /// 本字段 `gpu_texture_handle` 与 `damage_rect` / `needs_repaint` 仍未被
    /// 生产 renderer 消费：上述实现走的是 encoder 侧的独立通路（按 stable_id
    /// 查 offscreen pool），没有反向写回 LayerTree。保留字段是为了不丢失
    /// 设计意图，真做第 2 项（damage 裁剪）时它们才会被接上。
    gpu_texture_handle: u64 = 0,
    /// 包含哪些 PaintChunk（按 ElementId 索引；同 element 的 chunk）
    /// 简单 ArrayList, chunk 数有限（实际 layer 平均 < 100 chunk）
    chunk_elements: std.ArrayListUnmanaged(ElementId),
    /// world-space 包络 bounds
    world_bounds: Bounds = .ZERO,
    /// 本帧累积的 damage rect（local space；GPU encoder 只重画此区域）
    damage_rect: Bounds = .ZERO,
    /// 上次 paint 的 epoch；layerize pass 复用 layer 时验证
    repaint_epoch: u64 = 0,
    /// retained plan：本 layer 最后一次被 planAppendLayer 触达的 plan_epoch。
    /// 清扫时 != 当前 epoch 的 plan layer 视为退场，销毁。
    plan_seen_epoch: u64 = 0,
    /// 是否本帧需要重画（false = 完全 cache hit，仅 compose）
    needs_repaint: bool = false,
    /// GPU encoder 写回（观测用，与 damage_rect 生产通路分离，写进
    /// damage_rect 会在无人调 beginFrame 的生产环境里被下一帧的
    /// captureLayerTreeDamage 误当生产端申报，形成全层脏区反馈环）：
    /// 0=本帧无 retained 决策 1=cache hit 2=整层重画 3=部分重绘
    encoder_repaint_kind: u8 = 0,
    /// encoder 写回的实际重绘区（local space；kind=3 时为脏区，=2 时为整层）
    encoder_damage_rect: Bounds = .ZERO,
    /// alive 标记，destroy 后置 false 等 epoch 回收
    alive: bool = true,
    /// 取代 CompositorPlan 的 frame state 机
    frame_flags: LayerFrameFlags = .{},
    /// P1.6'（2026-05-01）：CompositorPlan 的 per-frame 描述符 inline。
    /// CompositorPlan.appendLayer mirror 到这里；callers 应优先 read tree.get(id).composited
    /// 而非 plan.layers.items[plan_id]。null = 此 layer 不是 plan 创建的（layerize 创建）。
    composited: ?CompositedLayer = null,

    pub fn deinit(self: *Layer, allocator: std.mem.Allocator) void {
        self.chunk_elements.deinit(allocator);
    }
};

/// LayerTree 配置
pub const LayerTreeConfig = struct {
    /// 单 layer 最小面积（小于此值会被合并回父层）
    min_layer_area_px2: f32 = 64.0 * 64.0,
    /// 全局 layer 计数上限（超出则降级提升策略）
    max_layer_count: u32 = 256,
};

pub const LayerTree = struct {
    allocator: std.mem.Allocator,
    layers: std.ArrayListUnmanaged(Layer),
    generations: std.ArrayListUnmanaged(u8),
    free_list: std.ArrayListUnmanaged(u24),
    /// element -> layer 反查（element 属于哪个 layer）
    element_to_layer: std.AutoHashMapUnmanaged(u32, LayerId),
    /// 根 layer
    root: LayerId = LayerId.NULL,
    config: LayerTreeConfig,
    /// P1.8'（2026-05-01）：本帧合成操作序列。曾经在 CompositorPlan.ops，迁入。
    /// frame_clear() 帧间清；plan API 的 appendOp/findXxxOp 通过此存取。
    frame_ops: std.ArrayList(CompositeOp),
    /// P1.9'（2026-05-01）：本帧 plan_layer_id (= 顺序索引) -> LayerId 索引。
    /// 曾经在 CompositorPlan.tree_layer_ids，迁入。
    frame_layer_ids: std.ArrayList(LayerId),
    /// Retained plan 层身份：(root_node_id, effect_kind) -> 持久 tree LayerId。
    /// planAppendLayer 命中时**复用** tree layer（原地更新 composited descriptor、
    /// 保留 surface_valid），miss 时才 createLayer；planBuild 末尾 epoch 清扫
    /// 本帧未出现的条目。layer 身份从此跨帧稳定（不再是帧内序号）。
    plan_by_node: std.AutoHashMapUnmanaged(u64, LayerId) = .{},
    /// plan 帧 epoch（planBuildFromPropertyTree 每次 +1，用于清扫退场 layer）。
    plan_epoch: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, config: LayerTreeConfig) LayerTree {
        return .{
            .allocator = allocator,
            .layers = .{},
            .generations = .{},
            .free_list = .{},
            .element_to_layer = .{},
            .config = config,
            .frame_ops = .{},
            .frame_layer_ids = .{},
        };
    }

    pub fn deinit(self: *LayerTree) void {
        for (self.layers.items) |*l| {
            if (l.alive) l.deinit(self.allocator);
        }
        self.layers.deinit(self.allocator);
        self.generations.deinit(self.allocator);
        self.free_list.deinit(self.allocator);
        self.element_to_layer.deinit(self.allocator);
        self.frame_ops.deinit(self.allocator);
        self.frame_layer_ids.deinit(self.allocator);
        self.plan_by_node.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn createLayer(self: *LayerTree, root_element: ElementId, reason: PromotionReason, parent: LayerId) !LayerId {
        // 世代退役（防 ABA，对齐 element_id.SlotMap / ElementTable）：
        // generation 推进到 MAX_GEN（=NULL 的 generation）的 slot 永久退役。
        // alive 位挡不住复用后的 ABA，复用槽 alive=true、generation 回卷后
        // 与陈旧 LayerId 假匹配。create/destroy 两侧各推进一次，两侧都要判。
        while (self.free_list.pop()) |idx| {
            const next_gen = self.generations.items[idx] +% 1;
            if (next_gen == element_id_mod.MAX_GEN) {
                self.generations.items[idx] = element_id_mod.MAX_GEN;
                continue;
            }
            self.layers.items[idx] = .{
                .root_element = root_element,
                .parent = parent,
                .reason = reason,
                .chunk_elements = .{},
            };
            self.generations.items[idx] = next_gen;
            return .{ .index = idx, .generation = next_gen };
        }

        const idx = self.layers.items.len;
        if (idx >= 0xFFFFFF) return error.LayerTreeFull;

        // layers 与 generations 必须永远同长：isAlive 先按 layers.len 过滤下标、再读
        // generations[idx]。以前是两次可失败 append，第二次失败就留下一格没有世代的
        // layer，下一次 isAlive 直接越界。先把两边容量订好，再零失败地追加。
        try self.layers.ensureUnusedCapacity(self.allocator, 1);
        try self.generations.ensureUnusedCapacity(self.allocator, 1);
        self.layers.appendAssumeCapacity(.{
            .root_element = root_element,
            .parent = parent,
            .reason = reason,
            .chunk_elements = .{},
        });
        self.generations.appendAssumeCapacity(0);

        const id: LayerId = .{ .index = @intCast(idx), .generation = 0 };
        if (parent.isNull() and self.root.isNull()) self.root = id;
        return id;
    }

    /// GPU handle release 回调签名（用 u64 传 ResourceHandle.raw 避免跨模块依赖）
    pub const GpuReleaseFn = *const fn (ctx: *anyopaque, handle: u64) void;

    pub fn destroyLayer(self: *LayerTree, id: LayerId) void {
        self.destroyLayerWithRelease(id, null, null);
    }

    /// 销毁 layer 并通过回调把 GPU 资源 handle 交给 caller（ResourcePool.release）。
    /// release_cb 为 null 时 GPU 资源仅在 LayerTree 内丢弃指针；caller 自负回收。
    pub fn destroyLayerWithRelease(
        self: *LayerTree,
        id: LayerId,
        release_cb: ?GpuReleaseFn,
        release_ctx: ?*anyopaque,
    ) void {
        const layer = self.getMut(id) orelse return;
        // 移除 element_to_layer 反向条目
        for (layer.chunk_elements.items) |elem_id| {
            _ = self.element_to_layer.remove(elem_id.raw());
        }
        // GPU 资源回收
        if (layer.gpu_texture_handle != 0) {
            if (release_cb) |cb| {
                cb(release_ctx orelse undefined, layer.gpu_texture_handle);
            }
            layer.gpu_texture_handle = 0;
        }
        layer.deinit(self.allocator);
        layer.alive = false;
        self.generations.items[id.index] +%= 1;
        if (self.root.eql(id)) self.root = LayerId.NULL;
        // 世代退役：推进到 MAX_GEN 的 slot 不回 free_list（见 createLayer 注释）
        if (self.generations.items[id.index] == element_id_mod.MAX_GEN) return;
        // 安全降级：free_list 只是 slot 复用池，OOM 时泄漏一个 slot 索引，
        // generation 已 +1，悬垂 LayerId 仍会被 isValid 正确拒绝。
        self.free_list.append(self.allocator, id.index) catch {};
    }

    /// 设置 layer 的 GPU texture handle（caller 已用 ResourcePool 分配）
    pub fn setGpuTextureHandle(self: *LayerTree, id: LayerId, handle: u64) void {
        if (self.getMut(id)) |l| l.gpu_texture_handle = handle;
    }

    pub fn gpuTextureHandle(self: *const LayerTree, id: LayerId) u64 {
        if (self.get(id)) |l| return l.gpu_texture_handle;
        return 0;
    }

    pub fn isAlive(self: *const LayerTree, id: LayerId) bool {
        if (id.isNull()) return false;
        if (id.index >= self.layers.items.len) return false;
        if (self.generations.items[id.index] != id.generation) return false;
        return self.layers.items[id.index].alive;
    }

    pub fn get(self: *const LayerTree, id: LayerId) ?*const Layer {
        if (!self.isAlive(id)) return null;
        return &self.layers.items[id.index];
    }

    pub fn getMut(self: *LayerTree, id: LayerId) ?*Layer {
        if (!self.isAlive(id)) return null;
        return &self.layers.items[id.index];
    }

    /// 把 element 归到某 layer 下（layerize pass 调用）
    pub fn assignElement(self: *LayerTree, layer_id: LayerId, element: ElementId) !void {
        const layer = self.getMut(layer_id) orelse return;
        // 反查表先订容量：append 成功后 put 再失败会让 element 挂在 layer 上却查不到。
        try self.element_to_layer.ensureUnusedCapacity(self.allocator, 1);
        try layer.chunk_elements.append(self.allocator, element);
        self.element_to_layer.putAssumeCapacity(element.raw(), layer_id);
    }

    pub fn layerOf(self: *const LayerTree, element: ElementId) ?LayerId {
        return self.element_to_layer.get(element.raw());
    }

    /// 把 chunk 的 dirty 转成 layer damage rect（layerize pass 后由 paint pass 调用）。
    /// 2026-07-30 起 GPU encoder 消费此申报：retained miss 且 diff 出脏区时，
    /// 申报的 rect 会并入部分重绘的 scissor 区域（见 command_encoder.
    /// captureLayerTreeDamage / opacity_layer.computePartialDamage）。
    pub fn addDamage(self: *LayerTree, layer_id: LayerId, rect: Bounds) void {
        const layer = self.getMut(layer_id) orelse return;
        layer.damage_rect = layer.damage_rect.unionWith(rect);
        layer.needs_repaint = true;
    }

    /// GPU encoder 写回（damage 通路合流 2026-07-30）：retained 层本帧的实际
    /// 重绘决策。kind: 0=cache hit（零重绘）1=整层重画 2=部分重绘。
    /// rect = local space {min_x,min_y,max_x,max_y}。写进 encoder_repaint_kind /
    /// encoder_damage_rect（观测字段），与 addDamage 的生产通路分离，
    /// 生产申报由 encoder 的 captureLayerTreeDamage 取走即清（consume-clear）。
    pub fn noteEncoderOutcome(self: *LayerTree, stable_id: u32, kind: u8, rect: [4]f32) void {
        for (self.layers.items) |*l| {
            if (!l.alive) continue;
            const comp = l.composited orelse continue;
            if (comp.stable_id != stable_id) continue;
            switch (kind) {
                0 => {
                    l.encoder_repaint_kind = 1;
                    l.encoder_damage_rect = .ZERO;
                },
                1 => {
                    l.encoder_repaint_kind = 2;
                    l.encoder_damage_rect = .{ .min_x = rect[0], .min_y = rect[1], .max_x = rect[2], .max_y = rect[3] };
                },
                2 => {
                    l.encoder_repaint_kind = 3;
                    l.encoder_damage_rect = .{ .min_x = rect[0], .min_y = rect[1], .max_x = rect[2], .max_y = rect[3] };
                },
                else => {},
            }
            return;
        }
    }

    /// 帧开始：清各 layer 的 damage / needs_repaint
    pub fn beginFrame(self: *LayerTree) void {
        for (self.layers.items) |*l| {
            if (!l.alive) continue;
            l.damage_rect = .ZERO;
            l.needs_repaint = false;
            // 帧间清 frame_flags（取代 CompositorPlan.clear() 的同等行为）
            // 保留 surface_valid（跨帧 cache 状态），其余每帧重算。
            const sv = l.frame_flags.surface_valid;
            l.frame_flags = .{};
            l.frame_flags.surface_valid = sv;
        }
    }

    /// 取代 CompositorPlan.markLayerSurfaceInvalidated
    pub fn markLayerSurfaceInvalidated(self: *LayerTree, id: LayerId, reason: SurfaceInvalidationReason) void {
        if (self.getMut(id)) |l| {
            l.frame_flags.surface_valid = false;
            switch (reason) {
                .self => l.frame_flags.invalidated_by_self_this_frame = true,
                .descendant => l.frame_flags.invalidated_by_descendant_this_frame = true,
            }
        }
    }

    /// 取代 CompositorPlan.markLayerSurfaceReused
    /// 语义与 CompositorPlan.markLayerSurfaceReused 一致（P1.3' 调齐）：
    /// surface_valid=true, reused=true, 清 rebuilt/invalidated_*/descendant_scoped。
    pub fn markLayerSurfaceReused(self: *LayerTree, id: LayerId) void {
        if (self.getMut(id)) |l| {
            l.frame_flags.surface_valid = true;
            l.frame_flags.reused_this_frame = true;
            l.frame_flags.rebuilt_this_frame = false;
            l.frame_flags.invalidated_by_descendant_this_frame = false;
            l.frame_flags.invalidated_by_self_this_frame = false;
            l.frame_flags.descendant_scoped_rebuild_candidate_this_frame = false;
        }
    }

    /// 取代 CompositorPlan.markLayerSurfaceRebuilt
    /// 语义同 plan：surface_valid=true, rebuilt=true, 清 reused/descendant_scoped。
    pub fn markLayerSurfaceRebuilt(self: *LayerTree, id: LayerId) void {
        if (self.getMut(id)) |l| {
            l.frame_flags.surface_valid = true;
            l.frame_flags.reused_this_frame = false;
            l.frame_flags.rebuilt_this_frame = true;
            l.frame_flags.descendant_scoped_rebuild_candidate_this_frame = false;
        }
    }

    /// 取代 CompositorPlan.markLayerDescendantScopedRebuildCandidate
    pub fn markLayerDescendantScopedRebuildCandidate(self: *LayerTree, id: LayerId) void {
        if (self.getMut(id)) |l| {
            l.frame_flags.descendant_scoped_rebuild_candidate_this_frame = true;
        }
    }

    pub fn liveLayerCount(self: *const LayerTree) u32 {
        var c: u32 = 0;
        for (self.layers.items) |l| {
            if (l.alive) c += 1;
        }
        return c;
    }

    // =========================================================================
    // Compositor plan API (P1.10' 2026-05-01: 自 CompositorPlan struct 吸收进来)
    //
    // 历史：原 CompositorPlan struct 是 thin facade（持 *LayerTree 引用），所有 13
    // 个方法都 forward 到 LayerTree。P1.10' 直接把方法搬到 LayerTree 上，删除
    // facade。冲突的 markLayer*Surface* 方法用 `plan` 前缀区分（plan-layer-id 路径
    // vs 直接 LayerId 路径）。
    // =========================================================================

    pub const RootLayerState = struct {
        has_plan_layer: bool = false,
        promoted_layer_id: u32 = INVALID_ID,
        /// 跨帧稳定身份（CompositedLayer.stable_id）；缓存写入/比较必须用它。
        promoted_layer_stable_id: u32 = INVALID_ID,
        frame_flags: LayerFrameFlags = .{},
    };

    pub const EffectPlanState = struct {
        has_plan_layer: bool = false,
        layer_id: u32 = INVALID_ID,
        layer: ?CompositedLayer = null,
        begin_bounds: ?ComputedRect = null,
        draw_opacity: ?f32 = null,
        has_end_surface: bool = false,
        apply_clip_bounds: ?ComputedRect = null,
        apply_clip_shape_kind: display_list_mod.ClipShapeKind = .rect,
        apply_clip_radius: f32 = 0,
        apply_clip_polygon: display_list_mod.ClipPolygon = .{},
        apply_clip_bounds_fallback: bool = false,

        pub fn hasCompleteSurfaceBridge(self: EffectPlanState) bool {
            return self.has_plan_layer and
                self.layer != null and
                self.begin_bounds != null and
                self.has_end_surface;
        }

        pub fn hasPlanClipBridge(self: EffectPlanState) bool {
            return self.apply_clip_bounds != null;
        }
    };

    pub const NodePlanState = struct {
        root: RootLayerState = .{},
        effect: EffectPlanState = .{},
        promoted_layer_id: u32 = INVALID_ID,
        promoted_layer_stable_id: u32 = INVALID_ID,
        frame_flags: LayerFrameFlags = .{},
        needs_rect_clip_fallback: bool = false,
        clip_bounds_fallback: bool = false,
    };

    /// 取本帧 plan_layer_id 对应的 LayerTree.LayerId。
    /// 内部用：外部读 plan-layer 数据走 planCompositedAt / planFrameFlagsOf 等便捷 API。
    fn planTreeLayerOf(self: *const LayerTree, plan_layer_id: u32) LayerId {
        if (plan_layer_id >= self.frame_layer_ids.items.len) return LayerId.NULL;
        return self.frame_layer_ids.items[plan_layer_id];
    }

    /// 取 plan_layer_id 对应的 LayerTree frame_flags。
    pub fn planFrameFlagsOf(self: *const LayerTree, plan_layer_id: u32) LayerFrameFlags {
        const tree_id = self.planTreeLayerOf(plan_layer_id);
        const tree_layer = self.get(tree_id) orelse return .{};
        return tree_layer.frame_flags;
    }

    /// 取 plan_layer_id 对应的 CompositedLayer descriptor。
    pub fn planCompositedAt(self: *const LayerTree, plan_layer_id: u32) ?CompositedLayer {
        const tree_id = self.planTreeLayerOf(plan_layer_id);
        const tree_layer = self.get(tree_id) orelse return null;
        return tree_layer.composited;
    }

    /// 帧间清本帧的 plan ops 与 ordinal 索引。retained 化后**不再销毁 layer**,
    /// tree layer 跨帧持久（plan_by_node 键控），退场清扫由 planBuildFromPropertyTree
    /// 末尾的 epoch sweep 负责。
    pub fn planClear(self: *LayerTree) void {
        self.frame_ops.clearRetainingCapacity();
        self.frame_layer_ids.clearRetainingCapacity();
    }

    fn planLayerKey(root_node_id: u32, kind: EffectKind) u64 {
        return (@as(u64, root_node_id) << 3) | @intFromEnum(kind);
    }

    pub fn planAppendLayer(self: *LayerTree, layer: CompositedLayer) !u32 {
        // 先把本函数全部可失败操作的容量订好：createLayer 之后不能再有 try。
        // 以前 createLayer 成功、plan_by_node.put 失败会留下一个既不在 plan_by_node
        // 也不在 frame_layer_ids 的活 layer, epoch sweep 只遍历 plan_by_node，
        // 它永远不会被回收，每次失败都多一个。
        try self.frame_layer_ids.ensureUnusedCapacity(self.allocator, 1);
        try self.plan_by_node.ensureUnusedCapacity(self.allocator, 1);

        const id: u32 = @intCast(self.frame_layer_ids.items.len);
        var l = layer;
        l.layer_id = id;

        const key = planLayerKey(l.root_node_id, l.effect_kind);
        const tree_id: LayerId = blk: {
            if (self.plan_by_node.get(key)) |existing| {
                if (self.isAlive(existing)) break :blk existing;
            }
            const created = try self.createLayer(ElementId.NULL, .root, LayerId.NULL);
            self.plan_by_node.putAssumeCapacity(key, created);
            break :blk created;
        };

        l.stable_id = @bitCast(tree_id);
        if (self.getMut(tree_id)) |tl| {
            // retained 命中：原地更新 per-frame descriptor（transform/opacity/bounds），
            // frame_flags 保留跨帧 surface_valid、清其余 per-frame 位（对齐 beginFrame 语义）。
            const sv = tl.frame_flags.surface_valid;
            tl.frame_flags = .{};
            tl.frame_flags.surface_valid = sv;
            tl.composited = l;
            tl.plan_seen_epoch = self.plan_epoch;
        }
        self.frame_layer_ids.appendAssumeCapacity(tree_id);
        return id;
    }

    /// planBuild 末尾：销毁本帧未出现的 retained plan layer（节点/effect 退场）。
    fn planSweepStale(self: *LayerTree) void {
        // 零分配：每趟最多摘 64 个 key，摘满了就再来一趟，直到一趟没摘满为止。
        // 以前只跑一趟：一帧退场超过 64 个 layer（关掉一个满是效果的大文档）时，
        // 第 65 个起 layer 已销毁但 key 留在表里，要靠后面几帧每帧 64 个慢慢清，
        // 期间 plan_by_node 的体积和遍历成本都是虚高的。
        while (true) {
            var stale: [64]u64 = undefined;
            var stale_count: usize = 0;
            var it = self.plan_by_node.iterator();
            while (it.next()) |entry| {
                const lid = entry.value_ptr.*;
                const layer = self.get(lid) orelse {
                    if (stale_count < stale.len) {
                        stale[stale_count] = entry.key_ptr.*;
                        stale_count += 1;
                    }
                    continue;
                };
                if (layer.plan_seen_epoch != self.plan_epoch) {
                    self.destroyLayer(lid);
                    if (stale_count < stale.len) {
                        stale[stale_count] = entry.key_ptr.*;
                        stale_count += 1;
                    }
                }
            }
            for (stale[0..stale_count]) |key| {
                _ = self.plan_by_node.remove(key);
            }
            if (stale_count < stale.len) break;
        }
    }

    fn planAppendOp(self: *LayerTree, op: CompositeOp) !void {
        try self.frame_ops.append(self.allocator, op);
    }

    /// 一个 effect 的 op 序列（可选 apply_clip + begin/end/draw 三元组）最多 4 条。
    const OPS_PER_EFFECT: usize = 4;

    fn planAppendOpAssumeCapacity(self: *LayerTree, op: CompositeOp) void {
        self.frame_ops.appendAssumeCapacity(op);
    }

    pub fn planFindLayerIdByEffectId(self: *const LayerTree, effect_id: u32) ?u32 {
        for (self.frame_layer_ids.items, 0..) |_, i| {
            const layer = self.planCompositedAt(@intCast(i)) orelse continue;
            if (layer.effect_id == effect_id) return @intCast(i);
        }
        return null;
    }

    pub fn planQueryRootNode(self: *const LayerTree, root_node_id: u32) RootLayerState {
        var state = RootLayerState{};
        var best_priority: u8 = 0;
        for (self.frame_layer_ids.items, 0..) |_, i| {
            const layer = self.planCompositedAt(@intCast(i)) orelse continue;
            if (layer.root_node_id != root_node_id) continue;
            state.has_plan_layer = true;
            if (!layer.promotion_reason.any()) continue;
            const priority = promotedLayerPriority(layer);
            if (state.promoted_layer_id == INVALID_ID or priority > best_priority) {
                state.promoted_layer_id = @intCast(i);
                state.promoted_layer_stable_id = layer.stable_id;
                state.frame_flags = self.planFrameFlagsOf(@intCast(i));
                best_priority = priority;
            }
        }
        return state;
    }

    pub fn planQueryEffect(self: *const LayerTree, effect_id: u32) EffectPlanState {
        var state = EffectPlanState{};
        const layer_id = self.planFindLayerIdByEffectId(effect_id) orelse {
            if (self.findApplyClipOpForEffect(effect_id)) |clip_op| {
                switch (clip_op) {
                    .apply_clip => |clip| {
                        state.apply_clip_bounds = clip.bounds;
                        state.apply_clip_shape_kind = clip.shape_kind;
                        state.apply_clip_radius = clip.radius;
                        state.apply_clip_polygon = clip.polygon;
                        state.apply_clip_bounds_fallback = clip.bounds_fallback;
                    },
                    else => unreachable,
                }
            }
            return state;
        };

        state.has_plan_layer = true;
        state.layer_id = layer_id;
        state.layer = self.planCompositedAt(layer_id);

        if (self.findBeginSurfaceOp(layer_id)) |begin_op| {
            switch (begin_op) {
                .begin_surface => |begin| state.begin_bounds = begin.bounds,
                else => unreachable,
            }
        }
        if (self.findDrawSurfaceOp(layer_id)) |draw_op| {
            switch (draw_op) {
                .draw_surface => |draw| state.draw_opacity = draw.opacity,
                else => unreachable,
            }
        }
        state.has_end_surface = self.hasEndSurfaceOp(layer_id);

        if (self.findApplyClipOpForEffect(effect_id)) |clip_op| {
            switch (clip_op) {
                .apply_clip => |clip| {
                    state.apply_clip_bounds = clip.bounds;
                    state.apply_clip_shape_kind = clip.shape_kind;
                    state.apply_clip_radius = clip.radius;
                    state.apply_clip_polygon = clip.polygon;
                    state.apply_clip_bounds_fallback = clip.bounds_fallback;
                },
                else => unreachable,
            }
        }

        return state;
    }

    pub fn planQueryNode(
        self: *const LayerTree,
        root_node_id: u32,
        effect_id: u32,
        needs_clip: bool,
        use_rounded_clip: bool,
        clip_bounds_fallback: bool,
    ) NodePlanState {
        const root = self.planQueryRootNode(root_node_id);
        const effect = if (effect_id != INVALID_ID) self.planQueryEffect(effect_id) else EffectPlanState{};
        return .{
            .root = root,
            .effect = effect,
            .promoted_layer_id = root.promoted_layer_id,
            .promoted_layer_stable_id = root.promoted_layer_stable_id,
            .frame_flags = root.frame_flags,
            .needs_rect_clip_fallback = needs_clip and !use_rounded_clip and effect_id == INVALID_ID,
            .clip_bounds_fallback = if (effect_id != INVALID_ID) effect.apply_clip_bounds_fallback else clip_bounds_fallback,
        };
    }

    /// plan-layer-id wrapper：把 plan_layer_id 翻译成 LayerId 后 forward 给
    /// markLayerDescendantScopedRebuildCandidate。
    pub fn planMarkLayerDescendantScopedRebuildCandidate(self: *LayerTree, plan_layer_id: u32) void {
        if (plan_layer_id >= self.frame_layer_ids.items.len) return;
        const tree_id = self.planTreeLayerOf(plan_layer_id);
        if (!tree_id.isNull()) self.markLayerDescendantScopedRebuildCandidate(tree_id);
    }

    pub fn planMarkLayerSurfaceInvalidated(
        self: *LayerTree,
        plan_layer_id: u32,
        reason: SurfaceInvalidationReason,
    ) void {
        if (plan_layer_id >= self.frame_layer_ids.items.len) return;
        const tree_id = self.planTreeLayerOf(plan_layer_id);
        if (!tree_id.isNull()) self.markLayerSurfaceInvalidated(tree_id, reason);
    }

    pub fn planMarkLayerSurfaceReused(self: *LayerTree, plan_layer_id: u32) void {
        if (plan_layer_id >= self.frame_layer_ids.items.len) return;
        const tree_id = self.planTreeLayerOf(plan_layer_id);
        if (!tree_id.isNull()) self.markLayerSurfaceReused(tree_id);
    }

    pub fn planMarkLayerSurfaceRebuilt(self: *LayerTree, plan_layer_id: u32) void {
        if (plan_layer_id >= self.frame_layer_ids.items.len) return;
        const tree_id = self.planTreeLayerOf(plan_layer_id);
        if (!tree_id.isNull()) self.markLayerSurfaceRebuilt(tree_id);
    }

    fn findBeginSurfaceOp(self: *const LayerTree, layer_id: u32) ?CompositeOp {
        for (self.frame_ops.items) |op| {
            switch (op) {
                .begin_surface => |begin| if (begin.layer_id == layer_id) return op,
                else => {},
            }
        }
        return null;
    }

    fn hasEndSurfaceOp(self: *const LayerTree, layer_id: u32) bool {
        for (self.frame_ops.items) |op| {
            switch (op) {
                .end_surface => |end| if (end.layer_id == layer_id) return true,
                else => {},
            }
        }
        return false;
    }

    fn findDrawSurfaceOp(self: *const LayerTree, layer_id: u32) ?CompositeOp {
        for (self.frame_ops.items) |op| {
            switch (op) {
                .draw_surface => |draw| if (draw.layer_id == layer_id) return op,
                else => {},
            }
        }
        return null;
    }

    fn findApplyClipOpForEffect(self: *const LayerTree, effect_id: u32) ?CompositeOp {
        for (self.frame_ops.items) |op| {
            switch (op) {
                .apply_clip => |clip| if (clip.effect_id == effect_id) return op,
                else => {},
            }
        }
        return null;
    }

    pub fn planBuildFromPropertyTree(
        self: *LayerTree,
        effects: []const property_tree_mod.EffectNode,
        clips: []const property_tree_mod.ClipNode,
        transforms: []const property_tree_mod.TransformNode,
        scene_runtime: ?*const scene_runtime_mod.SceneRuntime,
    ) void {
        self.plan_epoch +%= 1;
        self.planClear();
        for (effects, 0..) |effect, i| {
            if (!effect.requires_offscreen) continue;

            const world_bounds = if (effect.transform_id < transforms.len)
                transforms[effect.transform_id].world.transformRect(effect.local_bounds)
            else
                effect.local_bounds;

            const transform = if (effect.transform_id < transforms.len) transforms[effect.transform_id] else null;
            const node_runtime = if (scene_runtime) |runtime| runtime.get(effect.node_id) else null;
            const promotion_reason = buildPromotionReason(effect, transform, node_runtime);
            const promoted = shouldPromoteLayer(effect, promotion_reason, node_runtime);

            // CA-pure：surface 永远走统一的 draw_transform 合成路径（src=owner-local，
            // composite=parent_inverse·owner_world）。不再区分"轴对齐 blit at world bounds" vs "transform
            // 合成"，那个分叉正是 rest/animation 接缝 bug 的来源。恒 true。
            const has_surface_transform = true;

            // ── CA-pure 合成模型（2026-06-07 revamp）──────────────────────────────
            // 统一路径（不再 has_surface_transform 分叉）：
            //  - surface 内 content 已被 lowering 用 owner_world⁻¹ 投到 **owner-unscaled-local**
            //    帧（见 mod.zig surface_inverse=self.world.invert()）：owner 自身在 (0,0)、不含
            //    owner 的 scale/rotate。
            //  - 因此 texture 的 src 区域 = opacity_bounds 投到同一帧 = owner_world⁻¹·opacity_bounds。
            //  - 合成回写 = parent_inverse·owner_world（含 position+scale+rotate）。
            //    owner_world 本身就是 CA 的 M：它把 owner-local 内容放回世界并施加动画 scale。
            //    rest（scale=1）时 owner_world 退化为 Translate(owner_pos) -> 精确居中、不漂。
            const owner_world = if (transform) |tx| tx.world else types.Transform2D.identity();
            const owner_world_inv = owner_world.invert();
            // src = bounds 投到 owner-unscaled-local 帧（与 content 同帧）。texture 覆盖此矩形，
            // 但 GPU 端 addImageUVWithTransform 画的是 **texture-local quad [0,w]×[0,h]**
            // （quad 原点 = src 左上角）。故合成矩阵必须把 quad(0,0)=src_origin 映回世界：
            //   M = parent_inverse · owner_world · Translate(src.x, src.y)
            // owner_world 含 position+scale+rotate（scale 绕 owner transform-origin），
            // Translate(src) 把 quad 原点对齐到 src 左上角。rest（scale=1）时
            // 顶层 parent_inverse 为 identity；嵌套时将世界位置转入父 surface 内容帧。
            const surface_source_bounds = owner_world_inv.transformRect(world_bounds);
            // A child surface composites into its nearest capturing ancestor's
            // content frame. Backdrop blur samples in place and does not open one.
            var parent_inverse = types.Transform2D.identity();
            var ancestor_id = effect.parent;
            while (ancestor_id != INVALID_ID and ancestor_id < effects.len) {
                const ancestor = effects[ancestor_id];
                if (ancestor.requires_offscreen and ancestor.kind != .backdrop_blur) {
                    if (ancestor.transform_id < transforms.len) {
                        parent_inverse = transforms[ancestor.transform_id].inverse_world;
                        // Descendant traversal excludes the owner's animated scale
                        // and rotation. Same-node effects share the owner's own frame.
                        if (ancestor.node_id != effect.node_id) {
                            if (scene_runtime) |runtime| {
                                if (runtime.get(ancestor.node_id)) |owner| parent_inverse = owner.content_transform.invert();
                            }
                        }
                    }
                    break;
                }
                ancestor_id = ancestor.parent;
            }
            const surface_draw_bounds = parent_inverse.transformRect(world_bounds);
            const surface_rotate: f32 = if (transform) |tx| tx.local.decompose().rotate else 0;
            const surface_draw_transform = parent_inverse.mul(owner_world).mul(types.Transform2D.translation(
                surface_source_bounds.x,
                surface_source_bounds.y,
            ));

            var layer = CompositedLayer{
                .root_node_id = effect.node_id,
                .content_bounds_local = effect.local_bounds,
                .surface_bounds_world = world_bounds,
                .transform_id = effect.transform_id,
                .effect_id = @intCast(i),
                .effect_kind = effect.kind,
                .opacity = effect.opacity,
                .glass = effect.glass,
                .blend_mode = effect.blend_mode,
                .corner_radius = effect.corner_radius,
                .promotion_reason = if (promoted) promotion_reason else .{},
                .has_surface_transform = has_surface_transform,
                .surface_rotate = surface_rotate,
                .surface_draw_transform = surface_draw_transform,
                .surface_parent_inverse = parent_inverse,
                .surface_source_bounds = surface_source_bounds,
                .surface_draw_bounds = surface_draw_bounds,
            };
            if (node_runtime) |runtime| {
                layer.content_version = runtime.content_version;
                layer.flags = .{
                    .is_animating = runtime.has_active_composite_animation,
                    .contains_text = runtime.content_flags.has_text,
                };
            }

            // 一个 effect 要么整体进 plan，要么整体跳过：先把它全部 op 的容量订好，
            // 再建 layer，之后零失败地追加。以前 op 追加失败是 @panic，理由是
            // begin/end/draw 三元组不可拆，但对编辑器来说 abort 是最坏结局；订不到
            // 容量就跳过这个 effect（与 planAppendLayer 失败同样的降级），三元组
            // 依然不会出现半截。
            self.frame_ops.ensureUnusedCapacity(self.allocator, OPS_PER_EFFECT) catch continue;
            const layer_id = self.planAppendLayer(layer) catch continue;
            // 刚 append 成功的 plan layer 一定活着且 composited 已写入，这个 orelse 实际
            // 不可达；留着只是为了不在帧路径上 unreachable。它排在任何 op 追加之前，
            // 所以即便走到也只是「本帧没画这个 effect」，不会留下孤儿 apply_clip。
            const stored_layer = self.planCompositedAt(layer_id) orelse continue;
            const can_reuse_surface = canReusePromotedSurface(stored_layer, transform, node_runtime);
            const tree_id = self.planTreeLayerOf(layer_id);
            if (!tree_id.isNull()) {
                if (can_reuse_surface) {
                    if (self.getMut(tree_id)) |tl| tl.frame_flags.surface_valid = true;
                } else if (promoted) {
                    if (node_runtime) |runtime| {
                        if (runtime.has_promoted_surface_cache) {
                            self.markLayerSurfaceInvalidated(tree_id, .self);
                        }
                    }
                }
            }

            if (node_runtime) |runtime| {
                // surface 内部 lowering 不发 clip 链，apply_clip 是 effect owner 受
                // 裁剪的唯一载体：runtime.clip_id 是作用于该节点的最近 clip（自己的
                // overflow clip，或继承自祖先）。
                //
                // 例外：owner 自己的 overflow clip 若标了 owner_wraps_children（owner
                // 有阴影/描边等画在 children clip 之外的内容），该 clip 由渲染树侧
                // children 包围的 node-local push_clip 承担，apply_clip 在
                // begin_layer 后立即 push，会连 owner 自己的阴影/描边一起裁（Popover
                // 阴影被切成矩形、贴边内容压住描边）。此时 apply_clip 退回到**父**
                // clip，owner 仍受祖先裁剪。
                var apply_clip_id = runtime.clip_id;
                if (apply_clip_id != INVALID_ID and apply_clip_id < clips.len and
                    effect.kind != .backdrop_blur and
                    clips[apply_clip_id].owner_wraps_children and
                    clips[apply_clip_id].node_id == runtime.node_id)
                {
                    apply_clip_id = clips[apply_clip_id].parent;
                }
                if (apply_clip_id != INVALID_ID and apply_clip_id < clips.len and runtime.effect_id == i and effect.kind != .rounded_clip) {
                    const tree_id2 = self.planTreeLayerOf(layer_id);
                    if (self.getMut(tree_id2)) |tl| {
                        if (tl.composited) |*c| c.clip_id = apply_clip_id;
                    }
                    const clip = clips[apply_clip_id];
                    self.planAppendOpAssumeCapacity(.{ .apply_clip = .{
                        .effect_id = @intCast(i),
                        .clip_id = apply_clip_id,
                        .bounds = clip.world_aabb,
                        .shape_kind = clip.shape_kind,
                        .radius = clip.radius,
                        .polygon = clip.polygon,
                        .bounds_fallback = clip.bounds_fallback,
                    } });
                }
            }

            // begin/end/draw_surface 是不可拆的三元组（begin 无 end / 画了不存在的
            // surface 都会让下游 compositor 渲染错乱），容量已在本 effect 开头订好，
            // 这里不可能失败，三条要么全在要么全不在。
            self.planAppendOpAssumeCapacity(.{ .begin_surface = .{
                .layer_id = layer_id,
                .bounds = world_bounds,
            } });
            self.planAppendOpAssumeCapacity(.{ .end_surface = .{
                .layer_id = layer_id,
            } });
            self.planAppendOpAssumeCapacity(.{ .draw_surface = .{
                .layer_id = layer_id,
                .opacity = effect.opacity,
                .transform_id = effect.transform_id,
            } });
        }
        self.planSweepStale();
    }
};

fn promotedLayerPriority(layer: CompositedLayer) u8 {
    return switch (layer.effect_kind) {
        .backdrop_blur => 3,
        .composited_group => 2,
        .opacity => 1,
        .rounded_clip => 1,
    };
}

fn buildPromotionReason(
    effect: property_tree_mod.EffectNode,
    transform: ?property_tree_mod.TransformNode,
    node_runtime: ?scene_runtime_mod.SceneNodeRuntime,
) CompositedPromotionReason {
    var reason = CompositedPromotionReason{};
    if (node_runtime) |runtime| {
        reason.is_overlay = runtime.is_overlay_candidate;
        reason.has_opacity_animation = runtime.has_active_opacity_animation;
        reason.has_transform_animation = runtime.has_active_transform_animation or if (transform) |tx|
            tx.flags.has_animation and (tx.flags.has_translation or tx.flags.has_scale or tx.flags.has_rotation)
        else
            false;
        reason.text_with_transform_animation = runtime.is_overlay_candidate and runtime.content_flags.has_text and reason.has_transform_animation;
        reason.has_will_change_transform = runtime.will_change_transform;
        reason.has_will_change_opacity = runtime.will_change_opacity;
    }
    reason.explicit_composited_group = effect.kind == .composited_group;
    reason.has_filter_effect = effect.kind == .backdrop_blur;
    return reason;
}

fn shouldPromoteLayer(effect: property_tree_mod.EffectNode, reason: CompositedPromotionReason, node_runtime: ?scene_runtime_mod.SceneNodeRuntime) bool {
    if (effect.kind == .backdrop_blur) return true;
    if (effect.kind == .composited_group) return true;
    if (reason.text_with_transform_animation) return true;
    if (reason.has_will_change_transform or reason.has_will_change_opacity) return true;
    if (reason.is_overlay and (reason.has_transform_animation or reason.has_opacity_animation)) return true;
    if (effect.kind == .rounded_clip) {
        if (node_runtime) |runtime| {
            return runtime.has_active_composite_animation;
        }
    }
    return false;
}

fn hasSameLinearTransform(a: types.Transform2D, b: types.Transform2D) bool {
    return @abs(a.a - b.a) < 0.0001 and
        @abs(a.b - b.b) < 0.0001 and
        @abs(a.c - b.c) < 0.0001 and
        @abs(a.d - b.d) < 0.0001;
}

fn canReusePromotedSurface(layer: CompositedLayer, transform: ?property_tree_mod.TransformNode, node_runtime: ?scene_runtime_mod.SceneNodeRuntime) bool {
    const runtime = node_runtime orelse return false;
    const current_transform = transform orelse return false;
    if (!layer.promotion_reason.any()) return false;
    if (!runtime.has_promoted_surface_cache) return false;
    // 跨帧身份比较用 stable_id（retained LayerId raw，含 generation），帧内序号
    // 会随节点增删平移，曾造成整批 spurious cache miss。
    if (runtime.promoted_surface_layer_id != layer.stable_id) return false;
    if (runtime.promoted_surface_content_version != runtime.content_version) return false;
    if (layer.promotion_reason.has_transform_animation) {
        return true;
    }
    if (@abs(runtime.promoted_surface_bounds.w - runtime.world_bounds.w) > 0.01) return false;
    if (@abs(runtime.promoted_surface_bounds.h - runtime.world_bounds.h) > 0.01) return false;
    if (!hasSameLinearTransform(runtime.promoted_surface_transform, current_transform.world)) return false;
    return true;
}

// ============================================================================
// Tests
// ============================================================================

test "LayerId is exactly 4 bytes" {
    try testing.expectEqual(@as(usize, 4), @sizeOf(LayerId));
}

test "LayerTree: createLayer / get / destroyLayer" {
    var t = LayerTree.init(testing.allocator, .{});
    defer t.deinit();

    const root_elem: ElementId = .{ .index = 0, .generation = 0 };
    const id = try t.createLayer(root_elem, .root, LayerId.NULL);
    try testing.expect(t.isAlive(id));
    try testing.expect(t.root.eql(id));

    const layer = t.get(id).?;
    try testing.expectEqual(PromotionReason.root, layer.reason);

    t.destroyLayer(id);
    try testing.expect(!t.isAlive(id));
}

test "LayerTree: assignElement + layerOf reverse lookup" {
    var t = LayerTree.init(testing.allocator, .{});
    defer t.deinit();

    const root_elem: ElementId = .{ .index = 0, .generation = 0 };
    const layer = try t.createLayer(root_elem, .root, LayerId.NULL);

    const e1: ElementId = .{ .index = 1, .generation = 0 };
    const e2: ElementId = .{ .index = 2, .generation = 0 };
    try t.assignElement(layer, e1);
    try t.assignElement(layer, e2);

    try testing.expect(t.layerOf(e1).?.eql(layer));
    try testing.expect(t.layerOf(e2).?.eql(layer));
    try testing.expect(t.layerOf(.{ .index = 99, .generation = 0 }) == null);
}

test "LayerTree: addDamage marks needs_repaint and unions rect" {
    var t = LayerTree.init(testing.allocator, .{});
    defer t.deinit();

    const root_elem: ElementId = .{ .index = 0, .generation = 0 };
    const layer = try t.createLayer(root_elem, .scroll, LayerId.NULL);
    try testing.expect(!t.get(layer).?.needs_repaint);

    t.addDamage(layer, .{ .min_x = 0, .min_y = 0, .max_x = 50, .max_y = 50 });
    try testing.expect(t.get(layer).?.needs_repaint);

    t.addDamage(layer, .{ .min_x = 30, .min_y = 30, .max_x = 100, .max_y = 100 });
    const dmg = t.get(layer).?.damage_rect;
    try testing.expectEqual(@as(f32, 0), dmg.min_x);
    try testing.expectEqual(@as(f32, 100), dmg.max_x);
}

test "LayerTree: beginFrame clears damage" {
    var t = LayerTree.init(testing.allocator, .{});
    defer t.deinit();

    const root_elem: ElementId = .{ .index = 0, .generation = 0 };
    const layer = try t.createLayer(root_elem, .root, LayerId.NULL);
    t.addDamage(layer, .{ .min_x = 0, .min_y = 0, .max_x = 50, .max_y = 50 });

    t.beginFrame();
    try testing.expect(!t.get(layer).?.needs_repaint);
    try testing.expectEqual(@as(f32, 0), t.get(layer).?.damage_rect.max_x);
}

test "LayerTree: destroyLayer cleans up element_to_layer" {
    var t = LayerTree.init(testing.allocator, .{});
    defer t.deinit();

    const root_elem: ElementId = .{ .index = 0, .generation = 0 };
    const layer = try t.createLayer(root_elem, .root, LayerId.NULL);
    const e1: ElementId = .{ .index = 1, .generation = 0 };
    try t.assignElement(layer, e1);

    t.destroyLayer(layer);
    try testing.expect(t.layerOf(e1) == null);
}

test "LayerTree: liveLayerCount" {
    var t = LayerTree.init(testing.allocator, .{});
    defer t.deinit();
    try testing.expectEqual(@as(u32, 0), t.liveLayerCount());

    const root_elem: ElementId = .{ .index = 0, .generation = 0 };
    const a = try t.createLayer(root_elem, .root, LayerId.NULL);
    _ = try t.createLayer(root_elem, .scroll, a);
    _ = try t.createLayer(root_elem, .transform_animating, a);
    try testing.expectEqual(@as(u32, 3), t.liveLayerCount());

    t.destroyLayer(a);
    try testing.expectEqual(@as(u32, 2), t.liveLayerCount());
}

test "LayerTree: setGpuTextureHandle / destroy with release callback" {
    var t = LayerTree.init(testing.allocator, .{});
    defer t.deinit();

    const root_elem: ElementId = .{ .index = 0, .generation = 0 };
    const layer = try t.createLayer(root_elem, .scroll, LayerId.NULL);
    t.setGpuTextureHandle(layer, 0xDEADBEEF);
    try testing.expectEqual(@as(u64, 0xDEADBEEF), t.gpuTextureHandle(layer));

    const Captured = struct {
        last_handle: u64 = 0,
        var release_count: u32 = 0;

        fn cb(ctx: *anyopaque, handle: u64) void {
            const c: *@This() = @ptrCast(@alignCast(ctx));
            c.last_handle = handle;
            release_count += 1;
        }
    };
    var captured = Captured{};
    Captured.release_count = 0;

    t.destroyLayerWithRelease(layer, &Captured.cb, &captured);
    try testing.expectEqual(@as(u64, 0xDEADBEEF), captured.last_handle);
    try testing.expectEqual(@as(u32, 1), Captured.release_count);
    try testing.expect(!t.isAlive(layer));
}

test "LayerTree: destroyLayer (no callback) just drops GPU handle" {
    var t = LayerTree.init(testing.allocator, .{});
    defer t.deinit();

    const root_elem: ElementId = .{ .index = 0, .generation = 0 };
    const layer = try t.createLayer(root_elem, .scroll, LayerId.NULL);
    t.setGpuTextureHandle(layer, 0xCAFE);

    t.destroyLayer(layer);
    try testing.expect(!t.isAlive(layer));
    // 没有 release callback, GPU handle 由 caller 自管（接 ResourcePool 时由
    // pool.release 走 epoch retirement queue）
}

test "LayerTree: ABA — destroyed id rejected after slot reuse" {
    var t = LayerTree.init(testing.allocator, .{});
    defer t.deinit();

    const root_elem: ElementId = .{ .index = 0, .generation = 0 };
    const a = try t.createLayer(root_elem, .root, LayerId.NULL);
    t.destroyLayer(a);

    const b = try t.createLayer(root_elem, .scroll, LayerId.NULL);
    try testing.expectEqual(a.index, b.index); // 复用 slot
    try testing.expect(a.generation != b.generation);
    try testing.expect(!t.isAlive(a));
    try testing.expect(t.isAlive(b));
}

test "P1.10': planAppendLayer creates layer in tree and returns plan_id" {
    var tree = LayerTree.init(testing.allocator, .{});
    defer tree.deinit();

    const live_before = tree.liveLayerCount();
    const plan_id = try tree.planAppendLayer(.{
        .root_node_id = 1,
        .content_bounds_local = ComputedRect.init(0, 0, 100, 100),
        .surface_bounds_world = ComputedRect.init(0, 0, 100, 100),
        .transform_id = 0,
        .effect_id = 0,
        .effect_kind = .composited_group,
    });
    try testing.expectEqual(@as(u32, 0), plan_id);
    try testing.expectEqual(live_before + 1, tree.liveLayerCount());

    const tree_id = tree.planTreeLayerOf(plan_id);
    try testing.expect(!tree_id.isNull());
    try testing.expect(tree.isAlive(tree_id));
}

test "retained plan: planClear 保留 layer，跨帧身份稳定，epoch sweep 清退场" {
    var tree = LayerTree.init(testing.allocator, .{});
    defer tree.deinit();

    tree.plan_epoch += 1;
    _ = try tree.planAppendLayer(.{
        .root_node_id = 1,
        .content_bounds_local = ComputedRect.init(0, 0, 100, 100),
        .surface_bounds_world = ComputedRect.init(0, 0, 100, 100),
        .transform_id = 0,
        .effect_id = 0,
        .effect_kind = .composited_group,
    });
    _ = try tree.planAppendLayer(.{
        .root_node_id = 2,
        .content_bounds_local = ComputedRect.init(0, 0, 50, 50),
        .surface_bounds_world = ComputedRect.init(0, 0, 50, 50),
        .transform_id = 0,
        .effect_id = 1,
        .effect_kind = .opacity,
    });
    try testing.expectEqual(@as(u32, 2), tree.liveLayerCount());
    const stable_a = tree.planCompositedAt(0).?.stable_id;

    // retained：planClear 只清 ops/ordinal 索引，layer 跨帧存活
    tree.planClear();
    try testing.expectEqual(@as(u32, 2), tree.liveLayerCount());
    try testing.expectEqual(@as(usize, 0), tree.frame_layer_ids.items.len);

    // 下一帧同 node 重现 -> 复用同一 layer（stable_id 不变），ordinal 可以不同
    tree.plan_epoch += 1;
    _ = try tree.planAppendLayer(.{
        .root_node_id = 1,
        .content_bounds_local = ComputedRect.init(0, 0, 100, 100),
        .surface_bounds_world = ComputedRect.init(0, 0, 100, 100),
        .transform_id = 0,
        .effect_id = 0,
        .effect_kind = .composited_group,
    });
    try testing.expectEqual(stable_a, tree.planCompositedAt(0).?.stable_id);
    // node 2 本帧未出现 -> sweep 后销毁
    tree.planSweepStale();
    try testing.expectEqual(@as(u32, 1), tree.liveLayerCount());
}

test "P1.10': planMarkLayerSurfaceInvalidated forwards to tree by plan id" {
    var tree = LayerTree.init(testing.allocator, .{});
    defer tree.deinit();

    const plan_id = try tree.planAppendLayer(.{
        .root_node_id = 1,
        .content_bounds_local = ComputedRect.init(0, 0, 100, 100),
        .surface_bounds_world = ComputedRect.init(0, 0, 100, 100),
        .transform_id = 0,
        .effect_id = 0,
        .effect_kind = .composited_group,
    });
    tree.planMarkLayerSurfaceInvalidated(plan_id, .self);

    const tree_id = tree.planTreeLayerOf(plan_id);
    const tree_layer = tree.get(tree_id).?;
    try testing.expect(!tree_layer.frame_flags.surface_valid);
    try testing.expect(tree_layer.frame_flags.invalidated_by_self_this_frame);
    try testing.expect(!tree_layer.frame_flags.invalidated_by_descendant_this_frame);

    tree.planMarkLayerSurfaceInvalidated(plan_id, .descendant);
    const tree_layer2 = tree.get(tree_id).?;
    try testing.expect(tree_layer2.frame_flags.invalidated_by_descendant_this_frame);
}

test "P1.10': planMarkLayerSurfaceReused matches semantics" {
    var tree = LayerTree.init(testing.allocator, .{});
    defer tree.deinit();

    const plan_id = try tree.planAppendLayer(.{
        .root_node_id = 1,
        .content_bounds_local = ComputedRect.init(0, 0, 100, 100),
        .surface_bounds_world = ComputedRect.init(0, 0, 100, 100),
        .transform_id = 0,
        .effect_id = 0,
        .effect_kind = .composited_group,
    });
    tree.planMarkLayerSurfaceInvalidated(plan_id, .self);
    tree.planMarkLayerSurfaceReused(plan_id);

    const tree_id = tree.planTreeLayerOf(plan_id);
    const tree_layer = tree.get(tree_id).?;
    try testing.expect(tree_layer.frame_flags.surface_valid);
    try testing.expect(tree_layer.frame_flags.reused_this_frame);
    try testing.expect(!tree_layer.frame_flags.invalidated_by_self_this_frame);
    try testing.expect(!tree_layer.frame_flags.rebuilt_this_frame);

    const ff = tree.planFrameFlagsOf(plan_id);
    try testing.expectEqual(tree_layer.frame_flags.surface_valid, ff.surface_valid);
    try testing.expectEqual(tree_layer.frame_flags.reused_this_frame, ff.reused_this_frame);
    try testing.expectEqual(tree_layer.frame_flags.rebuilt_this_frame, ff.rebuilt_this_frame);
}

test "P1.10': planMarkLayerSurfaceRebuilt + planMarkLayerDescendantScoped" {
    var tree = LayerTree.init(testing.allocator, .{});
    defer tree.deinit();

    const plan_id = try tree.planAppendLayer(.{
        .root_node_id = 1,
        .content_bounds_local = ComputedRect.init(0, 0, 100, 100),
        .surface_bounds_world = ComputedRect.init(0, 0, 100, 100),
        .transform_id = 0,
        .effect_id = 0,
        .effect_kind = .composited_group,
    });

    tree.planMarkLayerSurfaceRebuilt(plan_id);
    const tree_id = tree.planTreeLayerOf(plan_id);
    var tree_layer = tree.get(tree_id).?;
    try testing.expect(tree_layer.frame_flags.surface_valid);
    try testing.expect(tree_layer.frame_flags.rebuilt_this_frame);
    try testing.expect(!tree_layer.frame_flags.reused_this_frame);

    tree.planMarkLayerDescendantScopedRebuildCandidate(plan_id);
    tree_layer = tree.get(tree_id).?;
    try testing.expect(tree_layer.frame_flags.descendant_scoped_rebuild_candidate_this_frame);
}

test "P1.10': planAppendLayer mirrors CompositedLayer to tree.composited" {
    var tree = LayerTree.init(testing.allocator, .{});
    defer tree.deinit();

    const plan_id = try tree.planAppendLayer(.{
        .root_node_id = 42,
        .content_bounds_local = ComputedRect.init(0, 0, 100, 50),
        .surface_bounds_world = ComputedRect.init(10, 20, 100, 50),
        .transform_id = 7,
        .effect_id = 3,
        .effect_kind = .opacity,
        .opacity = 0.5,
    });

    const tree_id = tree.planTreeLayerOf(plan_id);
    const tree_layer = tree.get(tree_id).?;
    try testing.expect(tree_layer.composited != null);
    const c = tree_layer.composited.?;
    try testing.expectEqual(@as(u32, 42), c.root_node_id);
    try testing.expectEqual(@as(u32, 7), c.transform_id);
    try testing.expectEqual(@as(u32, 3), c.effect_id);
    try testing.expectEqual(EffectKind.opacity, c.effect_kind);
    try testing.expectEqual(@as(f32, 0.5), c.opacity);
    try testing.expectApproxEqAbs(@as(f32, 100), c.surface_bounds_world.w, 0.001);
}

// =============================================================================
// Compositor types (CompositedLayer / CompositeOp etc), historically lived in
// compositor_plan.zig; merged into layer_tree.zig with the API that operates on
// them now living on the LayerTree struct itself (P1.10' 2026-05-01).
// =============================================================================

/// Phase L5: Layer promotion 原因（CompositorPlan 内部使用，区别于 LayerTree 自己
/// 的 PromotionReason enum）
pub const CompositedPromotionReason = packed struct(u16) {
    has_transform_animation: bool = false,
    has_opacity_animation: bool = false,
    has_filter_effect: bool = false,
    text_with_transform_animation: bool = false,
    is_overlay: bool = false,
    has_will_change_transform: bool = false,
    has_will_change_opacity: bool = false,
    explicit_composited_group: bool = false,
    is_scroll_container: bool = false,
    _pad: u7 = 0,

    pub fn any(self: CompositedPromotionReason) bool {
        return self.has_transform_animation or
            self.has_opacity_animation or
            self.has_filter_effect or
            self.text_with_transform_animation or
            self.is_overlay or
            self.has_will_change_transform or
            self.has_will_change_opacity or
            self.explicit_composited_group or
            self.is_scroll_container;
    }
};

/// CompositedLayer 标志（旧 CompositorPlan 私有 LayerFlags）。
/// P1.5'（2026-05-01）：6 个 frame state 字段（surface_valid / reused / rebuilt /
/// invalidated_by_self / invalidated_by_descendant / descendant_scoped_rebuild_candidate）
/// 已下移到 LayerTree.frame_flags（参 P1.4'）。这里仅保留 plan-stable 的 promotion 元
/// 数据（is_animating / contains_text）。读 frame state 用 plan.frameFlagsOf(plan_id)。
const CompositedLayerFlags = packed struct(u8) {
    is_animating: bool = false,
    contains_text: bool = false,
    _reserved: u6 = 0,
};

/// 一个需要离屏合成的子树
pub const CompositedLayer = struct {
    layer_id: u32 = 0,
    /// 跨帧稳定身份（retained tree LayerId 的 packed raw，含 generation ABA 防护）。
    /// layer_id 是帧内序号（仅本帧 ops 引用用）；**所有跨帧比较必须用 stable_id**。
    stable_id: u32 = INVALID_ID,
    root_node_id: u32,
    content_bounds_local: ComputedRect,
    surface_bounds_world: ComputedRect,
    transform_id: u32,
    clip_id: u32 = INVALID_ID,
    effect_id: u32,
    effect_kind: EffectKind,
    opacity: f32 = 1.0,
    blend_mode: types.BlendMode = .normal,
    glass: types.ResolvedGlassParams = .{},
    corner_radius: [4]f32 = .{ 0, 0, 0, 0 },
    content_version: u32 = 0,
    flags: CompositedLayerFlags = .{},
    promotion_reason: CompositedPromotionReason = .{},
    has_surface_transform: bool = false,
    surface_rotate: f32 = 0,
    surface_draw_transform: types.Transform2D = types.Transform2D.identity(),
    surface_parent_inverse: types.Transform2D = types.Transform2D.identity(),
    surface_source_bounds: ComputedRect = ComputedRect.init(0, 0, 0, 0),
    surface_draw_bounds: ComputedRect = ComputedRect.init(0, 0, 0, 0),
};

/// 合成操作
const CompositeOp = union(enum) {
    begin_surface: struct {
        layer_id: u32,
        bounds: ComputedRect,
    },
    end_surface: struct {
        layer_id: u32,
    },
    draw_surface: struct {
        layer_id: u32,
        opacity: f32,
        transform_id: u32,
    },
    apply_clip: struct {
        effect_id: u32,
        clip_id: u32,
        bounds: ComputedRect,
        shape_kind: display_list_mod.ClipShapeKind = .rect,
        radius: f32 = 0,
        polygon: display_list_mod.ClipPolygon = .{},
        bounds_fallback: bool = false,
    },
};

test "LayerTree: 世代回卷前 slot 永久退役（悬垂 LayerId 不复活）" {
    var t = LayerTree.init(testing.allocator, .{});
    defer t.deinit();

    const root_elem: ElementId = .{ .index = 0, .generation = 0 };
    const first = try t.createLayer(root_elem, .root, LayerId.NULL);
    t.destroyLayer(first);

    // 单 slot 反复 create/destroy：每周期 generation +2。
    // 旧实现回卷后陈旧 LayerId 会重新 isAlive（alive 位挡不住复用槽）。
    var cycles: u32 = 0;
    while (cycles < 200) : (cycles += 1) {
        const id = try t.createLayer(root_elem, .root, LayerId.NULL);
        if (id.index != first.index) {
            t.destroyLayer(id);
            break;
        }
        try testing.expect(!t.isAlive(first));
        t.destroyLayer(id);
    }
    try testing.expect(cycles < 200);
    try testing.expect(!t.isAlive(first));
}

// ---------------------------------------------------------------------------
// （2026-09-14）：LayerTree 槽位表的分配/回滚契约。
// ---------------------------------------------------------------------------

/// 两张平行表必须永远同长；活 layer 必须都能从 plan_by_node 或 frame_layer_ids 找到
/// （否则 epoch sweep 永远回收不到它）。
fn expectLayerTreeInvariants(t: *const LayerTree) !void {
    try testing.expectEqual(t.layers.items.len, t.generations.items.len);
    // plan 路径建的 layer：活 layer 数 == plan_by_node 里活条目数
    var planned_alive: u32 = 0;
    var it = t.plan_by_node.iterator();
    while (it.next()) |entry| {
        if (t.isAlive(entry.value_ptr.*)) planned_alive += 1;
    }
    try testing.expectEqual(planned_alive, t.liveLayerCount());
}

test "LayerTree: createLayer 在任意分配点失败都不留下 layers/generations 错位的半个 layer" {
    var fail_index: usize = 0;
    while (fail_index < 64) : (fail_index += 1) {
        var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        const a = failing.allocator();
        var t = LayerTree.init(a, .{});
        defer t.deinit();
        const root_elem: ElementId = .{ .index = 0, .generation = 0 };
        var created: u32 = 0;
        var i: usize = 0;
        while (i < 40) : (i += 1) {
            const r = t.createLayer(root_elem, .root, LayerId.NULL);
            try testing.expectEqual(t.layers.items.len, t.generations.items.len);
            if (r) |_| {
                created += 1;
            } else |err| {
                try testing.expectEqual(error.OutOfMemory, err);
                break;
            }
        }
        try testing.expectEqual(created, t.liveLayerCount());
        // 失败之后表仍然可用：isAlive 对任何下标都不越界。
        const probe: LayerId = .{ .index = @intCast(t.layers.items.len), .generation = 0 };
        try testing.expect(!t.isAlive(probe));
        if (!failing.has_induced_failure) break;
    }
}

test "LayerTree: planAppendLayer 在任意分配点失败都不留下 sweep 永远收不到的孤儿 layer" {
    var fail_index: usize = 0;
    while (fail_index < 64) : (fail_index += 1) {
        var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        const a = failing.allocator();
        var t = LayerTree.init(a, .{});
        defer t.deinit();
        t.plan_epoch += 1;
        var node: u32 = 1;
        while (node <= 20) : (node += 1) {
            const r = t.planAppendLayer(.{
                .root_node_id = node,
                .content_bounds_local = ComputedRect.init(0, 0, 10, 10),
                .surface_bounds_world = ComputedRect.init(0, 0, 10, 10),
                .transform_id = 0,
                .effect_id = node,
                .effect_kind = .opacity,
            });
            try expectLayerTreeInvariants(&t);
            if (r) |_| {} else |err| {
                try testing.expectEqual(error.OutOfMemory, err);
                break;
            }
        }
        // 下一帧一个都不出现：sweep 必须把全部活 layer 收干净（孤儿收不到就会剩下）。
        t.plan_epoch += 1;
        t.planClear();
        t.planSweepStale();
        try testing.expectEqual(@as(u32, 0), t.liveLayerCount());
        try testing.expectEqual(@as(usize, 0), t.plan_by_node.count());
        if (!failing.has_induced_failure) break;
    }
}

test "LayerTree: 一帧退场超过 64 个 layer 时 plan_by_node 一次清干净" {
    var t = LayerTree.init(testing.allocator, .{});
    defer t.deinit();
    t.plan_epoch += 1;
    var node: u32 = 1;
    while (node <= 150) : (node += 1) {
        _ = try t.planAppendLayer(.{
            .root_node_id = node,
            .content_bounds_local = ComputedRect.init(0, 0, 10, 10),
            .surface_bounds_world = ComputedRect.init(0, 0, 10, 10),
            .transform_id = 0,
            .effect_id = node,
            .effect_kind = .opacity,
        });
    }
    try testing.expectEqual(@as(u32, 150), t.liveLayerCount());
    t.plan_epoch += 1;
    t.planClear();
    t.planSweepStale();
    try testing.expectEqual(@as(u32, 0), t.liveLayerCount());
    // 以前只跑一趟：这里会剩 86 条已销毁 layer 的 key。
    try testing.expectEqual(@as(usize, 0), t.plan_by_node.count());
}

test "LayerTree: planBuildFromPropertyTree 在任意分配点失败都不 abort、不留半截 op 三元组" {
    const effects = [_]property_tree_mod.EffectNode{
        .{ .parent = INVALID_ID, .transform_id = 0, .node_id = 1, .kind = .opacity, .requires_offscreen = true, .local_bounds = ComputedRect.init(0, 0, 10, 10) },
        .{ .parent = INVALID_ID, .transform_id = 0, .node_id = 2, .kind = .composited_group, .requires_offscreen = true, .local_bounds = ComputedRect.init(0, 0, 20, 20) },
        .{ .parent = INVALID_ID, .transform_id = 0, .node_id = 3, .kind = .opacity, .requires_offscreen = true, .local_bounds = ComputedRect.init(0, 0, 30, 30) },
    };
    var fail_index: usize = 0;
    while (fail_index < 64) : (fail_index += 1) {
        var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        const a = failing.allocator();
        var t = LayerTree.init(a, .{});
        defer t.deinit();
        // 修复前：注入命中 op 追加时 @panic，整个测试进程 abort。
        t.planBuildFromPropertyTree(&effects, &.{}, &.{}, null);
        try expectLayerTreeInvariants(&t);
        // 每个进了 plan 的 layer 都必须有完整的 begin/end/draw；op 里引用的 layer 都必须在 plan 里。
        var begins: usize = 0;
        var ends: usize = 0;
        var draws: usize = 0;
        for (t.frame_ops.items) |op| switch (op) {
            .begin_surface => |b| {
                begins += 1;
                try testing.expect(b.layer_id < t.frame_layer_ids.items.len);
            },
            .end_surface => ends += 1,
            .draw_surface => draws += 1,
            else => {},
        };
        try testing.expectEqual(t.frame_layer_ids.items.len, begins);
        try testing.expectEqual(begins, ends);
        try testing.expectEqual(begins, draws);
        if (!failing.has_induced_failure) {
            // 没注入到任何分配点 = 完整成功：三个 effect 全进。
            try testing.expectEqual(@as(usize, 3), t.frame_layer_ids.items.len);
            break;
        }
    }
}

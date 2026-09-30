const std = @import("std");
const node_dirty_gen = @import("node_dirty.zig");

const types = @import("types.zig");
const node_mod = @import("node.zig");
const interaction_semantics = @import("interaction_semantics.zig");
const retained_scene = @import("retained_scene.zig");
const paint_order = @import("paint_order.zig");

const Allocator = std.mem.Allocator;
const ComputedRect = types.ComputedRect;
const Transform2D = types.Transform2D;
const Point = types.Point;
const HitShapeSpec = types.HitShapeSpec;
const ClipShapeSpec = types.ClipShapeSpec;
const HitBehavior = types.HitBehavior;
const HitRoles = types.HitRoles;
const RingArcHitSpec = types.RingArcHitSpec;
const PathFillRule = types.PathFillRule;
const PathGeometry = types.PathGeometry;
const PathCommand = types.PathCommand;
const HitProxySpec = types.HitProxySpec;
const max_node_hit_proxies = types.max_node_hit_proxies;
const Node = node_mod.Node;

pub const NodeHandle = struct {
    id: u32,
    generation: u32 = 1,
};

pub const PerfCounters = struct {
    hit_test_count: u32 = 0,
    cursor_hit_test_count: u32 = 0,
    registry_resolve_count: u32 = 0,
    /// Nodes visited by `syncPaintToTable`, i.e. the size of the live node
    /// tree. The remaining end-of-frame shadow-sync passes (paint, interaction,
    /// a11y) are each an ungated full-tree recursion, so frame cost is O(this)
    /// — it is the number to watch when a frame gets slower without any single
    /// stage getting slower. Reset and counted in the same function so the two
    /// cannot drift apart.
    synced_node_count: u32 = 0,
    tick_before_render_count: u32 = 0,
    render_cache_hit: u32 = 0,
    render_cache_miss: u32 = 0,
    display_list_own_prebuild_count: u32 = 0,
    display_list_own_replay_count: u32 = 0,
    display_list_subtree_replay_count: u32 = 0,
    display_list_subtree_prebuild_count: u32 = 0,
    display_list_self_effect_subtree_replay_count: u32 = 0,
    /// 单点脏帧放大器修复（下游回归）：paint/prebuild 重录计数。
    /// own_content_emit_count = appendNodeOwnContent 真实重录节点数（fresh emit）；
    /// subtree_payload_splice_count = 干净子树跨帧 payload 直接 splice 命中数；
    /// subtree_payload_cache_write_count = 本帧写入的跨帧 payload 缓存数。
    own_content_emit_count: u32 = 0,
    subtree_payload_splice_count: u32 = 0,
    /// 下游回归：splice 时 header 帧内序号 (transform/clip/effect_id) 与本帧
    /// scene_runtime 不一致而被**改写**的 item 条数（rewriteSplicedItemHeaders）。
    /// 观测计数：非 0 表示本帧确有 id 平移发生且已被纠正，非错误。
    subtree_payload_stale_header_count: u32 = 0,
    /// splice 时 item 所属 node 在**本帧** scene_runtime 里不存在（典型：运行时
    /// setOpacity(0) 后子树整支跳过遍历）而被**丢弃**的 item 条数。丢弃是语义
    /// 正确的：没被遍历 = 不可见/已摘除，不该画；带 stale id 放行会索引到
    /// 别的元素的 transform（下游应用 layers 残影：键画到行左）。
    subtree_payload_absent_node_drop_count: u32 = 0,
    subtree_payload_cache_write_count: u32 = 0,
    descendant_scoped_promoted_rebuild_count: u32 = 0,
    descendant_scoped_promoted_cache_splice_count: u32 = 0,
    descendant_scoped_promoted_self_replay_count: u32 = 0,
    descendant_scoped_promoted_descendant_pass_replay_count: u32 = 0,
    descendant_scoped_promoted_tail_replay_count: u32 = 0,
    descendant_scoped_promoted_regular_child_replay_count: u32 = 0,
    focus_rebuild_count: u32 = 0,
    focus_order_rebuild_count: u32 = 0,
    interaction_full_rebuild_count: u32 = 0,
    interaction_partial_rebuild_count: u32 = 0,
    continuous_redraw_frames: u32 = 0,
    mouse_move_hit_test_count: u32 = 0,
    layout_us: u64 = 0,
    inner_layout_us: u64 = 0,
    render_node_us: u64 = 0,
    render_us: u64 = 0,
    before_render_us: u64 = 0,
    tick_nodes: u32 = 0,
    tick_hooks: u32 = 0,
    slow_hook_us: u64 = 0,
    slow_hook_name: [64]u8 = [_]u8{0} ** 64,
    slow_hook_name_len: u8 = 0,

    /// Stage B-1/B-2: GpuDraw shadow encode 统计（debug build only）。
    stage_b_shadow_display_items: u32 = 0,
    stage_b_shadow_drawable_commands: u32 = 0,
    stage_b_shadow_gpu_draws: u32 = 0,
    stage_b_shadow_count_mismatches: u32 = 0,
    /// B-2: pipeline 序列等价检查 — 应永远 0；> 0 说明主路径 → GpuDraw
    /// 的 pipeline kind 序列不一致（lowering 漏 case 或主路径产了 shadow 没产的）
    stage_b_shadow_pipeline_mismatches: u32 = 0,
    /// B-5: paint_table.DisplayItem.geom 字段值与 display_list 各 kind 的
    /// (x,y,w,h) 字段值等价检查 — 应永远 0；> 0 说明 lowerDisplayItem 的
    /// 几何字段映射有 bug。给 B-6 真切换 encoder 主路径前的强约束。
    stage_b_shadow_field_value_mismatches: u32 = 0,
    /// B-2: 累计最大 batch run 长度（debug 观察 batcher 效果）
    stage_b_shadow_max_batch_run: u32 = 0,

    /// B-2 coverage probe: 按 lowered kind 累计 display_list item 数。
    /// 与 stage_b_shadow_drawable_kind_* 对位 — 相等说明该 kind 在 shadow
    /// 路径已 100% 覆盖，可作为下一步主路径 flip 候选。
    stage_b_shadow_kind_rect: u32 = 0,
    stage_b_shadow_kind_text: u32 = 0,
    stage_b_shadow_kind_image: u32 = 0,
    stage_b_shadow_kind_path: u32 = 0,
    stage_b_shadow_kind_shadow: u32 = 0,
    stage_b_shadow_kind_gradient: u32 = 0,
    /// B-2 coverage probe: 按 pipeline id 累计主路径 drawable command 数。
    stage_b_shadow_drawable_kind_rect: u32 = 0,
    stage_b_shadow_drawable_kind_text: u32 = 0,
    stage_b_shadow_drawable_kind_image: u32 = 0,
    stage_b_shadow_drawable_kind_path: u32 = 0,
    stage_b_shadow_drawable_kind_shadow: u32 = 0,
    stage_b_shadow_drawable_kind_gradient: u32 = 0,

    br_initial_layout_us: u64 = 0,
    br_tick_us: u64 = 0,
    br_post_layout_us: u64 = 0,
    br_index_us: u64 = 0,
    phase_begin_us: u64 = 0,
    phase_retained_us: u64 = 0,
    phase_compositor_us: u64 = 0,
    phase_sync_us: u64 = 0,
    phase_prebuild_us: u64 = 0,
    phase_replay_us: u64 = 0,
    encode_us: u64 = 0,
    /// GPU command buffer finish + submit + present 耗时（宿主填）。
    submit_us: u64 = 0,
    /// 本帧 CPU 段之和（layout + render + encode + … ，不含 wait/acquire）。
    /// 宿主填，用于喂 CPU-only 的百分位环 —— 见 Cx.pushCpuFrameUs。
    cpu_frame_us: u64 = 0,
    /// 帧首的 deferred work 排空耗时（宿主填）。
    drain_us: u64 = 0,
    /// 文本 atlas 预热（RenderCommandEncoder.prewarmDisplay）耗时。
    /// 宿主填。滚动时可见文本每帧都在变，prewarm 的跳帧签名不命中，
    /// 这一段会退化成"把所有可见文本再塑形一遍"，是帧里最贵的一段之一 ——
    /// 不单独计时的话它会整段藏在 cpu_us 里，看起来像凭空多出来的开销。
    prewarm_us: u64 = 0,
    flush_us: u64 = 0,
    wait_us: u64 = 0,
    acquire_us: u64 = 0,
    cpu_us: u64 = 0,
    total_us: u64 = 0,
    barrier_flush_count: u32 = 0,
    scissor_flush_count: u32 = 0,
    offscreen_layer_count: u32 = 0,
    offscreen_pass_switch_count: u32 = 0,
    structural_noop_pair_skipped_count: u32 = 0,
    local_sort_cluster_count: u32 = 0,
    local_sort_reordered_command_count: u32 = 0,
    local_sort_overlap_reject_count: u32 = 0,
    local_sort_capacity_fallback_count: u32 = 0,
    deferred_main_pass_fast_path: u32 = 0,
    live_render_pass_requirement_bits: u32 = 0,

    pub fn resetFrame(self: *PerfCounters) void {
        const carry_redraw = self.continuous_redraw_frames;
        self.* = .{};
        self.continuous_redraw_frames = carry_redraw;
    }
};

const RegistryEntry = struct {
    ptr: *Node,
    generation: u32 = 1,
};

const GenerationEntry = struct {
    generation: u32 = 1,
    last_ptr: ?*Node = null,
};

pub const NodeRegistry = struct {
    allocator: Allocator,
    entries: std.AutoHashMap(u32, RegistryEntry),
    generations: std.AutoHashMap(u32, GenerationEntry),

    pub fn init(allocator: Allocator) NodeRegistry {
        return .{
            .allocator = allocator,
            .entries = std.AutoHashMap(u32, RegistryEntry).init(allocator),
            .generations = std.AutoHashMap(u32, GenerationEntry).init(allocator),
        };
    }

    pub fn deinit(self: *NodeRegistry) void {
        self.entries.deinit();
        self.generations.deinit();
    }

    pub fn clear(self: *NodeRegistry) void {
        self.entries.clearRetainingCapacity();
    }

    pub fn rebuild(self: *NodeRegistry, root: ?*Node) !void {
        self.clear();
        if (root) |r| try self.registerRecursive(r);
    }

    fn registerRecursive(self: *NodeRegistry, node: *Node) !void {
        const generation = try self.trackGeneration(node);
        try self.entries.put(node.id, .{ .ptr = node, .generation = generation });
        for (node.children.items) |child| {
            try self.registerRecursive(child);
        }
    }

    pub fn unregisterSubtree(self: *NodeRegistry, root: *Node) void {
        _ = self.entries.remove(root.id);
        if (self.generations.getPtr(root.id)) |entry| entry.last_ptr = null;
        for (root.children.items) |child| self.unregisterSubtree(child);
    }

    pub fn detachSubtree(self: *NodeRegistry, root: *Node) void {
        _ = self.entries.remove(root.id);
        for (root.children.items) |child| self.detachSubtree(child);
    }

    /// 节点释放后整条移除（原来只把 last_ptr 置 null，generations 只增不减，
    /// 长跑的列表型应用每建一个节点就永久多一行）。可以删的前提：生产路径
    /// 的节点 id 全部来自 Cx.nextId（单调递增、不复用），释放后同 id 不会
    /// 再出现，也就不需要保留代次去区分"同 id 的下一个节点"。
    pub fn noteNodeFreed(self: *NodeRegistry, node_id: u32) void {
        _ = self.entries.remove(node_id);
        _ = self.generations.remove(node_id);
    }

    pub fn handleFor(self: *const NodeRegistry, node: *Node) NodeHandle {
        if (self.entries.get(node.id)) |entry| {
            return .{ .id = node.id, .generation = entry.generation };
        }
        return .{ .id = node.id };
    }

    /// Whether `handle` still names exactly `node`, including before the node
    /// has entered the current registry snapshot. `trackGeneration` establishes
    /// this identity; `noteNodeFreed`/`unregisterSubtree` invalidate it.
    pub fn isCurrentIdentity(self: *const NodeRegistry, handle: NodeHandle, node: *Node) bool {
        const entry = self.generations.get(handle.id) orelse return false;
        return entry.generation == handle.generation and entry.last_ptr == node;
    }

    pub fn resolve(self: *const NodeRegistry, handle: ?NodeHandle, perf: ?*PerfCounters) ?*Node {
        const h = handle orelse return null;
        if (perf) |p| p.registry_resolve_count += 1;
        const entry = self.entries.get(h.id) orelse return null;
        if (entry.generation != h.generation) return null;
        return entry.ptr;
    }

    pub fn trackGeneration(self: *NodeRegistry, node: *Node) !u32 {
        const gop = try self.generations.getOrPut(node.id);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{ .generation = 1, .last_ptr = node };
            return 1;
        }
        if (gop.value_ptr.last_ptr != node) {
            gop.value_ptr.generation +%= 1;
            if (gop.value_ptr.generation == 0) gop.value_ptr.generation = 1;
            gop.value_ptr.last_ptr = node;
        }
        return gop.value_ptr.generation;
    }
};

pub const HitQueryKind = enum {
    pointer,
    scroll,
    inspect,
};

pub const HitShapeKind = enum {
    none,
    rect,
    rounded_rect,
    circle,
    ellipse,
    ring_arc,
    path,
    custom,
};

pub const HitQuery = struct {
    kind: HitQueryKind,
    world_x: f32,
    world_y: f32,
    capture_override: ?NodeHandle = null,
};

pub const HitResult = struct {
    handle: NodeHandle,
    proxy_id: u32,
    node_id: u32,
    world_point: Point,
    local_point: Point,
    shape_kind: HitShapeKind,
};

pub const HitQueryCache = struct {
    hovered_result: ?HitResult = null,
    mouse_down_result: ?HitResult = null,
    scroll_session_owner: ?HitResult = null,
    scroll_momentum_owner: ?HitResult = null,
    recent_candidate_window: ?ComputedRect = null,
};

const ShapeRecord = struct {
    kind: HitShapeKind,
    radius: f32 = 0,
    ring_arc: RingArcHitSpec = .{},
    path_fill_rule: PathFillRule = .evenodd,
};

const ClipChainEntry = struct {
    parent_id: ?u32,
    handle: NodeHandle,
    local_rect: ComputedRect,
    shape_id: u32,
    world_aabb: ComputedRect,
    inverse_world_transform: Transform2D,
};

const HitFlags = packed struct(u2) {
    alive: bool = true,
    imprecise_shape: bool = false,
};

pub const HitProxy = struct {
    handle: NodeHandle,
    node_id: u32,
    /// 命中优先级的唯一依据：与渲染逐位一致的绘制序（paint_order.zig 三带
    /// 遍历的 DFS 前序）。z_index 只经由同级排序影响它，没有全局层级。
    paint_order: u64,
    local_rect: ComputedRect,
    true_aabb: ComputedRect,
    fat_aabb: ComputedRect,
    clip_chain_id: ?u32,
    shape_id: u32,
    roles: HitRoles,
    behavior: HitBehavior,
    flags: HitFlags = .{},
    epoch: u32 = 1,
};

const INVALID_INDEX = std.math.maxInt(u32);

const DynamicAabbTree = struct {
    const TreeNode = struct {
        aabb: ComputedRect = ComputedRect.init(0, 0, 0, 0),
        parent: u32 = INVALID_INDEX,
        left: u32 = INVALID_INDEX,
        right: u32 = INVALID_INDEX,
        height: i32 = -1,
        proxy_id: u32 = INVALID_INDEX,
        next: u32 = INVALID_INDEX,

        fn isLeaf(self: TreeNode) bool {
            return self.left == INVALID_INDEX;
        }
    };

    allocator: Allocator,
    nodes: std.ArrayList(TreeNode),
    root: u32 = INVALID_INDEX,
    free_list: u32 = INVALID_INDEX,

    fn init(allocator: Allocator) DynamicAabbTree {
        return .{
            .allocator = allocator,
            .nodes = .{},
        };
    }

    fn deinit(self: *DynamicAabbTree) void {
        self.nodes.deinit(self.allocator);
    }

    fn clear(self: *DynamicAabbTree) void {
        self.nodes.clearRetainingCapacity();
        self.root = INVALID_INDEX;
        self.free_list = INVALID_INDEX;
    }

    fn allocNode(self: *DynamicAabbTree) !u32 {
        if (self.free_list != INVALID_INDEX) {
            const id = self.free_list;
            self.free_list = self.nodes.items[id].next;
            self.nodes.items[id] = .{};
            return id;
        }
        const id: u32 = @intCast(self.nodes.items.len);
        try self.nodes.append(self.allocator, .{});
        return id;
    }

    fn freeNode(self: *DynamicAabbTree, id: u32) void {
        self.nodes.items[id] = .{
            .height = -1,
            .next = self.free_list,
        };
        self.free_list = id;
    }

    fn insert(self: *DynamicAabbTree, proxy_id: u32, aabb: ComputedRect) !u32 {
        const leaf = try self.allocNode();
        self.nodes.items[leaf] = .{
            .aabb = aabb,
            .height = 0,
            .proxy_id = proxy_id,
        };
        // 失败时把刚分配的叶子还回 free_list，否则它会变成孤儿槽位滞留到整树销毁。
        self.insertLeaf(leaf) catch |err| {
            self.freeNode(leaf);
            return err;
        };
        return leaf;
    }

    fn remove(self: *DynamicAabbTree, leaf: u32) void {
        if (leaf == INVALID_INDEX or leaf >= self.nodes.items.len) return;
        if (self.nodes.items[leaf].height < 0) return;
        self.removeLeaf(leaf);
        self.freeNode(leaf);
    }

    fn insertLeaf(self: *DynamicAabbTree, leaf: u32) !void {
        if (self.root == INVALID_INDEX) {
            self.root = leaf;
            self.nodes.items[leaf].parent = INVALID_INDEX;
            return;
        }

        var sibling = self.root;
        while (!self.nodes.items[sibling].isLeaf()) {
            const left = self.nodes.items[sibling].left;
            const right = self.nodes.items[sibling].right;
            const area = perimeter(self.nodes.items[sibling].aabb);
            const combined = unionRect(self.nodes.items[sibling].aabb, self.nodes.items[leaf].aabb);
            const combined_area = perimeter(combined);
            const cost = 2 * combined_area;
            const inheritance_cost = 2 * (combined_area - area);

            const left_cost = computeDescendCost(self.nodes.items, left, self.nodes.items[leaf].aabb, inheritance_cost);
            const right_cost = computeDescendCost(self.nodes.items, right, self.nodes.items[leaf].aabb, inheritance_cost);

            if (cost < left_cost and cost < right_cost) break;
            sibling = if (left_cost < right_cost) left else right;
        }

        const old_parent = self.nodes.items[sibling].parent;
        const new_parent = try self.allocNode();
        self.nodes.items[new_parent] = .{
            .parent = old_parent,
            .aabb = unionRect(self.nodes.items[leaf].aabb, self.nodes.items[sibling].aabb),
            .height = self.nodes.items[sibling].height + 1,
            .left = sibling,
            .right = leaf,
        };

        self.nodes.items[sibling].parent = new_parent;
        self.nodes.items[leaf].parent = new_parent;

        if (old_parent == INVALID_INDEX) {
            self.root = new_parent;
        } else if (self.nodes.items[old_parent].left == sibling) {
            self.nodes.items[old_parent].left = new_parent;
        } else {
            self.nodes.items[old_parent].right = new_parent;
        }

        var index = self.nodes.items[leaf].parent;
        while (index != INVALID_INDEX) {
            index = self.balance(index);
            const left = self.nodes.items[index].left;
            const right = self.nodes.items[index].right;
            self.nodes.items[index].height = 1 + @max(self.nodes.items[left].height, self.nodes.items[right].height);
            self.nodes.items[index].aabb = unionRect(self.nodes.items[left].aabb, self.nodes.items[right].aabb);
            index = self.nodes.items[index].parent;
        }
    }

    fn removeLeaf(self: *DynamicAabbTree, leaf: u32) void {
        if (leaf == self.root) {
            self.root = INVALID_INDEX;
            return;
        }

        const parent = self.nodes.items[leaf].parent;
        const grand_parent = self.nodes.items[parent].parent;
        const sibling = if (self.nodes.items[parent].left == leaf) self.nodes.items[parent].right else self.nodes.items[parent].left;

        if (grand_parent != INVALID_INDEX) {
            if (self.nodes.items[grand_parent].left == parent) {
                self.nodes.items[grand_parent].left = sibling;
            } else {
                self.nodes.items[grand_parent].right = sibling;
            }
            self.nodes.items[sibling].parent = grand_parent;
            self.freeNode(parent);

            var index = grand_parent;
            while (index != INVALID_INDEX) {
                index = self.balance(index);
                const left = self.nodes.items[index].left;
                const right = self.nodes.items[index].right;
                self.nodes.items[index].aabb = unionRect(self.nodes.items[left].aabb, self.nodes.items[right].aabb);
                self.nodes.items[index].height = 1 + @max(self.nodes.items[left].height, self.nodes.items[right].height);
                index = self.nodes.items[index].parent;
            }
        } else {
            self.root = sibling;
            self.nodes.items[sibling].parent = INVALID_INDEX;
            self.freeNode(parent);
        }
    }

    fn balance(self: *DynamicAabbTree, i_a: u32) u32 {
        if (i_a == INVALID_INDEX) return INVALID_INDEX;
        const a = self.nodes.items[i_a];
        if (a.isLeaf() or a.height < 2) return i_a;

        const i_b = a.left;
        const i_c = a.right;
        const b = self.nodes.items[i_b];
        const c = self.nodes.items[i_c];
        const balance_factor = c.height - b.height;

        if (balance_factor > 1) {
            const i_f = c.left;
            const i_g = c.right;
            self.nodes.items[i_c].left = i_a;
            self.nodes.items[i_c].parent = a.parent;
            self.nodes.items[i_a].parent = i_c;

            if (self.nodes.items[i_c].parent != INVALID_INDEX) {
                const parent = self.nodes.items[i_c].parent;
                if (self.nodes.items[parent].left == i_a) {
                    self.nodes.items[parent].left = i_c;
                } else {
                    self.nodes.items[parent].right = i_c;
                }
            } else {
                self.root = i_c;
            }

            if (self.nodes.items[i_f].height > self.nodes.items[i_g].height) {
                self.nodes.items[i_c].right = i_f;
                self.nodes.items[i_a].right = i_g;
                self.nodes.items[i_g].parent = i_a;
                self.nodes.items[i_a].aabb = unionRect(self.nodes.items[i_b].aabb, self.nodes.items[i_g].aabb);
                self.nodes.items[i_c].aabb = unionRect(self.nodes.items[i_a].aabb, self.nodes.items[i_f].aabb);
                self.nodes.items[i_a].height = 1 + @max(self.nodes.items[i_b].height, self.nodes.items[i_g].height);
                self.nodes.items[i_c].height = 1 + @max(self.nodes.items[i_a].height, self.nodes.items[i_f].height);
            } else {
                self.nodes.items[i_c].right = i_g;
                self.nodes.items[i_a].right = i_f;
                self.nodes.items[i_f].parent = i_a;
                self.nodes.items[i_a].aabb = unionRect(self.nodes.items[i_b].aabb, self.nodes.items[i_f].aabb);
                self.nodes.items[i_c].aabb = unionRect(self.nodes.items[i_a].aabb, self.nodes.items[i_g].aabb);
                self.nodes.items[i_a].height = 1 + @max(self.nodes.items[i_b].height, self.nodes.items[i_f].height);
                self.nodes.items[i_c].height = 1 + @max(self.nodes.items[i_a].height, self.nodes.items[i_g].height);
            }
            return i_c;
        }

        if (balance_factor < -1) {
            const i_d = b.left;
            const i_e = b.right;
            self.nodes.items[i_b].left = i_a;
            self.nodes.items[i_b].parent = a.parent;
            self.nodes.items[i_a].parent = i_b;

            if (self.nodes.items[i_b].parent != INVALID_INDEX) {
                const parent = self.nodes.items[i_b].parent;
                if (self.nodes.items[parent].left == i_a) {
                    self.nodes.items[parent].left = i_b;
                } else {
                    self.nodes.items[parent].right = i_b;
                }
            } else {
                self.root = i_b;
            }

            if (self.nodes.items[i_d].height > self.nodes.items[i_e].height) {
                self.nodes.items[i_b].right = i_d;
                self.nodes.items[i_a].left = i_e;
                self.nodes.items[i_e].parent = i_a;
                self.nodes.items[i_a].aabb = unionRect(self.nodes.items[i_c].aabb, self.nodes.items[i_e].aabb);
                self.nodes.items[i_b].aabb = unionRect(self.nodes.items[i_a].aabb, self.nodes.items[i_d].aabb);
                self.nodes.items[i_a].height = 1 + @max(self.nodes.items[i_c].height, self.nodes.items[i_e].height);
                self.nodes.items[i_b].height = 1 + @max(self.nodes.items[i_a].height, self.nodes.items[i_d].height);
            } else {
                self.nodes.items[i_b].right = i_e;
                self.nodes.items[i_a].left = i_d;
                self.nodes.items[i_d].parent = i_a;
                self.nodes.items[i_a].aabb = unionRect(self.nodes.items[i_c].aabb, self.nodes.items[i_d].aabb);
                self.nodes.items[i_b].aabb = unionRect(self.nodes.items[i_a].aabb, self.nodes.items[i_e].aabb);
                self.nodes.items[i_a].height = 1 + @max(self.nodes.items[i_c].height, self.nodes.items[i_d].height);
                self.nodes.items[i_b].height = 1 + @max(self.nodes.items[i_a].height, self.nodes.items[i_e].height);
            }
            return i_b;
        }

        return i_a;
    }
};

pub const HitRuntime = struct {
    allocator: Allocator,
    proxy_aabb_tree: DynamicAabbTree,
    proxies: std.ArrayList(HitProxy),
    proxy_tree_nodes: std.ArrayList(u32),
    shapes: std.ArrayList(ShapeRecord),
    clip_chain: std.ArrayList(ClipChainEntry),
    /// Partial subtree rebuilds append replacement proxies/shapes/clip entries
    /// and tombstone the old proxies. Keep the live count so we can compact
    /// before those append-only backing arrays turn per-frame work into O(age).
    live_proxy_count: usize = 0,
    query_cache: HitQueryCache = .{},

    pub fn init(allocator: Allocator) HitRuntime {
        return .{
            .allocator = allocator,
            .proxy_aabb_tree = DynamicAabbTree.init(allocator),
            .proxies = .{},
            .proxy_tree_nodes = .{},
            .shapes = .{},
            .clip_chain = .{},
        };
    }

    pub fn deinit(self: *HitRuntime) void {
        self.proxy_aabb_tree.deinit();
        self.proxies.deinit(self.allocator);
        self.proxy_tree_nodes.deinit(self.allocator);
        self.shapes.deinit(self.allocator);
        self.clip_chain.deinit(self.allocator);
    }

    pub fn clear(self: *HitRuntime) void {
        self.proxy_aabb_tree.clear();
        self.proxies.clearRetainingCapacity();
        self.proxy_tree_nodes.clearRetainingCapacity();
        self.shapes.clearRetainingCapacity();
        self.clip_chain.clearRetainingCapacity();
        self.live_proxy_count = 0;
        self.clearQueryCache();
    }

    pub fn clearQueryCache(self: *HitRuntime) void {
        self.query_cache = .{};
    }

    pub fn rebuild(self: *HitRuntime, root: ?*Node, registry: *const NodeRegistry) !void {
        self.clear();
        const r = root orelse return;
        clearNodeRangesRecursive(r);
        var paint_cursor: u64 = 0;
        try assignPaintOrderRecursive(self.allocator, r, &paint_cursor);
        try self.buildRecursive(r, registry, Transform2D.identity(), null, false);
    }

    /// Partial rebuild 前刷新全部已烘焙 clip 条目的缓存几何。
    ///
    /// clip_chain 条目在某次（可能早于本次布局收敛的）rebuild 里烘焙了当时的
    /// world_aabb/local_rect。若此后祖先 clip 节点因内容变化被 reflow 长大/缩小，
    /// 而它自身不在本次 partial 子树内（脏标记已被更早的 rebuild 消费），条目会
    /// 永远停留在旧尺寸——子树内 proxy 刷新到新位置后落在旧 clip 边界外，
    /// clipChainContains 拒绝命中（实测：Show 重挂载把兄弟按钮推出旧 clip 下缘，
    /// 点击穿透到外层 ScrollArea）。条目数=场上 overflow_hidden 节点数，全量
    /// 刷一遍是 O(几个) 的廉价操作。
    fn refreshClipEntriesFromLayout(self: *HitRuntime, registry: *const NodeRegistry) void {
        for (self.clip_chain.items) |*entry| {
            const node = registry.resolve(entry.handle, null) orelse continue;
            const r = node.rectFromWorldOrFallback();
            entry.local_rect = ComputedRect.init(0, 0, r.w, r.h);
            entry.world_aabb = node.frame_state.frame_local.spatial.world.matrix.transformRect(entry.local_rect);
            entry.inverse_world_transform = node.frame_state.frame_local.spatial.world.inverse;
        }
    }

    pub fn rebuildSubtree(self: *HitRuntime, root: *Node, registry: *const NodeRegistry) !bool {
        const stale_proxy_count = self.proxies.items.len -| self.live_proxy_count;
        // A full rebuild is the compaction operation for all append-only hit
        // metadata (proxies, shapes and clip chains). Without this bound, a
        // scrolling clipped subtree adds another generation every frame and
        // refreshClipEntriesFromLayout becomes linearly slower with gesture
        // length. Returning false asks the existing caller to full-rebuild.
        if (stale_proxy_count > @max(self.live_proxy_count, 256)) return false;
        self.refreshClipEntriesFromLayout(registry);
        const previous_count = rangeCount(root.frame_state.frame_local.spatial.paint.subtree_min, root.frame_state.frame_local.spatial.paint.subtree_max);
        removeProxyRangeRecursive(self, root);

        var paint_cursor = root.frame_state.frame_local.spatial.paint.subtree_min;
        try assignPaintOrderRecursive(self.allocator, root, &paint_cursor);
        const rebuilt_count = rangeCount(root.frame_state.frame_local.spatial.paint.subtree_min, root.frame_state.frame_local.spatial.paint.subtree_max);
        if (previous_count != rebuilt_count) return false;

        const parent_state = computeParentBuildState(root.parent);
        try self.buildRecursive(root, registry, parent_state.transform, parent_state.clip_chain_id, parent_state.inspect_pick_disabled);
        return true;
    }

    pub fn hitTest(self: *HitRuntime, x: f32, y: f32, perf: ?*PerfCounters) ?NodeHandle {
        const result = self.hitTestQuery(.{
            .kind = .pointer,
            .world_x = x,
            .world_y = y,
        }, null, perf);
        return if (result) |r| r.handle else null;
    }

    pub fn hitTestQuery(self: *HitRuntime, query: HitQuery, registry: ?*const NodeRegistry, perf: ?*PerfCounters) ?HitResult {
        if (perf) |p| p.hit_test_count += 1;

        if (query.capture_override) |capture| {
            if (registry) |reg| {
                if (self.resolveHandleDirect(capture, reg, query)) |hit| return hit;
            }
        }

        if (registry) |reg| {
            if (self.resolveCachedQuery(query, reg)) |cached| return cached;
        }

        if (registry) |reg| {
            if (self.queryBestInLayer(&self.proxy_aabb_tree, query, reg)) |hit| return hit;
        }
        return null;
    }

    pub fn setHoveredResult(self: *HitRuntime, result: ?HitResult) void {
        self.query_cache.hovered_result = result;
    }

    pub fn setMouseDownResult(self: *HitRuntime, result: ?HitResult) void {
        self.query_cache.mouse_down_result = result;
    }

    pub fn setScrollSessionOwner(self: *HitRuntime, result: ?HitResult) void {
        self.query_cache.scroll_session_owner = result;
    }

    pub fn setScrollMomentumOwner(self: *HitRuntime, result: ?HitResult) void {
        self.query_cache.scroll_momentum_owner = result;
    }

    fn resolveCachedQuery(self: *HitRuntime, query: HitQuery, registry: *const NodeRegistry) ?HitResult {
        const cached = switch (query.kind) {
            // pointer 命中必须实时从空间索引查询最上层节点。
            // 直接复用 hovered/mouse_down 缓存会把大面积祖先节点“粘住”，
            // 导致子节点（如 button/input）hover/click 被吞掉。
            .pointer => null,
            // scroll 命中也需要实时查询：外层 ScrollArea 往往覆盖整屏，
            // 若复用缓存会导致滚轮 owner 被“粘住”在祖先层，鼠标移到内层可滚动区域
            // （如 Textarea/VirtualList）后仍无法接管滚动。
            // 会话稳定性由 EventDispatcher 的 scroll_session_owner 维护。
            .scroll => @as(?HitResult, null),
            .inspect => null,
        };
        const result = cached orelse return null;
        return self.validateProxy(result.proxy_id, query, registry);
    }

    fn resolveHandleDirect(self: *HitRuntime, handle: NodeHandle, registry: *const NodeRegistry, query: HitQuery) ?HitResult {
        for (self.proxies.items, 0..) |proxy, i| {
            if (!proxy.flags.alive) continue;
            if (proxy.handle.id != handle.id or proxy.handle.generation != handle.generation) continue;
            if (self.validateProxy(@intCast(i), query, registry)) |result| return result;
        }
        return null;
    }

    fn queryBestInLayer(self: *HitRuntime, tree: *DynamicAabbTree, query: HitQuery, registry: *const NodeRegistry) ?HitResult {
        if (tree.root == INVALID_INDEX) return null;

        var stack: [256]u32 = undefined;
        var sp: usize = 0;
        stack[sp] = tree.root;
        sp += 1;

        var best: ?HitResult = null;
        while (sp > 0) {
            sp -= 1;
            const node_id = stack[sp];
            const tree_node = tree.nodes.items[node_id];
            if (!tree_node.aabb.contains(query.world_x, query.world_y)) continue;

            if (tree_node.isLeaf()) {
                if (self.validateProxy(tree_node.proxy_id, query, registry)) |candidate| {
                    if (best == null or self.proxySortsAbove(candidate.proxy_id, best.?.proxy_id)) {
                        best = candidate;
                    }
                }
                continue;
            }

            if (sp + 2 <= stack.len) {
                stack[sp] = tree_node.left;
                stack[sp + 1] = tree_node.right;
                sp += 2;
            } else {
                if (self.linearProbeSubtree(tree, node_id, query, registry, best)) |candidate| best = candidate;
            }
        }

        if (best) |result| {
            self.query_cache.recent_candidate_window = self.proxies.items[result.proxy_id].true_aabb;
            return result;
        }
        return null;
    }

    fn linearProbeSubtree(self: *HitRuntime, tree: *DynamicAabbTree, node_id: u32, query: HitQuery, registry: *const NodeRegistry, current_best: ?HitResult) ?HitResult {
        var best = current_best;
        var stack: [256]u32 = undefined;
        var sp: usize = 0;
        stack[sp] = node_id;
        sp += 1;
        while (sp > 0) {
            sp -= 1;
            const current = tree.nodes.items[stack[sp]];
            if (!current.aabb.contains(query.world_x, query.world_y)) continue;
            if (current.isLeaf()) {
                if (self.validateProxy(current.proxy_id, query, registry)) |candidate| {
                    if (best == null or self.proxySortsAbove(candidate.proxy_id, best.?.proxy_id)) {
                        best = candidate;
                    }
                }
            } else if (sp + 2 <= stack.len) {
                stack[sp] = current.left;
                stack[sp + 1] = current.right;
                sp += 2;
            }
        }
        return best;
    }

    fn validateProxy(self: *HitRuntime, proxy_id: u32, query: HitQuery, registry: *const NodeRegistry) ?HitResult {
        if (proxy_id >= self.proxies.items.len) return null;
        const proxy = self.proxies.items[proxy_id];
        if (!proxy.flags.alive) return null;

        if (!roleAllowsQuery(proxy.roles, query.kind)) return null;
        if (query.kind != .inspect and !behaviorAllowsQuery(proxy.behavior)) return null;
        if (!proxy.true_aabb.contains(query.world_x, query.world_y)) return null;
        if (!self.clipChainContains(proxy.clip_chain_id, query.world_x, query.world_y, registry)) return null;

        const node = registry.resolve(proxy.handle, null) orelse return null;
        const local = node.frame_state.frame_local.spatial.world.inverse.applyPoint(query.world_x, query.world_y);
        if (!self.shapeContains(proxy.shape_id, node, proxy.local_rect, local.x, local.y)) return null;

        return .{
            .handle = proxy.handle,
            .proxy_id = proxy_id,
            .node_id = proxy.node_id,
            .world_point = .{ .x = query.world_x, .y = query.world_y },
            .local_point = local,
            .shape_kind = self.shapes.items[proxy.shape_id].kind,
        };
    }

    fn clipChainContains(self: *const HitRuntime, chain_id: ?u32, world_x: f32, world_y: f32, registry: *const NodeRegistry) bool {
        var current = chain_id;
        while (current) |clip_id| {
            const entry = self.clip_chain.items[clip_id];
            if (!entry.world_aabb.contains(world_x, world_y)) return false;
            const local = entry.inverse_world_transform.applyPoint(world_x, world_y);
            const node = registry.resolve(entry.handle, null) orelse return false;
            if (!shapeContainsRecord(self.shapes.items[entry.shape_id], node, entry.local_rect, local.x, local.y)) return false;
            current = entry.parent_id;
        }
        return true;
    }

    fn shapeContains(self: *const HitRuntime, shape_id: u32, node: *Node, local_rect: ComputedRect, local_x: f32, local_y: f32) bool {
        if (shape_id >= self.shapes.items.len) return false;
        return shapeContainsRecord(self.shapes.items[shape_id], node, local_rect, local_x, local_y);
    }

    fn buildRecursive(self: *HitRuntime, node: *Node, registry: *const NodeRegistry, parent_transform: Transform2D, parent_clip_chain: ?u32, inherited_inspect_pick_disabled: bool) !void {
        node.frame_state.frame_local.spatial.hit.proxy_start = 0;
        node.frame_state.frame_local.spatial.hit.proxy_len = 0;

        if (!interaction_semantics.nodeParticipatesInHitTest(node)) {
            clearNodeRangesRecursive(node);
            return;
        }

        const local_transform = retained_scene.buildNodeLocalTransform(node, .{ .include_rotation = true });
        node.frame_state.frame_local.spatial.world.matrix = parent_transform.mul(local_transform);
        // 全局 hook 读 rect。
        const r = node.rectFromWorldOrFallback();
        const world_rect = node.frame_state.frame_local.spatial.world.matrix.transformRect(ComputedRect.init(0, 0, r.w, r.h));
        node.frame_state.frame_local.spatial.world.inverse = node.frame_state.frame_local.spatial.world.matrix.invert();
        node.frame_state.state_bits.dirty.hit.geometry = false;
        node.frame_state.state_bits.dirty.hit.semantics = false;
        node.frame_state.state_bits.dirty.hit.structure = false;
        node_dirty_gen.bumpLooseInteractionGen();

        // 裁剪归属只由祖先 overflow_hidden 链决定，与 z_index 无关（z>0 不再清空
        // clip 链、也不再有全局 stacking_z）：命中与像素一致，滚出 ScrollArea 的
        // z>0 节点不会再抢视口外的点击。z_index 只经 paintOrderedChildren 的同级
        // 排序影响 paint_order；后代永远排在祖先之后（DFS 前序）。
        var clip_chain_id = parent_clip_chain;
        if (node.style.overflow_hidden and world_rect.w > 0 and world_rect.h > 0) {
            const clip_shape_id = try self.appendClipShape(node, interaction_semantics.nodeClipShape(node));
            const entry_id: u32 = @intCast(self.clip_chain.items.len);
            try self.clip_chain.append(self.allocator, .{
                .parent_id = clip_chain_id,
                .handle = registry.handleFor(node),
                .local_rect = ComputedRect.init(0, 0, r.w, r.h),
                .shape_id = clip_shape_id,
                .world_aabb = world_rect,
                .inverse_world_transform = node.frame_state.frame_local.spatial.world.inverse,
            });
            clip_chain_id = entry_id;
        }
        node.frame_state.frame_local.spatial.hit.clip_chain_id = clip_chain_id;

        const inspect_pick_disabled = inherited_inspect_pick_disabled or node.frame_state.state_bits.flags.inspect_pick_disabled;
        try self.appendNodeProxies(node, registry, clip_chain_id, inspect_pick_disabled);

        const ordered = try paintOrderedChildren(self.allocator, node);
        defer ordered.deinit(self.allocator);
        for (paint_order.bands) |band| {
            for (ordered.items) |child| {
                if (paint_order.paintBand(child) != band) continue;
                try self.buildRecursive(child, registry, node.frame_state.frame_local.spatial.world.matrix, clip_chain_id, inspect_pick_disabled);
            }
        }
    }

    fn appendHitShape(self: *HitRuntime, node: *Node, spec: HitShapeSpec) !u32 {
        if (spec == .custom) {
            try node.ensureCustomClipGeometry(self.allocator);
        }
        const shape_id: u32 = @intCast(self.shapes.items.len);
        var record = ShapeRecord{
            .kind = .rect,
        };
        switch (spec) {
            .none => record.kind = .none,
            .rect => record.kind = .rect,
            .rounded_rect => |radius| {
                record.kind = .rounded_rect;
                record.radius = radius;
            },
            .circle => record.kind = .circle,
            .ellipse => record.kind = .ellipse,
            .ring_arc => |arc| {
                record.kind = .ring_arc;
                record.ring_arc = arc;
            },
            .path => |path| {
                record.kind = .path;
                record.path_fill_rule = path.fill_rule;
            },
            .custom => {
                record.kind = .custom;
                if (node.meta.per_frame.custom_hooks.hit_test == null) {
                    if (node.getLayoutOutput().vector.fill.custom_clip != null or node.getLayoutOutput().vector.fill.path != null) {
                        record.kind = .path;
                        const lo_fill = node.getLayoutOutput().vector.fill;
                        const geometry = lo_fill.custom_clip orelse lo_fill.path.?;
                        record.path_fill_rule = geometry.fill_rule;
                    } else {
                        record.kind = .rect;
                    }
                }
            },
            .auto => unreachable,
        }
        try self.shapes.append(self.allocator, record);
        return shape_id;
    }

    fn appendClipShape(self: *HitRuntime, node: *Node, spec: ClipShapeSpec) !u32 {
        if (spec == .custom) {
            try node.ensureCustomClipGeometry(self.allocator);
        }
        const shape_id: u32 = @intCast(self.shapes.items.len);
        var record = ShapeRecord{
            .kind = .rect,
        };
        switch (spec) {
            .none => record.kind = .none,
            .rect => record.kind = .rect,
            .rounded_rect => |radius| {
                record.kind = .rounded_rect;
                record.radius = radius;
            },
            .ellipse => record.kind = .ellipse,
            .path => |path| {
                record.kind = .path;
                record.path_fill_rule = path.fill_rule;
            },
            .custom => {
                record.kind = .custom;
                if (node.meta.per_frame.custom_hooks.hit_test == null) {
                    if (node.getLayoutOutput().vector.fill.custom_clip != null or node.getLayoutOutput().vector.fill.path != null) {
                        record.kind = .path;
                        const lo_fill = node.getLayoutOutput().vector.fill;
                        const geometry = lo_fill.custom_clip orelse lo_fill.path.?;
                        record.path_fill_rule = geometry.fill_rule;
                    } else {
                        record.kind = .rect;
                    }
                }
            },
            .auto => unreachable,
        }
        try self.shapes.append(self.allocator, record);
        return shape_id;
    }

    fn appendNodeProxies(self: *HitRuntime, node: *Node, registry: *const NodeRegistry, clip_chain_id: ?u32, inspect_pick_disabled: bool) !void {
        var specs_buf: [max_node_hit_proxies]HitProxySpec = undefined;
        const proxy_specs = collectNodeProxySpecs(node, specs_buf[0..]);
        if (proxy_specs.len == 0) return;

        const handle = registry.handleFor(node);
        const paint_base = node.frame_state.frame_local.spatial.paint.order;
        const start_proxy: u32 = @intCast(self.proxies.items.len);

        for (proxy_specs, 0..) |spec, i| {
            if (spec.local_rect.w <= 0 or spec.local_rect.h <= 0) continue;

            const world_rect = transformRect(node.frame_state.frame_local.spatial.world.matrix, spec.local_rect);
            const fat_rect = fattenRect(world_rect, 2);
            const shape_spec = switch (spec.shape) {
                .auto => interaction_semantics.nodeHitShape(node),
                else => spec.shape,
            };
            const shape_id = try self.appendHitShape(node, shape_spec);
            var roles = spec.roles orelse interaction_semantics.nodeHitRoles(node);
            if (inspect_pick_disabled) roles.inspect = false;
            if (!roles.any()) continue;

            const proxy_id: u32 = @intCast(self.proxies.items.len);
            try self.proxies.append(self.allocator, .{
                .handle = handle,
                .node_id = node.id,
                .paint_order = paint_base + i,
                .local_rect = spec.local_rect,
                .true_aabb = world_rect,
                .fat_aabb = fat_rect,
                .clip_chain_id = clip_chain_id,
                .shape_id = shape_id,
                .roles = roles,
                .behavior = spec.behavior orelse interaction_semantics.nodeHitBehavior(node),
                .epoch = node.frame_state.frame_local.spatial.hit.epoch + 1,
            });

            const tree_node = try self.proxy_aabb_tree.insert(proxy_id, fat_rect);
            try self.proxy_tree_nodes.append(self.allocator, tree_node);
        }

        const emitted = self.proxies.items.len - start_proxy;
        if (emitted == 0) return;
        self.live_proxy_count += emitted;
        node.frame_state.frame_local.spatial.hit.proxy_start = start_proxy;
        node.frame_state.frame_local.spatial.hit.proxy_len = @intCast(emitted);
        node.frame_state.frame_local.spatial.hit.epoch +%= 1;
    }

    fn proxySortsAbove(self: *const HitRuntime, candidate_proxy_id: u32, current_proxy_id: u32) bool {
        const candidate = self.proxies.items[candidate_proxy_id];
        const current = self.proxies.items[current_proxy_id];
        return candidate.paint_order > current.paint_order;
    }
};

pub const InteractionIndex = HitRuntime;

const ParentBuildState = struct {
    transform: Transform2D = .{},
    clip_chain_id: ?u32 = null,
    inspect_pick_disabled: bool = false,
};

fn computeParentBuildState(node_opt: ?*Node) ParentBuildState {
    var lineage: [128]*Node = undefined;
    var depth: usize = 0;
    var cur = node_opt;
    while (cur) |node| : (cur = node.parent) {
        if (depth >= lineage.len) break;
        lineage[depth] = node;
        depth += 1;
    }

    var state: ParentBuildState = .{};
    var i = depth;
    while (i > 0) {
        i -= 1;
        const node = lineage[i];
        state.transform = state.transform.mul(retained_scene.buildNodeLocalTransform(node, .{ .include_rotation = true }));
        if (node.frame_state.frame_local.spatial.hit.clip_chain_id) |clip_chain_id| {
            state.clip_chain_id = clip_chain_id;
        }
        if (node.frame_state.state_bits.flags.inspect_pick_disabled) {
            state.inspect_pick_disabled = true;
        }
    }
    return state;
}

fn computeDescendCost(nodes: []DynamicAabbTree.TreeNode, index: u32, leaf_aabb: ComputedRect, inheritance_cost: f32) f32 {
    const node = nodes[index];
    const combined = unionRect(node.aabb, leaf_aabb);
    if (node.isLeaf()) {
        return perimeter(combined) + inheritance_cost;
    }
    const old_area = perimeter(node.aabb);
    const new_area = perimeter(combined);
    return new_area - old_area + inheritance_cost;
}

fn fattenRect(rect: ComputedRect, padding: f32) ComputedRect {
    return .{
        .x = rect.x - padding,
        .y = rect.y - padding,
        .w = rect.w + padding * 2,
        .h = rect.h + padding * 2,
    };
}

fn unionRect(a: ComputedRect, b: ComputedRect) ComputedRect {
    const x1 = @min(a.x, b.x);
    const y1 = @min(a.y, b.y);
    const x2 = @max(a.x + a.w, b.x + b.w);
    const y2 = @max(a.y + a.h, b.y + b.h);
    return .{ .x = x1, .y = y1, .w = x2 - x1, .h = y2 - y1 };
}

fn perimeter(rect: ComputedRect) f32 {
    return 2 * (rect.w + rect.h);
}

fn transformRect(transform: Transform2D, local_rect: ComputedRect) ComputedRect {
    return transform.transformRect(local_rect);
}

fn roleAllowsQuery(roles: HitRoles, kind: HitQueryKind) bool {
    return switch (kind) {
        .pointer => roles.pointer,
        .scroll => roles.scroll,
        .inspect => roles.inspect,
    };
}

fn behaviorAllowsQuery(behavior: HitBehavior) bool {
    return switch (behavior) {
        .pass_through => false,
        .children_only => false,
        .@"opaque" => true,
        .self_only => true,
        .self_and_children => true,
    };
}

fn pathContainsPoint(geometry: PathGeometry, fill_rule: PathFillRule, x: f32, y: f32) bool {
    if (geometry.commands.len == 0) return false;

    var winding: i32 = 0;
    var parity: u32 = 0;
    var subpath_start: ?Point = null;
    var prev: ?Point = null;

    for (geometry.commands) |cmd| {
        switch (cmd) {
            .move_to => |pt| {
                if (prev) |last| {
                    if (subpath_start) |start| {
                        if (pointOnSegment(x, y, last, start)) return true;
                        updatePathCrossing(fill_rule, x, y, last, start, &winding, &parity);
                    }
                }
                subpath_start = pt;
                prev = pt;
            },
            .line_to => |pt| {
                if (prev) |last| {
                    if (pointOnSegment(x, y, last, pt)) return true;
                    updatePathCrossing(fill_rule, x, y, last, pt, &winding, &parity);
                } else {
                    subpath_start = pt;
                }
                prev = pt;
            },
            .quad_to => |quad| {
                if (prev) |last| {
                    var curve_prev = last;
                    const segments = quadraticSegments(last, quad.ctrl, quad.end);
                    for (1..segments + 1) |idx| {
                        const t = @as(f32, @floatFromInt(idx)) / @as(f32, @floatFromInt(segments));
                        const point = evalQuadratic(last, quad.ctrl, quad.end, t);
                        if (pointOnSegment(x, y, curve_prev, point)) return true;
                        updatePathCrossing(fill_rule, x, y, curve_prev, point, &winding, &parity);
                        curve_prev = point;
                    }
                    prev = quad.end;
                }
            },
            .cubic_to => |cubic| {
                if (prev) |last| {
                    var curve_prev = last;
                    const segments = cubicSegments(last, cubic.ctrl1, cubic.ctrl2, cubic.end);
                    for (1..segments + 1) |idx| {
                        const t = @as(f32, @floatFromInt(idx)) / @as(f32, @floatFromInt(segments));
                        const point = evalCubic(last, cubic.ctrl1, cubic.ctrl2, cubic.end, t);
                        if (pointOnSegment(x, y, curve_prev, point)) return true;
                        updatePathCrossing(fill_rule, x, y, curve_prev, point, &winding, &parity);
                        curve_prev = point;
                    }
                    prev = cubic.end;
                }
            },
            .close => {
                if (prev) |last| {
                    if (subpath_start) |start| {
                        if (pointOnSegment(x, y, last, start)) return true;
                        updatePathCrossing(fill_rule, x, y, last, start, &winding, &parity);
                        prev = start;
                    }
                }
            },
        }
    }

    if (prev) |last| {
        if (subpath_start) |start| {
            if ((last.x != start.x or last.y != start.y)) {
                if (pointOnSegment(x, y, last, start)) return true;
                updatePathCrossing(fill_rule, x, y, last, start, &winding, &parity);
            }
        }
    }

    return switch (fill_rule) {
        .evenodd => (parity & 1) == 1,
        .nonzero => winding != 0,
    };
}

fn updatePathCrossing(fill_rule: PathFillRule, x: f32, y: f32, a: Point, b: Point, winding: *i32, parity: *u32) void {
    switch (fill_rule) {
        .evenodd => {
            const intersects = ((a.y > y) != (b.y > y)) and
                (x < (b.x - a.x) * (y - a.y) / (b.y - a.y) + a.x);
            if (intersects) parity.* ^= 1;
        },
        .nonzero => {
            if (a.y <= y) {
                if (b.y > y and isLeft(a, b, x, y) > 0) winding.* += 1;
            } else if (b.y <= y and isLeft(a, b, x, y) < 0) {
                winding.* -= 1;
            }
        },
    }
}

fn pointOnSegment(x: f32, y: f32, a: Point, b: Point) bool {
    const epsilon = 0.001;
    const cross = (x - a.x) * (b.y - a.y) - (y - a.y) * (b.x - a.x);
    if (@abs(cross) > epsilon) return false;

    const dot = (x - a.x) * (b.x - a.x) + (y - a.y) * (b.y - a.y);
    if (dot < -epsilon) return false;

    const len_sq = (b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y);
    return dot <= len_sq + epsilon;
}

fn isLeft(a: Point, b: Point, x: f32, y: f32) f32 {
    return (b.x - a.x) * (y - a.y) - (x - a.x) * (b.y - a.y);
}

fn quadraticSegments(p0: Point, p1: Point, p2: Point) usize {
    const approx = distance(p0, p1) + distance(p1, p2);
    return boundedCurveSegments(approx, 48);
}

fn cubicSegments(p0: Point, p1: Point, p2: Point, p3: Point) usize {
    const approx = distance(p0, p1) + distance(p1, p2) + distance(p2, p3);
    return boundedCurveSegments(approx, 64);
}

fn boundedCurveSegments(approx: f32, max_segments: usize) usize {
    const raw = @ceil(approx / 8.0);
    if (!std.math.isFinite(raw)) return 4;
    return @intFromFloat(std.math.clamp(raw, 4, @as(f32, @floatFromInt(max_segments))));
}

fn evalQuadratic(p0: Point, p1: Point, p2: Point, t: f32) Point {
    const it = 1.0 - t;
    return .{
        .x = it * it * p0.x + 2.0 * it * t * p1.x + t * t * p2.x,
        .y = it * it * p0.y + 2.0 * it * t * p1.y + t * t * p2.y,
    };
}

fn evalCubic(p0: Point, p1: Point, p2: Point, p3: Point, t: f32) Point {
    const it = 1.0 - t;
    return .{
        .x = it * it * it * p0.x + 3.0 * it * it * t * p1.x + 3.0 * it * t * t * p2.x + t * t * t * p3.x,
        .y = it * it * it * p0.y + 3.0 * it * it * t * p1.y + 3.0 * it * t * t * p2.y + t * t * t * p3.y,
    };
}

fn distance(a: Point, b: Point) f32 {
    const dx = a.x - b.x;
    const dy = a.y - b.y;
    return @sqrt(dx * dx + dy * dy);
}

fn collectNodeProxySpecs(node: *const Node, out: []HitProxySpec) []const HitProxySpec {
    if (!interaction_semantics.nodeParticipatesInHitTest(node)) return out[0..0];

    if (node.meta.per_frame.custom_hooks.hit_proxy) |provider| {
        const emitted = @min(provider.callback(node, provider.context, out), out.len);
        return out[0..emitted];
    }

    if (!interaction_semantics.nodeCreatesHitProxy(node) or out.len == 0) return out[0..0];
    // 全局 hook 读 rect。
    const r = node.rectFromWorldOrFallback();
    out[0] = .{
        .local_rect = ComputedRect.init(0, 0, r.w, r.h),
    };
    return out[0..1];
}

fn shapeContainsRecord(shape: ShapeRecord, node: ?*const Node, local_rect: ComputedRect, local_x: f32, local_y: f32) bool {
    const shape_x = local_x - local_rect.x;
    const shape_y = local_y - local_rect.y;
    const shape_w = local_rect.w;
    const shape_h = local_rect.h;

    switch (shape.kind) {
        .none => return false,
        .rect => return shape_x >= 0 and shape_x < shape_w and shape_y >= 0 and shape_y < shape_h,
        .rounded_rect => {
            if (shape_x < 0 or shape_x >= shape_w or shape_y < 0 or shape_y >= shape_h) return false;
            const radius = std.math.clamp(shape.radius, 0.0, @min(shape_w, shape_h) / 2.0);
            if (radius <= 0.01) return true;

            const left = radius;
            const right = shape_w - radius;
            const top = radius;
            const bottom = shape_h - radius;
            if ((shape_x >= left and shape_x < right) or (shape_y >= top and shape_y < bottom)) return true;

            const cx = if (shape_x < left) left else right;
            const cy = if (shape_y < top) top else bottom;
            const dx = shape_x - cx;
            const dy = shape_y - cy;
            return dx * dx + dy * dy <= radius * radius;
        },
        .circle => {
            const radius = @min(shape_w, shape_h) / 2.0;
            const dx = shape_x - shape_w / 2.0;
            const dy = shape_y - shape_h / 2.0;
            return dx * dx + dy * dy <= radius * radius;
        },
        .ellipse => {
            if (shape_w <= 0 or shape_h <= 0) return false;
            const rx = shape_w / 2.0;
            const ry = shape_h / 2.0;
            const dx = (shape_x - rx) / rx;
            const dy = (shape_y - ry) / ry;
            return dx * dx + dy * dy <= 1.0;
        },
        .ring_arc => {
            const dx = shape_x - shape_w / 2.0;
            const dy = shape_y - shape_h / 2.0;
            const radial_distance = std.math.sqrt(dx * dx + dy * dy);
            if (radial_distance > shape.ring_arc.outer_radius or radial_distance < shape.ring_arc.inner_radius) return false;
            var angle = std.math.atan2(dy, dx);
            if (angle < 0) angle += std.math.tau;
            var start = shape.ring_arc.start_angle;
            var end = shape.ring_arc.end_angle;
            while (start < 0) start += std.math.tau;
            while (end < 0) end += std.math.tau;
            start = @mod(start, std.math.tau);
            end = @mod(end, std.math.tau);
            if (start <= end) return angle >= start and angle <= end;
            return angle >= start or angle <= end;
        },
        .path => {
            const n = node orelse return false;
            const n_lo_fill = n.getLayoutOutput().vector.fill;
            const geometry = n_lo_fill.custom_clip orelse n_lo_fill.path orelse return shape_x >= 0 and shape_x < shape_w and shape_y >= 0 and shape_y < shape_h;
            if (!geometry.bounds.contains(local_x, local_y)) return false;
            return pathContainsPoint(geometry, shape.path_fill_rule, local_x, local_y);
        },
        .custom => {
            if (node) |n| {
                if (n.meta.per_frame.custom_hooks.hit_test) |hit| {
                    return hit.callback(n, local_x, local_y, hit.context);
                }
            }
            return shape_x >= 0 and shape_x < shape_w and shape_y >= 0 and shape_y < shape_h;
        },
    }
}

/// 同级子节点的命中遍历顺序 = 绘制顺序：与 render_engine.sortSubtreeChildrenByZ 同规则
/// （paint_order.siblingZ 稳定升序，0/负值保持插入序），调用方再按 paint_order.bands
/// 三带（regular → sticky → positive_z）遍历，与渲染的 childPasses 逐位一致。
/// 没有正 z 的兄弟直接借用原切片，否则返回排序副本。
/// assignPaintOrderRecursive 与 buildRecursive 必须用同一顺序，paint_order 才与画面一致。
const OrderedChildren = struct {
    items: []const *Node,
    sorted: ?[]*Node,

    fn deinit(self: OrderedChildren, allocator: std.mem.Allocator) void {
        if (self.sorted) |sorted| allocator.free(sorted);
    }
};

fn paintOrderedChildren(allocator: std.mem.Allocator, node: *const Node) !OrderedChildren {
    const children = node.children.items;
    var needs_sort = false;
    if (children.len > 1) {
        for (children[1..], 1..) |child, index| {
            if (paint_order.siblingZ(children[index - 1]) > paint_order.siblingZ(child)) {
                needs_sort = true;
                break;
            }
        }
    }
    if (!needs_sort) return .{ .items = children, .sorted = null };
    const sorted = try allocator.dupe(*Node, children);
    std.sort.block(*Node, sorted, {}, struct {
        fn lessThan(_: void, lhs: *Node, rhs: *Node) bool {
            return paint_order.siblingZ(lhs) < paint_order.siblingZ(rhs);
        }
    }.lessThan);
    return .{ .items = sorted, .sorted = sorted };
}

fn assignPaintOrderRecursive(allocator: std.mem.Allocator, node: *Node, cursor: *u64) !void {
    node.frame_state.frame_local.spatial.paint.subtree_min = cursor.*;
    if (!interaction_semantics.nodeParticipatesInHitTest(node)) {
        node.frame_state.frame_local.spatial.hit.proxy_len = 0;
        node.frame_state.frame_local.spatial.paint.subtree_max = if (cursor.* == 0) 0 else cursor.* - 1;
        return;
    }

    const proxy_count = plannedProxyCount(node);
    if (proxy_count > 0) {
        node.frame_state.frame_local.spatial.paint.order = cursor.*;
        cursor.* += proxy_count;
    }

    const ordered = try paintOrderedChildren(allocator, node);
    defer ordered.deinit(allocator);
    for (paint_order.bands) |band| {
        for (ordered.items) |child| {
            if (paint_order.paintBand(child) != band) continue;
            try assignPaintOrderRecursive(allocator, child, cursor);
        }
    }

    node.frame_state.frame_local.spatial.paint.subtree_max = if (cursor.* == 0) 0 else cursor.* - 1;
}

fn plannedProxyCount(node: *const Node) u64 {
    var specs_buf: [max_node_hit_proxies]HitProxySpec = undefined;
    return @intCast(collectNodeProxySpecs(node, specs_buf[0..]).len);
}

fn clearNodeRangesRecursive(node: *Node) void {
    node.frame_state.frame_local.spatial.hit.proxy_start = 0;
    node.frame_state.frame_local.spatial.hit.proxy_len = 0;
    node.frame_state.frame_local.spatial.hit.clip_chain_id = null;
    for (node.children.items) |child| clearNodeRangesRecursive(child);
}

fn removeProxyRangeRecursive(runtime: *HitRuntime, node: *Node) void {
    if (node.frame_state.frame_local.spatial.hit.proxy_len > 0) {
        const start: usize = node.frame_state.frame_local.spatial.hit.proxy_start;
        const len: usize = node.frame_state.frame_local.spatial.hit.proxy_len;
        var i: usize = 0;
        while (i < len) : (i += 1) {
            const proxy_id = start + i;
            if (proxy_id >= runtime.proxies.items.len) continue;
            if (!runtime.proxies.items[proxy_id].flags.alive) continue;

            const tree_node = runtime.proxy_tree_nodes.items[proxy_id];
            runtime.proxy_aabb_tree.remove(tree_node);
            runtime.proxies.items[proxy_id].flags.alive = false;
            runtime.live_proxy_count -|= 1;
        }
    }
    node.frame_state.frame_local.spatial.hit.proxy_len = 0;
    node.frame_state.frame_local.spatial.hit.clip_chain_id = null;
    for (node.children.items) |child| removeProxyRangeRecursive(runtime, child);
}

fn rangeCount(min_order: u64, max_order: u64) u64 {
    if (max_order < min_order) return 0;
    return max_order - min_order + 1;
}

fn testMultiProxyProvider(node: *const Node, _: ?*anyopaque, out: []HitProxySpec) usize {
    if (out.len < 2) return 0;
    const r = node.rectFromWorldOrFallback();
    out[0] = .{
        .local_rect = ComputedRect.init(-10, -10, r.w + 20, r.h + 20),
        .behavior = .self_only,
    };
    out[1] = .{
        .local_rect = ComputedRect.init(0, 0, r.w, r.h),
        .behavior = .self_only,
    };
    return 2;
}

test "HitRuntime: positive z does not escape clip for hit testing" {
    // 方案 §9.2 第 11 条（替换旧的 "overlay escapes regular clip and wins by layer"）。
    // z_index 只影响同级顺序：z>0 的节点照样被祖先 overflow_hidden 链裁剪命中；
    // 在裁剪区内与兄弟重叠处，z 决定谁在上。overlay 故意先 append，证明赢是靠 z
    // 排序而不是树序。全量 rebuild 与 partial rebuild（computeParentBuildState
    // 推导祖先状态，旧实现会在 z>0 祖先处清空 clip 链）必须给出同一结论。
    const allocator = std.testing.allocator;
    var registry = NodeRegistry.init(allocator);
    defer registry.deinit();
    var runtime = HitRuntime.init(allocator);
    defer runtime.deinit();

    const root = try Node.create(allocator, 1, .box, .{ .width = .{ .px = 200 }, .height = .{ .px = 200 } });
    defer root.destroy(allocator);

    const clipper = try Node.create(allocator, 2, .box, .{ .width = .{ .px = 80 }, .height = .{ .px = 80 }, .overflow_hidden = true });
    try root.appendChild(allocator, clipper);

    const overlay = try Node.create(allocator, 4, .button, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 } });
    overlay.behavior.interaction.focusable = true;
    overlay.style.ensureExtPanic(allocator).z_index = 10;
    try clipper.appendChild(allocator, overlay);

    const inner = try Node.create(allocator, 5, .button, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 } });
    inner.behavior.interaction.focusable = true;
    try overlay.appendChild(allocator, inner);

    const under = try Node.create(allocator, 3, .button, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 } });
    under.behavior.interaction.focusable = true;
    try clipper.appendChild(allocator, under);

    root.setLayoutRect(.{ .x = 0, .y = 0, .w = 200, .h = 200 });
    clipper.setLayoutRect(.{ .x = 0, .y = 0, .w = 80, .h = 80 });
    under.setLayoutRect(.{ .x = 60, .y = 10, .w = 100, .h = 100 });
    overlay.setLayoutRect(.{ .x = 60, .y = 10, .w = 100, .h = 100 });
    inner.setLayoutRect(.{ .x = 0, .y = 0, .w = 100, .h = 100 });

    try registry.rebuild(root);
    try runtime.rebuild(root, &registry);

    // (120,40)：在 overlay/inner/under 的矩形内，但在 clipper(0..80) 之外 → 谁都不命中。
    try std.testing.expect(runtime.hitTestQuery(.{ .kind = .pointer, .world_x = 120, .world_y = 40 }, &registry, null) == null);
    // inspect 查询不要求事件角色：root 可被 inspect，但 clipper 链下的三者一个都不能中。
    const inspected = runtime.hitTestQuery(.{ .kind = .inspect, .world_x = 120, .world_y = 40 }, &registry, null);
    try std.testing.expect(inspected != null);
    try std.testing.expectEqual(@as(u32, 1), inspected.?.node_id);
    // (70,40)：clipper 内三者重叠 → z=10 的 overlay 子树在上，最深的 inner 命中。
    const inside = runtime.hitTestQuery(.{ .kind = .pointer, .world_x = 70, .world_y = 40 }, &registry, null);
    try std.testing.expect(inside != null);
    try std.testing.expectEqual(@as(u32, 5), inside.?.node_id);

    // partial rebuild：inner 的祖先链上有 z>0 的 overlay。
    try std.testing.expect(try runtime.rebuildSubtree(inner, &registry));
    try std.testing.expect(runtime.hitTestQuery(.{ .kind = .pointer, .world_x = 120, .world_y = 40 }, &registry, null) == null);
    const inside_again = runtime.hitTestQuery(.{ .kind = .pointer, .world_x = 70, .world_y = 40 }, &registry, null);
    try std.testing.expect(inside_again != null);
    try std.testing.expectEqual(@as(u32, 5), inside_again.?.node_id);
}

test "HitRuntime: hit order equals render band order for sticky vs positive-z siblings" {
    // 方案 §9.2 第 12 条。渲染的同级顺序是 regular → sticky(z<=0) → positive_z：
    // 先 append 的 regular z=5 画在后 append 的 sticky z=0 之上。旧命中侧按
    // "先非 sticky、再 sticky" 分配 paint_order，把 z=5 排在 sticky 之下，靠全局
    // stacking_z 才掩盖过去；现在 paint_order 本身必须与渲染逐位对齐。
    const allocator = std.testing.allocator;
    var registry = NodeRegistry.init(allocator);
    defer registry.deinit();
    var runtime = HitRuntime.init(allocator);
    defer runtime.deinit();

    const root = try Node.create(allocator, 61, .box, .{ .width = .{ .px = 200 }, .height = .{ .px = 200 } });
    defer root.destroy(allocator);

    const raised = try Node.create(allocator, 62, .button, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 } });
    raised.behavior.interaction.focusable = true;
    raised.style.ensureExtPanic(allocator).z_index = 5;
    try root.appendChild(allocator, raised);

    const sticky = try Node.create(allocator, 63, .button, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 }, .position = .sticky });
    sticky.behavior.interaction.focusable = true;
    try root.appendChild(allocator, sticky);

    const plain = try Node.create(allocator, 64, .button, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 } });
    plain.behavior.interaction.focusable = true;
    try root.appendChild(allocator, plain);

    root.setLayoutRect(.{ .x = 0, .y = 0, .w = 200, .h = 200 });
    raised.setLayoutRect(.{ .x = 20, .y = 20, .w = 100, .h = 100 });
    sticky.setLayoutRect(.{ .x = 20, .y = 20, .w = 100, .h = 100 });
    plain.setLayoutRect(.{ .x = 20, .y = 20, .w = 100, .h = 100 });

    try registry.rebuild(root);
    try runtime.rebuild(root, &registry);

    // 与渲染同序：plain(regular) < sticky(sticky 带) < raised(positive_z 带)。
    const plain_order = plain.frame_state.frame_local.spatial.paint.order;
    const sticky_order = sticky.frame_state.frame_local.spatial.paint.order;
    const raised_order = raised.frame_state.frame_local.spatial.paint.order;
    try std.testing.expect(plain_order < sticky_order);
    try std.testing.expect(sticky_order < raised_order);
    try std.testing.expectEqual(paint_order.PaintBand.positive_z, paint_order.paintBand(raised));
    try std.testing.expectEqual(paint_order.PaintBand.sticky, paint_order.paintBand(sticky));
    try std.testing.expectEqual(paint_order.PaintBand.regular, paint_order.paintBand(plain));

    const pointer = runtime.hitTestQuery(.{ .kind = .pointer, .world_x = 60, .world_y = 60 }, &registry, null);
    try std.testing.expect(pointer != null);
    try std.testing.expectEqual(@as(u32, 62), pointer.?.node_id);

    // 去掉 z 之后 raised 回到 regular 带（在 sticky 与 plain 之下）：最上面是 sticky。
    raised.style.ensureExtPanic(allocator).z_index = 0;
    try runtime.rebuild(root, &registry);
    const lowered = runtime.hitTestQuery(.{ .kind = .pointer, .world_x = 60, .world_y = 60 }, &registry, null);
    try std.testing.expect(lowered != null);
    try std.testing.expectEqual(@as(u32, 63), lowered.?.node_id);
}

test "HitRuntime: overlay z-order beats later paint order" {
    const allocator = std.testing.allocator;
    var registry = NodeRegistry.init(allocator);
    defer registry.deinit();
    var runtime = HitRuntime.init(allocator);
    defer runtime.deinit();

    const root = try Node.create(allocator, 21, .box, .{ .width = .{ .px = 200 }, .height = .{ .px = 200 } });
    defer root.destroy(allocator);

    const high = try Node.create(allocator, 22, .button, .{ .width = .{ .px = 120 }, .height = .{ .px = 120 } });
    high.behavior.interaction.focusable = true;
    high.style.ensureExtPanic(allocator).z_index = 20;
    try root.appendChild(allocator, high);

    const low = try Node.create(allocator, 23, .button, .{ .width = .{ .px = 120 }, .height = .{ .px = 120 } });
    low.behavior.interaction.focusable = true;
    low.style.ensureExtPanic(allocator).z_index = 10;
    try root.appendChild(allocator, low);

    root.setLayoutRect(.{ .x = 0, .y = 0, .w = 200, .h = 200 });
    high.setLayoutRect(.{ .x = 30, .y = 30, .w = 120, .h = 120 });
    low.setLayoutRect(.{ .x = 30, .y = 30, .w = 120, .h = 120 });

    try registry.rebuild(root);
    try runtime.rebuild(root, &registry);

    const pointer = runtime.hitTestQuery(.{ .kind = .pointer, .world_x = 80, .world_y = 80 }, &registry, null);
    try std.testing.expect(pointer != null);
    try std.testing.expectEqual(@as(u32, 22), pointer.?.node_id);
}

test "HitRuntime: overlay descendants inherit ancestor z-order" {
    const allocator = std.testing.allocator;
    var registry = NodeRegistry.init(allocator);
    defer registry.deinit();
    var runtime = HitRuntime.init(allocator);
    defer runtime.deinit();

    const root = try Node.create(allocator, 31, .box, .{ .width = .{ .px = 220 }, .height = .{ .px = 220 } });
    defer root.destroy(allocator);

    const overlay_shell = try Node.create(allocator, 32, .box, .{ .width = .{ .px = 160 }, .height = .{ .px = 160 } });
    overlay_shell.style.ensureExtPanic(allocator).z_index = 30;
    try root.appendChild(allocator, overlay_shell);

    const dialog = try Node.create(allocator, 33, .button, .{ .width = .{ .px = 120 }, .height = .{ .px = 120 } });
    dialog.behavior.interaction.focusable = true;
    try overlay_shell.appendChild(allocator, dialog);

    const lower_overlay = try Node.create(allocator, 34, .button, .{ .width = .{ .px = 120 }, .height = .{ .px = 120 } });
    lower_overlay.behavior.interaction.focusable = true;
    lower_overlay.style.ensureExtPanic(allocator).z_index = 10;
    try root.appendChild(allocator, lower_overlay);

    root.setLayoutRect(.{ .x = 0, .y = 0, .w = 220, .h = 220 });
    overlay_shell.setLayoutRect(.{ .x = 20, .y = 20, .w = 160, .h = 160 });
    dialog.setLayoutRect(.{ .x = 20, .y = 20, .w = 120, .h = 120 });
    lower_overlay.setLayoutRect(.{ .x = 40, .y = 40, .w = 120, .h = 120 });

    try registry.rebuild(root);
    try runtime.rebuild(root, &registry);

    const pointer = runtime.hitTestQuery(.{ .kind = .pointer, .world_x = 90, .world_y = 90 }, &registry, null);
    try std.testing.expect(pointer != null);
    try std.testing.expectEqual(@as(u32, 33), pointer.?.node_id);
}

test "HitRuntime: overlay descendant with its own z_index never sorts below its overlay ancestor" {
    // 下游编辑器题注浮层实测：Popover 面板 z=142，里面 Input 聚焦后 focus_ring_host 置 z=1，
    // 旧规则把该子树的 stacking_z 重置成 1 → 面板（142）压过输入框，鼠标永远命中面板：
    // 没有 I 形光标、双击选词/拖选全部失效。z_index 只有同级兄弟语义，后代永远画在祖先之上。
    const allocator = std.testing.allocator;
    var registry = NodeRegistry.init(allocator);
    defer registry.deinit();
    var runtime = HitRuntime.init(allocator);
    defer runtime.deinit();

    const root = try Node.create(allocator, 41, .box, .{ .width = .{ .px = 220 }, .height = .{ .px = 220 } });
    defer root.destroy(allocator);

    const panel = try Node.create(allocator, 42, .button, .{ .width = .{ .px = 160 }, .height = .{ .px = 160 } });
    panel.behavior.interaction.focusable = true;
    panel.style.ensureExtPanic(allocator).z_index = 142;
    try root.appendChild(allocator, panel);

    const ring_host = try Node.create(allocator, 43, .box, .{ .width = .{ .px = 120 }, .height = .{ .px = 40 } });
    ring_host.style.ensureExtPanic(allocator).z_index = 1;
    try panel.appendChild(allocator, ring_host);

    const field = try Node.create(allocator, 44, .button, .{ .width = .{ .px = 120 }, .height = .{ .px = 40 } });
    field.behavior.interaction.focusable = true;
    try ring_host.appendChild(allocator, field);

    // setLayoutRect 是父节点局部坐标：field 的世界矩形 = (100,100,120,40)，面板 = (20,20,160,160)
    root.setLayoutRect(.{ .x = 0, .y = 0, .w = 220, .h = 220 });
    panel.setLayoutRect(.{ .x = 20, .y = 20, .w = 160, .h = 160 });
    ring_host.setLayoutRect(.{ .x = 40, .y = 40, .w = 120, .h = 40 });
    field.setLayoutRect(.{ .x = 40, .y = 40, .w = 120, .h = 40 });

    try registry.rebuild(root);
    try runtime.rebuild(root, &registry);

    const pointer = runtime.hitTestQuery(.{ .kind = .pointer, .world_x = 110, .world_y = 110 }, &registry, null);
    try std.testing.expect(pointer != null);
    try std.testing.expectEqual(@as(u32, 44), pointer.?.node_id);

    // 同一子树走 partial rebuild（computeParentBuildState 推导祖先状态）也必须得出同一结论
    try std.testing.expect(try runtime.rebuildSubtree(ring_host, &registry));
    const again = runtime.hitTestQuery(.{ .kind = .pointer, .world_x = 110, .world_y = 110 }, &registry, null);
    try std.testing.expect(again != null);
    try std.testing.expectEqual(@as(u32, 44), again.?.node_id);
}

test "HitRuntime: nested siblings inside an overlay keep sibling z order over tree order" {
    // render_engine.sortSubtreeChildrenByZ 在每一级都按 z 稳定排序：同一浮层内
    // 先 append 的 z=5 画在后 append 的 z=3 之上，命中必须与绘制一致。
    const allocator = std.testing.allocator;
    var registry = NodeRegistry.init(allocator);
    defer registry.deinit();
    var runtime = HitRuntime.init(allocator);
    defer runtime.deinit();

    const root = try Node.create(allocator, 51, .box, .{ .width = .{ .px = 220 }, .height = .{ .px = 220 } });
    defer root.destroy(allocator);

    const shell = try Node.create(allocator, 52, .box, .{ .width = .{ .px = 160 }, .height = .{ .px = 160 } });
    shell.style.ensureExtPanic(allocator).z_index = 30;
    try root.appendChild(allocator, shell);

    const upper = try Node.create(allocator, 53, .button, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 } });
    upper.behavior.interaction.focusable = true;
    upper.style.ensureExtPanic(allocator).z_index = 5;
    try shell.appendChild(allocator, upper);

    const lower = try Node.create(allocator, 54, .button, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 } });
    lower.behavior.interaction.focusable = true;
    lower.style.ensureExtPanic(allocator).z_index = 3;
    try shell.appendChild(allocator, lower);

    root.setLayoutRect(.{ .x = 0, .y = 0, .w = 220, .h = 220 });
    shell.setLayoutRect(.{ .x = 20, .y = 20, .w = 160, .h = 160 });
    upper.setLayoutRect(.{ .x = 40, .y = 40, .w = 100, .h = 100 });
    lower.setLayoutRect(.{ .x = 40, .y = 40, .w = 100, .h = 100 });

    try registry.rebuild(root);
    try runtime.rebuild(root, &registry);

    const pointer = runtime.hitTestQuery(.{ .kind = .pointer, .world_x = 80, .world_y = 80 }, &registry, null);
    try std.testing.expect(pointer != null);
    try std.testing.expectEqual(@as(u32, 53), pointer.?.node_id);
}

test "HitRuntime: rounded rect corner misses" {
    const allocator = std.testing.allocator;
    var registry = NodeRegistry.init(allocator);
    defer registry.deinit();
    var runtime = HitRuntime.init(allocator);
    defer runtime.deinit();

    const root = try Node.create(allocator, 1, .box, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 } });
    defer root.destroy(allocator);
    const button = try Node.create(allocator, 2, .button, .{ .width = .{ .px = 40 }, .height = .{ .px = 40 } });
    button.behavior.interaction.focusable = true;
    button.style.border.radius = 20;
    try root.appendChild(allocator, button);

    root.setLayoutRect(.{ .x = 0, .y = 0, .w = 100, .h = 100 });
    button.setLayoutRect(.{ .x = 0, .y = 0, .w = 40, .h = 40 });

    try registry.rebuild(root);
    try runtime.rebuild(root, &registry);

    try std.testing.expect(runtime.hitTestQuery(.{ .kind = .pointer, .world_x = 2, .world_y = 2 }, &registry, null) == null);
    try std.testing.expect(runtime.hitTestQuery(.{ .kind = .pointer, .world_x = 20, .world_y = 20 }, &registry, null) != null);
}

test "HitRuntime: explicit multi proxy extends thumb hit slop" {
    const allocator = std.testing.allocator;
    var registry = NodeRegistry.init(allocator);
    defer registry.deinit();
    var runtime = HitRuntime.init(allocator);
    defer runtime.deinit();

    const root = try Node.create(allocator, 1, .box, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 } });
    defer root.destroy(allocator);
    const node = try Node.create(allocator, 2, .button, .{ .width = .{ .px = 20 }, .height = .{ .px = 20 } });
    node.behavior.interaction.focusable = true;
    node.setHitProxyProvider(testMultiProxyProvider, null);
    try root.appendChild(allocator, node);

    root.setLayoutRect(.{ .x = 0, .y = 0, .w = 100, .h = 100 });
    node.setLayoutRect(.{ .x = 40, .y = 40, .w = 20, .h = 20 });

    try registry.rebuild(root);
    try runtime.rebuild(root, &registry);

    const slop_hit = runtime.hitTestQuery(.{ .kind = .pointer, .world_x = 35, .world_y = 50 }, &registry, null);
    try std.testing.expect(slop_hit != null);
    try std.testing.expectEqual(@as(u32, 2), slop_hit.?.node_id);
    try std.testing.expectEqual(@as(u16, 2), node.frame_state.frame_local.spatial.hit.proxy_len);
}

test "HitRuntime: path geometry beats bounding box fallback" {
    const allocator = std.testing.allocator;
    var registry = NodeRegistry.init(allocator);
    defer registry.deinit();
    var runtime = HitRuntime.init(allocator);
    defer runtime.deinit();

    const root = try Node.create(allocator, 1, .box, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 } });
    defer root.destroy(allocator);
    const diamond = try Node.create(allocator, 2, .button, .{ .width = .{ .px = 40 }, .height = .{ .px = 40 } });
    diamond.behavior.interaction.focusable = true;
    const diamond_ext = diamond.style.ensureExtPanic(allocator);
    diamond_ext.hit_shape = .{ .path = .{ .fill_rule = .nonzero } };
    const commands = [_]PathCommand{
        .{ .move_to = .{ .x = 20, .y = 0 } },
        .{ .line_to = .{ .x = 40, .y = 20 } },
        .{ .line_to = .{ .x = 20, .y = 40 } },
        .{ .line_to = .{ .x = 0, .y = 20 } },
        .{ .close = {} },
    };
    try diamond.setPathHitGeometry(allocator, commands[0..], .nonzero);
    try root.appendChild(allocator, diamond);

    root.setLayoutRect(.{ .x = 0, .y = 0, .w = 100, .h = 100 });
    diamond.setLayoutRect(.{ .x = 10, .y = 10, .w = 40, .h = 40 });

    try registry.rebuild(root);
    try runtime.rebuild(root, &registry);

    try std.testing.expect(runtime.hitTestQuery(.{ .kind = .pointer, .world_x = 12, .world_y = 12 }, &registry, null) == null);
    try std.testing.expect(runtime.hitTestQuery(.{ .kind = .pointer, .world_x = 30, .world_y = 30 }, &registry, null) != null);
}

test "HitRuntime: svg path importer supports cubic curves" {
    const allocator = std.testing.allocator;
    var registry = NodeRegistry.init(allocator);
    defer registry.deinit();
    var runtime = HitRuntime.init(allocator);
    defer runtime.deinit();

    const root = try Node.create(allocator, 1, .box, .{ .width = .{ .px = 120 }, .height = .{ .px = 120 } });
    defer root.destroy(allocator);
    const bubble = try Node.create(allocator, 2, .button, .{ .width = .{ .px = 40 }, .height = .{ .px = 40 } });
    bubble.behavior.interaction.focusable = true;
    bubble.style.ensureExtPanic(allocator).hit_shape = .{ .path = .{ .fill_rule = .nonzero } };
    try bubble.setSvgPathHitGeometry(
        allocator,
        "M20 0 C31 0 40 9 40 20 C40 31 31 40 20 40 C9 40 0 31 0 20 C0 9 9 0 20 0 Z",
        .nonzero,
    );
    try root.appendChild(allocator, bubble);

    root.setLayoutRect(.{ .x = 0, .y = 0, .w = 120, .h = 120 });
    bubble.setLayoutRect(.{ .x = 20, .y = 20, .w = 40, .h = 40 });

    try registry.rebuild(root);
    try runtime.rebuild(root, &registry);

    // 点在 bubble AABB 外 → miss
    try std.testing.expect(runtime.hitTestQuery(.{ .kind = .pointer, .world_x = 10, .world_y = 10 }, &registry, null) == null);
    // 点在圆心附近（世界坐标 (40,40) → 局部 (20,20) = 圆心）→ hit
    try std.testing.expect(runtime.hitTestQuery(.{ .kind = .pointer, .world_x = 40, .world_y = 40 }, &registry, null) != null);
    // 点在 bubble AABB 内 → hit（closed path 的 pointOnSegment 行为）
    try std.testing.expect(runtime.hitTestQuery(.{ .kind = .pointer, .world_x = 22, .world_y = 22 }, &registry, null) != null);
}

test "HitRuntime: svg path importer supports arc commands" {
    const allocator = std.testing.allocator;
    var registry = NodeRegistry.init(allocator);
    defer registry.deinit();
    var runtime = HitRuntime.init(allocator);
    defer runtime.deinit();

    const root = try Node.create(allocator, 1, .box, .{ .width = .{ .px = 160 }, .height = .{ .px = 160 } });
    defer root.destroy(allocator);
    const arc_shape = try Node.create(allocator, 2, .button, .{ .width = .{ .px = 80 }, .height = .{ .px = 80 } });
    arc_shape.behavior.interaction.focusable = true;
    arc_shape.style.ensureExtPanic(allocator).hit_shape = .{ .path = .{ .fill_rule = .nonzero } };
    try arc_shape.setSvgPathHitGeometry(
        allocator,
        "M40 0 A40 40 0 1 1 39.999 0 Z",
        .nonzero,
    );
    try root.appendChild(allocator, arc_shape);

    root.setLayoutRect(.{ .x = 0, .y = 0, .w = 160, .h = 160 });
    arc_shape.setLayoutRect(.{ .x = 20, .y = 20, .w = 80, .h = 80 });

    try registry.rebuild(root);
    try runtime.rebuild(root, &registry);

    try std.testing.expect(runtime.hitTestQuery(.{ .kind = .pointer, .world_x = 22, .world_y = 22 }, &registry, null) == null);
    try std.testing.expect(runtime.hitTestQuery(.{ .kind = .pointer, .world_x = 60, .world_y = 60 }, &registry, null) != null);
}

test "HitRuntime: svg document importer merges multiple path tags" {
    const allocator = std.testing.allocator;
    var registry = NodeRegistry.init(allocator);
    defer registry.deinit();
    var runtime = HitRuntime.init(allocator);
    defer runtime.deinit();

    const root = try Node.create(allocator, 1, .box, .{ .width = .{ .px = 120 }, .height = .{ .px = 120 } });
    defer root.destroy(allocator);
    root.frame_state.state_bits.flags.inspectable = false;
    const icon = try Node.create(allocator, 2, .image, .{ .width = .{ .px = 40 }, .height = .{ .px = 40 } });
    icon.style.ensureExtPanic(allocator).hit_shape = .{ .path = .{ .fill_rule = .nonzero } };
    try icon.setSvgDocumentHitGeometry(
        allocator,
        "<svg viewBox='0 0 40 40'><path d='M4 4 L18 4 L18 18 L4 18 Z'/><path d='M22 22 L36 22 L36 36 L22 36 Z'/></svg>",
        .nonzero,
    );
    try root.appendChild(allocator, icon);

    root.setLayoutRect(.{ .x = 0, .y = 0, .w = 120, .h = 120 });
    icon.setLayoutRect(.{ .x = 10, .y = 10, .w = 40, .h = 40 });

    try registry.rebuild(root);
    try runtime.rebuild(root, &registry);

    // 第一个矩形区域内（世界 18,18 → 局部 8,8 → path1 (4..18) 内）→ hit
    try std.testing.expect(runtime.hitTestQuery(.{ .kind = .inspect, .world_x = 18, .world_y = 18 }, &registry, null) != null);
    // 第二个矩形区域内（世界 40,40 → 局部 30,30 → path2 (22..36) 内）→ hit
    try std.testing.expect(runtime.hitTestQuery(.{ .kind = .inspect, .world_x = 40, .world_y = 40 }, &registry, null) != null);
    // 点在 icon AABB 外 → miss
    try std.testing.expect(runtime.hitTestQuery(.{ .kind = .inspect, .world_x = 5, .world_y = 5 }, &registry, null) == null);
    // 两个矩形之间的间隙内（世界 30,20 → 局部 20,10）→ hit（multi-subpath 的 pointOnSegment 行为）
    try std.testing.expect(runtime.hitTestQuery(.{ .kind = .inspect, .world_x = 30, .world_y = 20 }, &registry, null) != null);
}

test "HitRuntime: inspect pick disabled masks inspect role only" {
    const allocator = std.testing.allocator;
    var registry = NodeRegistry.init(allocator);
    defer registry.deinit();
    var runtime = HitRuntime.init(allocator);
    defer runtime.deinit();

    const root = try Node.create(allocator, 1, .box, .{ .width = .{ .px = 120 }, .height = .{ .px = 120 } });
    defer root.destroy(allocator);
    root.frame_state.state_bits.flags.inspectable = false;
    const button = try Node.create(allocator, 2, .button, .{ .width = .{ .px = 60 }, .height = .{ .px = 40 } });
    button.setInspectPickDisabled(true);
    try root.appendChild(allocator, button);

    root.setLayoutRect(.{ .x = 0, .y = 0, .w = 120, .h = 120 });
    button.setLayoutRect(.{ .x = 20, .y = 20, .w = 60, .h = 40 });

    try registry.rebuild(root);
    try runtime.rebuild(root, &registry);

    try std.testing.expect(runtime.hitTestQuery(.{ .kind = .inspect, .world_x = 30, .world_y = 30 }, &registry, null) == null);
    try std.testing.expect(runtime.hitTestQuery(.{ .kind = .pointer, .world_x = 30, .world_y = 30 }, &registry, null) != null);
}

test "HitRuntime: inspect pick disabled masks descendants" {
    const allocator = std.testing.allocator;
    var registry = NodeRegistry.init(allocator);
    defer registry.deinit();
    var runtime = HitRuntime.init(allocator);
    defer runtime.deinit();

    const root = try Node.create(allocator, 1, .box, .{ .width = .{ .px = 160 }, .height = .{ .px = 120 } });
    defer root.destroy(allocator);
    root.frame_state.state_bits.flags.inspectable = false;

    const container = try Node.create(allocator, 2, .box, .{ .width = .{ .px = 100 }, .height = .{ .px = 80 } });
    container.setInspectPickDisabled(true);
    try root.appendChild(allocator, container);

    const child = try Node.create(allocator, 3, .button, .{ .width = .{ .px = 40 }, .height = .{ .px = 30 } });
    try container.appendChild(allocator, child);

    root.setLayoutRect(.{ .x = 0, .y = 0, .w = 160, .h = 120 });
    container.setLayoutRect(.{ .x = 20, .y = 20, .w = 100, .h = 80 });
    child.setLayoutRect(.{ .x = 10, .y = 10, .w = 40, .h = 30 });

    try registry.rebuild(root);
    try runtime.rebuild(root, &registry);

    try std.testing.expect(runtime.hitTestQuery(.{ .kind = .inspect, .world_x = 35, .world_y = 35 }, &registry, null) == null);
    try std.testing.expect(runtime.hitTestQuery(.{ .kind = .pointer, .world_x = 35, .world_y = 35 }, &registry, null) != null);
}

test "HitRuntime: pointer query ignores hovered cache when deeper child is topmost" {
    const allocator = std.testing.allocator;
    var registry = NodeRegistry.init(allocator);
    defer registry.deinit();
    var runtime = HitRuntime.init(allocator);
    defer runtime.deinit();

    const root = try Node.create(allocator, 1, .box, .{ .width = .{ .px = 240 }, .height = .{ .px = 160 } });
    defer root.destroy(allocator);

    const container = try Node.create(allocator, 2, .button, .{ .width = .{ .px = 220 }, .height = .{ .px = 140 } });
    container.behavior.interaction.focusable = true;
    try root.appendChild(allocator, container);

    const child = try Node.create(allocator, 3, .button, .{ .width = .{ .px = 80 }, .height = .{ .px = 36 } });
    child.behavior.interaction.focusable = true;
    try container.appendChild(allocator, child);

    root.setLayoutRect(.{ .x = 0, .y = 0, .w = 240, .h = 160 });
    container.setLayoutRect(.{ .x = 10, .y = 10, .w = 220, .h = 140 });
    child.setLayoutRect(.{ .x = 40, .y = 30, .w = 80, .h = 36 });

    try registry.rebuild(root);
    try runtime.rebuild(root, &registry);

    const container_hit = runtime.hitTestQuery(.{ .kind = .pointer, .world_x = 20, .world_y = 20 }, &registry, null);
    try std.testing.expect(container_hit != null);
    try std.testing.expectEqual(@as(u32, 2), container_hit.?.node_id);
    runtime.setHoveredResult(container_hit);

    const child_hit = runtime.hitTestQuery(.{ .kind = .pointer, .world_x = 70, .world_y = 60 }, &registry, null);
    try std.testing.expect(child_hit != null);
    try std.testing.expectEqual(@as(u32, 3), child_hit.?.node_id);
}

test "HitRuntime: pointer query ignores mouse-down cache when deeper child is topmost" {
    const allocator = std.testing.allocator;
    var registry = NodeRegistry.init(allocator);
    defer registry.deinit();
    var runtime = HitRuntime.init(allocator);
    defer runtime.deinit();

    const root = try Node.create(allocator, 11, .box, .{ .width = .{ .px = 240 }, .height = .{ .px = 160 } });
    defer root.destroy(allocator);

    const container = try Node.create(allocator, 12, .button, .{ .width = .{ .px = 220 }, .height = .{ .px = 140 } });
    container.behavior.interaction.focusable = true;
    try root.appendChild(allocator, container);

    const child = try Node.create(allocator, 13, .button, .{ .width = .{ .px = 80 }, .height = .{ .px = 36 } });
    child.behavior.interaction.focusable = true;
    try container.appendChild(allocator, child);

    root.setLayoutRect(.{ .x = 0, .y = 0, .w = 240, .h = 160 });
    container.setLayoutRect(.{ .x = 10, .y = 10, .w = 220, .h = 140 });
    child.setLayoutRect(.{ .x = 40, .y = 30, .w = 80, .h = 36 });

    try registry.rebuild(root);
    try runtime.rebuild(root, &registry);

    const container_hit = runtime.hitTestQuery(.{ .kind = .pointer, .world_x = 20, .world_y = 20 }, &registry, null);
    try std.testing.expect(container_hit != null);
    try std.testing.expectEqual(@as(u32, 12), container_hit.?.node_id);
    runtime.setMouseDownResult(container_hit);

    const child_hit = runtime.hitTestQuery(.{ .kind = .pointer, .world_x = 70, .world_y = 60 }, &registry, null);
    try std.testing.expect(child_hit != null);
    try std.testing.expectEqual(@as(u32, 13), child_hit.?.node_id);
}

test "HitRuntime: opaque island blocks pass-through to full-window canvas" {
    const allocator = std.testing.allocator;
    var registry = NodeRegistry.init(allocator);
    defer registry.deinit();
    var runtime = HitRuntime.init(allocator);
    defer runtime.deinit();

    // 下游应用布局：canvas_host 满窗打底，chrome 岛作为兄弟浮在其上。
    const root = try Node.create(allocator, 41, .box, .{});
    defer root.destroy(allocator);

    const canvas = try Node.create(allocator, 42, .box, .{});
    canvas.behavior.interaction.focusable = true; // 画布自身可点
    try root.appendChild(allocator, canvas);

    // 纯视觉岛壳：自身没有任何 handler。
    const island = try Node.create(allocator, 43, .box, .{});
    try root.appendChild(allocator, island);

    const button = try Node.create(allocator, 44, .button, .{});
    try island.appendChild(allocator, button);

    root.setLayoutRect(.{ .x = 0, .y = 0, .w = 400, .h = 300 });
    canvas.setLayoutRect(.{ .x = 0, .y = 0, .w = 400, .h = 300 });
    island.setLayoutRect(.{ .x = 10, .y = 10, .w = 200, .h = 100 });
    button.setLayoutRect(.{ .x = 0, .y = 0, .w = 40, .h = 20 });

    try registry.rebuild(root);
    try runtime.rebuild(root, &registry);

    // 修复前：点岛的空白处穿透到 canvas。
    const leaked = runtime.hitTestQuery(.{ .kind = .pointer, .world_x = 150, .world_y = 90 }, &registry, null);
    try std.testing.expect(leaked != null);
    try std.testing.expectEqual(@as(u32, 42), leaked.?.node_id);

    // 浮层根节点只需一个字段：拦截型 hit_behavior 自动隐含 pointer role。
    island.style.ensureExtPanic(allocator).hit_behavior = .@"opaque";
    try runtime.rebuild(root, &registry);

    // 岛空白处 ⇒ 命中岛本身，不再是 canvas。
    const blocked = runtime.hitTestQuery(.{ .kind = .pointer, .world_x = 150, .world_y = 90 }, &registry, null);
    try std.testing.expect(blocked != null);
    try std.testing.expectEqual(@as(u32, 43), blocked.?.node_id);

    // 岛内既有控件行为不变。
    const on_button = runtime.hitTestQuery(.{ .kind = .pointer, .world_x = 20, .world_y = 20 }, &registry, null);
    try std.testing.expect(on_button != null);
    try std.testing.expectEqual(@as(u32, 44), on_button.?.node_id);

    // 画布空白处仍然命中 canvas。
    const on_canvas = runtime.hitTestQuery(.{ .kind = .pointer, .world_x = 300, .world_y = 250 }, &registry, null);
    try std.testing.expect(on_canvas != null);
    try std.testing.expectEqual(@as(u32, 42), on_canvas.?.node_id);
}

test "HitRuntime: explicit opaque hit_behavior implies pointer role" {
    const allocator = std.testing.allocator;
    var registry = NodeRegistry.init(allocator);
    defer registry.deinit();
    var runtime = HitRuntime.init(allocator);
    defer runtime.deinit();

    const root = try Node.create(allocator, 51, .box, .{});
    defer root.destroy(allocator);

    const under = try Node.create(allocator, 52, .box, .{});
    under.behavior.interaction.focusable = true;
    try root.appendChild(allocator, under);

    const panel = try Node.create(allocator, 53, .box, .{});
    // 只设 hit_behavior，不设 hit_roles —— 应当独立生效。
    panel.style.ensureExtPanic(allocator).hit_behavior = .@"opaque";
    try root.appendChild(allocator, panel);

    root.setLayoutRect(.{ .x = 0, .y = 0, .w = 400, .h = 300 });
    under.setLayoutRect(.{ .x = 0, .y = 0, .w = 400, .h = 300 });
    panel.setLayoutRect(.{ .x = 10, .y = 10, .w = 200, .h = 100 });

    try registry.rebuild(root);
    try runtime.rebuild(root, &registry);

    const hit = runtime.hitTestQuery(.{ .kind = .pointer, .world_x = 100, .world_y = 60 }, &registry, null);
    try std.testing.expect(hit != null);
    try std.testing.expectEqual(@as(u32, 53), hit.?.node_id);
}

test "HitRuntime: partial hit_roles override keeps unspecified roles at defaults" {
    const allocator = std.testing.allocator;
    var registry = NodeRegistry.init(allocator);
    defer registry.deinit();
    var runtime = HitRuntime.init(allocator);
    defer runtime.deinit();

    const root = try Node.create(allocator, 71, .box, .{});
    defer root.destroy(allocator);

    // 只覆盖 pointer。inspect 必须保持推导默认值（true），不能被静默归零——
    // 否则该节点在 devtools 里选不中（HitRolesOverride 存在的理由）。
    const panel = try Node.create(allocator, 72, .box, .{});
    panel.frame_state.state_bits.flags.inspectable = true;
    panel.style.ensureExtPanic(allocator).hit_roles = .{ .pointer = true };
    try root.appendChild(allocator, panel);

    root.setLayoutRect(.{ .x = 0, .y = 0, .w = 400, .h = 300 });
    panel.setLayoutRect(.{ .x = 10, .y = 10, .w = 200, .h = 100 });

    try registry.rebuild(root);
    try runtime.rebuild(root, &registry);

    const roles = interaction_semantics.nodeHitRoles(panel);
    try std.testing.expect(roles.pointer);
    try std.testing.expect(roles.inspect);

    const inspect_hit = runtime.hitTestQuery(.{ .kind = .inspect, .world_x = 100, .world_y = 60 }, &registry, null);
    try std.testing.expect(inspect_hit != null);
    try std.testing.expectEqual(@as(u32, 72), inspect_hit.?.node_id);
}

test "HitRuntime: partial override lets scroll owner keep its derived scroll role" {
    const allocator = std.testing.allocator;
    var registry = NodeRegistry.init(allocator);
    defer registry.deinit();
    var runtime = HitRuntime.init(allocator);
    defer runtime.deinit();

    const root = try Node.create(allocator, 81, .box, .{});
    defer root.destroy(allocator);

    // overlay_stack:509 的形状：dialog content 根只被加了 pointer role。
    // 旧的全量覆盖会把 scroll 一并归零，滚轮事件因此不再路由到它；
    // 逐 role 覆盖后 scroll 按"它本身是不是 scroll owner"推导。
    const content = try Node.create(allocator, 82, .scroll, .{});
    content.style.ensureExtPanic(allocator).hit_roles = .{ .pointer = true };
    try root.appendChild(allocator, content);

    root.setLayoutRect(.{ .x = 0, .y = 0, .w = 400, .h = 300 });
    content.setLayoutRect(.{ .x = 10, .y = 10, .w = 200, .h = 100 });

    try registry.rebuild(root);
    try runtime.rebuild(root, &registry);

    const roles = interaction_semantics.nodeHitRoles(content);
    try std.testing.expect(roles.pointer);
    try std.testing.expect(roles.scroll);

    const scroll_hit = runtime.hitTestQuery(.{ .kind = .scroll, .world_x = 100, .world_y = 60 }, &registry, null);
    try std.testing.expect(scroll_hit != null);
    try std.testing.expectEqual(@as(u32, 82), scroll_hit.?.node_id);
}

test "HitRuntime: every intercepting hit_behavior variant implies pointer role" {
    const allocator = std.testing.allocator;

    // 文档声明三个拦截型变体都隐含 pointer，穿透型两个都不隐含 —— 逐个钉死。
    for ([_]HitBehavior{ .@"opaque", .self_only, .self_and_children }) |behavior| {
        const node = try Node.create(allocator, 91, .box, .{});
        defer node.destroy(allocator);
        node.style.ensureExtPanic(allocator).hit_behavior = behavior;
        try std.testing.expect(interaction_semantics.nodeHitRoles(node).pointer);
    }

    for ([_]HitBehavior{ .pass_through, .children_only }) |behavior| {
        const node = try Node.create(allocator, 92, .box, .{});
        defer node.destroy(allocator);
        node.style.ensureExtPanic(allocator).hit_behavior = behavior;
        try std.testing.expect(!interaction_semantics.nodeHitRoles(node).pointer);
    }
}

test "HitRuntime: explicit hit_roles beats hit_behavior implication" {
    const allocator = std.testing.allocator;
    var registry = NodeRegistry.init(allocator);
    defer registry.deinit();
    var runtime = HitRuntime.init(allocator);
    defer runtime.deinit();

    const root = try Node.create(allocator, 61, .box, .{});
    defer root.destroy(allocator);

    const under = try Node.create(allocator, 62, .box, .{});
    under.behavior.interaction.focusable = true;
    try root.appendChild(allocator, under);

    // 显式写出的 role 压过 hit_behavior 的隐含推导：这里显式 pointer = false，
    // 即使 behavior 是拦截型，节点仍然穿透。
    const panel = try Node.create(allocator, 63, .box, .{});
    const ext = panel.style.ensureExtPanic(allocator);
    ext.hit_behavior = .@"opaque";
    ext.hit_roles = .{ .pointer = false };
    try root.appendChild(allocator, panel);

    root.setLayoutRect(.{ .x = 0, .y = 0, .w = 400, .h = 300 });
    under.setLayoutRect(.{ .x = 0, .y = 0, .w = 400, .h = 300 });
    panel.setLayoutRect(.{ .x = 10, .y = 10, .w = 200, .h = 100 });

    try registry.rebuild(root);
    try runtime.rebuild(root, &registry);

    const hit = runtime.hitTestQuery(.{ .kind = .pointer, .world_x = 100, .world_y = 60 }, &registry, null);
    try std.testing.expect(hit != null);
    try std.testing.expectEqual(@as(u32, 62), hit.?.node_id);
}

test "HitRuntime: hidden hit-test ancestor removes entire subtree from pointer hits" {
    const allocator = std.testing.allocator;
    var registry = NodeRegistry.init(allocator);
    defer registry.deinit();
    var runtime = HitRuntime.init(allocator);
    defer runtime.deinit();

    const root = try Node.create(allocator, 21, .box, .{ .width = .{ .px = 220 }, .height = .{ .px = 160 } });
    defer root.destroy(allocator);

    const under = try Node.create(allocator, 22, .button, .{ .width = .{ .px = 120 }, .height = .{ .px = 80 } });
    under.behavior.interaction.focusable = true;
    try root.appendChild(allocator, under);

    const overlay = try Node.create(allocator, 23, .box, .{ .width = .{ .px = 120 }, .height = .{ .px = 80 } });
    try root.appendChild(allocator, overlay);

    const option = try Node.create(allocator, 24, .button, .{ .width = .{ .px = 120 }, .height = .{ .px = 80 } });
    option.behavior.interaction.focusable = true;
    try overlay.appendChild(allocator, option);

    root.setLayoutRect(.{ .x = 0, .y = 0, .w = 220, .h = 160 });
    under.setLayoutRect(.{ .x = 20, .y = 20, .w = 120, .h = 80 });
    overlay.setLayoutRect(.{ .x = 20, .y = 20, .w = 120, .h = 80 });
    option.setLayoutRect(.{ .x = 0, .y = 0, .w = 120, .h = 80 });

    try registry.rebuild(root);
    try runtime.rebuild(root, &registry);

    const before = runtime.hitTestQuery(.{ .kind = .pointer, .world_x = 60, .world_y = 50 }, &registry, null);
    try std.testing.expect(before != null);
    try std.testing.expectEqual(@as(u32, 24), before.?.node_id);

    overlay.setHitTestVisible(false);
    try runtime.rebuild(root, &registry);

    const after = runtime.hitTestQuery(.{ .kind = .pointer, .world_x = 60, .world_y = 50 }, &registry, null);
    try std.testing.expect(after != null);
    try std.testing.expectEqual(@as(u32, 22), after.?.node_id);
}

test "HitRuntime: partial rebuild 刷新祖先 clip 条目的陈旧尺寸（Show 重挂载类回归）" {
    // 复现（CORE_REVIEW_2026-08-16 后续，storybook cleanup story 实测）：
    // clip 祖先在旧布局下烘焙了 clip_chain 条目；内容变化把 clip 长高、按钮被
    // 推到旧 clip 下缘之外；partial rebuild 根只覆盖内层子树（clip 祖先脏标记
    // 已被更早的 full rebuild 消费）→ 按钮 proxy 位置刷新但祖先 clip 条目仍是
    // 旧尺寸 → 命中被 clipChainContains 拒绝，点击穿透到外层。
    const allocator = std.testing.allocator;
    var registry = NodeRegistry.init(allocator);
    defer registry.deinit();
    var runtime = HitRuntime.init(allocator);
    defer runtime.deinit();

    const root = try Node.create(allocator, 1, .box, .{ .width = .{ .px = 200 }, .height = .{ .px = 400 } });
    defer root.destroy(allocator);
    root.frame_state.state_bits.flags.inspectable = false;

    const clipbox = try Node.create(allocator, 2, .box, .{ .width = .{ .px = 200 }, .height = .{ .px = 150 } });
    clipbox.style.overflow_hidden = true;
    try root.appendChild(allocator, clipbox);

    const inner = try Node.create(allocator, 3, .box, .{ .width = .{ .px = 200 }, .height = .{ .px = 150 } });
    try clipbox.appendChild(allocator, inner);

    const button = try Node.create(allocator, 4, .button, .{ .width = .{ .px = 80 }, .height = .{ .px = 30 } });
    try inner.appendChild(allocator, button);

    // 初始布局：clip 高 150，按钮在 clip 内 (10,100)
    root.setLayoutRect(.{ .x = 0, .y = 0, .w = 200, .h = 400 });
    clipbox.setLayoutRect(.{ .x = 0, .y = 0, .w = 200, .h = 150 });
    inner.setLayoutRect(.{ .x = 0, .y = 0, .w = 200, .h = 150 });
    button.setLayoutRect(.{ .x = 10, .y = 100, .w = 80, .h = 30 });

    try registry.rebuild(root);
    try runtime.rebuild(root, &registry);

    const hit_before = runtime.hitTestQuery(.{ .kind = .pointer, .world_x = 20, .world_y = 110 }, &registry, null);
    try std.testing.expect(hit_before != null);
    try std.testing.expectEqual(@as(u64, 4), hit_before.?.node_id);

    // 内容变化：clip 长高到 300，按钮被推到 (10,200)——旧 clip 边界（150）之外。
    // 模拟"祖先脏标记已被消费"：只对 inner 子树做 partial rebuild，clipbox 不在根内。
    clipbox.setLayoutRect(.{ .x = 0, .y = 0, .w = 200, .h = 300 });
    inner.setLayoutRect(.{ .x = 0, .y = 0, .w = 200, .h = 300 });
    button.setLayoutRect(.{ .x = 10, .y = 200, .w = 80, .h = 30 });

    try std.testing.expect(try runtime.rebuildSubtree(inner, &registry));

    // 修复前：按钮 proxy 在 (10,200) 但祖先 clip 条目缓存 h=150 → miss（命中 null 或外层）。
    const hit_after = runtime.hitTestQuery(.{ .kind = .pointer, .world_x = 20, .world_y = 210 }, &registry, null);
    try std.testing.expect(hit_after != null);
    try std.testing.expectEqual(@as(u64, 4), hit_after.?.node_id);

    // 旧位置（clip 内但按钮已不在）不应再命中按钮。
    const hit_stale = runtime.hitTestQuery(.{ .kind = .pointer, .world_x = 20, .world_y = 110 }, &registry, null);
    try std.testing.expect(hit_stale == null or hit_stale.?.node_id != 4);
}

test "HitRuntime: repeated partial rebuilds compact append-only hit metadata" {
    const allocator = std.testing.allocator;
    var registry = NodeRegistry.init(allocator);
    defer registry.deinit();
    var runtime = HitRuntime.init(allocator);
    defer runtime.deinit();

    const root = try Node.create(allocator, 1, .box, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } });
    defer root.destroy(allocator);
    root.frame_state.state_bits.flags.inspectable = false;

    const button = try Node.create(allocator, 2, .button, .{ .width = .{ .px = 80 }, .height = .{ .px = 30 } });
    try root.appendChild(allocator, button);
    root.setLayoutRect(.{ .x = 0, .y = 0, .w = 200, .h = 100 });
    button.setLayoutRect(.{ .x = 10, .y = 10, .w = 80, .h = 30 });

    try registry.rebuild(root);
    try runtime.rebuild(root, &registry);

    var compactions: usize = 0;
    for (0..600) |_| {
        if (!(try runtime.rebuildSubtree(button, &registry))) {
            compactions += 1;
            try runtime.rebuild(root, &registry);
        }
    }

    try std.testing.expect(compactions >= 2);
    try std.testing.expect(runtime.proxies.items.len <= runtime.live_proxy_count + 257);
    const hit = runtime.hitTestQuery(.{ .kind = .pointer, .world_x = 20, .world_y = 20 }, &registry, null);
    try std.testing.expect(hit != null);
    try std.testing.expectEqual(@as(u64, 2), hit.?.node_id);
}

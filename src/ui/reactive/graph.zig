//! Reactive Graph, Phase 1 push-pull 混合调度核心
//!
//! 为什么需要这个：原 reactive 系统是朴素深度优先 push（signal.notifyImpl 直接
//! 同步驱动 effect.runWithTracking），三个根问题：
//!   1. 钻石依赖：A->B(memo)->C, A->C，C 可能在 B 重算前看到陈旧 memo 值
//!   2. memo eager 计算：未读也跑
//!   3. batch flush 16 次硬上限 + 插入序遍历，diamond 内必然 glitch
//!
//! 工业参考（吸取的 + 避坑的）：
//!   - Solid v1：dirty/check 双阶段标记 + lazy memo，我们采用
//!   - Reactively（论文）：version stamp + pull-up 比对，我们采用
//!   - SwiftUI AttributeGraph：纯 pull，部分采用（memo lazy）；effect 仍 push
//!     避坑：AG 早期黑盒批评，我们提供 dumpGraph + traceUpdate
//!   - React fiber 优先级队列：太重，不抄
//!
//! 数据模型：
//!   GraphNode {
//!     kind: signal | memo | effect
//!     version: u64                 (signal: write++; memo: 重算且值变++)
//!     state: clean | check | dirty (Solid v1 风格三态)
//!     depth: u32                   (拓扑深度；动态依赖时 max(sources)+1)
//!     sources: []ReactiveNodeId    (我读的)
//!     observers: []ReactiveNodeId  (读我的)
//!   }
//!
//! 算法：
//!   write(signal):
//!     signal.version += 1
//!     for obs in signal.observers: markCheck(obs)  // 不递归 push effect
//!     enqueue dirty observers (effects only)
//!
//!   markCheck(node):
//!     if node.state == clean: node.state = check
//!     for obs: markCheck(obs)  // 仅在 clean->check 转移时递归（防止重复）
//!
//!   read(memo):
//!     updateIfNecessary(memo)
//!     return memo.value
//!
//!   updateIfNecessary(node):
//!     if node.state == clean: return
//!     if node.state == check:
//!       for src in node.sources:
//!         updateIfNecessary(src)
//!         if src.version > node.last_seen_version[src]: node.state = dirty; break
//!       if still check: node.state = clean; return
//!     if node.state == dirty: recompute(node); node.state = clean
//!
//! 这个文件先做纯数据结构 + 单测；signal/memo/effect facade 在后续 patch 中
//! 接入。第一步：结构 + 单测（diamond glitch 自由的 minimal 演示）。

const std = @import("std");
const testing = std.testing;
const eqlValue = @import("eq.zig").eqlValue;

// ============================================================================
// 节点 ID + 类型
// ============================================================================

pub const NodeKind = enum(u8) {
    signal,
    memo,
    effect,
};

pub const NodeState = enum(u8) {
    clean,
    check,
    dirty,
};

pub const NodeId = packed struct(u32) {
    index: u24,
    generation: u8,

    pub const NULL: NodeId = .{ .index = 0xFFFFFF, .generation = 0xFF };

    pub fn isNull(self: NodeId) bool {
        return self.index == 0xFFFFFF;
    }

    pub fn eq(a: NodeId, b: NodeId) bool {
        return a.index == b.index and a.generation == b.generation;
    }
};

// ============================================================================
// GraphNode
// ============================================================================

pub const RecomputeFn = *const fn (ctx: *anyopaque) bool; // 返回 true 表示值发生变化

pub const GraphNode = struct {
    kind: NodeKind,
    state: NodeState,
    /// 自身值的版本号；signal write 或 memo 重算且值变时 ++
    version: u64,
    /// 拓扑深度。signal=0；memo/effect=max(sources.depth)+1
    depth: u32,
    /// 我依赖的节点（读过的 source）
    sources: std.ArrayListUnmanaged(NodeId),
    /// 我被谁观察（写时通知的 observer）
    observers: std.ArrayListUnmanaged(NodeId),
    /// 上次重算时各 source 的 version 快照；updateIfNecessary 比对此值
    seen_versions: std.ArrayListUnmanaged(u64),
    /// 每条 source 在最近一次 recompute 时被 trackRead 命中的 run epoch；
    /// recompute 结束后小于 current_run 的 source 被 prune（动态依赖切换的清理）。
    /// 与 sources / seen_versions 同长度。
    source_runs: std.ArrayListUnmanaged(u32),
    /// 当前 recompute 的 run epoch，递增；trackRead 写入对应 source_runs 槽。
    current_run: u32 = 0,
    /// 用于 memo / effect：重算入口；signal 为 null
    recompute: ?RecomputeFn = null,
    /// 重算闭包上下文（memo/effect 的状态）
    recompute_ctx: ?*anyopaque = null,
    /// 节点是否被释放（generation 通过 SlotMap 管理；这里只标"逻辑死"）
    alive: bool = true,
    /// effect 重入保护
    is_running: bool = false,
    /// Failed dependency capture must never publish this run as clean.
    tracking_failed: bool = false,
};

// ============================================================================
// ReactiveGraph，全局调度器
// ============================================================================

/// 依赖追踪压栈失败次数（OOM / 栈满）。每次都意味着一次 recompute 被跳过、
/// 节点保持陈旧值，稳态下必须恒为 0。
pub var reactive_tracking_failures: u64 = 0;
/// Reactive dependency chains deeper than this are rejected before they can
/// exhaust the process stack. Real UI graphs are normally shallow; the bound
/// primarily protects applications that compile untrusted nested data into a
/// memo/effect chain.
pub const max_reactive_recursion_depth: usize = 128;
pub var reactive_depth_limit_hits: u64 = 0;
/// 测试用静音开关（Zig test runner 把 std.log.err 视为测试失败，
/// 而"错误被上报"恰恰是要断言的行为）。
pub var suppress_reactive_error_log: bool = false;

pub const ReactiveGraph = struct {
    allocator: std.mem.Allocator,
    nodes: std.ArrayListUnmanaged(GraphNode),
    free_list: std.ArrayListUnmanaged(u24),
    generations: std.ArrayListUnmanaged(u8),

    /// 当前正在 recompute 的节点（依赖追踪栈顶）
    tracking_stack: std.ArrayListUnmanaged(NodeId),
    /// 是否启用追踪（untrack 时关）
    tracking_enabled: bool,

    /// 待执行 effect 队列；endBatch 时按 depth 排序后 drain
    pending_effects: std.ArrayListUnmanaged(NodeId),
    /// drain 期间的临时 buffer（与 pending_effects swap 避免 alloc）
    drain_buffer: std.ArrayListUnmanaged(NodeId),
    /// Reused DFS worklist for observer propagation. Capacity is reserved
    /// before any node state changes, so worklist OOM cannot half-dirty a graph.
    propagation_stack: std.ArrayListUnmanaged(NodeId),
    /// batch 嵌套深度（栈式）；> 0 时 write 不立即 drain
    batch_depth: u32,
    /// flush 期间正在 drain 防止重入
    flushing: bool,
    /// `updateIfNecessary` may recurse both through source checks and through
    /// user recompute callbacks. Keep the depth on the graph so both paths
    /// share one budget instead of resetting at callback boundaries.
    update_depth: usize,

    pub fn init(allocator: std.mem.Allocator) ReactiveGraph {
        return .{
            .allocator = allocator,
            .nodes = .{},
            .free_list = .{},
            .generations = .{},
            .tracking_stack = .{},
            .tracking_enabled = true,
            .pending_effects = .{},
            .drain_buffer = .{},
            .propagation_stack = .{},
            .batch_depth = 0,
            .flushing = false,
            .update_depth = 0,
        };
    }

    pub fn deinit(self: *ReactiveGraph) void {
        for (self.nodes.items) |*n| {
            if (!n.alive) continue; // destroyNode 已经回收过这些 ArrayList
            n.sources.deinit(self.allocator);
            n.observers.deinit(self.allocator);
            n.seen_versions.deinit(self.allocator);
            n.source_runs.deinit(self.allocator);
        }
        self.nodes.deinit(self.allocator);
        self.free_list.deinit(self.allocator);
        self.generations.deinit(self.allocator);
        self.tracking_stack.deinit(self.allocator);
        self.pending_effects.deinit(self.allocator);
        self.drain_buffer.deinit(self.allocator);
        self.propagation_stack.deinit(self.allocator);
        self.* = undefined;
    }

    // ------------------------------------------------------------------------
    // 节点生命周期
    // ------------------------------------------------------------------------

    pub fn createSignal(self: *ReactiveGraph) !NodeId {
        return try self.createNode(.{
            .kind = .signal,
            .state = .clean,
            .version = 1,
            .depth = 0,
            .sources = .{},
            .observers = .{},
            .seen_versions = .{},
            .source_runs = .{},
        });
    }

    pub fn createMemo(
        self: *ReactiveGraph,
        recompute: RecomputeFn,
        ctx: *anyopaque,
    ) !NodeId {
        return try self.createNode(.{
            .kind = .memo,
            .state = .dirty, // 初次读时计算
            .version = 0,
            .depth = 0,
            .sources = .{},
            .observers = .{},
            .seen_versions = .{},
            .source_runs = .{},
            .recompute = recompute,
            .recompute_ctx = ctx,
        });
    }

    pub fn createEffect(
        self: *ReactiveGraph,
        recompute: RecomputeFn,
        ctx: *anyopaque,
    ) !NodeId {
        const id = try self.createNode(.{
            .kind = .effect,
            .state = .dirty,
            .version = 0,
            .depth = 0,
            .sources = .{},
            .observers = .{},
            .seen_versions = .{},
            .source_runs = .{},
            .recompute = recompute,
            .recompute_ctx = ctx,
        });
        // effect 创建时立即跑一次（建立依赖）
        self.runEffect(id);
        return id;
    }

    /// 不立即跑的版本，facade 层（reactive/effect.zig）需要先建立
    /// EffectBase 与 graph node 的双向引用，再由 facade 自己触发首次 run。
    /// 否则首次 graph.recomputeNode 调 callback 时 EffectBase.graph_node_raw
    /// 还没 set，依赖追踪会缺一帧。
    ///
    /// 重要：effect 创建时 state = .clean（不是 .dirty），facade 层会立即
    /// 通过 EffectBase.runWithTracking 完成首次运行 + 依赖收集；之后 signal
    /// propagate 时才能正确从 clean -> dirty 转移并入 pending_effects。
    /// 若初始 state = .dirty，propagate 会跳过它（因 "if obs.state == .dirty continue"）。
    pub fn createNodeRaw(
        self: *ReactiveGraph,
        kind: NodeKind,
        recompute: RecomputeFn,
        ctx: *anyopaque,
    ) !NodeId {
        return try self.createNode(.{
            .kind = kind,
            // signal/effect 都从 clean 开始；memo 仍 .dirty（lazy 初次读时计算）
            .state = if (kind == .memo) .dirty else .clean,
            .version = if (kind == .signal) 1 else 0,
            .depth = 0,
            .sources = .{},
            .observers = .{},
            .seen_versions = .{},
            .source_runs = .{},
            .recompute = recompute,
            .recompute_ctx = ctx,
        });
    }

    fn createNode(self: *ReactiveGraph, node: GraphNode) !NodeId {
        // 世代退役（防 ABA，对齐 element_id.SlotMap）：generation 推进到
        // 0xFF（=NULL 的 generation）的 slot 永久退役不再复用。alive 位挡不住
        // 复用后的假匹配，第 255 次复用回卷后，陈旧 NodeId 会重新 isAlive，
        // 悬垂的 graph_node_raw 静默指到无关节点。
        while (self.free_list.pop()) |idx| {
            const next_gen = self.generations.items[idx] +% 1;
            if (next_gen == 0xFF) {
                self.generations.items[idx] = 0xFF;
                continue;
            }
            self.nodes.items[idx] = node;
            self.generations.items[idx] = next_gen;
            return .{ .index = idx, .generation = next_gen };
        }
        const idx = self.nodes.items.len;
        if (idx >= 0xFFFFFF) return error.GraphFull;
        // Prepare all parallel storage before publishing a live slot. Reserve
        // reclamation too: destroying a node must not allocate or lose its slot.
        try self.nodes.ensureTotalCapacity(self.allocator, idx + 1);
        try self.generations.ensureTotalCapacity(self.allocator, idx + 1);
        try self.free_list.ensureTotalCapacity(self.allocator, idx + 1);
        self.nodes.appendAssumeCapacity(node);
        self.generations.appendAssumeCapacity(0);
        return .{ .index = @intCast(idx), .generation = 0 };
    }

    pub fn destroyNode(self: *ReactiveGraph, id: NodeId) void {
        if (!self.isAlive(id)) return;
        const n = &self.nodes.items[id.index];
        // 从所有 source 的 observers 中移除自己
        for (n.sources.items) |src_id| {
            if (self.isAlive(src_id)) {
                const src = &self.nodes.items[src_id.index];
                removeFromList(&src.observers, id);
            }
        }
        // 从所有 observer 的 sources 中移除自己（observer 仍存在但失去这个 source）
        for (n.observers.items) |obs_id| {
            if (self.isAlive(obs_id)) {
                const obs = &self.nodes.items[obs_id.index];
                if (indexOf(obs.sources, id)) |idx| {
                    _ = obs.sources.swapRemove(idx);
                    if (idx < obs.seen_versions.items.len) {
                        _ = obs.seen_versions.swapRemove(idx);
                    }
                    if (idx < obs.source_runs.items.len) {
                        _ = obs.source_runs.swapRemove(idx);
                    }
                }
            }
        }
        n.sources.deinit(self.allocator);
        n.observers.deinit(self.allocator);
        n.seen_versions.deinit(self.allocator);
        n.source_runs.deinit(self.allocator);
        n.alive = false;
        self.free_list.appendAssumeCapacity(id.index);
    }

    pub fn isAlive(self: *const ReactiveGraph, id: NodeId) bool {
        if (id.isNull()) return false;
        if (id.index >= self.nodes.items.len) return false;
        if (self.generations.items[id.index] != id.generation) return false;
        return self.nodes.items[id.index].alive;
    }

    pub fn getNode(self: *ReactiveGraph, id: NodeId) ?*GraphNode {
        if (!self.isAlive(id)) return null;
        return &self.nodes.items[id.index];
    }

    // ------------------------------------------------------------------------
    // 依赖追踪
    // ------------------------------------------------------------------------

    /// 在读 signal/memo 时调用以建立 caller -> callee 边。
    /// 由 facade 在 get/peek 路径调用。
    pub fn trackRead(self: *ReactiveGraph, source_id: NodeId) !void {
        if (!self.tracking_enabled) return;
        if (self.tracking_stack.items.len == 0) return;
        const reader_id = self.tracking_stack.items[self.tracking_stack.items.len - 1];
        if (reader_id.eq(source_id)) return; // 自循环不可能但保险
        self.addEdge(reader_id, source_id) catch |err| {
            if (self.getNode(reader_id)) |reader| {
                reader.tracking_failed = true;
                reader.state = .dirty;
            }
            reactive_tracking_failures +|= 1;
            return err;
        };
    }

    fn addEdge(self: *ReactiveGraph, reader: NodeId, source: NodeId) !void {
        const r = self.getNode(reader) orelse return;
        const s = self.getNode(source) orelse return;
        // 去重：已经有这个 source？标记 current_run（v0.5-P2 epoch 化追踪）
        for (r.sources.items, 0..) |existing, i| {
            if (existing.eq(source)) {
                if (i < r.source_runs.items.len) {
                    r.source_runs.items[i] = r.current_run;
                }
                return;
            }
        }
        // 四表先全部预留、再不可失败地写入：中途 OOM 不得留下半建边
        // （sources 已增而 seen_versions/source_runs 缺失 -> version 比较错位，
        // 该重算的 memo 静默不重算；或正向边无反向 observer -> 永不被唤醒）。
        try r.sources.ensureUnusedCapacity(self.allocator, 1);
        try r.seen_versions.ensureUnusedCapacity(self.allocator, 1);
        try r.source_runs.ensureUnusedCapacity(self.allocator, 1);
        try s.observers.ensureUnusedCapacity(self.allocator, 1);
        r.sources.appendAssumeCapacity(source);
        r.seen_versions.appendAssumeCapacity(s.version);
        r.source_runs.appendAssumeCapacity(r.current_run);
        s.observers.appendAssumeCapacity(reader);

        // 拓扑深度更新
        if (s.depth + 1 > r.depth) r.depth = s.depth + 1;
    }

    /// 公共版本，facade（EffectBase.runWithTracking）在 effectFn run
    /// 之前调，配合动态依赖追踪。
    pub fn clearSourcesPub(self: *ReactiveGraph, id: NodeId) void {
        self.clearSources(id);
    }

    /// 清掉一个节点的所有 source 边（重算前调用，配合动态依赖）
    fn clearSources(self: *ReactiveGraph, id: NodeId) void {
        const n = self.getNode(id) orelse return;
        for (n.sources.items) |src_id| {
            const s = self.getNode(src_id) orelse continue;
            removeFromList(&s.observers, id);
        }
        n.sources.clearRetainingCapacity();
        n.seen_versions.clearRetainingCapacity();
        n.source_runs.clearRetainingCapacity();
    }

    pub fn pushTracking(self: *ReactiveGraph, id: NodeId) !void {
        try self.tracking_stack.append(self.allocator, id);
    }

    pub fn popTracking(self: *ReactiveGraph) void {
        _ = self.tracking_stack.pop();
    }

    pub fn untrack(self: *ReactiveGraph, comptime fnRef: anytype, args: anytype) @TypeOf(@call(.auto, fnRef, args)) {
        const prev = self.tracking_enabled;
        self.tracking_enabled = false;
        defer self.tracking_enabled = prev;
        return @call(.auto, fnRef, args);
    }

    // ------------------------------------------------------------------------
    // 写入路径
    // ------------------------------------------------------------------------

    /// 标记 signal 已写入（caller 已写好新值并判定不等）。
    pub fn markSignalWritten(self: *ReactiveGraph, id: NodeId) !void {
        const n = self.getNode(id) orelse return;
        std.debug.assert(n.kind == .signal);
        n.version +%= 1;
        // 标记直接 observers 为 dirty，间接 observers 为 check
        var first_error: ?anyerror = null;
        self.propagate(id) catch |err| {
            first_error = err;
        };
        // batch 外立即 drain
        if (self.batch_depth == 0) {
            self.drainPendingEffects() catch |err| {
                if (first_error == null) first_error = err;
            };
        }
        if (first_error) |err| return err;
    }

    fn propagate(self: *ReactiveGraph, source_id: NodeId) !void {
        // Each node transitions out of `.clean` at most once in this walk, so
        // `nodes.len` is a strict upper bound. Reserve before touching state:
        // an OOM then leaves the graph wholly retryable.
        try self.propagation_stack.ensureTotalCapacity(self.allocator, self.nodes.items.len);
        self.propagation_stack.clearRetainingCapacity();

        const src = self.getNode(source_id) orelse return;
        // 不拷贝 observer 列表，直接遍历。observer 在 propagate 内部不会变：
        // 1. 我们只改 obs.state 和 obs.kind 的 pending 入队，不增删 observers
        // 2. 真正的 effect run 在 drainPendingEffects 才发生，那时 propagate 已结束
        // 这避免 O(N) 的拷贝；对 1k fanout 显著降开销。
        const observers_len = src.observers.items.len;
        var first_error: ?anyerror = null;
        var i: usize = 0;
        while (i < observers_len) : (i += 1) {
            const obs_id = src.observers.items[i];
            const obs = self.getNode(obs_id) orelse continue;
            if (obs.state == .dirty) continue;
            // **先入队、后置位**：顺序反过来时，append OOM 会让 effect 停在
            // "dirty 但不在 pending"，此后每次写入都因 `state == .dirty`
            // 跳过它，一次瞬时 OOM 把 effect 永久毒聋（且只有一行日志）。
            // 先入队则 OOM 时 observer 保持原态，下一次写入可完整重试。
            // observers 经 addEdge 去重，同一 reader 不会重复入队。
            if (obs.kind == .effect) {
                self.pending_effects.append(self.allocator, obs_id) catch |err| {
                    if (first_error == null) first_error = err;
                    continue;
                };
            }
            obs.state = .dirty;
            self.propagation_stack.appendAssumeCapacity(obs_id);
        }

        // A hostile/degenerated graph may contain tens of thousands of nodes.
        // Walk it on the pre-reserved heap stack instead of consuming one
        // native stack frame per edge.
        while (self.propagation_stack.pop()) |current_id| {
            const current = self.getNode(current_id) orelse continue;
            const downstream_len = current.observers.items.len;
            var downstream_index: usize = 0;
            while (downstream_index < downstream_len) : (downstream_index += 1) {
                const obs_id = current.observers.items[downstream_index];
                const obs = self.getNode(obs_id) orelse continue;
                if (obs.state != .clean) continue;
                if (obs.kind == .effect) {
                    self.pending_effects.ensureUnusedCapacity(self.allocator, 1) catch |err| {
                        if (first_error == null) first_error = err;
                        continue;
                    };
                    self.pending_effects.appendAssumeCapacity(obs_id);
                }
                obs.state = .check;
                self.propagation_stack.appendAssumeCapacity(obs_id);
            }
        }
        if (first_error) |err| return err;
    }

    // ------------------------------------------------------------------------
    // 读取路径 + 拉式重算
    // ------------------------------------------------------------------------

    /// 读 memo 前调用：把 memo 拉到 clean 状态，确保返回最新值。
    pub fn updateIfNecessary(self: *ReactiveGraph, id: NodeId) void {
        if (self.update_depth >= max_reactive_recursion_depth) {
            reactive_depth_limit_hits +|= 1;
            return;
        }
        self.update_depth += 1;
        defer self.update_depth -= 1;

        const n = self.getNode(id) orelse return;
        if (n.state == .clean) return;

        if (n.state == .check) {
            // ⚠ `n` 不可跨 updateIfNecessary 递归存活：递归会走到用户 compute
            // 回调，回调里创建任何 reactive 节点都会让 createNode 的
            // `nodes.append` realloc，使一切缓存的 *GraphNode 悬垂
            // （recomputeNode 的 defer 同理，故它也在回调后重新 getNode）。
            // 因此这里每轮都按 index 重新取节点，且不持有 sources 切片。
            var i: usize = 0;
            while (true) {
                const cur = self.getNode(id) orelse return;
                if (i >= cur.sources.items.len) break;
                const sources_len_before = cur.sources.items.len;
                const src_id = cur.sources.items[i];

                self.updateIfNecessary(src_id);

                const after = self.getNode(id) orelse return;
                // Nested user recompute may destroy a sibling source. destroyNode
                // swap-removes that edge, potentially moving an unchecked source
                // into an index lower than `i`. Restart the small source scan on
                // any structural change so no swapped-in dependency is skipped.
                if (after.sources.items.len != sources_len_before or
                    i >= after.sources.items.len or
                    !NodeId.eq(after.sources.items[i], src_id))
                {
                    i = 0;
                    continue;
                }
                const s = self.getNode(src_id) orelse {
                    i += 1;
                    continue;
                };
                const seen = if (i < after.seen_versions.items.len) after.seen_versions.items[i] else 0;
                if (s.version != seen) {
                    after.state = .dirty;
                    break;
                }
                i += 1;
            }
            const cur = self.getNode(id) orelse return;
            if (cur.state == .check) {
                cur.state = .clean;
                return;
            }
        }

        const cur = self.getNode(id) orelse return;
        if (cur.state == .dirty) {
            self.recomputeNode(id);
        }
    }

    fn recomputeNode(self: *ReactiveGraph, id: NodeId) void {
        const n = self.getNode(id) orelse return;
        if (n.is_running) return; // 重入保护
        if (self.tracking_stack.items.len >= max_reactive_recursion_depth) {
            reactive_depth_limit_hits +|= 1;
            return;
        }
        const recompute = n.recompute orelse return;
        const ctx = n.recompute_ctx orelse return;

        n.is_running = true;
        defer if (self.getNode(id)) |nn| {
            nn.is_running = false;
        };

        // epoch 化依赖追踪，不再 clearSources（O(observers)）；
        // 而是 bump current_run，addEdge 标 source_runs 槽，结束后 prune 未命中的 source。
        // 静态依赖路径（1k fanout）：trackRead 命中 dedup 直接 return，零 alloc 零 remove。
        n.tracking_failed = false;
        n.current_run +%= 1;
        const this_run = n.current_run;

        // pushTracking 失败（OOM / 追踪栈满）意味着**这次 recompute 整个不跑**,
        // 节点保持陈旧值且没有任何信号，是最难排查的一类静默失败
        // （审查报告 §3）。这里至少留下日志与计数。
        self.pushTracking(id) catch |err| {
            reactive_tracking_failures += 1;
            if (!suppress_reactive_error_log) {
                std.log.scoped(.zenit_reactive).err(
                    "pushTracking failed ({s}) for node {d}: recompute skipped, value stays stale",
                    .{ @errorName(err), id.index },
                );
            }
            return;
        };
        defer self.popTracking();

        const value_changed = recompute(ctx);

        const after = self.getNode(id) orelse return;
        if (after.tracking_failed) {
            after.state = .dirty;
            return;
        }

        // Prune stale sources（current_run 落后的）；倒序 swapRemove 避免索引乱
        var i: usize = after.sources.items.len;
        while (i > 0) {
            i -= 1;
            const seen = if (i < after.source_runs.items.len) after.source_runs.items[i] else 0;
            if (seen != this_run) {
                const stale_src = after.sources.items[i];
                if (self.getNode(stale_src)) |s| removeFromList(&s.observers, id);
                _ = after.sources.swapRemove(i);
                if (i < after.seen_versions.items.len) _ = after.seen_versions.swapRemove(i);
                if (i < after.source_runs.items.len) _ = after.source_runs.swapRemove(i);
            }
        }

        // 同步 seen_versions 到 sources 当前 version
        after.seen_versions.clearRetainingCapacity();
        for (after.sources.items) |src_id| {
            const s = self.getNode(src_id) orelse continue;
            // 不可降级：seen_versions 必须与 sources 逐项对齐，短一项会让
            // 后续 version 比较错位/漏比 -> 该重算的 memo 静默不重算。
            after.seen_versions.append(self.allocator, s.version) catch @panic("OOM: ReactiveGraph seen_versions resync");
        }

        if (after.kind == .memo and value_changed) {
            after.version +%= 1;
        }
        after.state = .clean;
    }

    fn runEffect(self: *ReactiveGraph, id: NodeId) void {
        self.recomputeNode(id);
    }

    // ------------------------------------------------------------------------
    // Batch / flush
    // ------------------------------------------------------------------------

    pub fn beginBatch(self: *ReactiveGraph) void {
        self.batch_depth += 1;
    }

    pub fn endBatch(self: *ReactiveGraph) !void {
        std.debug.assert(self.batch_depth > 0);
        self.batch_depth -= 1;
        if (self.batch_depth == 0) {
            try self.drainPendingEffects();
        }
    }

    /// 按拓扑深度排序后 drain，保证浅依赖先于深依赖更新。
    /// 同一 effect 在一轮内最多跑一次（state 检查负责去重，effect run 后
    /// state 变 clean，下次循环遇到同 id 直接 skip）。
    fn drainPendingEffects(self: *ReactiveGraph) !void {
        if (self.flushing) return;
        self.flushing = true;
        defer self.flushing = false;

        // 防止迭代上限：动态依赖可能在 effect 跑完后引入新 dirty effect。
        // 这是合法的；我们按层运行，直到队列稳定。
        var rounds: u32 = 0;
        const MAX_ROUNDS: u32 = 1024;

        // 双 buffer swap 取代 alloc + memcpy + clear。
        // pending_effects 与 drain_buffer 互换；drain 完后下轮 pending_effects 清空。
        // 节省 1k fanout 下每轮 ~8KB alloc + free + memcpy。
        while (self.pending_effects.items.len > 0) : (rounds += 1) {
            if (rounds >= MAX_ROUNDS) return error.ReactivePropagationDidNotConverge;

            // 排序：仅当 > 1 个 effect 时排序；同 depth 数据 zig std sort 已优化为 O(N)
            // (introsort with insertion sort for small/sorted)，不预检查省去 N 次 getNode 开销
            if (self.pending_effects.items.len > 1) {
                std.mem.sort(NodeId, self.pending_effects.items, self, sortByDepth);
            }

            // 把 pending_effects 切到 drain_buffer，pending_effects 重置为空
            // 这样 drain 期间新加入的 effect 进入新的 pending_effects（下一轮处理）
            std.mem.swap(std.ArrayListUnmanaged(NodeId), &self.pending_effects, &self.drain_buffer);

            // drain：state == .clean 的 effect skip（updateIfNecessary 内部检查）
            for (self.drain_buffer.items) |id| {
                const n = self.getNode(id) orelse continue;
                if (n.state == .clean) continue;
                if (n.kind != .effect) continue;
                self.updateIfNecessary(id);
            }
            self.drain_buffer.clearRetainingCapacity();
        }
    }

    fn sortByDepth(self: *ReactiveGraph, a: NodeId, b: NodeId) bool {
        const an = if (a.index < self.nodes.items.len) self.nodes.items[a.index].depth else 0;
        const bn = if (b.index < self.nodes.items.len) self.nodes.items[b.index].depth else 0;
        return an < bn;
    }

    // ------------------------------------------------------------------------
    // Devtools
    // ------------------------------------------------------------------------

    pub fn dumpGraph(self: *ReactiveGraph, w: anytype) !void {
        try w.print("== ReactiveGraph: {d} nodes, batch_depth={d} ==\n", .{ self.nodes.items.len, self.batch_depth });
        for (self.nodes.items, 0..) |n, i| {
            if (!n.alive) continue;
            try w.print("  [{d:>4}] kind={s:<6} state={s:<5} ver={d:<4} depth={d:<3} sources={d} observers={d}\n", .{
                i,
                @tagName(n.kind),
                @tagName(n.state),
                n.version,
                n.depth,
                n.sources.items.len,
                n.observers.items.len,
            });
        }
    }

    pub fn nodeCount(self: *const ReactiveGraph) usize {
        var c: usize = 0;
        for (self.nodes.items) |n| {
            if (n.alive) c += 1;
        }
        return c;
    }
};

fn indexOf(list: std.ArrayListUnmanaged(NodeId), needle: NodeId) ?usize {
    for (list.items, 0..) |n, i| {
        if (n.eq(needle)) return i;
    }
    return null;
}

fn removeFromList(list: *std.ArrayListUnmanaged(NodeId), target: NodeId) void {
    if (indexOf(list.*, target)) |i| {
        _ = list.swapRemove(i);
    }
}

// ============================================================================
// Tests
// ============================================================================

test "ReactiveGraph: basic signal create + write" {
    var g = ReactiveGraph.init(testing.allocator);
    defer g.deinit();

    const s = try g.createSignal();
    const node = g.getNode(s).?;
    try testing.expectEqual(NodeKind.signal, node.kind);
    try testing.expectEqual(NodeState.clean, node.state);

    try g.markSignalWritten(s);
    const n2 = g.getNode(s).?;
    try testing.expectEqual(@as(u64, 2), n2.version);
}

test "NodeId is exactly 4 bytes" {
    try testing.expectEqual(@as(usize, 4), @sizeOf(NodeId));
}

// ----- Diamond glitch test -----
//
//      A (signal)
//     / \
//    B   C
//   memo memo
//    \ /
//     D (effect)
//
// 写 A 后，D 重算时必须读到 B 和 C 都已根据新 A 值更新过的最新值。
const DiamondCtx = struct {
    g: *ReactiveGraph,
    a_id: NodeId,
    b_id: NodeId = .{ .index = 0, .generation = 0 },
    c_id: NodeId = .{ .index = 0, .generation = 0 },
    a_value: i32 = 0,
    b_value: i32 = 0,
    c_value: i32 = 0,
    d_observed: struct { b: i32, c: i32 } = .{ .b = 0, .c = 0 },
    d_run_count: u32 = 0,
};

fn computeB(ctx: *anyopaque) bool {
    const c: *DiamondCtx = @ptrCast(@alignCast(ctx));
    c.g.trackRead(c.a_id) catch {};
    const new_b = c.a_value * 10;
    const changed = c.b_value != new_b;
    c.b_value = new_b;
    return changed;
}

fn computeC(ctx: *anyopaque) bool {
    const c: *DiamondCtx = @ptrCast(@alignCast(ctx));
    c.g.trackRead(c.a_id) catch {};
    const new_c = c.a_value + 100;
    const changed = c.c_value != new_c;
    c.c_value = new_c;
    return changed;
}

fn observeD(ctx: *anyopaque) bool {
    const c: *DiamondCtx = @ptrCast(@alignCast(ctx));
    // 模拟 Memo facade 的 get：先 updateIfNecessary 再 trackRead 再读 cache
    c.g.updateIfNecessary(c.b_id);
    c.g.updateIfNecessary(c.c_id);
    c.g.trackRead(c.b_id) catch {};
    c.g.trackRead(c.c_id) catch {};
    c.d_observed = .{ .b = c.b_value, .c = c.c_value };
    c.d_run_count += 1;
    return false;
}

test "Diamond glitch freedom: D sees consistent B/C after A change" {
    var g = ReactiveGraph.init(testing.allocator);
    defer g.deinit();

    var ctx = DiamondCtx{
        .g = &g,
        .a_id = try g.createSignal(),
    };
    ctx.b_id = try g.createMemo(&computeB, &ctx);
    ctx.c_id = try g.createMemo(&computeC, &ctx);

    // 初次：让 D 跑一次，建立依赖
    _ = try g.createEffect(&observeD, &ctx);
    try testing.expectEqual(@as(u32, 1), ctx.d_run_count);
    try testing.expectEqual(@as(i32, 0), ctx.d_observed.b);
    try testing.expectEqual(@as(i32, 100), ctx.d_observed.c);

    // 写 A：D 应只跑一次（不是两次），且看到 b=50, c=105
    ctx.a_value = 5;
    try g.markSignalWritten(ctx.a_id);

    try testing.expectEqual(@as(u32, 2), ctx.d_run_count);
    try testing.expectEqual(@as(i32, 50), ctx.d_observed.b);
    try testing.expectEqual(@as(i32, 105), ctx.d_observed.c);
}

test "ReactiveGraph: memo lazy — not computed until read" {
    var g = ReactiveGraph.init(testing.allocator);
    defer g.deinit();

    const a_id = try g.createSignal();
    const Ctx = struct {
        g: *ReactiveGraph,
        a_id: NodeId,
        compute_count: u32 = 0,
    };
    var ctx = Ctx{ .g = &g, .a_id = a_id };

    const computeM = struct {
        fn cb(opaque_ctx: *anyopaque) bool {
            const c: *Ctx = @ptrCast(@alignCast(opaque_ctx));
            c.g.trackRead(c.a_id) catch {};
            c.compute_count += 1;
            return false;
        }
    }.cb;

    const m_id = try g.createMemo(&computeM, &ctx);
    // memo 创建后不应立即计算
    try testing.expectEqual(@as(u32, 0), ctx.compute_count);

    // 第一次 updateIfNecessary 触发计算
    g.updateIfNecessary(m_id);
    try testing.expectEqual(@as(u32, 1), ctx.compute_count);

    // 再次 update 不重算（state=clean）
    g.updateIfNecessary(m_id);
    try testing.expectEqual(@as(u32, 1), ctx.compute_count);

    // 写 a 后 update 重算
    try g.markSignalWritten(a_id);
    g.updateIfNecessary(m_id);
    try testing.expectEqual(@as(u32, 2), ctx.compute_count);
}

test "ReactiveGraph: batch coalesces multiple writes" {
    var g = ReactiveGraph.init(testing.allocator);
    defer g.deinit();

    const Ctx = struct {
        g: *ReactiveGraph,
        a_id: NodeId,
        b_id: NodeId,
        run_count: u32 = 0,
    };
    var ctx: Ctx = undefined;
    ctx.g = &g;
    ctx.a_id = try g.createSignal();
    ctx.b_id = try g.createSignal();
    ctx.run_count = 0;

    const eff = struct {
        fn cb(opaque_ctx: *anyopaque) bool {
            const c: *Ctx = @ptrCast(@alignCast(opaque_ctx));
            c.g.trackRead(c.a_id) catch {};
            c.g.trackRead(c.b_id) catch {};
            c.run_count += 1;
            return false;
        }
    }.cb;

    _ = try g.createEffect(&eff, &ctx);
    try testing.expectEqual(@as(u32, 1), ctx.run_count);

    // 不 batch：两次 set -> 两次 effect
    try g.markSignalWritten(ctx.a_id);
    try g.markSignalWritten(ctx.b_id);
    try testing.expectEqual(@as(u32, 3), ctx.run_count);

    // batch：两次 set -> 一次 effect
    g.beginBatch();
    try g.markSignalWritten(ctx.a_id);
    try g.markSignalWritten(ctx.b_id);
    try g.endBatch();
    try testing.expectEqual(@as(u32, 4), ctx.run_count);
}

test "ReactiveGraph: destroy removes from graph" {
    var g = ReactiveGraph.init(testing.allocator);
    defer g.deinit();

    const a = try g.createSignal();
    try testing.expect(g.isAlive(a));
    g.destroyNode(a);
    try testing.expect(!g.isAlive(a));
}

test "ReactiveGraph: dumpGraph produces output" {
    var g = ReactiveGraph.init(testing.allocator);
    defer g.deinit();

    _ = try g.createSignal();
    _ = try g.createSignal();

    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try g.dumpGraph(stream.writer());
    const out = stream.getWritten();
    try testing.expect(std.mem.indexOf(u8, out, "ReactiveGraph") != null);
    try testing.expect(std.mem.indexOf(u8, out, "signal") != null);
}

// ----- compile-time hygiene -----
test "eqlValue is reachable from graph context" {
    try testing.expect(eqlValue(i32, 42, 42));
}

// ----- propagate OOM 自愈性 -----
//
// std.testing.FailingAllocator 一旦命中 fail_index 就**永久**失败（alloc_index
// 只在成功时递增），模拟不了"一次瞬时 OOM 后系统恢复"。这里用一次性失败
// allocator：armed 时失败恰好一次，随后恢复正常。
const OneShotFailingAllocator = struct {
    backing: std.mem.Allocator,
    armed: bool = false,

    fn allocator(self: *OneShotFailingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = std.mem.Allocator.VTable{
        .alloc = allocImpl,
        .resize = resizeImpl,
        .remap = remapImpl,
        .free = freeImpl,
    };

    fn allocImpl(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *OneShotFailingAllocator = @ptrCast(@alignCast(ctx));
        if (self.armed) {
            self.armed = false;
            return null;
        }
        return self.backing.rawAlloc(len, alignment, ret_addr);
    }
    fn resizeImpl(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *OneShotFailingAllocator = @ptrCast(@alignCast(ctx));
        return self.backing.rawResize(memory, alignment, new_len, ret_addr);
    }
    fn remapImpl(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *OneShotFailingAllocator = @ptrCast(@alignCast(ctx));
        if (self.armed) {
            self.armed = false;
            return null;
        }
        return self.backing.rawRemap(memory, alignment, new_len, ret_addr);
    }
    fn freeImpl(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *OneShotFailingAllocator = @ptrCast(@alignCast(ctx));
        self.backing.rawFree(memory, alignment, ret_addr);
    }
};

test "propagate: 一次瞬时 OOM 不得把 effect 永久毒聋" {
    // 回归（先入队后置位）：旧序是先 obs.state = .dirty 再 try append,
    // append OOM 后 effect 停在 dirty-but-not-pending，后续每次写入都因
    // `state == .dirty` 被跳过，一次 OOM 永久失聪。
    var one_shot = OneShotFailingAllocator{ .backing = testing.allocator };
    var g = ReactiveGraph.init(one_shot.allocator());
    defer g.deinit();

    const s = try g.createSignal();

    const Ctx = struct { g: *ReactiveGraph, s: NodeId, runs: usize = 0 };
    var ctx = Ctx{ .g = &g, .s = s };
    const cb = struct {
        fn run(opaque_ctx: *anyopaque) bool {
            const c: *Ctx = @ptrCast(@alignCast(opaque_ctx));
            c.runs += 1;
            c.g.trackRead(c.s) catch {};
            return true;
        }
    }.run;

    _ = try g.createEffect(&cb, &ctx);
    try testing.expectEqual(@as(usize, 1), ctx.runs);

    // 在 propagate 的 pending_effects.append 处诱发一次 OOM（本次写入允许失败）
    try g.propagation_stack.ensureTotalCapacity(g.allocator, g.nodes.items.len);
    suppress_reactive_error_log = true;
    defer suppress_reactive_error_log = false;
    one_shot.armed = true;
    _ = g.markSignalWritten(s) catch {};
    one_shot.armed = false;

    // 恢复后的写入必须仍能唤醒 effect
    const runs_before = ctx.runs;
    try g.markSignalWritten(s);
    try testing.expect(ctx.runs > runs_before);
}

test "propagate: one observer OOM does not skip successfully queued tail observers" {
    var one_shot = OneShotFailingAllocator{ .backing = testing.allocator };
    var g = ReactiveGraph.init(one_shot.allocator());
    defer g.deinit();

    const source = try g.createSignal();
    const Ctx = struct {
        graph: *ReactiveGraph,
        source: NodeId,
        runs: usize = 0,
    };
    const callback = struct {
        fn run(raw: *anyopaque) bool {
            const ctx: *Ctx = @ptrCast(@alignCast(raw));
            ctx.runs += 1;
            ctx.graph.trackRead(ctx.source) catch @panic("test trackRead failed");
            return false;
        }
    }.run;

    var first = Ctx{ .graph = &g, .source = source };
    var tail = Ctx{ .graph = &g, .source = source };
    _ = try g.createEffect(&callback, &first);
    _ = try g.createEffect(&callback, &tail);

    // Keep the injected failure focused on the first pending-effect append;
    // propagation's reusable worklist reserves transactionally up front.
    try g.propagation_stack.ensureTotalCapacity(g.allocator, g.nodes.items.len);
    suppress_reactive_error_log = true;
    defer suppress_reactive_error_log = false;
    one_shot.armed = true;
    try testing.expectError(error.OutOfMemory, g.markSignalWritten(source));

    // The first append consumed the injected OOM. Propagation continues, the
    // tail observer queues successfully, and markSignalWritten drains it before
    // reporting the partial failure.
    try testing.expectEqual(@as(usize, 1), first.runs);
    try testing.expectEqual(@as(usize, 2), tail.runs);
}

test "updateIfNecessary rescans when nested recompute removes an earlier sibling source" {
    var g = ReactiveGraph.init(testing.allocator);
    defer g.deinit();

    const victim = try g.createSignal();
    const trigger = try g.createSignal();
    const tail = try g.createSignal();

    const KillerCtx = struct {
        graph: *ReactiveGraph,
        trigger: NodeId,
        victim: NodeId,
        destroy_victim: bool = false,
    };
    var killer_ctx = KillerCtx{ .graph = &g, .trigger = trigger, .victim = victim };
    const killer_cb = struct {
        fn run(raw: *anyopaque) bool {
            const ctx: *KillerCtx = @ptrCast(@alignCast(raw));
            ctx.graph.trackRead(ctx.trigger) catch @panic("test trackRead failed");
            if (ctx.destroy_victim) {
                ctx.destroy_victim = false;
                ctx.graph.destroyNode(ctx.victim);
            }
            // Keep the memo version stable: the reader must still inspect tail.
            return false;
        }
    }.run;
    const killer = try g.createMemo(killer_cb, &killer_ctx);
    g.updateIfNecessary(killer);

    const ReaderCtx = struct {
        graph: *ReactiveGraph,
        victim: NodeId,
        killer: NodeId,
        tail: NodeId,
        runs: usize = 0,
    };
    var reader_ctx = ReaderCtx{ .graph = &g, .victim = victim, .killer = killer, .tail = tail };
    const reader_cb = struct {
        fn run(raw: *anyopaque) bool {
            const ctx: *ReaderCtx = @ptrCast(@alignCast(raw));
            ctx.runs += 1;
            ctx.graph.trackRead(ctx.victim) catch {};
            ctx.graph.updateIfNecessary(ctx.killer);
            ctx.graph.trackRead(ctx.killer) catch @panic("test trackRead failed");
            ctx.graph.trackRead(ctx.tail) catch @panic("test trackRead failed");
            return true;
        }
    }.run;
    const reader = try g.createMemo(reader_cb, &reader_ctx);
    g.updateIfNecessary(reader);
    try testing.expectEqual(@as(usize, 1), reader_ctx.runs);

    // Tail changed, but only killer propagation marks reader .check. While the
    // reader checks killer, killer destroys victim (source index 0), which
    // swap-removes tail into that already-visited index.
    g.getNode(tail).?.version +%= 1;
    killer_ctx.destroy_victim = true;
    try g.markSignalWritten(trigger);
    g.updateIfNecessary(reader);

    try testing.expectEqual(@as(usize, 2), reader_ctx.runs);
}

test "propagation uses heap worklist for very deep observer chains" {
    var g = ReactiveGraph.init(testing.allocator);
    defer g.deinit();

    const chain_len = 4096;
    const ids = try testing.allocator.alloc(NodeId, chain_len);
    defer testing.allocator.free(ids);
    for (ids) |*id| id.* = try g.createSignal();
    for (1..ids.len) |i| try g.addEdge(ids[i], ids[i - 1]);

    try g.markSignalWritten(ids[0]);
    try testing.expectEqual(NodeState.dirty, g.getNode(ids[1]).?.state);
    try testing.expectEqual(NodeState.check, g.getNode(ids[ids.len - 1]).?.state);
}

test "propagation worklist OOM leaves every observer retryable" {
    var one_shot = OneShotFailingAllocator{ .backing = testing.allocator };
    var g = ReactiveGraph.init(one_shot.allocator());
    defer g.deinit();

    const source = try g.createSignal();
    const direct = try g.createSignal();
    const tail = try g.createSignal();
    try g.addEdge(direct, source);
    try g.addEdge(tail, direct);

    one_shot.armed = true;
    try testing.expectError(error.OutOfMemory, g.markSignalWritten(source));
    try testing.expectEqual(NodeState.clean, g.getNode(direct).?.state);
    try testing.expectEqual(NodeState.clean, g.getNode(tail).?.state);

    try g.markSignalWritten(source);
    try testing.expectEqual(NodeState.dirty, g.getNode(direct).?.state);
    try testing.expectEqual(NodeState.check, g.getNode(tail).?.state);
}

test "reactive recompute chain stops at explicit recursion budget" {
    var g = ReactiveGraph.init(testing.allocator);
    defer g.deinit();

    const chain_len = max_reactive_recursion_depth + 16;
    const Context = struct {
        graph: *ReactiveGraph,
        next: ?NodeId = null,
        runs: usize = 0,
    };
    const contexts = try testing.allocator.alloc(Context, chain_len);
    defer testing.allocator.free(contexts);
    const ids = try testing.allocator.alloc(NodeId, chain_len);
    defer testing.allocator.free(ids);
    const callback = struct {
        fn run(raw: *anyopaque) bool {
            const ctx: *Context = @ptrCast(@alignCast(raw));
            ctx.runs += 1;
            if (ctx.next) |next| {
                ctx.graph.updateIfNecessary(next);
                ctx.graph.trackRead(next) catch @panic("test trackRead failed");
            }
            return true;
        }
    }.run;

    var i = chain_len;
    while (i > 0) {
        i -= 1;
        contexts[i] = .{ .graph = &g, .next = if (i + 1 < chain_len) ids[i + 1] else null };
        ids[i] = try g.createMemo(&callback, &contexts[i]);
    }

    const hits_before = reactive_depth_limit_hits;
    g.updateIfNecessary(ids[0]);
    try testing.expect(reactive_depth_limit_hits > hits_before);
    try testing.expectEqual(@as(usize, 0), g.update_depth);
    try testing.expectEqual(@as(usize, 0), g.tracking_stack.items.len);
    try testing.expect(contexts[0].runs > 0);
    try testing.expectEqual(@as(usize, 0), contexts[chain_len - 1].runs);
}

// ----- OOM 不变式 -----
//
// batch1 把 recomputeNode 末尾的 `seen_versions.append(...) catch {}` 改成了
// @panic。本测试锁的是那条 panic 所**保护的不变式**：seen_versions 必须与
// sources 逐项等长对齐（短一项 -> version 比较错位 -> 该重算的 memo 静默不重算）。
//
// 实测结论（重要，别据此误判覆盖率）：那条 @panic 实际是**防御性不可达**的。
// addEdge 对四张表（sources / seen_versions / source_runs / observers）先
// ensureUnusedCapacity 全部预留、再 appendAssumeCapacity 不可失败地写入,
// 半建边在结构上不可能；而 resync 循环前只调 clearRetainingCapacity
// （保留容量），重同步时 append 永远不需要新分配。
//
// 历史沿革：此前 addEdge 是四个顺序 try append。当时实测中间的
// source_runs.append 换成 `catch {}` 后数组会在函数内瞬时错位（@panic 探针
// 命中 6 次），只是紧接着 observers.append 同样 OOM 让整个 addEdge 报错、
// 调用方丢弃这次重算，错位状态才没有对外可见。也就是说旧实现的对齐依赖
// "后续 append 恰好也失败"这个巧合；FailingAllocator 直连 trackRead 循环
// 可以打出 sources 与 seen_versions 长度错位。现改为预留后提交，对齐
// 不再依赖巧合。
//
// 本测试断言的是 OOM 下真正可观测的性质：依赖边要么完整建立（memo 能被该
// source 唤醒），要么完整缺失且 trackRead 返回 error 让调用方知情,
// 不存在「边半建成 + 调用方以为成功」的中间态。这里刻意记录 trackRead 的
// 失败次数而非 `catch {}` 丢掉，边丢了才能被下面的断言观测到。
test "allocation campaign: ReactiveGraph dependency edge is fully committed or absent" {
    var saw_induced_failure = false;
    var saw_dropped_edge = false;

    // 诱发 OOM 必然打出 pushTracking 失败的 err 日志，那是预期行为而非测试失败。
    suppress_reactive_error_log = true;
    defer suppress_reactive_error_log = false;

    var fail_index: usize = 0;
    while (fail_index < 256) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{
            .fail_index = fail_index,
        });
        var g = ReactiveGraph.init(failing.allocator());
        defer g.deinit();

        var signals: [8]NodeId = undefined;
        var made: usize = 0;
        while (made < signals.len) : (made += 1) {
            signals[made] = g.createSignal() catch break;
        }
        if (made == 0) continue;

        const Ctx = struct {
            g: *ReactiveGraph,
            signals: []const NodeId,
            read_count: usize,
            /// trackRead 失败次数，即「这一轮有边没建上」的信号。
            track_failures: usize = 0,
            /// 本轮 recompute 回调是否真的跑了。
            ran: bool = false,
        };
        // 第一轮只读 1 个 source，之后逐轮增加读取数量，迫使 addEdge 反复分配。
        var ctx = Ctx{ .g = &g, .signals = signals[0..made], .read_count = 1 };

        const computeM = struct {
            fn cb(opaque_ctx: *anyopaque) bool {
                const c: *Ctx = @ptrCast(@alignCast(opaque_ctx));
                c.ran = true;
                for (c.signals[0..c.read_count]) |sid| {
                    // 刻意不吞：边加不上必须可观测，否则测试只能验到空气。
                    c.g.trackRead(sid) catch {
                        c.track_failures += 1;
                    };
                }
                return true;
            }
        }.cb;

        const m_id = g.createMemo(&computeM, &ctx) catch continue;
        g.updateIfNecessary(m_id);

        // 逐轮扩大依赖集合，迫使 addEdge 反复分配。
        while (ctx.read_count < made) {
            ctx.read_count += 1;
            ctx.track_failures = 0;
            ctx.ran = false;
            g.markSignalWritten(signals[0]) catch break;
            g.updateIfNecessary(m_id);
            const m = g.getNode(m_id) orelse break;

            // 三个平行数组必须**始终**等长（结构性不变式）。这条断言不受
            // ctx.ran 影响：即使这轮没重算，残留状态也不允许错位。
            // （实测：把 addEdge 里 source_runs.append 的 try 换成 catch {}，
            //  这两条断言之一必红，见下方 ran 守卫的注意事项。）
            try testing.expectEqual(m.sources.items.len, m.seen_versions.items.len);
            try testing.expectEqual(m.sources.items.len, m.source_runs.items.len);

            // 下面的条数比较才依赖「本轮真的重算过」：markSignalWritten 自身
            // 可能 OOM 导致 memo 没被标脏，此时 sources 还是上一轮的内容。
            // 注意别把这个 continue 提到上面，那会把真正暴露错位的轮次跳过去，
            // 测试就再也验不出东西了（本次开发中踩过）。
            if (!ctx.ran) continue;

            // 核心断言：本轮成功读取的 source 全部建成了边。
            // sources 可能还含上一轮遗留、尚未 prune 的边，故用 >=；
            // 但绝不能少于「本轮成功 trackRead 的条数」，少了就意味着有边
            // 被静默丢弃，而调用方（track_failures）却毫不知情，那正是
            // 「该更新的 memo 静默不更新」的直接成因。
            try testing.expect(m.sources.items.len >= ctx.read_count - ctx.track_failures);
            if (ctx.track_failures > 0) saw_dropped_edge = true;
        }

        if (!failing.has_induced_failure) continue;
        saw_induced_failure = true;
    }

    // 保证这个测试确实诱发过分配失败，而不是一路 continue 空跑成假绿。
    try testing.expect(saw_induced_failure);
    // 且确实观测到过「边被丢掉」的场景（否则上面那条核心断言从未被真正考验）。
    try testing.expect(saw_dropped_edge);
}

test "createNode: 世代回卷前 slot 永久退役（悬垂 NodeId 不复活）" {
    // 验证期实测：旧实现在恰好第 256 次复用时陈旧 id 重新 isAlive（ABA）。
    var g = ReactiveGraph.init(testing.allocator);
    defer g.deinit();

    const first = try g.createSignal();
    g.destroyNode(first);

    var cycles: u32 = 0;
    while (cycles < 300) : (cycles += 1) {
        const id = try g.createSignal();
        if (id.index != first.index) {
            g.destroyNode(id);
            break;
        }
        try testing.expect(!g.isAlive(first));
        g.destroyNode(id);
    }
    try testing.expect(cycles < 300);
    try testing.expect(!g.isAlive(first));
}

//! node_lifecycle — v0.12 §N4 god-object split: 从 node.zig 抽出
//! 生命周期 + geometry/rect 两个子域（geometry ~50 行小，按 plan 并入）。
//!
//! 范式同 §N1-§N3：Node-typed free function + @import("node.zig") 循环
//! import；node.zig 保留 thin delegate（原 pub/private 可见性）。
//!
//! 含本 epic 最高风险点（§L memory 强调的 standalone 陷阱）：
//!   - rect callback 单元（g_rect_query/g_rect_write + registrar）
//!   - standalone fallback rect storage（g_standalone_rects + Get/Set，
//!     key by node ptr，element_id==0xFFFFFFFF 的 cx-less mock 用）
//!   三者必须整体搬（类比 §N1 dirty callback 整体搬），node.zig
//!   re-export 保持公开 API（外部 core.zig 调 setRect*Callback）。
//!
//! 生命周期：create（用 g_node_create_hook，hook 单元随迁）/ destroy
//! （树递归 → destroyForNode 递归调自身）/ release{Path,Stroke,
//! CustomClip,All}Geometry / fireMountIfNeeded / fireCleanupCallbacks
//! / clearNodeScopes（后三者原即 file-scope free fn，非 Node 方法，
//! 直接搬 + node.zig re-export）。

const std = @import("std");
const node_mod = @import("node.zig");
const types = @import("types.zig");
const world_mod = @import("world.zig");

const Node = node_mod.Node;
const Allocator = std.mem.Allocator;
const ComputedRect = types.ComputedRect;
const ElementTag = types.ElementTag;
const Style = types.Style;

// ─────────────────────────────────────────────────────────────────────
// rect callback 单元（自 node.zig 整体搬入）
// 给不带 cx 的 fn 从 World.LayoutTable 读/写 rect。
// ─────────────────────────────────────────────────────────────────────

// ─────────────────────────────────────────────────────────────────────
// 跨 Cx 串台检测（P0-3 阶段 2）
//
// Node↔World 的路由目前仍走进程级全局回调，而 ElementId 不含 World 标识
// （两个 World 都从 index 0 分配），所以拿窗口 A 的节点去查窗口 B 的 World
// 会**假匹配返回错误数据**，不会崩、也没有任何信号。
// Node.world_id 补上了 owner 标识；这里用它在每个 World 访问入口做校验，
// 让串台**立即暴露**而不是静默画错。
//
// 当前 Cx.init 仍拒绝第二个并发 Cx，所以这条断言在正常使用下永不触发；
// 它是为后续拆掉全局回调层准备的安全网 —— 迁移过程中一旦漏改某条路径，
// debug build 会立刻 panic 而不是产出诡异画面。
// ─────────────────────────────────────────────────────────────────────

/// 由 core.zig 注册：判断 node 是否属于当前 active World。
pub const WorldOwnershipCheckFn = *const fn (node: *const Node) bool;
var g_world_ownership_check: ?WorldOwnershipCheckFn = null;

pub fn setWorldOwnershipCheck(check: ?WorldOwnershipCheckFn) void {
    g_world_ownership_check = check;
}

/// 在访问 World 表之前校验 owner。跨 Cx 时 debug/safe build panic，
/// release 静默放行（保持既有行为，不给生产引入新的崩溃面）。
///
/// **只对仍走全局回调的节点生效**（world_ref == null）。带 world_ref 的节点
/// 已经直连自己的 owner World，天然不可能串台 —— 此时"当前 active World
/// 是谁"完全无关紧要，再断言反而会误伤合法的多 Cx 场景
/// （节点 A 属于 cx_a，而 g_active_world 恰好指向后 init 的 cx_b）。
/// 这正是阶段 3 迁移带来的能力：断言的适用面随迁移自动收缩。
inline fn assertOwnedByActiveWorld(node: *const Node, comptime site: []const u8) void {
    if (!std.debug.runtime_safety) return;
    if (node.world_ref != null) return; // 已直连 owner，无串台可能
    const check = g_world_ownership_check orelse return;
    if (!check(node)) {
        std.debug.panic(
            "[zenit] cross-Cx node access at {s}: node.id={d} world_id={d} " ++
                "does not belong to the active World. " ++
                "Node↔World routing still goes through process-wide globals; " ++
                "see docs/internal/P0-3_MULTI_CX_ROOTCAUSE_2026-07-29.md",
            .{ site, node.id, node.world_id },
        );
    }
}

pub const RectQueryFn = *const fn (element_id_raw: u32) ?ComputedRect;
var g_rect_query: ?RectQueryFn = null;

pub fn setRectQueryCallback(query: ?RectQueryFn) void {
    g_rect_query = query;
}

pub const RectWriteFn = *const fn (element_id_raw: u32, r: ComputedRect) void;
var g_rect_write: ?RectWriteFn = null;

pub fn setRectWriteCallback(write: ?RectWriteFn) void {
    g_rect_write = write;
}

// Node.create 时自动注册到 World 的 callback。
pub const NodeCreateHookFn = *const fn (node: *Node) void;
var g_node_create_hook: ?NodeCreateHookFn = null;

pub fn setNodeCreateHook(hook: ?NodeCreateHookFn) void {
    g_node_create_hook = hook;
}

// ─────────────────────────────────────────────────────────────────────
// standalone fallback rect storage（element_id_raw == 0xFFFFFFFF 节点用，
// test mock 直接 Node.create 没 cx 时）。hashmap key by node ptr。
//
// ⚠️ 旧注释写的是"生产路径节点都经 g_node_create_hook 注册到 World，
//    永不 hit（zero-cost）"—— **实测证伪**（2026-07-29）。
//    插桩跑真实 hello_button / storybook：生产节点（element_id 有效、
//    回调已注册）确实会落到这里，因为 onRectQuery 用 `epoch == 0` 表示
//    "已注册但本帧还没 layout" 并返回 null。详见 rectFromWorldOrFallback
//    里的说明与 prelayout_zero_rect_reads 计数器。
// ─────────────────────────────────────────────────────────────────────

var g_standalone_rects: std.AutoHashMap(usize, ComputedRect) = undefined;
var g_standalone_rects_init: bool = false;

fn standaloneRectGet(node_ptr: usize) ComputedRect {
    if (!g_standalone_rects_init) return ComputedRect.init(0, 0, 0, 0);
    return g_standalone_rects.get(node_ptr) orelse ComputedRect.init(0, 0, 0, 0);
}

fn standaloneRectSet(node_ptr: usize, r: ComputedRect) void {
    if (!g_standalone_rects_init) {
        g_standalone_rects = std.AutoHashMap(usize, ComputedRect).init(std.heap.page_allocator);
        g_standalone_rects_init = true;
    }
    // 不可降级：这是 fallback 节点 rect 的唯一权威存储，丢写 →
    // standaloneRectGet 返回 0×0 矩形，布局静默错成零尺寸。
    g_standalone_rects.put(node_ptr, r) catch @panic("OOM: standalone rect store");
}

// ─────────────────────────────────────────────────────────────────────
// geometry / rect 方法
// ─────────────────────────────────────────────────────────────────────

/// 从全局 World 读 rect，失败回退 standalone fallback storage。
pub fn rectFromWorldOrFallback(self: *const Node) ComputedRect {
    assertOwnedByActiveWorld(self, "rectFromWorldOrFallback");
    // P0-3 阶段 3：直接走 owner World，不再经过进程级 g_rect_query。
    // 语义与原 core.zig:onRectQuery 完全一致（含 epoch==0 的"已 seed 但未
    // markLaidOut"判定），只是把 World 的来源从全局变量换成节点自带的 owner。
    if (self.world_ref) |w| {
        if (self.element_id_raw != 0xFFFFFFFF) {
            const eid = world_mod.ElementId.fromRaw(self.element_id_raw);
            // createElement 会自动 seed layout slot（默认全 0），epoch==0 即
            // "尚未 markLaidOut"——rectIfLaidOut 把该判定与 rect 读合并为
            // 单次 MultiArrayList 派生（此路径全帧十万次级，Debug 下双读
            // 曾是采样最大单项之一）。
            if (w.layout.rectIfLaidOut(eid)) |r| {
                return ComputedRect.init(r.x, r.y, r.width, r.height);
            }
        }
    } else if (g_rect_query) |query| {
        legacy_rect_query_hits += 1;
        // 兜底：world_ref 未设置的老路径（理论上只剩 cx-less mock）。
        if (query(self.element_id_raw)) |r| return r;
    }
    // 走到这里有两种**语义完全不同**的情况，此前被混为一谈：
    //
    //  (a) 真 standalone —— element_id == INVALID 的 cx-less mock，
    //      本来就该读 fallback storage。
    //  (b) **注册过但本帧还没 layout** —— onRectQuery 靠 `epoch == 0` 识别
    //      "slot 已 seed 但未 markLaidOut" 并返回 null（语义正确）。
    //      这类节点在 fallback map 里通常没有条目，于是静默拿到
    //      ComputedRect(0,0,0,0) —— 一条**无声返回零矩形**的通路，
    //      症状与 docs/BUGS.md 里"布局对、paint 空"一类吻合。
    //
    // 实测（插桩跑真实 hello_button / storybook）：(b) 确实会在生产路径命中，
    // 每次 mount 约 3 次，集中在首帧 layout 之前的 overlay 定位查询 ——
    // 即 node_lifecycle.zig 旧注释所谓"生产路径永不 hit（zero-cost）"是错的。
    //
    // 命中数量有限且都发生在首帧前，属于**良性瞬态**（随后 layout 完成即
    // 读到真值），所以不改行为、不 panic；但用 debug 计数器把它显式记录下来，
    // 避免"零矩形"再次被当成正常值悄悄传播。
    if (std.debug.runtime_safety and self.element_id_raw != 0xFFFFFFFF and g_rect_query != null) {
        prelayout_zero_rect_reads += 1;
    }
    return standaloneRectGet(@intFromPtr(self));
}

/// 「已注册但尚未 layout」而回退到零矩形的次数（仅 debug build 统计）。
/// 稳态下应停止增长；持续增长意味着某条路径在 layout 之前读 rect，
/// 那正是"布局对、paint 空"类 bug 的温床。
pub var prelayout_zero_rect_reads: u64 = 0;

/// 仍走**旧全局回调**的 rect 查询次数（world_ref 为 null 的节点）。
/// 迁移完成后这里应只剩 cx-less test mock；生产路径应恒为 0。
pub var legacy_rect_query_hits: u64 = 0;

/// 仍走 `Node.create`（依赖 g_node_create_hook + g_active_world 全局对）
/// 的节点创建次数。生产路径应全部改走 `Cx.createNode` / `createIn`，
/// 稳态下这里只剩 cx-less 测试会命中。
pub var legacy_node_create_hits: u64 = 0;

/// 组件层"自己改子节点 rect"的统一写入口。
/// 写入 World.LayoutTable + 维护 standalone fallback storage。
pub fn setLayoutRect(self: *Node, r: ComputedRect) void {
    assertOwnedByActiveWorld(self, "setLayoutRect");
    // P0-3 阶段 3：直接写 owner World（语义同原 core.zig:onRectWrite）。
    if (self.world_ref) |w| {
        if (self.element_id_raw != 0xFFFFFFFF) {
            const eid = world_mod.ElementId.fromRaw(self.element_id_raw);
            if (w.layout.ensureSlot(eid)) |_| {
                w.layout.markLaidOut(
                    eid,
                    .{ .width = r.w, .height = r.h },
                    .{ .x = r.x, .y = r.y, .width = r.w, .height = r.h },
                );
            } else |_| {}
        }
    } else if (g_rect_write) |write| {
        write(self.element_id_raw, r);
    }
    // standalone fallback：仅 element_id == 0xFFFFFFFF 时实际有用，但因为
    // setLayoutRect 不知道 World 是否成功 markLaidOut，无脑写一份保险
    // (生产节点 element_id != 0xFFFFFFFF 时 read path 优先 World，永不 hit)
    if (self.element_id_raw == 0xFFFFFFFF) {
        standaloneRectSet(@intFromPtr(self), r);
    }
}

pub fn setLayoutW(self: *Node, w: f32) void {
    var r = rectFromWorldOrFallback(self);
    r.w = w;
    setLayoutRect(self, r);
}

pub fn setLayoutH(self: *Node, h: f32) void {
    var r = rectFromWorldOrFallback(self);
    r.h = h;
    setLayoutRect(self, r);
}

pub fn setLayoutX(self: *Node, x: f32) void {
    var r = rectFromWorldOrFallback(self);
    r.x = x;
    setLayoutRect(self, r);
}

pub fn setLayoutY(self: *Node, y: f32) void {
    var r = rectFromWorldOrFallback(self);
    r.y = y;
    setLayoutRect(self, r);
}

/// 计算节点的全局绝对坐标（遍历祖先链累积 rect + translate + sticky）
pub fn globalRect(self: *const Node) ComputedRect {
    var x: f32 = 0;
    var y: f32 = 0;
    var cur: ?*const Node = self;
    while (cur) |n| : (cur = n.parent) {
        const nr = rectFromWorldOrFallback(n);
        x += nr.x + n.style.translate_x + n.frame_state.frame_local.runtime.sticky.x;
        y += nr.y + n.style.translate_y + n.frame_state.frame_local.runtime.sticky.y;
    }
    const sr = rectFromWorldOrFallback(self);
    return .{ .x = x, .y = y, .w = sr.w, .h = sr.h };
}

// ─────────────────────────────────────────────────────────────────────
// 生命周期：create / destroy / release*Geometry
// ─────────────────────────────────────────────────────────────────────

pub fn create(allocator: Allocator, id: u32, tag: ElementTag, style: Style) !*Node {
    const node = try allocator.create(Node);
    node.* = .{
        .id = id,
        .tag = tag,
        .style = style,
        .children = .{},
    };
    // 如果当前 active cx 注册了 hook，自动 linkNodeToWorld（让 setLayoutRect
    // 真写 World 表，避免 fallback 字段成为 source-of-truth）。
    //
    // P0-3 说明：这是 19 个全局回调里**最后一个仍被生产路径使用**的。
    // 它有"鸡生蛋"性质 —— 调用时节点还没有 world_ref，无法自举。
    // `createIn()`（见下）是显式传 World 的版本，多窗口场景应走它；
    // 保留本函数是为了不破坏现有 API 与大量 cx-less 测试。
    if (g_node_create_hook) |hook| {
        legacy_node_create_hits += 1;
        hook(node);
    }
    return node;
}

/// Node tag → World tag（与 core.zig:nodeTagToWorldTag 保持一致）。
fn worldTagForElementTag(t: ElementTag) world_mod.ElementTag {
    return switch (t) {
        .box, .scroll, .list, .spacer => .container,
        .text => .text,
        .image => .image,
        .input, .button => .input,
        .custom => .component,
    };
}

/// 显式指定 owner World 的节点创建 —— 不依赖任何进程级全局。
///
/// P0-3 阶段 4 的前提：只要所有生产路径都走这里，`g_node_create_hook`
/// 与 `g_active_world` 就可以退役，多个 Cx 才能真正并存。
/// 语义与 core.zig:onNodeCreate 一致：分配 element slot + 盖 owner 章。
pub fn createIn(
    allocator: Allocator,
    world: *world_mod.World,
    world_id: u16,
    id: u32,
    tag: ElementTag,
    style: Style,
) !*Node {
    const node = try allocator.create(Node);
    node.* = .{
        .id = id,
        .tag = tag,
        .style = style,
        .children = .{},
    };
    // 直接 destroy 绕过了 destroy()/freeNodeNow 的投毒收尾，所以这里手动投毒：
    // 否则这块内存带着 ALIVE 被还给 allocator，复用后哨兵会误判成活节点。
    errdefer {
        node.alive_sentinel = node_mod.DEAD_SENTINEL;
        allocator.destroy(node);
    }

    const eid = try world.createElement(.{
        .tag = worldTagForElementTag(tag),
        .key = id,
    });
    node.element_id_raw = eid.raw();
    node.world_id = world_id;
    node.world_ref = world;
    return node;
}

/// 保留模式: 递归销毁节点及其子树
///
/// 注意: 不负责 dispose scope。Scope 的生命周期由 Scope 树管理
/// （父 Scope.dispose() 递归 dispose 子 Scope）。调用者应在 destroy
/// 之前先 dispose scope，再 clearNodeScopes 清除悬垂指针。
pub fn destroy(self: *Node, allocator: Allocator) void {
    // 与 Cx.freeNodeNow 同型：哨兵检查必须**排在 freeing 之前**。
    // 释放后的内存在 Debug 下被写成 0xaa，`freeing` 会读出 true，
    // 于是 double free 退化成静默 early-return。这是第二条释放路径，
    // 漏了它等于哨兵只挡住一半。
    if (self.alive_sentinel != node_mod.ALIVE_SENTINEL) {
        @panic("Node.destroy: 节点已被释放（double free）或内存已损坏");
    }
    if (self.freeing) return;
    self.freeing = true;
    self.deferred_disposal.cancel();
    self.pending_free_cx = null;
    for (self.children.items) |child| {
        destroy(child, allocator);
    }

    // 先摘再调：同一 hook 不得被 destroy / freeNodeNow / fireCleanupCallbacks
    // 重复触发（见 Cx.freeNodeNow 同处注释）。
    if (self.meta.ownership.hooks.on_cleanup) |h| {
        self.meta.ownership.hooks.on_cleanup = null;
        h.invoke();
        self.frame_state.state_bits.flags.is_mounted = false;
    }

    // scope 由调用者负责 dispose，这里只清零指针
    self.meta.ownership.scope.scope = null;

    self.invalidateRenderCache();
    self.invalidatePromotedRenderCache();
    self.invalidateSubtreePayloadCache();

    // 释放动态分配的 test_id
    if (self.frame_state.state_bits.flags.test_id_owned) {
        if (self.meta.ownership.meta.test_id) |tid| {
            allocator.free(tid);
        }
        self.meta.ownership.meta.test_id = null;
        self.frame_state.state_bits.flags.test_id_owned = false;
    }

    // 释放 StyleExt 扩展（含 Grid 配置指针）
    if (self.style.ext) |ext| {
        if (ext.grid) |gc| {
            allocator.destroy(gc);
        }
        allocator.destroy(ext);
        self.style.ext = null;
    }

    // 释放 Transition 槽
    if (self.frame_state.frame_local.runtime.transitions) |ts| {
        allocator.destroy(ts);
        self.frame_state.frame_local.runtime.transitions = null;
    }

    // 释放 NodeAnimations 槽（与 Cx.freeNodeNow 对齐——此前唯一遗漏项）
    if (self.frame_state.frame_local.runtime.commands) |na| {
        na.deinit();
        allocator.destroy(na);
        self.frame_state.frame_local.runtime.commands = null;
    }

    // 释放 owned 文本内容，防止泄漏
    if (self.getText()) |t| {
        if (t.spans_owned and t.spans.len > 0) {
            allocator.free(t.spans);
        }
        if (t.owned and t.content.len > 0) {
            allocator.free(t.content);
        }
    }

    releasePathGeometry(self, allocator);
    releaseStrokeGeometry(self, allocator);
    releaseCustomClipGeometry(self, allocator);

    // World 的 DevTools 样式来源表按 element raw key 稀疏持有；节点回收时同步
    // 移除，避免长生命周期窗口频繁 mount/unmount 后诊断表只增不减。
    if (self.world_ref) |w| w.clearStyleOrigins(self.element_id_raw);

    self.children.deinit(allocator);
    // 投毒：释放后若再被当成活节点使用，哨兵检查会当场 panic 而不是
    // 靠 0xaa 让 `freeing` 读出 true 从而静默 early-return。
    self.alive_sentinel = node_mod.DEAD_SENTINEL;
    allocator.destroy(self);
}

pub fn releasePathGeometry(self: *Node, allocator: Allocator) void {
    const lo = self.layoutOutputPtr() orelse return;
    if (lo.vector.fill.path) |geometry| {
        if (geometry.owned and geometry.commands.len > 0) {
            allocator.free(geometry.commands);
        }
        lo.vector.fill.path = null;
    }
}

pub fn releaseStrokeGeometry(self: *Node, allocator: Allocator) void {
    const lo = self.layoutOutputPtr() orelse return;
    if (lo.vector.stroke.geometry) |geometry| {
        if (geometry.owned and geometry.commands.len > 0) {
            allocator.free(geometry.commands);
        }
        lo.vector.stroke.geometry = null;
    }
}

pub fn releaseCustomClipGeometry(self: *Node, allocator: Allocator) void {
    if (self.layoutOutputPtr()) |lo| {
        if (lo.vector.fill.custom_clip) |geometry| {
            if (geometry.owned and geometry.commands.len > 0) {
                allocator.free(geometry.commands);
            }
            lo.vector.fill.custom_clip = null;
        }
    }
    self.meta.per_frame.custom_hooks.clip_meta.cache_rect = ComputedRect.init(-1, -1, -1, -1);
    self.meta.per_frame.custom_hooks.clip_meta.cache_epoch = 0;
}

/// freeNode 用——把节点持有的 path 堆内存（path /
/// stroke / custom_clip）经 World.layout_output slot 释放。必须在
/// elements.destroy 之前调（element_id 还有效，layoutOutputPtr 能拿到
/// slot；之后 slot 复用会脏）。语义同 §a freeNode 先 free owned text。
pub fn releaseAllGeometry(self: *Node, allocator: Allocator) void {
    releasePathGeometry(self, allocator);
    releaseStrokeGeometry(self, allocator);
    releaseCustomClipGeometry(self, allocator);
}

// ─────────────────────────────────────────────────────────────────────
// mount/cleanup/scope（原即 file-scope free fn，非 Node 方法）
// ─────────────────────────────────────────────────────────────────────

/// 触发当前节点的 onMount（首次布局后一次）
pub fn fireMountIfNeeded(node: *Node) void {
    if (!node.frame_state.state_bits.flags.is_mounted) {
        node.frame_state.state_bits.flags.is_mounted = true;
        if (node.meta.ownership.hooks.on_mount) |mount_handler| {
            mount_handler.invoke();
        }
    }
}

/// 递归触发已挂载节点的 onCleanup 回调 (从叶到根)
///
/// **先摘再调**：on_cleanup 有三个触发点（这里、Node.destroy、Cx.freeNodeNow），
/// 都必须遵守"取出即置空 ⇒ 只此一次"。此处曾只置 is_mounted 不清字段，
/// 于是 removeChild/detachChild → freeNode 的正常 teardown 链对已 mount
/// 节点会二次 invoke（回调普遍是"释放一次性资源"语义，ScrollArea cell
/// 曾因此 refcount 下溢）。未 mount 的节点跳过且**保留字段**，留给
/// destroy/freeNodeNow 触发一次。
pub fn fireCleanupCallbacks(node: *Node) void {
    for (node.children.items) |child| {
        fireCleanupCallbacks(child);
    }
    if (node.frame_state.state_bits.flags.is_mounted) {
        if (node.meta.ownership.hooks.on_cleanup) |cleanup_handler| {
            node.meta.ownership.hooks.on_cleanup = null;
            cleanup_handler.invoke();
        }
        node.frame_state.state_bits.flags.is_mounted = false;
    }
}

/// 递归清除节点子树上的 scope 指针。
/// 用于先释放 root_scope 再释放节点内存的场景，避免访问已释放的 Scope。
pub fn clearNodeScopes(node: *Node) void {
    if (node.meta.ownership.scope.node_slot) |slot| {
        slot.* = null;
        node.meta.ownership.scope.node_slot = null;
    }
    node.meta.ownership.scope.scope = null;
    // 将 hook/组件状态指针标记为无效，避免 scope 先释放后留下悬垂引用。
    node.meta.per_frame.hooks.slots.animated_bg_state = null;
    node.meta.per_frame.hooks.slots.hover_highlight_state = null;
    node.meta.per_frame.hooks.slots.anim_state = null;
    node.meta.per_frame.hooks.slots.focus_ring_anim = null;
    for (node.children.items) |child| {
        clearNodeScopes(child);
    }
}

/// 释放 standalone rect fallback storage（见 paint_content_accessor.zig
/// 同名函数的说明：这几张表是进程级 + page_allocator，GPA leak check 盲视）。
/// 幂等。
pub fn deinitStandaloneRects() void {
    if (!g_standalone_rects_init) return;
    g_standalone_rects.deinit();
    g_standalone_rects_init = false;
}

/// 当前 standalone rect 表条目数（诊断/验收用）。
pub fn standaloneRectCount() usize {
    if (!g_standalone_rects_init) return 0;
    return g_standalone_rects.count();
}

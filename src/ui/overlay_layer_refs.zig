//! overlay 层对 trigger / anchor 目标的「弱引用 + 代次存活校验」，从
//! `overlay_stack.zig` 析出。
//!
//! ## 为什么搬
//!
//! overlay 层持有 `trigger_node: ?*Node`（打开它的按钮）和
//! `anchor.target: ?*Node`（锚定目标）。这两个指针指向**caller 子树里**
//! 的节点，不由 overlay 拥有：caller 的 scope dispose / story 切换 /
//! removePermanently 都可能在 overlay 还活着时把那棵子树整棵释放。
//! 历史上因此踩过悬垂指针：节点释放后 outside-click 判定仍沿
//! `isDescendantOf(stale_ptr)` 走 parent 链，读到已回收内存。
//!
//! 修法是把「裸指针 + 由 node_registry 做代次校验」固化成一对函数：
//!
//!   trackNode(node)         push/setAnchor 时换取代次化 handle
//!   resolveTrackedNode(h, cached_ptr)   每次解引用前校验
//!
//! resolve 的三段语义就是**存活判定的全部不变量**，任何一条砍掉都会复活
//! 悬垂指针：
//!
//!   1. `cached == null`            -> 没缓存指针，无从校验 -> null
//!   2. 无 registry                 -> 没有校验能力。返回 cached 本身：
//!                                     此时无人调用过 trackNode（registry
//!                                     由 setRegistry 注入，push 前必设），
//!                                     指针生命周期由测试 caller 用
//!                                     defer destroy 保证。
//!   3. `h == null`                 -> 从未 track 过（trackNode 在 registry
//!                                     缺失/OOM 时返回 null）-> null。
//!                                     **这条必须判 null 而不是回退 cached**：
//!                                     track 失败意味着没有代次可查，直接
//!                                     信 cached 就是回到悬垂指针。
//!   4. registry.resolve(h) 命中    -> 代次一致，活着 -> 返回
//!   5. resolve 落空但 isCurrentIdentity
//!      (h, cached) 仍真           -> 节点还没进本帧 registry 快照
//!                                     （trackGeneration 已建立身份），
//!                                     是暂态而非悬垂 -> 返回 cached
//!   6. 其余                         -> 节点已释放或同 id 换了对象 -> null
//!
//! ## 接口切在哪 / 不搬什么
//!
//! 切在「单节点的存活判定」。不搬：
//!   - `OverlayLayer` 结构本身（它聚合了动画、z 序、focus 等层的全部状态，
//!     拆走等于把层状态机撕成两半）；
//!   - `handleOutsideClick` 的判定顺序（content -> trigger -> barrier ->
//!     未知区域，这是整栈语义，见 overlay_stack.zig 内注释）；
//!   - `nestedParentZ`（要遍历整栈的 ordered 索引）。
//!
//! 依赖注入而非硬 import：`NodeRegistry` 以参数传入（真实实现是
//! `core/hit_runtime.zig`），本模块不 import core.zig，也就不产生
//! core.zig ↔ overlay_stack.zig 的环。单测用真 registry（它本身就是
//! 可独立构造的纯数据结构），钉住「unregisterSubtree 之后必须判死」。
//! 收集方式：overlay_stack.zig 末尾 `test { _ = @import("overlay_layer_refs.zig"); }`。
//!
//! OverlayStack 侧的薄封装（trackNode / resolveTrigger）留在
//! overlay_stack.zig：它们要把结果写回 layer 字段，属于层状态机。

const std = @import("std");
const node_mod = @import("core/node.zig");
const hit_runtime = @import("core/hit_runtime.zig");

const Node = node_mod.Node;
const NodeHandle = hit_runtime.NodeHandle;
const NodeRegistry = hit_runtime.NodeRegistry;

/// 把裸节点指针换成带代次的 handle。registry 缺失或 trackGeneration 失败
/// （OOM）时返回 null，调用方存 null，之后 resolve 永远判死，绝不回退
/// 到裸指针。这是整条链上唯一允许「降级为不可用」的点，且降级方向是
/// 安全侧（不解析），不是危险侧（信旧指针）。
pub fn trackNode(registry: ?*NodeRegistry, node: ?*Node) ?NodeHandle {
    const n = node orelse return null;
    const registry_ = registry orelse return null;
    const generation = registry_.trackGeneration(n) catch return null;
    return .{ .id = n.id, .generation = generation };
}

/// 见模块头「三段语义」清单。cached 为 null 直接判死，不做任何 registry
/// 查询，没有 cached 就没有可回退的对象。
pub fn resolveTrackedNode(registry: ?*const NodeRegistry, handle: ?NodeHandle, cached: ?*Node) ?*Node {
    const node = cached orelse return null;
    const registry_ = registry orelse return node;
    const h = handle orelse return null;
    return registry_.resolve(h, null) orelse
        if (registry_.isCurrentIdentity(h, node)) node else null;
}

// ── 测试 ───────────────────────────────────────────────────────────────

test "无 registry 时回退 cached（测试路径），null cached 一律判死" {
    const allocator = std.testing.allocator;
    const node = try Node.create(allocator, 900_001, .button, .{});
    defer node.destroy(allocator);

    try std.testing.expectEqual(@as(?NodeHandle, null), trackNode(null, node));
    try std.testing.expectEqual(@as(?*Node, null), resolveTrackedNode(null, null, null));
    // 无 registry + 有 cached：返回 cached 本身（见三段语义第 2 条）
    try std.testing.expectEqual(@as(?*Node, node), resolveTrackedNode(null, null, node));
}

test "track → resolve 往返命中；handle 为 null 时即使有 cached 也判死" {
    const allocator = std.testing.allocator;
    var registry = NodeRegistry.init(allocator);
    defer registry.deinit();
    const node = try Node.create(allocator, 900_002, .button, .{});
    defer node.destroy(allocator);
    try registry.rebuild(node);

    const h = trackNode(&registry, node).?;
    try std.testing.expectEqual(@as(?*Node, node), resolveTrackedNode(&registry, h, node));
    // 第 3 条不变量：track 失败留下的 null handle 绝不能回退 cached
    try std.testing.expectEqual(@as(?*Node, null), resolveTrackedNode(&registry, null, node));
}

test "unregisterSubtree 之后 resolve 判死 —— 悬垂指针不再沿 parent 链走" {
    const allocator = std.testing.allocator;
    var registry = NodeRegistry.init(allocator);
    defer registry.deinit();

    const trigger = try Node.create(allocator, 900_003, .button, .{ .width = .{ .px = 40 } });
    const child = try Node.create(allocator, 900_004, .button, .{});
    try trigger.appendChild(allocator, child);
    defer trigger.destroy(allocator);

    try registry.rebuild(trigger);
    const h = trackNode(&registry, trigger).?;
    try std.testing.expectEqual(@as(?*Node, trigger), resolveTrackedNode(&registry, h, trigger));

    // 模拟 caller 子树被卸载/释放前的 registry 摘除
    registry.unregisterSubtree(trigger);
    try std.testing.expectEqual(@as(?*Node, null), resolveTrackedNode(&registry, h, trigger));
}

test "同 id 复用新节点（代次前进）后旧 handle 判死" {
    const allocator = std.testing.allocator;
    var registry = NodeRegistry.init(allocator);
    defer registry.deinit();

    // 不销毁 a：直接模拟「id 被复用」的注册表视角（destroy 后重建，在
    // testing.allocator 下新对象地址可能复用旧地址，把用例变成 UB）。
    const a = try Node.create(allocator, 900_005, .button, .{});
    defer a.destroy(allocator);
    const b = try Node.create(allocator, 900_006, .button, .{});
    defer b.destroy(allocator);

    try registry.rebuild(a);
    const stale_handle = trackNode(&registry, a).?;
    registry.unregisterSubtree(a);

    // 同 id 换对象：b 复用 a 的 id（entries/generations 都按 id 键）。
    b.id = a.id;
    try registry.rebuild(b);

    // 旧 handle + 旧 cached 都不该再解析出任何东西（代次已前进）
    try std.testing.expectEqual(@as(?*Node, null), resolveTrackedNode(&registry, stale_handle, a));
    // 新对象用它自己的 handle 正常解析
    const fresh = trackNode(&registry, b).?;
    try std.testing.expectEqual(@as(?*Node, b), resolveTrackedNode(&registry, fresh, b));
}

test "registry.resolve 落空但身份仍最新（暂态）→ 回退 cached" {
    const allocator = std.testing.allocator;
    var registry = NodeRegistry.init(allocator);
    defer registry.deinit();

    const node = try Node.create(allocator, 900_007, .button, .{});
    defer node.destroy(allocator);
    // 只 trackGeneration、不放进 entries：模拟「节点还没进本帧快照」
    const h = trackNode(&registry, node).?;
    try std.testing.expectEqual(@as(?*Node, node), resolveTrackedNode(&registry, h, node));
}

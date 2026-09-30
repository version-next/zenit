/// 保留模式控制流原语
///
/// Show: 条件渲染 — condition 为 true 时挂载内容，false 时卸载并销毁
/// For: 列表渲染 — 根据 data Signal 增量渲染列表（key-based diff）
const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core.zig");
const hooks = @import("hooks.zig");
const Node = core.Node;
const Cx = core.Cx;
const Scope = core.Scope;
const Signal = core.Signal;
const clearNodeScopes = core.clearNodeScopes;

/// 控制流（Show / For / Match）内部错误上报。
///
/// 这些回调由 reactive effect 驱动，签名不能返回 error，历史上一律
/// `catch return` —— 于是 OOM / 构建失败被**完全吞掉**：UI 悄悄少一块，
/// 没有日志、没有计数，排查时无从下手（审查报告 §3）。
///
/// 在不改回调签名的前提下，至少做到：(1) 打日志带上出错位置与原始 error；
/// (2) 计数供测试/诊断断言。真正的 error boundary 需要 effect 层支持
/// error sink，属后续工作。
pub var control_flow_error_count: u64 = 0;

/// 测试期静音开关：Zig test runner 把 `std.log.err` 视为测试失败，
/// 而"错误被上报"恰恰是我们要断言的行为 —— 故给测试留一个静音旁路，
/// 计数照常自增。
pub var control_flow_suppress_error_log: bool = false;

fn reportControlFlowError(site: []const u8, err: anyerror) void {
    control_flow_error_count += 1;
    if (control_flow_suppress_error_log) return;
    std.log.scoped(.zenit_control_flow).err(
        "{s} failed: {s} (UI subtree omitted; see control_flow_error_count)",
        .{ site, @errorName(err) },
    );
}

/// 挂载失败时回收一棵尚未交付的子树，顺序与正常卸载一致：
/// 摘 hook 状态 → dispose scope（cleanup 此刻还能看到活节点）→ 清节点上的
/// scope 指针 → destroyDetached（回收 ElementTable slot、清 Cx 裸引用）。
/// 不能用 node.destroy：它既跳过上述清理，又在 scope dispose 之前就释放了节点。
fn discardUnmountedSubtree(cx: *Cx, child_scope: *Scope, node: *Node) void {
    hooks.invalidateSubtreeHookState(node);
    if (!child_scope.disposed) child_scope.dispose();
    clearNodeScopes(node);
    if (node.parent) |p| cx.detachChild(p, node);
    cx.destroyDetached(node);
}

/// For 的"建一个新条目"公共路径：childScope → render → append 三步，
/// 任一步失败都逐级回滚（原实现是三行各自 `catch return`，
/// 后一步失败会漏掉前一步产出的 scope / node）。
/// 成功时把条目写进 new_entries 并转移所有权。
fn appendForEntry(
    s: anytype,
    new_entries: anytype,
    key: u64,
    item: anytype,
    idx: usize,
    comptime renderItem: anytype,
) !void {
    const child_scope = s.parent_scope.childScope() catch |err| {
        reportControlFlowError("For.create/childScope", err);
        return err;
    };
    const node = renderItem(child_scope, s.cx_ptr, item, idx) catch |err| {
        reportControlFlowError("For.create/render", err);
        child_scope.dispose();
        return err;
    };

    new_entries.append(s.alloc, .{
        .key = key,
        .item = item,
        .scope = child_scope,
        .node = node,
    }) catch |err| {
        reportControlFlowError("For.create/append", err);
        discardUnmountedSubtree(s.cx_ptr, child_scope, node);
        return err;
    };
}

/// 只重排 For 管理的那一段子节点，parent 里的其它兄弟（标题、Show 节点等）
/// 原位保留。原实现把 parent.children 整体替换成 For 条目列表，
/// replaceChildOrder 会把不在列表里的兄弟全部摘下 —— 它们成了无人释放的孤儿。
///
/// 段位置用"段前的非 For 兄弟个数"表示：有 For 节点仍挂着时以其实际位置为准
/// （兄弟可能被其它控制流增删），列表曾为空时沿用上次记录值。
fn reorderForSegment(s: anytype) !void {
    const parent = s.parent_node;
    var owned: std.AutoHashMapUnmanaged(*Node, void) = .{};
    defer owned.deinit(s.alloc);
    try owned.ensureTotalCapacity(s.alloc, @intCast(s.entries.items.len));
    for (s.entries.items) |entry| owned.putAssumeCapacity(entry.node, {});

    var others: usize = 0;
    var lead: ?usize = null;
    for (parent.children.items) |child| {
        if (owned.contains(child)) {
            if (lead == null) lead = others;
        } else others += 1;
    }
    const segment_lead = lead orelse @min(s.segment_lead, others);
    s.segment_lead = segment_lead;

    var order: std.ArrayList(*Node) = .{};
    defer order.deinit(s.alloc);
    try order.ensureTotalCapacity(s.alloc, others + s.entries.items.len);
    var seen: usize = 0;
    var inserted = false;
    for (parent.children.items) |child| {
        if (owned.contains(child)) continue;
        if (!inserted and seen == segment_lead) {
            for (s.entries.items) |entry| order.appendAssumeCapacity(entry.node);
            inserted = true;
        }
        order.appendAssumeCapacity(child);
        seen += 1;
    }
    if (!inserted) {
        for (s.entries.items) |entry| order.appendAssumeCapacity(entry.node);
    }
    try parent.replaceChildOrder(s.alloc, order.items);
}

/// Show — 条件渲染
///
/// 当 condition Signal 为 true 时，调用 buildFn 创建子树并挂载到 parent；
/// 为 false 时，销毁子 Scope + 从 parent 移除子节点。
///
/// 用法:
/// ```zig
/// try Show(scope, parent, is_visible, cx, struct {
///     fn build(child_scope: *Scope, c: *Cx) anyerror!*Node {
///         return try Button(.{}).label("Hello").mount(child_scope, c);
///     }
/// }.build);
/// ```
pub fn Show(
    scope: *Scope,
    parent: *Node,
    condition: *Signal(bool),
    cx: *Cx,
    comptime buildFn: fn (*Scope, *Cx) anyerror!*Node,
) !void {
    const State = struct {
        child_scope: ?*Scope = null,
        child_node: ?*Node = null,
        parent_scope: *Scope,
        parent_node: *Node,
        cx_ptr: *Cx,
    };

    const state = try scope.allocator.create(State);
    state.* = .{
        .parent_scope = scope,
        .parent_node = parent,
        .cx_ptr = cx,
    };
    try scope.adoptResource(@ptrCast(state), struct {
        fn destroy(ptr: *anyopaque, allocator: Allocator) void {
            const s: *State = @ptrCast(@alignCast(ptr));
            allocator.destroy(s);
        }
    }.destroy);

    // 如果初始条件为 true，立即创建
    if (condition.peek()) {
        const child_scope = try scope.childScope();
        const node = buildFn(child_scope, cx) catch |err| {
            child_scope.dispose();
            return err;
        };
        parent.appendChild(cx.allocator, node) catch |err| {
            discardUnmountedSubtree(cx, child_scope, node);
            return err;
        };
        state.child_scope = child_scope;
        state.child_node = node;
    }

    // Effect: 响应 condition 变化
    try scope.createEffect(.{
        .condition = condition,
        .state = state,
    }, struct {
        fn update(c: anytype) void {
            const cond = c.condition.get();
            const s = c.state;

            if (cond and s.child_node == null) {
                // 创建。三步都可能失败，且**后一步失败时前一步的产物无人回收** ——
                // 原实现三行各自 `catch return`：第 2 行失败漏掉 child_scope，
                // 第 3 行失败则 node + scope 双双泄漏，且 UI 静默少一块、无任何日志。
                // 改为逐级 errdefer 回滚，失败时至少不留垃圾。
                const child_scope = s.parent_scope.childScope() catch |err| {
                    reportControlFlowError("Show.create/childScope", err);
                    return;
                };
                const node = buildFn(child_scope, s.cx_ptr) catch |err| {
                    reportControlFlowError("Show.create/build", err);
                    child_scope.dispose();
                    return;
                };

                s.parent_node.appendChild(s.cx_ptr.allocator, node) catch |err| {
                    reportControlFlowError("Show.create/appendChild", err);
                    discardUnmountedSubtree(s.cx_ptr, child_scope, node);
                    return;
                };
                s.child_scope = child_scope;
                s.child_node = node;
                s.parent_node.markLayoutDirty();
                s.cx_ptr.needs_redraw = true;
            } else if (!cond and s.child_node != null) {
                // 销毁 — 先 dispose scope 再清除 scope 指针再 destroy node
                const old = s.child_node.?;
                hooks.invalidateSubtreeHookState(old);
                if (s.child_scope) |cs| {
                    if (!cs.disposed) cs.dispose();
                }
                clearNodeScopes(old);
                s.cx_ptr.detachChild(s.parent_node, old);
                // 必须走 cx.freeNode 而非 node.destroy：后者不回收 ElementTable
                // slot（destroyElement 只在 freeNode 里调），且绕过 tick_depth
                // 延迟释放守卫 —— before_render 里 set signal 会同步 drain 到
                // 这里，此刻直接 free 会让上层遍历栈解引用已释放节点。
                s.cx_ptr.freeNode(old);
                s.child_scope = null;
                s.child_node = null;
                s.parent_node.markLayoutDirty();
                s.cx_ptr.needs_redraw = true;
            }
        }
    }.update);
}

/// For 控制流 options（v0.7 §2.4 拆出 — key_fn 强制 + eq_props_fn 可选）
///
/// 三类函数职责分离:
/// - `key_fn`: item → 唯一 key (必填)。**身份**判定，决定哪两个 item 是 "同一个"。
///   推荐 `item.id` / `item.hash()`；不能用 index（增删时 index shift 会误匹配）。
/// - `render_fn`: 渲染 fn (必填)。child_scope 持有 reactive 资源，回收时自动 dispose。
/// - `eq_props_fn`: prev vs next 是否 **props 等价** (可选)。缺省 null → eqlValue
///   智能比较（[]const u8 比内容 / NaN bytewise / 嵌套 struct 递归）。
///   true 时复用旧 node（不 rerender），false 时 destroy + create。
///   caller 注 fast-path: 只比关键字段、跳过 cached_handle 等内部字段，或
///   `fn(_, _) bool { return true; }` 强制永远复用（搭配 reactive signal 自管脏）。
pub fn ForOpts(comptime T: type) type {
    return struct {
        key_fn: fn (T) u64,
        render_fn: fn (*Scope, *Cx, T, usize) anyerror!*Node,
        eq_props_fn: ?fn (T, T) bool = null,
    };
}

/// For — 列表渲染
///
/// 根据 items slice Signal 增量渲染列表。
/// 用 opts.key_fn 提取每 item 唯一 key 做身份匹配；opts.eq_props_fn 判 props
/// 等价决定 reuse vs rebuild。
/// parent 不必独占：For 条目在 parent 里占连续一段（挂载时位于末尾），
/// 段前后的其它兄弟在增删重排时保持原位。
///
/// 用法:
/// ```zig
/// try For([]const u8, scope, parent, items_signal, cx, .{
///     .key_fn = struct { fn k(item: []const u8) u64 { return std.hash.Wyhash.hash(0, item); } }.k,
///     .render_fn = struct { fn r(child_scope: *Scope, c: *Cx, item: []const u8, idx: usize) anyerror!*Node {
///         _ = idx;
///         return try ui.text(c, item, .{});
///     }}.r,
///     // .eq_props_fn = null,  // 默认走 eqlValue
/// });
/// ```
pub fn For(
    comptime T: type,
    scope: *Scope,
    parent: *Node,
    data: *Signal([]const T),
    cx: *Cx,
    comptime opts: ForOpts(T),
) !void {
    const keyFn = opts.key_fn;
    const renderItem = opts.render_fn;
    const eqProps = opts.eq_props_fn;
    const ItemEntry = struct {
        key: u64,
        item: T,
        scope: *Scope,
        node: *Node,
    };

    const State = struct {
        entries: std.ArrayList(ItemEntry),
        /// For 段之前的非 For 兄弟个数（见 reorderForSegment）。
        segment_lead: usize,
        parent_scope: *Scope,
        parent_node: *Node,
        cx_ptr: *Cx,
        alloc: Allocator,
    };

    const state = try scope.allocator.create(State);
    state.* = .{
        .entries = .{},
        .segment_lead = parent.children.items.len,
        .parent_scope = scope,
        .parent_node = parent,
        .cx_ptr = cx,
        .alloc = scope.allocator,
    };
    try scope.adoptResource(@ptrCast(state), struct {
        fn destroy(ptr: *anyopaque, allocator: Allocator) void {
            const s: *State = @ptrCast(@alignCast(ptr));
            s.entries.deinit(allocator);
            allocator.destroy(s);
        }
    }.destroy);

    // 初始渲染
    const initial_items = data.peek();
    for (initial_items, 0..) |item, idx| {
        const key = keyFn(item);
        const child_scope = try scope.childScope();
        const node = renderItem(child_scope, cx, item, idx) catch |err| {
            child_scope.dispose();
            return err;
        };
        // 先预留 entries 容量再挂树：两步之间不能再有可失败点，否则节点
        // 已上树却不在 entries 里（后续 diff 永远摘不掉它）。
        state.entries.ensureUnusedCapacity(scope.allocator, 1) catch |err| {
            discardUnmountedSubtree(cx, child_scope, node);
            return err;
        };
        parent.appendChild(cx.allocator, node) catch |err| {
            discardUnmountedSubtree(cx, child_scope, node);
            return err;
        };
        state.entries.appendAssumeCapacity(.{
            .key = key,
            .item = item,
            .scope = child_scope,
            .node = node,
        });
    }

    // Effect: 响应 data 变化，key-based diff 增量更新
    try scope.createEffect(.{
        .data = data,
        .state = state,
    }, struct {
        fn update(c: anytype) void {
            const items = c.data.get();
            const s = c.state;

            // Key-based diff: 保留 key 相同的条目，只销毁/创建变化的
            // 1. 旧条目 → HashMap<key, index>
            var old_map = std.AutoHashMap(u64, usize).init(s.alloc);
            defer old_map.deinit();
            for (s.entries.items, 0..) |entry, i| {
                // 不可降级：old_map 缺条目 → 已存在的 key 被当成新建，
                // 旧节点在步骤 3 被销毁而新节点重复创建 = 静默 UI 错乱。
                old_map.put(entry.key, i) catch @panic("OOM: For keyed reconcile old_map.put");
            }

            // 2. 遍历新 items — 匹配的复用，不匹配的创建
            var new_entries: std.ArrayList(ItemEntry) = .{};
            var reused = std.AutoHashMap(usize, void).init(s.alloc); // 标记被复用的旧索引
            defer reused.deinit();

            for (items, 0..) |item, idx| {
                const key = keyFn(item);
                if (old_map.get(key)) |old_idx| {
                    // A key may occur more than once even though keyed lists
                    // conventionally require uniqueness. Reusing the same old
                    // entry twice aliases its node/scope and later cleanup turns
                    // that alias into UAF/double-free. Only the first occurrence
                    // may consume an old entry; render later duplicates afresh.
                    if (reused.contains(old_idx)) {
                        appendForEntry(s, &new_entries, key, item, idx, renderItem) catch @panic("OOM: For keyed reconcile appendForEntry (duplicate key)");
                        continue;
                    }
                    const old_entry = s.entries.items[old_idx];
                    // caller 可注 eq_props_fn 自定义 reuse 判定；缺省
                    // 走 eqlValue（reactive/eq.zig 类型分发的内容比较，正确处理
                    // []const u8 / NaN / 嵌套 struct）。key 命中但 props 不等仍重建。
                    const can_reuse = if (eqProps) |f|
                        f(item, old_entry.item)
                    else
                        @import("reactive/eq.zig").eqlValue(@TypeOf(item), item, old_entry.item);
                    if (can_reuse) {
                        new_entries.append(s.alloc, old_entry) catch @panic("OOM: For keyed reconcile new_entries.append");
                        // 不可降级：漏标 reused → 步骤 3 会销毁一个仍挂在
                        // new_entries 里的节点，留下悬垂 node 指针。
                        reused.put(old_idx, {}) catch @panic("OOM: For keyed reconcile reused.put");
                        continue;
                    }

                    hooks.invalidateSubtreeHookState(old_entry.node);
                    if (!old_entry.scope.disposed) old_entry.scope.dispose();
                    clearNodeScopes(old_entry.node);
                    s.cx_ptr.detachChild(s.parent_node, old_entry.node);
                    s.cx_ptr.freeNode(old_entry.node);
                    // 不可降级：此处 old_entry.node 已被 freeNode，漏标 reused
                    // 会让步骤 3 再次 dispose/free 同一节点 = double free。
                    reused.put(old_idx, {}) catch @panic("OOM: For keyed reconcile reused.put (rebuilt entry)");

                    appendForEntry(s, &new_entries, key, item, idx, renderItem) catch @panic("OOM: For keyed reconcile appendForEntry");
                } else {
                    // 新建: key 不在旧列表中
                    appendForEntry(s, &new_entries, key, item, idx, renderItem) catch @panic("OOM: For keyed reconcile appendForEntry (new key)");
                }
            }

            // 3. 销毁旧 map 中未被复用的条目
            for (s.entries.items, 0..) |entry, i| {
                if (reused.contains(i)) continue;
                hooks.invalidateSubtreeHookState(entry.node);
                if (!entry.scope.disposed) entry.scope.dispose();
                clearNodeScopes(entry.node);
                s.cx_ptr.detachChild(s.parent_node, entry.node);
                s.cx_ptr.freeNode(entry.node);
            }

            // 4. 替换 entries —— 必须无条件、且先于任何可失败的步骤：步骤 2/3
            //    已释放旧节点，若在这之前 `catch return`，s.entries 会留着悬垂
            //    节点（下次 diff double free），new_entries 则整批泄漏。
            s.entries.deinit(s.alloc);
            s.entries = new_entries;
            s.cx_ptr.needs_redraw = true;

            // 5. 只重排 For 管理的那一段，保留 parent 里的其它兄弟。
            //    失败时新节点暂未上树但归 s.entries 所有，下次 diff 会再挂。
            reorderForSegment(s) catch |err| reportControlFlowError("For.update/reorder", err);
        }
    }.update);
}

/// Match — 枚举/整数条件切换
///
/// 类似 SolidJS 的 <Switch>/<Match>，根据枚举或整数 Signal 值切换子树。
/// value 变化时，销毁旧子树，调用 buildFn 创建新子树。
///
/// 用法:
/// ```zig
/// try Match(Category, scope, parent, category_signal, cx,
///     struct {
///         fn build(child_scope: *Scope, c: *Cx, cat: Category) anyerror!*Node {
///             return switch (cat) {
///                 .buttons => try buildButtonsPage(child_scope, c),
///                 .inputs  => try buildInputsPage(child_scope, c),
///             };
///         }
///     }.build,
/// );
/// ```
/// Match 句柄，用于外部强制重建
pub const MatchHandle = struct {
    state: *anyopaque,
    rebuild_fn: *const fn (*anyopaque) void,

    /// 强制重建当前子树（主题切换等场景）
    pub fn invalidate(self: MatchHandle) void {
        self.rebuild_fn(self.state);
    }
};

pub fn Match(
    comptime T: type,
    scope: *Scope,
    parent: *Node,
    value: *Signal(T),
    cx: *Cx,
    comptime buildFn: fn (*Scope, *Cx, T) anyerror!*Node,
) !MatchHandle {
    const State = struct {
        child_scope: ?*Scope = null,
        child_node: ?*Node = null,
        current_value: T,
        parent_scope: *Scope,
        parent_node: *Node,
        cx_ptr: *Cx,

        fn rebuild(s: *@This()) void {
            // 销毁旧子树
            // 顺序重要：先 dispose scope（清理 effects/signals 等响应式资源），
            // 再清除节点树上的 scope 指针（防止 destroy 访问已释放的 scope），
            // 最后 destroy node（释放节点内存）。
            if (s.child_scope) |cs| {
                if (s.child_node) |old_node| hooks.invalidateSubtreeHookState(old_node);
                if (!cs.disposed) cs.dispose();
            }
            if (s.child_node) |old_node| {
                // scope 已 dispose 并释放内存，清除节点上的悬垂 scope 指针
                clearNodeScopes(old_node);
                s.cx_ptr.detachChild(s.parent_node, old_node);
                s.cx_ptr.freeNode(old_node);
            }
            s.child_scope = null;
            s.child_node = null;

            // 创建新子树
            // 与 Show.create 同构的逐级回滚（原实现三行各自 catch return，
            // 后一步失败会漏掉前一步的 scope/node）。
            const child_scope = s.parent_scope.childScope() catch |err| {
                reportControlFlowError("Match.rebuild/childScope", err);
                return;
            };
            const node = buildFn(child_scope, s.cx_ptr, s.current_value) catch |err| {
                reportControlFlowError("Match.rebuild/build", err);
                child_scope.dispose();
                return;
            };

            s.parent_node.appendChild(s.cx_ptr.allocator, node) catch |err| {
                reportControlFlowError("Match.rebuild/appendChild", err);
                discardUnmountedSubtree(s.cx_ptr, child_scope, node);
                return;
            };
            s.child_scope = child_scope;
            s.child_node = node;
            s.parent_node.markLayoutDirty();
            s.cx_ptr.needs_redraw = true;
        }

        fn rebuildErased(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.rebuild();
        }
    };

    const state = try scope.allocator.create(State);
    state.* = .{
        .current_value = value.peek(),
        .parent_scope = scope,
        .parent_node = parent,
        .cx_ptr = cx,
    };
    try scope.adoptResource(@ptrCast(state), struct {
        fn destroy(ptr: *anyopaque, allocator: Allocator) void {
            const s: *State = @ptrCast(@alignCast(ptr));
            allocator.destroy(s);
        }
    }.destroy);

    // 初始创建
    {
        const child_scope = try scope.childScope();
        const node = buildFn(child_scope, cx, state.current_value) catch |err| {
            child_scope.dispose();
            return err;
        };
        parent.appendChild(cx.allocator, node) catch |err| {
            discardUnmountedSubtree(cx, child_scope, node);
            return err;
        };
        state.child_scope = child_scope;
        state.child_node = node;
    }

    // Effect: 响应 value 变化 → 销毁旧子树 + 创建新子树
    try scope.createEffect(.{
        .value = value,
        .state = state,
    }, struct {
        fn update(c: anytype) void {
            const new_val = c.value.get();
            const s = c.state;

            // 同值不切换 (v0.7 §2.4: eqlValue 替代 std.meta.eql — 正确处理 NaN /
            // []const u8 / 嵌套 struct，避免 Match(T=string) 时 ptr-equality 误判)
            if (@import("reactive/eq.zig").eqlValue(@TypeOf(new_val), new_val, s.current_value) and s.child_node != null) return;
            s.current_value = new_val;

            s.rebuild();
        }
    }.update);

    return .{
        .state = @ptrCast(state),
        .rebuild_fn = &State.rebuildErased,
    };
}

// ===== 测试 =====

test "Show: basic toggle" {
    const allocator = std.testing.allocator;
    var ctx = try Cx.init(allocator);
    defer ctx.deinit();

    const parent = try Node.create(allocator, ctx.nextId(), .box, .{ .width = .{ .px = 200 }, .height = .{ .px = 200 } });
    ctx.root = parent;

    const root_scope = try Scope.init(allocator, null, ctx.owner);
    defer root_scope.dispose();

    const visible = try root_scope.createSignal(bool, false);

    try Show(root_scope, parent, visible, ctx, struct {
        fn build(_: *Scope, c: *Cx) anyerror!*Node {
            const n = try Node.create(c.allocator, c.nextId(), .box, .{
                .width = .{ .px = 100 },
                .height = .{ .px = 50 },
            });
            c.linkNodeToWorld(n);
            n.setBackgroundRaw(core.Color.hex(0xff0000));
            return n;
        }
    }.build);

    // 初始: 不可见，无子节点
    try std.testing.expectEqual(@as(usize, 0), parent.children.items.len);

    // 设置可见
    visible.set(true);
    try std.testing.expectEqual(@as(usize, 1), parent.children.items.len);

    // 设置不可见
    visible.set(false);
    try std.testing.expectEqual(@as(usize, 0), parent.children.items.len);

    // 再次可见
    visible.set(true);
    try std.testing.expectEqual(@as(usize, 1), parent.children.items.len);
}

test "Show: initial true" {
    const allocator = std.testing.allocator;
    var ctx = try Cx.init(allocator);
    defer ctx.deinit();

    const parent = try Node.create(allocator, ctx.nextId(), .box, .{ .width = .{ .px = 200 }, .height = .{ .px = 200 } });
    ctx.root = parent;

    const root_scope = try Scope.init(allocator, null, ctx.owner);
    defer root_scope.dispose();

    const visible = try root_scope.createSignal(bool, true);

    try Show(root_scope, parent, visible, ctx, struct {
        fn build(_: *Scope, c: *Cx) anyerror!*Node {
            return try Node.create(c.allocator, c.nextId(), .box, .{
                .width = .{ .px = 50 },
                .height = .{ .px = 50 },
            });
        }
    }.build);

    // 初始即可见
    try std.testing.expectEqual(@as(usize, 1), parent.children.items.len);

    // 隐藏
    visible.set(false);
    try std.testing.expectEqual(@as(usize, 0), parent.children.items.len);
}

test "Show: reactive teardown runs scope cleanups before freeing its node" {
    const allocator = std.testing.allocator;
    const ctx = try Cx.init(allocator);
    defer ctx.deinit();

    const parent = try Node.create(allocator, ctx.nextId(), .box, .{
        .width = .{ .px = 200 },
        .height = .{ .px = 100 },
    });
    ctx.linkNodeToWorld(parent);
    ctx.root = parent;

    const root_scope = try Scope.init(allocator, null, ctx.owner);
    defer root_scope.dispose();
    const visible = try root_scope.createSignal(bool, true);

    const TeardownOrder = struct {
        node_freed: bool = false,
        cleanup_ran: bool = false,
        cleanup_saw_live_node: bool = false,
    };
    var order = TeardownOrder{};

    const Harness = struct {
        var marker: ?*TeardownOrder = null;

        fn build(child_scope: *Scope, c: *Cx) anyerror!*Node {
            const order_marker = marker.?;
            const node = try Node.create(c.allocator, c.nextId(), .box, .{
                .width = .{ .px = 10 },
                .height = .{ .px = 10 },
            });
            c.linkNodeToWorld(node);
            node.meta.ownership.hooks.on_cleanup = Cx.simpleHandler(struct {
                fn freed(raw: *anyopaque) void {
                    const teardown: *TeardownOrder = @ptrCast(@alignCast(raw));
                    teardown.node_freed = true;
                }
            }.freed, @ptrCast(order_marker));
            try child_scope.onCleanup(TeardownOrder, order_marker, struct {
                fn cleanup(teardown: *TeardownOrder) void {
                    teardown.cleanup_ran = true;
                    teardown.cleanup_saw_live_node = !teardown.node_freed;
                }
            }.cleanup);
            return node;
        }
    };
    Harness.marker = &order;
    defer Harness.marker = null;

    try Show(root_scope, parent, visible, ctx, Harness.build);

    visible.set(false);
    try std.testing.expect(order.cleanup_ran);
    try std.testing.expect(order.cleanup_saw_live_node);
    try std.testing.expect(order.node_freed);
}

test "For: basic list" {
    const allocator = std.testing.allocator;
    var ctx = try Cx.init(allocator);
    defer ctx.deinit();

    const parent = try Node.create(allocator, ctx.nextId(), .box, .{ .width = .{ .px = 300 }, .height = .{ .px = 400 } });
    ctx.root = parent;

    const root_scope = try Scope.init(allocator, null, ctx.owner);
    defer root_scope.dispose();

    const Item = struct { id: u64, value: i32 };
    const items_storage = [_]Item{
        .{ .id = 1, .value = 10 },
        .{ .id = 2, .value = 20 },
        .{ .id = 3, .value = 30 },
    };

    const items = try root_scope.createSignal([]const Item, &items_storage);

    try For(Item, root_scope, parent, items, ctx, .{
        .key_fn = struct {
            fn key(item: Item) u64 {
                return item.id;
            }
        }.key,
        .render_fn = struct {
            fn render(_: *Scope, c: *Cx, _: Item, _: usize) anyerror!*Node {
                return try Node.create(c.allocator, c.nextId(), .box, .{
                    .width = .{ .grow = .{} },
                    .height = .{ .px = 30 },
                });
            }
        }.render,
    });

    // 初始 3 个条目
    try std.testing.expectEqual(@as(usize, 3), parent.children.items.len);

    // 更新为 2 个条目
    const items_2 = [_]Item{
        .{ .id = 1, .value = 100 },
        .{ .id = 4, .value = 40 },
    };
    items.set(&items_2);
    try std.testing.expectEqual(@as(usize, 2), parent.children.items.len);

    // 更新为空
    const items_empty: []const Item = &.{};
    items.set(items_empty);
    try std.testing.expectEqual(@as(usize, 0), parent.children.items.len);
}

test "For: key-based diff rebuilds nodes when item payload changes" {
    const allocator = std.testing.allocator;
    var ctx = try Cx.init(allocator);
    defer ctx.deinit();

    const parent = try Node.create(allocator, ctx.nextId(), .box, .{ .width = .{ .px = 300 }, .height = .{ .px = 400 } });
    ctx.root = parent;

    const root_scope = try Scope.init(allocator, null, ctx.owner);
    defer root_scope.dispose();

    const Item = struct { id: u64, value: i32 };
    const items_v1 = [_]Item{
        .{ .id = 1, .value = 10 },
        .{ .id = 2, .value = 20 },
        .{ .id = 3, .value = 30 },
    };

    const items = try root_scope.createSignal([]const Item, &items_v1);

    try For(Item, root_scope, parent, items, ctx, .{
        .key_fn = struct {
            fn key(item: Item) u64 {
                return item.id;
            }
        }.key,
        .render_fn = struct {
            fn render(_: *Scope, c: *Cx, _: Item, _: usize) anyerror!*Node {
                return try Node.create(c.allocator, c.nextId(), .box, .{
                    .width = .{ .grow = .{} },
                    .height = .{ .px = 30 },
                });
            }
        }.render,
    });

    // 保存初始节点指针
    const node_1 = parent.children.items[0];
    const node_2 = parent.children.items[1];
    const node_3 = parent.children.items[2];

    // 更新: 删除 id=2，id=1/id=3 的 payload 变化，新增 id=4
    const items_v2 = [_]Item{
        .{ .id = 1, .value = 100 },
        .{ .id = 3, .value = 300 },
        .{ .id = 4, .value = 40 },
    };
    items.set(&items_v2);

    try std.testing.expectEqual(@as(usize, 3), parent.children.items.len);
    // id=1 / id=3 payload 变化后应重建，避免复用旧节点导致陈旧内容
    try std.testing.expect(parent.children.items[0] != node_1);
    try std.testing.expect(parent.children.items[1] != node_3);
    // id=4 是新节点
    try std.testing.expect(parent.children.items[2] != node_2);

    // 反向: 保留 id=4, 删除 id=1 和 id=3
    const node_4 = parent.children.items[2];
    const items_v3 = [_]Item{
        .{ .id = 4, .value = 400 },
    };
    items.set(&items_v3);

    try std.testing.expectEqual(@as(usize, 1), parent.children.items.len);
    // id=4 payload 从 40 -> 400，当前策略会重建
    try std.testing.expect(parent.children.items[0] != node_4);
}

test "Match: enum switch" {
    const allocator = std.testing.allocator;
    var ctx = try Cx.init(allocator);
    defer ctx.deinit();

    const parent = try Node.create(allocator, ctx.nextId(), .box, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } });
    ctx.root = parent;

    const root_scope = try Scope.init(allocator, null, ctx.owner);
    defer root_scope.dispose();

    const Mode = enum(u8) { alpha = 0, beta, gamma };
    const mode = try root_scope.createSignal(Mode, .alpha);

    _ = try Match(Mode, root_scope, parent, mode, ctx, struct {
        fn build(_: *Scope, c: *Cx, val: Mode) anyerror!*Node {
            const h: f32 = switch (val) {
                .alpha => 10,
                .beta => 20,
                .gamma => 30,
            };
            return try Node.create(c.allocator, c.nextId(), .box, .{
                .width = .{ .px = 100 },
                .height = .{ .px = h },
            });
        }
    }.build);

    // 初始: alpha → 1 个子节点
    try std.testing.expectEqual(@as(usize, 1), parent.children.items.len);

    // 切换到 beta
    mode.set(.beta);
    try std.testing.expectEqual(@as(usize, 1), parent.children.items.len);

    // 切换到 gamma
    mode.set(.gamma);
    try std.testing.expectEqual(@as(usize, 1), parent.children.items.len);

    // 切回 alpha
    mode.set(.alpha);
    try std.testing.expectEqual(@as(usize, 1), parent.children.items.len);

    // 设同值不应触发重建 (只是验证不 crash)
    mode.set(.alpha);
    try std.testing.expectEqual(@as(usize, 1), parent.children.items.len);
}

// ============================================================================
// v0.7 §2.4 — For 控制流 key-only + eq_props_fn tests
// ============================================================================

test "For eq_props_fn=true 强制复用，key 命中即不重建" {
    const allocator = std.testing.allocator;
    var ctx = try Cx.init(allocator);
    defer ctx.deinit();

    const parent = try Node.create(allocator, ctx.nextId(), .box, .{ .width = .{ .px = 300 }, .height = .{ .px = 400 } });
    ctx.root = parent;

    const root_scope = try Scope.init(allocator, null, ctx.owner);
    defer root_scope.dispose();

    const Item = struct { id: u64, payload: i32 };
    const v1 = [_]Item{ .{ .id = 1, .payload = 10 }, .{ .id = 2, .payload = 20 } };
    const items = try root_scope.createSignal([]const Item, &v1);

    try For(Item, root_scope, parent, items, ctx, .{
        .key_fn = struct {
            fn k(i: Item) u64 {
                return i.id;
            }
        }.k,
        .render_fn = struct {
            fn r(_: *Scope, c: *Cx, _: Item, _: usize) anyerror!*Node {
                return try Node.create(c.allocator, c.nextId(), .box, .{ .width = .{ .px = 10 }, .height = .{ .px = 10 } });
            }
        }.r,
        // 强制永远 reuse — 即使 payload 变了也不重建（caller 用 reactive signal 自管脏）
        .eq_props_fn = struct {
            fn eq(_: Item, _: Item) bool {
                return true;
            }
        }.eq,
    });

    const node_1 = parent.children.items[0];
    const node_2 = parent.children.items[1];

    // payload 改变 — 但 eq_props_fn=true 强制复用
    const v2 = [_]Item{ .{ .id = 1, .payload = 999 }, .{ .id = 2, .payload = 888 } };
    items.set(&v2);

    try std.testing.expectEqual(@as(usize, 2), parent.children.items.len);
    try std.testing.expectEqual(node_1, parent.children.items[0]); // 同 ptr，未重建
    try std.testing.expectEqual(node_2, parent.children.items[1]);
}

test "For eq_props_fn=false 强制重建，每次 update 都换 node" {
    const allocator = std.testing.allocator;
    var ctx = try Cx.init(allocator);
    defer ctx.deinit();

    const parent = try Node.create(allocator, ctx.nextId(), .box, .{ .width = .{ .px = 300 }, .height = .{ .px = 400 } });
    ctx.root = parent;

    const root_scope = try Scope.init(allocator, null, ctx.owner);
    defer root_scope.dispose();

    const Item = struct { id: u64, payload: i32 };
    const v1 = [_]Item{.{ .id = 1, .payload = 10 }};
    const items = try root_scope.createSignal([]const Item, &v1);

    try For(Item, root_scope, parent, items, ctx, .{
        .key_fn = struct {
            fn k(i: Item) u64 {
                return i.id;
            }
        }.k,
        .render_fn = struct {
            fn r(_: *Scope, c: *Cx, _: Item, _: usize) anyerror!*Node {
                return try Node.create(c.allocator, c.nextId(), .box, .{ .width = .{ .px = 10 }, .height = .{ .px = 10 } });
            }
        }.r,
        // 强制永远重建
        .eq_props_fn = struct {
            fn eq(_: Item, _: Item) bool {
                return false;
            }
        }.eq,
    });

    const node_1 = parent.children.items[0];

    // 改 payload，让 signal.set 检测到不等触发 effect。key 仍然=1，
    // 默认走 eqlValue 会重建（payload 变了）；这里我们用 eq_props_fn=false 来
    // 验 caller 显式 override —— 即使 eq_props_fn 总返 false 也成立重建。
    // 反向 case 是 "payload 不变 + eq_props_fn=false" — 信号检测到等会短路，
    // effect 永不跑，所以无法在 fixture 内独立测；先用 payload 变化 + 强制 false
    // 验 "eq_props_fn 真被调"。
    const v2 = [_]Item{.{ .id = 1, .payload = 999 }};
    items.set(&v2);
    try std.testing.expect(parent.children.items[0] != node_1);
}

test "For eq_props_fn 选择性比较字段（忽略 cached_handle）" {
    const allocator = std.testing.allocator;
    var ctx = try Cx.init(allocator);
    defer ctx.deinit();

    const parent = try Node.create(allocator, ctx.nextId(), .box, .{ .width = .{ .px = 300 }, .height = .{ .px = 400 } });
    ctx.root = parent;

    const root_scope = try Scope.init(allocator, null, ctx.owner);
    defer root_scope.dispose();

    const Item = struct {
        id: u64,
        label: i32,
        cached_handle: u64, // caller 内部缓存，每次 update 都变，但不影响渲染
    };
    const v1 = [_]Item{.{ .id = 1, .label = 10, .cached_handle = 0xABCD }};
    const items = try root_scope.createSignal([]const Item, &v1);

    try For(Item, root_scope, parent, items, ctx, .{
        .key_fn = struct {
            fn k(i: Item) u64 {
                return i.id;
            }
        }.k,
        .render_fn = struct {
            fn r(_: *Scope, c: *Cx, _: Item, _: usize) anyerror!*Node {
                return try Node.create(c.allocator, c.nextId(), .box, .{ .width = .{ .px = 10 }, .height = .{ .px = 10 } });
            }
        }.r,
        // 只比 label，忽略 cached_handle
        .eq_props_fn = struct {
            fn eq(a: Item, b: Item) bool {
                return a.label == b.label;
            }
        }.eq,
    });

    const node_1 = parent.children.items[0];

    // cached_handle 变了，但 label 没变 → 复用
    const v2 = [_]Item{.{ .id = 1, .label = 10, .cached_handle = 0xDEAD }};
    items.set(&v2);
    try std.testing.expectEqual(node_1, parent.children.items[0]);

    // label 真变了 → 重建
    const v3 = [_]Item{.{ .id = 1, .label = 20, .cached_handle = 0xDEAD }};
    items.set(&v3);
    try std.testing.expect(parent.children.items[0] != node_1);
}

test "For 默认 eq_props_fn=null 走 eqlValue (与历史行为一致)" {
    const allocator = std.testing.allocator;
    var ctx = try Cx.init(allocator);
    defer ctx.deinit();

    const parent = try Node.create(allocator, ctx.nextId(), .box, .{ .width = .{ .px = 300 }, .height = .{ .px = 400 } });
    ctx.root = parent;

    const root_scope = try Scope.init(allocator, null, ctx.owner);
    defer root_scope.dispose();

    const Item = struct { id: u64, name: []const u8 };
    const v1 = [_]Item{.{ .id = 1, .name = "alpha" }};
    const items = try root_scope.createSignal([]const Item, &v1);

    try For(Item, root_scope, parent, items, ctx, .{
        .key_fn = struct {
            fn k(i: Item) u64 {
                return i.id;
            }
        }.k,
        .render_fn = struct {
            fn r(_: *Scope, c: *Cx, _: Item, _: usize) anyerror!*Node {
                return try Node.create(c.allocator, c.nextId(), .box, .{ .width = .{ .px = 10 }, .height = .{ .px = 10 } });
            }
        }.r,
        // eq_props_fn = null → 走 eqlValue 默认 (内容比较)
    });

    const node_1 = parent.children.items[0];

    // 不同 ptr 但内容相同的 []const u8 — std.meta.eql 会误判不等 → 重建；
    // eqlValue 比内容 → 视作等 → 复用
    var name_buf: [16]u8 = undefined;
    @memcpy(name_buf[0..5], "alpha");
    const v2 = [_]Item{.{ .id = 1, .name = name_buf[0..5] }};
    items.set(&v2);
    try std.testing.expectEqual(node_1, parent.children.items[0]);

    // 真改名 → 重建
    const v3 = [_]Item{.{ .id = 1, .name = "beta" }};
    items.set(&v3);
    try std.testing.expect(parent.children.items[0] != node_1);
}

// ============================================================================
// v0.8 §2.3 — For focus restoration e2e
// ============================================================================
//
// v0.7 §2.4 退出标准里 "focus restoration on rerender: infrastructure 就位...
// e2e 验证留 v0.8"。本 fixture 兑现：
//
// 1. mount For 用 eq_props_fn=true (强制 reuse)
// 2. setFocus 到第二个节点
// 3. items signal.set 新数组 (相同 key, 不同 payload)
// 4. 断言: (a) Node ptr 没变 (eq_props_fn 真生效)；(b) cx.isFocused 仍 true
//
// 如果 For 没复用同 Node ptr → focus_manager 的 focused_node 指向被销毁的 Node →
// isFocused = false 或 segfault；这一刀真验 "key + eq_props_fn 的复用是
// reactive focus restoration 的基础设施"。
// ============================================================================

test "For eq_props_fn=true 时 reactive rerender 保持焦点" {
    const allocator = std.testing.allocator;
    var ctx = try Cx.init(allocator);
    defer ctx.deinit();

    const parent = try Node.create(allocator, ctx.nextId(), .box, .{ .width = .{ .px = 300 }, .height = .{ .px = 400 } });
    ctx.linkNodeToWorld(parent);
    ctx.root = parent;

    const root_scope = try Scope.init(allocator, null, ctx.owner);
    defer root_scope.dispose();

    const Item = struct { id: u64, payload: i32 };
    const v1 = [_]Item{
        .{ .id = 1, .payload = 10 },
        .{ .id = 2, .payload = 20 },
        .{ .id = 3, .payload = 30 },
    };
    const items = try root_scope.createSignal([]const Item, &v1);

    try For(Item, root_scope, parent, items, ctx, .{
        .key_fn = struct {
            fn k(i: Item) u64 {
                return i.id;
            }
        }.k,
        .render_fn = struct {
            fn r(_: *Scope, c: *Cx, _: Item, _: usize) anyerror!*Node {
                const n = try Node.create(c.allocator, c.nextId(), .box, .{
                    .width = .{ .px = 10 },
                    .height = .{ .px = 10 },
                });
                n.behavior.interaction.focusable = true;
                c.linkNodeToWorld(n);
                return n;
            }
        }.r,
        // 强制 reuse — caller 用 reactive signal 自管脏，eq_props_fn=true
        // 让 key 命中即不重建
        .eq_props_fn = struct {
            fn eq(_: Item, _: Item) bool {
                return true;
            }
        }.eq,
    });

    try std.testing.expectEqual(@as(usize, 3), parent.children.items.len);
    const node_2_before = parent.children.items[1];

    // 焦点落在第二个节点
    ctx.setFocus(node_2_before);
    try std.testing.expect(ctx.isFocused(node_2_before));

    // 改 payload —— signal 检测到不等触发 effect，For 走 reuse 分支
    const v2 = [_]Item{
        .{ .id = 1, .payload = 999 },
        .{ .id = 2, .payload = 888 },
        .{ .id = 3, .payload = 777 },
    };
    items.set(&v2);

    // (a) Node ptr 没变
    const node_2_after = parent.children.items[1];
    try std.testing.expectEqual(node_2_before, node_2_after);

    // (b) 焦点仍贴在原 Node 上 — focus_manager 的 focused_node 没失效
    try std.testing.expect(ctx.isFocused(node_2_after));
}

test "反向 case — eq_props_fn=false 时 Node 被销毁，焦点丢失" {
    const allocator = std.testing.allocator;
    var ctx = try Cx.init(allocator);
    defer ctx.deinit();

    const parent = try Node.create(allocator, ctx.nextId(), .box, .{ .width = .{ .px = 300 }, .height = .{ .px = 400 } });
    ctx.linkNodeToWorld(parent);
    ctx.root = parent;

    const root_scope = try Scope.init(allocator, null, ctx.owner);
    defer root_scope.dispose();

    const Item = struct { id: u64, payload: i32 };
    const v1 = [_]Item{.{ .id = 1, .payload = 10 }};
    const items = try root_scope.createSignal([]const Item, &v1);

    try For(Item, root_scope, parent, items, ctx, .{
        .key_fn = struct {
            fn k(i: Item) u64 {
                return i.id;
            }
        }.k,
        .render_fn = struct {
            fn r(_: *Scope, c: *Cx, _: Item, _: usize) anyerror!*Node {
                const n = try Node.create(c.allocator, c.nextId(), .box, .{ .width = .{ .px = 10 }, .height = .{ .px = 10 } });
                n.behavior.interaction.focusable = true;
                c.linkNodeToWorld(n);
                return n;
            }
        }.r,
        .eq_props_fn = struct {
            fn eq(_: Item, _: Item) bool {
                return false; // 强制重建
            }
        }.eq,
    });

    const node_1_before = parent.children.items[0];
    ctx.setFocus(node_1_before);
    try std.testing.expect(ctx.isFocused(node_1_before));

    // 改 payload —— eq_props_fn=false 触发重建
    const v2 = [_]Item{.{ .id = 1, .payload = 999 }};
    items.set(&v2);

    const node_1_after = parent.children.items[0];
    try std.testing.expect(node_1_after != node_1_before);
    // 旧 node 已销毁；focus_manager 的 focused_node 不再指向当前 child
    try std.testing.expect(!ctx.isFocused(node_1_after));
}

test "control flow: build failure is reported, not silently swallowed" {
    // 审查报告 §3：Show/For/Match 的 effect 回调历史上一律 `catch return`，
    // OOM/构建失败被**完全吞掉** —— UI 悄悄少一块，无日志无计数。
    // 现在至少会计数 + 打日志（真正的 error boundary 需 effect 层支持
    // error sink，属后续工作）。本测试锁住"不再静默"这条不变量。
    const ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const parent = try core.box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 } }, .{});
    ctx.root = parent;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const visible = try scope.createSignal(bool, false);

    control_flow_suppress_error_log = true;
    defer control_flow_suppress_error_log = false;
    const before = control_flow_error_count;
    try Show(scope, parent, visible, ctx, struct {
        fn build(_: *Scope, _: *Cx) anyerror!*Node {
            return error.OutOfMemory; // 模拟构建失败
        }
    }.build);

    // 翻开条件 → effect 触发 build → 必然失败。
    visible.set(true);

    // 关键断言：失败被**记录**了（而不是静默 return）。
    try std.testing.expect(control_flow_error_count > before);
    // 且没有半截子树被挂上去。
    try std.testing.expectEqual(@as(usize, 0), parent.children.items.len);
}

// 回归：Show/For/Switch 拆除子树必须走 cx.freeNode，而不是 node.destroy。
//
// node.destroy 只释放 Node 本身，不回收 ElementTable slot ——
// world.destroyElement 唯一的调用点在 Cx.freeNode 里。修复前每次 Show
// 切换都漏一个 element slot（外加 interaction / dirty_set / content /
// paint_state / layout_output 五张镜像表的残留行）。ElementTable index
// 是 u24，长期跑列表型应用最终会 error.ElementTableFull。
test "regression: Show 反复切换不泄漏 ElementTable slot" {
    const allocator = std.testing.allocator;
    var ctx = try Cx.init(allocator);
    defer ctx.deinit();

    const parent = try Node.create(allocator, ctx.nextId(), .box, .{ .width = .{ .px = 200 }, .height = .{ .px = 200 } });
    ctx.linkNodeToWorld(parent);
    ctx.root = parent;

    const root_scope = try Scope.init(allocator, null, ctx.owner);
    defer root_scope.dispose();

    const visible = try root_scope.createSignal(bool, false);

    try Show(root_scope, parent, visible, ctx, struct {
        fn build(_: *Scope, c: *Cx) anyerror!*Node {
            const n = try Node.create(c.allocator, c.nextId(), .box, .{
                .width = .{ .px = 100 },
                .height = .{ .px = 50 },
            });
            c.linkNodeToWorld(n);
            return n;
        }
    }.build);

    // 先切一轮，让稳定态的 element 数量落定（首次 mount 会新建 slot）。
    visible.set(true);
    visible.set(false);
    const baseline = ctx.world.elements.count();

    // 再切 50 轮：若 slot 未回收，count 会线性增长 50。
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        visible.set(true);
        visible.set(false);
    }

    try std.testing.expectEqual(baseline, ctx.world.elements.count());
}

// ----- OOM 不变式：For keyed reconcile -----
//
// batch1 把 For 的 keyed reconcile 里 old_map.put / reused.put /
// new_entries.append / appendForEntry 的 `catch {}` / `catch return` 全部
// 改成了 @panic（漏标 reused → 步骤 3 会 dispose/free 一个仍挂在
// new_entries 里的节点 = 悬垂指针 / double free）。
//
// @panic 无法在进程内捕获。实测确认：只要 FailingAllocator 打中 reconcile
// 内任一分配点，进程直接 abort（signal 6，panic 文案
// "OOM: For keyed reconcile old_map.put"）。而 For 的首次挂载本身就是走
// reconcile effect 完成的（栈：effect.runImpl → update → old_map.put），
// 所以**无法**构造「挂载成功、随后 reconcile 才遇 OOM」的进程内场景 ——
// 任何打中 reconcile 的 fail_index 都会在挂载阶段就 abort。
//
// 因此这里不做 fail_index 遍历（那只会让测试自杀），而是用**充足内存**
// 跑一遍混合 keyed diff，锁住那些 @panic 所保护的可观测后果：
// 复用 / 重建 / 新建 / 删除 四种分支同时发生后，parent 子节点必须与
// items 一一对应 —— 少了说明漏标 reused 导致旧节点被误销毁（悬垂），
// 多了说明同 key 被重复创建。double free / 泄漏则由 GPA 在 deinit 处暴露。
//
// 反向验证（已实测）：把复用分支的 `reused.put(...)` 整行删掉（模拟漏标），
// 本测试在「id=1 必须是同一个 Node 对象」那条断言上 abort —— 因为漏标导致
// 仍在使用的节点被步骤 3 销毁。变异可编译，是真红不是编译错。
// 注意充足内存下 `catch {}` 与 `@panic` 行为相同（那行永不失败），所以
// 能让本测试变红的是漏标本身，而这正是那些 @panic 要防的后果。
// 「OOM 时必 panic 而非静默错乱」那一面，由上述 abort 实测直接证实。
test "For keyed reconcile: 复用/重建/新建/删除混合后子节点与 items 一一对应" {
    const Item = struct { id: u64, value: i32 };
    const allocator = std.testing.allocator;

    const ctx = try Cx.init(allocator);
    defer ctx.deinit();

    const parent = try Node.create(allocator, ctx.nextId(), .box, .{
        .width = .{ .px = 300 },
        .height = .{ .px = 400 },
    });
    ctx.linkNodeToWorld(parent);
    ctx.root = parent;

    const root_scope = try Scope.init(allocator, null, ctx.owner);
    defer root_scope.dispose();

    const initial = [_]Item{
        .{ .id = 1, .value = 10 },
        .{ .id = 2, .value = 20 },
        .{ .id = 3, .value = 30 },
    };
    const items = try root_scope.createSignal([]const Item, &initial);

    try For(Item, root_scope, parent, items, ctx, .{
        .key_fn = struct {
            fn key(it: Item) u64 {
                return it.id;
            }
        }.key,
        .render_fn = struct {
            fn render(_: *Scope, c: *Cx, _: Item, _: usize) anyerror!*Node {
                const n = try Node.create(c.allocator, c.nextId(), .box, .{
                    .width = .{ .grow = .{} },
                    .height = .{ .px = 30 },
                });
                c.linkNodeToWorld(n);
                return n;
            }
        }.render,
    });
    try std.testing.expectEqual(initial.len, parent.children.items.len);

    // 记下 id=1 的节点指针：它必须被**原样复用**（不是销毁重建）。
    const reused_node_before = parent.children.items[0];

    // 混合四种分支：复用 id=1 / key 命中但 props 变而重建 id=3 /
    // 新 key 新建 id=4 / id=2 消失被删除。
    // 一次 update 同时踩到 reused.put 的两个分支 + appendForEntry 两个分支。
    const updated = [_]Item{
        .{ .id = 1, .value = 10 }, // 完全相同 → 复用
        .{ .id = 3, .value = 999 }, // key 命中但 props 变 → 销毁重建
        .{ .id = 4, .value = 40 }, // 新 key → 新建
    };
    items.set(&updated);

    // 少于 3 = 漏标 reused 导致仍在用的节点被销毁；多于 3 = 同 key 重复创建。
    try std.testing.expectEqual(updated.len, parent.children.items.len);
    // id=1 必须是同一个 Node 对象（真复用，而非销毁后重建的新节点）。
    try std.testing.expectEqual(reused_node_before, parent.children.items[0]);

    // 再删到只剩一个，确认删除路径也不多杀/少杀。
    const shrunk = [_]Item{.{ .id = 4, .value = 40 }};
    items.set(&shrunk);
    try std.testing.expectEqual(shrunk.len, parent.children.items.len);

    // 全清空：所有节点都必须被回收（泄漏会由 GPA 在 ctx.deinit 处报出来）。
    const empty: []const Item = &.{};
    items.set(empty);
    try std.testing.expectEqual(@as(usize, 0), parent.children.items.len);
}

test "For keyed reconcile: duplicate keys never alias node or scope ownership" {
    const Item = struct { id: u64, value: i32 };
    const allocator = std.testing.allocator;

    const ctx = try Cx.init(allocator);
    defer ctx.deinit();

    const parent = try Node.create(allocator, ctx.nextId(), .box, .{
        .width = .{ .px = 300 },
        .height = .{ .px = 200 },
    });
    ctx.linkNodeToWorld(parent);
    ctx.root = parent;

    const root_scope = try Scope.init(allocator, null, ctx.owner);
    defer root_scope.dispose();

    const duplicate = [_]Item{
        .{ .id = 7, .value = 70 },
        .{ .id = 7, .value = 70 },
    };
    const items = try root_scope.createSignal([]const Item, &duplicate);

    try For(Item, root_scope, parent, items, ctx, .{
        .key_fn = struct {
            fn key(it: Item) u64 {
                return it.id;
            }
        }.key,
        .render_fn = struct {
            fn render(_: *Scope, c: *Cx, _: Item, _: usize) anyerror!*Node {
                const n = try Node.create(c.allocator, c.nextId(), .box, .{
                    .width = .{ .grow = .{} },
                    .height = .{ .px = 30 },
                });
                c.linkNodeToWorld(n);
                return n;
            }
        }.render,
    });

    try std.testing.expectEqual(@as(usize, 2), parent.children.items.len);
    try std.testing.expect(parent.children.items[0] != parent.children.items[1]);

    // Exercise duplicate -> duplicate -> single -> empty. The old algorithm
    // first inserted one node twice, then freed it through the other entry.
    const duplicate_changed = [_]Item{
        .{ .id = 7, .value = 71 },
        .{ .id = 7, .value = 71 },
    };
    items.set(&duplicate_changed);
    try std.testing.expectEqual(@as(usize, 2), parent.children.items.len);
    try std.testing.expect(parent.children.items[0] != parent.children.items[1]);

    const single = [_]Item{.{ .id = 7, .value = 70 }};
    items.set(&single);
    try std.testing.expectEqual(@as(usize, 1), parent.children.items.len);

    const empty: []const Item = &.{};
    items.set(empty);
    try std.testing.expectEqual(@as(usize, 0), parent.children.items.len);
}

// ----- 挂载失败路径：必须按正常卸载顺序回收 -----
//
// 失败回滚原先是两个 defer：node.destroy 先跑、child_scope.dispose 后跑。
// 于是 (1) scope cleanup 看到的是已释放节点；(2) Node.destroy 不回收
// ElementTable slot（destroyElement 只在 Cx.freeNode 里）。
// FailingAllocator 的 fail_index 可运行期改写：build 末尾把它设成当前
// alloc_index，让紧随其后的 appendChild / entries 扩容失败，测完再复原。
const MountFailureHarness = struct {
    var failing: ?*std.testing.FailingAllocator = null;
    var order: ?*Order = null;

    const Order = struct {
        node_freed: bool = false,
        cleanup_ran: bool = false,
        cleanup_saw_live_node: bool = false,
    };

    fn armNextAllocFailure() void {
        const fa = failing.?;
        fa.fail_index = fa.alloc_index;
    }

    fn disarm() void {
        failing.?.fail_index = std.math.maxInt(usize);
    }

    fn buildTracked(child_scope: *Scope, c: *Cx) anyerror!*Node {
        const marker = order.?;
        const node = try Node.create(c.allocator, c.nextId(), .box, .{
            .width = .{ .px = 10 },
            .height = .{ .px = 10 },
        });
        c.linkNodeToWorld(node);
        node.meta.ownership.hooks.on_cleanup = Cx.simpleHandler(struct {
            fn freed(raw: *anyopaque) void {
                const o: *Order = @ptrCast(@alignCast(raw));
                o.node_freed = true;
            }
        }.freed, @ptrCast(marker));
        try child_scope.onCleanup(Order, marker, struct {
            fn cleanup(o: *Order) void {
                o.cleanup_ran = true;
                o.cleanup_saw_live_node = !o.node_freed;
            }
        }.cleanup);
        armNextAllocFailure();
        return node;
    }
};

test "Show: appendChild 失败时按卸载顺序回收（scope 先于节点、回收 element slot）" {
    var fa = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const allocator = fa.allocator();
    const ctx = try Cx.init(allocator);
    defer ctx.deinit();

    const parent = try Node.create(allocator, ctx.nextId(), .box, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 } });
    ctx.linkNodeToWorld(parent);
    ctx.root = parent;

    const root_scope = try Scope.init(allocator, null, ctx.owner);
    defer root_scope.dispose();
    const visible = try root_scope.createSignal(bool, false);

    var order = MountFailureHarness.Order{};
    MountFailureHarness.failing = &fa;
    MountFailureHarness.order = &order;
    defer MountFailureHarness.failing = null;
    defer MountFailureHarness.order = null;

    try Show(root_scope, parent, visible, ctx, MountFailureHarness.buildTracked);
    const baseline = ctx.world.elements.count();

    control_flow_suppress_error_log = true;
    defer control_flow_suppress_error_log = false;
    const errors_before = control_flow_error_count;
    visible.set(true);
    MountFailureHarness.disarm();

    try std.testing.expect(control_flow_error_count > errors_before);
    try std.testing.expectEqual(@as(usize, 0), parent.children.items.len);
    try std.testing.expect(order.cleanup_ran);
    try std.testing.expect(order.cleanup_saw_live_node);
    try std.testing.expect(order.node_freed);
    try std.testing.expectEqual(baseline, ctx.world.elements.count());
}

test "For: 首次挂载 entries/appendChild 失败不泄漏节点、不留半截子树" {
    const Item = struct { id: u64 };
    var fa = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const allocator = fa.allocator();
    const ctx = try Cx.init(allocator);
    defer ctx.deinit();

    const parent = try Node.create(allocator, ctx.nextId(), .box, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 } });
    ctx.linkNodeToWorld(parent);
    ctx.root = parent;

    const root_scope = try Scope.init(allocator, null, ctx.owner);
    defer root_scope.dispose();
    const items_storage = [_]Item{ .{ .id = 1 }, .{ .id = 2 } };
    const items = try root_scope.createSignal([]const Item, &items_storage);

    var order = MountFailureHarness.Order{};
    MountFailureHarness.failing = &fa;
    MountFailureHarness.order = &order;
    defer MountFailureHarness.failing = null;
    defer MountFailureHarness.order = null;
    const baseline = ctx.world.elements.count();

    const result = For(Item, root_scope, parent, items, ctx, .{
        .key_fn = struct {
            fn k(item: Item) u64 {
                return item.id;
            }
        }.k,
        .render_fn = struct {
            fn r(child_scope: *Scope, c: *Cx, _: Item, _: usize) anyerror!*Node {
                return MountFailureHarness.buildTracked(child_scope, c);
            }
        }.r,
    });
    MountFailureHarness.disarm();

    try std.testing.expectError(error.OutOfMemory, result);
    try std.testing.expectEqual(@as(usize, 0), parent.children.items.len);
    try std.testing.expect(order.cleanup_saw_live_node);
    try std.testing.expect(order.node_freed);
    try std.testing.expectEqual(baseline, ctx.world.elements.count());
}

// ----- For 与同 parent 兄弟共存 -----
//
// For 的 effect 每次（含首次）都 replaceChildOrder(parent, 仅 For 条目)，
// 而 replaceChildOrder 会摘掉不在列表里的所有子节点 —— 同一 parent 下的
// 标题 / Show 节点被静默摘下成孤儿（不渲染 + 永不释放）。
test "For: 与同 parent 的前后兄弟共存，增删重排都不摘兄弟" {
    const Item = struct { id: u64 };
    const allocator = std.testing.allocator;
    const ctx = try Cx.init(allocator);
    defer ctx.deinit();

    const parent = try Node.create(allocator, ctx.nextId(), .box, .{ .width = .{ .px = 100 }, .height = .{ .px = 300 } });
    ctx.linkNodeToWorld(parent);
    ctx.root = parent;

    const header = try Node.create(allocator, ctx.nextId(), .box, .{ .width = .{ .px = 10 }, .height = .{ .px = 10 } });
    ctx.linkNodeToWorld(header);
    try parent.appendChild(allocator, header);

    const root_scope = try Scope.init(allocator, null, ctx.owner);
    defer root_scope.dispose();
    const initial = [_]Item{ .{ .id = 1 }, .{ .id = 2 } };
    const items = try root_scope.createSignal([]const Item, &initial);

    try For(Item, root_scope, parent, items, ctx, .{
        .key_fn = struct {
            fn k(item: Item) u64 {
                return item.id;
            }
        }.k,
        .render_fn = struct {
            fn r(_: *Scope, c: *Cx, item: Item, _: usize) anyerror!*Node {
                const n = try Node.create(c.allocator, c.nextId(), .box, .{ .width = .{ .px = 10 }, .height = .{ .px = 10 } });
                c.linkNodeToWorld(n);
                n.meta.ownership.meta.component_name = switch (item.id) {
                    1 => "i1",
                    2 => "i2",
                    3 => "i3",
                    else => "i?",
                };
                return n;
            }
        }.r,
    });

    try std.testing.expectEqual(@as(usize, 3), parent.children.items.len);
    try std.testing.expectEqual(header, parent.children.items[0]);
    try std.testing.expectEqual(parent, header.parent.?);

    // For 之后再挂一个兄弟
    const footer = try Node.create(allocator, ctx.nextId(), .box, .{ .width = .{ .px = 10 }, .height = .{ .px = 10 } });
    ctx.linkNodeToWorld(footer);
    try parent.appendChild(allocator, footer);

    const Expect = struct {
        fn names(p: *Node, h: *Node, f: *Node, comptime want: []const []const u8) !void {
            try std.testing.expectEqual(want.len + 2, p.children.items.len);
            try std.testing.expectEqual(h, p.children.items[0]);
            try std.testing.expectEqual(f, p.children.items[p.children.items.len - 1]);
            inline for (want, 0..) |w, i| {
                try std.testing.expectEqualStrings(w, p.children.items[i + 1].meta.ownership.meta.component_name.?);
            }
        }
    };

    // 插入
    const inserted = [_]Item{ .{ .id = 1 }, .{ .id = 3 }, .{ .id = 2 } };
    items.set(&inserted);
    try Expect.names(parent, header, footer, &.{ "i1", "i3", "i2" });
    // 重排
    const reordered = [_]Item{ .{ .id = 2 }, .{ .id = 1 }, .{ .id = 3 } };
    items.set(&reordered);
    try Expect.names(parent, header, footer, &.{ "i2", "i1", "i3" });
    // 删除
    const removed = [_]Item{.{ .id = 3 }};
    items.set(&removed);
    try Expect.names(parent, header, footer, &.{"i3"});
    // 清空再恢复：段位置必须记住（列表为空时没有可参照的 For 节点）
    const empty: []const Item = &.{};
    items.set(empty);
    try Expect.names(parent, header, footer, &.{});
    items.set(&initial);
    try Expect.names(parent, header, footer, &.{ "i1", "i2" });
}

// 步骤 2/3 已释放旧节点后，重排若 OOM，原实现 `catch return` 跳过了
// entries 替换：s.entries 留着已释放节点（下次 diff 再 free = double free），
// new_entries 与新建节点整批泄漏。
// 触发方式：key 相同但 props 变化 → 步骤 2 释放旧节点并调 render 重建；
// render 末尾武装 FailingAllocator，让随后的重排分配失败。（被删条目的
// scope/node cleanup 在 reactive 回调内会延迟到 effect 之后，不能用来武装。）
// new_entries 初始容量 ≥ 2（cache_line / @sizeOf(ItemEntry)），重建条目的
// append 不再分配，失败必然落在重排上 —— 下面断言错误计数确认打中了。
test "For: 旧节点已释放后重排 OOM 不留悬垂 entries、不泄漏" {
    const Item = struct { id: u64, v: u32 };
    const H = struct {
        var failing: ?*std.testing.FailingAllocator = null;
        var arm_on_render = false;
    };
    var fa = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const allocator = fa.allocator();
    H.failing = &fa;
    defer H.failing = null;
    const ctx = try Cx.init(allocator);
    defer ctx.deinit();

    const parent = try Node.create(allocator, ctx.nextId(), .box, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 } });
    ctx.linkNodeToWorld(parent);
    ctx.root = parent;

    const root_scope = try Scope.init(allocator, null, ctx.owner);
    defer root_scope.dispose();
    const initial = [_]Item{ .{ .id = 1, .v = 0 }, .{ .id = 2, .v = 0 } };
    const items = try root_scope.createSignal([]const Item, &initial);

    try For(Item, root_scope, parent, items, ctx, .{
        .key_fn = struct {
            fn k(item: Item) u64 {
                return item.id;
            }
        }.k,
        .render_fn = struct {
            fn r(_: *Scope, c: *Cx, _: Item, _: usize) anyerror!*Node {
                const n = try Node.create(c.allocator, c.nextId(), .box, .{ .width = .{ .px = 10 }, .height = .{ .px = 10 } });
                c.linkNodeToWorld(n);
                if (H.arm_on_render) {
                    const f = H.failing.?;
                    f.fail_index = f.alloc_index;
                }
                return n;
            }
        }.r,
    });
    try std.testing.expectEqual(@as(usize, 2), parent.children.items.len);

    control_flow_suppress_error_log = true;
    defer control_flow_suppress_error_log = false;
    const errors_before = control_flow_error_count;
    H.arm_on_render = true;
    const changed = [_]Item{ .{ .id = 1, .v = 0 }, .{ .id = 2, .v = 1 } };
    items.set(&changed);
    H.arm_on_render = false;
    fa.fail_index = std.math.maxInt(usize);
    // 确认确实打中了重排失败分支（否则本测试是假绿）。
    try std.testing.expect(control_flow_error_count > errors_before);

    // 再走几轮 diff：若 entries 残留已释放节点，这里会 double free / UAF；
    // 未上树的新节点归 entries 所有，下一轮 diff 要能把它挂回去。
    const empty: []const Item = &.{};
    items.set(empty);
    try std.testing.expectEqual(@as(usize, 0), parent.children.items.len);
    items.set(&initial);
    try std.testing.expectEqual(@as(usize, 2), parent.children.items.len);
}

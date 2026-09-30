//! ElementTable — Phase 3 拆 Node 的逻辑树存储（SoA）
//!
//! 当前 Node 是 107 字段 god-object，把"逻辑树 / 布局 / 渲染缓存 / 命中 / 焦点"
//! 全混在一起。这里只存"逻辑树"——即 React Element / Flutter Widget 等价物：
//! tag、parent、children 链表、组件归属、key（用于 reconcile）。
//!
//! 设计要点：
//! - **MultiArrayList**：字段拆分独立连续数组，cache-line 友好；脏帧只扫需要的字段
//! - **ElementId 生成式 handle**：跨帧持有不挂（generation 防 ABA）
//! - **链表式子树**：parent + first_child + next_sibling，不持 std.ArrayList(Children)
//!   —— 增删 O(1)，遍历 O(n)；规避了 children 数组扩容的内存抖动
//! - **owner_component**：哪个组件实例创建了我（用于 reconcile / dispose）
//!
//! 历史债避免：
//! - cc::Layer 教训：不在此表上塞布局 / 渲染 / 交互字段（那些去 LayoutTable / PaintTable / InteractionTable）
//! - 不持有 *Node 类型指针 —— 一切用 ElementId 索引

const std = @import("std");
const testing = std.testing;
const element_id = @import("element_id.zig");

pub const ElementId = element_id.ElementId;
// re-export SlotMap 让 bench 不必独立 import element_id 引发冲突
pub const SlotMap = element_id.SlotMap;

/// 元素的"标签"——用于 reconcile diff 时快速判断是否同类。
/// 暂时只覆盖几大类，后续可扩。
pub const ElementTag = enum(u16) {
    /// 容器：div / box / vstack / hstack / scroll_area
    container,
    /// 文本节点
    text,
    /// 图像 / icon / svg
    image,
    /// 输入控件根
    input,
    /// 自定义组件根（owner_component != NULL）
    component,
    /// 占位（用于 reconcile 临时填充）
    placeholder,
    /// 调试 / 测试用
    debug,
};

/// 子树连接——单链表 first_child + next_sibling，避免 children 数组动态扩容。
pub const ElementLinks = struct {
    parent: ElementId = ElementId.NULL,
    first_child: ElementId = ElementId.NULL,
    last_child: ElementId = ElementId.NULL,
    next_sibling: ElementId = ElementId.NULL,
    prev_sibling: ElementId = ElementId.NULL,
};

/// SoA 字段集合——MultiArrayList 接受 struct 类型，每字段独立数组。
pub const Element = struct {
    tag: ElementTag,
    /// 用于 reconcile：同 parent 下 (tag, key) 唯一标识；NULL key 走顺序匹配。
    key: u64,
    /// 创建此 element 的组件实例 id（NULL = 非组件创建）
    owner_component: ElementId = ElementId.NULL,
    /// 子树链
    links: ElementLinks = .{},
    /// 用户标记位（debug name index 或 source location）
    user_tag: u32 = 0,
};

pub const ElementTable = struct {
    allocator: std.mem.Allocator,
    /// SoA 存储；MultiArrayList 提供 .items(.field_name) 取每字段独立数组。
    elements: std.MultiArrayList(Element),
    /// generation per slot
    generations: std.ArrayListUnmanaged(u8),
    /// free list（slot index）
    free_list: std.ArrayListUnmanaged(u24),
    /// Retired slots remain allocated but are not live elements.
    live_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator) ElementTable {
        return .{
            .allocator = allocator,
            .elements = .{},
            .generations = .{},
            .free_list = .{},
        };
    }

    pub fn deinit(self: *ElementTable) void {
        self.elements.deinit(self.allocator);
        self.generations.deinit(self.allocator);
        self.free_list.deinit(self.allocator);
        self.* = undefined;
    }

    /// 创建新 element，返回 ElementId。
    ///
    /// 世代退役（防 ABA）：generation 偶数表示 live，奇数表示 dead。
    /// generation 一旦回卷，陈旧 id 会重新生效。对齐
    /// element_id.SlotMap 的策略：generation 推进到 MAX_GEN 的 slot 永久
    /// 退役（不再分配也不入 free_list）。create/destroy 两侧各推进一次，
    /// 任一侧落到 MAX_GEN 都退役——否则 create 侧推到 255 后 destroy 的
    /// `+%=` 仍会回卷到 0。MAX_GEN 同时是 NULL 的 generation，正常 id
    /// 永不携带它。slot 预算：每 slot ~128 个生命周期，16M slot 总计
    /// ~10⁹ 次 destroy，耗尽落在 error.ElementTableFull 而非 UB。
    pub fn create(self: *ElementTable, e: Element) !ElementId {
        while (self.free_list.pop()) |idx| {
            const next_gen = self.generations.items[idx] +% 1;
            if (next_gen == element_id.MAX_GEN) {
                // 退役：钉在 MAX_GEN（≠ 任何已发出的 id），slot 不再复用
                self.generations.items[idx] = element_id.MAX_GEN;
                continue;
            }
            self.elements.set(idx, e);
            self.generations.items[idx] = next_gen;
            self.live_count += 1;
            return .{ .index = idx, .generation = next_gen };
        }
        const idx = self.elements.len;
        if (idx >= element_id.MAX_INDEX) return error.ElementTableFull;
        // Reserve all parallel storage before publishing a slot. Reserving a
        // free-list entry for every slot makes destruction allocation-free,
        // including rollback while the allocator is still failing.
        try self.elements.ensureTotalCapacity(self.allocator, idx + 1);
        try self.generations.ensureTotalCapacity(self.allocator, idx + 1);
        try self.free_list.ensureTotalCapacity(self.allocator, idx + 1);
        self.elements.appendAssumeCapacity(e);
        self.generations.appendAssumeCapacity(0);
        self.live_count += 1;
        return .{ .index = @intCast(idx), .generation = 0 };
    }

    /// 销毁 element：从父链表中摘除，generation++ 防 ABA，slot 回 free list。
    /// 子树由调用方自行递归销毁（这里不做以避免无意识级联）。
    pub fn destroy(self: *ElementTable, id: ElementId) void {
        if (!self.isValid(id)) return;
        // 从父子链表中摘除
        self.unlink(id);
        self.live_count -= 1;
        self.generations.items[id.index] +%= 1;
        // 世代退役：推进到 MAX_GEN 的 slot 不回 free_list（见 create 注释）
        if (self.generations.items[id.index] == element_id.MAX_GEN) return;
        self.free_list.appendAssumeCapacity(id.index);
    }

    pub fn isValid(self: *const ElementTable, id: ElementId) bool {
        if (id.isNull()) return false;
        // Fresh/live generations are even; destroy makes them odd. Reject
        // handles reconstructed from a dead slot's current generation too.
        if (id.generation & 1 != 0) return false;
        if (id.index >= self.elements.len) return false;
        return self.generations.items[id.index] == id.generation;
    }

    /// 读取整 Element 副本
    pub fn get(self: *const ElementTable, id: ElementId) ?Element {
        if (!self.isValid(id)) return null;
        return self.elements.get(id.index);
    }

    /// 读取 tag（频繁调用 —— 直接走 SoA）
    pub fn tag(self: *const ElementTable, id: ElementId) ?ElementTag {
        if (!self.isValid(id)) return null;
        return self.elements.items(.tag)[id.index];
    }

    /// 读取 links（频繁，遍历用）
    pub fn links(self: *const ElementTable, id: ElementId) ?ElementLinks {
        if (!self.isValid(id)) return null;
        return self.elements.items(.links)[id.index];
    }

    fn linksMut(self: *ElementTable, id: ElementId) *ElementLinks {
        return &self.elements.items(.links)[id.index];
    }

    // --- 树操作 ---

    /// 把 child 追加到 parent 的 last_child 后。child 必须未链入任何父。
    pub fn appendChild(self: *ElementTable, parent: ElementId, child: ElementId) void {
        if (!self.isValid(parent) or !self.isValid(child)) return;
        const child_links = self.linksMut(child);
        std.debug.assert(child_links.parent.isNull()); // 不允许 reparent without unlink
        child_links.parent = parent;
        child_links.next_sibling = ElementId.NULL;

        const parent_links = self.linksMut(parent);
        if (parent_links.first_child.isNull()) {
            parent_links.first_child = child;
            parent_links.last_child = child;
            child_links.prev_sibling = ElementId.NULL;
        } else {
            const last = parent_links.last_child;
            child_links.prev_sibling = last;
            self.linksMut(last).next_sibling = child;
            parent_links.last_child = child;
        }
    }

    /// 把 child 从父链中摘除（不销毁 element）
    ///
    /// parent/prev/next 都必须经 isValid 校验：先销毁父再销毁子时，
    /// 子持有的 parent id 已失效（slot 可能被新元素复用），裸 linksMut
    /// 会把 first_child/last_child 写穿到复用后的新元素上（链表静默损坏）。
    /// 对照 appendChild 的双侧校验——unlink 此前缺对称防护。
    pub fn unlink(self: *ElementTable, id: ElementId) void {
        if (!self.isValid(id)) return;
        const my_links = self.linksMut(id);
        if (my_links.parent.isNull()) return; // 已经游离

        const prev = my_links.prev_sibling;
        const next = my_links.next_sibling;
        const parent = my_links.parent;

        if (!prev.isNull()) {
            if (self.isValid(prev)) self.linksMut(prev).next_sibling = next;
        } else if (self.isValid(parent)) {
            // 我是 first_child
            self.linksMut(parent).first_child = next;
        }
        if (!next.isNull()) {
            if (self.isValid(next)) self.linksMut(next).prev_sibling = prev;
        } else if (self.isValid(parent)) {
            // 我是 last_child
            self.linksMut(parent).last_child = prev;
        }

        my_links.parent = ElementId.NULL;
        my_links.prev_sibling = ElementId.NULL;
        my_links.next_sibling = ElementId.NULL;
    }

    /// 子节点遍历 helper
    pub const ChildIterator = struct {
        table: *const ElementTable,
        next_id: ElementId,

        pub fn next(self: *ChildIterator) ?ElementId {
            if (self.next_id.isNull()) return null;
            const cur = self.next_id;
            const lk = self.table.links(cur) orelse return null;
            self.next_id = lk.next_sibling;
            return cur;
        }
    };

    pub fn children(self: *const ElementTable, parent: ElementId) ChildIterator {
        const lk = self.links(parent) orelse return .{ .table = self, .next_id = ElementId.NULL };
        return .{ .table = self, .next_id = lk.first_child };
    }

    pub fn count(self: *const ElementTable) usize {
        return self.live_count;
    }

    /// 统计某 parent 的子节点数（O(n)）
    pub fn childCount(self: *const ElementTable, parent: ElementId) u32 {
        var iter = self.children(parent);
        var n: u32 = 0;
        while (iter.next() != null) n += 1;
        return n;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "ElementTable: create/get/destroy" {
    var t = ElementTable.init(testing.allocator);
    defer t.deinit();

    const id = try t.create(.{ .tag = .container, .key = 42 });
    const e = t.get(id).?;
    try testing.expectEqual(ElementTag.container, e.tag);
    try testing.expectEqual(@as(u64, 42), e.key);

    t.destroy(id);
    try testing.expect(t.get(id) == null);
    try testing.expect(!t.isValid(id));
}

test "ElementTable: appendChild builds linked list" {
    var t = ElementTable.init(testing.allocator);
    defer t.deinit();

    const root = try t.create(.{ .tag = .container, .key = 0 });
    const c1 = try t.create(.{ .tag = .text, .key = 1 });
    const c2 = try t.create(.{ .tag = .text, .key = 2 });
    const c3 = try t.create(.{ .tag = .text, .key = 3 });

    t.appendChild(root, c1);
    t.appendChild(root, c2);
    t.appendChild(root, c3);

    try testing.expectEqual(@as(u32, 3), t.childCount(root));

    var iter = t.children(root);
    const ids = [_]ElementId{ c1, c2, c3 };
    var i: usize = 0;
    while (iter.next()) |got| {
        try testing.expect(got.eql(ids[i]));
        i += 1;
    }
    try testing.expectEqual(@as(usize, 3), i);
}

test "ElementTable: unlink middle child" {
    var t = ElementTable.init(testing.allocator);
    defer t.deinit();

    const root = try t.create(.{ .tag = .container, .key = 0 });
    const c1 = try t.create(.{ .tag = .text, .key = 1 });
    const c2 = try t.create(.{ .tag = .text, .key = 2 });
    const c3 = try t.create(.{ .tag = .text, .key = 3 });

    t.appendChild(root, c1);
    t.appendChild(root, c2);
    t.appendChild(root, c3);

    t.unlink(c2);
    try testing.expectEqual(@as(u32, 2), t.childCount(root));

    // 顺序应是 c1 → c3
    var iter = t.children(root);
    try testing.expect(iter.next().?.eql(c1));
    try testing.expect(iter.next().?.eql(c3));
    try testing.expect(iter.next() == null);

    // c2 已游离
    const c2_links = t.links(c2).?;
    try testing.expect(c2_links.parent.isNull());
    try testing.expect(c2_links.prev_sibling.isNull());
    try testing.expect(c2_links.next_sibling.isNull());
}

test "ElementTable: unlink first child updates first_child" {
    var t = ElementTable.init(testing.allocator);
    defer t.deinit();

    const root = try t.create(.{ .tag = .container, .key = 0 });
    const c1 = try t.create(.{ .tag = .text, .key = 1 });
    const c2 = try t.create(.{ .tag = .text, .key = 2 });

    t.appendChild(root, c1);
    t.appendChild(root, c2);

    t.unlink(c1);
    const root_links = t.links(root).?;
    try testing.expect(root_links.first_child.eql(c2));
    try testing.expect(root_links.last_child.eql(c2));
}

test "ElementTable: unlink last child updates last_child" {
    var t = ElementTable.init(testing.allocator);
    defer t.deinit();

    const root = try t.create(.{ .tag = .container, .key = 0 });
    const c1 = try t.create(.{ .tag = .text, .key = 1 });
    const c2 = try t.create(.{ .tag = .text, .key = 2 });

    t.appendChild(root, c1);
    t.appendChild(root, c2);

    t.unlink(c2);
    const root_links = t.links(root).?;
    try testing.expect(root_links.first_child.eql(c1));
    try testing.expect(root_links.last_child.eql(c1));
}

test "ElementTable: destroy auto-unlinks" {
    var t = ElementTable.init(testing.allocator);
    defer t.deinit();

    const root = try t.create(.{ .tag = .container, .key = 0 });
    const c1 = try t.create(.{ .tag = .text, .key = 1 });
    t.appendChild(root, c1);

    t.destroy(c1);
    const root_links = t.links(root).?;
    try testing.expect(root_links.first_child.isNull());
    try testing.expect(root_links.last_child.isNull());
}

test "ElementTable: free list reuses slots, generation differs" {
    var t = ElementTable.init(testing.allocator);
    defer t.deinit();

    const a = try t.create(.{ .tag = .text, .key = 1 });
    const idx_a = a.index;
    t.destroy(a);

    const b = try t.create(.{ .tag = .text, .key = 2 });
    try testing.expectEqual(idx_a, b.index);
    try testing.expect(a.generation != b.generation);
    try testing.expect(!t.isValid(a));
    try testing.expect(t.isValid(b));
}

test "ElementTable: SoA tag access" {
    var t = ElementTable.init(testing.allocator);
    defer t.deinit();

    const a = try t.create(.{ .tag = .container, .key = 0 });
    const b = try t.create(.{ .tag = .text, .key = 1 });
    try testing.expectEqual(ElementTag.container, t.tag(a).?);
    try testing.expectEqual(ElementTag.text, t.tag(b).?);
}

test "ElementTable: count tracks live elements" {
    var t = ElementTable.init(testing.allocator);
    defer t.deinit();

    const a = try t.create(.{ .tag = .text, .key = 0 });
    _ = try t.create(.{ .tag = .text, .key = 1 });
    _ = try t.create(.{ .tag = .text, .key = 2 });
    try testing.expectEqual(@as(usize, 3), t.count());

    t.destroy(a);
    try testing.expectEqual(@as(usize, 2), t.count());
}

test "ElementTable: 世代回卷前 slot 永久退役（ABA 防线）" {
    var t = ElementTable.init(testing.allocator);
    defer t.deinit();

    // 单 slot 反复 create/destroy：每周期 generation +2（create 复用 +1、destroy +1）。
    // 旧实现 +%= 回卷后第 256 次复用会让最早的 id 重新 isValid（ABA）。
    const first = try t.create(.{ .tag = .container, .key = 0 });
    t.destroy(first);

    var cycles: u32 = 0;
    while (cycles < 200) : (cycles += 1) {
        const id = t.create(.{ .tag = .container, .key = 1 }) catch break;
        // 一旦 slot 退役，create 会走 fresh-append 分配新 index
        if (id.index != first.index) break;
        try testing.expect(!t.isValid(first)); // 陈旧 id 任何时刻不得复活
        t.destroy(id);
    }
    // 循环要么因 slot 退役换了 index 而 break（正确），要么跑满 200 周期
    // ——200*2 > 255，旧实现必然已回卷，上面的 isValid 断言必然已抓到
    try testing.expect(cycles < 200);
    try testing.expect(!t.isValid(first));
}

test "ElementTable: 先销毁父再销毁子不得写穿复用 slot" {
    var t = ElementTable.init(testing.allocator);
    defer t.deinit();

    const parent = try t.create(.{ .tag = .container, .key = 0 });
    const child = try t.create(.{ .tag = .text, .key = 1 });
    t.appendChild(parent, child);

    // 违反常规顺序：先销毁父（destroy 会 unlink 自己但 child.links.parent 仍指旧 slot）
    // 注意 destroy(parent) 只摘 parent 自己，不递归——child 的 parent 引用悬空
    t.destroy(parent);

    // parent slot 被新元素复用，且新元素挂了自己的孩子——
    // 链表字段非 NULL，写穿才可观测（NULL 盖 NULL 测不出来）
    const reused = try t.create(.{ .tag = .container, .key = 2 });
    try testing.expectEqual(parent.index, reused.index);
    const grandchild = try t.create(.{ .tag = .text, .key = 3 });
    t.appendChild(reused, grandchild);
    const reused_links_before = t.links(reused).?;
    try testing.expect(!reused_links_before.first_child.isNull());

    // 销毁 child：unlink 拿着失效的 parent id（prev/next 均 NULL → 走
    // first_child/last_child 分支），不得把 reused 的链表字段清成 NULL
    t.destroy(child);
    const reused_links_after = t.links(reused).?;
    try testing.expectEqual(reused_links_before.first_child.raw(), reused_links_after.first_child.raw());
    try testing.expectEqual(reused_links_before.last_child.raw(), reused_links_after.last_child.raw());
}

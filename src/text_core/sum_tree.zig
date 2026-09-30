/// SumTree — 泛型 B-tree，支持 O(log N) 的随机位置 insert/remove/seek
///
/// 设计参考 Zed 编辑器的 SumTree：
/// - B-Tree 结构保持平衡
/// - 每个节点存储子树的聚合信息（Summary）
/// - 支持按多种维度查找（通过 comptime Dimension）
/// - COW (Copy-on-Write) 快照：节点引用计数，O(1) 快照
///
/// Item 协议: fn summary(self: Item) -> Summary
/// Summary 协议: const ZERO: Summary; fn add(self, other) -> Summary
const std = @import("std");
const Allocator = std.mem.Allocator;
const Atomic = std.atomic.Value;

/// B-Tree 参数
const BRANCHING_FACTOR = 8;
const MIN_CHILDREN = BRANCHING_FACTOR / 4; // 合并阈值
const SPLIT_AT = BRANCHING_FACTOR / 2; // 分裂点

pub fn SumTree(comptime Item: type, comptime Summary: type) type {
    return struct {
        const Self = @This();

        allocator: Allocator,
        root: ?*Node = null,
        item_count: usize = 0,
        transaction_active: bool = false,
        transaction_failed: bool = false,

        // ===== Node 定义 =====

        pub const Node = struct {
            ref_count: Atomic(usize) = Atomic(usize).init(1),
            height: u32 = 0, // 0 = leaf
            data: union(enum) {
                internal: InternalData,
                leaf: LeafData,
            },
        };

        const InternalData = struct {
            children: [BRANCHING_FACTOR]*Node = undefined,
            summaries: [BRANCHING_FACTOR]Summary = undefined,
            len: usize = 0,

            fn totalSummary(self: *const InternalData) Summary {
                var result = Summary.ZERO;
                for (self.summaries[0..self.len]) |s| {
                    result = result.add(s);
                }
                return result;
            }
        };

        const LeafData = struct {
            items: [BRANCHING_FACTOR]Item = undefined,
            len: usize = 0,

            fn totalSummary(self: *const LeafData) Summary {
                var result = Summary.ZERO;
                for (self.items[0..self.len]) |item| {
                    result = result.add(item.summary());
                }
                return result;
            }
        };

        // ===== Node 方法 =====

        fn nodeSummary(node: *const Node) Summary {
            return switch (node.data) {
                .internal => |*n| n.totalSummary(),
                .leaf => |*n| n.totalSummary(),
            };
        }

        fn subtreeCount(node: *const Node) usize {
            return switch (node.data) {
                .internal => |*n| blk: {
                    var total: usize = 0;
                    for (0..n.len) |i| {
                        total += subtreeCount(n.children[i]);
                    }
                    break :blk total;
                },
                .leaf => |*n| n.len,
            };
        }

        fn retain(node: *Node) void {
            _ = node.ref_count.fetchAdd(1, .monotonic);
        }

        fn destroyNode(self: *Self, node: *Node) void {
            switch (node.data) {
                .internal => |*n| {
                    for (n.children[0..n.len]) |child| {
                        self.release(child);
                    }
                },
                .leaf => {},
            }
            self.allocator.destroy(node);
        }

        fn release(self: *Self, node: *Node) void {
            const prev = node.ref_count.fetchSub(1, .acq_rel);
            std.debug.assert(prev > 0);
            if (prev == 1) {
                self.destroyNode(node);
            }
        }

        /// COW: 如果 ref_count > 1，克隆节点（浅拷贝，子节点 retain）
        fn ensureUnique(self: *Self, node: *Node) !*Node {
            if (node.ref_count.load(.acquire) == 1) return node;
            // Clone
            const new_node = try self.allocator.create(Node);
            new_node.* = node.*;
            new_node.ref_count = Atomic(usize).init(1);
            // 对子节点执行 retain（内部节点的子节点现在被两个父节点引用）
            switch (new_node.data) {
                .internal => |*n| {
                    for (n.children[0..n.len]) |child| {
                        retain(child);
                    }
                },
                .leaf => {},
            }
            // 释放旧引用
            const prev = node.ref_count.fetchSub(1, .acq_rel);
            std.debug.assert(prev > 0);
            if (prev == 1) {
                self.destroyNode(node);
            }
            return new_node;
        }

        fn createLeaf(self: *Self) !*Node {
            const node = try self.allocator.create(Node);
            node.* = .{
                .height = 0,
                .data = .{ .leaf = .{} },
            };
            return node;
        }

        fn createInternal(self: *Self, height: u32) !*Node {
            const node = try self.allocator.create(Node);
            node.* = .{
                .height = height,
                .data = .{ .internal = .{} },
            };
            return node;
        }

        // ===== 公共 API =====

        pub fn init(allocator: Allocator) Self {
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            if (self.root) |root| {
                self.release(root);
            }
            self.root = null;
            self.item_count = 0;
        }

        /// Mutations outside a batch have a strong failure guarantee. A batch
        /// shares one COW checkpoint across many mutations, avoiding repeated
        /// root/path cloning in clients such as PieceTree. No nested batches.
        /// Any error requires rollback (deinit), never commit.
        pub const Transaction = struct {
            owner: *Self,
            original: Self,
            active: bool = true,

            pub fn commit(tx: *Transaction) void {
                std.debug.assert(tx.active and !tx.owner.transaction_failed);
                tx.original.deinit();
                tx.owner.transaction_active = false;
                tx.active = false;
            }

            pub fn deinit(tx: *Transaction) void {
                if (!tx.active) return;
                tx.owner.deinit();
                tx.owner.* = tx.original;
                tx.active = false;
            }
        };

        pub fn beginTransaction(self: *Self) Transaction {
            std.debug.assert(!self.transaction_active);
            const original = self.snapshot();
            self.transaction_active = true;
            self.transaction_failed = false;
            return .{ .owner = self, .original = original };
        }

        /// O(1) 获取整棵树的摘要
        pub fn summary(self: *const Self) Summary {
            if (self.root) |root| {
                return nodeSummary(root);
            }
            return Summary.ZERO;
        }

        /// O(1) item 总数
        pub fn count(self: *const Self) usize {
            return self.item_count;
        }

        /// O(log N) 在末尾追加
        pub fn push(self: *Self, item: Item) !void {
            try self.insert(self.item_count, item);
        }

        /// O(log N) 在指定 index 插入 item
        pub fn insert(self: *Self, index: usize, item: Item) !void {
            if (self.transaction_active) {
                std.debug.assert(!self.transaction_failed);
                errdefer self.transaction_failed = true;
                return self.insertInTransaction(index, item);
            }
            var tx = self.beginTransaction();
            defer tx.deinit();
            try self.insertInTransaction(index, item);
            tx.commit();
        }

        fn insertInTransaction(self: *Self, index: usize, item: Item) !void {
            std.debug.assert(index <= self.item_count);

            if (self.root == null) {
                const leaf = try self.createLeaf();
                leaf.data.leaf.items[0] = item;
                leaf.data.leaf.len = 1;
                self.root = leaf;
                self.item_count = 1;
                return;
            }

            self.root = try self.ensureUnique(self.root.?);
            const result = try self.insertInNode(self.root.?, index, item);
            if (result.split) |split_node| {
                // A split node is not owned by the root until attached.
                errdefer self.release(split_node);
                // 根节点分裂
                const new_root = try self.createInternal(self.root.?.height + 1);
                new_root.data.internal.children[0] = self.root.?;
                new_root.data.internal.summaries[0] = nodeSummary(self.root.?);
                new_root.data.internal.children[1] = split_node;
                new_root.data.internal.summaries[1] = nodeSummary(split_node);
                new_root.data.internal.len = 2;
                self.root = new_root;
            }
            self.item_count += 1;
        }

        /// O(log N) 删除指定 index 的 item
        pub fn remove(self: *Self, index: usize) !void {
            if (self.transaction_active) {
                std.debug.assert(!self.transaction_failed);
                errdefer self.transaction_failed = true;
                return self.removeInTransaction(index);
            }
            var tx = self.beginTransaction();
            defer tx.deinit();
            try self.removeInTransaction(index);
            tx.commit();
        }

        fn removeInTransaction(self: *Self, index: usize) !void {
            std.debug.assert(index < self.item_count);
            std.debug.assert(self.root != null);

            self.root = try self.ensureUnique(self.root.?);
            try self.removeInNode(self.root.?, index);
            self.item_count -= 1;

            // 如果根是内部节点且只剩一个子节点，降低树高
            if (self.root) |root| {
                if (root.data == .internal and root.data.internal.len == 1) {
                    const child = root.data.internal.children[0];
                    retain(child);
                    self.release(root);
                    self.root = child;
                }
            }

            // 空树
            if (self.item_count == 0) {
                if (self.root) |root| {
                    self.release(root);
                    self.root = null;
                }
            }
        }

        /// O(log N) 获取指定 index 的 item
        pub fn get(self: *const Self, index: usize) ?Item {
            if (index >= self.item_count) return null;
            if (self.root == null) return null;
            return self.getInNode(self.root.?, index);
        }

        /// O(log N) 替换指定 index 的 item
        pub fn replace(self: *Self, index: usize, item: Item) !void {
            if (self.transaction_active) {
                std.debug.assert(!self.transaction_failed);
                errdefer self.transaction_failed = true;
                return self.replaceInTransaction(index, item);
            }
            var tx = self.beginTransaction();
            defer tx.deinit();
            try self.replaceInTransaction(index, item);
            tx.commit();
        }

        fn replaceInTransaction(self: *Self, index: usize, item: Item) !void {
            std.debug.assert(index < self.item_count);
            std.debug.assert(self.root != null);

            self.root = try self.ensureUnique(self.root.?);
            try self.replaceInNode(self.root.?, index, item);
        }

        /// O(1) COW 快照（共享节点，引用计数）
        pub fn snapshot(self: *const Self) Self {
            if (self.root) |root| {
                retain(root);
            }
            return .{
                .allocator = self.allocator,
                .root = self.root,
                .item_count = self.item_count,
            };
        }

        /// Dimension-based seek: 按某个 Summary 维度查找 item
        pub fn SeekResult(comptime Dim: type) type {
            _ = Dim;
            return struct {
                index: usize = 0,
                item: ?Item = null,
                offset_in_item: usize = 0, // target - 前面所有 item 的 Dim 值之和
                preceding: usize = 0, // 前面所有 item 的 Dim 值之和
            };
        }

        /// O(log N) 按 Dimension 查找
        /// Dim 需要有 fn fromSummary(Summary) usize
        pub fn seek(self: *const Self, comptime Dim: type, target: usize) SeekResult(Dim) {
            var result = SeekResult(Dim){};
            if (self.root == null) return result;
            self.seekInNode(Dim, self.root.?, target, &result, 0);
            return result;
        }

        fn seekInNode(self: *const Self, comptime Dim: type, node: *const Node, target: usize, result: *SeekResult(Dim), base_index: usize) void {
            switch (node.data) {
                .leaf => |*leaf| {
                    var acc: usize = 0;
                    for (leaf.items[0..leaf.len], 0..) |item, i| {
                        const dim_val = Dim.fromSummary(item.summary());
                        if (acc + dim_val > target) {
                            result.index = base_index + i;
                            result.item = item;
                            result.offset_in_item = target - acc;
                            result.preceding = result.preceding + acc;
                            return;
                        }
                        acc += dim_val;
                    }
                    // target 超出范围，指向最后一个 item 之后
                    result.index = base_index + leaf.len;
                    result.preceding += acc;
                },
                .internal => |*internal| {
                    var acc: usize = 0;
                    var child_base: usize = base_index;
                    for (0..internal.len) |i| {
                        const dim_val = Dim.fromSummary(internal.summaries[i]);
                        if (acc + dim_val > target) {
                            result.preceding += acc;
                            self.seekInNode(Dim, internal.children[i], target - acc, result, child_base);
                            return;
                        }
                        acc += dim_val;
                        child_base += subtreeCount(internal.children[i]);
                    }
                    result.index = child_base;
                    result.preceding += acc;
                },
            }
        }

        /// 遍历所有 item
        pub const Iterator = struct {
            tree: *const Self,
            stack: [32]StackEntry = undefined,
            stack_len: usize = 0,
            chunk_idx: usize = 0,
            started: bool = false,

            const StackEntry = struct {
                node: *const Node,
                child_idx: usize,
            };

            /// Position before the item containing target in an additive,
            /// nonnegative dimension. Returns its intra-item offset. EOF leaves
            /// the iterator exhausted; a later seek can reposition it again.
            /// Uses cached summaries, without counting preceding subtrees.
            /// Exact boundaries seek forward; zero-sized items are skipped while
            /// seeking (subsequent next() calls still visit every item).
            pub fn seekTo(self_iter: *Iterator, comptime Dim: type, target: usize) ?usize {
                self_iter.started = true;
                self_iter.stack_len = 0;
                self_iter.chunk_idx = 0;
                var node = self_iter.tree.root orelse return null;
                if (target >= Dim.fromSummary(self_iter.tree.summary())) return null;
                var remaining = target;
                descend: while (true) {
                    std.debug.assert(self_iter.stack_len < self_iter.stack.len);
                    const depth = self_iter.stack_len;
                    self_iter.stack[depth] = .{ .node = node, .child_idx = 0 };
                    self_iter.stack_len += 1;
                    switch (node.data) {
                        .leaf => |*leaf| {
                            for (leaf.items[0..leaf.len], 0..) |item, i| {
                                const size = Dim.fromSummary(item.summary());
                                if (remaining < size) {
                                    self_iter.chunk_idx = i;
                                    return remaining;
                                }
                                remaining -= size;
                            }
                        },
                        .internal => |*internal| {
                            for (0..internal.len) |i| {
                                const size = Dim.fromSummary(internal.summaries[i]);
                                if (remaining < size) {
                                    self_iter.stack[depth].child_idx = i;
                                    node = internal.children[i];
                                    continue :descend;
                                }
                                remaining -= size;
                            }
                        },
                    }
                    // Defensive exhaustion for inconsistent summaries.
                    self_iter.stack_len = 0;
                    return null;
                }
            }

            pub fn next(self_iter: *Iterator) ?Item {
                if (!self_iter.started) {
                    self_iter.started = true;
                    if (self_iter.tree.root) |root| {
                        self_iter.stack[0] = .{ .node = root, .child_idx = 0 };
                        self_iter.stack_len = 1;
                    } else {
                        return null;
                    }
                }

                while (self_iter.stack_len > 0) {
                    const top = &self_iter.stack[self_iter.stack_len - 1];

                    switch (top.node.data) {
                        .leaf => |*leaf| {
                            if (self_iter.chunk_idx < leaf.len) {
                                const item = leaf.items[self_iter.chunk_idx];
                                self_iter.chunk_idx += 1;
                                return item;
                            } else {
                                self_iter.stack_len -= 1;
                                self_iter.chunk_idx = 0;
                                if (self_iter.stack_len > 0) {
                                    self_iter.stack[self_iter.stack_len - 1].child_idx += 1;
                                }
                            }
                        },
                        .internal => |*internal| {
                            if (top.child_idx < internal.len) {
                                const child = internal.children[top.child_idx];
                                std.debug.assert(self_iter.stack_len < 32);
                                self_iter.stack[self_iter.stack_len] = .{ .node = child, .child_idx = 0 };
                                self_iter.stack_len += 1;
                            } else {
                                self_iter.stack_len -= 1;
                                if (self_iter.stack_len > 0) {
                                    self_iter.stack[self_iter.stack_len - 1].child_idx += 1;
                                }
                            }
                        },
                    }
                }
                return null;
            }
        };

        pub fn iterator(self: *const Self) Iterator {
            return .{ .tree = self };
        }

        // ===== 内部实现 =====

        const InsertResult = struct {
            split: ?*Node = null,
        };

        fn insertInNode(self: *Self, node: *Node, index: usize, item: Item) !InsertResult {
            switch (node.data) {
                .leaf => |*leaf| {
                    if (leaf.len < BRANCHING_FACTOR) {
                        // 有空间，在 index 位置插入
                        var i = leaf.len;
                        while (i > index) : (i -= 1) {
                            leaf.items[i] = leaf.items[i - 1];
                        }
                        leaf.items[index] = item;
                        leaf.len += 1;
                        return .{};
                    } else {
                        // 叶满，需要分裂
                        return try self.splitLeafInsert(leaf, index, item);
                    }
                },
                .internal => |*internal| {
                    // 找到目标子树
                    var acc: usize = 0;
                    var child_idx: usize = 0;
                    while (child_idx < internal.len) : (child_idx += 1) {
                        const child_count = subtreeCount(internal.children[child_idx]);
                        if (acc + child_count >= index or child_idx == internal.len - 1) {
                            break;
                        }
                        acc += child_count;
                    }

                    // COW 子节点
                    internal.children[child_idx] = try self.ensureUnique(internal.children[child_idx]);
                    const result = try self.insertInNode(internal.children[child_idx], index - acc, item);

                    // 更新 summary
                    internal.summaries[child_idx] = nodeSummary(internal.children[child_idx]);

                    if (result.split) |split_child| {
                        if (internal.len < BRANCHING_FACTOR) {
                            // 有空间，在 child_idx+1 位置插入分裂的子节点
                            var i = internal.len;
                            while (i > child_idx + 1) : (i -= 1) {
                                internal.children[i] = internal.children[i - 1];
                                internal.summaries[i] = internal.summaries[i - 1];
                            }
                            internal.children[child_idx + 1] = split_child;
                            internal.summaries[child_idx + 1] = nodeSummary(split_child);
                            internal.len += 1;
                            return .{};
                        } else {
                            // 内部节点也满了，分裂
                            errdefer self.release(split_child);
                            return try self.splitInternalInsert(internal, child_idx + 1, split_child);
                        }
                    }

                    return .{};
                },
            }
        }

        fn splitLeafInsert(self: *Self, leaf: *LeafData, index: usize, item: Item) !InsertResult {
            // 收集所有 items（包括新 item），共 BRANCHING_FACTOR + 1 个
            var all: [BRANCHING_FACTOR + 1]Item = undefined;
            var pos: usize = 0;
            for (0..leaf.len) |i| {
                if (i == index) {
                    all[pos] = item;
                    pos += 1;
                }
                all[pos] = leaf.items[i];
                pos += 1;
            }
            if (index == leaf.len) {
                all[pos] = item;
                pos += 1;
            }
            std.debug.assert(pos == BRANCHING_FACTOR + 1);

            // 分裂：前 SPLIT_AT 留在原节点，其余进新节点
            const new_leaf = try self.createLeaf();
            leaf.len = SPLIT_AT;
            @memcpy(leaf.items[0..SPLIT_AT], all[0..SPLIT_AT]);
            const right_count = pos - SPLIT_AT;
            @memcpy(new_leaf.data.leaf.items[0..right_count], all[SPLIT_AT..pos]);
            new_leaf.data.leaf.len = right_count;

            return .{ .split = new_leaf };
        }

        fn splitInternalInsert(self: *Self, internal: *InternalData, insert_idx: usize, new_child: *Node) !InsertResult {
            // 收集所有 children（包括新的），共 BRANCHING_FACTOR + 1 个
            var all_children: [BRANCHING_FACTOR + 1]*Node = undefined;
            var all_summaries: [BRANCHING_FACTOR + 1]Summary = undefined;
            var pos: usize = 0;
            for (0..internal.len) |i| {
                if (i == insert_idx) {
                    all_children[pos] = new_child;
                    all_summaries[pos] = nodeSummary(new_child);
                    pos += 1;
                }
                all_children[pos] = internal.children[i];
                all_summaries[pos] = internal.summaries[i];
                pos += 1;
            }
            if (insert_idx == internal.len) {
                all_children[pos] = new_child;
                all_summaries[pos] = nodeSummary(new_child);
                pos += 1;
            }
            std.debug.assert(pos == BRANCHING_FACTOR + 1);

            // Allocate before transferring child ownership out of this node.
            const new_internal = try self.createInternal(all_children[0].height + 1);
            internal.len = SPLIT_AT;
            @memcpy(internal.children[0..SPLIT_AT], all_children[0..SPLIT_AT]);
            @memcpy(internal.summaries[0..SPLIT_AT], all_summaries[0..SPLIT_AT]);

            const right_count = pos - SPLIT_AT;
            @memcpy(new_internal.data.internal.children[0..right_count], all_children[SPLIT_AT..pos]);
            @memcpy(new_internal.data.internal.summaries[0..right_count], all_summaries[SPLIT_AT..pos]);
            new_internal.data.internal.len = right_count;

            return .{ .split = new_internal };
        }

        fn removeInNode(self: *Self, node: *Node, index: usize) !void {
            switch (node.data) {
                .leaf => |*leaf| {
                    std.debug.assert(index < leaf.len);
                    // Shift items left
                    var i = index;
                    while (i + 1 < leaf.len) : (i += 1) {
                        leaf.items[i] = leaf.items[i + 1];
                    }
                    leaf.len -= 1;
                },
                .internal => |*internal| {
                    // 找到目标子树
                    var acc: usize = 0;
                    var child_idx: usize = 0;
                    while (child_idx < internal.len) : (child_idx += 1) {
                        const child_count = subtreeCount(internal.children[child_idx]);
                        if (acc + child_count > index) {
                            break;
                        }
                        acc += child_count;
                    }

                    // COW
                    internal.children[child_idx] = try self.ensureUnique(internal.children[child_idx]);
                    try self.removeInNode(internal.children[child_idx], index - acc);

                    // 更新 summary
                    internal.summaries[child_idx] = nodeSummary(internal.children[child_idx]);

                    // 检查是否需要合并（子节点过空）
                    const child_len = switch (internal.children[child_idx].data) {
                        .leaf => |*l| l.len,
                        .internal => |*n| n.len,
                    };
                    if (child_len < MIN_CHILDREN and internal.len > 1) {
                        try self.rebalanceChild(internal, child_idx);
                    }
                },
            }
        }

        fn rebalanceChild(self: *Self, parent: *InternalData, child_idx: usize) !void {
            // 尝试从兄弟借用或合并
            if (child_idx + 1 < parent.len) {
                // 尝试从右兄弟借用
                parent.children[child_idx + 1] = try self.ensureUnique(parent.children[child_idx + 1]);
                const right = parent.children[child_idx + 1];
                const right_len = switch (right.data) {
                    .leaf => |*l| l.len,
                    .internal => |*n| n.len,
                };
                if (right_len > MIN_CHILDREN) {
                    // 借用右兄弟的第一个元素
                    try self.borrowFromRight(parent, child_idx);
                    return;
                }
                // 合并到左边
                try self.mergeChildren(parent, child_idx);
                return;
            }
            if (child_idx > 0) {
                // 尝试从左兄弟借用
                parent.children[child_idx - 1] = try self.ensureUnique(parent.children[child_idx - 1]);
                const left = parent.children[child_idx - 1];
                const left_len = switch (left.data) {
                    .leaf => |*l| l.len,
                    .internal => |*n| n.len,
                };
                if (left_len > MIN_CHILDREN) {
                    try self.borrowFromLeft(parent, child_idx);
                    return;
                }
                // 合并：将 child_idx 合并到 child_idx-1
                try self.mergeChildren(parent, child_idx - 1);
                return;
            }
        }

        fn borrowFromRight(self: *Self, parent: *InternalData, child_idx: usize) !void {
            _ = self;
            const left = parent.children[child_idx];
            const right = parent.children[child_idx + 1];

            switch (left.data) {
                .leaf => |*left_leaf| {
                    const right_leaf = &right.data.leaf;
                    // 将右兄弟的第一个 item 移到左边
                    left_leaf.items[left_leaf.len] = right_leaf.items[0];
                    left_leaf.len += 1;
                    // Shift right
                    var i: usize = 0;
                    while (i + 1 < right_leaf.len) : (i += 1) {
                        right_leaf.items[i] = right_leaf.items[i + 1];
                    }
                    right_leaf.len -= 1;
                },
                .internal => |*left_int| {
                    const right_int = &right.data.internal;
                    left_int.children[left_int.len] = right_int.children[0];
                    left_int.summaries[left_int.len] = right_int.summaries[0];
                    left_int.len += 1;
                    var i: usize = 0;
                    while (i + 1 < right_int.len) : (i += 1) {
                        right_int.children[i] = right_int.children[i + 1];
                        right_int.summaries[i] = right_int.summaries[i + 1];
                    }
                    right_int.len -= 1;
                },
            }
            parent.summaries[child_idx] = nodeSummary(left);
            parent.summaries[child_idx + 1] = nodeSummary(right);
        }

        fn borrowFromLeft(self: *Self, parent: *InternalData, child_idx: usize) !void {
            _ = self;
            const left = parent.children[child_idx - 1];
            const right_node = parent.children[child_idx];

            switch (right_node.data) {
                .leaf => |*right_leaf| {
                    const left_leaf = &left.data.leaf;
                    // Shift right's items to make room at front
                    var i = right_leaf.len;
                    while (i > 0) : (i -= 1) {
                        right_leaf.items[i] = right_leaf.items[i - 1];
                    }
                    right_leaf.items[0] = left_leaf.items[left_leaf.len - 1];
                    right_leaf.len += 1;
                    left_leaf.len -= 1;
                },
                .internal => |*right_int| {
                    const left_int = &left.data.internal;
                    var i = right_int.len;
                    while (i > 0) : (i -= 1) {
                        right_int.children[i] = right_int.children[i - 1];
                        right_int.summaries[i] = right_int.summaries[i - 1];
                    }
                    right_int.children[0] = left_int.children[left_int.len - 1];
                    right_int.summaries[0] = left_int.summaries[left_int.len - 1];
                    right_int.len += 1;
                    left_int.len -= 1;
                },
            }
            parent.summaries[child_idx - 1] = nodeSummary(left);
            parent.summaries[child_idx] = nodeSummary(right_node);
        }

        fn mergeChildren(self: *Self, parent: *InternalData, left_idx: usize) !void {
            const left = parent.children[left_idx];
            const right = parent.children[left_idx + 1];

            switch (left.data) {
                .leaf => |*left_leaf| {
                    const right_leaf = &right.data.leaf;
                    @memcpy(left_leaf.items[left_leaf.len..][0..right_leaf.len], right_leaf.items[0..right_leaf.len]);
                    left_leaf.len += right_leaf.len;
                },
                .internal => |*left_int| {
                    const right_int = &right.data.internal;
                    @memcpy(left_int.children[left_int.len..][0..right_int.len], right_int.children[0..right_int.len]);
                    @memcpy(left_int.summaries[left_int.len..][0..right_int.len], right_int.summaries[0..right_int.len]);
                    left_int.len += right_int.len;
                },
            }

            // 更新 summary
            parent.summaries[left_idx] = nodeSummary(left);

            // 释放右节点（不递归释放子节点，因为子节点已经被合并到左边）
            switch (right.data) {
                .internal => {
                    // 子节点已经被移到左边，不需要递归释放
                    self.allocator.destroy(right);
                },
                .leaf => {
                    self.allocator.destroy(right);
                },
            }

            // 从 parent 中移除右节点
            var i = left_idx + 1;
            while (i + 1 < parent.len) : (i += 1) {
                parent.children[i] = parent.children[i + 1];
                parent.summaries[i] = parent.summaries[i + 1];
            }
            parent.len -= 1;
        }

        fn getInNode(self: *const Self, node: *const Node, index: usize) ?Item {
            switch (node.data) {
                .leaf => |*leaf| {
                    if (index < leaf.len) return leaf.items[index];
                    return null;
                },
                .internal => |*internal| {
                    var acc: usize = 0;
                    for (0..internal.len) |i| {
                        const child_count = subtreeCount(internal.children[i]);
                        if (acc + child_count > index) {
                            return self.getInNode(internal.children[i], index - acc);
                        }
                        acc += child_count;
                    }
                    return null;
                },
            }
        }

        fn replaceInNode(self: *Self, node: *Node, index: usize, item: Item) !void {
            switch (node.data) {
                .leaf => |*leaf| {
                    std.debug.assert(index < leaf.len);
                    leaf.items[index] = item;
                },
                .internal => |*internal| {
                    var acc: usize = 0;
                    var child_idx: usize = 0;
                    while (child_idx < internal.len) : (child_idx += 1) {
                        const child_count = subtreeCount(internal.children[child_idx]);
                        if (acc + child_count > index) {
                            break;
                        }
                        acc += child_count;
                    }
                    internal.children[child_idx] = try self.ensureUnique(internal.children[child_idx]);
                    try self.replaceInNode(internal.children[child_idx], index - acc, item);
                    internal.summaries[child_idx] = nodeSummary(internal.children[child_idx]);
                },
            }
        }
    };
}

// ===== 向后兼容类型别名 =====

/// 文本摘要：存储子树的聚合统计信息
pub const TextSummary = struct {
    bytes: usize = 0,
    lines: usize = 0,
    max_line_len: usize = 0,

    pub const ZERO: TextSummary = .{};

    pub fn add(self: TextSummary, other: TextSummary) TextSummary {
        return .{
            .bytes = self.bytes + other.bytes,
            .lines = self.lines + other.lines,
            .max_line_len = @max(self.max_line_len, other.max_line_len),
        };
    }

    pub fn fromText(text: []const u8) TextSummary {
        var lines: usize = 0;
        var max_line_len: usize = 0;
        var current_line_len: usize = 0;

        for (text) |byte| {
            if (byte == '\n') {
                lines += 1;
                max_line_len = @max(max_line_len, current_line_len);
                current_line_len = 0;
            } else {
                current_line_len += 1;
            }
        }
        max_line_len = @max(max_line_len, current_line_len);

        return .{
            .bytes = text.len,
            .lines = lines,
            .max_line_len = max_line_len,
        };
    }
};

/// 文本块
pub const TextChunk = struct {
    start: usize,
    len: usize,
    newline_count: usize,

    pub fn summary(self: TextChunk) TextSummary {
        return .{
            .bytes = self.len,
            .lines = self.newline_count,
            .max_line_len = 0,
        };
    }
};

/// 向后兼容别名
pub const TextSumTree = SumTree(TextChunk, TextSummary);

/// Dimension: 按字节偏移查找
pub const ByteDim = struct {
    pub fn fromSummary(s: TextSummary) usize {
        return s.bytes;
    }
};

/// Dimension: 按行号查找
pub const LineDim = struct {
    pub fn fromSummary(s: TextSummary) usize {
        return s.lines;
    }
};

// ===== 单元测试 =====

test "TextSummary: fromText" {
    const text = "Hello\nWorld\n";
    const s = TextSummary.fromText(text);

    try std.testing.expectEqual(@as(usize, 12), s.bytes);
    try std.testing.expectEqual(@as(usize, 2), s.lines);
    try std.testing.expectEqual(@as(usize, 5), s.max_line_len);
}

test "TextSummary: add" {
    const s1 = TextSummary{ .bytes = 10, .lines = 2, .max_line_len = 5 };
    const s2 = TextSummary{ .bytes = 15, .lines = 3, .max_line_len = 8 };
    const result = s1.add(s2);

    try std.testing.expectEqual(@as(usize, 25), result.bytes);
    try std.testing.expectEqual(@as(usize, 5), result.lines);
    try std.testing.expectEqual(@as(usize, 8), result.max_line_len);
}

test "SumTree: init and deinit" {
    var tree = TextSumTree.init(std.testing.allocator);
    defer tree.deinit();

    try std.testing.expectEqual(@as(usize, 0), tree.summary().bytes);
    try std.testing.expectEqual(@as(usize, 0), tree.summary().lines);
    try std.testing.expectEqual(@as(usize, 0), tree.count());
}

test "SumTree: push single chunk" {
    var tree = TextSumTree.init(std.testing.allocator);
    defer tree.deinit();

    const chunk = TextChunk{ .start = 0, .len = 12, .newline_count = 2 };
    try tree.push(chunk);

    try std.testing.expectEqual(@as(usize, 12), tree.summary().bytes);
    try std.testing.expectEqual(@as(usize, 2), tree.summary().lines);
    try std.testing.expectEqual(@as(usize, 1), tree.count());
}

test "SumTree: push multiple chunks" {
    var tree = TextSumTree.init(std.testing.allocator);
    defer tree.deinit();

    try tree.push(TextChunk{ .start = 0, .len = 7, .newline_count = 1 });
    try tree.push(TextChunk{ .start = 7, .len = 7, .newline_count = 1 });
    try tree.push(TextChunk{ .start = 14, .len = 7, .newline_count = 1 });

    try std.testing.expectEqual(@as(usize, 21), tree.summary().bytes);
    try std.testing.expectEqual(@as(usize, 3), tree.summary().lines);
    try std.testing.expectEqual(@as(usize, 3), tree.count());
}

test "SumTree: seek by byte" {
    var tree = TextSumTree.init(std.testing.allocator);
    defer tree.deinit();

    try tree.push(TextChunk{ .start = 0, .len = 6, .newline_count = 1 });
    try tree.push(TextChunk{ .start = 6, .len = 6, .newline_count = 1 });

    const result = tree.seek(ByteDim, 6);
    try std.testing.expect(result.item != null);
    try std.testing.expectEqual(@as(usize, 0), result.offset_in_item);
    try std.testing.expectEqual(@as(usize, 1), result.index);
}

test "SumTree: seek by line" {
    var tree = TextSumTree.init(std.testing.allocator);
    defer tree.deinit();

    try tree.push(TextChunk{ .start = 0, .len = 7, .newline_count = 1 });
    try tree.push(TextChunk{ .start = 7, .len = 7, .newline_count = 1 });
    try tree.push(TextChunk{ .start = 14, .len = 7, .newline_count = 1 });

    // seek(LineDim, 1): 找到包含第 1 行的 chunk
    // chunk 0 有 1 行 (line 0)，chunk 1 有 1 行 (line 1)
    const result = tree.seek(LineDim, 1);
    try std.testing.expect(result.item != null);
    try std.testing.expectEqual(@as(usize, 1), result.index); // chunk 1
    try std.testing.expectEqual(@as(usize, 1), result.preceding); // 前面有 1 行
    try std.testing.expectEqual(@as(usize, 7), result.item.?.start); // chunk 1 的 start
}

test "SumTree: many chunks trigger split" {
    var tree = TextSumTree.init(std.testing.allocator);
    defer tree.deinit();

    var i: usize = 0;
    while (i < 20) : (i += 1) {
        try tree.push(TextChunk{
            .start = i * 10,
            .len = 10,
            .newline_count = 1,
        });
    }

    try std.testing.expectEqual(@as(usize, 20), tree.summary().lines);
    try std.testing.expectEqual(@as(usize, 20), tree.count());

    const result = tree.seek(LineDim, 10);
    try std.testing.expect(result.item != null);
}

test "SumTree: iterator" {
    var tree = TextSumTree.init(std.testing.allocator);
    defer tree.deinit();

    try tree.push(TextChunk{ .start = 0, .len = 2, .newline_count = 1 });
    try tree.push(TextChunk{ .start = 2, .len = 2, .newline_count = 1 });
    try tree.push(TextChunk{ .start = 4, .len = 2, .newline_count = 1 });

    var iter = tree.iterator();
    var cnt: usize = 0;
    while (iter.next()) |_| {
        cnt += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), cnt);
}

test "SumTree: large tree with splits" {
    var tree = TextSumTree.init(std.testing.allocator);
    defer tree.deinit();

    const n: usize = 100;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        try tree.push(TextChunk{
            .start = i * 50,
            .len = 50,
            .newline_count = 1,
        });
    }

    try std.testing.expectEqual(@as(usize, n * 50), tree.summary().bytes);
    try std.testing.expectEqual(@as(usize, n), tree.summary().lines);
    try std.testing.expectEqual(@as(usize, n), tree.count());

    var iter = tree.iterator();
    var cnt: usize = 0;
    while (iter.next()) |_| {
        cnt += 1;
    }
    try std.testing.expectEqual(n, cnt);

    const mid_byte = (n * 50) / 2;
    const byte_result = tree.seek(ByteDim, mid_byte);
    try std.testing.expect(byte_result.item != null);

    const mid_line = n / 2;
    const line_result = tree.seek(LineDim, mid_line);
    try std.testing.expect(line_result.item != null);
}

// ===== 新增测试：insert/remove/get/replace =====

test "SumTree: insert at various positions" {
    var tree = TextSumTree.init(std.testing.allocator);
    defer tree.deinit();

    // 头部插入
    try tree.insert(0, TextChunk{ .start = 100, .len = 10, .newline_count = 0 });
    try std.testing.expectEqual(@as(usize, 1), tree.count());
    try std.testing.expectEqual(@as(usize, 100), tree.get(0).?.start);

    // 尾部插入
    try tree.insert(1, TextChunk{ .start = 200, .len = 20, .newline_count = 1 });
    try std.testing.expectEqual(@as(usize, 2), tree.count());
    try std.testing.expectEqual(@as(usize, 200), tree.get(1).?.start);

    // 中间插入
    try tree.insert(1, TextChunk{ .start = 150, .len = 15, .newline_count = 0 });
    try std.testing.expectEqual(@as(usize, 3), tree.count());
    try std.testing.expectEqual(@as(usize, 100), tree.get(0).?.start);
    try std.testing.expectEqual(@as(usize, 150), tree.get(1).?.start);
    try std.testing.expectEqual(@as(usize, 200), tree.get(2).?.start);

    // Summary 正确
    try std.testing.expectEqual(@as(usize, 45), tree.summary().bytes);
    try std.testing.expectEqual(@as(usize, 1), tree.summary().lines);
}

test "SumTree: remove at various positions" {
    var tree = TextSumTree.init(std.testing.allocator);
    defer tree.deinit();

    // 插入 5 个
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        try tree.push(TextChunk{ .start = i * 10, .len = 10, .newline_count = 1 });
    }
    try std.testing.expectEqual(@as(usize, 5), tree.count());

    // 删除中间
    try tree.remove(2);
    try std.testing.expectEqual(@as(usize, 4), tree.count());
    try std.testing.expectEqual(@as(usize, 0), tree.get(0).?.start);
    try std.testing.expectEqual(@as(usize, 10), tree.get(1).?.start);
    try std.testing.expectEqual(@as(usize, 30), tree.get(2).?.start);
    try std.testing.expectEqual(@as(usize, 40), tree.get(3).?.start);

    // 删除头部
    try tree.remove(0);
    try std.testing.expectEqual(@as(usize, 3), tree.count());
    try std.testing.expectEqual(@as(usize, 10), tree.get(0).?.start);

    // 删除尾部
    try tree.remove(2);
    try std.testing.expectEqual(@as(usize, 2), tree.count());
    try std.testing.expectEqual(@as(usize, 30), tree.get(1).?.start);
}

test "SumTree: get" {
    var tree = TextSumTree.init(std.testing.allocator);
    defer tree.deinit();

    try tree.push(TextChunk{ .start = 0, .len = 5, .newline_count = 0 });
    try tree.push(TextChunk{ .start = 5, .len = 10, .newline_count = 1 });

    try std.testing.expectEqual(@as(usize, 0), tree.get(0).?.start);
    try std.testing.expectEqual(@as(usize, 5), tree.get(1).?.start);
    try std.testing.expect(tree.get(2) == null);
}

test "SumTree: replace" {
    var tree = TextSumTree.init(std.testing.allocator);
    defer tree.deinit();

    try tree.push(TextChunk{ .start = 0, .len = 5, .newline_count = 0 });
    try tree.push(TextChunk{ .start = 5, .len = 10, .newline_count = 1 });

    try tree.replace(0, TextChunk{ .start = 0, .len = 8, .newline_count = 2 });
    try std.testing.expectEqual(@as(usize, 8), tree.get(0).?.len);
    try std.testing.expectEqual(@as(usize, 18), tree.summary().bytes);
    try std.testing.expectEqual(@as(usize, 3), tree.summary().lines);
}

test "SumTree: COW snapshot" {
    var tree = TextSumTree.init(std.testing.allocator);
    defer tree.deinit();

    try tree.push(TextChunk{ .start = 0, .len = 10, .newline_count = 1 });
    try tree.push(TextChunk{ .start = 10, .len = 20, .newline_count = 2 });

    // 创建快照
    var snap = tree.snapshot();
    defer snap.deinit();

    try std.testing.expectEqual(@as(usize, 2), snap.count());
    try std.testing.expectEqual(@as(usize, 30), snap.summary().bytes);

    // 修改主树
    try tree.push(TextChunk{ .start = 30, .len = 5, .newline_count = 0 });
    try tree.remove(0);

    // 主树已变
    try std.testing.expectEqual(@as(usize, 2), tree.count());
    try std.testing.expectEqual(@as(usize, 25), tree.summary().bytes);

    // 快照不变
    try std.testing.expectEqual(@as(usize, 2), snap.count());
    try std.testing.expectEqual(@as(usize, 30), snap.summary().bytes);
    try std.testing.expectEqual(@as(usize, 0), snap.get(0).?.start);
    try std.testing.expectEqual(@as(usize, 10), snap.get(1).?.start);
}

test "SumTree: alternating insert and remove" {
    var tree = TextSumTree.init(std.testing.allocator);
    defer tree.deinit();

    // 交替操作
    try tree.push(TextChunk{ .start = 0, .len = 10, .newline_count = 1 });
    try tree.push(TextChunk{ .start = 10, .len = 10, .newline_count = 1 });
    try tree.push(TextChunk{ .start = 20, .len = 10, .newline_count = 1 });

    try tree.remove(1); // 移除中间
    try std.testing.expectEqual(@as(usize, 2), tree.count());

    try tree.insert(1, TextChunk{ .start = 50, .len = 5, .newline_count = 0 });
    try std.testing.expectEqual(@as(usize, 3), tree.count());
    try std.testing.expectEqual(@as(usize, 50), tree.get(1).?.start);
    try std.testing.expectEqual(@as(usize, 20), tree.get(2).?.start);

    try tree.remove(0);
    try tree.remove(0);
    try tree.remove(0);
    try std.testing.expectEqual(@as(usize, 0), tree.count());
}

test "SumTree: many inserts trigger splits and removes trigger merges" {
    var tree = TextSumTree.init(std.testing.allocator);
    defer tree.deinit();

    // 插入足够多的元素触发多层分裂
    const n: usize = 50;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        try tree.insert(i, TextChunk{ .start = i * 10, .len = 10, .newline_count = 1 });
    }
    try std.testing.expectEqual(n, tree.count());
    try std.testing.expectEqual(@as(usize, n * 10), tree.summary().bytes);

    // 验证所有元素顺序正确
    i = 0;
    while (i < n) : (i += 1) {
        try std.testing.expectEqual(i * 10, tree.get(i).?.start);
    }

    // 逐个从头部删除
    i = 0;
    while (i < n) : (i += 1) {
        try tree.remove(0);
        try std.testing.expectEqual(n - i - 1, tree.count());
    }
    try std.testing.expectEqual(@as(usize, 0), tree.count());
}

test "SumTree: fuzzy insert/remove vs ArrayList reference" {
    // 用确定性种子的伪随机序列测试正确性
    var tree = TextSumTree.init(std.testing.allocator);
    defer tree.deinit();

    var ref = std.ArrayList(TextChunk){};
    defer ref.deinit(std.testing.allocator);

    // 使用简单的 LCG 伪随机数
    var seed: u64 = 12345;
    const lcg = struct {
        fn next(s: *u64) u64 {
            s.* = s.* *% 6364136223846793005 +% 1442695040888963407;
            return s.*;
        }
    };

    var i: usize = 0;
    while (i < 200) : (i += 1) {
        const op = lcg.next(&seed) % 3;
        if (op < 2 or ref.items.len == 0) {
            // Insert
            const idx = if (ref.items.len == 0) 0 else lcg.next(&seed) % (ref.items.len + 1);
            const chunk = TextChunk{ .start = i * 7, .len = @as(usize, @intCast(lcg.next(&seed) % 20)) + 1, .newline_count = @as(usize, @intCast(lcg.next(&seed) % 3)) };
            try tree.insert(idx, chunk);
            try ref.insert(std.testing.allocator, idx, chunk);
        } else {
            // Remove
            const idx = lcg.next(&seed) % ref.items.len;
            try tree.remove(idx);
            _ = ref.orderedRemove(idx);
        }

        // 验证一致性
        try std.testing.expectEqual(ref.items.len, tree.count());
        // 每 10 步做一次全量验证
        if (i % 10 == 0) {
            for (ref.items, 0..) |expected, j| {
                const actual = tree.get(j);
                try std.testing.expect(actual != null);
                try std.testing.expectEqual(expected.start, actual.?.start);
                try std.testing.expectEqual(expected.len, actual.?.len);
            }
        }
    }
}

fn checkMutationFailureAtomicity(comptime operation: enum { insert, remove, replace }, item_count: usize) !void {
    var fail_at: usize = 0;
    while (fail_at < 100) : (fail_at += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        var tree = TextSumTree.init(failing.allocator());
        defer tree.deinit();
        for (0..item_count) |i| try tree.push(.{ .start = i, .len = i + 1, .newline_count = i % 2 });
        var original = tree.snapshot();
        defer original.deinit();
        const summary_before = tree.summary();
        const index = if (operation == .insert) item_count else 0;
        failing.fail_index = failing.alloc_index + fail_at;
        const result = switch (operation) {
            .insert => tree.insert(index, .{ .start = 999, .len = 42, .newline_count = 1 }),
            .remove => tree.remove(index),
            .replace => tree.replace(index, .{ .start = 999, .len = 42, .newline_count = 1 }),
        };
        // Readers holding an existing snapshot never see even a successful edit.
        try std.testing.expectEqualDeep(summary_before, original.summary());
        for (0..item_count) |i| try std.testing.expectEqual(i, original.get(i).?.start);
        if (result) |_| {
            try std.testing.expectEqual(switch (operation) {
                .insert => item_count + 1,
                .remove => item_count - 1,
                .replace => item_count,
            }, tree.count());
            return;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expectEqual(item_count, tree.count());
            try std.testing.expectEqualDeep(summary_before, tree.summary());
            var iterator = tree.iterator();
            for (0..item_count) |i| {
                try std.testing.expectEqualDeep(original.get(i).?, tree.get(i).?);
                try std.testing.expectEqualDeep(original.get(i).?, iterator.next().?);
            }
            try std.testing.expect(iterator.next() == null);
        }
    }
    return error.TestUnexpectedResult;
}

test "SumTree public mutations preserve items summaries and snapshots at every allocation failure" {
    // Full leaf, full internal root, and a taller tree exercise split ownership.
    for ([_]usize{ 8, 36, 164 }) |count| {
        try checkMutationFailureAtomicity(.insert, count);
        try checkMutationFailureAtomicity(.remove, count);
        try checkMutationFailureAtomicity(.replace, count);
    }
}

test "SumTree batch rolls back successful edits before a later failure" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var tree = TextSumTree.init(failing.allocator());
    defer tree.deinit();
    for (0..36) |i| try tree.push(.{ .start = i, .len = 1, .newline_count = 0 });
    {
        var tx = tree.beginTransaction();
        defer tx.deinit();
        try tree.replace(0, .{ .start = 999, .len = 100, .newline_count = 3 });
        failing.fail_index = failing.alloc_index;
        try std.testing.expectError(error.OutOfMemory, tree.insert(36, .{ .start = 36, .len = 1, .newline_count = 0 }));
    }
    try std.testing.expectEqual(@as(usize, 36), tree.count());
    try std.testing.expectEqual(@as(usize, 36), tree.summary().bytes);
    for (0..36) |i| try std.testing.expectEqual(i, tree.get(i).?.start);
}

test "SumTree iterator seek resumes across levels and resets after exhaustion" {
    var tree = TextSumTree.init(std.testing.allocator);
    defer tree.deinit();
    var it = tree.iterator();
    try std.testing.expect(it.seekTo(ByteDim, 0) == null);
    try std.testing.expect(it.next() == null);
    for (0..1600) |i| try tree.push(.{ .start = i * 3, .len = 3, .newline_count = if (i % 7 == 0) 1 else 0 });
    try std.testing.expect(tree.root.?.height >= 3);
    _ = it.seekTo(ByteDim, 4790);
    _ = it.next();
    _ = it.next();
    try std.testing.expectEqual(@as(usize, 1), it.seekTo(ByteDim, 1).?);
    try std.testing.expectEqual(@as(usize, 0), it.next().?.start);
    for ([_]usize{ 0, 1, 2, 3, 47, 48, 1535, 4799 }) |target| {
        try std.testing.expectEqual(target % 3, it.seekTo(ByteDim, target).?);
        var index = target / 3;
        while (it.next()) |item| : (index += 1) try std.testing.expectEqual(index * 3, item.start);
        try std.testing.expectEqual(@as(usize, 1600), index);
        try std.testing.expect(it.next() == null);
    }
    for ([_]usize{ 0, 1, 7, 100, 228 }) |target| {
        try std.testing.expectEqual(@as(usize, 0), it.seekTo(LineDim, target).?);
        var index = target * 7;
        while (it.next()) |item| : (index += 1) try std.testing.expectEqual(index * 3, item.start);
        try std.testing.expectEqual(@as(usize, 1600), index);
    }
    try std.testing.expect(it.seekTo(ByteDim, 4800) == null);
    try std.testing.expect(it.next() == null);
    try std.testing.expect(it.seekTo(ByteDim, std.math.maxInt(usize)) == null);
    try std.testing.expect(it.next() == null);
    try std.testing.expectEqual(@as(usize, 1), it.seekTo(ByteDim, 4).?);
    try std.testing.expectEqual(@as(usize, 3), it.next().?.start);
}

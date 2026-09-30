const std = @import("std");
const Allocator = std.mem.Allocator;

/// 编辑操作类型
pub const OpType = enum {
    insert,
    delete,
};

/// 编辑操作记录
pub const Operation = struct {
    op_type: OpType,
    position: usize,
    length: usize,
    text: ?[]const u8, // 对于删除操作，存储被删除的文本
    group_id: u32 = 0, // 非 0 时，相同 group_id 的操作一起 undo/redo

    pub fn deinit(self: *Operation, allocator: Allocator) void {
        if (self.text) |text| {
            allocator.free(text);
        }
    }
};

/// Undo/Redo 栈
/// 基于 Piece Table 的不可变性，我们可以轻量级地存储操作历史
pub const UndoStack = struct {
    allocator: Allocator,
    undo_stack: std.ArrayList(Operation),
    redo_stack: std.ArrayList(Operation),
    max_size: usize,
    next_group_id: u32 = 1,
    version: u32 = 0,

    pub fn init(allocator: Allocator, max_size: usize) UndoStack {
        return UndoStack{
            .allocator = allocator,
            .undo_stack = std.ArrayList(Operation){},
            .redo_stack = std.ArrayList(Operation){},
            .max_size = max_size,
        };
    }

    pub fn deinit(self: *UndoStack) void {
        for (self.undo_stack.items) |*op| {
            op.deinit(self.allocator);
        }
        for (self.redo_stack.items) |*op| {
            op.deinit(self.allocator);
        }
        self.undo_stack.deinit(self.allocator);
        self.redo_stack.deinit(self.allocator);
    }

    /// 推入新操作（同时清空 redo 栈）。
    /// 所有权：成功时 op（含其 text）归栈所有；返回错误时所有权仍在调用方
    /// （但 redo 栈已被清空 —— redo 失效是保守且无害的）。
    pub fn push(self: *UndoStack, op: Operation) !void {
        // 清空 redo 栈
        for (self.redo_stack.items) |*redo_op| {
            redo_op.deinit(self.allocator);
        }
        self.redo_stack.clearRetainingCapacity();

        // 推入 undo 栈
        try self.undo_stack.append(self.allocator, op);
        self.version +%= 1;

        // 限制栈大小
        if (self.undo_stack.items.len > self.max_size) {
            var removed = self.undo_stack.orderedRemove(0);
            removed.deinit(self.allocator);
        }
    }

    /// 单次撤销。
    /// 所有权：返回的 Operation 转移给调用方（用完须 op.deinit(allocator)）；
    /// redo 栈保留自己的独立副本，两者不共享内存（对照 textarea 快照栈的
    /// 所有权转移写法）。
    /// 瞬时 OOM 时返回 null 且状态不变：op 仍留在 undo 栈，可重试。
    pub fn undo(self: *UndoStack) ?Operation {
        if (self.undo_stack.items.len == 0) return null;

        // 先把所有可失败的分配做完，任一失败则不动任何状态（op 不丢、不泄漏）。
        self.redo_stack.ensureUnusedCapacity(self.allocator, 1) catch return null;
        const top = self.undo_stack.items[self.undo_stack.items.len - 1];
        var stack_copy = top;
        if (top.text) |text| {
            stack_copy.text = self.allocator.dupe(u8, text) catch return null;
        }

        const op = self.undo_stack.pop().?;
        self.redo_stack.appendAssumeCapacity(stack_copy);
        self.version +%= 1;
        return op;
    }

    /// 单次重做。所有权契约与 undo 相同：返回值归调用方，undo 栈存独立副本；
    /// 瞬时 OOM 时返回 null 且状态不变。
    pub fn redo(self: *UndoStack) ?Operation {
        if (self.redo_stack.items.len == 0) return null;

        self.undo_stack.ensureUnusedCapacity(self.allocator, 1) catch return null;
        const top = self.redo_stack.items[self.redo_stack.items.len - 1];
        var stack_copy = top;
        if (top.text) |text| {
            stack_copy.text = self.allocator.dupe(u8, text) catch return null;
        }

        const op = self.redo_stack.pop().?;
        self.undo_stack.appendAssumeCapacity(stack_copy);
        self.version +%= 1;
        return op;
    }

    pub fn canUndo(self: *UndoStack) bool {
        return self.undo_stack.items.len > 0;
    }

    pub fn canRedo(self: *UndoStack) bool {
        return self.redo_stack.items.len > 0;
    }
};

/// 一次性失败 allocator：armed（fail_next=true）后使下一次分配失败一次，
/// 之后恢复正常。std.testing.FailingAllocator 首中后**永久**失败
/// （alloc_index 只在成功时递增），模拟「瞬时 OOM 后恢复」必须用这种。
const OneShotFailingAllocator = struct {
    backing: Allocator,
    fail_next: bool = false,

    fn allocator(self: *OneShotFailingAllocator) Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn consumeArm(self: *OneShotFailingAllocator) bool {
        if (self.fail_next) {
            self.fail_next = false;
            return true;
        }
        return false;
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *OneShotFailingAllocator = @ptrCast(@alignCast(ctx));
        if (self.consumeArm()) return null;
        return self.backing.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *OneShotFailingAllocator = @ptrCast(@alignCast(ctx));
        if (new_len > memory.len and self.consumeArm()) return false;
        return self.backing.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *OneShotFailingAllocator = @ptrCast(@alignCast(ctx));
        if (new_len > memory.len and self.consumeArm()) return null;
        return self.backing.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *OneShotFailingAllocator = @ptrCast(@alignCast(ctx));
        self.backing.rawFree(memory, alignment, ret_addr);
    }
};

test "UndoStack: 瞬时 OOM 下 undo 不丢操作" {
    var one_shot = OneShotFailingAllocator{ .backing = std.testing.allocator };
    const alloc = one_shot.allocator();

    var stack = UndoStack.init(alloc, 100);
    defer stack.deinit();

    const text = try alloc.dupe(u8, "hello");
    try stack.push(.{ .op_type = .delete, .position = 0, .length = 5, .text = text });

    // 使 undo 内部的下一次分配失败一次（瞬时 OOM，随后恢复）。
    one_shot.fail_next = true;
    try std.testing.expect(stack.undo() == null);

    // op 必须仍留在 undo 栈：既不丢操作也不泄漏 text。
    try std.testing.expect(stack.canUndo());
    try std.testing.expect(!stack.canRedo());

    // OOM 恢复后重试必须成功。
    var op = stack.undo() orelse return error.TestUnexpectedResult;
    defer op.deinit(alloc);
    try std.testing.expectEqualStrings("hello", op.text.?);
    try std.testing.expect(!stack.canUndo());
    try std.testing.expect(stack.canRedo());
}

test "UndoStack: undo/redo 返回的 op 所有权归调用方,与栈内副本不共享内存" {
    var stack = UndoStack.init(std.testing.allocator, 100);
    defer stack.deinit();

    const text = try std.testing.allocator.dupe(u8, "abc");
    try stack.push(.{ .op_type = .delete, .position = 0, .length = 3, .text = text });

    var undone = stack.undo() orelse return error.TestUnexpectedResult;
    // 调用方释放自己那份。若返回值与 redo 栈共享同一 text 指针，
    // 后续 redo/deinit 会二次释放 —— testing.allocator 抓 double free。
    undone.deinit(std.testing.allocator);

    try std.testing.expect(stack.canRedo());

    var redone = stack.redo() orelse return error.TestUnexpectedResult;
    redone.deinit(std.testing.allocator);

    try std.testing.expect(stack.canUndo());
    try std.testing.expect(!stack.canRedo());
}

test "UndoStack: 返回的 op 在后续 push 清空 redo 栈后仍有效" {
    var stack = UndoStack.init(std.testing.allocator, 100);
    defer stack.deinit();

    const t1 = try std.testing.allocator.dupe(u8, "first");
    try stack.push(.{ .op_type = .delete, .position = 0, .length = 5, .text = t1 });

    var undone = stack.undo() orelse return error.TestUnexpectedResult;
    defer undone.deinit(std.testing.allocator);

    // push 清空 redo 栈。若 undone.text 与 redo 栈条目共享指针，
    // 此后读 undone.text 就是 use-after-free。
    const t2 = try std.testing.allocator.dupe(u8, "second");
    try stack.push(.{ .op_type = .insert, .position = 0, .length = 6, .text = t2 });

    try std.testing.expectEqualStrings("first", undone.text.?);
}

test "UndoStack: basic operations" {
    var stack = UndoStack.init(std.testing.allocator, 100);
    defer stack.deinit();

    try std.testing.expect(!stack.canUndo());
    try std.testing.expect(!stack.canRedo());

    try stack.push(Operation{
        .op_type = .insert,
        .position = 0,
        .length = 5,
        .text = null,
    });

    try std.testing.expect(stack.canUndo());
    try std.testing.expect(!stack.canRedo());

    _ = stack.undo();
    try std.testing.expect(!stack.canUndo());
    try std.testing.expect(stack.canRedo());
}

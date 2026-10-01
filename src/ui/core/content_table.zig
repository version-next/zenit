//! ContentTable, v0.9-§a NodeContent SoA, dense by ElementId
//!
//! 与 ElementTable 一一对应：每个 element 创建时同步 ensureSlot。
//! v0.9 stage 1 (本提交): 双写期。Node.visuals.content 仍是 source of truth；
//! 此表是镜像，给未来读路径切换准备。stage 3 才真删 Node 字段。
//!
//! TextProps 的 inline_buf 自指 slice 问题：set 路径必须 fixupAfterMove。
//! ImageProps / IconProps 没有自指字段，普通值拷贝即可。

const std = @import("std");
const testing = std.testing;
const element_id_mod = @import("element_id.zig");
const types = @import("types.zig");

pub const ElementId = element_id_mod.ElementId;
pub const TextProps = types.TextProps;
pub const ImageProps = types.ImageProps;
pub const IconProps = types.IconProps;

/// 单 element 的 content 镜像（text + media）。
/// 与 node.zig NodeContent / NodeMedia 字段对齐。
pub const ContentData = struct {
    text: ?TextProps = null,
    image: ?ImageProps = null,
    icon: ?IconProps = null,
};

pub const ContentTable = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayListUnmanaged(ContentData),

    pub fn init(allocator: std.mem.Allocator) ContentTable {
        return .{ .allocator = allocator, .items = .{} };
    }

    pub fn deinit(self: *ContentTable) void {
        self.items.deinit(self.allocator);
        self.* = undefined;
    }

    /// Grow items 并 re-fixup 所有现有 entry 的 inline_buf 自指 slice。
    /// ArrayList 扩容时 entries 会 move 到新地址，旧 inline_buf slice 失效，必须
    /// 全表重 fixup。
    pub fn ensureSlot(self: *ContentTable, id: ElementId) !void {
        if (id.isNull()) return;
        const idx = id.index;
        if (self.items.items.len > idx) return;
        const old_ptr = if (self.items.items.len > 0) @intFromPtr(self.items.items.ptr) else 0;
        // One fallible reservation precedes all moves/length changes. A later
        // append must not fail after relocation but before inline fixups.
        try self.items.ensureTotalCapacity(self.allocator, @as(usize, idx) + 1);
        while (self.items.items.len <= idx) {
            self.items.appendAssumeCapacity(.{});
        }
        const new_ptr = @intFromPtr(self.items.items.ptr);
        if (old_ptr != 0 and old_ptr != new_ptr) {
            // 内存搬过家，所有 text inline_buf slice 失效；逐 entry re-fixup。
            for (self.items.items) |*entry| {
                if (entry.text) |*tt| tt.fixupAfterMove();
            }
        }
    }

    pub fn get(self: *const ContentTable, id: ElementId) ?ContentData {
        if (id.isNull() or id.index >= self.items.items.len) return null;
        return self.items.items[id.index];
    }

    /// 返回 TextProps 值 copy。caller 拿到 copy 后 content 仍指 ContentTable 内部
    /// inline_buf；这是有意为之，因为 caller 通常立即读 content 不会复制 struct。
    /// 若 caller `var t = getText().?; ... node.setText(t)`，setText 内部会再 fixup
    /// 让 stored entry 的 inline_buf 重新自洽。
    pub fn getText(self: *const ContentTable, id: ElementId) ?TextProps {
        if (id.isNull() or id.index >= self.items.items.len) return null;
        return self.items.items[id.index].text;
    }

    /// 写入 text；fixupAfterMove 把 inline_buf 自指 slice 重定向到新存储地址。
    /// 用智能 fixup：仅当 content 字节内容与 inline_buf[0..inline_len] 一致时
    /// 才视为 inline-storage 路径，重定向到 slot 的 inline_buf；否则保留外部 slice。
    pub fn setText(self: *ContentTable, id: ElementId, t: ?TextProps) void {
        if (id.isNull() or id.index >= self.items.items.len) return;
        var slot = &self.items.items[id.index];
        // 换文本时释放旧 owned 内容/spans，否则被换出的 dupe 永久泄漏。
        // 指针守卫：caller `getText -> 改字段 -> setText` 原样写回同一块内存时不能 free。
        if (slot.text) |old| {
            const new_content_ptr: ?[*]const u8 = if (t) |nt| nt.content.ptr else null;
            const new_spans_ptr: ?[*]const types.TextSpan = if (t) |nt| nt.spans.ptr else null;
            if (old.owned and old.content.len > 0 and old.content.ptr != new_content_ptr) {
                self.allocator.free(old.content);
            }
            if (old.spans_owned and old.spans.len > 0 and old.spans.ptr != new_spans_ptr) {
                self.allocator.free(old.spans);
            }
        }
        slot.text = t;
        if (slot.text) |*tt| {
            if (tt.inline_len > 0 and t.?.content.len == tt.inline_len) {
                if (std.mem.eql(u8, t.?.content, tt.inline_buf[0..tt.inline_len])) {
                    tt.content = tt.inline_buf[0..tt.inline_len];
                }
            }
        }
    }

    pub fn setImage(self: *ContentTable, id: ElementId, img: ?ImageProps) void {
        if (id.isNull() or id.index >= self.items.items.len) return;
        self.items.items[id.index].image = img;
    }

    pub fn setIcon(self: *ContentTable, id: ElementId, ic: ?IconProps) void {
        if (id.isNull() or id.index >= self.items.items.len) return;
        self.items.items[id.index].icon = ic;
    }

    /// Cx.destroyElement 调；不缩容 (dense by index)。
    pub fn clear(self: *ContentTable, id: ElementId) void {
        if (id.isNull() or id.index >= self.items.items.len) return;
        self.items.items[id.index] = .{};
    }
};

// ============================================================================
// Tests
// ============================================================================

test "ContentTable: init/deinit empty" {
    var t = ContentTable.init(testing.allocator);
    defer t.deinit();
    try testing.expectEqual(@as(usize, 0), t.items.items.len);
}

test "ContentTable: ensureSlot grows up to index" {
    var t = ContentTable.init(testing.allocator);
    defer t.deinit();

    const id = ElementId{ .index = 3, .generation = 1 };
    try t.ensureSlot(id);
    try testing.expectEqual(@as(usize, 4), t.items.items.len);
    try testing.expect(t.getText(id) == null);
}

test "ContentTable: setText / getText roundtrip with inline_buf fixup" {
    var t = ContentTable.init(testing.allocator);
    defer t.deinit();

    const id = ElementId{ .index = 0, .generation = 1 };
    try t.ensureSlot(id);

    var src_text: TextProps = .{ .font_size = 16 };
    try src_text.setInlineContent("hi");

    t.setText(id, src_text);

    const got = t.getText(id).?;
    try testing.expectEqual(@as(f32, 16), got.font_size);
    try testing.expectEqualSlices(u8, "hi", got.content);
}

test "ContentTable: setImage / setIcon" {
    var t = ContentTable.init(testing.allocator);
    defer t.deinit();

    const id = ElementId{ .index = 0, .generation = 1 };
    try t.ensureSlot(id);

    t.setImage(id, .{ .texture_id = 42 });
    t.setIcon(id, .{ .icon_id = 7, .rep = .{ .size = 24, .shapes = &.{} } });

    const got = t.get(id).?;
    try testing.expectEqual(@as(u32, 42), got.image.?.texture_id);
    try testing.expectEqual(@as(u16, 7), got.icon.?.icon_id);
}

test "ContentTable: clear resets slot" {
    var t = ContentTable.init(testing.allocator);
    defer t.deinit();

    const id = ElementId{ .index = 0, .generation = 1 };
    try t.ensureSlot(id);
    var tp: TextProps = .{};
    try tp.setInlineContent("x");
    t.setText(id, tp);

    t.clear(id);
    try testing.expect(t.getText(id) == null);
}

test "ContentTable: setText frees replaced owned content" {
    var t = ContentTable.init(testing.allocator);
    defer t.deinit();

    const id = ElementId{ .index = 0, .generation = 1 };
    try t.ensureSlot(id);

    const first = try testing.allocator.dupe(u8, "first owned content!");
    t.setText(id, .{ .content = first, .owned = true });

    // 换成新 owned 内容：旧的 first 应被 setText 自动释放（泄漏由 testing.allocator 检测）
    const second = try testing.allocator.dupe(u8, "second owned content");
    t.setText(id, .{ .content = second, .owned = true });
    try testing.expectEqualStrings("second owned content", t.getText(id).?.content);

    // 原样写回同一块内存：不能误 free
    var same = t.getText(id).?;
    same.color = .{ .r = 1, .g = 0, .b = 0, .a = 1 };
    t.setText(id, same);
    try testing.expectEqualStrings("second owned content", t.getText(id).?.content);

    // 收尾：模拟节点销毁路径释放最后一份 owned 内容
    if (t.getText(id)) |last| {
        if (last.owned) testing.allocator.free(last.content);
    }
}

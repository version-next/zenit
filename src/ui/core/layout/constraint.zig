//! Layout Constraints, Taffy-style LayoutInput / AvailableSpace
//!
//! 取代当前 layout_engine.zig 的"先 layout 后 fitResizeAfterLayout 回填"模型。
//! 子算法接收 LayoutInput，返回 LayoutOutput；约束沿父->子方向单向流动，
//! 不再有"父布完后回头读子尺寸再修正自己"的多遍。
//!
//! 历史债避免（吸取 zenit 当前 .fit 三遍修正 + Chromium 早期 layout-thrash 教训）：
//! 1. AvailableSpace 三态枚举（Definite/MinContent/MaxContent）覆盖 CSS 全部约束语义
//! 2. run_mode 区分"只测尺寸"和"真正 layout"两条路径，让 intrinsic 测量走 cache-friendly 短路径
//! 3. known_dimensions 让父能直接传"已知值"避免子重算
//!
//! 设计参照：
//! - Taffy LayoutInput (DioxusLabs/taffy/src/tree/layout.rs)
//! - Flutter BoxConstraints (flutter/lib/src/rendering/box.dart)
//! - CSS § "Available space" / "Min/Max-content contributions"

const std = @import("std");
const testing = std.testing;

/// 一个轴上的可用空间。CSS spec § "available space"。
pub const AvailableSpace = union(enum) {
    /// 明确的浮点像素值
    definite: f32,
    /// "min-content"：内容最小所需（每个 child 取自身 min-content）
    min_content,
    /// "max-content"：内容偏好（每个 child 取自身 max-content）
    max_content,

    pub fn isDefinite(self: AvailableSpace) bool {
        return self == .definite;
    }

    /// 取出确定值；非 definite 返回 fallback
    pub fn definiteOr(self: AvailableSpace, fallback: f32) f32 {
        return switch (self) {
            .definite => |v| v,
            else => fallback,
        };
    }

    /// 减一个确定值后的新 AvailableSpace（child padding/margin 扣除）
    pub fn subtractDefinite(self: AvailableSpace, x: f32) AvailableSpace {
        return switch (self) {
            .definite => |v| .{ .definite = @max(0, v - x) },
            else => self,
        };
    }

    /// 与 max 取较小确定值；非确定不变
    pub fn clampMax(self: AvailableSpace, max: f32) AvailableSpace {
        return switch (self) {
            .definite => |v| .{ .definite = @min(v, max) },
            else => self,
        };
    }
};

/// 二维向量（与现 types.Size / Point 不耦合，避免循环 import）
pub const Vec2 = struct {
    x: f32 = 0,
    y: f32 = 0,

    pub const ZERO: Vec2 = .{};

    pub fn eq(a: Vec2, b: Vec2) bool {
        return a.x == b.x and a.y == b.y;
    }
};

pub const Size2D = struct {
    width: f32 = 0,
    height: f32 = 0,

    pub const ZERO: Size2D = .{};

    pub fn add(a: Size2D, b: Size2D) Size2D {
        return .{ .width = a.width + b.width, .height = a.height + b.height };
    }
};

/// 二维 AvailableSpace
pub const AvailableSpaceXY = struct {
    width: AvailableSpace,
    height: AvailableSpace,

    pub fn definite(w: f32, h: f32) AvailableSpaceXY {
        return .{ .width = .{ .definite = w }, .height = .{ .definite = h } };
    }

    pub fn maxContent() AvailableSpaceXY {
        return .{ .width = .max_content, .height = .max_content };
    }
};

/// 已知维度（父已确定的 child 尺寸；让 child 不必重算自身）。null = 未知。
pub const KnownDimensions = struct {
    width: ?f32 = null,
    height: ?f32 = null,

    pub const NONE: KnownDimensions = .{};
};

/// run_mode = layout 子算法运行模式
/// - perform_layout：完整布局，写入 final_rect、bubble 子树
/// - measure：仅测量返回尺寸；不写入持久化布局结果（用于 intrinsic 探测）
pub const RunMode = enum(u8) {
    perform_layout,
    measure,
};

/// 父->子的布局输入。
pub const LayoutInput = struct {
    /// 父能给我多少空间（每轴一个 AvailableSpace）
    available_space: AvailableSpaceXY,
    /// 父已经替我决定好的尺寸（我不再决定，直接用）
    known_dimensions: KnownDimensions = .{},
    /// 父自身尺寸（用于百分比解析）
    parent_size: Size2D = .{},
    /// 主轴方向（flex/grid 子算法用）
    /// 0 = horizontal/row，1 = vertical/column
    axis: u2 = 0,
    /// 运行模式
    run_mode: RunMode = .perform_layout,

    pub fn forMeasure(available: AvailableSpaceXY) LayoutInput {
        return .{ .available_space = available, .run_mode = .measure };
    }
};

/// 子->父的布局结果。
pub const LayoutOutput = struct {
    /// 测得的内容尺寸（不含 outer margin）
    size: Size2D,
    /// 第一行 baseline 距离 size.height 的 y 偏移；null = 无 baseline 概念
    first_baseline: ?f32 = null,
    /// 最后一行 baseline；用于 align-items: last baseline
    last_baseline: ?f32 = null,

    pub const ZERO: LayoutOutput = .{ .size = Size2D.ZERO };
};

/// Intrinsic size cache，同一节点同输入的 measure 复用结果。
/// 简单 4-entry direct-mapped cache（cache-line 友好；查找 O(1)）。
/// Phase 3 拆 Node 时挂到 LayoutTable 旁。
pub const IntrinsicCache = struct {
    pub const ENTRY_COUNT: usize = 4;

    const Entry = struct {
        valid: bool = false,
        input_hash: u64 = 0,
        output: LayoutOutput = .ZERO,
    };

    entries: [ENTRY_COUNT]Entry = [_]Entry{.{}} ** ENTRY_COUNT,

    pub fn get(self: *const IntrinsicCache, input_hash: u64) ?LayoutOutput {
        const slot = @as(usize, input_hash) % ENTRY_COUNT;
        const e = self.entries[slot];
        if (e.valid and e.input_hash == input_hash) return e.output;
        return null;
    }

    pub fn put(self: *IntrinsicCache, input_hash: u64, output: LayoutOutput) void {
        const slot = @as(usize, input_hash) % ENTRY_COUNT;
        self.entries[slot] = .{
            .valid = true,
            .input_hash = input_hash,
            .output = output,
        };
    }

    pub fn invalidate(self: *IntrinsicCache) void {
        for (&self.entries) |*e| e.valid = false;
    }
};

/// 计算 LayoutInput 的稳定 hash，用于 intrinsic cache 索引。
pub fn hashLayoutInput(input: LayoutInput) u64 {
    var hasher = std.hash.Wyhash.init(0xCAFEBABE);
    hashAvailable(&hasher, input.available_space.width);
    hashAvailable(&hasher, input.available_space.height);
    hashOptF32(&hasher, input.known_dimensions.width);
    hashOptF32(&hasher, input.known_dimensions.height);
    hasher.update(std.mem.asBytes(&input.parent_size.width));
    hasher.update(std.mem.asBytes(&input.parent_size.height));
    hasher.update(&[_]u8{ input.axis, @intFromEnum(input.run_mode) });
    return hasher.final();
}

fn hashAvailable(h: *std.hash.Wyhash, a: AvailableSpace) void {
    switch (a) {
        .definite => |v| {
            h.update(&[_]u8{0});
            h.update(std.mem.asBytes(&v));
        },
        .min_content => h.update(&[_]u8{1}),
        .max_content => h.update(&[_]u8{2}),
    }
}

fn hashOptF32(h: *std.hash.Wyhash, x: ?f32) void {
    if (x) |v| {
        h.update(&[_]u8{1});
        h.update(std.mem.asBytes(&v));
    } else {
        h.update(&[_]u8{0});
    }
}

// ============================================================================
// Tests
// ============================================================================

test "AvailableSpace: definite operations" {
    const a: AvailableSpace = .{ .definite = 100 };
    try testing.expect(a.isDefinite());
    try testing.expectEqual(@as(f32, 100), a.definiteOr(0));

    const b = a.subtractDefinite(30);
    try testing.expectEqual(AvailableSpace{ .definite = 70 }, b);

    const c = a.clampMax(50);
    try testing.expectEqual(AvailableSpace{ .definite = 50 }, c);

    const d = a.subtractDefinite(200);
    try testing.expectEqual(AvailableSpace{ .definite = 0 }, d); // clamp to 0
}

test "AvailableSpace: indefinite operations are no-op" {
    const mc: AvailableSpace = .min_content;
    try testing.expect(!mc.isDefinite());
    try testing.expectEqual(@as(f32, 99), mc.definiteOr(99));

    const after_sub = mc.subtractDefinite(10);
    try testing.expectEqual(AvailableSpace.min_content, after_sub);
}

test "AvailableSpaceXY: constructors" {
    const a = AvailableSpaceXY.definite(100, 200);
    try testing.expectEqual(AvailableSpace{ .definite = 100 }, a.width);
    try testing.expectEqual(AvailableSpace{ .definite = 200 }, a.height);

    const m = AvailableSpaceXY.maxContent();
    try testing.expectEqual(AvailableSpace.max_content, m.width);
}

test "LayoutInput: forMeasure shortcut" {
    const i = LayoutInput.forMeasure(AvailableSpaceXY.maxContent());
    try testing.expectEqual(RunMode.measure, i.run_mode);
}

test "hashLayoutInput: same input → same hash" {
    const a = LayoutInput{
        .available_space = AvailableSpaceXY.definite(100, 200),
        .parent_size = .{ .width = 800, .height = 600 },
    };
    const b = LayoutInput{
        .available_space = AvailableSpaceXY.definite(100, 200),
        .parent_size = .{ .width = 800, .height = 600 },
    };
    try testing.expectEqual(hashLayoutInput(a), hashLayoutInput(b));
}

test "hashLayoutInput: different input → different hash" {
    const a = LayoutInput{ .available_space = AvailableSpaceXY.definite(100, 200) };
    const b = LayoutInput{ .available_space = AvailableSpaceXY.definite(101, 200) };
    try testing.expect(hashLayoutInput(a) != hashLayoutInput(b));
}

test "IntrinsicCache: get/put/invalidate" {
    var cache = IntrinsicCache{};
    const out = LayoutOutput{ .size = .{ .width = 100, .height = 50 } };

    try testing.expect(cache.get(0xDEADBEEF) == null);

    cache.put(0xDEADBEEF, out);
    const got = cache.get(0xDEADBEEF).?;
    try testing.expectEqual(@as(f32, 100), got.size.width);

    cache.invalidate();
    try testing.expect(cache.get(0xDEADBEEF) == null);
}

test "IntrinsicCache: collision overwrites slot" {
    var cache = IntrinsicCache{};
    const out_a = LayoutOutput{ .size = .{ .width = 100, .height = 50 } };
    const out_b = LayoutOutput{ .size = .{ .width = 200, .height = 60 } };

    // 两个 hash 模 ENTRY_COUNT 相等 -> 后者覆盖
    cache.put(0, out_a);
    cache.put(IntrinsicCache.ENTRY_COUNT, out_b);

    try testing.expect(cache.get(0) == null); // 覆盖
    const got = cache.get(IntrinsicCache.ENTRY_COUNT).?;
    try testing.expectEqual(@as(f32, 200), got.size.width);
}

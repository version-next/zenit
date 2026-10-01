/// Phase L3: Text Blob，逻辑布局与渲染缩放分离
///
/// TextStyleKey 唯一标识布局/塑形参数，TextLayoutBlob 保存逻辑字号空间的稳定布局结果。
/// TextRasterPolicy 控制光栅化策略（静态锐利 vs 动画稳定）。
/// BlobStore 是帧级存储，每帧 clear + 重建。
const std = @import("std");
const types = @import("types.zig");
const text_layout_mod = @import("text_layout.zig");

const Allocator = std.mem.Allocator;
const TextWrap = types.TextWrap;
const LineInfo = text_layout_mod.LineInfo;
pub const MAX_LINES = text_layout_mod.MAX_LINES;
const INVALID_BLOB_ID = std.math.maxInt(u32);

/// 光栅化策略
pub const TextRasterPolicy = enum(u8) {
    /// 静态文本：允许子像素变体 + nearest 采样 + 精确字号派生
    static_crisp,
    /// 动画中文本：强制 linear 采样，禁止子像素变体切换
    animated_stable,
    /// 预留：文本先光栅到 layer surface，动画期间只变换 surface
    surface_cached,
};

/// 布局/塑形的唯一标识（缓存键）
pub const TextStyleKey = struct {
    /// 逻辑字号（不乘 scale）
    font_size: f32,
    font_weight: u16,
    /// 字体族 id。**必须进这个 key**，同一段文字换族要重新塑形,
    /// 漏了它会让第二个族命中第一个族的布局缓存(与 shapingKey 同款坑)。
    font_family: u16 = 0,
    line_height: f32,
    use_italic: bool = false,
    use_monospace: bool = false,
    use_symbols: bool = false,
    wrap: TextWrap = .none,
    max_lines: u16 = 0,
};

/// 稳定的布局结果（逻辑字号空间）
pub const TextLayoutBlob = struct {
    style_key: TextStyleKey,
    /// content 的 hash（用于变更检测）
    content_hash: u64,
    /// 当前帧内借用的源文本切片；生命周期受帧约束
    content: []const u8 = "",
    spans_hash: u64 = 0,
    /// 折行结果
    lines: [MAX_LINES]LineInfo = undefined,
    line_count: u16 = 0,
    /// 逻辑空间总高度 (line_count * font_size * line_height)
    total_height: f32 = 0,
    /// 逻辑空间最大行宽
    max_line_width: f32 = 0,
    /// 折行宽度
    wrap_width: f32 = 0,
    /// 在 BlobStore 中的索引
    blob_id: u32 = 0,
    /// 帧内 dedupe 索引里的同指纹链表
    dedupe_next_blob_id: u32 = INVALID_BLOB_ID,
};

fn eqlStyleKey(a: TextStyleKey, b: TextStyleKey) bool {
    return a.font_size == b.font_size and
        a.font_weight == b.font_weight and
        a.font_family == b.font_family and
        a.line_height == b.line_height and
        a.use_italic == b.use_italic and
        a.use_monospace == b.use_monospace and
        a.use_symbols == b.use_symbols and
        a.wrap == b.wrap and
        a.max_lines == b.max_lines;
}

fn eqlBlob(a: TextLayoutBlob, b: TextLayoutBlob) bool {
    if (!eqlStyleKey(a.style_key, b.style_key)) return false;
    if (a.content_hash != b.content_hash) return false;
    if (a.spans_hash != b.spans_hash) return false;
    if (a.line_count != b.line_count) return false;
    if (a.total_height != b.total_height) return false;
    if (a.max_line_width != b.max_line_width) return false;
    if (a.wrap_width != b.wrap_width) return false;
    for (a.lines[0..a.line_count], 0..) |line, i| {
        const other = b.lines[i];
        if (line.byte_start != other.byte_start or line.byte_end != other.byte_end or line.width != other.width) return false;
    }
    return true;
}

fn hashBlobFingerprint(blob: TextLayoutBlob) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(std.mem.asBytes(&blob.style_key.font_size));
    hasher.update(std.mem.asBytes(&blob.style_key.font_weight));
    hasher.update(std.mem.asBytes(&blob.style_key.line_height));
    hasher.update(std.mem.asBytes(&blob.style_key.use_italic));
    hasher.update(std.mem.asBytes(&blob.style_key.use_monospace));
    hasher.update(std.mem.asBytes(&blob.style_key.use_symbols));
    const wrap_tag: u8 = @intFromEnum(blob.style_key.wrap);
    hasher.update(std.mem.asBytes(&wrap_tag));
    hasher.update(std.mem.asBytes(&blob.style_key.max_lines));
    hasher.update(std.mem.asBytes(&blob.content_hash));
    hasher.update(std.mem.asBytes(&blob.spans_hash));
    hasher.update(std.mem.asBytes(&blob.line_count));
    hasher.update(std.mem.asBytes(&blob.total_height));
    hasher.update(std.mem.asBytes(&blob.max_line_width));
    hasher.update(std.mem.asBytes(&blob.wrap_width));
    for (blob.lines[0..blob.line_count]) |line| {
        hasher.update(std.mem.asBytes(&line.byte_start));
        hasher.update(std.mem.asBytes(&line.byte_end));
        hasher.update(std.mem.asBytes(&line.width));
    }
    return hasher.final();
}

/// 帧级 blob 存储
pub const BlobStore = struct {
    allocator: Allocator,
    blobs: std.ArrayList(TextLayoutBlob),
    blob_index: std.AutoHashMapUnmanaged(u64, u32),

    pub fn init(allocator: Allocator) BlobStore {
        return .{
            .allocator = allocator,
            .blobs = .{},
            .blob_index = .{},
        };
    }

    pub fn deinit(self: *BlobStore) void {
        self.blobs.deinit(self.allocator);
        self.blob_index.deinit(self.allocator);
    }

    pub fn clear(self: *BlobStore) void {
        self.blobs.clearRetainingCapacity();
        self.blob_index.clearRetainingCapacity();
    }

    /// 追加 blob，返回其 blob_id
    pub fn append(self: *BlobStore, blob: TextLayoutBlob) !u32 {
        const id: u32 = @intCast(self.blobs.items.len);
        var b = blob;
        b.blob_id = id;
        try self.blobs.append(self.allocator, b);
        return id;
    }

    pub const AppendOrReuseResult = struct {
        blob_id: u32,
        reused: bool,
    };

    pub fn appendOrReuseTracked(self: *BlobStore, blob: TextLayoutBlob) !AppendOrReuseResult {
        const fingerprint = hashBlobFingerprint(blob);
        // 头指针可能悬空：paint pass 的双发射守卫会把 blobs 截断回
        // subtree_blob_start（render_engine/mod.zig renderNodeTransform），
        // 但 index 里指向被截断区间的表项还在，直接解引用越界 panic
        // （线上 crash 实证：appendOrReuseTracked +336 outOfBounds）。
        // 链上 id 严格递减（新头指向旧头），存活 blob 只会链到更早、
        // 必然也存活的 blob，所以只需守卫头指针这一处。
        const raw_head_id = self.blob_index.get(fingerprint);
        const head_blob_id: ?u32 = if (raw_head_id) |id|
            (if (id < self.blobs.items.len) id else null)
        else
            null;
        if (head_blob_id) |head_id| {
            var candidate_id = head_id;
            while (candidate_id != INVALID_BLOB_ID) {
                const existing = self.blobs.items[candidate_id];
                if (eqlBlob(existing, blob)) {
                    return .{
                        .blob_id = existing.blob_id,
                        .reused = true,
                    };
                }
                candidate_id = existing.dedupe_next_blob_id;
            }
        }

        var next_blob = blob;
        next_blob.dedupe_next_blob_id = head_blob_id orelse INVALID_BLOB_ID;
        const blob_id = try self.append(next_blob);
        try self.blob_index.put(self.allocator, fingerprint, blob_id);
        return .{
            .blob_id = blob_id,
            .reused = false,
        };
    }

    pub fn get(self: *const BlobStore, blob_id: u32) ?TextLayoutBlob {
        if (blob_id < self.blobs.items.len) {
            return self.blobs.items[blob_id];
        }
        return null;
    }

    pub fn slice(self: *const BlobStore, start: usize, count: usize) []const TextLayoutBlob {
        const clamped_start = @min(start, self.blobs.items.len);
        const clamped_end = @min(clamped_start + count, self.blobs.items.len);
        return self.blobs.items[clamped_start..clamped_end];
    }
};

test "BlobStore: blobs 被子树回滚截断后，同指纹查询不越界" {
    // 复现线上 SIGABRT：renderNodeTransform 的双发射守卫
    // shrinkRetainingCapacity(blobs) 不回滚 blob_index，
    // 同帧内相同指纹的文本再次查询会拿到 >= blobs.len 的悬空头指针。
    var store = BlobStore.init(std.testing.allocator);
    defer store.deinit();

    var blob = TextLayoutBlob{
        .style_key = .{
            .font_size = 13,
            .font_weight = 400,
            .line_height = 1.35,
            .wrap = .none,
        },
        .content_hash = std.hash.Wyhash.hash(0, "prompt"),
        .content = "prompt",
        .line_count = 1,
        .total_height = 17.55,
        .max_line_width = 46.8,
        .wrap_width = 0,
    };
    blob.lines[0] = .{ .byte_start = 0, .byte_end = 6, .width = 46.8 };

    const first = try store.appendOrReuseTracked(blob);
    try std.testing.expect(!first.reused);

    // 模拟 paint pass 的子树回滚：只截断 blobs，不动 index
    store.blobs.shrinkRetainingCapacity(0);

    // 修复前这里 index-out-of-bounds panic；修复后按未命中处理、重新追加
    const second = try store.appendOrReuseTracked(blob);
    try std.testing.expect(!second.reused);
    try std.testing.expectEqual(@as(u32, 0), second.blob_id);
    try std.testing.expectEqual(@as(usize, 1), store.blobs.items.len);
}

test "BlobStore reuses identical blobs without scanning every existing entry" {
    var store = BlobStore.init(std.testing.allocator);
    defer store.deinit();

    var first = TextLayoutBlob{
        .style_key = .{
            .font_size = 16,
            .font_weight = 400,
            .line_height = 1.25,
            .wrap = .word,
        },
        .content_hash = std.hash.Wyhash.hash(0, "shared"),
        .content = "shared",
        .line_count = 1,
        .total_height = 20,
        .max_line_width = 48,
        .wrap_width = 120,
    };
    first.lines[0] = .{ .byte_start = 0, .byte_end = 6, .width = 48 };

    const first_result = try store.appendOrReuseTracked(first);
    const second_result = try store.appendOrReuseTracked(first);

    try std.testing.expect(!first_result.reused);
    try std.testing.expect(second_result.reused);
    try std.testing.expectEqual(first_result.blob_id, second_result.blob_id);
    try std.testing.expectEqual(@as(usize, 1), store.blobs.items.len);
}

test "BlobStore clear resets dedupe index" {
    var store = BlobStore.init(std.testing.allocator);
    defer store.deinit();

    var blob = TextLayoutBlob{
        .style_key = .{
            .font_size = 14,
            .font_weight = 500,
            .line_height = 1.2,
            .wrap = .none,
        },
        .content_hash = std.hash.Wyhash.hash(0, "clear-me"),
        .content = "clear-me",
        .line_count = 1,
        .total_height = 16.8,
        .max_line_width = 40,
        .wrap_width = 0,
    };
    blob.lines[0] = .{ .byte_start = 0, .byte_end = 8, .width = 40 };

    _ = try store.appendOrReuseTracked(blob);
    store.clear();
    const after_clear = try store.appendOrReuseTracked(blob);

    try std.testing.expect(!after_clear.reused);
    try std.testing.expectEqual(@as(u32, 0), after_clear.blob_id);
    try std.testing.expectEqual(@as(usize, 1), store.blobs.items.len);
}

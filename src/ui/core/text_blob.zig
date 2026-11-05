/// Text Blob: logical layout and render scale are separate.
///
/// TextStyleKey uniquely identifies layout/shaping parameters; TextLayoutBlob holds stable
/// layout result in logical font-size space. TextRasterPolicy controls rasterization strategy
/// (static sharp vs animation stable). BlobStore is frame-local storage, cleared + rebuilt each
/// frame.
const std = @import("std");
const types = @import("types.zig");
const text_layout_mod = @import("text_layout.zig");

const Allocator = std.mem.Allocator;
const TextWrap = types.TextWrap;
pub const LineInfo = text_layout_mod.LineInfo;
pub const MAX_LINES = text_layout_mod.MAX_LINES;
const INVALID_BLOB_ID = std.math.maxInt(u32);

/// Rasterization strategy
pub const TextRasterPolicy = enum(u8) {
    /// Static text: allow subpixel variants + nearest sampling + exact font-size derivative
    static_crisp,
    /// Text in animation: force linear sampling, forbid subpixel variant switching
    animated_stable,
    /// Reserved: rasterize text to layer surface, animate surface only
    surface_cached,
};

/// Unique identifier for layout/shaping (cache key)
pub const TextStyleKey = struct {
    /// Logical font size (not scaled)
    font_size: f32,
    font_weight: u16,
    /// Font family id. **Must enter this key**: same text, different family needs reshape;
    /// omit it -> second family hits first family's layout cache (same bug as shapingKey).
    font_family: u16 = 0,
    line_height: f32,
    use_italic: bool = false,
    use_monospace: bool = false,
    use_symbols: bool = false,
    wrap: TextWrap = .none,
    max_lines: u16 = 0,
};

/// Stable layout result (logical font-size space)
pub const TextLayoutBlob = struct {
    style_key: TextStyleKey,
    /// content hash (used for change detection)
    content_hash: u64,
    /// Source text slice borrowed this frame; lifetime frame-bound
    content: []const u8 = "",
    spans_hash: u64 = 0,
    /// Line-break result: `line_count` lines at `lines_start` in the owning
    /// BlobStore (BlobStore.lines). Stored out of line: an inline
    /// MAX_LINES table made every blob 12 KiB.
    lines_start: u32 = 0,
    line_count: u16 = 0,
    /// Total height in logical space (line_count * font_size * line_height)
    total_height: f32 = 0,
    /// Max line width in logical space
    max_line_width: f32 = 0,
    /// Line-break width
    wrap_width: f32 = 0,
    /// Index in BlobStore
    blob_id: u32 = 0,
    /// In-frame dedupe index, same-fingerprint chain link
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

fn eqlBlob(a: TextLayoutBlob, a_lines: []const LineInfo, b: TextLayoutBlob, b_lines: []const LineInfo) bool {
    if (!eqlStyleKey(a.style_key, b.style_key)) return false;
    if (a.content_hash != b.content_hash) return false;
    if (a.spans_hash != b.spans_hash) return false;
    if (a.line_count != b.line_count) return false;
    if (a.total_height != b.total_height) return false;
    if (a.max_line_width != b.max_line_width) return false;
    if (a.wrap_width != b.wrap_width) return false;
    if (a_lines.len != b_lines.len) return false;
    for (a_lines, b_lines) |line, other| {
        if (line.byte_start != other.byte_start or line.byte_end != other.byte_end or line.width != other.width) return false;
    }
    return true;
}

fn hashBlobFingerprint(blob: TextLayoutBlob, lines: []const LineInfo) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(std.mem.asBytes(&blob.style_key.font_size));
    hasher.update(std.mem.asBytes(&blob.style_key.font_weight));
    hasher.update(std.mem.asBytes(&blob.style_key.line_height));
    hasher.update(std.mem.asBytes(&blob.style_key.use_italic));
    hasher.update(std.mem.asBytes(&blob.style_key.use_monospace));
    hasher.update(std.mem.asBytes(&blob.style_key.use_symbols));
    const wrap_tag: u8 = @backingInt(blob.style_key.wrap);
    hasher.update(std.mem.asBytes(&wrap_tag));
    hasher.update(std.mem.asBytes(&blob.style_key.max_lines));
    hasher.update(std.mem.asBytes(&blob.content_hash));
    hasher.update(std.mem.asBytes(&blob.spans_hash));
    hasher.update(std.mem.asBytes(&blob.line_count));
    hasher.update(std.mem.asBytes(&blob.total_height));
    hasher.update(std.mem.asBytes(&blob.max_line_width));
    hasher.update(std.mem.asBytes(&blob.wrap_width));
    for (lines) |line| {
        hasher.update(std.mem.asBytes(&line.byte_start));
        hasher.update(std.mem.asBytes(&line.byte_end));
        hasher.update(std.mem.asBytes(&line.width));
    }
    return hasher.final();
}

/// Frame-local blob storage
pub const BlobStore = struct {
    allocator: Allocator,
    blobs: std.ArrayList(TextLayoutBlob),
    line_storage: std.ArrayList(LineInfo) = .empty,
    blob_index: std.AutoHashMapUnmanaged(u64, u32),

    pub fn init(allocator: Allocator) BlobStore {
        return .{
            .allocator = allocator,
            .blobs = .empty,
            .blob_index = .{},
        };
    }

    pub fn deinit(self: *BlobStore) void {
        self.blobs.deinit(self.allocator);
        self.line_storage.deinit(self.allocator);
        self.blob_index.deinit(self.allocator);
    }

    pub fn clear(self: *BlobStore) void {
        self.blobs.clearRetainingCapacity();
        self.line_storage.clearRetainingCapacity();
        self.blob_index.clearRetainingCapacity();
    }

    /// Append blob with its lines, return its blob_id
    pub fn append(self: *BlobStore, blob: TextLayoutBlob, blob_lines: []const LineInfo) !u32 {
        const id: u32 = @intCast(self.blobs.items.len);
        var b = blob;
        b.blob_id = id;
        b.lines_start = @intCast(self.line_storage.items.len);
        b.line_count = @intCast(blob_lines.len);
        try self.line_storage.appendSlice(self.allocator, blob_lines);
        errdefer self.line_storage.shrinkRetainingCapacity(b.lines_start);
        try self.blobs.append(self.allocator, b);
        return id;
    }

    /// Lines of a blob held by this store.
    pub fn lines(self: *const BlobStore, blob: TextLayoutBlob) []const LineInfo {
        const start = @min(blob.lines_start, self.line_storage.items.len);
        const end = @min(start + blob.line_count, self.line_storage.items.len);
        return self.line_storage.items[start..end];
    }

    pub const AppendOrReuseResult = struct {
        blob_id: u32,
        reused: bool,
    };

    /// `blob_lines` are the candidate's lines (`line_count` is taken from them).
    pub fn appendOrReuseTracked(self: *BlobStore, blob_in: TextLayoutBlob, blob_lines: []const LineInfo) !AppendOrReuseResult {
        var blob = blob_in;
        blob.line_count = @intCast(blob_lines.len);
        const fingerprint = hashBlobFingerprint(blob, blob_lines);
        // Head pointer may dangle: the paint pass dual-emit guard truncates blobs back to
        // subtree_blob_start (render_engine/mod.zig renderNodeTransform), but index entries
        // pointing into the truncated range remain; dereferencing directly panics out-of-bounds
        // (appendOrReuseTracked). On the chain, id strictly decreases (new head -> old head); an
        // alive
        // blob only chains to earlier, hence alive, blobs; so guard the head pointer only here.
        const raw_head_id = self.blob_index.get(fingerprint);
        const head_blob_id: ?u32 = if (raw_head_id) |id|
            (if (id < self.blobs.items.len) id else null)
        else
            null;
        if (head_blob_id) |head_id| {
            var candidate_id = head_id;
            while (candidate_id != INVALID_BLOB_ID) {
                const existing = self.blobs.items[candidate_id];
                if (eqlBlob(existing, self.lines(existing), blob, blob_lines)) {
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
        const blob_id = try self.append(next_blob, blob_lines);
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
    // Reproduce on-line SIGABRT: renderNodeTransform dual-emit guard
    // shrinkRetainingCapacity(blobs) doesn't roll back blob_index;
    // same-fingerprint text later in frame reads >= blobs.len dangling head.
    var store = BlobStore.init(std.testing.allocator);
    defer store.deinit();

    const blob = TextLayoutBlob{
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
    const blob_lines = [_]LineInfo{.{ .byte_start = 0, .byte_end = 6, .width = 46.8 }};

    const first = try store.appendOrReuseTracked(blob, &blob_lines);
    try std.testing.expect(!first.reused);

    // Simulate paint-pass subtree rollback: truncate blobs only, don't touch index
    store.blobs.shrinkRetainingCapacity(0);

    // Pre-fix here index-out-of-bounds panic; post-fix treat as miss, re-append
    const second = try store.appendOrReuseTracked(blob, &blob_lines);
    try std.testing.expect(!second.reused);
    try std.testing.expectEqual(@as(u32, 0), second.blob_id);
    try std.testing.expectEqual(@as(usize, 1), store.blobs.items.len);
}

test "BlobStore reuses identical blobs without scanning every existing entry" {
    var store = BlobStore.init(std.testing.allocator);
    defer store.deinit();

    const first = TextLayoutBlob{
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
    const first_lines = [_]LineInfo{.{ .byte_start = 0, .byte_end = 6, .width = 48 }};

    const first_result = try store.appendOrReuseTracked(first, &first_lines);
    const second_result = try store.appendOrReuseTracked(first, &first_lines);

    try std.testing.expect(!first_result.reused);
    try std.testing.expect(second_result.reused);
    try std.testing.expectEqual(first_result.blob_id, second_result.blob_id);
    try std.testing.expectEqual(@as(usize, 1), store.blobs.items.len);
}

test "BlobStore clear resets dedupe index" {
    var store = BlobStore.init(std.testing.allocator);
    defer store.deinit();

    const blob = TextLayoutBlob{
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
    const blob_lines = [_]LineInfo{.{ .byte_start = 0, .byte_end = 8, .width = 40 }};

    _ = try store.appendOrReuseTracked(blob, &blob_lines);
    store.clear();
    const after_clear = try store.appendOrReuseTracked(blob, &blob_lines);

    try std.testing.expect(!after_clear.reused);
    try std.testing.expectEqual(@as(u32, 0), after_clear.blob_id);
    try std.testing.expectEqual(@as(usize, 1), store.blobs.items.len);
}

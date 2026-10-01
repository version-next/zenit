/// WrapMap，通用 Soft Wrap 映射
///
/// 维护 buffer line -> display line 映射。每个 display line 固定行高，
/// wrap 只改变一个 buffer line 占几个 display line。
///
/// 泛型参数 Doc: 任何提供以下 read-only API 的文档类型:
///   lineCount() -> usize
///   totalLength() -> usize
///   getLineStart(line) -> usize
///   getLineLength(line) -> usize
///   getTextBuf(start, len, buf) -> ![]const u8
///   getTextAlloc(alloc, start, len) -> ![]const u8
///
/// Phase 1B: Fenwick Tree 加速前缀和
/// - applyEdit 行数不变时: O(K·logN) 增量更新（替代 O(N) rebuildPrefixSums）
/// - bufferLineToDisplayLine: O(logN)（原 prefix_sums O(1)，但调用频率低）
/// - displayLineInfo: O(logN)（原二分查找也是 O(logN)）
const std = @import("std");
const Allocator = std.mem.Allocator;
const FenwickTree = @import("fenwick_tree.zig").FenwickTree;
const prepared_wrap_line = @import("prepared_wrap_line.zig");
const PreparedWrapLine = prepared_wrap_line.PreparedWrapLine;
const grapheme = @import("grapheme.zig");
const i18n = @import("i18n");

fn saturatingU32(value: usize) u32 {
    return @intCast(@min(value, std.math.maxInt(u32)));
}

fn displayLineDelta(old: u32, new: u32) i32 {
    const delta = @as(i64, new) - @as(i64, old);
    return @intCast(std.math.clamp(delta, std.math.minInt(i32), std.math.maxInt(i32)));
}

/// 取一个 grapheme cluster 切片的首个码点（断行规则只看簇首码点，
/// 与渲染端 text_layout.decodeUtf8 的取法一致）。
fn firstCodepoint(cluster: []const u8) u21 {
    if (cluster.len == 0) return 0;
    const len = std.unicode.utf8ByteSequenceLength(cluster[0]) catch return 0xFFFD;
    if (len > cluster.len) return 0xFFFD;
    return std.unicode.utf8Decode(cluster[0..len]) catch 0xFFFD;
}

/// 文本宽度测量函数（与 UIContext.measure_fn 签名一致）
pub const MeasureFn = *const fn ([*]const u8, usize, f32, u16, bool) f32;
pub const MeasureCtxFn = *const fn (*anyopaque, [*]const u8, usize, f32, u16, bool) f32;

/// 单个 buffer line 的 wrap 信息
pub const WrapEntry = struct {
    /// wrap 断点字节偏移列表（相对于行首）
    /// N 个断点 -> N+1 个 display line
    breaks: []u32 = &.{},
    /// 断点是否由 WrapMap 分配（需要 free）
    owned: bool = false,
    /// 宽度无关的预处理段缓存，用于宽度变化时避免重新扫全文
    prepared: ?*PreparedWrapLine = null,
    /// 本行的 breaks 是否为 interpolated 占位（wrap 未精确计算，下一帧 rewrap）
    is_interpolated: bool = false,
};

/// 编辑 / rewrap 产生的脏区 patch。下游（DisplaySnapshot / HighlightSnapshot）
/// 消费此 patch 决定如何失效。
pub const WrapPatch = struct {
    /// 受影响的 buffer_line 范围（半开区间）
    dirty_start_line: u32,
    dirty_end_line: u32,
    /// display_line 总数变化（+ / -）
    display_delta: i32,
    /// WrapMap revision（snapshot 版本号，单调递增）
    revision: u64,
    /// 该 patch 是由 wrap width / toggle 变化产生的（影响全文）
    is_global: bool = false,
};

/// Display 行信息（由 displayLineInfo 返回）
pub const DisplayLineInfo = struct {
    /// 对应的 buffer 行号
    buffer_line: usize,
    /// 在该 buffer line 中的 wrap 索引（0 = 首行）
    wrap_index: usize,
    /// 与当前 display line 对应的 segment 起止索引。
    /// 当前 wrap 路径下等价于单个 wrap 段；供上层 long-line 显示层复用。
    segment_start_index: usize = 0,
    segment_end_index: usize = 1,
    /// 该 display line 在 buffer line 内的起始字节偏移
    byte_start: usize,
    /// 该 display line 在 buffer line 内的结束字节偏移
    byte_end: usize,
};

/// Display 坐标（buffer 坐标转换结果）
pub const DisplayPoint = struct {
    display_line: u32,
    display_col: usize, // 相对于 display line 起始的字节偏移
};

pub const BufferLineRange = struct {
    start: usize,
    end: usize,
};

pub const DisplayLineRange = struct {
    start: usize,
    end: usize,
};

/// WrapMap，通用 Soft Wrap 映射
/// Doc: 任何提供 lineCount/getLineStart/getLineLength/getTextBuf/getTextAlloc/totalLength 的类型
/// 从 Doc 类型推断 snapshot 返回值的 payload 类型
/// 位置 i 之前那个**字符**的首字节（跳过 UTF-8 continuation 字节）。
/// wrap 断词的"CJK/emoji 之后可断"规则必须看前一字符的 lead byte,
/// 直接看 text[i-1] 对多字节字符拿到的是 continuation（<0xE0），规则永不生效，
/// 导致 "，后跟拉丁词" 时断点退到 "，" 之前：标点被推去下一行行首，
/// 与渲染端的折行不一致（选区矩形/光标整段错位）。
fn prevCharLead(text: []const u8, i: usize) u8 {
    var j = i;
    while (j > 0) {
        j -= 1;
        if ((text[j] & 0xC0) != 0x80) return text[j];
    }
    return 0;
}

fn SnapshotType(comptime Doc: type) type {
    // snapshot(self: *const Doc, alloc: Allocator) !SomeSnapshot
    const SnapshotFn = @TypeOf(Doc.snapshot);
    const ret = @typeInfo(SnapshotFn).@"fn".return_type.?;
    // strip error union
    return switch (@typeInfo(ret)) {
        .error_union => |eu| eu.payload,
        else => ret,
    };
}

pub fn WrapMap(comptime Doc: type) type {
    // Doc 必须提供 snapshot API 才能支持后台 rewrap
    const has_snapshot = @hasDecl(Doc, "snapshot");

    return struct {
        const Self = @This();
        pub const SupportsAsync = has_snapshot;

        allocator: Allocator,
        enabled: bool = false,
        wrap_width: f32 = 0,

        /// 每个 buffer line 的 wrap 断点
        line_wraps: std.ArrayListUnmanaged(WrapEntry) = .{},

        /// Fenwick Tree: 每个 buffer line 的 display line 数作为值
        /// prefixSum(i) = 前 i+1 个 buffer line 的 display line 总数
        fenwick: ?FenwickTree = null,

        total_display_lines: u32 = 0,
        measure_fn: ?MeasureFn = null,
        /// Context-aware measurement for per-window font systems. Preferred
        /// over `measure_fn` when both are present.
        measure_ctx_fn: ?MeasureCtxFn = null,
        measure_ctx: ?*anyopaque = null,
        font_size: f32 = 14,
        font_weight: u16 = 400,
        /// 等宽字体的单字符宽度（ASCII），用于快速 wrap 计算
        char_width: f32 = 0,
        /// 是否启用精确换行（逐字符真实测量，精度高但更慢）
        precise_wrap: bool = false,
        /// Tab 展开大小（默认 4）
        tab_size: usize = 4,

        // ── Interpolation / Patch 状态 ──
        /// snapshot 版本号：每次产生 patch（apply edit / rewrap / width change）递增
        revision: u64 = 0,
        /// 待消费的 patch（主线程每帧 takePendingPatch）
        pending_patch: ?WrapPatch = null,
        /// 当前有 interpolated 行 -> 下一帧需要做精确 rewrap
        has_interpolated_lines: bool = false,
        /// Structural allocation failed: use a coherent 1:1 mapping until retry.
        needs_rebuild: bool = false,

        // ── 后台 rewrap 状态（仅当 Doc 提供 snapshot 时启用）──
        bg_thread: if (has_snapshot) ?std.Thread else void = if (has_snapshot) null else {},
        bg_done: if (has_snapshot) std.atomic.Value(bool) else void = if (has_snapshot) std.atomic.Value(bool).init(false) else {},
        /// 后台返回的 (buffer_line, breaks) 结果列表
        bg_result: if (has_snapshot) std.ArrayListUnmanaged(BgRewrapResult) else void = if (has_snapshot) .{} else {},
        /// 启动后台任务时的参数快照
        bg_doc_snapshot: if (has_snapshot) ?SnapshotType(Doc) else void = if (has_snapshot) null else {},
        bg_wrap_width: f32 = 0,
        bg_wrap_columns: usize = 0,
        bg_tab_size: usize = 0,
        bg_char_width: f32 = 0,
        /// 启动时的文档 edit_version（stale 校验）
        bg_doc_version: u64 = 0,
        /// 启动时的 WrapMap revision（stale 校验）
        bg_base_revision: u64 = 0,

        pub const BgRewrapResult = struct {
            buffer_line: u32,
            breaks: []u32, // owned by WrapMap.allocator
        };

        pub fn init(allocator: Allocator) Self {
            var self = Self{ .allocator = allocator };
            if (has_snapshot) {
                self.bg_done = std.atomic.Value(bool).init(false);
            }
            return self;
        }

        fn hasPreciseMeasure(self: *const Self) bool {
            return self.measure_ctx_fn != null or self.measure_fn != null;
        }

        pub fn deinit(self: *Self) void {
            if (has_snapshot) {
                if (self.bg_thread) |t| t.join();
                for (self.bg_result.items) |*r| {
                    if (r.breaks.len > 0) self.allocator.free(r.breaks);
                }
                self.bg_result.deinit(self.allocator);
                if (self.bg_doc_snapshot) |*s| s.deinit();
            }
            for (self.line_wraps.items) |*entry| {
                self.freeWrapEntry(entry);
            }
            self.line_wraps.deinit(self.allocator);
            if (self.fenwick) |*ft| ft.deinit();
        }

        // ── Patch API ──

        /// 拉取并清空待消费的 patch
        pub fn takePendingPatch(self: *Self) ?WrapPatch {
            const p = self.pending_patch;
            self.pending_patch = null;
            return p;
        }

        /// 合并/发出 patch
        fn emitPatch(self: *Self, dirty_start: u32, dirty_end: u32, display_delta: i32, is_global: bool) void {
            self.revision +%= 1;
            if (self.pending_patch) |*p| {
                // 合并多个 patch：取范围并集 + 累加 delta
                p.dirty_start_line = @min(p.dirty_start_line, dirty_start);
                p.dirty_end_line = @max(p.dirty_end_line, dirty_end);
                p.display_delta +|= display_delta;
                p.revision = self.revision;
                p.is_global = p.is_global or is_global;
            } else {
                self.pending_patch = .{
                    .dirty_start_line = dirty_start,
                    .dirty_end_line = dirty_end,
                    .display_delta = display_delta,
                    .revision = self.revision,
                    .is_global = is_global,
                };
            }
        }

        /// 设置 wrap 宽度。
        ///
        /// **不再同步全量重算**：只更新 width 参数 + 标记所有行 interpolated + emit global patch。
        /// 调用方（editor_before_render）负责在下一帧调 `rewrapInterpolated(budget_us)` 做精确收敛，
        /// 或 `startBackgroundRewrap()` 进后台。
        pub fn setWrapWidth(self: *Self, width: f32, doc: *const Doc) void {
            if (@abs(self.wrap_width - width) < 1.0) return;
            self.wrap_width = width;
            if (!self.enabled) return;
            self.markAllInterpolated();
            self.emitPatch(0, @intCast(doc.lineCount()), 0, true);
        }

        /// 启用/禁用 wrap。
        ///
        /// **不再同步全量重算**：启用时初始化 entries（每行 breaks=&.{} + interpolated=true），
        /// 禁用时清空。精确 wrap 计算延迟到 `rewrapInterpolated`。
        pub fn setEnabled(self: *Self, enabled: bool, doc: *const Doc) void {
            if (self.enabled == enabled and !self.needs_rebuild) return;
            const old_total = self.total_display_lines;
            self.enabled = enabled;
            self.clearAll(doc.lineCount());
            if (enabled) {
                self.line_wraps.ensureTotalCapacity(self.allocator, doc.lineCount()) catch {
                    self.needs_rebuild = true;
                    self.has_interpolated_lines = doc.lineCount() > 0;
                    self.emitPatch(0, saturatingU32(doc.lineCount()), displayLineDelta(old_total, self.total_display_lines), true);
                    return;
                };
                for (0..doc.lineCount()) |_| self.line_wraps.appendAssumeCapacity(.{ .is_interpolated = true });
                self.rebuildFenwickFromWraps();
                self.has_interpolated_lines = doc.lineCount() > 0;
            }
            self.emitPatch(0, saturatingU32(doc.lineCount()), displayLineDelta(old_total, self.total_display_lines), true);
        }

        /// 把所有行标记 interpolated（wrap width 变化时使用）
        fn markAllInterpolated(self: *Self) void {
            for (self.line_wraps.items) |*entry| entry.is_interpolated = true;
            self.has_interpolated_lines = self.needs_rebuild or self.line_wraps.items.len > 0;
        }

        /// 全量重算所有行
        pub fn rebuildAll(self: *Self, doc: *const Doc) void {
            // Publish a global patch and invalidate older background results.
            const old_total = self.total_display_lines;
            defer self.emitPatch(0, saturatingU32(doc.lineCount()), displayLineDelta(old_total, self.total_display_lines), true);
            if (!self.enabled) {
                self.clearAll(doc.lineCount());
                return;
            }
            var next: std.ArrayListUnmanaged(WrapEntry) = .{};
            next.ensureTotalCapacity(self.allocator, doc.lineCount()) catch {
                self.clearAll(doc.lineCount());
                self.needs_rebuild = true;
                self.has_interpolated_lines = doc.lineCount() > 0;
                return;
            };
            var pending = false;
            for (0..doc.lineCount()) |idx| {
                const entry = self.wrapSingleLine(doc, idx);
                next.appendAssumeCapacity(entry);
                pending = pending or entry.is_interpolated;
            }
            for (self.line_wraps.items) |*entry| self.freeWrapEntry(entry);
            self.line_wraps.deinit(self.allocator);
            self.line_wraps = next;
            self.needs_rebuild = false;
            self.has_interpolated_lines = pending;
            self.rebuildFenwickFromWraps();
        }

        /// 从 display_counts 重建 Fenwick Tree
        fn rebuildFenwick(self: *Self, display_counts: []const u32) void {
            if (self.fenwick) |*ft| ft.deinit();
            self.fenwick = FenwickTree.buildFrom(self.allocator, display_counts) catch null;
            if (self.fenwick) |ft| {
                self.total_display_lines = ft.total();
            } else {
                // fallback: 累加
                var total: u32 = 0;
                for (display_counts) |c| total +|= c;
                self.total_display_lines = total;
            }
        }

        /// 清空 wrap（禁用时恢复 1:1 映射）
        fn clearAll(self: *Self, line_count: usize) void {
            for (self.line_wraps.items) |*entry| self.freeWrapEntry(entry);
            self.line_wraps.clearRetainingCapacity();
            if (self.fenwick) |*ft| ft.deinit();
            self.fenwick = null;
            self.total_display_lines = saturatingU32(line_count);
            self.needs_rebuild = false;
            self.has_interpolated_lines = false;
        }

        /// 增量编辑：**只做 interpolation**，不做精确 wrap 计算。
        ///
        /// 编辑产生的所有受影响行被标记为 `is_interpolated=true`，
        /// breaks 保持旧值（坐标仍然可用，但 wrap 位置可能陈旧）。
        /// 精确 wrap 交由下一帧 `rewrapInterpolated(budget_us)` 完成，
        /// 预算不够的行交给 `startBackgroundRewrap`。
        ///
        /// 时间复杂度：O(K) 行数变化 + O(N) fenwick 重建（仅当行数变化时）。
        /// 行数不变时：O(K) fenwick set（K = 受影响行数），零 wrap 计算。
        pub fn applyEdit(self: *Self, doc: *const Doc, start_line: usize, old_line_count: usize, new_line_count: usize) void {
            if (!self.enabled) {
                // wrap 禁用时维护 1:1 映射，只增量调整 line_wraps 数组和 fenwick
                self.applyEditDisabled(doc.lineCount(), start_line, old_line_count, new_line_count);
                return;
            }

            const old_total = self.total_display_lines;
            const new_doc_lines = doc.lineCount();
            const expected_old_lines: ?usize = blk: {
                if (new_line_count > new_doc_lines) break :blk null;
                break :blk std.math.add(usize, new_doc_lines - new_line_count, old_line_count) catch null;
            };
            const valid_edit = if (expected_old_lines) |old_lines|
                self.line_wraps.items.len == old_lines and
                    start_line <= old_lines and old_line_count <= old_lines - start_line and
                    start_line <= new_doc_lines and new_line_count <= new_doc_lines - start_line
            else
                false;
            if (!valid_edit) {
                self.rebuildAll(doc);
                return;
            }

            if (old_line_count == new_line_count) {
                // 行数不变：只标记受影响行 interpolated；wrap 不变化则 display_delta = 0
                const total_lines = doc.lineCount();
                const end = @min(start_line + new_line_count, total_lines);
                for (@min(start_line, end)..end) |i| {
                    if (i < self.line_wraps.items.len) {
                        self.markInterpolated(i);
                    }
                }
            } else if (new_line_count > old_line_count) {
                // 行数增加：插入空 entry + 标记整个编辑段为 interpolated
                const added = new_line_count - old_line_count;
                const insert_at = start_line + old_line_count;
                self.line_wraps.ensureTotalCapacity(self.allocator, new_doc_lines) catch {
                    self.clearAll(new_doc_lines);
                    self.needs_rebuild = true;
                    self.has_interpolated_lines = new_doc_lines > 0;
                    self.emitPatch(0, saturatingU32(new_doc_lines), displayLineDelta(old_total, self.total_display_lines), true);
                    return;
                };
                for (0..added) |j| {
                    self.line_wraps.insert(self.allocator, insert_at + j, .{
                        .is_interpolated = true,
                    }) catch {
                        // OOM: 回退到 rebuild（罕见）
                        self.rebuildAll(doc);
                        return;
                    };
                }
                // 编辑段内所有旧行也 interpolated
                const old_end = @min(start_line + old_line_count, self.line_wraps.items.len);
                for (start_line..old_end) |i| {
                    self.markInterpolated(i);
                }

                // fenwick 需要 resize
                self.rebuildFenwickFromWraps();
            } else {
                // 行数减少
                const removed = old_line_count - new_line_count;
                const remove_start = start_line + new_line_count;
                const remove_end = @min(remove_start + removed, self.line_wraps.items.len);
                for (remove_start..remove_end) |i| {
                    self.freeWrapEntry(&self.line_wraps.items[i]);
                }
                var k: usize = 0;
                while (k < removed and remove_start < self.line_wraps.items.len) : (k += 1) {
                    _ = self.line_wraps.orderedRemove(remove_start);
                }

                // 剩余编辑段内行标记 interpolated
                const end = @min(start_line + new_line_count, self.line_wraps.items.len);
                for (@min(start_line, end)..end) |i| {
                    self.markInterpolated(i);
                }

                self.rebuildFenwickFromWraps();
            }

            self.has_interpolated_lines = true;
            const new_total = self.total_display_lines;
            const display_delta = displayLineDelta(old_total, new_total);
            self.emitPatch(
                @intCast(start_line),
                @intCast(start_line + new_line_count),
                display_delta,
                false,
            );
        }

        /// 将 entry 标记为 interpolated（保留旧 breaks 作为坐标占位）
        fn markInterpolated(self: *Self, line_idx: usize) void {
            if (line_idx >= self.line_wraps.items.len) return;
            const entry = &self.line_wraps.items[line_idx];
            entry.is_interpolated = true;
            self.has_interpolated_lines = true;
            // 拆掉 prepared 引信：该缓存是**编辑前**文本的 segment 快照，
            // content_hash 全仓从未被比较过。生产组件都设 precise_wrap=true
            // 绕开快路径才没踩中，任何新消费者忘设这个 flag，
            // rewrapInterpolated 就会用旧 segment 重算换行（光标/选区错位）。
            // 行已标插值 ⇒ 快照必然过期，直接释放，快路径自然退化到重读文档。
            if (entry.prepared) |prepared| {
                prepared.deinit(self.allocator);
                self.allocator.destroy(prepared);
                entry.prepared = null;
            }
        }

        /// 统计 interpolated 行数（用于 scheduler 决策）
        pub fn interpolatedLineCount(self: *const Self) usize {
            if (self.needs_rebuild) return self.total_display_lines;
            if (!self.has_interpolated_lines) return 0;
            var count: usize = 0;
            for (self.line_wraps.items) |entry| {
                if (entry.is_interpolated) count += 1;
            }
            return count;
        }

        pub const RewrapResult = struct {
            /// 本次 rewrap 精确计算的行数
            lines_rewrapped: usize,
            /// 仍然 interpolated 的行数（预算耗尽留给下一帧或后台）
            lines_remaining: usize,
        };

        /// 对 interpolated 行做精确 wrap 计算，预算控制。
        /// `budget_us = null` 表示无限预算（同步收敛所有 interpolated 行）。
        /// 返回本次处理/剩余统计；如果 display line 数量变化会 emit patch。
        fn retryRebuild(self: *Self, doc: *const Doc) ?RewrapResult {
            if (!self.needs_rebuild) return null;
            self.rebuildAll(doc);
            return .{ .lines_rewrapped = if (self.needs_rebuild) 0 else doc.lineCount(), .lines_remaining = self.interpolatedLineCount() };
        }

        pub fn rewrapInterpolated(self: *Self, doc: *const Doc, budget_us: ?u64) RewrapResult {
            if (self.retryRebuild(doc)) |result| return result;
            if (!self.has_interpolated_lines) return .{ .lines_rewrapped = 0, .lines_remaining = 0 };
            if (!self.enabled) {
                // wrap 禁用时不需要 rewrap，直接清理 interpolated 标记
                for (self.line_wraps.items) |*e| e.is_interpolated = false;
                self.has_interpolated_lines = false;
                return .{ .lines_rewrapped = 0, .lines_remaining = 0 };
            }

            var timer: ?std.time.Timer = if (budget_us != null) std.time.Timer.start() catch null else null;
            var processed: usize = 0;
            var min_dirty: u32 = std.math.maxInt(u32);
            var max_dirty: u32 = 0;
            var delta: i32 = 0;

            const wrap_columns = self.wrapWidthColumns();
            for (self.line_wraps.items, 0..) |*entry, i| {
                if (!entry.is_interpolated) continue;
                if (budget_us) |budget| {
                    if (timer) |*t| {
                        if (t.read() / 1000 >= budget) break;
                    }
                }

                const old_display_count: i32 = @intCast(entry.breaks.len + 1);

                // 快路径：若已有 prepared，直接用它重新按列数切分，不需要重读文档
                if (!(self.precise_wrap and self.hasPreciseMeasure())) {
                    if (entry.prepared) |prepared| {
                        if (entry.owned and entry.breaks.len > 0) {
                            self.allocator.free(entry.breaks);
                        }
                        entry.breaks = prepared.breaksForColumns(self.allocator, wrap_columns, self.tab_size) catch {
                            // 失败 fallback 到 wrapSingleLine
                            entry.breaks = &.{};
                            entry.owned = false;
                            // 不得先置 entry.prepared = null, freeWrapEntry 靠
                            // `if (entry.prepared)` 释放 PreparedWrapLine（含 segments
                            // 堆数组），提前抹掉指针 = 整块泄漏（它内部会置 null）
                            self.freeWrapEntry(entry);
                            entry.* = self.wrapSingleLine(doc, i);
                            const ndc: i32 = @intCast(entry.breaks.len + 1);
                            delta += ndc - old_display_count;
                            if (self.fenwick) |*ft| {
                                if (i < ft.n) ft.set(i, @intCast(ndc));
                            }
                            min_dirty = @min(min_dirty, @as(u32, @intCast(i)));
                            max_dirty = @max(max_dirty, @as(u32, @intCast(i + 1)));
                            processed += 1;
                            continue;
                        };
                        entry.owned = entry.breaks.len > 0;
                        entry.is_interpolated = false;
                        const ndc: i32 = @intCast(entry.breaks.len + 1);
                        delta += ndc - old_display_count;
                        if (self.fenwick) |*ft| {
                            if (i < ft.n) ft.set(i, @intCast(ndc));
                        }
                        min_dirty = @min(min_dirty, @as(u32, @intCast(i)));
                        max_dirty = @max(max_dirty, @as(u32, @intCast(i + 1)));
                        processed += 1;
                        continue;
                    }
                }

                // 慢路径：没有 prepared，或 precise_wrap 模式 -> 重读 doc
                self.freeWrapEntry(entry);
                entry.* = self.wrapSingleLine(doc, i);
                const new_display_count: i32 = @intCast(entry.breaks.len + 1);
                delta += new_display_count - old_display_count;

                if (self.fenwick) |*ft| {
                    if (i < ft.n) ft.set(i, @intCast(new_display_count));
                }

                min_dirty = @min(min_dirty, @as(u32, @intCast(i)));
                max_dirty = @max(max_dirty, @as(u32, @intCast(i + 1)));
                processed += 1;
            }

            // 刷新 total
            self.refreshTotal();

            // 检查是否还有 interpolated 行
            var remaining: usize = 0;
            for (self.line_wraps.items) |entry| {
                if (entry.is_interpolated) remaining += 1;
            }
            self.has_interpolated_lines = remaining > 0;

            if (processed > 0 and (delta != 0 or max_dirty > min_dirty)) {
                self.emitPatch(min_dirty, max_dirty, delta, false);
            }
            return .{ .lines_rewrapped = processed, .lines_remaining = remaining };
        }

        /// 便利 API：同步收敛所有 interpolated 行（预算无限）
        pub fn rewrapInterpolatedAll(self: *Self, doc: *const Doc) RewrapResult {
            return self.rewrapInterpolated(doc, null);
        }

        /// 只同步收敛 [start_line, end_line) 范围内的 interpolated 行（预算无限）。
        /// 用于编辑路径：立即精确 rewrap 编辑涉及的少量行，避免 VL adjustLineCount 抖动；
        /// 范围外的 interpolated 行仍留给 maintainWrapMap 处理。
        pub fn rewrapInterpolatedRange(self: *Self, doc: *const Doc, start_line: usize, end_line_exclusive: usize) RewrapResult {
            if (self.retryRebuild(doc)) |result| return result;
            if (!self.has_interpolated_lines or !self.enabled) {
                return .{ .lines_rewrapped = 0, .lines_remaining = 0 };
            }
            var processed: usize = 0;
            var min_dirty: u32 = std.math.maxInt(u32);
            var max_dirty: u32 = 0;
            var delta: i32 = 0;
            const wrap_columns = self.wrapWidthColumns();
            const end = @min(end_line_exclusive, self.line_wraps.items.len);
            for (@min(start_line, end)..end) |i| {
                const entry = &self.line_wraps.items[i];
                if (!entry.is_interpolated) continue;
                const old_display_count: i32 = @intCast(entry.breaks.len + 1);
                // 快路径 + 慢路径（同 rewrapInterpolated）
                if (!(self.precise_wrap and self.hasPreciseMeasure())) {
                    if (entry.prepared) |prepared| {
                        if (entry.owned and entry.breaks.len > 0) {
                            self.allocator.free(entry.breaks);
                        }
                        entry.breaks = prepared.breaksForColumns(self.allocator, wrap_columns, self.tab_size) catch {
                            entry.breaks = &.{};
                            entry.owned = false;
                            // 不得先置 entry.prepared = null, freeWrapEntry 靠
                            // `if (entry.prepared)` 释放 PreparedWrapLine（含 segments
                            // 堆数组），提前抹掉指针 = 整块泄漏（它内部会置 null）
                            self.freeWrapEntry(entry);
                            entry.* = self.wrapSingleLine(doc, i);
                            const ndc: i32 = @intCast(entry.breaks.len + 1);
                            delta += ndc - old_display_count;
                            if (self.fenwick) |*ft| {
                                if (i < ft.n) ft.set(i, @intCast(ndc));
                            }
                            min_dirty = @min(min_dirty, @as(u32, @intCast(i)));
                            max_dirty = @max(max_dirty, @as(u32, @intCast(i + 1)));
                            processed += 1;
                            continue;
                        };
                        entry.owned = entry.breaks.len > 0;
                        entry.is_interpolated = false;
                        const ndc: i32 = @intCast(entry.breaks.len + 1);
                        delta += ndc - old_display_count;
                        if (self.fenwick) |*ft| {
                            if (i < ft.n) ft.set(i, @intCast(ndc));
                        }
                        min_dirty = @min(min_dirty, @as(u32, @intCast(i)));
                        max_dirty = @max(max_dirty, @as(u32, @intCast(i + 1)));
                        processed += 1;
                        continue;
                    }
                }
                self.freeWrapEntry(entry);
                entry.* = self.wrapSingleLine(doc, i);
                const ndc: i32 = @intCast(entry.breaks.len + 1);
                delta += ndc - old_display_count;
                if (self.fenwick) |*ft| {
                    if (i < ft.n) ft.set(i, @intCast(ndc));
                }
                min_dirty = @min(min_dirty, @as(u32, @intCast(i)));
                max_dirty = @max(max_dirty, @as(u32, @intCast(i + 1)));
                processed += 1;
            }
            self.refreshTotal();
            // 检查全局 remaining
            var remaining: usize = 0;
            for (self.line_wraps.items) |e| if (e.is_interpolated) {
                remaining += 1;
            };
            self.has_interpolated_lines = remaining > 0;
            if (processed > 0) {
                self.emitPatch(min_dirty, max_dirty, delta, false);
            }
            return .{ .lines_rewrapped = processed, .lines_remaining = remaining };
        }

        // ========================================================================
        // 后台 Rewrap Task（仅当 Doc 支持 snapshot 时启用）
        // ========================================================================

        pub const BgPollResult = union(enum) {
            /// 后台还在跑
            none,
            /// 后台完成且已 apply
            applied: RewrapApplyStats,
            /// 后台完成但编辑版本已变 -> 结果丢弃
            stale,
            /// 后台失败（OOM / snapshot 失败等）
            failed,
        };

        pub const RewrapApplyStats = struct {
            lines_applied: usize,
            display_delta: i32,
        };

        // ────────────────────────────────────────────────────────
        // Background Rewrap
        // ────────────────────────────────────────────────────────

        /// 启动后台 rewrap：
        ///   - snapshot 当前文档
        ///   - 收集当前 interpolated 行号列表
        ///   - spawn worker 线程，逐行精确 rewrap
        ///   - 完成后由 UI 线程 `pollBackgroundRewrap` 拉取并 apply
        /// 只有在 `has_snapshot=true` 时可调用；已有任务在跑则跳过。
        /// `doc_version` 由调用方提供（通常是 state.edit_count），用于 stale 判定。
        pub fn startBackgroundRewrap(self: *Self, doc: *Doc, doc_version: u64) void {
            if (!has_snapshot) return;
            if (self.bg_thread != null) return;
            if (!self.enabled or !self.has_interpolated_lines or self.needs_rebuild) return;

            // snapshot doc（需要 *Doc：snapshot 内部持 mutex 与主线程 mutation 互斥）
            var snap = doc.snapshot(self.allocator) catch return;
            errdefer snap.deinit();
            self.bg_doc_snapshot = snap;
            self.bg_wrap_width = self.wrap_width;
            self.bg_tab_size = self.tab_size;
            self.bg_char_width = self.char_width;
            self.bg_wrap_columns = self.wrapWidthColumns();
            self.bg_doc_version = doc_version;
            self.bg_base_revision = self.revision;
            self.bg_done.store(false, .release);

            // 清空上次残留结果
            for (self.bg_result.items) |*r| {
                if (r.breaks.len > 0) self.allocator.free(r.breaks);
            }
            // The worker publishes a new owned list, replacing bg_result.
            // Release the previous backing allocation before that transfer.
            self.bg_result.clearAndFree(self.allocator);

            self.bg_thread = std.Thread.spawn(.{}, bgRewrapThread, .{self}) catch {
                self.bg_doc_snapshot.?.deinit();
                self.bg_doc_snapshot = null;
                return;
            };
        }

        fn bgRewrapThread(self: *Self) void {
            if (!has_snapshot) return;
            defer self.bg_done.store(true, .release);

            const snap = &self.bg_doc_snapshot.?;
            const line_count = snap.lineCount();

            var work_buf: std.ArrayListUnmanaged(BgRewrapResult) = .{};
            defer {
                for (work_buf.items) |*r| {
                    if (r.breaks.len > 0) self.allocator.free(r.breaks);
                }
                work_buf.deinit(self.allocator);
            }
            work_buf.ensureTotalCapacity(self.allocator, line_count) catch return;

            if (snap.totalLength() == 0) {
                self.bg_result = work_buf;
                work_buf = .{};
                return;
            }

            var i: usize = 0;
            while (i < line_count) : (i += 1) {
                const line_start = snap.getLineStart(i);
                const line_len = snap.getLineLength(i);
                if (line_len == 0) {
                    work_buf.append(self.allocator, .{ .buffer_line = @intCast(i), .breaks = &.{} }) catch return;
                } else {
                    var stack_buf: [8192]u8 = undefined;
                    var line_storage: ?[]u8 = null;
                    defer if (line_storage) |storage| self.allocator.free(storage);

                    const line_text_full = if (line_len <= stack_buf.len)
                        snap.getTextBuf(line_start, line_len, &stack_buf) catch return
                    else blk: {
                        const heap = self.allocator.alloc(u8, line_len) catch return;
                        line_storage = heap;
                        break :blk snap.getTextBuf(line_start, line_len, heap) catch return;
                    };
                    var content_end = line_text_full.len;
                    while (content_end > 0 and (line_text_full[content_end - 1] == '\n' or line_text_full[content_end - 1] == '\r')) {
                        content_end -= 1;
                    }
                    const line_text = line_text_full[0..content_end];
                    if (line_text.len == 0) {
                        work_buf.append(self.allocator, .{ .buffer_line = @intCast(i), .breaks = &.{} }) catch return;
                        continue;
                    }
                    const breaks = self.bgComputeBreaks(line_text) catch continue;
                    work_buf.append(self.allocator, .{
                        .buffer_line = @intCast(i),
                        .breaks = breaks,
                    }) catch {
                        if (breaks.len > 0) self.allocator.free(breaks);
                        return;
                    };
                }
            }

            self.bg_result = work_buf;
            work_buf = .{};
        }

        /// 后台线程用的 wrap 计算（独立于 self 的 wrap_width / char_width 等字段，
        /// 使用启动时 snapshot 的参数 bg_*）
        fn bgComputeBreaks(self: *Self, text: []const u8) ![]u32 {
            if (!has_snapshot) return &.{};
            var breaks_list: std.ArrayListUnmanaged(u32) = .{};
            errdefer breaks_list.deinit(self.allocator);

            const cw = if (self.bg_char_width > 0) self.bg_char_width else @as(f32, 8.0);
            const ts = if (self.bg_tab_size == 0) 4 else self.bg_tab_size;
            const wrap_w = self.bg_wrap_width;

            var seg_start: usize = 0;
            var last_word_boundary: usize = 0;
            var accumulated_w: f32 = 0;
            var col: usize = 0;
            var i: usize = 0;
            var grapheme_cursor = grapheme.BoundaryCursor.init(text);
            while (i < text.len) {
                const byte = text[i];
                // 按 grapheme cluster 步进（1e2bee4 修了 computeWraps/Precise，
                // 这里是当时的遗漏兄弟）：按码点会把 ZWJ emoji/组合字符切开
                const next_i = grapheme_cursor.next(i);
                if (i > seg_start) {
                    if (byte == ' ' or byte == '\t') {
                        last_word_boundary = next_i;
                    } else if (byte >= 0xE0) {
                        last_word_boundary = i;
                    } else if (i > 0 and prevCharLead(text, i) >= 0xE0) {
                        last_word_boundary = i;
                    }
                }
                const char_w: f32 = if (byte == '\t') blk: {
                    const spaces = ts - (col % ts);
                    col += spaces;
                    break :blk @as(f32, @floatFromInt(spaces)) * cw;
                } else if (byte < 0x80) blk: {
                    col += 1;
                    break :blk cw;
                } else blk: {
                    col += 2;
                    break :blk cw * 2.0;
                };
                accumulated_w += char_w;
                if (accumulated_w > wrap_w and i > seg_start) {
                    const break_at: usize = if (last_word_boundary > seg_start) last_word_boundary else i;
                    try breaks_list.append(self.allocator, @intCast(break_at));
                    seg_start = break_at;
                    last_word_boundary = seg_start;
                    accumulated_w = 0;
                    col = 0;
                    i = break_at;
                    continue;
                }
                i = next_i;
            }
            return breaks_list.toOwnedSlice(self.allocator);
        }

        /// 每帧轮询后台结果。
        /// `current_doc_version` 用于 stale 判定（与 startBackgroundRewrap 的 doc_version 对比）。
        pub fn pollBackgroundRewrap(self: *Self, current_doc_version: u64) BgPollResult {
            if (!has_snapshot) return .none;
            if (self.bg_thread == null) return .none;
            if (!self.bg_done.load(.acquire)) return .none;

            if (self.bg_thread) |t| t.join();
            self.bg_thread = null;

            defer {
                if (self.bg_doc_snapshot) |*s| s.deinit();
                self.bg_doc_snapshot = null;
            }

            // stale: 编辑版本已变 -> 丢弃结果（编辑改变了行号映射，强行 apply 会错位）
            if (current_doc_version != self.bg_doc_version or self.bg_base_revision != self.revision or !self.enabled or self.needs_rebuild) {
                for (self.bg_result.items) |*r| {
                    if (r.breaks.len > 0) self.allocator.free(r.breaks);
                }
                self.bg_result.clearRetainingCapacity();
                return .stale;
            }

            // Apply: 对每个结果 swap breaks + 更新 fenwick
            var delta: i32 = 0;
            var min_dirty: u32 = std.math.maxInt(u32);
            var max_dirty: u32 = 0;
            var applied: usize = 0;
            for (self.bg_result.items) |result| {
                const i: usize = result.buffer_line;
                if (i >= self.line_wraps.items.len) {
                    if (result.breaks.len > 0) self.allocator.free(result.breaks);
                    continue;
                }
                const entry = &self.line_wraps.items[i];
                const old_display_count: i32 = @intCast(entry.breaks.len + 1);

                // swap: free 旧 breaks, 装上新 breaks
                if (entry.owned and entry.breaks.len > 0) {
                    self.allocator.free(entry.breaks);
                }
                entry.breaks = result.breaks;
                entry.owned = result.breaks.len > 0;
                entry.is_interpolated = false;
                // prepared 保留（供后续 wrap width 变化快路径）

                const new_display_count: i32 = @intCast(entry.breaks.len + 1);
                delta += new_display_count - old_display_count;
                if (self.fenwick) |*ft| {
                    if (i < ft.n) ft.set(i, @intCast(new_display_count));
                }
                min_dirty = @min(min_dirty, @as(u32, @intCast(i)));
                max_dirty = @max(max_dirty, @as(u32, @intCast(i + 1)));
                applied += 1;
            }
            self.bg_result.clearRetainingCapacity();

            self.refreshTotal();

            // 检查是否还有 interpolated 行（后台 snapshot 时刻之后新编辑的行）
            var remaining: usize = 0;
            for (self.line_wraps.items) |entry| {
                if (entry.is_interpolated) remaining += 1;
            }
            self.has_interpolated_lines = remaining > 0;

            if (applied > 0) {
                self.emitPatch(min_dirty, max_dirty, delta, false);
            }
            return .{ .applied = .{ .lines_applied = applied, .display_delta = delta } };
        }

        pub fn hasBackgroundRewrap(self: *const Self) bool {
            if (!has_snapshot) return false;
            return self.bg_thread != null;
        }

        /// 从 line_wraps 重建 fenwick（行数变化时用）
        fn refreshTotal(self: *Self) void {
            if (self.fenwick) |ft| {
                self.total_display_lines = ft.total();
            } else {
                var total: u32 = 0;
                for (self.line_wraps.items) |entry| total +|= saturatingU32(entry.breaks.len + 1);
                self.total_display_lines = total;
            }
        }

        fn rebuildFenwickFromWraps(self: *Self) void {
            // Drop stale indexes even if allocating replacement counts fails.
            if (self.fenwick) |*ft| ft.deinit();
            self.fenwick = null;
            const n = self.line_wraps.items.len;
            const display_counts = self.allocator.alloc(u32, n) catch {
                self.refreshTotal();
                return;
            };
            defer self.allocator.free(display_counts);
            for (self.line_wraps.items, 0..) |entry, i| display_counts[i] = saturatingU32(entry.breaks.len + 1);
            self.rebuildFenwick(display_counts);
        }

        /// Disabled wrapping is an allocation-free identity mapping.
        fn applyEditDisabled(self: *Self, total_lines: usize, _: usize, _: usize, _: usize) void {
            self.clearAll(total_lines);
        }

        /// 对单行执行 wrap 计算
        fn wrapSingleLine(self: *Self, doc: *const Doc, line: usize) WrapEntry {
            if (self.wrap_width <= 0) return .{};

            const line_start = doc.getLineStart(line);
            const line_len = doc.getLineLength(line);
            if (line_len == 0) return .{};
            if (!(self.precise_wrap and self.hasPreciseMeasure()) and line_len > 8192) {
                return self.prepareAndComputeWrapsChunked(doc, line_start, line_len);
            }

            var stack_buf: [8192]u8 = undefined;
            var line_text: []const u8 = "";
            var heap = false;

            if (line_len <= stack_buf.len) {
                line_text = doc.getTextBuf(line_start, line_len, &stack_buf) catch return .{ .is_interpolated = true };
            } else {
                line_text = doc.getTextAlloc(self.allocator, line_start, line_len) catch return .{ .is_interpolated = true };
                heap = true;
            }
            defer if (heap) self.allocator.free(line_text);

            var text_len = line_text.len;
            while (text_len > 0 and (line_text[text_len - 1] == '\n' or line_text[text_len - 1] == '\r')) text_len -= 1;
            if (text_len == 0) return .{};
            const text = line_text[0..text_len];

            return self.prepareAndComputeWraps(text);
        }

        fn prepareAndComputeWrapsChunked(self: *Self, doc: *const Doc, line_start: usize, line_len: usize) WrapEntry {
            const FeedCtx = struct {
                doc: *const Doc,
                line_start: usize,
            };

            var ctx = FeedCtx{ .doc = doc, .line_start = line_start };
            const prepared = prepared_wrap_line.prepareLineChunked(
                self.allocator,
                struct {
                    fn feed(ptr: *anyopaque, offset: usize, buf: []u8) anyerror![]const u8 {
                        const typed: *FeedCtx = @ptrCast(@alignCast(ptr));
                        return typed.doc.getTextBuf(typed.line_start + offset, buf.len, buf);
                    }
                }.feed,
                &ctx,
                line_len,
                4096,
            ) catch return .{ .is_interpolated = true };
            errdefer {
                prepared.deinit(self.allocator);
                self.allocator.destroy(prepared);
            }

            const breaks = prepared.breaksForColumns(self.allocator, self.wrapWidthColumns(), self.tab_size) catch {
                prepared.deinit(self.allocator);
                self.allocator.destroy(prepared);
                return .{ .is_interpolated = true };
            };
            return .{
                .breaks = breaks,
                .owned = breaks.len > 0,
                .prepared = prepared,
            };
        }

        fn prepareAndComputeWraps(self: *Self, text: []const u8) WrapEntry {
            if (self.precise_wrap and self.hasPreciseMeasure()) {
                return self.computeWraps(text);
            }

            const prepared = prepared_wrap_line.prepareLine(self.allocator, text) catch return self.computeWraps(text);
            // 注意：本函数返回类型非 !T，errdefer 永远不会触发（曾有一段
            // errdefer 死代码给了"已覆盖"的假象）。失败路径必须显式清理,
            // 对比 prepareAndComputeWrapsChunked 的正确写法。
            const breaks = prepared.breaksForColumns(self.allocator, self.wrapWidthColumns(), self.tab_size) catch {
                prepared.deinit(self.allocator);
                self.allocator.destroy(prepared);
                return self.computeWraps(text);
            };
            return .{
                .breaks = breaks,
                .owned = breaks.len > 0,
                .prepared = prepared,
            };
        }

        fn wrapWidthColumns(self: *const Self) usize {
            const cw = if (self.char_width > 0) self.char_width else @as(f32, 8.0);
            return @max(1, @as(usize, @intFromFloat(@floor(self.wrap_width / @max(cw, 0.5)))));
        }

        /// wrap 断点计算核心算法
        fn computeWraps(self: *Self, text: []const u8) WrapEntry {
            if (self.precise_wrap and self.hasPreciseMeasure()) {
                return self.computeWrapsPrecise(text);
            }

            var breaks_stack: [256]u32 = undefined;
            var stack_count: usize = 0;
            var breaks_heap: std.ArrayListUnmanaged(u32) = .{};
            var use_heap = false;
            defer if (use_heap) breaks_heap.deinit(self.allocator);

            const cw = if (self.char_width > 0) self.char_width else @as(f32, 8.0);
            const ts = if (self.tab_size == 0) 4 else self.tab_size;

            var seg_start: usize = 0;
            var last_word_boundary: usize = 0;
            var accumulated_w: f32 = 0;
            var col: usize = 0; // 当前列（用于 tab stop 计算）
            var i: usize = 0;
            var grapheme_cursor = grapheme.BoundaryCursor.init(text);

            while (i < text.len) {
                const byte = text[i];
                // 同 computeWrapsPrecise：按 grapheme cluster 步进，断点不得落在
                // 簇内部（估算路径同样会被下游当作显示行段起点）。
                const next_i = grapheme_cursor.next(i);

                if (i > seg_start) {
                    if (byte == ' ' or byte == '\t') {
                        last_word_boundary = next_i;
                    } else if (byte >= 0xE0) {
                        last_word_boundary = i;
                    } else if (i > 0 and prevCharLead(text, i) >= 0xE0) {
                        last_word_boundary = i;
                    }
                }

                const char_w: f32 = if (byte == '\t') blk: {
                    const spaces = ts - (col % ts);
                    col += spaces;
                    break :blk @as(f32, @floatFromInt(spaces)) * cw;
                } else if (byte < 0x80) blk: {
                    col += 1;
                    break :blk cw;
                } else blk: {
                    col += 2;
                    break :blk cw * 2.0;
                };
                accumulated_w += char_w;

                if (accumulated_w > self.wrap_width and i > seg_start) {
                    var break_at: usize = undefined;
                    if (last_word_boundary > seg_start) {
                        break_at = last_word_boundary;
                    } else {
                        break_at = i;
                    }

                    if (!use_heap and stack_count < breaks_stack.len) {
                        breaks_stack[stack_count] = @intCast(break_at);
                        stack_count += 1;
                    } else {
                        if (!use_heap) {
                            breaks_heap.ensureTotalCapacity(self.allocator, breaks_stack.len * 2) catch return .{ .is_interpolated = true };
                            for (breaks_stack[0..stack_count]) |bp| {
                                breaks_heap.appendAssumeCapacity(bp);
                            }
                            use_heap = true;
                        }
                        breaks_heap.append(self.allocator, @intCast(break_at)) catch return .{ .is_interpolated = true };
                    }

                    seg_start = break_at;
                    last_word_boundary = seg_start;
                    accumulated_w = 0;
                    col = 0;
                    i = break_at;
                    continue;
                }

                i = next_i;
            }

            const break_count = if (use_heap) breaks_heap.items.len else stack_count;
            if (break_count == 0) return .{};

            const breaks = self.allocator.alloc(u32, break_count) catch return .{ .is_interpolated = true };
            if (use_heap) {
                @memcpy(breaks, breaks_heap.items[0..break_count]);
            } else {
                @memcpy(breaks, breaks_stack[0..break_count]);
            }
            return .{ .breaks = breaks, .owned = true };
        }

        /// 精确换行：逐字符真实测量宽度（用于需要高精度的 UI 文本框）
        fn computeWrapsPrecise(self: *Self, text: []const u8) WrapEntry {
            var breaks_stack: [256]u32 = undefined;
            var stack_count: usize = 0;
            var breaks_heap: std.ArrayListUnmanaged(u32) = .{};
            var use_heap = false;
            defer if (use_heap) breaks_heap.deinit(self.allocator);

            const cw = if (self.char_width > 0) self.char_width else @as(f32, 8.0);
            const ts = if (self.tab_size == 0) 4 else self.tab_size;

            var seg_start: usize = 0;
            var last_word_boundary: usize = 0;
            var accumulated_w: f32 = 0;
            var col: usize = 0;
            var i: usize = 0;
            var grapheme_cursor = grapheme.BoundaryCursor.init(text);

            while (i < text.len) {
                const byte = text[i];
                // 步进单位必须是 extended grapheme cluster，不是码点：ZWJ 序列
                // （👨‍👩‍👧）、肤色修饰（👋🏻）、VS16（❤️）、组合音标都是多码点单字形。
                // 按码点走会把一个字形拆成多段，既按半个字形累加 advance，
                // 又可能把断点/last_word_boundary 落在簇内部，导致下游显示行段
                // 起点非字形边界，光标 x 与选区宽度随之错位（emoji 光标停左边、
                // 选区只盖半个）。整簇测量同时保证 advance 与 shaping 同源。
                const next_i = grapheme_cursor.next(i);

                const char_w: f32 = if (byte == '\t') blk: {
                    const spaces = ts - (col % ts);
                    col += spaces;
                    break :blk @as(f32, @floatFromInt(spaces)) * cw;
                } else blk: {
                    if (byte >= 0xE0) {
                        col += 2;
                    } else {
                        col += 1;
                    }
                    const measured = self.measureText(text[i..next_i]);
                    if (measured > 0) break :blk measured;
                    break :blk if (byte >= 0xE0) cw * 2.0 else cw;
                };
                accumulated_w += char_w;

                if (accumulated_w > self.wrap_width and i > seg_start) {
                    const break_at: usize = if (last_word_boundary > seg_start) last_word_boundary else i;

                    if (!use_heap and stack_count < breaks_stack.len) {
                        breaks_stack[stack_count] = @intCast(break_at);
                        stack_count += 1;
                    } else {
                        if (!use_heap) {
                            breaks_heap.ensureTotalCapacity(self.allocator, breaks_stack.len * 2) catch return .{ .is_interpolated = true };
                            for (breaks_stack[0..stack_count]) |bp| {
                                breaks_heap.appendAssumeCapacity(bp);
                            }
                            use_heap = true;
                        }
                        breaks_heap.append(self.allocator, @intCast(break_at)) catch return .{ .is_interpolated = true };
                    }

                    seg_start = break_at;
                    last_word_boundary = seg_start;
                    accumulated_w = 0;
                    col = 0;
                    i = break_at;
                    continue;
                }

                // 断点规则与渲染端 text_layout.findLineBreak 严格同源：CJK 之后
                // 可断；其余位置按 UAX #14 pair table（i18n.linebreak）。记录必须
                // 发生在溢出判定之后，当前簇若已溢出，断点只能取之前的簇。
                // 旧的 lead-byte 启发式把 emoji 当 CJK（前后都可断），而渲染端
                // classify 把 emoji 归为 AL（AL×AL 不断）：同一处溢出时两边选到
                // 不同断点，WrapMap 行段与渲染行从此错位，选区/光标整段偏移。
                if (i > seg_start) {
                    const cp = firstCodepoint(text[i..next_i]);
                    if (i18n.linebreak.isCJK(cp)) {
                        last_word_boundary = next_i;
                    } else if (next_i < text.len) {
                        const next_cp = firstCodepoint(text[next_i..@min(next_i + 4, text.len)]);
                        if (i18n.linebreak.canBreakBetween(i18n.linebreak.classify(cp), i18n.linebreak.classify(next_cp))) {
                            last_word_boundary = next_i;
                        }
                    }
                }

                i = next_i;
            }

            const break_count = if (use_heap) breaks_heap.items.len else stack_count;
            if (break_count == 0) return .{};

            const breaks = self.allocator.alloc(u32, break_count) catch return .{ .is_interpolated = true };
            if (use_heap) {
                @memcpy(breaks, breaks_heap.items[0..break_count]);
            } else {
                @memcpy(breaks, breaks_stack[0..break_count]);
            }
            return .{ .breaks = breaks, .owned = true };
        }

        /// 测量文本宽度
        fn measureText(self: *const Self, text: []const u8) f32 {
            if (text.len == 0) return 0;
            if (self.measure_ctx_fn) |mfn| {
                if (self.measure_ctx) |ctx| {
                    return mfn(ctx, text.ptr, text.len, self.font_size, self.font_weight, false);
                }
            }
            if (self.measure_fn) |mfn| {
                return mfn(text.ptr, text.len, self.font_size, self.font_weight, false);
            }
            // 等宽 fallback（char_width 估算，仅用于无 GPU 的测试环境）
            const cw = if (self.char_width > 0) self.char_width else @as(f32, 8.0);
            var w: f32 = 0;
            var i: usize = 0;
            while (i < text.len) {
                const b = text[i];
                const cl: usize = if (b < 0x80) 1 else if (b < 0xE0) 2 else if (b < 0xF0) 3 else 4;
                w += if (b >= 0xE0) cw * 2.0 else cw;
                i += @min(cl, text.len - i);
            }
            return w;
        }

        /// buffer line -> 该行的首个 display line 编号（Fenwick O(logN)）
        pub fn bufferLineToDisplayLine(self: *const Self, buf_line: usize) u32 {
            if (!self.enabled or self.needs_rebuild) return saturatingU32(buf_line);
            if (self.fenwick) |ft| {
                if (buf_line == 0) return 0;
                if (buf_line > ft.n) return self.total_display_lines;
                return ft.prefixSum(buf_line - 1);
            }
            var total: u32 = 0;
            for (self.line_wraps.items[0..@min(buf_line, self.line_wraps.items.len)]) |entry| total +|= saturatingU32(entry.breaks.len + 1);
            return total;
        }

        /// buffer 坐标 -> display 坐标
        pub fn bufferToDisplay(self: *const Self, buf_line: usize, byte_col: usize) DisplayPoint {
            if (!self.enabled or self.needs_rebuild) return .{ .display_line = saturatingU32(buf_line), .display_col = byte_col };

            if (buf_line >= self.line_wraps.items.len) {
                return .{ .display_line = self.total_display_lines, .display_col = 0 };
            }

            const base = self.bufferLineToDisplayLine(buf_line);
            const wrap_idx = self.wrapIndexForBufferByte(buf_line, byte_col);
            const seg_start: usize = if (wrap_idx == 0) 0 else self.line_wraps.items[buf_line].breaks[wrap_idx - 1];
            return .{
                .display_line = base + @as(u32, @intCast(wrap_idx)),
                .display_col = byte_col - seg_start,
            };
        }

        pub fn wrapIndexForBufferByte(self: *const Self, buf_line: usize, byte_col: usize) usize {
            if (!self.enabled or buf_line >= self.line_wraps.items.len) return 0;
            const breaks = self.line_wraps.items[buf_line].breaks;
            var wrap_idx: usize = 0;
            for (breaks) |bp| {
                if (byte_col < bp) break;
                wrap_idx += 1;
            }
            return wrap_idx;
        }

        pub fn displayLineForBufferByte(self: *const Self, buf_line: usize, byte_col: usize) u32 {
            if (!self.enabled or self.needs_rebuild) return saturatingU32(buf_line);
            if (buf_line >= self.line_wraps.items.len) return self.total_display_lines;
            return self.bufferLineToDisplayLine(buf_line) + @as(u32, @intCast(self.wrapIndexForBufferByte(buf_line, byte_col)));
        }

        /// display line -> buffer line + wrap 段信息（Fenwick O(logN)）。
        ///
        /// `line_wraps` 在增量编辑后的插值窗口中可能暂时保留旧断点，因此
        /// 必须用当前文档行长钳位。把 `doc` 作为必需参数可保证所有调用者
        /// 都拿到可直接切片的范围，而不是依赖消费层记得逐处防御 stale breaks。
        pub fn displayLineInfo(self: *const Self, display_line: u32, doc: *const Doc) DisplayLineInfo {
            if (!self.enabled or self.line_wraps.items.len == 0) {
                const buffer_line: usize = display_line;
                const line_len = if (buffer_line < doc.lineCount()) doc.getLineLength(buffer_line) else 0;
                return .{
                    .buffer_line = buffer_line,
                    .wrap_index = 0,
                    .segment_start_index = 0,
                    .segment_end_index = 1,
                    .byte_start = 0,
                    .byte_end = line_len,
                };
            }

            const dl = self.clampDisplayLine(display_line);
            const buf_line = self.findBufferLineForClamped(dl);

            const base_dl = self.bufferLineToDisplayLine(buf_line);
            const wrap_index_raw: usize = @intCast(dl - base_dl);

            if (buf_line >= self.line_wraps.items.len) {
                return .{
                    .buffer_line = buf_line,
                    .wrap_index = 0,
                    .segment_start_index = 0,
                    .segment_end_index = 1,
                    .byte_start = 0,
                    .byte_end = 0,
                };
            }

            const entry = self.line_wraps.items[buf_line];
            // wrap_index 合法区间为 [0, breaks.len]，其中 breaks.len 表示最后一段（到行尾）。
            const wrap_index = @min(wrap_index_raw, entry.breaks.len);
            const line_len = if (buf_line < doc.lineCount()) doc.getLineLength(buf_line) else 0;
            const stale_start: usize = if (wrap_index == 0) 0 else entry.breaks[wrap_index - 1];
            const stale_end: usize = if (wrap_index < entry.breaks.len) entry.breaks[wrap_index] else line_len;
            const byte_start = @min(stale_start, line_len);
            const byte_end = @max(byte_start, @min(stale_end, line_len));

            return .{
                .buffer_line = buf_line,
                .wrap_index = wrap_index,
                .segment_start_index = wrap_index,
                .segment_end_index = wrap_index + 1,
                .byte_start = byte_start,
                .byte_end = byte_end,
            };
        }

        pub fn bufferLineForDisplayLine(self: *const Self, display_line: u32) usize {
            if (!self.enabled or self.needs_rebuild) return display_line;
            if (self.line_wraps.items.len == 0) return 0;
            return self.findBufferLineForClamped(self.clampDisplayLine(display_line));
        }

        /// 总 display 行数
        pub fn displayLineCount(self: *const Self) u32 {
            if (!self.enabled) return 0;
            return self.total_display_lines;
        }

        /// 获取某个 buffer line 的 display line 数量
        pub fn displayLinesForBuffer(self: *const Self, buf_line: usize) u32 {
            if (!self.enabled or buf_line >= self.line_wraps.items.len) return 1;
            return @intCast(self.line_wraps.items[buf_line].breaks.len + 1);
        }

        pub fn displayRangeForBufferLine(self: *const Self, buf_line: usize) DisplayLineRange {
            const start: usize = @intCast(self.bufferLineToDisplayLine(buf_line));
            return .{
                .start = start,
                .end = start + self.displayLinesForBuffer(buf_line),
            };
        }

        pub fn bufferRangeForDisplayRange(self: *const Self, display_start: usize, display_end: usize) BufferLineRange {
            if (!self.enabled or self.line_wraps.items.len == 0 or display_end <= display_start) {
                return .{ .start = display_start, .end = display_end };
            }
            const clamped_start = @min(display_start, @as(usize, self.total_display_lines -| 1));
            const clamped_end_exclusive = @min(display_end, @as(usize, self.total_display_lines));
            if (clamped_end_exclusive <= clamped_start) {
                const start_buf = self.bufferLineForDisplayLine(@intCast(clamped_start));
                return .{ .start = start_buf, .end = start_buf };
            }
            const start_buf = self.bufferLineForDisplayLine(@intCast(clamped_start));
            const end_buf = self.bufferLineForDisplayLine(@intCast(clamped_end_exclusive - 1)) + 1;
            return .{ .start = start_buf, .end = end_buf };
        }

        /// 获取某个 buffer line 的 wrap 断点切片
        pub fn breaksForBuffer(self: *const Self, buf_line: usize) []const u32 {
            if (!self.enabled or buf_line >= self.line_wraps.items.len) return &.{};
            return self.line_wraps.items[buf_line].breaks;
        }

        fn freeWrapEntry(self: *Self, entry: *WrapEntry) void {
            if (entry.owned and entry.breaks.len > 0) {
                self.allocator.free(entry.breaks);
            }
            entry.breaks = &.{};
            entry.owned = false;
            if (entry.prepared) |prepared| {
                prepared.deinit(self.allocator);
                self.allocator.destroy(prepared);
                entry.prepared = null;
            }
        }

        fn clampDisplayLine(self: *const Self, display_line: u32) u32 {
            if (self.total_display_lines == 0) return 0;
            return @min(display_line, self.total_display_lines - 1);
        }

        fn findBufferLineForClamped(self: *const Self, dl: u32) usize {
            return if (self.fenwick) |ft| blk: {
                if (dl == 0) break :blk 0;
                const target = dl + 1;
                const idx = ft.find(target);
                if (idx == 0) break :blk 0;
                const prev_sum = ft.prefixSum(idx - 1);
                if (dl < prev_sum) break :blk idx - 1;
                break :blk idx;
            } else blk: {
                var acc: u32 = 0;
                for (self.line_wraps.items, 0..) |entry, i| {
                    acc +|= saturatingU32(entry.breaks.len + 1);
                    if (acc > dl) break :blk i;
                }
                break :blk self.line_wraps.items.len -| 1;
            };
        }
    };
}

const testing = std.testing;

const MockDoc = struct {
    text: []const u8,
    starts: []const usize,
    buf_reads: *usize,
    alloc_reads: *usize,

    fn lineCount(self: *const MockDoc) usize {
        return self.starts.len;
    }

    fn totalLength(self: *const MockDoc) usize {
        return self.text.len;
    }

    fn getLineStart(self: *const MockDoc, line: usize) usize {
        return self.starts[@min(line, self.starts.len - 1)];
    }

    fn getLineLength(self: *const MockDoc, line: usize) usize {
        const start = self.getLineStart(line);
        const next = if (line + 1 < self.starts.len) self.starts[line + 1] else self.text.len;
        return next - start;
    }

    fn getTextBuf(self: *const MockDoc, start: usize, len: usize, buf: []u8) ![]const u8 {
        self.buf_reads.* += 1;
        const end = @min(start + len, self.text.len);
        const slice = self.text[start..end];
        if (slice.len > buf.len) return error.NoSpaceLeft;
        @memcpy(buf[0..slice.len], slice);
        return buf[0..slice.len];
    }

    fn getTextAlloc(self: *const MockDoc, allocator: Allocator, start: usize, len: usize) ![]const u8 {
        self.alloc_reads.* += 1;
        const end = @min(start + len, self.text.len);
        return allocator.dupe(u8, self.text[start..end]);
    }
};

test "WrapMap reuses prepared lines on wrap width change" {
    var buf_reads: usize = 0;
    var alloc_reads: usize = 0;
    const text = "alpha beta gamma\nshort line\n";
    const starts = [_]usize{ 0, 17 };
    const doc = MockDoc{
        .text = text,
        .starts = &starts,
        .buf_reads = &buf_reads,
        .alloc_reads = &alloc_reads,
    };

    var wm = WrapMap(MockDoc).init(testing.allocator);
    defer wm.deinit();
    wm.char_width = 1;
    wm.tab_size = 4;
    wm.setWrapWidth(6, &doc);
    wm.setEnabled(true, &doc);
    _ = wm.rewrapInterpolatedAll(&doc);

    try testing.expectEqual(@as(usize, 2), buf_reads);
    try testing.expectEqual(@as(usize, 0), alloc_reads);
    try testing.expect(wm.displayLinesForBuffer(0) > 1);

    wm.setWrapWidth(10, &doc);
    _ = wm.rewrapInterpolatedAll(&doc);

    try testing.expectEqual(@as(usize, 2), buf_reads);
    try testing.expectEqual(@as(usize, 0), alloc_reads);
    try testing.expect(wm.displayLinesForBuffer(0) < 3);

    const display_range = wm.displayRangeForBufferLine(0);
    try testing.expectEqual(@as(usize, 0), display_range.start);
    try testing.expectEqual(@as(usize, @intCast(wm.displayLinesForBuffer(0))), display_range.end);
}

test "WrapMap applyEdit rebuilds on inconsistent edit ranges" {
    var buf_reads: usize = 0;
    var alloc_reads: usize = 0;
    const starts = [_]usize{0};
    const doc = MockDoc{
        .text = "one line",
        .starts = &starts,
        .buf_reads = &buf_reads,
        .alloc_reads = &alloc_reads,
    };
    var wm = WrapMap(MockDoc).init(testing.allocator);
    defer wm.deinit();
    wm.char_width = 1;
    wm.setWrapWidth(4, &doc);
    wm.setEnabled(true, &doc);

    wm.applyEdit(&doc, 999, 1, 1);
    try testing.expectEqual(doc.lineCount(), wm.line_wraps.items.len);
    try testing.expect(wm.takePendingPatch().?.is_global);
}

test "WrapMap chunked long line avoids heap line allocation during rewrap" {
    var text: std.ArrayList(u8) = .{};
    defer text.deinit(testing.allocator);
    for (0..12000) |_| {
        try text.append(testing.allocator, 'x');
    }

    var buf_reads: usize = 0;
    var alloc_reads: usize = 0;
    const starts = [_]usize{0};
    const doc = MockDoc{
        .text = text.items,
        .starts = &starts,
        .buf_reads = &buf_reads,
        .alloc_reads = &alloc_reads,
    };

    var wm = WrapMap(MockDoc).init(testing.allocator);
    defer wm.deinit();
    wm.char_width = 1;
    wm.tab_size = 4;
    wm.setWrapWidth(120, &doc);
    wm.setEnabled(true, &doc);
    _ = wm.rewrapInterpolatedAll(&doc);

    try testing.expect(buf_reads > 0);
    try testing.expectEqual(@as(usize, 0), alloc_reads);
    try testing.expect(wm.displayLinesForBuffer(0) > 1);
}

test "WrapMap context measurement stays isolated across windows" {
    const MeasureState = struct {
        advance: f32,

        fn withContext(raw: *anyopaque, _: [*]const u8, len: usize, _: f32, _: u16, _: bool) f32 {
            const self: *@This() = @ptrCast(@alignCast(raw));
            return @as(f32, @floatFromInt(len)) * self.advance;
        }

        fn legacy(_: [*]const u8, _: usize, _: f32, _: u16, _: bool) f32 {
            return 0;
        }
    };

    var buf_reads: usize = 0;
    var alloc_reads: usize = 0;
    const starts = [_]usize{0};
    const doc = MockDoc{
        .text = "abcd",
        .starts = &starts,
        .buf_reads = &buf_reads,
        .alloc_reads = &alloc_reads,
    };
    var narrow_font = MeasureState{ .advance = 1 };
    var wide_font = MeasureState{ .advance = 3 };

    var narrow = WrapMap(MockDoc).init(testing.allocator);
    defer narrow.deinit();
    narrow.precise_wrap = true;
    narrow.measure_fn = MeasureState.legacy;
    narrow.measure_ctx_fn = MeasureState.withContext;
    narrow.measure_ctx = &narrow_font;
    narrow.setWrapWidth(5, &doc);
    narrow.setEnabled(true, &doc);
    _ = narrow.rewrapInterpolatedAll(&doc);

    var wide = WrapMap(MockDoc).init(testing.allocator);
    defer wide.deinit();
    wide.precise_wrap = true;
    wide.measure_fn = MeasureState.legacy;
    wide.measure_ctx_fn = MeasureState.withContext;
    wide.measure_ctx = &wide_font;
    wide.setWrapWidth(5, &doc);
    wide.setEnabled(true, &doc);
    _ = wide.rewrapInterpolatedAll(&doc);

    try testing.expectEqual(@as(u32, 1), narrow.displayLinesForBuffer(0));
    try testing.expect(wide.displayLinesForBuffer(0) > narrow.displayLinesForBuffer(0));
}

// 软换行断点必须落在 extended grapheme cluster 边界上。
//
// 回归根因：两个 wrap 循环都按“UTF-8 码点”步进（lead byte 推 1/2/3/4 字节）。
// ZWJ 序列（👨‍👩‍👧 = 8 码点 / 1 字形）、肤色修饰（👋🏻）、VS16（❤️）、组合音标
// 都是多码点单字形，按码点走既把单字形的 advance 拆成多段累加，又会把断点
// （以及 last_word_boundary）落到簇内部。下游把 display line 的 byte_start
// 当作显示行段起点喂给 shaping/caret，段首是“半个字形”时整段 caret x 与
// 选区矩形集体错位：emoji 光标停在左边、选区只盖半个字形。
//
// 修复后断点单位 = grapheme cluster，此测试锁住该不变量（修复前 ZWJ/肤色
// 两例 byte_start 落在簇内 -> 断言红）。
test "soft wrap 断点落在 grapheme cluster 边界（emoji/ZWJ/肤色/组合）" {
    const M = struct {
        fn ctx(_: *anyopaque, ptr: [*]const u8, len: usize, _: f32, _: u16, _: bool) f32 {
            _ = ptr;
            return @as(f32, @floatFromInt(len)) * 2.0;
        }
    };
    const cases = [_][]const u8{
        "aaaa\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}aaaa", // ZWJ 家庭
        "aaaa\u{2764}\u{FE0F}aaaa", // BMP + VS16
        "aaaae\u{0301}aaaa", // 组合音标
        "aaaa\u{1F44B}\u{1F3FB}aaaa", // 肤色修饰
        "aaaa\u{1F60A}aaaa", // 单码点 SMP emoji
        "aaaa\u{4E2D}\u{6587}aaaa", // CJK 全角
    };
    var dummy: u8 = 0;
    for (cases) |txt| {
        const starts = [_]usize{0};
        var br: usize = 0;
        var ar: usize = 0;
        const doc = MockDoc{ .text = txt, .starts = &starts, .buf_reads = &br, .alloc_reads = &ar };
        var wm = WrapMap(MockDoc).init(testing.allocator);
        defer wm.deinit();
        wm.precise_wrap = true;
        wm.measure_ctx_fn = M.ctx;
        wm.measure_ctx = @ptrCast(&dummy);
        wm.setWrapWidth(20, &doc);
        wm.setEnabled(true, &doc);
        _ = wm.rewrapInterpolatedAll(&doc);
        const n = wm.displayLinesForBuffer(0);
        try testing.expect(n >= 1);
        var d: u32 = 0;
        while (d < n) : (d += 1) {
            const info = wm.displayLineInfo(d, &doc);
            const bs = @min(info.byte_start, txt.len);
            try testing.expect(@import("text_coordinates.zig").isGraphemeBoundary(txt, bs));
        }
    }
}

// precise wrap 的断点规则必须与渲染端 text_layout.findLineBreak 一致（UAX #14
// pair table + isCJK）。
//
// 回归根因：旧实现用 lead-byte 启发式（任何 ≥0xE0 的字符前后都可断），把 emoji
// 当 CJK；渲染端 i18n.linebreak.classify 把 emoji 归为 AL（AL×AL 不断）。文本
// "asfd🎩一样的欠fds🍰奥asdfasdf" 在 🍰 处溢出时：渲染端退回"欠"后断行
// （line1 = "fds🍰…"），WrapMap 却在 🍰 前断行（line1 = "🍰…"），编辑态
// 选区/光标基于 WrapMap 行段，从第一个 wrap 起与渲染整段错位。
test "precise wrap 断点规则与渲染端一致：emoji 前不断行" {
    const M = struct {
        fn ctx(_: *anyopaque, ptr: [*]const u8, len: usize, _: f32, _: u16, _: bool) f32 {
            _ = ptr;
            // 模拟真实度量：拉丁 ~7px、CJK 16px、emoji 21px（按字节长区分）。
            return switch (len) {
                1 => 7.0,
                3 => 16.0,
                4 => 21.0,
                else => @as(f32, @floatFromInt(len)) * 7.0,
            };
        }
    };
    //                0...4  8..11 14  17..20 23..27 30
    const txt = "asfd\u{1F3A9}一样的欠fds\u{1F370}奥asdfasdf";
    const starts = [_]usize{0};
    var br: usize = 0;
    var ar: usize = 0;
    const doc = MockDoc{ .text = txt, .starts = &starts, .buf_reads = &br, .alloc_reads = &ar };
    var wm = WrapMap(MockDoc).init(testing.allocator);
    defer wm.deinit();
    wm.precise_wrap = true;
    wm.measure_ctx_fn = M.ctx;
    var dummy: u8 = 0;
    wm.measure_ctx = @ptrCast(&dummy);
    // "asfd🎩一样的欠fds" = 4*7+21+4*16+3*7 = 134 ≤ 140；+🍰(21) = 155 > 140。
    // 渲染端：🍰(AL) 前不可断 -> 退回"欠"后（byte 20）。旧实现会在 🍰 前断（byte 23）。
    wm.setWrapWidth(140, &doc);
    wm.setEnabled(true, &doc);
    _ = wm.rewrapInterpolatedAll(&doc);

    try testing.expectEqual(@as(usize, 2), wm.displayLinesForBuffer(0));
    const line1 = wm.displayLineInfo(1, &doc);
    try testing.expectEqual(@as(usize, 20), line1.byte_start);
    try testing.expectEqualStrings("fds\u{1F370}奥asdfasdf", txt[line1.byte_start..]);
}

test "displayLineInfo clamps interpolated stale breaks to current line length" {
    var buf_reads: usize = 0;
    var alloc_reads: usize = 0;
    const starts = [_]usize{0};
    const long_doc = MockDoc{
        .text = "abcdefghijklmnop",
        .starts = &starts,
        .buf_reads = &buf_reads,
        .alloc_reads = &alloc_reads,
    };
    var wm = WrapMap(MockDoc).init(testing.allocator);
    defer wm.deinit();
    wm.char_width = 8;
    wm.setWrapWidth(16, &long_doc);
    wm.setEnabled(true, &long_doc);
    _ = wm.rewrapInterpolatedAll(&long_doc);
    try testing.expect(wm.displayLinesForBuffer(0) > 1);

    // Same-line edit preserves old breaks as interpolation placeholders until
    // the maintenance pass. The public query must still be slice-safe now.
    const short_doc = MockDoc{
        .text = "x",
        .starts = &starts,
        .buf_reads = &buf_reads,
        .alloc_reads = &alloc_reads,
    };
    wm.applyEdit(&short_doc, 0, 1, 1);
    const stale_last: u32 = wm.displayLinesForBuffer(0) - 1;
    const info = wm.displayLineInfo(stale_last, &short_doc);
    try testing.expect(info.byte_start <= short_doc.text.len);
    try testing.expect(info.byte_end <= short_doc.text.len);
    try testing.expect(info.byte_start <= info.byte_end);
}

test "WrapMap missing Fenwick retains wrapped coordinate prefixes" {
    var reads: usize = 0;
    var alloc_reads: usize = 0;
    const doc: MockDoc = .{ .text = "abcdefgh\nijklmnop", .starts = &.{ 0, 9 }, .buf_reads = &reads, .alloc_reads = &alloc_reads };
    var wm = WrapMap(MockDoc).init(testing.allocator);
    defer wm.deinit();
    wm.char_width = 8;
    wm.wrap_width = 16;
    wm.setEnabled(true, &doc);
    wm.rebuildAll(&doc);
    const expected = wm.bufferLineToDisplayLine(1);
    try testing.expect(expected > 1);
    if (wm.fenwick) |*ft| ft.deinit();
    wm.fenwick = null;
    try testing.expectEqual(expected, wm.bufferLineToDisplayLine(1));
    const info = wm.displayLineInfo(expected, &doc);
    try testing.expectEqual(@as(usize, 1), info.buffer_line);
    try testing.expectEqual(@as(usize, 0), info.byte_start);
}

test "WrapMap failed rebuild keeps current document coordinates usable and retries" {
    var reads: usize = 0;
    var alloc_reads: usize = 0;
    const old: MockDoc = .{ .text = "abcdefgh", .starts = &.{0}, .buf_reads = &reads, .alloc_reads = &alloc_reads };
    const current: MockDoc = .{ .text = "abcdefgh\nijklmnop", .starts = &.{ 0, 9 }, .buf_reads = &reads, .alloc_reads = &alloc_reads };
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var wm = WrapMap(MockDoc).init(failing.allocator());
    defer wm.deinit();
    wm.char_width = 8;
    wm.wrap_width = 16;
    wm.setEnabled(true, &old);
    wm.rebuildAll(&old);
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    wm.rebuildAll(&current);
    try testing.expectEqual(@as(u32, 2), wm.total_display_lines);
    try testing.expectEqual(@as(u32, 1), wm.bufferToDisplay(1, 3).display_line);
    try testing.expectEqual(@as(usize, 3), wm.bufferToDisplay(1, 3).display_col);
    try testing.expectEqual(@as(usize, 1), wm.bufferLineForDisplayLine(1));
    failing.fail_index = std.math.maxInt(usize);
    failing.resize_fail_index = std.math.maxInt(usize);
    _ = wm.rewrapInterpolatedAll(&current);
    try testing.expect(wm.total_display_lines > 2);
    try testing.expectEqual(current.lineCount(), wm.line_wraps.items.len);
}

fn expectCoherentWrapMapping(wm: *const WrapMap(MockDoc), doc: *const MockDoc) !void {
    if (!wm.enabled or wm.needs_rebuild) {
        try testing.expectEqual(saturatingU32(doc.lineCount()), wm.total_display_lines);
        try testing.expect(wm.fenwick == null);
        for (0..doc.lineCount()) |line| {
            const point = wm.bufferToDisplay(line, 1);
            try testing.expectEqual(saturatingU32(line), point.display_line);
            try testing.expectEqual(@as(usize, 1), point.display_col);
            try testing.expectEqual(line, wm.bufferLineForDisplayLine(saturatingU32(line)));
        }
        return;
    }
    try testing.expectEqual(doc.lineCount(), wm.line_wraps.items.len);
    var display: u32 = 0;
    for (wm.line_wraps.items, 0..) |entry, line| {
        try testing.expectEqual(display, wm.bufferLineToDisplayLine(line));
        for (0..entry.breaks.len + 1) |segment| {
            const info = wm.displayLineInfo(display, doc);
            try testing.expectEqual(line, info.buffer_line);
            try testing.expectEqual(segment, info.wrap_index);
            try testing.expect(info.byte_start <= info.byte_end);
            try testing.expect(info.byte_end <= doc.getLineLength(line));
            try testing.expectEqual(line, wm.bufferLineForDisplayLine(display));
            display += 1;
        }
    }
    try testing.expectEqual(display, wm.total_display_lines);
    if (wm.fenwick) |ft| {
        try testing.expectEqual(doc.lineCount(), ft.n);
        try testing.expectEqual(display, ft.total());
    }
}

test "WrapMap rebuild enable and growth allocation failures keep coherent mappings and recover" {
    var reads: usize = 0;
    var alloc_reads: usize = 0;
    const old: MockDoc = .{ .text = "abcdefgh", .starts = &.{0}, .buf_reads = &reads, .alloc_reads = &alloc_reads };
    const current: MockDoc = .{ .text = "abcdefghijklmnop\nabcdefghijklmnop\nabcdefghijklmnop", .starts = &.{ 0, 17, 34 }, .buf_reads = &reads, .alloc_reads = &alloc_reads };
    for (0..4) |operation| {
        var completed = false;
        for (0..150) |failure| {
            var failing = testing.FailingAllocator.init(testing.allocator, .{});
            var wm = WrapMap(MockDoc).init(failing.allocator());
            defer wm.deinit();
            wm.char_width = 8;
            wm.wrap_width = 16;
            wm.setEnabled(true, &old);
            wm.rebuildAll(&old);
            if (operation == 1 or operation == 3) wm.setEnabled(false, &old);
            failing.fail_index = failing.alloc_index + failure;
            failing.resize_fail_index = failing.resize_index;
            switch (operation) {
                0 => wm.rebuildAll(&current),
                1 => wm.setEnabled(true, &current),
                2, 3 => wm.applyEdit(&current, 0, 1, 3),
                else => unreachable,
            }
            const induced = failing.has_induced_failure;
            try expectCoherentWrapMapping(&wm, &current);
            failing.fail_index = std.math.maxInt(usize);
            failing.resize_fail_index = std.math.maxInt(usize);
            if (operation != 3) {
                _ = wm.rewrapInterpolatedAll(&current);
                _ = wm.rewrapInterpolatedAll(&current);
                try testing.expect(!wm.has_interpolated_lines);
                try testing.expect(!wm.needs_rebuild);
                try expectCoherentWrapMapping(&wm, &current);
                try testing.expectEqual(@as(u32, 24), wm.total_display_lines);
            }
            if (!induced) {
                completed = true;
                break;
            }
        }
        try testing.expect(completed);
    }
}

test "WrapMap line wrap allocation failure stays pending through whole and range refresh" {
    var reads: usize = 0;
    var alloc_reads: usize = 0;
    const text = "abcdefgh" ** 1200;
    const doc: MockDoc = .{ .text = text, .starts = &.{0}, .buf_reads = &reads, .alloc_reads = &alloc_reads };
    for ([_]bool{ false, true }) |range| {
        var failing = testing.FailingAllocator.init(testing.allocator, .{});
        var wm = WrapMap(MockDoc).init(failing.allocator());
        defer wm.deinit();
        wm.char_width = 8;
        wm.wrap_width = 160;
        wm.setEnabled(true, &doc);
        wm.rebuildAll(&doc);
        wm.setWrapWidth(80, &doc);
        failing.fail_index = failing.alloc_index;
        failing.resize_fail_index = failing.resize_index;
        const failed = if (range) wm.rewrapInterpolatedRange(&doc, 0, 1) else wm.rewrapInterpolatedAll(&doc);
        try testing.expectEqual(@as(usize, 1), failed.lines_remaining);
        try testing.expect(wm.has_interpolated_lines);
        try expectCoherentWrapMapping(&wm, &doc);
        failing.fail_index = std.math.maxInt(usize);
        failing.resize_fail_index = std.math.maxInt(usize);
        const retried = if (range) wm.rewrapInterpolatedRange(&doc, 0, 1) else wm.rewrapInterpolatedAll(&doc);
        try testing.expectEqual(@as(usize, 0), retried.lines_remaining);
        try testing.expectEqual(@as(u32, 960), wm.total_display_lines);
        try expectCoherentWrapMapping(&wm, &doc);
    }
}

test "WrapMap background publication rejects obsolete mapping epochs" {
    const AsyncDoc = struct {
        const Snapshot = struct {
            pub fn deinit(_: *@This()) void {}
        };
        pub fn snapshot(_: *@This(), _: Allocator) !Snapshot {
            return .{};
        }
    };
    for (0..4) |mutation| {
        var wm = WrapMap(AsyncDoc).init(testing.allocator);
        defer wm.deinit();
        wm.enabled = true;
        try wm.line_wraps.append(testing.allocator, .{ .is_interpolated = true });
        wm.has_interpolated_lines = true;
        wm.total_display_lines = 1;
        const breaks = try testing.allocator.dupe(u32, &.{ 2, 4 });
        try wm.bg_result.append(testing.allocator, .{ .buffer_line = 0, .breaks = breaks });
        wm.bg_thread = try std.Thread.spawn(.{}, struct {
            fn run() void {}
        }.run, .{});
        wm.bg_done.store(true, .release);
        switch (mutation) {
            0 => {},
            1 => wm.revision += 1,
            2 => wm.enabled = false,
            3 => wm.needs_rebuild = true,
            else => unreachable,
        }
        const result = wm.pollBackgroundRewrap(0);
        if (mutation == 0) {
            try testing.expect(result == .applied);
            try testing.expectEqual(@as(u32, 3), wm.total_display_lines);
            try testing.expectEqual(@as(u32, 3), wm.bufferLineToDisplayLine(1));
        } else {
            try testing.expect(result == .stale);
            try testing.expectEqual(@as(u32, 1), wm.total_display_lines);
            try testing.expect(wm.line_wraps.items[0].is_interpolated);
            try testing.expectEqual(@as(usize, 0), wm.line_wraps.items[0].breaks.len);
        }
    }
}

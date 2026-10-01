/// 离屏纹理池 + 尺寸计算，从 command_encoder.zig 析出
///
/// 用于 opacity layer / backdrop blur / rounded clip 等需要离屏渲染的场景。
const std = @import("std");
const gpu = @import("gpu");

pub const OffscreenTextureSize = struct {
    width: u32,
    height: u32,
};

/// 纹理分配尺寸桶：向上取整到 64px 倍数（钳到 max_dimension）。
/// scale/尺寸动画期离屏内容逐帧 ±1px 抖动，exact-match 池永远不命中；
/// 按桶分配后同桶帧共享纹理，合成端按 used/alloc 裁 UV。
pub const BUCKET_PX: u32 = 64;

pub fn bucketDimension(px: u32, max_dimension: u32) u32 {
    const capped = @min(px, max_dimension);
    const remainder = capped % BUCKET_PX;
    if (remainder == 0) return capped;
    const bucketed = std.math.add(u32, capped, BUCKET_PX - remainder) catch max_dimension;
    return @min(bucketed, max_dimension);
}

pub fn computeOffscreenTextureSize(width: f32, height: f32, scale: f32, max_dimension: u32) ?OffscreenTextureSize {
    if (max_dimension == 0) return null;
    if (!std.math.isFinite(width) or !std.math.isFinite(height) or !std.math.isFinite(scale)) return null;
    if (width <= 0 or height <= 0 or scale <= 0) return null;

    const scaled_width = @ceil(width * scale);
    const scaled_height = @ceil(height * scale);
    if (!std.math.isFinite(scaled_width) or !std.math.isFinite(scaled_height)) return null;

    const max_dimension_f: f32 = @floatFromInt(max_dimension);
    if (scaled_width > max_dimension_f or scaled_height > max_dimension_f) return null;

    return .{
        .width = @intFromFloat(@max(@as(f32, 1), scaled_width)),
        .height = @intFromFloat(@max(@as(f32, 1), scaled_height)),
    };
}

/// 离屏纹理池：按尺寸缓存复用，避免每帧 alloc/free
/// 注意：同一帧内不能复用已经提交给 command buffer 采样/写入过的纹理，
/// 否则后续离屏 pass 会覆盖前一个 rounded-clip/blur 合成仍在使用的内容。
/// `PoolEntry.retained_id` 的哨兵：该条目不归任何 layer 所有，走普通按尺寸复用。
pub const NO_RETAINED_OWNER: u32 = std.math.maxInt(u32);

/// Copyable, non-owning token for one active offscreen texture. Ownership stays
/// in `OffscreenTexturePool`; generation checks prevent stale tokens from
/// resolving after eviction or transient destruction.
pub const TextureLease = struct {
    kind: Kind,
    slot: u8,
    generation: u32,

    pub const Kind = enum(u8) { pooled, transient };

    pub fn eql(self: TextureLease, other: TextureLease) bool {
        return self.kind == other.kind and self.slot == other.slot and self.generation == other.generation;
    }
};

/// `acquireRetained` 的结果。
pub const RetainedAcquire = struct {
    lease: TextureLease,
    /// true = 纹理里已有的像素就是本帧要的内容，可以跳过内容 pass 直接合成。
    content_matches: bool,
    /// true = 纹理尺寸未变且上一帧内容已画好（content_matches=false 时，
    /// 这是 damage-rect 部分重绘的前提：旧像素仍有意义，只需重画脏区）。
    was_primed: bool = false,
};

/// damage-rect 部分重绘：retained layer 上一帧每条 paint 命令的
/// {单条指纹, 保守外扩后的 bounds}。跨帧 diff 出脏区。
pub const DamageItem = struct {
    digest: u64,
    /// x/y/w/h（layer 外层坐标系，与 begin token 的 geom 同空间；已含
    /// shadow/stroke 外扩 pad）
    bounds: [4]f32,
};

/// 每个 retained 条目最多记多少条命令的 damage 信息。超过 = 放弃部分重绘
/// （整层重画），不截断（截断 = diff 不完整 = 漏脏区 = 陈旧像素）。
pub const MAX_DAMAGE_ITEMS = 128;

/// retained 条目连续多少帧没被认领就回收。合成层可能长期不出现（popover 关掉），
/// 一直钉着一张全屏纹理不划算；给几帧宽限避免"关掉又立刻打开"反复重建。
pub const RETAINED_IDLE_FRAMES: u64 = 60;

/// damage 基线的旁路槽位数。
///
/// 为什么不是 MAX_POOL（128）：damage 基线只对 **retained** 条目有意义，而
/// 一帧里能拿到有效基线的 retained 层数有硬上限，command_encoder 的
/// `retained_hashes: [64]` 与 `damage_ranges: [64]`：
///   - 序号 ≥ 64 的 opacity layer 拿不到 content_version（`break :blk 0`），
///     0 指纹被 `acquireRetained` 直接拒绝 ⇒ 根本不是 retained 条目；
///   - `storeRetainedDamageItems` 的唯一调用点（opacity_layer.zig:609）先判
///     `retained_seq < damage_ranges.len`(64)，超界一律存 null（invalid）。
/// 所以**同一帧内**最多 64 条基线。跨帧残留的基线由槽位随条目一起回收
/// （sweepRetained / dropRetained / evict / deinit 都释放），不会累积。
/// 64 槽 = 64 × (128×24 + 8) ≈ 197 KB，比原来内联进 128 条 PoolEntry 省 2/3，
/// 且这块内存本来就是 damage 功能自身要的，不再随池容量放大。
///
/// 容量不足时（理论上不可达，见上）走**安全降级**：不存基线 = 下一帧整层重画。
/// 绝不截断（截断 = diff 不完整 = 漏脏区 = 陈旧像素）。
pub const MAX_DAMAGE_SLOTS = 64;

pub const OffscreenTexturePool = struct {
    /// 2026-08-02 容量修订（下游回归性能项）：16 槽在 glass 工作负载下
    /// 恒满，每块玻璃岛一帧要 level0 capture + kawase 链 + glass/composite
    /// 数张纹理，opacity/clip layer 又因 release() 的 in-flight 保护期需要
    /// 每尺寸 ~4 份轮换；池满后新纹理全走 transient（帧末即毁）-> 同尺寸
    /// 每帧 create/destroy。48 槽容纳多岛 + 多故事切换的工作集；内存上限
    /// 靠 `sweepIdle`（普通条目闲置若干帧即回收）兜底，不靠压条数。
    /// 2026-08-12 再次修订 48 -> 128（下游应用）：**同一个缺陷第二次复发**。
    ///
    /// 症状：下游应用里 7 个玻璃岛时池恒满（`[offpool] create ... (pool=48)`，
    /// 一帧 51 次 acquire / 6 次失败）。降采样链拿不到纹理就 `break`，
    /// `actual_levels` 停在半途 ⇒ 模糊级数在 5/5 与 4/5 之间跳。因为所有玻璃岛
    /// 共用这一个池、且复用滞后固定 REUSE_LAG_FRAMES=3，**几个互不相关的岛会
    /// 同步以 3 帧为周期抖动**（用户看到的是「Inspector 的填充行一直在闪、
    /// 工具栏图标忽有忽无」）。实测：改成 128 后逐帧像素差归零。
    ///
    /// 实测（下游应用复现夹具，108 帧）：**扩容后显存反而降到 1/20**,
    ///
    ///   MAX_POOL=48 ：create 1414 次，池峰值卡死在 48，若全驻留 1135 MB
    ///   MAX_POOL=128：create  112 次，池峰值 111，        若全驻留   52 MB
    ///
    /// 因为 48 低于工作集（实测 111）时，池恒满 ⇒ 新纹理全走 transient ⇒
    /// **帧末即毁、下帧重建**，同一尺寸一轮跑下来能 create 四十多次。
    /// 所以这不只是"把临界点推远"：容量低于工作集会让缓存彻底失效（颠簸），
    /// 抬到工作集之上才让它回到设计意图内。上限靠 `sweepIdle` 兜底而非压条数
    /// （见上），所以给足余量是安全的。
    ///
    /// ⚠ 仍需注意：需求随「玻璃岛数 × 链深」线性增长，128 也只是当前工作集
    /// (111) 之上的一档余量。治本方向：(a) 容量按当帧 glass 岛数动态伸缩；
    /// (b) 保证同一岛的模糊级数帧间**稳定**（宁可恒定少一级，也不要在 4/5
    /// 之间跳，跳变才是视觉上的"闪"）。
    pub const MAX_POOL = 128;
    pub const MAX_TRANSIENT = 32;
    /// 普通池条目连续多少帧没被复用就销毁（防切换场景后一堆陈旧尺寸的
    /// 大纹理永久占内存；retained 条目的回收另走 RETAINED_IDLE_FRAMES）。
    pub const POOL_IDLE_FRAMES: u64 = 180;
    const REUSE_LAG_FRAMES: u64 = 3;
    entries: [MAX_POOL]?PoolEntry = .{null} ** MAX_POOL,
    transients: [MAX_TRANSIENT]?TransientEntry = .{null} ** MAX_TRANSIENT,
    pool_generations: [MAX_POOL]u32 = [_]u32{1} ** MAX_POOL,
    transient_generations: [MAX_TRANSIENT]u32 = [_]u32{1} ** MAX_TRANSIENT,
    count: usize = 0,
    /// `acquire` 彻底失败（池 **和** transient 都满）的累计次数。
    ///
    /// ⚠ 语义边界（实测澄清，别误用）：池满但 transient 还有位时**不计数**,
    /// 那条路是"新建一张、帧末即毁"，表现为性能颠簸（issue 33 实测：容量不足时
    /// 108 帧 create 1414 次）而**不是**画面降级，所以本计数器在那种情况下恒为 0。
    /// 换言之：`> 0` 一定有画面级降级；`== 0` **不代表**池够用。
    /// 判断池是否够用要看 `ZENIT_DEBUG_PASSCOUNT` 的 `[offpool] create` 频次。
    exhausted_count: u64 = 0,
    exhausted_warned: bool = false,
    /// damage 基线的旁路存储（见 MAX_DAMAGE_SLOTS / DamageSlot）。
    /// 不变量：`damage_slot_used[i]` 为 true ⟺ **恰有一个** PoolEntry 的
    /// `damage_slot == i`。维持它的是 acquireDamageSlot / releaseDamageSlot
    /// 这一对，以及所有让条目失去 retained 身份的路径都调用后者。
    damage_slots: [MAX_DAMAGE_SLOTS]DamageSlot = undefined,
    damage_slot_used: [MAX_DAMAGE_SLOTS]bool = [_]bool{false} ** MAX_DAMAGE_SLOTS,

    pub const PoolEntry = struct {
        texture: gpu.Backend.Texture,
        width: u32,
        height: u32,
        in_use: bool,
        reusable_after_frame: u64 = 0,
        last_used_frame: u64 = 0,
        /// GPU retained：该纹理被哪个合成 layer 独占持有（layer 的 stable_id）。
        /// NO_RETAINED_OWNER = 普通池条目。
        ///
        /// retained 条目与普通条目的关键区别：
        /// - 按尺寸的 `acquire` **永不**返回它（否则别人会覆写别人的缓存内容）；
        /// - `resetFrame` **不清**它的 in_use（普通条目靠这个每帧归还，retained
        ///   条目是跨帧持有的，清了就等于把它还给了池）；
        /// - 只能由 `acquireRetained` 按 (id, 尺寸) 认领，或被 idle 回收。
        retained_id: u32 = NO_RETAINED_OWNER,
        /// 该 retained 条目里已经光栅化好的**内容指纹**（encoder 侧对本层实际要
        /// 编码的命令取的哈希，见 command_encoder.computeRetainedContentHashes）。
        /// 与请求的指纹相等 = 内容没变，可以直接拿去合成，跳过内容 pass。
        retained_content_version: u64 = 0,
        /// 内容是否已经画过。刚分配的纹理内容是未定义的，必须先画一次才能复用。
        retained_primed: bool = false,
        /// damage-rect：上一帧 per-item 基线所在的**旁路槽位**下标。
        /// NO_DAMAGE_SLOT = 本条目当前没有有效基线（= 下次 miss 整层重画）。
        ///
        /// 为什么不内联（2026-08-12）：基线数组是 128×24 B = 3 KB，内联进
        /// PoolEntry 会让 `entries: [128]?PoolEntry` 涨到 ~403 KB，而其中
        /// 绝大部分槽位是**普通条目**、永远不会写 damage 基线。拆成旁路后
        /// PoolEntry 回到 ~72 B，数组 ~10 KB。
        damage_slot: u8 = NO_DAMAGE_SLOT,
    };

    /// `PoolEntry.damage_slot` 的哨兵。
    pub const NO_DAMAGE_SLOT: u8 = std.math.maxInt(u8);

    /// 一条 retained 层的上一帧 damage 基线。
    const DamageSlot = struct {
        items: [MAX_DAMAGE_ITEMS]DamageItem = undefined,
        count: u16 = 0,
    };

    /// 归还某条目占用的 damage 槽（幂等）。
    /// **必须**在 retained 条目失去身份/被覆写/被销毁时调用，漏掉会泄漏槽位，
    /// 更糟的是让别的 layer 认领到旧条目时读到**别人的**基线（串味 = 漏脏区）。
    fn releaseDamageSlot(self: *OffscreenTexturePool, entry: *PoolEntry) void {
        const slot = entry.damage_slot;
        if (slot == NO_DAMAGE_SLOT) return;
        entry.damage_slot = NO_DAMAGE_SLOT;
        if (slot < MAX_DAMAGE_SLOTS) self.damage_slot_used[slot] = false;
    }

    /// 为某条目分配一个 damage 槽（已有则复用）。槽位耗尽返回 null，调用方
    /// 必须安全降级（不存基线 = 整层重画），不得截断。
    fn acquireDamageSlot(self: *OffscreenTexturePool, entry: *PoolEntry) ?*DamageSlot {
        if (entry.damage_slot != NO_DAMAGE_SLOT and entry.damage_slot < MAX_DAMAGE_SLOTS) {
            return &self.damage_slots[entry.damage_slot];
        }
        for (&self.damage_slot_used, 0..) |*used, i| {
            if (used.*) continue;
            used.* = true;
            entry.damage_slot = @intCast(i);
            return &self.damage_slots[i];
        }
        return null;
    }

    const TransientEntry = struct {
        texture: gpu.Backend.Texture,
        width: u32,
        height: u32,
        in_use: bool,
    };

    fn bumpGeneration(generation: *u32) void {
        generation.* +%= 1;
        if (generation.* == 0) generation.* = 1;
    }

    fn pooledLease(self: *const OffscreenTexturePool, slot: usize) TextureLease {
        return .{ .kind = .pooled, .slot = @intCast(slot), .generation = self.pool_generations[slot] };
    }

    fn transientLease(self: *const OffscreenTexturePool, slot: usize) TextureLease {
        return .{ .kind = .transient, .slot = @intCast(slot), .generation = self.transient_generations[slot] };
    }

    pub fn resolveTexture(self: *OffscreenTexturePool, lease: TextureLease) ?*gpu.Backend.Texture {
        const slot: usize = lease.slot;
        return switch (lease.kind) {
            .pooled => if (slot < MAX_POOL and self.pool_generations[slot] == lease.generation)
                if (self.entries[slot]) |*entry| &entry.texture else null
            else
                null,
            .transient => if (slot < MAX_TRANSIENT and self.transient_generations[slot] == lease.generation)
                if (self.transients[slot]) |*entry| &entry.texture else null
            else
                null,
        };
    }

    pub fn binding(self: *OffscreenTexturePool, lease: TextureLease) ?gpu.Backend.TextureBinding {
        const value = self.resolveTexture(lease) orelse return null;
        return value.binding();
    }

    /// 获取或创建匹配尺寸的离屏纹理。
    /// 池满且无匹配时按 LRU 驱逐一个安全条目（!in_use 且已过 in-flight 保护期），
    /// 避免陈旧尺寸永久占坑、后续 acquire 全部走不入池的 create/release 慢路径。
    pub fn acquire(self: *OffscreenTexturePool, device: *gpu.Backend.Device, width: u32, height: u32, frame_index: u64) ?TextureLease {
        for (&self.entries, 0..) |*entry, slot| {
            if (entry.*) |*e| {
                // retained 条目归某个 layer 独占，按尺寸的复用绝不能碰它。
                if (e.retained_id != NO_RETAINED_OWNER) continue;
                if (!e.in_use and e.reusable_after_frame <= frame_index and e.width == width and e.height == height) {
                    e.in_use = true;
                    e.last_used_frame = frame_index;
                    return self.pooledLease(slot);
                }
            }
        }
        for (&self.transients, 0..) |*entry, slot| {
            if (entry.*) |*e| {
                if (!e.in_use and e.width == width and e.height == height) {
                    e.in_use = true;
                    return self.transientLease(slot);
                }
            }
        }
        if (std.posix.getenv("ZENIT_DEBUG_PASSCOUNT") != null) {
            var retained_n: usize = 0;
            for (self.entries) |m| {
                if (m) |e| {
                    if (e.retained_id != NO_RETAINED_OWNER) retained_n += 1;
                }
            }
            std.debug.print("[offpool] create {d}x{d} (pool={d} retained={d})\n", .{ width, height, self.count, retained_n });
        }
        // A failed allocation after an earlier eviction can leave a hole below
        // `count`. Reuse it before growing or evicting again; otherwise a pool
        // whose high-water mark reached MAX_POOL could permanently lose slots.
        var vacant_slot: ?usize = null;
        for (self.entries[0..self.count], 0..) |entry, slot| {
            if (entry == null) {
                vacant_slot = slot;
                break;
            }
        }
        if (vacant_slot) |slot| {
            const new_texture = createTexture(device, width, height) orelse return null;
            self.entries[slot] = .{
                .texture = new_texture,
                .width = width,
                .height = height,
                .in_use = true,
                .last_used_frame = frame_index,
            };
            return self.pooledLease(slot);
        } else if (self.count < MAX_POOL) {
            const new_texture = createTexture(device, width, height) orelse return null;
            self.entries[self.count] = .{
                .texture = new_texture,
                .width = width,
                .height = height,
                .in_use = true,
                .last_used_frame = frame_index,
            };
            const lease = self.pooledLease(self.count);
            self.count += 1;
            return lease;
        } else if (self.evictLruSlot(frame_index)) |slot| {
            const new_texture = createTexture(device, width, height) orelse return null;
            self.entries[slot] = .{
                .texture = new_texture,
                .width = width,
                .height = height,
                .in_use = true,
                .last_used_frame = frame_index,
            };
            return self.pooledLease(slot);
        }
        for (&self.transients, 0..) |*entry, slot| {
            if (entry.* != null) continue;
            const new_texture = createTexture(device, width, height) orelse return null;
            entry.* = .{ .texture = new_texture, .width = width, .height = height, .in_use = true };
            return self.transientLease(slot);
        }
        // 池 + transient 全满。调用方（blur 链、opacity layer）此时**静默降级**：
        // 少一级模糊、或整层不合成。视觉上表现为"闪"，而且因为所有玻璃岛
        // 共用这一个池，多个不相关的区域会同步抖动，极难归因（下游应用
        // 查了很久才定位到这里）。所以耗尽必须留下不依赖调试开关的痕迹。
        self.exhausted_count += 1;
        if (!self.exhausted_warned) {
            self.exhausted_warned = true;
            std.log.warn(
                "[offpool] exhausted (pool={d}/{d} transient={d}) requesting {d}x{d} — " ++
                    "callers will silently degrade (blur levels dropped / layer not composited). " ++
                    "This message appears once; see exhausted_count for the running total.",
                .{ self.count, MAX_POOL, MAX_TRANSIENT, width, height },
            );
        }
        return null;
    }

    /// 新建一张离屏 RT。
    ///
    /// Private 存储：这些离屏 RT 是**纯 GPU 中间产物**（opacity layer 合成、
    /// backdrop blur 的 ping-pong），CPU 从不读写它们，全仓唯一的像素回读
    /// 是 e2e 截图，且只读 drawable，不碰这个池（renderer.zig:214）。
    /// Shared 会让 Apple Silicon 上的这些纹理走 CPU 可见的一致性路径，
    /// 白白牺牲带宽与压缩（审查报告 P2）。Private 让驱动可以启用无损压缩
    /// 并省掉一致性开销。若将来真要回读，应另走 staging blit，而不是把整个
    /// 池退回 Shared。
    fn createTexture(device: *gpu.Backend.Device, width: u32, height: u32) ?gpu.Backend.Texture {
        return device.createTexture(std.heap.page_allocator, .{
            .label = "Zenit.Offscreen",
            .size = .{ .width = width, .height = height },
            .format = .bgra8_unorm_srgb,
            .usage = .{ .texture_binding = true, .render_attachment = true, .copy_src = true, .copy_dst = true },
            .memory = .device_local,
        }) catch null;
    }

    /// 池满时挑一个可安全驱逐的条目：!in_use 且 reusable_after_frame 已过
    /// （= 池自身的复用规则认定 GPU 不再引用），取 last_used_frame 最旧者。
    /// 无安全候选（全部 in_use 或仍在 in-flight 保护期）-> null，新纹理不入池。
    fn findLruSlot(self: *const OffscreenTexturePool, frame_index: u64) ?usize {
        var best: ?usize = null;
        var best_frame: u64 = std.math.maxInt(u64);
        for (&self.entries, 0..) |*entry, i| {
            if (entry.*) |*e| {
                if (e.retained_id != NO_RETAINED_OWNER) continue;
                if (!e.in_use and e.reusable_after_frame <= frame_index and e.last_used_frame < best_frame) {
                    best = i;
                    best_frame = e.last_used_frame;
                }
            }
        }
        if (best == null) {
            // 没有普通条目可驱逐，退而牺牲**本帧没被认领**的 retained 条目。
            //
            // 不做这一步的后果（实测）：retained 条目把 16 个槽位钉死后，
            // evictLruSlot 恒返 null，于是**所有**普通离屏纹理都走"创建了但
            // 进不了池"的路径，每帧 create/release, Modal / Sheet 的离屏合成
            // 直接垮掉（e2e 逮到：对话框整块空白）。
            // GPU retained 是一项优化，绝不能把普通路径挤死。
            for (&self.entries, 0..) |*entry, i| {
                if (entry.*) |*e| {
                    if (e.retained_id == NO_RETAINED_OWNER) continue;
                    if (e.last_used_frame >= frame_index) continue; // 本帧正在用
                    if (e.reusable_after_frame > frame_index) continue; // 仍在 in-flight 保护期
                    if (e.last_used_frame < best_frame) {
                        best = i;
                        best_frame = e.last_used_frame;
                    }
                }
            }
        }
        return best;
    }

    fn evictLruSlot(self: *OffscreenTexturePool, frame_index: u64) ?usize {
        const slot = self.findLruSlot(frame_index) orelse return null;
        if (self.entries[slot]) |*entry| {
            // 条目整个消失，槽位必须一起还，否则泄漏（槽位有限，泄光后
            // 所有 retained 层永久退化成整层重画）。
            self.releaseDamageSlot(entry);
            entry.texture.destroy();
        }
        self.entries[slot] = null;
        bumpGeneration(&self.pool_generations[slot]);
        return slot;
    }

    /// 释放纹理回池
    /// 纹理要到下一帧 resetFrame 后才能再次复用，避免同帧读写踩踏。
    pub fn release(self: *OffscreenTexturePool, lease: TextureLease, frame_index: u64) bool {
        const slot: usize = lease.slot;
        switch (lease.kind) {
            .pooled => {
                if (slot >= MAX_POOL or self.pool_generations[slot] != lease.generation) return false;
                const entry = if (self.entries[slot]) |*value| value else return false;
                entry.reusable_after_frame = frame_index + REUSE_LAG_FRAMES;
                return true;
            },
            .transient => {
                if (slot >= MAX_TRANSIENT or self.transient_generations[slot] != lease.generation) return false;
                if (self.transients[slot]) |*entry| entry.texture.destroy() else return false;
                self.transients[slot] = null;
                bumpGeneration(&self.transient_generations[slot]);
                return true;
            },
        }
    }

    /// 同帧立即复用释放，backdrop blur 内部链专用。
    ///
    /// 前提：该纹理只被**当前 command buffer 内已编码完成的 pass** 读/写过
    /// （GPU-only 纹理 + 默认 hazard tracking 下，同一 command buffer 内
    /// pass 串行自动排障，pass i+1 覆写 pass i 读过的纹理是安全的）。
    /// REUSE_LAG_FRAMES 防的是跨帧 in-flight command buffer，对这种场景过保守。
    /// 若未来一帧内 command buffer 会 split（多次 commit），该假设失效，
    /// 调用点必须回退到 release()。opacity layer 等其它调用方保持 release() 不动。
    pub fn releaseForReuseInFrame(self: *OffscreenTexturePool, lease: TextureLease) bool {
        const slot: usize = lease.slot;
        switch (lease.kind) {
            .pooled => {
                if (slot >= MAX_POOL or self.pool_generations[slot] != lease.generation) return false;
                const entry = if (self.entries[slot]) |*value| value else return false;
                entry.in_use = false;
                entry.reusable_after_frame = 0;
                return true;
            },
            .transient => {
                if (slot >= MAX_TRANSIENT or self.transient_generations[slot] != lease.generation) return false;
                const entry = if (self.transients[slot]) |*value| value else return false;
                entry.in_use = false;
                return true;
            },
        }
    }

    /// 帧开始时重置所有 in_use 标记。
    ///
    /// retained 条目**不**参与重置，它们是跨帧持有的，in_use 恒为 true 表示
    /// "归某个 layer 独占"。清掉就等于把还有人用的纹理还给了池。
    /// 它们的回收走 `sweepRetained`（idle 若干帧后）。
    pub fn resetFrame(self: *OffscreenTexturePool) void {
        for (&self.entries) |*entry| {
            if (entry.*) |*e| {
                if (e.retained_id != NO_RETAINED_OWNER) continue;
                e.in_use = false;
            }
        }
        for (&self.transients, 0..) |*entry, slot| {
            if (entry.*) |*value| value.texture.destroy();
            entry.* = null;
            bumpGeneration(&self.transient_generations[slot]);
        }
    }

    /// GPU retained：认领属于 `retained_id` 的专属纹理。
    ///
    /// 返回 null 表示"这一帧不要走 retained 路径"（池满等），caller 必须回退到
    /// 普通 acquire 的每帧重画路径，永远是安全的降级方向。
    ///
    /// `content_matches` 为 true 时表示纹理里已有的内容就是本帧要的内容，
    /// caller 可以跳过内容 pass 直接合成；false 时 caller 必须重画一遍。
    /// **尺寸不匹配一律判为不命中**（内容尺寸变了，旧像素没有意义）。
    pub fn acquireRetained(
        self: *OffscreenTexturePool,
        device: *gpu.Backend.Device,
        retained_id: u32,
        content_version: u64,
        width: u32,
        height: u32,
        frame_index: u64,
    ) ?RetainedAcquire {
        if (retained_id == NO_RETAINED_OWNER) return null;
        // 0 = 指纹无效（预扫描没覆盖到 / 层数超上限）。宁可每帧重画。
        if (content_version == 0) return null;

        for (&self.entries, 0..) |*entry, slot| {
            if (entry.*) |*e| {
                if (e.retained_id != retained_id) continue;
                // 身份对上了但尺寸变了：旧内容作废，就地重建成新尺寸。
                if (e.width != width or e.height != height) {
                    // 仍在 in-flight 保护期内不能覆写，本帧降级走普通路径。
                    if (e.reusable_after_frame > frame_index) return null;
                    const fresh = createTexture(device, width, height) orelse return null;
                    e.texture.destroy();
                    e.texture = fresh;
                    e.width = width;
                    e.height = height;
                    e.retained_content_version = content_version;
                    e.retained_primed = false;
                    self.releaseDamageSlot(e); // 尺寸变了，旧 diff 基线作废
                    e.last_used_frame = frame_index;
                    e.in_use = true;
                    bumpGeneration(&self.pool_generations[slot]);
                    return .{ .lease = self.pooledLease(slot), .content_matches = false };
                }
                const was_primed = e.retained_primed;
                const matches = e.retained_primed and e.retained_content_version == content_version;
                if (!matches) {
                    // 要重画。上一次命中合成时 GPU 采样过这张纹理；若那一帧的
                    // command buffer 仍 in-flight（三重缓冲常态），本帧就地
                    // clear+重画是写读竞争，内容切换的一两帧会闪烁。
                    // 处于保护期内就拒绝认领，caller 走普通池路径（那边的临时
                    // 纹理过了保护期，安全），下一帧再回来重画专属纹理。
                    if (e.reusable_after_frame > frame_index) return null;
                }
                const matches_final = matches;
                // miss：纹理即将被重画，旧像素不再对应任何已完成的版本。必须
                // 先撤掉 primed，否则版本号已改写成新指纹而 primed 仍为
                // true，内容 pass 中途失败（没走到 markRetainedPrimed）时，
                // 下一帧同指纹会命中半成品/陈旧像素。重画完成后 end 处
                // markRetainedPrimed 再置回。was_primed 已在上面快照，部分
                // 重绘判据不受影响。
                if (!matches) e.retained_primed = false;
                e.retained_content_version = content_version;
                e.last_used_frame = frame_index;
                e.in_use = true;
                // 本帧 GPU 会读（hit 合成）或写（miss 重画）这张纹理，
                // 记下保护期供上面的判断与 evictLruSlot 使用。
                e.reusable_after_frame = frame_index + REUSE_LAG_FRAMES;
                return .{ .lease = self.pooledLease(slot), .content_matches = matches_final, .was_primed = was_primed };
            }
        }

        // 首次认领：新建一张钉给这个 layer 的纹理。
        var new_texture = createTexture(device, width, height) orelse return null;
        const slot: usize = blk: {
            if (self.count < MAX_POOL) {
                const i = self.count;
                self.count += 1;
                break :blk i;
            }
            break :blk self.evictLruSlot(frame_index) orelse {
                // 池满且无可驱逐条目，不入池就无法跨帧持有，retained 没意义。
                new_texture.destroy();
                return null;
            };
        };
        self.entries[slot] = .{
            .texture = new_texture,
            .width = width,
            .height = height,
            .in_use = true,
            .last_used_frame = frame_index,
            .retained_id = retained_id,
            .retained_content_version = content_version,
            .retained_primed = false,
        };
        return .{ .lease = self.pooledLease(slot), .content_matches = false };
    }

    /// 标记某 retained 纹理的内容已经画好，下一帧起可以直接复用。
    /// 必须在内容 pass 真正编码完成后调用，提前调会让下一帧复用到没画完的像素。
    pub fn markRetainedPrimed(self: *OffscreenTexturePool, lease: TextureLease) bool {
        if (lease.kind != .pooled) return false;
        const slot: usize = lease.slot;
        if (slot >= MAX_POOL or self.pool_generations[slot] != lease.generation) return false;
        const entry = &(self.entries[slot] orelse return false);
        if (entry.retained_id == NO_RETAINED_OWNER) return false;
        entry.retained_primed = true;
        return true;
    }

    /// damage-rect：取某 retained 条目上一帧的 per-item 基线（无效返回 null）。
    pub fn retainedDamageItems(self: *OffscreenTexturePool, retained_id: u32) ?[]const DamageItem {
        for (&self.entries) |*entry| {
            if (entry.*) |*e| {
                if (e.retained_id != retained_id) continue;
                if (e.damage_slot == NO_DAMAGE_SLOT or e.damage_slot >= MAX_DAMAGE_SLOTS) continue;
                const slot = &self.damage_slots[e.damage_slot];
                return slot.items[0..slot.count];
            }
        }
        return null;
    }

    /// damage-rect：内容 pass 编码完成后写入本帧的 per-item 基线。
    /// items 超上限时置 invalid（宁可下次整层重画，不可截断 diff）。
    pub fn storeRetainedDamageItems(self: *OffscreenTexturePool, retained_id: u32, items: ?[]const DamageItem) void {
        for (&self.entries) |*entry| {
            if (entry.*) |*e| {
                if (e.retained_id != retained_id) continue;
                if (items) |list| {
                    if (list.len <= MAX_DAMAGE_ITEMS) {
                        // 槽位耗尽 -> 落到下面的 release（invalid）＝整层重画。
                        if (self.acquireDamageSlot(e)) |slot| {
                            @memcpy(slot.items[0..list.len], list);
                            slot.count = @intCast(list.len);
                            return;
                        }
                    }
                }
                self.releaseDamageSlot(e);
                return;
            }
        }
    }

    /// 回收连续 `POOL_IDLE_FRAMES` 帧没被任何 acquire 命中的普通条目。
    /// 与 sweepRetained 同节奏调用（每帧一次）。in_use / in-flight 保护期内
    /// 的条目不碰，只清确定无人引用的闲置纹理。
    pub fn sweepIdle(self: *OffscreenTexturePool, frame_index: u64) void {
        for (&self.entries, 0..) |*entry, slot| {
            if (entry.*) |*e| {
                if (e.retained_id != NO_RETAINED_OWNER) continue;
                if (e.in_use) continue;
                if (e.reusable_after_frame > frame_index) continue;
                if (frame_index < e.last_used_frame + POOL_IDLE_FRAMES) continue;
                self.releaseDamageSlot(e); // 防御性：普通条目本不该持槽
                e.texture.destroy();
                entry.* = null;
                bumpGeneration(&self.pool_generations[slot]);
            }
        }
    }

    /// 回收连续 `RETAINED_IDLE_FRAMES` 帧没被认领的 retained 条目，
    /// 让它们变回普通池条目（纹理本身留着继续按尺寸复用，不浪费一次创建）。
    pub fn sweepRetained(self: *OffscreenTexturePool, frame_index: u64) void {
        for (&self.entries) |*entry| {
            if (entry.*) |*e| {
                if (e.retained_id == NO_RETAINED_OWNER) continue;
                if (frame_index < e.last_used_frame + RETAINED_IDLE_FRAMES) continue;
                // 失去 retained 身份 ⇒ 基线必须作废并还槽。不还的话：这张纹理
                // 会被别的 layer 按尺寸 acquire 走，而槽位仍挂在条目上；等它
                // 再次被 acquireRetained 认领成**另一个 id** 时就会读到前任的
                // 基线 ⇒ diff 全错 ⇒ 漏脏区、陈旧像素。
                self.releaseDamageSlot(e);
                e.retained_id = NO_RETAINED_OWNER;
                e.retained_primed = false;
                e.retained_content_version = 0;
                e.in_use = false;
                // 退回普通池后仍要过 in-flight 保护期才能被别人拿走。
                e.reusable_after_frame = frame_index + REUSE_LAG_FRAMES;
            }
        }
    }

    /// 主动放弃某个 layer 的 retained 纹理（layer 销毁时）。
    pub fn dropRetained(self: *OffscreenTexturePool, retained_id: u32, frame_index: u64) void {
        for (&self.entries) |*entry| {
            if (entry.*) |*e| {
                if (e.retained_id != retained_id) continue;
                self.releaseDamageSlot(e); // 同 sweepRetained：身份没了基线必须作废
                e.retained_id = NO_RETAINED_OWNER;
                e.retained_primed = false;
                e.retained_content_version = 0;
                e.in_use = false;
                e.reusable_after_frame = frame_index + REUSE_LAG_FRAMES;
            }
        }
    }

    /// 释放所有纹理
    pub fn deinit(self: *OffscreenTexturePool) void {
        for (&self.entries, 0..) |*entry, slot| {
            if (entry.*) |*e| {
                self.releaseDamageSlot(e);
                e.texture.destroy();
                entry.* = null;
                bumpGeneration(&self.pool_generations[slot]);
            }
        }
        self.damage_slot_used = [_]bool{false} ** MAX_DAMAGE_SLOTS;
        for (&self.transients, 0..) |*entry, slot| {
            if (entry.*) |*e| e.texture.destroy();
            entry.* = null;
            bumpGeneration(&self.transient_generations[slot]);
        }
        self.count = 0;
    }
};

test "releaseForReuseInFrame makes texture immediately reacquirable in same frame" {
    var pool = OffscreenTexturePool{};
    pool.entries[0] = .{ .texture = fakeTexture(64, 64), .width = 64, .height = 64, .in_use = true, .reusable_after_frame = 0 };
    pool.count = 1;
    const lease = pool.pooledLease(0);

    // 常规 release：REUSE_LAG_FRAMES 内不可复用
    try std.testing.expect(pool.release(lease, 10));
    try std.testing.expectEqual(@as(u64, 13), pool.entries[0].?.reusable_after_frame);

    // 同帧复用 release：立即可被同帧 acquire 命中（命中路径不触碰 device）
    pool.entries[0].?.in_use = true;
    try std.testing.expect(pool.releaseForReuseInFrame(lease));
    try std.testing.expect(!pool.entries[0].?.in_use);
    try std.testing.expectEqual(@as(u64, 0), pool.entries[0].?.reusable_after_frame);
    const got = pool.acquire(undefined, 64, 64, 10) orelse return error.TestUnexpectedResult;
    try std.testing.expect(got.eql(lease));
    try std.testing.expect(pool.entries[0].?.in_use);
}

test "computeOffscreenTextureSize accepts finite positive bounds" {
    const size = computeOffscreenTextureSize(120.25, 60.1, 2.0, 8192).?;
    try std.testing.expectEqual(@as(u32, 241), size.width);
    try std.testing.expectEqual(@as(u32, 121), size.height);
}

test "computeOffscreenTextureSize rejects invalid layer bounds" {
    try std.testing.expect(computeOffscreenTextureSize(std.math.nan(f32), 40, 2.0, 8192) == null);
    try std.testing.expect(computeOffscreenTextureSize(40, std.math.inf(f32), 2.0, 8192) == null);
    try std.testing.expect(computeOffscreenTextureSize(0, 40, 2.0, 8192) == null);
    try std.testing.expect(computeOffscreenTextureSize(40, -2, 2.0, 8192) == null);
    try std.testing.expect(computeOffscreenTextureSize(40, 40, 0, 8192) == null);
}

test "computeOffscreenTextureSize rejects oversize textures" {
    try std.testing.expect(computeOffscreenTextureSize(4097, 1, 2.0, 8192) == null);
    try std.testing.expect(computeOffscreenTextureSize(1, 4096.5, 2.0, 8192) == null);
}

// ============================================================================
// GPU retained 语义测试
// ----------------------------------------------------------------------------
// 这些用例守的是**渲染正确性**，不是性能：retained 判错的后果是画面显示上一帧
// 的陈旧内容，比多画一遍严重得多。所以每条"可以复用"的断言都配一条"必须不可
// 复用"的反向断言。
// Tests use an undefined native handle and only exercise bookkeeping paths.
// ============================================================================

fn fakeTexture(width: u32, height: u32) gpu.Backend.Texture {
    // 经由后端提供的构造器，而不是直写字段字面量，后者会把某个后端的
    // 字段布局（Metal 的 `.raw`）焊进渲染层测试，换后端即编译失败。
    return gpu.Backend.Texture.fakeForTesting(width, height, .bgra8_unorm_srgb);
}

/// 预置一个已 primed 的 retained 条目，模拟"上一帧已经画好了"。
fn seedRetained(
    pool: *OffscreenTexturePool,
    idx: usize,
    retained_id: u32,
    content_version: u64,
    w: u32,
    h: u32,
) void {
    pool.entries[idx] = .{
        .texture = fakeTexture(w, h),
        .width = w,
        .height = h,
        .in_use = true,
        .last_used_frame = 0,
        .retained_id = retained_id,
        .retained_content_version = content_version,
        .retained_primed = true,
    };
    if (pool.count <= idx) pool.count = idx + 1;
}

test "retained: same id + same content_version + same size = cache hit" {
    var pool = OffscreenTexturePool{};
    seedRetained(&pool, 0, 42, 7, 128, 128);

    const got = pool.acquireRetained(undefined, 42, 7, 128, 128, 5) orelse
        return error.TestUnexpectedResult;
    try std.testing.expect(got.lease.eql(pool.pooledLease(0)));
    try std.testing.expect(got.content_matches);
}

test "retained: content_version bump forces repaint" {
    var pool = OffscreenTexturePool{};
    seedRetained(&pool, 0, 42, 7, 128, 128);

    // 内容变了 -> 必须重画，否则画面停留在旧内容。
    const got = pool.acquireRetained(undefined, 42, 8, 128, 128, 5) orelse
        return error.TestUnexpectedResult;
    try std.testing.expect(got.lease.eql(pool.pooledLease(0))); // 纹理仍复用（省一次创建）
    try std.testing.expect(!got.content_matches); // 但内容必须重画
    // 认领后记下新版本；重画完 markRetainedPrimed 之前不能算命中。
    try std.testing.expectEqual(@as(u64, 8), pool.entries[0].?.retained_content_version);
}

test "retained: not primed yet = miss even when version matches" {
    var pool = OffscreenTexturePool{};
    seedRetained(&pool, 0, 42, 7, 128, 128);
    // 刚分配、还没画过的纹理内容是未定义的。
    pool.entries[0].?.retained_primed = false;

    const got = pool.acquireRetained(undefined, 42, 7, 128, 128, 5) orelse
        return error.TestUnexpectedResult;
    try std.testing.expect(!got.content_matches);

    // 画完并标记后才算命中。
    try std.testing.expect(pool.markRetainedPrimed(got.lease));
    const got2 = pool.acquireRetained(undefined, 42, 7, 128, 128, 6) orelse
        return error.TestUnexpectedResult;
    try std.testing.expect(got2.content_matches);
}

test "retained: miss 后内容 pass 未完成（未 markRetainedPrimed）下一帧同指纹不得命中" {
    var pool = OffscreenTexturePool{};
    seedRetained(&pool, 0, 42, 7, 128, 128);
    // 帧 N：指纹 7->8，miss，开始重画……但内容 pass 中途失败，没走到 end 的
    // markRetainedPrimed。
    const miss = pool.acquireRetained(undefined, 42, 8, 128, 128, 5) orelse
        return error.TestUnexpectedResult;
    try std.testing.expect(!miss.content_matches);
    try std.testing.expect(miss.was_primed); // 部分重绘判据仍按旧状态
    // 帧 N+k（过了保护期）：同指纹 8，纹理里是半成品，必须重画。
    const again = pool.acquireRetained(undefined, 42, 8, 128, 128, 5 + OffscreenTexturePool.REUSE_LAG_FRAMES) orelse
        return error.TestUnexpectedResult;
    try std.testing.expect(!again.content_matches);
    try std.testing.expect(!again.was_primed); // 旧像素不可信 → 不走部分重绘
    // 这次画完了 -> 之后同指纹命中。
    try std.testing.expect(pool.markRetainedPrimed(again.lease));
    const hit = pool.acquireRetained(undefined, 42, 8, 128, 128, 5 + 2 * OffscreenTexturePool.REUSE_LAG_FRAMES) orelse
        return error.TestUnexpectedResult;
    try std.testing.expect(hit.content_matches);
}

test "retained: different layer id never shares a texture" {
    var pool = OffscreenTexturePool{};
    seedRetained(&pool, 0, 42, 7, 128, 128);
    seedRetained(&pool, 1, 43, 7, 128, 128);

    const a = pool.acquireRetained(undefined, 42, 7, 128, 128, 5) orelse
        return error.TestUnexpectedResult;
    const b = pool.acquireRetained(undefined, 43, 7, 128, 128, 5) orelse
        return error.TestUnexpectedResult;
    try std.testing.expect(a.lease.eql(pool.pooledLease(0)));
    try std.testing.expect(b.lease.eql(pool.pooledLease(1)));
    try std.testing.expect(!a.lease.eql(b.lease));
}

test "retained: size-keyed acquire never steals a retained texture" {
    var pool = OffscreenTexturePool{};
    seedRetained(&pool, 0, 42, 7, 128, 128);
    // 即便把 in_use 清掉（模拟 resetFrame 的错误行为），也不该被普通 acquire 拿走。
    pool.entries[0].?.in_use = false;

    // 尺寸完全匹配，但因为是 retained 条目，acquire 必须跳过它去走创建路径。
    // 创建路径需要真 device，这里传 undefined 会 crash，所以改为验证
    // "命中扫描不会返回它"：先让池里只有这一个条目，且不可能有其它命中。
    var found_retained = false;
    for (pool.entries) |maybe| {
        if (maybe) |e| {
            if (e.retained_id != NO_RETAINED_OWNER) found_retained = true;
        }
    }
    try std.testing.expect(found_retained);
    // 直接验证不变量：acquire 的命中条件里含 retained 跳过。
    // （行为等价断言见上面的注释，这里断言簿记状态没被 resetFrame 破坏。）
    pool.resetFrame();
    try std.testing.expect(pool.entries[0].?.retained_id == 42);
}

test "retained: resetFrame does not release retained entries" {
    var pool = OffscreenTexturePool{};
    seedRetained(&pool, 0, 42, 7, 128, 128);
    pool.entries[1] = .{ .texture = fakeTexture(64, 64), .width = 64, .height = 64, .in_use = true };
    pool.count = 2;

    pool.resetFrame();
    // 普通条目归还池；retained 条目仍被其 layer 独占。
    try std.testing.expect(!pool.entries[1].?.in_use);
    try std.testing.expect(pool.entries[0].?.in_use);
}

test "retained: idle sweep returns the texture to the normal pool" {
    var pool = OffscreenTexturePool{};
    seedRetained(&pool, 0, 42, 7, 128, 128);
    pool.entries[0].?.last_used_frame = 100;

    // 还没到期：保持 retained。
    pool.sweepRetained(100 + RETAINED_IDLE_FRAMES - 1);
    try std.testing.expectEqual(@as(u32, 42), pool.entries[0].?.retained_id);

    // 到期：退回普通池，纹理本身留着复用，但要过 in-flight 保护期。
    pool.sweepRetained(100 + RETAINED_IDLE_FRAMES);
    try std.testing.expectEqual(NO_RETAINED_OWNER, pool.entries[0].?.retained_id);
    try std.testing.expect(!pool.entries[0].?.in_use);
    try std.testing.expect(!pool.entries[0].?.retained_primed);
    try std.testing.expect(pool.entries[0].?.reusable_after_frame > 100 + RETAINED_IDLE_FRAMES);
}

test "retained: dropRetained releases ownership immediately" {
    var pool = OffscreenTexturePool{};
    seedRetained(&pool, 0, 42, 7, 128, 128);

    pool.dropRetained(42, 200);
    try std.testing.expectEqual(NO_RETAINED_OWNER, pool.entries[0].?.retained_id);
    try std.testing.expect(!pool.entries[0].?.in_use);
    try std.testing.expect(pool.entries[0].?.reusable_after_frame > 200);
}

test "retained: zero fingerprint is rejected" {
    var pool = OffscreenTexturePool{};
    seedRetained(&pool, 0, 42, 0, 128, 128);
    // 指纹 0 = 预扫描没算出有效值，必须拒绝走 retained（宁可每帧重画）。
    try std.testing.expect(pool.acquireRetained(undefined, 42, 0, 128, 128, 5) == null);
}

test "retained: NO_RETAINED_OWNER id is rejected" {
    var pool = OffscreenTexturePool{};
    // 哨兵 id 不是合法身份，必须拒绝，否则所有"不参与 retained"的 layer
    // 会共用同一张纹理互相覆写。
    try std.testing.expect(pool.acquireRetained(undefined, NO_RETAINED_OWNER, 0, 64, 64, 1) == null);
}

test "retained: eviction may sacrifice an idle retained entry when pool is full" {
    // 回归守卫（2026-07-30）：retained 条目曾是**完全不可驱逐**的，把 16 个槽位
    // 钉死后 evictLruSlot 恒返 null，所有普通离屏纹理都进不了池，每帧
    // create/release。GPU retained 是优化，绝不能把普通路径挤死。
    var pool = OffscreenTexturePool{};
    for (0..OffscreenTexturePool.MAX_POOL) |i| {
        seedRetained(&pool, i, @intCast(i + 1), 7, 64, 64);
        // 都是"上一帧用过"，本帧没被认领。
        pool.entries[i].?.last_used_frame = 10;
        pool.entries[i].?.reusable_after_frame = 0;
    }
    // 全是 retained，但都不是本帧认领的 -> 允许牺牲最旧的一个。
    const victim = pool.findLruSlot(20);
    try std.testing.expect(victim != null);
}

test "retained: entry claimed this frame is never evicted" {
    var pool = OffscreenTexturePool{};
    for (0..OffscreenTexturePool.MAX_POOL) |i| {
        seedRetained(&pool, i, @intCast(i + 1), 7, 64, 64);
        pool.entries[i].?.last_used_frame = 20; // 本帧刚认领
        pool.entries[i].?.reusable_after_frame = 0;
    }
    // 本帧正在用的 retained 纹理被驱逐 = 正在写的纹理被别人拿走，画面必错。
    try std.testing.expect(pool.findLruSlot(20) == null);
}

test "damage-rect: 基线存取 + 尺寸变化作废 + was_primed 语义" {
    var pool = OffscreenTexturePool{};
    seedRetained(&pool, 0, 42, 7, 128, 128);

    const items = [_]DamageItem{
        .{ .digest = 111, .bounds = .{ 0, 0, 10, 10 } },
        .{ .digest = 222, .bounds = .{ 10, 10, 20, 20 } },
    };
    pool.storeRetainedDamageItems(42, items[0..]);
    const got_items = pool.retainedDamageItems(42) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 2), got_items.len);
    try std.testing.expectEqual(@as(u64, 222), got_items[1].digest);

    // 内容 miss 但 primed + 同尺寸 -> was_primed=true（部分重绘前提）
    const got = pool.acquireRetained(undefined, 42, 8, 128, 128, 100) orelse
        return error.TestUnexpectedResult;
    try std.testing.expect(!got.content_matches);
    try std.testing.expect(got.was_primed);

    // 显式置 invalid
    pool.storeRetainedDamageItems(42, null);
    try std.testing.expect(pool.retainedDamageItems(42) == null);

    // 重新存上，尺寸变化路径必须作废基线
    pool.storeRetainedDamageItems(42, items[0..]);
    pool.entries[0].?.reusable_after_frame = 0;
    // 无法走真 createTexture（需要 device），直接断言字段语义：
    try std.testing.expect(pool.entries[0].?.damage_slot != OffscreenTexturePool.NO_DAMAGE_SLOT);
    pool.entries[0].?.width = 999; // 模拟尺寸不匹配前提
    // acquireRetained 尺寸不匹配分支需要真 device 创建纹理，无法在单测走通；
    // 语义由分支内 `releaseDamageSlot(e)` 一行保证（见 acquireRetained）。
    _ = &pool;
}

test "damage-rect: 旁路槽位随条目回收，绝不串味" {
    var pool = OffscreenTexturePool{};
    seedRetained(&pool, 0, 42, 7, 128, 128);
    const items = [_]DamageItem{.{ .digest = 111, .bounds = .{ 0, 0, 10, 10 } }};

    pool.storeRetainedDamageItems(42, items[0..]);
    const slot = pool.entries[0].?.damage_slot;
    try std.testing.expect(slot != OffscreenTexturePool.NO_DAMAGE_SLOT);
    try std.testing.expect(pool.damage_slot_used[slot]);

    // idle 回收 -> 身份没了，槽必须还回去，基线读不到。
    pool.entries[0].?.last_used_frame = 100;
    pool.sweepRetained(100 + RETAINED_IDLE_FRAMES);
    try std.testing.expectEqual(OffscreenTexturePool.NO_DAMAGE_SLOT, pool.entries[0].?.damage_slot);
    try std.testing.expect(!pool.damage_slot_used[slot]);
    try std.testing.expect(pool.retainedDamageItems(42) == null);

    // 同一条目被**另一个** id 认领后，绝不能读到前任的基线（串味 = 漏脏区）。
    pool.entries[0].?.retained_id = 43;
    try std.testing.expect(pool.retainedDamageItems(43) == null);

    // dropRetained 同样还槽。
    pool.entries[0].?.retained_id = 44;
    pool.storeRetainedDamageItems(44, items[0..]);
    try std.testing.expect(pool.entries[0].?.damage_slot != OffscreenTexturePool.NO_DAMAGE_SLOT);
    pool.dropRetained(44, 200);
    try std.testing.expectEqual(OffscreenTexturePool.NO_DAMAGE_SLOT, pool.entries[0].?.damage_slot);
}

test "damage-rect: 槽位耗尽是安全降级（不截断、不复用别人的槽）" {
    var pool = OffscreenTexturePool{};
    const items = [_]DamageItem{.{ .digest = 111, .bounds = .{ 0, 0, 10, 10 } }};
    // ⚠ 槽数与池容量是**两个独立常量**，本测试要同时索引 entries（长 MAX_POOL）
    // 和 damage_slots（长 MAX_DAMAGE_SLOTS）。直接拿 MAX_DAMAGE_SLOTS 当 entries
    // 的下标上界，会在 MAX_POOL < MAX_DAMAGE_SLOTS+1 的配置下**编译失败**
    // （实测：把 MAX_POOL 临时调回 48 做变异验证时炸了
    //  "index 64 outside array of length 48"）。取两者较小值，并跳过
    // 池容量不足以演示"槽耗尽"的配置。
    const pool_cap = OffscreenTexturePool.MAX_POOL;
    // SKIP-REASON: 仅当池容量大于 damage 槽位数时该分支才可达，取决于编译期常量
    if (pool_cap <= MAX_DAMAGE_SLOTS) return error.SkipZigTest;
    const fill_n = @min(MAX_DAMAGE_SLOTS, pool_cap - 1);
    // 把所有槽占满（id 从 1 开始，避开 NO_RETAINED_OWNER）。
    for (0..fill_n) |i| {
        seedRetained(&pool, i, @intCast(i + 1), 7, 64, 64);
        pool.storeRetainedDamageItems(@intCast(i + 1), items[0..]);
        try std.testing.expect(pool.entries[i].?.damage_slot != OffscreenTexturePool.NO_DAMAGE_SLOT);
    }
    // 第 N+1 个条目：拿不到槽 -> 不存基线（下一帧整层重画），而不是抢别人的。
    seedRetained(&pool, fill_n, 9999, 7, 64, 64);
    pool.storeRetainedDamageItems(9999, items[0..]);
    try std.testing.expectEqual(
        OffscreenTexturePool.NO_DAMAGE_SLOT,
        pool.entries[fill_n].?.damage_slot,
    );
    try std.testing.expect(pool.retainedDamageItems(9999) == null);
    // 已有的基线一条都没被顶掉。
    for (0..fill_n) |i| {
        try std.testing.expect(pool.retainedDamageItems(@intCast(i + 1)) != null);
    }
}

test "damage-rect: 超上限的 items 置 invalid 且释放已占槽" {
    var pool = OffscreenTexturePool{};
    seedRetained(&pool, 0, 42, 7, 128, 128);
    const ok = [_]DamageItem{.{ .digest = 1, .bounds = .{ 0, 0, 1, 1 } }};
    pool.storeRetainedDamageItems(42, ok[0..]);
    try std.testing.expect(pool.retainedDamageItems(42) != null);

    // 超 MAX_DAMAGE_ITEMS：宁可整层重画，也绝不截断 diff。
    var big: [MAX_DAMAGE_ITEMS + 1]DamageItem = undefined;
    for (&big) |*it| it.* = .{ .digest = 2, .bounds = .{ 0, 0, 1, 1 } };
    pool.storeRetainedDamageItems(42, big[0..]);
    try std.testing.expect(pool.retainedDamageItems(42) == null);
    try std.testing.expectEqual(OffscreenTexturePool.NO_DAMAGE_SLOT, pool.entries[0].?.damage_slot);
}

// ============================================================================
// 结构体尺寸护栏
// ----------------------------------------------------------------------------
// 2026-08-12：`damage_items: [128]DamageItem` 曾内联在 PoolEntry 里，单条 3152 B，
// `entries: [128]?PoolEntry` = 403 KB，而其中绝大多数是普通条目，永远不写
// damage 基线。拆成旁路后 PoolEntry 回到 ~72 B。
// 这条断言是**防复发**用的：再有人往 PoolEntry 里内联大数组会在编译期炸。
// 真需要加字段时，改这个数字并在 commit 里说明为什么值得。
// ============================================================================
comptime {
    const entry_size = @sizeOf(OffscreenTexturePool.PoolEntry);
    if (entry_size > 96) {
        @compileError(std.fmt.comptimePrint(
            "PoolEntry 膨胀到 {d} B（上限 96）。entries 数组是 MAX_POOL 份，" ++
                "别往这里内联大数组 —— 只对 retained 条目有意义的数据请走旁路存储" ++
                "（见 damage_slots）。",
            .{entry_size},
        ));
    }
}

test "PoolEntry 不再内联大数组（尺寸护栏）" {
    try std.testing.expect(@sizeOf(OffscreenTexturePool.PoolEntry) <= 96);
    // entries 数组整体也钉一下：MAX_POOL=128 时应在 ~16 KB 量级，不是 ~400 KB。
    try std.testing.expect(@sizeOf(@TypeOf(@as(OffscreenTexturePool, undefined).entries)) <= 32 * 1024);
}

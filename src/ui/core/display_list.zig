/// Display List — paint pass 内部 IR。
///
/// **v0.9-§c c4 (2026-05-13): 此文件仅 core/ 内部使用，外部不应直接 import。**
/// encoder 主路径已切到 paint_table.DisplayItem (struct, 非 union)。本文件保留
/// 为 paint pass → display_list_lowering 之间的中转 IR；snapshot.zig 跨帧持有
/// 也使用此 union (Snapshot.commands)。所有 .zig 模块若需 paint 数据，应 import
/// `paint_table.zig` 而非此文件。
/// `grep -rn "@import.*display_list.zig" src/` 应只命中 src/ui/core/ 子树。
///
/// DisplayItem 是 paint pass → encoder 之间的唯一 IR。每个 item 通过 ItemHeader
/// 关联到 PropertyTree 中的 transform/clip/effect。paint pass emit local 坐标，
/// display_list_lowering 在 lowering 时 apply transform 得 world 坐标，encoder 直
/// 消费 lowered DisplayItem。
const std = @import("std");
const types = @import("types.zig");
const icon_ir = @import("icon_ir");
const property_tree = @import("property_tree.zig");
const text_blob_mod = @import("text_blob.zig");

pub const TextRasterPolicy = text_blob_mod.TextRasterPolicy;

const Allocator = std.mem.Allocator;
const Color = types.Color;
const TextSpan = types.TextSpan;
const GradientDirection = types.GradientDirection;
pub const INVALID_ID = property_tree.INVALID_ID;

/// Clip primitive 类型 (R3f 后定义在 display_list)，与 ClipNode/clip token 共享。
/// PathFillRule 沿用 types.PathFillRule (跨模块共享，非本文件定义)。
pub const max_clip_polygon_points: usize = 32;
pub const max_clip_polygon_contours: usize = 8;

/// `begin_opacity_layer.surface_stable_id` 的哨兵：不参与 GPU retained 合成。
/// 语义上是"没有稳定身份"，encoder 见到它必须走每帧重画的老路径。
pub const INVALID_SURFACE_ID: u32 = std.math.maxInt(u32);

pub const ClipShapeKind = enum(u8) {
    rect = 0,
    rounded_rect = 1,
    ellipse = 2,
    polygon = 3,
};

pub const ClipPolygon = struct {
    point_count: u8 = 0,
    contour_count: u8 = 0,
    fill_rule: types.PathFillRule = .evenodd,
    contour_end_points: [max_clip_polygon_contours]u8 = [_]u8{0} ** max_clip_polygon_contours,
    points: [max_clip_polygon_points][2]f32 = [_][2]f32{.{ 0, 0 }} ** max_clip_polygon_points,

    pub fn empty() ClipPolygon {
        return .{};
    }
};

/// 每个 DisplayItem 的公共关联头（PropertyTree 引用）
pub const ItemHeader = struct {
    /// Frozen snapshot geometry has no dependency on the current property tree.
    already_lowered: bool = false,
    transform_id: u32,
    clip_id: u32 = INVALID_ID,
    effect_id: u32 = INVALID_ID,
    node_id: u32,
    paint_order: u64 = 0,
};

pub const DisplayItem = union(enum) {
    fill_rect: struct {
        header: ItemHeader,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        color: Color,
        radius: [4]f32 = .{ 0, 0, 0, 0 },
        /// 绘制形状（0 = rounded_rect, 1 = ellipse）。与 types.ShapeSpec 同序。
        /// ellipse 时 radius 被忽略（SDF 由半轴决定）。
        shape: u8 = 0,
    },
    stroke_rect: struct {
        header: ItemHeader,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        color: Color,
        width: f32,
        radius: [4]f32 = .{ 0, 0, 0, 0 },
        /// 见 fill_rect.shape
        shape: u8 = 0,
    },
    border_side: struct {
        header: ItemHeader,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        color: Color,
        width: f32,
        radius: [4]f32 = .{ 0, 0, 0, 0 },
        clip_x: f32,
        clip_y: f32,
        clip_w: f32,
        clip_h: f32,
        clip_radius: f32 = 0,
        clip_shape_kind: ClipShapeKind = .rect,
        clip_polygon: ClipPolygon = .{},
    },
    /// Per-side border: shader 内计算内轮廓，无需 clip
    border_per_side: struct {
        header: ItemHeader,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        color: Color,
        widths: [4]f32, // top, right, bottom, left
        radius: [4]f32 = .{ 0, 0, 0, 0 },
    },
    gradient_rect: struct {
        header: ItemHeader,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        from: Color,
        to: Color,
        direction: GradientDirection = .vertical,
        radius: [4]f32 = .{ 0, 0, 0, 0 },
        radial_center_x: f32 = 0,
        radial_center_y: f32 = 0,
        conic_start_angle: f32 = 0,
        extend_mode: types.GradientExtendMode = .pad,
        /// 见 fill_rect.shape
        shape: u8 = 0,
    },
    shadow_rect: struct {
        header: ItemHeader,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        color: Color,
        blur: f32,
        offset_x: f32 = 0,
        offset_y: f32 = 0,
        /// CSS spread（正外扩 / 负收缩阴影形状；本体下方始终挖空）。
        spread: f32 = 0,
        radius: [4]f32 = .{ 0, 0, 0, 0 },
    },
    outline_rect: struct {
        header: ItemHeader,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        color: Color,
        width: f32,
        radius: [4]f32 = .{ 0, 0, 0, 0 },
    },
    text_run: struct {
        header: ItemHeader,
        /// local origin x
        x: f32,
        /// local baseline y
        y: f32,
        content: []const u8,
        blob_byte_start: u32 = 0,
        blob_byte_end: u32 = 0,
        color: Color,
        /// 逻辑字号（不乘 scale！）
        font_size: f32,
        font_weight: u16 = 400,
        /// 字体族 id(见 TextProps.font_family)。0 = 默认族。
        font_family: u16 = 0,
        use_symbols_font: bool = false,
        use_monospace_font: bool = false,
        monospace_char_width: f32 = 0,
        use_italic_font: bool = false,
        spans: ?[]const TextSpan = null,
        /// Phase L3: 关联的 TextLayoutBlob（INVALID_ID = 无）
        blob_id: u32 = INVALID_ID,
        /// 该 blob 的 content_hash 快照，用于校验 blob_id 是否仍指向同一段文本。
        ///
        /// blob_id 是**帧内序号**，text_blob_store 每帧 clear 后重新分配。
        /// 保留（replay/cache）下来的 item 若跨帧存活，同一序号可能已被别的
        /// 控件占用 —— 于是终端会按自己的字节偏移去切状态栏的 "plaintext"，
        /// 画出 "plainte"（实测截图）。带上 hash 就能识破并回退到 content。
        blob_content_hash: u64 = 0,
        /// Phase L3: 光栅化策略
        raster_policy: TextRasterPolicy = .static_crisp,
        /// 右端淡出遮罩窗口，**相对 run 起点 x 的偏移**（0/0 = 关闭）。
        /// 相对量在 lowering 只需乘 scale、snapshot 平移天然免改。
        /// 见 TextProps.fade_right。
        fade_dx0: f32 = 0,
        fade_dx1: f32 = 0,
    },
    image_quad: struct {
        header: ItemHeader,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        texture_id: u32,
        tint: Color = Color.WHITE,
        corner_radius: f32 = 0,
        opacity: f32 = 1,
        rotate: f32 = 0,
    },
    icon_rep: struct {
        header: ItemHeader,
        icon_id: u16,
        rep_size: u8,
        rep: icon_ir.Rep,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        tint: Color = Color.WHITE,
        corner_clip_radius: f32 = 0,
        opacity: f32 = 1,
        rotate: f32 = 0,
    },
    arc: struct {
        header: ItemHeader,
        cx: f32,
        cy: f32,
        outer_radius: f32,
        stroke_width: f32,
        start_angle: f32,
        end_angle: f32,
        color: Color,
    },
    /// 多色渐变（多 stop）
    multi_gradient_rect: struct {
        header: ItemHeader,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        direction: GradientDirection = .vertical,
        radius: [4]f32 = .{ 0, 0, 0, 0 },
        stop_colors: [16]Color = [_]Color{Color.rgba(0, 0, 0, 0)} ** 16,
        stop_positions: [16]f32 = [_]f32{0} ** 16,
        stop_count: u8 = 0,
        radial_center_x: f32 = 0,
        radial_center_y: f32 = 0,
        /// 径向椭圆半径（UV 单位；0.5 = 内切）。
        radial_radius_x: f32 = 0.5,
        radial_radius_y: f32 = 0.5,
        conic_start_angle: f32 = 0,
        extend_mode: types.GradientExtendMode = .pad,
        /// 见 fill_rect.shape（0 = rounded_rect, 1 = ellipse）。
        /// 渐变也必须服从形状，否则椭圆的渐变会铺满整个包围盒。
        shape: u8 = 0,
    },
    /// 程序性噪声纹理
    noise_rect: struct {
        header: ItemHeader,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        fill: Color,
        mode: u8 = 1,
        scale: f32 = 2.0,
        intensity: f32 = 0.04,
        seed: u8 = 0,
        radius: [4]f32 = .{ 0, 0, 0, 0 },
    },
    /// Inset Shadow 内阴影
    inset_shadow_rect: struct {
        header: ItemHeader,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        fill: Color,
        shadow_color: Color,
        blur: f32,
        offset_x: f32 = 0,
        offset_y: f32 = 0,
        radius: [4]f32 = .{ 0, 0, 0, 0 },
    },
    /// 双外阴影
    shadow_dual_rect: struct {
        header: ItemHeader,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        fill: Color,
        shadow1_color: Color,
        shadow1_blur: f32,
        shadow1_offset_x: f32 = 0,
        shadow1_offset_y: f32 = 0,
        shadow2_color: Color,
        shadow2_blur: f32,
        shadow2_offset_x: f32 = 0,
        shadow2_offset_y: f32 = 0,
        radius: [4]f32 = .{ 0, 0, 0, 0 },
    },
    /// 矢量路径填充（局部坐标，offset 相对节点左上角）
    fill_path: struct {
        header: ItemHeader,
        /// PathGeometry 生命周期由调用方（scene runtime）管理
        geometry: *const types.PathGeometry,
        color: Color,
        offset_x: f32 = 0,
        offset_y: f32 = 0,
        opacity: f32 = 1.0,
        /// 渐变填充（可选）。`gradient_direction == 0` 即纯色走 `color`。
        /// 逐顶点着色由 path_renderer 完成（GPU 侧 PathVertex.color 早已支持），
        /// 多边形（三角/星形）的渐变填充靠这条 —— 否则只能退化成纯色。
        gradient_direction: u8 = 0,
        gradient_stop_colors: [16]Color = [_]Color{Color.rgba(0, 0, 0, 0)} ** 16,
        gradient_stop_positions: [16]f32 = [_]f32{0} ** 16,
        gradient_stop_count: u8 = 0,
        gradient_center_x: f32 = 0.5,
        gradient_center_y: f32 = 0.5,
        gradient_start_angle: f32 = 0,
    },
    /// 矢量路径描边（局部坐标，offset 相对节点左上角）
    stroke_path: struct {
        header: ItemHeader,
        geometry: *const types.PathGeometry,
        color: Color,
        width: f32 = 1.0,
        line_join: types.LineJoin = .miter,
        offset_x: f32 = 0,
        offset_y: f32 = 0,
        opacity: f32 = 1.0,
    },

    // ─── Effect/clip 字面 token variant ───
    // Effect bridge tokens are already lowered to the active content frame.
    // Node-owned push_clip is the exception: node_local requests the same
    // property-tree/replay transform as paint items before encoder dispatch.

    push_clip: struct {
        header: ItemHeader,
        /// Node clips share the paint item transform; literal bridge/snapshot clips are already lowered.
        node_local: bool = false,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        radius: f32 = 0,
        shape_kind: ClipShapeKind = .rect,
        polygon: ClipPolygon = .{},
    },
    pop_clip: struct {
        header: ItemHeader,
    },

    begin_opacity_layer: struct {
        header: ItemHeader,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        opacity: f32,
        /// Stage 3 rounded-clip fold: 同节点 rounded_clip 合并进 opacity layer 时
        /// 由 composite blit 施加的圆角 mask 半径（0 = 无圆角，语义同 begin_blur_layer）。
        corner_radius: f32 = 0,
        rotate: f32 = 0,
        draw_x: f32 = std.math.nan(f32),
        draw_y: f32 = std.math.nan(f32),
        draw_w: f32 = std.math.nan(f32),
        draw_h: f32 = std.math.nan(f32),
        use_draw_transform: bool = false,
        draw_transform: types.Transform2D = types.Transform2D.identity(),
        blend_mode: types.BlendMode = .normal,
        /// GPU retained 合成的缓存键（Stage 1 起）。
        ///
        /// `surface_stable_id` = 该 layer 的跨帧稳定身份（retained LayerId 的
        /// packed raw，含 generation ABA 防护）；`surface_content_version` =
        /// 内容版本，内容变一次涨一次。encoder 侧据此判断"同一个 layer 且内容
        /// 没变" → 可以直接复用上一帧光栅化好的离屏纹理，跳过内容 pass。
        ///
        /// INVALID(= std.math.maxInt(u32)) 表示本 layer 不参与 GPU retained
        /// （非 promoted / 无稳定身份），encoder 必须每帧重画 —— 这是安全默认值。
        surface_stable_id: u32 = INVALID_SURFACE_ID,
        surface_content_version: u32 = 0,
    },
    end_opacity_layer: struct {
        header: ItemHeader,
    },

    begin_blur_layer: struct {
        header: ItemHeader,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        corner_radius: f32 = 0,
        /// glass 拥有者 node id（亮度区域槽的稳定 key；header 是 CONTROL 不携带）
        owner_node: u32 = std.math.maxInt(u32),
        glass: types.ResolvedGlassParams = .{},
        rotate: f32 = 0,
        draw_x: f32 = std.math.nan(f32),
        draw_y: f32 = std.math.nan(f32),
        draw_w: f32 = std.math.nan(f32),
        draw_h: f32 = std.math.nan(f32),
        use_draw_transform: bool = false,
        draw_transform: types.Transform2D = types.Transform2D.identity(),
    },
    end_blur_layer: struct {
        header: ItemHeader,
    },

    begin_rounded_clip: struct {
        header: ItemHeader,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        radius: f32,
        rotate: f32 = 0,
        draw_x: f32 = std.math.nan(f32),
        draw_y: f32 = std.math.nan(f32),
        draw_w: f32 = std.math.nan(f32),
        draw_h: f32 = std.math.nan(f32),
        use_draw_transform: bool = false,
        draw_transform: types.Transform2D = types.Transform2D.identity(),
    },
    end_rounded_clip: struct {
        header: ItemHeader,
    },

    /// 返回所有变体共有的 ItemHeader（消灭调用方的重复 switch）
    pub fn header(self: DisplayItem) ItemHeader {
        return switch (self) {
            inline else => |it| it.header,
        };
    }

    /// 可变 header 访问：跨帧缓存 splice 时按 node_id 把写入帧的帧内序号
    /// (transform/clip/effect_id) 改写为本帧值（见 render_engine
    /// rewriteSplicedItemHeaders）。
    /// 控制类 item（层 begin/end、push/pop clip）：只做分组/状态切换，不含几何。
    /// 起 scroll-clip token 带的是**真实 header**（node_id = 发它的节点），
    /// 凡按 node_id 归属"子树内容"的扫描（bulk quad 插入点、z 归并）都必须跳过它们，
    /// 否则 token 会被当成该节点的最后一条内容。
    pub fn isControl(self: DisplayItem) bool {
        return switch (self) {
            .begin_opacity_layer,
            .end_opacity_layer,
            .begin_blur_layer,
            .end_blur_layer,
            .begin_rounded_clip,
            .end_rounded_clip,
            .push_clip,
            .pop_clip,
            => true,
            else => false,
        };
    }

    pub fn headerPtr(self: *DisplayItem) *ItemHeader {
        return switch (self.*) {
            inline else => |*it| &it.header,
        };
    }
};

pub const TextRunItem = @FieldType(DisplayItem, "text_run");

pub const DisplayList = struct {
    allocator: Allocator,
    items: std.ArrayList(DisplayItem),
    /// Pointer-backed items can be replayed after their node/cache/snapshot has
    /// rebuilt or been replaced. Keep text slices and path geometry with the
    /// list rather than borrowing them from mutable producer storage.
    payload_arena: std.heap.ArenaAllocator,

    pub fn init(allocator: Allocator) DisplayList {
        return .{
            .allocator = allocator,
            .items = .{},
            .payload_arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *DisplayList) void {
        self.items.deinit(self.allocator);
        self.payload_arena.deinit();
    }

    pub fn clear(self: *DisplayList) void {
        self.items.clearRetainingCapacity();
        _ = self.payload_arena.reset(.retain_capacity);
    }

    pub fn append(self: *DisplayList, item: DisplayItem) !void {
        var owned_item = item;
        switch (owned_item) {
            .text_run => |*text| {
                const arena = self.payload_arena.allocator();
                text.content = if (text.content.len > 0) try arena.dupe(u8, text.content) else "";
                if (text.spans) |spans| {
                    text.spans = if (spans.len > 0) try arena.dupe(types.TextSpan, spans) else null;
                }
            },
            .fill_path => |*path| path.geometry = try self.clonePathGeometry(path.geometry),
            .stroke_path => |*path| path.geometry = try self.clonePathGeometry(path.geometry),
            else => {},
        }
        try self.items.append(self.allocator, owned_item);
    }

    fn clonePathGeometry(self: *DisplayList, source: *const types.PathGeometry) !*const types.PathGeometry {
        const arena = self.payload_arena.allocator();
        const clone = try arena.create(types.PathGeometry);
        clone.* = source.*;
        clone.commands = try arena.dupe(types.PathCommand, source.commands);
        // The arena owns the command slice and releases it as a group.
        clone.owned = false;
        return clone;
    }

    pub fn slice(self: *const DisplayList, start: usize, len: usize) []const DisplayItem {
        const clamped_start = @min(start, self.items.items.len);
        const clamped_end = @min(clamped_start + len, self.items.items.len);
        return self.items.items[clamped_start..clamped_end];
    }

    pub fn count(self: *const DisplayList) usize {
        return self.items.items.len;
    }
};

pub fn resolveTextRunContent(
    blob_store: *const text_blob_mod.BlobStore,
    run: TextRunItem,
) []const u8 {
    if (run.blob_id != INVALID_ID) {
        if (blob_store.get(run.blob_id)) |blob| {
            // ⚠️ 身份校验：blob_id 是帧内序号，store 每帧 clear 后重新分配。
            // 跨帧存活的 item（replay/cache 路径）拿着旧序号，可能落在别的
            // 控件本帧新建的 blob 上 —— 不校验就会按自己的偏移切别人的字节
            // （实测：终端行画出状态栏 "plaintext" 的切片 "plainte"）。
            // hash 不匹配说明这个序号已经易主，退回 item 自带的 content。
            const identity_ok = run.blob_content_hash == 0 or
                run.blob_content_hash == blob.content_hash;
            if (identity_ok and
                run.blob_byte_start < run.blob_byte_end and
                run.blob_byte_end <= blob.content.len)
            {
                return blob.content[run.blob_byte_start..run.blob_byte_end];
            }
        }
    }
    return run.content;
}

test "resolveTextRunContent: blob_id 易主时回退到 item 自带文本" {
    // 回归：blob_id 是**帧内序号**，text_blob_store 每帧 clear 后重新分配。
    // 跨帧存活的 item（replay / 命令缓存）拿着旧序号，可能落在别的控件
    // 本帧新建的 blob 上 —— 不校验身份就会按自己的字节偏移去切别人的字节。
    //
    // 实测线上表现：终端行画出状态栏 "plaintext" 的切片 "plainte"、
    // 编辑器 tab 名 "hello.txt" 的切片 "hello.t"（截图实证）。
    const testing = std.testing;
    var store = text_blob_mod.BlobStore.init(testing.allocator);
    defer store.deinit();

    // 本帧 0 号 blob 属于状态栏
    var other = text_blob_mod.TextLayoutBlob{
        .style_key = .{ .font_size = 13, .font_weight = 400, .line_height = 1.35 },
        .content_hash = std.hash.Wyhash.hash(0, "plaintext"),
        .content = "plaintext",
        .line_count = 1,
    };
    other.lines[0] = .{ .byte_start = 0, .byte_end = 9, .width = 70 };
    const other_id = try store.append(other);

    // 上一帧的终端行 item：同样指向 0 号，但内容 hash 是自己的
    const stale_run = TextRunItem{
        .header = .{ .transform_id = 0, .node_id = 0 },
        .x = 0,
        .y = 0,
        .content = "(base) ",
        .blob_byte_start = 0,
        .blob_byte_end = 7,
        .color = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
        .font_size = 13,
        .blob_id = other_id,
        .blob_content_hash = std.hash.Wyhash.hash(0, "(base) "),
    };

    // 必须识破并回退，而不是切出 "plainte"
    try testing.expectEqualStrings("(base) ", resolveTextRunContent(&store, stale_run));

    // 同一序号、hash 匹配时仍走 blob 间接路径（不能因为加校验就退化）
    const live_run = TextRunItem{
        .header = .{ .transform_id = 0, .node_id = 0 },
        .x = 0,
        .y = 0,
        .content = "",
        .blob_byte_start = 0,
        .blob_byte_end = 5,
        .color = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
        .font_size = 13,
        .blob_id = other_id,
        .blob_content_hash = other.content_hash,
    };
    try testing.expectEqualStrings("plain", resolveTextRunContent(&store, live_run));
}

test "resolveTextRunContent: 漏传 blob_content_hash 会让身份校验退化成永真" {
    // 回归（下游编辑器状态栏 "3 × 4" → "4 × 5" 画成 "4 × 4"）：
    // display_list_lowering 的 re-lower 分支逐字段重建 TextRunItem 时，曾经
    // 只抄 blob_id 而**漏抄 blob_content_hash**。漏抄后该字段取默认 0，
    // resolveTextRunContent 的 `run.blob_content_hash == 0` 短路把身份校验
    // 变成永真 —— item 拿着上一帧的帧内序号，去切本帧**别的 blob** 的字节。
    //
    // 这个测试用「同序号 + 不同内容」的构造把两种取值摆在一起：带 hash 的
    // 必须识破并回退到自带文本，hash=0 的则会取到冒名 blob 的字节。后者正是
    // 漏抄字段时的实际行为，钉住它是为了让任何新增的 re-lower 站点若忘记
    // 成对透传，就在这里失败而不是在用户的屏幕上。
    const testing = std.testing;
    var store = text_blob_mod.BlobStore.init(testing.allocator);
    defer store.deinit();

    var impostor = text_blob_mod.TextLayoutBlob{
        .style_key = .{ .font_size = 11, .font_weight = 400, .line_height = 1.35 },
        .content_hash = std.hash.Wyhash.hash(0, "3 \xc3\x97 4"),
        .content = "3 \xc3\x97 4",
        .line_count = 1,
    };
    impostor.lines[0] = .{ .byte_start = 0, .byte_end = 6, .width = 40 };
    const impostor_id = try store.append(impostor);

    const base = TextRunItem{
        .header = .{ .transform_id = 0, .node_id = 0 },
        .x = 0,
        .y = 0,
        .content = "4 \xc3\x97 5",
        .blob_byte_start = 0,
        .blob_byte_end = 6,
        .color = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
        .font_size = 11,
        .blob_id = impostor_id,
    };

    // 正确透传：hash 不匹配 → 识破易主，回退到 item 自带的本帧文本。
    var carried = base;
    carried.blob_content_hash = std.hash.Wyhash.hash(0, "4 \xc3\x97 5");
    try testing.expectEqualStrings("4 \xc3\x97 5", resolveTextRunContent(&store, carried));

    // 漏传（=0）：校验被短路，切到冒名 blob 的字节 —— 正是屏幕上的陈旧字形。
    try testing.expectEqualStrings("3 \xc3\x97 4", resolveTextRunContent(&store, base));
}

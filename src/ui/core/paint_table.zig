//! PaintTable + PaintChunk — Phase 3 拆 Node 的渲染产物
//!
//! 每 element 持一个 PaintChunk：
//!   - display_items[]：高层语义绘制项（rect / text / image / path / shadow）
//!   - property_state_ref：(transform_id, clip_id, effect_id, scroll_id) 四元 u32 引用 PropertyTree
//!   - bounds：world-space AABB（用于 culling / hit broad-phase）
//!   - content_hash：内容稳定 hash —— 重新生成时若 hash 命中则跳过录制，复用上帧 display_items
//!
//! 历史债避免（吸取 zenit 现状中 "Node.cached_commands" 是唯一保留态、
//! 而 display_items 每帧重建 的问题）：
//! - chunk 自身跨帧保留；只在 content_hash mismatch 时才重生
//! - 不持有 GPU 资源；那些去 ResourcePool。chunk 只是 CPU 侧 IR
//! - paint_epoch 与 layout_epoch 解耦：颜色变化 paint_epoch++，layout_epoch 不变
//!
//! Phase 4 layer tree 接入后，layer 按 chunk 分组并跟踪 damage rect。

const std = @import("std");
const testing = std.testing;
const element_id_mod = @import("element_id.zig");
const types = @import("types.zig");
const display_list_mod = @import("display_list.zig");
const icon_ir = @import("icon_ir");

pub const ElementId = element_id_mod.ElementId;

/// Property tree 引用：四个 u32 索引 PropertyTree 的 4 棵树。
/// INVALID_ID = 该轴无引用（继承父）。
pub const PropertyStateRef = packed struct(u128) {
    transform_id: u32 = std.math.maxInt(u32),
    clip_id: u32 = std.math.maxInt(u32),
    effect_id: u32 = std.math.maxInt(u32),
    scroll_id: u32 = std.math.maxInt(u32),

    pub const NONE: PropertyStateRef = .{};
};

/// World-space bounds（postransformed AABB）
pub const Bounds = struct {
    min_x: f32 = 0,
    min_y: f32 = 0,
    max_x: f32 = 0,
    max_y: f32 = 0,

    pub const ZERO: Bounds = .{};

    pub fn isEmpty(self: Bounds) bool {
        return self.max_x <= self.min_x or self.max_y <= self.min_y;
    }

    pub fn unionWith(a: Bounds, b: Bounds) Bounds {
        if (a.isEmpty()) return b;
        if (b.isEmpty()) return a;
        return .{
            .min_x = @min(a.min_x, b.min_x),
            .min_y = @min(a.min_y, b.min_y),
            .max_x = @max(a.max_x, b.max_x),
            .max_y = @max(a.max_y, b.max_y),
        };
    }
};

/// 高层 display item 类别。当前先列基本几种；后续 paint pass 切换时按需加。
pub const DisplayItemKind = enum(u8) {
    /// 占位（用于 chunk 创建时）
    none,
    /// 实色矩形（含圆角）
    rect,
    /// 文本 run
    text,
    /// 图片 / SVG icon
    image,
    /// 路径填充
    path,
    /// 阴影
    shadow,
    /// 渐变填充
    gradient,
    /// effect/clip control token (begin/end_opacity/blur/rounded_clip + push/pop_clip)
    control,
};

/// Control sub-kind (B-7-C): 当 DisplayItemKind == .control 时区分 8 种 token。
/// .none 用于非 control item (paint kind)。
pub const ControlKind = enum(u8) {
    none = 0,
    push_clip = 1,
    pop_clip = 2,
    begin_opacity_layer = 3,
    end_opacity_layer = 4,
    begin_blur_layer = 5,
    end_blur_layer = 6,
    begin_rounded_clip = 7,
    end_rounded_clip = 8,
};

/// fill_rect kind 的几何 payload (x,y,w,h packed)。32-bit f16 quantized 节省空间，
/// 但当前先用 f32 简单清晰；后续真接管 batch 时再 quantize。
pub const RectGeom = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,
};

/// 4-corner radius (TL/TR/BR/BL)
pub const CornerRadii = struct {
    tl: f32 = 0,
    tr: f32 = 0,
    br: f32 = 0,
    bl: f32 = 0,

    /// 转 [4]f32 顺序 TL/TR/BR/BL — sdf_renderer.addRoundedRect 直消费的格式。
    /// 让 encoder 切到 paint_table 时无需转换。
    pub fn toArray(self: CornerRadii) [4]f32 {
        return .{ self.tl, self.tr, self.br, self.bl };
    }

    pub fn fromArray(arr: [4]f32) CornerRadii {
        return .{ .tl = arr[0], .tr = arr[1], .br = arr[2], .bl = arr[3] };
    }
};

/// RGBA8 packed color (与 types.Color 同 layout 但本模块不依赖 types)
pub const RGBA = packed struct(u32) {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
    a: u8 = 0,

    /// 转 GPU shader 用的 normalized [4]f32 (linear RGB convention)。
    /// 让 encoder 切到 paint_table 时直接喂 sdf_renderer。
    pub fn toFloat4(self: RGBA) [4]f32 {
        const inv: f32 = 1.0 / 255.0;
        return .{
            @as(f32, @floatFromInt(self.r)) * inv,
            @as(f32, @floatFromInt(self.g)) * inv,
            @as(f32, @floatFromInt(self.b)) * inv,
            @as(f32, @floatFromInt(self.a)) * inv,
        };
    }

    /// 转 types.Color (相同 r/g/b/a u8 字段，字段顺序一致 → bitcast 等价但显式
    /// 字段拷贝更清晰，便于 caller 用 Color.eql/Color.rgba 等 API)。tests fixture 用。
    pub fn toColor(self: RGBA) types.Color {
        return .{ .r = self.r, .g = self.g, .b = self.b, .a = self.a };
    }
};

/// 高层 display item —— 绘制描述。
///
/// v0.5 §5 GpuDraw epic B-4 起步: 旧 payload_a/b u64 placeholder 升级为
/// 强类型字段 (geom + color + radii)，让 shadow 路径能真验证内容等价；
/// 后续真接管时 paint_table.DisplayItem 直接喂 backend，不丢数据。
///
/// B-5+ 扩展 kind-specific 字段:
/// - stroke_rect: stroke_width (line 1)
/// - shadow_rect: shadow_blur + shadow_offset_x/y (line 4-6)
/// - border_per_side: border_widths [4]f32
/// - image_quad: image_opacity
///
/// 后续阶段继续补 gradient (to_color/direction/extend_mode) / text (font_size/
/// weight/italic/spans) / path / icon 等字段。
pub const DisplayItem = struct {
    kind: DisplayItemKind,
    /// 该 item 在 element 局部空间的 AABB（用于 chunk 内裁剪 / 部分重画）
    local_bounds: Bounds = .{},
    /// 资源句柄（texture / glyph atlas / path geometry buffer 等），u64 类型擦除。
    /// Phase 4 接入 ResourcePool 时替换为强类型 ResourceHandle。
    resource_handle: u64 = 0,
    /// 几何（rect kind 用 x/y/w/h；其它 kind 当前 0）
    geom: RectGeom = .{},
    /// 主色 (rect/stroke/shadow/text 用)
    color: RGBA = .{},
    /// 圆角半径 (rect/stroke 用)
    radii: CornerRadii = .{},

    // ── kind-specific extension fields (B-5+) ──
    /// stroke / outline 线宽 (stroke_rect, outline_rect, border_side 用)
    stroke_width: f32 = 0,
    /// border_per_side: top/right/bottom/left 各边 width
    border_widths: [4]f32 = .{ 0, 0, 0, 0 },
    /// shadow_rect: 模糊半径
    shadow_blur: f32 = 0,
    /// shadow_rect: 阴影偏移 x
    shadow_offset_x: f32 = 0,
    /// shadow_rect: 阴影偏移 y
    shadow_offset_y: f32 = 0,
    /// shadow_rect: CSS spread
    shadow_spread: f32 = 0,
    /// image_quad: 透明度 (0..1)
    image_opacity: f32 = 1,
    // ── gradient_rect 专用 ──
    /// gradient: 终点颜色 (color 字段是起点 from)
    gradient_to_color: RGBA = .{},
    /// gradient: direction enum 表示 (与 types.GradientDirection 同顺序)。
    /// 0=horizontal 1=vertical 2=diagonal 3=radial 4=conic
    gradient_direction: u8 = 1,
    /// gradient: extend mode (与 types.GradientExtendMode 同顺序)。
    /// 0=pad 1=repeat 2=reflect
    gradient_extend_mode: u8 = 0,
    /// radial gradient: 中心 x 偏移 (相对几何中心，0..1 normalized)
    gradient_radial_center_x: f32 = 0,
    /// radial gradient: 中心 y 偏移 (相对几何中心，0..1 normalized)
    gradient_radial_center_y: f32 = 0,
    /// 径向椭圆半径（UV 单位；0.5 = 内切，旧行为）
    gradient_radial_radius_x: f32 = 0.5,
    gradient_radial_radius_y: f32 = 0.5,
    /// conic gradient: 起始角度 (radians)
    gradient_conic_start_angle: f32 = 0,
    // ── text_run 专用 ──
    /// text 逻辑字号（不乘 scale）
    text_font_size: f32 = 0,
    /// text 字重 (400 = regular, 700 = bold)
    text_font_weight: u16 = 400,
    /// text 字体族 id(render.FontRegistry)。0 = 默认族。
    text_font_family: u16 = 0,
    /// text font flags packed: bit 0 = italic, bit 1 = monospace, bit 2 = symbols
    text_font_flags: u8 = 0,
    /// monospace 字符宽度 (0 = 非 monospace 或自动)
    text_monospace_char_width: f32 = 0,
    /// blob byte 范围 start (用于 sub-string render)
    text_blob_byte_start: u32 = 0,
    /// blob byte 范围 end (exclusive)
    text_blob_byte_end: u32 = 0,
    /// text_run.content (生命周期由 display_list / TextLayoutBlob 保证)
    text_content: []const u8 = "",
    /// text_run.spans (?[]const TextSpan) — null 表示无 span 着色
    text_spans: ?[]const types.TextSpan = null,
    /// text_run.raster_policy 过线值（与 text_blob.TextRasterPolicy 一一对应）：
    /// 0 = static_crisp (默认), 1 = animated_stable/direct_animated, 2 = surface_cached。
    /// encoder 侧 exhaustive switch 消化，禁止折叠成布尔。
    text_raster_policy: u8 = 0,
    /// text_run 右端淡出遮罩窗口（相对 geom.x 的偏移；0/0 = 关闭）
    text_fade_dx0: f32 = 0,
    text_fade_dx1: f32 = 0,
    // ── noise_rect 专用 (B-7-B 第一刀: 推 paint_table 主路径覆盖 noise) ──
    /// noise mode (0=cellular 1=fbm 2=value 等，与 types.NoiseMode 同顺序)
    noise_mode: u8 = 0,
    /// noise scale (单位: pixels per cell)
    noise_scale: f32 = 0,
    /// noise intensity (0..1)。dispatchCommand .rect arm 用 > 0 判别是否走 noise 路径，
    /// 默认必须 0；非 noise_rect 的 .rect kind item 不能有非零 intensity (B-7 主路径切换 bug)
    noise_intensity: f32 = 0,
    /// noise PRNG seed
    noise_seed: u8 = 0,
    // ── multi_gradient_rect 专用 (B-7-D) ──
    /// 16 stop 颜色数组（与 display_list union 同 capacity）
    mg_stop_colors: [16]RGBA = [_]RGBA{.{}} ** 16,
    /// 16 stop 位置（0..1 normalized）
    mg_stop_positions: [16]f32 = [_]f32{0} ** 16,
    /// 实际 stop 数（≤16）
    mg_stop_count: u8 = 0,
    // ── icon_rep / fill_path / stroke_path 专用 (B-7-D) ──
    /// icon_rep: *const icon_ir.Rep。
    icon_rep_ptr: ?*const icon_ir.Rep = null,
    /// fill_path / stroke_path: *const types.PathGeometry
    path_geometry_ptr: ?*const types.PathGeometry = null,
    /// push_clip(polygon): *const display_list_mod.ClipPolygon
    clip_polygon_ptr: ?*const display_list_mod.ClipPolygon = null,
    /// begin_blur_layer.glass: *const types.ResolvedGlassParams
    glass_ptr: ?*const types.ResolvedGlassParams = null,
    /// glass 拥有者 node id（亮度区域槽的稳定 key）
    glass_owner_id: u32 = std.math.maxInt(u32),
    /// rotate 角度 (image_quad/icon_rep 用) - 弧度
    rotate: f32 = 0,
    /// stroke_path: line join (与 types.LineJoin 同顺序)。0=miter 1=bevel 2=round
    path_line_join: u8 = 0,
    /// icon_rep: corner clip radius
    icon_corner_clip_radius: f32 = 0,
    /// icon_rep: tint color
    icon_tint: RGBA = .{ .r = 255, .g = 255, .b = 255, .a = 255 },
    /// icon_rep: rep_size (px hint)
    icon_rep_size: u8 = 0,
    /// image_quad: tint color (与 icon_tint 平行；image_quad 单独存避免歧义)
    image_tint: RGBA = .{ .r = 255, .g = 255, .b = 255, .a = 255 },
    /// image_quad: corner_radius (与 radii 区别 — image_quad union 字段是单 f32)
    image_corner_radius: f32 = 0,
    // ── inset_shadow_rect / shadow_dual_rect 专用 (B-7-E) ──
    /// shadow_dual / inset_shadow 的辅助阴影颜色 (shadow_dual.shadow1_color，
    /// inset_shadow.shadow_color)。主 color 字段保留 fill 颜色；secondary 是
    /// 阴影颜色 — 跟 gradient_to_color 类比但语义独立避免 alias。
    shadow_secondary_color: RGBA = .{},
    /// shadow_dual 第二阴影颜色
    shadow2_color: RGBA = .{},
    /// shadow_dual 第二阴影 blur
    shadow2_blur: f32 = 0,
    /// shadow_dual 第二阴影 offset x
    shadow2_offset_x: f32 = 0,
    /// shadow_dual 第二阴影 offset y
    shadow2_offset_y: f32 = 0,
    // ── arc 专用 (B-7-E) ──
    /// arc 起始角度（弧度）
    arc_start_angle: f32 = 0,
    /// arc 结束角度（弧度）
    arc_end_angle: f32 = 0,
    /// arc 外圆半径 (用 geom.x/y 存中心点；w/h 存 0；这里独立存半径避免歧义)
    arc_outer_radius: f32 = 0,
    // ── control kind 专用 (B-7-C) ──
    /// 当 kind == .control 时区分 8 种 token；paint kind 时 .none。
    control_kind: ControlKind = .none,
    /// begin_opacity_layer.opacity / begin_*.draw_w/h 等共用此字段。
    /// 平时 0；begin_opacity_layer 写 opacity (rect kind 也共用)。
    opacity: f32 = 0,
    /// 绘制形状 (fill_rect/stroke_rect)：0 = rounded_rect, 1 = ellipse。
    /// 与 types.ShapeSpec 同序。**不是** clip_shape_kind —— 那个是裁剪掩码，
    /// 只裁内容裁不动描边；这个换的是填充与描边的距离场本身。
    shape_kind: u8 = 0,
    /// push_clip.shape_kind (rect/rounded_rect/ellipse/polygon)。0 = rect。
    /// 与 display_list.ClipShapeKind 同顺序。
    clip_shape_kind: u8 = 0,
    /// begin_opacity_layer.blend_mode (与 types.BlendMode 同顺序，0 = normal)
    blend_mode: u8 = 0,
    /// begin_opacity / begin_blur / begin_rounded_clip 的 draw_x/y/w/h。
    /// NaN 默认值与 union 字段对齐（caller 用 isNan 判别）。
    draw_x: f32 = 0,
    draw_y: f32 = 0,
    draw_w: f32 = 0,
    draw_h: f32 = 0,
    /// begin_opacity_layer 的 GPU retained 缓存键（见 display_list 同名字段）。
    /// surface_stable_id = 跨帧稳定 layer 身份，INVALID_SURFACE_ID = 不参与
    /// retained（每帧重画）；surface_content_version = 内容版本。
    surface_stable_id: u32 = display_list_mod.INVALID_SURFACE_ID,
    surface_content_version: u32 = 0,
    /// use_draw_transform 标记 + draw_transform[6] 仿射 matrix。
    use_draw_transform: bool = false,
    draw_transform: [6]f32 = .{ 1, 0, 0, 1, 0, 0 },
    // 复杂 control payload (push_clip.polygon / begin_blur_layer.glass) 暂不
    // inline；走 extra_ptr 透传 source union variant 的指针。lowerDisplayItem
    // 写 source variant payload &it 进 extra_ptr，dispatch 端 cast 回原类型读
    // polygon / glass 字段。生命周期由 caller 保证 (display_list 跨帧稳定)。

    /// tests fixture 友好 helpers (v0.5 §5 GpuDraw 收尾切 tests 时用)：
    /// 让 fixture 写起来跟 union .text_run / .fill_rect / .push_clip 等 pattern
    /// 一样直接，不必每处 spell out kind/control_kind 组合。
    pub fn isFillRect(self: DisplayItem) bool {
        return self.kind == .rect and self.stroke_width == 0;
    }
    pub fn isStrokeRect(self: DisplayItem) bool {
        return self.kind == .rect and self.stroke_width > 0;
    }
    pub fn isText(self: DisplayItem) bool {
        return self.kind == .text;
    }
    pub fn isShadow(self: DisplayItem) bool {
        return self.kind == .shadow;
    }
    pub fn isGradient(self: DisplayItem) bool {
        return self.kind == .gradient;
    }
    pub fn isImage(self: DisplayItem) bool {
        return self.kind == .image;
    }
    pub fn isControl(self: DisplayItem, ck: ControlKind) bool {
        return self.kind == .control and self.control_kind == ck;
    }
};

pub const TextFontFlag = struct {
    pub const italic: u8 = 1;
    pub const monospace: u8 = 2;
    pub const symbols: u8 = 4;
};

/// 单 element 的 paint chunk
pub const PaintChunk = struct {
    /// chunk 涉及的 display items
    display_items: std.ArrayListUnmanaged(DisplayItem),
    /// 引用 PropertyTree 的 4 棵树状态
    property_state: PropertyStateRef = .NONE,
    /// world-space bounds（包络所有 display_items）
    bounds: Bounds = .ZERO,
    /// 内容 hash —— 比对此值与上次记录决定是否需要重新录制
    content_hash: u64 = 0,
    /// paint_epoch：每次重录 ++。下游 layer cache 据此判失效。
    paint_epoch: u64 = 0,

    pub fn deinit(self: *PaintChunk, allocator: std.mem.Allocator) void {
        self.display_items.deinit(allocator);
    }

    pub fn clear(self: *PaintChunk) void {
        self.display_items.clearRetainingCapacity();
        self.bounds = .ZERO;
    }
};

pub const PaintTable = struct {
    allocator: std.mem.Allocator,
    /// dense by ElementId.index
    chunks: std.ArrayListUnmanaged(PaintChunk),

    pub fn init(allocator: std.mem.Allocator) PaintTable {
        return .{ .allocator = allocator, .chunks = .{} };
    }

    pub fn deinit(self: *PaintTable) void {
        for (self.chunks.items) |*c| c.deinit(self.allocator);
        self.chunks.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn ensureSlot(self: *PaintTable, id: ElementId) !void {
        if (id.isNull()) return;
        const idx = id.index;
        while (self.chunks.items.len <= idx) {
            try self.chunks.append(self.allocator, .{ .display_items = .{} });
        }
    }

    pub fn get(self: *PaintTable, id: ElementId) ?*PaintChunk {
        if (id.isNull() or id.index >= self.chunks.items.len) return null;
        return &self.chunks.items[id.index];
    }

    /// 元素销毁时调用：释放 display_items 内存并把 chunk 复位到"从未录制"。
    /// slot 本身保留（dense by index），但内容必须清，否则：
    /// 1) 长生命周期窗口反复 mount/unmount 时 display_items 堆内存只增不减；
    /// 2) slot 复用后若新 owner 的 content_hash 恰好撞上旧值，beginRecord 的
    ///    cache-hit（paint_epoch != 0 分支）会原样吐出上一个 owner 的
    ///    display_items（内容串台）；
    /// 3) 下游按全表扫描消费 property_state（core.zig syncPaint 循环用 idx
    ///    反推 id、恒拼出当前世代），已死元素的残留 effect 引用会继续参与
    ///    图层提升决策。
    pub fn release(self: *PaintTable, id: ElementId) void {
        if (id.isNull() or id.index >= self.chunks.items.len) return;
        const chunk = &self.chunks.items[id.index];
        chunk.display_items.clearAndFree(self.allocator);
        chunk.bounds = .ZERO;
        chunk.content_hash = 0;
        chunk.paint_epoch = 0;
        chunk.property_state = .NONE;
    }

    pub fn epoch(self: *const PaintTable, id: ElementId) u64 {
        if (id.isNull() or id.index >= self.chunks.items.len) return 0;
        return self.chunks.items[id.index].paint_epoch;
    }

    /// 重新录制 chunk —— 只在 content_hash 不同时真正清空 + 再录制。
    /// 返回 true 表示真的重录了；false 表示 hash 命中跳过。
    pub fn beginRecord(self: *PaintTable, id: ElementId, new_content_hash: u64) !bool {
        try self.ensureSlot(id);
        const chunk = &self.chunks.items[id.index];
        if (chunk.content_hash == new_content_hash and chunk.paint_epoch != 0) {
            return false; // cache hit
        }
        chunk.clear();
        chunk.content_hash = new_content_hash;
        return true;
    }

    pub fn pushItem(self: *PaintTable, id: ElementId, item: DisplayItem) !void {
        if (id.isNull() or id.index >= self.chunks.items.len) return;
        const chunk = &self.chunks.items[id.index];
        try chunk.display_items.append(self.allocator, item);
        chunk.bounds = chunk.bounds.unionWith(item.local_bounds);
    }

    pub fn endRecord(self: *PaintTable, id: ElementId, prop_ref: PropertyStateRef) void {
        if (id.isNull() or id.index >= self.chunks.items.len) return;
        const chunk = &self.chunks.items[id.index];
        chunk.property_state = prop_ref;
        chunk.paint_epoch +%= 1;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "PaintTable: ensureSlot / get / epoch" {
    var t = PaintTable.init(testing.allocator);
    defer t.deinit();

    const id: ElementId = .{ .index = 0, .generation = 0 };
    try t.ensureSlot(id);
    const chunk = t.get(id).?;
    try testing.expectEqual(@as(u64, 0), chunk.paint_epoch);
    try testing.expectEqual(@as(u64, 0), t.epoch(id));
}

test "PaintTable: beginRecord on different hash bumps epoch + clears items" {
    var t = PaintTable.init(testing.allocator);
    defer t.deinit();
    const id: ElementId = .{ .index = 0, .generation = 0 };

    // 首次录制
    try testing.expect(try t.beginRecord(id, 0xAAAA));
    try t.pushItem(id, .{ .kind = .rect, .local_bounds = .{ .min_x = 0, .min_y = 0, .max_x = 100, .max_y = 50 } });
    t.endRecord(id, .NONE);

    const epoch1 = t.epoch(id);
    try testing.expect(epoch1 > 0);
    try testing.expectEqual(@as(usize, 1), t.get(id).?.display_items.items.len);

    // 同 hash → 不重录
    try testing.expect(!(try t.beginRecord(id, 0xAAAA)));
    try testing.expectEqual(epoch1, t.epoch(id));
    try testing.expectEqual(@as(usize, 1), t.get(id).?.display_items.items.len);

    // 不同 hash → 重录
    try testing.expect(try t.beginRecord(id, 0xBBBB));
    try testing.expectEqual(@as(usize, 0), t.get(id).?.display_items.items.len); // cleared
    try t.pushItem(id, .{ .kind = .text, .local_bounds = .{} });
    t.endRecord(id, .NONE);
    try testing.expect(t.epoch(id) > epoch1);
}

test "PaintTable: bounds union accumulates" {
    var t = PaintTable.init(testing.allocator);
    defer t.deinit();
    const id: ElementId = .{ .index = 0, .generation = 0 };

    _ = try t.beginRecord(id, 1);
    try t.pushItem(id, .{ .kind = .rect, .local_bounds = .{ .min_x = 0, .min_y = 0, .max_x = 100, .max_y = 50 } });
    try t.pushItem(id, .{ .kind = .rect, .local_bounds = .{ .min_x = 50, .min_y = 30, .max_x = 200, .max_y = 80 } });
    t.endRecord(id, .NONE);

    const chunk = t.get(id).?;
    try testing.expectEqual(@as(f32, 0), chunk.bounds.min_x);
    try testing.expectEqual(@as(f32, 0), chunk.bounds.min_y);
    try testing.expectEqual(@as(f32, 200), chunk.bounds.max_x);
    try testing.expectEqual(@as(f32, 80), chunk.bounds.max_y);
}

test "PropertyStateRef is exactly 16 bytes" {
    try testing.expectEqual(@as(usize, 16), @sizeOf(PropertyStateRef));
}

test "Bounds: unionWith with empty" {
    const empty: Bounds = .{};
    const real: Bounds = .{ .min_x = 0, .min_y = 0, .max_x = 100, .max_y = 50 };
    try testing.expectEqual(real, empty.unionWith(real));
    try testing.expectEqual(real, real.unionWith(empty));
}

test "RGBA.toFloat4: roundtrip" {
    const c: RGBA = .{ .r = 255, .g = 128, .b = 0, .a = 255 };
    const f = c.toFloat4();
    try testing.expectEqual(@as(f32, 1.0), f[0]);
    try testing.expectApproxEqAbs(@as(f32, 0.5019608), f[1], 0.001);
    try testing.expectEqual(@as(f32, 0.0), f[2]);
    try testing.expectEqual(@as(f32, 1.0), f[3]);
}

test "CornerRadii.toArray + fromArray: roundtrip" {
    const r = CornerRadii.fromArray(.{ 4, 8, 16, 0 });
    try testing.expectEqual(@as(f32, 4), r.tl);
    try testing.expectEqual(@as(f32, 8), r.tr);
    try testing.expectEqual(@as(f32, 16), r.br);
    try testing.expectEqual(@as(f32, 0), r.bl);
    const arr = r.toArray();
    try testing.expectEqual([4]f32{ 4, 8, 16, 0 }, arr);
}

comptime {
    // GPU retained 哨兵三处一致：display_list（产出端）、paint_table（本文件，
    // 传输端）、render/opacity_layer + offscreen_texture（消费端，那两处之间
    // 另有 comptime 断言互钉）。消费端在 render module 里、不便反向 import，
    // 故用同一个字面量并在此处钉住产出/传输两端。
    std.debug.assert(display_list_mod.INVALID_SURFACE_ID == std.math.maxInt(u32));
}

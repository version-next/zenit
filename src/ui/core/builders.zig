//! Top-level node-tree builder functions: `box`, `text`, `image`, `icon`,
//! `svg`, `spacer`, `grid`, `clickable`, `hstack`/`vstack`, plus the
//! `appendChildrenFromTuple` helper used by all container builders.
//!
//! Extracted from `core.zig` to keep that file focused on the `Cx` runtime.
//! These functions take `cx: anytype` (a `*core.Cx`) — using anytype avoids
//! a build-time import cycle between core.zig (which re-exports the builders)
//! and this file (which would otherwise need to `@import("../core.zig")`).
//!
//! No behavior change.

const std = @import("std");
const icon_ir = @import("icon_ir");
const types = @import("types.zig");
const node_mod = @import("node.zig");
const svg_geometry = @import("svg_geometry.zig");
const svg_assets_mod = @import("../svg_assets.zig");
const theme = @import("../theme.zig");

const Node = node_mod.Node;
const Color = types.Color;
const Style = types.Style;
const BoxStyle = types.BoxStyle;
const Sizing = types.Sizing;
const Padding = types.Padding;
const Border = types.Border;
const JustifyContent = types.JustifyContent;
const AlignItems = types.AlignItems;
const HandlerRef = types.HandlerRef;
const GridTrackSize = types.GridTrackSize;
const GridConfig = types.GridConfig;

/// 统一的节点创建入口 —— **不依赖进程级全局**。
///
/// P0-3：`Node.create` 靠 `g_node_create_hook` + `g_active_world` 这对全局
/// 把节点注册到 World；多个 Cx 并存时它会注册到"最后一个 init 的 Cx"，
/// 而不是调用者自己的那个。builder 手上本来就有 cx，没有理由绕全局。
///
/// 用 `@hasField` 探测是为了兼容 cx 为 anytype 的既有签名（少数测试传的是
/// 精简 mock，没有 world/world_id 字段）—— 那种情况退回旧路径。
fn createNode(cx: anytype, tag: types.ElementTag, style: Style) !*Node {
    const CxT = @TypeOf(cx.*);
    if (@hasField(CxT, "world") and @hasField(CxT, "world_id")) {
        return node_mod.createIn(cx.allocator, &cx.world, cx.world_id, cx.nextId(), tag, style);
    }
    return Node.create(cx.allocator, cx.nextId(), tag, style);
}

/// box - 通用容器节点
///
/// 用法:
/// ```
/// try ui.box(cx, .{ .direction = .row, .gap = 8 }, .{
///     ui.text("Hello", .{}),
///     ui.text("World", .{}),
/// });
/// ```
/// 把 BoxStyle 的 background/opacity（已不在 Style）经
/// SoA 写入口落到 World.paint_state。必须在 linkNodeToWorld 之后调用，
/// 这样 element_id 已分配，setBackgroundRaw 走 World 而非 standalone。
pub fn applyPaintOverride(node: *Node, ov: types.BoxStyle.PaintOverride) void {
    if (ov.background) |c| node.setBackgroundRaw(c);
    if (ov.opacity) |o| node.setOpacityRaw(o);
}

fn boxWithOrigin(
    cx: anytype,
    style: BoxStyle,
    children_tuple: anytype,
    origin_address: usize,
    origin_kind: @import("world.zig").StyleOriginKind,
) !*Node {
    const resolved = try style.toStyleFallible(cx.allocator);
    const node = createNode(cx, .box, resolved) catch |err| {
        if (resolved.ext) |ext| cx.allocator.destroy(ext);
        return err;
    };
    // node 建好之后到 return 之前，它是一棵无人持有的游离子树：
    // appendChildrenFromTuple 里的任何一次分配失败都会让它整棵泄漏。
    // 消费方下游编辑器做 mount 路径的逐分配点 OOM 注入时，
    // 交叉 review 把「box 自身是否事务化」列为待验证前提 —— 查证结果是**不是**，
    // 这里补上。box 是全仓库最高频的构造入口，这一处覆盖面很大。
    errdefer cx.freeDetachedNodeAfterScopeDispose(node);
    cx.linkNodeToWorld(node);
    applyPaintOverride(node, style.paintOverride());
    node.recordStyleBaseOrigin(style.styleFieldMask(), origin_address, origin_kind);
    try appendChildrenFromTuple(cx, node, children_tuple);
    return node;
}

pub fn box(cx: anytype, style: BoxStyle, children_tuple: anytype) !*Node {
    return boxWithOrigin(cx, style, children_tuple, @returnAddress(), .inline_builder);
}

// ============================================================================
// Styled builders —— 主题安全的具名样式函数消费端
//
// `styles.zig` 约定的消费入口：样式是 `fn (*const ThemeTokens) BoxStyle` 纯函数，
// mount 时求值一次，同时挂 on_theme hook；`Cx.setTheme` 全树遍历会带新 tokens
// 重放样式函数（applyTo + paint override + markLayoutDirty），普通 `box(cx, .{...})`
// 的字面量样式在换主题后是死值，这里不是。
// on_theme 不是 before_render hook：不参与每帧执行，也不影响 promoted 渲染缓存资格。
// 覆盖范围：setTheme 只遍历 cx.root 子树，独立 overlay 树外的节点不在其中。
// ============================================================================

fn boxThemeHookFor(comptime style_fn: fn (*const theme.ThemeTokens) BoxStyle) node_mod.ThemeHook {
    return struct {
        fn hook(n: *Node, t: *const theme.ThemeTokens, allocator: std.mem.Allocator) void {
            const s = style_fn(t);
            s.applyTo(&n.style, allocator);
            applyPaintOverride(n, s.paintOverride());
            // invokeThemeHookRecursive 只标 render/composite；样式函数可能输出
            // padding/width/font_size 等布局字段，这里统一标 layout（换主题低频，无热路径成本）
            n.markLayoutDirty();
        }
    }.hook;
}

/// boxStyled - 主题安全的 box：样式来自具名纯函数而非内联字面量
///
/// 用法:
/// ```
/// // styles.zig:  pub fn card(t: *const ThemeTokens) BoxStyle { return .{ .background = t.color.bg_secondary, ... }; }
/// const node = try ui.boxStyled(cx, S.card, .{ ...children });
/// ```
pub fn boxStyled(cx: anytype, comptime style_fn: fn (*const theme.ThemeTokens) BoxStyle, children_tuple: anytype) !*Node {
    const style = style_fn(cx.tokens);
    const node = try boxWithOrigin(cx, style, children_tuple, @intFromPtr(&style_fn), .styled);
    node.meta.per_frame.hooks.on_theme = boxThemeHookFor(style_fn);
    return node;
}

/// hstackStyled - 主题安全的 hstack（direction 在重放时也保持 .row）
pub fn hstackStyled(cx: anytype, comptime style_fn: fn (*const theme.ThemeTokens) BoxStyle, children_tuple: anytype) !*Node {
    const wrapped = struct {
        fn f(t: *const theme.ThemeTokens) BoxStyle {
            var s = style_fn(t);
            s.direction = .row;
            return s;
        }
    }.f;
    var style = style_fn(cx.tokens);
    style.direction = .row;
    const node = try boxWithOrigin(cx, style, children_tuple, @intFromPtr(&style_fn), .styled);
    node.meta.per_frame.hooks.on_theme = boxThemeHookFor(wrapped);
    return node;
}

/// vstackStyled - 主题安全的 vstack（direction 在重放时也保持 .column）
pub fn vstackStyled(cx: anytype, comptime style_fn: fn (*const theme.ThemeTokens) BoxStyle, children_tuple: anytype) !*Node {
    const wrapped = struct {
        fn f(t: *const theme.ThemeTokens) BoxStyle {
            var s = style_fn(t);
            s.direction = .column;
            return s;
        }
    }.f;
    var style = style_fn(cx.tokens);
    style.direction = .column;
    const node = try boxWithOrigin(cx, style, children_tuple, @intFromPtr(&style_fn), .styled);
    node.meta.per_frame.hooks.on_theme = boxThemeHookFor(wrapped);
    return node;
}

fn textThemeHookFor(comptime style_fn: fn (*const theme.ThemeTokens) TextStyle) node_mod.ThemeHook {
    return struct {
        fn hook(n: *Node, t: *const theme.ThemeTokens, allocator: std.mem.Allocator) void {
            _ = allocator;
            const s = style_fn(t);
            // getText → 改样式字段 → setText 原样写回：content 指针不变，
            // ContentTable.setText 的指针守卫保证不误 free owned 内容。
            var props = n.getText() orelse return;
            props.color = s.color;
            props.font_size = s.font_size;
            props.font_weight = s.font_weight;
            props.line_height = s.line_height;
            props.wrap = s.wrap;
            props.max_lines = s.max_lines;
            n.setText(props);
            n.markLayoutDirty();
        }
    }.hook;
}

/// textStyled - 主题安全的 text：样式来自 `fn (*const ThemeTokens) TextStyle` 纯函数
pub fn textStyled(cx: anytype, comptime style_fn: fn (*const theme.ThemeTokens) TextStyle, content: []const u8) !*Node {
    const node = try textWithOrigin(cx, content, style_fn(cx.tokens), @intFromPtr(&style_fn), .styled);
    node.meta.per_frame.hooks.on_theme = textThemeHookFor(style_fn);
    return node;
}

/// hstack - 水平布局 (direction = .row)
pub fn hstack(cx: anytype, style: BoxStyle, children_tuple: anytype) !*Node {
    var s = style;
    s.direction = .row;
    return boxWithOrigin(cx, s, children_tuple, @returnAddress(), .inline_builder);
}

/// vstack - 垂直布局 (direction = .column)
pub fn vstack(cx: anytype, style: BoxStyle, children_tuple: anytype) !*Node {
    var s = style;
    s.direction = .column;
    return boxWithOrigin(cx, s, children_tuple, @returnAddress(), .inline_builder);
}

/// text 节点的样式参数（具名类型，供 textStyled 的样式函数复用）
pub const TextStyle = struct {
    color: Color = theme.dark.color.fg_primary,
    font_size: f32 = 14,
    font_weight: u16 = 400,
    /// 字体族 id(zenit_app.FontRegistry)。0 = 默认族。
    font_family: u16 = 0,
    line_height: f32 = 1.4,
    wrap: types.TextWrap = .none,
    max_lines: u16 = 0,
    /// 逐视觉行水平对齐（见 TextProps.text_align）
    text_align: types.TextAlign = .start,
};

/// text - 文本节点
fn textStyleFieldMask() u64 {
    return (@as(u64, 1) << @intFromEnum(types.StyleField.text_color)) |
        (@as(u64, 1) << @intFromEnum(types.StyleField.text_font_size)) |
        (@as(u64, 1) << @intFromEnum(types.StyleField.text_font_weight));
}

fn textWithOrigin(
    cx: anytype,
    content: []const u8,
    props: TextStyle,
    origin_address: usize,
    origin_kind: @import("world.zig").StyleOriginKind,
) !*Node {
    const node = try createNode(cx, .text, .{
        .width = if (props.wrap != .none) .{ .grow = .{} } else .{ .fit = .{} },
        .height = .{ .fit = .{} },
    });
    errdefer cx.freeNode(node);
    // Content lifetime contract: builder 内部 take ownership 避免 caller 误用
    // frame_arena dupe (下一帧 reset → content 悬垂)。
    // - ≤16 bytes: 走 inline_buf，零额外 alloc
    // - >16 bytes: cx.allocator.dupe，并设 owned=true 让 Node.destroy 释放
    var t = types.TextProps{
        .color = props.color,
        .font_size = props.font_size,
        .font_weight = props.font_weight,
        .font_family = props.font_family,
        .line_height = props.line_height,
        .wrap = props.wrap,
        .max_lines = props.max_lines,
        .text_align = props.text_align,
    };
    try t.setContent(cx.allocator, content);
    // linkNodeToWorld 先于 setText，确保 mirror 写入有 element_id。
    cx.linkNodeToWorld(node);
    node.setText(t);
    node.recordStyleBaseOrigin(textStyleFieldMask(), origin_address, origin_kind);
    return node;
}

pub fn text(cx: anytype, content: []const u8, props: TextStyle) !*Node {
    return textWithOrigin(cx, content, props, @returnAddress(), .inline_builder);
}

/// image - 图片节点（纹理 ID）
pub fn image(cx: anytype, texture_id: u32, style: Style) !*Node {
    const node = try createNode(cx, .image, style);
    cx.linkNodeToWorld(node);
    node.setImage(.{ .texture_id = texture_id, .tint = Color.WHITE });
    try applyRegisteredImageHitGeometry(cx, node, texture_id);
    return node;
}

pub fn imageSvgHit(cx: anytype, texture_id: u32, style: Style, svg_data: []const u8) !*Node {
    const node = try image(cx, texture_id, style);
    try node.setSvgDocumentHitGeometry(cx.allocator, svg_data, .nonzero);
    (try node.style.ensureExtFallible(cx.allocator)).hit_shape = .{ .path = .{ .fill_rule = .nonzero } };
    return node;
}

/// imageTint - 图片节点（纹理 ID + tint）
pub fn imageTint(cx: anytype, texture_id: u32, tint: Color, style: Style) !*Node {
    const node = try createNode(cx, .image, style);
    errdefer cx.freeNode(node);
    cx.linkNodeToWorld(node);
    node.setImage(.{ .texture_id = texture_id, .tint = tint });
    try applyRegisteredImageHitGeometry(cx, node, texture_id);
    return node;
}

pub fn imageTintSvgHit(cx: anytype, texture_id: u32, tint: Color, style: Style, svg_data: []const u8) !*Node {
    const node = try imageTint(cx, texture_id, tint, style);
    errdefer cx.freeNode(node);
    const ext = try node.style.ensureExtFallible(cx.allocator);
    try node.setSvgDocumentHitGeometry(cx.allocator, svg_data, .nonzero);
    ext.hit_shape = .{ .path = .{ .fill_rule = .nonzero } };
    return node;
}

pub fn icon(cx: anytype, asset: svg_assets_mod.Asset, style: Style) !*Node {
    return iconTint(cx, asset, Color.WHITE, style);
}

pub fn iconTint(cx: anytype, asset: svg_assets_mod.Asset, tint: Color, style: Style) !*Node {
    const logical_size = svg_geometry.resolveIconLogicalSize(asset, style);
    const rep = asset.pickRep(logical_size) orelse return svgTint(cx, asset.svg_data, tint, style);
    const icon_id = asset.icon_id orelse return svgTint(cx, asset.svg_data, tint, style);

    const node = try createNode(cx, .image, style);
    errdefer cx.freeNode(node);
    cx.linkNodeToWorld(node);
    node.setIcon(.{
        .icon_id = icon_id,
        .rep = rep,
        .tint = tint,
    });
    try applyIconHitGeometry(cx, node, rep);
    return node;
}

/// BoxStyle variant of iconTint. Unlike the legacy Style entry point this can
/// apply SoA paint fields such as opacity at construction time.
pub fn iconTintStyled(cx: anytype, asset: svg_assets_mod.Asset, tint: Color, style: BoxStyle) !*Node {
    const node = try iconTint(cx, asset, tint, style.toStyle(cx.allocator));
    applyPaintOverride(node, style.paintOverride());
    return node;
}

pub fn iconStyled(cx: anytype, asset: svg_assets_mod.Asset, style: BoxStyle) !*Node {
    return iconTintStyled(cx, asset, Color.WHITE, style);
}

pub fn svg(cx: anytype, svg_data: []const u8, style: Style) !*Node {
    const raster_size = svg_geometry.resolveSvgRasterSize(cx.window_scale, svg_data, style);
    const texture_id = try cx.svg_textures.load(svg_data, raster_size[0], raster_size[1]);
    return imageSvgHit(cx, texture_id, style, svg_data);
}

pub fn svgTint(cx: anytype, svg_data: []const u8, tint: Color, style: Style) !*Node {
    const raster_size = svg_geometry.resolveSvgRasterSize(cx.window_scale, svg_data, style);
    const texture_id = try cx.svg_textures.load(svg_data, raster_size[0], raster_size[1]);
    return imageTintSvgHit(cx, texture_id, tint, style, svg_data);
}

fn applyRegisteredImageHitGeometry(cx: anytype, node: *Node, texture_id: u32) !void {
    const geometry = cx.svg_textures.lookupHit(texture_id) orelse return;
    const ext = try node.style.ensureExtFallible(cx.allocator);
    try node.setClonedPathGeometry(cx.allocator, geometry);
    ext.hit_shape = .{ .path = .{ .fill_rule = geometry.fill_rule } };
}

fn applyIconHitGeometry(cx: anytype, node: *Node, rep: icon_ir.Rep) !void {
    const ext = try node.style.ensureExtFallible(cx.allocator);
    var geometry = try svg_geometry.createIconPathGeometry(cx.allocator, rep);
    errdefer node_mod.freePathGeometry(cx.allocator, &geometry);
    const fill_rule = geometry.fill_rule;
    try node.setClonedPathGeometry(cx.allocator, geometry);
    node_mod.freePathGeometry(cx.allocator, &geometry);
    ext.hit_shape = .{ .path = .{ .fill_rule = switch (fill_rule) {
        .nonzero => .nonzero,
        .evenodd => .evenodd,
    } } };
}

/// spacer - 弹性空白 (填充可用空间)
pub fn spacer(cx: anytype) !*Node {
    return createNode(cx, .spacer, .{
        .width = .{ .grow = .{} },
        .height = .{ .grow = .{} },
    });
}

/// Grid 容器样式配置
pub const GridStyle = struct {
    columns: []const GridTrackSize = &.{},
    rows: []const GridTrackSize = &.{},
    column_gap: f32 = 0,
    row_gap: f32 = 0,

    // 常用 Style 字段透传
    background: Color = Color.TRANSPARENT,
    padding: Padding = Padding.ZERO,
    width: Sizing = .{ .grow = .{} },
    height: Sizing = .{ .grow = .{} },
    justify: JustifyContent = .start,
    align_items: AlignItems = .stretch,
    overflow_hidden: bool = false,
    border: Border = .{},
    corner_radius: ?types.CornerRadius = null,
    margin: Padding = Padding.ZERO,
    /// 完整 margin 声明（支持 auto）。若设置，则覆盖 margin。
    margin_spec: ?types.Margin = null,
};

/// grid - Grid 容器（CSS Grid 布局）
pub fn grid(cx: anytype, config: GridStyle, children_tuple: anytype) !*Node {
    var style = Style{
        .padding = config.padding,
        .width = config.width,
        .height = config.height,
        .justify = config.justify,
        .align_items = config.align_items,
        .overflow_hidden = config.overflow_hidden,
        .border = config.border,
        .margin = config.margin,
    };
    if (config.margin_spec) |v| {
        style.setMarginSpec(cx.allocator, v);
    }
    if (config.corner_radius) |cr| {
        (try style.ensureExtFallible(cx.allocator)).corner_radius = cr;
    }

    const gc = try cx.allocator.create(GridConfig);
    gc.* = .{
        .column_gap = config.column_gap,
        .row_gap = config.row_gap,
    };

    const ncols: u8 = @intCast(@min(config.columns.len, GridConfig.MAX_TRACKS));
    for (0..ncols) |i| {
        gc.columns[i] = config.columns[i];
    }
    gc.column_count = ncols;

    const nrows: u8 = @intCast(@min(config.rows.len, GridConfig.MAX_TRACKS));
    for (0..nrows) |i| {
        gc.rows[i] = config.rows[i];
    }
    gc.row_count = nrows;

    (try style.ensureExtFallible(cx.allocator)).grid = gc;

    const node = try createNode(cx, .box, style);
    cx.linkNodeToWorld(node);
    if (config.background.a != 0) node.setBackgroundRaw(config.background);
    try appendChildrenFromTuple(cx, node, children_tuple);
    return node;
}

/// clickable - 给任意节点添加点击事件
pub fn clickable(node: *Node, on_click: HandlerRef) *Node {
    node.behavior.events.on_click = on_click;
    return node;
}

/// 将 comptime children tuple 展开为 Node 子节点。
///
/// tuple 中的元素可以是:
///   - *Node: 直接添加
///   - 实现了 render(*Cx) !*Node 的 struct: 调用 render()
///   - ?*Node: 可选节点 (null 跳过)
pub fn appendChildrenFromTuple(cx: anytype, parent: *Node, children_tuple: anytype) !void {
    const T = @TypeOf(children_tuple);
    const info = @typeInfo(T);
    const fields = info.@"struct".fields;

    inline for (fields) |field| {
        const child = @field(children_tuple, field.name);
        try appendSingleChild(cx, parent, child);
    }
}

fn appendSingleChild(cx: anytype, parent: *Node, child: anytype) !void {
    const T = @TypeOf(child);

    // null literal - skip (conditional rendering)
    if (T == @TypeOf(null)) {
        return;
    }

    // *Node - 直接添加
    if (T == *Node) {
        try parent.appendChild(cx.allocator, child);
        return;
    }

    // ?*Node - 条件渲染
    if (T == ?*Node) {
        if (child) |c| {
            try parent.appendChild(cx.allocator, c);
        }
        return;
    }

    // Component protocol: struct with render(self, *Cx) !*Node
    if (@typeInfo(T) == .@"struct") {
        if (@hasDecl(T, "render")) {
            const node = try child.render(cx);
            try parent.appendChild(cx.allocator, node);
            return;
        }
    }

    @compileError("Unsupported child type: " ++ @typeName(T) ++
        ". Expected *Node, ?*Node, null, or a struct with pub fn render(self, *Cx) !*Node");
}

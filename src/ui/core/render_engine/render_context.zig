/// RenderContext — render engine 的显式上下文，替代 cx: anytype 上帝对象
///
/// 所有 mod.zig / node_style_render.zig / text_render.zig 的渲染函数
/// 统一使用 *RenderContext 代替 anytype，实现编译期类型检查与子模块独立可测试。
const std = @import("std");
const display_list_mod = @import("../display_list.zig");
const text_blob_mod = @import("../text_blob.zig");
const scene_runtime_mod = @import("../scene_runtime.zig");
const property_tree_mod = @import("../property_tree.zig");
const layer_tree_mod = @import("../layer_tree.zig");
const hit_runtime_mod = @import("../hit_runtime.zig");
const world_mod = @import("../world.zig");
const types = @import("../types.zig");
const shaping_cache_mod = @import("../shaping_cache.zig");
const paint_table_mod = @import("../paint_table.zig");
const text_module = @import("text");
const text_coordinates = @import("text_core").text_coordinates;

pub const RenderContext = struct {
    /// Optional snapshot sink: capture the same lowered commands sent to the encoder.
    capture_lowered: ?*std.ArrayList(display_list_mod.DisplayItem) = null,
    /// Lowering 输出 buffer (DisplayItem world-space 切片)。lowering 路径写入此处，
    /// encoder 通过 cx.lowerForEncoder() 拿到切片。
    lowering_buffer: *std.ArrayList(display_list_mod.DisplayItem),
    /// paint_table.DisplayItem 视角的镜像 buffer。
    /// 与 lowering_buffer 索引 1:1 同步，encoder 主路径 (lowerForEncoderPaintTable)
    /// 直接返这里的 items。
    lowering_buffer_paint: *std.ArrayList(paint_table_mod.DisplayItem),
    display_list: *display_list_mod.DisplayList,
    text_blob_store: *text_blob_mod.BlobStore,
    scene_runtime: *scene_runtime_mod.SceneRuntime,
    property_tree: *property_tree_mod.PropertyTree,
    layer_tree: *layer_tree_mod.LayerTree,
    /// World 引入 RenderContext，render path 可读 LayoutTable / PaintTable。
    /// 当前仍 shadow-mode：node.rect 与 world.layout 由 syncLayoutToTable 保持一致。
    world: *world_mod.World,
    allocator: std.mem.Allocator,
    frame_allocator: std.mem.Allocator,
    viewport: types.Size,
    perf: *hit_runtime_mod.PerfCounters,
    /// GlyphRun pipeline — render engine 通过 ShapingCache 走 GlyphRun
    /// 替代 measureTextWidthByFontKind 直调 platform 桥。null 时 caller fallback
    /// 到旧 text_layout 路径。
    /// Paint-order 前缀不变式（display_list raw 顺序 == paint 顺序的全局保证）：
    /// prebuild 两个 pass 按 paint 顺序走，一旦遇到**必须留给 paint pass fresh
    /// emit** 的内容（transform 子树、overlay hook 重定位、own 不可表示……），
    /// 此后 paint 顺序里的任何内容都不得再 prebuild —— 否则后画的内容先落
    /// display_list，fresh 内容追加在表尾，出现"旋转的 ◇ 浮在 z=30500 浮层
    /// 之上"一类穿透。prebuild 内容永远是 paint 顺序的一个**前缀**。
    /// 每帧 beginRetainedFrame 复位。
    display_payload_prefix_broken: bool = false,
    /// Nodes whose subtree-payload cache crosses a disable_render_cache
    /// boundary, either as an ancestor or a descendant. Built once per
    /// prebuild pass so cache eligibility stays O(1) per node.
    render_cache_boundary_blocked: ?*const std.AutoHashMapUnmanaged(u32, void) = null,
    /// Node 外部裁剪矩形旁表（node.id → 视口系 rect；见 Cx.external_clip_rects）。
    /// null = 宿主未启用该能力（DevTools 等旁路构造点无需关心）。
    external_clip_rects: ?*const std.AutoHashMapUnmanaged(u32, [4]f32) = null,
    shaping_cache: ?*shaping_cache_mod.ShapingCache = null,
    font_system: ?*text_module.FontSystem = null,
    visual_line_context: ?*anyopaque = null,
    visual_line_fn: ?*const fn (*anyopaque, []const u8, f32, u16, bool) ?text_coordinates.VisualLine = null,

    pub fn visualLine(self: *RenderContext, text: []const u8, font_size: f32, font_weight: u16, italic: bool) ?text_coordinates.VisualLine {
        const callback = self.visual_line_fn orelse return null;
        return callback(self.visual_line_context orelse return null, text, font_size, font_weight, italic);
    }

    /// Stage 4-2 helper: 从 World.LayoutTable 读 element 的 rect，节点未挂 World 时
    /// 回退到 standalone fallback (node.rectFromWorldOrFallback)。
    /// v0.5-P3 N-2 (2026-05-03): frame_state.rect 字段已删，所有 fallback 走
    /// node.zig 的 g_standalone_rects hashmap。
    pub fn rectFromWorld(self: *const RenderContext, node: anytype) types.ComputedRect {
        if (node.element_id_raw == 0xFFFFFFFF) {
            return node.rectFromWorldOrFallback();
        }
        const eid = world_mod.ElementId.fromRaw(node.element_id_raw);
        if (self.world.layout.rect(eid)) |r| {
            return types.ComputedRect.init(r.x, r.y, r.width, r.height);
        }
        return node.rectFromWorldOrFallback();
    }
};

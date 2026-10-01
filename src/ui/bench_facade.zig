//! v0.2 bench facade，把 bench 需要的所有 zenit 内部类型从一个 module 导出。
//!
//! 必须放在 src/ui/ 内部（zig 0.15 module strict path：facade module 不能
//! 跨上级目录 import）。bench main 通过此 facade module 访问 element_table /
//! paint_table 等，避免 element_id.zig 被多个 module 重复 import 冲突。
//!
//! 加 frame-level scenario bench 支持，re-export Cx + ui builders。
//! 要求 build.zig 给 zenit_facade_bench_module 注入 system_sdk/icon_ir/
//! text_core/trace/platform 等 sub-import（与 ui_module 同构）。

pub const element_id = @import("core/element_id.zig");
pub const ElementId = element_id.ElementId;
pub const SlotMap = element_id.SlotMap;

pub const element_table_mod = @import("core/element_table.zig");
pub const ElementTable = element_table_mod.ElementTable;
pub const Element = element_table_mod.Element;
pub const ElementTag = element_table_mod.ElementTag;

pub const paint_table_mod = @import("core/paint_table.zig");
pub const PaintTable = paint_table_mod.PaintTable;
pub const PaintChunk = paint_table_mod.PaintChunk;
pub const DisplayItem = paint_table_mod.DisplayItem;
pub const Bounds = paint_table_mod.Bounds;
pub const PropertyStateRef = paint_table_mod.PropertyStateRef;

pub const layout_constraint = @import("core/layout/constraint.zig");
pub const IntrinsicCache = layout_constraint.IntrinsicCache;
pub const LayoutInput = layout_constraint.LayoutInput;
pub const LayoutOutput = layout_constraint.LayoutOutput;
pub const AvailableSpaceXY = layout_constraint.AvailableSpaceXY;
pub const hashLayoutInput = layout_constraint.hashLayoutInput;

pub const layout_table_mod = @import("core/layout_table.zig");
pub const LayoutTable = layout_table_mod.LayoutTable;
pub const LayoutData = layout_table_mod.LayoutData;
pub const Size2D = layout_constraint.Size2D;

// PropertyTree（Scroll 部分），注意 property_tree.zig 链 types.zig 链
// animation/easing 跨目录 import，bench facade 无法访问完整版；只暴露 ScrollNode
// 类型本身（无依赖的 enum/struct）。bench 测 nodes 是逻辑表达式不需要真 PropertyTree。
pub const PropertyScrollNode = struct {
    parent: u32 = 0xFFFFFFFF,
    transform_id: u32 = 0xFFFFFFFF,
    node_id: u32 = 0,
    scroll_offset_x: f32 = 0,
    scroll_offset_y: f32 = 0,
    content_w: f32 = 0,
    content_h: f32 = 0,
    viewport_w: f32 = 0,
    viewport_h: f32 = 0,
    is_scrolling: bool = false,
};

// v0.2-P4 注：layer_tree.zig 链 property_tree -> types -> animation/easing 等
// 跨目录 import，bench module strict path 不可达。layer_tree 真 bench 等 v0.3
// 主路径切换时通过 ui module 测。当前 bench 只能测**纯 enum/packed struct** 部分。

pub const gpu_draw_mod = @import("core/gpu_draw.zig");
pub const GpuDraw = gpu_draw_mod.GpuDraw;
pub const BlendMode = gpu_draw_mod.BlendMode;
pub const BufferRange = gpu_draw_mod.BufferRange;

pub const glyph_run_mod = @import("core/glyph_run.zig");
pub const GlyphRun = glyph_run_mod.GlyphRun;
pub const GlyphPosition = glyph_run_mod.GlyphPosition;
pub const Cluster = glyph_run_mod.Cluster;
pub const FontMetrics = glyph_run_mod.FontMetrics;

pub const shaping_cache_mod = @import("core/shaping_cache.zig");
pub const ShapingCache = shaping_cache_mod.ShapingCache;
pub const ShapingKey = shaping_cache_mod.ShapingKey;

pub const a11y_tree_mod_facade = @import("a11y/tree.zig");
pub const AccessibilityTree = a11y_tree_mod_facade.AccessibilityTree;
pub const A11yNode = a11y_tree_mod_facade.A11yNode;
pub const A11yDirtyFlag = a11y_tree_mod_facade.A11yDirtyFlag;
pub const A11yRole = a11y_tree_mod_facade.Role;

pub const gesture_mod = @import("input/gesture_recognizer.zig");
pub const GestureArena = gesture_mod.GestureArena;
pub const GestureKind = gesture_mod.GestureKind;
pub const GestureState = gesture_mod.GestureState;
pub const Recognizer = gesture_mod.Recognizer;

pub const controlled_mod = @import("components/controlled.zig");
pub const ControlledProp = controlled_mod.ControlledProp;

pub const select_headless_mod = @import("components/select_headless/state_machine.zig");

// v0.8 §2.2 frame_select_1k_keyboard_pagedown 需要完整 mount 路径 (Popover +
// VirtualList + Scope) 来跑真 frame-level bench
pub const select_headless_mount = @import("components/select_headless/mod.zig");
pub const Scope = @import("reactive.zig").Scope;

// re-export Cx + ui builders so bench
// main 可以构 real frame (build -> layout -> render -> encode)。
// 需要 build.zig 给 zenit_facade_bench_module 注入 system_sdk/icon_ir/
// text_core/trace/platform sub-imports（参见 ui_module 的依赖列表）。
pub const ui_core = @import("core.zig");
pub const Cx = ui_core.Cx;
pub const Node = ui_core.Node;
pub const Color = ui_core.Color;
pub const Padding = ui_core.Padding;
pub const Direction = ui_core.Direction;
pub const Style = ui_core.Style;
pub const box = ui_core.box;
pub const text = ui_core.text;
pub const hstack = ui_core.hstack;
pub const vstack = ui_core.vstack;
pub const spacer = ui_core.spacer;

pub const display_item_encode = @import("core/display_item_encode.zig");
pub const encodeOne = display_item_encode.encodeOne;
pub const encodeStream = display_item_encode.encodeStream;
pub const maxBatchableRun = display_item_encode.maxBatchableRun;
pub const pipelineForKind = display_item_encode.pipelineForKind;

// 把 PromotionHint 复制一份到 facade（不依赖 layer_tree.zig）
// 注意：与 layer_tree.zig::PromotionHint 字段结构必须保持同步
pub const PromotionReasonForBench = enum(u8) {
    root,
    transform_animating,
    opacity_animating,
    scroll,
    will_change,
    filter,
    mask,
    blend_mode,
    transform_3d,
};

pub const PromotionHintForBench = packed struct(u8) {
    transform_animating: bool = false,
    opacity_animating: bool = false,
    is_scroll_container: bool = false,
    will_change: bool = false,
    has_filter: bool = false,
    has_3d_transform: bool = false,
    _reserved: u2 = 0,

    pub fn shouldPromote(self: @This()) bool {
        return self.transform_animating or
            self.opacity_animating or
            self.is_scroll_container or
            self.will_change;
    }

    pub fn primaryReason(self: @This()) PromotionReasonForBench {
        if (self.transform_animating) return .transform_animating;
        if (self.opacity_animating) return .opacity_animating;
        if (self.is_scroll_container) return .scroll;
        if (self.will_change) return .will_change;
        if (self.has_filter) return .filter;
        if (self.has_3d_transform) return .transform_3d;
        return .root;
    }
};

/// UI Core - 声明式 UI 框架核心 (v2)
///
/// Gooey 风格重构: 内联 children + 统一 Cx 上下文
///
/// 设计理念 (学习自 Gooey):
/// 1. 内联声明式: ui.box(.{}, .{ child1, child2 }) 代替手动 appendChild
/// 2. 统一 Cx: 合并 UIContext/EventDispatcher/FocusManager/StateStore
/// 3. 组件协议: struct + render() 方法, 组件可直接内嵌为 children
/// 4. 类型安全 handler: 先显式创建状态，再用 cx.handler(State, id, method) 绑定
///
/// 用法示例:
/// ```
/// fn render(cx: *Cx) !void {
///     const state_id: u64 = 1;
///     const s = try cx.state(AppState, state_id, .{});
///     cx.root = try ui.box(cx, .{
///         .width = .{ .px = 800 },
///         .height = .{ .px = 600 },
///         .direction = .column,
///         .gap = 16,
///         .padding = Padding.all(20),
///     }, .{
///         ui.text("Hello", .{}),
///         Button{ .label = "Click", .on_click = try cx.handler(AppState, state_id, AppState.increment) },
///         ui.hstack(cx, .{ .gap = 8 }, .{
///             ui.text("Left", .{}),
///             ui.spacer(),
///             ui.text("Right", .{}),
///         }),
///     });
/// }
/// ```
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const system_sdk_mod = @import("system_sdk");
const svg_assets_mod = @import("svg_assets.zig");
pub const svg_assets = svg_assets_mod;

// 导入子系统
const reactive = @import("reactive.zig");
pub const SignalOwner = reactive.SignalOwner;
pub const Signal = reactive.Signal;
pub const createEffect = reactive.createEffect;
pub const Memo = reactive.Memo;
pub const createMemo = reactive.createMemo;
pub const Scope = reactive.Scope;
const deferred_scheduler_mod = @import("deferred_scheduler.zig");
const DeferredScheduler = deferred_scheduler_mod.DeferredScheduler;
pub const work = @import("work.zig");
pub const WorkPriority = work.WorkPriority;
pub const WorkKey = work.WorkKey;
pub const WorkSpec = work.WorkSpec;
pub const WorkStep = work.WorkStep;
pub const WorkResult = work.WorkResult;
pub const WorkHandle = work.WorkHandle;
pub const Task = deferred_scheduler_mod.Task;
pub const TaskPriority = deferred_scheduler_mod.TaskPriority;
pub const DrainDeferredResult = deferred_scheduler_mod.DrainResult;

const events_mod = @import("events.zig");
pub const Event = events_mod.Event;
pub const overlay_stack_mod = @import("overlay_stack.zig");
const hooks_mod = @import("hooks.zig");
pub const OverlayStack = overlay_stack_mod.OverlayStack;
pub const EventResult = events_mod.EventResult;
pub const KeyCode = events_mod.KeyCode;
pub const Modifiers = events_mod.Modifiers;
pub const MouseButton = events_mod.MouseButton;

const event_dispatcher_mod = @import("event_dispatcher.zig");
const interaction_drag = @import("interaction/drag.zig");
const focus_mod = @import("focus.zig");
const widget_state_mod = @import("widget_state.zig");
const actions_mod = @import("actions.zig");
const console_mod = @import("console.zig");
pub const theme = @import("theme.zig");
pub const recipe = @import("recipe.zig");
pub const animation = @import("animation/mod.zig");
pub const ConditionalStyle = recipe.ConditionalStyle;
pub const SystemSdk = system_sdk_mod.SystemSdk;
pub const animateNode = animation.animateNode;
pub const AnimatableProp = animation.AnimatableProp;
pub const Easing = animation.Easing;

const core_types = @import("core/types.zig");
const core_node = @import("core/node.zig");
const paint_content_accessor = @import("core/paint_content_accessor.zig");
const virtual_cursor_mod = @import("core/virtual_cursor.zig");
const custom_cursor_mod = @import("core/custom_cursor.zig");
const text_input_session_mod = @import("core/text_input_session.zig");
const bulk_quad_layer_mod = @import("core/bulk_quad_layer.zig");
const frame_perf_mod = @import("core/frame_perf.zig");
const svg_texture_store = @import("core/svg_texture_store.zig");
const text_shaping = @import("core/text_shaping.zig");
const text_context = @import("core/text_context.zig");
pub const cursor = @import("core/cursor.zig");
pub const CursorRegion = cursor.Region;
pub const CursorToken = cursor.Token;

// Phase 0: ElementId 生成式 handle —— Phase 3 拆 Node 后的核心索引
pub const element_id = @import("core/element_id.zig");
pub const ElementId = element_id.ElementId;
pub const SlotMap = element_id.SlotMap;

// Phase 3: 4 张表 + World 容器（取代 Node god-object 的新 source of truth）
pub const element_table = @import("core/element_table.zig");
pub const ElementTable = element_table.ElementTable;
pub const layout_table = @import("core/layout_table.zig");
pub const LayoutTable = layout_table.LayoutTable;
pub const paint_table = @import("core/paint_table.zig");
pub const PaintTable = paint_table.PaintTable;
pub const PaintChunk = paint_table.PaintChunk;
pub const PropertyStateRef = paint_table.PropertyStateRef;
pub const interaction_table = @import("core/interaction_table.zig");
pub const InteractionTable = interaction_table.InteractionTable;
pub const world = @import("core/world.zig");
pub const World = world.World;

// Phase 5: GpuDraw IR + DisplayItem encoder（v0.3 渲染主路径切到此）
pub const gpu_draw = @import("core/gpu_draw.zig");
pub const GpuDraw = gpu_draw.GpuDraw;
pub const display_item_encode = @import("core/display_item_encode.zig");

// Phase 6: GlyphRun + ShapingCache（cluster-aware text layout 基础）
pub const glyph_run = @import("core/glyph_run.zig");
pub const GlyphRun = glyph_run.GlyphRun;
pub const FontMetrics = glyph_run.FontMetrics;
pub const TextDirection = glyph_run.Direction;
pub const shaping_cache = @import("core/shaping_cache.zig");
pub const ShapingCache = shaping_cache.ShapingCache;
pub const ShapingKey = shaping_cache.ShapingKey;

// GlyphRun pipeline 接管旧 ASCII-first measure 路径起步 —
// cx.shapeText 调 TextShaper.shape() 构 GlyphRun，过 ShapingCache 缓存。
const text_module = @import("text");
pub const TextShaper = text_module.TextShaper;
pub const Font = text_module.Font;
pub const FontSystem = text_module.FontSystem;
pub const ShapedGlyph = text_module.ShapedGlyph;
pub const FontDescriptor = text_module.FontDescriptor;

fn releaseShapedFallbackFontRefs(glyphs: []const ShapedGlyph) void {
    for (glyphs) |glyph| {
        if (glyph.fallback_font_ref) |font_ref| {
            text_module.releaseFallbackFontRef(font_ref);
        }
    }
}

// Phase 4: 真合成层（取代每帧重建的 CompositorPlan）
pub const layer_tree = @import("core/layer_tree.zig");
pub const LayerTree = layer_tree.LayerTree;
pub const LayerId = layer_tree.LayerId;
pub const Layer = layer_tree.Layer;
pub const PromotionReason = layer_tree.PromotionReason;
pub const layerize_mod = @import("core/layerize.zig");
pub const PromotionHint = layerize_mod.PromotionHint;
pub const layerize = layerize_mod.layerize;

// Phase 0: DirtyFlags —— 替代 Node 上分散的 13 布尔 + 2 version。Phase 3 接入。
pub const dirty_flags = @import("core/dirty_flags.zig");
pub const DirtyFlags = dirty_flags.DirtyFlags;

// Phase 2: Layout constraint passing model（Taffy 风格）。Phase 3 layout_engine 切换主路径。
pub const layout_constraint = @import("core/layout/constraint.zig");
pub const LayoutInput = layout_constraint.LayoutInput;
pub const LayoutOutput = layout_constraint.LayoutOutput;
pub const AvailableSpace = layout_constraint.AvailableSpace;
pub const AvailableSpaceXY = layout_constraint.AvailableSpaceXY;
const snapshot_mod = @import("core/snapshot.zig");
const hit_runtime_mod = @import("core/hit_runtime.zig");
pub const interaction_semantics = @import("core/interaction_semantics.zig");
// redraw.zig 全局变量仅被 node.markRenderDirty 设置，Cx.render 不再依赖它
// （HMR 跨 dylib 时 Plugin/Host 各有一份全局变量，不可靠）
pub const layout_engine = @import("core/layout_engine.zig");

pub const render_engine = @import("core/render_engine/mod.zig");
const inspector_mod = @import("core/inspector.zig");
const scene_runtime_mod = @import("core/scene_runtime.zig");
const property_tree_mod = @import("core/property_tree.zig");
const display_list_mod = @import("core/display_list.zig");
const text_blob_mod = @import("core/text_blob.zig");

// gesture + a11y 模块（在 src/ui/ 平级，不在 core/ 子目录）
const gesture_input = @import("input/gesture_recognizer.zig");
pub const gesture = gesture_input;
const a11y_tree_mod = @import("a11y/tree.zig");
const a11y_macos_bridge_mod = @import("a11y/macos_bridge.zig");
const a11y_router_mod = @import("a11y/nsaccessibility_router.zig");
/// a11y_tree 子模块对外（tests / platform bridges 等）re-export。
pub const a11y_tree = a11y_tree_mod;
pub const a11y_macos_bridge = a11y_macos_bridge_mod;
pub const a11y_router = a11y_router_mod;
pub const display_list = display_list_mod;
pub const text_blob = text_blob_mod;
pub const debug_trace = inspector_mod.debug_trace;
pub const text_layout = @import("core/text_layout.zig");

// ========== 基础类型 ==========
pub const Size = core_types.Size;
pub const ComputedRect = core_types.ComputedRect;
pub const Point = core_types.Point;
pub const Padding = core_types.Padding;
pub const Margin = core_types.Margin;

// ========== Sizing 模型 (学习自 Gooey) ==========
pub const Sizing = core_types.Sizing;
pub const Direction = core_types.Direction;
pub const JustifyContent = core_types.JustifyContent;
pub const AlignItems = core_types.AlignItems;
pub const FlexWrap = core_types.FlexWrap;
pub const ScrollDirectionHint = core_types.ScrollDirectionHint;

// 类型别名
pub const Justify = core_types.Justify;
pub const Alignment = core_types.Alignment;

// ========== 颜色与主题 ==========
pub const Color = core_types.Color;
pub const ThemeTokens = core_types.ThemeTokens;
pub const GradientDirection = core_types.GradientDirection;
pub const Border = core_types.Border;
pub const Shadow = core_types.Shadow;
pub const Gradient = core_types.Gradient;
pub const GradientStop = core_types.GradientStop;
pub const MultiGradient = core_types.MultiGradient;
pub const NoiseParams = core_types.NoiseParams;
pub const NoiseMode = core_types.NoiseMode;
pub const InsetShadow = core_types.InsetShadow;
pub const CornerRadius = core_types.CornerRadius;
pub const GlassSurface = core_types.GlassSurface;
pub const GlassParams = core_types.GlassParams;
pub const BlurGradient = core_types.BlurGradient;
pub const ResolvedGlassParams = core_types.ResolvedGlassParams;
pub const Position = core_types.Position;
pub const Display = core_types.Display;
pub const EffectKind = property_tree_mod.EffectKind;
pub const BlendMode = core_types.BlendMode;
pub const SceneRuntimeInvalidId = scene_runtime_mod.INVALID_ID;
pub const DisplayPayloadSubtreeStrategy = scene_runtime_mod.DisplayPayloadSubtreeStrategy;
pub const displayPayloadSubtreeStrategyUsesSelfEffectSpace = scene_runtime_mod.displayPayloadSubtreeStrategyUsesSelfEffectSpace;
pub const ClipShapeKind = display_list_mod.ClipShapeKind;

// ========== 样式 (Layout Config) ==========
pub const Style = core_types.Style;
pub const BoxStyle = core_types.BoxStyle;
pub const StyleOverride = core_types.StyleOverride;
pub const InteractionState = core_types.InteractionState;
pub const Outline = core_types.Outline;
pub const CursorShape = core_types.CursorShape;

/// 自定义位图光标描述（`Cx.setCustomCursor` 的输入）。
/// 纵横比由 SVG 自身保持，`size_pt` 只约束逻辑宽度（输出宽度 = size_pt，
/// viewBox 会等比缩放到它）；
/// `hot_x/hot_y` 是**最终位图**内左上原点的热点逻辑坐标（points）——
/// 若 size_pt ≠ viewBox 宽度，调用方要自行按比例换算（常用
/// size_pt == viewBox 宽度，此时两者一致）。
pub const CustomCursorDesc = custom_cursor_mod.CustomCursorDesc;

pub const CustomCursorEntry = custom_cursor_mod.CustomCursorEntry;

// ========== Recipe 样式配方系统 ==========
pub const transition = recipe.transition;
pub const TransitionEntry = recipe.TransitionEntry;

// ========== Grid Layout ==========
pub const GridTrackSize = core_types.GridTrackSize;
pub const GridConfig = core_types.GridConfig;
pub const GridPlacement = core_types.GridPlacement;

// ========== 无障碍 (Accessibility) ==========
pub const A11yRole = core_types.A11yRole;
pub const A11yProps = core_types.A11yProps;
pub const A11yOrientation = core_types.A11yOrientation;
pub const A11ySortDirection = core_types.A11ySortDirection;
pub const A11yRect = core_types.A11yRect;
pub const A11yValueRange = core_types.A11yValueRange;
pub const TextInputClient = core_types.TextInputClient;
pub const TextInputSelection = core_types.TextInputSelection;

// ========== 元素类型标签 ==========
pub const ElementTag = core_types.ElementTag;
pub const TextProps = core_types.TextProps;
pub const TextWrap = core_types.TextWrap;
pub const TextAlign = core_types.TextAlign;
pub const TextSpan = core_types.TextSpan;
pub const UnderlineStyle = core_types.UnderlineStyle;
pub const ImageProps = core_types.ImageProps;
pub const IconProps = core_types.IconProps;

// ========== Handler 系统 (类型安全) ==========
pub const HandlerRef = core_types.HandlerRef;
pub const GenericEventCallback = core_types.GenericEventCallback;
pub const EventCallback = core_types.EventCallback;
pub const KeyEventCallback = core_types.KeyEventCallback;
pub const EventHandlers = core_types.EventHandlers;
pub const DebugSignalKind = core_types.DebugSignalKind;
pub const DebugSignalRef = core_types.DebugSignalRef;
pub const Transform2D = core_types.Transform2D;
pub const TransformOrigin = core_types.TransformOrigin;
pub const TransformOriginValue = core_types.TransformOriginValue;
pub const PathFillRule = core_types.PathFillRule;
pub const LineJoin = core_types.LineJoin;
pub const PathCommand = core_types.PathCommand;
pub const QuadraticPathCommand = core_types.QuadraticPathCommand;
pub const CubicPathCommand = core_types.CubicPathCommand;
pub const PathGeometry = core_types.PathGeometry;
pub const HitShapeSpec = core_types.HitShapeSpec;
pub const ClipShapeSpec = core_types.ClipShapeSpec;
pub const HitBehavior = core_types.HitBehavior;
pub const HitRoles = core_types.HitRoles;
pub const HitProxySpec = core_types.HitProxySpec;

// ========== UI 节点 ==========
pub const Node = core_node.Node;
/// 左键按下时的焦点策略，见 `NodeInteraction.pointer_down_focus`。
pub const PointerDownFocus = core_node.PointerDownFocus;
/// Node.world_id 的哨兵值（未注册到任何 World）。见 P0-3 owner 标识说明。
pub const INVALID_WORLD_ID = core_node.INVALID_WORLD_ID;
pub const Snapshot = snapshot_mod.Snapshot;
pub const DrawContext = core_node.DrawContext;
pub const clearNodeScopes = core_node.clearNodeScopes;
pub const clonePathGeometry = core_node.clonePathGeometry;
pub const freePathGeometry = core_node.freePathGeometry;
pub const createSvgDocumentPathGeometry = core_node.createSvgDocumentPathGeometry;
pub fn bindScopeToNode(scope: *Scope, node: *Node) !void {
    try Cx.bindScopeToNode(scope, node);
}

/// 一次性收养：把刚建好的 child 立刻挂到 parent 上，append 失败时自己释放 child。
/// 「建好即挂」让 create→append 之间不存在游离窗口，也就不需要门控 flag；
/// 各组件里同型的 adoptTagChild / adoptTabChild / adoptDividerChild 就是它。
/// 前提：parent 自身已挂在受守卫的子树上（根节点有 errdefer freeNode）。
pub fn adoptChild(cx: *Cx, allocator: std.mem.Allocator, parent: *Node, child: *Node) !*Node {
    errdefer cx.freeNode(child);
    try parent.appendChild(allocator, child);
    return child;
}
pub const NodeHandle = hit_runtime_mod.NodeHandle;
pub const NodeRegistry = hit_runtime_mod.NodeRegistry;
pub const InteractionIndex = hit_runtime_mod.InteractionIndex;
pub const PerfCounters = hit_runtime_mod.PerfCounters;
pub const HitQueryKind = hit_runtime_mod.HitQueryKind;
pub const HitShapeKind = hit_runtime_mod.HitShapeKind;

const cx_hit_target = @import("core/cx_hit_target.zig");
const resolveInteractionTarget = cx_hit_target.resolveInteractionTarget;
const resolveInspectTarget = cx_hit_target.resolveInspectTarget;

// Cx 方法按领域拆在 core/cx_*.zig（free function 收 *Cx），Cx 上只留同名
// pub thin delegate 保持公开 API 不变：
//   cx_input          鼠标 / 键盘 / IME / 滚轮 / 拖放入口
//   cx_cursor         cursor lease 与光标形状决策
//   cx_render         render() 帧管线、after-layout hooks、redraw 调度
//   cx_frame          帧时钟、idle 停帧门控、deferred 预算
//   cx_runtime_index  interaction index / focus order 全量与增量重建
//   cx_world_sync     Node → World 表同步、layerize
//   cx_world_hooks    进程级 Node → World 路由回调（g_active_world*）
//   cx_node_lifetime  detach / freeNode / 引用失效
//   cx_a11y           a11y 树同步 + macOS bridge 回调（投影规则在 a11y_projection）
//   cx_platform       SystemSdk / 窗口身份 / 原生文本输入会话
//   cx_bulk_quads     批量 quad 层
const cx_input = @import("core/cx_input.zig");
const cx_cursor = @import("core/cx_cursor.zig");
const cx_render = @import("core/cx_render.zig");
const cx_frame = @import("core/cx_frame.zig");
const cx_runtime_index = @import("core/cx_runtime_index.zig");
const cx_world_sync = @import("core/cx_world_sync.zig");
const cx_world_hooks = @import("core/cx_world_hooks.zig");
const cx_node_lifetime = @import("core/cx_node_lifetime.zig");
const cx_a11y = @import("core/cx_a11y.zig");
const cx_platform = @import("core/cx_platform.zig");
const cx_bulk_quads = @import("core/cx_bulk_quads.zig");

pub const HitQuery = hit_runtime_mod.HitQuery;
pub const HitResult = hit_runtime_mod.HitResult;
pub const SvgTextureLoader = svg_texture_store.SvgTextureLoader;
/// 系统剪贴板 / 文件对话框。收 `?*SystemSdk`，用法：
/// `platform_services.clipboardSetText(cx.system_sdk, text)`。
pub const platform_services = @import("core/platform_services.zig");

// ========== Cx: 统一上下文 ==========

/// main union DisplayItem 字段已物理删除。
/// 现在只保留 main_paint (paint_table.DisplayItem)，encoder 主路径直接消费。
/// 历史背景: Stage B R3f 时 main union 是 encoder 中转；v0.5 §5 GpuDraw epic 后
/// encoder 改吃 paint_table，union main 变镜像。v0.9-§c 把镜像 dropped，paint_table
/// 是唯一 source。
///
/// _dead_main: RenderContext / DrawContext 仍有 lowering_buffer 字段 (*ArrayList(union DisplayItem))
/// 占位但没活跃 caller append/read。保留空 ArrayList 让指针有效；下一波 epic
/// 把这两个字段从 RenderContext/DrawContext 物理删，本字段可一起删。
pub const LoweringBuffers = struct {
    _dead_main: std.ArrayList(display_list_mod.DisplayItem) = .{},
    main_paint: std.ArrayList(paint_table.DisplayItem) = .{},

    pub fn deinit(self: *LoweringBuffers, allocator: Allocator) void {
        self._dead_main.deinit(allocator);
        self.main_paint.deinit(allocator);
    }
};

/// 统一上下文 - 合并 UIContext/EventDispatcher/FocusManager/StateStore
/// paint chunk 写入失败次数（OOM）。每次都意味着画面局部缺失，
/// 稳态下必须恒为 0（审查报告 §3：静默吞错家族的可观测化）。
pub var paint_push_failures: u64 = 0;

/// interaction 表写入失败次数（OOM）。每次都意味着某节点该帧不可命中
/// （点击/hover 静默失效），稳态下必须恒为 0。
pub var interaction_put_failures: u64 = 0;

/// a11y active context 注册失败次数。只可能是同时存活的窗口数超过
/// `macos_bridge.MAX_WINDOWS`；后果是该窗口对 VoiceOver 不可读（渲染不受影响）。
pub var a11y_context_register_failures: u64 = 0;

/// 逐 glass 亮度样本（renderer 每帧从 luminance 槽池投影；key = glass 拥有者 node id）。
pub const BackdropLumRegion = struct { node_id: u32, lum: f32 };

/// 批量矩形 —— 绕过 Node 树的"一批同构矩形"提交单元。
///
/// 实现已整体析出到 core/bulk_quad_layer.zig（五个字段 + 十三个方法）。
/// 这里保留公共别名：消费者（下游应用等）用的是 `ui.BulkQuad` /
/// `Cx.setBulkQuads`，类型搬家不该顺带 break 仓外 API。完整的动机、
/// 受限语义与像素等价保证见该模块头部注释。
pub const BulkQuad = bulk_quad_layer_mod.BulkQuad;

/// 一条 BulkQuad 最多降成几个 DisplayItem（见 bulk_quad_layer.zig）。
pub const MAX_ITEMS_PER_QUAD: usize = bulk_quad_layer_mod.MAX_ITEMS_PER_QUAD;

/// Window portal 在用户 UI 之上、DevTools overlay（32000）之下。
/// Portal 内部的精确顺序仍由 OverlayStack 的 100..3000 tier 决定。
pub const WINDOW_PORTAL_Z_INDEX: i16 = 31_000;

/// 由 Cx 兜底释放的一块组件私有内存（目前只有 ScrollArea 的 ScrollCtxCell）。
/// 用 destroyFn 抹掉具体类型，避免 core → components 的反向依赖。
pub const OwnedCell = struct {
    ptr: *anyopaque,
    destroyFn: *const fn (*anyopaque, Allocator) void,
};

/// 布局之后、生成绘制命令之前的回调结果。
pub const AfterLayoutResult = enum { done, needs_layout };
/// `round` 从 0 开始；`last_round` 为 true 时返回 needs_layout 也不会再被调用。
pub const AfterLayoutFn = *const fn (ctx: *anyopaque, round: u8, last_round: bool) AfterLayoutResult;
/// 一帧内「回调 → 布局」最多循环的轮数。
pub const max_after_layout_rounds: u8 = 4;
const AfterLayoutHook = struct { ctx: *anyopaque, run: AfterLayoutFn };

pub const Cx = struct {
    /// 保留为公共别名（实现见 core/frame_perf.zig）。
    pub const frame_perf_history_size: usize = frame_perf_mod.history_size;
    pub const window_portal_z_index: i16 = WINDOW_PORTAL_Z_INDEX;

    /// Ref-counted liveness marker for cross-window observers such as DevTools.
    /// The marker outlives `Cx` when another window still holds a reference, so
    /// callers can test liveness without dereferencing a freed `*Cx`.
    pub const LifetimeToken = struct {
        allocator: Allocator,
        ref_count: usize = 1,
        alive: bool = true,

        pub fn retain(self: *LifetimeToken) *LifetimeToken {
            std.debug.assert(self.ref_count > 0);
            self.ref_count += 1;
            return self;
        }

        pub fn release(self: *LifetimeToken) void {
            std.debug.assert(self.ref_count > 0);
            self.ref_count -= 1;
            if (self.ref_count == 0) self.allocator.destroy(self);
        }

        pub fn isAlive(self: *const LifetimeToken) bool {
            return self.alive;
        }
    };

    allocator: Allocator,
    owner: *SignalOwner,
    lifetime_token: *LifetimeToken,

    // UI 树
    root: ?*Node = null,
    /// Window-root portal —— 所有脱离正常文档流的 overlay 的唯一宿主。
    /// Popover/Tooltip 只把 floating content 挂到这里，trigger wrapper 仍留在
    /// caller 树中。Modal/Sheet 的 barrier 也作为同一 portal 的直接 child，
    /// 使 OverlayStack 的 z-index tier 能在同级兄弟之间正确排序。
    /// App.mount 会在调用用户 mount_fn 之前设置它；低层 standalone Cx
    /// 由 ensurePopoverPortalRoot() 在已有 root 下自动补建，不走 inline fallback。
    popover_portal_root: ?*Node = null,
    /// Debug 自检去重：最近一次做过"portal 祖先链无裁剪/无 effect surface"检查的
    /// portal 节点 id（0 = 尚未检查）。见 checkPopoverPortalAncestry。
    popover_portal_ancestry_checked_id: u32 = 0,
    next_id: u32 = 1,

    // 交互状态
    hovered_node: ?*Node = null,
    focused_node: ?*Node = null,
    pressed_node: ?*Node = null,
    hovered_handle: ?NodeHandle = null,
    focused_handle: ?NodeHandle = null,
    /// magnify 手势期间锁定的派发目标（began 时命中，ended/cancelled 清除）
    magnify_target_handle: ?NodeHandle = null,
    /// 拖放会话中当前悬停的 drop target。
    /// 只存 handle 不存裸指针：resolve 天然带存活校验，避免节点在拖拽期间
    /// 被释放后解引用（见 invalidateReferencesTo 处对 hovered_node 的注释）。
    drag_hover_handle: ?NodeHandle = null,
    pressed_handle: ?NodeHandle = null,
    /// 最近一次 mouseDown 命中的节点（不在 mouseUp 时清除，供 on_before_render 读取）
    last_mouse_down_target: ?*Node = null,
    /// 最近一次左键按下时命中的浮层（渲染期 outside-click 判定的兜底）。
    press_overlay_owner: ?overlay_stack_mod.LayerHandle = null,
    /// 被 `.close_and_consume` 浮层吞掉的那次按下：对应按键的抬起也吞掉。
    swallowed_press_button: ?MouseButton = null,
    last_mouse_down_handle: ?NodeHandle = null,
    /// 标记本帧是否有新的 mouseDown 事件（每帧清除）
    has_new_mouse_down: bool = false,

    // (已删除: hovered_node_id/pressed_node_id/focused_node_id — 保留模式下节点不重建，直接用 ?*Node 指针)

    mouse_x: f32 = 0,
    mouse_y: f32 = 0,
    viewport: Size = Size.ZERO,
    /// App-defined "safe area" insets — title bar / tab bar / status bar 占用的空间。
    /// floating UI（popover / hover / tooltip）做 viewport boundary 计算时把它们减掉，
    /// 避免 popover 顶部跑到 title bar 后面。Caller 在 app shell layout 后设置一次。
    /// 默认 0（无 chrome）。
    safe_area_top: f32 = 0,
    safe_area_bottom: f32 = 0,
    safe_area_left: f32 = 0,
    safe_area_right: f32 = 0,
    window_scale: f32 = 1.0,

    /// 当前系统光标形状（避免重复调用平台 API）
    current_cursor: CursorShape = .default,
    cursor_override: ?CursorShape = null,
    cursor_state: cursor.State = .{},
    /// 自定义位图光标（CursorShape.custom 的内容），key → 已光栅化位图。
    /// 同一时刻只有一个激活位图（active_custom_cursor）。
    /// 自定义位图光标存储（实现见 core/custom_cursor.zig）。
    /// store 负责「desc → 光栅化 → 按内容寻址缓存」，下发到系统留在
    /// updateCursorShape（那一步才需要 system_sdk / window_id）。
    custom_cursor: custom_cursor_mod.CustomCursorStore = .{},
    /// Harness 自动化指针。仅在收到自动化 pointer 命令后可见；纯绘制，
    /// 不参与布局、命中或原生 cursor 状态。
    virtual_cursor: virtual_cursor_mod.VirtualCursor = .{},

    /// 帧计数器 (用于多击检测等计时逻辑)
    frame_count: u64 = 0,

    /// 真实帧间隔（秒），由 renderFrame 每帧更新。动画系统使用此值代替硬编码 1/60。
    frame_dt_seconds: f32 = 1.0 / 60.0,
    /// 上一帧的时间戳（用于计算帧间隔）
    last_frame_instant: ?std.time.Instant = null,

    /// 单调递增的帧时间戳（ms），相对于应用启动。用于绝对时间戳驱动的动画系统。
    /// f64 避免长时间运行后精度退化（f32 在 ~16.7 秒后丢失亚毫秒精度）。
    ///
    /// **由墙钟派生**：frame_time_ms = (now - clock_epoch) - clock_paused_ns。
    /// 不是逐帧 dt 的累加和——累加会把每个被 clamp 削短的慢帧永久丢失（实测 4fps
    /// 下 5s 真实时间只走 2s，动画降到 40% 速度且永不追回），表现为"性能越差动画越慢"。
    frame_time_ms: f64 = 0,
    /// 逻辑时钟原点。首次 advanceFrameClock 时锚定。
    clock_epoch: ?std.time.Instant = null,
    /// 累计 idle 暂停时长（ns）。idle 帧不推进逻辑时钟（零脏帧快速路径依赖它），
    /// 这段真实时间被记进偏移量而非灌进动画，使 active 帧恢复后时间轴连续。
    clock_paused_ns: u64 = 0,
    /// 帧间隔（ms），由 frame_dt_seconds 派生。保留给 Spring 物理模拟等增量 dt 消费者。
    frame_dt_ms: f32 = 16.667,
    /// 当前窗口显示器刷新率（Hz）
    display_refresh_hz: f32 = 60.0,
    /// 帧性能采样（四条链路的环形缓冲，见 core/frame_perf.zig）。
    ///
    /// 这里原本铺着 14 个平铺字段 + 17 个方法，push/percentile/avg/max 的逻辑
    /// 各抄了四遍。它们不碰 Cx 的任何其它状态，已析出成可独立单测的值类型；
    /// 下面的 Cx 方法只剩薄转发，保持既有调用点不变。
    frame_perf: frame_perf_mod.FramePerf = .{},
    /// 帧级重绘标记 (R4a: idle 零开销)
    /// 输入事件、活跃动画、窗口 resize 时设为 true。
    /// 应用层在帧循环中检查此标记，idle 时跳过 buildUI/layout/render/GPU 提交。
    needs_redraw: bool = true,

    /// 上一次 tick pass 结束时是否仍有活跃 node transition/command 动画。
    /// 供 hasPendingSceneWork 做 O(1) 判定，替代对整树的递归扫描：
    /// 动画启动必经 markXxxDirty（root 脏位已覆盖"本帧新启动"），持续中的
    /// 动画由上一帧 tick 的返回值记录在这里；误报方向只多渲染一帧，自愈。
    last_tick_animations_active: bool = false,

    // Stage B R3d (B 路线): cx.display_list 是真源，下面 lowering 子结构持有
    // encoder 端 buffer (paint pass → derive 翻译目标 + inspector overlay merge)。
    // v0.5 §5 GpuDraw 完工后 (commit 10d26a8) encoder 吃 lowering.main_paint;
    // lowering.main union 仍保留供 inspector overlay 写入 + 内部诊断。
    // 直接读 lowering.* 字段属于内部访问；外部 caller 走 cx.lowerForEncoderPaintTable()。
    lowering: LoweringBuffers = .{},

    /// Stage B R3d: 零脏 skip 路径直接返回 self.display_list 切片（display_list
    /// 跨帧稳定不需快照）。此 flag 在首帧 / resize / 强制重绘时置 false 以强制
    /// 走完整 paint pass 并填 self.lowering.main 供 encoder lower 用。
    last_render_valid: bool = false,
    /// 上一次 render() 时的 frame_time_ms。frame_time_ms 推进意味着可能有动画在跑——
    /// 即便 dirty 位 clean 也不能 skip（动画 hook 没机会推进）。
    last_render_frame_time_ms: f64 = 0,

    /// overlay 渲染命令分段记录（按 z_index 排序后合并，确保嵌套 overlay 层级正确）
    /// 帧级 Arena 分配器 — 每帧 reset，用于临时计算（避免堆碎片化）
    frame_arena: std.heap.ArenaAllocator,
    deferred_epoch: std.time.Instant,
    deferred_scheduler: DeferredScheduler,
    /// 一次性计时器（`setTimer`）。到点会唤醒帧循环并在 render 开头触发。
    timers: std.ArrayListUnmanaged(Timer) = .{},
    next_timer_id: u64 = 1,

    // Inspector (DevTools)
    inspector: Inspector = .{},
    /// Per-window diagnostic log store. It lives with the target Cx rather
    /// than with the DevTools window, so logs are captured before DevTools is
    /// opened and two windows never share output.
    console_store: console_mod.Console,

    node_registry: NodeRegistry,
    interaction_index: InteractionIndex,
    /// SVG 贴图缓存 + 命中几何（实现见 core/svg_texture_store.zig）。
    /// 原本是这里的三个字段 + 六个方法，自成所有权闭环，已整体搬出。
    svg_textures: svg_texture_store.SvgTextureStore,
    scene_runtime: scene_runtime_mod.SceneRuntime,
    property_tree: property_tree_mod.PropertyTree,
    display_list: display_list_mod.DisplayList,
    text_blob_store: text_blob_mod.BlobStore,
    /// 批量矩形层（实现见 core/bulk_quad_layer.zig）。宿主直接提交一批
    /// 绝对坐标矩形，绕过 Node 的挂载/布局/paint 遍历；渲染时由
    /// `appendBulkQuads` lower 进 display list 并插入锚点位置。
    /// 字段以 `bulk_quads_*` 之名保留在 Cx 上（tests / devtools 直读），
    /// 实为该层五个状态的薄别名。
    bulk_quads: std.ArrayListUnmanaged(BulkQuad) = .{},
    /// 批量矩形层挂靠的 Node（见 `setBulkQuads`）。null = 不挂靠（画在
    /// 整棵树之上、不裁剪）。渲染时按该 Node 的 display item 区间与
    /// clip/transform id 插入这批 quad。
    bulk_quads_anchor: ?*Node = null,
    /// 锚点子树里"交互叠加"的 z_index 起点（见 `setBulkQuads`）。
    /// null = 整棵锚点子树都算静态内容。
    bulk_quads_overlay_z: ?i16 = null,
    /// 宿主声明的批量层内容版本（见 setBulkQuadsVersioned）。
    bulk_quads_version: ?u64 = null,
    /// Node 外部裁剪矩形旁表（node.id → 视口系 x/y/w/h）。
    ///
    /// 语义：该节点（含整个子树）额外受此矩形裁剪，与自身 overflow clip
    /// 取交。节点**无须**成为裁剪来源的父子 —— 宿主场景是画布对象平铺
    /// 挂载（frame 与其成员是兄弟 Node），frame 的 clip 只能由宿主逐节点
    /// 标注。存旁表而不是 Node 字段：Node 顶层字段有 SoA 尺寸纪律，而这
    /// 是极稀疏的属性（只有画布 frame 成员用）。
    external_clip_rects: std.AutoHashMapUnmanaged(u32, [4]f32) = .{},
    /// 本帧批量层内容是否与上一帧相同（由版本号判定；见
    /// core/bulk_quad_layer.zig 的 setVersioned）。
    bulk_quads_unchanged: bool = false,

    // World 容器持有 4 表（ElementTable / LayoutTable / PaintTable /
    // InteractionTable）+ dirty_set。当前 shadow-mode 双写：旧 Cx 字段
    // (property_tree, display_list, scene_runtime) 仍是真渲染源；World 同步
    // 收集数据供 v0.2-P4+ 消费方使用。v0.3 反转 source-of-truth。
    world: world.World,
    // LayerTree 真合成层。每帧 layerize 把 World.elements 分组成
    // layer。v0.5 Stage A (2026-05-01) compositor_plan.zig 删除后 LayerTree
    // 已成为合成层的 source-of-truth；CompositedLayer 直接挂在 LayerTree.Layer.composited。
    layer_tree: layer_tree.LayerTree,
    // v0.6 §2.3 infrastructure 接入 (2026-05-12):
    // - cx.handleMouseDown/Move/Up feed gesture_arena.onTouchDown/Move/Up
    // - cx.render() 每帧 tick (long_press 时间判定)
    // - cx.registerGesture(target, kind, config, callback) 暴露注册 API
    // input/state.zig 自己写的双击/三击/drag anchor 仍并存（旧路径走 dispatcher
    // 内置 click/double_click 合成 + input 组件 handleMouseDown），未迁过来。
    // 完整迁移 (input 组件迁到 GestureArena) 等用户场景出现需要再推。
    gesture_arena: gesture_input.GestureArena,
    // AccessibilityTree 完整 ARIA 投影。
    // v0.6 §2.1 (commit 1370e15-946d9d7) 已成为 macOS NSAccessibility 主路径：
    // cx.render() 末尾 syncA11yTreeFromInteractions 把 Node tree 投影成 A11yNode；
    // ObjC accessibilityChildren 协议方法通过 a11y/macos_bridge.zig 的 9 个
    // zenit_a11y_* C ABI 拉数据。focus_manager.a11y_bridge (旧 single-point
    // notify) 仍存在但只覆盖 focus/property change 通知；children navigation
    // 100% 走新 tree。
    accessibility_tree: a11y_tree_mod.AccessibilityTree,
    /// A11yNode 只持 label/description/value 的 u64 hash；本表保留 hash → string
    /// 的反向映射，让 platform bridge (NSAccessibility / IAccessible) 能查回真实 UTF-8
    /// 字符串供 AT 工具读出。每帧 cx.render() 末尾在 syncA11yTreeFromInteractions 内重建。
    a11y_label_buf: std.AutoHashMapUnmanaged(u64, []const u8) = .{},
    /// push-side bridge context — 持 window_id + label_resolver 指针。
    /// 每帧 syncA11yTreeFromInteractions 重设；flushToBridge 调用 macos_bridge
    /// extern push fn 时回弹此 ref 拿 window_id。
    a11y_push_cx_ref: a11y_macos_bridge_mod.PushCxRef = .{
        .window_id = 0,
        .label_ctx = undefined,
        .label_resolver = undefined,
    },
    perf: PerfCounters = .{},
    before_render_frame: ?u64 = null,
    before_render_time_ms: f64 = std.math.nan(f64),
    next_redraw_scheduled_at: ?std.time.Instant = null,
    next_redraw_delay_ns: ?u64 = null,

    // 主题 Token (运行时可切换)
    tokens: *const theme.ThemeTokens = &theme.dark,
    /// setTheme 每次 swap 自增；before_render hook 可比对此值
    /// 决定是否重读 tokens（避免每帧都同步派生 style）。
    theme_version: u32 = 0,
    /// theme Signal 化：惰性创建（themeSignal()），setTheme 时 set，
    /// 让 Effect/Memo 可以响应式订阅主题切换而非轮询 theme_version。
    theme_signal: ?*Signal(*const theme.ThemeTokens) = null,
    // 系统通信 SDK（可选）
    system_sdk: ?*system_sdk_mod.SystemSdk = null,
    /// Sole owner of the window-level native text input context. `active`
    /// tracks the logical focused client; `native_enabled == null` means the
    /// platform state is unknown and must be reconciled after SDK attachment.
    /// 原生输入法会话的对账状态机（实现见 core/text_input_session.zig）。
    /// 三态 native_enabled 的理由见该模块头部注释。
    text_input_session: text_input_session_mod.TextInputSession = .{},
    /// backdrop 亮度自适应：上一帧玻璃 backdrop 的实测平均 luminance（0~1，
    /// linear）。由 App 运行时在 GPU 回读后写入；null = 未启用/无玻璃。
    backdrop_luminance: ?f32 = null,
    /// 逐 glass 的 backdrop 亮度（key = glass 拥有者 node id，滚动恒定）。
    /// 组件按自身 node id 精确匹配，无匹配退回全局均值。
    backdrop_luminance_regions: [12]BackdropLumRegion = undefined,
    backdrop_luminance_region_count: usize = 0,
    // 当前 UIContext 绑定的窗口 ID（用于多窗口系统 API 路由）
    window_id: system_sdk_mod.events.WindowId = 1,
    /// Native callback identity, independent of the SDK logical routing id.
    native_window_id: u32 = 1,
    /// 字体 / 塑形 / 测量子系统（实现见 core/text_context.zig）。
    ///
    /// 原本是五个平铺字段（measure_fn / measure_ctx_fn / measure_ctx /
    /// shaping_cache / font_system）+ 八个方法。它们自成闭环，但挂在 Cx 上
    /// 导致任何要测文本测量的代码都得先造一个完整的 Cx。
    text: text_context.TextContext,

    // 保留模式
    root_scope: ?*Scope = null, // 全局根 Scope

    /// 本 Cx 的 World id —— 盖在它创建的每个 Node.world_id 上，用于检测跨 Cx 串台。
    world_id: u16 = 0,

    /// >0 表示正处于 before_render tick 遍历中（render_engine 正在走节点树）。
    /// 期间任何 freeNode 都必须**延后**到遍历结束，否则会把正在被迭代的
    /// 节点内存抽走 —— 见 deferred_free_nodes。
    tick_depth: u32 = 0,
    /// 布局之后的回调：在 before_render tick 之后那一轮布局完成后调用，读到的是本帧
    /// 最终几何。回调可以改几何并请求再布局（有轮数上限）；命中索引在全部轮次之后重建。
    after_layout_hooks: std.ArrayListUnmanaged(AfterLayoutHook) = .{},
    /// runAfterLayoutHooks 遍历中下一个要跑的下标；回调里 removeAfterLayoutHook
    /// 移除它之前的条目时同步回退，避免跳过后继 hook。null = 不在遍历中。
    after_layout_cursor: ?usize = null,
    /// tick 期间请求释放、待遍历结束后统一释放的节点。
    /// 触发路径：before_render hook / 动画完成回调里 dispose 组件 scope，
    /// scope cleanup 走 detachChild + freeNode（snapshot_layer 的
    /// animateOpacity(done) 是典型），而此时 tickBeforeRender 的递归栈上
    /// 还持有该节点及其祖先的 *Node —— 立即 free 会让上层栈帧读到 0xaaaa… 毒值。
    deferred_free_nodes: @import("reactive/deferred_disposal.zig").Queue = .{},
    draining_deferred_frees: bool = false,
    /// ScrollArea 的 on_cleanup 中转格（components/scroll_area 的 ScrollCtxCell）。
    /// 节点可能比自己的 ScrollEventCtx 活得久且解绑够不着（见该类型注释），所以
    /// 格子不能随 scope 走；由 Cx 兜底持有，deinit 时统一回收。
    scroll_ctx_cells: std.ArrayList(OwnedCell) = .{},
    current_scope: ?*Scope = null, // 当前活跃 Scope（mount 期间使用）
    is_mounted: bool = false, // 是否已完成首次 mount

    /// 匿名 state id 计数器。由 `bindState` 使用：从 u64.max 向下递减，避开
    /// 用户显式分配的小 id 空间（典型用 1, 2, ...）。让用户在不需要跨调用
    /// 寻址 state 时可以完全跳过 id 系统。
    next_anon_state_id: u64 = std.math.maxInt(u64),

    // 子系统 (内部管理, 不暴露)
    dispatcher: event_dispatcher_mod.EventDispatcher,
    /// 窗口内连续 pointer drag 的中心仲裁（docs/DRAG_INTERACTION_DESIGN.md §5.3）。
    /// 每 Cx 单会话；不持业务 payload。
    drag_manager: interaction_drag.Manager = .{},
    focus_manager: focus_mod.FocusManager,
    state_store: widget_state_mod.StateStore,
    action_dispatcher: actions_mod.ActionDispatcher = .{},
    overlay_stack: OverlayStack = .{},
    /// GlyphRun 流水线接管旧 ASCII-first measure 路径的容器。每帧
    /// beginFrame 推进 epoch；shaped run 通过 ShapingKey 命中 cache，避免重复
    /// 当前存活的 Cx 数量。**不再用于拒绝第二个 Cx**（守卫已于 2026-07-30 拆除，
    /// 理由见 init）；仍需要它来判断"我是最后一个 Cx 吗"，决定何时回收
    /// 进程级的 standalone fallback 存储 —— 见 deinit。
    var g_live_cx_count: usize = 0;

    /// 已废弃的 no-op：多 Cx 守卫已拆除，无需再放行。保留供旧测试调用不报错。
    /// 新代码不要调。
    pub fn allowMultipleContextsForTest(allow: bool) void {
        _ = allow;
    }

    pub fn console(self: *Cx) *console_mod.Console {
        return &self.console_store;
    }

    pub fn init(allocator: Allocator) !*Cx {
        // ── 多 Cx / 多窗口：曾经的 MultipleContextsUnsupported 守卫已拆除 ──
        //
        // 该守卫存在的理由是一串进程级依赖会让两个窗口互相串台。逐条拆完了：
        //
        // 1. **Node↔World 路由**（P0-3 阶段 1-5）：曾走 20 多个进程级回调，
        //    第二个 Cx.init 会把回调重指向新 World，导致窗口 A 的 mutation 落进
        //    窗口 B 的表（且 ElementId 不含 World 标识，isValid 会假匹配）。
        //    现在 Node 自带 `world_ref`，属性读写、dirty、父子链全部直连 owner
        //    World；builder 与 devtools 也已改走 `cx.createNode`。回归测试见
        //    core/tests.zig "two coexisting Cx each render their own tree"。
        // 2. **文本测量**：新增带 context 的 `MeasureCtxFn`，`App.init` 把自己的
        //    FontSelector 作为 context 传下去，多 App 并存时各测各的字体。
        // 3. **a11y bridge active context**（最后一处，2026-07-30）：9 个
        //    `zenit_a11y_*` C ABI export 全部加了 `window_id` 首参，zig 端换成
        //    按 window_id 键入的注册表，ObjC 代理从自己的 NSWindow 取 id 带进来。
        //    验收见 a11y/macos_bridge.zig 的 "two windows route independently"。
        //
        // 仍存在的 `g_*` 全局（node_tree / paint_content_accessor 的 standalone
        // 表、layout_engine 的 active cache）都**只在 `world_ref == null` 时**
        // 才被读到 —— 即 cx-less mock 路径；生产路径已插桩验证 0 次命中。
        // layout_engine 的两个 active 指针是 layoutNode 内 save/restore 的
        // 调用域内状态，不跨窗口存活。
        //
        // 真窗口由 `MultiWindowApp` 统一 pump/render。纯生命周期与路由走
        // test-headless；需要登录态 WindowServer 的双窗/单窗幸存/退出析构验证
        // 走 scripts/run_multiwindow_smoke.sh。物理输入与辅助功能仍留在人工矩阵。

        const owner = try SignalOwner.init(allocator);
        errdefer owner.deinit();

        const lifetime_token = try allocator.create(LifetimeToken);
        errdefer allocator.destroy(lifetime_token);
        lifetime_token.* = .{ .allocator = allocator };

        const cx = try allocator.create(Cx);
        cx.* = .{
            .allocator = allocator,
            .owner = owner,
            .lifetime_token = lifetime_token,
            .lowering = .{},
            .frame_arena = std.heap.ArenaAllocator.init(allocator),
            .deferred_epoch = try std.time.Instant.now(),
            .deferred_scheduler = DeferredScheduler.init(allocator),
            .node_registry = NodeRegistry.init(allocator),
            .interaction_index = InteractionIndex.init(allocator),
            .svg_textures = svg_texture_store.SvgTextureStore.init(allocator),
            .scene_runtime = scene_runtime_mod.SceneRuntime.init(allocator),
            .property_tree = property_tree_mod.PropertyTree.init(allocator),
            .display_list = display_list_mod.DisplayList.init(allocator),
            .text_blob_store = text_blob_mod.BlobStore.init(allocator),
            .world = world.World.init(allocator),
            .layer_tree = layer_tree.LayerTree.init(allocator, .{}),
            .gesture_arena = gesture_input.GestureArena.init(allocator),
            .accessibility_tree = a11y_tree_mod.AccessibilityTree.init(allocator),
            .dispatcher = event_dispatcher_mod.EventDispatcher.init(allocator),
            .focus_manager = focus_mod.FocusManager.init(allocator),
            .state_store = widget_state_mod.StateStore.init(allocator),
            .console_store = console_mod.Console.init(allocator, .{}),
            // GlyphRun pipeline cache，capacity 1024 是 ShapingCache
            // 默认水位（具体调节后续 perf 数据驱动）。
            .text = text_context.TextContext.init(allocator, 1024),
        };
        // 连接 focus_manager 与 dispatcher，使 focus/blur 事件能冒泡
        cx.focus_manager.dispatcher = &cx.dispatcher;
        cx.focus_manager.setRegistry(&cx.node_registry);
        cx.focus_manager.settled_context = cx;
        cx.focus_manager.on_focus_settled = &cx_platform.focusSettled;
        cx.dispatcher.setRegistry(&cx.node_registry);
        cx.action_dispatcher.setRegistry(&cx.node_registry);
        cx.overlay_stack.setRegistry(&cx.node_registry);

        // 启用 layout intrinsic cache（当前是全局静态；v0.2-P3 拆 Node 时
        // 迁到 LayoutTable per-node 字段）。allocator 用 Cx.allocator —— 跨帧持久。
        layout_engine.enableIntrinsicCache(allocator);

        // 设置 Node dirty notify callback，让 markRenderDirty 把 dirty
        // 同步到 World.dirty_set。当前是全局静态——多 Cx 场景下后者覆盖前者。
        //
        // ⚠️ 订正（2026-07-29）：旧注释写的是"旧 Cx 的 dirty 流入新 Cx.world
        // 是无害的（id 不匹配则 isValid 检查保护）"—— **这是错的，已证伪**。
        // ElementId 是 {index:u24, generation:u8}，**不含 World 标识**，且每个
        // World 都从 index 0 开始分配。SlotMap.isValid 只校验 index 范围 +
        // generation，所以拿旧 Cx 的 id 去查新 Cx 的 World **会假匹配并返回
        // 错误数据**，不是"不匹配被拦下"。这正是必须给 Node 加 world_id
        // （owner 标识）的原因，也是 Cx.init 目前拒绝并发第二个 Cx 的原因。
        // 详见 docs/internal/P0-3_MULTI_CX_ROOTCAUSE_2026-07-29.md。
        cx_world_hooks.g_active_world = &cx.world;
        // 给这个 Cx 分配唯一 world id（不复用，见 cx_world_hooks.g_next_world_id 注释）。
        // 溢出到 INVALID 时跳过该值，保证哨兵语义不被占用。
        if (cx_world_hooks.g_next_world_id == core_node.INVALID_WORLD_ID) cx_world_hooks.g_next_world_id = 0;
        cx.world_id = cx_world_hooks.g_next_world_id;
        cx_world_hooks.g_next_world_id +%= 1;
        cx_world_hooks.g_active_world_id = cx.world_id;
        core_node.setDirtyNotifyCallback(&cx_world_hooks.onNodeDirty);
        core_node.setStructureNotifyCallback(&cx_world_hooks.onNodeStructure);
        core_node.setRectQueryCallback(&cx_world_hooks.onRectQuery);
        core_node.setRectWriteCallback(&cx_world_hooks.onRectWrite);
        core_node.setWorldOwnershipCheck(&cx_world_hooks.nodeBelongsToActiveWorld);
        core_node.setNodeCreateHook(&cx_world_hooks.onNodeCreate);
        // NodeContent SoA mirror writers.
        core_node.setContentTextWriteCallback(&cx_world_hooks.onContentTextWrite);
        core_node.setContentImageWriteCallback(&cx_world_hooks.onContentImageWrite);
        core_node.setContentIconWriteCallback(&cx_world_hooks.onContentIconWrite);
        // read end 也走 World.content.
        core_node.setContentTextReadCallback(&cx_world_hooks.onContentTextRead);
        core_node.setContentImageReadCallback(&cx_world_hooks.onContentImageRead);
        core_node.setContentIconReadCallback(&cx_world_hooks.onContentIconRead);
        // PaintState SoA mirror writers.
        core_node.setPaintBackgroundWriteCallback(&cx_world_hooks.onPaintBackgroundWrite);
        core_node.setPaintOpacityWriteCallback(&cx_world_hooks.onPaintOpacityWrite);
        // PaintState SoA readers (字段已删, getter 走 World).
        core_node.setPaintBackgroundReadCallback(&cx_world_hooks.onPaintBackgroundRead);
        core_node.setPaintOpacityReadCallback(&cx_world_hooks.onPaintOpacityRead);
        // NodeLayoutOutput SoA mirror (双写期).
        core_node.setLayoutOutputWriteCallback(&cx_world_hooks.onLayoutOutputWrite);
        core_node.setLayoutOutputReadCallback(&cx_world_hooks.onLayoutOutputRead);
        core_node.setLayoutOutputPtrCallback(&cx_world_hooks.onLayoutOutputPtr);

        // 全部成功后才计数 —— 上面任何 errdefer 回滚都不应留下计数残留。
        g_live_cx_count += 1;
        return cx;
    }

    /// Acquire a liveness reference that remains valid after this `Cx` is
    /// destroyed. The caller must eventually call `LifetimeToken.release()`.
    pub fn retainLifetimeToken(self: *Cx) *LifetimeToken {
        return self.lifetime_token.retain();
    }

    /// 创建一个显式归属本 Cx 的节点 —— **不依赖任何进程级全局**。
    ///
    /// P0-3：这是多窗口的必要入口。`Node.create` 走的是
    /// `g_node_create_hook` + `cx_world_hooks.g_active_world` 全局对，多个 Cx 并存时
    /// 会把节点注册到"最后一个 init 的 Cx"而非调用者自己的 World。
    /// 用本方法就没有这个歧义。
    pub fn createNode(self: *Cx, tag: ElementTag, style: Style) !*Node {
        return cx_world_hooks.createNode(self, tag, style);
    }

    pub fn nodeBelongsToActiveWorldForTest(node: *const Node) bool {
        return cx_world_hooks.nodeBelongsToActiveWorldForTest(node);
    }

    pub fn deinit(self: *Cx) void {
        // Invalidate external observers before any owned state starts tearing
        // down. They can now stop without ever touching this soon-to-be-freed Cx.
        const lifetime_token = self.lifetime_token;
        lifetime_token.alive = false;
        self.timers.deinit(self.allocator);

        // 活跃 drag 先取消：callback context 可能由下面即将销毁的 scope 持有，
        // 顺序反了就是 UAF（docs/DRAG_INTERACTION_DESIGN.md §11.2）。
        self.drag_manager.cancel(self, .scope_disposed);

        // tick 期间排队但还没释放的节点（正常帧路径会在 tick 结束时 drain，
        // 这里兜底：deinit 可能发生在任意时刻）。必须在 root 释放之前处理 ——
        // 这些节点已经摘链，不会被 root 子树的递归释放覆盖到。
        self.tick_depth = 0;
        cx_node_lifetime.drainDeferredFrees(self);

        // ScrollArea 中转格：此刻所有节点与 scope 都已结束，没人再会读它们。
        // 用组件自己登记的 destroyFn 释放，避免 core → components 的反向依赖。
        for (self.scroll_ctx_cells.items) |entry| {
            entry.destroyFn(entry.ptr, self.allocator);
        }
        self.scroll_ctx_cells.deinit(self.allocator);

        // standalone fallback storage 是进程级 + page_allocator，GPA leak
        // check 覆盖不到（审查报告列的盲区）。这里显式回收，让"零残留"可断言。
        // 仅当没有其它存活 Cx 时才清 —— 否则会抽走别人还在用的表。
        if (g_live_cx_count == 1) {
            core_node.deinitStandaloneRects();
            paint_content_accessor.deinitStandaloneStorage();
        }

        // 保留模式: 先把节点上的 scope 指针断开，再销毁 root_scope。
        // 否则后续 freeNode() 访问 node.ownership.scope.scope 会触发悬垂指针。
        //
        // 注意：clearNodeScopes 必须在所有路径上跑（不只是 root_scope 存在的
        // 路径）。测试和高级 caller 经常用外部 Scope mount 组件树，那种情况
        // self.root_scope 为 null，但 cx.root 子树的节点仍可能挂着已 dispose
        // 的外部 scope 指针。如果不先清，freeNode → invalidateSubtreeHookState
        // 会访问 hook 状态注册到外部 scope 上的悬垂指针，触发 UAF。
        if (self.root) |r| {
            hooks_mod.invalidateSubtreeHookState(r);
            clearNodeScopes(r);
        }
        if (self.root_scope) |rs| {
            if (!rs.disposed) rs.dispose();
            self.root_scope = null;
        }

        // Tear down the sole native session before its focused client dies.
        cx_platform.deactivateTextInputSession(self);
        // 焦点悬垂指针先清再放树（同 unmount；下游应用的 segfault 路径）
        self.focus_manager.current_focus = null;
        self.focus_manager.current_focus_handle = null;
        if (self.root) |r| {
            self.freeNode(r);
            self.root = null;
        }
        self.popover_portal_root = null;

        self.overlay_stack.clear();
        self.console_store.deinit();
        self.text.deinit();
        self.state_store.deinit();
        self.focus_manager.deinit();
        self.dispatcher.deinit();
        self.svg_textures.deinit();
        self.custom_cursor.deinit(self.allocator);
        self.cursor_state.deinit(self.allocator);
        self.scene_runtime.deinit();
        self.property_tree.deinit();
        self.display_list.deinit();
        self.bulk_quads.deinit(self.allocator); // 批量层（析出实现见 core/bulk_quad_layer.zig）
        self.external_clip_rects.deinit(self.allocator);
        self.text_blob_store.deinit();
        self.layer_tree.deinit();
        a11y_macos_bridge_mod.clearActiveContextForOwner(cx_platform.a11yWindowKey(self), self);
        self.accessibility_tree.deinit();
        self.a11y_label_buf.deinit(self.allocator);
        self.gesture_arena.deinit();
        // v0.5-P3 N-2 (2026-05-03): 在 world.deinit 之前清 cx_world_hooks.g_active_world，
        // 避免后续 test 的 Node.create hook 看到 stale ptr 触发 UAF。
        if (cx_world_hooks.g_active_world == &self.world) {
            cx_world_hooks.g_active_world = null;
            cx_world_hooks.g_active_world_id = core_node.INVALID_WORLD_ID;
        }
        if (g_live_cx_count > 0) g_live_cx_count -= 1;
        self.world.deinit();
        self.interaction_index.deinit();
        self.node_registry.deinit();
        self.deferred_scheduler.deinit();
        self.inspector.deinitTraceStore(self.allocator);
        self.frame_arena.deinit();
        self.lowering.deinit(self.allocator);

        // intrinsic cache 释放
        layout_engine.disableIntrinsicCache();

        self.owner.deinit();
        // 最后才释放：上面销毁 root scope / 节点树时，组件（如编辑器）的 deinit 仍会注销回调。
        self.after_layout_hooks.deinit(self.allocator);
        self.after_layout_hooks = .{};
        const allocator = self.allocator;
        allocator.destroy(self);
        lifetime_token.release();
    }

    /// 保留模式: 销毁当前 UI 树和 root_scope
    pub fn unmount(self: *Cx) void {
        self.cancelPointerInteractions(.window_blur);
        self.cursor_override = null;
        // unmount 直接清空 focus 指针而不触发组件 blur；由 session owner
        // 原子地 discard + disable，避免新树继承旧编辑器的 marked text。
        cx_platform.deactivateTextInputSession(self);
        // 焦点悬垂指针必须在释放树**之前**清掉——递归 freeNode 过程中的任何
        // 焦点查询都可能解引用已释放节点（下游应用）。
        self.focus_manager.current_focus = null;
        self.focus_manager.current_focus_handle = null;
        if (self.root_scope) |rs| {
            if (self.root) |r| {
                hooks_mod.invalidateSubtreeHookState(r);
                clearNodeScopes(r);
            }
            if (!rs.disposed) rs.dispose();
            self.root_scope = null;
        }
        if (self.root) |r| {
            self.freeNode(r);
            self.root = null;
        }
        self.popover_portal_root = null;
        self.current_scope = null;
        self.is_mounted = false;
        // 释放 StateStore — 销毁所有 Welcome 页面组件状态（含内部 HashMap/ArrayList）
        self.state_store.deinit();
        self.state_store = widget_state_mod.StateStore.init(self.allocator);
        // 重置 OverlayStack
        self.overlay_stack.clear();
        // 重置 EventDispatcher — 清除指向已销毁节点的悬空指针
        self.dispatcher.clearPersistentState();
        // 重置 FocusManager — 清除指向已销毁节点的悬空指针
        self.focus_manager.current_focus = null;
        self.focus_manager.current_focus_handle = null;
        self.focus_manager.focus_order.clearRetainingCapacity();
        self.focus_manager.scope_count = 0;
        self.focus_manager.scope_stack = [_]?*Node{null} ** 64;
        self.focus_manager.scope_stack_handles = [_]?NodeHandle{null} ** 64;
        self.focus_manager.scope_memory = [_]?u32{null} ** 64;
        self.focus_manager.scope_memory_handles = [_]?NodeHandle{null} ** 64;
        // 重置 Cx 自身持有的节点状态字段
        self.pressed_node = null;
        self.pressed_handle = null;
        self.hovered_node = null;
        self.hovered_handle = null;
        self.drag_hover_handle = null;
        self.focused_node = null;
        self.focused_handle = null;
        self.last_mouse_down_target = null;
        self.last_mouse_down_handle = null;
        self.node_registry.clear();
        self.interaction_index.clear();
    }

    /// 返回窗口级 overlay portal；standalone Cx 宿主未预建时会在
    /// `root` 下自动补建。这使 Popover/Tooltip 没有 inline fallback：
    /// floating content 的 containing block 永远是 viewport 级 portal。
    pub fn ensurePopoverPortalRoot(self: *Cx) !*Node {
        if (self.popover_portal_root) |portal| {
            self.checkPopoverPortalAncestry(portal);
            return portal;
        }
        const root_node = self.root orelse return error.RootUnavailable;

        const portal = try box(self, .{
            .position = .absolute,
            .width = .{ .grow = .{} },
            .height = .{ .grow = .{} },
        }, .{});
        // 不能用 portal.destroy：Node.destroy 不回收 ElementTable slot，也不清
        // Cx 裸引用 —— 每次失败漏一个 element slot。portal 此时必然游离。
        errdefer self.destroyDetached(portal);
        portal.meta.ownership.meta.component_name = "WindowOverlayPortal";
        // ensureExt 是不可失败版（内部 `catch @panic("OOM: StyleExt")`）——
        // 在这个已经返回 !*Node 的函数里用它，等于把一次可传播的分配失败
        // 变成整个进程 abort。消费方下游编辑器对 MdEditor.mount 做逐分配点
        // OOM 注入时实测：signal 6，栈顶就是这一行。改用 fallible 版本传播出去。
        (try portal.style.ensureExtFallible(self.allocator)).z_index = WINDOW_PORTAL_Z_INDEX;
        try root_node.appendChild(self.allocator, portal);
        self.popover_portal_root = portal;
        self.checkPopoverPortalAncestry(portal);
        return portal;
    }

    /// Debug 断言（只 log.err，不 panic）：portal 是"画到所有容器外"的唯一机制，
    /// 它自己的祖先链上若有 overflow_hidden 或 effect surface（opacity<1 /
    /// composited_group / backdrop blur / will_change），挂进去的浮层照样会被裁剪
    /// 或困在那张 surface 里 —— z_index 不会让它们逃逸（方案 §6 步骤 2）。
    /// 每个 portal 节点只在首次经由 ensurePopoverPortalRoot 取用时检查一次。
    fn checkPopoverPortalAncestry(self: *Cx, portal: *Node) void {
        if (builtin.mode != .Debug) return;
        if (self.popover_portal_ancestry_checked_id == portal.id) return;
        self.popover_portal_ancestry_checked_id = portal.id;
        var current = portal.parent;
        while (current) |ancestor| : (current = ancestor.parent) {
            // 树根就是窗口表面：它的裁剪区等于视口，任何浮层本来就被视口裁剪，不是"逃不出容器"。
            // （borderless 窗口根为圆角带 overflow_hidden；挂载期候选根尚未发布为 cx.root，同样是链顶。）
            if (ancestor.parent == null) break;
            const clips = ancestor.style.overflow_hidden;
            const effect_surface = ancestor.getOpacity() < 0.999 or
                ancestor.style.composited_group() or
                ancestor.style.backdrop_blur() >= 0.5 or
                ancestor.style.will_change_opacity() or
                ancestor.style.will_change_transform();
            if (clips or effect_surface) {
                std.log.err(
                    "popover portal (node {d}) has a clipping/effect-surface ancestor (node {d}, component={s}, overflow_hidden={}, effect_surface={}); overlays mounted in it will be clipped by that ancestor",
                    .{ portal.id, ancestor.id, ancestor.meta.ownership.meta.component_name orelse "?", clips, effect_surface },
                );
                return;
            }
        }
    }

    /// 请求下一帧重绘 (R4a)
    /// 动画钩子、外部事件等调用此方法标记需要重绘。
    pub fn requestRedraw(self: *Cx) void {
        self.needs_redraw = true;
    }

    /// 替换本帧的批量矩形层（见 `BulkQuad`）。内部拷贝一份，调用方可立即
    /// 复用/释放 `quads`。传空切片即关闭该层。
    ///
    /// `anchor` 决定这批矩形的**层级与裁剪**：
    ///   - 传某个 Node（典型：画布/视口容器）⇒ 这批矩形画在该 Node 的内容
    ///     位置上、并受该 Node 的 clip 裁剪。于是它表现得和该 Node 的普通
    ///     子内容完全一致：**该 Node 之后的兄弟（侧栏 / inspector / 工具栏 /
    ///     overlay / modal）照常盖在它之上**，超出该 Node 的部分被裁掉。
    ///     绝大多数宿主要的是这个。
    ///   - 传 null ⇒ 退化为旧行为：画在整棵 Node 树之上、不裁剪。只适合
    ///     真正的全屏 overlay。
    ///
    /// 注意 `anchor` 只提供层级锚点与 clip 来源，**不改变坐标语义**——
    /// BulkQuad 的 x/y 始终是绝对视口坐标，不会被 anchor 的 transform 再变换。
    ///
    /// 生命周期（显式契约，不要依赖隐式行为）：
    ///   - 提交的数据**跨帧保留**，直到宿主下次调用本函数覆盖它。zenit 不会
    ///     在消费后自动清空，因此宿主跳过某帧的提交不会导致批量层消失。
    ///   - 失效条件只有两个：(a) 宿主再次调用本函数（含传空切片关闭该层）；
    ///     (b) `Cx.deinit`。
    ///   - `anchor` 是裸 `*Node`：宿主**应当**在锚点节点被销毁/重建前重新调用
    ///     本函数（传新锚点或传 null/空切片）。锚点节点在 display list 里没有
    ///     任何 item 时（自身无背景 + 子内容全降级）层级仍然正确——见
    ///     锚点子树三级回退（bulk_quad_layer.zig 的 `insertPoint`）。
    ///   - 兜底：锚点子树若经 `detachChild` / `freeNode` / scope dispose 销毁，
    ///     `invalidateReferencesToEx` 会自动清掉锚点**并关闭该层**。宿主漏掉
    ///     重新提交不会变成 use-after-free，只会少画这一层，直到下次提交。
    ///     （曾经只有契约没有兜底：下游应用 goHome 摘掉画布子树后 applySnapshot
    ///     在 homepage 屏早退不再提交，锚点悬垂 ⇒ Cx.render 解引用已释放节点
    ///     ⇒ SIGSEGV。）
    ///
    /// 层级契约（底 → 顶）：画布静态内容（Node 大对象 + 批量层小对象）
    /// → 画布交互叠加（选择框 / handles / 尺寸标签 / hover / snap 线）
    /// → UI chrome → overlay/modal。批量层属于第一层；要让画布**内部**的
    /// 交互叠加压住它，用 `setBulkQuadsEx` 传 `overlay_z_threshold`。
    ///
    /// 非空的批量层会让本帧**跳过零脏帧快速路径**：这批矩形由宿主每帧重新
    /// 提交，zenit 不做跨帧 diff，无从判断内容是否变化，只能保守重画。
    /// （宿主若能自证内容未变，应当自己不调用本函数——那样零脏帧路径照常生效。）
    pub fn setBulkQuads(self: *Cx, anchor: ?*Node, quads: []const BulkQuad) !void {
        return cx_bulk_quads.setBulkQuads(self, anchor, quads);
    }
    /// `setBulkQuads` + 交互叠加阈值。`overlay_z_threshold` 声明锚点子树里
    /// 哪些子节点属于**画布交互叠加**（选择框 / resize handles / 尺寸标签 /
    /// hover 高亮 / snap 线）：z_index ≥ 阈值的节点及其子树算叠加，批量层
    /// 插到它们**之前**，于是叠加照常盖在批量矩形之上。
    ///
    /// 不传（或用 `setBulkQuads`）⇒ 整棵锚点子树都算静态内容，批量层插在
    /// 子树全部内容之后——此时任何画布内叠加都会被批量矩形盖住（这正是
    /// "选择手柄/尺寸标签被批量层压住"那个 bug）。
    /// `setBulkQuadsEx` + **内容版本号**。
    ///
    /// 宿主用 `version` 声明"这批 quad 的内容"：版本与上一帧相同 ⇒ zenit 可以
    /// 认定批量层未变，于是零脏帧快速路径继续成立。
    ///
    /// 为什么需要它：批量层由宿主每帧重新提交，zenit 不做跨帧 diff，因此
    /// **只要存在批量层就必须保守重画**（见 render 的 fast-path 条件）。
    /// 在两万+ quad 的画布上这意味着每帧重跑整个 paint pass 重建整份
    /// display list —— 实测 render_gen 21.6ms/帧，占整帧 70%，而 GPU 只用了
    /// 6.3ms。宿主自己知道内容变没变（对象几何/颜色/可视集是否变化），
    /// 把这个信息传下来，静止画面就能回到零脏帧。
    ///
    /// 语义：`version` 单调变化即可（宿主自增或用 hash）；传 `null` 表示
    /// "无法自证"，退化为原来的保守重画。
    pub fn setBulkQuadsVersioned(
        self: *Cx,
        anchor: ?*Node,
        quads: []const BulkQuad,
        overlay_z_threshold: ?i16,
        version: ?u64,
    ) !void {
        return cx_bulk_quads.setBulkQuadsVersioned(self, anchor, quads, overlay_z_threshold, version);
    }

    pub fn setBulkQuadsEx(self: *Cx, anchor: ?*Node, quads: []const BulkQuad, overlay_z_threshold: ?i16) !void {
        return cx_bulk_quads.setBulkQuadsEx(self, anchor, quads, overlay_z_threshold);
    }

    /// 设置/清除某个 Node 的外部裁剪矩形（视口系；见 `external_clip_rects`
    /// 字段注释）。子树整体受裁；与节点自身 overflow clip 取交。
    /// 值变化才请求重画 —— 宿主逐帧全量重标注是常态，不能帧帧触发重画。
    pub fn setNodeExternalClipRect(self: *Cx, node_id: u32, rect: ?[4]f32) void {
        return cx_bulk_quads.setNodeExternalClipRect(self, node_id, rect);
    }

    /// 在 target node 上注册 gesture recognizer。返回的 u32 是
    /// recognizer id，可用于 cx.gesture_arena.requireFailure 建立 A 必须 B failed
    /// 才 began 的关系。
    /// callback 在 GestureArena state 转换 (possible→began/changed/ended/failed) 时
    /// 触发，ctx 透传给 callback。target node 销毁后 recognizer 不会自动 unregister，
    /// caller 需要在 scope dispose 时清理（或直接复用 ElementId 检查 SlotMap）。
    pub fn registerGesture(
        self: *Cx,
        target: *Node,
        kind: gesture_input.GestureKind,
        config: gesture_input.Recognizer.Config,
        callback: gesture_input.GestureCallback,
        ctx: ?*anyopaque,
    ) !u32 {
        const elem_id = element_id.ElementId.fromRaw(target.element_id_raw);
        return self.gesture_arena.addRecognizer(.{
            .kind = kind,
            .target = elem_id,
            .config = config,
            .callback = callback,
            .ctx = ctx,
        });
    }

    /// cx.shapeText 入参。font_family 当前必须是 FontSystem 已知的家族字符串。
    pub const ShapeTextOpts = text_shaping.ShapeTextOpts;

    /// 挂载系统 SDK（用于剪贴板、对话框、系统事件等）
    /// 多窗口调用方须先绑定窗口身份，再挂 SDK；逻辑/原生 ID 不同用 setWindowIdentity。
    pub fn setSystemSdk(self: *Cx, sdk: *system_sdk_mod.SystemSdk) void {
        return cx_platform.setSystemSdk(self, sdk);
    }

    pub fn setWindowId(self: *Cx, window_id: system_sdk_mod.events.WindowId) void {
        return cx_platform.setWindowId(self, window_id);
    }

    /// Bind SDK routing and native callback identities together, before attaching
    /// the SDK. Retain the native key for cleanup even after SDK unregistration.
    pub fn setWindowIdentity(self: *Cx, window_id: system_sdk_mod.events.WindowId, native_window_id: u32) void {
        return cx_platform.setWindowIdentity(self, window_id, native_window_id);
    }

    pub fn clearSystemSdk(self: *Cx) void {
        return cx_platform.clearSystemSdk(self);
    }

    /// Reconcile logical focus with the one native NSTextInputContext owned by
    /// this window. This is intentionally public for controls which switch
    /// between passive/editable modes without changing focus.
    pub fn refreshTextInputSession(self: *Cx) void {
        return cx_platform.refreshTextInputSession(self);
    }

    pub fn announceAccessibilityText(self: *Cx, announce_text: []const u8) void {
        return cx_platform.announceAccessibilityText(self, announce_text);
    }

    pub fn notifyAccessibilityPropertyChange(self: *Cx, node: *Node) void {
        return cx_platform.notifyAccessibilityPropertyChange(self, node);
    }

    /// 更新 IME 候选框锚点（窗口逻辑像素，左上原点）
    pub fn setImeCursorRect(self: *Cx, x: f32, y: f32, width: f32, height: f32) bool {
        return cx_platform.setImeCursorRect(self, x, y, width, height);
    }

    // ── 文本能力：状态与实现都在 self.text（core/text_context.zig）──────
    // 这些不是转发壳：它们是 Cx 对外的文本 API，只是状态不再平铺在 Cx 上。
    // 需要直接操作子系统时用 cx.text.*（例如 cx.text.measure_ctx_fn = ...）。

    /// 给 text_core.WrapMap 等接受擦除上下文指针的 API 用的回调适配器。
    ///
    /// ⚠ context 必须是 `*Cx`（不是 `*TextContext`）—— 既有调用点传的都是 cx。
    pub fn measureTextWidthCallback(
        context: *anyopaque,
        text_ptr: [*]const u8,
        text_len: usize,
        font_size: f32,
        font_weight: u16,
        italic: bool,
    ) f32 {
        return cx_platform.measureTextWidthCallback(context, text_ptr, text_len, font_size, font_weight, italic);
    }

    pub fn invalidateReferencesToEx(self: *Cx, subtree_root: *Node, unregister: bool) void {
        return cx_node_lifetime.invalidateReferencesToEx(self, subtree_root, unregister);
    }

    /// 语义：节点 *即将销毁* — 清 state + 从 registry 摘除。
    /// detachChild/freeNode 等真正摘除节点的路径用这个。
    pub fn invalidateReferencesTo(self: *Cx, subtree_root: *Node) void {
        return cx_node_lifetime.invalidateReferencesTo(self, subtree_root);
    }

    /// mount 成功但**还没上树**的子树的唯一合法销毁入口。
    ///
    /// 由来（下游编辑器第126–129轮 OOM 注入）：组件 `mountResult` 返回一棵游离子树，
    /// 调用方在 `panel.appendChild(im.node)` 失败时想回收它。三种拼装全部在**全量
    /// sweep** 里 SIGABRT（单点注入却是干净的），因为它们都把「释放内存」提前到了
    /// teardown 的失效/注销扫描之前，或者反过来抢先 clearNodeScopes 把该跑的失效
    /// 整段跳过：
    ///   - `freeNode(node)`                       → 不清 cx 引用/注销登记
    ///   - `freeDetachedNodeAfterScopeDispose(n)` → clearNodeScopes 抢跑，binding.destroy
    ///                                              退化成 no-op，失效整层被跳过
    ///   - 组件自写 abandon（先 clear 再 free）   → 同上，且比前者少跑一层
    ///
    /// 不变量：**所有失效/注销必须在节点内存仍存活时跑完，之后才允许释放内存。**
    /// 这里按该顺序固定下来，调用方不需要（也不应该）自己拼装：
    ///   ① invalidateReferencesTo：清掉 cx 侧指向子树各节点的引用与注销登记
    ///      （此时树完整，isDescendantOf 沿 parent 链的遍历安全）
    ///   ② freeNode：内部按子树递归 unregisterFocusableSilent / clearNodeScopes /
    ///      dispose 绑定 scope，最后才释放内存
    ///
    /// 前置条件：`node` 必须**没有 parent**（游离）。已上树的节点走 detachChild。
    ///
    /// 覆盖面对账（交叉 review 指出「泄漏 sweep 看不见悬垂指针，
    /// invalidateReferencesTo 的覆盖面本身没有不变量保护」，故逐项核对）：
    /// Cx 上的 *Node 字段共 7 个 —— focused_node / hovered_node / pressed_node /
    /// last_mouse_down_target / bulk_quads_anchor 五个由 invalidateReferencesToEx
    /// 显式清空；root 与 popover_portal_root 是生命周期根，不会落在被销毁的子树里。
    /// 其余按 node 索引的引用统一走 node_registry（handle + 代次校验，
    /// 释放后查表失败而不是读悬垂内存）。
    /// **新增 Cx 上的 *Node 字段时，必须同步在 invalidateReferencesToEx 里清它。**
    pub fn destroyDetached(self: *Cx, node: *Node) void {
        return cx_node_lifetime.destroyDetached(self, node);
    }

    pub fn detachChild(self: *Cx, parent: *Node, child: *Node) void {
        return cx_node_lifetime.detachChild(self, parent, child);
    }

    pub fn detachChildRetained(self: *Cx, parent: *Node, child: *Node) void {
        return cx_node_lifetime.detachChildRetained(self, parent, child);
    }

    pub fn freeNode(self: *Cx, node: *Node) void {
        return cx_node_lifetime.freeNode(self, node);
    }

    /// 把一份"节点释放之后才能释放"的资源排进与 freeNode **同一条**延迟队列。
    ///
    /// 场景：消费方（Global Find 的 EditorPool）逐出 / 销毁 slot 时 `freeNode(editor)`，节点在
    /// reactive / tick 深度里只是排队、仍借用一份文档；文档不能立刻释放（UAF），消费方结构又可能
    /// 马上消失，无处暂存。此前只能故意泄漏。
    ///
    /// 路由与 freeNode **逐字一致**（reactive 深度 → owner 队列；否则 tick 深度 → deferred_free_nodes；
    /// 都不在 → 当场执行）。用法契约：**紧跟在对应的 freeNode 之后调用**——两者在同一时刻按同一组
    /// 深度计数路由，必然落进同一条 FIFO 队列，节点在前、资源在后。若节点早先已在别的语境里排过队
    ///（freeNode 早退），这条契约不再成立，调用方要自己兜底（EditorPool 用 pending_docs + 帧末回收）。
    /// 交叉审查指出过"tick 优先"的另一种路由在 reactive 嵌在 tick 里 / tick 嵌在回调里
    /// 两种嵌套下各有一条先释放文档的序列——只有"同队列相邻"才不依赖两条队列的 drain 顺序。
    /// `entry` 的存储归资源自己，直到回调跑完。
    pub fn deferDisposalLikeFreeNode(
        self: *Cx,
        entry: *@import("reactive/deferred_disposal.zig").Entry,
        ptr: *anyopaque,
        dispose_fn: *const fn (*anyopaque) void,
    ) void {
        return cx_node_lifetime.deferDisposalLikeFreeNode(self, entry, ptr, dispose_fn);
    }

    /// 释放已从 UI 树分离、且其子 scope 可能已被祖先 scope.dispose() 释放的节点树。
    /// 这类子树上的 node.ownership.scope.scope 可能仍是悬垂指针，必须先清空回指再递归 freeNode。
    ///
    /// 关键顺序：**先 invalidateSubtreeHookState 再 clearNodeScopes**。
    /// invalidate 把双向 link 断开（既清 node.hooks.slots.animated_bg_state，也把
    /// anim_state.node 设为 null）。clearNodeScopes 只清单向 node→ptr，所以
    /// 反序时 invalidate 看到 node.hooks.slots.animated_bg_state == null 直接跳过，
    /// 留下的 anim_state 仍持有悬垂 node 指针，等会儿 hook scope dispose
    /// 调它的 destroyFn 就 deref 已释放节点 → SEGV。
    /// 登记一个由 Cx 兜底释放的组件内存（见 OwnedCell / ScrollCtxCell）。
    pub fn registerScrollCtxCell(self: *Cx, cell: OwnedCell) !void {
        return cx_node_lifetime.registerScrollCtxCell(self, cell);
    }

    pub fn freeDetachedNodeAfterScopeDispose(self: *Cx, node: *Node) void {
        return cx_node_lifetime.freeDetachedNodeAfterScopeDispose(self, node);
    }

    /// 将 Scope 与节点绑定，并在 Scope dispose 时自动清空 node.ownership.scope.scope，
    /// 避免调用方提前 dispose 后留下悬垂指针。
    /// ⚠️ 所有权语义（下游编辑器交叉 review 逼出来的查证结论，别再猜）：
    /// 这里登记的 ScopeBinding.destroy **只做解绑，从不释放节点**
    /// （invalidateSubtreeHookState + clearNodeScopes，没有 freeNode）。
    /// 而 `node_slot = &binding.node` 让 clearNodeScopes 的 `slot.* = null`
    /// 直接写进这份登记 —— 所以节点先被释放时，这条登记会退化成 no-op。
    ///
    /// 结论：**「errdefer 释放了节点、之后 scope dispose 再释放一次」这个
    /// 双重释放形态在本框架不成立** —— 不是因为"解绑了指针"（那不够，
    /// 摘登记才算数），而是因为**这条登记本身就不负责释放**。
    pub fn bindScopeToNode(scope: *Scope, node: *Node) !void {
        return cx_node_lifetime.bindScopeToNode(scope, node);
    }

    // ---- ID 生成 ----

    pub fn nextId(self: *Cx) u32 {
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }

    /// 把 Node 注册到 World.elements 表。
    /// builders 在 Node.create 后调一次；node.element_id_raw 被设置。
    /// 失败（OOM / table full）不致命——node 仍可运行旧路径。
    pub fn linkNodeToWorld(self: *Cx, node: *Node) void {
        return cx_world_sync.linkNodeToWorld(self, node);
    }

    // v0.5-P3 stage 1（2026-04-30）：删 linkParentChild 死 helper。
    // 当时设计为 builders 在 appendChild 调用以维护 World.elements 的父子链，但从未被
    // 任何 caller 调用——World.elements 因此只有扁平节点列表无 tree structure。下游
    // 消费方（render_engine / layout_engine 等）也未读 World.elements 的 children，
    // 整条 shadow 路径不完整。Stage 2+ 真接入主路径时再重建。

    pub fn layerizeFrame(self: *Cx, extra_hints: []const layerize_mod.LayerizeInput) u32 {
        return cx_world_sync.layerizeFrame(self, extra_hints);
    }

    // v0.5-P3 stage 3-1（2026-05-01）：syncLayoutToTable revived as **真 shadow write**。
    // 在每次 layoutNode 之后调用，把 Node.rect 同步到 LayoutTable.final_rect。
    // 让 LayoutTable 成为 secondary view，允许下游 paint pass 渐进迁移读路径。
    // 真切换主路径（LayoutTable 作 source-of-truth + Node.rect 删除）需后续 stage。

    /// 把 Node 树的 rect 同步到 LayoutTable（shadow write，layout 之后调一次）。
    /// Ensure every node in the tree has a LayoutTable slot.
    ///
    /// The walk is disabled because it cannot do anything. Three facts, each
    /// checked against the code rather than assumed:
    ///
    ///  1. `World.createElement` (world.zig) calls `layout.ensureSlot(id)` for
    ///     every id it hands out, and it is the only way to get an ElementId —
    ///     `linkNodeToWorld` below, the builder in node_lifecycle.zig, and Cx's
    ///     own registration all route through it.
    ///  2. Slots are never reclaimed. `World.destroyElement` calls
    ///     `layout.clear(id)`, which does `items.set(index, .{})` — it zeroes
    ///     the entry and leaves the array length alone, with the comment
    ///     "layout / paint 槽不立即回收（保持 dense by index）". So an index
    ///     that was ever covered stays covered.
    ///  3. Recycled ids reuse an existing index (generation bump), so they
    ///     cannot need a slot that was never allocated.
    ///
    /// Together: `ensureSlot` here is always a no-op. There are eight call
    /// sites (grep this file); most are gated on `had_dirty`, but at least one
    /// runs unconditionally every frame, and each one that fires walks the
    /// entire node tree. On a markdown document with code blocks, tables and
    /// images that is thousands of pointer-chases for zero effect. The saving
    /// is modest on its own — the point is that it is free.
    ///
    /// Kept behind a flag rather than deleted: a caller that hand-builds
    /// elements outside `createElement` would break fact 1, and flipping this
    /// back is the fastest way to test that hypothesis.
    pub fn syncLayoutToTable(self: *Cx, root: *Node) void {
        return cx_world_sync.syncLayoutToTable(self, root);
    }

    /// v0.5-P3 N-2 (2026-05-03 字段已删): syncNodeRect 退化为 ensureSlot helper.
    /// frame_state.rect 字段已删；layout pass 通过 setLayoutRect 实时写 World，
    /// 不再需要"扫树同步"。此 fn 保留是为了不破公开 API + 给 ScrollArea 等组件
    /// 一个 ensureSlot 入口（确保 layout 表里有 slot 可写）。
    pub fn syncNodeRect(self: *Cx, node: *Node) void {
        return cx_world_sync.syncNodeRect(self, node);
    }

    // v0.5-P3 Stage 3-3（2026-05-02）：syncPaintToTable —— paint pass 出口 shadow-sync。
    // 在 render_engine.renderNode 完成后调用：每个有 element_id 的节点，根据
    // node.style.background_color + border + text 计算 content_hash（lightweight），
    // 命中即跳过；不命中则 begin/end record 一个 chunk。Phase 1 不真填 display_items，
    // 只验证 PaintTable.beginRecord/endRecord/content_hash invalidation 路径走通。
    // bounds 暂用 node.rect 转 paint_table.Bounds。Phase 2 起 mirror 真 display_items。

    /// 把 Node 树的 paint props 同步到 PaintTable（shadow write，render 之后调一次）。
    pub fn syncPaintToTable(self: *Cx, root: *Node) void {
        return cx_world_sync.syncPaintToTable(self, root);
    }

    // cx 内的 mapDisplayItem + colorToRGBA +
    // radiusArrayToCorners 已合并到 gpu_draw_shadow.lowerDisplayItem (那是
    // 唯一的 display_list → paint_table 映射点)。callsite 见 syncPaintToTable。

    // v0.5-P3 Stage 3-4（2026-05-02）：syncInteractionToTable —— 把 focus + events
    // 信号 shadow-sync 到 InteractionTable。每节点取 node.interaction.focusable / tab_index、
    // 监听 mask（events 是否非空作为粗 mask）、a11y role。
    //
    // 注：InteractionTable 是 sparse，仅当 focusable || a11y || 任意 event handler 存在时才 put。
    pub fn syncInteractionToTable(self: *Cx, root: *Node) void {
        return cx_world_sync.syncInteractionToTable(self, root);
    }

    // ========================================================================
    // Accessibility Tree 投影
    // ------------------------------------------------------------------------
    // 把 Node 树 (behavior.interaction.a11y + focusable) 投影成 A11yNode 流到
    // cx.accessibility_tree。upsert 自动 diff + 标 dirty；下一步 (§2.4) cx.render()
    // 末尾会调 a11y_router.flushToBridge 把 dirty 推到 macOS NSAccessibility。
    //
    // 投影策略：
    // - 节点有 a11y props (role != .none) → 投影为该 role
    // - 节点 focusable 但无 a11y props → 投影为 .generic 容器（VoiceOver 仍可 tab 到）
    // - 节点无 a11y 也不 focusable → 不投影（保持 tree sparse；VoiceOver 跳过纯视觉容器）
    // - label 取 a11y.label，缺省 fall back 到子树第一个 text node 的 content（与
    //   focus.zig a11ySnapshotForNode 行为一致）
    //
    // 不维护层级裁剪：a11y_tree parent = element 树上**最近的已投影祖先**，
    // 不一定是 element parent。这样 button 包 text 时只投 button，text 内容作 label。
    pub fn syncA11yTreeFromInteractions(self: *Cx, root: *Node) void {
        return cx_a11y.syncA11yTreeFromInteractions(self, root);
    }

    // 整树校验 LayoutTable 与 Node.rect 严格一致。
    // SoT inversion 前的健康检查 —— 任何 sync miss 都让此函数返回 false。
    // 用法：debug build 内 layout/render 末尾调一次；prod build 不调。
    pub fn assertLayoutSyncIntegrity(self: *Cx, root: *Node) bool {
        return cx_world_sync.assertLayoutSyncIntegrity(self, root);
    }

    // v0.3-P3 ElementId first-class API（让 ElementId 与 *Node 双 API 并存；
    // 新代码鼓励用 ElementId，旧代码 *Node 兼容）

    /// 通过 ElementId 取 LayoutTable rect（v0.3 起 paint pass 应当走此路径）
    pub fn rectOf(self: *Cx, id: world.ElementId) ?layout_table.Rect {
        return self.world.layout.rect(id);
    }

    // ---- 状态访问 ----

    /// 获取或创建组件状态
    pub fn state(self: *Cx, comptime T: type, id: u64, initial: T) !*T {
        return self.state_store.getOrCreate(T, id, initial);
    }

    /// 创建匿名状态 — 由 cx 持有所有权，返回稳定的 `*T` 指针。
    ///
    /// 推荐路径，适合大多数应用：
    /// ```
    /// const counter = try cx.bindState(Counter, .{ .n = 0 });
    /// const click = cx.on(Counter, counter, Counter.increment);
    /// ```
    ///
    /// 与 `cx.state(T, id, init)` 的区别：用户不需要分配 u64 id。每次调用
    /// 创建一个新条目；不能跨 mount 再取回（要那种语义请用 `state(...)` 加显式 id）。
    ///
    /// 警告：匿名 id 按调用顺序从 `u64` 最大值向下递减分配，仅在单次 mount
    /// 内有效——同一状态无法在下次 mount 或其它调用点凭 id 取回。需要持久
    /// 或可寻址的 state，请改用 `cx.state(T, id, init)` 并自行分配显式 id。
    pub fn bindState(self: *Cx, comptime T: type, initial: T) !*T {
        const id = self.next_anon_state_id;
        self.next_anon_state_id -= 1;
        return self.state_store.getOrCreate(T, id, initial);
    }

    /// 类型安全 handler 的简洁形式 — 直接传 `*State` 而不是 `(Type, id)`。
    ///
    /// 与 `cx.handler` 等价但不查 state_store。配合 `cx.bindState` 使用。
    pub fn on(_: *Cx, comptime State: type, s: *State, comptime method: *const fn (*State) void) HandlerRef {
        return handlerFrom(State, s, method);
    }

    /// 获取已存在的组件状态
    pub fn getState(self: *Cx, comptime T: type, id: u64) ?*T {
        return self.state_store.get(T, id);
    }

    /// 获取已存在的组件状态，不存在则返回错误
    pub fn requireState(self: *Cx, comptime T: type, id: u64) !*T {
        return self.getState(T, id) orelse error.StateNotFound;
    }

    /// 创建 Signal
    pub fn createSignal(self: *Cx, comptime T: type, initial: T) !*Signal(T) {
        return Signal(T).create(self.owner, initial);
    }

    /// 创建 Memo (缓存的派生计算)
    pub fn memo(self: *Cx, comptime T: type, context: anytype, comptime computeFn: anytype) !*Memo(T) {
        return createMemo(self.owner, T, context, computeFn);
    }

    // ---- Context API ----

    /// 提供上下文值 (组件树内任意深度可访问)
    pub fn provide(self: *Cx, comptime T: type, value: *T) !void {
        const scope = try self.ensureRootScope();
        const ContextT = reactive.Context(T);
        try ContextT.provide(scope, value);
    }

    /// 消费上下文值
    pub fn consume(self: *Cx, comptime T: type) ?*T {
        const scope = self.root_scope orelse return null;
        const ContextT = reactive.Context(T);
        return ContextT.consume(scope);
    }

    pub fn contextCount(self: *const Cx) usize {
        const scope = self.root_scope orelse return 0;
        return scope.context_count;
    }

    fn ensureRootScope(self: *Cx) !*Scope {
        if (self.root_scope) |scope| return scope;
        const root_scope = try Scope.init(self.allocator, null, self.owner);
        self.root_scope = root_scope;
        return root_scope;
    }

    // ---- 类型安全 handler ----

    /// 创建类型安全的事件 handler
    /// 用法: try cx.handler(AppState, state_id, AppState.increment)
    pub fn handler(self: *Cx, comptime State: type, id: u64, comptime method: *const fn (*State) void) !HandlerRef {
        const s = try self.requireState(State, id);
        return handlerFrom(State, s, method);
    }

    /// 从已有指针创建 handler
    pub fn handlerFrom(comptime State: type, s: *State, comptime method: *const fn (*State) void) HandlerRef {
        return .{
            .callback = struct {
                fn invoke(ctx: *anyopaque) void {
                    const typed: *State = @ptrCast(@alignCast(ctx));
                    method(typed);
                }
            }.invoke,
            .context = s,
        };
    }

    /// 创建简单 handler（直接绑定裸指针上下文）
    pub fn simpleHandler(callback: EventCallback, context: *anyopaque) HandlerRef {
        return .{
            .callback = callback,
            .context = context,
        };
    }

    // ── 带值 handler（2026-07-31 回调协议并轨）─────────────────────────
    // 组件侧统一用 `?HandlerRef` 声明、用 invokeWithBool/Str 触发；
    // 调用方按需要值与否选下面两组构造器之一。详见 HandlerRef 文档。

    /// 从 state 指针 + 方法创建**带 bool 值**的 handler。
    /// 用于 Checkbox / Switch / Accordion 这类"变成了 true/false"的回调。
    pub fn boolHandlerFrom(
        comptime State: type,
        s: *State,
        comptime method: *const fn (*State, bool) void,
    ) HandlerRef {
        const Shim = struct {
            fn withValue(v: bool, ctx: *anyopaque) void {
                const typed: *State = @ptrCast(@alignCast(ctx));
                method(typed, v);
            }
            // 无参兜底：调用方拿不到值时至少还能收到"变了"这个事实。
            fn bare(ctx: *anyopaque) void {
                const typed: *State = @ptrCast(@alignCast(ctx));
                method(typed, false);
            }
        };
        return .{
            .callback = Shim.bare,
            .context = s,
            .payload_callback = .{ .boolean = Shim.withValue },
        };
    }

    /// 从 state 指针 + 方法创建**带字符串值**的 handler。
    /// 用于 Input / Textarea / Tabs / Radio 这类"变成了这个文本/这个 id"的回调。
    /// ⚠ slice 只在回调执行期间有效，需留存请 dupe。
    pub fn strHandlerFrom(
        comptime State: type,
        s: *State,
        comptime method: *const fn (*State, []const u8) void,
    ) HandlerRef {
        const Shim = struct {
            fn withValue(v: []const u8, ctx: *anyopaque) void {
                const typed: *State = @ptrCast(@alignCast(ctx));
                method(typed, v);
            }
            fn bare(ctx: *anyopaque) void {
                const typed: *State = @ptrCast(@alignCast(ctx));
                method(typed, "");
            }
        };
        return .{
            .callback = Shim.bare,
            .context = s,
            .payload_callback = .{ .string = Shim.withValue },
        };
    }

    /// 从 state 指针 + 方法创建 **drop 专用** handler：回调收到完整
    /// DropPayload（换行分隔 paths + 落点 x/y，window 坐标系）。
    /// 用于按落点摆放文件的 drop target（画布拖入）。
    /// ⚠ paths slice 只在回调执行期间有效，需留存请 dupe。
    pub fn dropHandlerFrom(
        comptime State: type,
        s: *State,
        comptime method: *const fn (*State, core_types.HandlerRef.DropPayload) void,
    ) HandlerRef {
        const Shim = struct {
            fn withValue(p: core_types.HandlerRef.DropPayload, ctx: *anyopaque) void {
                const typed: *State = @ptrCast(@alignCast(ctx));
                method(typed, p);
            }
            fn bare(ctx: *anyopaque) void {
                const typed: *State = @ptrCast(@alignCast(ctx));
                method(typed, .{ .paths = "", .x = 0, .y = 0 });
            }
        };
        return .{
            .callback = Shim.bare,
            .context = s,
            .payload_callback = .{ .drop = Shim.withValue },
        };
    }

    /// `dropHandlerFrom` 的 state_store 版本。
    pub fn dropHandler(
        self: *Cx,
        comptime State: type,
        id: u64,
        comptime method: *const fn (*State, core_types.HandlerRef.DropPayload) void,
    ) !HandlerRef {
        const s = try self.requireState(State, id);
        return dropHandlerFrom(State, s, method);
    }

    /// `boolHandlerFrom` 的 state_store 版本（对应 `cx.handler`）。
    pub fn boolHandler(
        self: *Cx,
        comptime State: type,
        id: u64,
        comptime method: *const fn (*State, bool) void,
    ) !HandlerRef {
        const s = try self.requireState(State, id);
        return boolHandlerFrom(State, s, method);
    }

    /// `strHandlerFrom` 的 state_store 版本。
    pub fn strHandler(
        self: *Cx,
        comptime State: type,
        id: u64,
        comptime method: *const fn (*State, []const u8) void,
    ) !HandlerRef {
        const s = try self.requireState(State, id);
        return strHandlerFrom(State, s, method);
    }

    // ---- 视口 ----

    pub fn setWindowMetrics(self: *Cx, width: f32, height: f32, scale: f32) void {
        self.viewport = Size.init(width, height);
        self.window_scale = if (scale > 0) scale else 1.0;
        self.needs_redraw = true;
        if (self.root) |r| {
            r.markLayoutDirty();
        }
    }

    /// 便捷入口：只改视口尺寸，scale 取 1.0。
    ///
    /// ⚠ HiDPI 注意：本函数会把 `window_scale` **重置为 1.0**。只有在 scale
    /// 确实无关的场景（绝大多数单测）才可以用。真实窗口的 resize 路径必须走
    /// `setWindowMetrics` 并传入当前 backing scale —— 否则 Retina 下每次
    /// resize 都会把 window_scale 打回 1.0，导致 SVG 按 1x 光栅化
    /// （resolveSvgRasterSize 读的正是 window_scale）。
    pub fn setViewport(self: *Cx, width: f32, height: f32) void {
        self.setWindowMetrics(width, height, 1.0);
    }

    /// v0.9-§E (2026-05-13): 运行时切换主题。
    /// 切换后需要触发整树 markRenderDirty + markCompositeDirty，
    /// 切 token 时遍历整棵树，触发每个挂有 before_render hook
    /// 的节点重算（组件 hook 内重新读 cx.tokens 把派生 style/color 写回）。
    /// 同时对整棵树 markRenderDirty + markCompositeDirty。
    /// 没挂 hook 的节点只刷 paint state（背景色等已写入 PaintStateTable 的不会
    /// 自动更新 — 那条路径要靠 §b stage 3 Signal-driven token；当前 fallback
    /// 是 component 自己挂 before_render hook 把 token color 同步写回 node.style）。
    pub fn setTheme(self: *Cx, t: *const theme.ThemeTokens) void {
        if (self.tokens == t) return;
        self.tokens = t;
        self.theme_version +%= 1;
        if (self.theme_signal) |sig| sig.set(t);
        if (self.root) |r| {
            invokeThemeHookRecursive(r, t, self.allocator);
        }
        self.needs_redraw = true;
    }

    /// 获取（惰性创建）theme Signal。生命周期挂在传入 scope（通常 app 根 scope）；
    /// scope dispose 后 Signal 失效，caller 需保证 scope 存活期 ≥ 订阅方。
    /// ⚠️ 缓存必须随**创建它的那个 Scope**一起失效。
    ///
    /// `createSignal` 把 Signal 建在传入的 scope 上（`createInScope`），由它释放。
    /// 而 `theme_signal` 是 Cx 上的**全局**缓存 —— 第一个订阅主题的常常是某个
    /// 组件/面板的 scope（比如一个弹层）。那个面板一关（`scope.dispose()`），
    /// 缓存就指向已释放内存；下一个调用者拿到野指针，`get()` 与 `setTheme()`
    /// 都是 UAF。已写出故障复现（本文件末尾那个测试），实测 SIGSEGV
    /// 落在 `signal.get()` 的 `self.owner.assertThread()`。
    ///
    /// 修法用现成机制：往同一个 scope 登记一份资源，dispose 时把 Cx 上的缓存
    /// 清掉。这样解绑和释放天然同步，不需要给 Scope 加新的耦合。
    /// 登记排在最后一个可失败操作之后 —— 登记本身可失败，失败就别缓存，
    /// 宁可下次重建（见 [[register-must-follow-last-fallible-step]]）。
    pub fn themeSignal(self: *Cx, scope: *Scope) !*Signal(*const theme.ThemeTokens) {
        if (self.theme_signal) |sig| return sig;
        const sig = try scope.createSignal(*const theme.ThemeTokens, self.tokens);

        // ⚠️ 必须用 **onCleanup（disposeNow 第 2 步）而不是 registerResource
        // （第 5 步）**。disposeNow 的顺序是：
        //   1 子 scope → 2 cleanups → 3 effects → 4 **销毁 signals** → 5 resources
        // 用 resource 的话，解绑发生在 Signal 已经被释放**之后**，中间
        // 第 3/4 步跑的是用户回调（effect destroy 等），任何一个再调
        // themeSignal 就会命中还没清的缓存拿到野指针。
        // 这是交叉审查（glm-5.3）指出的瞬态窗口，实测顺序确认属实。
        try scope.onCleanup(Cx, self, struct {
            fn unbind(cx: *Cx) void {
                // 身份判定：只清仍指向我们这份的缓存。当前机制下缓存非空即
                // 早返回、不会被覆写，所以这条分支实际到不了；保留是因为
                // 一旦将来允许显式重建，它就是唯一能防误清的判据。
                cx.theme_signal = null;
            }
        }.unbind);

        self.theme_signal = sig;
        return sig;
    }

    fn invokeThemeHookRecursive(n: *Node, t: *const theme.ThemeTokens, allocator: std.mem.Allocator) void {
        if (n.meta.per_frame.hooks.before_render.main) |hook| {
            hook(n);
        }
        for (n.meta.per_frame.hooks.before_render.hooks[0..n.meta.per_frame.hooks.before_render.count]) |maybe| {
            if (maybe) |hook| hook(n);
        }
        // setTheme-only 主题重放（boxStyled/textStyled 具名样式函数）
        if (n.meta.per_frame.hooks.on_theme) |hook| {
            hook(n, t, allocator);
        }
        n.markRenderDirty();
        n.markCompositeDirty();
        for (n.children.items) |c| {
            invokeThemeHookRecursive(c, t, allocator);
        }
    }

    // ---- Pointer Capture ----

    pub fn setPointerCapture(self: *Cx, node: *Node) void {
        self.dispatcher.setPointerCapture(node);
        cx_cursor.updateCursorShape(self);
    }

    pub fn releasePointerCapture(self: *Cx) void {
        self.dispatcher.releasePointerCapture();
        cx_cursor.updateCursorShape(self);
    }

    // ---- 焦点管理 ----

    pub fn setFocus(self: *Cx, node: ?*Node) void {
        self.focus_manager.setFocus(node);
    }

    pub fn clearFocus(self: *Cx) void {
        self.focus_manager.clearFocus();
    }

    pub fn isFocused(self: *Cx, node: *Node) bool {
        return self.focus_manager.isFocused(node);
    }

    // ---- 事件处理 ----

    pub fn handleMouseDown(self: *Cx, x: f32, y: f32, modifiers: Modifiers) void {
        return cx_input.handleMouseDown(self, x, y, modifiers);
    }

    pub fn handleMouseDownEx(self: *Cx, x: f32, y: f32, button: MouseButton, modifiers: Modifiers) void {
        return cx_input.handleMouseDownEx(self, x, y, button, modifiers);
    }

    /// 兼容入口：不带修饰键的抬手。等价于 `handleMouseUpEx(x, y, .left, .{})`。
    /// 宿主若要 mouse_up 携带**抬手时刻**的真实修饰键，用 `handleMouseUpEx`。
    pub fn handleMouseUp(self: *Cx, x: f32, y: f32) void {
        return cx_input.handleMouseUp(self, x, y);
    }

    pub fn handleMouseUpEx(self: *Cx, x: f32, y: f32, button: MouseButton, modifiers: Modifiers) void {
        return cx_input.handleMouseUpEx(self, x, y, button, modifiers);
    }

    /// pointer capture 释放后重算 hover/cursor。原先内联在 handleMouseUpEx 的
    /// 自动释放路径里；抽出来是因为 drag 的 cancel 路径（Escape/blur/detach）
    /// 也显式释放 capture，同样需要 resync，否则光标/hover 卡在旧节点直到下次
    /// move（docs/DRAG_INTERACTION_DESIGN.md §8.4/§11.2）。
    pub fn resyncPointerAfterCaptureRelease(self: *Cx, x: f32, y: f32, fallback_handle: ?NodeHandle) void {
        return cx_input.resyncPointerAfterCaptureRelease(self, x, y, fallback_handle);
    }

    /// 兼容入口：不带修饰键的移动。等价于 `handleMouseMoveEx(x, y, .{})`。
    pub fn handleMouseMove(self: *Cx, x: f32, y: f32) void {
        return cx_input.handleMouseMove(self, x, y);
    }

    pub fn handleMouseMoveEx(self: *Cx, x: f32, y: f32, modifiers: Modifiers) void {
        return cx_input.handleMouseMoveEx(self, x, y, modifiers);
    }

    /// 统一取消进行中的 pointer 交互（drag session + gesture 识别器）。
    /// 窗口失焦、root 替换等生命周期事件由宿主/runtime 调用。pending 静默
    /// 清理，active 恰好发一次 cancel callback；幂等。
    pub fn cancelPointerInteractions(self: *Cx, reason: interaction_drag.CancelReason) void {
        return cx_input.cancelPointerInteractions(self, reason);
    }

    /// Only for the owner's exact current capture session; never for hover.
    pub fn acquireCursor(self: *Cx, owner: *Node, shape: CursorShape) !CursorToken {
        return cx_input.acquireCursor(self, owner, shape);
    }

    pub fn updateCursor(self: *Cx, token: CursorToken, shape: CursorShape) void {
        return cx_input.updateCursor(self, token, shape);
    }

    pub fn releaseCursor(self: *Cx, token: CursorToken) void {
        return cx_input.releaseCursor(self, token);
    }

    pub fn refreshCursor(self: *Cx) void {
        return cx_input.refreshCursor(self);
    }

    pub fn replayCursor(self: *Cx) void {
        return cx_input.replayCursor(self);
    }

    pub fn setCursorOverride(self: *Cx, shape: ?CursorShape) void {
        return cx_input.setCursorOverride(self, shape);
    }

    /// 激活一个自定义位图光标：SVG 按宽度 size_pt×scale 光栅化（纵横比由
    /// SVG 自身保持）为预乘 RGBA 并内容寻址缓存，随后立即尝试下发。
    /// 节点/override 上写 `CursorShape.custom` 即解析到当前激活位图 ——
    /// 本方法立即调 updateCursorShape，指针静止时换光标也当场生效
    /// （同 setCursorOverride 的立即更新语义；style.cursor 赋值本身无副作用）。
    /// 同一时刻只有一个激活位图，再次调用即切换内容。幂等：同 key 直接返回。
    pub fn setCustomCursor(self: *Cx, desc: CustomCursorDesc) void {
        return cx_input.setCustomCursor(self, desc);
    }

    /// 当前激活的自定义光标 key（e2e 探针/调试用）。未激活返回 null。
    pub fn activeCustomCursorKey(self: *const Cx) ?u64 {
        return cx_input.activeCustomCursorKey(self);
    }

    /// 更新自动化虚拟指针。`pressed=null` 保留当前按键状态，供 move/scroll
    /// 使用。该 API 不派发事件，只解析当前位置应显示的 cursor 并标记重绘。
    pub fn updateAutomationCursor(self: *Cx, x: f32, y: f32, pressed: ?bool) void {
        return cx_input.updateAutomationCursor(self, x, y, pressed);
    }

    pub fn handleClick(self: *Cx, x: f32, y: f32) void {
        return cx_input.handleClick(self, x, y);
    }

    pub fn bindCommandAction(self: *Cx, command_id: u64, action: actions_mod.Action) void {
        return cx_input.bindCommandAction(self, command_id, action);
    }

    /// Native menus and keyboard bindings converge on ActionDispatcher.
    pub fn handleCommand(self: *Cx, command_id: u64) void {
        return cx_input.handleCommand(self, command_id);
    }

    pub fn handleKeyDown(self: *Cx, key: KeyCode, modifiers: Modifiers) void {
        return cx_input.handleKeyDown(self, key, modifiers);
    }

    pub fn handleKeyUp(self: *Cx, key: KeyCode, modifiers: Modifiers) void {
        return cx_input.handleKeyUp(self, key, modifiers);
    }

    pub fn handleTextInput(self: *Cx, t: []const u8) void {
        return cx_input.handleTextInput(self, t);
    }

    pub fn handleImePreedit(self: *Cx, preedit_text: []const u8, cursor_utf8_offset: u32) void {
        return cx_input.handleImePreedit(self, preedit_text, cursor_utf8_offset);
    }

    /// 带 replacementRange（UTF-8 字节区间，相对文档；哨兵 = 无 replacement）
    /// 的 IME 预编辑入口。再変換把已提交文本拉回合成态时走这里。
    pub fn handleImePreeditReplace(
        self: *Cx,
        preedit_text: []const u8,
        cursor_utf8_offset: u32,
        replace_start_utf8: u32,
        replace_end_utf8: u32,
    ) void {
        return cx_input.handleImePreeditReplace(self, preedit_text, cursor_utf8_offset, replace_start_utf8, replace_end_utf8);
    }

    pub fn handleImeCommit(self: *Cx, commit_text: []const u8) void {
        return cx_input.handleImeCommit(self, commit_text);
    }

    /// 带 replacementRange 的 IME 提交入口；哨兵时与 handleImeCommit 等价。
    pub fn handleImeCommitReplace(
        self: *Cx,
        commit_text: []const u8,
        replace_start_utf8: u32,
        replace_end_utf8: u32,
    ) void {
        return cx_input.handleImeCommitReplace(self, commit_text, replace_start_utf8, replace_end_utf8);
    }

    pub fn handleScrollEx(
        self: *Cx,
        x: f32,
        y: f32,
        dx: f32,
        dy: f32,
        is_momentum: bool,
        phase_ended: bool,
        is_trackpad: bool,
    ) void {
        return cx_input.handleScrollEx(self, x, y, dx, dy, is_momentum, phase_ended, is_trackpad);
    }

    pub fn handleScrollWithModifiers(
        self: *Cx,
        x: f32,
        y: f32,
        dx: f32,
        dy: f32,
        is_momentum: bool,
        phase_ended: bool,
        is_trackpad: bool,
        modifiers: Modifiers,
    ) void {
        return cx_input.handleScrollWithModifiers(self, x, y, dx, dy, is_momentum, phase_ended, is_trackpad, modifiers);
    }

    /// 触控板捏合手势：按 pointer 命中派发到目标节点（沿冒泡链传播）。
    /// 手势期间目标锁定在 began 时的命中节点，避免画布缩放中内容移动导致换目标。
    pub fn handleMagnify(self: *Cx, magnification: f32, x: f32, y: f32, phase: events_mod.GesturePhase) void {
        return cx_input.handleMagnify(self, magnification, x, y, phase);
    }

    /// 拖放事件：按 pointer 命中派发（配合 hitTest 应用可高亮拖放目标）。
    /// 处理一个平台拖放事件。
    ///
    /// 平台只在**窗口**边界给 entered/exited；节点级的进入/离开是这里从
    /// 位置流合成出来的（同 mouse_enter/leave 的做法）：每次事件重新命中，
    /// 与上一次的 drop target 比较，跨越边界时补发 exited / entered。
    /// 否则拖过窗口内多个 drop target 时只有第一个能收到 entered。
    pub fn handleDrag(self: *Cx, x: f32, y: f32, kind: u8, paths: []const u8) void {
        return cx_input.handleDrag(self, x, y, kind, paths);
    }

    /// Platform/backend entry point. Unlike application-synthesized drag
    /// events, native payloads are explicitly tagged as untrusted and carry a
    /// fail-closed truncation bit through to the target handler.
    pub fn handlePlatformDrag(
        self: *Cx,
        x: f32,
        y: f32,
        kind: u8,
        paths: []const u8,
        payload_kind: u8,
        payload_truncated: bool,
        payload_is_untrusted: bool,
    ) void {
        return cx_input.handlePlatformDrag(self, x, y, kind, paths, payload_kind, payload_truncated, payload_is_untrusted);
    }

    // ---- 命中测试 ----

    pub fn hitTestQuery(self: *Cx, query: HitQuery) ?HitResult {
        // The scene is being mutated. Reentering hooks can recurse forever,
        // and the previous index may still contain retiring nodes. The outer
        // refresh publishes the next usable scene when it finishes.
        if (self.tick_depth > 0 or self.draining_deferred_frees) return null;
        cx_render.ensureHitTestSceneFresh(self);
        return self.interaction_index.hitTestQuery(query, &self.node_registry, &self.perf);
    }

    pub fn hitTest(self: *Cx, x: f32, y: f32) ?*Node {
        const hit = self.hitTestQuery(.{
            .kind = .pointer,
            .world_x = x,
            .world_y = y,
        }) orelse return null;
        return resolveInteractionTarget(self.node_registry.resolve(hit.handle, &self.perf));
    }

    pub fn hitTestInspect(self: *Cx, x: f32, y: f32) ?*Node {
        const hit = self.hitTestQuery(.{
            .kind = .inspect,
            .world_x = x,
            .world_y = y,
        }) orelse return null;
        return resolveInspectTarget(self.node_registry.resolve(hit.handle, &self.perf));
    }

    // ---- 布局 ----

    /// 推进单调帧时钟一拍。**每个可见帧调用一次**（由 App.frame 在 layout/render
    /// 前调），驱动绝对时间戳动画系统（overlay enter/exit transition、Spring 等）。
    ///
    /// 不要在 layout() 里调：layout() 一个可见帧内可能被 hit-test freshness 多次重入，
    /// 重复推进会让浮层跳过打开帧（见 ensureBeforeRenderTickedForHitTest 注释）。
    ///
    /// 历史 bug：生产路径从未推进 frame_time_ms（恒为 0），overlay TransitionController
    /// 靠 now_ms - last_tick 推进 → delta 恒 0 → 入场动画仅靠首帧 pending_first dt 走一拍
    /// 后冻结在 ~progress 0.09（opacity 0.177），popover/menu/dropdown 永远半透明残留。
    pub fn advanceFrameClock(self: *Cx) void {
        return cx_frame.advanceFrameClock(self);
    }

    pub fn layout(self: *Cx) void {
        return cx_frame.layout(self);
    }

    // ---- 渲染 ----

    pub fn enqueueTask(self: *Cx, task: *Task) !u64 {
        return cx_frame.enqueueTask(self, task);
    }

    pub fn cancelTask(self: *Cx, key: WorkKey) void {
        return cx_frame.cancelTask(self, key);
    }

    pub fn promoteTask(self: *Cx, key: WorkKey, priority: TaskPriority) void {
        return cx_frame.promoteTask(self, key, priority);
    }

    pub fn hasReadyWork(self: *Cx) bool {
        return cx_frame.hasReadyWork(self);
    }

    pub fn hasPendingWork(self: *const Cx) bool {
        return cx_frame.hasPendingWork(self);
    }

    /// idle 停帧门控统一判据：本轮 wake 是否需要渲染一帧。
    /// 会先消费到期的 scheduleRedrawAfterNs deadline（置 needs_redraw）。
    /// needs_redraw 的边沿消费发生在 advanceFrameClock（时钟读完之后）——
    /// 调用方**不要**自己清，提前清会冻住本次唤醒的帧时钟。
    /// 只读聚合"最近一次需要自发唤醒"的剩余 ns：scheduleRedrawAfterNs deadline
    /// （光标闪烁等）+ deferred scheduler 最近未到期任务。null = 没有任何定时唤醒
    /// 需求（可纯事件阻塞）。不消费任何状态——供主循环在 display-link 模式下算
    /// pump 阻塞超时上限，deadline 到期的消费仍走 wantsFrame→processScheduledRedraw。
    // ---- 计时器 ----

    pub const Timer = struct {
        id: u64,
        due_ns: u64,
        callback: *const fn (?*anyopaque) void,
        context: ?*anyopaque,
    };

    /// 一次性计时器：`delay_ns` 后在下一帧的 render 开头调用 `callback`
    /// （早于零脏帧快速路径，回调里标脏的节点当帧生效）。空闲停帧时也会按时
    /// 唤醒帧循环（`nextWakeDelayNs` / `wantsFrame`）。context 的生命周期由
    /// 调用方负责：释放前 `clearTimer`。返回的 id 永不为 0。
    pub fn setTimer(self: *Cx, delay_ns: u64, callback: *const fn (?*anyopaque) void, context: ?*anyopaque) !u64 {
        return cx_frame.setTimer(self, delay_ns, callback, context);
    }

    pub fn clearTimer(self: *Cx, id: u64) void {
        return cx_frame.clearTimer(self, id);
    }

    /// 触发到点的计时器。回调里可以再 set / clear（本轮只触发进入时已到点的）。
    pub fn fireDueTimers(self: *Cx) void {
        return cx_frame.fireDueTimers(self);
    }

    pub fn nextWakeDelayNs(self: *const Cx) ?u64 {
        return cx_frame.nextWakeDelayNs(self);
    }

    pub fn wantsFrame(self: *Cx) bool {
        return cx_frame.wantsFrame(self);
    }

    /// 树已经被输入/动画钩子标脏，但事件路径未显式翻转 needs_redraw 时，
    /// idle loop 仍然必须继续跑一帧把 layout/render/index rebuild 消费掉。
    pub fn hasPendingSceneWork(self: *const Cx) bool {
        return cx_frame.hasPendingSceneWork(self);
    }

    pub fn deferredBudgetUs(self: *const Cx) u32 {
        return cx_frame.deferredBudgetUs(self);
    }

    pub fn drainDeferredWork(self: *Cx, budget_us: u32) DrainDeferredResult {
        return cx_frame.drainDeferredWork(self, budget_us);
    }

    /// paint pass 入口：填 display_list (paint 端 local 坐标) 后返回切片。
    /// 内部末尾调 derive (appendAllDisplayItemsToRenderList) lowering 到
    /// self.lowering.main + inspector overlay 写入；encoder 通过 lowerForEncoder()
    /// 拿 lowered DisplayItem 切片。
    pub fn render(self: *Cx) []const display_list_mod.DisplayItem {
        return cx_render.render(self);
    }

    /// encoder 主路径吃 paint_table.DisplayItem。
    /// lowering 阶段已双写到 self.lowering.main_paint，本 fn 仅返切片，
    /// 不再做二次翻译 (省每帧 frame_arena alloc + 17 个 lowerDisplayItem 调用)。
    ///
    /// 生命周期：main_paint 跨帧 clearRetainingCapacity；inline payload ptr 指向
    /// frame_arena spill 副本（appendLoweredBoth 写入），单帧内稳定。
    pub fn lowerForEncoderPaintTable(self: *Cx) []const paint_table.DisplayItem {
        return cx_render.lowerForEncoderPaintTable(self);
    }

    pub fn scheduleRedrawAfterNs(self: *Cx, delay_ns: u64) void {
        return cx_render.scheduleRedrawAfterNs(self, delay_ns);
    }

    pub fn processScheduledRedraw(self: *Cx) bool {
        return cx_render.processScheduledRedraw(self);
    }

    /// 注册布局之后的回调（同一 ctx 重复注册只保留一份）。
    pub fn addAfterLayoutHook(self: *Cx, ctx: *anyopaque, run: AfterLayoutFn) !void {
        return cx_render.addAfterLayoutHook(self, ctx, run);
    }

    pub fn removeAfterLayoutHook(self: *Cx, ctx: *anyopaque) void {
        return cx_render.removeAfterLayoutHook(self, ctx);
    }

    /// 仅供测试：暴露 rebuildRuntimeIndexes 的可失败性，用来锁住「OOM 会返回
    /// error（所以调用点的 @panic 不是死代码）」这一前提。不是公共 API。
    pub fn rebuildRuntimeIndexesForTest(self: *Cx) !void {
        return cx_runtime_index.rebuildRuntimeIndexesForTest(self);
    }
};

// ========== Inspector (DevTools) ==========
pub const Inspector = inspector_mod.Inspector;

// ========== 声明式 API: 内联 children ==========
//
// Top-level builder functions (`box`, `text`, `image`, `icon`, `svg`,
// `spacer`, `grid`, `clickable`, plus `hstack`/`vstack`) live in
// `core/builders.zig` now. Re-exported here so existing `ui.box(...)` /
// `core.box(...)` callers keep working without churn.
const builders = @import("core/builders.zig");

pub const box = builders.box;
pub const hstack = builders.hstack;
pub const vstack = builders.vstack;
pub const text = builders.text;
pub const boxStyled = builders.boxStyled;
pub const hstackStyled = builders.hstackStyled;
pub const vstackStyled = builders.vstackStyled;
pub const textStyled = builders.textStyled;
pub const TextStyle = builders.TextStyle;
pub const image = builders.image;
pub const imageSvgHit = builders.imageSvgHit;
pub const imageTint = builders.imageTint;
pub const imageTintSvgHit = builders.imageTintSvgHit;
pub const icon = builders.icon;
pub const iconTint = builders.iconTint;
pub const iconStyled = builders.iconStyled;
pub const iconTintStyled = builders.iconTintStyled;
pub const svg = builders.svg;
pub const svgTint = builders.svgTint;
pub const spacer = builders.spacer;
pub const grid = builders.grid;
pub const GridStyle = builders.GridStyle;
pub const clickable = builders.clickable;

// ========== 声明式 API: 响应式文本 ==========
/// textFmt — 响应式文本节点：内容 = comptime 格式串 + 一组 Signal/Memo 源。
///
/// ```
/// const count = try scope.createSignal(u32, 0);
/// const label = try ui.textFmt(cx, scope, "count = {d}", .{count}, .{ .font_size = 18 });
/// ```
///
/// 框架内部创建一个 effect：每当任一源变化，重新格式化并 `setText` +
/// `markRenderDirty`——取代手写 Bindings struct + createEffect + bufPrint
/// 的样板。`sources` 是 `*Signal(T)` / `*Memo(T)` 指针的 tuple，effect 内
/// 调 `.get()` 自动订阅。
///
/// 内存契约：`setText` 对 >16 字节内容不拷贝、直接存 slice，因此格式化
/// buffer 必须比节点活得久且地址稳定——这里 buffer 挂在 heap 分配、注册为
/// `scope` 资源的 state 上,scope dispose 时先杀 effect 再释放资源(顺序
/// 由 `Scope.dispose` 保证)。**调用方契约:销毁节点前先 dispose 传入的
/// scope**(`App.runWith` 的根 scope 天然满足)。
pub fn textFmt(
    cx: *Cx,
    scope: *Scope,
    comptime fmt: []const u8,
    sources: anytype,
    props: builders.TextStyle,
) !*Node {
    const Sources = @TypeOf(sources);
    const State = TextFmtState(fmt, Sources);

    const node = try builders.text(cx, "", .{
        .color = props.color,
        .font_size = props.font_size,
        .font_weight = props.font_weight,
        .line_height = props.line_height,
        .wrap = props.wrap,
        .max_lines = props.max_lines,
    });

    const state = try cx.allocator.create(State);
    state.* = .{ .node = node, .sources = sources, .allocator = cx.allocator };
    try scope.adoptResource(state, State.destroy);

    // createEffect 创建时立即跑一次 → 首帧即为真实内容。
    try scope.createEffect(.{ .s = state }, struct {
        fn run(ctx: anytype) void {
            ctx.s.update();
        }
    }.run);

    return node;
}

/// textFmt 的 per-node state：稳定地址的格式化 buffer + 源 tuple。
/// 短内容走定长 buf；超长时 fallback 到 allocator（`overflow`），避免
/// 静默截断/冻结。
fn TextFmtState(comptime fmt: []const u8, comptime Sources: type) type {
    return struct {
        const Self = @This();

        node: *Node,
        sources: Sources,
        allocator: std.mem.Allocator,
        overflow: ?[]u8 = null,
        buf: [64]u8 = undefined,

        fn update(self: *Self) void {
            const args = readSourceValues(self.sources);
            const content = std.fmt.bufPrint(&self.buf, fmt, args) catch blk: {
                const heap = std.fmt.allocPrint(self.allocator, fmt, args) catch return;
                if (self.overflow) |old| self.allocator.free(old);
                self.overflow = heap;
                break :blk heap;
            };
            if (self.node.getText()) |old| {
                var t = old;
                t.content = content;
                // buffer 归 state 所有；禁止 node 销毁路径 free 它。
                t.owned = false;
                self.node.setText(t);
            }
            self.node.markRenderDirty();
        }

        fn destroy(ptr: *anyopaque, _: std.mem.Allocator) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            if (self.overflow) |old| self.allocator.free(old);
            self.allocator.destroy(self);
        }
    };
}

/// 源 tuple (`.{ *Signal(u32), *Memo(f32), ... }`) → 值 tuple 类型。
fn SourceValues(comptime Sources: type) type {
    const fields = @typeInfo(Sources).@"struct".fields;
    var value_types: [fields.len]type = undefined;
    for (fields, 0..) |f, i| {
        const Child = @typeInfo(f.type).pointer.child;
        value_types[i] = @typeInfo(@TypeOf(Child.get)).@"fn".return_type.?;
    }
    return std.meta.Tuple(&value_types);
}

fn readSourceValues(sources: anytype) SourceValues(@TypeOf(sources)) {
    var out: SourceValues(@TypeOf(sources)) = undefined;
    inline for (@typeInfo(@TypeOf(sources)).@"struct".fields, 0..) |f, i| {
        out[i] = @field(sources, f.name).get();
    }
    return out;
}

// ========== 渲染命令 ==========
pub const DisplayItem = display_list_mod.DisplayItem;

test {
    _ = @import("core/cx_tests.zig");
}

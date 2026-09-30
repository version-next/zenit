const std = @import("std");
const Allocator = std.mem.Allocator;

const focus_mod = @import("../focus.zig");
const reactive = @import("../reactive.zig");
const recipe_mod = @import("../recipe.zig");
const types = @import("types.zig");
const text_change = @import("text_change.zig");
const text_layout_mod = @import("text_layout.zig");
const redraw = @import("redraw.zig");
const render_engine = @import("render_engine/mod.zig");
const render_cache = @import("render_cache.zig");
const svg_path = @import("svg_path.zig");
const debug_trace = @import("debug_trace.zig");
/// World 是 Node 各类属性（rect / paint / content / layout_output）的
/// source of truth。node.zig 直接 import 它**不构成循环** —— world.zig
/// 及其依赖的表模块都不反向 import node.zig（已核实）。
/// 这是拆掉 19 个进程级全局回调的前提：Node 能直接拿到 owner World，
/// 就不需要"用全局变量把 World 偷渡进来"。
const world_mod = @import("world.zig");

/// `Node.world_id` 的哨兵值：尚未注册到任何 World
/// （cx-less 的 test mock、或 Cx.init 之前建的裸节点）。
pub const INVALID_WORLD_ID: u16 = 0xFFFF;

var bracket_debug_node_cache: ?u32 = null;

fn bracketDebugNodeFilter() ?u32 {
    if (bracket_debug_node_cache) |v| return if (v == std.math.maxInt(u32)) null else v;
    const raw = std.c.getenv("ZENIT_TEXT_BRACKET_NODE") orelse {
        bracket_debug_node_cache = std.math.maxInt(u32);
        return null;
    };
    const value = std.mem.span(raw);
    const parsed = std.fmt.parseInt(u32, value, 10) catch {
        bracket_debug_node_cache = std.math.maxInt(u32);
        return null;
    };
    bracket_debug_node_cache = parsed;
    return parsed;
}

// 升 pub —— node_render_cache.zig 跨模块调（纯 debug helper）
pub fn shouldLogBracketNode(node_id: u32) bool {
    const filter = bracketDebugNodeFilter() orelse return false;
    return node_id == filter;
}

const display_list_mod = @import("display_list.zig");
const DisplayItem = display_list_mod.DisplayItem;
pub const DrawContext = render_engine.DrawContext;

const Scope = reactive.Scope;

const ComputedRect = types.ComputedRect;
const Transform2D = types.Transform2D;
const ElementTag = types.ElementTag;
const Style = types.Style;
const TextProps = types.TextProps;
const ImageProps = types.ImageProps;
const IconProps = types.IconProps;
const EventHandlers = types.EventHandlers;
const HandlerRef = types.HandlerRef;
const A11yProps = types.A11yProps;
const DebugSignalRef = types.DebugSignalRef;
const DebugSignalKind = types.DebugSignalKind;
const PathFillRule = types.PathFillRule;
const PathGeometry = types.PathGeometry;
const PathCommand = types.PathCommand;
const HitProxySpec = types.HitProxySpec;
const Color = types.Color;

// Cached render command slices live in core/render_cache.zig now.
// Re-exported here so existing `core_node.ChildCommandSlice` etc. callers
// keep working without churn.
pub const ChildCommandSlice = render_cache.ChildCommandSlice;
pub const CachedRenderSlice = render_cache.CachedRenderSlice;
pub const duplicateDisplayItems = render_cache.duplicateDisplayItems;
pub const freeDuplicatedDisplayItems = render_cache.freeDuplicatedDisplayItems;

// SVG path parsing + path-geometry helpers live in core/svg_path.zig now.
// Public re-exports keep existing call sites in core.zig and components stable;
// the file-private aliases let Node methods below keep the unqualified names
// they were written with.
pub const clonePathGeometry = svg_path.clonePathGeometry;
pub const freePathGeometry = svg_path.freePathGeometry;
pub const createSvgDocumentPathGeometry = svg_path.createSvgDocumentPathGeometry;
const computePathBounds = svg_path.computePathBounds;
const parseSvgPathCommands = svg_path.parseSvgPathCommands;
const parseSvgDocumentPathCommands = svg_path.parseSvgDocumentPathCommands;

/// UI 树的核心数据结构，所有可见元素的运行时表示。
/// 包含 style、布局结果(rect)、子节点、脏标记、渲染缓存、事件处理等全部运行时状态。
/// 布局引擎、渲染引擎、事件系统均直接操作此结构。
///
// dirty 通知钩子。Cx.init 设置；core.zig 内的回调把 (element_id_raw, kind)
// 转成 world.markDirty 调用。Node 不直接 import core.zig 避免循环依赖。
// callback 单元 + 15 dirty 方法整体搬到 node_dirty.zig，
// 此处 re-export 保持 node.DirtyKind / node.setDirtyNotifyCallback 公开 API 不破。
pub const DirtyKind = node_dirty.DirtyKind;
pub const DirtyNotifyFn = node_dirty.DirtyNotifyFn;
pub const setDirtyNotifyCallback = node_dirty.setDirtyNotifyCallback;

// v0.5-P3 Stage 3-2 (2026-05-01): structure 通知钩子。Node.appendChild / removeChild
// 调用此钩子让 Cx 同步 World.elements 父子链表。Node 不持 World 指针避免循环依赖；
// 父/子双方的 element_id_raw == 0xFFFFFFFF 时为旧路径节点，hook 直接 return。
// structure callback 单元 + 7 树结构方法整体搬到
// node_tree.zig。此处 re-export 保持公开 API（外部 core.zig 调
// setStructureNotifyCallback）。
pub const StructureKind = node_tree.StructureKind;
pub const StructureNotifyFn = node_tree.StructureNotifyFn;
pub const setStructureNotifyCallback = node_tree.setStructureNotifyCallback;

// v0.5-P3 Stage 4-2 (session 27): 全局 rect 查询钩子。给不带 cx 的 fn（如
// computeStickyOffset / tickBeforeRender / event_dispatcher hit-test）从 World.LayoutTable
// 读 rect 用；查询失败时 caller 应回退到 node.rect。
pub const RectQueryFn = node_lifecycle.RectQueryFn;
pub const setRectQueryCallback = node_lifecycle.setRectQueryCallback;
pub const RectWriteFn = node_lifecycle.RectWriteFn;
pub const setRectWriteCallback = node_lifecycle.setRectWriteCallback;
pub const NodeCreateHookFn = node_lifecycle.NodeCreateHookFn;
pub const setNodeCreateHook = node_lifecycle.setNodeCreateHook;
/// P0-3 阶段 2：跨 Cx 串台检测（见 node_lifecycle.zig 顶部说明）。
pub const setWorldOwnershipCheck = node_lifecycle.setWorldOwnershipCheck;
/// 显式指定 owner World 的节点创建（P0-3 多窗口入口，见 Cx.createNode）。
pub const createIn = node_lifecycle.createIn;
/// standalone fallback storage 显式回收（GPA leak check 覆盖不到，需手动收）。
pub const deinitStandaloneRects = node_lifecycle.deinitStandaloneRects;
pub const standaloneRectCount = node_lifecycle.standaloneRectCount;
pub const prelayoutZeroRectReads = struct {
    pub fn get() u64 {
        return node_lifecycle.prelayout_zero_rect_reads;
    }
};
// RectQuery/RectWrite/NodeCreateHook callback 单元 + standalone
// fallback rect storage（g_standalone_rects + Get/Set）整体搬到
// node_lifecycle.zig（§L standalone 陷阱核心，整体迁移防半截）。
// 此处 re-export 保持公开 API（外部 core.zig 调 setRect*Callback）。

// §a NodeContent SoA + §b paint state SoA 的
// callback/standalone-fallback/路由 全抽到 paint_content_accessor.zig。
// 这里 re-export 公开 callback 类型 + registrar（core.zig 用
// core_node.setContentTextWriteCallback 等注册 World 镜像 hook）。
// Node 上的 get/setText/Image/Icon + getBackground/setBackgroundRaw 等
// 方法降为 thin one-liner，delegate 到 pca.* 路由 free function。
const pca = @import("paint_content_accessor.zig");
const node_dirty = @import("node_dirty.zig");
const node_render_cache = @import("node_render_cache.zig");
const node_interaction = @import("node_interaction.zig");
const node_lifecycle = @import("node_lifecycle.zig");
const node_tree = @import("node_tree.zig");
const node_inherit = @import("node_inherit.zig");

pub const PaintStateBackgroundWriteFn = pca.PaintStateBackgroundWriteFn;
pub const PaintStateOpacityWriteFn = pca.PaintStateOpacityWriteFn;
pub const PaintStateBackgroundReadFn = pca.PaintStateBackgroundReadFn;
pub const PaintStateOpacityReadFn = pca.PaintStateOpacityReadFn;
pub const setPaintBackgroundWriteCallback = pca.setPaintBackgroundWriteCallback;
pub const setPaintOpacityWriteCallback = pca.setPaintOpacityWriteCallback;
pub const setPaintBackgroundReadCallback = pca.setPaintBackgroundReadCallback;
pub const setPaintOpacityReadCallback = pca.setPaintOpacityReadCallback;

pub const ContentTextWriteFn = pca.ContentTextWriteFn;
pub const ContentImageWriteFn = pca.ContentImageWriteFn;
pub const ContentIconWriteFn = pca.ContentIconWriteFn;
pub const ContentTextReadFn = pca.ContentTextReadFn;
pub const ContentImageReadFn = pca.ContentImageReadFn;
pub const ContentIconReadFn = pca.ContentIconReadFn;
pub const setContentTextWriteCallback = pca.setContentTextWriteCallback;
pub const setContentImageWriteCallback = pca.setContentImageWriteCallback;
pub const setContentIconWriteCallback = pca.setContentIconWriteCallback;
pub const setContentTextReadCallback = pca.setContentTextReadCallback;
pub const setContentImageReadCallback = pca.setContentImageReadCallback;
pub const setContentIconReadCallback = pca.setContentIconReadCallback;

/// Text hash 缓存——避免同一帧多次 render 重复 hash 同 content/spans。
/// 把原本平铺在 Node 上的 7 个 cached_text_* 字段 collapse 进来，节省 Node 6 字段槽。
pub const TextHashCache = struct {
    content_version: u32 = 0,
    content_ptr: usize = 0,
    content_len: usize = 0,
    spans_ptr: usize = 0,
    spans_len: usize = 0,
    content_hash: u64 = 0,
    spans_hash: u64 = 0,
};

/// Custom clip geometry 元数据——provider fn + context + cache 状态。
/// 把 5 个相关字段 collapse 进来，节省 Node 4 字段槽。
pub const CustomClipMeta = struct {
    provider: ?Node.CustomClipGeometryProviderFn = null,
    provider_context: ?*anyopaque = null,
    cache_rect: ComputedRect = ComputedRect.init(-1, -1, -1, -1),
    epoch: u32 = 1,
    cache_epoch: u32 = 0,
};

/// 节点 paint 信息：paint_order + subtree paint range（子树命中测试的 [min, max] 区间）。
/// paint_order + subtree_paint_min/max 3 字段 collapsed → 1。
pub const PaintInfo = struct {
    /// 此节点在 paint pass 的全局序号
    order: u64 = 0,
    /// 子树命中测试 paint_order 范围 [min, max]
    subtree_min: u64 = 0,
    subtree_max: u64 = 0,
};

/// 节点 hit-test 索引元数据。
/// hit_proxy_start/len + hit_epoch + hit_clip_chain_id 4 字段 collapsed → 1。
pub const HitIndex = struct {
    proxy_start: u32 = 0,
    proxy_len: u16 = 0,
    epoch: u32 = 0,
    clip_chain_id: ?u32 = null,
};

/// 动画 linger 帧计数——保留几帧 promote 状态以避免动画结束瞬间 layer 收缩闪烁。
/// composite/opacity/transform linger 3 字段 collapsed → 1。
pub const AnimationLinger = struct {
    composite: u8 = 0,
    opacity: u8 = 0,
    transform: u8 = 0,
};

/// 矢量路径描边状态（与 path_geometry 独立）。
/// stroke_geometry/color/width/line_join 4 字段 collapsed → 1。
// NodeLayoutOutput 及子 struct 移到独立 node_layout_output.zig
// (让 node.zig 与 layout_output_table.zig 都能引用而不成环)。这里 re-export
// 保持 node.NodeStroke / node.NodeLayoutOutput 等旧引用点不破。
const nlo = @import("node_layout_output.zig");
pub const NodeGeometries = nlo.NodeGeometries;
pub const NodeStroke = nlo.NodeStroke;
pub const NodeVector = nlo.NodeVector;
pub const LayoutArtifacts = nlo.LayoutArtifacts;
pub const NodeLayoutOutput = nlo.NodeLayoutOutput;

// NodeLayoutOutput SoA — World.LayoutOutputTable 是 source
// of truth（in-place 字段已删）。callback/standalone-fallback/路由全在 pca
// (paint_content_accessor.zig，与 §a content / §b paint 同型)。cx-less
// mock (element_id==0xFFFFFFFF, hit_runtime/tests Node.create) 走 pca
// standalone heap pool（稳定地址，供 layoutOutputPtr 指针逃逸/原地改）。
// 这里 re-export callback 类型 + registrar（core.zig 注册 World hook）。
pub const LayoutOutputWriteFn = pca.LayoutOutputWriteFn;
pub const LayoutOutputReadFn = pca.LayoutOutputReadFn;
pub const LayoutOutputPtrFn = pca.LayoutOutputPtrFn;
pub const setLayoutOutputWriteCallback = pca.setLayoutOutputWriteCallback;
pub const setLayoutOutputReadCallback = pca.setLayoutOutputReadCallback;
pub const setLayoutOutputPtrCallback = pca.setLayoutOutputPtrCallback;

/// Custom draw 回调 + context（v0.5: fn ptr + context 2 字段 collapsed → ?CustomDraw）。
pub const CustomDraw = struct {
    callback: *const fn (DrawContext, ?*anyopaque) anyerror!void,
    context: ?*anyopaque = null,
};

/// Custom hit test 回调 + context（v0.5: fn ptr + context 2 字段 collapsed → ?CustomHitTest）。
pub const CustomHitTest = struct {
    callback: Node.CustomHitTestFn,
    context: ?*anyopaque = null,
};

/// Hit proxy provider 回调 + context（v0.5: 2 字段 collapsed → ?HitProxyProvider）。
pub const HitProxyProvider = struct {
    callback: Node.HitProxyProviderFn,
    context: ?*anyopaque = null,
};

/// Hit-test dirty bits（v0.5: 3 个 bool 字段 collapsed → 1 packed struct）。
pub const HitDirty = packed struct(u8) {
    geometry: bool = false,
    semantics: bool = false,
    structure: bool = false,
    _reserved: u5 = 0,
};

/// Runtime-index dirty bits（v0.5: 4 个 bool 字段 collapsed → 1 packed struct）。
/// dirty / subtree_dirty / full_rebuild / subtree_full_rebuild
pub const RuntimeIndexFlags = packed struct(u8) {
    dirty: bool = true,
    subtree_dirty: bool = true,
    full_rebuild: bool = true,
    subtree_full_rebuild: bool = true,
    _reserved: u4 = 0,
};

/// 左键按下时，框架对键盘焦点做什么（见 `NodeInteraction.pointer_down_focus`）。
pub const PointerDownFocus = enum {
    /// 默认：焦点交给命中节点自身或最近的 focusable 祖先；一路都没有则清空焦点。
    transfer,
    /// 保持按下前的焦点不变：既不转移给任何节点，也不清空。
    /// 适用于工具栏按钮、悬浮操作条、非模态面板等"点了只执行动作、
    /// 不该打断正在编辑的那个节点"的 UI。
    preserve,
};

/// 节点交互元数据（v0.5: focus + semantics 5 字段 collapsed → 1 NodeInteraction）。
pub const NodeInteraction = struct {
    /// 焦点管理
    focusable: bool = false,
    tab_index: ?i32 = null,
    focus_scope: ?focus_mod.FocusScopeConfig = null,
    /// 左键按下的默认焦点行为是否作用于本节点所在的这段父链。
    ///
    /// 按下时框架从命中节点出发沿父链向上逐个检查：先遇到 `.preserve` 的节点
    /// → 焦点原样保留（按下前谁持有就还是谁，没人持有就继续空着）；先遇到
    /// focusable 节点 → 焦点交给它。节点自身既 `.preserve` 又 focusable 时
    /// `.preserve` 优先（可 Tab 到、但鼠标点击不抢焦点的按钮）。因此把它设在
    /// 工具栏容器上即可覆盖整条工具栏，而工具栏里更深处的 focusable 子节点
    /// （如内嵌 Input）仍会正常拿到焦点。
    ///
    /// 只影响框架的默认焦点决策：mouse_down/click 照常分发，handler 里显式
    /// 调用的聚焦不受限制。判定在分发 mouse_down 之前按当时的树做出，与
    /// focusable 目标的确定时机一致。
    pointer_down_focus: PointerDownFocus = .transfer,
    /// 无障碍属性
    a11y: ?A11yProps = null,
    /// Synchronous platform text-input endpoint. The focused node is the only
    /// node whose client is active; Cx owns native session activation.
    text_input_client: ?types.TextInputClient = null,
    /// A text/IME commit consumed with .stop owns its redraw scheduling.
    /// Async clients may wait for their output; errors and local UI changes
    /// must invalidate explicitly. Preedit and keyboard defaults are unchanged.
    deferred_text_input_redraw: bool = false,
    /// Key context (Action dispatch 系统)
    key_context: ?[]const u8 = null,
};

/// 节点代理引用（v0.5: interaction_delegate + inspect_delegate 2 字段 collapsed → 1）。
pub const NodeDelegate = struct {
    interaction: ?*Node = null,
    inspect: ?*Node = null,
};

/// 节点生命周期钩子（v0.5: on_mount + on_cleanup 2 字段 collapsed → 1）。
pub const NodeLifecycle = struct {
    on_mount: ?HandlerRef = null,
    on_cleanup: ?HandlerRef = null,
};

/// Sticky 视觉补偿偏移（v0.5: x + y 2 字段 collapsed → 1）。
pub const StickyOffset = struct {
    x: f32 = 0,
    y: f32 = 0,
    state: StickyState = .{},

    pub fn isStuck(self: StickyOffset) bool {
        return self.state.pinned;
    }
};

/// Sticky 吸附状态（每帧由 tick 与偏移一起写入，只读观测用）。
/// - engaged_*：该方向产生了非零补偿（离开自然位置）。
/// - pinned：有补偿且没有被钳制容器截短，正贴在吸附边上。
/// - constrained：钳制容器截短了想要的补偿（被推着走 / 正在交接，含已被完全推回自然位置的情形）。
/// pinned 与 constrained 互斥。
pub const StickyState = packed struct(u8) {
    engaged_top: bool = false,
    engaged_bottom: bool = false,
    engaged_left: bool = false,
    engaged_right: bool = false,
    pinned: bool = false,
    constrained: bool = false,
    _pad: u2 = 0,

    pub fn eql(a: StickyState, b: StickyState) bool {
        return @as(u8, @bitCast(a)) == @as(u8, @bitCast(b));
    }
};

/// 节点的世界坐标变换 + 其逆（hit-test 使用）。
/// world_transform + inverse_world_transform 2 字段 collapsed → 1。
pub const WorldTransform = struct {
    matrix: Transform2D = .{},
    inverse: Transform2D = .{},
};

/// 节点 render command 缓存（own subtree + promoted layer 各一份）。
/// cached_commands + promoted_cached_commands 2 字段 collapsed → 1。
pub const RenderCache = struct {
    own: ?CachedRenderSlice = null,
    promoted: ?CachedRenderSlice = null,
    /// 下游回归：非 promoted 干净子树的跨帧 display payload 缓存。
    /// prebuild pass 对 stamp 命中的干净子树直接 splice，免全树 paint 重录。
    subtree_payload: ?CachedRenderSlice = null,
};

/// before_render hooks (主 + 子 list)。
/// on_before_render + before_render_hook_count + before_render_hooks 3 字段 collapsed → 1。
pub const BeforeRenderHooks = struct {
    main: ?*const fn (*Node) void = null,
    count: u8 = 0,
    hooks: [8]?*const fn (*Node) void = [_]?*const fn (*Node) void{null} ** 8,
};

/// 节点关联的 Scope 状态：scope ptr + binding back-pointer。
/// scope + scope_binding_node_slot 2 字段 collapsed → 1。
/// scope 是组件根节点的响应式范围；slot 是 bindScopeToNode 注册的 back pointer，
/// clearNodeScopes 在 freeNode 前 null 化以避免父 scope dispose 时碰到 stale ptr。
pub const ScopeBinding = struct {
    scope: ?*Scope = null,
    node_slot: ?*?*Node = null,
};

/// 节点版本号（content / composite）—— 用于 paint cache 失效检测。
/// content_version + composite_version 2 字段 collapsed → 1。
pub const NodeVersions = struct {
    content: u32 = 1,
    composite: u32 = 1,
};

/// 节点元数据：组件类型名 + 测试标识符（DevTools / test_harness 用）。
/// component_name + test_id 2 字段 collapsed → 1。
pub const NodeMeta = struct {
    component_name: ?[]const u8 = null,
    test_id: ?[]const u8 = null,
};

/// 布局阶段产出（layout pass artifacts）。
/// children_bbox + text_layout 2 字段 collapsed → 1。
/// 两者均由 layout_engine 写入，render/hit 阶段只读消费。
// LayoutArtifacts / NodeVector / NodeLayoutOutput / NodeGeometries 定义已移
// node_layout_output.zig（见上方 nlo re-export 块）。

/// 自定义渲染/命中钩子集合。
/// custom_draw + custom_hit_test + hit_proxy_provider + custom_clip_meta
/// 4 字段 collapsed → 1 sub-struct CustomHooks（节省 Node 3 字段槽）。
/// 大多数节点全 null/默认，集中在一处便于 cache locality。
pub const CustomHooks = struct {
    /// Custom draw 回调：替代子节点递归，直接往 lowering_buffer 写 DisplayItem。
    draw: ?CustomDraw = null,
    /// Custom hit test 回调
    hit_test: ?CustomHitTest = null,
    /// Hit proxy provider（命中代理替身）
    hit_proxy: ?HitProxyProvider = null,
    /// Custom clip mask provider + cache 元数据
    clip_meta: CustomClipMeta = .{},
};

/// 节点缓存集合（versions + text hash cache + paint cache）。
/// versions + cached_text_hash + render_cache 3 字段 collapsed → 1 NodeCaches（节省 Node 2 字段槽）。
pub const NodeCaches = struct {
    /// content/composite 版本号（paint cache 失效检测用）
    versions: NodeVersions = .{},
    /// 文本 hash cache（避免每帧重 hash）
    text_hash: TextHashCache = .{},
    /// Last published semantics, including borrowed text/span contents.
    text_signature: text_change.Signature = text_change.signature(null),
    /// 命令缓存（own + promoted）
    commands: RenderCache = .{},
};

/// 节点位图/图标内容（image + icon 互斥用）。
/// image + icon 2 字段 collapsed → 1 sub-struct NodeMedia（节省 Node 1 字段槽）。
/// 大多数节点 image=null icon=null。
pub const NodeMedia = struct {
    /// 位图（CALayer texture / texture_id 引用）
    image: ?ImageProps = null,
    /// 矢量图标（icon_id 索引，按 size 解析）
    icon: ?IconProps = null,
};

// NodeContent / NodeVisuals 已删 —— content (§a) +
// layout_output (§L) 全 SoA 化到 World，Node 不再有 visuals 字段。

/// 节点 ownership：identity + lifetime 合并集合。
/// P-Node-SoA-2: NodeIdentity (meta + debug_slots) + NodeLifetime (hooks + scope + delegate)
/// 5 字段 collapsed → 1 NodeOwnership（节省 Node 1 字段槽）。
pub const NodeOwnership = struct {
    /// component_name + test_id（identity.meta）
    meta: NodeMeta = .{},
    /// DevTools 调试用 state/signal 关联槽（identity.debug_slots）
    debug_slots: DebugSlots = .{},
    /// on_mount + on_cleanup 钩子（lifetime.hooks）
    hooks: NodeLifecycle = .{},
    /// 关联的 reactive Scope binding（lifetime.scope）
    scope: ScopeBinding = .{},
    /// interaction/inspect 代理节点（lifetime.delegate）
    delegate: NodeDelegate = .{},
};

/// 节点空间索引（world transform + paint order + hit index 3 类索引数据）。
/// world_xform + paint_info + hit_index 3 字段 collapsed → 1 NodeSpatial（节省 Node 2 字段槽）。
/// 全部由 layout/paint/hit pass 写入；render/event 阶段只读消费。
pub const NodeSpatial = struct {
    /// world transform + inverse
    world: WorldTransform = .{},
    /// paint order index（DFS 序号 + subtree 范围）
    paint: PaintInfo = .{},
    /// hit test 索引（proxy ranges + epoch + clip chain）
    hit: HitIndex = .{},
};

/// 节点 dirty 标记集合（layout / pipeline / hit / runtime_index 4 个 packed structs）。
/// core_dirty + runtime_index + pipeline_dirty + hit_dirty 4 字段 collapsed → 1 NodeDirty（节省 Node 3 字段槽）。
/// 子字段名保持原样，仅多一层 .core/.runtime/.pipeline/.hit 的访问跳跃。
pub const NodeDirty = struct {
    /// layout/render dirty bits（4 bool packed）
    core: CoreDirty = .{},
    /// runtime_index 4 bool packed
    runtime: RuntimeIndexFlags = .{},
    /// pipeline order/interaction/composite × self+subtree 6 bool packed
    pipeline: PipelineDirty = .{},
    /// hit_geometry/semantics/structure 3 bool packed
    hit: HitDirty = .{},
};

/// setTheme 主题重放钩子：boxStyled/textStyled 等具名样式函数挂载于此，
/// setTheme 时用新 tokens 重跑样式函数。
pub const ThemeHook = *const fn (*Node, *const types.ThemeTokens, std.mem.Allocator) void;

/// 节点钩子集合（before_render hooks + hook-owned state slots）。
/// before_render + hook_slots 2 字段 collapsed → 1 NodeHooks（节省 Node 1 字段槽）。
pub const NodeHooks = struct {
    /// on_before_render main + extra hook ring
    before_render: BeforeRenderHooks = .{},
    /// setTheme-only 主题重放 hook（boxStyled/textStyled 等具名样式函数挂载）
    on_theme: ?ThemeHook = null,
    /// useFocusRing / useAnimatedBackground / useHoverHighlight / 组件 anim_state 4 个 ?*anyopaque slot
    slots: HookSlots = .{},
};

/// 节点每帧 state 集合（caches + hooks + custom_hooks）。
/// P-Node-SoA-4: caches + hooks + custom_hooks 3 字段 collapsed → 1 NodePerFrameState（-2 fields）。
pub const NodePerFrameState = struct {
    caches: NodeCaches = .{},
    hooks: NodeHooks = .{},
    custom_hooks: CustomHooks = .{},
};

/// P-Node-SoA-5b (2026-05-02): frame_local 合并 spatial + runtime。
pub const NodeFrameLocal = struct {
    spatial: NodeSpatial = .{},
    runtime: NodeRuntime = .{},
};

/// P-Node-SoA-5b (2026-05-02): behavior 合并 events + interaction。
pub const NodeBehavior = struct {
    events: EventHandlers = .{},
    interaction: NodeInteraction = .{},
};

/// P-Node-SoA-6 (2026-05-02): 终极 frame state 合并 — state_bits + frame_local。
/// 这两个都是 per-frame transient state，逻辑高度相关。
/// v0.5-P3 N-2 (2026-05-03): rect 字段已删 — element_id != 0xFFFFFFFF 节点的 rect
/// 在 World.LayoutTable，element_id == 0xFFFFFFFF (standalone Node.create 节点)
/// 的 rect 在 g_standalone_rects (out-of-line hashmap, key by node ptr)。
pub const NodeFrameState = struct {
    state_bits: NodeStateBits = .{},
    frame_local: NodeFrameLocal = .{},
};

/// P-Node-SoA-6 (2026-05-02): meta 合并 ownership + per_frame。
pub const NodeMetadata = struct {
    ownership: NodeOwnership = .{},
    per_frame: NodePerFrameState = .{},
};

/// 节点运行时视觉状态（sticky 位置补偿 + 动画 linger 帧计数 + 动画运行时槽）。
/// sticky_offset + animation_linger 2 字段 collapsed → 1 NodeRuntime（节省 Node 1 字段槽）。
/// P-Node-SoA-1 (2026-05-02): merged former NodeAnimRuntime (transitions + commands) here，
/// 多省 1 字段槽（→ Node 23 fields）。两者均 lazily 分配，绝大多数节点是 null/null。
pub const NodeRuntime = struct {
    /// sticky 位置 x/y
    sticky: StickyOffset = .{},
    /// 动画 linger 帧计数（composite/opacity/transform）
    linger: AnimationLinger = .{},
    /// 声明式 Transition 运行时状态（former NodeAnimRuntime.transitions）
    transitions: ?*types.TransitionSlots = null,
    /// 命令式节点动画（由 animateNode 分配；former NodeAnimRuntime.commands）
    commands: ?*@import("../animation/node_animator.zig").NodeAnimations = null,
};

/// 由 hooks 拥有的不透明 state slot（4 个独立用途的指针；指向 hook 私有的 state struct）。
/// 4 个 `?*anyopaque` 字段 collapsed → 1。
pub const HookSlots = struct {
    /// useFocusRing
    focus_ring_anim: ?*anyopaque = null,
    /// useAnimatedBackground
    animated_bg_state: ?*anyopaque = null,
    /// useHoverHighlight
    hover_highlight_state: ?*anyopaque = null,
    /// 组件自定义 anim_state（供 on_before_render 使用）
    anim_state: ?*anyopaque = null,
};

/// 散落 bool flags（v0.5: 11 个 bool collapsed → 1 packed struct）。
/// 不包括 dirty propagation 位（那些在 CoreDirty / PipelineDirty / RuntimeIndexFlags / HitDirty）。
pub const NodeFlags = packed struct(u16) {
    out_of_viewport: bool = false,
    hit_test_visible: bool = true,
    text_stabilize_subtree: bool = false,
    manual_transform_animation_active: bool = false,
    manual_opacity_animation_active: bool = false,
    has_custom_draw_subtree: bool = false,
    /// 子树（含自身）存在 text 内容。setText 非空置位并沿祖先冒泡，appendChild
    /// /reparent 时并入父链；保守不清位（删文本后保持 true，只增不减）。
    /// collectContentFlags.has_text 的 O(1) 数据源，替代旧 subtreeHasText
    /// 每节点递归下钻（整帧 O(n·depth)）。
    has_text_subtree: bool = false,
    /// 子树（含自身）存在 before_render hook。addBeforeRender 置位并冒泡，
    /// appendChild 并入父链；保守不清位。hasBeforeRenderHookSubtree 的 O(1) 源。
    has_before_render_subtree: bool = false,
    disable_render_cache: bool = false,
    test_id_owned: bool = false,
    is_mounted: bool = false,
    inspectable: bool = true,
    inspect_pick_disabled: bool = false,
    /// before_render hook 的影响范围声明（默认 false = 保守，影响整棵子树）。
    ///
    /// 背景：prebuildDisplayPayloadSubtrees 遇到挂了 before_render hook 的节点
    /// 会置 display_payload_prefix_broken，让 paint 顺序在其之后的**一切**都退回
    /// fresh emit。这条闸门防的是真问题（hook 在 render 期改 transform/内容，
    /// prebuild 预录的是 hook 运行前的状态 → 半 prebuilt 半 fresh 的双份合成，
    /// GlassLab 拖拽球闪烁的根因）。但代价是整条前缀，对"hook 只回填自己几何"
    /// 的场景（编辑器的滚动同步 / 尺寸回填）是巨大的误伤。
    ///
    /// 置 true 表示调用方担保：**本 hook 只改本节点自身的几何/样式/内容，
    /// 不触碰任何后代或兄弟节点的 transform、内容与可见性**。此时闸门降级为
    /// "只让本节点自己不参与跨帧缓存"，不再打断整条 paint 前缀。
    ///
    /// ⚠ 担保错了的表现是残影/双份合成，不是崩溃 —— 必须配逐帧像素对照验收，
    /// 逃生阀见 ZENIT_DISABLE_HOOK_SELF_SCOPE。
    before_render_hook_affects_self_only: bool = false,
    _reserved: u2 = 0,
};

/// 核心 dirty bits（v0.5: layout/subtree_layout/render/subtree_render 4 bool collapsed → 1 packed struct）。
/// 这些是 zenit dirty propagation 主链路。
pub const CoreDirty = packed struct(u8) {
    layout: bool = true,
    subtree_layout: bool = true, // 原名 subtree_dirty（指 subtree_layout_dirty）
    render: bool = true,
    subtree_render: bool = true,
    _reserved: u4 = 0,
};

/// Pipeline dirty bits（v0.5: order / interaction / composite × (self+subtree) 6 bool collapsed → 1 packed struct）。
pub const PipelineDirty = packed struct(u8) {
    order: bool = true,
    subtree_order: bool = true,
    interaction: bool = false,
    subtree_interaction: bool = false,
    composite: bool = true,
    subtree_composite: bool = true,
    _reserved: u2 = 0,
};

/// Devtools debug slots——状态指针池 + signal ref 池，仅 inspector/devtools 消费。
/// 把 4 个 debug_* 字段 collapse 进来，节省 Node 3 字段槽。
pub const DebugSlots = struct {
    state_count: u8 = 0,
    state_ptrs: [8]?*anyopaque = [_]?*anyopaque{null} ** 8,
    signal_count: u8 = 0,
    signals: [8]?DebugSignalRef = [_]?DebugSignalRef{null} ** 8,
};

/// P-Node-SoA-5: dirty (NodeDirty) + flags (NodeFlags) collapsed.
pub const NodeStateBits = struct {
    dirty: NodeDirty = .{},
    flags: NodeFlags = .{},
};

/// 应用层不直接构造 Node，而是通过 `ui.box()` / `ui.text()` / `ui.image()` 等
/// 工厂函数创建（见 core.zig）。这些函数内部调用 `Node.create()` 并设置对应的 tag。
pub const ALIVE_SENTINEL: u32 = 0x5A11_5A11;
pub const DEAD_SENTINEL: u32 = 0xDEAD_0DE0;

pub const Node = struct {
    pub const CustomHitTestFn = *const fn (node: *const Node, local_x: f32, local_y: f32, context: ?*anyopaque) bool;
    pub const HitProxyProviderFn = *const fn (node: *const Node, context: ?*anyopaque, out: []HitProxySpec) usize;
    pub const CustomClipGeometryProviderFn = *const fn (node: *const Node, allocator: Allocator, context: ?*anyopaque) anyerror!PathGeometry;

    id: u32,
    tag: ElementTag,
    style: Style,

    /// Pure, world-coordinate cursor query for a custom-drawn subtree. Only
    /// called on current hit ancestry. Null defers to descendant styles.
    cursor_query: ?*const fn (*const Node, f32, f32, ?*anyopaque) ?@import("cursor.zig").Region = null,
    cursor_query_context: ?*anyopaque = null,
    /// Called after capture ownership is cleared. Must tolerate cancellation.
    on_capture_lost: ?*const fn (*Node) void = null,

    /// 链接到 World.elements 中的 ElementId（u32 raw 形式存避免 import 循环）。
    element_id_raw: u32 = 0xFFFFFFFF,

    /// 本节点归属哪个 World（= 哪个 Cx / 哪个窗口）。0xFFFF = 未注册。
    ///
    /// **为什么需要**：`element_id_raw` 是 `{index:u24, generation:u8}`，
    /// **不含任何 World 标识**，而每个 World 都从 index 0 开始分配 —— 于是
    /// 窗口 A 的 eid 0x8 与窗口 B 的 eid 0x8 完全无法区分，
    /// `SlotMap.isValid` 只校验 index 范围 + generation，拿 A 的 id 去查 B 的
    /// World 会**假匹配并返回错误数据**（core.zig 旧注释断言"id 不匹配则
    /// isValid 保护"是错的）。
    ///
    /// 有了 owner 标识，Node↔World 的路由才能被校验（当前阶段）乃至完全
    /// 摆脱进程级全局回调（后续阶段）。见 Zenit_P0-3_RootCause_2026-07-29.md。
    world_id: u16 = INVALID_WORLD_ID,

    /// 本节点所属 World 的直接指针（null = 未注册，走 standalone fallback）。
    ///
    /// P0-3 阶段 3：这是拆掉 19 个进程级全局回调（g_rect_query /
    /// g_structure_notify / g_paint_* / g_content_* / g_layout_output_* …）的
    /// 关键 —— 有了它，Node 的属性访问可以直接 `node.world_ref.?.layout.rect(eid)`，
    /// 不必再"用全局变量把 World 偷渡进来"。
    /// 与 world_id 同时由 onNodeCreate 写入；world_id 保留用于**跨 Cx 串台断言**
    /// （指针相等无法区分"同一个 World 被释放后地址复用"的情况）。
    world_ref: ?*world_mod.World = null,

    children: std.ArrayList(*Node),
    parent: ?*Node = null,
    /// Stable request storage shared by reactive and frame-deferred queues.
    deferred_disposal: @import("../reactive/deferred_disposal.zig").Entry = .{},
    pending_free_cx: ?*anyopaque = null,
    freeing: bool = false,
    /// 生存哨兵：init 写 ALIVE，destroy 前写 DEAD。
    ///
    /// 由来（交叉 review 二-2）：`freeing` 只能挡**同一次 teardown 内**的
    /// 重入。真正的 double free（内存已还给 allocator、甚至已被复用）挡不住 ——
    /// 更糟的是 Debug 下 Zig 会把释放后的内存写成 0xaa，于是 `freeing` 读出来是
    /// true（0xaa ≠ 0），freeNodeNow 会**静默 early-return**，把一个可检测的
    /// double free 变成无声的 no-op。
    ///
    /// 有了哨兵就能区分三种状态：ALIVE（正常）/ 本次 teardown 进行中（freeing=true
    /// 且 alive_sentinel==ALIVE）/ 已释放（sentinel 既不是 ALIVE 也不是 DEAD，
    /// 或正好是 DEAD）—— 后两者都 panic 而不是装作没事。
    ///
    /// **结论的适用范围**（交叉 review 判据1/2：检测能力类结论必须带
    /// 构建模式限定词，缺失性结论必须带覆盖数字）：
    /// - 哨兵在**所有构建模式**下都存在（用 @panic 不用 assert）。
    /// - 但它挡的那个「0xaa 让 freeing 读出 true 从而静默 no-op」形态是
    ///   **Debug/ReleaseSafe 的 DebugAllocator 毒化行为**；ReleaseFast 下
    ///   读到的是复用内存，哨兵可能假阴（复用成同类型且新 init 写回 ALIVE）。
    ///   所以哨兵是**第一条皮带**，allocator 自身的 double-free 检测是第二条，
    ///   两条都不能省。
    /// - 实测覆盖：zenit test（Debug + ReleaseSafe）、下游编辑器两条 OOM sweep
    ///   （2335 + 1178 个注入点，Debug + ReleaseSafe）全绿。
    alive_sentinel: u32 = ALIVE_SENTINEL,

    // visuals 字段已删 —— content (§a) + layout_output (§L)
    // 全 SoA 化到 World (ContentTable / LayoutOutputTable)。Node 顶层 10→9。

    /// P-Node-SoA-6 (2026-05-02): rect + state_bits + frame_local 三合一。
    frame_state: NodeFrameState = .{},

    /// P-Node-SoA-6 (2026-05-02): ownership + per_frame 合并。
    meta: NodeMetadata = .{},

    /// P-Node-SoA-5b: events + interaction 合并 → behavior。
    behavior: NodeBehavior = .{},

    /// 从全局 World 读 rect，失败回退 standalone fallback storage。
    /// 给不带 cx 的 fn（computeStickyOffset / tickBeforeRender 等）用。
    pub fn rectFromWorldOrFallback(self: *const Node) ComputedRect {
        return node_lifecycle.rectFromWorldOrFallback(self);
    }

    /// 组件层"自己改子节点 rect"的统一写入口。
    /// 写入 World.LayoutTable + 维护 standalone fallback storage。
    pub fn setLayoutRect(self: *Node, r: ComputedRect) void {
        node_lifecycle.setLayoutRect(self, r);
    }

    /// Partial setters — layout_engine 频繁做 partial updates；这些 helper 把
    /// "read current → modify → setLayoutRect" 封装成单调用，让 layout 路径不
    /// 直接写 frame_state.rect 字段，使得真删字段时改这里就行。
    pub fn setLayoutW(self: *Node, w: f32) void {
        node_lifecycle.setLayoutW(self, w);
    }

    pub fn setLayoutH(self: *Node, h: f32) void {
        node_lifecycle.setLayoutH(self, h);
    }

    pub fn setLayoutX(self: *Node, x: f32) void {
        node_lifecycle.setLayoutX(self, x);
    }

    pub fn setLayoutY(self: *Node, y: f32) void {
        node_lifecycle.setLayoutY(self, y);
    }

    /// v0.9-§a stage 3 (2026-05-13): NodeContent SoA — World.content 是 source of truth.
    /// element_id_raw == 0xFFFFFFFF (mock test 不带 cx) 落 standalone fallback hashmap by node ptr.
    // content accessor 路由全在 pca；这里只做
    // element_id_raw + node_ptr 的薄转发（方法必须留 Node 容器内）。
    /// Publishes text and invalidates measurement or paint as needed. Re-publish
    /// borrowed content/spans after mutating them; identical writes are inert.
    /// Ownership changes still reach the storage layer even when pixels match.
    pub fn setText(self: *Node, t: ?TextProps) void {
        const next = text_change.signature(t);
        const previous = self.meta.per_frame.caches.text_signature;
        pca.writeText(self.world_ref, self.element_id_raw, @intFromPtr(self), t);
        // 子树 text 标志：非空文本置位并冒泡（保守不清位，见 NodeFlags 注释）。
        if (t != null) node_interaction.markSubtreeText(self);
        // 内容换了，按 (version, ptr, len) 记的 text hash 必须作废：等长换文本
        // 时这三项可以全都不变（见 invalidateTextHashCache 的注释）。
        node_render_cache.invalidateTextHashCache(self);
        self.meta.per_frame.caches.text_signature = next;
        if (next.layout != previous.layout) {
            self.markSizingDirty();
        } else if (next.paint != previous.paint) {
            self.markRenderDirty();
        }
    }

    /// 便捷换文本：dupe 新内容并标记 owned，旧 owned 内容由 setText 自动释放。
    /// 应用侧状态栏/标签类「同节点换文案」场景用这个即可，无需手工管理 owned 标记。
    /// 换文本内容。内容真的变了才标脏：新内容的宽高要重新测量（也会重画），
    /// 调用方不必再手动 markSizingDirty——漏掉它时文本按旧宽度排，更长的新内容
    /// 会冲出父容器（通知卡片的「刚刚 → 1 分钟前」就是这么溢出的）。
    pub fn setTextContent(self: *Node, alloc: std.mem.Allocator, content: []const u8) !void {
        var t: TextProps = self.getText() orelse .{};
        const changed = !std.mem.eql(u8, t.content, content);
        t.content = try alloc.dupe(u8, content);
        t.owned = true;
        t.inline_len = 0;
        self.setText(t);
        if (changed) self.markSizingDirty();
    }

    pub fn setImage(self: *Node, img: ?ImageProps) void {
        pca.writeImage(self.world_ref, self.element_id_raw, @intFromPtr(self), img);
    }

    /// 改图标着色，不关心存储形态：iconTint 对带 icon_id 的资源走 icon 表，
    /// 无预烘焙 rep 的资源退回 image（svgTint）——调用方各自只判一种时，另一种
    /// 静默不变色（Rate hover 不变色即此）。两者都没有时返回 false。
    pub fn setTint(self: *Node, tint: Color) bool {
        if (self.getIcon()) |old| {
            var ic = old;
            ic.tint = tint;
            self.setIcon(ic);
        } else if (self.getImage()) |old| {
            var img = old;
            img.tint = tint;
            self.setImage(img);
        } else return false;
        self.markRenderDirty();
        return true;
    }

    pub fn setIcon(self: *Node, ic: ?IconProps) void {
        pca.writeIcon(self.world_ref, self.element_id_raw, @intFromPtr(self), ic);
    }

    pub fn getText(self: *const Node) ?TextProps {
        return pca.readText(self.world_ref, self.element_id_raw, @intFromPtr(self));
    }

    pub fn getImage(self: *const Node) ?ImageProps {
        return pca.readImage(self.world_ref, self.element_id_raw, @intFromPtr(self));
    }

    pub fn getIcon(self: *const Node) ?IconProps {
        return pca.readIcon(self.world_ref, self.element_id_raw, @intFromPtr(self));
    }

    // NodeLayoutOutput 字段已删 → World.LayoutOutputTable
    // 是 source of truth；cx-less mock 走 pca standalone heap pool。thin
    // delegate 到 pca（element_id + node_ptr 两参，pca 内分流 World/standalone）。
    pub fn getLayoutOutput(self: *const Node) NodeLayoutOutput {
        return pca.readLayoutOutput(self.world_ref, self.element_id_raw, @intFromPtr(self));
    }

    pub fn setLayoutOutput(self: *Node, v: NodeLayoutOutput) void {
        pca.writeLayoutOutput(self.world_ref, self.element_id_raw, @intFromPtr(self), v);
    }

    /// 稳定地址：供 owner 方法原地改子字段 + display_list 指针逃逸 caller。
    /// cx-backed 走 World slot（dense by element_id，帧内稳定）；cx-less
    /// mock 走 pca standalone heap pool（地址永久稳定）。
    pub fn layoutOutputPtr(self: *Node) ?*NodeLayoutOutput {
        return pca.layoutOutputPtr(self.world_ref, self.element_id_raw, @intFromPtr(self));
    }

    pub fn create(allocator: Allocator, id: u32, tag: ElementTag, style: Style) !*Node {
        return node_lifecycle.create(allocator, id, tag, style);
    }

    pub fn setFocusable(self: *Node, focusable: bool) void {
        node_interaction.setFocusable(self, focusable);
    }

    pub fn setInteractionDelegate(self: *Node, delegate: ?*Node) void {
        node_interaction.setInteractionDelegate(self, delegate);
    }

    pub fn setInspectPickDisabled(self: *Node, disabled: bool) void {
        node_interaction.setInspectPickDisabled(self, disabled);
    }

    pub fn setHitTestVisible(self: *Node, visible: bool) void {
        node_interaction.setHitTestVisible(self, visible);
    }

    pub fn addBeforeRender(self: *Node, hook: *const fn (*Node) void) void {
        // 子树 hook 标志：置位并沿祖先冒泡（供 hasBeforeRenderHookSubtree O(1) 读）。
        // 组件层还有大量 `before_render.main =` 直赋值不经过本函数——那些由
        // tick.zig 的 tickBeforeRender 每次执行时折叠自愈（见其注释）。
        node_interaction.markSubtreeBeforeRenderHook(self);
        if (self.meta.per_frame.hooks.before_render.main == hook) return;
        for (self.meta.per_frame.hooks.before_render.hooks[0..self.meta.per_frame.hooks.before_render.count]) |existing| {
            if (existing == hook) return;
        }
        if (self.meta.per_frame.hooks.before_render.count < self.meta.per_frame.hooks.before_render.hooks.len) {
            self.meta.per_frame.hooks.before_render.hooks[self.meta.per_frame.hooks.before_render.count] = hook;
            self.meta.per_frame.hooks.before_render.count += 1;
        }
    }

    pub fn removeBeforeRender(self: *Node, hook: *const fn (*Node) void) void {
        if (self.meta.per_frame.hooks.before_render.count == 0) return;
        var i: usize = 0;
        while (i < self.meta.per_frame.hooks.before_render.count) : (i += 1) {
            if (self.meta.per_frame.hooks.before_render.hooks[i] == hook) {
                var j = i;
                while (j + 1 < self.meta.per_frame.hooks.before_render.count) : (j += 1) {
                    self.meta.per_frame.hooks.before_render.hooks[j] = self.meta.per_frame.hooks.before_render.hooks[j + 1];
                }
                self.meta.per_frame.hooks.before_render.count -= 1;
                self.meta.per_frame.hooks.before_render.hooks[self.meta.per_frame.hooks.before_render.count] = null;
                return;
            }
        }
    }

    pub fn hasBeforeRenderHooks(self: *const Node) bool {
        return self.meta.per_frame.hooks.before_render.main != null or self.meta.per_frame.hooks.before_render.count > 0;
    }

    pub fn setTabIndex(self: *Node, tab_index: ?i32) void {
        node_interaction.setTabIndex(self, tab_index);
    }

    pub fn setFocusScope(self: *Node, focus_scope: ?focus_mod.FocusScopeConfig) void {
        node_interaction.setFocusScope(self, focus_scope);
    }

    /// 见 `NodeInteraction.pointer_down_focus`。
    pub fn setPointerDownFocus(self: *Node, policy: PointerDownFocus) void {
        node_interaction.setPointerDownFocus(self, policy);
    }

    /// 沿 parent 链向上查找；self 是 ancestor 后代（含 self）返回 true。
    pub fn isDescendantOf(self: *Node, ancestor: *Node) bool {
        return node_tree.isDescendantOf(self, ancestor);
    }

    pub fn appendChild(self: *Node, allocator: Allocator, child: *Node) !void {
        return node_tree.appendChild(self, allocator, child);
    }

    /// 使用现有子节点指针重排 children 顺序。
    /// 不创建/销毁节点，不触发 runtime registry rebuild，只标记 order/layout dirty。
    pub fn replaceChildOrder(self: *Node, allocator: Allocator, ordered_children: []const *Node) !void {
        return node_tree.replaceChildOrder(self, allocator, ordered_children);
    }

    /// 设置 custom_draw 回调并冒泡标记 has_custom_draw_subtree
    pub fn setCustomDraw(self: *Node, draw_fn: *const fn (DrawContext, ?*anyopaque) anyerror!void, draw_ctx: ?*anyopaque) void {
        node_interaction.setCustomDraw(self, draw_fn, draw_ctx);
    }

    pub fn setCustomClipGeometryProvider(self: *Node, allocator: Allocator, provider: CustomClipGeometryProviderFn, context: ?*anyopaque) void {
        node_interaction.setCustomClipGeometryProvider(self, allocator, provider, context);
    }

    pub fn setHitProxyProvider(self: *Node, provider: HitProxyProviderFn, context: ?*anyopaque) void {
        node_interaction.setHitProxyProvider(self, provider, context);
    }

    pub fn setCursor(self: *Node, shape: types.CursorShape) void {
        if (self.style.cursor == shape) return;
        self.style.cursor = shape;
        self.markInteractionDirty();
    }

    pub fn setCursorQuery(self: *Node, query: ?*const fn (*const Node, f32, f32, ?*anyopaque) ?@import("cursor.zig").Region, context: ?*anyopaque) void {
        self.cursor_query = query;
        self.cursor_query_context = context;
        self.markInteractionDirty();
    }

    pub fn setPathHitGeometry(self: *Node, allocator: Allocator, commands: []const PathCommand, fill_rule: PathFillRule) !void {
        return node_interaction.setPathHitGeometry(self, allocator, commands, fill_rule);
    }

    pub fn setSvgPathHitGeometry(self: *Node, allocator: Allocator, svg_path_data: []const u8, fill_rule: PathFillRule) !void {
        return node_interaction.setSvgPathHitGeometry(self, allocator, svg_path_data, fill_rule);
    }

    pub fn setSvgDocumentHitGeometry(self: *Node, allocator: Allocator, svg_data: []const u8, fill_rule: PathFillRule) !void {
        return node_interaction.setSvgDocumentHitGeometry(self, allocator, svg_data, fill_rule);
    }

    pub fn setClonedPathGeometry(self: *Node, allocator: Allocator, geometry: PathGeometry) !void {
        return node_interaction.setClonedPathGeometry(self, allocator, geometry);
    }

    fn setCustomClipGeometry(self: *Node, allocator: Allocator, commands: []const PathCommand, fill_rule: PathFillRule) !void {
        return node_interaction.setCustomClipGeometryForNode(self, allocator, commands, fill_rule);
    }

    pub fn setSvgCustomClipGeometry(self: *Node, allocator: Allocator, svg_path_data: []const u8, fill_rule: PathFillRule) !void {
        return node_interaction.setSvgCustomClipGeometry(self, allocator, svg_path_data, fill_rule);
    }

    pub fn ensureCustomClipGeometry(self: *Node, allocator: Allocator) !void {
        return node_interaction.ensureCustomClipGeometry(self, allocator);
    }

    /// 冒泡标记 has_custom_draw_subtree（子节点添加时调用）
    // 升 pub —— node_tree 经 self.markCustomDrawSubtree() 跨模块调
    pub fn markCustomDrawSubtree(self: *Node) void {
        node_interaction.markCustomDrawSubtree(self);
    }

    /// 冒泡标记 has_text_subtree（setText 非空 / 子树添加时调用）
    pub fn markSubtreeText(self: *Node) void {
        node_interaction.markSubtreeText(self);
    }

    /// 冒泡标记 has_before_render_subtree（addBeforeRender / 子树添加时调用）
    pub fn markSubtreeBeforeRenderHook(self: *Node) void {
        node_interaction.markSubtreeBeforeRenderHook(self);
    }

    /// 计算节点的全局绝对坐标（遍历祖先链累积 rect + translate + sticky）
    pub fn globalRect(self: *const Node) ComputedRect {
        return node_lifecycle.globalRect(self);
    }

    // ==================== 可继承属性 resolve（向上遍历 parent 链） ====================

    // 可继承属性 resolve 已析出到 node_inherit.zig（node.zig 里唯一的
    // 向上遍历 + 零副作用读路径）。Node.InheritedTextStyle 路径保持不变。
    pub const InheritedTextStyle = node_inherit.InheritedTextStyle;

    pub fn resolveInheritedTextStyle(self: *const Node) InheritedTextStyle {
        return node_inherit.resolveInheritedTextStyle(self);
    }

    pub fn resolveTextColor(self: *const Node) ?types.Color {
        return node_inherit.resolveTextColor(self);
    }

    pub fn resolveTextFontSize(self: *const Node) ?f32 {
        return node_inherit.resolveTextFontSize(self);
    }

    pub fn resolveTextFontWeight(self: *const Node) ?u16 {
        return node_inherit.resolveTextFontWeight(self);
    }

    // ==================== 类型安全的 Style 修改 API ====================

    /// 给 DevTools 记录 builder / 具名样式函数的公共声明来源。来源表是 World
    /// 上的稀疏调试数据，不扩 Node，也不在这里做昂贵的 debug-info 解析。
    pub fn recordStyleBaseOrigin(self: *Node, fields: u64, address: usize, kind: world_mod.StyleOriginKind) void {
        const w = self.world_ref orelse return;
        w.recordStyleBase(self.element_id_raw, fields, .{ .address = address, .kind = kind });
    }

    /// 读取某字段的 last-writer；null field 用于尚未进入 StyleField 的
    /// TextStyle.line_height 等属性，此时只查询公共来源。
    pub fn styleOrigin(self: *const Node, field: ?types.StyleField) ?world_mod.StyleOrigin {
        const w = self.world_ref orelse return null;
        const field_index: ?u8 = if (field) |f| @intCast(@intFromEnum(f)) else null;
        return w.styleOrigin(self.element_id_raw, field_index);
    }

    /// 设置单个 style 字段，编译时自动选择正确的标脏级别
    /// 低频字段自动分配 StyleExt（需要提供 allocator）。
    /// ext 字段 + 字面量 null → 编译错误；ext 字段 + 运行时 null →
    /// debug assert + error 日志（曾经的静默跳过让下游 10 处 z_index 全部
    /// 哑火且无任何信号，下游回归）。
    pub fn setStyle(self: *Node, maybe_allocator: anytype, comptime field: types.StyleField, value: types.StyleFieldType(field)) void {
        const AllocArg = @TypeOf(maybe_allocator);
        if (comptime AllocArg != std.mem.Allocator and AllocArg != ?std.mem.Allocator and AllocArg != @TypeOf(null)) {
            @compileError("setStyle 的 allocator 参数必须是 Allocator / ?Allocator / null，收到 " ++ @typeName(AllocArg));
        }
        if (comptime types.isExtField(field) and AllocArg == @TypeOf(null)) {
            @compileError("setStyle(." ++ @tagName(field) ++ ") 是 StyleExt 字段：allocator 传 null 会丢弃写入，必须传实际 allocator");
        }
        // background/opacity 已不在 Style → SoA Raw 写路径。
        if (comptime field == .background) {
            self.setBackgroundRaw(value);
        } else if (comptime field == .opacity) {
            self.setOpacityRaw(value);
        } else if (comptime types.isExtField(field)) {
            const maybe: ?std.mem.Allocator = maybe_allocator;
            if (maybe) |allocator| {
                const ext = self.style.ensureExtPanic(allocator);
                @field(ext, @tagName(field)) = value;
            } else {
                // 运行时 null：写入无法进行。曾静默跳过——现在必须可见。
                std.log.err("setStyle(.{s}) 需要 allocator，写入被丢弃", .{@tagName(field)});
                std.debug.assert(false);
                return;
            }
        } else {
            @field(self.style, @tagName(field)) = value;
        }
        if (self.world_ref) |w| {
            w.recordStyleField(self.element_id_raw, @intCast(@intFromEnum(field)), .{
                .address = @returnAddress(),
                .kind = .set_style,
            });
        }
        switch (comptime types.styleDirtyLevel(field)) {
            .sizing => {
                self.markSizingDirty();
                debug_trace.maybeRecordRender(self.id, .sizing_triggered, "setStyle");
            },
            .layout => {
                self.markLayoutDirty();
                debug_trace.maybeRecordRender(self.id, .layout_triggered, "setStyle");
            },
            .interaction => {
                self.markInteractionDirty();
                self.markRenderDirtyTracked(.style_change, "setStyle");
            },
            .render => self.markRenderDirtyTracked(.style_change, "setStyle"),
            .none => {},
        }
    }

    /// 设置完整数值 margin，并清除已有的 auto margin 标记。
    pub fn setMargin(self: *Node, margin: types.Padding) void {
        if (std.meta.eql(self.style.margin, margin) and self.style.marginAutoMask() == 0) return;
        self.style.margin = margin;
        self.style.clearAutoMargins();
        self.markSizingDirty();
    }

    /// 设置完整 margin 声明（支持 auto）。
    pub fn setMarginSpec(self: *Node, allocator: Allocator, margin: types.Margin) void {
        if (types.Margin.eql(self.style.marginSpec(), margin)) return;
        self.style.setMarginSpec(allocator, margin);
        self.markSizingDirty();
    }

    /// 设置 margin.left，并清除 left auto 标记。
    pub fn setMarginLeft(self: *Node, value: f32) void {
        if (@abs(self.style.margin.left - value) < 0.001 and !self.style.marginLeftIsAuto()) return;
        self.style.margin.left = value;
        if (self.style.marginLeftIsAuto()) self.style.setMarginLeftAutoFallback(false);
        self.markSizingDirty();
    }

    /// 设置 margin.top，并清除 top auto 标记。
    pub fn setMarginTop(self: *Node, value: f32) void {
        if (@abs(self.style.margin.top - value) < 0.001 and !self.style.marginTopIsAuto()) return;
        self.style.margin.top = value;
        if (self.style.marginTopIsAuto()) self.style.setMarginTopAutoFallback(false);
        self.markSizingDirty();
    }

    /// Update an absolute/virtualized child's top offset without escalating
    /// through sizing propagation. Virtualized pools already have fixed child
    /// dimensions; only their layout position changes during scrolling.
    pub fn setMarginTopLayout(self: *Node, value: f32) void {
        if (@abs(self.style.margin.top - value) < 0.001 and !self.style.marginTopIsAuto()) return;
        self.style.margin.top = value;
        if (self.style.marginTopIsAuto()) self.style.setMarginTopAutoFallback(false);
        self.markLayoutDirty();
    }

    /// 设置 border.color（如果配置了过渡则自动插值）
    pub fn setBorderColor(self: *Node, color: types.Color) void {
        if (self.frame_state.frame_local.runtime.transitions) |slots| {
            if (slots.find(.border_color)) |slot| {
                if (!types.Color.eql(color, slot.to_color)) {
                    slot.from_color = self.style.border.color;
                    slot.to_color = color;
                    slot.start_time_ms = render_engine.current_frame_time_ms;
                    slot.active = true;
                    slots.any_active = true;
                    self.markRenderDirtyTracked(.border_change, "setBorderColor");
                }
                return;
            }
        }
        if (types.Color.eql(self.style.border.color, color)) return;
        self.style.border.color = color;
        self.markRenderDirtyTracked(.border_change, "setBorderColor");
    }

    /// 设置 border.width（如果配置了过渡则自动插值）
    pub fn setBorderWidth(self: *Node, width: f32) void {
        if (self.frame_state.frame_local.runtime.transitions) |slots| {
            if (slots.find(.border_width)) |slot| {
                if (@abs(width - slot.to_value) > 0.01) {
                    slot.from_value = self.style.border.width;
                    slot.to_value = width;
                    slot.start_time_ms = render_engine.current_frame_time_ms;
                    slot.active = true;
                    slots.any_active = true;
                    self.markRenderDirtyTracked(.border_change, "setBorderWidth");
                }
                return;
            }
        }
        self.style.border.setUniformWidth(width);
        self.markLayoutDirty();
    }

    /// 设置四边 border.color 覆盖（top, right, bottom, left）
    /// 传 null 表示该边回退到 border.color
    pub fn setBorderSideColors(
        self: *Node,
        allocator: Allocator,
        top: ?types.Color,
        right: ?types.Color,
        bottom: ?types.Color,
        left: ?types.Color,
    ) void {
        const ext = self.style.ensureExtPanic(allocator);
        ext.border_side_colors = .{
            .top = top,
            .right = right,
            .bottom = bottom,
            .left = left,
        };
        self.markRenderDirtyTracked(.border_change, "setBorderSideColors");
    }

    // ==================== 声明式 Transition API ====================

    /// 配置属性过渡（需要 allocator 分配 TransitionSlots）
    fn setTransition(self: *Node, allocator: Allocator, prop: types.TransitionProp, spec: types.TransitionSpec) void {
        if (self.frame_state.frame_local.runtime.transitions == null) {
            self.frame_state.frame_local.runtime.transitions = allocator.create(types.TransitionSlots) catch return;
            self.frame_state.frame_local.runtime.transitions.?.* = .{};
        }
        if (self.frame_state.frame_local.runtime.transitions.?.getOrCreate(prop)) |slot| {
            slot.spec = spec;
        }
    }

    /// 设置 background 颜色（如果配置了过渡则自动插值）
    /// style.background 字段已删；source of truth 是
    /// World.paint_state（element_id!=0xFFFFFFFF）或 standalone fallback（mock）。
    pub fn setBackground(self: *Node, color: types.Color) void {
        if (self.frame_state.frame_local.runtime.transitions) |slots| {
            if (slots.find(.background)) |slot| {
                if (!types.Color.eql(color, slot.to_color)) {
                    slot.from_color = self.getBackground();
                    slot.to_color = color;
                    slot.start_time_ms = render_engine.current_frame_time_ms;
                    slot.active = true;
                    slots.any_active = true;
                    self.markRenderDirtyTracked(.background_change, "setBackground");
                }
                return;
            }
        }
        if (types.Color.eql(self.getBackground(), color)) return;
        self.setBackgroundRaw(color);
        self.markRenderDirtyTracked(.background_change, "setBackground");
    }

    /// 设置 opacity（如果配置了过渡则自动插值）
    pub fn setOpacity(self: *Node, value: f32) void {
        if (self.frame_state.frame_local.runtime.transitions) |slots| {
            if (slots.find(.opacity)) |slot| {
                if (@abs(value - slot.to_value) > 0.001) {
                    slot.from_value = self.getOpacity();
                    slot.to_value = value;
                    slot.start_time_ms = render_engine.current_frame_time_ms;
                    slot.active = true;
                    slots.any_active = true;
                    // opacity 是 composite 属性：权威组合（四条写入路径收口的最后一处）。
                    self.markCompositePropDirty();
                }
                return;
            }
        }
        if (@abs(self.getOpacity() - value) < 0.001) return;
        self.setOpacityRaw(value);
        self.markCompositePropDirty();
    }

    /// 无副作用 background 写入口。SoA 唯一写路径。
    /// 不触发 transition / dirty / 去重。路由细节见 pca.writeBackground。
    pub fn setBackgroundRaw(self: *Node, color: types.Color) void {
        pca.writeBackground(self.world_ref, self.element_id_raw, @intFromPtr(self), color);
    }

    /// 无副作用 opacity 写入口。语义同 setBackgroundRaw。
    pub fn setOpacityRaw(self: *Node, value: f32) void {
        pca.writeOpacity(self.world_ref, self.element_id_raw, @intFromPtr(self), value);
    }

    /// style.background 字段已删，从 World.paint_state
    /// (element_id!=0xFFFFFFFF) 或 standalone fallback (mock) 读。无数据时返回默认。
    pub fn getBackground(self: *const Node) types.Color {
        return pca.readBackground(self.world_ref, self.element_id_raw, @intFromPtr(self));
    }

    /// 本节点连同子树不进入绘制：display:none，或完全透明且未要求透明时保持渲染。
    /// 渲染 / tick 遍历里所有"跳过不可见子树"的判断都走这一个判据。
    pub fn isPaintSkipped(self: *const Node) bool {
        if (self.style.display == .none) return true;
        return self.getOpacity() == 0 and !self.style.keep_rendering_when_transparent();
    }

    /// 自身及所有祖先都不是 display:none（即"在渲染树里"）。焦点遍历 / 无障碍用它
    /// 排除被隐藏子树里的节点。
    pub fn isDisplayedInTree(self: *const Node) bool {
        var cur: ?*const Node = self;
        while (cur) |n| : (cur = n.parent) {
            if (n.style.display == .none) return false;
        }
        return true;
    }

    /// display 切换：会改变兄弟排布（占位 / gap），标脏自身与父节点布局并重绘。
    pub fn setDisplay(self: *Node, d: types.Display) void {
        if (self.style.display == d) return;
        self.style.display = d;
        self.markLayoutDirty();
        if (self.parent) |p| p.markLayoutDirty();
        self.markRenderDirty();
        self.markHitStructureDirty();
    }

    pub fn getOpacity(self: *const Node) f32 {
        return pca.readOpacity(self.world_ref, self.element_id_raw, @intFromPtr(self));
    }

    /// 设置 translate_x（如果配置了过渡则自动插值）
    pub fn setTranslateX(self: *Node, value: f32) void {
        if (self.frame_state.frame_local.runtime.transitions) |slots| {
            if (slots.find(.translate_x)) |slot| {
                if (@abs(value - slot.to_value) > 0.1) {
                    slot.from_value = self.style.translate_x;
                    slot.to_value = value;
                    slot.start_time_ms = render_engine.current_frame_time_ms;
                    slot.active = true;
                    slots.any_active = true;
                    // translate 是 composite 类属性：统一权威失效组合（interaction+
                    // composite+cache 失效），与 transition tick / animator / hooks 一致。
                    self.markCompositePropDirty();
                }
                return;
            }
        }
        self.style.translate_x = value;
        self.markCompositePropDirty();
    }

    /// 设置 rotate（如果配置了过渡则自动插值）
    pub fn setRotate(self: *Node, allocator: Allocator, value: f32) void {
        if (self.frame_state.frame_local.runtime.transitions) |slots| {
            if (slots.find(.rotate)) |slot| {
                if (@abs(value - slot.to_value) > 0.001) {
                    slot.from_value = self.style.rotate();
                    slot.to_value = value;
                    slot.start_time_ms = render_engine.current_frame_time_ms;
                    slot.active = true;
                    slots.any_active = true;
                    self.markInteractionDirty();
                    self.markCompositeDirty();
                }
                return;
            }
        }
        self.style.ensureExtPanic(allocator).rotate = value;
        self.markInteractionDirty();
        self.markCompositeDirty();
    }

    /// 立即设值并同步 transition slot（**不**触发动画）：首帧定位/瞬移场景用。
    /// 组件不得直接改写 slot 的 from/to_value（引擎内部状态）——统一走这里。
    pub fn snapTransition(self: *Node, allocator: Allocator, prop: types.TransitionProp, value: f32) void {
        if (self.frame_state.frame_local.runtime.transitions) |slots| {
            if (slots.find(prop)) |slot| {
                slot.from_value = value;
                slot.to_value = value;
                slot.active = false;
            }
        }
        switch (prop) {
            .width => {
                self.style.width = .{ .px = @max(0, value) };
                self.markSizingDirty();
            },
            .translate_x => {
                self.style.translate_x = value;
                self.markCompositePropDirty();
            },
            .translate_y => {
                self.style.translate_y = value;
                self.markCompositePropDirty();
            },
            .opacity => {
                self.setOpacityRaw(value);
                self.markCompositePropDirty();
            },
            .scale_x => {
                self.style.ensureExtPanic(allocator).scale_x = value;
                self.markCompositePropDirty();
            },
            .scale_y => {
                self.style.ensureExtPanic(allocator).scale_y = value;
                self.markCompositePropDirty();
            },
            .rotate => {
                self.style.ensureExtPanic(allocator).rotate = value;
                self.markCompositePropDirty();
            },
            else => {},
        }
    }

    /// 设置 transform_origin（影响 scale/rotate 的基准点）
    pub fn setTransformOrigin(self: *Node, allocator: Allocator, value: types.TransformOrigin) void {
        const ext = self.style.ensureExtPanic(allocator);
        ext.transform_origin = value;
        self.markInteractionDirty();
        self.markCompositeDirty();
    }

    /// 设置 width（如果配置了过渡则自动插值）
    pub fn setWidth(self: *Node, value: f32) void {
        if (self.frame_state.frame_local.runtime.transitions) |slots| {
            if (slots.find(.width)) |slot| {
                if (@abs(value - slot.to_value) > 0.1) {
                    const current = switch (self.style.width) {
                        .px => |v| v,
                        else => self.rectFromWorldOrFallback().w, // 从 layout 结果取当前宽度
                    };
                    slot.from_value = current;
                    slot.to_value = value;
                    slot.start_time_ms = render_engine.current_frame_time_ms;
                    slot.active = true;
                    slots.any_active = true;
                    self.markLayoutDirty();
                }
                return;
            }
        }
        self.style.width = .{ .px = value };
        self.markLayoutDirty();
    }

    /// 一次性为多个属性配置隐式动画过渡
    /// 之后通过 setBackground/setOpacity/setBorderColor/setTranslateX/setTranslateY/setWidth
    /// 修改属性时自动走过渡动画。
    pub fn enableImplicitAnimation(
        self: *Node,
        allocator: Allocator,
        props: []const types.TransitionProp,
        spec: types.TransitionSpec,
    ) void {
        for (props) |prop| {
            self.setTransition(allocator, prop, spec);
        }
    }

    /// 应用 CSS 风格的 comptime transition 解析结果
    ///
    /// 用法:
    /// ```zig
    /// node.applyTransition(allocator, comptime recipe.transition("background 200ms ease-out, opacity 150ms"));
    /// ```
    pub fn applyTransition(self: *Node, allocator: Allocator, entries: []const recipe_mod.TransitionEntry) void {
        for (entries) |entry| {
            self.setTransition(allocator, entry.prop, entry.spec);
        }
    }

    pub fn requestCompositeAnimationLinger(self: *Node, affects_opacity: bool, affects_transform: bool) void {
        if (!affects_opacity and !affects_transform) return;
        self.frame_state.frame_local.runtime.linger.composite = @max(self.frame_state.frame_local.runtime.linger.composite, @as(u8, 2));
        if (affects_opacity) {
            self.frame_state.frame_local.runtime.linger.opacity = @max(self.frame_state.frame_local.runtime.linger.opacity, @as(u8, 2));
        }
        if (affects_transform) {
            self.frame_state.frame_local.runtime.linger.transform = @max(self.frame_state.frame_local.runtime.linger.transform, @as(u8, 2));
        }
    }

    pub fn consumeCompositeAnimationLingerFrame(self: *Node) bool {
        var active = false;
        if (self.frame_state.frame_local.runtime.linger.composite > 0) {
            self.frame_state.frame_local.runtime.linger.composite -= 1;
            active = true;
        }
        if (self.frame_state.frame_local.runtime.linger.opacity > 0) {
            self.frame_state.frame_local.runtime.linger.opacity -= 1;
            active = true;
        }
        if (self.frame_state.frame_local.runtime.linger.transform > 0) {
            self.frame_state.frame_local.runtime.linger.transform -= 1;
            active = true;
        }
        return active;
    }

    // 15 dirty 方法实现整体搬到 node_dirty.zig。
    // 以下为 thin delegate，保持原 pub/private 可见性 + node.zig 内
    // self.markX() caller 零改（仍调本地 delegate）。
    pub fn markLayoutDirty(self: *Node) void {
        node_dirty.markLayoutDirty(self);
    }
    pub fn markSizingDirty(self: *Node) void {
        node_dirty.markSizingDirty(self);
    }
    pub fn markRuntimeIndexDirty(self: *Node) void {
        node_dirty.markRuntimeIndexDirty(self);
    }
    pub fn markRuntimeIndexFullRebuild(self: *Node) void {
        node_dirty.markRuntimeIndexFullRebuild(self);
    }
    pub fn markOrderDirty(self: *Node) void {
        node_dirty.markOrderDirty(self);
    }
    pub fn markInteractionDirty(self: *Node) void {
        node_dirty.markInteractionDirty(self);
    }
    // 升 pub —— node_interaction 经 self.markHit*Dirty() 跨模块调
    pub fn markHitSemanticsDirty(self: *Node) void {
        node_dirty.markHitSemanticsDirty(self);
    }
    pub fn markHitStructureDirty(self: *Node) void {
        node_dirty.markHitStructureDirty(self);
    }
    // 升 pub —— node_tree 经 self.bubbleChildRuntimeIndexDirty() 跨模块调
    pub fn bubbleChildRuntimeIndexDirty(self: *Node, full_rebuild: bool) void {
        node_dirty.bubbleChildRuntimeIndexDirty(self, full_rebuild);
    }
    pub fn markSubtreeDirty(self: *Node) void {
        node_dirty.markSubtreeDirty(self);
    }
    pub fn markCompositeDirty(self: *Node) void {
        node_dirty.markCompositeDirty(self);
    }

    /// composite 类属性（opacity/translate/scale/rotate）写入后的唯一权威失效组合。
    pub fn markCompositePropDirty(self: *Node) void {
        node_dirty.markCompositePropDirty(self);
    }

    /// composite 属性逐帧动画驱动专用（不 bump content 版本，保 surface 复用）。
    pub fn markCompositeAnimFrameDirty(self: *Node) void {
        node_dirty.markCompositeAnimFrameDirty(self);
    }
    fn isOutOfBandRenderUnit(self: *const Node) bool {
        return node_dirty.isOutOfBandRenderUnit(self);
    }
    pub fn markRenderDirty(self: *Node) void {
        node_dirty.markRenderDirty(self);
    }
    fn markRenderDirtyTracked(self: *Node, reason: debug_trace.RenderReason, comptime source: []const u8) void {
        node_dirty.markRenderDirtyTracked(self, reason, source);
    }

    pub fn addDebugState(self: *Node, ptr: *anyopaque) void {
        for (self.meta.ownership.debug_slots.state_ptrs[0..self.meta.ownership.debug_slots.state_count]) |slot| {
            if (slot != null and slot.? == ptr) return;
        }
        if (self.meta.ownership.debug_slots.state_count >= self.meta.ownership.debug_slots.state_ptrs.len) return;
        self.meta.ownership.debug_slots.state_ptrs[self.meta.ownership.debug_slots.state_count] = ptr;
        self.meta.ownership.debug_slots.state_count += 1;
    }

    pub fn addDebugSignal(self: *Node, ptr: *anyopaque, label: []const u8, kind: DebugSignalKind) void {
        for (self.meta.ownership.debug_slots.signals[0..self.meta.ownership.debug_slots.signal_count]) |slot| {
            if (slot != null and slot.?.ptr == ptr) return;
        }
        if (self.meta.ownership.debug_slots.signal_count >= self.meta.ownership.debug_slots.signals.len) return;
        self.meta.ownership.debug_slots.signals[self.meta.ownership.debug_slots.signal_count] = .{
            .ptr = ptr,
            .label = label,
            .kind = kind,
        };
        self.meta.ownership.debug_slots.signal_count += 1;
    }

    // 渲染缓存 6 方法 + TextHashSnapshot 抽到
    // node_render_cache.zig。以下 thin delegate（buildCachedRenderSlice
    // 原 static fn 已移为模块级 free function，不再在 Node 上暴露）。
    pub const TextHashSnapshot = node_render_cache.TextHashSnapshot;

    pub fn cacheRenderCommands(self: *Node, allocator: Allocator, commands: []const DisplayItem, scroll_ox: f32, scroll_oy: f32) void {
        node_render_cache.cacheRenderCommands(self, allocator, commands, scroll_ox, scroll_oy);
    }
    pub fn cachePromotedRenderCommands(
        self: *Node,
        allocator: Allocator,
        commands: []const DisplayItem,
        scroll_ox: f32,
        scroll_oy: f32,
        promoted_layer_id: u32,
        world_bounds: ComputedRect,
        world_transform: Transform2D,
        self_content_command_count: u32,
        descendant_content_command_count: u32,
        descendant_regular_command_count: u32,
        descendant_sticky_command_count: u32,
        descendant_overlay_command_count: u32,
        descendant_tail_command_count: u32,
        regular_child_slices: []const ChildCommandSlice,
    ) void {
        node_render_cache.cachePromotedRenderCommands(self, allocator, commands, scroll_ox, scroll_oy, promoted_layer_id, world_bounds, world_transform, self_content_command_count, descendant_content_command_count, descendant_regular_command_count, descendant_sticky_command_count, descendant_overlay_command_count, descendant_tail_command_count, regular_child_slices);
    }
    pub fn invalidateRenderCache(self: *Node) void {
        node_render_cache.invalidateRenderCache(self);
    }
    pub fn invalidatePromotedRenderCache(self: *Node) void {
        node_render_cache.invalidatePromotedRenderCache(self);
    }
    pub fn cacheSubtreePayloadCommands(
        self: *Node,
        allocator: Allocator,
        commands: []const DisplayItem,
        self_content_command_count: u32,
        transform_id: u32,
        effect_id: u32,
        clip_id: u32,
        world_bounds: ComputedRect,
    ) void {
        node_render_cache.cacheSubtreePayloadCommands(self, allocator, commands, self_content_command_count, transform_id, effect_id, clip_id, world_bounds);
    }
    pub fn invalidateSubtreePayloadCache(self: *Node) void {
        node_render_cache.invalidateSubtreePayloadCache(self);
    }
    pub fn getOrComputeTextHashes(self: *Node, t: *const TextProps) TextHashSnapshot {
        return node_render_cache.getOrComputeTextHashes(self, t);
    }

    /// 从父节点移除子节点，递归触发 onCleanup。
    /// 注意: 不释放 child 内存。调用者需手动 `cx.freeNode(child)` 释放。
    pub fn removeChild(self: *Node, child: *Node) void {
        node_tree.removeChild(self, child);
    }

    pub fn removeChildIncremental(self: *Node, child: *Node) void {
        node_tree.removeChildIncremental(self, child);
    }

    pub fn removeChildRetained(self: *Node, child: *Node) void {
        node_tree.removeChildRetained(self, child);
    }

    /// 保留模式: 递归销毁节点及其子树
    ///
    /// 注意: 不负责 dispose scope。Scope 的生命周期由 Scope 树管理
    /// （父 Scope.dispose() 递归 dispose 子 Scope）。调用者应在 destroy
    /// 之前先 dispose scope，再 clearNodeScopes 清除悬垂指针。
    pub fn destroy(self: *Node, allocator: Allocator) void {
        node_lifecycle.destroy(self, allocator);
    }

    /// 移除所有子节点，递归触发 onCleanup。
    /// 注意: 不释放子节点内存。调用者需对每个子节点手动 `cx.freeNode()` 释放。
    pub fn removeAllChildren(self: *Node) void {
        node_tree.removeAllChildren(self);
    }

    // 升 pub —— node_interaction 跨模块调（生命周期 §N4 抽出随迁）
    pub fn releasePathGeometry(self: *Node, allocator: Allocator) void {
        node_lifecycle.releasePathGeometry(self, allocator);
    }

    fn releaseStrokeGeometry(self: *Node, allocator: Allocator) void {
        node_lifecycle.releaseStrokeGeometry(self, allocator);
    }

    pub fn releaseCustomClipGeometry(self: *Node, allocator: Allocator) void {
        node_lifecycle.releaseCustomClipGeometry(self, allocator);
    }

    /// freeNode 用——把节点持有的 path 堆内存（path /
    /// stroke / custom_clip）经 World.layout_output slot 释放。必须在
    /// elements.destroy 之前调（element_id 还有效，layoutOutputPtr 能拿到
    /// slot；之后 slot 复用会脏）。语义同 §a freeNode 先 free owned text。
    pub fn releaseAllGeometry(self: *Node, allocator: Allocator) void {
        node_lifecycle.releaseAllGeometry(self, allocator);
    }

    // 升 pub —— node_dirty.zig 跨模块调（交互子域 Stage 3 抽出时随迁）
    pub fn invalidateCustomClipGeometryCache(self: *Node) void {
        node_interaction.invalidateCustomClipGeometryCache(self);
    }
};

// fireMountIfNeeded / fireCleanupCallbacks / clearNodeScopes
// 原即 file-scope free fn（非 Node 方法），整体搬到 node_lifecycle.zig。
// 此处 re-export 保持公开 API（外部 core/control_flow/hooks 等调）。
pub const fireMountIfNeeded = node_lifecycle.fireMountIfNeeded;
pub const fireCleanupCallbacks = node_lifecycle.fireCleanupCallbacks;
pub const clearNodeScopes = node_lifecycle.clearNodeScopes;

test {
    _ = @import("text_update_tests.zig");
}

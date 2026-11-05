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
/// World is Node property source of truth (rect/paint/content/layout_output). node.zig imports it
/// **no cycle**, world.zig and its dependencies don't back-import node.zig (verified).
/// This is premise for removing 19 process-level global callbacks: Node can get owner World
/// directly, no need to "smuggle World via global variable".
const world_mod = @import("world.zig");

/// Sentinel for Node.world_id: not yet registered to any World (cx-less test mock or naked Node
/// before Cx.init).
pub const INVALID_WORLD_ID: u16 = 0xFFFF;

var bracket_debug_node_cache: ?u32 = null;

fn bracketDebugNodeFilter() ?u32 {
    if (bracket_debug_node_cache) |v| return if (v == std.math.maxInt(u32)) null else v;
    const raw = @import("zenit_environment").getNative("ZENIT_TEXT_BRACKET_NODE") orelse {
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

// upgrade pub, node_render_cache.zig cross-module call (pure debug helper)
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

/// Core UI tree data structure, runtime representation of all visible elements. Contains style,
/// layout result (rect), children, dirty marks, render cache, event handling, all runtime state.
/// Layout/render/event engines operate directly on this.
// Dirty notify hook. Cx.init sets; core.zig callbacks convert (element_id_raw, kind) to
// world.markDirty call. Node doesn't import core.zig to avoid cycle. Callback unit + 15 dirty
// methods moved to node_dirty.zig, re-export here keeps node.DirtyKind/node.setDirtyNotifyCallback
// public API unbroken.
pub const DirtyKind = node_dirty.DirtyKind;
pub const DirtyNotifyFn = node_dirty.DirtyNotifyFn;
pub const setDirtyNotifyCallback = node_dirty.setDirtyNotifyCallback;

// v0.5-P3 Stage 3-2 (2026-05-01): structure notify hook. Node.appendChild/removeChild call hook let
// Cx sync World.elements parent-child list. Node has no World pointer to avoid cycle; both node
// parties element_id_raw == 0xFFFFFFFF are legacy nodes, hook return. Structure callback unit + 7
// tree methods moved to node_tree.zig. Re-export here keeps public API (core.zig
// setStructureNotifyCallback).
pub const StructureKind = node_tree.StructureKind;
pub const StructureNotifyFn = node_tree.StructureNotifyFn;
pub const setStructureNotifyCallback = node_tree.setStructureNotifyCallback;

// v0.5-P3 Stage 4-2 (session 27): global rect query hook. For cx-less functions
// (computeStickyOffset/tickBeforeRender/event_dispatcher hit-test) read from World.LayoutTable;
// fail caller should fallback to node.rect.
pub const RectQueryFn = node_lifecycle.RectQueryFn;
pub const setRectQueryCallback = node_lifecycle.setRectQueryCallback;
pub const RectWriteFn = node_lifecycle.RectWriteFn;
pub const setRectWriteCallback = node_lifecycle.setRectWriteCallback;
pub const NodeCreateHookFn = node_lifecycle.NodeCreateHookFn;
pub const setNodeCreateHook = node_lifecycle.setNodeCreateHook;
/// P0-3 stage 2: cross-Cx cross-talk detection (see node_lifecycle.zig top note).
pub const setWorldOwnershipCheck = node_lifecycle.setWorldOwnershipCheck;
/// Node create with explicit owner World (P0-3 multi-window entry, see Cx.createNode).
pub const createIn = node_lifecycle.createIn;
/// Explicit recover standalone fallback storage (GPA leak check can't cover, need manual).
pub const deinitStandaloneRects = node_lifecycle.deinitStandaloneRects;
pub const standaloneRectCount = node_lifecycle.standaloneRectCount;
pub const prelayoutZeroRectReads = struct {
    pub fn get() u64 {
        return node_lifecycle.prelayout_zero_rect_reads;
    }
};
// RectQuery/RectWrite/NodeCreateHook callback unit + standalone fallback rect storage
// (g_standalone_rects + Get/Set) moved to node_lifecycle.zig (§L standalone pitfall core, migrate
// whole to prevent partial). Re-export here keeps public API (core.zig setRect*Callback).

// §a NodeContent SoA + §b paint state SoA callback/standalone-fallback/routing all extracted to
// paint_content_accessor.zig. Re-export here callback types + registrar (core.zig
// setContentTextWriteCallback etc register World mirror hook). Node get/setText/Image/Icon +
// getBackground/setBackgroundRaw etc methods drop to thin one-liner, delegate to pca.* routing free
// function.
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

/// Text hash cache, avoid same content/spans multi-render same frame hash again. 7 cached_text_*
/// fields on Node collapse here, save 6 field slots.
pub const TextHashCache = struct {
    content_version: u32 = 0,
    content_ptr: usize = 0,
    content_len: usize = 0,
    spans_ptr: usize = 0,
    spans_len: usize = 0,
    content_hash: u64 = 0,
    spans_hash: u64 = 0,
};

/// Custom clip geometry metadata, provider fn + context + cache state. 5 related fields collapse
/// here, save 4 field slots.
pub const CustomClipMeta = struct {
    provider: ?Node.CustomClipGeometryProviderFn = null,
    provider_context: ?*anyopaque = null,
    cache_rect: ComputedRect = ComputedRect.init(-1, -1, -1, -1),
    epoch: u32 = 1,
    cache_epoch: u32 = 0,
};

/// Node paint info: paint_order + subtree paint range ([min, max] hit-test). paint_order +
/// subtree_paint_min/max 3 fields collapsed -> 1.
pub const PaintInfo = struct {
    /// this node global paint pass sequence number
    order: u64 = 0,
    /// subtree hit-test paint_order range [min, max]
    subtree_min: u64 = 0,
    subtree_max: u64 = 0,
};

/// Node hit-test index metadata. hit_proxy_start/len + hit_epoch + hit_clip_chain_id 4 fields
/// collapsed -> 1.
pub const HitIndex = struct {
    proxy_start: u32 = 0,
    proxy_len: u16 = 0,
    epoch: u32 = 0,
    clip_chain_id: ?u32 = null,
    /// Hit space this node's world matrix, proxies and clip entry are stored in (0 = world; see
    /// hit_runtime.HitLayer).
    layer: u32 = 0,
    /// For a hit-layer node: the layer it opened at the last build.
    own_layer: u32 = 0,
    /// Paint-order numbering scope `PaintInfo` is expressed in (hit_runtime.HitBlock; 0 = the
    /// root block). A direct child of a hit-layer node roots its own block.
    block: u32 = 0,
};

/// animation linger frame count, keep promote state few frames to avoid animation end layer shrink
/// flicker. composite/opacity/transform linger 3 fields collapsed -> 1.
pub const AnimationLinger = struct {
    composite: u8 = 0,
    opacity: u8 = 0,
    transform: u8 = 0,
};

/// vector path stroke state (independent of path_geometry). stroke_geometry/color/width/line_join 4
/// fields collapsed -> 1.
// NodeLayoutOutput and child structs moved to standalone node_layout_output.zig (let node.zig and
// layout_output_table.zig both reference without cycle). Re-export here keeps
// node.NodeStroke/node.NodeLayoutOutput etc old ref points unbroken.
const nlo = @import("node_layout_output.zig");
pub const NodeGeometries = nlo.NodeGeometries;
pub const NodeStroke = nlo.NodeStroke;
pub const NodeVector = nlo.NodeVector;
pub const LayoutArtifacts = nlo.LayoutArtifacts;
pub const NodeLayoutOutput = nlo.NodeLayoutOutput;

// NodeLayoutOutput SoA, World.LayoutOutputTable is source of truth (in-place fields deleted).
// Callback/standalone-fallback/routing all in pca (paint_content_accessor.zig, same shape as §a
// content/§b paint). cx-less mock (element_id==0xFFFFFFFF, hit_runtime/tests Node.create) use pca
// standalone heap pool (stable address, layoutOutputPtr escapes/in-place change). Re-export
// callback types + registrar (core.zig register World hook).
pub const LayoutOutputWriteFn = pca.LayoutOutputWriteFn;
pub const LayoutOutputReadFn = pca.LayoutOutputReadFn;
pub const LayoutOutputPtrFn = pca.LayoutOutputPtrFn;
pub const setLayoutOutputWriteCallback = pca.setLayoutOutputWriteCallback;
pub const setLayoutOutputReadCallback = pca.setLayoutOutputReadCallback;
pub const setLayoutOutputPtrCallback = pca.setLayoutOutputPtrCallback;

/// Custom draw callback + context (v0.5: fn ptr + context 2 fields collapsed -> ?CustomDraw).
pub const CustomDraw = struct {
    callback: *const fn (DrawContext, ?*anyopaque) anyerror!void,
    context: ?*anyopaque = null,
};

/// Custom hit test callback + context (v0.5: fn ptr + context 2 fields collapsed ->
/// ?CustomHitTest).
pub const CustomHitTest = struct {
    callback: Node.CustomHitTestFn,
    context: ?*anyopaque = null,
};

/// Hit proxy provider callback + context (v0.5: 2 fields collapsed -> ?HitProxyProvider).
pub const HitProxyProvider = struct {
    callback: Node.HitProxyProviderFn,
    context: ?*anyopaque = null,
};

/// Hit-test dirty bits (v0.5: 3 bool fields collapsed -> 1 packed struct).
pub const HitDirty = packed struct(u8) {
    geometry: bool = false,
    semantics: bool = false,
    structure: bool = false,
    _reserved: u5 = 0,
};

/// Runtime-index dirty bits (v0.5: 4 bool fields collapsed -> 1 packed struct).
/// dirty/subtree_dirty/full_rebuild/subtree_full_rebuild
pub const RuntimeIndexFlags = packed struct(u8) {
    dirty: bool = true,
    subtree_dirty: bool = true,
    full_rebuild: bool = true,
    subtree_full_rebuild: bool = true,
    _reserved: u4 = 0,
};

/// Left mouse down, what framework does to keyboard focus (see
/// `NodeInteraction.pointer_down_focus`).
pub const PointerDownFocus = enum {
    /// default: give focus to hit node self or nearest focusable ancestor; none all the way clear
    /// focus.
    transfer,
    /// keep pre-click focus unchanged: don't move to any node, don't clear. Use for toolbar
    /// buttons, floating action bar, non-modal panel etc "click to act, don't interrupt editing
    /// node" UI.
    preserve,
};

/// Node interaction metadata (v0.5: focus + semantics 5 fields collapsed -> 1 NodeInteraction).
pub const NodeInteraction = struct {
    window_region: @import("system_sdk").window_chrome.Region = .inherit,
    /// Hit-test this subtree in the node's own local space (hit_runtime.HitLayer): changes of this
    /// node's transform (a scroll container's content offset) cost no hit-index rebuild. Pair
    /// every such change with `markHitLayerMotionDirty`/`markHitLayerMotionPropDirty`.
    hit_layer: bool = false,
    /// Focus management
    focusable: bool = false,
    tab_index: ?i32 = null,
    focus_scope: ?focus_mod.FocusScopeConfig = null,
    /// Whether the default left-click focus behavior applies to nodes in this parent chain.
    ///
    /// On click the framework walks from the hit node up the parent chain: the first `.preserve`
    /// node -> focus unchanged (whoever had focus keeps it, or stays empty); the first focusable
    /// node -> receives focus. A node that is both `.preserve` and focusable: `.preserve` wins
    /// (tab-reachable, but a mouse click does not steal focus, e.g. toolbar buttons). Set on a
    /// toolbar container it covers the whole toolbar; a deeper focusable child (e.g. embedded
    /// Input)
    /// still takes focus normally.
    ///
    /// Only affects the framework default focus decision: mouse_down/click dispatch normally and
    /// explicit focus calls in handlers are unrestricted. Decided before mouse_down dispatch
    /// against
    /// the current tree, same timing as focusable target lookup.
    pointer_down_focus: PointerDownFocus = .transfer,
    /// a11y attributes
    a11y: ?A11yProps = null,
    /// Synchronous platform text-input endpoint. The focused node is the only
    /// node whose client is active; Cx owns native session activation.
    text_input_client: ?types.TextInputClient = null,
    /// A text/IME commit consumed with .stop owns its redraw scheduling.
    /// Async clients may wait for their output; errors and local UI changes
    /// must invalidate explicitly. Preedit and keyboard defaults are unchanged.
    deferred_text_input_redraw: bool = false,
    /// Key context (Action dispatch system)
    key_context: ?[]const u8 = null,
};

/// Node delegate reference (v0.5: interaction_delegate + inspect_delegate 2 fields collapsed -> 1).
pub const NodeDelegate = struct {
    interaction: ?*Node = null,
    inspect: ?*Node = null,
    /// Descendant that draws this node's control frame (Input's field inside its label/helper
    /// column). Attachments that shape the frame (Group corner radii, shared-edge colors) go
    /// there; layout attachments (overlap margin) stay on this node.
    frame: ?*Node = null,
};

/// Node lifecycle hooks (v0.5: on_mount + on_cleanup 2 fields collapsed -> 1).
pub const NodeLifecycle = struct {
    on_mount: ?HandlerRef = null,
    on_cleanup: ?HandlerRef = null,
};

/// Sticky visual compensation offset (v0.5: x + y 2 fields collapsed -> 1).
pub const StickyOffset = struct {
    x: f32 = 0,
    y: f32 = 0,
    state: StickyState = .{},

    pub fn isStuck(self: StickyOffset) bool {
        return self.state.pinned;
    }
};

/// Sticky engagement state (each frame by tick and offset write, read-only observe). engaged_*:
/// this direction non-zero compensation (away from natural). pinned: compensation and not
/// clamp-container cut short, pinned to engagement edge. constrained: clamp-container cut desired
/// compensation (pushed/in-handoff, includes fully pushed back natural). pinned and constrained
/// mutually exclusive.
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

/// Node world coordinate transform + inverse (hit-test use). world_transform +
/// inverse_world_transform 2 fields collapsed -> 1.
pub const WorldTransform = struct {
    matrix: Transform2D = .{},
    inverse: Transform2D = .{},
};

/// Node render command cache (own subtree + promoted layer each one). cached_commands +
/// promoted_cached_commands 2 fields collapsed -> 1.
pub const RenderCache = struct {
    own: ?CachedRenderSlice = null,
    promoted: ?CachedRenderSlice = null,
    /// downstream regression: non-promoted clean subtree cross-frame display payload cache.
    /// prebuild pass splice clean subtree stamp hits directly, skip full tree paint re-record.
    subtree_payload: ?CachedRenderSlice = null,
    /// Cross-frame copy of this node's **own** content items (background / border / outline /
    /// text / media), reused while the node itself is clean even when its subtree is being
    /// re-recorded (dirty-path ancestors, leaves next to them). See render_engine
    /// tryReplayOwnContentCache.
    own_payload: ?CachedRenderSlice = null,
    /// render_engine/retained_memo.zig Memo: last property-tree / scene-runtime output of this
    /// node's subtree (type-erased to keep node.zig free of render-engine types).
    retained_memo: ?*anyopaque = null,
};

/// before_render hooks (main + child list). on_before_render + before_render_hook_count +
/// before_render_hooks 3 fields collapsed -> 1.
pub const BeforeRenderHooks = struct {
    main: ?*const fn (*Node) void = null,
    count: u8 = 0,
    hooks: [8]?*const fn (*Node) void = @as([8]?*const fn (*Node) void, @splat(null)),
    /// Bit i set: hooks[i] was registered with `.self` scope (see BeforeRenderScope).
    self_only_mask: u8 = 0,
    /// Bit i set: hooks[i] was registered with `.self` or `.dirty_marking` scope: it writes only
    /// through dirty-marking entries (Node.beforeRenderHooksCacheTrusted).
    trusted_mask: u8 = 0,
};

/// What a before_render hook may change. `.self`: only this node's own style /
/// content, written through dirty-marking setters (setStyle, setBackground,
/// markRenderDirty after a raw write); never descendants, siblings or a
/// transform that moves other content. A self-scoped node keeps the paint
/// prefix intact, so everything painted after it can still be prebuilt and
/// reused across frames. `.subtree` (default): anything; the render pass stops
/// prebuilding at this node. Debug/ReleaseSafe builds audit `.self` claims.
///
/// `.dirty_marking`: the hook may change this node, its transform included, but only through
/// dirty-marking entries (markRenderDirty after a raw write, setters, markCompositePropDirty), and
/// writes no other node. It still stops prebuilding at this node like `.subtree`, but caches of the
/// node and of subtrees containing it stay valid: they see every change through dirty bits, as
/// they see event-handler writes (custom-draw / loop animation ticks).
pub const BeforeRenderScope = enum { subtree, self, dirty_marking };

/// Scope state associated with node: scope ptr + binding back-pointer. scope +
/// scope_binding_node_slot 2 fields collapsed -> 1. Scope is component root node reactive range;
/// slot is bindScopeToNode register back pointer, clearNodeScopes null before freeNode to avoid
/// stale ptr when parent scope dispose.
pub const ScopeBinding = struct {
    scope: ?*Scope = null,
    node_slot: ?*?*Node = null,
};

/// Node version (content/composite) for paint cache invalidation. content_version +
/// composite_version 2 fields collapsed -> 1.
pub const NodeVersions = struct {
    content: u32 = 1,
    composite: u32 = 1,
};

/// Node metadata: component type name + test identifier (DevTools/test_harness use). component_name
/// + test_id 2 fields collapsed -> 1.
pub const NodeMeta = struct {
    component_name: ?[]const u8 = null,
    test_id: ?[]const u8 = null,
};

/// Layout phase output (layout pass artifacts). children_bbox + text_layout 2 fields collapsed ->
/// 1. Both written by layout_engine, render/hit phases read-only consume.
// LayoutArtifacts/NodeVector/NodeLayoutOutput/NodeGeometries defs moved node_layout_output.zig (see
// above nlo re-export block).

/// Custom render/hit hooks collection. custom_draw + custom_hit_test + hit_proxy_provider +
/// custom_clip_meta 4 fields collapsed -> 1 sub-struct CustomHooks (save 3 field slots). Most nodes
/// all null/default, concentrate saves cache locality.
pub const CustomHooks = struct {
    /// Custom draw callback: replace child recursion, directly write DisplayItem to
    /// lowering_buffer.
    draw: ?CustomDraw = null,
    /// Custom hit test callback
    hit_test: ?CustomHitTest = null,
    /// Hit proxy provider (hit substitute).
    hit_proxy: ?HitProxyProvider = null,
    /// Custom clip mask provider + cache metadata
    clip_meta: CustomClipMeta = .{},
};

/// Node cache collection (versions + text hash cache + paint cache). versions + cached_text_hash +
/// render_cache 3 fields collapsed -> 1 NodeCaches (save 2 field slots).
pub const NodeCaches = struct {
    /// content/composite version (paint cache invalidation)
    versions: NodeVersions = .{},
    /// text hash cache (skip per-frame re-hash)
    text_hash: TextHashCache = .{},
    /// Last published semantics, including borrowed text/span contents.
    text_signature: text_change.Signature = text_change.signature(null),
    /// command cache (own + promoted)
    commands: RenderCache = .{},
};

/// Node bitmap/icon content (image + icon mutually exclusive). image + icon 2 fields collapsed -> 1
/// sub-struct NodeMedia (save 1 field slot). Most nodes image=null icon=null.
pub const NodeMedia = struct {
    /// bitmap (CALayer texture/texture_id reference)
    image: ?ImageProps = null,
    /// vector icon (icon_id index, resolve by size)
    icon: ?IconProps = null,
};

// NodeContent/NodeVisuals deleted, content (§a) + layout_output (§L) all SoA to World, Node no
// visuals field.

/// Node ownership: identity + lifetime merged collection. P-Node-SoA-2: NodeIdentity (meta +
/// debug_slots) + NodeLifetime (hooks + scope + delegate) 5 fields collapsed -> 1 NodeOwnership
/// (save 1 field slot).
pub const NodeOwnership = struct {
    /// component_name + test_id (identity.meta)
    meta: NodeMeta = .{},
    /// DevTools debug state/signal association slots (identity.debug_slots)
    debug_slots: DebugSlots = .{},
    /// on_mount + on_cleanup hooks (lifetime.hooks)
    hooks: NodeLifecycle = .{},
    /// associated reactive Scope binding (lifetime.scope)
    scope: ScopeBinding = .{},
    /// interaction/inspect delegate node (lifetime.delegate)
    delegate: NodeDelegate = .{},
};

/// Node spatial index (world transform + paint order + hit index 3 index data). world_xform +
/// paint_info + hit_index 3 fields collapsed -> 1 NodeSpatial (save 2 field slots). All written by
/// layout/paint/hit pass; render/event read-only consume.
pub const NodeSpatial = struct {
    /// world transform + inverse
    world: WorldTransform = .{},
    /// paint order index (DFS number + subtree range)
    paint: PaintInfo = .{},
    /// hit test index (proxy ranges + epoch + clip chain)
    hit: HitIndex = .{},
};

/// Node dirty marks collection (layout/pipeline/hit/runtime_index 4 packed structs). core_dirty +
/// runtime_index + pipeline_dirty + hit_dirty 4 fields collapsed -> 1 NodeDirty (save 3 field
/// slots). Sub-field names unchanged, only add .core/.runtime/.pipeline/.hit access hop.
pub const NodeDirty = struct {
    /// layout/render dirty bits (4 bool packed)
    core: CoreDirty = .{},
    /// runtime_index 4 bool packed
    runtime: RuntimeIndexFlags = .{},
    /// pipeline order/interaction/composite × self+subtree 6 bool packed
    pipeline: PipelineDirty = .{},
    /// hit_geometry/semantics/structure 3 bool packed
    hit: HitDirty = .{},
};

/// setTheme replay hook: boxStyled/textStyled etc named style functions mount here, setTheme re-run
/// style functions with new tokens.
pub const ThemeHook = *const fn (*Node, *const types.ThemeTokens, std.mem.Allocator) void;
/// The box declaration an `on_theme` hook writes, resolved for some tokens: lets a style host
/// that stacks on the node keep it as its own layer (see `StyleHostRef.retheme`).
pub const ThemeDecl = *const fn (*const types.ThemeTokens) types.BoxStyle;

/// view-layer runtime style theme replay: scope-owned style state inline here, hang on node,
/// setTheme call. Separate from component own on_theme, both non-overlapping (component root often
/// own on_theme).
pub const ViewThemeReplay = struct {
    run: *const fn (*ViewThemeReplay, *const types.ThemeTokens) void,
    /// node may have multi-layer runtime style (text style + box style, component root attrs
    /// layer): intrusive singly-linked list
    next: ?*ViewThemeReplay = null,
};

/// view-layer style host opaque reference (core independent of view types): call destroy on node
/// free.
pub const StyleHostRef = struct {
    ptr: *anyopaque,
    destroy: *const fn (*anyopaque) void,
    /// component imperative style write (setBackground etc) give to host component inline layer;
    /// return false means host applying, caller still write.
    write_inline: *const fn (*anyopaque, *const types.BoxStyle) bool,
    /// strip component inline layer fields (non-null fields in params), fallback to below
    unset_inline: *const fn (*anyopaque, *const types.BoxStyle) void,
    /// Fallible inline write, first half: make every allocation the write needs without changing
    /// anything visible. false = host applying (caller writes directly). At most one staged write
    /// per host; it must be committed or aborted before the host's layers change again.
    stage_inline: *const fn (*anyopaque, *const types.BoxStyle) error{OutOfMemory}!bool,
    /// apply the staged write (cannot fail)
    commit_inline: *const fn (*anyopaque) void,
    /// theme switch: re-resolve the layer holding the node's `theme_decl`; false = the host has
    /// none (the node's `on_theme` hook replays as usual)
    retheme: *const fn (*anyopaque, *const types.ThemeTokens) bool,
    /// drop the staged write; the node and host are as before staging
    abort_inline: *const fn (*anyopaque) void,
};

/// Component inline style written to a node that has no view style host but replays a declared
/// style on theme switch (`on_theme`). The replay rewrites the whole declaration, then reapplies
/// this, so inline writes stay above the element style as a style host would cascade them.
pub const ThemeInlineStyle = struct {
    allocator: Allocator,
    style: types.BoxStyle = .{},

    pub fn destroy(self: *ThemeInlineStyle) void {
        self.allocator.destroy(self);
    }
};

/// A component-inline style write whose allocations already succeeded (`Node.stageStyleInline`):
/// `commit` applies it and cannot fail, `abort` leaves the node exactly as before. Lets a mount
/// write several nodes all-or-nothing: stage every write, then commit them together.
pub const StagedStyleInline = struct {
    node: *Node,
    allocator: Allocator,
    partial: types.BoxStyle,
    via_host: bool,
    /// direct path: staging created the node's ext block (abort frees it again)
    created_ext: bool,
    /// direct path: staging created the node's theme inline record (abort frees it again)
    created_theme_inline: bool = false,

    pub fn commit(self: StagedStyleInline) void {
        if (self.via_host) {
            const h = self.node.meta.per_frame.hooks.style_host.?;
            return h.commit_inline(h.ptr);
        }
        if (self.node.meta.per_frame.hooks.theme_inline) |rec| rec.style = rec.style.merge(self.partial);
        self.node.applyStyleInlineDirect(self.allocator, self.partial);
    }

    pub fn abort(self: StagedStyleInline) void {
        if (self.via_host) {
            const h = self.node.meta.per_frame.hooks.style_host.?;
            return h.abort_inline(h.ptr);
        }
        if (self.created_ext) {
            self.allocator.destroy(self.node.style.ext.?);
            self.node.style.ext = null;
        }
        if (self.created_theme_inline) {
            self.node.meta.per_frame.hooks.theme_inline.?.destroy();
            self.node.meta.per_frame.hooks.theme_inline = null;
        }
    }
};

/// Node hook collection (before_render hooks + hook-owned state slots). before_render + hook_slots
/// 2 fields collapsed -> 1 NodeHooks (save 1 field slot).
pub const NodeHooks = struct {
    /// on_before_render main + extra hook ring
    before_render: BeforeRenderHooks = .{},
    /// setTheme-only theme replay hook (boxStyled/textStyled etc named style function mount)
    on_theme: ?ThemeHook = null,
    /// What `on_theme` declares (box styles only), for a style host stacking on this node
    theme_decl: ?ThemeDecl = null,
    /// view-layer runtime style (currently static, change only with theme) theme replay list head,
    /// see ViewThemeReplay
    view_theme: ?*ViewThemeReplay = null,
    /// view-layer style layer host (all node runtime box style is its layer), destroy on node free
    style_host: ?StyleHostRef = null,
    /// Inline writes a hostless `on_theme` node must keep across theme replays, destroy on node
    /// free
    theme_inline: ?*ThemeInlineStyle = null,
    /// useFocusRing/useHoverHighlight/component anim_state ?*anyopaque slots
    slots: HookSlots = .{},
};

/// Node per-frame state collection (caches + hooks + custom_hooks). P-Node-SoA-4: caches + hooks +
/// custom_hooks 3 fields collapsed -> 1 NodePerFrameState (-2 fields).
pub const NodePerFrameState = struct {
    caches: NodeCaches = .{},
    hooks: NodeHooks = .{},
    custom_hooks: CustomHooks = .{},
};

/// P-Node-SoA-5b (2026-05-02): frame_local merge spatial + runtime.
pub const NodeFrameLocal = struct {
    spatial: NodeSpatial = .{},
    runtime: NodeRuntime = .{},
};

/// P-Node-SoA-5b (2026-05-02): behavior merge events + interaction.
pub const NodeBehavior = struct {
    events: EventHandlers = .{},
    interaction: NodeInteraction = .{},
};

/// P-Node-SoA-6 (2026-05-02): ultimate frame state merge, state_bits + frame_local. Both per-frame
/// transient state, logic highly related. v0.5-P3 N-2 (2026-05-03): rect field deleted, element_id
/// != 0xFFFFFFFF node rect in World.LayoutTable, element_id == 0xFFFFFFFF (standalone Node.create
/// node) rect in g_standalone_rects (out-of-line hashmap, key by node ptr).
pub const NodeFrameState = struct {
    /// Raw child-slice end of the first flex line, collected before flexing.
    /// Unwrapped/unlaid-out containers default to the whole child list.
    first_flex_line_end: usize = std.math.maxInt(usize),
    state_bits: NodeStateBits = .{},
    frame_local: NodeFrameLocal = .{},
};

/// P-Node-SoA-6 (2026-05-02): meta merge ownership + per_frame.
pub const NodeMetadata = struct {
    ownership: NodeOwnership = .{},
    per_frame: NodePerFrameState = .{},
};

/// Node runtime visual state (sticky position compensation + animation linger frame count +
/// animation runtime slot). sticky_offset + animation_linger 2 fields collapsed -> 1 NodeRuntime
/// (save 1 field slot). P-Node-SoA-1 (2026-05-02): merged former NodeAnimRuntime (transitions +
/// commands) here, save 1 more field slot (-> Node 23 fields). Both lazily allocated, vast majority
/// nodes null/null.
pub const NodeRuntime = struct {
    /// Conservative subtree summary, set on cleanup, refreshed during layout and consumed by mount publication.
    /// Kept true across deferred/OOM passes and interrupted callbacks.
    layout_mount_pending: bool = true,
    /// sticky position x/y
    sticky: StickyOffset = .{},
    /// animation linger frame count (composite/opacity/transform)
    linger: AnimationLinger = .{},
    /// tickBeforeRender subtree summary: equal to tick.g_tick_quiet_epoch while the last full tick
    /// of this subtree found no tick work in it (no hooks, no active transitions / animations /
    /// linger, no sticky). Together with clean dirty bits it lets the tick skip the subtree.
    tick_quiet_epoch: u32 = 0,
    /// declarative Transition runtime state (former NodeAnimRuntime.transitions)
    transitions: ?*types.TransitionSlots = null,
    /// imperative node animation (allocated by animateNode; former NodeAnimRuntime.commands)
    commands: ?*@import("../animation/node_animator.zig").NodeAnimations = null,
};

/// opaque state slot owned by hooks (4 independent use pointers; point to hook private state
/// struct). 4 ?*anyopaque fields collapsed -> 1.
pub const HookSlots = struct {
    hover_listeners: ?*anyopaque = null,
    /// Candidate-owned invalidation links, not active hover subscriptions.
    /// No storage in ordinary/release nodes.
    preview_hover_pending: if (@import("zenit_environment").dev_preview) ?*anyopaque else void = if (@import("zenit_environment").dev_preview) null else {},
    /// useFocusRing
    focus_ring_anim: ?*anyopaque = null,
    /// Distinguishes useFocusRing from legacy custom use of the opaque slot.
    /// Function pointer identity cannot identify hooks across hot dylibs.
    focus_ring_owned: bool = false,
    /// useHoverHighlight
    hover_highlight_state: ?*anyopaque = null,
    /// component custom anim_state (for on_before_render use)
    anim_state: ?*anyopaque = null,
    /// view-layer time-loop style (`ui.view.loop`) runtime, for its before_render hook fetch
    view_loop: ?*anyopaque = null,
};

/// scattered bool flags (v0.5: 11 bool collapsed -> 1 packed struct). Excludes dirty propagation
/// bits (those in CoreDirty/PipelineDirty/RuntimeIndexFlags/HitDirty).
pub const NodeFlags = packed struct(u16) {
    out_of_viewport: bool = false,
    hit_test_visible: bool = true,
    text_stabilize_subtree: bool = false,
    manual_transform_animation_active: bool = false,
    manual_opacity_animation_active: bool = false,
    has_custom_draw_subtree: bool = false,
    /// subtree (incl self) has text content. setText non-empty set and bubble ancestor,
    /// appendChild/reparent merge parent chain. Conservative: the bit is never cleared (stays true
    /// after the text is deleted; it only grows, never shrinks). collectContentFlags.has_text O(1) data source, replace old
    /// subtreeHasText per-node recursion (full frame O(n*depth)).
    has_text_subtree: bool = false,
    /// subtree (incl self) has before_render hook. addBeforeRender set and bubble, appendChild
    /// merge parent chain. Conservative: the bit is never cleared. O(1) source for
    /// hasBeforeRenderHookSubtree.
    has_before_render_subtree: bool = false,
    disable_render_cache: bool = false,
    test_id_owned: bool = false,
    is_mounted: bool = false,
    inspectable: bool = true,
    inspect_pick_disabled: bool = false,
    /// Declares that this node's before_render hook leaves the node and its descendants
    /// **cache-safe**: every write it makes to this node or below either goes through a dirty-marking entry (content_version
    /// bumps), only moves a node (transform/translate: cached items are node-local and lowering
    /// reads this frame's property tree), or lands on a node flagged `disable_render_cache`
    /// (never part of any cross-frame cache). Unlike `before_render_hook_affects_self_only` it
    /// keeps the conservative paint-prefix break at this node; it only lets the paint pass reuse
    /// cross-frame caches for the node and inside its subtree (render_engine
    /// beforeRenderHookTaintsSubtree / ownPayloadCacheEligible).
    /// Without it, an undeclared hook's subtree is hook-owned: re-recorded every frame.
    /// Debug/ReleaseSafe audit: runBeforeRenderHook (tick.zig) checks the subtree.
    before_render_hook_descendants_cache_safe: bool = false,
    /// Declares the impact scope of a before_render hook (default false = conservative, affects the
    /// whole subtree).
    ///
    /// prebuildDisplayPayloadSubtrees sets display_payload_prefix_broken on a node with a
    /// before_render hook, so everything after it in paint order falls back to fresh emit. The gate
    /// prevents a real problem: a hook that changes transform/content during render while prebuild
    /// pre-recorded the pre-hook state yields double composite (half prebuilt, half fresh; GlassLab
    /// drag-ball flicker). The cost is the whole prefix, a large collateral for hooks that only
    /// refill their own geometry (editor scroll sync / size refill).
    ///
    /// Setting true is the caller's guarantee: **this hook only changes this node's own
    /// geometry/style/content, and touches no descendant/sibling transform or content visibility**.
    /// The gate then downgrades to "this node skips the cross-frame cache only" and no longer
    /// breaks the whole paint prefix.
    ///
    /// A wrong guarantee shows as ghosting/double composite, not a crash; validate with per-frame
    /// pixel-by-pixel acceptance. Escape valve: ZENIT_DISABLE_HOOK_SELF_SCOPE.
    before_render_hook_affects_self_only: bool = false,
    /// Some node in this subtree (or this node) has a before_render hook that is not
    /// cache-trusted (Node.beforeRenderHooksCacheTrusted). Set when such a hook is registered or
    /// first runs (tick self-heal), merged into the parent chain on attach, never cleared.
    has_untrusted_before_render_subtree: bool = false,
};

/// core dirty bits (v0.5: layout/subtree_layout/render/subtree_render 4 bool collapsed -> 1 packed
/// struct). These are zenit dirty propagation main circuit.
pub const CoreDirty = packed struct(u8) {
    layout: bool = true,
    subtree_layout: bool = true, // former subtree_dirty (means subtree_layout_dirty)
    render: bool = true,
    subtree_render: bool = true,
    _reserved: u4 = 0,
};

/// Pipeline dirty bits (v0.5: order/interaction/composite x (self+subtree) 6 bool collapsed -> 1
/// packed struct).
pub const PipelineDirty = packed struct(u8) {
    order: bool = true,
    subtree_order: bool = true,
    interaction: bool = false,
    subtree_interaction: bool = false,
    composite: bool = true,
    subtree_composite: bool = true,
    _reserved: u2 = 0,
};

/// Devtools debug slots, state pointer pool + signal ref pool, inspector/devtools only consume.
/// Collapse 4 debug_* fields, save 3 field slots.
pub const DebugSlots = struct {
    state_count: u8 = 0,
    state_ptrs: [8]?*anyopaque = @as([8]?*anyopaque, @splat(null)),
    signal_count: u8 = 0,
    signals: [8]?DebugSignalRef = @as([8]?DebugSignalRef, @splat(null)),
};

/// P-Node-SoA-5: dirty (NodeDirty) + flags (NodeFlags) collapsed.
pub const NodeStateBits = struct {
    dirty: NodeDirty = .{},
    flags: NodeFlags = .{},
};

/// application doesn't directly construct Node, use `ui.box()/ui.text()/ui.image()` etc factory
/// functions (see core.zig). Functions internally call `Node.create()` and set tag.
pub const ALIVE_SENTINEL: u32 = 0x5A11_5A11;
pub const DEAD_SENTINEL: u32 = 0xDEAD_0DE0;

pub const Node = struct {
    pub const CustomHitTestFn = *const fn (node: *const Node, local_x: f32, local_y: f32, context: ?*anyopaque) bool;
    pub const HitProxyProviderFn = *const fn (node: *const Node, context: ?*anyopaque, out: []HitProxySpec) usize;
    pub const CustomClipGeometryProviderFn = *const fn (node: *const Node, allocator: Allocator, context: ?*anyopaque) anyerror!PathGeometry;

    id: u32,
    host_id: if (node_tree.host_enabled) node_tree.HostId else void = if (node_tree.host_enabled) 0 else {},
    tag: ElementTag,
    style: Style,

    /// Pure, world-coordinate cursor query for a custom-drawn subtree. Only
    /// called on current hit ancestry. Null defers to descendant styles.
    cursor_query: ?*const fn (*const Node, f32, f32, ?*anyopaque) ?@import("cursor.zig").Region = null,
    cursor_query_context: ?*anyopaque = null,
    /// Called after capture ownership is cleared. Must tolerate cancellation.
    on_capture_lost: ?*const fn (*Node) void = null,

    /// link to World.elements ElementId (u32 raw form store avoid import cycle).
    element_id_raw: u32 = 0xFFFFFFFF,

    /// Which World this node belongs to (= which Cx/window). 0xFFFF = unregistered.
    ///
    /// Why needed: `element_id_raw` is `{index:u24, generation:u8}` with **no World id** and each
    /// World starts at index 0, so window A's eid 0x8 and window B's eid 0x8 are indistinguishable.
    /// `SlotMap.isValid` checks only index range + generation, so querying World B with A's id
    /// **false-matches and returns wrong data**.
    ///
    /// With an owner id, Node<->World routing can be validated, or process-level global callbacks
    /// shed entirely. See Zenit_P0-3_RootCause_2026-07-29.md.
    world_id: u16 = INVALID_WORLD_ID,

    /// this node owner World direct pointer (null = unregistered, fallback standalone).
    ///
    /// P0-3 stage 3: key to shedding 19 process-level global callbacks
    /// (g_rect_query/g_structure_notify/g_paint_*/g_content_*/g_layout_output_*...), with it Node
    /// property access can `node.world_ref.?.layout.rect(eid)` directly, no need to "smuggle World
    /// via global". Written together with world_id by onNodeCreate; world_id kept for **cross-Cx
    /// cross-talk assertion** (pointer equal can't distinguish "same World freed then address
    /// reused").
    world_ref: ?*world_mod.World = null,

    children: std.ArrayList(*Node),
    parent: ?*Node = null,
    /// Stable request storage shared by reactive and frame-deferred queues.
    deferred_disposal: @import("../reactive/deferred_disposal.zig").Entry = .{},
    pending_free_cx: ?*anyopaque = null,
    freeing: bool = false,
    /// Alive sentinel: init writes ALIVE, destroy writes DEAD before freeing.
    ///
    /// `freeing` only blocks re-entry **within the same teardown**. A real double free (memory
    /// returned to the allocator, maybe reused) cannot be blocked, and Debug Zig writes 0xaa to
    /// freed
    /// memory so `freeing` reads true (0xaa != 0): freeNodeNow would **silently early-return**,
    /// turning a detectable double free into a silent no-op.
    ///
    /// The sentinel distinguishes three states: ALIVE (normal) / this teardown in progress
    /// (freeing=true and alive_sentinel==ALIVE) / freed (sentinel neither ALIVE nor DEAD, or
    /// exactly
    /// DEAD). The latter two panic rather than pretend fine.
    ///
    /// Scope (build-mode qualified):
    /// - The sentinel exists in **all build modes** (uses @panic, not assert).
    /// - The "0xaa makes freeing read true -> silent no-op" form is **Debug/ReleaseSafe
    ///   DebugAllocator poison behavior**; in ReleaseFast reused memory may be read and the
    ///   sentinel
    ///   can false-negative (same type reused and a new init writes ALIVE). So the sentinel is the
    ///   **first belt** and the allocator's own double-free detection the second; neither can be
    ///   skipped.
    /// - Coverage: zenit tests (Debug + ReleaseSafe) and downstream editor OOM sweeps (2335 + 1178
    ///   injection points, Debug + ReleaseSafe) all pass.
    alive_sentinel: u32 = ALIVE_SENTINEL,

    // visuals field deleted, content (§a) + layout_output (§L) all SoA to World
    // (ContentTable/LayoutOutputTable). Node top-level 10->9.

    /// P-Node-SoA-6 (2026-05-02): rect + state_bits + frame_local three-way.
    frame_state: NodeFrameState = .{},

    /// P-Node-SoA-6 (2026-05-02): ownership + per_frame merge.
    meta: NodeMetadata = .{},

    /// P-Node-SoA-5b: events + interaction merge -> behavior.
    behavior: NodeBehavior = .{},

    /// read rect from global World, fallback standalone fallback storage on fail. For cx-less
    /// functions (computeStickyOffset/tickBeforeRender etc) use.
    pub fn rectFromWorldOrFallback(self: *const Node) ComputedRect {
        return node_lifecycle.rectFromWorldOrFallback(self);
    }

    /// component-layer "change own child rect" unified write entry. Write World.LayoutTable +
    /// maintain standalone fallback storage.
    pub fn setLayoutRect(self: *Node, r: ComputedRect) void {
        node_lifecycle.setLayoutRect(self, r);
    }

    /// Partial setters, layout_engine frequent partial updates; helpers encapsulate "read current
    /// -> modify -> setLayoutRect" single call, let layout path not directly write frame_state.rect
    /// field, so when truly delete field change here.
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

    /// v0.9-§a stage 3 (2026-05-13): NodeContent SoA, World.content is source of truth.
    /// element_id_raw == 0xFFFFFFFF (mock test cx-less) fall standalone fallback hashmap by node
    /// ptr.
    // content accessor routing all in pca; here just thin forward element_id_raw + node_ptr
    // (methods must stay Node container).
    /// Publishes text and invalidates measurement or paint as needed. Re-publish
    /// borrowed content/spans after mutating them; identical writes are inert.
    /// Ownership changes still reach the storage layer even when pixels match.
    pub fn setText(self: *Node, t_in: ?TextProps) void {
        var t = t_in;
        // ownership: explicit owned=true writer declare transfer; without declare but write back
        // node already owned same content (getText -> change style fields -> setText) preserve
        // ownership.
        if (t) |*nt| {
            if (self.getTextRaw()) |old| {
                // pointer and length both same means write-back: original truncate (same pointer,
                // shorter) if recover ownership, later free whole allocation wrong length; not
                // recover worst case leak this block, not corrupt heap.
                if (!nt.owned and old.owned and old.content.len > 0 and
                    old.content.ptr == nt.content.ptr and old.content.len == nt.content.len) nt.owned = true;
                if (!nt.spans_owned and old.spans_owned and old.spans.len > 0 and
                    old.spans.ptr == nt.spans.ptr and old.spans.len == nt.spans.len) nt.spans_owned = true;
            }
        }
        const next = text_change.signature(t);
        const previous = self.meta.per_frame.caches.text_signature;
        pca.writeText(self.world_ref, self.element_id_raw, @intFromPtr(self), t);
        // subtree text flag: non-empty setText set and bubble (the bit is never cleared, see
        // NodeFlags note).
        if (t != null) node_interaction.markSubtreeText(self);
        // content changed, text hash by (version, ptr, len) record must invalid: same-length
        // content swap these three can all unchanged (see invalidateTextHashCache note).
        node_render_cache.invalidateTextHashCache(self);
        self.meta.per_frame.caches.text_signature = next;
        if (next.layout != previous.layout) {
            self.markSizingDirty();
        } else if (next.paint != previous.paint) {
            self.markRenderDirty();
        }
    }

    /// quick setText: dupe new content and mark owned, old owned content by setText auto-free.
    /// App-side status bar/label "same node change text" use this, no hand-manage owned. Change
    /// text content. Content really changed only dirty: new content width/height need re-measure
    /// (also re-paint), caller no need hand markSizingDirty, miss it text layout by old width,
    /// longer new content explodes parent (notification card "just now" -> "1 min ago" so
    /// overflow).
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
        if (std.meta.eql(self.getImage(), img)) return;
        pca.writeImage(self.world_ref, self.element_id_raw, @intFromPtr(self), img);
        // Texture/tint changes invalidate retained draw commands, even when
        // layout and every other node remain unchanged.
        self.markRenderDirty();
    }

    /// change icon tint, don't care storage form: iconTint on icon_id resource go icon table, no
    /// pre-baked rep fallback image (svgTint), caller when judge one type other silently unchanged
    /// (Rate hover unchanged here). Returns false when both are absent or the tint is unchanged.
    pub fn setTint(self: *Node, tint: Color) bool {
        return self.writeTint(tint, false);
    }

    /// Tint with the nearest ancestor text color (CSS currentColor, resolved at paint; see
    /// IconProps.tint_current_color). `fallback` paints when no ancestor declares a text color.
    pub fn setTintCurrentColor(self: *Node, fallback: Color) bool {
        return self.writeTint(fallback, true);
    }

    /// Write a whole tint mode (fixed color or currentColor with its fallback).
    pub fn setTintMode(self: *Node, mode: types.TintMode) bool {
        return self.writeTint(mode.color, mode.current_color);
    }

    /// The icon / image tint mode now on the node (null when it holds neither).
    pub fn tintMode(self: *const Node) ?types.TintMode {
        if (self.getIcon()) |ic| return .{ .color = ic.tint, .current_color = ic.tint_current_color };
        if (self.getImage()) |img| return .{ .color = img.tint, .current_color = img.tint_current_color };
        return null;
    }

    /// Returns whether the tint changed. Rewriting the same tint is a no-op: per-frame callers
    /// (toolbar / bar refresh) would otherwise mark the icon render-dirty every frame and defeat
    /// every cross-frame cache on its path.
    fn writeTint(self: *Node, tint: Color, current_color: bool) bool {
        if (self.getIcon()) |old| {
            if (std.meta.eql(old.tint, tint) and old.tint_current_color == current_color) return false;
            var ic = old;
            ic.tint = tint;
            ic.tint_current_color = current_color;
            self.setIcon(ic);
        } else if (self.getImage()) |old| {
            if (std.meta.eql(old.tint, tint) and old.tint_current_color == current_color) return false;
            var img = old;
            img.tint = tint;
            img.tint_current_color = current_color;
            self.setImage(img);
            return true; // setImage already invalidated the retained paint.
        } else return false;
        self.markRenderDirty();
        return true;
    }

    pub fn setIcon(self: *Node, ic: ?IconProps) void {
        pca.writeIcon(self.world_ref, self.element_id_raw, @intFromPtr(self), ic);
    }

    /// read text (value copy). Returned copy **no ownership** (`owned`/`spans_owned` always false):
    /// ownership only writer declare fresh-allocate content, read-modify-write copy can't bring it
    /// back - else caller change `.content` to own buffer then `setText`, node destroy will free
    /// caller memory. Original write-back same pointer setText keep node original ownership.
    pub fn getText(self: *const Node) ?TextProps {
        var t = pca.readText(self.world_ref, self.element_id_raw, @intFromPtr(self)) orelse return null;
        t.owned = false;
        t.spans_owned = false;
        return t;
    }

    /// raw read with ownership flag, only for node cleanup/setText recover path.
    pub fn getTextRaw(self: *const Node) ?TextProps {
        return pca.readText(self.world_ref, self.element_id_raw, @intFromPtr(self));
    }

    pub fn getImage(self: *const Node) ?ImageProps {
        return pca.readImage(self.world_ref, self.element_id_raw, @intFromPtr(self));
    }

    pub fn getIcon(self: *const Node) ?IconProps {
        return pca.readIcon(self.world_ref, self.element_id_raw, @intFromPtr(self));
    }

    // NodeLayoutOutput field deleted -> World.LayoutOutputTable is source of truth; cx-less mock
    // use pca standalone heap pool. Thin delegate to pca (element_id + node_ptr two params, pca
    // internal route World/standalone).
    /// Cheap non-owning header snapshot. Per-node hot paths use layoutOutput().
    pub fn getLayoutOutput(self: *const Node) NodeLayoutOutput {
        return pca.readLayoutOutput(self.world_ref, self.element_id_raw, @intFromPtr(self));
    }

    /// Read-only view of the layout output; null means "nothing computed yet"
    /// (equivalent to the default value). No copy, no allocation. The pointer
    /// points into a fixed-address chunk. Valid until clear/reuse/teardown;
    /// content may change on layout/cache replacement.
    pub fn layoutOutput(self: *const Node) ?*const NodeLayoutOutput {
        return pca.layoutOutputConstPtr(self.world_ref, self.element_id_raw, @intFromPtr(self));
    }

    pub fn layoutChildrenBbox(self: *const Node) ?ComputedRect {
        const lo = self.layoutOutput() orelse return null;
        return lo.artifacts.children_bbox;
    }

    pub fn layoutTextLayout(self: *const Node) ?*const @import("text_layout.zig").TextLayout {
        const lo = self.layoutOutput() orelse return null;
        return lo.artifacts.text_layout;
    }

    pub fn storeTextLayout(self: *Node, text: *const @import("text_layout.zig").TextLayout) !void {
        return pca.storeTextLayout(self.world_ref, self.element_id_raw, @intFromPtr(self), text);
    }

    pub fn clearTextLayout(self: *Node) void {
        pca.clearTextLayout(self.world_ref, self.element_id_raw, @intFromPtr(self));
    }

    pub fn setLayoutOutput(self: *Node, v: NodeLayoutOutput) void {
        pca.writeLayoutOutput(self.world_ref, self.element_id_raw, @intFromPtr(self), v);
    }

    /// stable address: owner method in-place change child field + display_list pointer escape
    /// caller. cx-backed World slot (dense by element_id, frame stable); cx-less mock pca
    /// standalone heap pool (permanent stable).
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

    /// See NodeDelegate.frame: `delegate` must be a descendant (freed with this node).
    pub fn setFrameDelegate(self: *Node, delegate: ?*Node) void {
        self.meta.ownership.delegate.frame = delegate;
    }

    /// The node that draws this node's control frame (itself unless delegated).
    pub fn frameNode(self: *Node) *Node {
        var n = self;
        while (n.meta.ownership.delegate.frame) |next| n = next;
        return n;
    }

    pub fn setInspectPickDisabled(self: *Node, disabled: bool) void {
        node_interaction.setInspectPickDisabled(self, disabled);
    }

    pub fn setHitTestVisible(self: *Node, visible: bool) void {
        node_interaction.setHitTestVisible(self, visible);
    }

    pub fn addBeforeRender(self: *Node, hook: *const fn (*Node) void) void {
        self.addBeforeRenderScoped(hook, .subtree);
    }

    pub fn addBeforeRenderScoped(self: *Node, hook: *const fn (*Node) void, scope: BeforeRenderScope) void {
        // subtree hook flag: set and bubble ancestor (for hasBeforeRenderHookSubtree O(1) read).
        // Component-layer lots `before_render.main =` direct assign not through function, those by
        // tick.zig tickBeforeRender every run fold self-heal (see its note).
        node_interaction.markSubtreeBeforeRenderHook(self);
        node_interaction.invalidateTickQuietChain(self);
        if (scope == .subtree and !self.frame_state.state_bits.flags.before_render_hook_descendants_cache_safe)
            node_interaction.markSubtreeUntrustedBeforeRenderHook(self);
        const hooks = &self.meta.per_frame.hooks.before_render;
        if (hooks.main == hook) return;
        for (hooks.hooks[0..hooks.count], 0..) |existing, i| {
            if (existing != hook) continue;
            // Registered again: conflicting declarations resolve to the
            // conservative one, so a later .subtree demotes an earlier .self
            // (a later .self never widens an earlier .subtree).
            const bit_i = @as(u8, 1) << @intCast(i);
            if (scope != .self) hooks.self_only_mask &= ~bit_i;
            if (scope == .subtree) hooks.trusted_mask &= ~bit_i;
            return;
        }
        if (hooks.count < hooks.hooks.len) {
            const bit = @as(u8, 1) << @intCast(hooks.count);
            hooks.hooks[hooks.count] = hook;
            if (scope == .self) hooks.self_only_mask |= bit else hooks.self_only_mask &= ~bit;
            if (scope != .subtree) hooks.trusted_mask |= bit else hooks.trusted_mask &= ~bit;
            hooks.count += 1;
        }
    }

    pub fn removeBeforeRender(self: *Node, hook: *const fn (*Node) void) void {
        const hooks = &self.meta.per_frame.hooks.before_render;
        if (hooks.count == 0) return;
        var i: usize = 0;
        while (i < hooks.count) : (i += 1) {
            if (hooks.hooks[i] == hook) {
                var j = i;
                while (j + 1 < hooks.count) : (j += 1) {
                    hooks.hooks[j] = hooks.hooks[j + 1];
                }
                // Shift the scope bits above i down by one, like the entries.
                inline for (.{ &hooks.self_only_mask, &hooks.trusted_mask }) |mask| {
                    const below = mask.* & ((@as(u8, 1) << @intCast(i)) - 1);
                    const above = (mask.* >> 1) & ~((@as(u8, 1) << @intCast(i)) - 1);
                    mask.* = below | above;
                }
                hooks.count -= 1;
                hooks.hooks[hooks.count] = null;
                hooks.self_only_mask &= ~(@as(u8, 1) << @intCast(hooks.count));
                hooks.trusted_mask &= ~(@as(u8, 1) << @intCast(hooks.count));
                return;
            }
        }
    }

    /// Every before_render hook on this node is limited to the node itself:
    /// either its owner declared the whole node (`before_render_hook_affects_self_only`,
    /// e.g. ControlShell, which installs the `main` hook) or there is no `main`
    /// hook and every registered hook used `.self` scope.
    pub fn beforeRenderHooksSelfOnly(self: *const Node) bool {
        if (self.frame_state.state_bits.flags.before_render_hook_affects_self_only) return true;
        const hooks = self.meta.per_frame.hooks.before_render;
        if (hooks.main != null) return false;
        if (hooks.count == 0) return false;
        const all = (@as(u16, 1) << @intCast(hooks.count)) - 1;
        return (@as(u16, hooks.self_only_mask) & all) == all;
    }

    /// Every before_render hook on this node writes only through dirty-marking entries, so a
    /// cross-frame cache of this node or of a subtree containing it sees every change through
    /// dirty bits and content / composite versions, like any event-driven write:
    /// - all hooks registered with `.self` / `.dirty_marking` scope (Debug/ReleaseSafe audit
    ///   includes the node itself), or
    /// - the owner declared `before_render_hook_descendants_cache_safe` (audited over the subtree).
    /// The node-wide `before_render_hook_affects_self_only` flag is not enough: its hooks may
    /// refill their own geometry raw. No hooks: trivially true.
    pub fn beforeRenderHooksCacheTrusted(self: *const Node) bool {
        if (!self.hasBeforeRenderHooks()) return true;
        if (self.frame_state.state_bits.flags.before_render_hook_descendants_cache_safe) return true;
        return self.beforeRenderHooksScopedTrusted();
    }

    /// No `main` hook and every registered hook used `.self` or `.dirty_marking` scope.
    pub fn beforeRenderHooksScopedTrusted(self: *const Node) bool {
        const hooks = self.meta.per_frame.hooks.before_render;
        if (hooks.main != null) return false;
        if (hooks.count == 0) return false;
        const all = (@as(u16, 1) << @intCast(hooks.count)) - 1;
        return (@as(u16, hooks.trusted_mask) & all) == all;
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

    /// see `NodeInteraction.pointer_down_focus`.
    pub fn setPointerDownFocus(self: *Node, policy: PointerDownFocus) void {
        node_interaction.setPointerDownFocus(self, policy);
    }

    /// walk up parent chain; self ancestor-descendant (incl self) return true.
    pub fn isDescendantOf(self: *Node, ancestor: *Node) bool {
        return node_tree.isDescendantOf(self, ancestor);
    }

    pub fn appendChild(self: *Node, allocator: Allocator, child: *Node) !void {
        return node_tree.appendChild(self, allocator, child);
    }

    /// insert child before (before null append). before must be direct child.
    pub fn insertChildBefore(self: *Node, allocator: Allocator, child: *Node, before: ?*Node) !void {
        return node_tree.insertChildBefore(self, allocator, child, before);
    }

    /// re-order children order by existing child pointer. Don't create/destroy node, don't trigger
    /// runtime registry rebuild, only mark order/layout dirty.
    pub fn replaceChildOrder(self: *Node, allocator: Allocator, ordered_children: []const *Node) !void {
        return node_tree.replaceChildOrder(self, allocator, ordered_children);
    }

    /// set custom_draw callback and bubble mark has_custom_draw_subtree
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

    /// bubble mark has_custom_draw_subtree (on child add call)
    // upgrade pub, node_tree cross-module call via self.markCustomDrawSubtree()
    pub fn markCustomDrawSubtree(self: *Node) void {
        node_interaction.markCustomDrawSubtree(self);
    }

    /// bubble mark has_text_subtree (setText non-empty/child add call)
    pub fn markSubtreeText(self: *Node) void {
        node_interaction.markSubtreeText(self);
    }

    /// bubble mark has_before_render_subtree (addBeforeRender/child add call)
    /// See node_interaction.invalidateTickQuietChain.
    pub fn invalidateTickQuietChain(self: *Node) void {
        node_interaction.invalidateTickQuietChain(self);
    }

    pub fn markSubtreeBeforeRenderHook(self: *Node) void {
        node_interaction.markSubtreeBeforeRenderHook(self);
    }

    /// compute node global absolute coordinates (walk ancestor chain accumulate rect + translate +
    /// sticky)
    pub fn globalRect(self: *const Node) ComputedRect {
        return node_lifecycle.globalRect(self);
    }

    /// Compose the same ancestor transforms used by rendering and hit testing.
    pub fn worldTransform(self: *const Node) Transform2D {
        return @import("retained_scene.zig").buildAncestorWorldTransform(self, .{ .include_rotation = true });
    }

    // ==================== inheritable property resolve (walk up parent chain) ====================

    // inheritable property resolve extracted to node_inherit.zig (node.zig only upwalk +
    // zero-side-effect read path). Node.InheritedTextStyle path unchanged.
    pub const InheritedTextStyle = node_inherit.InheritedTextStyle;

    pub fn resolveInheritedTextStyle(self: *const Node) InheritedTextStyle {
        return node_inherit.resolveInheritedTextStyle(self);
    }

    /// Text properties as laid out and painted (inheritance resolved, see
    /// node_inherit.resolveTextProps). Layout and paint must both read this, never getText()'s
    /// raw size / weight / color.
    pub fn resolveTextProps(self: *const Node) ?TextProps {
        return node_inherit.resolveTextProps(self);
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

    // ==================== type-safe Style change API ====================

    /// give DevTools record builder/named style function public declaration source. Source table
    /// sparse debug data on World, don't expand Node, don't expensive debug-info parse here.
    pub fn recordStyleBaseOrigin(self: *Node, fields: u64, address: usize, kind: world_mod.StyleOriginKind) void {
        const w = self.world_ref orelse return;
        w.recordStyleBase(self.element_id_raw, fields, .{ .address = address, .kind = kind });
    }

    /// read some field last-writer; null field for TextStyle.line_height etc unenter StyleField
    /// yet, then query public source only.
    pub fn styleOrigin(self: *const Node, field: ?types.StyleField) ?world_mod.StyleOrigin {
        const w = self.world_ref orelse return null;
        const field_index: ?u8 = if (field) |f| @intCast(@backingInt(f)) else null;
        return w.styleOrigin(self.element_id_raw, field_index);
    }

    /// set single style field, compile-time pick correct dirty level. Low-freq field auto-allocate
    /// StyleExt (need provide allocator). ext field + literal null -> compile error; ext field +
    /// runtime null -> debug assert + error log (prior silent skip let downstream 10 z_index all
    /// mute no signal, downstream regression).
    pub fn setStyle(self: *Node, maybe_allocator: anytype, comptime field: types.StyleField, value: types.StyleFieldType(field)) void {
        node_tree.hostDirty(self);
        const AllocArg = @TypeOf(maybe_allocator);
        if (comptime AllocArg != std.mem.Allocator and AllocArg != ?std.mem.Allocator and AllocArg != @TypeOf(null)) {
            @compileError("setStyle 的 allocator 参数必须是 Allocator / ?Allocator / null，收到 " ++ @typeName(AllocArg));
        }
        if (comptime types.isExtField(field) and AllocArg == @TypeOf(null)) {
            @compileError("setStyle(." ++ @tagName(field) ++ ") 是 StyleExt 字段：allocator 传 null 会丢弃写入，必须传实际 allocator");
        }
        // background/opacity not in Style -> SoA raw write path.
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
                // runtime null: write can't happen. Prior silent skip, now must visible.
                std.log.err("setStyle(.{s}) 需要 allocator，写入被丢弃", .{@tagName(field)});
                std.debug.assert(false);
                return;
            }
        } else {
            @field(self.style, @tagName(field)) = value;
        }
        if (self.world_ref) |w| {
            w.recordStyleField(self.element_id_raw, @intCast(@backingInt(field)), .{
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
        if (comptime field == .text_color) self.markInheritedTextDirty(.{ .color = true });
        if (comptime field == .text_font_size or field == .text_font_weight) self.markInheritedTextDirty(.{ .metrics = true });
    }

    /// set full value margin, clear any auto margin mark.
    pub fn setMargin(self: *Node, margin: types.Padding) void {
        if (std.meta.eql(self.style.margin, margin) and self.style.marginAutoMask() == 0) return;
        self.style.margin = margin;
        self.style.clearAutoMargins();
        self.markSizingDirty();
    }

    /// set full margin declaration (support auto).
    pub fn setMarginSpec(self: *Node, allocator: Allocator, margin: types.Margin) void {
        if (types.Margin.eql(self.style.marginSpec(), margin)) return;
        self.style.setMarginSpec(allocator, margin);
        self.markSizingDirty();
    }

    /// set margin.left, clear left auto mark.
    pub fn setMarginLeft(self: *Node, value: f32) void {
        if (@abs(self.style.margin.left - value) < 0.001 and !self.style.marginLeftIsAuto()) return;
        self.style.margin.left = value;
        if (self.style.marginLeftIsAuto()) self.style.setMarginLeftAutoFallback(false);
        self.markSizingDirty();
    }

    /// set margin.top, clear top auto mark.
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

    /// set border.color (auto interpolate if transition configured)
    pub fn setBorderColor(self: *Node, color: types.Color) void {
        if (self.routeInlineStyle(.{ .border_color = color })) return;
        if (self.frame_state.frame_local.runtime.transitions) |slots| {
            if (slots.find(.border_color)) |slot| {
                if (!types.Color.eql(color, if (slot.active) slot.to_color else self.style.border.color)) {
                    slot.from_color = self.style.border.color;
                    slot.to_color = color;
                    slot.start_time_ms = render_engine.current_frame_time_ms;
                    slot.active = true;
                    slots.any_active = true;
                    node_interaction.invalidateTickQuietChain(self);
                    self.markRenderDirtyTracked(.border_change, "setBorderColor");
                }
                return;
            }
        }
        if (types.Color.eql(self.style.border.color, color)) return;
        self.style.border.color = color;
        self.markRenderDirtyTracked(.border_change, "setBorderColor");
    }

    /// set border.width (auto interpolate if transition configured)
    pub fn setBorderWidth(self: *Node, width: f32) void {
        if (self.frame_state.frame_local.runtime.transitions) |slots| {
            if (slots.find(.border_width)) |slot| {
                if (@abs(width - (if (slot.active) slot.to_value else self.style.border.width)) > 0.01) {
                    slot.from_value = self.style.border.width;
                    slot.to_value = width;
                    slot.start_time_ms = render_engine.current_frame_time_ms;
                    slot.active = true;
                    slots.any_active = true;
                    node_interaction.invalidateTickQuietChain(self);
                    self.markRenderDirtyTracked(.border_change, "setBorderWidth");
                }
                return;
            }
        }
        self.style.border.setUniformWidth(width);
        self.markLayoutDirty();
    }

    /// set four-edge border.color override (top, right, bottom, left). Pass null edge fallback to
    /// border.color
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

    // ==================== declarative Transition API ====================

    /// The node's transition slots, allocated on first use (the only allocation configuring a
    /// transition makes).
    fn ensureTransitionSlots(self: *Node, allocator: Allocator) error{OutOfMemory}!*types.TransitionSlots {
        if (self.frame_state.frame_local.runtime.transitions) |slots| return slots;
        const slots = try allocator.create(types.TransitionSlots);
        slots.* = .{};
        self.frame_state.frame_local.runtime.transitions = slots;
        return slots;
    }

    /// configure property transition (slots already allocated: cannot fail)
    fn setTransition(slots: *types.TransitionSlots, prop: types.TransitionProp, spec: types.TransitionSpec) void {
        if (slots.getOrCreate(prop)) |slot| {
            slot.spec = spec;
        }
    }

    /// Set background color (auto-interpolate if a transition is configured).
    /// style.background field deleted; source of truth is World.paint_state
    /// (element_id!=0xFFFFFFFF) or standalone fallback (mock).
    pub fn setBackground(self: *Node, color: types.Color) void {
        if (self.routeInlineStyle(.{ .background = color })) return;
        if (self.frame_state.frame_local.runtime.transitions) |slots| {
            if (slots.find(.background)) |slot| {
                // idle compare current: slot built to_color default, not compare current, write
                // same as current also start empty transition (mount time view apply like this)
                if (!types.Color.eql(color, if (slot.active) slot.to_color else self.getBackground())) {
                    slot.from_color = self.getBackground();
                    slot.to_color = color;
                    slot.start_time_ms = render_engine.current_frame_time_ms;
                    slot.active = true;
                    slots.any_active = true;
                    node_interaction.invalidateTickQuietChain(self);
                    self.markRenderDirtyTracked(.background_change, "setBackground");
                }
                return;
            }
        }
        if (types.Color.eql(self.getBackground(), color)) return;
        self.setBackgroundRaw(color);
        self.markRenderDirtyTracked(.background_change, "setBackground");
    }

    /// set opacity (auto interpolate if transition configured)
    pub fn setOpacity(self: *Node, value: f32) void {
        if (self.routeInlineStyle(.{ .opacity = value })) return;
        if (self.frame_state.frame_local.runtime.transitions) |slots| {
            if (slots.find(.opacity)) |slot| {
                if (@abs(value - (if (slot.active) slot.to_value else self.getOpacity())) > 0.001) {
                    slot.from_value = self.getOpacity();
                    slot.to_value = value;
                    slot.start_time_ms = render_engine.current_frame_time_ms;
                    slot.active = true;
                    slots.any_active = true;
                    node_interaction.invalidateTickQuietChain(self);
                    // opacity is composite property: authority composition (four write path
                    // bottleneck last place).
                    self.markCompositePropDirty();
                }
                return;
            }
        }
        if (@abs(self.getOpacity() - value) < 0.001) return;
        self.setOpacityRaw(value);
        self.markCompositePropDirty();
    }

    /// node has view style host, component imperative style write become host component inline
    /// layer (overlay own style, lose caller stack, undo cascade back); no host return false,
    /// caller direct write.
    pub fn routeInlineStyle(self: *Node, partial: types.BoxStyle) bool {
        const h = self.meta.per_frame.hooks.style_host orelse {
            self.recordThemeInline(partial);
            return false;
        };
        return h.write_inline(h.ptr, &partial);
    }

    /// Hostless node whose declared style replays on theme switch: remember the inline write so
    /// the replay keeps it (best effort, like the write itself; see `ThemeInlineStyle`).
    fn recordThemeInline(self: *Node, partial: types.BoxStyle) void {
        if (self.meta.per_frame.hooks.on_theme == null) return;
        const rec = self.meta.per_frame.hooks.theme_inline orelse blk: {
            const allocator = (self.world_ref orelse return).allocator;
            const created = allocator.create(ThemeInlineStyle) catch {
                std.log.warn("ui: inline style kept only until the next theme switch (out of memory)", .{});
                return;
            };
            created.* = .{ .allocator = allocator };
            self.meta.per_frame.hooks.theme_inline = created;
            break :blk created;
        };
        rec.style = rec.style.merge(partial);
    }

    /// Theme replay of this node's `on_theme` declaration: through its style host when the host
    /// holds it as a layer (inline and caller layers stay above it), else the hook rewrites the
    /// declaration and the remembered inline writes go back over it.
    pub fn replayThemeDeclaration(self: *Node, t: *const types.ThemeTokens, allocator: std.mem.Allocator) void {
        const hook = self.meta.per_frame.hooks.on_theme orelse return;
        if (self.meta.per_frame.hooks.style_host) |h| if (h.retheme(h.ptr, t)) return;
        hook(self, t, allocator);
        self.reapplyThemeInline(allocator);
    }

    /// Theme replay: put the remembered inline writes back over the declaration `on_theme` just
    /// rewrote (raw writes: the values were already showing, nothing transitions).
    pub fn reapplyThemeInline(self: *Node, allocator: std.mem.Allocator) void {
        const rec = self.meta.per_frame.hooks.theme_inline orelse return;
        const partial = rec.style;
        if (partial.needsExt()) _ = self.style.ensureExtFallible(allocator) catch {
            std.log.warn("ui: inline style lost on theme switch (out of memory)", .{});
            return;
        };
        var rest = partial;
        rest.background = null;
        rest.opacity = null;
        rest.applyTo(&self.style, allocator);
        if (partial.background) |c| self.setBackgroundRaw(c);
        if (partial.opacity) |o| self.setOpacityRaw(o);
        self.markLayoutDirty();
        self.markInheritedTextDirty(.of(partial));
    }

    /// imperative set style fields group (component inline style). With view style host go
    /// component inline layer; else direct write to node
    /// (background/opacity/border_color/translate_x via interpolate setter).
    ///
    /// Best effort: an allocation failure drops the write (whole: never part of it; a layered
    /// node's host retries a failed recalculation on its next write). For effects / callbacks
    /// that cannot report errors; mount paths use `setStyleInlineFallible`.
    pub fn setStyleInline(self: *Node, allocator: std.mem.Allocator, partial: types.BoxStyle) void {
        if (self.routeInlineStyle(partial)) return;
        // the ext block is the direct write's only allocation: without it the whole write is
        // dropped, never just its ext fields
        if (partial.needsExt()) _ = self.style.ensureExtFallible(allocator) catch {
            std.log.warn("ui: inline style write dropped (out of memory)", .{});
            return;
        };
        self.applyStyleInlineDirect(allocator, partial);
    }

    /// `setStyleInline` that reports allocation failure: the write lands completely or the node
    /// is left unchanged (mount paths).
    pub fn setStyleInlineFallible(self: *Node, allocator: std.mem.Allocator, partial: types.BoxStyle) error{OutOfMemory}!void {
        (try self.stageStyleInline(allocator, partial)).commit();
    }

    /// First half of a fallible inline write: every allocation happens here, nothing visible
    /// changes until `commit` (see `StagedStyleInline`).
    pub fn stageStyleInline(self: *Node, allocator: std.mem.Allocator, partial: types.BoxStyle) error{OutOfMemory}!StagedStyleInline {
        if (self.meta.per_frame.hooks.style_host) |h| {
            if (try h.stage_inline(h.ptr, &partial)) return .{ .node = self, .allocator = allocator, .partial = partial, .via_host = true, .created_ext = false };
        }
        // Direct write: the ext block (and a themed node's inline record) are the only
        // allocations applyTo / the setters make.
        const had_ext = self.style.ext != null;
        if (partial.needsExt()) _ = try self.style.ensureExtFallible(allocator);
        errdefer if (!had_ext) if (self.style.ext) |ext| {
            allocator.destroy(ext);
            self.style.ext = null;
        };
        var created_theme_inline = false;
        if (self.meta.per_frame.hooks.on_theme != null and self.meta.per_frame.hooks.theme_inline == null) {
            const rec = try allocator.create(ThemeInlineStyle);
            rec.* = .{ .allocator = allocator };
            self.meta.per_frame.hooks.theme_inline = rec;
            created_theme_inline = true;
        }
        return .{ .node = self, .allocator = allocator, .partial = partial, .via_host = false, .created_ext = !had_ext and self.style.ext != null, .created_theme_inline = created_theme_inline };
    }

    fn applyStyleInlineDirect(self: *Node, allocator: std.mem.Allocator, partial: types.BoxStyle) void {
        node_tree.hostDirty(self);
        var rest = partial;
        rest.background = null;
        rest.opacity = null;
        rest.border_color = null;
        rest.translate_x = null;
        rest.applyTo(&self.style, allocator);
        if (partial.background) |c| self.setBackground(c);
        if (partial.opacity) |o| self.setOpacity(o);
        if (partial.border_color) |c| self.setBorderColor(c);
        if (partial.translate_x) |x| self.setTranslateX(x);
        self.markLayoutDirty();
        self.markInheritedTextDirty(.of(partial));
    }

    /// strip prior setStyleInline/interpolate setter write component inline style (`fields`
    /// non-null fields; value self ignore), let properties cascade back (own element
    /// style/default). No view style host nothing to do.
    pub fn unsetStyleInline(self: *Node, fields: types.BoxStyle) void {
        const h = self.meta.per_frame.hooks.style_host orelse {
            // Hostless: nothing cascades back now, but the next theme replay stops keeping them.
            const rec = self.meta.per_frame.hooks.theme_inline orelse return;
            inline for (@import("zenit_reflection").fields(types.BoxStyle)) |f| {
                if (@field(fields, f.name) != null) @field(rec.style, f.name) = null;
            }
            return;
        };
        h.unset_inline(h.ptr, &fields);
    }

    /// side-effect-free background write entry. SoA only write path. Don't trigger
    /// transition/dirty/dedup. Route detail see pca.writeBackground.
    pub fn setBackgroundRaw(self: *Node, color: types.Color) void {
        node_tree.hostDirty(self);
        pca.writeBackground(self.world_ref, self.element_id_raw, @intFromPtr(self), color);
    }

    /// side-effect-free opacity write entry. Semantics like setBackgroundRaw.
    pub fn setOpacityRaw(self: *Node, value: f32) void {
        node_tree.hostDirty(self);
        pca.writeOpacity(self.world_ref, self.element_id_raw, @intFromPtr(self), value);
    }

    /// style.background field deleted, from World.paint_state (element_id!=0xFFFFFFFF) or
    /// standalone fallback (mock) read. No data return default.
    pub fn getBackground(self: *const Node) types.Color {
        return pca.readBackground(self.world_ref, self.element_id_raw, @intFromPtr(self));
    }

    /// this node plus subtree no enter paint: display:none, or fully transparent and don't require
    /// transparent render. All paint/tick traverse "skip invisible subtree" logic use this one
    /// criterion.
    pub fn isPaintSkipped(self: *const Node) bool {
        if (self.style.display == .none) return true;
        return self.getOpacity() == 0 and !self.style.keep_rendering_when_transparent();
    }

    /// self and all ancestor not display:none (i.e. "in paint tree"). Focus traverse/a11y use it
    /// exclude hidden subtree nodes.
    pub fn isDisplayedInTree(self: *const Node) bool {
        var cur: ?*const Node = self;
        while (cur) |n| : (cur = n.parent) {
            if (n.style.display == .none) return false;
        }
        return true;
    }

    /// display switch: change sibling layout (occupy/gap), mark self and parent layout re-draw.
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

    /// set text color (auto interpolate if text_color transition configured). Non-text node ignore.
    pub fn setTextColor(self: *Node, color: types.Color) void {
        const cur = self.getText() orelse return;
        if (self.frame_state.frame_local.runtime.transitions) |slots| {
            if (slots.find(.text_color)) |slot| {
                if (!types.Color.eql(color, if (slot.active) slot.to_color else cur.color)) {
                    slot.from_color = cur.color;
                    slot.to_color = color;
                    slot.start_time_ms = render_engine.current_frame_time_ms;
                    slot.active = true;
                    slots.any_active = true;
                    node_interaction.invalidateTickQuietChain(self);
                    self.markRenderDirty();
                }
                return;
            }
        }
        var tp = cur;
        tp.color = color;
        self.setText(tp);
        self.markRenderDirty();
    }

    /// set translate_x (auto interpolate if transition configured)
    pub fn setTranslateX(self: *Node, value: f32) void {
        if (self.routeInlineStyle(.{ .translate_x = value })) return;
        if (self.frame_state.frame_local.runtime.transitions) |slots| {
            if (slots.find(.translate_x)) |slot| {
                if (@abs(value - (if (slot.active) slot.to_value else self.style.translate_x)) > 0.1) {
                    slot.from_value = self.style.translate_x;
                    slot.to_value = value;
                    slot.start_time_ms = render_engine.current_frame_time_ms;
                    slot.active = true;
                    slots.any_active = true;
                    node_interaction.invalidateTickQuietChain(self);
                    // translate is composite-type property: unified authority invalidation
                    // composition (interaction + composite + cache invalid), match transition
                    // tick/animator/hooks.
                    self.markCompositePropDirty();
                }
                return;
            }
        }
        // Re-writing the current offset changes nothing: per-frame writers
        // (Slider's before-render thumb sync) would otherwise dirty the hit
        // scene every frame, and a live stationary pointer then re-resolves
        // hover against the new scene epoch and requests the next frame.
        if (self.style.translate_x == value) return;
        self.style.translate_x = value;
        self.markCompositePropDirty();
    }

    /// set rotate (auto interpolate if transition configured)
    pub fn setRotate(self: *Node, allocator: Allocator, value: f32) void {
        if (self.frame_state.frame_local.runtime.transitions) |slots| {
            if (slots.find(.rotate)) |slot| {
                if (@abs(value - (if (slot.active) slot.to_value else self.style.rotate())) > 0.001) {
                    slot.from_value = self.style.rotate();
                    slot.to_value = value;
                    slot.start_time_ms = render_engine.current_frame_time_ms;
                    slot.active = true;
                    slots.any_active = true;
                    node_interaction.invalidateTickQuietChain(self);
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

    /// immediate set value and sync transition slot (**don't** trigger animation): first-frame
    /// position/teleport scene use. Component must not directly rewrite slot from/to_value (engine
    /// private state), all via here.
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

    /// set transform_origin (affect scale/rotate baseline)
    pub fn setTransformOrigin(self: *Node, allocator: Allocator, value: types.TransformOrigin) void {
        const ext = self.style.ensureExtPanic(allocator);
        ext.transform_origin = value;
        self.markInteractionDirty();
        self.markCompositeDirty();
    }

    /// set width (auto interpolate if transition configured)
    pub fn setWidth(self: *Node, value: f32) void {
        if (self.frame_state.frame_local.runtime.transitions) |slots| {
            if (slots.find(.width)) |slot| {
                if (@abs(value - slot.to_value) > 0.1) {
                    const current = switch (self.style.width) {
                        .px => |v| v,
                        else => self.rectFromWorldOrFallback().w, // from layout result take current width
                    };
                    slot.from_value = current;
                    slot.to_value = value;
                    slot.start_time_ms = render_engine.current_frame_time_ms;
                    slot.active = true;
                    slots.any_active = true;
                    node_interaction.invalidateTickQuietChain(self);
                    self.markLayoutDirty();
                }
                return;
            }
        }
        self.style.width = .{ .px = value };
        self.markLayoutDirty();
    }

    /// one-time configure implicit animation transition for multiple properties. Afterward change
    /// via setBackground/setOpacity/setBorderColor/setTranslateX/setTranslateY/setWidth
    /// auto-transition animate.
    pub fn enableImplicitAnimation(
        self: *Node,
        allocator: Allocator,
        props: []const types.TransitionProp,
        spec: types.TransitionSpec,
    ) error{OutOfMemory}!void {
        if (props.len == 0) return;
        const slots = try self.ensureTransitionSlots(allocator);
        for (props) |prop| setTransition(slots, prop, spec);
    }

    /// Apply a CSS style's comptime transition parse result.
    ///
    /// usage:
    /// ```zig
    /// try node.applyTransition(allocator, comptime recipe.transition("background 200ms ease-out,
    /// opacity 150ms"));
    /// ```
    ///
    /// All or nothing: the slot block (allocated on the first transition) is the only allocation;
    /// when it fails the node is unchanged and `error.OutOfMemory` is returned, never a node that
    /// silently snaps where its style declares a transition.
    pub fn applyTransition(self: *Node, allocator: Allocator, entries: []const recipe_mod.TransitionEntry) error{OutOfMemory}!void {
        if (entries.len == 0) return;
        const slots = try self.ensureTransitionSlots(allocator);
        for (entries) |entry| setTransition(slots, entry.prop, entry.spec);
    }

    pub fn requestCompositeAnimationLinger(self: *Node, affects_opacity: bool, affects_transform: bool) void {
        if (!affects_opacity and !affects_transform) return;
        node_interaction.invalidateTickQuietChain(self);
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

    // 15 dirty methods impl moved to node_dirty.zig. Below thin delegate, keep original pub/private
    // visibility + node.zig self.markX() caller zero change (still call local delegate).
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
    // upgrade pub, node_interaction cross-module call via self.markHit*Dirty()
    pub fn markHitSemanticsDirty(self: *Node) void {
        node_dirty.markHitSemanticsDirty(self);
    }
    pub fn markHitStructureDirty(self: *Node) void {
        node_dirty.markHitStructureDirty(self);
    }
    // upgrade pub, node_tree cross-module call via self.bubbleChildRuntimeIndexDirty()
    pub fn bubbleChildRuntimeIndexDirty(self: *Node, full_rebuild: bool) void {
        node_dirty.bubbleChildRuntimeIndexDirty(self, full_rebuild);
    }
    pub fn markSubtreeDirty(self: *Node) void {
        node_dirty.markSubtreeDirty(self);
    }
    pub fn markCompositeDirty(self: *Node) void {
        node_dirty.markCompositeDirty(self);
    }

    /// composite property (opacity/translate/scale/rotate) write unique authority invalidation
    /// composition.
    pub fn markCompositePropDirty(self: *Node) void {
        node_dirty.markCompositePropDirty(self);
    }

    /// composite property per-frame animation drive (don't bump content version, keep surface
    /// reuse).
    pub fn markCompositeAnimFrameDirty(self: *Node) void {
        node_dirty.markCompositeAnimFrameDirty(self);
    }
    /// Own-transform (scroll offset) change: hit-layer aware variants of markInteractionDirty /
    /// markCompositeAnimFrameDirty / markCompositePropDirty (see node_dirty.markHitLayerMotion).
    pub fn markHitLayerMotion(self: *Node) void {
        node_dirty.markHitLayerMotion(self);
    }
    pub fn markHitLayerMotionAnimFrameDirty(self: *Node) void {
        node_dirty.markHitLayerMotionAnimFrameDirty(self);
    }
    pub fn markHitLayerMotionPropDirty(self: *Node) void {
        node_dirty.markHitLayerMotionPropDirty(self);
    }
    fn isOutOfBandRenderUnit(self: *const Node) bool {
        return node_dirty.isOutOfBandRenderUnit(self);
    }
    pub fn markRenderDirty(self: *Node) void {
        node_dirty.markRenderDirty(self);
    }
    pub const InheritedTextChange = node_dirty.InheritedTextChange;

    /// Inheritable text properties changed: re-measure / repaint the texts and descendants that
    /// resolve them (see node_dirty.markInheritedTextDirty).
    pub fn markInheritedTextDirty(self: *Node, change: InheritedTextChange) void {
        node_dirty.markInheritedTextDirty(self, change);
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

    pub fn removeDebugSignal(self: *Node, ptr: *anyopaque) void {
        const slots = &self.meta.ownership.debug_slots;
        var i: usize = 0;
        while (i < slots.signal_count) {
            if (slots.signals[i] != null and slots.signals[i].?.ptr == ptr) {
                slots.signal_count -= 1;
                std.mem.copyForwards(?DebugSignalRef, slots.signals[i..slots.signal_count], slots.signals[i + 1 .. slots.signal_count + 1]);
                slots.signals[slots.signal_count] = null;
            } else i += 1;
        }
    }

    // render cache 6 methods + TextHashSnapshot extract to node_render_cache.zig. Below thin
    // delegate (buildCachedRenderSlice former static fn now module-level free function, no longer
    // expose on Node).
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
    /// Releases both cross-frame payload caches (subtree and own content).
    pub fn invalidateSubtreePayloadCache(self: *Node) void {
        @import("render_engine/retained_memo.zig").dropMemo(self);
        node_render_cache.invalidateSubtreePayloadCache(self);
        node_render_cache.invalidateOwnPayloadCache(self);
    }
    pub fn getOrComputeTextHashes(self: *Node, t: *const TextProps) TextHashSnapshot {
        return node_render_cache.getOrComputeTextHashes(self, t);
    }

    /// remove child from parent, recursively trigger onCleanup. Note: don't free child memory.
    /// Caller need hand `cx.freeNode(child)` free.
    pub fn removeChild(self: *Node, child: *Node) void {
        node_tree.removeChild(self, child);
    }

    pub fn removeChildIncremental(self: *Node, child: *Node) void {
        node_tree.removeChildIncremental(self, child);
    }

    pub fn removeChildRetained(self: *Node, child: *Node) void {
        node_tree.removeChildRetained(self, child);
    }

    /// retention mode: recursively destroy node and subtree
    ///
    /// Note: don't dispose scope. Scope lifecycle managed by Scope tree (parent Scope.dispose()
    /// recursive dispose child). Caller should dispose scope before destroy, then clearNodeScopes
    /// clear stale ptr.
    pub fn destroy(self: *Node, allocator: Allocator) void {
        node_lifecycle.destroy(self, allocator);
    }

    /// remove all children, recursively trigger onCleanup. Note: don't free children memory. Caller
    /// need hand `cx.freeNode()` each child free.
    pub fn removeAllChildren(self: *Node) void {
        node_tree.removeAllChildren(self);
    }

    // upgrade pub, node_interaction cross-module call (lifecycle §N4 extract migrate)
    pub fn releasePathGeometry(self: *Node, allocator: Allocator) void {
        node_lifecycle.releasePathGeometry(self, allocator);
    }

    fn releaseStrokeGeometry(self: *Node, allocator: Allocator) void {
        node_lifecycle.releaseStrokeGeometry(self, allocator);
    }

    pub fn releaseCustomClipGeometry(self: *Node, allocator: Allocator) void {
        node_lifecycle.releaseCustomClipGeometry(self, allocator);
    }

    /// freeNode use, free node own path heap (path/stroke/custom_clip) via World.layout_output
    /// slot. Must before elements.destroy call (element_id still valid, layoutOutputPtr can get
    /// slot; after slot reuse will dirty). Semantics like §a freeNode free owned text first.
    pub fn releaseAllGeometry(self: *Node, allocator: Allocator) void {
        node_lifecycle.releaseAllGeometry(self, allocator);
    }

    // upgrade pub, node_dirty.zig cross-module call (interaction sub-domain Stage 3 extract
    // migrate)
    pub fn invalidateCustomClipGeometryCache(self: *Node) void {
        node_interaction.invalidateCustomClipGeometryCache(self);
    }
};

// fireMountIfNeeded/fireCleanupCallbacks/clearNodeScopes prior file-scope free fn (not Node
// method), moved to node_lifecycle.zig. Re-export here keep public API (external
// core/control_flow/hooks etc call).
pub const fireMountIfNeeded = node_lifecycle.fireMountIfNeeded;
pub const fireCleanupCallbacks = node_lifecycle.fireCleanupCallbacks;
pub const clearNodeScopes = node_lifecycle.clearNodeScopes;

test {
    _ = @import("text_update_tests.zig");
}

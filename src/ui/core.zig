/// UI Core - declarative UI framework core
///
/// Design principles:
/// 1. Inline declarative: ui.box(.{}, .{ child1, child2 }) replaces manual appendChild
/// 2. Unified Cx: merge UIContext/EventDispatcher/FocusManager/StateStore
/// 3. Component protocol: struct + render() method, components embed directly as children
/// 4. Type-safe handlers: create state explicitly, bind via cx.handler(State, id, method)
///
/// Example:
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
const dev_preview = @import("zenit_environment").dev_preview;
const Allocator = std.mem.Allocator;
const system_sdk_mod = @import("system_sdk");
const svg_assets_mod = @import("svg_assets.zig");
pub const svg_assets = svg_assets_mod;

// Import subsystems
const reactive = @import("reactive.zig");
pub const SignalOwner = reactive.SignalOwner;
pub const Signal = reactive.Signal;

/// Press state observer: signal means "current pressed target is in node's subtree"
pub const PressWatch = struct {
    node: *Node,
    signal: *Signal(bool),
};
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
/// Per-scroll-event handler effect accounting (event_dispatcher.scroll_effect).
pub const scroll_effect = event_dispatcher_mod.scroll_effect;
const interaction_drag = @import("interaction/drag.zig");
const focus_mod = @import("focus.zig");
const widget_state_mod = @import("widget_state.zig");
const actions_mod = @import("actions.zig");
const console_mod = @import("console.zig");
pub const theme = @import("theme.zig");
const a11y_preferences = @import("a11y/preferences.zig");
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

// Phase 0: ElementId generational handle, Phase 3 core index after Node split
pub const element_id = @import("core/element_id.zig");
pub const ElementId = element_id.ElementId;
pub const SlotMap = element_id.SlotMap;

// Phase 3: 4 tables + World container (replaces Node god-object as new source of truth)
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

// Phase 5: GpuDraw IR + DisplayItem encoder (v0.3 render main path switched to this)
pub const gpu_draw = @import("core/gpu_draw.zig");
pub const GpuDraw = gpu_draw.GpuDraw;
pub const display_item_encode = @import("core/display_item_encode.zig");

// Phase 6: GlyphRun + ShapingCache (cluster-aware text layout foundation)
pub const glyph_run = @import("core/glyph_run.zig");
pub const GlyphRun = glyph_run.GlyphRun;
pub const FontMetrics = glyph_run.FontMetrics;
pub const TextDirection = glyph_run.Direction;
pub const shaping_cache = @import("core/shaping_cache.zig");
pub const ShapingCache = shaping_cache.ShapingCache;
pub const ShapingKey = shaping_cache.ShapingKey;

// GlyphRun pipeline takes over old ASCII-first measure path;
// cx.shapeText calls TextShaper.shape() to build GlyphRun, cached via ShapingCache.
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

// Phase 4: true compositing layers (replaces per-frame CompositorPlan rebuild)
pub const layer_tree = @import("core/layer_tree.zig");
pub const LayerTree = layer_tree.LayerTree;
pub const LayerId = layer_tree.LayerId;
pub const Layer = layer_tree.Layer;
pub const PromotionReason = layer_tree.PromotionReason;
pub const layerize_mod = @import("core/layerize.zig");
pub const PromotionHint = layerize_mod.PromotionHint;
pub const layerize = layerize_mod.layerize;

// Phase 0: DirtyFlags replace 13 scattered Node booleans + 2 versions. Phase 3 integrates.
pub const dirty_flags = @import("core/dirty_flags.zig");
pub const DirtyFlags = dirty_flags.DirtyFlags;

// Phase 2: Layout constraint passing model (Taffy style). Phase 3 layout_engine switches.
pub const layout_constraint = @import("core/layout/constraint.zig");
pub const LayoutInput = layout_constraint.LayoutInput;
pub const LayoutOutput = layout_constraint.LayoutOutput;
pub const AvailableSpace = layout_constraint.AvailableSpace;
pub const AvailableSpaceXY = layout_constraint.AvailableSpaceXY;
const snapshot_mod = @import("core/snapshot.zig");
const hit_runtime_mod = @import("core/hit_runtime.zig");
pub const interaction_semantics = @import("core/interaction_semantics.zig");
// redraw.zig global only set by node.markRenderDirty, Cx.render no longer depends on it
// (HMR across dylib: Plugin/Host each have own global, unreliable)
pub const layout_engine = @import("core/layout_engine.zig");

pub const render_engine = @import("core/render_engine/mod.zig");
const inspector_mod = @import("core/inspector.zig");
const scene_runtime_mod = @import("core/scene_runtime.zig");
const property_tree_mod = @import("core/property_tree.zig");
const display_list_mod = @import("core/display_list.zig");
const text_blob_mod = @import("core/text_blob.zig");

// gesture + a11y modules (at src/ui/ level, not in core/ subdir)
const gesture_input = @import("input/gesture_recognizer.zig");
pub const gesture = gesture_input;
const a11y_tree_mod = @import("a11y/tree.zig");
const a11y_macos_bridge_mod = @import("a11y/macos_bridge.zig");
const a11y_router_mod = @import("a11y/nsaccessibility_router.zig");
/// a11y_tree submodule re-exported outward (tests / platform bridges etc).
pub const a11y_tree = a11y_tree_mod;
pub const a11y_macos_bridge = a11y_macos_bridge_mod;
pub const a11y_router = a11y_router_mod;
pub const display_list = display_list_mod;
pub const paint_invariants = @import("core/paint_invariants.zig");
pub const text_blob = text_blob_mod;
pub const debug_trace = inspector_mod.debug_trace;
pub const text_layout = @import("core/text_layout.zig");

// ========== Basic types ==========
pub const Size = core_types.Size;
pub const ComputedRect = core_types.ComputedRect;
pub const Point = core_types.Point;
pub const Padding = core_types.Padding;
pub const Margin = core_types.Margin;

// ========== Sizing model (learned from Gooey) ==========
pub const Sizing = core_types.Sizing;
pub const FlexBasis = core_types.FlexBasis;
pub const Direction = core_types.Direction;
pub const JustifyContent = core_types.JustifyContent;
pub const AlignItems = core_types.AlignItems;
pub const AlignContent = core_types.AlignContent;
pub const FlexWrap = core_types.FlexWrap;
pub const ScrollDirectionHint = core_types.ScrollDirectionHint;

// Type aliases
pub const Justify = core_types.Justify;
pub const Alignment = core_types.Alignment;

// ========== Color and theme ==========
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

// ========== Styling (Layout Config) ==========
pub const Style = core_types.Style;
pub const BoxStyle = core_types.BoxStyle;
pub const ShadowList = core_types.ShadowList;
pub const InsetShadowList = core_types.InsetShadowList;
pub const Inset = core_types.Inset;
pub const InsetValue = core_types.InsetValue;
pub const StyleOverride = core_types.StyleOverride;
pub const InteractionState = core_types.InteractionState;
pub const Outline = core_types.Outline;
pub const CursorShape = core_types.CursorShape;

/// Custom bitmap cursor descriptor (input to `Cx.setCustomCursor`). SVG preserves aspect ratio;
/// `size_pt` only constrains logical width (output width = size_pt, viewBox scales proportionally);
/// `hot_x/hot_y` are the final bitmap's hotspot in logical coords (points) from the top-left
/// origin.
/// If size_pt != viewBox width the caller must scale them (usually size_pt == viewBox width).
pub const CustomCursorDesc = custom_cursor_mod.CustomCursorDesc;

pub const CustomCursorEntry = custom_cursor_mod.CustomCursorEntry;

// ========== Recipe styling system ==========
pub const transition = recipe.transition;
pub const TransitionEntry = recipe.TransitionEntry;

// ========== Grid Layout ==========
pub const GridTrackSize = core_types.GridTrackSize;
pub const GridConfig = core_types.GridConfig;
pub const GridPlacement = core_types.GridPlacement;

// ========== Accessibility ==========
pub const A11yRole = core_types.A11yRole;
pub const A11yProps = core_types.A11yProps;
pub const A11yOrientation = core_types.A11yOrientation;
pub const A11ySortDirection = core_types.A11ySortDirection;
pub const A11yRect = core_types.A11yRect;
pub const A11yValueRange = core_types.A11yValueRange;
pub const TextInputClient = core_types.TextInputClient;
pub const TextInputSelection = core_types.TextInputSelection;

// ========== Element type tags ==========
pub const ElementTag = core_types.ElementTag;
pub const TextProps = core_types.TextProps;
pub const TextWrap = core_types.TextWrap;
pub const OverflowWrap = core_types.OverflowWrap;
pub const WordBreak = core_types.WordBreak;
pub const TextAlign = core_types.TextAlign;
pub const TextSpan = core_types.TextSpan;
pub const UnderlineStyle = core_types.UnderlineStyle;
pub const ImageProps = core_types.ImageProps;
pub const IconProps = core_types.IconProps;

// ========== Handler system (type-safe) ==========
pub const HandlerRef = core_types.HandlerRef;

/// Unified callback type for UI events (docs/SIGNAL_API_DESIGN.md §4.5). `Handler(void)` is
/// Node-level `HandlerRef` (non-generic, in Node); payload events are `reactive.Callback(T)`.
/// Construct via `cx.on(S, s, S.method)`, payload type inferred from method signature.
pub fn Handler(comptime T: type) type {
    return if (T == void) HandlerRef else reactive.Callback(T);
}
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

// ========== UI nodes ==========
pub const Node = core_node.Node;
pub const BeforeRenderScope = core_node.BeforeRenderScope;
/// Focus strategy on left-click, see `NodeInteraction.pointer_down_focus`.
pub const PointerDownFocus = core_node.PointerDownFocus;
/// Sentinel value for Node.world_id (not registered to any World). See P0-3 owner identification.
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

/// One-shot adopt: attach freshly-built child to parent immediately, free child on append failure.
/// "Build then attach" avoids window between create->append, no flag guard needed;
/// adoptTagChild / adoptTabChild / adoptDividerChild in components are it.
/// Precondition: parent itself already attached to a guarded subtree (root has errdefer freeNode).
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

// Cx methods split by domain in core/cx_*.zig (free functions take *Cx), Cx keeps same-named
// pub thin delegates to preserve public API:
//   cx_input          mouse / keyboard / IME / wheel / drag entry
//   cx_cursor         cursor lease + cursor shape decision
//   cx_render         render() frame pipeline, after-layout hooks, redraw scheduling
//   cx_frame          frame clock, idle frame gating, deferred budget
//   cx_runtime_index  interaction index / focus order full + incremental rebuild
//   cx_world_sync     Node -> World table sync, layerize
//   cx_world_hooks    process-level Node -> World routing callbacks (g_active_world*)
//   cx_node_lifetime  detach / freeNode / reference invalidation
//   cx_a11y           a11y tree sync + macOS bridge callbacks (projection rules in a11y_projection)
//   cx_platform       SystemSdk / window identity / native text input session
//   cx_bulk_quads     bulk quad layer
const cx_input = @import("core/cx_input.zig");
const cx_cursor = @import("core/cx_cursor.zig");
const cx_hover = @import("core/cx_hover.zig");
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
/// System clipboard / file dialog. Takes `?*SystemSdk`; usage:
/// `platform_services.clipboardSetText(cx.system_sdk, text)`.
pub const platform_services = @import("core/platform_services.zig");

// ========== Cx: unified context ==========

/// main union DisplayItem field deleted; only main_paint (paint_table.DisplayItem) remains and the
/// encoder main path consumes it directly. paint_table is the sole source.
///
/// _dead_main: RenderContext / DrawContext still have a lowering_buffer field
/// (*ArrayList(union DisplayItem)) as a placeholder; no active caller appends/reads it.
/// An empty ArrayList keeps the pointer valid; delete the field from RenderContext/DrawContext
/// together with this one.
pub const LoweringBuffers = struct {
    _dead_main: std.ArrayList(display_list_mod.DisplayItem) = .empty,
    main_paint: std.ArrayList(paint_table.DisplayItem) = .empty,

    pub fn deinit(self: *LoweringBuffers, allocator: Allocator) void {
        self._dead_main.deinit(allocator);
        self.main_paint.deinit(allocator);
    }
};

/// Unified context - merges UIContext/EventDispatcher/FocusManager/StateStore. paint chunk write
/// failures (OOM). Each means partial screen missing, must be 0 at steady state (audit report sect
/// 3: make silent-drop family observable).
pub var paint_push_failures: u64 = 0;

/// interaction table write failures (OOM). Each means node unhittable that frame (click/hover
/// silent fail), must be 0 at steady state.
pub var interaction_put_failures: u64 = 0;

/// a11y active context registration failures. Only if simultaneous windows exceed
/// macos_bridge.MAX_WINDOWS; consequence: window unreadable to VoiceOver (rendering unaffected).
pub var a11y_context_register_failures: u64 = 0;

/// AXScrollToVisible scroll implementation registered by ScrollArea on first mount (core
/// independent of components). scroll is ancestor container with tag=.scroll; returns whether
/// scroll position actually adjusted.
pub var a11y_scroll_into_view_hook: ?*const fn (scroll: *Node, target: *Node) bool = null;

/// Per-glass luminance sample (renderer projects from luminance slot each frame; key = glass owner
/// node id).
pub const BackdropLumRegion = struct { node_id: u32, lum: f32, lum_srgb: f32 = 0 };

/// Bulk rectangles, bypass Node tree's 'batch of homogeneous rects' submission unit.
///
/// Implementation moved entirely to core/bulk_quad_layer.zig (five fields + thirteen methods).
/// Public alias retained here: consumers (downstream apps etc) use ui.BulkQuad / Cx.setBulkQuads,
/// type move shouldn't break external API. Complete motivation, constrained semantics, and
/// pixel-equivalence guarantees in that module header.
pub const BulkQuad = bulk_quad_layer_mod.BulkQuad;

/// One BulkQuad degrades to at most N DisplayItems (see bulk_quad_layer.zig).
pub const MAX_ITEMS_PER_QUAD: usize = bulk_quad_layer_mod.MAX_ITEMS_PER_QUAD;

/// Window portal above user UI, below DevTools overlay (32000). Exact order within portal still
/// determined by OverlayStack's 100..3000 tier.
pub const WINDOW_PORTAL_Z_INDEX: i16 = 31_000;

/// Component private memory released by Cx (currently only ScrollArea's ScrollCtxCell). Use
/// destroyFn to erase concrete type, avoid core -> components reverse dependency.
pub const OwnedCell = struct {
    ptr: *anyopaque,
    destroyFn: *const fn (*anyopaque, Allocator) void,
    /// Reclaim before a later registration only after both owner and every
    /// escaped node callback have released the cell. Null retains until exit.
    can_destroy: ?*const fn (*anyopaque) bool = null,
};

/// Callback result after layout, before generating paint commands.
pub const AfterLayoutResult = enum { done, needs_layout };
/// round starts at 0; when last_round=true, returning needs_layout won't be called again.
pub const AfterLayoutFn = *const fn (ctx: *anyopaque, round: u8, last_round: bool) AfterLayoutResult;
/// Max loop cycles within one frame (callback -> layout).
pub const max_after_layout_rounds: u8 = 4;
const AfterLayoutHook = struct { ctx: *anyopaque, run: AfterLayoutFn };

pub const CountingAllocator = @import("core/counting_allocator.zig").CountingAllocator;

/// A left release that may dismiss overlays its press began outside of (`Cx.press_releases`).
pub const PressRelease = struct {
    press_handle: ?NodeHandle,
    press_owner: ?overlay_stack_mod.LayerHandle,
    press_mark: u64,
};

pub const Cx = struct {
    pub const AllocationOwner = enum { text, world, display_list, property_tree, frame_arena, interaction, node_cache, text_blob, scene_runtime };
    pub const PresentationSample = @import("core/presentation_clock.zig").Sample;
    /// Retained as public alias (implementation: core/frame_perf.zig).
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

    allocation_probe_enabled: bool = false,
    allocation_counters: [9]CountingAllocator = undefined,
    allocator: Allocator,
    io: std.Io,
    owner: *SignalOwner,
    lifetime_token: *LifetimeToken,

    // UI tree
    root: ?*Node = null,
    /// The application's own tree under `root` (App mounts it beside the overlay portal).
    /// Keys with no focused node are delivered here, so capture/bubble handlers on the
    /// application root (window-level shortcuts) see them. Only used while it is still a
    /// child of `root`; otherwise `root` receives them.
    content_root: ?*Node = null,
    /// Window-root portal, sole host of all overlays detached from normal document flow.
    /// Popover/Tooltip only attach floating content here, trigger wrapper stays in caller tree.
    /// Modal/Sheet barrier also direct child of same portal, lets OverlayStack's z-index tier
    /// correctly sort same-level siblings. App.mount sets it before calling user mount_fn;
    /// low-level standalone Cx auto-builds it under existing root via ensurePopoverPortalRoot(), no
    /// inline fallback.
    popover_portal_root: ?*Node = null,
    /// Debug dedup: most recent node id checked for 'portal ancestor chain has no clip/effect
    /// surface' (0 = never checked). See checkPopoverPortalAncestry.
    popover_portal_ancestry_checked_id: u32 = 0,
    next_id: u32 = 1,

    // Interaction state
    hovered_node: ?*Node = null,
    focused_node: ?*Node = null,
    pressed_node: ?*Node = null,
    hovered_handle: ?NodeHandle = null,
    focused_handle: ?NodeHandle = null,
    /// magnify gesture dispatch target locked during gesture (hit on began, cleared on
    /// ended/cancelled)
    magnify_target_handle: ?NodeHandle = null,
    /// Current drop target in drag session. Store handle not raw pointer: resolve brings existence
    /// check, avoids use-after-free if node freed during drag (see invalidateReferencesTo comment
    /// on hovered_node).
    drag_hover_handle: ?NodeHandle = null,
    /// Increments per drag location event. handleDragPayload handler may sync re-enter next drag
    /// event (same Cx), outer uses this to know it's been superseded.
    drag_event_seq: u64 = 0,
    pressed_handle: ?NodeHandle = null,
    /// Pressed state observer (hooks.usePressed): recalc 'pressed falls in subtree' when
    /// pressed_node changes. Press changes twice per click, observer count = nodes using `_active`
    /// style, linear recalc sufficient.
    press_watchers: std.ArrayListUnmanaged(PressWatch) = .empty,
    /// Most recent mouseDown hit node (not cleared on mouseUp, available to on_before_render)
    last_mouse_down_target: ?*Node = null,
    /// Most recent left-press hit overlay (fallback for outside-click check during render).
    press_overlay_owner: ?overlay_stack_mod.LayerHandle = null,
    /// Press swallowed by `.close_and_consume` overlay: corresponding release also swallowed.
    swallowed_press_button: ?MouseButton = null,
    last_mouse_down_handle: ?NodeHandle = null,
    /// Mark whether this frame has new mouseDown event (cleared each frame)
    has_new_mouse_down: bool = false,
    /// A left press is down whose release may dismiss overlays it began outside of.
    outside_press_armed: bool = false,
    /// OverlayStack.activationMark() when that press began: layers it opened stay open.
    outside_press_mark: u64 = 0,
    /// This frame released such a press (cleared each frame): outside-click dismissal.
    has_new_press_release: bool = false,
    /// Those releases, each with the press it ends (one event batch can hold a release and a
    /// later press, which overwrites the press fields above). Render dismisses in order.
    press_releases: [4]PressRelease = undefined,
    press_release_count: u8 = 0,

    // (Deleted: hovered_node_id/pressed_node_id/focused_node_id, retain mode: nodes don't rebuild,
    // use ?*Node directly)

    mouse_x: f32 = 0,
    mouse_y: f32 = 0,
    viewport: Size = Size.ZERO,
    /// App-defined 'safe area' insets, space occupied by title bar / tab bar / status bar. floating
    /// UI (popover/hover/tooltip) subtracts when computing viewport bounds, avoids popover top
    /// going behind title bar. Caller sets once after app shell layout. Default 0 (no chrome).
    safe_area_top: f32 = 0,
    safe_area_bottom: f32 = 0,
    safe_area_left: f32 = 0,
    safe_area_right: f32 = 0,
    window_scale: f32 = 1.0,

    /// Current system cursor shape (avoid repeated platform API calls)
    current_cursor: CursorShape = .default,
    cursor_override: ?CursorShape = null,
    cursor_state: cursor.State = .{},
    /// Stationary-pointer hover: pointer liveness and the hit-scene epoch the current hover was
    /// resolved against (core/cx_hover.zig).
    hover_sync: cx_hover.HoverSync = .{},
    /// Custom bitmap cursor (content of CursorShape.custom), key -> rasterized bitmap. Only one
    /// active bitmap at any moment (active_custom_cursor). Store responsible for 'desc -> rasterize
    /// -> content-addressed cache', handoff to system stays in updateCursorShape (where system_sdk
    /// / window_id needed). Implementation: core/custom_cursor.zig.
    custom_cursor: custom_cursor_mod.CustomCursorStore = .{},
    /// Harness automation pointer. Visible only after automation pointer command received;
    /// draw-only, no layout/hit/native cursor participation.
    virtual_cursor: virtual_cursor_mod.VirtualCursor = .{},

    /// Frame counter (for multi-click timing etc)
    frame_count: u64 = 0,

    /// Actual frame interval (seconds), updated each frame by renderFrame. Animation system uses
    /// this instead of hardcoded 1/60.
    frame_dt_seconds: f32 = 1.0 / 60.0,
    /// App preference plus renderer fallback; no timer/timebase manipulation.
    reduced_motion: bool = false,
    renderer_reduced_motion: bool = false,
    /// Host window has active appearance (app in foreground and key window). Native inactive
    /// window: Glass.tint desaturated to gray layer (native_tint_backdrop.swift inactive), GlassBox
    /// switches material accordingly.
    window_active: bool = true,
    /// Platform glass rendering (`UIUserInterfaceIdiom`-like): selects the measured macOS or
    /// iOS Liquid Glass profile for every GlassBox / GlassShape without an explicit `idiom`.
    /// Defaults to the build target; set `.ios` on desktop to preview the mobile rendering.
    glass_idiom: @import("components/glass_box/profile.zig").GlassIdiom = @import("components/glass_box/profile.zig").GlassIdiom.host(),
    /// Previous frame timestamp (for frame interval calculation)
    last_frame_instant: ?@import("zenit_time").Instant = null,

    /// Monotonic increasing frame time (ms), relative to app startup. Drives absolute-timestamp
    /// animations. f64 avoids precision loss after long runtime (f32 loses sub-ms precision after
    /// ~16.7s).
    ///
    /// **Derived from wall clock**: frame_time_ms = (now - clock_epoch) - clock_paused_ns. Not
    /// cumulative dt sum, accumulation loses each clamped-short frame permanently (measured: 5s
    /// real time at 4fps = 2s elapsed, animations run at 40% speed and never catch up), shows as
    /// 'worse perf -> slower animation'.
    frame_time_ms: f64 = 0,
    /// Explicit harness-only deterministic animation sampling. null is realtime.
    test_frame_step_ms: ?f32 = null,
    /// Harness perf probe: render every frame with the whole tree dirtied, a
    /// steady full-repaint load that does not depend on input or the driver.
    test_force_frames: bool = false,
    /// Locked test clock: with a fixed step, time advances only while budget
    /// remains (granted by the harness), so a slow or remote driver can stop an
    /// animation at an exact moment. null = unlimited fixed steps.
    test_clock_budget_ms: ?f64 = null,
    clock_time_offset_ms: f64 = 0,
    /// Optional host display cadence scoped to a real renderer frame. It does
    /// not replace the wall/event clock used by input, timers or physics dt;
    /// event-side hit-test hooks must never read a previous frame's target.
    frame_presentation_sample: ?PresentationSample = null,
    /// Logical clock origin. Anchored on first advanceFrameClock.
    clock_epoch: ?@import("zenit_time").Instant = null,
    /// Accumulated idle pause duration (ns). idle frames don't advance logical clock (zero-dirty
    /// fast path depends on it), real time recorded as offset not injected into animations, so
    /// active frames resume with continuous timeline.
    clock_paused_ns: u64 = 0,
    /// Frame interval (ms), derived from frame_dt_seconds, for incremental dt consumers (actual
    /// frame interval, capped 1s).
    frame_dt_ms: f32 = 16.667,
    /// Previous advanceFrameClock was idle: next active frame's dt excludes idle wait.
    frame_clock_was_idle: bool = false,
    /// Current display refresh rate (Hz)
    display_refresh_hz: f32 = 60.0,
    /// Frame perf sampling (four-chain ring buffers, see core/frame_perf.zig).
    ///
    /// Originally laid out 14 flat fields + 17 methods, push/percentile/avg/max logic copied four
    /// times. Self-contained, no Cx state touched, moved to independent value type; Cx methods now
    /// thin forwards, call sites unchanged.
    frame_perf: frame_perf_mod.FramePerf = .{},
    /// Frame-level redraw flag (R4a: idle zero cost). Set on input, active animation, window
    /// resize. App checks during frame loop, skips buildUI/layout/render/GPU submit when idle.
    needs_redraw: bool = true,

    /// Last tick pass: active node transition/command animations pending. Feeds hasPendingSceneWork
    /// O(1) check, replaces full-tree recursion: animations start via markXxxDirty (root dirty
    /// covers 'started this frame'), ongoing tracked in last-frame tick return; false positives
    /// just rerender one frame, self-heal.
    last_tick_animations_active: bool = false,

    // Stage B R3d (B line): cx.display_list is true source, lowering substruct below holds encoder
    // buffer (paint pass -> derive translation target + inspector overlay merge). After v0.5 sect 5
    // GpuDraw (commit 10d26a8), encoder eats lowering.main_paint; lowering.main union kept for
    // inspector overlay + internal diagnostics. Direct lowering.* reads = internal; external
    // callers use cx.lowerForEncoderPaintTable().
    lowering: LoweringBuffers = .{},
    /// Periodic custom draws handed to the system compositor (see compositor_sprite).
    sprites: @import("core/compositor_sprite.zig").Registry = .{},

    /// Stage B R3d: clean fast path returns display_list slice directly (display_list stable
    /// cross-frame, no snapshot). Flag set false on first frame / resize / force redraw to walk
    /// full paint pass and fill lowering.main for encoder.
    last_render_valid: bool = false,
    /// Per-frame paint invariant self-check (e2e / test-mode enabled by host): same node emitting
    /// identical fill rects counts against fields below, see core/paint_invariants.zig. Zero cost
    /// when off.
    paint_invariant_check: bool = false,
    /// Cumulative duplicate fill rect count (only increases, e2e asserts 0)
    paint_duplicate_fills: u64 = 0,
    /// Most recent duplicate node id (diagnostics; 0 = never occurred)
    paint_duplicate_node: u32 = 0,
    /// ZENIT_VERIFY_INCREMENTAL: cumulative lowered items that differed between the cached path
    /// and the reference full path (only increases, 0 = incremental == full on every frame).
    incremental_verify_mismatch_total: u64 = 0,
    /// frame_time_ms from last render(). frame_time_ms advance means possible animation running,
    /// can't skip even if dirty clean (animation hook no chance to advance).
    last_render_frame_time_ms: f64 = 0,

    /// overlay render commands segmented and recorded (merged by z_index, ensures nested overlay
    /// tiers correct). Frame-level arena allocator, reset each frame, for temporary computation
    /// (avoid heap fragmentation).
    frame_arena: std.heap.ArenaAllocator,
    deferred_epoch: @import("zenit_time").Instant,
    deferred_scheduler: DeferredScheduler,
    /// One-shot timer (setTimer). When due, wakes frame loop and fires at render start.
    timers: std.ArrayListUnmanaged(Timer) = .empty,
    next_timer_id: u64 = 1,
    /// fireDueTimers in progress; nested fireDueTimers in callbacks doesn't spin up another round
    /// (see its comment).
    firing_timers: bool = false,

    // Inspector (DevTools)
    inspector: Inspector = .{},
    /// Per-window diagnostic log store. It lives with the target Cx rather
    /// than with the DevTools window, so logs are captured before DevTools is
    /// opened and two windows never share output.
    console_store: console_mod.Console,

    node_registry: NodeRegistry,
    interaction_index: InteractionIndex,
    /// Window-local observation cache; global dirty generation invalidates it.
    loose_interaction_memo: struct {
        root: ?*Node = null,
        gen: u64 = 0,
        result: bool = false,
        scans: u64 = 0,
    } = .{},
    /// SVG texture cache + hit geometry (implementation: core/svg_texture_store.zig). Originally
    /// three fields + six methods here, self-contained ownership loop, moved entirely out.
    svg_textures: svg_texture_store.SvgTextureStore,
    scene_runtime: scene_runtime_mod.SceneRuntime,
    property_tree: property_tree_mod.PropertyTree,
    display_list: display_list_mod.DisplayList,
    text_blob_store: text_blob_mod.BlobStore,
    /// Bulk rect layer (implementation: core/bulk_quad_layer.zig). Host submits batch of
    /// absolute-coord rects, bypasses Node mount/layout/paint traversal; at render time
    /// appendBulkQuads lowers into display list and inserts at anchor position. Fields retained as
    /// bulk_quads_* names on Cx (tests / devtools direct read), aliases to layer's five state
    /// fields.
    bulk_quads: std.ArrayListUnmanaged(BulkQuad) = .empty,
    /// Node bulk layer attaches to (see setBulkQuads). null = detached (drawn above tree,
    /// unclipped). Render inserts batch by that node's display item interval and clip/transform id.
    bulk_quads_anchor: ?*Node = null,
    /// z_index start of 'interaction overlay' in anchor subtree (see setBulkQuads). null = entire
    /// anchor subtree is static content.
    bulk_quads_overlay_z: ?i16 = null,
    /// Host-declared batch layer content version (see setBulkQuadsVersioned).
    bulk_quads_version: ?u64 = null,
    /// External clip rect table keyed by node.id -> viewport-sys x/y/w/h.
    ///
    /// Semantics: node (entire subtree) additionally clipped by this rect, intersected with own
    /// overflow clip. Node need not be parent/child of clip source, host use case is canvas objects
    /// laid flat (frame and members are sibling Nodes), frame's clip only marked per-node by host.
    /// Side table not Node field: top-level Node has SoA size discipline, this is sparse (only
    /// canvas frame members) Implementation: core/bulk_quad_layer.zig.
    external_clip_rects: std.AutoHashMapUnmanaged(u32, [4]f32) = .{},
    /// This frame batch layer content matches last frame (by version number; see
    /// core/bulk_quad_layer.zig setVersioned).
    bulk_quads_unchanged: bool = false,

    // World container holds 4 tables (ElementTable / LayoutTable / PaintTable / InteractionTable) +
    // dirty_set. Currently shadow-mode dual-write: old Cx fields (property_tree, display_list,
    // scene_runtime) still true render source; World shadows for v0.2-P4+ consumers. v0.3 flips
    // source-of-truth.
    world: world.World,
    // LayerTree true composite layers. Each frame layerize groups World.elements into layers. After
    // v0.5 Stage A (2026-05-01) compositor_plan.zig deleted, LayerTree = layer source-of-truth;
    // CompositedLayer attaches directly to LayerTree.Layer.composited.
    layer_tree: layer_tree.LayerTree,
    // Gesture infrastructure wired:
    // - cx.handleMouseDown/Move/Up feed gesture_arena.onTouchDown/Move/Up
    // - cx.render() ticks each frame (long_press timing)
    // - cx.registerGesture(target, kind, config, callback) exposes the API
    // input/state.zig custom double/triple/drag anchor coexists with the old path (dispatcher
    // builtin click/double_click synthesis + input component handleMouseDown); not yet migrated.
    // Full migration (input to GestureArena) awaits a user scenario.
    gesture_arena: gesture_input.GestureArena,
    // AccessibilityTree full ARIA projection. v0.6 sect 2.1 (commit 1370e15-946d9d7) = macOS
    // NSAccessibility main path: cx.render() tail syncA11yTreeFromInteractions projects Node tree
    // to A11yNode; ObjC accessibilityChildren protocol method pulls data via
    // a11y/macos_bridge.zig's 9 zenit_a11y_* C ABI. focus_manager.a11y_bridge (old single-point
    // notify) remains for focus/property change; children navigation 100% via new tree.
    accessibility_tree: a11y_tree_mod.AccessibilityTree,
    /// A11yNode stores u64 hash of label/description/value only; this table holds hash -> string
    /// reverse map, lets platform bridge (NSAccessibility / IAccessible) look up real UTF-8 string
    /// for AT tools. Rebuilt each frame tail in syncA11yTreeFromInteractions.
    a11y_label_buf: @import("core/a11y_projection.zig").LabelStore = .{},
    /// macOS: skip the per-frame a11y projection until an assistive client
    /// queries this process (see `a11y.macos_bridge.ProjectionDemand`). App
    /// runtimes enable it; a bare Cx (tests, tools) keeps eager projection.
    /// Other platforms always project: their bridges read the tree directly.
    a11y_on_demand: bool = false,
    /// A frame skipped projection, so the a11y tree lags the node tree.
    a11y_projection_stale: bool = false,
    /// A render happened since World.paint / World.interaction last mirrored the
    /// node tree. Those tables have no reader in the render, hit-test or event
    /// path (only `layerizeFrame`, the layout integrity audit and tests), so the
    /// full-tree mirror runs when a reader asks (`ensureWorldTablesSynced`)
    /// instead of at the end of every frame.
    world_tables_stale: bool = false,
    /// push-side bridge context, holds window_id + label_resolver pointer. Reset each
    /// syncA11yTreeFromInteractions; flushToBridge calls macos_bridge extern push fn, bounces back
    /// this ref for window_id.
    a11y_push_cx_ref: a11y_macos_bridge_mod.PushCxRef = .{
        .window_id = 0,
        .label_ctx = undefined,
        .label_resolver = undefined,
    },
    perf: PerfCounters = .{},
    /// Input-side work since the last traced frame (ZENIT_PERF_TRACE); reset by the host.
    input_perf: hit_runtime_mod.InputPerfCounters = .{},
    /// node_tree.g_scene_mutation_gen / frame_time_ms at the end of the last before-render tick
    /// (frame or event-time hit refresh); see cx_render.ensureHitTestSceneFresh.
    hit_scene_tick_gen: u64 = 0,
    hit_scene_tick_time_ms: f64 = std.math.nan(f64),
    before_render_frame: ?u64 = null,
    before_render_time_ms: f64 = std.math.nan(f64),
    next_redraw_scheduled_at: ?@import("zenit_time").Instant = null,
    next_redraw_delay_ns: ?u64 = null,

    /// Frame-local app declaration; only the host may override paint visibility.
    /// Host input generation distinguishes new interaction from retry-generated redraws.
    input_epoch: u64 = 0,
    caret_flip_host: bool = false,
    caret_phase_valid: bool = false,
    caret_visible: bool = true,
    /// Whether the focused field painted its blinking caret this frame (null:
    /// none, or the compositor blinks it). Pacing traces time the flips.
    caret_shown: ?bool = null,
    caret_next_ns: i128 = 0,
    caret_half_ns: u64 = 500 * std.time.ns_per_ms,
    caret_paint_override: ?bool = null,
    caret_rects: [64][4]f32 = undefined,
    caret_rect_count: usize = 0,
    caret_rect_overflow: bool = false,

    // Theme tokens (runtime switchable)
    tokens: *const theme.ThemeTokens = &theme.dark,
    /// setTheme increments on each swap; before_render hook can compare to decide whether to
    /// re-read tokens (avoid syncing derived style every frame).
    theme_version: u32 = 0,
    /// theme Signal-ified: lazy-created (themeSignal()), set on setTheme, lets Effect/Memo
    /// reactively subscribe to theme switch instead of polling theme_version.
    window_service: ?system_sdk_mod.window_chrome.Service = null,
    window_chrome_signal: ?*Signal(system_sdk_mod.window_chrome.State) = null,
    /// Registered presentation slot. Scope cleanup clears it before freeing nodes.
    window_header_node: ?*Node = null,
    window_header_offset: [2]f32 = .{ 0, 0 },
    window_header_reveal_leases: u32 = 0,
    /// Owner of the Cx-wide reactive services below (see `serviceScope`).
    service_scope: ?*Scope = null,
    theme_signal: ?*Signal(*const theme.ThemeTokens) = null,
    style_generation: if (dev_preview) u64 else void = if (dev_preview) 0 else {},
    style_signal: if (dev_preview) ?*Signal(u64) else void = if (dev_preview) null else {},
    /// System a11y display preferences (a11y/preferences.zig): this Cx's synced process-level
    /// version, and lazy-created Signal (a11yPreferencesSignal, a Cx service like theme_signal).
    a11y_prefs_version: u32 = 0,
    a11y_prefs_signal: ?*Signal(a11y_preferences.Preferences) = null,
    // System communications SDK (optional)
    system_sdk: ?*system_sdk_mod.SystemSdk = null,
    /// Sole owner of window-level native text input context. active tracks logical focused client;
    /// native_enabled == null means platform state unknown, needs reconciliation after SDK attach.
    /// Native IME session account-state machine (implementation: core/text_input_session.zig).
    /// Three-state native_enabled rationale in that module header.
    text_input_session: text_input_session_mod.TextInputSession = .{},
    /// backdrop luminance adaptive: last frame glass backdrop measured average luminance (0-1
    /// linear). App runtime writes after GPU readback; null = disabled/no glass.
    backdrop_luminance: ?f32 = null,
    /// Per-glass backdrop luminance (key = glass owner node id, scroll-stable). Components match
    /// exactly by own node id, fall back to global average if miss. Capacity = renderer luminance
    /// slot count 32 x (monolith 1 + GlassGroup members 8), compile-assert in renderer. Early 32:
    /// leftover slots from old stories filled front, new glass slots never wrote, first-frame probe
    /// never got reading.
    backdrop_luminance_regions: [288]BackdropLumRegion = undefined,
    backdrop_luminance_region_count: usize = 0,
    /// Renderer readback backdrop luminance per-glass (set true on App runtime Cx create; headless
    /// / test Cx = false). GlassBox uses to decide whether new glass probes backdrop before display
    /// (see glass_box family_probe).
    backdrop_luminance_readback: bool = false,
    /// New glass first-frame probe cumulative stats (e2e: watch readback arrival, timed_out should
    /// stay 0)
    glass_probe_stats: struct { resolved: u32 = 0, timed_out: u32 = 0, max_frames: u8 = 0 } = .{},
    /// Last frame actually encoded glass backdrop owner (monolith = self surface id, GlassGroup =
    /// container surface id). Clipped / not-laid-out / hidden glass excluded -- first-frame probe
    /// starts timeout count only after glass actually painted.
    glass_encoded_owners: [64]u32 = undefined,
    glass_encoded_count: usize = 0,
    // Current UIContext bound window ID (multi-window system API routing)
    window_id: system_sdk_mod.events.WindowId = 1,
    /// Native callback identity, independent of the SDK logical routing id.
    native_window_id: u32 = 1,
    /// Font / shaping / measurement subsystem (implementation: core/text_context.zig).
    ///
    /// Originally five flat fields (measure_fn / measure_ctx_fn / measure_ctx / shaping_cache /
    /// font_system) + eight methods. Self-contained loop, but on Cx forced all text-measurement
    /// code to construct full Cx first.
    text: text_context.TextContext,

    // Retain mode
    root_scope: ?*Scope = null, // Global root Scope

    /// This Cx's World id, stamped on every Node.world_id it creates, detects cross-Cx cross-talk.
    world_id: u16 = 0,

    /// >0 = currently in before_render tick traversal (render_engine walking node tree). Any
    /// freeNode must **defer** to end, else yanks memory of currently-iterated node, see
    /// deferred_free_nodes.
    tick_depth: u32 = 0,
    /// Window destruction is deferred until all host/dispatch stacks unwind.
    /// Unlike tick_depth this does not delay node unmount or reactive effects.
    active_use_depth: usize = 0,
    close_requested: bool = false,

    /// Post-layout callback: after before_render tick's layout round, reads final geometry this
    /// frame. Callback can modify geometry and request re-layout (round capped); hit index rebuilt
    /// after all rounds.
    after_layout_hooks: std.ArrayListUnmanaged(AfterLayoutHook) = .empty,
    /// Next index in runAfterLayoutHooks traversal; removeAfterLayoutHook before this index syncs
    /// back during traversal, avoids skipping successors. null = not traversing.
    after_layout_cursor: ?usize = null,
    /// Node queued for free during tick, batched at traversal end. Path: before_render hook /
    /// animation done callback disposes component scope, scope cleanup runs detachChild + freeNode
    /// (snapshot_layer animateOpacity(done) typical), while tickBeforeRender recursion stack holds
    /// *Node + ancestors, immediate free = UAF on outer frames.
    deferred_free_nodes: @import("reactive/deferred_disposal.zig").Queue = .{},
    draining_deferred_frees: bool = false,
    /// ScrollArea on_cleanup relay cell (components/scroll_area ScrollCtxCell). Node may outlive
    /// own ScrollEventCtx and lose binding (see type comment), cell can't follow scope; Cx holds,
    /// drains at deinit.
    scroll_ctx_cells: std.ArrayList(OwnedCell) = .empty,
    current_scope: ?*Scope = null, // Current active Scope (used during mount)
    is_mounted: bool = false, // First mount completed

    /// Anonymous state id counter. Used by bindState: counts down from u64.max, avoids user's small
    /// id space (typical 1, 2, ...). Lets user skip id system when state never addressed
    /// cross-call.
    next_anon_state_id: u64 = std.math.maxInt(u64),

    // Subsystems (internal management, not exported)
    dispatcher: event_dispatcher_mod.EventDispatcher,
    /// Window-scope pointer drag arbiter (docs/DRAG_INTERACTION_DESIGN.md sect 5.3). Per-Cx
    /// session, no business payload.
    drag_manager: interaction_drag.Manager = .{},
    focus_manager: focus_mod.FocusManager,
    state_store: widget_state_mod.StateStore,
    action_dispatcher: actions_mod.ActionDispatcher = .{},
    overlay_stack: OverlayStack = .{},
    /// Current live Cx count. **No longer rejects second Cx** (guard dropped 2026-07-30, see init
    /// rationale); still needed to detect 'am I last Cx', decide when to drain process-level
    /// fallback storage, see deinit.
    var g_live_cx_count: usize = 0;

    /// Deprecated no-op: multi-Cx guard dropped, no need to allow. Kept for old test calls not to
    /// error. Don't call in new code.
    pub fn allowMultipleContextsForTest(allow: bool) void {
        _ = allow;
    }

    pub fn console(self: *Cx) *console_mod.Console {
        return &self.console_store;
    }

    pub fn windowHeaderOwns(self: *const Cx, node: ?*Node) bool {
        const header = self.window_header_node orelse return false;
        var ancestor = node;
        while (ancestor) |n| {
            if (n == header) return true;
            ancestor = n.parent;
        }
        return false;
    }
    pub const HeaderRevealLease = struct {
        cx: *Cx,
        released: bool = false,
        pub fn release(lease: *@This()) void {
            if (lease.released) return;
            lease.released = true;
            std.debug.assert(lease.cx.window_header_reveal_leases > 0);
            lease.cx.window_header_reveal_leases -= 1;
            lease.cx.needs_redraw = true;
        }
    };
    pub fn acquireWindowHeaderReveal(self: *Cx, scope: *Scope) !*HeaderRevealLease {
        if (self.window_header_node == null) return error.MissingWindowHeader;
        if (self.window_header_reveal_leases == std.math.maxInt(u32)) return error.TooManyHeaderRevealLeases;
        const lease = try scope.createState(HeaderRevealLease, .{ .cx = self });
        try scope.onCleanup(HeaderRevealLease, lease, HeaderRevealLease.release);
        self.window_header_reveal_leases += 1;
        self.needs_redraw = true;
        return lease;
    }
    pub fn init(allocator: Allocator, io: std.Io) !*Cx {
        // -- Multi-Cx / multi-window: no MultipleContextsUnsupported guard --
        //
        // Each process-level dependency that would cross-contaminate windows is removed:
        //
        // 1. **Node <-> World routing**: Node has world_ref; property read/write/dirty/parent-child
        //    go
        //    directly to the owner World (ElementId lacks a World tag, so a shared route
        //    false-matched in
        //    isValid). Builder + devtools use cx.createNode. Regression test: core/tests.zig
        //    'two coexisting Cx each render tree'.
        // 2. **Text measure**: MeasureCtxFn carries context; App.init passes its own FontSelector.
        // 3. **a11y bridge active context**: the 9 zenit_a11y_* C ABI functions take window_id
        //    first, Zig
        //    side is a window_id-keyed registry, ObjC proxy brings its own NSWindow id. Acceptance:
        //    a11y/macos_bridge.zig 'two windows route independently'.
        //
        // Remaining g_* globals (node_tree / paint_content_accessor fallback, layout_engine active
        // cache)
        // **are only read when world_ref == null**, i.e. the cx-less mock path. layout_engine's two
        // active
        // pointers are layoutNode's save/restore domain state and don't persist cross-window.
        //
        // Real windows: MultiWindowApp unified pump/render. Lifecycle + routing: test-headless.
        // Dual-window/single-window survival/exit: scripts/run_multiwindow_smoke.sh.
        // Physical input + a11y: manual matrix.

        const owner = try SignalOwner.init(allocator);
        errdefer owner.deinit();

        const lifetime_token = try allocator.create(LifetimeToken);
        errdefer allocator.destroy(lifetime_token);
        lifetime_token.* = .{ .allocator = allocator };

        const cx = try allocator.create(Cx);
        cx.* = .{
            .allocator = allocator,
            .io = io,
            .owner = owner,
            .lifetime_token = lifetime_token,
            .lowering = .{},
            .frame_arena = std.heap.ArenaAllocator.init(allocator),
            .deferred_epoch = try @import("zenit_time").Instant.now(io),
            .deferred_scheduler = DeferredScheduler.init(allocator, io),
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
            .dispatcher = event_dispatcher_mod.EventDispatcher.init(allocator, io),
            .focus_manager = focus_mod.FocusManager.init(allocator),
            .state_store = widget_state_mod.StateStore.init(allocator),
            .console_store = console_mod.Console.init(allocator, io, .{}),
            // GlyphRun pipeline cache, capacity 1024 = ShapingCache default watermark (tuning later
            // on perf data).
            .text = text_context.TextContext.init(allocator, 1024),
        };
        // These constructors allocate lazily. Rebind before their first use;
        // Cx is heap-owned, so the ledger addresses survive all table growth.
        if (@import("zenit_environment").flag("ZENIT_CPU_ALLOC_PROBE")) {
            cx.allocation_probe_enabled = true;
            for (&cx.allocation_counters) |*counter| counter.* = .{ .parent = allocator };
            cx.text = text_context.TextContext.init(cx.allocation_counters[0].allocator(), 1024);
            cx.world = world.World.init(cx.allocation_counters[1].allocator());
            cx.display_list = display_list_mod.DisplayList.init(cx.allocation_counters[2].allocator());
            cx.property_tree = property_tree_mod.PropertyTree.init(cx.allocation_counters[3].allocator());
            cx.frame_arena = std.heap.ArenaAllocator.init(cx.allocation_counters[4].allocator());
            cx.interaction_index.deinit();
            cx.interaction_index = InteractionIndex.init(cx.allocation_counters[5].allocator());
            cx.world.interaction = world.InteractionTable.init(cx.allocation_counters[5].allocator());
            cx.world.render_cache_allocator = cx.allocation_counters[6].allocator();
            cx.text_blob_store = text_blob_mod.BlobStore.init(cx.allocation_counters[7].allocator());
            cx.scene_runtime = scene_runtime_mod.SceneRuntime.init(cx.allocation_counters[8].allocator());
        }
        // Connect focus_manager + dispatcher, let focus/blur events bubble
        cx.focus_manager.dispatcher = &cx.dispatcher;
        cx.focus_manager.setRegistry(&cx.node_registry);
        cx.focus_manager.settled_context = cx;
        cx.focus_manager.on_focus_settled = &cx_platform.focusSettled;
        cx.dispatcher.setRegistry(&cx.node_registry);
        cx.action_dispatcher.setRegistry(&cx.node_registry);
        cx.action_dispatcher.active_use_depth = &cx.active_use_depth;
        cx.overlay_stack.setRegistry(&cx.node_registry);
        cx.overlay_stack.allocator = allocator;

        // Enable layout intrinsic cache (currently global static; v0.2-P3 dismantles Node, migrates
        // to LayoutTable per-node field). allocator = Cx.allocator, persists cross-frame.
        layout_engine.enableIntrinsicCache(allocator);

        // Set Node dirty notify callback, sync markRenderDirty to World.dirty_set. Currently global
        // static, later Cx shadows earlier.
        //
        // Correction (2026-07-29): old comment said 'old Cx dirty flowing into new Cx.world
        // harmless (id mismatch shields)', **wrong, disproven**. ElementId = {index:u24,
        // generation:u8}, **lacks World tag**, every World starts index 0. SlotMap.isValid only
        // checks index range + generation, so old Cx id queried in new Cx World **false-matches and
        // returns wrong data**, not 'mismatches blocked'. This is why Node must get world_id (owner
        // tag) and Cx.init currently rejects concurrent second Cx.
        cx_world_hooks.g_active_world = &cx.world;
        // Allocate unique world id for this Cx (no reuse, see cx_world_hooks.g_next_world_id
        // comment). Skip INVALID on overflow, preserve sentinel semantics.
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
        // read end also uses World.content.
        core_node.setContentTextReadCallback(&cx_world_hooks.onContentTextRead);
        core_node.setContentImageReadCallback(&cx_world_hooks.onContentImageRead);
        core_node.setContentIconReadCallback(&cx_world_hooks.onContentIconRead);
        // PaintState SoA mirror writers.
        core_node.setPaintBackgroundWriteCallback(&cx_world_hooks.onPaintBackgroundWrite);
        core_node.setPaintOpacityWriteCallback(&cx_world_hooks.onPaintOpacityWrite);
        // PaintState SoA readers (fields deleted, getter uses World).
        core_node.setPaintBackgroundReadCallback(&cx_world_hooks.onPaintBackgroundRead);
        core_node.setPaintOpacityReadCallback(&cx_world_hooks.onPaintOpacityRead);
        // NodeLayoutOutput SoA mirror (dual-write period).
        core_node.setLayoutOutputWriteCallback(&cx_world_hooks.onLayoutOutputWrite);
        core_node.setLayoutOutputReadCallback(&cx_world_hooks.onLayoutOutputRead);
        core_node.setLayoutOutputPtrCallback(&cx_world_hooks.onLayoutOutputPtr);

        // Count only after all succeed, any errdefer unwind shouldn't leave stale count.
        g_live_cx_count += 1;
        return cx;
    }

    /// Keep the context alive across a complete host call, including callback tails.
    pub fn beginActiveUse(self: *Cx) void {
        self.active_use_depth += 1;
    }

    pub fn endActiveUse(self: *Cx) void {
        std.debug.assert(self.active_use_depth > 0);
        self.active_use_depth -= 1;
    }

    pub fn hasActiveCalls(self: *const Cx) bool {
        return self.active_use_depth != 0 or self.tick_depth != 0 or
            self.focus_manager.transition_depth != 0 or self.focus_manager.callback_depth != 0 or
            self.dispatcher.dispatch_depth != 0 or
            self.owner.reactive_callback_depth != 0 or self.owner.scope_disposal_depth != 0 or
            self.owner.draining_disposals;
    }

    /// Acquire a liveness reference that remains valid after this `Cx` is
    /// destroyed. The caller must eventually call `LifetimeToken.release()`.
    pub fn retainLifetimeToken(self: *Cx) *LifetimeToken {
        return self.lifetime_token.retain();
    }

    /// Create node explicitly owned by this Cx, **independent of any process global**.
    ///
    /// P0-3: necessary multi-window entry. Node.create uses g_node_create_hook +
    /// cx_world_hooks.g_active_world globals, multi-Cx registers to 'last init'd Cx' not caller's
    /// World. This method has no ambiguity.
    pub fn createNode(self: *Cx, tag: ElementTag, style: Style) !*Node {
        return cx_world_hooks.createNode(self, tag, style);
    }

    pub fn nodeBelongsToActiveWorldForTest(node: *const Node) bool {
        return cx_world_hooks.nodeBelongsToActiveWorldForTest(node);
    }

    pub fn deinit(self: *Cx) void {
        if (self.hasActiveCalls()) @panic("Cx.deinit during an active UI call; request window close instead");
        // Invalidate external observers before any owned state starts tearing
        // down. They can now stop without ever touching this soon-to-be-freed Cx.
        const lifetime_token = self.lifetime_token;
        lifetime_token.alive = false;
        // Stop pending callbacks now, but keep timer storage valid until scope
        // cleanup has cancelled its own timers. Deinit-before-scope made the
        // ordinary onCleanup(clearTimer) path read freed ArrayList storage.
        self.timers.clearRetainingCapacity();

        // Active drag cancel first: callback ctx may be held by scope about to destroy, reversed
        // order = UAF (docs/DRAG_INTERACTION_DESIGN.md sect 11.2).
        self.drag_manager.cancel(self, .scope_disposed);

        // Tick-queued but not-freed nodes (normal frame path drains at tick end, fallback: deinit
        // may happen anytime). Must handle before root free, these nodes already detached, won't be
        // covered by root subtree recursive free.
        self.tick_depth = 0;
        cx_node_lifetime.drainDeferredFrees(self);

        // Fallback storage is process-level + page_allocator, GPA leak check blind spot (audit
        // report). Explicit free here, lets 'zero residue' assert. Only clear if no other live Cx,
        // else yanks tables still in use elsewhere.
        if (g_live_cx_count == 1) {
            core_node.deinitStandaloneRects();
            paint_content_accessor.deinitStandaloneStorage();
        }

        // Retain mode: disconnect scope pointer on node first, then destroy root_scope. Else
        // freeNode() later access node.ownership.scope.scope = UAF.
        //
        // Caveat: clearNodeScopes must run on all paths (not just when root_scope exists). Tests
        // and advanced callers often mount component tree with external Scope, self.root_scope=null
        // but cx.root subtree nodes may hold already-disposed external scope pointers. Without
        // pre-clear, freeNode -> invalidateSubtreeHookState accesses hook state registered on
        // external scope -> UAF.
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
        // Clear focused pointer before freeing tree (same as unmount; downstream app SEGV path)
        self.focus_manager.current_focus = null;
        self.focus_manager.current_focus_handle = null;
        if (self.root) |r| {
            self.freeNode(r);
            self.root = null;
        }
        self.content_root = null;
        self.popover_portal_root = null;

        // ScrollArea cells outlive both scopes and nodes: scope cleanup clears cell.ctx, node
        // teardown may still read cell. Free via component's registered destroyFn, avoid core ->
        // components reverse dependency.
        for (self.scroll_ctx_cells.items) |entry| {
            entry.destroyFn(entry.ptr, self.allocator);
        }
        self.scroll_ctx_cells.deinit(self.allocator);

        self.overlay_stack.deinit();
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
        self.bulk_quads.deinit(self.allocator); // Bulk layer (implementation extracted: core/bulk_quad_layer.zig)
        self.external_clip_rects.deinit(self.allocator);
        self.text_blob_store.deinit();
        self.layer_tree.deinit();
        a11y_macos_bridge_mod.clearActiveContextForOwner(cx_platform.a11yWindowKey(self), self);
        self.accessibility_tree.deinit();
        self.a11y_label_buf.deinit(self.allocator);
        self.gesture_arena.deinit();
        // v0.5-P3 N-2 (2026-05-03): Clear cx_world_hooks.g_active_world before world.deinit, next
        // test's Node.create hook avoids stale ptr UAF.
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
        self.sprites.deinit(self.allocator);

        // intrinsic cache free
        layout_engine.disableIntrinsicCache();

        // Cx services outlive every app scope and node (all gone above) and go before their owner.
        if (self.service_scope) |scope| {
            self.theme_signal = null;
            self.a11y_prefs_signal = null;
            if (dev_preview) self.style_signal = null;
            self.service_scope = null;
            scope.dispose();
        }
        self.timers.deinit(self.allocator);
        self.owner.deinit();
        // Last: root scope / node tree destroy calls component deinit (e.g. editor), unregister
        // callbacks.
        self.after_layout_hooks.deinit(self.allocator);
        self.after_layout_hooks = .empty;
        self.press_watchers.deinit(self.allocator);
        const allocator = self.allocator;
        allocator.destroy(self);
        lifetime_token.release();
    }

    /// Retain mode: destroy current UI tree and root_scope
    pub fn unmount(self: *Cx) void {
        self.beginActiveUse();
        defer self.endActiveUse();
        self.cancelPointerInteractions(.window_blur);
        self.cursor_override = null;
        // unmount clears focus pointer without triggering component blur; session owner atomically
        // discard + disable, avoids new tree inheriting old editor marked text.
        cx_platform.deactivateTextInputSession(self);
        // Focus UAF must clear before tree free, any focus query during recursive freeNode may
        // dereference released node (downstream app).
        self.focus_manager.current_focus = null;
        self.focus_manager.current_focus_handle = null;
        // Retire every reference while parent links and scope-owned state still
        // exist. Immediate freeNode intentionally skips callback invalidation.
        if (self.root) |r| self.invalidateReferencesToEx(r, true);
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
        self.content_root = null;
        self.popover_portal_root = null;
        self.current_scope = null;
        self.is_mounted = false;
        // Free StateStore, destroy all Welcome page component state (includes inner
        // HashMap/ArrayList)
        self.state_store.deinit();
        self.state_store = widget_state_mod.StateStore.init(self.allocator);
        // Reset OverlayStack
        self.overlay_stack.clear();
        // Reset EventDispatcher, clear dangling pointers to destroyed nodes
        self.dispatcher.clearPersistentState();
        // Reset FocusManager, clear dangling pointers to destroyed nodes
        self.focus_manager.current_focus = null;
        self.focus_manager.current_focus_handle = null;
        self.focus_manager.focus_order.clearRetainingCapacity();
        self.focus_manager.scope_count = 0;
        self.focus_manager.scope_stack = @as([64]?*Node, @splat(null));
        self.focus_manager.scope_stack_handles = @as([64]?NodeHandle, @splat(null));
        self.focus_manager.scope_memory = @as([64]?u32, @splat(null));
        self.focus_manager.scope_memory_handles = @as([64]?NodeHandle, @splat(null));
        // Reset Cx's own node state fields
        self.pressed_node = null;
        self.pressed_handle = null;
        self.notifyPressWatchers();
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

    /// Return window-level overlay portal; standalone Cx host auto-builds under root via
    /// ensurePopoverPortalRoot() if unprepared. Popover/Tooltip no inline fallback: floating
    /// content's containing block always viewport-level portal.
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
        // Don't use portal.destroy: Node.destroy doesn't reclaim ElementTable slot or clear Cx bare
        // ref, each failure leaks a slot. Portal necessarily detached at this point.
        errdefer self.destroyDetached(portal);
        portal.meta.ownership.meta.component_name = "WindowOverlayPortal";
        // ensureExt unfailable (internal catch @panic('OOM: StyleExt')), using here in
        // already-!*Node function = turns one propagable alloc failure into process abort. Consumer
        // downstream editor tried OOM injection on MdEditor.mount per-allocation: signal 6, stack
        // top = this line. Switch to fallible version, propagate.
        (try portal.style.ensureExtFallible(self.allocator)).z_index = WINDOW_PORTAL_Z_INDEX;
        try root_node.appendChild(self.allocator, portal);
        self.popover_portal_root = portal;
        self.checkPopoverPortalAncestry(portal);
        return portal;
    }

    /// Debug assertion (log.err only, no panic): portal = only mechanism to 'paint above all
    /// containers'. If portal's ancestor chain has overflow_hidden or effect surface (opacity<1 /
    /// composited_group / backdrop blur / will_change), floats get clipped/trapped in surface,
    /// z_index can't escape (scheme sect 6 step 2). Each portal checks once on first
    /// ensurePopoverPortalRoot use.
    fn checkPopoverPortalAncestry(self: *Cx, portal: *Node) void {
        if (builtin.mode != .debug) return;
        if (self.popover_portal_ancestry_checked_id == portal.id) return;
        self.popover_portal_ancestry_checked_id = portal.id;
        var current = portal.parent;
        while (current) |ancestor| : (current = ancestor.parent) {
            // Tree root = window surface: its clip = viewport, any float already clipped by
            // viewport, not 'can't escape container'. (borderless window root has rounded clip
            // overflow_hidden; mount candidate root not yet published as cx.root, also chain head.)
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

    /// Request next frame redraw (R4a). Animation hooks, external events call this to mark needs
    /// redraw.
    pub fn requestRedraw(self: *Cx) void {
        self.needs_redraw = true;
    }

    /// Replace this frame's bulk rect layer (see BulkQuad). Copies internally; caller may free
    /// quads.
    /// Pass an empty slice to disable.
    /// anchor sets the **tier + clipping**: a Node (typical: canvas/viewport container) -> drawn at
    /// that
    /// Node's content position, clipped by it, like its normal children (**its siblings -- sidebar
    /// /
    /// inspector / toolbar / overlay / modal -- normally cover it**). null -> drawn above the Node
    /// tree,
    /// unclipped (only for a real fullscreen overlay). anchor gives tier + clip only: BulkQuad x/y
    /// are
    /// always absolute viewport coords.
    /// Lifecycle: submitted data **retains across frames** until the host calls again (zenit never
    /// auto-clears); invalidated only by a new call (empty slice disables) or Cx.deinit. The host
    /// should
    /// re-call before the anchor node is destroyed/rebuilt. An anchor with no display items still
    /// renders
    /// (three-tier fallback, bulk_quad_layer.zig insertPoint). If the anchor is destroyed via
    /// detachChild /
    /// freeNode / scope dispose, invalidateReferencesToEx clears anchor **and disables the layer**:
    /// no UAF,
    /// just a missing layer until the next submit.
    /// Tier contract (bottom -> top): canvas static (Node big + batch small) -> canvas interaction
    /// overlay
    /// -> UI chrome -> overlay/modal. Batch = tier 1; use setBulkQuadsEx with overlay_z_threshold
    /// to keep
    /// canvas **internal** overlay above it.
    /// Non-empty batch skips the zero-dirty fast path (can't diff resubmitted data): repaints
    /// conservatively. (If the host can prove the content is unchanged, it should skip calling this
    /// function so the zero-dirty fast path still applies, or use setBulkQuadsVersioned.)
    pub fn setBulkQuads(self: *Cx, anchor: ?*Node, quads: []const BulkQuad) !void {
        return cx_bulk_quads.setBulkQuads(self, anchor, quads);
    }
    /// setBulkQuads + interaction overlay threshold: overlay_z_threshold declares which anchor
    /// subtree
    /// children are the **canvas interaction overlay**
    /// (select/resize-handle/size-label/hover/snap-line):
    /// z_index >= threshold = overlay; the batch is inserted **before** them so overlay still
    /// covers it.
    /// Without it (or via setBulkQuads) the whole anchor subtree is static and the batch is
    /// inserted
    /// after all subtree content, hiding the canvas overlay.
    /// setBulkQuadsEx + **content version**: the host declares the batch content version; same as
    /// last
    /// frame -> zenit assumes the batch is unchanged and the zero-dirty fast path holds. Needed
    /// because
    /// resubmitted data can't be diffed, so a batch otherwise forces conservative repaint (full
    /// paint pass
    /// per frame on 20k+ quads). Version is just monotonic-change (increment or hash); null =
    /// 'can't
    /// self-prove', degrades to conservative repaint.
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

    /// Set/clear external clip rect for Node (viewport-sys; see external_clip_rects field comment).
    /// Whole subtree clipped; intersect with node's own overflow clip. Value change requests
    /// redraw, host full-revalidate every frame common, can't fire redraw each frame.
    pub fn setNodeExternalClipRect(self: *Cx, node_id: u32, rect: ?[4]f32) void {
        return cx_bulk_quads.setNodeExternalClipRect(self, node_id, rect);
    }

    /// Register gesture recognizer on target node. Return u32 recognizer id for
    /// cx.gesture_arena.requireFailure (A must B-failed to began). Callback fires on GestureArena
    /// state transitions (possible->began/changed/ended/failed), ctx passes through. Target destroy
    /// doesn't auto-unregister, caller cleans up on scope dispose (or direct SlotMap ElementId
    /// check).
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

    /// cx.shapeText input. font_family must be FontSystem-known family string.
    pub const ShapeTextOpts = text_shaping.ShapeTextOpts;

    /// Mount system SDK (clipboard, dialogs, system events). Multi-window callers must bind window
    /// identity first, then SDK; different logical/native IDs use setWindowIdentity.
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

    /// Reserve key chords for this window (docs/RESERVED_KEY_CHORDS.md): a
    /// reserved key-down still arrives as a key event, but the platform input
    /// method never interprets it, so it produces no text (macOS: ⌥] would
    /// otherwise type ‘ in the same keystroke). Replaces the previous set;
    /// empty clears; at most 32 (more are ignored). Matching is exact on key
    /// and Shift/Control/Option/Command. An active IME composition still
    /// receives every key. Reserve only while the chord means a command (e.g.
    /// while an inline suggestion is visible), so layouts that type brackets
    /// with Option keep working otherwise. Returns false when the platform
    /// has no such hook (Windows/Linux: Alt chords make no IME text) or no
    /// system SDK is attached (tests). UI thread.
    pub fn setReservedKeyChords(self: *Cx, chords: []const events_mod.KeyChord) bool {
        return cx_platform.setReservedKeyChords(self, chords);
    }

    /// Update IME candidate anchor (window logical pixels, top-left origin)
    pub fn setImeCursorRect(self: *Cx, x: f32, y: f32, width: f32, height: f32) bool {
        return cx_platform.setImeCursorRect(self, x, y, width, height);
    }

    // -- Text capability: state + implementation in self.text (core/text_context.zig) --------
    // These aren't forwards: public text API, state just not on Cx anymore. Direct subsystem
    // access: cx.text.* (e.g. cx.text.measure_ctx_fn = ...).

    /// Callback adapter for text_core.WrapMap APIs taking erased context pointer.
    ///
    /// Warning: context must be *Cx (not *TextContext), all call sites pass cx.
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

    /// Semantics: node **about to destroy**, clear state + unregister. Used by detachChild/freeNode
    /// etc real unregister paths.
    pub fn invalidateReferencesTo(self: *Cx, subtree_root: *Node) void {
        return cx_node_lifetime.invalidateReferencesTo(self, subtree_root);
    }

    /// Sole legal destroy entry for a mount-ok but **not-yet-attached** subtree.
    /// Case: mountResult yields a floating subtree and the caller's panel.appendChild(im.node)
    /// fails.
    /// Other teardown routes abort under a full OOM sweep because the free happens **before** the
    /// invalidation/unregister scan, or clearNodeScopes runs first and skips the invalidation:
    ///   - freeNode(node): doesn't clear cx refs/unregister
    ///   - freeDetachedNodeAfterScopeDispose(n): clearNodeScopes first, binding.destroy no-ops,
    ///     scan skipped
    ///   - custom abandon (clear+free): same
    /// Invariant: **all invalidation/unregister work must complete while node memory is still
    /// live; only then free.**
    /// Fixed order here: (1) invalidateReferencesTo clears cx refs + unregisters all subtree nodes
    /// (tree
    /// intact, isDescendantOf parent-walk safe); (2) freeNode recurses unregisterFocusableSilent /
    /// clearNodeScopes / dispose binding, free last.
    /// Precondition: node is **parentless** (detached). Attached nodes use detachChild.
    /// Coverage: Cx has 7 *Node fields;
    /// focused/hovered/pressed/last_mouse_down_target/bulk_quads_anchor
    /// are cleared by invalidateReferencesToEx, root/popover_portal_root are lifecycle roots, the
    /// rest go
    /// through node_registry (handle + gen check). **Adding a Cx *Node field -> clear it in
    /// invalidateReferencesToEx.**
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
        self.beginActiveUse();
        defer self.endActiveUse();
        return cx_node_lifetime.freeNode(self, node);
    }

    /// Queue a resource freed only after a node's free into the **same deferred queue as
    /// freeNode**.
    /// Use: EditorPool frees an editor node that still borrows doc; doc can't be freed first (UAF).
    /// Routing = **identical to freeNode** (reactive depth -> owner queue; else tick ->
    /// deferred_free_nodes;
    /// else execute). Contract: **call right after the matching freeNode** so both share routing
    /// and FIFO
    /// (node first, then resource); else caller falls back (EditorPool: pending_docs). Entry
    /// storage is the resource's.
    pub fn deferDisposalLikeFreeNode(
        self: *Cx,
        entry: *@import("reactive/deferred_disposal.zig").Entry,
        ptr: *anyopaque,
        dispose_fn: *const fn (*anyopaque) void,
    ) void {
        return cx_node_lifetime.deferDisposalLikeFreeNode(self, entry, ptr, dispose_fn);
    }

    /// Register component memory released by Cx (see OwnedCell / ScrollCtxCell).
    pub fn registerScrollCtxCell(self: *Cx, cell: OwnedCell) !void {
        return cx_node_lifetime.registerScrollCtxCell(self, cell);
    }

    /// Free detached subtree where child scopes may be destroyed by ancestor scope.dispose(). These
    /// subtrees' node.ownership.scope.scope may still dangle, must clear back-refs before freeNode
    /// recursion.
    ///
    /// Key order: **invalidateSubtreeHookState before clearNodeScopes**. Invalidate breaks both
    /// directions (clears the node's hook slots and the hook state's node back-pointer).
    /// clearNodeScopes = unidirectional node->ptr only, reverse: invalidate sees
    /// node.hooks.slots==null skips, anim_state still holds dangling node*, later hook scope
    /// dispose calls destroyFn -> deref freed node -> SEGV.
    pub fn freeDetachedNodeAfterScopeDispose(self: *Cx, node: *Node) void {
        return cx_node_lifetime.freeDetachedNodeAfterScopeDispose(self, node);
    }

    /// Bind a Scope to a node and auto-null node.ownership.scope.scope on Scope dispose, blocking
    /// stale pointers. Ownership semantics (resolved by downstream editor cross-review; do not
    /// guess again): registered ScopeBinding.destroy
    /// **unbind only, never free node** (invalidateSubtreeHookState + clearNodeScopes, no
    /// freeNode). node_slot = &binding.node lets clearNodeScopes slot.*=null write here, so
    /// node-freed-first = this registration no-op.
    ///
    /// Result: **'errdefer freed node, Scope.dispose frees again' double-free not possible**, not
    /// 'pointer unbound' (insufficient; dereg matters), but because **this registration itself
    /// doesn't free**.
    pub fn bindScopeToNode(scope: *Scope, node: *Node) !void {
        return cx_node_lifetime.bindScopeToNode(scope, node);
    }

    // ---- ID generation ----

    pub fn nextId(self: *Cx) u32 {
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }

    /// Register Node to World.elements. Builders call once post-Node.create; node.element_id_raw
    /// set. Failure (OOM / table full) non-fatal, node runs old path.
    pub fn linkNodeToWorld(self: *Cx, node: *Node) void {
        return cx_world_sync.linkNodeToWorld(self, node);
    }

    // v0.5-P3 stage 1 (2026-04-30): deleted linkParentChild dead helper. Designed: builders call on
    // appendChild to maintain World.elements parent-child, never actually called, World.elements
    // just flat node list, no tree. Consumers (render_engine / layout_engine) never read
    // World.elements children, whole shadow path incomplete. Rebuild on stage 2+ main-path entry.

    pub fn layerizeFrame(self: *Cx, extra_hints: []const layerize_mod.LayerizeInput) u32 {
        return cx_world_sync.layerizeFrame(self, extra_hints);
    }

    // v0.5-P3 stage 3-1 (2026-05-01): syncLayoutToTable revived as **true shadow write**.
    // Post-layoutNode call, copy Node.rect to LayoutTable.final_rect. Lets LayoutTable = secondary
    // view, paint pass can migrate reads. Switch source-of-truth (LayoutTable -> true, delete
    // Node.rect) later.

    /// Sync Node tree rect to LayoutTable (shadow write, call once after layout).
    /// Ensure every node in the tree has a LayoutTable slot.
    ///
    /// The slot-ensuring walk is disabled because it cannot do anything:
    ///  1. `World.createElement` (world.zig) calls `layout.ensureSlot(id)` for every id it hands
    ///     out, and
    ///     it is the only way to get an ElementId (`linkNodeToWorld`, node_lifecycle.zig builder
    ///     and Cx
    ///     registration all route through it).
    ///  2. Slots are never reclaimed: `World.destroyElement` calls `layout.clear(id)` which zeroes
    ///     the
    ///     entry (`items.set(index, .{})`) and keeps array length ("layout / paint slots not
    ///     immediately
    ///     reclaimed (keep dense by index)"). A once-covered index stays covered.
    ///  3. Recycled ids reuse an existing index (generation bump), so never need a new slot.
    ///
    /// So `ensureSlot` here is always a no-op, yet each call site (8; some run unconditionally
    /// every
    /// frame) walks the entire node tree: thousands of pointer-chases for zero effect on large
    /// documents.
    ///
    /// Kept behind a flag rather than deleted: a caller that hand-builds elements outside
    /// `createElement`
    /// would break fact 1, and flipping it back is the fastest way to test that.
    pub fn syncLayoutToTable(self: *Cx, root: *Node) void {
        return cx_world_sync.syncLayoutToTable(self, root);
    }

    /// v0.5-P3 N-2 (2026-05-03 field deleted): syncNodeRect = ensureSlot helper. frame_state.rect
    /// deleted; layout pass real-time writes World via setLayoutRect, no 'sweep-sync' needed. Kept
    /// = don't break public API + ScrollArea etc ensureSlot entry (ensure layout table slot for
    /// write).
    pub fn syncNodeRect(self: *Cx, node: *Node) void {
        return cx_world_sync.syncNodeRect(self, node);
    }

    // v0.5-P3 Stage 3-3 (2026-05-02): syncPaintToTable, paint pass outlet shadow-sync.
    // Post-render_engine.renderNode: per-node element_id, compute content_hash from
    // node.style.background_color + border + text (lightweight), hit=skip; miss=begin/end chunk
    // record. Phase 1 doesn't fill display_items, just validates
    // PaintTable.beginRecord/endRecord/content_hash invalidation paths work. bounds temp use
    // node.rect->paint_table.Bounds. Phase 2+ mirror true display_items.

    /// Sync Node tree paint props to PaintTable (shadow write, post-render call).
    pub fn syncPaintToTable(self: *Cx, root: *Node) void {
        return cx_world_sync.syncPaintToTable(self, root);
    }

    /// Bring World.paint and World.interaction up to date with the last render.
    /// Call before reading either table; a no-op when nothing rendered since.
    pub fn ensureWorldTablesSynced(self: *Cx) void {
        return cx_world_sync.ensureWorldTablesSynced(self);
    }

    // mapDisplayItem + colorToRGBA + radiusArrayToCorners in cx merged to
    // gpu_draw_shadow.lowerDisplayItem (sole display_list -> paint_table map point). Callsite:
    // syncPaintToTable.

    // v0.5-P3 Stage 3-4 (2026-05-02): syncInteractionToTable, focus + events shadow-sync to
    // InteractionTable. Per-node: node.interaction.focusable / tab_index, event listener mask
    // (non-empty=coarse), a11y role.
    //
    // Note: InteractionTable sparse, put only if focusable || a11y || event handler exists.
    pub fn syncInteractionToTable(self: *Cx, root: *Node) void {
        return cx_world_sync.syncInteractionToTable(self, root);
    }

    // Accessibility Tree projection
    // --------
    // Project Node tree (behavior.interaction.a11y + focusable) into A11yNode stream to
    // cx.accessibility_tree. Upsert auto-diffs + marks dirty; end of cx.render() calls
    // a11y_router.flushToBridge next to push dirtied nodes to macOS NSAccessibility.
    //
    // Projection strategy:
    // - Node has a11y props (role != .none) -> project as that role
    // - Node focusable but no a11y props -> project as .generic container (VoiceOver still tabs to
    //   it)
    // - Node neither a11y nor focusable -> don't project (keep tree sparse, VoiceOver skips pure
    //   visual containers)
    // - label from a11y.label, fallback to first text node content in subtree (matches
    //   focus.zig a11ySnapshotForNode)
    //
    // No hierarchy pruning: a11y_tree parent = closest already-projected ancestor in element tree,
    // not necessarily element parent. So button wrapping text only projects button, text becomes
    // label.
    pub fn setA11yExpanded(self: *Cx, raw: u32, expanded: bool) bool {
        return cx_a11y.setExpanded(self, raw, expanded);
    }

    pub fn setA11yItemSelection(self: *Cx, raw: u32, operation: A11yProps.ItemSelectionOperation) bool {
        return cx_a11y.setItemSelection(self, raw, operation);
    }

    pub fn scrollA11yTextRange(self: *Cx, raw: u32, start: u32, end: u32, align_top: bool) bool {
        return cx_a11y.scrollTextRange(self, raw, start, end, align_top);
    }

    pub fn a11yTextLineBoundaries(self: *Cx, raw: u32, expected: []const u8) !?[]u32 {
        return cx_a11y.textLineBoundaries(self, raw, expected);
    }

    pub fn a11yTextGeometry(self: *Cx, raw: u32, expected: []const u8) !?[]A11yProps.TextGeometrySegment {
        return cx_a11y.textGeometry(self, raw, expected);
    }

    /// Clip rendered polygons to a logical viewport before emitting rectangles.
    pub fn a11yTextGeometryClipped(self: *Cx, raw: u32, expected: []const u8, viewport: ComputedRect) !?[]A11yProps.TextGeometrySegment {
        return cx_a11y.textGeometryClipped(self, raw, expected, viewport);
    }

    /// Preserve each affine caret line while clipping to render/viewport bounds.
    pub fn a11yTextRowGeometryClipped(self: *Cx, raw: u32, expected: []const u8, viewport: ComputedRect) !?[]A11yProps.TextRowGeometry {
        return cx_a11y.textRowGeometryClipped(self, raw, expected, viewport);
    }

    pub fn a11yTextCaretGeometryClipped(self: *Cx, raw: u32, expected: []const u8, viewport: ComputedRect) !?[]A11yProps.TextCaretSegment {
        return cx_a11y.textCaretGeometryClipped(self, raw, expected, viewport);
    }

    /// Exact transformed carets beside visible text, including off-clip edges.
    pub fn a11yTextCaretCandidates(self: *Cx, raw: u32, expected: []const u8, viewport: ComputedRect) !?[]A11yProps.TextCaretCandidate {
        return cx_a11y.textCaretCandidates(self, raw, expected, viewport);
    }

    pub fn syncA11yTreeFromInteractions(self: *Cx, root: *Node) void {
        return cx_a11y.syncA11yTreeFromInteractions(self, root);
    }

    /// Frame-end a11y step: project now, or (on-demand mode with no client
    /// yet) defer until the first assistive query.
    pub fn syncOrDeferA11yProjection(self: *Cx, root: *Node) void {
        return cx_a11y.syncOrDeferA11yProjection(self, root);
    }

    // Whole-tree health check: LayoutTable and Node.rect strictly consistent.
    // SoT inversion health check before any sync mismatch; returns false if discrepancies found.
    // Usage: call once at layout/render end in debug build; not in prod.
    pub fn assertLayoutSyncIntegrity(self: *Cx, root: *Node) bool {
        return cx_world_sync.assertLayoutSyncIntegrity(self, root);
    }

    // v0.3-P3 ElementId first-class API (ElementId and *Node coexist; new code prefers ElementId,
    // old code compatible).

    /// Fetch LayoutTable rect via ElementId (v0.3+ paint pass should use this path).
    pub fn rectOf(self: *Cx, id: world.ElementId) ?layout_table.Rect {
        return self.world.layout.rect(id);
    }

    // ---- State access ----

    /// Get or create component state.
    pub fn state(self: *Cx, comptime T: type, id: u64, initial: T) !*T {
        return self.state_store.getOrCreate(T, id, initial);
    }

    /// Create anonymous state owned by cx; returns a stable *T pointer.
    ///
    /// Recommended path for most apps:
    /// ```
    /// const counter = try cx.bindState(Counter, .{ .n = 0 });
    /// const click = cx.on(Counter, counter, Counter.increment);
    /// ```
    ///
    /// Unlike `cx.state(T, id, init)`, the caller doesn't allocate a u64 id; each call creates a
    /// new entry
    /// that can't be retrieved across mounts. Anonymous ids decrement from u64 max and are valid
    /// only
    /// within a single mount; for persistent/addressable state use `cx.state(T, id, init)` with
    /// explicit id.
    pub fn bindState(self: *Cx, comptime T: type, initial: T) !*T {
        const id = self.next_anon_state_id;
        self.next_anon_state_id -= 1;
        return self.state_store.getOrCreate(T, id, initial);
    }

    /// Type-safe handler, payload type inferred from method signature at comptime:
    /// - `fn(*State) void`    -> `Handler(void)` (i.e., `HandlerRef`), for click-like events;
    /// - `fn(*State, T) void` -> `Handler(T)`, for `on_change` / `ui.split` write callbacks.
    ///
    /// Use with `cx.bindState`.
    pub fn on(_: *Cx, comptime State: type, s: *State, comptime method: anytype) Handler(HandlerPayload(State, method)) {
        const P = HandlerPayload(State, method);
        if (P == void) return handlerFrom(State, s, method);
        return reactive.Callback(P).from(State, s, method);
    }

    fn HandlerPayload(comptime State: type, comptime method: anytype) type {
        // Accepts function itself and function pointers (callers often pass `*const fn (*S) void`
        // as argument).
        const M = @TypeOf(method);
        const maybe_info: ?std.builtin.Type.Fn = switch (@typeInfo(M)) {
            .@"fn" => |f| f,
            .pointer => |p| if (@typeInfo(p.child) == .@"fn") @typeInfo(p.child).@"fn" else null,
            else => null,
        };
        const fn_info = maybe_info orelse @compileError("cx.on: expected a method fn(*State) void or fn(*State, T) void, got " ++ @typeName(M));
        const params = @import("zenit_reflection").paramsInfo(fn_info);
        if (params.len == 0 or params[0].type != *State) {
            @compileError("cx.on: the method's first parameter must be *" ++ @typeName(State));
        }
        return switch (params.len) {
            1 => void,
            2 => params[1].type.?,
            else => @compileError("cx.on: methods take (*State) or (*State, value)"),
        };
    }

    /// Fetch existing component state.
    pub fn getState(self: *Cx, comptime T: type, id: u64) ?*T {
        return self.state_store.get(T, id);
    }

    /// Fetch existing component state, error if not found.
    pub fn requireState(self: *Cx, comptime T: type, id: u64) !*T {
        return self.getState(T, id) orelse error.StateNotFound;
    }

    // ---- Context API ----

    /// Provide context value (accessible at any depth in component tree).
    pub fn provide(self: *Cx, comptime T: type, value: *T) !void {
        const scope = try self.ensureRootScope();
        const ContextT = reactive.Context(T);
        try ContextT.provide(scope, value);
    }

    /// Consume context value.
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

    // ---- Type-safe handler ----

    /// Create type-safe event handler.
    /// Usage: try cx.handler(AppState, state_id, AppState.increment)
    pub fn handler(self: *Cx, comptime State: type, id: u64, comptime method: *const fn (*State) void) !HandlerRef {
        const s = try self.requireState(State, id);
        return handlerFrom(State, s, method);
    }

    /// Create handler from existing pointer.
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

    /// Create simple handler (direct raw pointer context).
    pub fn simpleHandler(callback: EventCallback, context: *anyopaque) HandlerRef {
        return .{
            .callback = callback,
            .context = context,
        };
    }

    // -- Value handlers (2026-07-31 callback protocol unified) --
    // Component side uses `?HandlerRef` declaration, invokes via invokeWithBool/Str;
    // Caller chooses from two constructor groups below based on value need. See HandlerRef docs.

    /// Create handler with bool value from state ptr + method.
    /// For Checkbox / Switch / Accordion 'became true/false' callbacks.
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
            // No-arg fallback: when caller can't get value, at least receives change notification.
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

    /// Create handler with string value from state ptr + method.
    /// For Input / Textarea / Tabs / Radio 'became this text/id' callbacks.
    /// Warning: slice valid only during callback, dupe if keeping.
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

    /// Create drop-only handler: callback receives full DropPayload (newline-separated paths + x/y
    /// in window coords).
    /// For drop targets positioning files (canvas drag).
    /// Warning: paths slice valid only during callback, dupe if keeping.
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

    /// State store version of `dropHandlerFrom`.
    pub fn dropHandler(
        self: *Cx,
        comptime State: type,
        id: u64,
        comptime method: *const fn (*State, core_types.HandlerRef.DropPayload) void,
    ) !HandlerRef {
        const s = try self.requireState(State, id);
        return dropHandlerFrom(State, s, method);
    }

    /// State store version of `boolHandlerFrom` (corresponds to `cx.handler`).
    pub fn boolHandler(
        self: *Cx,
        comptime State: type,
        id: u64,
        comptime method: *const fn (*State, bool) void,
    ) !HandlerRef {
        const s = try self.requireState(State, id);
        return boolHandlerFrom(State, s, method);
    }

    /// State store version of `strHandlerFrom`.
    pub fn strHandler(
        self: *Cx,
        comptime State: type,
        id: u64,
        comptime method: *const fn (*State, []const u8) void,
    ) !HandlerRef {
        const s = try self.requireState(State, id);
        return strHandlerFrom(State, s, method);
    }

    // ---- Viewport ----

    pub fn setWindowMetrics(self: *Cx, width: f32, height: f32, scale: f32) void {
        self.viewport = Size.init(width, height);
        self.window_scale = if (scale > 0) scale else 1.0;
        self.needs_redraw = true;
        if (self.root) |r| {
            r.markLayoutDirty();
        }
    }

    /// Convenience entry point: set viewport size only, scale = 1.0.
    ///
    /// Warning (HiDPI): resets `window_scale` to 1.0. Only use when scale is irrelevant (most unit
    /// tests). Real window resize must call `setWindowMetrics` with current backing scale, else
    /// Retina resize resets window_scale to 1.0, SVG rasterizes at 1x (resolveSvgRasterSize reads
    /// window_scale).
    pub fn setViewport(self: *Cx, width: f32, height: f32) void {
        self.setWindowMetrics(width, height, 1.0);
    }

    /// v0.9-E (2026-05-13): runtime theme switch.
    /// Mark full tree dirty, trigger before_render hooks to recompute colors from cx.tokens.
    /// Also markRenderDirty + markCompositeDirty on full tree. Nodes without a hook only refresh
    /// paint state; colors already written into PaintStateTable (e.g. background) are NOT updated
    /// automatically. Current fallback: the component installs its own before_render hook and
    /// writes token colors back to node.style. Accessibility preference changes sync this Cx: invalidate tree
    /// (transitions/glass read prefs at render), update Signal, request frame. Call at render
    /// start.
    pub fn syncA11yPreferences(self: *Cx) void {
        const v = a11y_preferences.version();
        if (v == self.a11y_prefs_version) return;
        self.a11y_prefs_version = v;
        if (self.a11y_prefs_signal) |sig| sig.set(a11y_preferences.current());
        if (self.root) |r| invalidateForA11yPreferences(r);
        self.needs_redraw = true;
    }

    fn invalidateForA11yPreferences(n: *Node) void {
        n.markRenderDirty();
        n.markCompositeDirty();
        for (n.children.items) |c| invalidateForA11yPreferences(c);
    }

    /// Accessibility preference Signal (created on first use; a Cx service like `themeSignal`).
    /// Components use it to switch high-contrast tokens, non-color graphic markers, etc.
    pub fn a11yPreferencesSignal(self: *Cx) !*Signal(a11y_preferences.Preferences) {
        if (self.a11y_prefs_signal) |sig| return sig;
        if (comptime dev_preview) if (@import("preview_mount.zig").current != null) return error.TemplateCandidateSideEffects;
        const sig = try (try self.serviceScope()).createSignal(a11y_preferences.Preferences, a11y_preferences.current());
        self.a11y_prefs_signal = sig;
        return sig;
    }

    /// Preview invalidation is independent of theme identity. A Cx service like `themeSignal`.
    pub fn prepareStyleGeneration(self: *Cx) !void {
        if (!dev_preview) return;
        _ = try self.styleGenerationSignal();
    }

    pub fn styleGenerationSignal(self: *Cx) !*Signal(u64) {
        if (!dev_preview) unreachable;
        if (self.style_signal) |sig| return sig;
        if (comptime dev_preview) if (@import("preview_mount.zig").current != null) return error.TemplateCandidateSideEffects;
        const sig = try (try self.serviceScope()).createSignal(u64, self.style_generation);
        self.style_signal = sig;
        return sig;
    }

    /// Reserve propagation work before publishing a preview transaction. Existing
    /// dependencies keep their capacity, and shape validation forbids new ones.
    pub fn reserveStyleNotification(self: *Cx) !void {
        if (!dev_preview) return;
        const g = &self.owner.graph;
        const n = g.nodes.items.len;
        try g.propagation_stack.ensureTotalCapacity(g.allocator, n);
        try g.pending_effects.ensureTotalCapacity(g.allocator, n);
        try g.drain_buffer.ensureTotalCapacity(g.allocator, n);
        try g.tracking_stack.ensureTotalCapacity(g.allocator, n + g.tracking_stack.items.len + 1);
    }

    /// Called once per window at the same UI safe point, before any frame renders.
    pub fn publishStyleGeneration(self: *Cx, generation: u64) void {
        if (!dev_preview) return;
        self.style_generation = generation;
        self.needs_redraw = true;
        if (self.style_signal) |sig| sig.set(generation);
    }

    pub fn setTheme(self: *Cx, t: *const theme.ThemeTokens) void {
        if (self.tokens == t) return;
        if (dev_preview) self.owner.beginReactiveCallback();
        defer if (dev_preview) self.owner.endReactiveCallback();
        self.tokens = t;
        self.theme_version +%= 1;
        const replay_version = self.theme_version;
        if (self.theme_signal) |sig| sig.set(t);
        // A signal subscriber may synchronously choose another theme. Its complete
        // replay wins; never start an older replay after returning from it.
        if (dev_preview and self.theme_version != replay_version) return;
        self.replayThemeRoots(t);
        self.needs_redraw = true;
    }

    fn replayThemeRoots(self: *Cx, t: *const theme.Values) void {
        const replay_version = self.theme_version;
        const refs = @import("overlay_layer_refs.zig");
        // A layer may share the app tree or another layer's ancestor. Replay
        // each tree once, including retained/suspended and rootless portals.
        const capacity = 2 + 2 * OverlayStack.MAX_LAYERS;
        var roots: [capacity]*Node = undefined;
        var handles: [capacity]?NodeHandle = undefined;
        var count: usize = 0;
        var candidates: [capacity]?*Node = undefined;
        candidates[0] = self.root;
        candidates[1] = self.popover_portal_root;
        var n: usize = 2;
        for (self.overlay_stack.layers.items) |maybe| if (maybe) |layer| {
            candidates[n] = layer.content_node;
            candidates[n + 1] = layer.barrier_node;
            n += 2;
        };
        for (candidates[0..n]) |candidate| {
            var root = candidate orelse continue;
            while (root.parent) |parent| root = parent;
            var seen = false;
            for (roots[0..count]) |existing| if (existing == root) {
                seen = true;
                break;
            };
            if (seen) continue;
            roots[count] = root;
            handles[count] = refs.trackNode(&self.node_registry, root);
            count += 1;
        }
        // Hooks in an earlier tree can close a later overlay. Validate its
        // generation before dereferencing the captured pointer.
        for (roots[0..count], handles[0..count]) |root, handle| {
            if (dev_preview and self.theme_version != replay_version) return;
            if (refs.resolveTrackedNode(&self.node_registry, handle, root)) |live|
                if (dev_preview) self.invokePreviewThemeHooks(live, t, replay_version) else invokeThemeHookRecursive(live, t, self.allocator);
        }
    }

    /// The theme Signal (created on first use): every Effect / Memo that reads it re-runs on
    /// `setTheme`. It is a Cx service: owned by the Cx (`serviceScope`), so it lives exactly as
    /// long as the Cx, no matter which window, panel or component asked for it first. A window
    /// that replaces another on the same Cx keeps reading the same live Signal.
    pub fn themeSignal(self: *Cx) !*Signal(*const theme.ThemeTokens) {
        if (self.theme_signal) |sig| return sig;
        if (comptime dev_preview) if (@import("preview_mount.zig").current != null) return error.TemplateCandidateSideEffects;
        const sig = try (try self.serviceScope()).createSignal(*const theme.ThemeTokens, self.tokens);
        self.theme_signal = sig;
        return sig;
    }

    /// Scope owning the Cx-wide reactive services (theme, accessibility preferences, preview
    /// style generation). Created on first use, disposed by `deinit` after every app scope and
    /// node is gone and before the signal owner. App scopes never own these signals: a holder
    /// in one scope must not lose them when an unrelated scope (the first caller's window or
    /// panel) is disposed.
    fn serviceScope(self: *Cx) !*Scope {
        if (self.service_scope) |scope| return scope;
        const scope = try Scope.init(self.allocator, null, self.owner);
        self.service_scope = scope;
        return scope;
    }

    /// Callbacks can unmount their tree. Deferred disposal keeps memory alive;
    /// pending destruction stops further callbacks, and child lists are reread.
    fn invokePreviewThemeHooks(self: *Cx, n: *Node, t: *const theme.ThemeTokens, replay_version: u64) void {
        if (self.theme_version != replay_version or n.freeing or n.pending_free_cx != null) return;
        if (n.meta.per_frame.hooks.before_render.main) |hook| hook(n);
        if (self.theme_version != replay_version or n.freeing or n.pending_free_cx != null) return;
        var h: usize = 0;
        while (h < n.meta.per_frame.hooks.before_render.count) : (h += 1) {
            if (n.meta.per_frame.hooks.before_render.hooks[h]) |hook| hook(n);
            if (self.theme_version != replay_version or n.freeing or n.pending_free_cx != null) return;
        }
        n.replayThemeDeclaration(t, self.allocator);
        if (self.theme_version != replay_version or n.freeing or n.pending_free_cx != null) return;
        var replay = n.meta.per_frame.hooks.view_theme;
        while (replay) |r| {
            const next = r.next;
            r.run(r, t);
            if (self.theme_version != replay_version or n.freeing or n.pending_free_cx != null) return;
            replay = next;
        }
        n.markRenderDirty();
        n.markCompositeDirty();
        var i: usize = 0;
        while (i < n.children.items.len) {
            const child = n.children.items[i];
            self.invokePreviewThemeHooks(child, t, replay_version);
            if (self.theme_version != replay_version or n.freeing or n.pending_free_cx != null) return;
            if (i < n.children.items.len and n.children.items[i] == child) i += 1;
        }
    }

    fn invokeThemeHookRecursive(n: *Node, t: *const theme.ThemeTokens, allocator: std.mem.Allocator) void {
        if (n.meta.per_frame.hooks.before_render.main) |hook| {
            hook(n);
        }
        for (n.meta.per_frame.hooks.before_render.hooks[0..n.meta.per_frame.hooks.before_render.count]) |maybe| {
            if (maybe) |hook| hook(n);
        }
        // setTheme-only theme replay (boxStyled/textStyled named style functions).
        // Inline writes stay above the declaration (setTheme-only replay of named style fns).
        n.replayThemeDeclaration(t, allocator);
        var replay = n.meta.per_frame.hooks.view_theme;
        while (replay) |r| {
            replay = r.next;
            r.run(r, t);
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

    // ---- Focus management ----

    pub fn setFocus(self: *Cx, node: ?*Node) void {
        self.beginActiveUse();
        defer self.endActiveUse();
        self.focus_manager.setFocus(node);
    }

    pub fn clearFocus(self: *Cx) void {
        self.beginActiveUse();
        defer self.endActiveUse();
        self.focus_manager.clearFocus();
    }

    pub fn isFocused(self: *Cx, node: *Node) bool {
        return self.focus_manager.isFocused(node);
    }

    // ---- Event handling ----
    //
    // All host entry points (pointer/keyboard/IME/scroll/drag/command, timers, deferred tasks) bind
    // this Cx's animation clock (bindEventClock; global var in multiwindow), then run in owner
    // batch: handlers write multiple signals, effects depending on them drain once before entry
    // returns (see complete state post-write). before_render / after_layout hook batching in
    // cx_render.

    pub fn handleMouseDown(self: *Cx, x: f32, y: f32, modifiers: Modifiers) void {
        self.input_epoch +%= 1;
        const host = self.enterHost();
        defer self.exitHost(host);
        return cx_input.handleMouseDown(self, x, y, modifiers);
    }

    pub fn handleMouseDownEx(self: *Cx, x: f32, y: f32, button: MouseButton, modifiers: Modifiers) void {
        self.input_epoch +%= 1;
        const host = self.enterHost();
        defer self.exitHost(host);
        return cx_input.handleMouseDownEx(self, x, y, button, modifiers);
    }

    /// Compatibility entry point: mouse up without modifiers. Equivalent to `handleMouseUpEx(x, y,
    /// .left, .{})`. Host wanting mouse_up with **actual modifiers at release** uses
    /// `handleMouseUpEx`.
    pub fn handleMouseUp(self: *Cx, x: f32, y: f32) void {
        self.input_epoch +%= 1;
        const host = self.enterHost();
        defer self.exitHost(host);
        return cx_input.handleMouseUp(self, x, y);
    }

    pub fn handleMouseUpEx(self: *Cx, x: f32, y: f32, button: MouseButton, modifiers: Modifiers) void {
        self.input_epoch +%= 1;
        const host = self.enterHost();
        defer self.exitHost(host);
        return cx_input.handleMouseUpEx(self, x, y, button, modifiers);
    }

    /// Resync hover/cursor after pointer capture release. Extracted from handleMouseUpEx
    /// auto-release path; drag cancel (Escape/blur/detach) also explicitly releases capture, needs
    /// resync or cursor/hover stick to old node until next move (docs/DRAG_INTERACTION_DESIGN.md
    /// §8.4/§11.2).
    pub fn resyncPointerAfterCaptureRelease(self: *Cx, x: f32, y: f32, fallback_handle: ?NodeHandle) void {
        const host = self.enterHost();
        defer self.exitHost(host);
        return cx_input.resyncPointerAfterCaptureRelease(self, x, y, fallback_handle);
    }

    /// Compatibility entry point: mouse move without modifiers. Equivalent to `handleMouseMoveEx(x,
    /// y, .{})`.
    pub fn handleMouseMove(self: *Cx, x: f32, y: f32) void {
        self.input_epoch +%= 1;
        const host = self.enterHost();
        defer self.exitHost(host);
        return cx_input.handleMouseMove(self, x, y);
    }

    pub fn handleMouseMoveEx(self: *Cx, x: f32, y: f32, modifiers: Modifiers) void {
        self.input_epoch +%= 1;
        const host = self.enterHost();
        defer self.exitHost(host);
        return cx_input.handleMouseMoveEx(self, x, y, modifiers);
    }

    /// The platform reports the pointer is no longer over this window's visible content (macOS
    /// content tracking-area exit, including another window covering it; Windows WM_MOUSELEAVE;
    /// Wayland wl_pointer.leave). Clears hover and stops stationary re-resolution until the next
    /// pointer event; the last position no longer describes the pointer.
    pub fn handlePointerLeave(self: *Cx) void {
        self.input_epoch +%= 1;
        const host = self.enterHost();
        defer self.exitHost(host);
        return cx_hover.handlePointerLeave(self);
    }

    /// The last pointer position describes where the pointer is now: reported by the platform, no
    /// leave since, no OS drag session, inside the content. Components that hit-test
    /// `mouse_x`/`mouse_y` themselves (outside the hover dispatch) must gate on this, or they keep
    /// acting on a pointer that left the window or is under another window.
    pub fn pointerLive(self: *const Cx) bool {
        return cx_hover.pointerLive(self);
    }

    /// Re-resolve hover under a stationary pointer when the committed hit scene changed since
    /// hover was last resolved (scroll, layout, mount/unmount). Called by render at the start of
    /// each frame; no hit test when nothing changed. See core/cx_hover.zig.
    pub fn reconcileStationaryHover(self: *Cx) void {
        if (!cx_hover.pending(self)) return;
        const host = self.enterHost();
        defer self.exitHost(host);
        return cx_hover.reconcile(self);
    }

    /// Unified cancel of in-progress pointer interactions (drag session + gesture recognizers).
    /// Window blur/root replace lifecycle events called by host/runtime. Pending silently cleared;
    /// active fires cancel callback exactly once; idempotent.
    pub fn cancelPointerInteractions(self: *Cx, reason: interaction_drag.CancelReason) void {
        const host = self.enterHost();
        defer self.exitHost(host);
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

    /// Activate custom bitmap cursor: SVG rasterized at size_pt*scale width (aspect from SVG) to
    /// premultiplied RGBA, content-addressed cache, immediate dispatch attempt. Nodes/override
    /// write `CursorShape.custom` to resolve to active bitmap; updateCursorShape called
    /// immediately, so the cursor change takes effect even while the pointer is at rest (same
    /// immediate-update semantics as setCursorOverride; assigning style.cursor itself has no side
    /// effects). Only one bitmap is active at a time; calling again switches the content.
    /// Idempotent: same key -> early return.
    pub fn setCustomCursor(self: *Cx, desc: CustomCursorDesc) void {
        return cx_input.setCustomCursor(self, desc);
    }

    /// Active custom cursor key (e2e probe/debug). Null if not active.
    pub fn activeCustomCursorKey(self: *const Cx) ?u64 {
        return cx_input.activeCustomCursorKey(self);
    }

    /// Update automated virtual pointer. `pressed=null` keeps current button state for move/scroll.
    /// No event dispatch; only resolves current position's cursor, marks redraw.
    pub fn updateAutomationCursor(self: *Cx, x: f32, y: f32, pressed: ?bool) void {
        return cx_input.updateAutomationCursor(self, x, y, pressed);
    }

    /// Synthesize down+up. No outer batch: each fires its own batch, matching two independent
    /// platform events' effect ordering.
    pub fn handleClick(self: *Cx, x: f32, y: f32) void {
        self.beginActiveUse();
        defer self.endActiveUse();
        return cx_input.handleClick(self, x, y);
    }

    pub fn bindCommandAction(self: *Cx, command_id: u64, action: actions_mod.Action) void {
        return cx_input.bindCommandAction(self, command_id, action);
    }

    /// Native menus and keyboard bindings converge on ActionDispatcher.
    pub fn handleCommand(self: *Cx, command_id: u64) void {
        self.input_epoch +%= 1;
        const host = self.enterHost();
        defer self.exitHost(host);
        return cx_input.handleCommand(self, command_id);
    }

    pub fn handleKeyDown(self: *Cx, key: KeyCode, modifiers: Modifiers) void {
        self.input_epoch +%= 1;
        const host = self.enterHost();
        defer self.exitHost(host);
        return cx_input.handleKeyDown(self, key, modifiers);
    }

    pub fn handleKeyUp(self: *Cx, key: KeyCode, modifiers: Modifiers) void {
        self.input_epoch +%= 1;
        const host = self.enterHost();
        defer self.exitHost(host);
        return cx_input.handleKeyUp(self, key, modifiers);
    }

    pub fn handleTextInput(self: *Cx, t: []const u8) void {
        self.input_epoch +%= 1;
        const host = self.enterHost();
        defer self.exitHost(host);
        return cx_input.handleTextInput(self, t);
    }

    pub fn handleImePreeditEvent(self: *Cx, event: @import("events.zig").ImePreeditEvent) void {
        self.input_epoch +%= 1;
        const host = self.enterHost();
        defer self.exitHost(host);
        return cx_input.handleImePreeditEvent(self, event);
    }
    pub fn handleImeDeleteSurrounding(self: *Cx, before: u32, after: u32) void {
        self.input_epoch +%= 1;
        const host = self.enterHost();
        defer self.exitHost(host);
        return cx_input.handleImeDeleteSurrounding(self, before, after);
    }
    pub fn handleImePreedit(self: *Cx, preedit_text: []const u8, cursor_utf8_offset: u32) void {
        self.input_epoch +%= 1;
        const host = self.enterHost();
        defer self.exitHost(host);
        return cx_input.handleImePreedit(self, preedit_text, cursor_utf8_offset);
    }

    /// IME preedit entry with replacementRange (UTF-8 byte range, document-relative; sentinel = no
    /// replacement). Henkan pulls committed text back to composition state via this path.
    pub fn handleImePreeditReplace(
        self: *Cx,
        preedit_text: []const u8,
        cursor_utf8_offset: u32,
        replace_start_utf8: u32,
        replace_end_utf8: u32,
    ) void {
        self.input_epoch +%= 1;
        const host = self.enterHost();
        defer self.exitHost(host);
        return cx_input.handleImePreeditReplace(self, preedit_text, cursor_utf8_offset, replace_start_utf8, replace_end_utf8);
    }

    pub fn handleImeCommit(self: *Cx, commit_text: []const u8) void {
        self.input_epoch +%= 1;
        const host = self.enterHost();
        defer self.exitHost(host);
        return cx_input.handleImeCommit(self, commit_text);
    }

    /// IME commit entry with replacementRange; sentinel equivalent to handleImeCommit.
    pub fn handleImeCommitReplace(
        self: *Cx,
        commit_text: []const u8,
        replace_start_utf8: u32,
        replace_end_utf8: u32,
    ) void {
        self.input_epoch +%= 1;
        const host = self.enterHost();
        defer self.exitHost(host);
        return cx_input.handleImeCommitReplace(self, commit_text, replace_start_utf8, replace_end_utf8);
    }

    pub fn handleScroll(self: *Cx, scroll: events_mod.ScrollEvent) void {
        self.input_epoch +%= 1;
        const host = self.enterHost();
        defer self.exitHost(host);
        return cx_input.handleScroll(self, scroll);
    }

    /// SystemSdk native scroll event -> handleScroll (retains gesture phase, modifiers).
    pub fn handleSdkWheel(self: *Cx, wheel: system_sdk_mod.events.MouseWheel) void {
        self.input_epoch +%= 1;
        const host = self.enterHost();
        defer self.exitHost(host);
        return cx_input.handleScroll(self, cx_input.scrollEventFromSdk(wheel));
    }

    /// Pinch gesture: dispatch by pointer hit to target node (bubbles). Target locked at began,
    /// avoiding content move -> target change.
    pub fn handleMagnify(self: *Cx, magnification: f32, x: f32, y: f32, phase: events_mod.GesturePhase) void {
        self.input_epoch +%= 1;
        const host = self.enterHost();
        defer self.exitHost(host);
        return cx_input.handleMagnify(self, magnification, x, y, phase);
    }

    /// Drop event: dispatch by pointer hit (works with hitTest for highlighting drop targets).
    /// Handles one platform drop.
    ///
    /// Platform only sends entered/exited at **window** boundary; node-level enter/leave
    /// synthesized from position flow (like mouse_enter/leave): each event re-hits, compares last
    /// drop target, bridges gap with exited/entered. Otherwise dragging over multiple drop targets
    /// in window only first receives entered.
    pub fn handleDrag(self: *Cx, x: f32, y: f32, kind: u8, paths: []const u8) void {
        self.input_epoch +%= 1;
        const host = self.enterHost();
        defer self.exitHost(host);
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
        self.input_epoch +%= 1;
        const host = self.enterHost();
        defer self.exitHost(host);
        return cx_input.handlePlatformDrag(self, x, y, kind, paths, payload_kind, payload_truncated, payload_is_untrusted);
    }

    // ---- Hit testing ----

    pub fn hitTestQuery(self: *Cx, query: HitQuery) ?HitResult {
        // The scene is being mutated. Reentering hooks can recurse forever,
        // and the previous index may still contain retiring nodes. The outer
        // refresh publishes the next usable scene when it finishes.
        if (self.tick_depth > 0 or self.draining_deferred_frees) return null;
        cx_render.ensureHitTestSceneFresh(self);
        self.input_perf.in_hit_queries += 1;
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

    /// Publish on the application frame boundary, outside any native callback.
    pub fn publishWindowRegions(self: *Cx) void {
        if (self.window_chrome_signal) |signal| {
            if (signal.peek().effective_mode != .native) cx_render.ensureHitTestSceneFresh(self);
        }
    }
    pub fn legacyWindowControlAt(self: *Cx, x: f32, y: f32) bool {
        if (self.tick_depth > 0 or self.draining_deferred_frees) return true;
        inline for (.{ HitQueryKind.pointer, HitQueryKind.scroll }) |kind| {
            if (self.interaction_index.hitTestQuery(.{ .kind = kind, .world_x = x, .world_y = y }, &self.node_registry, null) != null) return true;
        }
        return false;
    }

    /// State belongs to this Cx, subscriptions belong to the consumer Scope.
    pub fn windowChrome(self: *Cx) !*Signal(system_sdk_mod.window_chrome.State) {
        if (self.window_chrome_signal) |signal| return signal;
        const signal = try Signal(system_sdk_mod.window_chrome.State).create(self.owner, .{});
        self.window_chrome_signal = signal;
        return signal;
    }

    pub fn performWindowAction(self: *Cx, action: system_sdk_mod.window_chrome.Action) !void {
        const service = self.window_service orelse return error.WindowServiceUnavailable;
        try service.perform(service.context, action);
    }

    /// Native event-pump entry: no layout, allocation, effects or UI mutation.
    /// Uses the last published transformed/clipped/ordered hit scene. During a
    /// tree mutation it fails closed; stale handles are checked by the registry.
    pub fn windowRegionAt(self: *Cx, x: f32, y: f32) system_sdk_mod.window_chrome.Region {
        if (self.tick_depth > 0 or self.draining_deferred_frees) return .client;
        const hit = self.interaction_index.hitTestQuery(.{ .kind = .window_chrome, .world_x = x, .world_y = y }, &self.node_registry, null) orelse return .client;
        var current = self.node_registry.resolve(hit.handle, null);
        while (current) |node| : (current = node.parent) {
            const region = node.behavior.interaction.window_region;
            if (region != .inherit) return region;
            const roles = @import("core/interaction_semantics.zig").nodeHitRoles(node);
            if (roles.pointer or roles.scroll or node.behavior.interaction.text_input_client != null) return .client;
        }
        return .client;
    }

    pub fn hitTestInspect(self: *Cx, x: f32, y: f32) ?*Node {
        const hit = self.hitTestQuery(.{
            .kind = .inspect,
            .world_x = x,
            .world_y = y,
        }) orelse return null;
        return resolveInspectTarget(self.node_registry.resolve(hit.handle, &self.perf));
    }

    // ---- Layout ----

    /// Advance the monotonic frame clock one tick. **Call once per visible frame** (App.frame
    /// before
    /// layout/render); drives absolute-time animations (overlay enter/exit transition, Spring,
    /// etc.).
    /// Don't call in layout(): it may re-enter several times per visible frame (hit-test
    /// freshness),
    /// which would skip opened frames on overlays (see ensureBeforeRenderTickedForHitTest).
    /// Without it, TransitionController deltas stay 0 and overlays freeze half-transparent.
    pub fn advanceFrameClock(self: *Cx) void {
        return cx_frame.advanceFrameClock(self);
    }
    /// Fixed-step/manual animation time is the sole clock while a harness
    /// controls it. A screenshot's real display tick must not advance poses.
    pub fn setFramePresentationSample(self: *Cx, sample: ?PresentationSample) void {
        self.frame_presentation_sample = if (self.test_frame_step_ms != null) null else sample;
    }

    pub fn setTestFrameStep(self: *Cx, step: ?f32) !void {
        if (step) |ms| if (!std.math.isFinite(ms) or ms < 1 or ms > 100) return error.InvalidFrameStep;
        self.test_frame_step_ms = step;
        self.frame_presentation_sample = null;
        if (step == null) self.test_clock_budget_ms = null;
        self.clock_time_offset_ms = self.frame_time_ms;
        self.clock_epoch = null;
        self.last_frame_instant = null;
        self.clock_paused_ns = 0;
    }

    /// Event-time frame clock (ms): consistent with next active frame advanceFrameClock value (wall
    /// time - epoch - cumulative idle pause). When frame clock never advanced (epoch null, test
    /// hand-sets frame_time_ms), use frame_time_ms for determinism.
    pub fn eventTimeMs(self: *const Cx) f64 {
        // Fixed-step clock (e2e /clock): frame clock only advances on frame submit. Event time
        // still wall-clock: on slow renderer, animation started by click has start in future,
        // stalls mid-animation, won't request frame.
        if (self.test_frame_step_ms != null) return self.frame_time_ms;
        const epoch = self.clock_epoch orelse return self.frame_time_ms;
        const now = @import("zenit_time").Instant.now(self.io) catch return self.frame_time_ms;
        const live_ns = now.since(epoch) -| self.clock_paused_ns;
        return @max(@as(f64, @floatFromInt(live_ns)) / std.time.ns_per_ms, self.frame_time_ms);
    }

    /// After pressed_node changes: observer signal becomes 'is pressed target in my subtree' (write
    /// only on value change). Doesn't dereference observer node (isDescendantOf walks pressed
    /// target's parent chain), safe even if observer node releasing. Whole loop in owner batch:
    /// signal write triggers effects deferred post-loop, effect adding/removing observers
    /// (modifying press_watchers) won't invalidate in-flight slice.
    pub fn notifyPressWatchers(self: *Cx) void {
        self.owner.beginBatch();
        defer self.owner.endBatch();
        for (self.press_watchers.items) |w| {
            const inside = if (self.pressed_node) |p| p.isDescendantOf(w.node) else false;
            if (w.signal.peek() != inside) w.signal.set(inside);
        }
    }

    /// Bind process-global animation clock (render_engine.current_frame_*) to this Cx's event time.
    ///
    /// Clock global; multiwindow (MultiWindowApp, e.g., storybook + DevTools) has each Cx its own
    /// frame clock. Frame-outside code (event handlers, timers, deferred tasks, drained effects,
    /// mount) without binding reads **last-frame window's** clock, starting transitions/animations
    /// at wrong time in this window—future start = never completes (window never idle), past start
    /// = first frame jumps to end. All host entries call it; no caller tracking needed.
    pub fn bindEventClock(self: *const Cx) void {
        render_engine.setFrameClock(.{
            .io = self.io,
            .time_ms = self.eventTimeMs(),
            .dt_ms = self.frame_dt_ms,
            .dt_seconds = self.frame_dt_seconds,
        });
    }

    /// Host entry common prefix: bind this Cx's clock, start owner batch (paired `exitHost`).
    /// Returns pre-entry global clock: entry may nest in another window's entry (window A handler
    /// calls window B entry), exit must restore to outer, else A's remainder and A's drain read B's
    /// clock.
    ///
    /// Intentionally **don't** raise tick_depth like cx_render hook traversal: unmount in events
    /// takes immediate effect (hit, focus, a11y see unmounted tree). Tradeoff: node may
    /// sync-release during dispatch: handler directly freeNode or nested exitHost from B (in A
    /// handler stack) drains, B effect releases A node. Invariant: on host entry path, **after
    /// dispatch returns, don't reuse pre-dispatch bare *Node**; resolve via node_registry /
    /// dispatcher handle (dispatch bubbling chain, hover epoch, click synthesis, drag relays all
    /// obey this). Regression in core/host_entry_lifetime_tests.zig.
    fn enterHost(self: *Cx) render_engine.SavedFrameClock {
        self.beginActiveUse();
        const outer = render_engine.saveFrameClock();
        self.bindEventClock();
        self.owner.beginBatch();
        return outer;
    }

    /// Drain this batch's effects in this window's clock, restore outer clock.
    fn exitHost(self: *Cx, outer: render_engine.SavedFrameClock) void {
        defer self.endActiveUse();
        self.owner.endBatch();
        render_engine.restoreFrameClock(outer);
    }

    /// Select this context's animation clock before host-driven UI updates.
    /// Does not advance time, consume redraw requests, or render. Multi-window
    /// hosts must bind the destination context before input/controller callbacks.
    pub fn bindFrameClock(self: *const Cx) void {
        render_engine.setFrameClock(.{
            .io = self.io,
            .time_ms = self.frame_time_ms,
            .dt_ms = self.frame_dt_ms,
            .dt_seconds = self.frame_dt_seconds,
            .reduced_motion = self.reduced_motion or self.renderer_reduced_motion,
        });
    }

    pub fn layout(self: *Cx) void {
        self.beginActiveUse();
        defer self.endActiveUse();
        return cx_frame.layout(self);
    }

    // ---- Rendering ----

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

    /// Time until the earliest `setTimer` callback is due (0 = overdue); null with none pending.
    pub fn nextTimerDelayNs(self: *const Cx) ?u64 {
        return cx_frame.nextTimerDelayNs(self);
    }

    /// Idle frame-gate unified criterion: does this wake need to render one frame.
    /// First consumes expired scheduleRedrawAfterNs deadline (sets needs_redraw).
    /// needs_redraw edge consumption at advanceFrameClock (after clock read); caller **must not**
    /// clear early (freezes this wake's frame clock).
    /// Aggregate read-only 'latest self-wake deadline' ns: scheduleRedrawAfterNs deadline (cursor
    /// blink, etc.) + deferred scheduler soonest non-expired task. null = no timed wake (pure
    /// event-driven). Doesn't consume state; main loop uses for display-link pump timeout ceiling;
    /// deadline expiry still consumed via wantsFrame->processScheduledRedraw.
    // ---- Timers ----

    pub const Timer = struct {
        id: u64,
        due_ns: u64,
        callback: *const fn (?*anyopaque) void,
        context: ?*anyopaque,
    };

    /// One-shot timer: callback at render start after delay_ns (before zero-dirty fast path;
    /// markRenderDirty in callback applies this frame). Wakes frame loop even idle (nextWakeDelayNs
    /// / wantsFrame). Caller manages context lifetime: clearTimer before release. Returned id never
    /// zero.
    pub fn setTimer(self: *Cx, delay_ns: u64, callback: *const fn (?*anyopaque) void, context: ?*anyopaque) !u64 {
        return cx_frame.setTimer(self, delay_ns, callback, context);
    }

    pub fn clearTimer(self: *Cx, id: u64) void {
        return cx_frame.clearTimer(self, id);
    }

    /// Fire due timers. 'This round' = batch that was due when entering outermost fireDueTimers
    /// (single-round limit 16, rest deferred). Callbacks can re-set/clear: new set (including 0
    /// delay) deferred to next round; prior callback clears not re-fired; nested call to self is
    /// no-op, remainder fires outer order, timer fires once max.
    pub fn fireDueTimers(self: *Cx) void {
        const host = self.enterHost();
        defer self.exitHost(host);
        return cx_frame.fireDueTimers(self);
    }

    pub fn nextWakeDelayNs(self: *const Cx) ?u64 {
        return cx_frame.nextWakeDelayNs(self);
    }

    pub fn wantsFrame(self: *Cx) bool {
        return cx_frame.wantsFrame(self);
    }

    /// Tree already marked dirty by input/animation hooks, but event path didn't flip needs_redraw
    /// explicitly; idle loop still must run one frame consuming layout/render/index rebuild.
    pub fn hasPendingSceneWork(self: *const Cx) bool {
        return cx_frame.hasPendingSceneWork(self);
    }

    pub fn deferredBudgetUs(self: *const Cx) u32 {
        return cx_frame.deferredBudgetUs(self);
    }

    pub fn drainDeferredWork(self: *Cx, budget_us: u32) DrainDeferredResult {
        const host = self.enterHost();
        defer self.exitHost(host);
        return cx_frame.drainDeferredWork(self, budget_us);
    }

    /// Paint entry point: fill display_list (paint-local coords), return slice. Internal end calls
    /// derive (appendAllDisplayItemsToRenderList) lowering to self.lowering.main + inspector
    /// overlay; encoder fetches via lowerForEncoder() lowered DisplayItem slice.
    pub fn render(self: *Cx) []const display_list_mod.DisplayItem {
        self.beginActiveUse();
        defer self.endActiveUse();
        return cx_render.render(self);
    }

    /// Encoder consumes paint_table.DisplayItem. Lowering phase already double-writes to
    /// self.lowering.main_paint; this fn only returns slice, no re-translate (saves per-frame
    /// frame_arena alloc + 17 lowerDisplayItem calls).
    ///
    /// Lifetime: main_paint clears per-frame; inline payload ptr points frame_arena spill copy
    /// (appendLoweredBoth writes), stable per-frame.
    pub fn lowerForEncoderPaintTable(self: *Cx) []const paint_table.DisplayItem {
        return cx_render.lowerForEncoderPaintTable(self);
    }

    /// Advances whenever a hit layer moves (a scroll offset change); see
    /// node_dirty.g_hit_layer_motion_gen.
    pub fn layerMotionGen(self: *const Cx) u64 {
        _ = self;
        return @import("core/node_dirty.zig").g_hit_layer_motion_gen;
    }

    pub fn scheduleRedrawAfterNs(self: *Cx, delay_ns: u64) void {
        return cx_render.scheduleRedrawAfterNs(self, delay_ns);
    }

    /// Declare during before-render. Does not request an ordinary scene redraw.
    pub fn setBlinkCaretPhase(self: *Cx, visible: bool, remaining_ns: u64, half_ns: u64) void {
        if (!self.window_active) {
            self.caret_phase_valid = false;
            return;
        }
        if (half_ns == 0) return;
        self.caret_phase_valid = true;
        self.caret_visible = visible;
        self.caret_half_ns = half_ns;
        self.caret_next_ns = @import("zenit_time").monotonicTimestamp(self.io) + @as(i128, @intCast(remaining_ns));
    }

    pub fn blinkCaretVisible(self: *const Cx, normal: bool) bool {
        if (!self.window_active) return false;
        return self.caret_paint_override orelse normal;
    }

    /// Scene-space visible portion, declared even when paint is hidden.
    pub fn addBlinkCaretRect(self: *Cx, rect: [4]f32) void {
        if (!self.window_active) return;
        for (rect) |v| if (!std.math.isFinite(v)) return;
        if (rect[2] <= 0 or rect[3] <= 0) return;
        if (self.caret_rect_count == self.caret_rects.len) {
            self.caret_rect_overflow = true;
            return;
        }
        self.caret_rects[self.caret_rect_count] = rect;
        self.caret_rect_count += 1;
    }

    pub fn processScheduledRedraw(self: *Cx) bool {
        return cx_render.processScheduledRedraw(self);
    }

    /// Register post-layout callback (same ctx, single entry only).
    pub fn addAfterLayoutHook(self: *Cx, ctx: *anyopaque, run: AfterLayoutFn) !void {
        return cx_render.addAfterLayoutHook(self, ctx, run);
    }

    pub fn removeAfterLayoutHook(self: *Cx, ctx: *anyopaque) void {
        return cx_render.removeAfterLayoutHook(self, ctx);
    }

    /// Test-only: expose rebuildRuntimeIndexes fallibility to lock 'OOM returns error (so caller
    /// @panic is not dead code)' premise. Not public API.
    pub fn rebuildRuntimeIndexesForTest(self: *Cx) !void {
        return cx_runtime_index.rebuildRuntimeIndexesForTest(self);
    }
};

// ========== Inspector (DevTools) ==========
pub const Inspector = inspector_mod.Inspector;

// ========== Declarative API: inline children ==========
//
// Top-level builder functions (`box`, `text`, `image`, `icon`, `svg`, `spacer`, `grid`,
// `clickable`, plus `hstack`/`vstack`) live in `core/builders.zig`. Re-exported here for
// `ui.box(...)` / `core.box(...)` compatibility.
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
pub const imageTintStyled = builders.imageTintStyled;
pub const svg = builders.svg;
pub const svgTint = builders.svgTint;
pub const spacer = builders.spacer;
pub const anchorNode = builders.anchor;
/// Component protocol type for `ui.view` (see view_parts.zig).
pub const ViewParts = @import("view_parts.zig").ViewParts;
pub const grid = builders.grid;
pub const GridStyle = builders.GridStyle;
pub const clickable = builders.clickable;

// ========== Declarative API: reactive text ==========
/// textFmt, reactive text node: content = comptime format string + Signal/Memo sources.
///
/// ```
/// const count = try scope.createSignal(u32, 0);
/// const label = try ui.textFmt(cx, scope, "count = {d}", .{count}, .{ .font_size = 18 });
/// ```
/// An internal effect reformats and calls `setText` + `markRenderDirty` on any source change.
/// `sources` is a tuple of `*Signal(T)` / `*Memo(T)`; the effect calls `.get()` (auto-subscribe).
/// Memory: `setText` doesn't copy >16 bytes, so the format buffer must outlive the node and be
/// address-stable: heap-allocated scope resource, freed after the effect. **Dispose the scope
/// before the node.**
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
    // Until return, this node has no sink/parent to own it. State allocation,
    // resource registration or effect creation can fail before viewEmit sees
    // the node; those paths must release it here. The scope still owns state.
    errdefer cx.freeDetachedNodeAfterScopeDispose(node);

    checkSourcesBorrow(scope, sources);
    const state = try cx.allocator.create(State);
    state.* = .{ .node = node, .sources = sources, .allocator = cx.allocator };
    try scope.adoptResource(state, State.destroy);

    // createEffect runs immediately -> first frame is real content.
    try scope.createEffect(.{ .s = state }, struct {
        fn run(ctx: anytype) void {
            ctx.s.update();
        }
    }.run);

    return node;
}

/// textFmt per-node state: stable-address format buffer + source tuple. Short content uses fixed
/// buf; overflow fallback to allocator (avoiding silent truncate/freeze).
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
                // Buffer owned by state; forbid node destroy path from freeing it.
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

/// Source tuple -> value tuple type. Elements can be `*Signal(T)` / `*Memo(T)` / derived
/// (`ui.map(...)`) / `Source(T)`, rest formatted as static values.
fn SourceValues(comptime Sources: type) type {
    const fields = @import("zenit_reflection").fields(Sources);
    var value_types: [fields.len]type = undefined;
    for (fields, 0..) |f, i| {
        value_types[i] = if (isReactiveArg(f.type)) reactive.SourceValueOf(f.type) else f.type;
    }
    return @Tuple(&value_types);
}

fn isReactiveArg(comptime X: type) bool {
    const source_kinds = @import("reactive/source.zig");
    if (source_kinds.reactiveKindOf(X) != null) return true;
    return switch (@typeInfo(X)) {
        .@"struct", .@"union" => @hasDecl(X, "zenit_source"),
        else => false,
    };
}

fn readSourceValues(sources: anytype) SourceValues(@TypeOf(sources)) {
    var out: SourceValues(@TypeOf(sources)) = undefined;
    inline for (@import("zenit_reflection").fields(@TypeOf(sources)), 0..) |f, i| {
        const v = @field(sources, f.name);
        out[i] = if (comptime isReactiveArg(f.type)) reactive.toSource(v).get() else v;
    }
    return out;
}

fn checkSourcesBorrow(scope: *Scope, sources: anytype) void {
    inline for (@import("zenit_reflection").fields(@TypeOf(sources))) |f| {
        if (comptime isReactiveArg(f.type)) reactive.checkBorrow(scope, @field(sources, f.name));
    }
}

// ========== Render commands ==========
pub const DisplayItem = display_list_mod.DisplayItem;

test {
    _ = @import("core/cx_tests.zig");
    _ = @import("core/window_chrome_tests.zig");
    _ = @import("core/presentation_clock.zig");
}

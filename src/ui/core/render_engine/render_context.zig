/// RenderContext: render engine's explicit context, replacing cx: anytype god-object.
///
/// All mod.zig / node_style_render.zig / text_render.zig rendering functions use *RenderContext
/// instead of anytype, enabling compile-time type checking and standalone submodule testability.
const std = @import("std");
const display_list_mod = @import("../display_list.zig");
const text_blob_mod = @import("../text_blob.zig");
const scene_runtime_mod = @import("../scene_runtime.zig");
const id_hash = @import("../id_hash.zig");
const property_tree_mod = @import("../property_tree.zig");
const layer_tree_mod = @import("../layer_tree.zig");
const hit_runtime_mod = @import("../hit_runtime.zig");
const world_mod = @import("../world.zig");
const types = @import("../types.zig");
const shaping_cache_mod = @import("../shaping_cache.zig");
const paint_table_mod = @import("../paint_table.zig");
const text_module = @import("text");
const text_coordinates = @import("text_core").text_coordinates;

pub const ContentStateEntry = struct {
    valid: bool = false,
    parent_transform: types.Transform2D = .{},
    parent_clip: ?types.ComputedRect = null,
    state: @import("node_state.zig").NodeContentRenderState = undefined,
};

pub const RenderContext = struct {
    /// Optional snapshot sink: capture the same lowered commands sent to the encoder.
    capture_lowered: ?*std.ArrayList(display_list_mod.DisplayItem) = null,
    /// Records where compositor-sprite nodes' items land in the paint list.
    sprite_probe: ?*@import("../compositor_sprite.zig").Registry = null,
    /// Lowering output buffer (DisplayItem world-space slice). Lowering paths write here; encoder
    /// gets slice via cx.lowerForEncoder().
    lowering_buffer: *std.ArrayList(display_list_mod.DisplayItem),
    /// Mirror buffer from paint_table.DisplayItem perspective. Indexes 1:1 sync with
    /// lowering_buffer; encoder's main path (lowerForEncoderPaintTable) returns directly from here.
    lowering_buffer_paint: *std.ArrayList(paint_table_mod.DisplayItem),
    display_list: *display_list_mod.DisplayList,
    text_blob_store: *text_blob_mod.BlobStore,
    scene_runtime: *scene_runtime_mod.SceneRuntime,
    property_tree: *property_tree_mod.PropertyTree,
    layer_tree: *layer_tree_mod.LayerTree,
    /// World embeds RenderContext; render path reads LayoutTable / PaintTable. Currently
    /// shadow-mode: node.rect and world.layout kept in sync by syncLayoutToTable.
    world: *world_mod.World,
    allocator: std.mem.Allocator,
    frame_allocator: std.mem.Allocator,
    viewport: types.Size,
    perf: *hit_runtime_mod.PerfCounters,
    /// GlyphRun pipeline: render engine uses GlyphRun via ShapingCache instead of directly calling
    /// measureTextWidthByFontKind to platform bridge. Null falls back to legacy text_layout path.
    /// Paint-order prefix invariant (display_list raw order == global paint order guarantee):
    /// prebuild's two passes follow paint order; once **content must stay for paint pass fresh
    /// emit** (transformed subtrees, overlay hook relocation, unrepresentable own...), paint order
    /// prohibits further prebuild, else later-painted content goes into display_list first; fresh
    /// content appends at tail, causing "rotated diamond floating above z=30500 overlay" piercing.
    /// Prebuild content is always a **prefix** of paint order. Reset each frame via
    /// beginRetainedFrame.
    display_payload_prefix_broken: bool = false,
    /// Nodes whose subtree-payload cache crosses a disable_render_cache
    /// boundary, either as an ancestor or a descendant. Built once per
    /// prebuild pass so cache eligibility stays O(1) per node.
    render_cache_boundary_blocked: ?*const id_hash.U32HashMapUnmanaged(void) = null,
    /// Paint-cursor prebuild resume (see `tryResumePrebuildAtPaintCursor`) is suppressed while
    /// this is non-zero: inside the subtree of an undeclared before_render hook (the hook may
    /// write its descendants without marking them dirty) and inside a subtree whose content was
    /// already prebuilt this frame but is being re-rendered (the fresh portion is truncated).
    paint_resume_suppress_depth: u32 = 0,
    /// Depth of undeclared before_render hooks enclosing the node being painted (their subtree
    /// is hook-owned: no cross-frame own-content reuse either, see beforeRenderHookTaintsSubtree).
    hook_owned_depth: u32 = 0,
    /// Escape hatch ZENIT_DISABLE_OWN_PAYLOAD_CACHE=1 clears it (read once per renderNode).
    own_payload_cache_enabled: bool = true,
    /// Escape hatches ZENIT_DISABLE_SUBTREE_SPLICE / ZENIT_DISABLE_SUBTREE_PAYLOAD_REPLAY, read
    /// once per renderNode: they used to be queried per node (getenv scans the environment), which
    /// with splices on every clean subtree cost more than the splice itself.
    subtree_splice_disabled: bool = false,
    /// false: the paint pass skips its own lowering into lowering_buffer_paint (subtree / own
    /// replays, scroll clip tokens). Set by a caller that clears that buffer after renderNode and
    /// lowers the whole display list itself (Cx.render): the paint-pass copy was discarded
    /// unread, and with most of a frame now replayed from caches it cost as much as the record
    /// it replaced. Direct renderNode users (tests reading the buffer) keep the default.
    paint_pass_lowering: bool = true,
    /// Lowering of one recorded item (display_list_lowering): the transform it
    /// goes through, which with the item's ItemHeader.local_fp names the
    /// lowered pixels (paint_table.DisplayItem.paint_digest), and how many
    /// paint items it has produced. null outside that scope (digest unknown).
    lowering_fp_transform: ?@import("../types.zig").Transform2D = null,
    lowering_fp_seq: u32 = 0,
    subtree_payload_replay_disabled: bool = false,
    /// Nodes that are, or descend from, a disable_render_cache boundary: their own content is
    /// never cached across frames (built with render_cache_boundary_blocked).
    render_cache_own_blocked: ?*const id_hash.U32HashMapUnmanaged(void) = null,
    /// Nodes with a sticky or positive-z descendant, indexed with the cache boundaries for the
    /// renderNode pass in progress (null outside it: the check walks the subtree).
    out_of_band_subtrees: ?*const id_hash.U32HashMapUnmanaged(void) = null,
    /// Escape hatch ZENIT_DISABLE_PAINT_RESUME=1 clears it (read once per renderNode).
    paint_resume_enabled: bool = true,
    /// Reference mode for the incremental == full check (`ZENIT_VERIFY_INCREMENTAL`): no
    /// cross-frame subtree payload splice, no cache writes, no paint-cursor resume. The frame is
    /// produced exactly as if no subtree payload cache existed.
    subtree_payload_reference_mode: bool = false,
    /// Nodes given a scene record this frame, in the order buildRetainedSubtree appended them
    /// (frame allocator); the retained subtree memo copies runs of it (retained_memo.zig).
    retained_nodes: std.ArrayList(*@import("../node.zig").Node) = .empty,
    /// Retained subtree memo on for this frame (ZENIT_DISABLE_RETAINED_MEMO clears it).
    retained_memo_enabled: bool = false,
    /// Content render state each node got in buildRetainedSubtree this frame, indexed like
    /// retained_nodes (SceneNodeRuntime.retained_index); the paint pass reuses it for the same
    /// inputs instead of recomputing (frame allocator).
    content_states: std.ArrayList(ContentStateEntry) = .empty,
    /// Undeclared before_render hooks enclosing the node buildRetainedSubtree visits.
    retained_hook_owned_depth: u32 = 0,
    /// Node external clip rects table (node.id -> viewport-space rect; see Cx.external_clip_rects).
    /// null = host did not enable this capability (DevTools etc. sidecar construction ignores).
    external_clip_rects: ?*const std.AutoHashMapUnmanaged(u32, [4]f32) = null,
    shaping_cache: ?*shaping_cache_mod.ShapingCache = null,
    font_system: ?*text_module.FontSystem = null,
    measure_font_context: ?*anyopaque = null,
    measure_font_fn: ?@import("../layout_engine.zig").DrawnTextMeasureFn = null,
    visual_line_context: ?*anyopaque = null,
    visual_line_fn: ?*const fn (*anyopaque, []const u8, f32, u16, bool, u16, bool, bool) ?text_coordinates.VisualLine = null,

    pub fn visualLine(self: *RenderContext, text: []const u8, font_size: f32, font_weight: u16, italic: bool, family: u16, mono: bool, symbols: bool) ?text_coordinates.VisualLine {
        const callback = self.visual_line_fn orelse return null;
        return callback(self.visual_line_context orelse return null, text, font_size, font_weight, italic, family, mono, symbols);
    }

    /// Stage 4-2 helper: read element rect from World.LayoutTable; when node lacks World, fall back
    /// to standalone fallback (node.rectFromWorldOrFallback). v0.5-P3 N-2 (2026-05-03):
    /// frame_state.rect field removed; all fallbacks use g_standalone_rects hashmap in node.zig.
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

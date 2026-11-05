/// Accordion / Collapsible Component
///
/// Collapsible panel component with expand/collapse animation.
///
/// Features:
/// - AccordionItem: header title + expandable content
/// - Click header to expand/collapse
/// - max_height interpolation + overflow_hidden for smooth collapse animation
/// - Signal-first: `expanded: Model(bool)`, `title: Source`; mutual expand via data:
///   `Accordion(.{ .open = section })` + each `.expanded = try acc.item(i)`
/// - on_change callback (after user action lands)
const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../../core.zig");
const view = @import("../../view.zig");
const Cx = core.Cx;
const Node = core.Node;
const box = core.box;
const Color = core.Color;
const theme = core.theme;
const Padding = core.Padding;
const Border = core.Border;
const ConditionalStyle = core.ConditionalStyle;
const hooks = @import("../../hooks.zig");
const events = @import("../../events.zig");
const Event = events.Event;
const EventResult = events.EventResult;
const svg_assets = @import("../../svg_assets.zig");
const reactive = @import("../../reactive.zig");
const Scope = reactive.Scope;
const Source = reactive.Source;
const Model = reactive.Model;
const Handler = core.Handler;
const bind_mod = @import("../../bind.zig");
const node_animator = @import("../../animation/node_animator.zig");
const recipe_mod = @import("../../recipe.zig");
const styles = @import("styles.zig");

// AccordionItemRecipe, recipe(variant) unifies AccordionItem styling.
// variant dimension:
//   - default: primary surface + panel radius + 1px border
//   - outline: transparent background + 1px border + rounded corner
//   - ghost:   fully transparent, no border no corner

/// AccordionItem variant.
pub const AccordionVariant = enum {
    default,
    outline,
    ghost,
};

pub const AccordionItemRecipe = styles.AccordionItemRecipe;

// ==================== AccordionItem ====================

const Signal = core.Signal;

/// AccordionItem view and animation state (scope-owned). `expanded` is
/// last-applied value to view; before_render compares with `last_expanded` to
/// initiate height / chevron animation.
pub const AccordionItemState = struct {
    expanded: bool = false,
    /// Previous frame expanded (for before_render change detection).
    last_expanded: bool = false,
    /// Animation state: idle -> measuring (expand needs measurement) -> animating.
    anim_phase: enum { idle, measure_expand, animating } = .idle,
    /// content node reference.
    content_node: ?*Node = null,
    /// body node reference (for direct intrinsic height read, avoid extra frame wait on
    /// expand).
    body_node: ?*Node = null,
    /// container node reference (for markRenderDirty + border-color animation).
    container_node: ?*Node = null,
    /// chevron icon node (rotate animation: 0 degrees collapsed -> 90 degrees expanded).
    chevron_node: ?*Node = null,
    /// title text node (weight 600 expanded, 500 collapsed).
    title_node: ?*Node = null,
    /// header button node (a11y expanded attribute on it).
    header_node: ?*Node = null,
    /// animation allocator (must match node allocator, used in beforeRender callback).
    alloc: Allocator = std.heap.page_allocator,

    /// Apply expanded state to view (a11y, title weight, request redraw); animation
    /// initiated by before_render.
    fn applyExpanded(self: *AccordionItemState, expanded: bool) void {
        if (self.expanded == expanded) return;
        self.expanded = expanded;

        // aria-expanded: without it, AT users can't tell if content expanded after pressing
        // header.
        if (self.header_node) |header| {
            if (header.behavior.interaction.a11y) |*a| a.expanded = expanded;
        }

        // title weight 600 when expanded, 500 when collapsed.
        if (self.title_node) |title| {
            if (title.getText()) |old| {
                var t = old;
                t.font_weight = if (expanded) 600 else 500;
                title.setText(t);
            }
        }

        if (self.container_node) |node| {
            node.markRenderDirty();
        }
    }
};

/// AccordionItem runtime: expand state data source and write-back pipeline.
const ItemRuntime = struct {
    expanded: reactive.Bound(bool),
    on_change: ?Handler(bool),
    state: *AccordionItemState,

    fn viewEffect(self: *ItemRuntime) void {
        self.state.applyExpanded(self.expanded.readAs(true));
    }

    /// Click / space / enter: proposal only, view effect refreshes after data source lands.
    fn toggle(self: *ItemRuntime) void {
        if (self.expanded.commit(!self.state.expanded)) |landed| {
            if (self.on_change) |h| h.call(landed);
        }
    }
};

/// AccordionItem before-render hook: detect expanded change -> initiate height animation.
fn accordionItemBeforeRender(node: *Node) void {
    const state: *AccordionItemState = @ptrCast(@alignCast(node.behavior.events.event_context orelse return));
    const content = state.content_node orelse return;
    const alloc = state.alloc;

    // 1. detect expanded state change.
    if (state.expanded != state.last_expanded) {
        state.last_expanded = state.expanded;

        // chevron rotate animation: collapsed 0 degrees -> expanded pi/2.
        if (state.chevron_node) |chevron| {
            const target_rotate: f32 = if (state.expanded) std.math.pi / 2.0 else 0.0;
            const from_rotate: f32 = if (state.expanded) 0.0 else std.math.pi / 2.0;
            node_animator.animateNode(chevron, alloc, .{
                .prop = .rotate,
                .from = from_rotate,
                .to = target_rotate,
                .duration = 0.2,
                .easing = .ease_in_out_cubic,
            });
        }

        if (state.expanded) {
            const target_h = blk: {
                if (state.body_node) |body| {
                    const bh = body.rectFromWorldOrFallback().h;
                    if (bh > 0) break :blk bh;
                }
                break :blk 0;
            };

            if (target_h > 0) {
                content.style.height = .{ .px = 0 };
                content.style.overflow_hidden = true;
                content.markLayoutDirty();

                node_animator.animateNode(content, alloc, .{
                    .prop = .height,
                    .from = 0,
                    .to = target_h,
                    .duration = 0.32,
                    .easing = .ease_in_out_cubic,
                    .on_complete = expandComplete,
                    .on_complete_ctx = @ptrCast(state),
                });
                state.anim_phase = .animating;
            } else {
                // fallback: first set height=.fit + overflow_hidden to let layout engine compute
                // true height, then read and initiate animation next frame (measure_expand).
                content.style.height = .{ .fit = .{} };
                content.style.overflow_hidden = true;
                content.markLayoutDirty();
                state.anim_phase = .measure_expand;
                node.markRenderDirty();
            }
        } else {
            // collapse: animate directly from current height to 0.
            const current_h = content.rectFromWorldOrFallback().h;
            content.style.height = .{ .px = current_h };
            content.style.overflow_hidden = true;
            content.markLayoutDirty();

            node_animator.animateNode(content, alloc, .{
                .prop = .height,
                .from = current_h,
                .to = 0,
                .duration = 0.2,
                .easing = .ease_out_cubic,
                .on_complete = collapseComplete,
                .on_complete_ctx = @ptrCast(state),
            });
            state.anim_phase = .animating;
        }
        return;
    }

    // 2. expand measure frame: read true height post-layout, initiate 0 -> realHeight
    // animation.
    if (state.anim_phase == .measure_expand) {
        const real_h = content.rectFromWorldOrFallback().h;
        if (real_h > 0) {
            // Got true height, start animation from 0.
            content.style.height = .{ .px = 0 };
            content.markLayoutDirty();

            node_animator.animateNode(content, alloc, .{
                .prop = .height,
                .from = 0,
                .to = real_h,
                .duration = 0.32,
                .easing = .ease_in_out_cubic,
                .on_complete = expandComplete,
                .on_complete_ctx = @ptrCast(state),
            });
            state.anim_phase = .animating;
        } else {
            // Layout not complete yet, wait next frame.
            node.markRenderDirty();
        }
        return;
    }

    // 3. continuous refresh while animation in progress.
    if (state.anim_phase == .animating) {
        if (content.frame_state.frame_local.runtime.commands) |anims| {
            if (anims.count > 0) {
                node.markRenderDirty();
            } else {
                state.anim_phase = .idle;
            }
        } else {
            state.anim_phase = .idle;
        }
    }
}

/// expand animation complete: switch back to height=.fit for free content resize.
fn expandComplete(ctx: *anyopaque) void {
    const state: *AccordionItemState = @ptrCast(@alignCast(ctx));
    if (state.content_node) |content| {
        content.style.height = .{ .fit = .{} };
        content.style.overflow_hidden = false;
        content.markSizingDirty();
    }
    state.anim_phase = .idle;
}

/// collapse animation complete: keep height=0 + overflow_hidden.
fn collapseComplete(ctx: *anyopaque) void {
    const state: *AccordionItemState = @ptrCast(@alignCast(ctx));
    if (state.content_node) |content| {
        content.style.height = .{ .px = 0 };
        content.style.overflow_hidden = true;
        content.markSizingDirty();
    }
    state.anim_phase = .idle;
}

/// AccordionItem click event handler.
fn accordionItemClickHandler(event: Event, context: ?*anyopaque) EventResult {
    const rt: *ItemRuntime = @ptrCast(@alignCast(context orelse return .ignored));

    switch (event) {
        .click => {
            rt.toggle();
            return .handled;
        },
        .key_down => |e| {
            if (e.key == .space or e.key == .@"return") {
                rt.toggle();
                return .handled;
            }
            return .ignored;
        },
        else => return .ignored,
    }
}

/// AccordionItem properties.
pub const AccordionItemProps = struct {
    /// Title text.
    title: Source([]const u8) = .{ .value = "" },
    /// Expand state: `bool` uncontrolled initial; `*Signal(bool)` controlled (interaction
    /// writes directly); `ui.split` parent intercepts; mutual expand uses `acc.item(i)`.
    expanded: Model(bool) = .{ .local = false },
    /// Visual variant.
    variant: AccordionVariant = .default,
    /// Called after user expand/collapse lands.
    on_change: ?Handler(bool) = null,
    /// Chevron icon (optional, default chevron_right).
    chevron_asset: ?svg_assets.Asset = null,
};

/// Create AccordionItem: `W.AccordionItem(.{ .title = "Details", .expanded = open })`.
pub fn AccordionItem(props: anytype) AccordionItemBuilder {
    return .{ .props = reactive.props.coerce(AccordionItemProps, props) };
}

/// Result of AccordionItemBuilder.mount.
pub const AccordionItemResult = struct {
    item: *Node,
    body: *Node,

    /// `ui.view` integration (see src/ui/view_parts.zig).
    pub fn viewParts(self: AccordionItemResult) core.ViewParts {
        return .{ .root = self.item, .slot = self.body };
    }
};

/// AT ExpandCollapse: explicit target state, uses same write-back pipeline as click
/// (mutual expand guaranteed by `acc.item(i)` data source, no manual sibling collapse
/// here).
fn setAccessibleExpanded(raw: *anyopaque, expanded: bool) bool {
    const rt: *ItemRuntime = @ptrCast(@alignCast(raw));
    if (rt.state.expanded == expanded) return true;
    const landed = rt.expanded.commit(expanded) orelse return false;
    if (rt.on_change) |h| h.call(landed);
    return landed == expanded;
}

pub const AccordionItemBuilder = struct {
    props: AccordionItemProps,

    /// Preserve mode: mount, return { item root node, content body node }.
    pub fn mount(self: AccordionItemBuilder, scope: *Scope, cx: *Cx) !AccordionItemResult {
        cx.owner.enterMount();
        defer cx.owner.exitMount();
        const my_scope = try scope.childScope();
        // my_scope unowned before binding to item.
        var scope_bound = false;
        errdefer if (!scope_bound) my_scope.dispose();
        const allocator = cx.allocator;
        const t = cx.tokens;
        const p = self.props;
        reactive.checkBorrow(my_scope, p.title);
        const expanded_model = try reactive.resolveModel(bool, my_scope, p.expanded);
        const initially_expanded = expanded_model.readAs(false);

        // === Recipe resolve ===
        const item_cs = AccordionItemRecipe.resolve(.{ .variant = p.variant }, t);
        const item_resolved = item_cs.resolve(.{});

        const item_bg = item_resolved.background orelse Color.TRANSPARENT;

        // allocate internal state.
        const state = try my_scope.allocator.create(AccordionItemState);
        state.* = .{
            .expanded = initially_expanded,
            .last_expanded = initially_expanded,
            .alloc = allocator,
        };
        try my_scope.adoptResource(@ptrCast(state), struct {
            fn destroy(ptr: *anyopaque, alloc: Allocator) void {
                const s: *AccordionItemState = @ptrCast(@alignCast(ptr));
                alloc.destroy(s);
            }
        }.destroy);
        const rt = try my_scope.allocator.create(ItemRuntime);
        rt.* = .{ .expanded = expanded_model, .on_change = p.on_change, .state = state };
        try my_scope.adoptResource(@ptrCast(rt), struct {
            fn destroy(ptr: *anyopaque, alloc: Allocator) void {
                alloc.destroy(@as(*ItemRuntime, @ptrCast(@alignCast(ptr))));
            }
        }.destroy);

        // outer container (vertical: header + content); style from Recipe variant; rounded
        // corners + persistent border extracted from the recipe.
        const item_radius = item_resolved.corner_radius orelse 0;
        var item_border: Border = item_resolved.border orelse .{};
        if (item_resolved.border) |b| {
            item_border.radius = b.radius;
        } else if (item_radius > 0) {
            item_border.radius = item_radius;
        }
        const item_style: core.BoxStyle = .{
            .width = .{ .grow = .{} },
            .height = .{ .fit = .{} },
            .background = item_bg,
            .corner_radius = if (item_radius > 0) item_radius else null,
            .border = item_border,
            .overflow_hidden = true,
        };
        // Chevron indicator (rotate around icon's own center).
        const chevron_size: core.Sizing = .{ .px = styles.accordion_chevron_size };
        const chevron_style: core.BoxStyle = .{
            .width = chevron_size,
            .height = chevron_size,
            .transform_origin = core.TransformOrigin.centered(),
            .will_change_transform = true,
            .rotate = if (initially_expanded) std.math.pi / 2.0 else null,
        };

        const Parts = struct { header: *Node = undefined, chevron: *Node = undefined, title: *Node = undefined, content: *Node = undefined, body: *Node = undefined };
        var parts: Parts = .{};
        const item = try view.render(my_scope, cx, view.col(.{ .style = item_style }, .{
            // === Header (clickable) ===.
            view.capture(&parts.header, view.box(.{
                .style = .{ styles.accordionHeaderStyle(t), view.hover(styles.accordionHeaderHover) },
                .focusable = true,
                // header is button semantic node.
                .tag = .button,
                .a11y = core.A11yProps{
                    .role = .button,
                    .expanded = initially_expanded,
                    .expansion = .{ .context = @ptrCast(rt), .set = setAccessibleExpanded },
                },
            }, .{
                view.capture(&parts.chevron, view.icon(.{ .style = chevron_style, .tint = t.tokens.color.fg_tertiary, .hit_test = false }, p.chevron_asset orelse svg_assets.common.chevron_right)),
                // title text: fills header remaining width (long titles clipped in header, same as
                // box text node).
                view.capture(&parts.title, view.attrs(.{ .style = core.BoxStyle{ .width = .{ .grow = .{} } } }, view.text(.{ .style = styles.accordionTitleText(initially_expanded, t), .hit_test = false }, p.title.peek()))),
            })),
            // === Content container (overflow_hidden + height animation) ===
            // Only observable expand state exit: height set 0 when collapsed, fit when expanded.
            // body child rect.h is content height, unchanged by collapse (clipping happens in
            // render phase, not layout rect), so e2e must check this layer.
            view.capture(&parts.content, view.col(.{
                .style = .{
                    .width = .{ .grow = .{} },
                    .height = if (initially_expanded) core.Sizing{ .fit = .{} } else core.Sizing{ .px = 0 },
                    .overflow_hidden = !initially_expanded,
                },
                .test_id = "accordion.content",
            }, .{
                // content body; left indent contract in accordionBodyStyle.
                view.capture(&parts.body, view.box(.{ .style = styles.accordionBodyStyle(t) }, {})),
            })),
        }));
        // sweep: item guard armed until return.
        errdefer cx.freeNode(item);

        item.meta.ownership.meta.component_name = "AccordionItem";
        try core.bindScopeToNode(my_scope, item);
        scope_bound = true;
        state.container_node = item;

        const header = parts.header;
        state.header_node = header;
        state.chevron_node = parts.chevron;

        const title_node = parts.title;
        // header a11y label points to title node copy; re-assigned after dynamic title
        // update.
        if (header.behavior.interaction.a11y) |*a| a.label = title_node.getText().?.content;
        try bind_mod.bindTextLabel(cx, my_scope, p.title, title_node, header);
        title_node.behavior.events.event_context = rt;
        title_node.behavior.events.on_event = accordionItemClickHandler;
        state.title_node = title_node;

        // Header interaction (header doesn't respond to hover background change, border
        // managed by item container).
        header.behavior.events.event_context = rt;
        header.behavior.events.on_event = accordionItemClickHandler;
        try hooks.useFocusRing(my_scope, cx, header, .{});

        state.content_node = parts.content;
        const body = parts.body;
        state.body_node = body;

        // Set on_before_render animation (must come after useFocusRing, which chains saves).
        item.behavior.events.event_context = state;
        item.meta.per_frame.hooks.before_render.main = accordionItemBeforeRender;

        // expanded is Model: local is also signal, click changes it, must have effect.
        try my_scope.createEffect(rt, ItemRuntime.viewEffect);
        return .{ .item = item, .body = body };
    }
};

// ==================== Accordion (container) ====================.

/// Accordion runtime: mutual expand data source (caller scope owns, see mount).
pub const AccordionRuntime = struct {
    open: reactive.Bound(?usize),
    scope: *Scope,

    /// Item expanded = `open == index`; write true to set item, write false clears
    /// only if it's current item.
    const ItemSlot = struct {
        rt: *AccordionRuntime,
        index: usize,

        fn compute(slot: *ItemSlot) bool {
            const cur = slot.rt.open.read.get() orelse return false;
            return cur == slot.index;
        }

        fn write(slot: *ItemSlot, expanded: bool) void {
            if (expanded) {
                _ = slot.rt.open.commit(slot.index);
            } else if (slot.rt.open.read.peek()) |cur| {
                if (cur == slot.index) _ = slot.rt.open.commit(null);
            }
        }
    };

    fn item(self: *AccordionRuntime, index: usize) !Model(bool) {
        const slot = try self.scope.allocator.create(ItemSlot);
        slot.* = .{ .rt = self, .index = index };
        try self.scope.adoptResource(@ptrCast(slot), struct {
            fn destroy(ptr: *anyopaque, alloc: Allocator) void {
                alloc.destroy(@as(*ItemSlot, @ptrCast(@alignCast(ptr))));
            }
        }.destroy);
        const expanded = try self.scope.createMemo(bool, slot, ItemSlot.compute);
        return .{ .split = reactive.split(expanded, reactive.Callback(bool).from(ItemSlot, slot, ItemSlot.write)) };
    }
};

/// Declarative mutual expand: no Accordion mount result needed; derives the item's
/// expanded from the parent's `*Signal(?usize)` at compile-time `index` (same semantics
/// as `AccordionResult.item`: expanded = `open == index`; write true sets the item,
/// write false clears only if it's the current one). No alloc:
/// `v.with(W.AccordionItem(.{ .title = "Billing", .expanded = W.accordionItemOpen(section, 1) }),
/// .{ ... })`.
pub fn accordionItemOpen(open: *Signal(?usize), comptime index: usize) Model(bool) {
    const Slot = struct {
        fn isOpen(cur: ?usize) bool {
            const c = cur orelse return false;
            return c == index;
        }
        fn write(sig: *Signal(?usize), expanded: bool) void {
            if (expanded) {
                sig.set(index);
            } else if (sig.peek()) |cur| {
                if (cur == index) sig.set(null);
            }
        }
    };
    return .{ .split = reactive.split(reactive.map(open, Slot.isOpen), reactive.Callback(bool).from(Signal(?usize), open, Slot.write)) };
}

/// Accordion properties.
pub const AccordionProps = struct {
    /// Mutual expand current item index (null = all collapsed): `?usize` uncontrolled
    /// initial; `*Signal(?usize)` controlled (interaction writes directly), `ui.split`
    /// intercepts. Only affects items with `.expanded = try acc.item(i)`; others expand
    /// independently.
    open: Model(?usize) = .{ .local = null },
    /// spacing.
    gap: f32 = 8,
};

/// Create Accordion: `W.Accordion(.{ .open = section })`.
pub fn Accordion(props: anytype) AccordionBuilder {
    return .{ .props = reactive.props.coerce(AccordionProps, props) };
}

/// Result of AccordionBuilder.mount.
pub const AccordionResult = struct {
    container: *Node,
    /// Mutual expand signal (null when `ui.split`).
    open: ?*Signal(?usize),
    runtime: *AccordionRuntime,

    /// Model of item `index`'s expanded state, pass to `AccordionItem(.{ .expanded
    /// = ... })`. Derived value allocated in mount-time scope, released with it
    /// (container release only, no reclaim); mutual expand by index match, same index
    /// opens/closes together.
    pub fn item(self: AccordionResult, index: usize) !Model(bool) {
        return self.runtime.item(index);
    }
    /// `ui.view` integration (see src/ui/view_parts.zig).
    pub fn viewParts(self: AccordionResult) core.ViewParts {
        return .{ .root = self.container, .slot = self.container };
    }
};

pub const AccordionBuilder = struct {
    props: AccordionProps,

    /// Preserve mode: mount, return { container node, open signal, runtime }.
    ///
    /// Runtime, open signal, and `item(i)` derived values all live in the caller `scope`:
    /// items under the same scope must read derived values from the ancestor chain (in
    /// Accordion's own child scope, items would read sibling scope data with no unload order
    /// guarantee).
    pub fn mount(self: AccordionBuilder, scope: *Scope, cx: *Cx) !AccordionResult {
        const p = self.props;
        const open = try reactive.resolveModel(?usize, scope, p.open);
        const rt = try scope.allocator.create(AccordionRuntime);
        rt.* = .{ .open = open, .scope = scope };
        try scope.adoptResource(@ptrCast(rt), struct {
            fn destroy(ptr: *anyopaque, alloc: Allocator) void {
                alloc.destroy(@as(*AccordionRuntime, @ptrCast(@alignCast(ptr))));
            }
        }.destroy);

        const container = try view.render(scope, cx, view.col(.{ .style = .{
            .width = .{ .grow = .{} },
            .height = .{ .fit = .{} },
            .gap = p.gap,
        } }, {}));
        container.meta.ownership.meta.component_name = "Accordion";
        return .{ .container = container, .open = open.asSignal(), .runtime = rt };
    }
};

// ========== Tests ==========.

test "AccordionItem: basic collapsed" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try AccordionItem(.{ .title = "Section 1" }).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, result.item);

    // item has 2 children: header + content.
    try std.testing.expectEqual(@as(usize, 2), result.item.children.items.len);
    // Collapsed: content height=0, overflow_hidden=true.
    const content = result.item.children.items[1];
    try std.testing.expectEqual(core.Sizing{ .px = 0 }, content.style.height);
    try std.testing.expect(content.style.overflow_hidden);
}

test "AccordionItem: expanded" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try AccordionItem(.{ .title = "Section 1", .expanded = true }).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, result.item);

    // Expanded: content height=.fit, overflow_hidden=false.
    const content = result.item.children.items[1];
    try std.testing.expectEqual(core.Sizing{ .fit = .{} }, content.style.height);
    try std.testing.expect(!content.style.overflow_hidden);

    const header = result.item.children.items[0];
    const chevron = header.children.items[0];
    try std.testing.expectApproxEqAbs(std.math.pi / 2.0, chevron.style.rotate(), 0.0001);
}

fn itemState(result: AccordionItemResult) *AccordionItemState {
    return @ptrCast(@alignCast(result.item.behavior.events.event_context.?));
}

fn clickHeader(result: AccordionItemResult) void {
    const header = result.item.children.items[0];
    _ = accordionItemClickHandler(.{ .click = .{ .x = 0, .y = 0, .button = .left, .click_count = 1 } }, header.behavior.events.event_context);
}

test "AccordionItem: bound expanded — external set, click writes back, on_change gets landed value" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const open = try scope.createSignal(bool, false);
    const Rec = struct {
        calls: u32 = 0,
        last: bool = false,
        fn changed(self: *@This(), v: bool) void {
            self.calls += 1;
            self.last = v;
        }
    };
    var rec = Rec{};
    const result = try AccordionItem(.{ .title = "Details", .expanded = open, .on_change = ctx.on(Rec, &rec, Rec.changed) }).mount(scope, ctx);
    defer ctx.freeNode(result.item);
    const header = result.item.children.items[0];

    open.set(true); // external drive.
    try std.testing.expect(itemState(result).expanded);
    try std.testing.expect(header.behavior.interaction.a11y.?.expanded.?);
    try std.testing.expectEqual(@as(u32, 0), rec.calls); // programmatic write doesn't trigger on_change.

    clickHeader(result);
    try std.testing.expect(!open.peek());
    try std.testing.expect(!header.behavior.interaction.a11y.?.expanded.?);
    try std.testing.expectEqual(@as(u32, 1), rec.calls);
    try std.testing.expect(!rec.last);
}

test "AccordionItem: a split parent can refuse to collapse" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const Parent = struct {
        open: *core.Signal(bool),
        fn write(self: *@This(), v: bool) void {
            if (v) self.open.set(true); // only allow expand.
        }
    };
    var parent = Parent{ .open = try scope.createSignal(bool, true) };
    const result = try AccordionItem(.{ .title = "Pinned", .expanded = reactive.split(parent.open, ctx.on(Parent, &parent, Parent.write)) }).mount(scope, ctx);
    defer ctx.freeNode(result.item);
    clickHeader(result);
    try std.testing.expect(parent.open.peek());
    try std.testing.expect(itemState(result).expanded);
}

test "AccordionItem: dynamic title updates the text and the header a11y label" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const title = try scope.createText("Files", .{});
    const result = try AccordionItem(.{ .title = title }).mount(scope, ctx);
    defer ctx.freeNode(result.item);
    const header = result.item.children.items[0];
    title.set("Files (3 changed)");
    const title_node = itemState(result).title_node.?;
    try std.testing.expectEqualStrings("Files (3 changed)", title_node.getText().?.content);
    try std.testing.expectEqual(title_node.getText().?.content.ptr, header.behavior.interaction.a11y.?.label.?.ptr);
}

test "AccordionItem: expand uses body intrinsic height when available" {
    const alloc = std.testing.allocator;
    var ctx = try Cx.init(alloc, std.testing.io);
    defer ctx.deinit();
    ctx.setViewport(480, 320);

    const root = try box(ctx, .{
        .width = .{ .px = 480 },
        .height = .{ .px = 320 },
        .background = ctx.tokens.tokens.color.bg_primary,
    }, .{});
    ctx.root = root;

    const scope = try Scope.init(alloc, null, ctx.owner);
    defer scope.dispose();

    const open = try scope.createSignal(bool, false);
    const result = try AccordionItem(.{ .title = "Section 1", .expanded = open }).mount(scope, ctx);
    try root.appendChild(alloc, result.item);

    const body_text = try box(ctx, .{
        .width = .{ .fit = .{} },
        .height = .{ .fit = .{} },
    }, .{});
    body_text.setText(.{ .content = "Expandable content", .font_size = 13, .color = ctx.tokens.tokens.color.fg_secondary });
    try result.body.appendChild(alloc, body_text);

    ctx.layout();

    const state = itemState(result);
    try std.testing.expect(state.body_node != null);
    try std.testing.expect(state.body_node.?.rectFromWorldOrFallback().h > 0);

    open.set(true);
    if (result.item.meta.per_frame.hooks.before_render.main) |hook| {
        hook(result.item);
    }

    try std.testing.expectEqual(@TypeOf(state.anim_phase).animating, state.anim_phase);
    try std.testing.expect(state.content_node.?.frame_state.frame_local.runtime.commands != null);
}

test "Accordion: acc.item(i) makes items mutually exclusive through the open signal" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const section = try scope.createSignal(?usize, 0);
    const acc = try Accordion(.{ .open = section }).mount(scope, ctx);
    defer ctx.freeNode(acc.container);
    var items: [3]AccordionItemResult = undefined;
    for (&items, 0..) |*it, i| {
        it.* = try AccordionItem(.{ .title = "Section", .expanded = try acc.item(i) }).mount(scope, ctx);
        try acc.container.appendChild(std.testing.allocator, it.item);
    }
    try std.testing.expect(itemState(items[0]).expanded);
    try std.testing.expect(!itemState(items[1]).expanded);

    clickHeader(items[1]); // expand 1 -> 0 auto-collapse.
    try std.testing.expectEqual(@as(?usize, 1), section.peek());
    try std.testing.expect(!itemState(items[0]).expanded);
    try std.testing.expect(itemState(items[1]).expanded);

    clickHeader(items[1]); // click 1 again -> all collapse.
    try std.testing.expectEqual(@as(?usize, null), section.peek());
    try std.testing.expect(!itemState(items[1]).expanded);

    section.set(2); // external drive.
    try std.testing.expect(itemState(items[2]).expanded);
    try std.testing.expect(!itemState(items[0]).expanded and !itemState(items[1]).expanded);
}

test "Accordion: exclusive click inside a host batch reports the landed value once" {
    // Real clicks all in host entry batch: effect deferred until batch end, commit
    // must still read write-back value from lazy memo, else on_change never triggers.
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const section = try scope.createSignal(?usize, 0);
    const acc = try Accordion(.{ .open = section }).mount(scope, ctx);
    defer ctx.freeNode(acc.container);
    const Rec = struct {
        calls: [2]u32 = .{ 0, 0 },
        last: [2]bool = .{ false, false },
        fn first(self: *@This(), v: bool) void {
            self.calls[0] += 1;
            self.last[0] = v;
        }
        fn second(self: *@This(), v: bool) void {
            self.calls[1] += 1;
            self.last[1] = v;
        }
    };
    var rec = Rec{};
    const a = try AccordionItem(.{ .title = "A", .expanded = try acc.item(0), .on_change = ctx.on(Rec, &rec, Rec.first) }).mount(scope, ctx);
    try acc.container.appendChild(std.testing.allocator, a.item);
    const b = try AccordionItem(.{ .title = "B", .expanded = try acc.item(1), .on_change = ctx.on(Rec, &rec, Rec.second) }).mount(scope, ctx);
    try acc.container.appendChild(std.testing.allocator, b.item);

    ctx.owner.beginBatch();
    clickHeader(b);
    ctx.owner.endBatch();
    try std.testing.expectEqual(@as(?usize, 1), section.peek());
    try std.testing.expectEqual(@as(u32, 1), rec.calls[1]);
    try std.testing.expect(rec.last[1]);
    try std.testing.expectEqual(@as(u32, 0), rec.calls[0]); // passive collapse doesn't fire on_change.
    try std.testing.expect(!itemState(a).expanded and itemState(b).expanded);
}

test "Accordion: items with their own expanded stay independent" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const acc = try Accordion(.{}).mount(scope, ctx);
    defer ctx.freeNode(acc.container);
    const a = try AccordionItem(.{ .title = "A" }).mount(scope, ctx);
    try acc.container.appendChild(std.testing.allocator, a.item);
    const b = try AccordionItem(.{ .title = "B" }).mount(scope, ctx);
    try acc.container.appendChild(std.testing.allocator, b.item);
    clickHeader(a);
    clickHeader(b);
    try std.testing.expect(itemState(a).expanded and itemState(b).expanded);
}

test "Accordion: hit-test follows layout after a sibling expands (regression)" {
    // Reproduce user-reported bug: expanding upper item pushes lower item down; click
    // on lower item header should hit lower item (hit-test uses new layout), not node
    // at that position in old layout.
    const render_engine = @import("../../core/render_engine/mod.zig");
    const alloc = std.testing.allocator;
    var ctx = try Cx.init(alloc, std.testing.io);
    defer ctx.deinit();
    ctx.setViewport(600, 400);

    const root = try box(ctx, .{ .width = .{ .px = 600 }, .height = .{ .px = 400 }, .direction = .column }, .{});
    ctx.root = root;

    const scope = try Scope.init(alloc, null, ctx.owner);
    defer scope.dispose();

    const acc = try Accordion(.{ .gap = 8 }).mount(scope, ctx);
    try root.appendChild(alloc, acc.container);

    // Align with storybook scenario: item 0 initially expanded (expands via animation
    // on mount).
    var items: [3]*Node = undefined;
    var opens: [3]*core.Signal(bool) = undefined;
    inline for (.{ "Section One", "Section Two", "Section Three" }, 0..) |title, i| {
        opens[i] = try scope.createSignal(bool, i == 0);
        const it = try AccordionItem(.{ .title = title, .expanded = opens[i] }).mount(scope, ctx);
        const body_text = try box(ctx, .{ .width = .{ .fit = .{} }, .height = .{ .fit = .{} } }, .{});
        body_text.setText(.{ .content = "Panel body content.", .font_size = 13, .color = ctx.tokens.tokens.color.fg_secondary });
        try it.body.appendChild(alloc, body_text);
        try acc.container.appendChild(alloc, it.item);
        items[i] = it.item;
    }

    // settle initial layout + item0's mount expand animation (multiple frames).
    var t: f64 = 0;
    var warm: usize = 0;
    while (warm < 60) : (warm += 1) {
        t += 16;
        render_engine.current_frame_time_ms = t;
        ctx.frame_time_ms = t;
        ctx.layout();
        _ = ctx.render();
    }

    // After initial expand settles, all three header positions should hit
    // corresponding items (baseline: not clicked yet).
    inline for (.{ 0, 1, 2 }) |idx| {
        const hdr0 = items[idx].children.items[0];
        const hr0 = hdr0.globalRect();
        const h0 = ctx.hitTest(hr0.x + hr0.w * 0.5, hr0.y + hr0.h * 0.5);
        try std.testing.expect(nodeIsInSubtree(h0, items[idx]));
    }

    // Record initial top y of all three item headers (header is item.children[0]).
    const header2_y0 = items[2].children.items[0].globalRect().y;

    // Expand Section Two (item 1) -> trigger height animation, push Section Three
    // down.
    opens[1].set(true);

    // Run enough frames for expand animation + finalization (expandComplete ->
    // height=.fit) to settle.
    var frame: usize = 0;
    while (frame < 60) : (frame += 1) {
        t += 16;
        render_engine.current_frame_time_ms = t;
        ctx.frame_time_ms = t;
        ctx.layout();
        _ = ctx.render();
    }

    // Section Three header should now be pushed further down.
    const header2 = items[2].children.items[0];
    const r2 = header2.globalRect();
    try std.testing.expect(r2.y > header2_y0 + 10); // indeed moved down.

    // Key assertion: hit-test at Section Three header's **new** position must hit
    // it (or its child / itself). Old layout bug hits different item or nothing.
    const hit = ctx.hitTest(r2.x + r2.w * 0.5, r2.y + r2.h * 0.5);
    try std.testing.expect(hit != null);
    try std.testing.expect(nodeIsInSubtree(hit, items[2]));

    // Full coverage: after expanding Section Two, hit-test at all three header
    // positions must hit **corresponding** item (prevent off-by-one: click item1 header
    // but hit item2, etc).
    inline for (.{ 0, 1, 2 }) |idx| {
        const hdr = items[idx].children.items[0];
        const hr = hdr.globalRect();
        const h = ctx.hitTest(hr.x + hr.w * 0.5, hr.y + hr.h * 0.5);
        try std.testing.expect(h != null);
        try std.testing.expect(nodeIsInSubtree(h, items[idx]));
    }
}

fn nodeIsInSubtree(node: ?*Node, ancestor: *Node) bool {
    var n: ?*Node = node;
    while (n) |cur| : (n = cur.parent) {
        if (cur == ancestor) return true;
    }
    return false;
}

// styles.zig test collection, this line required, see docs/STYLING.md.
test {
    _ = @import("styles.zig");
}

test "accordion: 动态标题 + 互斥 Model 的 mount 在任意分配点失败时不泄漏（sweep）" {
    try @import("../oom_sweep.zig").sweepMount("accordion(exclusive)", struct {
        fn m(scope: *Scope, cx: *Cx) anyerror!?*Node {
            const acc = try Accordion(.{ .open = 0 }).mount(scope, cx);
            errdefer cx.freeNode(acc.container);
            const title = try scope.createText("Section", .{});
            const it = try AccordionItem(.{ .title = title, .expanded = try acc.item(0) }).mount(scope, cx);
            acc.container.appendChild(cx.allocator, it.item) catch |err| {
                cx.freeNode(it.item);
                return err;
            };
            return acc.container;
        }
    }.m);
}

// per-allocation-point OOM sweep, see src/ui/components/oom_sweep.zig.
test "accordion_item: mount 在任意分配点失败时不泄漏（sweep）" {
    try @import("../oom_sweep.zig").sweepMount("accordion_item", struct {
        fn m(scope: *Scope, cx: *Cx) anyerror!?*Node {
            const r = try AccordionItem(.{ .title = "Section", .expanded = true }).mount(scope, cx);
            return r.item;
        }
    }.m);
}

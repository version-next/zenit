//! Cx ↔ 无障碍树：从 interaction 表同步 a11y 树，以及注册给 macOS
//! bridge 的 cxA11y* C-ABI 回调（执行动作 / 设焦点 / 设值 / 文本几何查询）。
//! 投影规则本身在 a11y_projection.zig（不持 *Cx）。

const core = @import("../core.zig");
const Cx = core.Cx;
const cx_input = @import("cx_input.zig");
const cx_platform = @import("cx_platform.zig");
const A11yProps = core.A11yProps;
const ElementId = core.ElementId;
const Node = core.Node;
const a11y_macos_bridge_mod = @import("../a11y/macos_bridge.zig");
const a11y_projection = @import("a11y_projection.zig");
const a11y_router_mod = @import("../a11y/nsaccessibility_router.zig");
const a11y_tree_mod = @import("../a11y/tree.zig");
const core_types = @import("types.zig");

pub fn syncA11yTreeFromInteractions(self: *Cx, root: *Node) void {
    self.a11y_label_buf.clearRetainingCapacity();
    self.accessibility_tree.beginProjection();
    var sibling_counter: u32 = 0;
    syncA11yNodeRecursive(self, root, ElementId.NULL, &sibling_counter, false);
    self.accessibility_tree.finishProjection() catch @panic("OOM: a11y tree stale-node sweep");
    // 把 active 指针注入 macos_bridge, ObjC NSAccessibility 协议方法 (从 C 调进
    // zenit_a11y_*) 会带上自己的 window_id 回来查这张表，多窗口各查各的树。
    // 注册失败只可能是表满（MAX_WINDOWS 个窗口），此时该窗口 a11y 降级为
    // 不可读，但渲染照常，计数出来供诊断，不吞成静默。
    if (!a11y_macos_bridge_mod.setActiveContextWithFullInteractions(
        cx_platform.a11yWindowKey(self),
        &self.accessibility_tree,
        self,
        &cxA11yLabelResolver,
        self,
        &cxA11yPerformAction,
        &cxA11ySetSelection,
        &cxA11ySetFocus,
        &cxA11ySetTextValue,
        &cxA11ySetNumericValue,
        &cxA11yTextFrame,
        &cxA11yTextRangeAtPoint,
    )) {
        core.a11y_context_register_failures +%= 1;
    }
    // Push the complete retained-tree diff to the exact native virtual
    // element. The legacy SystemSdk snapshot path remains available only
    // for callers which invoke it explicitly.
    self.a11y_push_cx_ref.window_id = cx_platform.a11yWindowKey(self);
    self.a11y_push_cx_ref.label_ctx = self;
    self.a11y_push_cx_ref.label_resolver = &cxA11yLabelResolver;
    a11y_router_mod.flushToBridge(
        &self.accessibility_tree,
        a11y_macos_bridge_mod.pushBridge(&self.a11y_push_cx_ref),
    );
}

fn cxA11yLabelResolver(ctx: *anyopaque, hash: u64) ?[]const u8 {
    const self: *Cx = @ptrCast(@alignCast(ctx));
    return self.a11y_label_buf.get(hash);
}

fn findNodeByElementRaw(node: *Node, raw: u32) ?*Node {
    if (node.element_id_raw == raw) return node;
    for (node.children.items) |child| {
        if (findNodeByElementRaw(child, raw)) |found| return found;
    }
    return null;
}

fn cxA11yPerformAction(ctx: *anyopaque, id: ElementId, action: a11y_macos_bridge_mod.Action) bool {
    const self: *Cx = @ptrCast(@alignCast(ctx));
    const root = self.root orelse return false;
    const node = findNodeByElementRaw(root, id.raw()) orelse return false;
    const props = node.behavior.interaction.a11y orelse return false;
    if (props.disabled) return false;

    if (node.behavior.interaction.focusable) self.setFocus(node);
    const rect = node.globalRect();
    const result = switch (action) {
        .press, .toggle => self.dispatcher.dispatch(.{ .click = .{
            .x = rect.x + rect.w / 2,
            .y = rect.y + rect.h / 2,
        } }, node),
        // Native AX increment/decrement is logical, independent of layout
        // direction. Existing widgets already map right/left to their
        // canonical step handlers, so route through the same key pipeline.
        .increment => self.dispatcher.dispatch(.{ .key_down = .{ .key = .right } }, node),
        .decrement => self.dispatcher.dispatch(.{ .key_down = .{ .key = .left } }, node),
    };
    self.needs_redraw = true;
    cx_input.rebuildRuntimeIndexesIfCurrentRootDirty(self);
    return result != .ignored;
}

fn cxA11ySetSelection(ctx: *anyopaque, id: ElementId, start_utf8: u32, end_utf8: u32) bool {
    const self: *Cx = @ptrCast(@alignCast(ctx));
    const root = self.root orelse return false;
    const node = findNodeByElementRaw(root, id.raw()) orelse return false;
    const props = node.behavior.interaction.a11y orelse return false;
    if (props.disabled or props.readonly) return false;
    const editable = props.editable_text orelse return false;
    if (!editable.set_selection(editable.context, start_utf8, end_utf8)) return false;
    if (node.behavior.interaction.focusable) self.setFocus(node);
    node.markRenderDirty();
    self.needs_redraw = true;
    return true;
}

fn cxA11ySetFocus(ctx: *anyopaque, id: ElementId, focused: bool) bool {
    const self: *Cx = @ptrCast(@alignCast(ctx));
    const root = self.root orelse return false;
    const node = findNodeByElementRaw(root, id.raw()) orelse return false;
    const props = node.behavior.interaction.a11y orelse A11yProps{};
    if (focused) {
        if (!node.behavior.interaction.focusable or props.disabled or props.hidden) return false;
        self.setFocus(node);
    } else if (self.focus_manager.getFocused() == node) {
        self.clearFocus();
    } else {
        return false;
    }
    node.markRenderDirty();
    self.needs_redraw = true;
    return true;
}

fn cxA11ySetTextValue(ctx: *anyopaque, id: ElementId, value: []const u8) bool {
    const self: *Cx = @ptrCast(@alignCast(ctx));
    const root = self.root orelse return false;
    const node = findNodeByElementRaw(root, id.raw()) orelse return false;
    const props = node.behavior.interaction.a11y orelse return false;
    if (props.disabled or props.readonly) return false;
    const editable = props.editable_text orelse return false;
    const setter = editable.set_value orelse return false;
    if (!setter(editable.context, value)) return false;
    if (node.behavior.interaction.focusable) self.setFocus(node);
    node.markLayoutDirty();
    self.needs_redraw = true;
    return true;
}

fn cxA11ySetNumericValue(ctx: *anyopaque, id: ElementId, value: f32) bool {
    const self: *Cx = @ptrCast(@alignCast(ctx));
    const root = self.root orelse return false;
    const node = findNodeByElementRaw(root, id.raw()) orelse return false;
    const props = node.behavior.interaction.a11y orelse return false;
    if (props.disabled or props.readonly) return false;
    const range = props.value_range orelse return false;
    const setter_ctx = range.context orelse return false;
    const setter = range.set_value orelse return false;
    if (!setter(setter_ctx, value)) return false;
    if (node.behavior.interaction.focusable) self.setFocus(node);
    node.markRenderDirty();
    self.needs_redraw = true;
    return true;
}

fn cxA11yTextFrame(ctx: *anyopaque, id: ElementId, start_utf8: u32, end_utf8: u32, out: *a11y_tree_mod.Frame) bool {
    const self: *Cx = @ptrCast(@alignCast(ctx));
    const root = self.root orelse return false;
    const node = findNodeByElementRaw(root, id.raw()) orelse return false;
    const props = node.behavior.interaction.a11y orelse return false;
    const editable = props.editable_text orelse return false;
    const callback = editable.frame_for_range orelse return false;
    var rect: core_types.A11yRect = undefined;
    if (!callback(editable.context, start_utf8, end_utf8, &rect)) return false;
    out.* = .{ .x = rect.x, .y = rect.y, .width = rect.width, .height = rect.height };
    return out.isUsable();
}

fn cxA11yTextRangeAtPoint(ctx: *anyopaque, id: ElementId, x: f32, y: f32, start_utf8: *u32, end_utf8: *u32) bool {
    const self: *Cx = @ptrCast(@alignCast(ctx));
    const root = self.root orelse return false;
    const node = findNodeByElementRaw(root, id.raw()) orelse return false;
    const props = node.behavior.interaction.a11y orelse return false;
    const editable = props.editable_text orelse return false;
    const callback = editable.range_at_point orelse return false;
    return callback(editable.context, x, y, start_utf8, end_utf8);
}

fn syncA11yNodeRecursive(self: *Cx, node: *Node, parent_a11y_id: ElementId, sibling_counter: *u32, ancestor_hidden: bool) void {
    a11y_projection.syncSubtree(
        self.allocator,
        &self.accessibility_tree,
        &self.a11y_label_buf,
        node,
        parent_a11y_id,
        sibling_counter,
        ancestor_hidden,
        .{ .ctx = @ptrCast(self), .isFocused = &a11yNodeIsFocused },
    );
}

/// a11y 投影的焦点探针：只读「这个节点是否持焦」。
/// 投影层因此不必 import Cx（见 a11y_projection.zig 模块头）。
fn a11yNodeIsFocused(ctx: ?*const anyopaque, node: *const Node) bool {
    const self: *const Cx = @ptrCast(@alignCast(ctx orelse return false));
    return if (self.focus_manager.current_focus) |fn_node| (fn_node == node) else false;
}

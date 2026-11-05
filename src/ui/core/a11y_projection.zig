//! a11y tree projection (Node -> AccessibilityTree), split out of `Cx`.
//!
//! Three pure functions `mapA11yRoleToTreeRole` / `parseLiveRegion` / `stringHash`, and three
//! projection functions `projectA11yNode` / `syncA11yNodeRecursive` / `firstSubtreeText`.
//! Their **entire** dependence on `Cx` is four items:
//!
//!   * `allocator`, for puts into a11y_label_buf;
//!   * `accessibility_tree`, the target of upsert / remove;
//!   * `a11y_label_buf`, the side lookup table from hash to string;
//!   * `focus_manager.current_focus`, read only for one bool: whether this node holds focus.
//!
//! So projection functions take explicit parameters, not `*Cx`. Focus resolution stays on the Cx
//! side (injected as a `FocusProbe` function pointer, like the Host of text_input_session); the 9
//! `cxA11y*` C-ABI callbacks, macos_bridge context registration and flushToBridge stay in
//! `Cx.syncA11yTreeFromInteractions`, the platform adaptation layer. The `accessibility_tree` /
//! `a11y_label_buf` fields also stay on Cx (many component tests read
//! `cx.accessibility_tree.get(...)` directly).
//!
//! Benefit: these rules can be asserted with a bare Node + an AccessibilityTree, no full
//! "create Cx -> mount -> layout -> render" chain. The per-field tests in this file pin down the
//! regression class where correctly declared component state is dropped (see projectNode).

const std = @import("std");
const Allocator = std.mem.Allocator;

const types = @import("types.zig");
const node_mod = @import("node.zig");
const element_id_mod = @import("element_id.zig");
const a11y_tree_mod = @import("../a11y/tree.zig");

const Node = node_mod.Node;
const ElementId = element_id_mod.ElementId;
const AXId = a11y_tree_mod.AXId;
const A11yProps = types.A11yProps;
const A11yRole = types.A11yRole;

/// Side table from hash to string. A11yNode stores only the hash, not a slice (see the header
/// comment of tree.zig); AT tools read strings back through this table via label_resolver.
///
/// **Strings are always copied into our own arena**, never borrowing the caller's slice. AT pulls
/// happen between two projections (AppKit main-thread run loop callbacks), and a borrowed slice
/// may by then be freed or rewritten: an input's `value_text` points straight at the edit buffer,
/// and `setText` frees the old text. After copying, every string from one projection stays alive
/// until the next projection's `clearRetainingCapacity`, so pulls read a consistent snapshot.
/// Method signatures match the `AutoHashMapUnmanaged` subset
/// (put/get/clearRetainingCapacity/deinit).
pub const LabelStore = struct {
    map: std.AutoHashMapUnmanaged(u64, []const u8) = .{},
    arena_state: std.heap.ArenaAllocator.State = .{},

    pub fn put(self: *LabelStore, allocator: Allocator, hash: u64, str: []const u8) Allocator.Error!void {
        const gop = try self.map.getOrPut(allocator, hash);
        if (gop.found_existing) return;
        var arena = self.arena_state.promote(allocator);
        defer self.arena_state = arena.state;
        gop.value_ptr.* = arena.allocator().dupe(u8, str) catch |err| {
            self.map.removeByPtr(gop.key_ptr);
            return err;
        };
    }

    pub fn get(self: *const LabelStore, hash: u64) ?[]const u8 {
        return self.map.get(hash);
    }

    pub fn count(self: *const LabelStore) usize {
        return self.map.count();
    }

    /// Called at projection start: the old snapshot is invalidated wholesale; the arena keeps
    /// capacity for reuse.
    pub fn clearRetainingCapacity(self: *LabelStore, allocator: Allocator) void {
        self.map.clearRetainingCapacity();
        var arena = self.arena_state.promote(allocator);
        _ = arena.reset(.retain_capacity);
        self.arena_state = arena.state;
    }

    pub fn deinit(self: *LabelStore, allocator: Allocator) void {
        self.map.deinit(allocator);
        self.arena_state.promote(allocator).deinit();
        self.* = .{};
    }
};

/// Alias kept for backward compatibility.
pub const LabelBuf = LabelStore;

/// Focus probe: Cx implements it as a comparison against the `focus_manager.current_focus` pointer.
/// The projection layer does not (and cannot) import Cx, so it is injected, the same way as
/// text_input_session.Host and custom_cursor.RasterizeFn.
pub const FocusProbe = struct {
    ctx: ?*const anyopaque = null,
    isFocused: *const fn (ctx: ?*const anyopaque, node: *const Node) bool,
    isBlocked: ?*const fn (ctx: ?*const anyopaque, node: *const Node) bool = null,
};

/// Maps types.A11yRole -> a11y_tree.Role. The latter is finer-grained (40+ ARIA roles); the
/// former is a 24-variant subset on Node. With no match, falls back to .generic (focusable
/// container) or .none.
pub fn mapA11yRoleToTreeRole(role: A11yRole, focusable: bool) a11y_tree_mod.Role {
    return switch (role) {
        .none => if (focusable) a11y_tree_mod.Role.generic else a11y_tree_mod.Role.none,
        .button => .button,
        .checkbox => .checkbox,
        .radio => .radio,
        .textbox => .textbox,
        // macOS expresses this as AXCheckBox + AXSwitch subrole (window_bridge.m); it gets its own
        // entry
        // in the tree, otherwise the platform layer cannot tell a switch from a checkbox.
        .switch_role => .switch_control,
        .tab => .tab,
        .tablist => .tabs,
        .dialog => .dialog,
        .alert => .alert,
        .menu => .menu,
        .menuitem => .menuitem,
        .listbox => .listbox,
        .option => .listitem,
        .progressbar => .progressbar,
        .slider => .slider,
        .heading => .heading,
        .link => .link,
        .img => .image,
        .list => .list,
        .listitem => .listitem,
        .table => .grid,
        .tooltip => .tooltip,
        // v0.7 §2.5
        .combobox => .combobox,
        .grid => .grid,
        .gridcell => .cell,
        // These roles have identically named counterparts in a11y/tree.zig.
        .tree => .tree,
        .treeitem => .treeitem,
        .row => .row,
        .columnheader => .columnheader,
        .rowheader => .rowheader,
        .menubar => .menubar,
        .menuitemcheckbox => .menuitemcheckbox,
        .menuitemradio => .menuitemradio,
        .spinbutton => .spinbutton,
        .status => .status,
        .group => .group,
        .navigation => .navigation,
        .separator => .separator,
        .region => .region,
        .article => .article,
        .application => .application,
        .radiogroup => .radiogroup,
        .textarea => .textarea,
        .searchbox => .searchbox,
        .tabpanel => .tabpanel,
        .alertdialog => .alertdialog,
        .log => .log,
        .paragraph => .paragraph,
        .section => .section,
        .form => .form,
        .main => .main,
        .banner => .banner,
        .contentinfo => .contentinfo,
        .generic => .generic,
        .scroll_area => .scroll_area,
    };
}

pub fn parseLiveRegion(value: ?[]const u8) a11y_tree_mod.LiveRegion {
    const s = value orelse return .off;
    if (std.mem.eql(u8, s, "polite")) return .polite;
    if (std.mem.eql(u8, s, "assertive")) return .assertive;
    return .off;
}

pub fn stringHash(s: []const u8) u64 {
    if (s.len == 0) return 0;
    return std.hash.Wyhash.hash(0, s);
}

/// Projects a Node into an A11yNode; returns whether it was projected (false = caller should
/// remove).
///
/// false only means 'semantically should not be projected'. An upsert OOM must not be folded into
/// false: the caller would remove a live node that should stay, and it would be projected again
/// next frame, making the AT-side element flicker. Consistent with the remove OOM policy, panic.
///
/// All Cx dependencies are explicit in the parameter list (see module header): tree / label_buf
/// are passed in, and focus is reduced to a bool. hidden is the value **after ancestor
/// propagation** (including the node's own props.hidden), computed by syncSubtree.
pub fn projectNode(
    allocator: Allocator,
    tree: *a11y_tree_mod.AccessibilityTree,
    label_buf: *LabelBuf,
    node: *const Node,
    eid: AXId,
    parent: AXId,
    sibling_index: u32,
    hidden: bool,
    is_focused: bool,
) bool {
    return projectNodeAs(allocator, tree, label_buf, node, node.behavior.interaction.a11y, eid, parent, sibling_index, hidden, is_focused, false);
}

/// Like projectNode, but semantics supplied by caller (inferred roles use this path, see
/// inferredProps).
pub fn projectNodeAs(
    allocator: Allocator,
    tree: *a11y_tree_mod.AccessibilityTree,
    label_buf: *LabelBuf,
    node: *const Node,
    a11y_props: ?A11yProps,
    eid: AXId,
    parent: AXId,
    sibling_index: u32,
    hidden: bool,
    is_focused: bool,
    /// Blocked by modal boundary (modal / outside non-ancestor popup): still presented but semantic
    /// actions disabled.
    blocked: bool,
) bool {
    const focusable = node.behavior.interaction.focusable;
    if (a11y_props == null and !focusable) return false;

    var props = a11y_props orelse A11yProps{};
    props.disabled = props.disabled or blocked;
    const role = mapA11yRoleToTreeRole(props.role, focusable);
    if (role == .none and !focusable) return false;

    // Accessible name (accname): explicit label wins ("" means explicitly no name); else only roles
    // with "name from content" concatenate visible descendant text. Container roles (list/dialog/
    // group...) do not borrow child text as name: their text is already exposed as static_text
    // children, reading twice is wrong. (Old impl named entire VirtualList as "#0".)
    var name_buf: [content_name_capacity]u8 = undefined;
    const label_str = if (props.label) |l|
        l
    else if (nameFromContent(props.role, focusable))
        contentText(node, &name_buf)
    else
        "";
    const label_hash = stringHash(label_str);
    if (label_str.len > 0) {
        // Graceful degradation: a11y_label_buf is hash->string side table, rebuilt entire on each
        // syncA11yTreeFromInteractions clearRetainingCapacity. put OOM only causes this lookup to
        // return null (label unreadable this round), does not damage tree structure; next sync
        // self-heals.
        label_buf.put(allocator, label_hash, label_str) catch {};
    }

    const description_str = props.description orelse "";
    const description_hash = stringHash(description_str);
    if (description_str.len > 0) {
        // Like label: side table, OOM only hides this round, next sync recovers.
        label_buf.put(allocator, description_hash, description_str) catch {};
    }

    const placeholder_str = props.placeholder orelse "";
    const placeholder_hash = stringHash(placeholder_str);
    if (placeholder_str.len > 0) {
        label_buf.put(allocator, placeholder_hash, placeholder_str) catch {};
    }

    const identifier_str = props.identifier orelse "";
    const identifier_hash = stringHash(identifier_str);
    if (identifier_str.len > 0) {
        label_buf.put(allocator, identifier_hash, identifier_str) catch {};
    }

    const value_str = props.value_text orelse "";
    const value_hash = stringHash(value_str);
    if (value_str.len > 0) {
        // Like label: side table, OOM only hides this round, next sync recovers.
        label_buf.put(allocator, value_hash, value_str) catch {};
    }

    const live = parseLiveRegion(props.live);
    const live_text = if (live == .off)
        ""
    else if (props.live_text) |announcement|
        announcement
    else if (props.value_text) |value|
        value
    else if (props.label) |label|
        if (label.len > 0) label else contentText(node, &name_buf)
    else
        contentText(node, &name_buf);
    const live_text_hash = stringHash(live_text);
    if (live_text.len > 0) {
        label_buf.put(allocator, live_text_hash, live_text) catch {};
    }

    // Warning: pressed/required/invalid/readonly/busy/selected/modal/haspopup/multiline/
    // multiselectable and value_now/min/max must be projected from props, never hardcoded
    // (false / 0): otherwise correctly declared component state is silently discarded (e.g.
    // ComboBox/DatePicker/SelectHeadless set has_popup, slider/progressbar report values).
    const a11y_state: a11y_tree_mod.State = .{
        .disabled = props.disabled,
        .checked = if (props.checked) |c| c else false,
        .indeterminate = props.indeterminate,
        .expanded = if (props.expanded) |e| e else false,
        .focused = is_focused,
        .focusable = focusable,
        .pressed = props.pressed,
        .required = props.required,
        .invalid = props.invalid,
        .readonly = props.readonly,
        .busy = props.busy,
        .hidden = hidden,
        .selected = props.selected,
        .modal = props.modal,
        .haspopup = props.has_popup != .none,
        .multiline = props.multiline,
        .multiselectable = props.multiselectable,
        .secure = props.secure,
        .expanded_present = props.expanded != null,
    };

    const local_rect = node.rectFromWorldOrFallback();
    const rect = @import("retained_scene.zig").buildAncestorWorldTransform(node, .{ .include_rotation = true }).transformRect(.{
        .x = 0,
        .y = 0,
        .w = local_rect.w,
        .h = local_rect.h,
    });
    const has_click_route = node.behavior.events.on_click != null or node.behavior.events.on_event != null;
    const has_logical_step = if (props.value_range) |range| range.context != null and range.step != null else false;
    const has_step_route = has_logical_step or node.behavior.events.on_key_down != null or node.behavior.events.on_event != null;
    const toggle_role = role == .checkbox or role == .switch_control or role == .radio or
        role == .menuitemcheckbox or role == .menuitemradio;
    const step_role = role == .slider or role == .spinbutton;
    const editable = if (props.editable_text) |editable_props| a11y_tree_mod.EditableText{
        .selection_start = editable_props.selection_start,
        .selection_end = editable_props.selection_end,
        .caret = editable_props.caret,
        .uniform_format = editable_props.uniform_format,
        .can_scroll = editable_props.scroll_into_view != null and !props.disabled,
        .visible_start = editable_props.visible_start,
        .visible_end = editable_props.visible_end,
        .can_set_selection = !props.disabled,
        .can_set_value = editable_props.set_value != null and !props.disabled and !props.readonly,
    } else null;
    const numeric = props.value_range;

    // active_descendant projection: caller sets
    // node.behavior.interaction.a11y.active_descendant_element_id
    // to current activated child element_id_raw (combobox/listbox/grid virtual-focus mode).
    const active_desc = if (props.active_descendant_element_id == 0xFFFFFFFF)
        AXId.NULL
    else
        AXId.node(ElementId.fromRaw(props.active_descendant_element_id));

    tree.upsert(.{
        .element = eid,
        .parent = parent,
        .role = role,
        .state = a11y_state,
        .live = live,
        .label_hash = label_hash,
        .description_hash = description_hash,
        .placeholder_hash = placeholder_hash,
        .identifier_hash = identifier_hash,
        .text_hash = value_hash,
        .live_text_hash = live_text_hash,
        .value_now = if (numeric) |value| value.now else props.value_now,
        .value_min = if (numeric) |value| value.min else props.value_min,
        .value_max = if (numeric) |value| value.max else props.value_max,
        .value_small_change = if (numeric) |value| validChange(value.small_change) else null,
        .value_large_change = if (numeric) |value| validChange(value.large_change) else null,
        .numeric_value_present = numeric != null or props.value_now != 0 or props.value_min != 0 or props.value_max != 0,
        .can_set_numeric_value = if (numeric) |value|
            value.context != null and value.set_value != null and !props.disabled and !props.readonly
        else
            false,
        .can_set_expanded = props.expanded != null and props.expansion != null and !props.disabled and !props.readonly,
        .can_set_item_selection = props.item_selection != null and !props.disabled and !props.readonly,
        .sibling_index = sibling_index,
        .active_descendant = active_desc,
        .frame = .{ .x = rect.x, .y = rect.y, .width = rect.w, .height = rect.h },
        .actions = .{
            .press = has_click_route,
            .toggle = toggle_role and has_click_route,
            .increment = step_role and has_step_route,
            .decrement = step_role and has_step_route,
        },
        .editable_text = editable,
        .orientation = @fromBackingInt(@intCast(@backingInt(props.orientation))),
        .sort_direction = @fromBackingInt(@intCast(@backingInt(props.sort_direction))),
        .level = props.level,
        .row_index = props.row_index,
        .row_span = @max(props.row_span, 1),
        .column_index = props.column_index,
        .column_span = @max(props.column_span, 1),
        .set_size = props.set_size,
        .pos_in_set = props.pos_in_set,
    }) catch @panic("OOM: a11y tree upsert");
    return true;
}

/// Name concatenation cap. Accessible names are human-readable phrases; long content (full
/// paragraphs) should be exposed as static_text children, not crammed into a control's name.
pub const content_name_capacity = 1024;

/// ARIA 'children presentational': these roles absorb **non-interactive** descendants into
/// themselves instead of exposing them independently. Button text, icons and spinners belong to
/// the button (else a loading button has an unnamed AXProgressIndicator child).
/// Interactive descendants (focusable or roles with click routes) are still exposed; nested
/// interaction is a structure issue that audit will report; the projection layer does not hide it.
pub fn childrenPresentational(role: A11yRole, focusable: bool) bool {
    return switch (role) {
        .button,
        .checkbox,
        .radio,
        .switch_role,
        .tab,
        .menuitem,
        .menuitemcheckbox,
        .menuitemradio,
        .option,
        .link,
        .heading,
        .img,
        .progressbar,
        .slider,
        .spinbutton,
        .textbox,
        .textarea,
        .searchbox,
        .combobox,
        .separator,
        .tooltip,
        .treeitem,
        .gridcell,
        .columnheader,
        .rowheader,
        // List items also absorb own text: real VoiceOver test, row with static text, VO walks into
        // text, skips row, never announces "item N of M". User does not know row is a list item.
        // Interactive elements within row still exposed (see isInteractive).
        .listitem,
        => true,
        // No role but focusable custom control (clickable card): treat as button-style leaf.
        .none, .generic => focusable,
        else => false,
    };
}

/// Name from content: when no explicit label, use visible descendant text as name. Input-class
/// roles absorb descendants but name cannot be from content (would read value or placeholder
/// as control name); containers same way.
pub fn nameFromContent(role: A11yRole, focusable: bool) bool {
    return switch (role) {
        .button,
        .checkbox,
        .radio,
        .switch_role,
        .tab,
        .menuitem,
        .menuitemcheckbox,
        .menuitemradio,
        .option,
        .link,
        .heading,
        .tooltip,
        .treeitem,
        .gridcell,
        .columnheader,
        .rowheader,
        .row,
        .listitem,
        => true,
        .none, .generic => focusable,
        else => false,
    };
}

/// ARIA widget/composite widget roles: declaring them marks interactive elements. Judge by role,
/// not handler: zenit often routes clicks on outer wrapper node (DatePicker trigger has no
/// on_click itself, route on Popover trigger).
pub fn isWidgetRole(role: A11yRole) bool {
    return switch (role) {
        .button,
        .link,
        .checkbox,
        .radio,
        .switch_role,
        .tab,
        .menuitem,
        .menuitemcheckbox,
        .menuitemradio,
        .option,
        .textbox,
        .textarea,
        .searchbox,
        .combobox,
        .slider,
        .spinbutton,
        .treeitem,
        .gridcell,
        .listbox,
        .tree,
        .grid,
        .tablist,
        .menu,
        .menubar,
        .radiogroup,
        => true,
        else => false,
    };
}

/// Interactive nodes: focusable or declare widget role. Only these survive under absorbent
/// ancestors.
fn isInteractive(node: *const Node) bool {
    if (node.behavior.interaction.focusable) return true;
    const props = node.behavior.interaction.a11y orelse return false;
    return isWidgetRole(props.role);
}

fn isSubtreeHiddenSelf(node: *const Node) bool {
    if (node.style.display == .none) return true;
    // Clipped to zero area: content renders zero pixels. Modal hides this way (barrier 0x0 +
    // overflow_hidden, not display:none); else closed dialog still readable (axprobe measured).
    if (node.style.overflow_hidden) {
        const r = node.globalRect();
        if (r.w <= 0 or r.h <= 0) return true;
    }
    const props = node.behavior.interaction.a11y orelse return false;
    return props.hidden;
}

/// Node's own visible text (`.text` content); blank treated as no text.
pub fn ownText(node: *const Node) ?[]const u8 {
    const t = node.getText() orelse return null;
    if (std.mem.trim(u8, t.content, " \t\r\n").len == 0) return null;
    return t.content;
}

/// Semantic inference: unannounced node with click route. Infer button only in "clean" subtree
/// (no declared semantics or interaction anywhere), name from content. Large container around
/// declared content (modal barrier) does not misfire as button, swallowing dialog. Inference is
/// fallback; audit lists every inferred point; components should declare.
pub fn inferredProps(node: *const Node) ?A11yProps {
    return inferredPropsMemo(node, null);
}

/// Only inferredProps implementation. Projection pass memo table: "subtree has declared semantics"
/// calculated once per node per projection. Without memo, deeply nested all-clickable subtree
/// rescans entire tree per layer, worst case Theta(N^2)/frame. Single-call pass null.
fn inferredPropsMemo(node: *const Node, memo: ?*DeclaredMemo) ?A11yProps {
    if (node.behavior.interaction.a11y != null or node.behavior.interaction.focusable) return null;
    // Scroll containers stay as group (AXScrollArea), like native NSScrollView.
    //
    // If all visual containers are flattened, hundreds of elements become window siblings and
    // VoiceOver reorders them by screen position, interleaving sidebar and main content by
    // y-coordinate. Keeping the scroll container as a group makes each a navigation unit.
    if (node.tag == .scroll) return .{ .role = .scroll_area };
    if (node.behavior.events.on_click == null) return null;
    for (node.children.items) |child| {
        if (hasDeclaredSemantics(child, memo)) return null;
    }
    return .{ .role = .button };
}

/// Within one projection, memo of "subtree (including self) has declared semantics or click route".
pub const DeclaredMemo = struct {
    allocator: Allocator,
    map: std.AutoHashMapUnmanaged(*const Node, bool) = .{},

    pub fn deinit(self: *DeclaredMemo) void {
        self.map.deinit(self.allocator);
    }
};

fn hasDeclaredSemantics(node: *const Node, memo: ?*DeclaredMemo) bool {
    if (node.behavior.interaction.a11y != null or node.behavior.interaction.focusable) return true;
    if (node.behavior.events.on_click != null) return true;
    if (memo) |m| {
        if (m.map.get(node)) |cached| return cached;
    }
    var found = false;
    for (node.children.items) |child| {
        if (hasDeclaredSemantics(child, memo)) {
            found = true;
            break;
        }
    }
    // Memo write OOM only loses cache, result still correct.
    if (memo) |m| m.map.put(m.allocator, node, found) catch {};
    return found;
}

/// Concatenate all visible text in subtree (single space sep), skip hidden subtrees and nested
/// interactive nodes (they have own names). Write to `buf`; cap at UTF-8 char boundary.
pub fn contentText(node: *const Node, buf: []u8) []const u8 {
    var len: usize = 0;
    appendContentText(node, buf, &len, true);
    // Truncation may have added sep space; next text not even one byte fits.
    return std.mem.trimEnd(u8, buf[0..len], " ");
}

fn appendContentText(node: *const Node, buf: []u8, len: *usize, is_root: bool) void {
    if (len.* >= buf.len) return;
    if (!is_root and (isSubtreeHiddenSelf(node) or isInteractive(node))) return;
    if (ownText(node)) |text| {
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (len.* > 0 and len.* < buf.len) {
            buf[len.*] = ' ';
            len.* += 1;
        }
        var take = @min(trimmed.len, buf.len - len.*);
        // Truncation mid-multibyte: rewind to char start, ensure output is valid UTF-8.
        while (take < trimmed.len and take > 0 and (trimmed[take] & 0xC0) == 0x80) take -= 1;
        @memcpy(buf[len.*..][0..take], trimmed[0..take]);
        len.* += take;
    }
    for (node.children.items) |child| appendContentText(child, buf, len, false);
}

/// Compat entry: first non-empty text span in subtree.
pub fn firstSubtreeText(node: *const Node) []const u8 {
    if (node.getText()) |t| {
        if (t.content.len > 0) return t.content;
    }
    for (node.children.items) |child| {
        const t = firstSubtreeText(child);
        if (t.len > 0) return t;
    }
    return "";
}

/// Project unlabeled text node as static_text (AXStaticText, value = text content).
pub fn projectStaticText(
    allocator: Allocator,
    tree: *a11y_tree_mod.AccessibilityTree,
    label_buf: *LabelBuf,
    node: *const Node,
    text: []const u8,
    eid: AXId,
    parent: AXId,
    sibling_index: u32,
    hidden: bool,
) bool {
    const value_hash = stringHash(text);
    label_buf.put(allocator, value_hash, text) catch {};
    const rect = node.globalRect();
    tree.upsert(.{
        .element = eid,
        .parent = parent,
        .role = .static_text,
        .state = .{ .hidden = hidden },
        .text_hash = value_hash,
        .sibling_index = sibling_index,
        .frame = .{ .x = rect.x, .y = rect.y, .width = rect.w, .height = rect.h },
    }) catch @panic("OOM: a11y tree upsert");
    return true;
}

/// Recursively sync Node subtree to a11y tree.
///
/// Each node falls into one of three categories:
///  * **Element**: has a11y props or focusable (component-declared semantics);
///  * **Static text**: unlabeled, has visible text, auto-projected as static_text so
///    VoiceOver can read titles and body text;
///  * **None**: pure visual container, flattened, children reparent to nearest projected ancestor.
/// Under an absorbent ancestor (childrenPresentational), non-interactive descendants all flatten.
///
/// Two invariants maintained:
///  * a11y parent = element tree **nearest projected ancestor**;
///  * sibling_index counts **projected** siblings only (unprojected visual containers take no
///    slot).
///
/// Unqualified node: remove. An OOM during remove leaves a stale entry (VoiceOver keeps reading
/// the vanished element, next sync never retries), so OOM panics directly.
pub fn syncSubtree(
    allocator: Allocator,
    tree: *a11y_tree_mod.AccessibilityTree,
    label_buf: *LabelBuf,
    node: *Node,
    parent_a11y_id: AXId,
    sibling_counter: *u32,
    ancestor_hidden: bool,
    focus: FocusProbe,
) void {
    var memo = DeclaredMemo{ .allocator = allocator };
    defer memo.deinit();
    const pass = Pass{
        .allocator = allocator,
        .tree = tree,
        .label_buf = label_buf,
        .modal = ModalScope.find(node),
        .focus = focus,
        .declared = &memo,
    };
    pass.sync(node, parent_a11y_id, sibling_counter, ancestor_hidden, false, pass.modal.modal == null, null);
}

/// Modal scope: visible modal dialog (role dialog/alertdialog, modal=true) latest in document
/// order. While open, nodes outside its subtree and outside ancestors are inert, VoiceOver
/// cannot "exit" dialog reading background.
///
/// Precondition: when multiple modals open, later one also later in doc order. zenit floats
/// append to portal root in order, satisfies this; if future allows inserting float mid-portal,
/// must instead take highest by layer, else topmost dialog inerts itself.
///
/// Done in two passes during projection (find modal, project with scope), not post-modify tree:
/// post would flip hidden true/false each frame, notification storm.
pub const ModalScope = struct {
    modal: ?*const Node = null,
    /// Modal node ancestors (including self). Depth exceeds cap: degrade to "no inert": better
    /// readable background than dialog inerted.
    ancestors: [64]*const Node = undefined,
    ancestor_count: usize = 0,

    pub fn find(root: *const Node) ModalScope {
        var scope = ModalScope{};
        scope.modal = lastVisibleModal(root);
        const modal = scope.modal orelse return scope;
        var cursor: ?*const Node = modal;
        while (cursor) |n| : (cursor = n.parent) {
            if (scope.ancestor_count == scope.ancestors.len) return .{};
            scope.ancestors[scope.ancestor_count] = n;
            scope.ancestor_count += 1;
            if (n == root) break;
        }
        return scope;
    }

    fn isAncestorOrSelf(self: *const ModalScope, node: *const Node) bool {
        for (self.ancestors[0..self.ancestor_count]) |a| {
            if (a == node) return true;
        }
        return false;
    }

    fn lastVisibleModal(node: *const Node) ?*const Node {
        if (isSubtreeHiddenSelf(node)) return null;
        var found: ?*const Node = null;
        if (node.behavior.interaction.a11y) |props| {
            if (props.modal and (props.role == .dialog or props.role == .alertdialog)) found = node;
        }
        for (node.children.items) |child| {
            if (lastVisibleModal(child)) |m| found = m;
        }
        return found;
    }
};

/// Immutable projection context. Passed by pointer, not copied per recursion level (ModalScope
/// has 64 pointers).
const Pass = struct {
    allocator: Allocator,
    tree: *a11y_tree_mod.AccessibilityTree,
    label_buf: *LabelBuf,
    modal: ModalScope,
    focus: FocusProbe,
    declared: *DeclaredMemo,

    fn sync(
        self: *const Pass,
        node: *Node,
        parent_a11y_id: AXId,
        sibling_counter: *u32,
        ancestor_hidden: bool,
        absorbed: bool,
        inside_modal: bool,
        /// Set declared by parent node (non-null only for direct children of set node).
        parent_collection: ?u32,
    ) void {
        var next_parent = parent_a11y_id;
        var child_absorbed = absorbed;
        var child_collection: ?u32 = null;
        var projected = false;
        const node_inside_modal = inside_modal or (self.modal.modal == node);
        // Modal open: subtree outside scope is inert.
        const inert = !node_inside_modal and !self.modal.isAncestorOrSelf(node);
        // display:none subtree and aria-hidden exit a11y tree same way (node present, not
        // rendered).
        const subtree_hidden = ancestor_hidden or inert or isSubtreeHiddenSelf(node);
        if (parent_collection) |collection_idx| {
            if (node.behavior.interaction.a11y) |props| {
                if (props.collection_item) |index| {
                    self.syncCollectionItem(node, collection_idx, index, subtree_hidden, node_inside_modal);
                    return;
                }
            }
        }
        if (node.element_id_raw != 0xFFFFFFFF) {
            const eid = AXId.node(ElementId.fromRaw(node.element_id_raw));
            const inferred = if (absorbed) null else inferredPropsMemo(node, self.declared);
            const semantics: ?A11yProps = node.behavior.interaction.a11y orelse inferred;
            const declared = semantics != null or node.behavior.interaction.focusable;
            const keep = !absorbed or isInteractive(node);
            if (declared and keep) {
                projected = projectNodeAs(self.allocator, self.tree, self.label_buf, node, semantics, eid, parent_a11y_id, sibling_counter.*, subtree_hidden, self.focus.isFocused(self.focus.ctx, node), if (self.focus.isBlocked) |probe| probe(self.focus.ctx, node) else false);
                if (projected) {
                    const props = semantics orelse A11yProps{};
                    child_absorbed = childrenPresentational(props.role, node.behavior.interaction.focusable);
                    if (props.collection) |provider| {
                        child_collection = self.tree.syncCollection(eid, provider, subtree_hidden) catch
                            @panic("OOM: a11y collection sync");
                    }
                }
            } else if (!declared and !absorbed) {
                if (ownText(node)) |text| {
                    projected = projectStaticText(self.allocator, self.tree, self.label_buf, node, text, eid, parent_a11y_id, sibling_counter.*, subtree_hidden);
                }
            }
            if (projected) {
                next_parent = eid;
                sibling_counter.* += 1;
            } else {
                // Correctness path: the node should no longer appear in the a11y tree. A failed
                // remove leaves a stale
                // entry in the tree, and the next sync will not reach here to retry.
                self.tree.remove(eid) catch @panic("OOM: a11y tree remove (stale node projection)");
            }
        }
        // A node that projects an element starts a new sibling order for its children; flattened
        // nodes let
        // children continue the parent's counter (they are siblings of the parent in the a11y
        // tree). Decided by
        // "is projected", not indirectly by ElementId equality (an id collision would mix up
        // counters).
        var child_counter: u32 = 0;
        const counter = if (projected) &child_counter else sibling_counter;
        for (node.children.items) |child| {
            self.sync(child, next_parent, counter, subtree_hidden, child_absorbed, node_inside_modal, child_collection);
        }
    }

    /// Row content container of a collection (pool node): the node itself is not projected, and its
    /// subtree is
    /// projected with the bound entry's cell as parent. When a pool node is rebound, the subtree's
    /// parent moves
    /// from the old cell to the new cell, and the tree's structure-change records emit one
    /// child-change per cell;
    /// the identity of the entry (row / cell) itself is unaffected.
    fn syncCollectionItem(
        self: *const Pass,
        node: *Node,
        collection_idx: u32,
        index: u32,
        subtree_hidden: bool,
        inside_modal: bool,
    ) void {
        if (node.element_id_raw != 0xFFFFFFFF) {
            self.tree.remove(AXId.node(ElementId.fromRaw(node.element_id_raw))) catch
                @panic("OOM: a11y tree remove (collection row host)");
        }
        const cell = self.tree.bindCollectionItem(collection_idx, index) catch |err| switch (err) {
            // A frame where the binding and the data source are out of sync (row count just
            // changed, pool node not yet
            // recycled): do not attach this frame; the unprojected subtree is cleared at the end of
            // this projection
            // and redone with the new binding next frame.
            error.ItemOutOfRange, error.ItemTableFull => return,
            error.OutOfMemory => @panic("OOM: a11y collection bind"),
        };
        // Stamp the owning table on nodes in a row subtree: after an AX callback commits a scroll,
        // their frames
        // shift by the committed offset.
        const outer_host = self.tree.projection_collection_host;
        self.tree.projection_collection_host = self.tree.collections.tableOf(collection_idx);
        defer self.tree.projection_collection_host = outer_host;
        var counter: u32 = 0;
        for (node.children.items) |child| {
            self.sync(child, cell, &counter, subtree_hidden, false, inside_modal, null);
        }
    }
};

// -- Tests --------------------------------------------------------------
//
// All use standalone Nodes (element_id_raw == 0xFFFFFFFF, not attached to any Cx/World):
// eid is an explicit parameter of projectNode, independent of node.element_id_raw, so no Cx,
// element table, or render is needed. content/rect land in the process-level fallback table
// (page_allocator, invisible to the GPA leak check).
// The syncSubtree cases need a non-INVALID element_id_raw (it derives eid from that field);
// see that section's header comment for the tree-building order.

const testing = std.testing;

var g_next_node_id: u32 = 0x9000;
var g_handler_ctx: u8 = 0;
var g_numeric_ctx: u8 = 0;
var g_edit_ctx: u8 = 0;

fn makeNode(tag: types.ElementTag) !*Node {
    g_next_node_id += 1;
    const n = try Node.create(testing.allocator, g_next_node_id, tag, .{});
    // Force standalone mode: even with residual test global hooks in process, always use standalone
    // content/rect storage; clear stale text at reused addresses.
    n.element_id_raw = 0xFFFFFFFF;
    n.world_id = node_mod.INVALID_WORLD_ID;
    n.world_ref = null;
    n.setText(null);
    return n;
}

fn makeBox() !*Node {
    return makeNode(.box);
}

fn makeText(content: []const u8) !*Node {
    const n = try makeNode(.text);
    var t = types.TextProps{};
    t.content = content;
    t.owned = false;
    n.setText(t);
    return n;
}

/// Standalone content table uses node pointer as key, process-level lifetime; without clearing,
/// stale text leaks to subsequent nodes reusing same address; clear recursively before destroy.
fn destroyTree(root: *Node) void {
    clearTextEntries(root);
    root.destroy(testing.allocator);
}

fn clearTextEntries(n: *Node) void {
    if (n.getText() != null) n.setText(null);
    for (n.children.items) |c| clearTextEntries(c);
}

fn makeEid(index: u24) AXId {
    return AXId.node(.{ .index = index, .generation = 1 });
}

/// Look up A11y node by element_id_raw in test.
fn axRaw(raw: u32) AXId {
    return AXId.node(ElementId.fromRaw(raw));
}

fn noopHandler(_: *anyopaque) void {}

fn handlerRef() types.HandlerRef {
    return .{ .callback = noopHandler, .context = @ptrCast(&g_handler_ctx) };
}

fn noopKeyHandler(_: types.KeyCode, _: types.Modifiers, _: ?*anyopaque) types.EventResult {
    return .handled;
}

fn noopEventHandler(_: types.Event, _: ?*anyopaque) types.EventResult {
    return .handled;
}

fn setNumericValue(_: *anyopaque, _: f32) bool {
    return true;
}

fn setSelection(_: *anyopaque, _: u32, _: u32) bool {
    return true;
}

fn setEditTextValue(_: *anyopaque, _: []const u8) bool {
    return true;
}

/// Focus probe: only that node has focus.
fn probeSingle(ctx: ?*const anyopaque, n: *const Node) bool {
    const target: *const Node = @ptrCast(@alignCast(ctx orelse return false));
    return target == n;
}

fn probeOf(target: *const Node) FocusProbe {
    return .{ .ctx = @ptrCast(target), .isFocused = probeSingle };
}

// Pure functions

test "mapA11yRoleToTreeRole: 非同名映射逐一钉住" {
    // Mappings with different names each side; assert each (prevent casual policy changes)
    try testing.expectEqual(a11y_tree_mod.Role.none, mapA11yRoleToTreeRole(.none, false));
    try testing.expectEqual(a11y_tree_mod.Role.switch_control, mapA11yRoleToTreeRole(.switch_role, false));
    try testing.expectEqual(a11y_tree_mod.Role.tabs, mapA11yRoleToTreeRole(.tablist, false));
    try testing.expectEqual(a11y_tree_mod.Role.listitem, mapA11yRoleToTreeRole(.option, false));
    try testing.expectEqual(a11y_tree_mod.Role.grid, mapA11yRoleToTreeRole(.table, false));
    try testing.expectEqual(a11y_tree_mod.Role.cell, mapA11yRoleToTreeRole(.gridcell, false));
    try testing.expectEqual(a11y_tree_mod.Role.image, mapA11yRoleToTreeRole(.img, false));

    // Spot-check same-name mappings (full set in next comptime case)
    try testing.expectEqual(a11y_tree_mod.Role.button, mapA11yRoleToTreeRole(.button, false));
    try testing.expectEqual(a11y_tree_mod.Role.combobox, mapA11yRoleToTreeRole(.combobox, false));
    try testing.expectEqual(a11y_tree_mod.Role.alertdialog, mapA11yRoleToTreeRole(.alertdialog, false));
    try testing.expectEqual(a11y_tree_mod.Role.generic, mapA11yRoleToTreeRole(.generic, false));
}

test "mapA11yRoleToTreeRole: 除 .none 外每个角色都落到非 .none（新增角色不得静默退化）" {
    inline for (@import("zenit_reflection").fields(A11yRole)) |field| {
        if (!std.mem.eql(u8, field.name, "none")) {
            const role: A11yRole = @field(A11yRole, field.name);
            try testing.expect(mapA11yRoleToTreeRole(role, false) != .none);
        }
    }
}

test "mapA11yRoleToTreeRole: focusable 只影响 .none（.generic 容器化），不影响具体角色" {
    try testing.expectEqual(a11y_tree_mod.Role.none, mapA11yRoleToTreeRole(.none, false));
    try testing.expectEqual(a11y_tree_mod.Role.generic, mapA11yRoleToTreeRole(.none, true));
    // focusable=true does not rewrite button to another role
    try testing.expectEqual(a11y_tree_mod.Role.button, mapA11yRoleToTreeRole(.button, true));
    try testing.expectEqual(a11y_tree_mod.Role.switch_control, mapA11yRoleToTreeRole(.switch_role, true));
}

test "parseLiveRegion: null/合法值/非法值" {
    try testing.expectEqual(a11y_tree_mod.LiveRegion.off, parseLiveRegion(null));
    try testing.expectEqual(a11y_tree_mod.LiveRegion.polite, parseLiveRegion("polite"));
    try testing.expectEqual(a11y_tree_mod.LiveRegion.assertive, parseLiveRegion("assertive"));
    try testing.expectEqual(a11y_tree_mod.LiveRegion.off, parseLiveRegion("off"));
    try testing.expectEqual(a11y_tree_mod.LiveRegion.off, parseLiveRegion(""));
    // Case-sensitive: ARIA attribute values are literals authored by components, no normalization
    // here
    try testing.expectEqual(a11y_tree_mod.LiveRegion.off, parseLiveRegion("POLITE"));
    try testing.expectEqual(a11y_tree_mod.LiveRegion.off, parseLiveRegion("rude"));
}

test "stringHash: 空串哨兵 0、确定性、可区分" {
    try testing.expectEqual(@as(u64, 0), stringHash(""));
    try testing.expectEqual(stringHash("Submit"), stringHash("Submit"));
    try testing.expect(stringHash("a") != stringHash("b"));
    try testing.expect(stringHash(" OK") != stringHash("OK"));
}

// projectNode: qualification, role, focus

test "projectNode: 无 a11y props 且不可聚焦 → false（caller 应 remove）" {
    var tree = a11y_tree_mod.AccessibilityTree.init(testing.allocator);
    defer tree.deinit();
    var labels: LabelBuf = .{};
    defer labels.deinit(testing.allocator);

    const n = try makeBox();
    defer destroyTree(n);
    try testing.expect(!projectNode(testing.allocator, &tree, &labels, n, makeEid(1), .NULL, 0, false, false));
    try testing.expectEqual(@as(usize, 0), tree.count());
}

test "projectNode: role=.none 且不可聚焦 → false；role=.none 可聚焦 → .generic 容器" {
    var tree = a11y_tree_mod.AccessibilityTree.init(testing.allocator);
    defer tree.deinit();
    var labels: LabelBuf = .{};
    defer labels.deinit(testing.allocator);

    const n = try makeBox();
    defer destroyTree(n);
    n.behavior.interaction.a11y = .{ .role = .none };
    try testing.expect(!projectNode(testing.allocator, &tree, &labels, n, makeEid(1), .NULL, 0, false, false));

    const f = try makeBox();
    defer destroyTree(f);
    f.behavior.interaction.a11y = .{ .role = .none };
    f.behavior.interaction.focusable = true;
    try testing.expect(projectNode(testing.allocator, &tree, &labels, f, makeEid(2), .NULL, 0, false, false));
    const a = tree.get(makeEid(2)).?;
    try testing.expectEqual(a11y_tree_mod.Role.generic, a.role);
    try testing.expect(a.state.focusable);
}

test "projectNode: 无 props 但 focusable → .generic（VoiceOver 仍可 tab 到）" {
    var tree = a11y_tree_mod.AccessibilityTree.init(testing.allocator);
    defer tree.deinit();
    var labels: LabelBuf = .{};
    defer labels.deinit(testing.allocator);

    const n = try makeBox();
    defer destroyTree(n);
    n.behavior.interaction.focusable = true;
    try testing.expect(projectNode(testing.allocator, &tree, &labels, n, makeEid(1), .NULL, 3, false, false));
    const a = tree.get(makeEid(1)).?;
    try testing.expectEqual(a11y_tree_mod.Role.generic, a.role);
    try testing.expect(a.state.focusable);
    try testing.expectEqual(@as(u32, 3), a.sibling_index);
}

test "projectNode: is_focused 直通 state.focused（未隐藏/未禁用节点）" {
    var tree = a11y_tree_mod.AccessibilityTree.init(testing.allocator);
    defer tree.deinit();
    var labels: LabelBuf = .{};
    defer labels.deinit(testing.allocator);

    const n = try makeBox();
    defer destroyTree(n);
    n.behavior.interaction.a11y = .{ .role = .button, .label = "F" };
    n.behavior.interaction.focusable = true;

    try testing.expect(projectNode(testing.allocator, &tree, &labels, n, makeEid(1), .NULL, 0, false, true));
    try testing.expect(tree.get(makeEid(1)).?.state.focused);

    try testing.expect(projectNode(testing.allocator, &tree, &labels, n, makeEid(2), .NULL, 0, false, false));
    try testing.expect(!tree.get(makeEid(2)).?.state.focused);
}

// projectNode: label/live text parsing

test "projectNode: label 回退到子树文本，显式 label 优先" {
    var tree = a11y_tree_mod.AccessibilityTree.init(testing.allocator);
    defer tree.deinit();
    var labels: LabelBuf = .{};
    defer labels.deinit(testing.allocator);

    const btn = try makeBox();
    defer destroyTree(btn);
    btn.behavior.interaction.a11y = .{ .role = .button };
    const label_text = try makeText("Submit");
    try btn.appendChild(testing.allocator, label_text);

    try testing.expect(projectNode(testing.allocator, &tree, &labels, btn, makeEid(1), .NULL, 0, false, false));
    const a = tree.get(makeEid(1)).?;
    try testing.expectEqual(stringHash("Submit"), a.label_hash);
    try testing.expectEqualStrings("Submit", labels.get(a.label_hash).?);

    // Explicit label wins over child text
    const btn2 = try makeBox();
    defer destroyTree(btn2);
    btn2.behavior.interaction.a11y = .{ .role = .button, .label = "OK" };
    const inner = try makeText("ignored");
    try btn2.appendChild(testing.allocator, inner);
    try testing.expect(projectNode(testing.allocator, &tree, &labels, btn2, makeEid(2), .NULL, 0, false, false));
    try testing.expectEqual(stringHash("OK"), tree.get(makeEid(2)).?.label_hash);
}

test "firstSubtreeText: 自身文本优先；跳过空子节点；深度优先取第一个非空" {
    const root = try makeBox();
    defer destroyTree(root);
    const empty_a = try makeBox();
    const deep = try makeText("deep");
    const sibling_b = try makeText("B");
    try empty_a.appendChild(testing.allocator, deep);
    try root.appendChild(testing.allocator, empty_a);
    try root.appendChild(testing.allocator, sibling_b);
    try testing.expectEqualStrings("deep", firstSubtreeText(root));

    const own = try makeText("own");
    defer destroyTree(own);
    const child = try makeText("child");
    try own.appendChild(testing.allocator, child);
    try testing.expectEqualStrings("own", firstSubtreeText(own));

    const bare = try makeBox();
    defer bare.destroy(testing.allocator);
    try testing.expectEqualStrings("", firstSubtreeText(bare));
}

test "projectNode: live 文本解析优先级 live_text > value_text > label > 子树文本" {
    var tree = a11y_tree_mod.AccessibilityTree.init(testing.allocator);
    defer tree.deinit();
    var labels: LabelBuf = .{};
    defer labels.deinit(testing.allocator);

    // live = off -> no announce text parsed
    const off = try makeBox();
    defer destroyTree(off);
    off.behavior.interaction.a11y = .{ .role = .status, .live_text = "不应被采用" };
    try testing.expect(projectNode(testing.allocator, &tree, &labels, off, makeEid(1), .NULL, 0, false, false));
    const a_off = tree.get(makeEid(1)).?;
    try testing.expectEqual(a11y_tree_mod.LiveRegion.off, a_off.live);
    try testing.expectEqual(@as(u64, 0), a_off.live_text_hash);

    // live_text explicit -> use directly
    const explicit = try makeBox();
    defer destroyTree(explicit);
    explicit.behavior.interaction.a11y = .{
        .role = .alert,
        .live = "assertive",
        .live_text = "Disk full",
        .value_text = "v",
        .label = "l",
    };
    try testing.expect(projectNode(testing.allocator, &tree, &labels, explicit, makeEid(2), .NULL, 0, false, false));
    const a_exp = tree.get(makeEid(2)).?;
    try testing.expectEqual(a11y_tree_mod.LiveRegion.assertive, a_exp.live);
    try testing.expectEqual(stringHash("Disk full"), a_exp.live_text_hash);
    try testing.expectEqualStrings("Disk full", labels.get(a_exp.live_text_hash).?);

    // No live_text -> value_text
    const by_value = try makeBox();
    defer destroyTree(by_value);
    by_value.behavior.interaction.a11y = .{ .role = .status, .live = "polite", .value_text = "3 files" };
    try testing.expect(projectNode(testing.allocator, &tree, &labels, by_value, makeEid(3), .NULL, 0, false, false));
    try testing.expectEqual(stringHash("3 files"), tree.get(makeEid(3)).?.live_text_hash);

    // No live_text/value_text -> non-empty label; empty string label falls through to child text
    const by_label = try makeBox();
    defer destroyTree(by_label);
    by_label.behavior.interaction.a11y = .{ .role = .status, .live = "polite", .label = "Saved" };
    try testing.expect(projectNode(testing.allocator, &tree, &labels, by_label, makeEid(4), .NULL, 0, false, false));
    try testing.expectEqual(stringHash("Saved"), tree.get(makeEid(4)).?.live_text_hash);

    const empty_label = try makeBox();
    defer destroyTree(empty_label);
    empty_label.behavior.interaction.a11y = .{ .role = .status, .live = "polite", .label = "" };
    const t = try makeText("from subtree");
    try empty_label.appendChild(testing.allocator, t);
    try testing.expect(projectNode(testing.allocator, &tree, &labels, empty_label, makeEid(5), .NULL, 0, false, false));
    try testing.expectEqual(stringHash("from subtree"), tree.get(makeEid(5)).?.live_text_hash);
}

test "projectNode: description/placeholder/identifier/value_text 各自入旁路表" {
    var tree = a11y_tree_mod.AccessibilityTree.init(testing.allocator);
    defer tree.deinit();
    var labels: LabelBuf = .{};
    defer labels.deinit(testing.allocator);

    const n = try makeBox();
    defer destroyTree(n);
    n.behavior.interaction.a11y = .{
        .role = .textbox,
        .label = "Email",
        .description = "工作邮箱",
        .placeholder = "name@example.com",
        .identifier = "login-email",
        .value_text = "a@b.c",
    };
    try testing.expect(projectNode(testing.allocator, &tree, &labels, n, makeEid(1), .NULL, 0, false, false));
    const a = tree.get(makeEid(1)).?;
    try testing.expectEqualStrings("工作邮箱", labels.get(a.description_hash).?);
    try testing.expectEqualStrings("name@example.com", labels.get(a.placeholder_hash).?);
    try testing.expectEqualStrings("login-email", labels.get(a.identifier_hash).?);
    try testing.expectEqualStrings("a@b.c", labels.get(a.text_hash).?);
    // Hash of empty description is 0; no empty-string entries should be written
    try testing.expect(labels.get(0) == null);
}

// projectNode: state bits field-by-field (historical regression points, each pinned)

test "projectNode: 状态位逐字段投影（2026-07-31 前曾整批硬编码 false）" {
    var tree = a11y_tree_mod.AccessibilityTree.init(testing.allocator);
    defer tree.deinit();
    var labels: LabelBuf = .{};
    defer labels.deinit(testing.allocator);

    const n = try makeBox();
    defer destroyTree(n);
    n.behavior.interaction.a11y = .{
        .role = .checkbox,
        .label = "All",
        .disabled = true,
        .checked = true,
        .indeterminate = true,
        .expanded = true,
        .selected = true,
        .pressed = true,
        .required = true,
        .invalid = true,
        .readonly = true,
        .busy = true,
        .modal = true,
        .has_popup = .menu,
        .multiline = true,
        .multiselectable = true,
        .secure = true,
    };

    try testing.expect(projectNode(testing.allocator, &tree, &labels, n, makeEid(1), .NULL, 0, true, false));
    const a = tree.get(makeEid(1)).?;
    // Ten bits once hardcoded false
    try testing.expect(a.state.selected);
    try testing.expect(a.state.pressed);
    try testing.expect(a.state.required);
    try testing.expect(a.state.invalid);
    try testing.expect(a.state.readonly);
    try testing.expect(a.state.busy);
    try testing.expect(a.state.modal);
    try testing.expect(a.state.haspopup);
    try testing.expect(a.state.multiline);
    try testing.expect(a.state.multiselectable);
    // Bits that always existed
    try testing.expect(a.state.disabled);
    try testing.expect(a.state.checked);
    try testing.expect(a.state.indeterminate);
    try testing.expect(a.state.expanded);
    try testing.expect(a.state.expanded_present);
    try testing.expect(a.state.secure);
    try testing.expect(a.state.hidden); // hidden param (ancestor-propagated) passes through
    // focused not in assertion: upsert forces zero on disabled/hidden nodes (tree side strategy);
    // pass-through tested separately in "is_focused pass-through" case.
}

test "projectNode: 默认 props 下除 focusable/hidden 外所有状态位为 false" {
    var tree = a11y_tree_mod.AccessibilityTree.init(testing.allocator);
    defer tree.deinit();
    var labels: LabelBuf = .{};
    defer labels.deinit(testing.allocator);

    const n = try makeBox();
    defer destroyTree(n);
    n.behavior.interaction.a11y = .{ .role = .button, .label = "B" };
    try testing.expect(projectNode(testing.allocator, &tree, &labels, n, makeEid(1), .NULL, 0, false, false));
    const a = tree.get(makeEid(1)).?;
    try testing.expect(!a.state.disabled);
    try testing.expect(!a.state.checked);
    try testing.expect(!a.state.indeterminate);
    try testing.expect(!a.state.expanded);
    try testing.expect(!a.state.expanded_present);
    try testing.expect(!a.state.selected);
    try testing.expect(!a.state.pressed);
    try testing.expect(!a.state.required);
    try testing.expect(!a.state.invalid);
    try testing.expect(!a.state.readonly);
    try testing.expect(!a.state.busy);
    try testing.expect(!a.state.modal);
    try testing.expect(!a.state.haspopup);
    try testing.expect(!a.state.multiline);
    try testing.expect(!a.state.multiselectable);
    try testing.expect(!a.state.secure);
    try testing.expect(!a.state.hidden);
    try testing.expect(!a.state.focused);
    try testing.expect(!a.state.focusable);
}

test "projectNode: checked/expanded 的可选三态（null → false；expanded_present 只看是否声明）" {
    var tree = a11y_tree_mod.AccessibilityTree.init(testing.allocator);
    defer tree.deinit();
    var labels: LabelBuf = .{};
    defer labels.deinit(testing.allocator);

    // checked = null / expanded = null: undeclared => false, expanded_present = false
    const undeclared = try makeBox();
    defer destroyTree(undeclared);
    undeclared.behavior.interaction.a11y = .{ .role = .checkbox, .label = "u" };
    try testing.expect(projectNode(testing.allocator, &tree, &labels, undeclared, makeEid(1), .NULL, 0, false, false));
    const a1 = tree.get(makeEid(1)).?;
    try testing.expect(!a1.state.checked);
    try testing.expect(!a1.state.expanded);
    try testing.expect(!a1.state.expanded_present);

    // checked = false (explicitly unchecked) / expanded = false (explicitly collapsed):
    // value still false, but "supports expand" fact must be expressible, expanded_present = true.
    // This distinguishes leaf treeitem from non-expandable element (tree.zig State comment).
    const declared_false = try makeBox();
    defer destroyTree(declared_false);
    declared_false.behavior.interaction.a11y = .{
        .role = .treeitem,
        .label = "d",
        .checked = false,
        .expanded = false,
    };
    try testing.expect(projectNode(testing.allocator, &tree, &labels, declared_false, makeEid(2), .NULL, 0, false, false));
    const a2 = tree.get(makeEid(2)).?;
    try testing.expect(!a2.state.checked);
    try testing.expect(!a2.state.expanded);
    try testing.expect(a2.state.expanded_present);

    // expanded = true
    const declared_true = try makeBox();
    defer destroyTree(declared_true);
    declared_true.behavior.interaction.a11y = .{ .role = .treeitem, .label = "t", .expanded = true };
    try testing.expect(projectNode(testing.allocator, &tree, &labels, declared_true, makeEid(3), .NULL, 0, false, false));
    const a3 = tree.get(makeEid(3)).?;
    try testing.expect(a3.state.expanded);
    try testing.expect(a3.state.expanded_present);
}

// projectNode: numeric values, actions, editable, metadata

test "projectNode: value_range 优先于 legacy value_now/min/max；present 与 setter 门控" {
    var tree = a11y_tree_mod.AccessibilityTree.init(testing.allocator);
    defer tree.deinit();
    var labels: LabelBuf = .{};
    defer labels.deinit(testing.allocator);

    // legacy three fields pass through as-is; any non-zero => present
    const legacy = try makeBox();
    defer destroyTree(legacy);
    legacy.behavior.interaction.a11y = .{
        .role = .slider,
        .label = "L",
        .value_now = 42,
        .value_min = 0,
        .value_max = 100,
    };
    try testing.expect(projectNode(testing.allocator, &tree, &labels, legacy, makeEid(1), .NULL, 0, false, false));
    const a1 = tree.get(makeEid(1)).?;
    try testing.expectEqual(@as(f32, 42), a1.value_now);
    try testing.expectEqual(@as(f32, 0), a1.value_min);
    try testing.expectEqual(@as(f32, 100), a1.value_max);
    try testing.expect(a1.numeric_value_present);
    try testing.expect(!a1.can_set_numeric_value);

    // value_range overrides legacy fields
    const ranged = try makeBox();
    defer destroyTree(ranged);
    ranged.behavior.interaction.a11y = .{
        .role = .slider,
        .label = "R",
        .value_now = 9,
        .value_range = .{ .now = 7, .min = 0, .max = 10 },
    };
    try testing.expect(projectNode(testing.allocator, &tree, &labels, ranged, makeEid(2), .NULL, 0, false, false));
    const a2 = tree.get(makeEid(2)).?;
    try testing.expectEqual(@as(f32, 7), a2.value_now);
    try testing.expectEqual(@as(f32, 0), a2.value_min);
    try testing.expectEqual(@as(f32, 10), a2.value_max);
    try testing.expect(a2.numeric_value_present);
    try testing.expect(!a2.can_set_numeric_value); // No context/set_value

    // All-zero + no range => not present (valid zero range vs undeclared value)
    const none = try makeBox();
    defer destroyTree(none);
    none.behavior.interaction.a11y = .{ .role = .progressbar, .label = "N" };
    try testing.expect(projectNode(testing.allocator, &tree, &labels, none, makeEid(3), .NULL, 0, false, false));
    try testing.expect(!tree.get(makeEid(3)).?.numeric_value_present);

    // setter + context + not disabled/readonly -> can_set_numeric_value
    const settable = try makeBox();
    defer destroyTree(settable);
    settable.behavior.interaction.a11y = .{
        .role = .slider,
        .label = "S",
        .value_range = .{
            .now = 1,
            .min = 0,
            .max = 2,
            .context = @ptrCast(&g_numeric_ctx),
            .set_value = setNumericValue,
        },
    };
    try testing.expect(projectNode(testing.allocator, &tree, &labels, settable, makeEid(4), .NULL, 0, false, false));
    try testing.expect(tree.get(makeEid(4)).?.can_set_numeric_value);

    // disabled or readonly shuts off setter path
    var disabled_props = settable.behavior.interaction.a11y.?;
    disabled_props.disabled = true;
    settable.behavior.interaction.a11y = disabled_props;
    try testing.expect(projectNode(testing.allocator, &tree, &labels, settable, makeEid(5), .NULL, 0, false, false));
    try testing.expect(!tree.get(makeEid(5)).?.can_set_numeric_value);
}

test "projectNode: actions 只按「角色 × 实际可路由的回调」宣告" {
    var tree = a11y_tree_mod.AccessibilityTree.init(testing.allocator);
    defer tree.deinit();
    var labels: LabelBuf = .{};
    defer labels.deinit(testing.allocator);

    // button + on_click -> press; button not toggle role -> toggle off
    const btn = try makeBox();
    defer destroyTree(btn);
    btn.behavior.interaction.a11y = .{ .role = .button, .label = "B" };
    btn.behavior.events.on_click = handlerRef();
    try testing.expect(projectNode(testing.allocator, &tree, &labels, btn, makeEid(1), .NULL, 0, false, false));
    const a1 = tree.get(makeEid(1)).?;
    try testing.expect(a1.actions.press);
    try testing.expect(!a1.actions.toggle);
    try testing.expect(!a1.actions.increment);

    // button with no event route: must not declare press to AT
    const dead = try makeBox();
    defer destroyTree(dead);
    dead.behavior.interaction.a11y = .{ .role = .button, .label = "D" };
    try testing.expect(projectNode(testing.allocator, &tree, &labels, dead, makeEid(2), .NULL, 0, false, false));
    try testing.expect(!tree.get(makeEid(2)).?.actions.press);

    // checkbox + on_click -> toggle; radio/menuitemcheckbox/menuitemradio similar
    const cb = try makeBox();
    defer destroyTree(cb);
    cb.behavior.interaction.a11y = .{ .role = .checkbox, .label = "C" };
    cb.behavior.events.on_click = handlerRef();
    try testing.expect(projectNode(testing.allocator, &tree, &labels, cb, makeEid(3), .NULL, 0, false, false));
    try testing.expect(tree.get(makeEid(3)).?.actions.toggle);

    // slider + on_key_down -> increment/decrement
    const slider = try makeBox();
    defer destroyTree(slider);
    slider.behavior.interaction.a11y = .{ .role = .slider, .label = "S" };
    slider.behavior.events.on_key_down = noopKeyHandler;
    try testing.expect(projectNode(testing.allocator, &tree, &labels, slider, makeEid(4), .NULL, 0, false, false));
    const a4 = tree.get(makeEid(4)).?;
    try testing.expect(a4.actions.increment);
    try testing.expect(a4.actions.decrement);

    // slider no key route: must not declare increment (AT sends unreceived command)
    const passive = try makeBox();
    defer destroyTree(passive);
    passive.behavior.interaction.a11y = .{ .role = .slider, .label = "P" };
    try testing.expect(projectNode(testing.allocator, &tree, &labels, passive, makeEid(5), .NULL, 0, false, false));
    const a5 = tree.get(makeEid(5)).?;
    try testing.expect(!a5.actions.increment);
    try testing.expect(!a5.actions.decrement);

    // spinbutton likewise step role
    const spin = try makeBox();
    defer destroyTree(spin);
    spin.behavior.interaction.a11y = .{ .role = .spinbutton, .label = "N" };
    spin.behavior.events.on_event = noopEventHandler;
    try testing.expect(projectNode(testing.allocator, &tree, &labels, spin, makeEid(6), .NULL, 0, false, false));
    try testing.expect(tree.get(makeEid(6)).?.actions.increment);
}

test "projectNode: editable_text 选区透传，只读保留选区，disabled 关闭动作" {
    var tree = a11y_tree_mod.AccessibilityTree.init(testing.allocator);
    defer tree.deinit();
    var labels: LabelBuf = .{};
    defer labels.deinit(testing.allocator);

    const editableProps = types.A11yProps.EditableText{
        .context = @ptrCast(&g_edit_ctx),
        .selection_start = 2,
        .selection_end = 5,
        .caret = 4,
        .uniform_format = true,
        .visible_start = 1,
        .visible_end = 9,
        .set_selection = setSelection,
    };

    const n = try makeBox();
    defer destroyTree(n);
    n.behavior.interaction.a11y = .{ .role = .textbox, .label = "T", .editable_text = editableProps };
    try testing.expect(projectNode(testing.allocator, &tree, &labels, n, makeEid(1), .NULL, 0, false, false));
    const e1 = tree.get(makeEid(1)).?.editable_text.?;
    try testing.expectEqual(@as(u32, 2), e1.selection_start);
    try testing.expectEqual(@as(u32, 5), e1.selection_end);
    try testing.expectEqual(@as(u32, 4), e1.caret);
    try testing.expectEqual(@as(u32, 1), e1.visible_start);
    try testing.expectEqual(@as(u32, 9), e1.visible_end);
    try testing.expect(e1.uniform_format);
    try testing.expect(e1.can_set_selection); // Not disabled/readonly
    try testing.expect(!e1.can_set_value); // set_value not published

    // set_value published -> can_set_value
    const n2 = try makeBox();
    defer destroyTree(n2);
    var with_setter = editableProps;
    with_setter.set_value = setEditTextValue;
    n2.behavior.interaction.a11y = .{ .role = .textbox, .label = "T2", .editable_text = with_setter };
    try testing.expect(projectNode(testing.allocator, &tree, &labels, n2, makeEid(2), .NULL, 0, false, false));
    const e2 = tree.get(makeEid(2)).?.editable_text.?;
    try testing.expect(e2.can_set_value);
    try testing.expect(e2.can_set_selection);

    // disabled shuts both paths; readonly only text write
    const n3 = try makeBox();
    defer destroyTree(n3);
    var disabled = editableProps;
    disabled.set_value = setEditTextValue;
    n3.behavior.interaction.a11y = .{
        .role = .textbox,
        .label = "T3",
        .editable_text = disabled,
        .disabled = true,
    };
    try testing.expect(projectNode(testing.allocator, &tree, &labels, n3, makeEid(3), .NULL, 0, false, false));
    const e3 = tree.get(makeEid(3)).?.editable_text.?;
    try testing.expect(!e3.can_set_selection);
    try testing.expect(!e3.can_set_value);

    const n4 = try makeBox();
    defer destroyTree(n4);
    n4.behavior.interaction.a11y = .{
        .role = .textbox,
        .label = "T4",
        .editable_text = editableProps,
        .readonly = true,
    };
    try testing.expect(projectNode(testing.allocator, &tree, &labels, n4, makeEid(4), .NULL, 0, false, false));
    try testing.expect(tree.get(makeEid(4)).?.editable_text.?.can_set_selection);
    try testing.expect(!tree.get(makeEid(4)).?.editable_text.?.can_set_value);

    // editable_text not published (textbox role only) -> null; platform bridge must fail closed
    const n5 = try makeBox();
    defer destroyTree(n5);
    n5.behavior.interaction.a11y = .{ .role = .textbox, .label = "T5" };
    try testing.expect(projectNode(testing.allocator, &tree, &labels, n5, makeEid(5), .NULL, 0, false, false));
    try testing.expect(tree.get(makeEid(5)).?.editable_text == null);
}

test "projectNode: active_descendant / 表格元数据 / orientation / frame" {
    var tree = a11y_tree_mod.AccessibilityTree.init(testing.allocator);
    defer tree.deinit();
    var labels: LabelBuf = .{};
    defer labels.deinit(testing.allocator);

    const n = try makeBox();
    defer destroyTree(n);
    n.behavior.interaction.a11y = .{
        .role = .gridcell,
        .label = "cell",
        .active_descendant_element_id = 0x00000A05,
        .orientation = .horizontal,
        .sort_direction = .ascending,
        .level = 3,
        .row_index = 2,
        .row_span = 0, // 0 must be clamped to 1
        .column_index = 4,
        .column_span = 0,
    };
    n.setLayoutRect(.{ .x = 10, .y = 20, .w = 30, .h = 40 });
    try testing.expect(projectNode(testing.allocator, &tree, &labels, n, makeEid(1), .NULL, 0, false, false));
    const a = tree.get(makeEid(1)).?;
    try testing.expect(a.active_descendant.eql(axRaw(0x00000A05)));
    try testing.expectEqual(a11y_tree_mod.Orientation.horizontal, a.orientation);
    try testing.expectEqual(a11y_tree_mod.SortDirection.ascending, a.sort_direction);
    try testing.expectEqual(@as(u16, 3), a.level);
    try testing.expectEqual(@as(u32, 2), a.row_index);
    try testing.expectEqual(@as(u32, 1), a.row_span);
    try testing.expectEqual(@as(u32, 4), a.column_index);
    try testing.expectEqual(@as(u32, 1), a.column_span);
    // globalRect: x/y accumulate self rect via ancestor chain (no parent => own rect)
    try testing.expectEqual(@as(f32, 10), a.frame.x);
    try testing.expectEqual(@as(f32, 20), a.frame.y);
    try testing.expectEqual(@as(f32, 30), a.frame.width);
    try testing.expectEqual(@as(f32, 40), a.frame.height);

    // One-level nesting: child frame x/y = ancestor sum + self (globalRect semantics).
    // child reparents under parent, destroy walks parent only (recursive).
    const parent = try makeBox();
    defer destroyTree(parent);
    parent.setLayoutRect(.{ .x = 10, .y = 20, .w = 100, .h = 50 });
    const child = try makeBox();
    child.setLayoutRect(.{ .x = 5, .y = 6, .w = 7, .h = 8 });
    child.behavior.interaction.a11y = .{ .role = .button, .label = "c" };
    try parent.appendChild(testing.allocator, child);
    try testing.expect(projectNode(testing.allocator, &tree, &labels, child, makeEid(3), .NULL, 0, false, false));
    const nested = tree.get(makeEid(3)).?;
    try testing.expectEqual(@as(f32, 15), nested.frame.x);
    try testing.expectEqual(@as(f32, 26), nested.frame.y);
    try testing.expectEqual(@as(f32, 7), nested.frame.width);
    try testing.expectEqual(@as(f32, 8), nested.frame.height);

    // Match render composition through a nonsemantic ancestor, including
    // translation, nonuniform scale and a reflected child with a custom origin.
    parent.style.ensureExtPanic(testing.allocator).scale_x = 2;
    parent.style.ensureExtPanic(testing.allocator).scale_y = 3;
    parent.style.ensureExtPanic(testing.allocator).transform_origin = types.TransformOrigin.topLeft();
    parent.style.translate_x = 3;
    parent.style.translate_y = 4;
    child.style.ensureExtPanic(testing.allocator).scale_x = -0.5;
    child.style.ensureExtPanic(testing.allocator).scale_y = 0.5;
    child.style.ensureExtPanic(testing.allocator).transform_origin = types.TransformOrigin.topLeft();
    child.style.translate_x = 2;
    child.style.translate_y = 3;
    try testing.expect(projectNode(testing.allocator, &tree, &labels, child, makeEid(3), .NULL, 0, false, false));
    const scaled_frame = tree.get(makeEid(3)).?.frame;
    try testing.expectEqual(@as(f32, 20), scaled_frame.x);
    try testing.expectEqual(@as(f32, 51), scaled_frame.y);
    try testing.expectEqual(@as(f32, 7), scaled_frame.width);
    try testing.expectEqual(@as(f32, 12), scaled_frame.height);

    // 0xFFFFFFFF sentinel -> NULL (no active descendant)
    const n2 = try makeBox();
    defer destroyTree(n2);
    n2.behavior.interaction.a11y = .{ .role = .combobox, .label = "cb" };
    try testing.expect(projectNode(testing.allocator, &tree, &labels, n2, makeEid(2), .NULL, 0, false, false));
    try testing.expect(tree.get(makeEid(2)).?.active_descendant.isNull());
}

// syncSubtree: hierarchy, order, hidden propagation, stale sweep
//
// These cases need non-INVALID node.element_id_raw (syncSubtree derives eid from that field).
// Build order: **first build the full parent-child tree in all-INVALID state, then assign
// element_id_raw uniformly**. appendChild/markLayoutDirty early-exit on INVALID before touching
// global callbacks, so tests don't depend on the current g_active_world.

test "syncSubtree: parent 是最近已投影祖先，sibling_index 只数已投影节点" {
    var tree = a11y_tree_mod.AccessibilityTree.init(testing.allocator);
    defer tree.deinit();
    var labels: LabelBuf = .{};
    defer labels.deinit(testing.allocator);

    const root = try makeBox();
    defer destroyTree(root);

    // Unprojected pure visual container (no a11y, not focusable)
    const plain = try makeBox();

    // first is container role: button-class roles absorb non-interactive descendants
    // (see childrenPresentational); test hierarchy and sibling order, not absorption.
    const first = try makeBox();
    first.behavior.interaction.a11y = .{ .role = .group, .label = "one" };

    const second = try makeBox();
    second.behavior.interaction.a11y = .{ .role = .button, .label = "two" };

    // first's subtree has another unprojected layer + one qualified node
    const wrapper = try makeBox();
    const inner = try makeBox();
    inner.behavior.interaction.a11y = .{ .role = .button, .label = "inner" };

    try wrapper.appendChild(testing.allocator, inner);
    try first.appendChild(testing.allocator, wrapper);
    try root.appendChild(testing.allocator, plain);
    try root.appendChild(testing.allocator, first);
    try root.appendChild(testing.allocator, second);

    // Assign element id after tree built (see section header).
    root.element_id_raw = 0x00000001;
    plain.element_id_raw = 0x00000002;
    first.element_id_raw = 0x00000003;
    second.element_id_raw = 0x00000004;
    wrapper.element_id_raw = 0x00000005;
    inner.element_id_raw = 0x00000006;
    root.behavior.interaction.a11y = .{ .role = .group, .label = "root" };

    var counter: u32 = 0;
    syncSubtree(testing.allocator, &tree, &labels, root, .NULL, &counter, false, .{ .isFocused = neverFocused });

    try testing.expectEqual(@as(usize, 4), tree.count()); // root/one/two/inner
    const root_eid = axRaw(0x00000001);
    const one_eid = axRaw(0x00000003);
    const two_eid = axRaw(0x00000004);
    const inner_eid = axRaw(0x00000006);

    try testing.expect(tree.get(axRaw(0x00000002)) == null); // Not projected
    try testing.expect(tree.get(one_eid).?.parent.eql(root_eid));
    try testing.expect(tree.get(two_eid).?.parent.eql(root_eid));
    // plain does not occupy slot: one is 0, two is 1
    try testing.expectEqual(@as(u32, 0), tree.get(one_eid).?.sibling_index);
    try testing.expectEqual(@as(u32, 1), tree.get(two_eid).?.sibling_index);
    try testing.expectEqual(@as(u32, 0), tree.get(root_eid).?.sibling_index);
    // wrapper not projected -> inner's a11y parent is first, in own sibling sequence from 0
    try testing.expect(tree.get(inner_eid).?.parent.eql(one_eid));
    try testing.expectEqual(@as(u32, 0), tree.get(inner_eid).?.sibling_index);
}

test "syncSubtree: 祖先 hidden 传播给整个子树（即使后代自身未声明）" {
    var tree = a11y_tree_mod.AccessibilityTree.init(testing.allocator);
    defer tree.deinit();
    var labels: LabelBuf = .{};
    defer labels.deinit(testing.allocator);

    const root = try makeBox();
    defer destroyTree(root);

    const child = try makeBox();
    // Container role: button absorbs non-interactive descendants; test hidden propagation.
    child.behavior.interaction.a11y = .{ .role = .group, .label = "B" }; // Self does not declare hidden

    const grandchild = try makeBox();
    grandchild.behavior.interaction.a11y = .{ .role = .button, .label = "C" };

    try child.appendChild(testing.allocator, grandchild);
    try root.appendChild(testing.allocator, child);

    root.element_id_raw = 0x00000011;
    child.element_id_raw = 0x00000012;
    grandchild.element_id_raw = 0x00000013;

    root.behavior.interaction.a11y = .{ .role = .group, .label = "G", .hidden = true };
    var counter: u32 = 0;
    syncSubtree(testing.allocator, &tree, &labels, root, .NULL, &counter, false, .{ .isFocused = neverFocused });

    try testing.expect(tree.get(axRaw(0x00000011)).?.state.hidden);
    try testing.expect(tree.get(axRaw(0x00000012)).?.state.hidden);
    try testing.expect(tree.get(axRaw(0x00000013)).?.state.hidden);

    // Control: same tree without ancestor hidden, descendants not hidden
    var tree2 = a11y_tree_mod.AccessibilityTree.init(testing.allocator);
    defer tree2.deinit();
    var labels2: LabelBuf = .{};
    defer labels2.deinit(testing.allocator);
    var counter2: u32 = 0;
    root.behavior.interaction.a11y = .{ .role = .group, .label = "G" };
    syncSubtree(testing.allocator, &tree2, &labels2, root, .NULL, &counter2, false, .{ .isFocused = neverFocused });
    try testing.expect(!tree2.get(axRaw(0x00000012)).?.state.hidden);
    try testing.expect(!tree2.get(axRaw(0x00000013)).?.state.hidden);
}

test "syncSubtree: 不再合格的节点被 remove（陈旧条目不能留给 VoiceOver）" {
    var tree = a11y_tree_mod.AccessibilityTree.init(testing.allocator);
    defer tree.deinit();
    var labels: LabelBuf = .{};
    defer labels.deinit(testing.allocator);

    const root = try makeBox();
    defer destroyTree(root);
    root.behavior.interaction.a11y = .{ .role = .button, .label = "B" };
    root.element_id_raw = 0x00000021;

    var counter: u32 = 0;
    syncSubtree(testing.allocator, &tree, &labels, root, .NULL, &counter, false, .{ .isFocused = neverFocused });
    try testing.expectEqual(@as(usize, 1), tree.count());

    // Node loses a11y props and focusable -> next sync must remove it
    root.behavior.interaction.a11y = null;
    root.behavior.interaction.focusable = false;
    var counter2: u32 = 0;
    syncSubtree(testing.allocator, &tree, &labels, root, .NULL, &counter2, false, .{ .isFocused = neverFocused });
    try testing.expectEqual(@as(usize, 0), tree.count());
    try testing.expect(tree.get(axRaw(0x00000021)) == null);
}

test "syncSubtree: FocusProbe 决定 state.focused（Cx 侧只注入一次比较）" {
    var tree = a11y_tree_mod.AccessibilityTree.init(testing.allocator);
    defer tree.deinit();
    var labels: LabelBuf = .{};
    defer labels.deinit(testing.allocator);

    const root = try makeBox();
    defer destroyTree(root);

    const a = try makeBox();
    a.behavior.interaction.a11y = .{ .role = .button, .label = "A" };

    const b = try makeBox();
    b.behavior.interaction.a11y = .{ .role = .button, .label = "B" };

    try root.appendChild(testing.allocator, a);
    try root.appendChild(testing.allocator, b);

    root.element_id_raw = 0x00000031;
    a.element_id_raw = 0x00000032;
    b.element_id_raw = 0x00000033;
    root.behavior.interaction.a11y = .{ .role = .group, .label = "G" };

    var counter: u32 = 0;
    syncSubtree(testing.allocator, &tree, &labels, root, .NULL, &counter, false, probeOf(a));

    try testing.expect(tree.get(axRaw(0x00000032)).?.state.focused);
    try testing.expect(!tree.get(axRaw(0x00000033)).?.state.focused);
}

fn neverFocused(_: ?*const anyopaque, _: *const Node) bool {
    return false;
}

// Semantic merging, static text, inferred button, sibling order
//
// These cases pin issues found on a real app via the external AXUIElement probe (tools/axprobe):
//  * text nodes not projected: titles and click counts invisible to VoiceOver;
//  * loading button had an unnamed AXProgressIndicator beneath (button did not absorb descendants);
//  * nav item readable but not clickable (on_click exists, no semantic declared);
//  * button matrix read by "column" (flattening layer reset sibling sequence to 0).
// Cases needing text content live in core/tests.zig (real Cx: once a node has an element id,
// text reads go through the process-level World hook, so results depend on prior global state).

fn assignIds(nodes: []const *Node, first: u32) void {
    for (nodes, 0..) |n, i| n.element_id_raw = first + @as(u32, @intCast(i));
}

test "syncSubtree: 多个扁平化包装层下的兄弟序连续（不再按列朗读）" {
    var tree = a11y_tree_mod.AccessibilityTree.init(testing.allocator);
    defer tree.deinit();
    var labels: LabelBuf = .{};
    defer labels.deinit(testing.allocator);

    // root(group) -> row1(plain) -> [a1, a2]; row2(plain) -> [b1, b2]
    const root = try makeBox();
    defer destroyTree(root);
    const row1 = try makeBox();
    const row2 = try makeBox();
    const a1 = try makeBox();
    const a2 = try makeBox();
    const b1 = try makeBox();
    const b2 = try makeBox();
    for ([_]*Node{ a1, a2, b1, b2 }) |n| n.behavior.interaction.a11y = .{ .role = .button, .label = "x" };
    try row1.appendChild(testing.allocator, a1);
    try row1.appendChild(testing.allocator, a2);
    try row2.appendChild(testing.allocator, b1);
    try row2.appendChild(testing.allocator, b2);
    try root.appendChild(testing.allocator, row1);
    try root.appendChild(testing.allocator, row2);
    assignIds(&.{ root, row1, row2, a1, a2, b1, b2 }, 0x100);
    root.behavior.interaction.a11y = .{ .role = .group, .label = "matrix" };

    var counter: u32 = 0;
    syncSubtree(testing.allocator, &tree, &labels, root, .NULL, &counter, false, .{ .isFocused = neverFocused });

    const kids = tree.exposedChildren(axRaw(0x100));
    try testing.expectEqual(@as(usize, 4), kids.len);
    // Doc order: a1 a2 b1 b2. Old impl recount from 0 per wrapper layer, reordered to a1 b1 a2 b2.
    try testing.expect(kids[0].eql(axRaw(a1.element_id_raw)));
    try testing.expect(kids[1].eql(axRaw(a2.element_id_raw)));
    try testing.expect(kids[2].eql(axRaw(b1.element_id_raw)));
    try testing.expect(kids[3].eql(axRaw(b2.element_id_raw)));
}

test "contentText: 拼接可见文字、跳过隐藏与嵌套交互、截断落在 UTF-8 边界" {
    const root = try makeBox();
    defer destroyTree(root);
    const first = try makeText(" 保存 ");
    const hidden = try makeText("SECRET");
    hidden.behavior.interaction.a11y = .{ .hidden = true };
    const nested = try makeBox();
    nested.behavior.interaction.a11y = .{ .role = .button, .label = "close" };
    const nested_text = try makeText("×");
    try nested.appendChild(testing.allocator, nested_text);
    const second = try makeText("draft");
    try root.appendChild(testing.allocator, first);
    try root.appendChild(testing.allocator, hidden);
    try root.appendChild(testing.allocator, nested);
    try root.appendChild(testing.allocator, second);

    var buf: [content_name_capacity]u8 = undefined;
    try testing.expectEqualStrings("保存 draft", contentText(root, &buf));

    // Capacity 4: fits 'bao' (3 bytes), not 'cun'; cannot cut mid-char.
    var tiny: [4]u8 = undefined;
    const cut = contentText(root, &tiny);
    try testing.expect(std.unicode.utf8ValidateSlice(cut));
    try testing.expectEqualStrings("保", cut);
}

test "LabelStore: put 复制字符串，源缓冲区之后被改写也读到投影时的值" {
    var store: LabelStore = .{};
    defer store.deinit(testing.allocator);
    var source = "editing".*;
    const h = stringHash(&source);
    try store.put(testing.allocator, h, &source);
    // Simulate input edit buffer modified between projections (old impl borrowed slice, AT read
    // stale).
    @memcpy(&source, "XXXXXXX");
    try testing.expectEqualStrings("editing", store.get(h).?);

    store.clearRetainingCapacity(testing.allocator);
    try testing.expect(store.get(h) == null);
    try store.put(testing.allocator, h, "again");
    try testing.expectEqualStrings("again", store.get(h).?);
}

test "syncSubtree: 深层全部可点的嵌套里，带备忘的推断与逐层重扫结论一致" {
    var tree = a11y_tree_mod.AccessibilityTree.init(testing.allocator);
    defer tree.deinit();
    var labels: LabelBuf = .{};
    defer labels.deinit(testing.allocator);

    // root(group) -> c0 -> c1 -> ... -> c39, each layer only click route, no declared semantics.
    const depth = 40;
    var chain: [depth]*Node = undefined;
    const root = try makeBox();
    defer destroyTree(root);
    var parent = root;
    for (&chain) |*slot| {
        const n = try makeBox();
        n.behavior.events.on_click = handlerRef();
        try parent.appendChild(testing.allocator, n);
        slot.* = n;
        parent = n;
    }
    root.element_id_raw = 0x500;
    for (chain, 0..) |n, i| n.element_id_raw = 0x501 + @as(u32, @intCast(i));
    root.behavior.interaction.a11y = .{ .role = .group, .label = "chain" };

    var counter: u32 = 0;
    syncSubtree(testing.allocator, &tree, &labels, root, .NULL, &counter, false, .{ .isFocused = neverFocused });

    // Only innermost (clean subtree) inferred as button; outer layers each have click route in
    // subtree, not inferred.
    for (chain[0 .. depth - 1]) |n| {
        try testing.expect(tree.get(axRaw(n.element_id_raw)) == null);
        try testing.expect(inferredProps(n) == null);
    }
    const leaf = chain[depth - 1];
    try testing.expectEqual(a11y_tree_mod.Role.button, tree.get(axRaw(leaf.element_id_raw)).?.role);
    try testing.expectEqual(A11yRole.button, inferredProps(leaf).?.role);
}

fn validChange(change: ?f32) ?f32 {
    const value = change orelse return null;
    return if (std.math.isFinite(value) and value >= 0) value else null;
}

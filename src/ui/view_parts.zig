//! Protocol type for components to integrate with `ui.view` declarative tree (in a separate file:
//! components depend only on this small type, not on the view DSL implementation).
//!
//! `ui.view` needs two pieces of information when using a component builder as a child element:
//!   - which node to attach to the parent (`root`);
//!   - where child elements of `ui.view.with(component, .{ children... })` attach (`slot`).
//!
//! Components with `mount` returning `*Node` directly need no extra work (root = return value, no
//! slot).
//! Components returning a Result struct provide:
//!
//! ```zig
//! pub fn viewParts(self: ScrollAreaResult) ViewParts {
//!     return .{ .root = self.container, .slot = self.content };
//! }
//! ```
//!
//! Components with alternate mounting methods (like Card's `mountBody`) that support slots provide
//! `pub fn viewMount(self, scope, cx) !ViewParts` on the builder, which takes precedence over
//! `mount`.
const std = @import("std");
const Node = @import("core/node.zig").Node;
const Scope = @import("reactive/scope.zig").Scope;

/// Slot insertion point: children insert into `parent` before `before` (null = end).
pub const SlotPoint = struct { parent: *Node, before: ?*Node = null };
/// Named slot (Yix component `header: View` param, `ui.view.with(...).slots(.{ .header = ... })`)
pub const NamedSlot = struct { name: []const u8, at: SlotPoint };
pub const max_named_slots = 4;

/// Named slots the caller actually filled for one mount (`?View` slots in Yix). Decided before
/// the component mounts and fixed for its lifetime: an optional slot is structure, not state.
/// Built by `ui.view.with(...).slots(...)`: a field whose value is `null` (or an optional that is
/// null) is absent; any other value, including `{}`, is present.
pub const SlotPresence = struct {
    names: [max_named_slots][]const u8 = undefined,
    len: u8 = 0,

    pub fn has(self: SlotPresence, name: []const u8) bool {
        for (self.names[0..self.len]) |n| if (std.mem.eql(u8, n, name)) return true;
        return false;
    }

    pub fn add(self: *SlotPresence, name: []const u8) void {
        if (self.has(name)) return;
        self.names[self.len] = name;
        self.len += 1;
    }
};

pub const ViewParts = struct {
    /// Node attached to parent. null = component attached elsewhere (e.g., portal to overlay layer
    /// Modal), nothing placed in parent.
    root: ?*Node,
    /// `ui.view.with` children go here. null = component doesn't accept children.
    slot: ?*Node = null,
    /// Children insert in slot before this node (anchor when slot not at end); null = append to
    /// end.
    slot_before: ?*Node = null,
    /// Named slots (match by name in `.slots(.{ ... })` fields)
    named: [max_named_slots]?NamedSlot = @splat(null),
    /// Which scope slot children belong to (set when component wants content to follow its own
    /// scope, e.g., Popover content). null = follow caller scope.
    slot_scope: ?*Scope = null,
    /// Trigger slot (Popover / Tooltip / Menu): children of `ui.view.with(...).trigger(.{ ... })`
    /// go here, follow caller scope.
    trigger: ?*Node = null,
};

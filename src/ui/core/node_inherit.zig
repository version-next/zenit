//! Resolve of inheritable text properties, factored out of node.zig (node_* sibling split of the
//! node god-object).
//!
//! This is the only **upward parent-chain traversal** read path in node.zig, semantically parallel
//! to CSS inherited properties: each property takes the nearest non-null value on the ancestor
//! chain, and the node's own value has highest priority. Unlike the other node.zig methods
//! (self-only, or **downward** subtree modification such as mark*Dirty), this is an upward read
//! with zero side effects: no allocation, no dirty marking, `*const Node` parameters.
//!
//! One traversal for all three properties (not three) is intentional: text nodes resolve every
//! frame, three parent-chain walks on deep trees are waste; isComplete early exit handles the
//! common "parent defines all three" case in one level.
//!
//! Circular import with node.zig for the Node type is fine via Zig lazy evaluation; node_dirty.zig
//! and others do the same.

const node_mod = @import("node.zig");
const types = @import("types.zig");

const Node = node_mod.Node;

/// Inheritable text properties snapshot
pub const InheritedTextStyle = struct {
    color: ?types.Color = null,
    font_size: ?f32 = null,
    font_weight: ?u16 = null,

    /// Whether all fields found (can early-exit traversal)
    pub fn isComplete(self: InheritedTextStyle) bool {
        return self.color != null and self.font_size != null and self.font_weight != null;
    }
};

/// Single parent-chain traversal finding text_color/text_font_size/text_font_weight. Each takes
/// nearest non-null value (closest override, like CSS inherited properties).
pub fn resolveInheritedTextStyle(self: *const Node) InheritedTextStyle {
    var result = InheritedTextStyle{};
    var cur: ?*const Node = self;
    while (cur) |n| {
        if (n.style.ext) |ext| {
            if (result.color == null and ext.text_color != null) result.color = ext.text_color;
            if (result.font_size == null and ext.text_font_size != null) result.font_size = ext.text_font_size;
            if (result.font_weight == null and ext.text_font_weight != null) result.font_weight = ext.text_font_weight;
            if (result.isComplete()) break;
        }
        cur = n.parent;
    }
    return result;
}

/// The text node's properties as laid out **and** painted (the one resolution both use, so the
/// measured box always holds what is drawn): color, size and weight the text's own style declared
/// (TextProps.*_set) stay its own; the others take the nearest value up the ancestors (CSS
/// inherited properties). The node's own StyleExt values (transition setters such as
/// setTextColor) always apply. null when the node holds no text.
pub fn resolveTextProps(self: *const Node) ?types.TextProps {
    var t = self.getText() orelse return null;
    const own = self.style.ext;
    const inherited = resolveInheritedTextStyle(self);
    if ((if (own) |e| e.text_color else null) orelse (if (t.color_set) null else inherited.color)) |c| t.color = c;
    if ((if (own) |e| e.text_font_size else null) orelse (if (t.font_size_set) null else inherited.font_size)) |v| t.font_size = v;
    if ((if (own) |e| e.text_font_weight else null) orelse (if (t.font_weight_set) null else inherited.font_weight)) |v| t.font_weight = v;
    return t;
}

/// Walk up for nearest non-null text_color (convenience method)
pub fn resolveTextColor(self: *const Node) ?types.Color {
    return resolveInheritedTextStyle(self).color;
}

/// Walk up for nearest non-null text_font_size (convenience method)
pub fn resolveTextFontSize(self: *const Node) ?f32 {
    return resolveInheritedTextStyle(self).font_size;
}

/// Walk up for nearest non-null text_font_weight (convenience method)
pub fn resolveTextFontWeight(self: *const Node) ?u16 {
    return resolveInheritedTextStyle(self).font_weight;
}

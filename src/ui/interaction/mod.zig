/// UI interaction primitives
///
/// 独立于 components/ 的交互层 helpers，不产出 Node 只管事件路由。
pub const range_hover = @import("range_hover.zig");
pub const RangeHoverRegistry = range_hover.RangeHoverRegistry;
pub const RangeHoverRegion = range_hover.RangeHoverRegion;
pub const RangeRect = range_hover.RangeRect;
pub const RangeId = range_hover.RangeId;

/// 窗口内连续 pointer drag 原语（docs/DRAG_INTERACTION_DESIGN.md）。
/// 新事件只经 `ui.interaction.drag.Event` 完整命名暴露，与已有的原生
/// drop `ui.events.DragEvent` 严格分开。
pub const drag = @import("drag.zig");

const std = @import("std");
test {
    std.testing.refAllDecls(@This());
}

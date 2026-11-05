//! Controls story (Actions, first): view in controls.yix, styles in styles.yss.
const ui = @import("ui");
const view = @import("_controls.yix.zig");

pub fn build(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    return ui.view.render(scope, cx, view.Controls(.{}));
}

//! Per-corner overflow clip fixture (Regressions): view in corner_clip.yix, styles in styles.yss.
const ui = @import("ui");
const view = @import("_corner_clip.yix.zig");

pub fn build(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    return ui.view.render(scope, cx, view.CornerClip(.{}));
}

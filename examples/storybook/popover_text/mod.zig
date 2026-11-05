//! Popover text raster seam fixture (Regressions). Each popover holds two lines at fractional font
//! sizes and opens from a trigger placed at a fractional x, so its rest origin is off the device
//! grid. The space under the triggers is empty: frames sampled on a locked clock measure every
//! glyph against the settled frame (e2e/popover-text-seam.test.ts). Correct: the panel scales its
//! settled text as one picture; no glyph moves on its own while it opens or when it settles.
const ui = @import("ui");
const v = ui.view;
const W = ui.widgets;

const Spec = struct {
    key: []const u8,
    label: []const u8,
    enter: @FieldType(W.popover.PopoverProps, "enter_transition"),
};

const Styles = struct {
    fn root(_: *const ui.theme.Values) ui.BoxStyle {
        return .{ .direction = .row, .gap = 180, .height = .{ .px = 260 }, .align_items = .start };
    }
    /// Fractional lead-in: puts the trigger (and the panel's rest origin) off the device grid.
    fn lead(_: *const ui.theme.Values) ui.BoxStyle {
        return .{ .width = .{ .px = 13.3 }, .height = .{ .px = 1 }, .flex_shrink = 0 };
    }
    fn cell(_: *const ui.theme.Values) ui.BoxStyle {
        return .{ .direction = .row, .align_items = .start };
    }
    fn panel(t: *const ui.theme.Values) ui.BoxStyle {
        return .{ .width = .fixed(236), .padding = ui.Padding.all(t.tokens.space.space400), .gap = 7.3 };
    }
    fn heading(t: *const ui.theme.Values) ui.TextStyle {
        return .{ .font_size = 15.3, .font_weight = 600, .color = t.tokens.color.fg_primary };
    }
    fn body(t: *const ui.theme.Values) ui.TextStyle {
        return .{ .font_size = 13.7, .color = t.tokens.color.fg_primary };
    }
};

fn popoverView(comptime spec: Spec) fn (*ui.Scope, *ui.Cx) anyerror!*ui.Node {
    return struct {
        fn build(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
            return v.render(scope, cx, v.row(.{ .style = Styles.cell }, .{
                v.box(.{ .style = Styles.lead }, {}),
                v.with(W.Popover(.{
                    .position = .bottom_start,
                    .trigger = .click,
                    .enter_transition = spec.enter,
                    .exit_transition = spec.enter,
                }), v.col(.{ .style = Styles.panel }, .{
                    v.text(.{ .style = Styles.heading }, "Popover content wiggle"),
                    v.text(.{ .style = Styles.body }, "Contextual text, settled glyphs"),
                })).trigger(W.Button(.{ .label = spec.label, .variant = .secondary })).parts(.{
                    .trigger = "story.popovertext." ++ spec.key ++ ".trigger",
                    .chrome = "story.popovertext." ++ spec.key ++ ".content",
                }),
            }));
        }
    }.build;
}

pub fn build(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    return v.render(scope, cx, v.row(.{ .style = Styles.root }, .{
        v.component(popoverView(.{ .key = "scale", .label = "Scale fade", .enter = .scale_fade }), {}),
        v.component(popoverView(.{ .key = "dropdown", .label = "Dropdown", .enter = .dropdown }), {}),
    }));
}

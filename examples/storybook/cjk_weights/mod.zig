//! CJK weight fixture (Regressions). The same Han line at one size in several weights, once in the
//! default UI font and once in a Latin-only family, so every Han glyph comes from a fallback face
//! (Windows: Segoe UI -> Microsoft YaHei; macOS: Helvetica Neue -> PingFang). Two weights of one
//! fallback family at one size are two faces: a semibold line must be heavier than the regular line
//! in every glyph, not only in the glyphs it happened to rasterize first
//! (e2e/storybook.test.ts "CJK weights").
const ui = @import("ui");
const v = ui.view;

/// FontRegistry id of the Latin-only family; examples/storybook/main.zig interns it first.
pub const latin_family_id: u16 = 1;
/// A family without Han glyphs on each desktop.
pub const latin_family_name = switch (@import("builtin").os.tag) {
    .macos => "Helvetica Neue",
    .windows => "Segoe UI",
    else => "DejaVu Sans",
};
pub const line = "连接拒绝重新探测同意共享";
pub const font_size: f32 = 16;

const Styles = struct {
    fn root(t: *const ui.theme.Values) ui.BoxStyle {
        return .{ .direction = .column, .gap = t.tokens.space.space300, .align_items = .start };
    }
};

fn lineStyle(comptime family: u16, comptime weight: u16) fn (*const ui.theme.Values) ui.TextStyle {
    return struct {
        fn style(t: *const ui.theme.Values) ui.TextStyle {
            return .{ .font_size = font_size, .font_weight = weight, .font_family = family, .color = t.tokens.color.fg_primary };
        }
    }.style;
}

pub fn build(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    // Regular first: a face shared across weights would hand its regular bitmaps to the bold lines.
    return v.render(scope, cx, v.col(.{ .style = Styles.root }, .{
        v.attrs(.{ .test_id = "story.cjkweights.system.400" }, v.text(.{ .style = lineStyle(0, 400) }, line)),
        v.attrs(.{ .test_id = "story.cjkweights.system.600" }, v.text(.{ .style = lineStyle(0, 600) }, line)),
        v.attrs(.{ .test_id = "story.cjkweights.system.700" }, v.text(.{ .style = lineStyle(0, 700) }, line)),
        v.attrs(.{ .test_id = "story.cjkweights.latin.400" }, v.text(.{ .style = lineStyle(latin_family_id, 400) }, line)),
        v.attrs(.{ .test_id = "story.cjkweights.latin.500" }, v.text(.{ .style = lineStyle(latin_family_id, 500) }, line)),
        v.attrs(.{ .test_id = "story.cjkweights.latin.600" }, v.text(.{ .style = lineStyle(latin_family_id, 600) }, line)),
        v.attrs(.{ .test_id = "story.cjkweights.latin.700" }, v.text(.{ .style = lineStyle(latin_family_id, 700) }, line)),
    }));
}

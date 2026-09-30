//! HiDPI：scale 变化时该更新哪些 FontSelector。
//!
//! 宿主经 `App.setFontSelector` 换上自己的 selector 后，真正画字/测量走的是
//! `renderer.fonts`（宿主那份），而此前 scale 变化只更新内建
//! `app.font_selector` —— 换屏后宿主字体停在旧 scale（糊 / bearing 错位）。
//! 同理 setFontSelector 装上时也必须立刻对齐当前 scale，否则首屏就是错的。
//!
//! 泛型于 selector 类型（只要求 `setScaleFactor(f32)`），便于脱离 Metal/
//! CoreText 单测。

const std = @import("std");

/// 内建 selector 恒更新（self.fonts 基准字体挂在它上面）；生效中的外来
/// selector 与内建不同则一并更新。
pub fn syncSelectorScale(builtin: anytype, active: ?@TypeOf(builtin), scale: f32) void {
    builtin.setScaleFactor(scale);
    if (active) |sel| {
        if (sel != builtin) sel.setScaleFactor(scale);
    }
}

const FakeSelector = struct {
    scale: f32 = 1,
    calls: u32 = 0,
    fn setScaleFactor(self: *FakeSelector, s: f32) void {
        self.scale = s;
        self.calls += 1;
    }
};

test "外来 selector 生效时 scale 变化同时更新它与内建 selector" {
    var builtin: FakeSelector = .{};
    var host: FakeSelector = .{};
    syncSelectorScale(&builtin, &host, 2.0);
    try std.testing.expectEqual(@as(f32, 2.0), builtin.scale);
    try std.testing.expectEqual(@as(f32, 2.0), host.scale);
}

test "未换 selector（active 为 null 或就是内建）只更新一次" {
    var builtin: FakeSelector = .{};
    syncSelectorScale(&builtin, null, 2.0);
    syncSelectorScale(&builtin, &builtin, 3.0);
    try std.testing.expectEqual(@as(f32, 3.0), builtin.scale);
    try std.testing.expectEqual(@as(u32, 2), builtin.calls);
}

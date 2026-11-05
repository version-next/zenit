// GENERATED FILE, do not edit: generated from tokens_probe.yss; after editing the source run `zig build gen-yix` (yix-lsp regenerates it on save).
//! Token mapping probe: examples/theme.json tokens read via .yss (runtime_tests compiles it under
//! example theme)
const ui = @import("ui");

/// semantic.typography.counterTitle: font-size = semantic.font_size.counterHeading (->
/// tokens.font_size.xxxl), font-weight = semibold
pub const heading = ui.previewCss("tests/yix/tokens_probe.yss", "heading", @embedFile("tokens_probe.yss"), .{ .typography = ui.tokenRef(.typography, "counterTitle"), });
/// Single property overrides same-name property in typography
pub const heading_light = ui.previewCss("tests/yix/tokens_probe.yss", "heading_light", @embedFile("tokens_probe.yss"), .{ .typography = ui.tokenRef(.typography, "counterTitle"), .font_weight = ui.tokenRef(.font_weight, "regular"), });

//# yix-map tokens_probe.yss

//! Test root for src/ui/core/tests.zig（orphan integration test bundle）。
//!
//! 历史问题：tests.zig 通过 `@import("ui_core")` 引用 build.zig 未注册模块，
//! 导致整个文件 200 tests 从 v0.4 起从未编译运行。
//!
//! task #161 阶段修复：用此文件作 test root（位置在 src/ui/，让 tests.zig 内
//! 的 `@import("../components/...")` 跨目录路径相对此根合法）。
//! tests.zig 自身改用 `@import("../core.zig")` 替代旧的 `@import("ui_core")`。

test {
    _ = @import("core/tests.zig");
    _ = @import("core/bulk_quad_layer.zig"); // Cx 拆分：BulkQuad 层单测（refAllDecls 不会自动发现）
    _ = @import("core/render_engine/gpu_draw_shadow.zig");
    _ = @import("core/text_shaper_adapter.zig"); // v0.5 §5 GlyphRun pipeline
    _ = @import("core/a11y_projection.zig"); // a11y 投影规则单测（不再经 cx.render 驱动）
}

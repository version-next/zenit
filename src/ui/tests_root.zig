//! Test root for src/ui/core/tests.zig (integration test bundle).
//!
//! Located in src/ui/ so relative @import("../components/...") paths in tests.zig resolve.
//! tests.zig must import the core via @import("../core.zig"), not an unregistered module
//! name such as @import("ui_core"), or its tests are never compiled/run.

test {
    _ = @import("core/counting_allocator.zig");
    _ = @import("core/shaping_cache.zig");
    _ = @import("core/layout_engine.zig"); // Required LC3 flex/OOM contracts, including filtered runs.
    _ = @import("core/layout_output_table.zig"); // Explicitly discover sparse storage/OOM tests.
    _ = @import("core/tests.zig");
    _ = @import("core/display_list.zig"); // Retained content fingerprint/replay contracts, including filtered runs.
    _ = @import("core/compositor_sprite.zig"); // compositor sprite admission/filter unit tests
    _ = @import("core/bulk_quad_layer.zig"); // Cx split: BulkQuad layer unit test (refAllDecls won't auto-discover)
    _ = @import("core/render_engine/gpu_draw_shadow.zig");
    _ = @import("core/text_shaper_adapter.zig"); // v0.5 §5 GlyphRun pipeline
    _ = @import("core/a11y_projection.zig"); // a11y projection rules unit test (no longer driven via cx.render)
}

// Named entry keeps the chrome suite discoverable with -Dtest-filter='window chrome'.
test "window chrome imports" {
    _ = @import("core/window_chrome_tests.zig");
}

// A filtered job that accidentally imports only the empty root tests must not
// masquerade as the LC3 gate. Narrow individual tests can still use their names.
test "LC3 flex gate requires its regression cases" {
    const std = @import("std");
    const required = [_][]const u8{
        "LC3 flex wide scratch OOM degrades safely and recovers",
        "LC3 automatic minimum respects paint-only text spans",
        "LC3 fit parent honors zero basis only on the main axis",
        "LC3 min-content cache separates kinds axes worlds and invalidation",
        "LC3 min-content depth is independent counted and never caches truncation",
        "LC3 flex scratch OOM reuses measured targets",
    };
    for (required) |name| {
        var found = false;
        for (@import("builtin").test_functions) |function| {
            if (std.mem.endsWith(u8, function.name, name)) found = true;
        }
        if (!found) std.debug.print("missing required flex regression: {s}\n", .{name});
        try std.testing.expect(found);
    }
}

test "LC3B gate requires wrap OOM and paint baseline regressions" {
    const std = @import("std");
    for ([_][]const u8{
        "LC3B wrap scratch OOM publishes clamped bases and recovers",
        "LC3B baseline layout and painted first line share the same origin",
        "LC3B wrap first frame OOM retries every scratch failure without zero geometry",
        "LC3B large wrap incremental layout skips independent siblings and redundant passes",
        "LC3B baseline export reuses collected first line without intrinsic reprobes",
    }) |name| {
        var found = false;
        for (@import("builtin").test_functions) |function| {
            if (std.mem.endsWith(u8, function.name, name)) found = true;
        }
        if (!found) std.debug.print("missing required LC3B regression: {s}\n", .{name});
        try std.testing.expect(found);
    }
}

test "LC3C gate requires lifetime and grid allocation regressions" {
    const std = @import("std");
    for ([_][]const u8{
        "LC3C mount publication skips settled trees and retains deferred new mounts",
        "LC3C mount callback reparents a sibling into another subtree",
        "LC3C aspect percentage suggestions require a definite containing axis",
        "LC3C sticky clamp includes non overlay border and padding",
        "LC3C VirtualList accessibility viewport includes layout border",
        "LC3C Grid external row window subtracts layout border",
        "LC3C ScrollArea border viewport maxScroll and resize use content insets",
        "LC3C nowrap mount destruction and reentry never retain child borrows",
        "LC3C mount publication permits direct ancestor destruction",
        "LC3C release during publication preserves remaining mount retries",
        "LC3C deferred outer probes do not mount display none descendants",
        "LC3C grid scratch OOM is atomic and implicit rows exceed old limits",
    }) |name| {
        var found = false;
        for (@import("builtin").test_functions) |function| {
            if (std.mem.endsWith(u8, function.name, name)) found = true;
        }
        if (!found) std.debug.print("missing required LC3C regression: {s}\n", .{name});
        try std.testing.expect(found);
    }
}

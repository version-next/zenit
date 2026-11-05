/// App module, application layer wrapper
///
/// Provides complete pipeline from UI declaration to screen display.
const renderer_mod = @import("renderer.zig");
const builtin = @import("builtin");
pub const AppRenderer = renderer_mod.AppRenderer;
pub const AcquireFaultHook = renderer_mod.AcquireFaultHook;
pub const VisualQuality = @import("render").visual_quality.Quality;
pub const ClearColor = renderer_mod.ClearColor;
pub const FrameStats = renderer_mod.FrameStats;

pub const ResourcePath = @import("resource_path.zig").ResourcePath;
/// Large blocks mapped directly, so freeing them returns the memory (macOS
/// libmalloc keeps freed large blocks resident); see large_block_allocator.zig.
pub const LargeBlockAllocator = @import("large_block_allocator.zig").LargeBlockAllocator;
/// The same policy for C libraries' allocator hooks (tree-sitter, SQLite).
pub const large_block_c_heap = @import("large_block_allocator.zig").c_heap;

/// All-in-one application runtime; see runtime.zig
pub const runtime = @import("runtime.zig");

/// E2E test harness inlet (active with `-Dtest-mode=true`, otherwise compiled away).
///
/// `runtime.App.run()` calls `drainTestCommands()` each frame itself; custom main-loop
/// hosts must call it once per loop, or the file-RPC server receives requests but never
/// executes or answers them, and clients hang until timeout.
pub const dev_control = @import("dev_control/mod.zig");

/// Custom-loop hosts drain after native event dispatch, before the frame.
pub fn drainDevCommands() void {
    dev_control.drain();
}

pub const test_harness = @import("test_harness");

/// Drain E2E command queue once per frame. Custom main-loop hosts call after processEvents().
pub fn drainTestCommands() void {
    test_harness.drainCommands();
}

/// Call once per frame after render (track frame sampling points for track_start/track_stop).
/// Custom main-loop hosts call after rendering.
pub fn afterTestFrame() void {
    test_harness.afterFrame();
}

/// Register custom E2E route handler. See test_harness.setAppRouteHandler.
pub fn setTestRouteHandler(f: test_harness.AppRouteFn) void {
    test_harness.setAppRouteHandler(f);
}
/// Process-level font family registry (id <-> family name + face cache). Host creates one,
/// `App.setFontRegistry` installs it, canvas/UI render by family.
/// Exported from zenit_app not ui to avoid layer inversion (ui doesn't depend on render).
pub const FontRegistry = @import("render").FontRegistry;
pub const FamilyId = @import("render").FamilyId;

pub const App = if (builtin.target.os.tag == .windows) @import("windows_runtime.zig").App else runtime.App;
pub const MultiWindowApp = if (builtin.target.os.tag == .windows) @import("windows_runtime.zig").MultiWindowApp else runtime.MultiWindowApp;
pub const Application = MultiWindowApp;
pub const AppWindow = App;
pub const MultiWindowConfig = if (builtin.target.os.tag == .windows) @import("windows_runtime.zig").MultiWindowConfig else runtime.MultiWindowConfig;
/// Native event as seen by `MultiWindowConfig.on_event`.
pub const NativeEvent = @import("system_sdk").events.Event;
pub const MenuCommand = if (builtin.target.os.tag == .windows) @import("windows_runtime.zig").MenuCommand else runtime.MenuCommand;
pub const window_chrome = @import("system_sdk").window_chrome;
pub const WindowChrome = window_chrome.Config;
pub const build_environment = window_chrome.build_environment;
pub const TitlebarStyle = @import("window_config.zig").TitlebarStyle;
pub const KeyEvent = @import("window_config.zig").KeyEvent;
pub const WindowConfig = if (builtin.target.os.tag == .windows) @import("windows_runtime.zig").WindowConfig else runtime.WindowConfig;
pub const FontConfig = runtime.FontConfig;
pub const window_lifecycle = @import("window_lifecycle.zig");

const std = @import("std");

test {
    _ = @import("renderer_pool_tests.zig");
    std.testing.refAllDecls(@This());
    _ = @import("pointer_isolation.zig");
    _ = @import("shared_gpu_policy.zig");
    _ = @import("remount_tests.zig");
    _ = @import("header_reveal_tests.zig");
    _ = @import("resource_path.zig");
    _ = @import("cpu_patch.zig");
    _ = @import("large_block_allocator.zig");
    _ = @import("sprite_tiles.zig");
    _ = @import("unwind_tables_contract.zig");
    // Native window code calls these exports even when no App is initialized.
    if (builtin.os.tag == .macos) {
        _ = @import("ui").a11y.macos_bridge;
        _ = @import("ui").a11y.preferences;
    }
}

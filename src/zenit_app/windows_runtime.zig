//! Pixel-producing Windows App runtime built on the current Direct2D paint
//! subset. It uses the same Cx and SystemSdk event path as the macOS App.
const chrome_backend = @import("chrome_backend.zig");
const chrome_controller = @import("chrome_controller.zig");
const std = @import("std");
const ui = @import("ui");
const platform = @import("platform");
const system_sdk = @import("system_sdk");
const text = @import("text");
const SharedGpu = @import("shared_gpu.zig").SharedGpu;
const shared_renderer = @import("gpu").is_direct3d;
const caret_sprite = @import("caret_sprite.zig");
const windows_paint = if (shared_renderer) @import("windows_shared_paint.zig") else @import("windows_paint.zig");
const dev_control = @import("dev_control/mod.zig");
const test_harness = @import("test_harness");
const ClearColor = @import("renderer.zig").ClearColor;
const window_lifecycle = @import("window_lifecycle.zig");

const pointer_isolation = @import("pointer_isolation.zig");
/// Background e2e runs (ZENIT_E2E_BACKGROUND=1) isolate by default; see pointer_isolation.zig.
fn isolateOsPointer() bool {
    return pointer_isolation.enabled(true);
}

pub const FontConfig = @import("font_config.zig").FontConfig;
const FontSelector = @import("render").FontSelector;

pub const TitlebarStyle = @import("window_config.zig").TitlebarStyle;
pub const WindowConfig = @import("window_config.zig").WindowConfig;

pub const Config = struct {
    /// Application-owned I/O implementation, valid until all windows are destroyed.
    io: std.Io,
    window: WindowConfig = .{},
    /// Return false to cancel. Called for native and application close requests.
    on_close_request: ?*const fn (*App) bool = null,
    /// Application reopen with no visible window (see the macOS runtime). Win32 has no such
    /// event (a hidden window's process is reached through its tray icon), so it is not called.
    on_reopen: ?*const fn (*App) void = null,
    /// Called once before teardown, while every App resource is still usable.
    on_destroy: ?*const fn (*App) void = null,
    /// Application-level shortcuts: called for every native key event before
    /// UI dispatch; return true to consume it. Runs whether or not a node has
    /// focus, so commands such as "open global search" work from any state.
    /// Use `ui.events.primaryModifier` for the platform command key. Test
    /// harness key injection goes straight to the UI and does not pass here.
    on_key: ?*const fn (*App, @import("window_config.zig").KeyEvent) bool = null,
    /// Called after this window stops being the active window, at the
    /// event-dispatch boundary, with where focus went. Typically set on owned
    /// panels (`WindowConfig.owner`) that close when the user returns to
    /// another window of the application.
    on_focus_lost: ?*const fn (*App, platform.owned_window.FocusLoss) void = null,
    font: FontConfig = .{},
    clear_color: ClearColor = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
    visual_quality: ?@import("render").visual_quality.Quality = null,
    pump_timeout_ms: u32 = 16,
    idle_skip_frames: bool = true,
    /// Start Zenit's file-RPC test harness for this window when the build has
    /// test-mode. An application that runs its own harness on the same RPC
    /// directory turns this off (two servers would race for each request).
    builtin_test_harness: bool = true,
};

/// D3D12 compiles HLSL at runtime, and the blur + glass sources (~87 KB) take
/// about two seconds on first use — the wait behind "the first glass story
/// opens slowly". Compile them once on a background thread right after
/// startup: the native compiler keeps the DXBC in the per-user disk cache, so
/// the first glass frame (and every later launch) loads bytecode instead.
/// The modules are discarded; D3DCompile is thread-safe and the device is not
/// touched. A glass frame that comes first simply compiles in parallel.
fn prewarmShaderCache(device: *@import("gpu").Backend.Device) void {
    const gpu = @import("gpu");
    warmShaderSource(device, "blur", gpu.Backend.shaders.blur);
    warmShaderSource(device, "glass", gpu.Backend.shaders.glass);
}

fn warmShaderSource(device: *@import("gpu").Backend.Device, name: []const u8, source: []const u8) void {
    var module = @import("gpu").Backend.ShaderModule.initFromSource(device, source) catch |err| {
        std.log.warn("[{s}] shader warm-up of {s} failed: {}", .{ @tagName(@import("gpu").backend_kind), name, err });
        return;
    };
    module.deinit();
}

pub const App = struct {
    config: Config,
    allocator: std.mem.Allocator,
    win: platform.Window,
    /// D3D12 shader-cache warm-up; joined before the painter goes away.
    prewarm_thread: ?std.Thread = null,
    sdk: system_sdk.SystemSdk,
    font_system: text.FontSystem,
    fonts: [3]*text.Font,
    font_selector: FontSelector,
    resolved_font_family: []const u8,
    font_registry: ?*@import("render").FontRegistry,
    fallback_stack: ?*@import("render").font_fallback_stack.FontFallbackStack,
    cx: *ui.Cx,
    painter: windows_paint.Painter,
    renderer: *windows_paint.Painter,
    chrome: chrome_controller.Controller,
    should_quit: bool = false,
    destroying: bool = false,
    /// Owner of this window when created through `WindowConfig.owner`.
    owner_window: ?system_sdk.events.WindowId = null,
    width: u32,
    height: u32,
    scale: f32,
    pump_timeout_ms: u32,
    idle_skip_frames: bool,
    native_frame_active: bool,
    native_redraw_pending: bool,
    in_native_callback: bool,
    /// Idle trim (as on macOS): one second after the last rendered frame the
    /// renderer releases its frame-loop resources (offscreen pool, scratch,
    /// sprite atlases), again two and seven seconds later. Null when no trim
    /// is pending. ZENIT_IDLE_TRIM_MS overrides the first delay.
    idle_trim_due_ns: ?i128,
    idle_trim_stage: u8,
    idle_trim_delay_ns: u64,
    /// Caret blinked by DirectComposition while nothing else changes
    /// (caret_sprite.zig; the macOS runtime's caret flip). ZENIT_CARET_FLIP=0
    /// disables it; under the test harness it is off unless set to 1
    /// (drawable readback cannot see the compositor).
    caret_flip_enabled: bool,
    caret_flipping: bool,
    /// Rendering only to advance the caret's own blink (keeps the quiet clock).
    caret_tick_only: bool,
    caret_quiet_since_ns: ?i128,
    caret_idle_delay_ns: u64,
    caret_admission: @import("caret_flip_lifecycle.zig").Admission,
    caret_entries: u64,

    pub const MountFn = *const fn (*ui.Cx, *ui.Scope) anyerror!*ui.Node;

    pub const chromeState = chrome_controller.chromeState;
    pub const windowCapabilities = chrome_controller.windowCapabilities;
    pub const requestClose = chrome_controller.requestClose;
    pub const minimize = chrome_controller.minimize;
    pub const setMaximized = chrome_controller.setMaximized;
    pub const toggleMaximize = chrome_controller.toggleMaximize;
    pub const setFullscreen = chrome_controller.setFullscreen;
    pub const performWindowAction = chrome_controller.performWindowAction;

    fn chromeAction(context: *anyopaque, action: chrome_backend.chrome.Action) anyerror!void {
        const self: *App = @ptrCast(@alignCast(context));
        try self.performWindowAction(action);
    }
    fn chromeHit(context: ?*anyopaque, x: f32, y: f32) callconv(.c) c_int {
        const self: *App = @ptrCast(@alignCast(context orelse return 1));
        return @intCast(@backingInt(self.cx.windowRegionAt(x, y)));
    }

    pub fn init(allocator: std.mem.Allocator, config: Config) !*App {
        return initWithSharedGpu(allocator, config, null);
    }

    fn initWithSharedGpu(allocator: std.mem.Allocator, config: Config, shared_slot: ?*?*SharedGpu) !*App {
        if (comptime !shared_renderer) {
            if (shared_slot != null) return error.SharedGpuRequiresDirect3D;
        }
        const sizes = [_]u32{ config.font.small_size, config.font.medium_size, config.font.large_size };
        for (sizes) |size| if (size == 0) return error.InvalidFontSize;
        const self = try allocator.create(App);
        errdefer allocator.destroy(self);
        self.config = config;
        self.allocator = allocator;
        self.should_quit = false;
        self.destroying = false;
        self.owner_window = null;
        // allocator.create applies no field defaults; deinit and the init
        // errdefer read this on every backend.
        self.prewarm_thread = null;
        self.font_registry = null;
        self.fallback_stack = null;
        // An owned window appears only once it is owned and placed (attachOwner).
        self.win = try platform.Window.initApplication(config.window.width, config.window.height, config.window.title, config.window.owner != null);
        errdefer self.win.deinit();
        if (test_harness.enabled) self.win.setKeyboardIsolated(pointer_isolation.keyboardEnabled());
        self.chrome = .{ .initial = try chrome_backend.configure(&self.win, @import("window_config.zig").requestedChrome(config.window), config.window.titlebar_height) };
        try chrome_backend.configureHeader(&self.win, self.chrome.initial, config.window.fullscreen_header, config.window.titlebar_height);
        try chrome_backend.setMinimumSize(&self.win, config.window.min_width, config.window.min_height);
        if (config.window.chrome == null and config.window.titlebar == .custom_inset) {
            try self.win.setCustomTitlebar(config.window.titlebar_height, config.window.titlebar_drag_right_inset);
        }
        if (self.chrome.initial.effective_mode != .native and !self.win.setSizeChecked(config.window.width, config.window.height)) return error.WindowResizeFailed;
        self.sdk = try system_sdk.backends.initSystemSdk(allocator, &self.win, self.win.getWindowId());
        errdefer self.sdk.deinit();
        self.font_system = try text.FontSystem.init(allocator, config.io);
        errdefer self.font_system.deinit();
        // No configured locale: the user's UI language, so CJK falls back like the system does.
        var locale_buffer: [86]u8 = undefined;
        self.font_system.setDefaultLocale(config.font.locale orelse text.Backend.userLocale(&locale_buffer) orelse "en-US");
        // Resolve once for all slots, own the family independently of Config.
        var chosen: ?*text.Font = null;
        for (config.font.fallback_families) |family| {
            chosen = self.font_system.findFont(.{ .family = family, .size = @floatFromInt(sizes[0]) }) catch |err| switch (err) {
                error.FontNotFound => continue,
                else => return err,
            };
            break;
        }
        self.fonts[0] = chosen orelse try self.font_system.findFont(.{ .family = "system", .size = @floatFromInt(sizes[0]) });
        var loaded: usize = 1;
        errdefer for (self.fonts[0..loaded]) |font| font.deinit();
        self.resolved_font_family = try allocator.dupe(u8, self.fonts[0].family);
        errdefer allocator.free(self.resolved_font_family);
        self.font_system.setDefaultFamily(self.resolved_font_family);
        // Keep the default locale tied to the owned small slot, not borrowed Config memory.
        self.font_system.setDefaultLocale(self.fonts[0].locale);
        for (sizes[1..], 1..) |size, index| {
            self.fonts[index] = try self.font_system.findFont(.{ .family = "system", .size = @floatFromInt(size) });
            loaded += 1;
        }
        self.font_selector = .{ .small = self.fonts[0], .medium = self.fonts[1], .large = self.fonts[2] };
        self.font_selector.weight_loader = .{ .context = self, .load = loadWeightedFont };
        self.font_selector.initDerivedCache(allocator);
        errdefer self.font_selector.deinitDerivedCache();
        self.cx = try ui.Cx.init(allocator, config.io);
        errdefer self.cx.deinit();
        self.cx.setWindowId(self.win.getWindowId());
        self.cx.setSystemSdk(&self.sdk);
        self.cx.text.setFontSystem(&self.font_system);
        self.cx.text.manage_legacy_font_hooks = true;
        const size = self.win.getSize();
        self.width = size[0];
        self.height = size[1];
        self.scale = self.win.getScaleFactor();
        self.font_selector.setScaleFactor(self.scale);
        self.cx.display_refresh_hz = self.win.getDisplayRefreshRate();
        // Compositor sprites (sprite_host.zig): DWM steps opaque flipbooks
        // sampled at the display refresh rate, above a frame that keeps
        // painting the node. Drawable readback (test screenshots) cannot see
        // them: off under the test harness unless ZENIT_SPRITES=1;
        // ZENIT_SPRITES=0 disables them anywhere.
        self.cx.sprites.enabled = shared_renderer and @import("sprite_host.zig").supported and blk: {
            var buf: [16]u8 = undefined;
            const value = @import("zenit_environment").getInto("ZENIT_SPRITES", &buf) orelse break :blk !test_harness.enabled;
            break :blk !std.mem.eql(u8, value, "0");
        };
        self.cx.sprites.filter_placed = false;
        self.cx.sprites.max_atlas_bytes = @import("sprite_host.zig").max_rendered_atlas_bytes;
        self.cx.sprites.replay_in_place = true;
        self.cx.sprites.flipbook_hz = self.cx.display_refresh_hz;
        self.pump_timeout_ms = config.pump_timeout_ms;
        self.idle_skip_frames = config.idle_skip_frames;
        self.native_frame_active = false;
        self.native_redraw_pending = false;
        self.in_native_callback = false;
        self.idle_trim_due_ns = null;
        self.idle_trim_stage = 0;
        self.idle_trim_delay_ns = idleTrimDelayNs();
        self.caret_flip_enabled = caretFlipEnabled();
        self.caret_flipping = false;
        self.caret_tick_only = false;
        self.caret_quiet_since_ns = null;
        self.caret_idle_delay_ns = caretIdleDelayNs();
        self.caret_admission = .{};
        self.caret_entries = 0;
        const logical = self.win.getLogicalSize();
        self.cx.setWindowMetrics(logical[0], logical[1], self.scale);
        self.painter = if (comptime shared_renderer) try windows_paint.Painter.initWithSharedGpu(allocator, config.io, &self.win, .{
            config.clear_color.r,
            config.clear_color.g,
            config.clear_color.b,
            config.clear_color.a,
        }, shared_slot) else try windows_paint.Painter.init(allocator, config.io, &self.win, .{
            config.clear_color.r,
            config.clear_color.g,
            config.clear_color.b,
            config.clear_color.a,
        });
        errdefer self.painter.deinit(&self.win);
        if (config.visual_quality) |quality| self.setVisualQuality(quality);
        // Painters read back per-glass backdrop luminance (refreshLuminance),
        // except the shared renderer at basic quality. Declare it before any UI
        // mounts so new glass takes the first-frame family probe, as on macOS.
        self.cx.backdrop_luminance_readback = if (comptime shared_renderer) self.painter.state.renderer.visual_quality != .basic else true;
        try self.painter.setDefaultFontFamily(self.resolved_font_family);
        try self.painter.setDefaultLocale(self.fonts[0].locale);
        self.renderer = &self.painter;
        if (shared_renderer) self.setFontSelector(&self.font_selector);
        if (comptime shared_renderer) {
            self.prewarm_thread = std.Thread.spawn(.{}, prewarmShaderCache, .{self.painter.state.renderer.device}) catch null;
        }
        errdefer if (self.prewarm_thread) |thread| thread.join();
        // Native sizing/moving runs a nested Win32 loop. Rebuild Cx geometry
        // there instead of replaying commands prepared for the old viewport.
        self.win.setRenderCallback(renderNative, self);
        const chrome_signal = try self.cx.windowChrome();
        chrome_signal.set(self.chromeState());
        self.cx.window_service = .{ .context = self, .perform = chromeAction };
        if (config.window.chrome != null and self.chrome.initial.effective_mode != .native)
            chrome_backend.setHitCallback(&self.win, chromeHit, self)
        else if (config.window.titlebar == .custom_inset) self.win.setTitlebarHitCallback(titlebarHitTest, self);
        @import("windows_accessibility.zig").install(self.cx, &self.win) catch |err| {
            std.log.err("Windows accessibility handler: {s}", .{@errorName(err)});
        };
        if (dev_control.enabled) try dev_control.attach(self);
        return self;
    }

    fn titlebarHitTest(context: ?*anyopaque, x: f32, y: f32) callconv(.c) c_int {
        const self: *App = @ptrCast(@alignCast(context orelse return 0));
        return if (self.cx.legacyWindowControlAt(x, y)) 1 else 0;
    }

    /// Change this window's title after creation (Window menu / taskbar /
    /// accessibility name). WindowConfig.title only sets the initial one.
    pub fn setTitle(self: *App, title: [:0]const u8) void {
        self.win.setTitle(title);
    }

    /// The GPU renderer behind this window: the shared AppRenderer when this
    /// Windows build paints through it, null for the native Direct2D painter.
    pub fn appRenderer(self: *App) ?*@import("renderer.zig").AppRenderer {
        if (comptime shared_renderer) return &self.painter.state.renderer;
        return null;
    }

    /// Window content size in logical units (same meaning on every runtime).
    pub fn viewportLogicalSize(self: *const App) [2]f32 {
        return .{ self.cx.viewport.width, self.cx.viewport.height };
    }

    pub fn bindMenuCommand(self: *App, command_id: u64, action: ui.actions.Action) void {
        self.cx.bindCommandAction(command_id, action);
    }

    pub fn sharedImageStore(self: *App) ?*@import("render").ImageTextureStore {
        if (comptime shared_renderer) {
            return if (self.painter.state.shared_gpu) |shared| &shared.images else null;
        }
        return null;
    }

    pub fn deinit(self: *App) void {
        if (self.cx.hasActiveCalls()) @panic("App.deinit during an active UI call; request window close instead");
        if (self.destroying) return;
        self.destroying = true;
        if (dev_control.enabled) dev_control.beginTeardown();
        defer if (dev_control.enabled) dev_control.endTeardown();
        if (dev_control.enabled) dev_control.detach(self);
        // Nothing paints once the renderer detaches below.
        self.win.conceal();
        if (self.config.on_destroy) |callback| callback(self);
        if (self.prewarm_thread) |thread| thread.join();
        self.prewarm_thread = null;
        chrome_backend.setHitCallback(&self.win, null, null);
        self.cx.window_service = null;
        self.win.setTitlebarHitCallback(null, null);
        self.win.setRenderCallback(null, null);
        @import("windows_accessibility.zig").detach(&self.win);
        test_harness.unregisterScreenshotWindow(self);
        if (test_harness.enabled and g_test_cx == self.cx) g_test_cx = null;
        if (test_harness.enabled and g_test_app == self) g_test_app = null;
        if (g_recording_app == self) {
            if (comptime shared_renderer) self.painter.flushRecording(&self.win);
            g_last_recording = mapRecordingState(self.win.stopWindowRecording());
            g_recording_app = null;
        }
        self.cx.deinit();
        self.painter.deinit(&self.win);
        self.font_selector.deinitDerivedCache();
        for (self.fonts) |font| font.deinit();
        self.font_system.deinit();
        self.allocator.free(self.resolved_font_family);
        self.sdk.deinit();
        self.win.deinit();
        self.allocator.destroy(self);
    }

    /// Caller owns selector and its fonts; keep them alive through App.deinit.
    pub fn setFontSelector(self: *App, selector: *FontSelector) void {
        if (self.font_registry) |registry| {
            selector.family_resolve_fn = resolveFamily;
            selector.family_resolve_ctx = registry;
        }
        selector.initDerivedCache(self.allocator);
        selector.setScaleFactor(self.scale);
        self.cx.text.clearManagedFontHooks();
        self.painter.setFonts(selector);
        self.cx.text.measure_ctx_fn = measureSelector;
        self.cx.text.measure_ctx = self;
        self.cx.text.font_resolve_fn = resolveSelector;
        self.cx.text.font_resolve_ctx = self;
        self.cx.text.legacy_font_resolve_fn = resolveLegacySelector;
        self.cx.text.font_props_measure_fn = measureFontProps;
        self.cx.text.resetShapingCache();
        self.invalidateFontLayout();
    }

    /// Caller owns registry and configures its FontSystem; keep it alive through App lifetime.
    pub fn setFontRegistry(self: *App, registry: *@import("render").FontRegistry) void {
        self.font_registry = registry;
        registry.setScaleFactor(self.scale);
        self.setFontSelector(self.painter.fonts orelse &self.font_selector);
    }

    /// Bind the same immutable selection factory to geometry and native paint.
    /// Rebind after its fonts/rules change, even if ctx/provider are unchanged.
    pub fn setFontRangesProvider(self: *App, ctx: ?*anyopaque, provider: @TypeOf(@as(ui.Cx, undefined).text.font_ranges_fn)) void {
        self.fallback_stack = null;
        if (shared_renderer) self.painter.setFallbackStack(null);
        self.painter.stack_mode = false;
        self.bindFontRangesProvider(ctx, provider);
    }

    /// Caller owns the stack and source Font objects until it is unbound.
    /// Rebind after mutating its families/fonts, including at the same address.
    pub fn setFallbackStack(self: *App, stack: ?*@import("render").font_fallback_stack.FontFallbackStack) void {
        self.fallback_stack = stack;
        if (shared_renderer) self.painter.setFallbackStack(stack);
        self.painter.stack_mode = stack != null;
        self.bindFontRangesProvider(if (stack != null) self else null, if (stack != null) stackRanges else null);
    }

    fn stackRanges(raw: *anyopaque, opts: ui.Cx.ShapeTextOpts, primary: *text.Font, allocator: std.mem.Allocator) !?*text.FontRanges {
        const self: *App = @ptrCast(@alignCast(raw));
        const stack = self.fallback_stack orelse return null;
        const snapshot = try allocator.create(text.FontRanges);
        errdefer allocator.destroy(snapshot);
        snapshot.* = try @import("windows_font_ranges.zig").build(allocator, stack, primary, opts.text, opts.font_size, opts.use_italic);
        return snapshot;
    }

    fn bindFontRangesProvider(self: *App, ctx: ?*anyopaque, provider: @TypeOf(@as(ui.Cx, undefined).text.font_ranges_fn)) void {
        if (provider != null and self.painter.fonts == null) self.setFontSelector(&self.font_selector);
        self.cx.text.setFontRangesProvider(ctx, provider);
        self.painter.setFontRangesProvider(ctx, provider);
        self.invalidateFontLayout();
    }

    pub fn resetFontSelector(self: *App) void {
        if (self.font_registry != null) {
            self.setFontSelector(&self.font_selector);
            return;
        }
        self.cx.text.clearManagedFontHooks();
        self.painter.setFonts(null);
        self.fallback_stack = null;
        if (shared_renderer) self.painter.setFallbackStack(null);
        self.painter.stack_mode = false;
        self.cx.text.setFontRangesProvider(null, null);
        self.painter.setFontRangesProvider(null, null);
        self.cx.text.measure_ctx_fn = null;
        self.cx.text.measure_ctx = null;
        self.cx.text.font_resolve_fn = null;
        self.cx.text.font_resolve_ctx = null;
        self.cx.text.legacy_font_resolve_fn = null;
        self.cx.text.font_props_measure_fn = null;
        self.cx.text.resetShapingCache();
        self.invalidateFontLayout();
    }

    fn invalidateFontLayout(self: *App) void {
        if (self.cx.root) |root| invalidateFontNode(root);
        self.cx.needs_redraw = true;
    }

    fn invalidateFontNode(node: *ui.Node) void {
        node.markSizingDirty();
        for (node.children.items) |child| invalidateFontNode(child);
    }

    fn measureSelector(raw: *anyopaque, bytes: [*]const u8, length: usize, size: f32, weight: u16, italic: bool) f32 {
        return measureFontProps(raw, bytes[0..length], size, weight, italic, false, 0, false, 0) orelse 0;
    }

    fn resolveSelector(raw: *anyopaque, opts: ui.Cx.ShapeTextOpts) ?*text.Font {
        const self: *App = @ptrCast(@alignCast(raw));
        const selector = self.painter.fonts orelse &self.font_selector;
        return selector.resolveFonts(opts.text, .{ .stack_mode_override = if (self.fallback_stack != null) true else null, .font_size = opts.font_size, .font_weight = opts.font_weight, .use_italic = opts.use_italic, .font_family = opts.font_family_id, .use_monospace = opts.use_monospace, .use_symbols = opts.use_symbols }).shapingFont();
    }

    fn resolveFamily(raw: *anyopaque, family: u16, size: f32, weight: u16, italic: bool) ?*text.Font {
        const registry: *@import("render").FontRegistry = @ptrCast(@alignCast(raw));
        return registry.resolve(@fromBackingInt(@intCast(family)), size, weight, italic);
    }

    fn resolveLegacySelector(raw: *anyopaque, content: []const u8, size: f32, weight: u16, italic: bool, mono: bool, family: u16) ?*text.Font {
        const self: *App = @ptrCast(@alignCast(raw));
        const selector = self.painter.fonts orelse &self.font_selector;
        return selector.resolveFonts(content, .{ .stack_mode_override = if (self.fallback_stack != null) true else null, .font_size = size, .font_weight = weight, .use_italic = italic, .use_monospace = mono, .font_family = family }).shapingFont();
    }

    fn measureFontProps(raw: *anyopaque, content: []const u8, size: f32, weight: u16, italic: bool, mono: bool, family: u16, symbols: bool, cell: f32) ?f32 {
        const self: *App = @ptrCast(@alignCast(raw));
        const selector = self.painter.fonts orelse &self.font_selector;
        if (self.cx.text.font_ranges_fn != null) {
            if (mono and cell > 0 and allAscii(content))
                return @as(f32, @floatFromInt(content.len)) * cell;
            const shaped = self.cx.text.shapeText(.{
                .text = content,
                .font_family = "system",
                .font_family_id = family,
                .font_size = size,
                .font_weight = weight,
                .use_italic = italic,
                .use_monospace = mono,
                .use_symbols = symbols,
            }) catch return null;
            return shaped.total_advance;
        }
        return selector.measureTextWidthWithProps(content, .{ .font_size = size, .font_weight = weight, .use_italic = italic, .use_monospace = mono, .font_family = family, .use_symbols = symbols, .monospace_char_width = cell });
    }

    fn allAscii(content: []const u8) bool {
        for (content) |byte| if (byte >= 128) return false;
        return true;
    }

    fn loadWeightedFont(raw: *anyopaque, size: f32, weight: u16) ?*text.Font {
        const self: *App = @ptrCast(@alignCast(raw));
        const mapped: text.FontWeight = if (weight <= 100) .thin else if (weight <= 300) .light else if (weight <= 400) .regular else if (weight <= 500) .medium else if (weight <= 600) .semibold else if (weight <= 700) .bold else if (weight <= 800) .heavy else .black;
        return self.font_system.findFont(.{ .family = self.resolved_font_family, .size = size, .weight = mapped }) catch null;
    }

    /// Replace the mounted UI at a host safe boundary (outside UI callbacks).
    /// A failed builder leaves an empty wrapper and portal, ready for another remount.
    pub fn remount(self: *App, mount_fn: MountFn) !void {
        self.cx.beginActiveUse();
        defer self.cx.endActiveUse();
        self.cx.unmount();
        self.mount(mount_fn) catch |err| {
            // Also reset any builder state before beginning the fallback transaction.
            self.cx.unmount();
            try self.mount(emptyRoot);
            return err;
        };
        self.cx.requestRedraw();
    }

    fn emptyRoot(cx: *ui.Cx, _: *ui.Scope) anyerror!*ui.Node {
        return ui.box(cx, .{ .width = .{ .grow = .{} }, .height = .{ .grow = .{} } }, .{});
    }

    pub fn mount(self: *App, mount_fn: MountFn) !void {
        self.cx.beginActiveUse();
        defer self.cx.endActiveUse();
        if (self.cx.root != null) return error.AlreadyMounted;
        const allocator = self.cx.allocator;
        const app_root = try ui.box(self.cx, .{
            .width = .{ .grow = .{} },
            .height = .{ .grow = .{} },
        }, .{});
        var app_root_orphan = true;
        errdefer if (app_root_orphan) self.cx.freeDetachedNodeAfterScopeDispose(app_root);

        const portal = try ui.box(self.cx, .{
            .position = .absolute,
            .width = .{ .grow = .{} },
            .height = .{ .grow = .{} },
        }, .{});
        var portal_orphan = true;
        errdefer if (portal_orphan) self.cx.freeDetachedNodeAfterScopeDispose(portal);
        portal.meta.ownership.meta.component_name = "WindowOverlayPortal";
        const portal_ext = try portal.style.ensureExtFallible(allocator);
        portal_ext.z_index = ui.Cx.window_portal_z_index;
        portal_ext.hit_behavior = .children_only;

        const scope = try ui.Scope.init(allocator, null, self.cx.owner);
        var scope_owned = true;
        errdefer if (scope_owned) {
            @import("mount_rollback.zig").rollback(self.cx, portal, null);
            app_root_orphan = false;
        };
        self.cx.root_scope = scope;
        self.cx.root = app_root;
        self.cx.popover_portal_root = portal;
        if (dev_control.enabled) try self.cx.prepareStyleGeneration();

        const user_root = try mount_fn(self.cx, scope);
        app_root.appendChild(allocator, user_root) catch |err| {
            @import("mount_rollback.zig").rollback(self.cx, portal, user_root);
            scope_owned = false;
            app_root_orphan = false;
            return err;
        };
        app_root.appendChild(allocator, portal) catch |err| {
            @import("mount_rollback.zig").rollback(self.cx, portal, null);
            scope_owned = false;
            app_root_orphan = false;
            return err;
        };
        portal_orphan = false;
        scope_owned = false;
        app_root_orphan = false;
        self.cx.is_mounted = true;
        self.cx.content_root = user_root;
        self.cx.needs_redraw = true;
        if (test_harness.enabled and self.config.builtin_test_harness) {
            self.rebindTestHarness();
            test_harness.init(self.cx.io, getTestCx, wakeTestHarness);
        }
    }

    pub fn runWith(self: *App, mount_fn: MountFn) !void {
        try self.mount(mount_fn);
        try self.run();
    }

    pub fn windowId(self: *const App) system_sdk.events.WindowId {
        return self.win.getWindowId();
    }

    /// This window's runtime test routes (/windows/..., /sprites/...; see
    /// spriteRoute), for hosts that run their own harness server and pick the
    /// target window themselves. Main thread. Null: not one of them.
    pub fn harnessRoute(self: *App, path: []const u8, body: []const u8, out: []u8) ?[]const u8 {
        if (comptime !test_harness.enabled) return null;
        return spriteRoute(self, path, body, out);
    }

    pub fn rebindTestHarness(self: *App) void {
        if (!test_harness.enabled) return;
        g_test_cx = self.cx;
        g_test_app = self;
        test_harness.registerScreenshotWindow(self.config.io, self, self.windowId(), captureWindowScreenshot, screenshotWindowClosing);
        test_harness.bindScreenshotWindow(self);
        test_harness.setResizeWindowCallback(resizeWindowForHarness);
        test_harness.setScreenshotCallback(captureScreenshotForHarness);
        test_harness.setFrameStatsCallback(frameStatsForHarness);
        if (comptime shared_renderer) test_harness.setRuntimeRouteHandler(perfRouteForHarness);
        test_harness.setResetTimingCallback(resetTimingForHarness);
        test_harness.setVisualQualityCallback(visualQualityForHarness);
        if (shared_renderer) test_harness.setRecordingCallbacks(startRecordingForHarness, recordingStatusForHarness, stopRecordingForHarness);
    }

    pub fn activate(self: *App) void {
        self.win.activate();
        self.cx.bindFrameClock();
    }

    pub fn setVisualQuality(self: *App, quality: @import("render").visual_quality.Quality) void {
        if (comptime shared_renderer) {
            self.painter.state.renderer.setVisualQuality(quality);
            self.cx.renderer_reduced_motion = self.painter.state.renderer.visual_quality == .basic;
            self.cx.backdrop_luminance_readback = self.painter.state.renderer.visual_quality != .basic;
            self.cx.needs_redraw = true;
            if (self.cx.root) |root| root.markRenderDirty();
        }
    }

    pub fn quit(self: *App) void {
        self.cx.close_requested = true;
        self.should_quit = true;
    }

    fn renderNative(context: ?*anyopaque) callconv(.c) void {
        const self: *App = @ptrCast(@alignCast(context orelse return));
        if (self.native_frame_active) {
            self.native_redraw_pending = true;
            return;
        }
        self.in_native_callback = true;
        defer self.in_native_callback = false;
        self.cx.needs_redraw = true;
        self.frame() catch |err| {
            std.log.err("Windows native paint: {s}", .{@errorName(err)});
            self.cx.needs_redraw = true;
        };
    }

    pub fn frame(self: *App) !void {
        self.cx.beginActiveUse();
        defer self.cx.endActiveUse();
        if (self.native_frame_active) {
            self.native_redraw_pending = true;
            return;
        }
        self.native_frame_active = true;
        defer {
            self.native_frame_active = false;
            if (self.native_redraw_pending) {
                self.native_redraw_pending = false;
                self.cx.needs_redraw = true;
            }
        }
        chrome_controller.syncChrome(self);
        // Publish fresh window regions for the native titlebar hit callback
        // only when this frame did not render: Cx.render already rebuilt the
        // hit scene, and forcing freshness afterwards re-ran every
        // before_render hook outside the frame (state changed after paint,
        // e.g. a just-mounted toolbar revealed a frame before it was drawn).
        var rendered = false;
        defer if (!rendered) self.cx.publishWindowRegions();
        const size = self.win.getSize();
        const scale = self.win.getScaleFactor();
        self.cx.display_refresh_hz = self.win.getDisplayRefreshRate();
        if (self.cx.display_refresh_hz > 0) self.cx.sprites.flipbook_hz = self.cx.display_refresh_hz;
        const logical = self.win.getLogicalSize();
        if (logical[0] != self.cx.viewport.width or logical[1] != self.cx.viewport.height or scale != self.scale) {
            self.width = size[0];
            self.height = size[1];
            self.scale = scale;
            self.font_selector.setScaleFactor(scale);
            if (self.painter.fonts) |fonts| fonts.setScaleFactor(scale);
            if (self.font_registry) |registry| registry.setScaleFactor(scale);
            self.cx.setWindowMetrics(logical[0], logical[1], scale);
        }
        self.cx.bindFrameClock();
        // Native paint must not execute queued provider/business mutations.
        if (!self.in_native_callback) {
            _ = self.cx.drainDeferredWork(self.cx.deferredBudgetUs());
            @import("windows_accessibility.zig").drain(&self.win);
        }
        // Poll completed tiny readbacks even while rendering is idle. A new
        // measurement requests one frame so adaptive hooks see it; unfinished
        // readbacks neither block the UI nor force continuous GPU redraws.
        if (self.painter.refreshLuminance(self.cx)) self.cx.needs_redraw = true;
        var want = !self.idle_skip_frames or self.cx.wantsFrame() or self.win.windowRecordingStatus().active != 0;
        if (comptime caret_sprite.supported) want = self.caretFlipDecide(want);
        if (want) {
            rendered = true;
            defer self.caret_tick_only = false;
            try self.painter.update(self.cx, &self.win);
            if (dev_control.enabled and !self.in_native_callback) dev_control.afterLayout(self);
            // Reveal on the first frame that carries the application's UI.
            // Showing the window paints synchronously before the app mounts
            // its root; that frame is background only and must stay cloaked.
            // Both painters present every non-empty frame they are given.
            if (self.cx.root != null and size[0] != 0 and size[1] != 0) self.win.notePresented();
            self.noteFrameForIdleTrim();
        } else self.maybeTrimIdle();
    }

    fn caretFlipEnabled() bool {
        if (comptime !caret_sprite.supported) return false;
        var buf: [8]u8 = undefined;
        const value = @import("zenit_environment").getInto("ZENIT_CARET_FLIP", &buf) orelse return !test_harness.enabled;
        return !std.mem.eql(u8, value, "0");
    }

    fn caretIdleDelayNs() u64 {
        var buf: [16]u8 = undefined;
        const value = @import("zenit_environment").getInto("ZENIT_CARET_FLIP_IDLE_MS", &buf) orelse return 2 * std.time.ns_per_s;
        const ms = std.fmt.parseInt(u32, value, 10) catch return 2 * std.time.ns_per_s;
        return @as(u64, std.math.clamp(ms, 500, 60000)) * std.time.ns_per_ms;
    }

    /// Advance the declared caret phase to `now`; true when it changed.
    fn updateCaretPhase(self: *App, now: i128) bool {
        if (now < self.cx.caret_next_ns) return false;
        const steps = @divTrunc(now - self.cx.caret_next_ns, self.cx.caret_half_ns) + 1;
        if (@mod(steps, 2) == 1) self.cx.caret_visible = !self.cx.caret_visible;
        self.cx.caret_next_ns += steps * self.cx.caret_half_ns;
        return true;
    }

    /// Whether this wake renders, with the caret handed to the compositor once
    /// it is the only thing changing (see caret_sprite.zig).
    fn caretFlipDecide(self: *App, want_frame: bool) bool {
        // The runtime, not wantsFrame, advances the caret phase.
        self.cx.caret_flip_host = self.caret_flip_enabled;
        if (!self.caret_flip_enabled) return want_frame;
        self.caret_admission.observe(self.cx.input_epoch, self.cx.world.mutation_epoch);
        const now = @import("zenit_time").monotonicTimestamp(self.cx.io);
        // The sprite host dropped the sprite (a failed put): paint the caret
        // again rather than rely on that failure's redraw reaching here.
        if (self.caret_flipping and !self.painter.state.renderer.caret_sprite.active) {
            self.exitCaretFlip();
            return true;
        }
        if (want_frame) {
            self.exitCaretFlip();
            return true;
        }
        const eligible = self.cx.caret_phase_valid and self.cx.caret_rect_count > 0 and !self.cx.caret_rect_overflow and
            self.painter.state.renderer.config.clear_color.a == 1;
        if (!eligible) {
            self.exitCaretFlip();
            // Unsupported or fully clipped declarations still blink normally.
            if (self.cx.caret_phase_valid and self.updateCaretPhase(now)) return self.caretTick();
            return false;
        }
        const was_visible = self.cx.caret_visible;
        const phase_changed = self.updateCaretPhase(now);
        if (self.caret_flipping) return false; // DWM blinks it.
        if (self.caret_quiet_since_ns == null) self.caret_quiet_since_ns = now;
        // Enter on a blink: the two capture frames are presented, so the first
        // repeats the phase on screen and the second is that blink itself.
        if (phase_changed and was_visible != self.cx.caret_visible and now - self.caret_quiet_since_ns.? >= @max(self.caret_idle_delay_ns, self.cx.caret_half_ns) and self.caret_admission.ready(now)) {
            self.enterCaretFlip() catch |err| {
                std.log.warn("[caret-flip] entry failed: {s}", .{@errorName(err)});
                self.painter.state.renderer.caret_sprite.deactivate();
                self.caret_flipping = false;
                self.caret_admission.failed(now, self.caret_idle_delay_ns);
                self.caret_admission.painted(self.cx.world.mutation_epoch);
                self.cx.needs_redraw = true;
                if (self.cx.root) |root| root.markSubtreeDirty();
                return true;
            };
            self.caret_admission.painted(self.cx.world.mutation_epoch);
            return false; // enterCaretFlip rendered its frames.
        }
        return if (phase_changed) self.caretTick() else false;
    }

    /// A frame that only advances the caret's blink.
    fn caretTick(self: *App) bool {
        self.caret_tick_only = true;
        self.cx.needs_redraw = true;
        return true;
    }

    fn exitCaretFlip(self: *App) void {
        if (self.caret_flipping) {
            // The next frame paints the caret again and no longer puts the
            // sprite; the host removes it once that frame is presented.
            self.painter.state.renderer.caret_sprite.deactivate();
            self.cx.needs_redraw = true;
            if (self.cx.root) |root| root.markSubtreeDirty();
        }
        self.caret_flipping = false;
        self.caret_quiet_since_ns = null;
    }

    /// Render the caret hidden, then shown, copying its patch out of each
    /// composed frame; then render the frame that puts the sprite.
    fn enterCaretFlip(self: *App) !void {
        if (comptime !caret_sprite.supported) return error.Unsupported;
        const renderer = &self.painter.state.renderer;
        const drawable = self.win.getDrawableSize();
        const rect = caret_sprite.patchRect(self.cx.caret_rects[0..self.cx.caret_rect_count], self.scale, drawable) orelse return error.CaretPatchUnavailable;
        try renderer.caret_sprite.begin(renderer.device, rect);
        defer self.cx.caret_paint_override = null;
        // Entry runs on a phase change: the phase just left is still on screen.
        // Capturing it first presents nothing new; the second frame is the blink.
        const now_visible = self.cx.caret_visible;
        for ([_]bool{ !now_visible, now_visible }) |visible| {
            self.cx.caret_paint_override = visible;
            renderer.caret_sprite.capture = if (visible) .visible else .hidden;
            self.cx.needs_redraw = true;
            if (self.cx.root) |root| root.markSubtreeDirty();
            try self.painter.update(self.cx, &self.win);
            // The frame did not reach its back buffer (no surface, zero size).
            if (renderer.caret_sprite.capture != .none) return error.CaretPatchUnavailable;
        }
        // Both pictures come from one unchanged window.
        if (!std.meta.eql(self.win.getDrawableSize(), drawable)) return error.CaretHostTransition;
        try renderer.caret_sprite.activate();
        self.caret_flipping = true;
        self.caret_entries += 1;
        self.cx.caret_paint_override = null;
        self.cx.needs_redraw = true;
        if (self.cx.root) |root| root.markSubtreeDirty();
        try self.painter.update(self.cx, &self.win);
        // From here the window renders nothing: idle trim counts from now.
        self.noteFrameForIdleTrim();
    }

    fn idleTrimDelayNs() u64 {
        var buf: [16]u8 = undefined;
        const value = @import("zenit_environment").getInto("ZENIT_IDLE_TRIM_MS", &buf) orelse return std.time.ns_per_s;
        const ms = std.fmt.parseInt(u32, value, 10) catch return std.time.ns_per_s;
        return @as(u64, ms) * std.time.ns_per_ms;
    }

    fn noteFrameForIdleTrim(self: *App) void {
        if (comptime !shared_renderer) return;
        if (self.idle_trim_delay_ns == 0) return;
        self.idle_trim_stage = 0;
        self.idle_trim_due_ns = @import("zenit_time").monotonicTimestamp(self.cx.io) + self.idle_trim_delay_ns;
    }

    fn maybeTrimIdle(self: *App) void {
        if (comptime !shared_renderer) return;
        const due = self.idle_trim_due_ns orelse return;
        const now = @import("zenit_time").monotonicTimestamp(self.cx.io);
        if (now < due) return;
        const trimmed = self.painter.trimIdle();
        if (@import("zenit_environment").flag("ZENIT_DEBUG_IDLE_TRIM"))
            std.debug.print("[idle-trim] window={d} stage={d} trimmed={}\n", .{ self.windowId(), self.idle_trim_stage, trimmed });
        if (!trimmed) {
            // The last frame is still executing: retry without waiting on the GPU.
            self.idle_trim_due_ns = now + 50 * std.time.ns_per_ms;
            return;
        }
        // Later stages catch resources released only after deferred work
        // (retired presentation, pool maintenance) completes.
        const later = [_]u64{ 2, 7 };
        self.idle_trim_due_ns = if (self.idle_trim_stage < later.len) now + @as(i128, later[self.idle_trim_stage] * self.idle_trim_delay_ns) else null;
        self.idle_trim_stage += 1;
    }

    /// Milliseconds until this window needs the loop again for its own
    /// maintenance (idle trim, offscreen pool), capped at `timeout_ms`.
    fn maintenanceTimeoutMs(self: *const App, timeout_ms: u32) u32 {
        var result = self.offscreenMaintenanceTimeoutMs(timeout_ms);
        // A just-submitted backdrop luminance readback may finish after the
        // last frame: poll it (refreshLuminance in frame) without rendering,
        // as the macOS runtime does.
        if (comptime shared_renderer) {
            if (self.painter.state.renderer.hasPendingBackdropLuminance()) result = @min(result, 16);
        }
        if (self.idle_trim_due_ns) |due| {
            const now = @import("zenit_time").monotonicTimestamp(self.cx.io);
            const left: u64 = if (due > now) @intCast(due - now) else 0;
            const ms = @max(1, (left + std.time.ns_per_ms - 1) / std.time.ns_per_ms);
            result = @min(result, @as(u32, @intCast(@min(ms, std.math.maxInt(u32)))));
        }
        return result;
    }

    fn offscreenMaintenanceTimeoutMs(self: *const App, timeout_ms: u32) u32 {
        if (comptime shared_renderer) {
            if (self.painter.state.renderer.nextOffscreenMaintenanceDelayNs()) |delay_ns| {
                const ms = @max(1, (delay_ns +| (std.time.ns_per_ms - 1)) / std.time.ns_per_ms);
                return @min(timeout_ms, @as(u32, @intCast(@min(ms, std.math.maxInt(u32)))));
            }
        }
        return timeout_ms;
    }

    pub fn run(self: *App) !void {
        self.cx.needs_redraw = true;
        try self.frame();
        while (!self.should_quit) {
            const timeout = if (self.cx.wantsFrame()) 0 else if (test_harness.enabled or dev_control.active()) @min(self.pump_timeout_ms, 16) else self.pump_timeout_ms;
            pumpNative(self.maintenanceTimeoutMs(timeout));
            self.cx.bindFrameClock();
            if (test_harness.enabled) test_harness.drainCommands();
            const result = try self.sdk.pump(0);
            for (self.sdk.events()) |event| self.processEvent(event);
            if (dev_control.enabled) dev_control.drain();
            self.dispatchFocusLoss();
            if (!result.should_continue or self.should_quit) break;
            try self.frame();
        }
    }

    pub fn processEvent(self: *App, event: system_sdk.events.Event) void {
        self.cx.beginActiveUse();
        defer self.cx.endActiveUse();
        self.processEventFrom(.os, event);
    }

    /// Deliver a focus loss recorded by WM_ACTIVATE to `on_focus_lost`.
    pub fn dispatchFocusLoss(self: *App) void {
        const loss = self.win.takeFocusLoss() orelse return;
        if (self.config.on_focus_lost) |callback| callback(self, loss);
    }

    /// Only for gallery contracts that own and synchronously seed the native
    /// input queue. Ordinary SDK pumps must always use processEvent.
    /// Calling this entry point outside a test-mode build fails compilation.
    pub fn processTestContractEvent(self: *App, event: system_sdk.events.Event) void {
        self.processEventFrom(.test_contract, event);
    }

    fn processEventFrom(self: *App, comptime source: pointer_isolation.Source, event: system_sdk.events.Event) void {
        if (event.targetWindowId()) |target| {
            if (target != self.windowId()) return;
        }
        // Harness pointer injection calls Cx directly, so dropping the OS pointer here leaves
        // only the test's own input. Without it, a person using the machine during a background
        // run moves the real cursor over the window and its hover state lands in screenshots.
        if (pointer_isolation.shouldDropEvent(test_harness.enabled, test_harness.enabled and isolateOsPointer(), test_harness.enabled and pointer_isolation.keyboardEnabled(), source, event)) return;
        // Same IME contract as the macOS runtime: re-sync the native text-input
        // session with the focused node after every event (focus, clicks and
        // key handlers can all move it). The generation filter only drops
        // stale composition events on backends that report IME generations;
        // the Win32 backend does not yet, so it passes everything.
        if (!self.sdk.imeEventCurrent(event)) return;
        defer self.cx.refreshTextInputSession();
        switch (event) {
            .quit => self.should_quit = true,
            .app_reopen => if (self.config.on_reopen) |callback| callback(self),
            .window_close_requested => self.requestClose() catch {},
            .window_resized, .frame_requested, .system_theme_changed => self.cx.needs_redraw = true,
            .window_focused => |e| {
                self.cx.needs_redraw = true;
                // Win32 has no separate key/main distinction: the window looks
                // active exactly while it is the focused foreground window.
                // Test-mode runs in the background, so treat it as active unless
                // the test asks for real activation (inactive baselines).
                const appears_active = if (test_harness.enabled and !@import("zenit_environment").flag("ZENIT_E2E_REAL_ACTIVATION")) true else e.focused and e.appears_active;
                if (self.cx.window_active != appears_active) {
                    self.cx.window_active = appears_active;
                    // Inactive appearance (caption text, glass tint) is resolved in hooks.
                    if (self.cx.root) |root| root.markSubtreeBeforeRenderHook();
                }
                if (!e.focused) self.cx.cancelPointerInteractions(.window_blur) else self.cx.replayCursor();
            },
            .mouse_move => |e| self.cx.handleMouseMoveEx(e.x, e.y, toUiModifiers(e.modifiers)),
            .pointer_left => self.cx.handlePointerLeave(),
            .mouse_button => |e| {
                if (e.cancelled) {
                    self.cx.needs_redraw = true;
                    self.cx.cancelPointerInteractions(.pointer_cancel);
                    return;
                }
                const button: ui.events.MouseButton = switch (e.button) {
                    .left => .left,
                    .right => .right,
                    .middle => .middle,
                    .other => return,
                };
                if (e.pressed) self.cx.handleMouseDownEx(e.x, e.y, button, toUiModifiers(e.modifiers)) else self.cx.handleMouseUpEx(e.x, e.y, button, toUiModifiers(e.modifiers));
            },
            .mouse_wheel => |e| self.cx.handleSdkWheel(e),
            .key => |e| {
                const key = ui.events.KeyCode.fromWindowsVirtualKey(e.keycode);
                const mods = toUiModifiers(e.modifiers);
                if (self.config.on_key) |filter| if (filter(self, .{ .key = key, .modifiers = mods, .pressed = e.pressed })) return;
                if (e.pressed) self.cx.handleKeyDown(key, mods) else self.cx.handleKeyUp(key, mods);
            },
            .text_input => |e| self.cx.handleTextInput(e.text),
            .ime_preedit => |e| self.cx.handleImePreeditEvent(.{ .text = e.text, .cursor_utf8_offset = e.cursor_utf8_offset, .cursor_visible = e.cursor_visible, .selection_end_utf8 = e.selection_end_utf8, .replace_start_utf8 = e.replace_start_utf8, .replace_end_utf8 = e.replace_end_utf8 }),
            .ime_commit => |e| self.cx.handleImeCommitReplace(e.text, e.replace_start_utf8, e.replace_end_utf8),
            .ime_delete_surrounding => |e| self.cx.handleImeDeleteSurrounding(e.before_bytes, e.after_bytes),
            .magnify => |e| self.cx.handleMagnify(e.magnification, e.x, e.y, @fromBackingInt(@intCast(e.phase))),
            .drag => |e| {
                if (e.kind == 4) self.cx.cancelPointerInteractions(.native_handoff);
                self.cx.handlePlatformDrag(e.x, e.y, e.kind, e.paths, e.payload_kind, e.payload_truncated, e.payload_is_untrusted);
            },
            .menu_command => |e| self.cx.handleCommand(e.command_id),
        }
    }
};

pub const MultiWindowConfig = struct {
    /// Share one device, queue and image namespace until MultiWindowApp.deinit.
    shared_gpu: bool = false,
    pump_timeout_ms: u32 = 16,
    /// Called for a user quit request (application menu Quit) before any
    /// window is torn down. Return false to keep running, e.g. after reporting
    /// unsaved work. `quit()` itself is never vetoed.
    on_quit_request: ?*const fn (*MultiWindowApp) bool = null,
    /// Sees every native event in queue order before it is routed to a
    /// window (input recording, diagnostics). Runs while windows are being
    /// iterated: observe only, do not create or close windows here.
    on_event: ?*const fn (*MultiWindowApp, system_sdk.events.Event) void = null,
    /// Application-level menu commands, offered before window routing.
    /// Return true to consume the command. Commands chosen with no key window
    /// (window_id 0, e.g. a process command with no window open) arrive here
    /// too; they used to be dropped. Commands captured for a window that has
    /// since closed are discarded with that window and are not offered.
    on_menu_command: ?*const fn (*MultiWindowApp, MenuCommand) bool = null,
};

/// A custom menu command as delivered to `MultiWindowConfig.on_menu_command`.
/// `window_id` is the window that was key when the command was chosen, or 0
/// when there was none.
pub const MenuCommand = struct {
    command_id: u64,
    window_id: system_sdk.events.WindowId,
};

pub const MultiWindowApp = struct {
    pub const max_windows = window_lifecycle.MAX_WINDOWS;
    allocator: std.mem.Allocator,
    config: MultiWindowConfig,
    shared_gpu: ?*SharedGpu = null,
    windows: std.ArrayList(*App) = .empty,
    lifecycle: window_lifecycle.State = .{},
    execution_depth: usize = 0,
    tearing_down: bool = false,

    pub fn init(allocator: std.mem.Allocator, config: MultiWindowConfig) MultiWindowApp {
        return .{ .allocator = allocator, .config = config };
    }

    pub fn deinit(self: *MultiWindowApp) void {
        if (self.execution_depth != 0 or self.tearing_down or self.hasActiveCalls()) @panic("MultiWindowApp.deinit during an active callback");
        self.execution_depth += 1;
        while (self.windows.pop()) |app| {
            self.detachOwner(app);
            app.deinit();
        }
        if (self.shared_gpu) |shared| shared.deinit();
        self.shared_gpu = null;
        self.windows.deinit(self.allocator);
        self.windows = .empty;
        self.lifecycle = .{};
        self.execution_depth -= 1;
    }

    pub fn windowCount(self: *const MultiWindowApp) usize {
        return self.windows.items.len;
    }
    pub fn nativeWindowCount() u32 {
        return platform.Window.liveWindowCount();
    }
    pub fn window(self: *MultiWindowApp, id: system_sdk.events.WindowId) ?*App {
        for (self.windows.items) |app| if (app.windowId() == id) return app;
        return null;
    }
    pub fn activeWindow(self: *MultiWindowApp) ?*App {
        return self.window(self.lifecycle.active_window_id orelse return null);
    }
    fn reserve(self: *MultiWindowApp) !void {
        if (self.windowCount() >= max_windows) return error.TooManyWindows;
        // Keep the backing slice stable when a native event callback opens a
        // window. The current traversal uses its original length; the new
        // window joins the following frame. Closes remain deferred.
        try self.windows.ensureTotalCapacity(self.allocator, max_windows);
    }
    pub fn createWindow(self: *MultiWindowApp, config: Config) !*App {
        try self.reserve();
        const owner = try self.ownerFor(config);
        const app = try App.initWithSharedGpu(self.allocator, config, if (self.config.shared_gpu) &self.shared_gpu else null);
        errdefer app.deinit();
        attachOwner(app, owner, config.window.placement);
        errdefer self.detachOwner(app);
        try self.lifecycle.add(app.windowId());
        self.windows.appendAssumeCapacity(app);
        return app;
    }
    pub fn createWindowWith(self: *MultiWindowApp, config: Config, mount_fn: App.MountFn) !*App {
        try self.reserve();
        const owner = try self.ownerFor(config);
        const app = try App.initWithSharedGpu(self.allocator, config, if (self.config.shared_gpu) &self.shared_gpu else null);
        errdefer {
            app.deinit();
            if (self.activeWindow()) |survivor| survivor.rebindTestHarness();
        }
        attachOwner(app, owner, config.window.placement);
        errdefer self.detachOwner(app);
        try app.mount(mount_fn);
        try self.lifecycle.add(app.windowId());
        self.windows.appendAssumeCapacity(app);
        return app;
    }
    pub fn activateWindow(self: *MultiWindowApp, id: system_sdk.events.WindowId) bool {
        const app = self.window(id) orelse return false;
        self.lifecycle.setFocused(id, true);
        app.activate();
        return true;
    }
    pub fn closeWindow(self: *MultiWindowApp, id: system_sdk.events.WindowId) bool {
        if (!self.lifecycle.requestClose(id)) return false;
        self.markClosingTree(id);
        self.applyPendingCloses();
        return true;
    }
    fn hasActiveCalls(self: *const MultiWindowApp) bool {
        for (self.windows.items) |app| if (app.cx.hasActiveCalls()) return true;
        return false;
    }

    fn markClosingTree(self: *MultiWindowApp, id: system_sdk.events.WindowId) void {
        if (self.window(id)) |app| app.cx.close_requested = true;
        for (self.windows.items) |app| {
            if (app.owner_window == id) self.markClosingTree(app.windowId());
        }
    }

    fn beginHarnessCommand() void {
        if (g_harness_host) |host| host.execution_depth += 1;
    }

    fn endHarnessCommand() void {
        if (g_harness_host) |host| {
            host.execution_depth -= 1;
            host.applyPendingCloses();
        }
    }

    fn applyPendingCloses(self: *MultiWindowApp) void {
        for (self.windows.items) |app| {
            if (app.should_quit) {
                _ = self.lifecycle.requestClose(app.windowId());
                self.markClosingTree(app.windowId());
            }
        }
        if (self.execution_depth != 0 or self.tearing_down or self.hasActiveCalls()) return;
        self.tearing_down = true;
        defer self.tearing_down = false;
        while (self.lifecycle.popPendingClose()) |id| {
            self.markClosingTree(id);
            self.destroyWindowNow(id);
        }
    }
    fn destroyWindowNow(self: *MultiWindowApp, id: system_sdk.events.WindowId) void {
        // Owned windows close with their owner, and go first: Win32 destroys
        // owned HWNDs together with the owner, so cut the relation while both
        // native windows still exist.
        var child_index: usize = 0;
        while (child_index < self.windows.items.len) {
            const child = self.windows.items[child_index];
            if (child.owner_window == id) {
                self.destroyWindowNow(child.windowId());
                child_index = 0;
                continue;
            }
            child_index += 1;
        }
        for (self.windows.items, 0..) |app, index| {
            if (app.windowId() != id) continue;
            const owner_id = app.owner_window;
            self.detachOwner(app);
            _ = self.windows.orderedRemove(index);
            // Only a window that still held focus hands it on (a closing panel
            // returns it to its owner); an inactive one leaves focus alone.
            const handoff = self.lifecycle.removedFocusHandoff(id, owner_id);
            app.deinit();
            if (self.activeWindow()) |survivor| survivor.rebindTestHarness();
            // Windows hands activation to an arbitrary window (or another
            // application) when the active one is destroyed. Make the fallback
            // explicit so keyboard focus, IME and shortcuts stay with this app.
            if (handoff != null) {
                if (self.activeWindow()) |survivor| survivor.activate();
            }
            break;
        }
    }
    /// A user quit request: the application may veto it, which withdraws the
    /// native request so the next pump does not report it again.
    fn requestUserQuit(self: *MultiWindowApp) void {
        if (self.lifecycle.quit_requested) return;
        if (self.config.on_quit_request) |allow| if (!allow(self)) {
            platform.Window.cancelAppQuit();
            return;
        };
        self.quit();
    }
    fn ownerFor(self: *MultiWindowApp, config: Config) !?*App {
        const owner_id = config.window.owner orelse return null;
        const owner = self.window(owner_id) orelse return error.UnknownOwnerWindow;
        if (owner.cx.close_requested or owner.destroying) return error.OwnerWindowClosing;
        return owner;
    }
    fn attachOwner(app: *App, owner: ?*App, placement: @import("window_config.zig").Placement) void {
        const target = owner orelse return;
        app.owner_window = target.windowId();
        if (!app.win.setOwner(&target.win)) std.log.scoped(.zenit_runtime).warn("owned window relation failed", .{});
        if (placement == .center_on_owner) _ = app.win.centerOnOwner(&target.win);
        app.win.show();
    }
    /// Cut the native owner relation while both windows are still alive.
    fn detachOwner(self: *MultiWindowApp, app: *App) void {
        const owner_id = app.owner_window orelse return;
        if (self.window(owner_id)) |owner| app.win.clearOwner(&owner.win);
        app.owner_window = null;
    }
    pub fn pump(self: *MultiWindowApp, timeout_ms: u32) !bool {
        if (self.execution_depth != 0 or self.tearing_down or self.hasActiveCalls()) return error.ReentrantWindowLoop;
        if (!self.shouldContinue()) return false;
        // Retire already accepted closes before any potentially blocking native wait.
        for (self.windows.items) |app| {
            if (app.should_quit) _ = self.lifecycle.requestClose(app.windowId());
        }
        self.applyPendingCloses();
        if (!self.shouldContinue()) return false;
        var maintenance_timeout_ms = timeout_ms;
        for (self.windows.items) |app| maintenance_timeout_ms = app.maintenanceTimeoutMs(maintenance_timeout_ms);
        self.execution_depth += 1;
        {
            defer self.execution_depth -= 1;
            pumpNative(maintenance_timeout_ms);
            // The native quit flag is process-wide, so every window's pump
            // reports it with a `.quit` event. Ask the application once per
            // pump; a veto withdraws the request and the rest of the batch
            // (input, focus, resize) is still delivered.
            var quit_asked = false;
            for (self.windows.items) |app| {
                app.cx.bindFrameClock();
                const result = try app.sdk.pump(0);
                if (!result.should_continue and !platform.Window.appShouldQuit()) {
                    // The native window itself is gone.
                    _ = self.lifecycle.requestClose(app.windowId());
                    continue;
                }
                app.sdk.dispatching = true;
                defer app.sdk.dispatching = false;
                for (app.sdk.events()) |event| {
                    if (self.config.on_event) |observe| observe(self, event);
                    if (event == .menu_command) if (self.config.on_menu_command) |handle| {
                        const e = event.menu_command;
                        if (handle(self, .{ .command_id = e.command_id, .window_id = e.window_id })) continue;
                    };
                    if (event == .quit) {
                        if (!quit_asked) {
                            quit_asked = true;
                            self.requestUserQuit();
                        }
                        if (self.lifecycle.quit_requested) break;
                        continue;
                    }
                    if (event == .window_focused) self.lifecycle.setFocused(event.window_focused.window_id, event.window_focused.focused);
                    app.processEvent(event);
                }
                if (self.lifecycle.quit_requested) break;
                app.dispatchFocusLoss();
                if (app.should_quit) _ = self.lifecycle.requestClose(app.windowId());
            }
        }
        self.applyPendingCloses();
        return self.shouldContinue();
    }
    pub fn frame(self: *MultiWindowApp) !void {
        if (self.execution_depth != 0 or self.tearing_down or self.hasActiveCalls()) return error.ReentrantWindowLoop;
        self.execution_depth += 1;
        {
            defer self.execution_depth -= 1;
            for (self.windows.items) |app| try app.frame();
        }
        self.applyPendingCloses();
    }
    /// The wait an application-owned loop (`pump` + `frame`) should pass to
    /// `pump` for the windows Zenit renders: zero while one wants a frame,
    /// else until the earliest window timer, scheduled redraw or
    /// maintenance deadline (idle trim, offscreen pool), at most the
    /// configured `pump_timeout_ms` only while a developer control session
    /// polls. Same contract as the macOS runtime's `pumpTimeoutMs`.
    pub fn pumpTimeoutMs(self: *MultiWindowApp) u32 {
        var timeout: u32 = std.math.maxInt(u32);
        for (self.windows.items) |app| {
            if (app.cx.wantsFrame()) return 0;
            if (app.cx.nextWakeDelayNs()) |delay_ns| {
                const ms = @max(1, (delay_ns +| (std.time.ns_per_ms - 1)) / std.time.ns_per_ms);
                timeout = @min(timeout, @as(u32, @intCast(@min(ms, std.math.maxInt(u32)))));
            }
            timeout = app.maintenanceTimeoutMs(timeout);
        }
        if (dev_control.active()) timeout = @min(timeout, 16);
        return timeout;
    }

    pub fn tick(self: *MultiWindowApp) !bool {
        if (self.execution_depth != 0 or self.tearing_down or self.hasActiveCalls()) return error.ReentrantWindowLoop;
        var timeout = self.config.pump_timeout_ms;
        for (self.windows.items) |app| {
            if (app.cx.wantsFrame()) {
                timeout = 0;
                break;
            }
        }
        if (dev_control.active()) timeout = @min(timeout, 16);
        if (!try self.pump(timeout)) return false;
        if (dev_control.enabled) dev_control.drain();
        if (test_harness.enabled) {
            g_harness_host = self;
            test_harness.setCommandBoundaryCallbacks(beginHarnessCommand, endHarnessCommand);
            defer {
                test_harness.setCommandBoundaryCallbacks(null, null);
                g_harness_host = null;
            }
            test_harness.drainCommands();
        }
        if (!self.shouldContinue()) return false;
        try self.frame();
        return self.shouldContinue();
    }
    pub fn run(self: *MultiWindowApp) !void {
        while (try self.tick()) {}
    }
    /// Render this window on the next `frame()` without waiting for a display
    /// tick. For work the application did outside event dispatch whose result
    /// must be on screen before more input is handled, such as a command from
    /// its own test harness (the built-in harness does this itself).
    pub fn requestFrame(self: *MultiWindowApp, id: system_sdk.events.WindowId) void {
        // Windows has no display tick gate: a dirty window renders next frame().
        if (self.window(id)) |app| app.cx.needs_redraw = true;
    }

    /// Wake the application loop from any thread (a watcher, a language
    /// server reader, terminal output) so it handles new work without waiting
    /// for its pump timeout. Safe to call before or during a pump.
    pub fn wakeFromAnyThread() void {
        platform.Window.postEmptyEvent();
    }

    pub fn quit(self: *MultiWindowApp) void {
        self.lifecycle.requestQuit();
    }
    pub fn shouldContinue(self: *const MultiWindowApp) bool {
        return !self.lifecycle.quit_requested and self.windows.items.len > 0;
    }
};

var g_harness_host: ?*MultiWindowApp = null;
var g_test_cx: ?*ui.Cx = null;
var g_test_app: ?*App = null;
var g_recording_app: ?*App = null;
var g_last_recording: test_harness.RecordingState = .{};

fn getTestCx() ?*ui.Cx {
    return g_test_cx;
}

fn wakeTestHarness() void {
    // The bounded Windows event loop checks the queue at least every 16 ms.
}

fn resizeWindowForHarness(width: u32, height: u32) bool {
    const app = g_test_app orelse return false;
    app.win.setSize(width, height);
    app.cx.needs_redraw = true;
    return true;
}

fn resetTimingForHarness() void {
    if (g_test_app) |app| app.painter.resetTiming();
}

fn frameStatsForHarness() test_harness.FrameStatsSnapshot {
    const app = g_test_app orelse return .{};
    const st = app.painter.timingStats();
    const retained = app.painter.retainedStats();
    return .{
        .renderer_backend = if (shared_renderer) @tagName(@import("gpu").backend_kind) else "legacy",
        .frame_count = st.frame_count,
        .path_draw_calls = app.painter.path_draw_calls,
        .backdrop_luminance = app.painter.backdrop_luminance orelse -1,
        .retained_hits = retained.hits,
        .retained_misses = retained.misses,
        .retained_partial_repaints = retained.partial,
        .gpu_execute_us = st.last.gpu_execute_us,
        .cpu_frame_us = st.last.cpu_frame_us,
        .total_frame_us = st.last.total_frame_us,
        .layout_us = st.last.layout_us,
        .render_gen_us = st.last.render_gen_us,
        .gpu_encode_us = st.last.gpu_encode_us,
        .wait_for_frame_us = if (shared_renderer) app.painter.state.renderer.last_frame_stats.wait_for_frame_us else null,
        .acquire_texture_us = if (shared_renderer) app.painter.state.renderer.last_frame_stats.acquire_texture_us else null,
        .encode_us = if (shared_renderer) app.painter.state.renderer.last_frame_stats.encode_us else null,
        .flush_us = if (shared_renderer) app.painter.state.renderer.last_frame_stats.flush_us else null,
        .glass_count = if (shared_renderer) app.painter.state.renderer.last_frame_stats.glass_count else 0,
        .glass_us = if (shared_renderer) app.painter.state.renderer.last_frame_stats.glass_us else 0,
        .texture_creates = if (shared_renderer) app.painter.state.renderer.last_frame_stats.texture_creates else 0,
        .render_passes = if (shared_renderer) app.painter.state.renderer.last_frame_stats.render_passes else 0,
        .blit_passes = if (shared_renderer) app.painter.state.renderer.last_frame_stats.blit_passes else 0,
        .compute_passes = if (shared_renderer) app.painter.state.renderer.last_frame_stats.compute_passes else 0,
        .pass_native_us = if (shared_renderer) app.painter.state.renderer.last_frame_stats.pass_native_us else 0,
        .stage_totals = if (shared_renderer) harnessStageTotals(app.painter.state.renderer.stage_totals) else null,
        .caret_flipping = app.caret_flipping,
        .caret_visible = app.cx.caret_visible,
        .caret_rect_count = @intCast(app.cx.caret_rect_count),
        .caret_entries = app.caret_entries,
        .gpu_p95_us = st.gpu_p95_us,
        .cpu_p95_us = st.cpu_p95_us,
        .total_p95_us = st.total_p95_us,
        .timing_samples = @intCast(st.timing_samples),
        .cpu_timing_samples = @intCast(st.cpu_timing_samples),
        .gpu_timing_disjoint_samples = st.disjoint_samples,
        .gpu_timing_failed_samples = st.failed_samples,
        .gpu_timing_pending_queries = @intCast(st.pending_queries),
        .gpu_timing_query_supported = switch (st.query_supported) {
            0 => null,
            1 => true,
            else => false,
        },
    };
}

fn screenshotWindowClosing(owner: *anyopaque) bool {
    const app: *App = @ptrCast(@alignCast(owner));
    return app.destroying or app.cx.close_requested or app.should_quit;
}
fn captureWindowScreenshot(owner: *anyopaque, path: []const u8) bool {
    const app: *App = @ptrCast(@alignCast(owner));
    app.cx.beginActiveUse();
    defer app.cx.endActiveUse();
    if (!std.mem.endsWith(u8, path, ".bmp")) return false;
    return app.painter.captureBmp(path) catch false;
}

fn captureScreenshotForHarness(path: []const u8) bool {
    // The HTTP worker requests a BMP and converts it to the host's PNG path.
    // Reject other suffixes rather than write BMP bytes under a PNG filename.
    if (!std.mem.endsWith(u8, path, ".bmp")) return false;
    const app = g_test_app orelse return false;
    // Both painters retain the submitted surface in test mode. A screenshot
    // reads that surface without advancing animation or generating a new frame.
    return app.painter.captureBmp(path) catch false;
}

fn toUiModifiers(mods: system_sdk.events.Modifiers) ui.events.Modifiers {
    return .{ .shift = mods.shift, .ctrl = mods.ctrl, .alt = mods.alt, .super = mods.super };
}

fn mapRecordingState(native: platform.Window.WindowRecordingState) test_harness.RecordingState {
    var state: test_harness.RecordingState = .{ .ok = native.ok != 0, .active = native.active != 0, .width = native.width, .height = native.height, .fps = native.fps, .duration_ms = native.duration_ms, .file_size = native.file_size, .frame_count = native.frame_count, .dropped_frames = native.dropped_frames };
    state.setPath(native.pathText());
    state.setError(native.errorText());
    return state;
}
fn startRecordingForHarness(path: []const u8, fps: u32) test_harness.RecordingState {
    if (comptime !shared_renderer) {
        var state: test_harness.RecordingState = .{};
        state.setError("window recording requires the D3D12 renderer");
        return state;
    }
    if (g_recording_app) |owner| {
        const active = mapRecordingState(owner.win.windowRecordingStatus());
        if (active.active) {
            var state = active;
            state.ok = false;
            state.setError("a window recording is already active");
            return state;
        }
    }
    const app = g_test_app orelse return .{};
    if (shared_renderer) app.painter.flushRecording(&app.win);
    const state = mapRecordingState(app.win.startWindowRecording(path, fps));
    if (state.ok and state.active) g_recording_app = app;
    return state;
}
fn recordingStatusForHarness() test_harness.RecordingState {
    const app = g_recording_app orelse return g_last_recording;
    return mapRecordingState(app.win.windowRecordingStatus());
}
fn stopRecordingForHarness() test_harness.RecordingState {
    const app = g_recording_app orelse return g_last_recording;
    if (shared_renderer) app.painter.flushRecording(&app.win);
    return mapRecordingState(app.win.stopWindowRecording());
}

fn visualQualityForHarness(command: test_harness.VisualQualityCommand) ?[]const u8 {
    if (comptime !shared_renderer) return null;
    const app = g_test_app orelse return null;
    switch (command) {
        .status => {},
        .auto => app.setVisualQuality(.auto),
        .full => app.setVisualQuality(.full),
        .frosted => app.setVisualQuality(.frosted),
        .basic => app.setVisualQuality(.basic),
        .fail_blur => {
            // Test-only fault injection through the same sticky failure state
            // that a failed blur shader compilation sets in production.
            app.painter.state.renderer.persistent_gpu.blur_pipeline_failed = true;
            app.cx.needs_redraw = true;
            if (app.cx.root) |root| root.markRenderDirty();
        },
    }
    return @tagName(app.painter.state.renderer.visual_quality);
}

fn harnessStageTotals(totals: anytype) test_harness.StageTotals {
    var out: test_harness.StageTotals = .{};
    inline for (@typeInfo(test_harness.StageTotals).@"struct".field_names) |name| @field(out, name) = @field(totals, name);
    return out;
}

/// Native event wait. While a harness scroll stream runs, wake when its next
/// event is due, as the real wheel message it stands for would wake the loop;
/// a plain timeout only ends on a system timer tick (15.6 ms), which paced the
/// stream at about 32 events per second instead of its 120 Hz.
fn pumpNative(timeout_ms: u32) void {
    if (timeout_ms != 0) if (test_harness.streamNextDelayNs()) |delay_ns| {
        const us = @min(@as(u64, timeout_ms) * std.time.us_per_ms, delay_ns / std.time.ns_per_us);
        return platform.Window.pumpAppEventsTimeoutPrecise(@intCast(us));
    };
    platform.Window.pumpAppEventsTimeout(timeout_ms);
}

/// Test-mode measurement switch: POST /perf/present-interval {"interval":N}
/// presents every Nth vblank (0 restores the surface default), to compare an
/// animation's CPU cost at 120 / 60 / 30 Hz on a 120 Hz display.
fn perfRouteForHarness(path: []const u8, body: []const u8, out: []u8) ?[]const u8 {
    if (spriteRouteForHarness(path, body, out)) |written| return written;
    if (!std.mem.eql(u8, path, "/perf/present-interval")) return null;
    const app = g_test_app orelse return null;
    const key = std.mem.indexOf(u8, body, "\"interval\"") orelse return null;
    var i = key + "\"interval\"".len;
    while (i < body.len and (body[i] == ':' or body[i] == ' ')) i += 1;
    var end = i;
    while (end < body.len and body[end] >= '0' and body[end] <= '9') end += 1;
    const interval = std.fmt.parseInt(u32, body[i..end], 10) catch return null;
    if (interval > 4) return null;
    app.painter.state.surface.sync_interval = if (interval == 0) null else interval;
    app.cx.needs_redraw = true;
    return std.fmt.bufPrint(out, "{{\"ok\":true,\"interval\":{d}}}", .{interval}) catch null;
}

extern fn zenit_win_capture_client_png(hwnd: *anyopaque, path: [*:0]const u8, x: c_int, y: c_int, w: c_int, h: c_int) c_int;
extern fn zenit_win_capture_burst_start(hwnd: *anyopaque, path: [*:0]const u8, x: c_int, y: c_int, w: c_int, h: c_int, count: c_uint) c_int;
extern fn zenit_win_capture_burst_wait(timeout_ms: c_uint) c_int;
extern fn zenit_win_sprites_set_freeze(on: c_int) void;
extern fn zenit_win_bring_to_front(hwnd: *anyopaque) c_int;
extern fn zenit_win_window_info(hwnd: *anyopaque, root: *?*anyopaque, foreground: *?*anyopaque, title: [*]u8, title_len: c_int, state: *[7]c_int) void;

/// Compositor sprite acceptance (e2e/windows-sprites.test.ts). Images are
/// what DWM composes for the window (swap chain and sprite visuals), read
/// from the screen; drawable readback cannot see the sprites.
///   POST /windows/readback {"path"}  the renderer's last frame as a BMP
///   POST /windows/info {}    the window's root, visibility, cloak, rect
///   POST /windows/raise {}   the foreground window, inside the work area
///        (moved, shrunk to fit): captures read the screen
///   POST /windows/capture {"path","x","y","w","h"}      client rect (w/h 0: all)
///   POST /windows/capture-burst {"path","x","y","w","h","count"}
///        one image per composition on a worker thread, stacked vertically
///   POST /windows/capture-burst-wait {"timeout_ms"}
///   POST /sprites/freeze {"on"}   show the put phase's frame, no animation
///   POST /sprites/flipbook {"path","index"}  the active sprite's flipbook as rendered
///   POST /sprites/caret {}       the caret sprite: flipping, patch rect, half period
///   POST /sprites/caret-flip {"on"}  hand the caret to the compositor or not
///        (off: the caret blinks in regular frames, the reference pictures)
fn spriteRouteForHarness(path: []const u8, body: []const u8, out: []u8) ?[]const u8 {
    return spriteRoute(g_test_app orelse return null, path, body, out);
}

fn spriteRoute(app: *App, path: []const u8, body: []const u8, out: []u8) ?[]const u8 {
    if (comptime !shared_renderer) return null;
    const Args = struct { path: []const u8 = "", x: i32 = 0, y: i32 = 0, w: i32 = 0, h: i32 = 0, count: u32 = 0, timeout_ms: u32 = 0, on: bool = false, index: u32 = 0 };
    if (!std.mem.startsWith(u8, path, "/windows/") and !std.mem.startsWith(u8, path, "/sprites/")) return null;
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const args = std.json.parseFromSliceLeaky(Args, arena, if (body.len == 0) "{}" else body, .{ .ignore_unknown_fields = true }) catch return std.fmt.bufPrint(out, "{{\"ok\":false,\"error\":\"bad json\"}}", .{}) catch null;
    const hwnd = app.win.getNativeSurfaceHandle();
    const path_z = arena.dupeSentinel(u8, args.path, 0) catch return null;
    if (std.mem.eql(u8, path, "/windows/readback")) {
        // The renderer's last frame (BMP), against what the screen shows.
        if (!std.mem.endsWith(u8, args.path, ".bmp")) return std.fmt.bufPrint(out, "{{\"ok\":false,\"error\":\"path must end in .bmp\"}}", .{}) catch null;
        const ok = app.painter.captureBmp(args.path) catch false;
        return std.fmt.bufPrint(out, "{{\"ok\":{}}}", .{ok}) catch null;
    }
    if (std.mem.eql(u8, path, "/windows/raise") or std.mem.eql(u8, path, "/windows/info")) {
        const ok = if (std.mem.eql(u8, path, "/windows/raise")) zenit_win_bring_to_front(hwnd) == 1 else true;
        var root: ?*anyopaque = null;
        var foreground: ?*anyopaque = null;
        var title: [128]u8 = @splat(0);
        var state: [7]c_int = @splat(0);
        zenit_win_window_info(hwnd, &root, &foreground, &title, title.len, &state);
        const t = std.mem.sliceTo(&title, 0);
        for (title[0..t.len]) |*c| if (c.* == '"' or c.* == '\\' or c.* < 0x20) {
            c.* = '_';
        };
        return std.fmt.bufPrint(out, "{{\"ok\":{},\"hwnd\":{d},\"root\":{d},\"foreground\":{d},\"title\":\"{s}\",\"visible\":{d},\"iconic\":{d},\"cloaked\":{d},\"rect\":[{d},{d},{d},{d}]}}", .{
            ok,       @intFromPtr(hwnd), @intFromPtr(root), @intFromPtr(foreground), t,
            state[0], state[1],          state[2],          state[3],                state[4],
            state[5], state[6],
        }) catch null;
    }
    if (std.mem.eql(u8, path, "/windows/capture")) {
        const ok = zenit_win_capture_client_png(hwnd, path_z.ptr, args.x, args.y, args.w, args.h) == 1;
        return std.fmt.bufPrint(out, "{{\"ok\":{}}}", .{ok}) catch null;
    }
    if (std.mem.eql(u8, path, "/windows/capture-burst")) {
        const ok = zenit_win_capture_burst_start(hwnd, path_z.ptr, args.x, args.y, args.w, args.h, args.count) == 1;
        return std.fmt.bufPrint(out, "{{\"ok\":{}}}", .{ok}) catch null;
    }
    if (std.mem.eql(u8, path, "/windows/capture-burst-wait")) {
        const result = zenit_win_capture_burst_wait(args.timeout_ms);
        return std.fmt.bufPrint(out, "{{\"ok\":{},\"done\":{}}}", .{ result == 1, result != 0 }) catch null;
    }
    if (std.mem.eql(u8, path, "/sprites/caret")) {
        const c = &app.painter.state.renderer.caret_sprite;
        return std.fmt.bufPrint(out, "{{\"ok\":true,\"enabled\":{},\"flipping\":{},\"active\":{},\"entries\":{d},\"visible\":{},\"rect\":[{d},{d},{d},{d}],\"half_ms\":{d}}}", .{
            app.caret_flip_enabled, app.caret_flipping, c.active,  app.caret_entries, app.cx.caret_visible,
            c.rect[0],              c.rect[1],          c.rect[2], c.rect[3],         @divTrunc(app.cx.caret_half_ns, std.time.ns_per_ms),
        }) catch null;
    }
    if (std.mem.eql(u8, path, "/sprites/caret-flip")) {
        if (!args.on) app.exitCaretFlip();
        app.caret_flip_enabled = args.on and caret_sprite.supported;
        app.cx.needs_redraw = true;
        return std.fmt.bufPrint(out, "{{\"ok\":true,\"enabled\":{}}}", .{app.caret_flip_enabled}) catch null;
    }
    if (std.mem.eql(u8, path, "/sprites/freeze")) {
        zenit_win_sprites_set_freeze(@intFromBool(args.on));
        return std.fmt.bufPrint(out, "{{\"ok\":true}}", .{}) catch null;
    }
    if (std.mem.eql(u8, path, "/sprites/tile")) {
        @import("sprite_host.zig").tile_override = args.count;
        return std.fmt.bufPrint(out, "{{\"ok\":true}}", .{}) catch null;
    }
    if (std.mem.eql(u8, path, "/sprites/dump")) {
        const host = @import("sprite_host.zig");
        if (args.path.len == 0 or args.path.len > host.dump_dir_buf.len) {
            host.dump_dir = null;
        } else {
            @memcpy(host.dump_dir_buf[0..args.path.len], args.path);
            host.dump_dir = host.dump_dir_buf[0..args.path.len];
        }
        return std.fmt.bufPrint(out, "{{\"ok\":true}}", .{}) catch null;
    }
    if (std.mem.eql(u8, path, "/sprites/flipbook")) {
        const info = @import("sprite_host.zig").writeFlipbookPng(&app.painter.state.renderer, app.cx, args.index, args.count, path_z) catch |err|
            return std.fmt.bufPrint(out, "{{\"ok\":false,\"error\":\"{s}\"}}", .{@errorName(err)}) catch null;
        return std.fmt.bufPrint(out, "{{\"ok\":true,\"origin\":[{d},{d}],\"cell\":[{d},{d}],\"columns\":{d},\"frames\":{d},\"period_ms\":{d}}}", .{ info.origin[0], info.origin[1], info.cell[0], info.cell[1], info.columns, info.frames, info.period_ms }) catch null;
    }
    return null;
}

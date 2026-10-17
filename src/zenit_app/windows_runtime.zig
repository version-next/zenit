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
const windows_paint = if (shared_renderer) @import("windows_shared_paint.zig") else @import("windows_paint.zig");
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
        try chrome_backend.setMaximizable(&self.win, config.window.maximizable);
        try chrome_backend.setRestorable(&self.win, config.window.restorable);
        if (config.window.chrome == null and config.window.titlebar == .custom_inset) {
            try self.win.setCustomTitlebar(config.window.titlebar_height, config.window.titlebar_drag_right_inset);
        }
        if (self.chrome.initial.effective_mode != .native and !self.win.setSizeChecked(config.window.width, config.window.height)) return error.WindowResizeFailed;
        self.sdk = try system_sdk.backends.initSystemSdk(allocator, &self.win, self.win.getWindowId());
        errdefer self.sdk.deinit();
        self.font_system = try text.FontSystem.init(allocator, config.io);
        errdefer self.font_system.deinit();
        self.font_system.setDefaultLocale(config.font.locale);
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
        self.pump_timeout_ms = config.pump_timeout_ms;
        self.idle_skip_frames = config.idle_skip_frames;
        self.native_frame_active = false;
        self.native_redraw_pending = false;
        self.in_native_callback = false;
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
        try self.painter.setDefaultLocale(config.font.locale);
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

    pub fn rebindTestHarness(self: *App) void {
        if (!test_harness.enabled) return;
        g_test_cx = self.cx;
        g_test_app = self;
        test_harness.registerScreenshotWindow(self.config.io, self, self.windowId(), captureWindowScreenshot, screenshotWindowClosing);
        test_harness.bindScreenshotWindow(self);
        test_harness.setResizeWindowCallback(resizeWindowForHarness);
        test_harness.setScreenshotCallback(captureScreenshotForHarness);
        test_harness.setFrameStatsCallback(frameStatsForHarness);
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
        if (!self.idle_skip_frames or self.cx.wantsFrame() or self.win.windowRecordingStatus().active != 0) {
            rendered = true;
            try self.painter.update(self.cx, &self.win);
            // Reveal on the first frame that carries the application's UI.
            // Showing the window paints synchronously before the app mounts
            // its root; that frame is background only and must stay cloaked.
            // Both painters present every non-empty frame they are given.
            if (self.cx.root != null and size[0] != 0 and size[1] != 0) self.win.notePresented();
        }
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
            const timeout = if (self.cx.wantsFrame()) 0 else if (test_harness.enabled) @min(self.pump_timeout_ms, 16) else self.pump_timeout_ms;
            platform.Window.pumpAppEventsTimeout(self.offscreenMaintenanceTimeoutMs(timeout));
            self.cx.bindFrameClock();
            if (test_harness.enabled) test_harness.drainCommands();
            const result = try self.sdk.pump(0);
            for (self.sdk.events()) |event| self.processEvent(event);
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
            .window_close_requested => self.requestClose() catch {},
            .window_resized, .frame_requested, .system_theme_changed => self.cx.needs_redraw = true,
            .window_focused => |e| {
                self.cx.needs_redraw = true;
                // Win32 has no separate key/main distinction: the window looks
                // active exactly while it is the focused foreground window.
                // Test-mode runs in the background, so treat it as active unless
                // the test asks for real activation (inactive baselines).
                const appears_active = if (test_harness.enabled and !@import("zenit_environment").has("ZENIT_E2E_REAL_ACTIVATION")) true else e.focused and e.appears_active;
                if (self.cx.window_active != appears_active) {
                    self.cx.window_active = appears_active;
                    // Inactive appearance (caption text, glass tint) is resolved in hooks.
                    if (self.cx.root) |root| root.markSubtreeBeforeRenderHook();
                }
                if (!e.focused) self.cx.cancelPointerInteractions(.window_blur) else self.cx.replayCursor();
            },
            .mouse_move => |e| self.cx.handleMouseMoveEx(e.x, e.y, toUiModifiers(e.modifiers)),
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
            _ = self.lifecycle.removed(id);
            app.deinit();
            if (self.activeWindow()) |survivor| survivor.rebindTestHarness();
            // Windows hands activation to an arbitrary window (or another
            // application) when the active one is destroyed. Make the fallback
            // explicit so keyboard focus, IME and shortcuts stay with this app.
            if (!self.lifecycle.quit_requested) {
                // A closing panel hands focus back to its owner.
                if (owner_id) |owner| if (self.window(owner) != null) self.lifecycle.setFocused(owner, true);
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
        for (self.windows.items) |app| maintenance_timeout_ms = app.offscreenMaintenanceTimeoutMs(maintenance_timeout_ms);
        self.execution_depth += 1;
        {
            defer self.execution_depth -= 1;
            platform.Window.pumpAppEventsTimeout(maintenance_timeout_ms);
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
    pub fn tick(self: *MultiWindowApp) !bool {
        if (self.execution_depth != 0 or self.tearing_down or self.hasActiveCalls()) return error.ReentrantWindowLoop;
        var timeout = self.config.pump_timeout_ms;
        for (self.windows.items) |app| {
            if (app.cx.wantsFrame()) {
                timeout = 0;
                break;
            }
        }
        if (!try self.pump(timeout)) return false;
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

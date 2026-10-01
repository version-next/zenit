/// runtime, zenit 应用运行时（App helper）
///
/// 把 main() 里的 ~110 行启动 + 主循环 boilerplate 一行解决：
///
/// ```
/// pub fn main() !void {
///     var gpa = std.heap.GeneralPurposeAllocator(.{}){};
///     defer _ = gpa.deinit();
///
///     var app = try App.init(gpa.allocator(), .{
///         .window = .{ .width = 800, .height = 600, .title = "My App" },
///     });
///     defer app.deinit();
///
///     try mountUI(app.cx);
///
///     try app.run();
/// }
/// ```
///
/// 覆盖：
///   - 平台初始化（NSApplication delegate / 主菜单）
///   - 窗口创建
///   - GPU instance / device / queue / surface
///   - AppRenderer + FontManager + 默认字体加载
///   - SystemSdk
///   - UI Cx 初始化 + 视口设置 + measure_fn 接线
///   - 主循环（事件 pump + 类型转换 + dispatch + resize 检测 + frame）
///
/// 不覆盖（应用层关注点，用户自己写）：
///   - mountUI() 构建 UI 树（这是应用的业务）
///   - devtools、热重载、IME 高级路径、devtools deferred dispatch
///   - 复杂字体配置（Inter/Lora/JetBrains 等多家族 + 多字重）
///
/// 多窗口应用使用本文件下方的 MultiWindowApp；它为每个原生窗口保留独立
/// App/GPU/UI 状态，并统一处理事件路由、关闭与退出。需要完全自定义事件循环时，
/// App 的字段仍是 pub，processEvents / maybeReconfigureSurface / frame 可单独调。
extern fn zenit_text_input_preedit_applied(window_id: u32, start_utf16: u64, end_utf16: u64, start_utf8: u32, end_utf8: u32) callconv(.c) c_int;
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const ui = @import("ui");
const platform = @import("platform");
const system_sdk = @import("system_sdk");
const gpu = @import("gpu");
const render = @import("render");

// macOS NSAccessibility push-side C ABI (window_bridge.m 提供)。
// 仅 App 这层链接，runtime.App.init 调 ui.a11y.macos_bridge.setPushHooks
// 注册到 macos_bridge.zig，让 tests 不依赖 ObjC link。
extern fn zenit_a11y_push_children_changed(window_id: u32, element_raw: u32) callconv(.c) c_int;
extern fn zenit_a11y_push_property_changed(window_id: u32, element_raw: u32, flags: u16) callconv(.c) c_int;
extern fn zenit_a11y_push_focus_changed(window_id: u32, element_raw: u32) callconv(.c) c_int;
extern fn zenit_a11y_push_announce(window_id: u32, text_ptr: [*]const u8, text_len: c_int, priority: u8) callconv(.c) c_int;
extern fn zenit_a11y_push_active_descendant(window_id: u32, container_raw: u32, active_raw: u32) callconv(.c) c_int;
extern fn zenit_a11y_push_window_cleared(window_id: u32) callconv(.c) c_int;

const renderer_mod = @import("renderer.zig");
const window_lifecycle = @import("window_lifecycle.zig");
const text_hook_owners = @import("text_hook_owners.zig");
const selector_scale = @import("selector_scale.zig");

/// 每轮主循环一个 autorelease pool。
///
/// 主循环（pump + layout + encode + CoreText shaping + present）跑在 AppKit
/// run loop **之外**，没有任何外层 pool：ObjC 侧 autorelease 的临时对象
/// （NSAttributeDictionary / NSNumber / MTLBuffer / CAMetalLayer 引用……）
/// 永远不会被释放。实测 OBJC_DEBUG_MISSING_POOLS=YES 下 text_input 启动 8s
/// 报 735 条 "just leaking"，storybook 8s 报 ~98k 条（绝大多数是
/// AGXG16XFamilyBuffer）。libobjc 的 push/pop 就是 @autoreleasepool 的实现，
/// 嵌套开销可忽略。
const AutoreleasePool = struct {
    token: ?*anyopaque,

    extern "c" fn objc_autoreleasePoolPush() ?*anyopaque;
    extern "c" fn objc_autoreleasePoolPop(token: ?*anyopaque) void;

    fn push() AutoreleasePool {
        if (comptime builtin.os.tag != .macos) return .{ .token = null };
        return .{ .token = objc_autoreleasePoolPush() };
    }

    fn pop(self: AutoreleasePool) void {
        if (comptime builtin.os.tag != .macos) return;
        objc_autoreleasePoolPop(self.token);
    }
};
const AppRenderer = renderer_mod.AppRenderer;
const ClearColor = renderer_mod.ClearColor;

const test_harness = @import("test_harness");

var isolate_os_pointer_cache: ?bool = null;
/// ZENIT_E2E_ISOLATE_POINTER=1：test-mode 下忽略系统鼠标输入，只认 harness 注入。
fn isolateOsPointer() bool {
    if (isolate_os_pointer_cache) |v| return v;
    const v = if (std.posix.getenv("ZENIT_E2E_ISOLATE_POINTER")) |raw| raw.len > 0 and !std.mem.eql(u8, raw, "0") else false;
    isolate_os_pointer_cache = v;
    return v;
}

// E2E test harness 全局 cx 引用 (单窗口应用，多窗口需要扩展)
var g_test_cx: ?*ui.Cx = null;
fn getTestCx() ?*ui.Cx {
    return g_test_cx;
}

// E2E test harness 截图，全局 App 引用（单窗口）。callback 只登记请求，
// 真实读像素在 renderer.frame() 内 present 前做。
var g_screenshot_app: ?*App = null;
fn getFrameStats() test_harness.FrameStatsSnapshot {
    const app = g_screenshot_app orelse return .{};
    return .{
        .retained_hits = @intCast(app.renderer.total_retained_hits),
        .retained_misses = @intCast(app.renderer.total_retained_misses),
        .retained_partial_repaints = @intCast(app.renderer.total_retained_partial_repaints),
        .offscreen_pool_exhausted = app.renderer.offscreen_pool.exhausted_count,
        .text_uniform_overflow = render.textUniformOverflowTotal(),
        .path_draw_calls = app.renderer.last_frame_stats.path_draw_calls,
        .frame_count = app.renderer.frame_count,
        .backdrop_luminance = app.renderer.backdrop_luminance orelse -1,

        // 单帧计时（噪声大，仅供 log）
        .gpu_execute_us = app.renderer.last_frame_stats.gpu_execute_us,
        .cpu_frame_us = app.renderer.last_frame_stats.cpu_frame_us,
        .layout_us = app.renderer.last_frame_stats.layout_us,
        .render_gen_us = app.renderer.last_frame_stats.render_gen_us,
        .gpu_encode_us = app.renderer.last_frame_stats.gpu_encode_us,
        .total_frame_us = app.renderer.last_frame_stats.total_frame_us,

        // 跨帧 P95（门禁断言用）
        .gpu_p95_us = app.renderer.timing_ring.gpuPercentile(95),
        .cpu_p95_us = app.renderer.timing_ring.cpuPercentile(95),
        .total_p95_us = app.renderer.timing_ring.totalPercentile(95),
        .timing_samples = @intCast(app.renderer.timing_ring.len),
    };
}

/// 清空跨帧计时环，e2e 性能门禁切到重场景、等其 settle 后调用，
/// 使随后的 P95 只反映该场景本身（不混入上一个 story 的样本）。
fn resetTiming() void {
    const app = g_screenshot_app orelse return;
    app.renderer.timing_ring.reset();
}

fn wakeTestHarness() void {
    // The file-RPC producer runs off the main thread. Publishing a native
    // application event wakes AppKit without touching App/UI state there.
    if (builtin.target.os.tag == .macos) platform.Window.postEmptyEvent();
}

fn resizeWindowForHarness(width: u32, height: u32) bool {
    const app = g_screenshot_app orelse return false;
    app.win.setSize(width, height);
    // 尺寸变化经主循环的 maybeReconfigureSurface 在后续帧重配 surface；
    // 这里只负责触发。回归锚点：重配后的 usage 必须保留 test-mode 的
    // CPU readback（surfaceConfigFor 单一出口），否则 resize 后 /screenshot 全花。
    app.cx.needs_redraw = true;
    return true;
}

fn captureScreenshot(path: []const u8) bool {
    const app = g_screenshot_app orelse return false;
    // 首选:读上一次**真实呈现**帧的保留拷贝(不驱动新帧)。
    // 驱动新帧会把 pending 布局/标脏顺带跑完,截到的比屏幕上新,
    // 呈现层 bug 期间"屏幕满残影、截图干净",e2e 全绿误判了三天。
    if (app.renderer.captureRetainedToPng(path)) return true;
    // 兜底(启动初期还没有保留帧):旧路径,驱动一帧再 readback。
    if (!app.renderer.requestCapture(path)) return false;
    app.frame() catch return false;
    return app.renderer.last_screenshot_ok;
}

fn mapWindowRecordingState(native: platform.Window.WindowRecordingState) test_harness.RecordingState {
    var state: test_harness.RecordingState = .{
        .ok = native.ok != 0,
        .active = native.active != 0,
        .width = native.width,
        .height = native.height,
        .fps = native.fps,
        .duration_ms = native.duration_ms,
        .file_size = native.file_size,
        .frame_count = native.frame_count,
        .dropped_frames = native.dropped_frames,
    };
    state.setPath(native.pathText());
    state.setError(native.errorText());
    return state;
}

fn startWindowRecording(path: []const u8, fps: u32) test_harness.RecordingState {
    const app = g_screenshot_app orelse {
        var state: test_harness.RecordingState = .{};
        state.setError("no harness application window");
        return state;
    };
    const state = mapWindowRecordingState(app.win.startWindowRecording(path, fps));
    app.renderer.setRecordingActive(state.ok and state.active);
    return state;
}

fn appendWindowRecordingFrame(texture: *const gpu.Backend.Texture) bool {
    const app = g_screenshot_app orelse return false;
    const handle = texture.nativeHandleForRecording() orelse return false;
    return app.win.appendWindowRecordingFrame(handle);
}

fn windowRecordingStatus() test_harness.RecordingState {
    const app = g_screenshot_app orelse {
        var state: test_harness.RecordingState = .{};
        state.setError("no harness application window");
        return state;
    };
    return mapWindowRecordingState(app.win.windowRecordingStatus());
}

fn stopWindowRecording() test_harness.RecordingState {
    const app = g_screenshot_app orelse {
        var state: test_harness.RecordingState = .{};
        state.setError("no harness application window");
        return state;
    };
    app.renderer.setRecordingActive(false);
    return mapWindowRecordingState(app.win.stopWindowRecording());
}

const Window = platform.Window;
const FontManager = render.FontManager;
const FontSelector = render.FontSelector;
const Font = render.Font;

pub const TitlebarStyle = enum {
    /// 系统默认：透明标题栏 + 内容延伸到顶（FullSizeContentView），
    /// 红绿灯在系统默认位置。
    default,
    /// 自定义内嵌标题栏（Figma/Linear 式）：红绿灯垂直居中于
    /// titlebar_height，顶部该高度区域可拖动窗口。App 自绘标题栏内容。
    custom_inset,
};

pub const WindowConfig = struct {
    width: u16 = 800,
    height: u16 = 600,
    title: [:0]const u8 = "zenit",
    titlebar: TitlebarStyle = .default,
    /// custom_inset 时的自绘标题栏高度（逻辑像素，如 52）
    titlebar_height: f32 = 52,
    /// custom_inset 时标题栏右侧排除拖拽的宽度（给自绘 action buttons 让出点击区）
    titlebar_drag_right_inset: f32 = 0,
};

pub const FontConfig = struct {
    /// 默认字体大小（用于 ui.text 默认 14pt）。`small` slot。
    small_size: u32 = 14,
    /// 中等字体（用于 H3 等）。`medium` slot。
    medium_size: u32 = 18,
    /// 大字体（用于 H2 等）。`large` slot。
    large_size: u32 = 24,
    /// 字体家族 fallback 链。第一个找到的即用。默认链兼容 macOS / Linux 桌面。
    fallback_families: []const []const u8 = &.{
        "Helvetica Neue",
        "Arial",
        "Helvetica",
        "Inter",
        "Menlo",
    },
};

pub const FramePacing = enum { poll, display_link };

pub const Config = struct {
    window: WindowConfig = .{},
    font: FontConfig = .{},
    /// Per-window diagnostic console sinks and bounded capture capacity.
    console: ui.console.Config = ui.console.defaultConfig(),
    /// 背景色（每帧 clear）。默认白色。
    clear_color: ClearColor = .{ .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0 },
    /// `sdk.pump` 超时毫秒。16 = 约 60Hz idle 唤醒。仅 `.poll` 帧节奏下生效。
    pump_timeout_ms: u32 = 16,
    /// 帧节奏来源：
    /// - `.display_link`（默认）：CVDisplayLink 每 vsync 唤醒主线程，pump 长超时
    ///   纯阻塞等事件；idle 时 link 停掉 -> CPU 完全静默。ProMotion 下自动 120Hz。
    /// - `.poll`：旧行为，pump(pump_timeout_ms) 定时轮询。回滚开关。
    /// 环境变量 `ZENIT_FRAME_PACING=poll|display_link` 可覆盖（App.init 读取）。
    frame_pacing: FramePacing = .display_link,
    /// display-link 模式下 pump 阻塞的兜底超时毫秒（防 deadline 任务在纯事件
    /// 阻塞下饿死）；实际超时取 min(此值, 距最近 wake deadline 的剩余时间)。
    idle_wait_ms: u32 = 500,
    /// idle 时跳过整帧 GPU 提交（树 clean + 无动画 + 无 deferred work）。
    /// 逃生阀：怀疑"该重绘却没绘"时置 false 回旧行为对照。
    idle_skip_frames: bool = true,
};

/// App，一站式应用运行时
///
/// 字段都是 pub 以便高级用户绕过 run() 自己写主循环：
///   var app = try App.init(...);
///   defer app.deinit();
///   while (custom condition) {
///     _ = try app.sdk.pump(16);
///     app.processEvents();              // 把 sdk 事件 dispatch 到 cx
///     try app.maybeReconfigureSurface(); // resize 检测
///     try app.frame();                   // 渲染一帧
///   }
pub const App = struct {
    allocator: Allocator,
    config: Config,

    win: Window,
    instance: gpu.Backend.Instance,
    device: gpu.Backend.Device,
    queue: gpu.Backend.Queue,
    surface: gpu.Backend.Surface,
    renderer: *AppRenderer,
    font_manager: FontManager,
    /// 宿主装上来的字体族注册表(可选)。App 只借指针,负责在 scale 变化时
    /// 通知它，见 setFontRegistry。
    font_registry: ?*render.FontRegistry = null,
    fonts: [3]*Font, // small / medium / large
    /// 基础字体实际解析到的字体族（按字重加载时沿用）。
    resolved_font_family: ?[]const u8 = null,
    font_selector: FontSelector,
    sdk: system_sdk.api.SystemSdk,
    cx: *ui.Cx,

    // 主循环状态
    current_drawable_w: u32,
    current_drawable_h: u32,
    viewport_w: f32,
    viewport_h: f32,
    scale: f32,
    should_quit: bool = false,
    /// display-link 帧节奏状态（frame_pacing == .display_link 时用）
    display_link_running: bool = false,
    /// 连续 idle（want=false）计数，达到阈值才 stop link（防 clean/dirty 边界抖动）
    idle_streak: u8 = 0,
    /// live-resize 同步渲染重入护栏（setFrameSize 回调可能嵌套触发）
    in_live_resize_render: bool = false,

    fn titlebarHitTestCb(ctx: ?*anyopaque, x: f32, y: f32) callconv(.c) c_int {
        const app: *App = @ptrCast(@alignCast(ctx orelse return 0));
        return if (app.cx.hitTest(x, y) != null) 1 else 0;
    }

    pub fn init(allocator: Allocator, config: Config) !*App {
        // 窗口 / Metal device / 字体装配同样在任何 run loop pool 之外。
        const pool = AutoreleasePool.push();
        defer pool.pop();
        // App 自己堆分配，否则 cx.measure_fn 全局桩拿不到稳定指针。
        var app = try allocator.create(App);
        errdefer allocator.destroy(app);

        app.allocator = allocator;
        app.config = config;
        app.should_quit = false;
        app.display_link_running = false;
        app.idle_streak = 0;
        app.in_live_resize_render = false;

        // 回滚开关：ZENIT_FRAME_PACING=poll 强制回旧轮询节奏，一行环境变量回滚
        if (std.posix.getenv("ZENIT_FRAME_PACING")) |val| {
            if (std.mem.eql(u8, val, "poll")) {
                app.config.frame_pacing = .poll;
            } else if (std.mem.eql(u8, val, "display_link")) {
                app.config.frame_pacing = .display_link;
            } else {
                std.log.scoped(.zenit_runtime).warn("ZENIT_FRAME_PACING={s} 无效（poll|display_link），忽略", .{val});
            }
        }

        // 把 macOS NSAccessibility push-side hooks (window_bridge.m
        // 实装的 zenit_a11y_push_*) 注册到 ui.a11y.macos_bridge, cx.render() 末尾
        // flushToBridge 通过这些 fn ptr 把 dirty event 推到 NSAccessibilityPostNotification。
        ui.a11y.macos_bridge.setPushHooks(.{
            .property_changed = zenit_a11y_push_property_changed,
            .focus_changed = zenit_a11y_push_focus_changed,
            .children_changed = zenit_a11y_push_children_changed,
            .announce = zenit_a11y_push_announce,
            .active_descendant_changed = zenit_a11y_push_active_descendant,
            .window_cleared = zenit_a11y_push_window_cleared,
        });

        ui.a11y.macos_bridge.setTextInputAppliedHook(zenit_text_input_preedit_applied);

        // 平台 init
        Window.initAppWithDelegate();
        app.win = try Window.init(config.window.width, config.window.height, config.window.title);
        errdefer app.win.deinit();

        if (config.window.titlebar == .custom_inset) {
            // 红绿灯垂直居中于自绘标题栏；x 取系统默认起点 7
            app.win.setTrafficLightsInset(7, config.window.titlebar_height / 2.0);
            app.win.setTitlebarDragHeight(config.window.titlebar_height);
            if (config.window.titlebar_drag_right_inset > 0) {
                app.win.setTitlebarDragRightInset(config.window.titlebar_drag_right_inset);
            }
        }

        // GPU
        app.instance = try gpu.Backend.Instance.init(allocator, .{});
        errdefer app.instance.deinit();
        const adapters = try app.instance.enumerateAdapters();
        defer {
            for (adapters) |*adapter| adapter.deinit();
            allocator.free(adapters);
        }
        if (adapters.len == 0) return error.NoGPU;
        const device_and_queue = try adapters[0].requestDevice(allocator, .{});
        app.device = device_and_queue.device;
        app.queue = device_and_queue.queue;
        errdefer app.device.deinit();
        errdefer app.queue.deinit();

        // Surface。句柄按 `*anyopaque` 交给后端解释，App 运行时不认识
        // CAMetalLayer，也不该认识（见 Surface.init 的注释）。
        app.surface = gpu.Backend.Surface.init(app.win.getNativeSurfaceHandle());
        errdefer app.surface.deinit();
        const drawable = app.win.getDrawableSize();
        app.current_drawable_w = drawable[0];
        app.current_drawable_h = drawable[1];
        try app.surface.configure(allocator, &app.device, surfaceConfigFor(drawable[0], drawable[1]));

        // AppRenderer
        app.renderer = try allocator.create(AppRenderer);
        errdefer allocator.destroy(app.renderer);
        app.renderer.* = try AppRenderer.init(allocator, &app.device, &app.queue, &app.surface, .{
            .clear_color = config.clear_color,
        });
        errdefer app.renderer.deinit();

        // Font
        app.font_manager = try FontManager.init(allocator);
        errdefer app.font_manager.deinit();
        app.scale = app.win.getScaleFactor();

        const sizes = [_]u32{ config.font.small_size, config.font.medium_size, config.font.large_size };
        var loaded_count: usize = 0;
        errdefer for (app.fonts[0..loaded_count]) |f| f.deinit();
        var resolved_family: ?[]const u8 = null;
        for (sizes, 0..) |sz, i| {
            const r = try findFontWithFallback(&app.font_manager, sz, config.font.fallback_families);
            r.font.setScaleFactor(app.scale);
            app.fonts[i] = r.font;
            if (resolved_family == null) resolved_family = r.family;
            loaded_count += 1;
        }
        // "system" family 收敛到渲染实际用的 family（GlyphRun 管线的
        // shapeText/visualLine 与 FontSelector 渲染必须同基字体，否则拉丁
        // kerning 与 🈶 类符号 emoji 的 fallback 解析会出现度量≠渲染）。
        app.font_manager.setDefaultFamily(resolved_family);

        app.font_selector = .{
            .small = app.fonts[0],
            .medium = app.fonts[1],
            .large = app.fonts[2],
        };
        // 按字重加载：同一字体族，目标字重（600 / 700 …）。否则所有粗体静默退回常规体。
        app.resolved_font_family = resolved_family;
        app.font_selector.weight_loader = .{ .context = @ptrCast(app), .load = loadWeightedFont };
        app.renderer.setFonts(&app.font_selector);
        app.renderer.initFontDerivedCache(allocator);

        // 本窗口的真实系统 id（macOS = NSWindow.windowNumber）。以前这里硬编码 1，
        // 两个 App 并存时 a11y / 系统 API 会全部路由到同一个 id 上互相覆盖。
        // 0 说明底层没拿到窗口；此时用进程内单调递增的合成 id 兜底，不能都
        // 退回同一个常数（两个 App 都拿 0 时会以同键注册、静默回到互相覆盖），
        // 合成 id 从高位段起，避免与真实 windowNumber 撞号。
        const window_id: system_sdk.events.WindowId = blk: {
            const raw = app.win.getWindowId();
            if (raw != 0) break :blk raw;
            const S = struct {
                var next_synthetic: u32 = 0x7F00_0000;
            };
            S.next_synthetic += 1;
            std.log.warn("[App] window id unavailable, using synthetic {d}", .{S.next_synthetic});
            break :blk S.next_synthetic;
        };

        // SystemSdk
        app.sdk = try system_sdk.backends.initSystemSdk(allocator, &app.win, window_id);
        errdefer app.sdk.deinit();

        // UI Cx
        app.cx = try ui.Cx.init(allocator);
        app.cx.console().configure(app.config.console);
        errdefer app.cx.deinit();
        app.cx.setWindowId(window_id);
        app.cx.setSystemSdk(&app.sdk);
        const win_size = app.win.getSize();
        app.viewport_w = @floatFromInt(win_size[0]);
        app.viewport_h = @floatFromInt(win_size[1]);
        app.cx.setWindowMetrics(app.viewport_w, app.viewport_h, app.scale);

        // 命中驱动拖拽区（下游应用）：custom_inset 标题栏内 mouseDown
        // 先做真实 hit-test，点在任意交互控件上就正常下发事件，其余空白才拖窗口。
        // 矩形模型（drag_right_inset）仍生效，作为回调之前的粗筛。
        if (config.window.titlebar == .custom_inset) {
            app.win.setTitlebarHitCallback(titlebarHitTestCb, app);
        }

        // 接 measure_fn。优先用**带 context** 的版本：它把本 App 自己的
        // FontSelector 作为 context 传下去，多个 App 并存时各测各的字体。
        // 无 context 的全局指针保留为兜底（旧 API 兼容），但不再是主路径,
        // 它曾是多窗口的两处非 World 全局依赖之一。
        app.cx.text.measure_ctx_fn = measureTextWithCtx;
        app.cx.text.measure_ctx = @ptrCast(&app.font_selector);
        app.cx.text.measure_fn = measureText;

        // GlyphRun pipeline 接管旧 measure 路径起步，把 FontManager
        // 注入 cx，让 cx.shapeText 能找 Font + 调 TextShaper。
        // setSystemSdk 风格：单向注入，cx 持有 ?*FontSystem 弱引用，App.deinit
        // 时 cx.deinit 在 font_manager.deinit 之前（生命周期由 App 兜底）。
        app.cx.text.setFontSystem(&app.font_manager);

        // The runtime owns the complete text pipeline, so its default setup
        // must not leave rich-text layout on the legacy system-font fallback.
        // App and renderer are heap-stable here; the callbacks stay pointed at
        // this App's selector until a newer App takes the top of the owner
        // stack or deinit hands them back to the next live App.
        installProcessTextHooks(try g_text_hook_owners.push(app, &app.font_selector));

        // live resize 同步渲染：AppKit 的 resize tracking loop 会把 pump 整段阻塞，
        // 主循环在拖拽期间完全不转，MetalView.setFrameSize 里的回调是唯一渲染机会。
        // 不注册它，CoreAnimation 就只能拉伸旧帧（"画布像图片一样变形"）。
        app.win.setRenderCallback(liveResizeRender, @ptrCast(app));

        return app;
    }

    /// 用 App 自己装配的 FontSelector 顶替 runtime 内建的那套（`app.font_selector`）。
    ///
    /// == 为什么必须有这个 API，而不能只调 renderer.setFonts ==
    /// 「谁来回答一段文本有多宽」在 runtime 里有**四个**出口，init() 时全部
    /// 绑到内建字体上：
    ///   1. `renderer.fonts`，真正画字形的那套
    ///   2. `cx.measure_ctx`, measure_ctx_fn 的 context
    ///   3. `g_font_selector_for_measure`，无 context 的 measure_fn 兜底
    ///   4. GlyphRun 管线（shapeViaPipeline）自己解析的字体，光标定位、
    ///      选区端点、命中测试走的就是它
    ///
    /// 前三个走 FontSelector，第四个**完全不经过 FontSelector**。所以
    /// 「只换 selector」和「只换 renderer」一样不够：必须四个一起换。
    ///
    /// 第 4 个不能用 `font_manager.setDefaultFamily("Inter")` 糊过去：那只是
    /// 把 "system" 换个名字再去查**系统已安装**字体，而 Inter/Lora 是 App 用
    /// loadFont(path) 从仓库文件装的，系统库里没有，查不到就静默回退到别的
    /// 族，偏差反而从 1.442px 放大到 3.783px（实测）。只有把 FontSelector
    /// 本身交给管线当解析器，才能保证「量的和画的是同一个 *Font 对象」。
    ///
    /// == 漏掉第 4 个会怎样（本函数存在的直接原因）==
    /// measureTextWidthWithSpans **不是** 参数的纯函数：measureProportional
    /// 先试 g_shape_measure_fn（GlyphRun 管线，走出口 4），NaN 才回落到
    /// measure_ctx_fn / measure_fn（走出口 1~3）。于是同一行文本、同一组
    /// 参数，在「钩子装着」与「钩子没装」两种环境下得到不同答案：
    ///   fs=14 fw=450 "ssdf x😊"（Inter 排版、default_family 还是 HelveticaNeue）
    ///     钩子装着（GlyphRun/HelveticaNeue）= 57.906   <- computeCursorPos 走这条
    ///     钩子没装（FontSelector/Inter）    = 59.348   <- 布局与绘制走这条
    ///   差 1.442px，光标与选区端点因此**短**在字形右缘里侧，越往行尾差越大。
    /// 逐字符看，拉丁段每个字母都差（s 7.465->7.266、d 8.614->8.554、
    /// f 5.247->4.410…），emoji 段两边都是 19.000，这个 bug 与 emoji 无关，
    /// 纯英文行同样错，只是行尾 emoji 让缺口最显眼。
    ///
    /// `selector` 由调用方持有，生命周期必须覆盖整个 App；这里只借指针。
    pub fn setFontSelector(self: *App, selector: *FontSelector) void {
        self.renderer.setFonts(selector);
        self.renderer.initFontDerivedCache(self.allocator);
        // 立刻对齐当前 backing scale：scale_changed 只在**变化**时触发，
        // 已经在 2x 屏上装载的宿主 selector 否则会一直按 1x 光栅化。
        selector.setScaleFactor(self.scale);
        self.cx.text.measure_ctx_fn = measureTextWithCtx;
        self.cx.text.measure_ctx = @ptrCast(selector);
        // 出口 3 + 4：无 context 兜底与 GlyphRun 管线字体解析器（进程全局，
        // 经归属栈登记，见 text_hook_owners.zig）。
        // self 已在 init 登记：更新已有 owner 不扩容，不会失败。
        installProcessTextHooks(g_text_hook_owners.push(self, selector) catch
            @panic("text hook owner update must not allocate"));
    }

    /// 装上字体族解析器(render.FontRegistry)。
    ///
    /// 装到**当前生效的** FontSelector 上，内建的那个,或宿主经
    /// `setFontSelector` 换上来的那个。因为 resolveFonts 是测量与渲染
    /// 共用的唯一入口,装在这一处就同时覆盖四个出口。
    ///
    /// `registry` 由调用方持有,生命周期必须覆盖整个 App;这里只借指针。
    pub fn setFontRegistry(self: *App, registry: *render.FontRegistry) void {
        const sel = self.renderer.fonts orelse &self.font_selector;
        sel.family_resolve_fn = &resolveFamilyFont;
        sel.family_resolve_ctx = @ptrCast(registry);
        self.font_registry = registry;
        // 立刻对齐当前 scale，装载时可能已经在 2x 屏上了,
        // 等下一次 scale **变化**才同步的话首屏就是糊的。
        registry.setScaleFactor(self.scale);
    }

    pub fn deinit(self: *App) void {
        // Invalidate every native->Zig edge before releasing Cx/render state.
        // A closing window can still be inside live resize, IME composition, or
        // a drag session, so teardown order is part of the public contract.
        self.win.setRenderCallback(null, null);
        self.win.setTitlebarHitCallback(null, null);
        if (self.display_link_running) {
            self.win.stopDisplayLink();
            self.display_link_running = false;
        }
        if (test_harness.enabled and g_screenshot_app == self) {
            self.renderer.setRecordingActive(false);
            const recording = self.win.windowRecordingStatus();
            if (recording.active != 0) _ = self.win.stopWindowRecording();
        }
        if (g_test_cx == self.cx) g_test_cx = null;
        if (g_screenshot_app == self) g_screenshot_app = null;
        // Cx.deinit owns the atomic discard + disable transition. Calling the
        // backend here as well would reintroduce a second IME state writer.
        // These are legacy process-wide hooks. Hand them back to the next live
        // App (or clear them when none is left) before either the Cx or
        // selector can be released: never leave a dangling callback behind,
        // and never strip the hooks from another still-open window (closing
        // DevTools used to break measurement in the main window).
        installProcessTextHooks(g_text_hook_owners.remove(self));
        self.cx.deinit();
        self.sdk.deinit();
        // ⚠️ 先把**外来** selector 摘掉,再动 font-derived cache。
        //
        // `setFontSelector` 之后 `renderer.fonts` 指向的是**宿主自己的**
        // FontSelector,而它的生命周期不归 App 管。宿主惯常写法是
        //   var app = try App.init(...);   defer app.deinit();
        //   const font_set = try loadFonts(...);  defer font_set.deinit();
        // defer 是 LIFO,于是 font_set 先释放、App.deinit 后执行,
        // `deinitFontDerivedCache()` 就会去遍历一份**已释放**的 selector:
        // EXC_BAD_ACCESS,栈顶正是 `runtime.App.deinit`(实测下游编辑器
        // 每次关窗必崩)。
        //
        // 让 App 在拆自己之前先回到内建 selector:外来那份由宿主自己负责,
        // 我们既不释放它、也不再读它。这样宿主两种 defer 顺序都安全,
        // 生命周期契约不该由调用方的声明次序来保证。
        if (self.renderer.fonts != &self.font_selector) {
            self.renderer.setFonts(&self.font_selector);
        }
        self.renderer.deinitFontDerivedCache();
        for (self.fonts) |f| f.deinit();
        self.font_manager.deinit();
        self.renderer.deinit();
        self.allocator.destroy(self.renderer);
        self.surface.deinit();
        self.queue.deinit();
        self.device.deinit();
        self.instance.deinit();
        self.win.deinit();
        const allocator = self.allocator;
        // g_font_selector_for_measure 已在上面随归属栈回落到下一个存活 App
        // （或 null）。外来 selector 可能被多个窗口共享，只能断言内建那份。
        std.debug.assert(g_font_selector_for_measure != &self.font_selector);
        allocator.destroy(self);
    }

    /// Mount 函数签名，`runWith` / `mount` 接受这种回调。
    /// scope 由 App 创建并持有；返回的 root node 直接装上去。
    pub const MountFn = *const fn (cx: *ui.Cx, scope: *ui.Scope) anyerror!*ui.Node;

    /// 创建 root_scope、调用 mount_fn 构建 UI 树、把 root 装上 cx。
    /// 这把每个 mountUI() 都写过的 4 行 boilerplate 一次性吃掉。
    /// test-mode：把 file-RPC harness 的目标重新绑到本 App。
    /// `mount()` 的注册是"后到者赢"，多窗口宿主（DevTools 等辅助窗口也走
    /// App.mount）会把 g_test_cx / g_screenshot_app 顶成辅助窗口，此后所有
    /// RPC 按键/截图都打到错误的窗口上。宿主创建完辅助窗口后调用本方法把
    /// 主窗抢回来。非 test-mode 下是 no-op。
    pub fn rebindTestHarness(self: *App) void {
        if (!test_harness.enabled) return;
        g_test_cx = self.cx;
        g_screenshot_app = self;
    }

    pub fn mount(self: *App, mount_fn: MountFn) !void {
        // Build-first / commit-last 事务：任何一步失败都必须让 App 回到"未 mount"
        // 状态，且不留下任何指向已释放内存的字段，用户惯用 `defer app.deinit()`，
        // deinit 第一件事就是 cx.deinit()，会重新走一遍 root_scope / root。
        //
        // 注意不能简单地把赋值挪到最后：mount_fn 里的 `cx.provide()` 会调
        // ensureRootScope()，若此时 cx.root_scope 仍是 null，它会**另建**一个
        // scope 并装上去，于是 provide 的 context 落在孤儿 scope 上（用户
        // consume 不到），我们这个 root_scope 也再无人引用。
        // 所以：构建期间必须可见，失败时才回滚。
        const allocator = self.cx.allocator;
        // Window-root portal 必须在 mount_fn **之前**就存在。Popover /
        // Tooltip 在 mount_fn 里建树；如果到 mount_fn 返回后才填
        // cx.popover_portal_root，它们只能退化成挂在 anchor wrapper 旁边，
        // 实际上根本没走 portal。portal 是窗口级 containing block：其下
        // absolute floating content 等价于 CSS position:fixed，定位只用 viewport
        // 坐标，不再依赖 trigger 的祖先布局。
        const app_root = try ui.box(self.cx, .{
            .width = .{ .grow = .{} },
            .height = .{ .grow = .{} },
        }, .{});
        var app_root_orphan = true;
        errdefer if (app_root_orphan) app_root.destroy(allocator);

        const portal = try ui.box(self.cx, .{
            .position = .absolute,
            .width = .{ .grow = .{} },
            .height = .{ .grow = .{} },
        }, .{});
        var portal_orphan = true;
        errdefer if (portal_orphan) portal.destroy(allocator);
        portal.meta.ownership.meta.component_name = "WindowOverlayPortal";
        (try portal.style.ensureExtFallible(allocator)).z_index = ui.Cx.window_portal_z_index;
        // 注意：不能用 setHitTestVisible(false), hit-test 构建在不可见节点处直接
        // 剪掉**整棵子树**（hit_runtime.buildRecursive: !participates -> return），会让
        // portal 里的 Modal/Sheet 全部不可点（× 关不掉、遮罩点不消）。空 box 默认就没有
        // pointer hit role（defaultRoles: 无 handler/非 focusable/非 button -> pointer=false），
        // portal 自身本就不拦截命中，其子树（barrier/dialog）正常参与 hit-test。
        // Scope 晚于两个节点创建，errdefer 时会先 dispose scope，
        // 让 portaled content 的 resource cleanup 还能安全访问 portal，然后再销毁树。
        const root_scope = try ui.Scope.init(allocator, null, self.cx.owner);
        var root_scope_owned = true;
        errdefer if (root_scope_owned) {
            if (self.cx.root_scope == root_scope) self.cx.root_scope = null;
            if (self.cx.popover_portal_root == portal) self.cx.popover_portal_root = null;
            if (self.cx.root == app_root) self.cx.root = null;
            root_scope.dispose();
        };

        self.cx.root_scope = root_scope;
        self.cx.root = app_root;
        // portal 暂时是一棵 detached tree，但指针在 mount 期间已稳定；
        // floating nodes 可以直接挂进去。建树完成后再把整棵 portal 作为
        // app_root 的最后一个 child 提交，保证它画在用户树之上。
        self.cx.popover_portal_root = portal;

        const user_root = try mount_fn(self.cx, root_scope);

        // 以下两个 append 是本事务最后的可失败步骤。失败时必须
        // 先 dispose scope（它会从 detached portal 摘 floating content），
        // 再销毁孤立 user_root / app_root，不能依赖默认 errdefer 逆序。
        app_root.appendChild(allocator, user_root) catch |err| {
            root_scope.dispose();
            root_scope_owned = false;
            self.cx.root_scope = null;
            self.cx.popover_portal_root = null;
            self.cx.root = null;
            user_root.destroy(allocator);
            return err;
        };
        app_root.appendChild(allocator, portal) catch |err| {
            root_scope.dispose();
            root_scope_owned = false;
            self.cx.root_scope = null;
            self.cx.popover_portal_root = null;
            self.cx.root = null;
            return err;
        };
        portal_orphan = false; // 所有权已转移给 app_root

        // ── COMMIT ──────────────────────────────────────────────────────
        // 至此所有可失败步骤已完成。下面全是不可失败的字段赋值，一次性提交；
        // app_root 的所有权交给 cx（cx.deinit 负责销毁整棵树）。
        root_scope_owned = false;
        app_root_orphan = false;
        self.cx.is_mounted = true;

        // E2E test harness: 注册 cx 引用 + 截图 callback + 启 file RPC server (test-mode=true 时)
        if (test_harness.enabled) {
            g_test_cx = self.cx;
            g_screenshot_app = self;
            // 开启"呈现帧保留拷贝",让 /screenshot 读真实呈现而非新渲染帧
            self.renderer.retain_present_copy = true;
            self.renderer.setRecordingFrameCallback(appendWindowRecordingFrame);
            test_harness.setScreenshotCallback(captureScreenshot);
            test_harness.setRecordingCallbacks(startWindowRecording, windowRecordingStatus, stopWindowRecording);
            test_harness.setFrameStatsCallback(getFrameStats);
            test_harness.setResetTimingCallback(resetTiming);
            test_harness.setResizeWindowCallback(resizeWindowForHarness);
            test_harness.init(getTestCx, wakeTestHarness);
        }
    }

    /// 一站式：mount + run 主循环。推荐入口。
    /// ```
    /// try app.runWith(mountUI); // mountUI: fn(*ui.Cx, *ui.Scope) !*ui.Node
    /// ```
    pub fn runWith(self: *App, mount_fn: MountFn) !void {
        try self.mount(mount_fn);
        try self.run();
    }

    pub fn setMenuModel(self: *App, model: system_sdk.MenuModel) !void {
        try self.sdk.setMenuModel(model);
    }

    pub fn bindMenuCommand(self: *App, command_id: u64, action: ui.actions.Action) void {
        self.cx.bindCommandAction(command_id, action);
    }

    pub fn windowId(self: *const App) system_sdk.events.WindowId {
        return self.cx.window_id;
    }

    /// Programmatically make this window the active/key window. AppKit also
    /// establishes the window's Metal view as first responder for IME/Edit
    /// command routing.
    pub fn activate(self: *App) void {
        self.win.activate();
    }

    /// 跑主循环到窗口关闭。先调 `mount` / `runWith` 装好 UI 再调这个，
    /// 或者用更老的"手动写 mountUI 然后 app.run()"流程。
    /// 进阶应用：手动 pump + processEvents + frame，自己控制 cadence。
    pub fn run(self: *App) !void {
        // 首帧必渲染（needs_redraw 默认 true 也兜底，双保险）。
        var force_frame = true;
        const display_link_mode = self.config.frame_pacing == .display_link;
        // ZENIT_DEBUG_FRAMEPACE=1：帧节奏统计，每 120 个连续渲染帧打一行
        // mean/min/max/stddev dt（ms）。验证 vsync 对齐（60Hz 下应紧贴 16.67ms、
        // 无 16/33ms 交替的 beat pattern）。idle 间隙（>100ms）不计入。
        const pace_debug = std.posix.getenv("ZENIT_DEBUG_FRAMEPACE") != null;
        // ZENIT_DEBUG_JANK=1：逐帧探针，连续渲染帧间隔 > 20ms 时打一行
        // （100ms 以上视为 idle 间隙不计）。定位动画卡顿用。
        const jank_debug = std.posix.getenv("ZENIT_DEBUG_JANK") != null;
        var jank_prev: ?std.time.Instant = null;
        var pace_prev: ?std.time.Instant = null;
        var pace_dts: [120]f64 = undefined;
        var pace_n: usize = 0;
        while (!self.win.shouldClose() and !self.should_quit) {
            const pool = AutoreleasePool.push();
            defer pool.pop();
            // .poll：定时轮询（旧行为逐字保留）。
            // .display_link：pump 长超时纯阻塞，link 运行时每 vsync 由空事件唤醒；
            // link 停掉（idle）时靠输入事件唤醒，超时钳到最近的 wake deadline
            // （光标闪烁 scheduleRedrawAfterNs / deferred 任务），兜底 idle_wait_ms。
            const pump_timeout: u32 = if (display_link_mode)
                self.computeIdleTimeoutMs()
            else
                self.config.pump_timeout_ms;
            const pump_result = self.sdk.pump(pump_timeout) catch |err| {
                std.log.scoped(.zenit_runtime).err("sdk.pump failed: {s}", .{@errorName(err)});
                return err;
            };
            // 任何输入事件后至少渲染一帧：hover/cursor 等路径不保证翻 needs_redraw。
            if (self.sdk.events().len > 0 or pump_result.requested_redraw) force_frame = true;
            self.processEvents();
            // E2E test harness: 消费命令队列 (test-mode=true 时)
            if (test_harness.enabled) {
                test_harness.drainCommands();
            }
            if (self.should_quit) break;
            try self.maybeReconfigureSurface();

            // idle 停帧门控：树全 clean、无动画、无 deferred work 时跳过整个
            // GPU acquire/encode/present（改动前 idle 稳定 ~60fps 空转提交）。
            // needs_redraw 由 advanceFrameClock 在帧内边沿消费（时钟读完后清），
            // 这里不要提前清，会把本次唤醒的帧时钟冻住，时间驱动的 overlay
            // 入场动画会永远停在 0。
            const want = !self.config.idle_skip_frames or force_frame or self.cx.wantsFrame() or self.renderer.recording_active;
            // display link start/stop 与 idle 门控同一决策点：want 沿变启停。
            // want && !running 时本帧仍立即渲染（不等下个 vsync，输入延迟不变差）。
            if (display_link_mode) self.syncDisplayLink(want);
            if (want) {
                force_frame = false;
                const jank_t0 = if (jank_debug) std.time.Instant.now() catch null else null;
                try self.frame();
                if (jank_debug) {
                    if (std.time.Instant.now() catch null) |now| {
                        const cpu_ms = if (jank_t0) |t0| @as(f64, @floatFromInt(now.since(t0))) / 1e6 else 0;
                        if (jank_prev) |prev| {
                            const dt_ms = @as(f64, @floatFromInt(now.since(prev))) / 1e6;
                            if (dt_ms > 20.0 and dt_ms < 100.0) {
                                std.debug.print("[jank] dt={d:.1}ms frame_wall={d:.1}ms\n", .{ dt_ms, cpu_ms });
                            }
                        }
                        jank_prev = now;
                    }
                }
                if (pace_debug) {
                    if (std.time.Instant.now() catch null) |now| {
                        if (pace_prev) |prev| {
                            const dt_ms = @as(f64, @floatFromInt(now.since(prev))) / 1e6;
                            if (dt_ms < 100.0) {
                                pace_dts[pace_n] = dt_ms;
                                pace_n += 1;
                                if (pace_n == pace_dts.len) {
                                    var sum: f64 = 0;
                                    var min: f64 = pace_dts[0];
                                    var max: f64 = pace_dts[0];
                                    for (pace_dts) |d| {
                                        sum += d;
                                        min = @min(min, d);
                                        max = @max(max, d);
                                    }
                                    const mean = sum / @as(f64, @floatFromInt(pace_dts.len));
                                    var var_sum: f64 = 0;
                                    for (pace_dts) |d| var_sum += (d - mean) * (d - mean);
                                    const stddev = @sqrt(var_sum / @as(f64, @floatFromInt(pace_dts.len)));
                                    std.log.scoped(.zenit_framepace).info(
                                        "{d} frames: mean={d:.2}ms min={d:.2}ms max={d:.2}ms stddev={d:.2}ms",
                                        .{ pace_dts.len, mean, min, max, stddev },
                                    );
                                    pace_n = 0;
                                }
                            }
                        }
                        pace_prev = now;
                    }
                }
            }
        }
        // 退出主循环时停掉 link（destroy_window 也会兜底 stop+release）
        if (self.display_link_running) {
            self.win.stopDisplayLink();
            self.display_link_running = false;
        }
    }

    /// display-link 模式的 pump 超时：min(idle_wait_ms, 距最近 wake deadline)。
    /// test harness 下钳到 16ms, e2e RPC 命令写在文件里，纯事件阻塞不会被唤醒。
    fn computeIdleTimeoutMs(self: *App) u32 {
        var timeout_ms: u64 = self.config.idle_wait_ms;
        if (test_harness.enabled) timeout_ms = @min(timeout_ms, 16);
        if (self.cx.nextWakeDelayNs()) |delay_ns| {
            // 向上取整 + 至少 1ms：提前醒会空转一轮再睡，晚醒才是可感知的延迟
            const delay_ms = (delay_ns + std.time.ns_per_ms - 1) / std.time.ns_per_ms;
            timeout_ms = @min(timeout_ms, @max(delay_ms, 1));
        }
        return @intCast(timeout_ms);
    }

    /// 每轮唤醒按 want 沿启停 CVDisplayLink。
    /// 启动即时（保证下一 vsync 就有节拍）；停止带 2 次防抖，动画收尾帧常在
    /// clean/dirty 边界抖动，立即 stop 会造成 link 频繁启停。
    fn syncDisplayLink(self: *App, want: bool) void {
        if (want) {
            self.idle_streak = 0;
            if (!self.display_link_running) {
                self.win.startDisplayLink();
                self.display_link_running = true;
            }
        } else if (self.display_link_running) {
            self.idle_streak +|= 1;
            if (self.idle_streak >= 2) {
                self.win.stopDisplayLink();
                self.display_link_running = false;
            }
        }
    }

    /// 把 sdk 事件队列 dispatch 到 ui.Cx，处理 quit / resize 信号。
    pub fn processEvents(self: *App) void {
        // 遍历的是 event_queue 的借用切片：期间任何 handler 重入 pump()
        // 都会 clear() 释放正被遍历的 payload。标志 + pump 侧断言钉住契约。
        self.sdk.dispatching = true;
        defer self.sdk.dispatching = false;
        for (self.sdk.events()) |evt| _ = self.processEvent(evt);
    }

    /// Dispatch one event if it belongs to this window. This strict boundary
    /// makes `App` safe with a shared/multi-window backend while preserving the
    /// existing single-window `processEvents()` API.
    pub fn processEvent(self: *App, evt: system_sdk.events.Event) bool {
        if (evt.targetWindowId()) |target| {
            if (target != self.windowId()) return false;
        }
        // e2e 输入隔离：harness 直接向 Cx 注入指针事件（不经这里）；机器上真实鼠标的
        // move/button/wheel/magnify 若也进来，会覆盖注入的 hover 位置、打断点击
        // （开发者边跑 e2e 边用电脑时，zindex 等浮层用例偶发红的实锤根因）。
        // 只在 test-mode 构建且显式开启时丢弃，手工操作 test-mode app 不受影响。
        if (test_harness.enabled and isolateOsPointer()) switch (evt) {
            .mouse_move, .mouse_button, .mouse_wheel, .magnify => return true,
            else => {},
        };
        switch (evt) {
            .quit, .window_close_requested => self.should_quit = true,
            .frame_requested, .window_resized, .system_theme_changed => self.cx.needs_redraw = true,
            .window_focused => |e| {
                self.cx.needs_redraw = true;
                // 失焦取消进行中的 pointer 交互（drag 等）：blur 由轮询边沿
                // 产生，帧级延迟可接受（docs/DRAG_INTERACTION_DESIGN.md §11.2）。
                if (!e.focused) self.cx.cancelPointerInteractions(.window_blur) else self.cx.replayCursor();
            },
            .mouse_move => |e| self.cx.handleMouseMoveEx(e.x, e.y, sdkModifiersToUi(e.modifiers)),
            .mouse_button => |e| {
                const ui_btn = sdkMouseButtonToUi(e.button) orelse return true;
                const ui_mods = sdkModifiersToUi(e.modifiers);
                if (e.pressed) {
                    self.cx.handleMouseDownEx(e.x, e.y, ui_btn, ui_mods);
                } else {
                    self.cx.handleMouseUpEx(e.x, e.y, ui_btn, ui_mods);
                }
            },
            .mouse_wheel => |e| self.cx.handleSdkWheel(e),
            .magnify => |e| self.cx.handleMagnify(e.magnification, e.x, e.y, @enumFromInt(e.phase)),
            .drag => |e| {
                // kind=4 = 拖拽源完成回执（cx.handleDrag 侧防御性忽略）。
                // 排障可见性：ZENIT_DEBUG_DRAG=1 下打印实际 operation
                // （0=cancelled 1=copy 2=move 4=link）。
                if (e.kind == 4 and std.posix.getenv("ZENIT_DEBUG_DRAG") != null) {
                    std.debug.print("[DRAG] source-completed token={d} op={d}\n", .{ e.source_token, e.operation });
                }
                self.cx.handlePlatformDrag(e.x, e.y, e.kind, e.paths, e.payload_kind, e.payload_truncated, e.payload_is_untrusted);
            },
            .menu_command => |e| {
                if (std.posix.getenv("ZENIT_DEBUG_MENU") != null) {
                    std.debug.print("[MENU] command_id={d} window_id={d} (self={d})\n", .{ e.command_id, e.window_id, self.windowId() });
                }
                self.cx.handleCommand(e.command_id);
            },
            .key => |e| {
                const key = ui.events.KeyCode.fromRawKeycode(e.keycode);
                const ui_mods = sdkModifiersToUi(e.modifiers);
                if (e.pressed) self.cx.handleKeyDown(key, ui_mods) else self.cx.handleKeyUp(key, ui_mods);
            },
            .text_input => |e| self.cx.handleTextInput(e.text),
            .ime_preedit => |e| self.cx.handleImePreeditReplace(e.text, e.cursor_utf8_offset, e.replace_start_utf8, e.replace_end_utf8),
            .ime_commit => |e| self.cx.handleImeCommitReplace(e.text, e.replace_start_utf8, e.replace_end_utf8),
        }
        return true;
    }

    /// surface 配置的单一出口：init 与 resize 重配必须产出一致的配置。
    /// usage 依赖 test-mode, test 下 drawable 必须 CPU 可读（framebufferOnly=false），
    /// 否则 e2e 截图的 getBytes 读不到像素；此前 resize 路径硬编码
    /// .color_target_only，重配后 readback 花屏。生产构建仍走快路径。
    fn surfaceConfigFor(width: u32, height: u32) gpu.Backend.SurfaceConfiguration {
        return .{
            .format = .bgra8_unorm_srgb,
            .width = width,
            .height = height,
            .usage = if (test_harness.enabled) .color_target_and_read else .color_target_only,
            .present_mode = .fifo,
            .alpha_mode = .fully_opaque,
            .maximum_frame_latency = 2,
        };
    }

    /// 检测窗口大小变化，必要时重新配置 surface 和视口。
    pub fn maybeReconfigureSurface(self: *App) !void {
        const new_drawable = self.win.getDrawableSize();
        if (new_drawable[0] != self.current_drawable_w or new_drawable[1] != self.current_drawable_h) {
            self.current_drawable_w = new_drawable[0];
            self.current_drawable_h = new_drawable[1];
            try self.surface.configure(self.allocator, &self.device, surfaceConfigFor(self.current_drawable_w, self.current_drawable_h));
            // drawable 尺寸/DPI 变化必须重绘，否则纯 DPI 切换只重配 surface 会花屏
            self.cx.needs_redraw = true;
        }
        // HiDPI：backing scale 变化（把窗口拖到另一块 DPI 不同的屏幕、或系统
        // 改分辨率）必须传导下去。此前 `self.scale` 只在 App.init 赋值一次，
        // 于是 scale 变化后全链路继续用旧值：字体按旧 scale 光栅化、
        // cx.window_scale 用于 SVG 光栅尺寸也停在旧值。
        //
        // 这里用**每帧轮询**而非 windowDidChangeBackingProperties 观察者：
        // 本函数已经每帧跑、且已经在处理由同一事件引起的 drawable 尺寸变化，
        // 轮询一个 CGFloat 的成本可忽略，而加观察者要跨 ObjC->Zig 再引一套
        // 事件队列，多一条独立的时序路径（观察者先到、drawable 后到）反而更难
        // 保证两者同帧一致。system_sdk 侧本来也已经是轮询 getScaleFactor 的。
        const new_scale = self.win.getScaleFactor();
        const scale_changed = new_scale > 0 and new_scale != self.scale;
        if (scale_changed) {
            self.scale = new_scale;
            // 字体必须按新 scale 重新光栅化。Font.scale_factor 就地可变、
            // 不改变 Font 指针，glyph atlas 的 GlyphKey 含 scale_q，所以
            // 新 scale 会自然产生新缓存条目，旧条目则随页面 age-based GC
            // （EVICT_THRESHOLD）被回收，无需在此手动清空图集。
            //
            // 走 font_selector 而非只遍历 self.fonts：后者只有 small/medium/
            // large 三个基准字体，而非标准字号的文本实际用的是 FontSelector
            // 里的扩展槽位与 lazy derived font，漏掉它们会表现为"部分字号
            // 变清晰了、另一些依旧糊"。
            // 宿主经 setFontSelector 换上的 selector（renderer.fonts）才是真正
            // 画字/测量的那份，必须一并更新，只改内建那份时换屏后宿主字体
            // 停在旧 scale。
            selector_scale.syncSelectorScale(&self.font_selector, self.renderer.fonts, new_scale);
            // 字体族注册表的 face 是独立创建的,不在 font_selector 的槽位链上,
            // 必须单独跟 scale，否则换屏后画布上自定义字体的文字继续糊。
            if (self.font_registry) |reg| reg.setScaleFactor(new_scale);
        }

        // 刷新率同步给 Cx：DevTools Performance 面板的目标线/柱高基准、
        // renderer 的帧间隔钳制都读 cx.display_refresh_hz。与 scale 同为
        // 每帧轮询，把窗口拖到 ProMotion↔60Hz 混合屏之间必须跟上，
        // 且读一个 f32 的成本可忽略。
        const refresh_hz = self.win.getDisplayRefreshRate();
        if (refresh_hz > 0 and refresh_hz != self.cx.display_refresh_hz) {
            self.cx.display_refresh_hz = refresh_hz;
        }

        const new_size = self.win.getSize();
        const new_w: f32 = @floatFromInt(new_size[0]);
        const new_h: f32 = @floatFromInt(new_size[1]);
        if (new_w != self.viewport_w or new_h != self.viewport_h or scale_changed) {
            self.viewport_w = new_w;
            self.viewport_h = new_h;
            // 注意用 setWindowMetrics 而非 setViewport：后者把 scale 硬编码成
            // 1.0，在 Retina 上每次 resize 都会把 cx.window_scale 打回 1.0，
            // 导致 SVG 按 1x 光栅化（resolveSvgRasterSize 读的正是它）。
            self.cx.setWindowMetrics(self.viewport_w, self.viewport_h, self.scale);
            self.cx.needs_redraw = true;
        }
    }

    /// 渲染一帧。
    pub fn frame(self: *App) !void {
        // 手写主循环（pump + frame 自己控制 cadence）的宿主同样需要 pool；
        // run()/tick() 外层已有一层，这里嵌套一层无害。
        const pool = AutoreleasePool.push();
        defer pool.pop();
        try self.renderer.frame(self.cx, self.viewport_w, self.viewport_h, self.scale);
    }

    /// 主动退出主循环（事件 handler 里调用）。
    pub fn quit(self: *App) void {
        self.should_quit = true;
    }
};

/// Application-level configuration for the public multi-window runtime.
pub const MultiWindowConfig = struct {
    /// Only the first window pump may block. Remaining registered windows are
    /// drained non-blockingly after AppKit has distributed the native events.
    pump_timeout_ms: u32 = 16,
};

/// A real multi-window application runtime.
///
/// Every returned `*App` owns an independent native window, Cx, font system,
/// Metal surface, renderer, device/queue, IME route, and accessibility route.
/// `MultiWindowApp` owns the application loop and routes native events/menu
/// commands by window id. Closing one window destroys only that window; closing
/// the last window terminates `run()`.
///
/// The existing single-window `App` API remains unchanged.
pub const MultiWindowApp = struct {
    /// Explicit public bound for the allocation-free lifecycle ledger.
    /// `createWindow*` returns `error.TooManyWindows` above this count.
    pub const max_windows: usize = window_lifecycle.MAX_WINDOWS;

    const ManagedWindow = struct {
        app: *App,
        force_frame: bool = true,
    };

    allocator: Allocator,
    config: MultiWindowConfig,
    windows: std.ArrayList(ManagedWindow) = .{},
    lifecycle: window_lifecycle.State = .{},
    iterating: bool = false,

    pub fn init(allocator: Allocator, config: MultiWindowConfig) MultiWindowApp {
        return .{ .allocator = allocator, .config = config };
    }

    pub fn deinit(self: *MultiWindowApp) void {
        // Reverse creation order mirrors nested ownership and avoids activating
        // fallback windows while the whole application is shutting down.
        while (self.windows.items.len > 0) {
            const managed = self.windows.pop().?;
            managed.app.deinit();
        }
        self.windows.deinit(self.allocator);
        self.lifecycle = .{};
        self.iterating = false;
    }

    pub fn windowCount(self: *const MultiWindowApp) usize {
        return self.windows.items.len;
    }

    /// Native registry count for lifecycle diagnostics and real-window smoke
    /// evidence. Application logic should normally use `windowCount()`.
    pub fn nativeWindowCount() u32 {
        return Window.liveWindowCount();
    }

    pub fn window(self: *MultiWindowApp, window_id: system_sdk.events.WindowId) ?*App {
        const index = self.indexOf(window_id) orelse return null;
        return self.windows.items[index].app;
    }

    pub fn activeWindow(self: *MultiWindowApp) ?*App {
        return self.window(self.lifecycle.active_window_id orelse return null);
    }

    /// Create an unmounted window. Call `App.mount` on the result before run,
    /// or use `createWindowWith` for transactional create+mount.
    pub fn createWindow(self: *MultiWindowApp, config: Config) !*App {
        try self.ensureWindowCapacity();
        const app = try App.init(self.allocator, config);
        errdefer app.deinit();
        try self.adopt(app);
        return app;
    }

    /// Transactional create+mount: a mount failure tears down every native/GPU
    /// resource and does not leave a half-registered application window.
    pub fn createWindowWith(self: *MultiWindowApp, config: Config, mount_fn: App.MountFn) !*App {
        try self.ensureWindowCapacity();
        const app = try App.init(self.allocator, config);
        errdefer app.deinit();
        try app.mount(mount_fn);
        try self.adopt(app);
        return app;
    }

    pub fn activateWindow(self: *MultiWindowApp, window_id: system_sdk.events.WindowId) bool {
        const app = self.window(window_id) orelse return false;
        self.lifecycle.setFocused(window_id, true);
        app.activate();
        return true;
    }

    /// Close one window. Calls from an input/menu/render callback are queued and
    /// committed at the safe iteration boundary; calls outside the loop tear it
    /// down immediately.
    pub fn closeWindow(self: *MultiWindowApp, window_id: system_sdk.events.WindowId) bool {
        if (!self.lifecycle.requestClose(window_id)) return false;
        if (!self.iterating) self.applyPendingCloses();
        return true;
    }

    /// Set the process-global macOS menu model. Custom command callbacks remain
    /// per-window because native invocation captures the key window id.
    pub fn setMenuModel(self: *MultiWindowApp, model: system_sdk.MenuModel) !void {
        const target = self.activeWindow() orelse return error.NoWindows;
        try target.setMenuModel(model);
    }

    pub fn bindMenuCommand(
        self: *MultiWindowApp,
        window_id: system_sdk.events.WindowId,
        command_id: u64,
        action: ui.actions.Action,
    ) !void {
        const target = self.window(window_id) orelse return error.UnknownWindow;
        target.bindMenuCommand(command_id, action);
    }

    /// Pump AppKit once and dispatch all per-window queues. Returns false after
    /// Cmd+Q, explicit `quit`, or teardown of the last window.
    pub fn pump(self: *MultiWindowApp, timeout_ms: u32) !bool {
        if (!self.shouldContinue()) return false;
        {
            std.debug.assert(!self.iterating);
            self.iterating = true;
            defer self.iterating = false;

            var index: usize = 0;
            while (index < self.windows.items.len) : (index += 1) {
                const managed = &self.windows.items[index];
                const result = try managed.app.sdk.pump(if (index == 0) timeout_ms else 0);
                if (!result.should_continue) self.lifecycle.requestQuit();
                if (result.requested_redraw or managed.app.sdk.events().len > 0) {
                    managed.force_frame = true;
                }
                managed.app.sdk.dispatching = true;
                defer managed.app.sdk.dispatching = false;
                for (managed.app.sdk.events()) |evt| self.dispatchEvent(managed.app.windowId(), evt);
                if (self.lifecycle.quit_requested) break;
            }
        }
        self.applyPendingCloses();
        return self.shouldContinue();
    }

    /// Reconfigure and render every live window independently.
    pub fn frame(self: *MultiWindowApp) !void {
        if (!self.shouldContinue()) return;
        {
            std.debug.assert(!self.iterating);
            self.iterating = true;
            defer self.iterating = false;

            for (self.windows.items) |*managed| {
                const app = managed.app;
                try app.maybeReconfigureSurface();
                const want = !app.config.idle_skip_frames or managed.force_frame or app.cx.wantsFrame() or app.renderer.recording_active;
                if (app.config.frame_pacing == .display_link) app.syncDisplayLink(want);
                if (want) {
                    managed.force_frame = false;
                    try app.frame();
                }
            }
        }
        self.applyPendingCloses();
    }

    pub fn tick(self: *MultiWindowApp) !bool {
        const pool = AutoreleasePool.push();
        defer pool.pop();
        if (!try self.pump(self.config.pump_timeout_ms)) return false;
        // MultiWindowApp owns the event loop just like App.run(). Drain the
        // process-global Harness queue exactly once after platform events so
        // DevTools and other auxiliary-window apps remain automatable.
        if (test_harness.enabled) test_harness.drainCommands();
        if (!self.shouldContinue()) return false;
        try self.frame();
        return self.shouldContinue();
    }

    /// Run until the last window closes or an application-wide quit is
    /// requested. Quit stops pumping and returns; the owning caller's deferred
    /// `deinit()` then destroys every remaining native/GPU/UI window resource.
    pub fn run(self: *MultiWindowApp) !void {
        while (try self.tick()) {}
        for (self.windows.items) |*managed| {
            if (managed.app.display_link_running) {
                managed.app.win.stopDisplayLink();
                managed.app.display_link_running = false;
            }
        }
    }

    pub fn quit(self: *MultiWindowApp) void {
        self.lifecycle.requestQuit();
        Window.postEmptyEvent();
    }

    pub fn shouldContinue(self: *const MultiWindowApp) bool {
        return !self.lifecycle.quit_requested and self.windows.items.len > 0;
    }

    fn ensureWindowCapacity(self: *MultiWindowApp) !void {
        if (self.windows.items.len >= max_windows) return error.TooManyWindows;
        try self.windows.ensureUnusedCapacity(self.allocator, 1);
    }

    fn adopt(self: *MultiWindowApp, app: *App) !void {
        try self.lifecycle.add(app.windowId());
        self.windows.appendAssumeCapacity(.{ .app = app });
    }

    fn dispatchEvent(
        self: *MultiWindowApp,
        pump_owner_window_id: system_sdk.events.WindowId,
        evt: system_sdk.events.Event,
    ) void {
        switch (evt) {
            .quit => {
                self.lifecycle.requestQuit();
                return;
            },
            .window_close_requested => |e| {
                _ = self.lifecycle.requestClose(e.window_id);
                return;
            },
            .window_focused => |e| {
                self.lifecycle.setFocused(e.window_id, e.focused);
                self.dispatchToWindow(e.window_id, evt);
                return;
            },
            .menu_command => |e| {
                // The native menu queue is process-global, so A's SDK pump may
                // dequeue a command captured while B was key. Never infer the
                // target from the pump owner; route the captured id instead.
                const target = self.lifecycle.menuTargetFromPump(pump_owner_window_id, e.window_id) orelse return;
                self.dispatchToWindow(target, evt);
                return;
            },
            .frame_requested, .system_theme_changed => {
                for (self.windows.items) |*managed| {
                    _ = managed.app.processEvent(evt);
                    managed.force_frame = true;
                }
                return;
            },
            else => {},
        }
        const target = evt.targetWindowId() orelse return;
        self.dispatchToWindow(target, evt);
    }

    fn dispatchToWindow(self: *MultiWindowApp, window_id: system_sdk.events.WindowId, evt: system_sdk.events.Event) void {
        const index = self.indexOf(window_id) orelse return;
        const managed = &self.windows.items[index];
        if (managed.app.processEvent(evt)) managed.force_frame = true;
        // `App.quit()` remains meaningful when a window is managed: it closes
        // that window, while `MultiWindowApp.quit()` exits the application.
        if (managed.app.should_quit) _ = self.lifecycle.requestClose(window_id);
    }

    fn applyPendingCloses(self: *MultiWindowApp) void {
        std.debug.assert(!self.iterating);
        while (self.lifecycle.popPendingClose()) |window_id| {
            self.destroyWindowNow(window_id);
        }
    }

    fn destroyWindowNow(self: *MultiWindowApp, window_id: system_sdk.events.WindowId) void {
        const index = self.indexOf(window_id) orelse return;
        const managed = self.windows.orderedRemove(index);
        _ = self.lifecycle.removed(window_id);
        managed.app.deinit();
        // AppKit normally promotes a remaining window. Make the lifecycle
        // fallback explicit so first responder/IME/menu routing is never left
        // attached to the destroyed context.
        if (!self.lifecycle.quit_requested) {
            if (self.activeWindow()) |active| active.activate();
        }
    }

    fn indexOf(self: *const MultiWindowApp, window_id: system_sdk.events.WindowId) ?usize {
        for (self.windows.items, 0..) |managed, index| {
            if (managed.app.windowId() == window_id) return index;
        }
        return null;
    }
};

// ============================================================================
// 私有 helpers
// ============================================================================

/// live resize 期间由 MetalView.setFrameSize 同步调入：重配 surface/viewport 并渲染，
/// 让内容跟随窗口逐帧重排（native 行为），而不是被 CoreAnimation 拉伸旧帧。
/// 非 live-resize 的 setFrameSize（程序化改尺寸）交回主循环处理，避免 frame() 重入。
fn liveResizeRender(ctx: ?*anyopaque) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(ctx orelse return));
    if (!app.win.isInLiveResize()) return;
    if (app.in_live_resize_render) return;
    app.in_live_resize_render = true;
    defer app.in_live_resize_render = false;
    app.maybeReconfigureSurface() catch |err| {
        std.log.scoped(.zenit_runtime).warn("live-resize surface reconfigure failed: {s}", .{@errorName(err)});
        return;
    };
    // 既被 setFrameSize:（尺寸变了 -> maybeReconfigureSurface 置 needs_redraw）调用，
    // 也被原生 live-resize ticker 按刷新率调用（拖动按住期间驱动动画）；
    // 静止且尺寸未变时不重画。
    if (!app.cx.wantsFrame()) return;
    app.frame() catch |err| {
        std.log.scoped(.zenit_runtime).warn("live-resize frame failed: {s}", .{@errorName(err)});
    };
}

/// 字体 fallback 链，找到第一个能用的就返回。
/// macOS 还会尝试系统字体目录绝对路径作为最后兜底。
const ResolvedFont = struct { font: *Font, family: []const u8 };

fn loadWeightedFont(context: *anyopaque, font_size: f32, font_weight: u16) ?*Font {
    const app: *App = @ptrCast(@alignCast(context));
    const family = app.resolved_font_family orelse return null;
    const Desc = @typeInfo(@TypeOf(FontManager.findFont)).@"fn".params[1].type.?;
    const weight: @FieldType(Desc, "weight") = if (font_weight <= 100) .thin else if (font_weight <= 300) .light else if (font_weight <= 400) .regular else if (font_weight <= 500) .medium else if (font_weight <= 600) .semibold else if (font_weight <= 700) .bold else if (font_weight <= 800) .heavy else .black;
    return app.font_manager.findFont(.{ .family = family, .size = font_size, .weight = weight, .style = .normal }) catch null;
}

fn findFontWithFallback(fm: *FontManager, size: u32, families: []const []const u8) !ResolvedFont {
    for (families) |family| {
        if (fm.findFont(.{
            .family = family,
            .size = @floatFromInt(size),
            .weight = .regular,
            .style = .normal,
        }) catch null) |font| {
            return .{ .font = font, .family = family };
        }
    }
    if (comptime builtin.os.tag == .macos) {
        const paths = [_][:0]const u8{
            "/System/Library/Fonts/Helvetica.ttc",
            "/System/Library/Fonts/Menlo.ttc",
        };
        const path_families = [_][]const u8{ "Helvetica", "Menlo" };
        inline for (paths, path_families) |path, fam| {
            if (fm.loadFont(path, size) catch null) |font| {
                return .{ .font = font, .family = fam };
            }
        }
    }
    return error.FontLoadFailed;
}

// measure_fn 签名 (`*const fn ([*]const u8, usize, f32, u16, bool) f32`) 不接受
// context 参数，只能走全局静态指针。它只保留给直接读取旧 `Cx.measure_fn`
// 的兼容代码；框架内部和布局主路径使用 `measure_ctx_fn` / `Cx.measureTextWidth`
// 来保证多窗口字体上下文隔离。
var g_font_selector_for_measure: ?*FontSelector = null;

/// 进程级文本钩子的归属栈：钩子恒指向栈顶 App 的 selector。
var g_text_hook_owners: text_hook_owners.OwnerStack(MultiWindowApp.max_windows) = .{};

/// 把三个进程级文本出口（无 context measure 兜底 / GlyphRun 字体解析器 /
/// drawn-width 测量）一起指向 `ctx`（一个 *FontSelector），null 则全部卸载。
fn installProcessTextHooks(ctx: ?*anyopaque) void {
    if (ctx) |c| {
        g_font_selector_for_measure = @ptrCast(@alignCast(c));
        ui.text_shaping.setShapeFontResolver(&resolveShapeFont, c);
        ui.text_shaping.setDrawnTextMeasure(&measureShapeTextAsDrawn, c);
    } else {
        g_font_selector_for_measure = null;
        ui.text_shaping.setShapeFontResolver(null, null);
        ui.text_shaping.setDrawnTextMeasure(null, null);
    }
}

/// 带 context 的测量，context 是本 App 的 FontSelector，故多 App 并存
/// 时不会互相覆盖（对比下面读全局静态指针的 measureText）。
fn measureTextWithCtx(ctx: *anyopaque, text_ptr: [*]const u8, text_len: usize, font_size: f32, font_weight: u16, use_italic: bool) f32 {
    const fs: *FontSelector = @ptrCast(@alignCast(ctx));
    return fs.measureTextWidth(text_ptr[0..text_len], font_size, font_weight, use_italic);
}

/// GlyphRun 管线的字体解析器：与渲染共用 FontSelector.resolveFonts，
/// 且**带 content**，含汉字/假名/谚文时和渲染一样切到回退字体。
///
/// == 为什么用 shapingFont() 而不是 `fallback orelse primary` ==
/// 渲染端（command_encoder.encodeText）把 `primary` 交给 shaper 当**整段
/// 的字体**，`fallback` 只是逐字形补漏的提示（CoreText 自己按 run 属性挑，
/// 见 text_renderer.getOrCreateGlyphFallbackFont）。测量端若反过来优先
/// 取 fallback，就会拿一个与绘制不同的字体去 shape 整段。
///
/// 斜体是这条错路唯一必然踩中的场景：resolveContentFallback 对 italic
/// 恒返回 upright 的 regular_font（给 italic 面缺字形时兜底），于是
/// **每一段斜体文本**都按直立字体测量、按斜体字体绘制。Inter Italic 比
/// upright 宽，`.fit` 容器因此照直立宽度收紧，斜体字被裁在右缘,
/// 下游编辑器的 preview file tab（单击预览＝斜体）长文件名尾部丢字即此因。
fn resolveFamilyFont(
    ctx: *anyopaque,
    family: u16,
    size: f32,
    weight: u16,
    italic: bool,
) ?*Font {
    const reg: *render.FontRegistry = @ptrCast(@alignCast(ctx));
    return reg.resolve(@enumFromInt(family), size, weight, italic);
}

fn resolveShapeFont(
    ctx: *anyopaque,
    content: []const u8,
    font_size: f32,
    font_weight: u16,
    use_italic: bool,
    use_monospace: bool,
    font_family: u16,
) ?*Font {
    const fs: *FontSelector = @ptrCast(@alignCast(ctx));
    return fs.resolveFonts(content, .{
        .font_size = font_size,
        .font_weight = font_weight,
        // 必须原样传下去，这是出口 4,漏了它测量端就用默认族、
        // 渲染端用用户选的族,光标/选区系统性偏移。
        .font_family = font_family,
        .use_italic = use_italic,
        .use_monospace = use_monospace,
    }).shapingFont();
}

/// Authoritative rich-text measurement bridge. FontSelector is already bound
/// by AppRenderer.setFonts to this App's stable TextRenderer, so this executes
/// the same segmentation, fallback-stack selection and glyph-advance loop as
/// drawing instead of reshaping with an approximate local font.
fn measureShapeTextAsDrawn(
    ctx: *anyopaque,
    content: []const u8,
    font_size: f32,
    font_weight: u16,
    use_italic: bool,
    use_monospace: bool,
    font_family: u16,
    use_symbols: bool,
    monospace_char_width: f32,
) ?f32 {
    const fs: *FontSelector = @ptrCast(@alignCast(ctx));
    return fs.measureTextWidthWithProps(content, .{
        .font_size = font_size,
        .font_weight = font_weight,
        .font_family = font_family,
        .use_italic = use_italic,
        .use_monospace = use_monospace,
        .use_symbols = use_symbols,
        .monospace_char_width = monospace_char_width,
    });
}

fn measureText(text_ptr: [*]const u8, text_len: usize, font_size: f32, font_weight: u16, use_italic: bool) f32 {
    const fs = g_font_selector_for_measure orelse return @as(f32, @floatFromInt(text_len)) * font_size * 0.5;
    return fs.measureTextWidth(text_ptr[0..text_len], font_size, font_weight, use_italic);
}

fn sdkModifiersToUi(m: system_sdk.events.Modifiers) ui.events.Modifiers {
    return .{ .shift = m.shift, .ctrl = m.ctrl, .alt = m.alt, .super = m.super };
}

fn sdkMouseButtonToUi(btn: system_sdk.events.MouseButton) ?ui.events.MouseButton {
    return switch (btn) {
        .left => .left,
        .right => .right,
        .middle => .middle,
        .other => null,
    };
}

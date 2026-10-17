const builtin = @import("builtin");

pub const TitlebarStyle = enum {
    default,
    /// Application content extends into the caption. Native window controls
    /// remain owned by the platform; the application draws its caption body.
    custom_inset,
};

pub const WindowChrome = @import("system_sdk").window_chrome.Config;

/// A native key event offered to `Config.on_key` before UI dispatch.
pub const KeyEvent = struct {
    key: @import("ui").events.KeyCode,
    modifiers: @import("ui").events.Modifiers,
    pressed: bool,
};

/// Initial position of a window.
pub const Placement = enum {
    /// Platform default (AppKit centres on screen, Win32 cascades).
    default,
    /// Centre on `WindowConfig.owner`, slightly above the middle and clamped to
    /// the owner's screen work area. Palette / find panel convention.
    center_on_owner,
};

pub const WindowConfig = struct {
    min_width: u32 = 0,
    min_height: u32 = 0,
    /// Zoom/maximize affordance (green button, title-bar double-click,
    /// performZoom:). macOS honors this today; other backends reject `false`
    /// with error.UnsupportedWindowCapability rather than silently maximizing.
    maximizable: bool = true,
    /// Window state restoration. Transient windows (panels, dashboards) opt
    /// out so they never join the platform restore pass. Only macOS has a
    /// restore pass; elsewhere `false` is trivially true.
    restorable: bool = true,
    width: if (builtin.os.tag == .windows) u32 else u16 = 800,
    height: if (builtin.os.tag == .windows) u32 else u16 = 600,
    title: [:0]const u8 = if (builtin.os.tag == .windows) "Zenit" else "zenit",
    /// New API takes precedence. Null translates the legacy titlebar settings.
    chrome: ?WindowChrome = null,
    titlebar: TitlebarStyle = .default,
    titlebar_height: f32 = 52,
    titlebar_drag_right_inset: f32 = 0,
    /// Experimental AppKit host prototype; other backends reject visible policies.
    /// Final host preference/fallback contract is not frozen yet.
    fullscreen_header: @import("system_sdk").window_chrome.HeaderVisibility = .hidden,
    /// Owner window (MultiWindowApp only). An owned window stays above its
    /// owner, comes forward with it, never floats over other applications, and
    /// is closed with it. Use with `chrome = .frameless` for panels. Linux
    /// keeps an independent window for now.
    owner: ?@import("system_sdk").events.WindowId = null,
    placement: Placement = .default,
};

pub fn requestedChrome(config: WindowConfig) WindowChrome {
    return config.chrome orelse switch (config.titlebar) {
        .default => .native,
        // Legacy custom_inset was a no-op on Linux; opt in through chrome.
        .custom_inset => if (builtin.os.tag == .linux) .native else .{ .custom = .{} },
    };
}

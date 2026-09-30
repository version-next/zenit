const builtin = @import("builtin");

pub const Backend = switch (builtin.target.os.tag) {
    .macos => @import("macos/window.zig"),
    else => @import("unsupported/window.zig"),
};

pub const Window = switch (builtin.target.os.tag) {
    .macos => Backend.MacOSWindow,
    else => Backend.UnsupportedWindow,
};

// Re-export common types
pub const KeyEvent = Window.KeyEvent;
pub const Modifiers = Window.Modifiers;
pub const MouseButton = Window.MouseButton;
pub const KeyCode = Window.KeyCode;
pub const MenuAction = Window.MenuAction;

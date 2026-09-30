// Platform-specific window and input implementations
// Re-exports from the platform module with comptime backend selection

const platform = @import("platform/platform.zig");

pub const Window = platform.Window;
pub const KeyEvent = platform.KeyEvent;
pub const Modifiers = platform.Modifiers;
pub const MouseButton = platform.MouseButton;
pub const KeyCode = platform.KeyCode;
pub const MenuAction = platform.MenuAction;

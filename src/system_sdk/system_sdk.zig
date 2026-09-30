/// System SDK - 统一系统通信层
///
/// Phase 0:
/// - 收敛跨平台系统 API
/// - 定义后端 SPI（vtable）
/// - 定义统一事件模型
/// - 支持能力探测（capabilities）
const std = @import("std");

pub const api = @import("api.zig");
pub const vtable = @import("vtable.zig");
pub const backends = @import("backends/mod.zig");
pub const events = @import("events.zig");
pub const capabilities = @import("capabilities.zig");
pub const accessibility = @import("accessibility.zig");
pub const errors = @import("errors.zig");

pub const SystemSdk = api.SystemSdk;
pub const ClipboardKinds = api.ClipboardKinds;
pub const ClipboardImage = api.ClipboardImage;
pub const MenuModel = vtable.MenuModel;
pub const MenuNode = vtable.MenuNode;
pub const MenuRole = vtable.MenuRole;
pub const MenuNodeKind = vtable.MenuNodeKind;
pub const DragPayloadKind = vtable.DragPayloadKind;
pub const DragOperations = vtable.DragOperations;
pub const DragRequest = vtable.DragRequest;
pub const BackendVTable = vtable.BackendVTable;
pub const HapticFeedbackPattern = vtable.HapticFeedbackPattern;
pub const PumpResult = vtable.PumpResult;
pub const Event = events.Event;
pub const EventQueue = events.EventQueue;
pub const Capabilities = capabilities.Capabilities;
pub const Capability = capabilities.Capability;
pub const AccessibilityRole = accessibility.Role;
pub const AccessibilityNodeSnapshot = accessibility.NodeSnapshot;
pub const SdkError = errors.SdkError;

test {
    std.testing.refAllDecls(@This());
}

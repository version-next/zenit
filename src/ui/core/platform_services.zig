//! 系统剪贴板与文件对话框，从 `Cx` 析出的 system_sdk 门面。
//!
//! 这些函数原本是 `Cx` 上的 11 个方法，但它们只碰一个东西：`Cx.system_sdk`。
//! 放在 `Cx` 上意味着任何拿到 `*Cx` 的组件都能顺手敲系统剪贴板，而且这套
//! 逻辑没法脱离一个完整的 `Cx` 来测。
//!
//! 这里的函数直接收 `?*SystemSdk`，因此：
//! - 可以用一个假的 sdk（或 null）独立单测「没有 SDK / SDK 报错」两条路径
//! - `Cx` 上保留的同名方法只是转发，既有调用点不受影响
//!
//! 错误语义沿用原实现：绝大多数入口把失败压成 `false` / `null` / 零值
//! （剪贴板不可用不该让 UI 崩），只有 `clipboardGetTextAllocChecked` 保留
//! 真正的错误联合，让调用方能区分「没有文本」和「读失败/分配失败」。

const std = @import("std");
const system_sdk_mod = @import("system_sdk");

const Sdk = system_sdk_mod.SystemSdk;

// ── 文件对话框 ──────────────────────────────────────────────────────────

pub fn fileDialogAvailable(sdk_opt: ?*Sdk) bool {
    const sdk = sdk_opt orelse return false;
    return sdk.getCapabilities().has(.file_dialog);
}

/// 弹出原生"打开文件"对话框（同步阻塞至用户选择/取消）。
/// 返回写入 buffer 的路径 slice；null = 无 SDK / 不支持 / 用户取消 / 出错。
pub fn openFilePanel(sdk_opt: ?*Sdk, buffer: []u8) ?[]const u8 {
    const sdk = sdk_opt orelse return null;
    return (sdk.runDialog(.{ .kind = .open_file }, buffer) catch return null) orelse null;
}

// ── 剪贴板 ─────────────────────────────────────────────────────────────

pub fn clipboardAvailable(sdk_opt: ?*Sdk) bool {
    const sdk = sdk_opt orelse return false;
    return sdk.getCapabilities().has(.clipboard);
}

/// 写入系统剪贴板。false = 无 SDK 或写失败。
pub fn clipboardSetText(sdk_opt: ?*Sdk, clip_text: []const u8) bool {
    const sdk = sdk_opt orelse return false;
    sdk.clipboardSetText(clip_text) catch return false;
    return true;
}

/// 读取系统剪贴板到调用方 buffer。
pub fn clipboardGetText(sdk_opt: ?*Sdk, buffer: []u8) ?[]const u8 {
    const sdk = sdk_opt orelse return null;
    return sdk.clipboardGetText(buffer) catch null;
}

/// 动态分配版。调用者负责释放（或用 frame_arena）。
pub fn clipboardGetTextAlloc(sdk_opt: ?*Sdk, alloc: std.mem.Allocator) ?[]const u8 {
    return clipboardGetTextAllocChecked(sdk_opt, alloc) catch null;
}

/// Checked variant: null means no text; missing SDK/support and read or
/// allocation failures remain distinguishable. Caller frees nonempty text.
pub fn clipboardGetTextAllocChecked(
    sdk_opt: ?*Sdk,
    alloc: std.mem.Allocator,
) system_sdk_mod.SdkError!?[]const u8 {
    const sdk = sdk_opt orelse return error.NotSupported;
    return sdk.clipboardGetTextAlloc(alloc);
}

/// 探测剪贴板可提供的类型（text/image/file_urls）。不解码，Cmd+V 时随手可查。
pub fn clipboardProbe(sdk_opt: ?*Sdk) system_sdk_mod.ClipboardKinds {
    const sdk = sdk_opt orelse return .{};
    return sdk.clipboardProbe() catch .{};
}

/// 剪贴板中的图片项数（支持 Finder 多选复制）；不支持时返回 0。
pub fn clipboardImageCount(sdk_opt: ?*Sdk) usize {
    const sdk = sdk_opt orelse return 0;
    return sdk.clipboardImageCount() catch 0;
}

/// 读取第 index 项剪贴板图片（premultiplied RGBA8 + 原始编码字节）。
/// null = 无图片或不支持。返回值用 `ClipboardImage.deinit(alloc)` 释放。
pub fn clipboardGetImageAlloc(
    sdk_opt: ?*Sdk,
    alloc: std.mem.Allocator,
    index: usize,
) ?system_sdk_mod.ClipboardImage {
    const sdk = sdk_opt orelse return null;
    return sdk.clipboardGetImageAlloc(alloc, index) catch null;
}

/// 写入 PNG 编码图片到剪贴板；false = 不支持或失败。
pub fn clipboardSetImagePng(sdk_opt: ?*Sdk, png_bytes: []const u8) bool {
    const sdk = sdk_opt orelse return false;
    sdk.clipboardSetImagePng(png_bytes) catch return false;
    return true;
}

// ── 测试 ───────────────────────────────────────────────────────────────
//
// 无 SDK 路径（sdk == null）是这层唯一能脱离真实系统独立验证的分支，也正是
// 宿主在 headless / 测试环境里实际会走到的那条。每个入口都必须安全降级而不是
// 崩，这就是下面这组测试钉住的契约。

test "无 SDK 时全部入口安全降级" {
    const alloc = std.testing.allocator;
    var buf: [64]u8 = undefined;

    try std.testing.expect(!fileDialogAvailable(null));
    try std.testing.expectEqual(@as(?[]const u8, null), openFilePanel(null, &buf));

    try std.testing.expect(!clipboardAvailable(null));
    try std.testing.expect(!clipboardSetText(null, "x"));
    try std.testing.expectEqual(@as(?[]const u8, null), clipboardGetText(null, &buf));
    try std.testing.expectEqual(@as(?[]const u8, null), clipboardGetTextAlloc(null, alloc));
    try std.testing.expectEqual(@as(usize, 0), clipboardImageCount(null));
    try std.testing.expectEqual(@as(?system_sdk_mod.ClipboardImage, null), clipboardGetImageAlloc(null, alloc, 0));
    try std.testing.expect(!clipboardSetImagePng(null, "png"));

    // probe 返回"什么都没有"的空集合，而不是崩或假阳性
    const kinds = clipboardProbe(null);
    try std.testing.expect(!kinds.text);
    try std.testing.expect(!kinds.image);
}

test "无 SDK 时 checked 变体保留可区分的错误" {
    // 非 checked 版把一切压成 null；checked 版必须让调用方能区分
    // 「剪贴板里没文本」和「根本没有 SDK」。
    try std.testing.expectError(
        error.NotSupported,
        clipboardGetTextAllocChecked(null, std.testing.allocator),
    );
}

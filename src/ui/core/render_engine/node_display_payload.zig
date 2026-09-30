//! 节点 display payload 的**只读取址** —— 从 display_list_lowering.zig 析出
//! （2026-08-05），延续 bracket_debug.zig 的拆分先例（本文件聚焦 lowering 核心）。
//!
//! 这一簇回答同一个问题：给定 node_id 和 own/subtree 作用域，
//! 它的 DisplayItem / TextLayoutBlob 切片在哪。共同点是**只读、不分配、
//! 不改 cx**：只在 scene_runtime 的 runtime 记录上做下标算术，再到
//! display_list / text_blob_store 上切片。
//!
//! 与 lowering 主路径的分工：那边**写**（把 display_list lower 进
//! lowering_buffer_paint，有缓冲区状态与分配）；这边只**读已经写好的
//! 结果**。两者混在一个文件里时，"哪些函数会动 buffer"要靠逐个读实现才能
//! 判断 —— 分开后这一整个文件的零副作用性质是文件级保证。
//!
//! own vs subtree：own 只含节点自己产出的 item；subtree 含它整棵子树的
//! 连续区间（lowering 时按前序保证连续，所以子树也能用一个 start+count 表达）。
//! count==0 返回 null 而不是空切片 —— 调用方据此区分"没有 payload"与
//! "有 payload 但为空"，跨帧 splice 路径依赖这个区分。

const render_context_mod = @import("render_context.zig");
const display_list_mod = @import("../display_list.zig");
const text_blob_mod = @import("../text_blob.zig");

const RenderContext = render_context_mod.RenderContext;

pub const DisplayPayloadScope = enum {
    own,
    subtree,
};

pub const TextBlobPayloadScope = enum {
    own,
    subtree,
};

pub const NodeDisplayPayloadView = struct {
    items: []const display_list_mod.DisplayItem,
    blobs: []const text_blob_mod.TextLayoutBlob,
};

pub fn getNodeDisplayItems(
    cx: *RenderContext,
    node_id: u32,
    scope: DisplayPayloadScope,
) ?[]const display_list_mod.DisplayItem {
    const runtime = cx.scene_runtime.get(node_id) orelse return null;
    const start: usize = switch (scope) {
        .own => runtime.display_item_start,
        .subtree => runtime.subtree_display_item_start,
    };
    const count: usize = switch (scope) {
        .own => runtime.display_item_count,
        .subtree => runtime.subtree_display_item_count,
    };
    if (count == 0) return null;
    return cx.display_list.slice(start, count);
}

pub fn getNodeTextBlobs(
    cx: *RenderContext,
    node_id: u32,
    scope: TextBlobPayloadScope,
) ?[]const text_blob_mod.TextLayoutBlob {
    const runtime = cx.scene_runtime.get(node_id) orelse return null;
    const start: usize = switch (scope) {
        .own => runtime.text_blob_start,
        .subtree => runtime.subtree_text_blob_start,
    };
    const count: usize = switch (scope) {
        .own => runtime.text_blob_count,
        .subtree => runtime.subtree_text_blob_count,
    };
    if (count == 0) return null;
    return cx.text_blob_store.slice(start, count);
}

/// items + blobs 一起取。blobs 缺失时退化为空切片而非整体 null ——
/// 纯图形节点没有文本 blob 是正常情况，不该让整个 payload 变成"不存在"。
pub fn getNodeDisplayPayload(
    cx: *RenderContext,
    node_id: u32,
    scope: DisplayPayloadScope,
) ?NodeDisplayPayloadView {
    const items = getNodeDisplayItems(cx, node_id, scope) orelse return null;
    const blob_scope: TextBlobPayloadScope = switch (scope) {
        .own => .own,
        .subtree => .subtree,
    };
    const blobs = getNodeTextBlobs(cx, node_id, blob_scope) orelse &.{};
    return .{
        .items = items,
        .blobs = blobs,
    };
}

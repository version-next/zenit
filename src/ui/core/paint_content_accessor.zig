//! paint_content_accessor — v0.9 god-object split: 从 node.zig 抽出
//! §a NodeContent SoA + §b paint state SoA + §L NodeLayoutOutput SoA 的
//! accessor 路由层。
//!
//! 包含：callback 类型定义 + 全局 callback 槽 + registrar + standalone
//! fallback hashmap（element_id == 0xFFFFFFFF 的非 cx mock test 用 node
//! 指针 key fallback）+ Node-agnostic 路由 free function。
//!
//! Node 上的 get/setText/Image/Icon + getBackground/setBackgroundRaw +
//! getLayoutOutput/setLayoutOutput/layoutOutputPtr 等方法降为 thin
//! one-liner，delegate 到本模块。source of truth 见 world.ContentTable /
//! world.PaintStateTable / world.LayoutOutputTable；本层只做 callback
//! 分发 + mock fallback。

const std = @import("std");
const world_mod = @import("world.zig");

/// 仍走**旧进程级全局回调**的属性访问次数（world_ref == null 的节点）。
/// P0-3 阶段 3 迁移后，生产路径应恒为 0，只剩 cx-less test mock 会命中。
pub var legacy_callback_hits: u64 = 0;
const types = @import("types.zig");
const nlo = @import("node_layout_output.zig");

const Color = types.Color;
const TextProps = types.TextProps;
const ImageProps = types.ImageProps;
const IconProps = types.IconProps;
const NodeLayoutOutput = nlo.NodeLayoutOutput;

// ─────────────────────────────────────────────────────────────────────
// §b paint state SoA — write/read callback + standalone fallback
// ─────────────────────────────────────────────────────────────────────

pub const PaintStateBackgroundWriteFn = *const fn (element_id_raw: u32, c: Color) void;
pub const PaintStateOpacityWriteFn = *const fn (element_id_raw: u32, o: f32) void;
pub const PaintStateBackgroundReadFn = *const fn (element_id_raw: u32) ?Color;
pub const PaintStateOpacityReadFn = *const fn (element_id_raw: u32) ?f32;

var g_paint_bg_write: ?PaintStateBackgroundWriteFn = null;
var g_paint_opacity_write: ?PaintStateOpacityWriteFn = null;
var g_paint_bg_read: ?PaintStateBackgroundReadFn = null;
var g_paint_opacity_read: ?PaintStateOpacityReadFn = null;

pub fn setPaintBackgroundWriteCallback(cb: ?PaintStateBackgroundWriteFn) void {
    g_paint_bg_write = cb;
}
pub fn setPaintOpacityWriteCallback(cb: ?PaintStateOpacityWriteFn) void {
    g_paint_opacity_write = cb;
}
pub fn setPaintBackgroundReadCallback(cb: ?PaintStateBackgroundReadFn) void {
    g_paint_bg_read = cb;
}
pub fn setPaintOpacityReadCallback(cb: ?PaintStateOpacityReadFn) void {
    g_paint_opacity_read = cb;
}

// 不可降级说明：这些 map 是 fallback 节点 paint/content 的**唯一权威存储**
// （write 进来、read 从这里出去）。put 失败 = 写入的样式/文本被静默丢弃，
// 读侧拿到默认值 → 节点画错而不报错。故 OOM 一律 panic。
// standalone fallback for non-cx mock tests (element_id == 0xFFFFFFFF)。
// Paint state 比 §a content 简单：Color/f32 是 POD，无 inline_buf 自指
// 问题，hashmap rehash 不需要 re-fixup。
var g_standalone_paint_bg: std.AutoHashMap(usize, Color) = undefined;
var g_standalone_paint_opacity: std.AutoHashMap(usize, f32) = undefined;
var g_standalone_paint_init: bool = false;

fn ensureStandalonePaintInit() void {
    if (g_standalone_paint_init) return;
    g_standalone_paint_bg = std.AutoHashMap(usize, Color).init(std.heap.page_allocator);
    g_standalone_paint_opacity = std.AutoHashMap(usize, f32).init(std.heap.page_allocator);
    g_standalone_paint_init = true;
}

/// 无副作用 background 写路由：element_id!=0xFFFFFFFF 走 World callback，
/// mock node 落 standalone fallback by node ptr。
pub fn writeBackground(world_ref: ?*world_mod.World, element_id_raw: u32, node_ptr: usize, color: Color) void {
    // P0-3 阶段 3：优先直连 owner World，退化到旧全局回调只为 cx-less mock。
    if (element_id_raw != 0xFFFFFFFF) {
        if (world_ref) |w| {
            const eid = world_mod.ElementId.fromRaw(element_id_raw);
            if (w.paint_state.ensureSlot(eid)) |_| {
                w.paint_state.setBackground(eid, color);
                return;
            } else |_| {}
        } else if (g_paint_bg_write) |cb| {
            legacy_callback_hits += 1;
            cb(element_id_raw, color);
            return;
        }
    }
    ensureStandalonePaintInit();
    g_standalone_paint_bg.put(node_ptr, color) catch @panic("OOM: standalone paint background store");
}

pub fn writeOpacity(world_ref: ?*world_mod.World, element_id_raw: u32, node_ptr: usize, value: f32) void {
    if (element_id_raw != 0xFFFFFFFF) {
        if (world_ref) |w| {
            const eid = world_mod.ElementId.fromRaw(element_id_raw);
            if (w.paint_state.ensureSlot(eid)) |_| {
                w.paint_state.setOpacity(eid, value);
                return;
            } else |_| {}
        } else if (g_paint_opacity_write) |cb| {
            legacy_callback_hits += 1;
            cb(element_id_raw, value);
            return;
        }
    }
    ensureStandalonePaintInit();
    g_standalone_paint_opacity.put(node_ptr, value) catch @panic("OOM: standalone paint opacity store");
}

/// background 读路由：World callback → standalone fallback → 默认 TRANSPARENT。
pub fn readBackground(world_ref: ?*world_mod.World, element_id_raw: u32, node_ptr: usize) Color {
    if (element_id_raw != 0xFFFFFFFF) {
        if (world_ref) |w| {
            const eid = world_mod.ElementId.fromRaw(element_id_raw);
            if (w.paint_state.get(eid)) |ps| return ps.background;
        } else if (g_paint_bg_read) |cb| {
            legacy_callback_hits += 1;
            if (cb(element_id_raw)) |c| return c;
        }
    }
    if (!g_standalone_paint_init) return Color.TRANSPARENT;
    return g_standalone_paint_bg.get(node_ptr) orelse Color.TRANSPARENT;
}

pub fn readOpacity(world_ref: ?*world_mod.World, element_id_raw: u32, node_ptr: usize) f32 {
    if (element_id_raw != 0xFFFFFFFF) {
        if (world_ref) |w| {
            const eid = world_mod.ElementId.fromRaw(element_id_raw);
            if (w.paint_state.get(eid)) |ps| return ps.opacity;
        } else if (g_paint_opacity_read) |cb| {
            legacy_callback_hits += 1;
            if (cb(element_id_raw)) |o| return o;
        }
    }
    if (!g_standalone_paint_init) return 1.0;
    return g_standalone_paint_opacity.get(node_ptr) orelse 1.0;
}

// ─────────────────────────────────────────────────────────────────────
// §a NodeContent SoA — write/read callback + standalone fallback
// ─────────────────────────────────────────────────────────────────────

pub const ContentTextWriteFn = *const fn (element_id_raw: u32, t: ?TextProps) void;
pub const ContentImageWriteFn = *const fn (element_id_raw: u32, img: ?ImageProps) void;
pub const ContentIconWriteFn = *const fn (element_id_raw: u32, ic: ?IconProps) void;
pub const ContentTextReadFn = *const fn (element_id_raw: u32) ?TextProps;
pub const ContentImageReadFn = *const fn (element_id_raw: u32) ?ImageProps;
pub const ContentIconReadFn = *const fn (element_id_raw: u32) ?IconProps;

var g_content_text_write: ?ContentTextWriteFn = null;
var g_content_image_write: ?ContentImageWriteFn = null;
var g_content_icon_write: ?ContentIconWriteFn = null;
var g_content_text_read: ?ContentTextReadFn = null;
var g_content_image_read: ?ContentImageReadFn = null;
var g_content_icon_read: ?ContentIconReadFn = null;

pub fn setContentTextWriteCallback(cb: ?ContentTextWriteFn) void {
    g_content_text_write = cb;
}
pub fn setContentImageWriteCallback(cb: ?ContentImageWriteFn) void {
    g_content_image_write = cb;
}
pub fn setContentIconWriteCallback(cb: ?ContentIconWriteFn) void {
    g_content_icon_write = cb;
}
pub fn setContentTextReadCallback(cb: ?ContentTextReadFn) void {
    g_content_text_read = cb;
}
pub fn setContentImageReadCallback(cb: ?ContentImageReadFn) void {
    g_content_image_read = cb;
}
pub fn setContentIconReadCallback(cb: ?ContentIconReadFn) void {
    g_content_icon_read = cb;
}

var g_standalone_content_text: std.AutoHashMap(usize, TextProps) = undefined;
var g_standalone_content_image: std.AutoHashMap(usize, ImageProps) = undefined;
var g_standalone_content_icon: std.AutoHashMap(usize, IconProps) = undefined;
var g_standalone_content_init: bool = false;

fn ensureStandaloneContentInit() void {
    if (g_standalone_content_init) return;
    g_standalone_content_text = std.AutoHashMap(usize, TextProps).init(std.heap.page_allocator);
    g_standalone_content_image = std.AutoHashMap(usize, ImageProps).init(std.heap.page_allocator);
    g_standalone_content_icon = std.AutoHashMap(usize, IconProps).init(std.heap.page_allocator);
    g_standalone_content_init = true;
}

fn standaloneSetText(node_ptr: usize, t: ?TextProps) void {
    ensureStandaloneContentInit();
    if (t) |val| {
        g_standalone_content_text.put(node_ptr, val) catch @panic("OOM: standalone content text store");
        // hashmap put 可能 rehash 移动 entry；re-fixup 全表
        var it = g_standalone_content_text.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.inline_len > 0) {
                if (e.value_ptr.content.len == e.value_ptr.inline_len) {
                    if (std.mem.eql(u8, e.value_ptr.content, e.value_ptr.inline_buf[0..e.value_ptr.inline_len])) {
                        e.value_ptr.content = e.value_ptr.inline_buf[0..e.value_ptr.inline_len];
                    }
                }
            }
        }
    } else {
        _ = g_standalone_content_text.remove(node_ptr);
    }
}

/// text 写路由：element_id!=0xFFFFFFFF 走 World callback，mock 落 standalone
/// (含 inline_buf 自指 re-fixup)。
pub fn writeText(world_ref: ?*world_mod.World, element_id_raw: u32, node_ptr: usize, t: ?TextProps) void {
    if (element_id_raw != 0xFFFFFFFF) {
        if (world_ref) |w| {
            const eid = world_mod.ElementId.fromRaw(element_id_raw);
            if (w.content.ensureSlot(eid)) |_| {
                w.content.setText(eid, t);
                return;
            } else |_| {}
        } else if (g_content_text_write) |cb| {
            legacy_callback_hits += 1;
            cb(element_id_raw, t);
            return;
        }
    }
    standaloneSetText(node_ptr, t);
}

pub fn writeImage(world_ref: ?*world_mod.World, element_id_raw: u32, node_ptr: usize, img: ?ImageProps) void {
    if (element_id_raw != 0xFFFFFFFF) {
        if (world_ref) |w| {
            const eid = world_mod.ElementId.fromRaw(element_id_raw);
            if (w.content.ensureSlot(eid)) |_| {
                w.content.setImage(eid, img);
                return;
            } else |_| {}
        } else if (g_content_image_write) |cb| {
            legacy_callback_hits += 1;
            cb(element_id_raw, img);
            return;
        }
    }
    ensureStandaloneContentInit();
    if (img) |val| {
        g_standalone_content_image.put(node_ptr, val) catch @panic("OOM: standalone content image store");
    } else {
        _ = g_standalone_content_image.remove(node_ptr);
    }
}

pub fn writeIcon(world_ref: ?*world_mod.World, element_id_raw: u32, node_ptr: usize, ic: ?IconProps) void {
    if (element_id_raw != 0xFFFFFFFF) {
        if (world_ref) |w| {
            const eid = world_mod.ElementId.fromRaw(element_id_raw);
            if (w.content.ensureSlot(eid)) |_| {
                w.content.setIcon(eid, ic);
                return;
            } else |_| {}
        } else if (g_content_icon_write) |cb| {
            legacy_callback_hits += 1;
            cb(element_id_raw, ic);
            return;
        }
    }
    ensureStandaloneContentInit();
    if (ic) |val| {
        g_standalone_content_icon.put(node_ptr, val) catch @panic("OOM: standalone content icon store");
    } else {
        _ = g_standalone_content_icon.remove(node_ptr);
    }
}

pub fn readText(world_ref: ?*world_mod.World, element_id_raw: u32, node_ptr: usize) ?TextProps {
    if (element_id_raw != 0xFFFFFFFF) {
        if (world_ref) |w| {
            return w.content.getText(world_mod.ElementId.fromRaw(element_id_raw));
        } else if (g_content_text_read) |cb| return cb(element_id_raw);
    }
    if (!g_standalone_content_init) return null;
    return g_standalone_content_text.get(node_ptr);
}

pub fn readImage(world_ref: ?*world_mod.World, element_id_raw: u32, node_ptr: usize) ?ImageProps {
    if (element_id_raw != 0xFFFFFFFF) {
        if (world_ref) |w| {
            if (w.content.get(world_mod.ElementId.fromRaw(element_id_raw))) |c| return c.image;
            return null;
        } else if (g_content_image_read) |cb| return cb(element_id_raw);
    }
    if (!g_standalone_content_init) return null;
    return g_standalone_content_image.get(node_ptr);
}

pub fn readIcon(world_ref: ?*world_mod.World, element_id_raw: u32, node_ptr: usize) ?IconProps {
    if (element_id_raw != 0xFFFFFFFF) {
        if (world_ref) |w| {
            if (w.content.get(world_mod.ElementId.fromRaw(element_id_raw))) |c| return c.icon;
            return null;
        } else if (g_content_icon_read) |cb| return cb(element_id_raw);
    }
    if (!g_standalone_content_init) return null;
    return g_standalone_content_icon.get(node_ptr);
}

// ─────────────────────────────────────────────────────────────────────
// §L NodeLayoutOutput SoA — write/read/ptr callback + standalone fallback
// ─────────────────────────────────────────────────────────────────────
//
// layout_output 只在 render/hit 路径用，生产 caller 全 cx-backed
// (element_id 有效) 走 World.LayoutOutputTable。但 hit_runtime / tests
// 用 cx-less Node.create + setPathHitGeometry (element_id==0xFFFFFFFF)，
// 需 standalone fallback（与 §a content / §b paint 同型 mock 墙）。
//
// 关键差异：layoutOutputPtr 要求**稳定地址**（owner 方法原地改子字段 +
// display_list 指针逃逸）。AutoHashMap 值地址 rehash 会失效，故 standalone
// 存 *NodeLayoutOutput（heap pool，永久稳定地址），map 只存指针。
// path geometry 堆内存由 Node.releaseAllGeometry 在 freeNode 释放（cx-less
// mock 进程短；entry 不主动回收，与 §a g_standalone stale 决议一致）。

pub const LayoutOutputWriteFn = *const fn (element_id_raw: u32, v: NodeLayoutOutput) void;
pub const LayoutOutputReadFn = *const fn (element_id_raw: u32) ?NodeLayoutOutput;
pub const LayoutOutputPtrFn = *const fn (element_id_raw: u32) ?*NodeLayoutOutput;

var g_layout_output_write: ?LayoutOutputWriteFn = null;
var g_layout_output_read: ?LayoutOutputReadFn = null;
var g_layout_output_ptr: ?LayoutOutputPtrFn = null;

pub fn setLayoutOutputWriteCallback(cb: ?LayoutOutputWriteFn) void {
    g_layout_output_write = cb;
}
pub fn setLayoutOutputReadCallback(cb: ?LayoutOutputReadFn) void {
    g_layout_output_read = cb;
}
pub fn setLayoutOutputPtrCallback(cb: ?LayoutOutputPtrFn) void {
    g_layout_output_ptr = cb;
}

var g_standalone_layout_output: std.AutoHashMap(usize, *NodeLayoutOutput) = undefined;
var g_standalone_layout_output_init: bool = false;

fn ensureStandaloneLayoutOutputInit() void {
    if (g_standalone_layout_output_init) return;
    g_standalone_layout_output = std.AutoHashMap(usize, *NodeLayoutOutput).init(std.heap.page_allocator);
    g_standalone_layout_output_init = true;
}

/// cx-less mock 节点的稳定 layout_output slot（heap pool，地址永久稳定）。
fn standaloneLayoutOutputPtr(node_ptr: usize) ?*NodeLayoutOutput {
    ensureStandaloneLayoutOutputInit();
    if (g_standalone_layout_output.get(node_ptr)) |p| return p;
    const slot = std.heap.page_allocator.create(NodeLayoutOutput) catch return null;
    slot.* = .{};
    g_standalone_layout_output.put(node_ptr, slot) catch {
        std.heap.page_allocator.destroy(slot);
        return null;
    };
    return slot;
}

pub fn layoutOutputPtr(world_ref: ?*world_mod.World, element_id_raw: u32, node_ptr: usize) ?*NodeLayoutOutput {
    if (element_id_raw != 0xFFFFFFFF) {
        if (world_ref) |w| {
            const eid = world_mod.ElementId.fromRaw(element_id_raw);
            w.layout_output.ensureSlot(eid) catch return null;
            return w.layout_output.getPtr(eid);
        }
        if (g_layout_output_ptr) |cb| return cb(element_id_raw);
        return null;
    }
    return standaloneLayoutOutputPtr(node_ptr);
}

pub fn writeLayoutOutput(world_ref: ?*world_mod.World, element_id_raw: u32, node_ptr: usize, v: NodeLayoutOutput) void {
    if (element_id_raw != 0xFFFFFFFF) {
        if (world_ref) |w| {
            const eid = world_mod.ElementId.fromRaw(element_id_raw);
            if (w.layout_output.ensureSlot(eid)) |_| {
                w.layout_output.set(eid, v);
            } else |_| {}
            return;
        }
        if (g_layout_output_write) |cb| cb(element_id_raw, v);
        return;
    }
    if (standaloneLayoutOutputPtr(node_ptr)) |p| p.* = v;
}

pub fn readLayoutOutput(world_ref: ?*world_mod.World, element_id_raw: u32, node_ptr: usize) NodeLayoutOutput {
    if (element_id_raw != 0xFFFFFFFF) {
        if (world_ref) |w| {
            if (w.layout_output.get(world_mod.ElementId.fromRaw(element_id_raw))) |v| return v;
            return .{};
        }
        if (g_layout_output_read) |cb| {
            if (cb(element_id_raw)) |v| return v;
        }
        return .{};
    }
    if (standaloneLayoutOutputPtr(node_ptr)) |p| return p.*;
    return .{};
}

// ─────────────────────────────────────────────────────────────────────
// standalone fallback storage 的显式回收
//
// 这几张表是**进程级**的，用 page_allocator 且此前从无 teardown ——
// 于是 `zig build test` 的 GPA leak check 对它们完全盲视（走的不是 GPA），
// 全绿并不代表这条路径没泄漏。审查报告把这点列为 GPA 盲区。
//
// 它们只服务 cx-less 的 test mock（element_id == INVALID 的裸 Node），
// 生产路径不 hit。这里提供显式回收入口，让测试/工具能在收尾时清干净并
// 断言"确实没有残留"，而不是把泄漏藏在 allocator 之外。
// ─────────────────────────────────────────────────────────────────────

/// 当前 standalone fallback 表中的条目总数（诊断/验收用）。
pub fn standaloneEntryCount() usize {
    var n: usize = 0;
    if (g_standalone_paint_init) {
        n += g_standalone_paint_bg.count();
        n += g_standalone_paint_opacity.count();
    }
    if (g_standalone_content_init) {
        n += g_standalone_content_text.count();
        n += g_standalone_content_image.count();
        n += g_standalone_content_icon.count();
    }
    if (g_standalone_layout_output_init) n += g_standalone_layout_output.count();
    return n;
}

/// 释放所有 standalone fallback storage。进程收尾/测试收尾调用。
/// 幂等：重复调用安全，之后再用到会按需重新 init。
pub fn deinitStandaloneStorage() void {
    if (g_standalone_paint_init) {
        g_standalone_paint_bg.deinit();
        g_standalone_paint_opacity.deinit();
        g_standalone_paint_init = false;
    }
    if (g_standalone_content_init) {
        g_standalone_content_text.deinit();
        g_standalone_content_image.deinit();
        g_standalone_content_icon.deinit();
        g_standalone_content_init = false;
    }
    if (g_standalone_layout_output_init) {
        // value 是 page_allocator.create 出来的裸指针，必须逐个 destroy，
        // 否则只回收 map 本身仍会漏掉每个 NodeLayoutOutput。
        var it = g_standalone_layout_output.valueIterator();
        while (it.next()) |slot_ptr| std.heap.page_allocator.destroy(slot_ptr.*);
        g_standalone_layout_output.deinit();
        g_standalone_layout_output_init = false;
    }
}

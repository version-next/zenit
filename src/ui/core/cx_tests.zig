//! Cx 集成单测：帧时钟 / 节点释放与 scope / World SoA 镜像 / 主题切换 /
//! textFmt / 输入命令 / 文本塑形度量等。从 core.zig 析出；由 core.zig 末尾
//! 的 test 块显式 import，避免成为孤儿测试。

const std = @import("std");
const core = @import("../core.zig");
const Cx = core.Cx;
const Allocator = std.mem.Allocator;
const Color = core.Color;
const FontSystem = core.FontSystem;
const Node = core.Node;
const Scope = core.Scope;
const Signal = core.Signal;
const World = core.World;
const actions_mod = @import("../actions.zig");
const bindScopeToNode = core.bindScopeToNode;
const boxStyled = core.boxStyled;
const builders = @import("builders.zig");
const clearNodeScopes = core.clearNodeScopes;
const core_node = @import("node.zig");
const core_types = @import("types.zig");
const cx_render = @import("cx_render.zig");
const events_mod = @import("../events.zig");
const hooks_mod = @import("../hooks.zig");
const image = core.image;
const layout_engine = core.layout_engine;
const text = core.text;
const textFmt = core.textFmt;
const textStyled = core.textStyled;
const text_core_module = @import("text_core");
const text_layout = core.text_layout;
const text_module = @import("text");
const theme = core.theme;
const transition = core.transition;
const world = core.world;

/// 把 last_frame_instant 往回拨 delta_ns，伪造一个"上一帧发生在 delta_ns 之前"的慢帧。
fn backdateLastFrame(cx: *Cx, delta_ns: u64) !void {
    var t = try std.time.Instant.now();
    t.timestamp.nsec -= @intCast(delta_ns % std.time.ns_per_s);
    if (t.timestamp.nsec < 0) {
        t.timestamp.nsec += std.time.ns_per_s;
        t.timestamp.sec -= 1;
    }
    t.timestamp.sec -= @intCast(delta_ns / std.time.ns_per_s);
    cx.last_frame_instant = t;
}

test "frame clock stays wall-clock accurate when frames exceed the dt clamp" {
    const testing = std.testing;

    var cx = try Cx.init(testing.allocator);
    defer cx.deinit();

    const root = try Node.create(testing.allocator, cx.nextId(), .box, .{});
    cx.root = root;
    defer {
        cx.freeNode(root);
        cx.root = null;
    }

    // 模拟 4fps 重负载：每帧 250ms，远超 0.1s 的增量 clamp。
    const slow_frame_ns: u64 = 250 * std.time.ns_per_ms;
    const frames: u64 = 20;

    // epoch 也往回拨满整段时长，让 now-epoch 覆盖全部 20 帧的真实时间。
    var epoch = try std.time.Instant.now();
    epoch.timestamp.sec -= @intCast(frames * slow_frame_ns / std.time.ns_per_s);
    cx.clock_epoch = epoch;

    var i: u64 = 0;
    while (i < frames) : (i += 1) {
        cx.needs_redraw = true; // 保证走活跃路径而非 idle 早退
        try backdateLastFrame(cx, slow_frame_ns);
        cx.advanceFrameClock();
    }

    // 回归断言：逻辑时钟必须跟得上真实经过时间。
    // 修复前这里是 2000ms（40% 速度），亏空 3000ms 且永不追回。
    const real_elapsed_ms: f64 = @floatFromInt(frames * slow_frame_ns / std.time.ns_per_ms);
    try testing.expect(cx.frame_time_ms > real_elapsed_ms * 0.95);

    // 增量 dt 仍必须被钳住，Spring 积分器依赖有界步长。
    try testing.expect(cx.frame_dt_seconds <= 0.1);
}

test "frame clock freezes across idle frames and resumes without a time jump" {
    const testing = std.testing;

    var cx = try Cx.init(testing.allocator);
    defer cx.deinit();

    const root = try Node.create(testing.allocator, cx.nextId(), .box, .{});
    cx.root = root;
    defer {
        cx.freeNode(root);
        cx.root = null;
    }

    // 先跑一个 active 帧建立基线。
    cx.needs_redraw = true;
    try backdateLastFrame(cx, 16 * std.time.ns_per_ms);
    cx.advanceFrameClock();
    const before_idle = cx.frame_time_ms;

    // 一段很长的 idle：树全 clean + 无浮层动画 + 无 needs_redraw。
    // 注意 dirty 位默认值是 true（见 node.zig:545），`= .{}` 会把树置脏而非置净，
    // 必须逐位清零，否则本用例会走 active 路径、静默失去对 idle 冻结的覆盖。
    const dirty = &root.frame_state.state_bits.dirty;
    dirty.core.layout = false;
    dirty.core.subtree_layout = false;
    dirty.core.render = false;
    dirty.core.subtree_render = false;
    dirty.pipeline.composite = false;
    dirty.pipeline.subtree_composite = false;
    try testing.expect(cx_render.isTreeFullyClean(root));

    // 用 backdate 伪造"这一帧距上一帧过了 1s"，但同时把 epoch 也往前推同样的量，
    // 模拟真实世界里 idle 期间墙钟确实在走。若 idle 分支不累计 clock_paused_ns，
    // 恢复后的 frame_time_ms 会把整段 idle 一次性算进去 -> 下面的 resume 断言炸。
    const idle_span_ns: u64 = 1 * std.time.ns_per_s;
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        cx.needs_redraw = false;
        try backdateLastFrame(cx, idle_span_ns);
        cx.clock_epoch.?.timestamp.sec -= @intCast(idle_span_ns / std.time.ns_per_s);
        cx.advanceFrameClock();
        // idle 期间逻辑时钟必须冻结（零脏帧快速路径依赖 time_unchanged）。
        try testing.expectEqual(before_idle, cx.frame_time_ms);
    }

    // 恢复 active：这 5 秒 idle 不能一次性灌进动画（否则浮层瞬间跳到终态）。
    cx.needs_redraw = true;
    try backdateLastFrame(cx, 16 * std.time.ns_per_ms);
    cx.advanceFrameClock();
    const resumed_delta = cx.frame_time_ms - before_idle;
    try testing.expect(resumed_delta >= 0);
    try testing.expect(resumed_delta < 100);
}

test "freeNode disposes attached node scope" {
    const testing = std.testing;

    var cx = try Cx.init(testing.allocator);
    defer cx.deinit();

    const node = try Node.create(testing.allocator, cx.nextId(), .box, .{});
    const scope = try Scope.init(testing.allocator, null, cx.owner);
    try bindScopeToNode(scope, node);

    const Marker = struct {
        disposed: *bool,
    };
    var disposed = false;
    var marker = Marker{ .disposed = &disposed };
    try scope.registerResource(@ptrCast(&marker), struct {
        fn destroy(ptr: *anyopaque, _: Allocator) void {
            const typed: *Marker = @ptrCast(@alignCast(ptr));
            typed.disposed.* = true;
        }
    }.destroy);

    cx.freeNode(node);
    try testing.expect(disposed);
}

test "freeDetachedNodeAfterScopeDispose clears stale child scope pointers" {
    const testing = std.testing;

    var cx = try Cx.init(testing.allocator);
    defer cx.deinit();

    const parent_scope = try Scope.init(testing.allocator, null, cx.owner);
    var parent_scope_disposed = false;
    defer if (!parent_scope_disposed) parent_scope.dispose();

    const orphan_root = try Node.create(testing.allocator, cx.nextId(), .box, .{});
    const child = try Node.create(testing.allocator, cx.nextId(), .box, .{});
    try orphan_root.appendChild(testing.allocator, child);

    const child_scope = try parent_scope.childScope();
    try bindScopeToNode(child_scope, child);

    var child_scope_disposed = false;
    try child_scope.registerResource(@ptrCast(&child_scope_disposed), struct {
        fn destroy(ptr: *anyopaque, _: Allocator) void {
            const flag: *bool = @ptrCast(@alignCast(ptr));
            flag.* = true;
        }
    }.destroy);

    var root_cleaned = false;
    orphan_root.meta.ownership.hooks.on_cleanup = Cx.simpleHandler(struct {
        fn cleanup(ptr: *anyopaque) void {
            const flag: *bool = @ptrCast(@alignCast(ptr));
            flag.* = true;
        }
    }.cleanup, @ptrCast(&root_cleaned));

    var child_cleaned = false;
    child.meta.ownership.hooks.on_cleanup = Cx.simpleHandler(struct {
        fn cleanup(ptr: *anyopaque) void {
            const flag: *bool = @ptrCast(@alignCast(ptr));
            flag.* = true;
        }
    }.cleanup, @ptrCast(&child_cleaned));

    const CleanupCtx = struct {
        cx: *Cx,
        node: *Node,
    };
    var cleanup_ctx = CleanupCtx{ .cx = cx, .node = orphan_root };
    try parent_scope.registerResource(@ptrCast(&cleanup_ctx), struct {
        fn destroy(ptr: *anyopaque, _: Allocator) void {
            const ctx: *CleanupCtx = @ptrCast(@alignCast(ptr));
            ctx.cx.freeDetachedNodeAfterScopeDispose(ctx.node);
        }
    }.destroy);

    parent_scope.dispose();
    parent_scope_disposed = true;

    try testing.expect(child_scope_disposed);
    try testing.expect(root_cleaned);
    try testing.expect(child_cleaned);
}

test "clearNodeScopes invalidates scope binding before node free" {
    const testing = std.testing;

    var cx = try Cx.init(testing.allocator);
    defer cx.deinit();

    const parent_scope = try Scope.init(testing.allocator, null, cx.owner);
    var parent_scope_disposed = false;
    defer if (!parent_scope_disposed) parent_scope.dispose();

    const node = try Node.create(testing.allocator, cx.nextId(), .box, .{});
    const child_scope = try parent_scope.childScope();
    try bindScopeToNode(child_scope, node);

    clearNodeScopes(node);
    cx.freeNode(node);

    parent_scope.dispose();
    parent_scope_disposed = true;
}

test "freeNode releases zero-length owned text content" {
    const testing = std.testing;

    var cx = try Cx.init(testing.allocator);
    defer cx.deinit();

    const node = try Node.create(testing.allocator, cx.nextId(), .box, .{});
    node.setText(.{
        .content = try testing.allocator.dupe(u8, ""),
        .owned = true,
    });

    cx.freeNode(node);
}

test "text builder mirrors content into World.content" {
    const testing = std.testing;

    var cx = try Cx.init(testing.allocator);
    defer cx.deinit();

    const node = try builders.text(cx, "hello", .{});
    defer cx.freeNode(node);
    try testing.expect(node.element_id_raw != 0xFFFFFFFF);

    const eid = world.ElementId.fromRaw(node.element_id_raw);
    const mirrored = cx.world.content.getText(eid).?;
    try testing.expectEqualSlices(u8, "hello", mirrored.content);

    // In-place 字段仍是 source of truth (stage 1 双写期)
    try testing.expectEqualSlices(u8, "hello", node.getText().?.content);
}

test "image builder mirrors texture_id into World.content" {
    const testing = std.testing;

    var cx = try Cx.init(testing.allocator);
    defer cx.deinit();

    const node = try builders.image(cx, 42, .{ .width = .{ .px = 10 }, .height = .{ .px = 10 } });
    defer cx.freeNode(node);
    const eid = world.ElementId.fromRaw(node.element_id_raw);
    const mirrored = cx.world.content.get(eid).?;
    try testing.expectEqual(@as(u32, 42), mirrored.image.?.texture_id);
    try testing.expectEqual(@as(u32, 42), node.getImage().?.texture_id);
}

test "setBackground mirrors into World.paint_state" {
    const testing = std.testing;

    var cx = try Cx.init(testing.allocator);
    defer cx.deinit();

    const node = try builders.box(cx, .{}, .{});
    defer cx.freeNode(node);
    try testing.expect(node.element_id_raw != 0xFFFFFFFF);

    const red = Color.rgba(255, 0, 0, 255);
    node.setBackground(red);

    const eid = world.ElementId.fromRaw(node.element_id_raw);
    const mirrored = cx.world.paint_state.get(eid).?;
    try testing.expectEqual(@as(u8, 255), mirrored.background.r);
    try testing.expectEqual(@as(u8, 0), mirrored.background.g);
    try testing.expectEqual(@as(u8, 255), node.getBackground().r);
}

test "setOpacity mirrors into World.paint_state" {
    const testing = std.testing;

    var cx = try Cx.init(testing.allocator);
    defer cx.deinit();

    const node = try builders.box(cx, .{}, .{});
    defer cx.freeNode(node);

    node.setOpacity(0.5);

    const eid = world.ElementId.fromRaw(node.element_id_raw);
    const mirrored = cx.world.paint_state.get(eid).?;
    try testing.expectApproxEqAbs(@as(f32, 0.5), mirrored.opacity, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.5), node.getOpacity(), 0.001);
}

test "setBackgroundRaw mirrors World but skips dirty/transition" {
    const testing = std.testing;

    var cx = try Cx.init(testing.allocator);
    defer cx.deinit();

    const node = try builders.box(cx, .{}, .{});
    defer cx.freeNode(node);
    try testing.expect(node.element_id_raw != 0xFFFFFFFF);

    // 给 node 配 background transition：setBackground 会走插值分支，
    // setBackgroundRaw 必须**绕过**它直接落值。
    node.enableImplicitAnimation(cx.allocator, &.{.background}, .{ .duration_ms = 200 });

    const blue = Color.rgba(0, 0, 255, 255);
    node.setBackgroundRaw(blue);

    // 1. in-place 字段直接落值（非插值起点）
    try testing.expectEqual(@as(u8, 255), node.getBackground().b);
    // 2. 镜像到 World.paint_state
    const eid = world.ElementId.fromRaw(node.element_id_raw);
    const mirrored = cx.world.paint_state.get(eid).?;
    try testing.expectEqual(@as(u8, 255), mirrored.background.b);
    // 3. 未激活 transition slot（Raw 绕过插值）
    if (node.frame_state.frame_local.runtime.transitions) |slots| {
        if (slots.find(.background)) |slot| {
            try testing.expect(!slot.active);
        }
    }
}

test "setOpacityRaw mirrors World, no transition activation" {
    const testing = std.testing;

    var cx = try Cx.init(testing.allocator);
    defer cx.deinit();

    const node = try builders.box(cx, .{}, .{});
    defer cx.freeNode(node);

    node.enableImplicitAnimation(cx.allocator, &.{.opacity}, .{ .duration_ms = 200 });

    node.setOpacityRaw(0.3);

    try testing.expectApproxEqAbs(@as(f32, 0.3), node.getOpacity(), 0.001);
    const eid = world.ElementId.fromRaw(node.element_id_raw);
    const mirrored = cx.world.paint_state.get(eid).?;
    try testing.expectApproxEqAbs(@as(f32, 0.3), mirrored.opacity, 0.001);
    if (node.frame_state.frame_local.runtime.transitions) |slots| {
        if (slots.find(.opacity)) |slot| {
            try testing.expect(!slot.active);
        }
    }
}

test "setLayoutOutput/getLayoutOutput 走 World (无 in-place 字段)" {
    const testing = std.testing;

    var cx = try Cx.init(testing.allocator);
    defer cx.deinit();

    const node = try builders.box(cx, .{}, .{});
    defer cx.freeNode(node);
    try testing.expect(node.element_id_raw != 0xFFFFFFFF);

    var lo: core_node.NodeLayoutOutput = .{};
    lo.artifacts.children_bbox = .{ .x = 1, .y = 2, .w = 30, .h = 40 };
    lo.vector.stroke.width = 2.5;
    node.setLayoutOutput(lo);

    // getLayoutOutput 走 World read callback（World 是 source of truth）
    try testing.expectEqual(@as(f32, 30), node.getLayoutOutput().artifacts.children_bbox.?.w);
    try testing.expectEqual(@as(f32, 2.5), node.getLayoutOutput().vector.stroke.width);

    const eid = world.ElementId.fromRaw(node.element_id_raw);
    const stored = cx.world.layout_output.get(eid).?;
    try testing.expectEqual(@as(f32, 30), stored.artifacts.children_bbox.?.w);
}

test "layoutOutputPtr 原地改子字段直写 World" {
    const testing = std.testing;

    var cx = try Cx.init(testing.allocator);
    defer cx.deinit();

    const node = try builders.box(cx, .{}, .{});
    defer cx.freeNode(node);

    // owner/layout_engine 路径用 layoutOutputPtr 拿 World slot 稳定地址原地改
    const lo = node.layoutOutputPtr().?;
    lo.artifacts.children_bbox = .{ .x = 0, .y = 0, .w = 77, .h = 0 };

    // 无 in-place 字段；getLayoutOutput 读 World 应见到改动
    try testing.expectEqual(@as(f32, 77), node.getLayoutOutput().artifacts.children_bbox.?.w);
}

test "主题运行时切换 (dark / light / high_contrast)" {
    const testing = std.testing;

    var cx = try Cx.init(testing.allocator);
    defer cx.deinit();

    // 初始为 dark
    try testing.expectEqualStrings("dark", cx.tokens.name);

    cx.setTheme(&theme.light);
    try testing.expectEqualStrings("light", cx.tokens.name);
    try testing.expect(cx.needs_redraw);

    cx.setTheme(&theme.high_contrast);
    try testing.expectEqualStrings("high_contrast", cx.tokens.name);
    // high_contrast 纯黑底
    try testing.expectEqual(@as(u8, 0), cx.tokens.color.bg_base.r);
    try testing.expectEqual(@as(u8, 0), cx.tokens.color.bg_base.g);
    try testing.expectEqual(@as(u8, 0), cx.tokens.color.bg_base.b);
    // 纯白前景
    try testing.expectEqual(@as(u8, 255), cx.tokens.color.fg_primary.r);
}

test "setTheme 触发 before_render hook + theme_version 自增" {
    const testing = std.testing;

    var cx = try Cx.init(testing.allocator);
    defer cx.deinit();

    const Probe = struct {
        var fire_count: u32 = 0;
        fn hook(_: *Node) void {
            fire_count += 1;
        }
    };
    Probe.fire_count = 0;

    const root = try builders.box(cx, .{}, .{});
    cx.root = root;
    root.meta.per_frame.hooks.before_render.main = &Probe.hook;

    const child = try builders.box(cx, .{}, .{});
    try root.appendChild(testing.allocator, child);
    child.meta.per_frame.hooks.before_render.main = &Probe.hook;

    const initial_version = cx.theme_version;
    cx.setTheme(&theme.light);

    try testing.expect(cx.theme_version == initial_version +% 1);
    try testing.expectEqual(@as(u32, 2), Probe.fire_count);
    try testing.expect(cx.needs_redraw);

    cx.setTheme(&theme.light);
    try testing.expectEqual(@as(u32, 2), Probe.fire_count);
}

test "theme Signal 化: themeSignal 惰性创建 + setTheme 驱动 set" {
    const testing = std.testing;

    var cx = try Cx.init(testing.allocator);
    defer cx.deinit();

    const scope = try Scope.init(testing.allocator, null, cx.owner);
    defer scope.dispose();

    const sig = try cx.themeSignal(scope);
    // 重复调用返回同一 Signal
    try testing.expectEqual(sig, try cx.themeSignal(scope));
    try testing.expectEqualStrings("dark", sig.get().name);

    cx.setTheme(&theme.light);
    try testing.expectEqualStrings("light", sig.get().name);
}

// 续接记录「待继续的工作」第 4 条点名的风险，做出故障复现：
// **Cx.theme_signal 缓存了一个归属于「第一个调用者的 Scope」的 Signal，
// 而 Scope 销毁时没有任何解绑**，于是缓存指向已释放内存。
//
// 真实触发路径：主题信号是全局的，但第一个订阅它的往往是某个**组件/面板**
// 的 scope（比如一个弹层）。那个面板一关（scope.dispose），Cx 上的缓存就悬垂；
// 下一个调用 themeSignal 的人拿到的是野指针，setTheme 会往里写。
test "themeSignal 的缓存必须随创建它的 Scope 一起失效（故障复现）" {
    const testing = std.testing;

    var cx = try Cx.init(testing.allocator);
    defer cx.deinit();

    // 长命 scope：代表窗口根。
    const root_scope = try Scope.init(testing.allocator, null, cx.owner);
    defer root_scope.dispose();

    {
        // 短命 scope：代表一个弹层/面板，它碰巧是第一个订阅主题的。
        const panel_scope = try Scope.init(testing.allocator, null, cx.owner);
        const sig = try cx.themeSignal(panel_scope);
        try testing.expectEqualStrings("dark", sig.get().name);
        panel_scope.dispose();
    }

    // 面板关掉之后：缓存必须已经失效，themeSignal 应当在 root_scope 上重建。
    // 修复前这里返回的是已释放的 Signal，get()/setTheme 都是 UAF。
    const sig2 = try cx.themeSignal(root_scope);
    try testing.expectEqualStrings("dark", sig2.get().name);
    cx.setTheme(&theme.light);
    try testing.expectEqualStrings("light", sig2.get().name);
}

// 交叉审查（glm-5.3）指出的**瞬态窗口**，实测确认存在并已修：
// disposeNow 的顺序是 1 子 scope -> 2 cleanups -> 3 effects -> 4 销毁 signals
// -> 5 resources。解绑若登记成 **resource**（第 5 步），就发生在 Signal
// 已被释放**之后**，而第 3/4 步跑的是用户回调，任何一个再调 themeSignal
// 都会命中还没清的缓存拿到野指针。所以解绑必须登记成 **cleanup**（第 2 步）。
//
// 本测试在 cleanup 里回调 themeSignal 来钉住这个顺序：拿到的必须是一个
// **活的**（新建在别的 scope 上的）Signal，而不是正在被销毁的那个。
test "dispose 期间回调里再取 themeSignal 不得拿到野指针" {
    const testing = std.testing;

    var cx = try Cx.init(testing.allocator);
    defer cx.deinit();

    const root_scope = try Scope.init(testing.allocator, null, cx.owner);
    defer root_scope.dispose();

    // 探针登记成 **resource**：resources 在第 5 步跑，也就是 signals 已经
    // 在第 4 步被销毁**之后**。逆序执行 ⇒ 后登记的先跑，所以这个探针一定
    // 排在 themeSignal 自己登记的解绑之前，正是最坏情况。
    // 解绑若也登记成 resource（错误写法），此刻缓存还指着已释放的 Signal，
    // 探针的 get() 就是 UAF；解绑登记成 cleanup（正确写法，第 2 步）则缓存
    // 早已清空，探针会在 root_scope 上重建一个活的。
    const Probe = struct {
        cx: *Cx,
        root: *Scope,
        name: []const u8 = "",

        fn destroy(ptr: *anyopaque, _: std.mem.Allocator) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            const sig = self.cx.themeSignal(self.root) catch return;
            self.name = sig.get().name;
        }
    };
    var probe = Probe{ .cx = cx, .root = root_scope };

    {
        const panel_scope = try Scope.init(testing.allocator, null, cx.owner);
        _ = try cx.themeSignal(panel_scope);
        try panel_scope.registerResource(@ptrCast(&probe), Probe.destroy);
        panel_scope.dispose();
    }

    // 探针拿到的必须是活 Signal 的内容，不是野指针读出的垃圾。
    try testing.expectEqualStrings("dark", probe.name);
}

test "boxStyled/textStyled: setTheme 重放具名样式函数（含 paint_state 背景路径）" {
    const testing = std.testing;

    var cx = try Cx.init(testing.allocator);
    defer cx.deinit();

    const S = struct {
        fn card(t: *const theme.ThemeTokens) core_types.BoxStyle {
            return .{
                .background = t.color.bg_primary,
                .padding = core_types.Padding.all(t.space._4),
                .text_color = t.color.fg_primary,
            };
        }
        fn label(t: *const theme.ThemeTokens) builders.TextStyle {
            return .{ .color = t.color.fg_primary, .font_size = t.font_size.md };
        }
    };

    const root = try builders.boxStyled(cx, S.card, .{});
    cx.root = root;
    const label_node = try builders.textStyled(cx, S.label, "hello");
    try root.appendChild(testing.allocator, label_node);

    // DevTools 精确来源：具名样式字段指向原始 style fn；函数未声明的字段
    // 不冒充有来源。TextStyle 的三个可追踪字段同样挂在 label fn 上。
    const card_addr = @intFromPtr(&S.card);
    try testing.expectEqual(card_addr, root.styleOrigin(.background).?.address);
    try testing.expectEqual(world.StyleOriginKind.styled, root.styleOrigin(.padding).?.kind);
    try testing.expect(root.styleOrigin(.gap) == null);
    try testing.expectEqual(@intFromPtr(&S.label), label_node.styleOrigin(.text_color).?.address);

    root.setStyle(null, .translate_x, @as(f32, 7));
    const translate_origin = root.styleOrigin(.translate_x).?;
    try testing.expectEqual(world.StyleOriginKind.set_style, translate_origin.kind);
    try testing.expect(translate_origin.address != 0);

    // mount 时即应用 dark 值（background 走 paint_state，不在 Style 里）
    try testing.expectEqual(theme.dark.color.bg_primary, root.getBackground());
    try testing.expectEqual(theme.dark.color.fg_primary, label_node.getText().?.color);
    // on_theme 不是 before_render hook：不毒化 promoted cache 资格
    try testing.expect(!root.hasBeforeRenderHooks());
    try testing.expect(!label_node.hasBeforeRenderHooks());

    cx.setTheme(&theme.light);

    // 背景色必须跟随（历史坑：只 applyTo 的话 background 恰恰不更新）
    try testing.expectEqual(theme.light.color.bg_primary, root.getBackground());
    try testing.expectEqual(theme.light.color.fg_primary, label_node.getText().?.color);
    try testing.expectEqual(theme.light.color.fg_primary, root.style.ext.?.text_color.?);
    // 布局脏已标（样式函数可能输出布局字段）
    try testing.expect(root.frame_state.state_bits.dirty.core.layout);

    // 普通 box 不受影响：无 on_theme、无任何 hook
    const plain = try builders.box(cx, .{ .background = theme.dark.color.bg_secondary }, .{});
    try root.appendChild(testing.allocator, plain);
    try testing.expect(plain.meta.per_frame.hooks.on_theme == null);
}

test "invalidateSubtreeHookState 摘除 on_theme hook" {
    const testing = std.testing;

    var cx = try Cx.init(testing.allocator);
    defer cx.deinit();

    const S = struct {
        fn card(t: *const theme.ThemeTokens) core_types.BoxStyle {
            return .{ .background = t.color.bg_primary };
        }
    };

    const node = try builders.boxStyled(cx, S.card, .{});
    cx.root = node;
    try testing.expect(node.meta.per_frame.hooks.on_theme != null);

    hooks_mod.invalidateSubtreeHookState(node);
    try testing.expect(node.meta.per_frame.hooks.on_theme == null);
}

test "textFmt updates content when a source signal changes" {
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();

    const count = try scope.createSignal(u32, 1);
    const label = try textFmt(cx, scope, "count = {d}", .{count}, .{});
    cx.root = label;

    try std.testing.expectEqualStrings("count = 1", label.getText().?.content);
    count.set(42);
    try std.testing.expectEqualStrings("count = 42", label.getText().?.content);
}

test "textFmt long content falls back to heap without truncation" {
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();

    const n = try scope.createSignal(u64, 7);
    const label = try textFmt(cx, scope, "x" ** 70 ++ "{d}", .{n}, .{});
    cx.root = label;

    try std.testing.expect(label.getText().?.content.len == 71);
    n.set(1234);
    try std.testing.expect(label.getText().?.content.len == 74);
}

test "Cx.handleDrag: source-completion kind(4) 与未知 kind 不 panic" {
    // 回归锁：kind=4 是 beginDrag 的完成回执（system_sdk 层文档），此前
    // 直接 @enumFromInt 进 DragEvent.Kind(0..3)，任何拖出会话松手即
    // "invalid enum value" panic。真机脚本 verify_interop_probe.sh 逮到。
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();

    cx.handleDrag(10, 10, 4, "");
    cx.handleDrag(10, 10, 255, "");
    try std.testing.expect(cx.needs_redraw);
}

test "Cx.handleCommand: 无焦点时全树回退找 action context（wrapper root 不再吞菜单命令）" {
    // 回归锁：cx.root 是 App 的内部 wrapper，dispatchAction 从焦点向上走，
    // 用户 mount root 上绑的 context 永远走不到，真菜单点击静默丢失
    // （verify_menu.sh 逮到）。修复 = ignored 时全树找第一个匹配节点。
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();

    const wrapper = try Node.create(std.testing.allocator, cx.nextId(), .box, .{});
    const child = try Node.create(std.testing.allocator, cx.nextId(), .box, .{});
    try wrapper.appendChild(std.testing.allocator, child);
    cx.root = wrapper;
    defer {
        cx.root = null;
        wrapper.destroy(std.testing.allocator);
    }

    const S = struct {
        var fired: bool = false;
        fn onAction(action: actions_mod.Action, context: ?*anyopaque) events_mod.EventResult {
            _ = context;
            if (std.mem.eql(u8, action.name, "ping")) fired = true;
            return .handled;
        }
    };
    S.fired = false;
    child.behavior.interaction.key_context = "probe";
    child.behavior.events.on_action = S.onAction;
    cx.bindCommandAction(100, .{ .context = "probe", .name = "ping" });

    cx.handleCommand(100);
    try std.testing.expect(S.fired);
}

test "Cx.handler requires existing state" {
    const CounterState = struct {
        value: u32 = 0,

        fn increment(self: *@This()) void {
            self.value += 1;
        }
    };

    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();

    try std.testing.expectError(error.StateNotFound, cx.handler(CounterState, 1, CounterState.increment));
}

test "Cx.handler binds to explicit state" {
    const CounterState = struct {
        value: u32 = 0,

        fn increment(self: *@This()) void {
            self.value += 1;
        }
    };

    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();

    const state = try cx.state(CounterState, 7, .{});
    const ref = try cx.handler(CounterState, 7, CounterState.increment);
    ref.callback(ref.context);

    try std.testing.expectEqual(@as(u32, 1), state.value);
    try std.testing.expect(state == cx.getState(CounterState, 7).?);
}

test "光标测量：shape 钩子装与不装必须同宽（ASCII / ASCII+emoji / CJK）" {
    // == 这个测试钉的是什么 ==
    // measureTextWidthWithSpans **不是参数的纯函数**：measureProportional
    // 先试 GlyphRun shape 钩子，NaN 才回落到 measure_ctx_fn / measure_fn。
    // 于是同一段文本、同一组参数，会因为「当前有没有装钩子」得到两个答案：
    //   - 布局与绘制：不装钩子 -> measure_ctx_fn 那条（App 的 FontSelector）
    //   - 光标/选区/命中：computeCursorPos 装钩子 -> shape 管线解析的字体
    // 两条路只要选出不同的 Font，光标就系统性地偏离字形边缘。实测
    // 下游编辑器上 "ssdf x😊" 差 1.442px（57.906 vs 59.348），行尾光标短在
    // 字形右缘里侧；**纯英文行同样错**，emoji 只是让缺口更显眼。
    //
    // 修复方式是给 shape 管线装 setShapeFontResolver，让它与测量端拿到
    // 同一个 *Font。本测试模拟那个装配，并断言两条路等宽。
    // 判据故意**不写死像素值**（随系统字体版本漂移会变脆），而是断言
    // 「两条路必须相等」，这正是 bug 的形状，也是修复要维持的不变式。
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    var fonts = try FontSystem.init(std.testing.allocator);
    defer fonts.deinit();
    cx.text.setFontSystem(&fonts);
    defer cx.text.clearFontSystem();

    // 一个具体字体同时供给两条路，相当于 App.setFontSelector 的最小模型。
    const base = try fonts.findFont(.{ .family = "Helvetica Neue", .size = 14 });
    defer base.deinit();

    const Bridge = struct {
        var the_font: ?*text_module.Font = null;
        fn measure(ctx: *anyopaque, ptr: [*]const u8, len: usize, size: f32, _: u16, _: bool) f32 {
            _ = ctx;
            const f = the_font.?;
            const scale = size / f.pixelSize();
            return f.measureWidth(ptr[0..len]) * scale;
        }
        fn resolve(ctx: *anyopaque, _: []const u8, _: f32, _: u16, _: bool, _: bool, _: u16) ?*text_module.Font {
            _ = ctx;
            return the_font;
        }
    };
    Bridge.the_font = base;
    var dummy: u8 = 0;
    cx.text.measure_ctx_fn = &Bridge.measure;
    cx.text.measure_ctx = @ptrCast(&dummy);
    text_layout.setMeasureCtxFn(&Bridge.measure, @ptrCast(&dummy));
    defer text_layout.setMeasureCtxFn(null, null);
    layout_engine.setShapeFontResolver(&Bridge.resolve, @ptrCast(&dummy));
    defer layout_engine.setShapeFontResolver(null, null);

    const tl = text_layout;
    const cases = [_][]const u8{
        "ssdf x", // 纯 ASCII —— 用户明确报告英文也偏，必须覆盖
        "ssdf x\u{1F60A}", // ASCII + emoji（最初的复现串）
        "\u{4E2D}\u{6587}\u{6D4B}\u{8BD5}", // CJK 走 fallback 字体，另一条解析分支
        "abc\u{4E2D}d\u{1F60A}e", // 三种混排：同一行里跨越三条字体解析路径
    };

    for (cases) |content| {
        const end: u32 = @intCast(content.len);
        // 不装钩子（布局/绘制这条路）
        const no_hook = tl.measureTextWidthWithSpans(content, 0, end, 14, 450, false, false, &.{});
        // 装钩子（光标/选区这条路）
        var guard = cx.text.beginExternalTextMeasure();
        const with_hook = tl.measureTextWidthWithSpans(content, 0, end, 14, 450, false, false, &.{});
        guard.end();

        try std.testing.expect(no_hook > 0);
        try std.testing.expect(with_hook > 0);
        // 亚像素级一致。0.01 只是容忍 f32 累加噪声；
        // 真出 bug 时差的是整像素级（实测 1.442 / 3.783）。
        try std.testing.expectApproxEqAbs(no_hook, with_hook, 0.01);
    }
}

test "光标测量：前缀宽度沿整行单调且末项等于整串" {
    // 配套锚点：上一个保证「两条路同宽」，这个保证「前缀累加 == 整串」。
    // computeCursorPos 按 [0, col) 前缀定位光标，所以前缀序列必须单调不减、
    // 且最后一项等于整串宽度，行尾光标正是靠这条等式落在文本右缘。
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    var fonts = try FontSystem.init(std.testing.allocator);
    defer fonts.deinit();
    cx.text.setFontSystem(&fonts);
    defer cx.text.clearFontSystem();

    const tl = text_layout;
    var guard = cx.text.beginExternalTextMeasure();
    defer guard.end();

    for ([_][]const u8{ "ssdf x", "ssdf x\u{1F60A}", "\u{4E2D}\u{6587}abc" }) |content| {
        const total = tl.measureTextWidthWithSpans(content, 0, @intCast(content.len), 14, 450, false, false, &.{});
        var prev: f32 = 0;
        var i: u32 = 1;
        while (i <= content.len) : (i += 1) {
            // 只在 UTF-8 字符边界取前缀（把 emoji 从中间切开没有意义）
            if (i < content.len and (content[i] & 0xC0) == 0x80) continue;
            const w = tl.measureTextWidthWithSpans(content, 0, i, 14, 450, false, false, &.{});
            try std.testing.expect(w >= prev - 0.001);
            prev = w;
        }
        try std.testing.expectApproxEqAbs(total, prev, 0.01);
    }
}

test "shapeVisualLine extracts CoreText grapheme and mixed-bidi caret geometry" {
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    var fonts = try FontSystem.init(std.testing.allocator);
    defer fonts.deinit();
    cx.text.setFontSystem(&fonts);
    defer cx.text.clearFontSystem();

    const content = "abc \u{5D0}\u{5D1}\u{5D2} 12";
    var owned = try cx.text.shapeVisualLine(.{
        .text = content,
        .font_family = "system",
        .font_size = 16,
    });
    defer owned.deinit();
    try owned.value.validate(content);
    try std.testing.expect(owned.value.width > 0);
    try std.testing.expect(owned.value.ascent > 0);

    var has_visual_reverse = false;
    for (owned.value.caret_stops[0 .. owned.value.caret_stops.len - 1], owned.value.caret_stops[1..]) |left, right| {
        if (right.position.byte.value < left.position.byte.value) has_visual_reverse = true;
    }
    try std.testing.expect(has_visual_reverse);

    const emoji = "A👩‍💻B";
    var emoji_line = try cx.text.shapeVisualLine(.{
        .text = emoji,
        .font_family = "system",
        .font_size = 18,
    });
    defer emoji_line.deinit();
    try emoji_line.value.validate(emoji);
    // A + one ZWJ grapheme + B yields exactly four logical boundaries; CoreText
    // may add secondary bidi carets, but must never expose interior scalar stops.
    for (emoji_line.value.caret_stops) |stop| {
        try std.testing.expect(text_core_module.text_coordinates.isGraphemeBoundary(emoji, stop.position.byte.value));
    }

    const cached_a = try cx.text.visualLine(.{ .text = content, .font_family = "system", .font_size = 16 });
    const cached_b = try cx.text.visualLine(.{ .text = content, .font_family = "system", .font_size = 16 });
    try std.testing.expect(cached_a.caret_stops.ptr == cached_b.caret_stops.ptr);
}

test "shapeVisualLine paragraph base direction follows UAX 9 outside isolates" {
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    var fonts = try FontSystem.init(std.testing.allocator);
    defer fonts.deinit();
    cx.text.setFontSystem(&fonts);
    defer cx.text.clearFontSystem();

    // The first glyph run is RTL, but P2 ignores strong characters inside the
    // leading isolate and therefore finds the following Latin paragraph text.
    const ltr = "\u{2067}\u{05D0}\u{05D1}\u{2069}abc";
    var ltr_line = try cx.text.shapeVisualLine(.{ .text = ltr, .font_family = "system", .font_size = 16 });
    defer ltr_line.deinit();
    try std.testing.expectEqual(text_core_module.text_coordinates.Direction.ltr, ltr_line.value.base_direction);

    // Symmetric case: isolated Latin does not override the Hebrew paragraph.
    const rtl = "\u{2066}abc\u{2069}\u{05D0}\u{05D1}";
    var rtl_line = try cx.text.shapeVisualLine(.{ .text = rtl, .font_family = "system", .font_size = 16 });
    defer rtl_line.deinit();
    try std.testing.expectEqual(text_core_module.text_coordinates.Direction.rtl, rtl_line.value.base_direction);
}

// 下游回归合同锁：measureTextWidth 必须与 GlyphRun 管线（渲染/光标/选区
// 用的 shapeText "system"）同源。两条度量路径并存却无交叉一致性测试，
// 是拉丁 ~1.5% 漂移能存活到下游的结构性原因，此测试红 = 管线再度分裂。
test "measureTextWidth 与 shapeText 跨管线一致（下游回归）" {
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    var fonts = try FontSystem.init(std.testing.allocator);
    defer fonts.deinit();
    cx.text.setFontSystem(&fonts);
    defer cx.text.clearFontSystem();

    // 覆盖当年的分歧画像：长拉丁（差最大）、短拉丁、数字（巧合相等）、
    // CJK（本就一致）、混排、CJK+SMP emoji（cascade 分歧用例）。
    const corpus = [_][]const u8{
        "The quick brown fox jumps over the lazy dog wonderful",
        "df",
        "Mixed",
        "123",
        "我们都好",
        "混排 Mixed 123",
        "sf工有\u{1F236}要在",
        "Hi \u{1F44B} emoji \u{1F389}\u{1F525} 测试 \u{1F600} end",
    };
    for (corpus) |s| {
        const run = try cx.text.shapeText(.{ .text = s, .font_family = "system", .font_size = 16 });
        const measured = cx.text.measureTextWidth(s, 16, 400, false);
        try std.testing.expectApproxEqAbs(run.total_advance, measured, 0.01);
    }
}

// #36 审查回归锁：emoji 强制字体必须按 ZWJ 序列整体覆盖。逐码点覆盖会把
// BMP 的 ZWJ 留在基字体 run 里、CTLine 不跨 run 结扎，👨‍👩‍👧 曾从单字形
// 21px 碎成三个人形 63px（度量/渲染/caret 三路同坏，全套测试当时全绿）。
test "ZWJ emoji 序列塑形不碎裂（#36 审查回归）" {
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    var fonts = try FontSystem.init(std.testing.allocator);
    defer fonts.deinit();
    cx.text.setFontSystem(&fonts);
    defer cx.text.clearFontSystem();

    const adv = struct {
        fn of(c: *Cx, s: []const u8) !f32 {
            const run = try c.text.shapeText(.{ .text = s, .font_family = "system", .font_size = 16 });
            return run.total_advance;
        }
    }.of;

    const one_person = try adv(cx, "\u{1F468}");
    // 家庭序列（👨 ZWJ 👩 ZWJ 👧）= 单字形，宽度 ≈ 单成员
    try std.testing.expectApproxEqAbs(one_person, try adv(cx, "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"), 0.5);
    // ❤️‍🔥（BMP 成员 2764+VS16 起头的 ZWJ 序列）= 单字形
    try std.testing.expectApproxEqAbs(try adv(cx, "\u{1F525}"), try adv(cx, "\u{2764}\u{FE0F}\u{200D}\u{1F525}"), 0.5);
    // 肤色修饰与旗帜（无 ZWJ 的多码点簇）也必须保持单字形
    try std.testing.expectApproxEqAbs(try adv(cx, "\u{1F44B}"), try adv(cx, "\u{1F44B}\u{1F3FB}"), 0.5);
    try std.testing.expectApproxEqAbs(one_person, try adv(cx, "\u{1F1FA}\u{1F1F8}"), 0.5);
}

// #36 根因 4 锁：CoreText cascade 是 run 上下文相关的，🈶 (U+1F236) 孤立
// 塑形走 Apple Color Emoji (~1.33em)，跟在 CJK run 后曾被 PingFang 接走
// (1em)。强制 emoji 字体后 advance 必须与上下文无关（CJK 无跨字距，
// 整串宽度 = 各段之和才成立；渲染端 per-codepoint 分段与度量端整串
// CTLine 的一致性正建立在这条性质上）。
test "SMP emoji advance 与 run 上下文无关（下游回归）" {
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    var fonts = try FontSystem.init(std.testing.allocator);
    defer fonts.deinit();
    cx.text.setFontSystem(&fonts);
    defer cx.text.clearFontSystem();

    const adv = struct {
        fn of(c: *Cx, s: []const u8) !f32 {
            const run = try c.text.shapeText(.{ .text = s, .font_family = "system", .font_size = 16 });
            return run.total_advance;
        }
    }.of;

    const cjk = try adv(cx, "工有");
    const yo = try adv(cx, "\u{1F236}");
    try std.testing.expectApproxEqAbs(cjk + yo, try adv(cx, "工有\u{1F236}"), 0.05);
    // 孤立 🈶 必须是 emoji 呈现（~1.33em），不是 PingFang 的 1em
    try std.testing.expect(yo > 16.5);
}

// 光标 x 与选区宽度对宽字形/多码点簇必须等于真实 shaping 度量。
//
// 每个 caret stop 的 x 必须精确等于该前缀的 shaping 宽度（不是码点数×常量、
// 不是 UTF-16 code unit 数推出来的估算）；选中单个字形时 selectionRects 的
// 宽度必须等于该字形的 advance（= 前缀差）。emoji 曾表现为“光标停在左边、
// 选区只盖左半边”，即宽度被算成实际的约一半。
test "caret x 与选区宽度 = 真实 shaping 度量（emoji/CJK/组合/ZWJ）" {
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    var fonts = try FontSystem.init(std.testing.allocator);
    defer fonts.deinit();
    cx.text.setFontSystem(&fonts);
    defer cx.text.clearFontSystem();

    const cases = [_][]const u8{
        "a\u{1F60A}b", // 单码点 SMP emoji（代理对）
        "a\u{4E2D}\u{6587}b", // CJK 全角
        "a\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}b", // ZWJ 家庭
        "ae\u{0301}b", // 组合音标
        "a\u{2764}\u{FE0F}b", // BMP + VS16 变体选择符
        "a\u{1F44B}\u{1F3FB}b", // 肤色修饰
    };
    const font_size: f32 = 24;
    for (cases) |s| {
        const line = try cx.text.visualLine(.{ .text = s, .font_family = "system", .font_size = font_size });

        // 1) 每个 caret stop 的 x == 该前缀的真实 shaping 宽度
        for (line.caret_stops) |stop| {
            const byte = stop.position.byte.value;
            try std.testing.expect(text_core_module.text_coordinates.isGraphemeBoundary(s, byte));
            const prefix = cx.text.measureTextWidth(s[0..byte], font_size, 400, false);
            try std.testing.expectApproxEqAbs(prefix, stop.x.value, 0.05);
        }

        // 2) 选中中间那个字形（去掉首尾 'a'/'b'）：选区宽度 == 该字形 advance
        const glyph_start: usize = 1;
        const glyph_end: usize = s.len - 1;
        var storage: [8]text_core_module.text_coordinates.SelectionRect = undefined;
        const rects = try line.selectionRects(
            .{ .value = glyph_start },
            .{ .value = glyph_end },
            &storage,
        );
        try std.testing.expectEqual(@as(usize, 1), rects.len);
        const x0 = cx.text.measureTextWidth(s[0..glyph_start], font_size, 400, false);
        const x1 = cx.text.measureTextWidth(s[0..glyph_end], font_size, 400, false);
        try std.testing.expectApproxEqAbs(x0, rects[0].x, 0.05);
        try std.testing.expectApproxEqAbs(x1 - x0, rects[0].width, 0.05);
        // 宽字形不能退化成半宽：中间字形至少要有可见宽度
        try std.testing.expect(rects[0].width > 1.0);
    }
}

// 点击命中回归：点到字形正中，光标必须落到该字形的某个边界（不得落进簇内部），
// 且点到字形右半边应吸附到右边界，emoji 光标停左边的对称面。
test "点击命中在宽字形上吸附到字形边界（emoji/CJK/ZWJ）" {
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    var fonts = try FontSystem.init(std.testing.allocator);
    defer fonts.deinit();
    cx.text.setFontSystem(&fonts);
    defer cx.text.clearFontSystem();

    // 每例中间恰好一个字形（点击吸附的目标必须唯一）
    const cases = [_][]const u8{
        "a\u{1F60A}b",
        "a\u{4E2D}b",
        "a\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}b",
        "a\u{1F44B}\u{1F3FB}b",
    };
    const font_size: f32 = 24;
    for (cases) |s| {
        const line = try cx.text.visualLine(.{ .text = s, .font_family = "system", .font_size = font_size });
        const glyph_start: usize = 1;
        const glyph_end: usize = s.len - 1;
        const x0 = cx.text.measureTextWidth(s[0..glyph_start], font_size, 400, false);
        const x1 = cx.text.measureTextWidth(s[0..glyph_end], font_size, 400, false);

        // 点右侧 75% 处 -> 吸附到字形右边界
        const right = line.xToPosition(.{ .value = x0 + (x1 - x0) * 0.75 });
        try std.testing.expect(text_core_module.text_coordinates.isGraphemeBoundary(s, right.byte.value));
        try std.testing.expectEqual(glyph_end, right.byte.value);

        // 点左侧 25% 处 -> 吸附到字形左边界
        const left = line.xToPosition(.{ .value = x0 + (x1 - x0) * 0.25 });
        try std.testing.expect(text_core_module.text_coordinates.isGraphemeBoundary(s, left.byte.value));
        try std.testing.expectEqual(glyph_start, left.byte.value);
    }
}

// 下游应用实测回归：按字节切的前缀落在 3 字节 CJK 中间（"asfd🎩"+半截一 =
// 9B 非法 UTF-8）时，CoreText NSString 构造失败，shape 层报
// TextShapingFailed、FontSelector 桥静默返 0.0f，measureTextWidth 最终
// 吐出精确 0.00 塌掉提交 bbox。修复：入口先裁到最长合法 UTF-8 前缀。
test "measureTextWidth 对截断 UTF-8（半个 CJK）不塌成 0" {
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    var fonts = try FontSystem.init(std.testing.allocator);
    defer fonts.deinit();
    cx.text.setFontSystem(&fonts);
    defer cx.text.clearFontSystem();

    // 模拟 app 侧 FontSelector 桥：对非法 UTF-8 返 0（nil NSString 路径）。
    // 修复前截断串走到这条腿 -> 精确 0.00；修复后 shapeText 先成功，不会到这。
    const Bridge = struct {
        fn zeroOnInvalid(_: *anyopaque, ptr: [*]const u8, len: usize, _: f32, _: u16, _: bool) f32 {
            return if (std.unicode.utf8ValidateSlice(ptr[0..len])) 999 else 0;
        }
    };
    var dummy: u8 = 0;
    cx.text.measure_ctx_fn = Bridge.zeroOnInvalid;
    cx.text.measure_ctx = @ptrCast(&dummy);

    const valid = "asfd\u{1F3A9}";
    const trunc = "asfd\u{1F3A9}\xe4"; // 9B：valid + 一 的首字节，非法 UTF-8
    try std.testing.expect(!std.unicode.utf8ValidateSlice(trunc));

    const w_valid = cx.text.measureTextWidth(valid, 16, 400, false);
    const w_trunc = cx.text.measureTextWidth(trunc, 16, 400, false);
    try std.testing.expect(w_valid > 0);
    // 截断串按最长合法前缀测量 = valid 的宽度（不再是 0，也不是桥的 999）
    try std.testing.expectApproxEqAbs(w_valid, w_trunc, 0.01);

    // 前缀整体非法（首字节即 continuation）时无前缀可裁，仍返 0
    try std.testing.expectEqual(@as(f32, 0), cx.text.measureTextWidth("\x80\x80", 16, 400, false));
}

test "shapeText 的缓存必须按 font_family 分桶（字体选择器预览的前置条件）" {
    // == bug 形状 ==
    // shapingKey 原先把 font_id 恒写 0、且不把 family 计入 text_hash。
    // 于是同一段文本换个 family 再 shape，会命中**上一个 family** 的缓存条目，
    // 拿回上一个字体的字形与宽度。
    //
    // 平时看不出来，因为全部生产调用点都传字面量 "system"（唯一 family，
    // 永远自洽）。但字体选择器的预览列表要用不同 family 画同一个字符串
    // （比如都画 "Aa"），这个 bug 会让第 2 行起全部退化成第 1 行的字体。
    //
    // 判据不写死像素（随系统字体版本漂移会脆），而是断言
    // 「两个差异极大的字体不能量出同一个宽度」，这正是 bug 的形状。
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    var fonts = try FontSystem.init(std.testing.allocator);
    defer fonts.deinit();
    cx.text.setFontSystem(&fonts);
    defer cx.text.clearFontSystem();

    const probe = "Aa Bb";
    const helv = try cx.text.shapeText(.{
        .text = probe,
        .font_family = "Helvetica Neue",
        .font_size = 16,
    });
    // Zapfino 是花体，同样字符串宽得多；两者不可能同宽。
    const zapf = try cx.text.shapeText(.{
        .text = probe,
        .font_family = "Zapfino",
        .font_size = 16,
    });

    try std.testing.expect(helv.total_advance > 0);
    try std.testing.expect(zapf.total_advance > 0);
    try std.testing.expect(helv.total_advance != zapf.total_advance);

    // 反向再取一次：缓存命中路径也必须分桶（不能第二次取又串回去）。
    const helv2 = try cx.text.shapeText(.{
        .text = probe,
        .font_family = "Helvetica Neue",
        .font_size = 16,
    });
    try std.testing.expectEqual(helv.total_advance, helv2.total_advance);
}

test "生存哨兵：新建节点是 ALIVE" {
    // 哨兵的负向验证不能在测试里做「释放后再读」，那本身就是 UAF，GPA 会先报。
    // 真正的负向复现方式记录在这里：把 freeNodeNow 入口的哨兵检查注释掉，
    // 再对同一节点调用两次 freeNode，Debug 下第二次会走进已被 0xaa 覆写的
    // `freeing`（读出 true）从而静默 early-return，那正是这个哨兵要消灭的
    // 「无声 no-op」。有哨兵时第二次会当场 panic。
    const ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();
    const n = try builders.box(ctx, .{ .width = .{ .px = 10 } }, .{});
    try std.testing.expect(n.alive_sentinel == core_node.ALIVE_SENTINEL);
    ctx.freeNode(n);
}

test "ensurePopoverPortalRoot: 构建中途 OOM 回滚回收 ElementTable slot" {
    // errdefer 原为 portal.destroy：Node.destroy 不调 world.destroyElement，
    // 每次失败漏一个 element slot（及镜像表残留行）。逐分配点注入失败。
    var fa = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const ctx = try Cx.init(fa.allocator());
    defer ctx.deinit();
    const root_node = try builders.box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root_node;
    // 预热：World 元素表 / 样式来源表等是摊还扩容，首次 box 比之后多分配。
    // 不预热的话 k 递增的同时 box 所需分配数递减，恰好跳过"box 之后"的失败点。
    ctx.freeNode(try builders.box(ctx, .{ .position = .absolute }, .{}));

    var saw_failure_after_box = false;
    var k: usize = 0;
    while (k < 64) : (k += 1) {
        const before = ctx.world.elements.count();
        fa.fail_index = fa.alloc_index + k;
        const result = ctx.ensurePopoverPortalRoot();
        fa.fail_index = std.math.maxInt(usize);
        if (result) |portal| {
            try std.testing.expectEqual(portal, ctx.popover_portal_root.?);
            break;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expect(ctx.popover_portal_root == null);
            try std.testing.expectEqual(@as(usize, 0), root_node.children.items.len);
            if (k > 0) saw_failure_after_box = true;
            try std.testing.expectEqual(before, ctx.world.elements.count());
        }
    }
    try std.testing.expect(k < 64);
    try std.testing.expect(saw_failure_after_box);
}

test "NodeRegistry: 节点释放后 generations 不再只增不减" {
    const ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();
    const root_node = try builders.box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root_node;
    const baseline = ctx.node_registry.generations.count();

    var i: usize = 0;
    while (i < 500) : (i += 1) {
        const n = try builders.box(ctx, .{ .width = .{ .px = 10 }, .height = .{ .px = 10 } }, .{});
        try root_node.appendChild(std.testing.allocator, n);
        try ctx.node_registry.rebuild(ctx.root);
        const h = ctx.node_registry.handleFor(n);
        try std.testing.expectEqual(n, ctx.node_registry.resolve(h, null).?);
        ctx.detachChild(root_node, n);
        ctx.freeNode(n);
        // 释放后旧 handle 必须解析失败、身份失效
        try std.testing.expect(ctx.node_registry.resolve(h, null) == null);
    }
    try ctx.node_registry.rebuild(ctx.root);
    try std.testing.expect(ctx.node_registry.generations.count() <= baseline + 1);
}

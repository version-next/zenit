//! 组件 mount 的逐分配点 OOM 注入 sweep —— 测试支撑，不进产品代码路径。
//!
//! 由来：第124～126轮（下游编辑器）与（Spinner）都证明，mount 里的守卫
//! 靠读代码审不完；只有在每一个分配点上各注入一次失败、用 per-case GPA 判定
//! "有没有东西没释放"才靠得住。scroll_area / spinner 各自手抄了一份 40 行的
//! sweep，这里收成一个泛型入口，让每个组件的 sweep 测试只剩 5 行。
//!
//! 判定口径：
//! - 每个注入点一个独立的 `GeneralPurposeAllocator(.{ .safety = true })`，
//!   用它的 `deinit() == .leak` 做判定。用 arena 会把泄漏整体回收，看不见。
//! - mount 成功时调用方（这里）负责 `freeNode(root)`；失败时不做任何事 ——
//!   失败路径该不该自己收拾干净正是被测的契约。
//! - 空转防护按**比例**而不是绝对下限：`induced > 0` 只要求 889 个分配点里
//!   有 1 个被诱发失败，实测值是 885（99.5%），门槛低了三个数量级 —— mount
//!   哪天提前 return、分配点从几百掉到个位数，测试照样绿。改成要求至少一半
//!   分配点能诱发失败：比例是稳定不变式，绝对值会随组件演进漂移。
const std = @import("std");
const core = @import("../core.zig");
pub const Cx = core.Cx;
pub const Node = core.Node;
pub const Scope = @import("../reactive.zig").Scope;

/// 被测 mount 的统一形态：返回要由调用方回收的根节点（null = 没有根节点要回收）。
pub const MountFn = *const fn (scope: *Scope, cx: *Cx) anyerror!?*Node;

pub fn sweepMount(comptime label: []const u8, mount: MountFn) !void {
    const t = std.testing;

    // 先量一次成功调用用掉多少个分配点。
    const total_allocs = blk: {
        var arena = std.heap.ArenaAllocator.init(t.allocator);
        defer arena.deinit();
        var counting = t.FailingAllocator.init(arena.allocator(), .{});
        const ctx = try Cx.init(counting.allocator());
        defer ctx.deinit();
        // Popover/Tooltip 一类要挂 portal，需要 cx.root；与各组件 basic 测试同形。
        ctx.root = try core.box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
        const scope = try Scope.init(counting.allocator(), null, ctx.owner);
        defer scope.dispose();
        const before = counting.alloc_index;
        _ = try mount(scope, ctx);
        break :blk counting.alloc_index - before;
    };
    try t.expect(total_allocs > 0);

    var induced: usize = 0;
    var leaked: usize = 0;
    var first_leak: ?usize = null;
    for (0..total_allocs) |failure_index| {
        var gpa = std.heap.GeneralPurposeAllocator(.{ .safety = true }){};
        {
            var failing = t.FailingAllocator.init(gpa.allocator(), .{});
            const ctx = Cx.init(failing.allocator()) catch {
                _ = gpa.deinit();
                continue;
            };
            ctx.root = core.box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{}) catch {
                ctx.deinit();
                _ = gpa.deinit();
                continue;
            };
            const scope = Scope.init(failing.allocator(), null, ctx.owner) catch {
                ctx.deinit();
                _ = gpa.deinit();
                continue;
            };
            failing.fail_index = failing.alloc_index + failure_index;
            failing.resize_fail_index = failing.resize_index + failure_index;
            const result = mount(scope, ctx);
            failing.fail_index = std.math.maxInt(usize);
            failing.resize_fail_index = std.math.maxInt(usize);
            if (result) |maybe_root| {
                if (maybe_root) |root| ctx.freeNode(root);
            } else |_| {
                induced += 1;
            }
            scope.dispose();
            ctx.deinit();
        }
        if (gpa.deinit() == .leak) {
            leaked += 1;
            if (first_leak == null) first_leak = failure_index;
        }
    }
    // 见文件头：按比例卡，不按绝对下限。正常值接近 100%（每个分配点注入一次
    // 失败，mount 基本都会失败返回）；掉到一半以下说明 sweep 没真正覆盖 mount。
    const min_induced = total_allocs / 2;
    if (induced < min_induced) {
        std.debug.print(
            "\n[{s}] sweep 覆盖坍塌: induced={d} / total_allocs={d}（要求 >= {d}）\n",
            .{ label, induced, total_allocs, min_induced },
        );
    }
    try t.expect(induced >= min_induced);
    if (leaked > 0) {
        std.debug.print(
            "\n[{s}] LEAK at {d}/{d} failure points; first={?d}\n",
            .{ label, leaked, total_allocs, first_leak },
        );
    }
    try t.expectEqual(@as(usize, 0), leaked);
}

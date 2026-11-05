//! Component mount per-allocation OOM injection sweep. Test support, not a product code path.
//!
//! Guards in mount cannot be verified by reading code; the reliable method is injecting a failure
//! at each allocation point and using a per-case GPA to judge whether anything leaked.
//!
//! Judgment criteria:
//! - Each injection point gets its own `GeneralPurposeAllocator(.{ .safety = true })`; judge by
//!   `deinit() == .leak`. An arena hides leaks entirely.
//! - On mount success the caller (here) calls `freeNode(root)`; on failure it does nothing. Whether
//!   the failure path cleans up after itself is the contract under test.
//! - Idle protection is a **ratio**, not an absolute floor: `induced > 0` would pass with 1 of ~889
//!   points failing. Require at least half of the points to induce failure; the ratio is a stable
//!   invariant, absolute counts drift as components evolve.
//! - No fake success: a mount that reports success must look exactly like the uninjected mount
//!   (`Appearance`). A write that swallowed its allocation failure (a dropped style layer, a
//!   transition never configured, a label left at its placeholder) fails the sweep, naming the
//!   first differing node and field with both values.
//! - Two passes: a persistent failure (every allocation from the point on fails, the classic
//!   cleanup check) and a transient one (exactly one allocation fails, everything after it
//!   succeeds). A swallowed failure is only visible in the persistent pass when it happens at the
//!   very end of the mount; the transient pass is what exposes a mount that drops a write and
//!   carries on. `ZENIT_SWEEP_TRACE=<label>:<point>` prints the stack of the transient failure
//!   at that point.
const std = @import("std");
const core = @import("../core.zig");
pub const Cx = core.Cx;
pub const Node = core.Node;
pub const Scope = @import("../reactive.zig").Scope;

/// Tested mount unified shape: return root node caller must free (null = no root to free).
pub const MountFn = *const fn (scope: *Scope, cx: *Cx) anyerror!?*Node;

/// `ZENIT_MOUNT_STATS=1`: test mount once and print allocation count, new signals/memos/effects.
fn mountStatsOnly() bool {
    return @import("zenit_environment").flag("ZENIT_MOUNT_STATS");
}

/// Checks a successfully mounted root (`sweepMountVerified`): a mount that reports success must
/// have fully applied its effects, never silently dropped part of them on a failed allocation.
pub const VerifyFn = *const fn (root: *Node) anyerror!void;

pub fn sweepMount(comptime label: []const u8, mount: MountFn) !void {
    return sweep(label, mount, null);
}

/// `sweepMount`, plus: at every injection point where mount still succeeds, `verify` must accept
/// the mounted root as well (component-specific invariants beyond its appearance).
pub fn sweepMountVerified(comptime label: []const u8, mount: MountFn, verify: ?VerifyFn) !void {
    return sweep(label, mount, verify);
}

fn sweep(comptime label: []const u8, mount: MountFn, verify: ?VerifyFn) !void {
    const t = std.testing;
    var reference: ?Appearance = null;
    defer if (reference) |*r| r.deinit();

    // Measure successful call cost in allocation points.
    const total_allocs = blk: {
        var arena = std.heap.ArenaAllocator.init(t.allocator);
        defer arena.deinit();
        var counting = t.FailingAllocator.init(arena.allocator(), .{});
        const ctx = try Cx.init(counting.allocator(), std.testing.io);
        defer ctx.deinit();
        // Popover/Tooltip etc. need portal, require cx.root; same shape as component's basic tests.
        ctx.root = try core.box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
        const scope = try Scope.init(counting.allocator(), null, ctx.owner);
        defer scope.dispose();
        const before = counting.alloc_index;
        const kinds_before = ctx.owner.graph.countByKind();
        const root = try mount(scope, ctx);
        const allocs = counting.alloc_index - before;
        reference = try Appearance.capture(t.allocator, root);
        if (mountStatsOnly()) {
            const kinds_after = ctx.owner.graph.countByKind();
            std.debug.print("[mount-stats] {s} allocs={d} signal={d} memo={d} effect={d}\n", .{
                label,
                allocs,
                kinds_after.get(.signal) - kinds_before.get(.signal),
                kinds_after.get(.memo) - kinds_before.get(.memo),
                kinds_after.get(.effect) - kinds_before.get(.effect),
            });
        }
        break :blk allocs;
    };
    try t.expect(total_allocs > 0);
    // Skip per-point injection when only sampling mount baseline (docs/SIGNAL_API_DESIGN.md §7 P0
    // baseline).
    if (mountStatsOnly()) return;

    // During injection, control flow regions (For / Show...) on allocation failure mid-effect
    // downgrade to "log error, keep old row" by design, not leak; its err log fails the test,
    // suppress here (leaks still judged by GPA).
    const control_flow = @import("../control_flow.zig");
    control_flow.control_flow_suppress_error_log = true;
    defer control_flow.control_flow_suppress_error_log = false;

    try injectPass(label, mount, verify, &reference.?, total_allocs, .persistent);
    try injectPass(label, mount, verify, &reference.?, total_allocs, .transient);
}

const FailureMode = enum { persistent, transient };

/// `ZENIT_SWEEP_TRACE=<label>:<point>`: print where the transient failure at that point was
/// allocated (finding the write a fake success swallowed).
fn traceRequested(label: []const u8, point: usize) bool {
    var buf: [256]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const raw = @import("zenit_environment").getOwned(fba.allocator(), "ZENIT_SWEEP_TRACE") catch return false;
    const colon = std.mem.lastIndexOfScalar(u8, raw, ':') orelse return false;
    if (!std.mem.eql(u8, raw[0..colon], label)) return false;
    return (std.fmt.parseInt(usize, raw[colon + 1 ..], 10) catch return false) == point;
}

/// Fails exactly one allocation (the `fail_at`-th from arming), then lets everything through.
const TransientFailingAllocator = struct {
    child: std.mem.Allocator,
    index: usize = 0,
    fail_at: usize = std.math.maxInt(usize),
    /// dump the stack of the failed allocation (`ZENIT_SWEEP_TRACE`)
    trace: bool = false,

    fn allocator(self: *TransientFailingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *TransientFailingAllocator = @ptrCast(@alignCast(ctx));
        defer self.index += 1;
        if (self.index == self.fail_at) {
            if (self.trace) std.debug.dumpCurrentStackTrace(.{ .first_address = @returnAddress() });
            return null;
        }
        return self.child.rawAlloc(len, alignment, ra);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *TransientFailingAllocator = @ptrCast(@alignCast(ctx));
        return self.child.rawResize(memory, alignment, new_len, ra);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *TransientFailingAllocator = @ptrCast(@alignCast(ctx));
        return self.child.rawRemap(memory, alignment, new_len, ra);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *TransientFailingAllocator = @ptrCast(@alignCast(ctx));
        self.child.rawFree(memory, alignment, ra);
    }
};

fn injectPass(
    comptime label: []const u8,
    mount: MountFn,
    verify: ?VerifyFn,
    reference: *const Appearance,
    total_allocs: usize,
    comptime mode: FailureMode,
) !void {
    const t = std.testing;
    var induced: usize = 0;
    var leaked: usize = 0;
    var first_leak: ?usize = null;
    var unverified: usize = 0;
    var first_unverified: ?usize = null;
    for (0..total_allocs) |failure_index| {
        var gpa = std.heap.DebugAllocator(.{ .safety = true }){};
        {
            var failing = switch (mode) {
                .persistent => t.FailingAllocator.init(gpa.allocator(), .{}),
                .transient => TransientFailingAllocator{ .child = gpa.allocator() },
            };
            const ctx = Cx.init(failing.allocator(), std.testing.io) catch {
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
            const result = switch (mode) {
                .persistent => r: {
                    failing.fail_index = failing.alloc_index + failure_index;
                    failing.resize_fail_index = failing.resize_index + failure_index;
                    const r = mount(scope, ctx);
                    failing.fail_index = std.math.maxInt(usize);
                    failing.resize_fail_index = std.math.maxInt(usize);
                    break :r r;
                },
                .transient => r: {
                    failing.fail_at = failing.index + failure_index;
                    failing.trace = traceRequested(label, failure_index);
                    const r = mount(scope, ctx);
                    failing.fail_at = std.math.maxInt(usize);
                    break :r r;
                },
            };
            if (result) |maybe_root| {
                const matches = matches: {
                    var got = try Appearance.capture(t.allocator, maybe_root);
                    defer got.deinit();
                    var where: Where = .{};
                    if (reference.diff(got, &where)) break :matches true;
                    if (first_unverified == null) std.debug.print(
                        "\n[{s}] {s} failure at point {d}: mount succeeded but differs from the reference mount at {s} ({s})\n",
                        .{ label, @tagName(mode), failure_index, where.path(), where.values },
                    );
                    break :matches false;
                };
                const verified = if (verify) |v| if (maybe_root) |root| if (v(root)) |_| true else |_| false else true else true;
                const complete = matches and verified;
                if (!complete) {
                    unverified += 1;
                    if (first_unverified == null) first_unverified = failure_index;
                }
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
    // See file header: card by ratio, not absolute floor. Normal ~100% (every allocation point
    // induced once, mount mostly fails return); dropping below half means sweep doesn't truly cover
    // mount. Only meaningful for persistent failures: a transient one may legitimately be absorbed
    // (a retry, an optional cache), as long as the result still matches the reference.
    if (mode == .persistent) {
        const min_induced = total_allocs / 2;
        if (induced < min_induced) {
            std.debug.print(
                "\n[{s}] sweep 覆盖坍塌: induced={d} / total_allocs={d}（要求 >= {d}）\n",
                .{ label, induced, total_allocs, min_induced },
            );
        }
        try t.expect(induced >= min_induced);
    }
    if (leaked > 0) {
        std.debug.print(
            "\n[{s}] {s} LEAK at {d}/{d} failure points; first={?d}\n",
            .{ label, @tagName(mode), leaked, total_allocs, first_leak },
        );
    }
    try t.expectEqual(@as(usize, 0), leaked);
    if (unverified > 0) {
        std.debug.print(
            "\n[{s}] {s}: mount reported success with incomplete state at {d}/{d} failure points; first={?d}\n",
            .{ label, @tagName(mode), unverified, total_allocs, first_unverified },
        );
    }
    try t.expectEqual(@as(usize, 0), unverified);
}

/// Everything a mounted tree shows, flattened depth-first and owned (independent of the Cx that
/// produced it), so an injected mount can be compared with the uninjected one.
pub const Appearance = struct {
    allocator: std.mem.Allocator,
    nodes: []Look,

    const types = @import("../core/types.zig");

    /// One node: structure, style (ext block by value), paint state, content and declared
    /// transitions. Identity (ids, World slots) and per-run pointers are left out.
    const Look = struct {
        depth: u32,
        tag: types.ElementTag,
        child_count: usize,
        style: types.Style,
        ext: ?types.StyleExt,
        grid: ?types.GridConfig,
        background: types.Color,
        opacity: f32,
        text: ?types.TextProps,
        icon: ?types.IconProps,
        image: ?types.ImageProps,
        transitions: ?types.TransitionSlots,
        /// A VirtualList content node: its rows are a per-frame projection with their own
        /// retry contract (`virtual_list.isVirtualContent`), so only the node itself is compared.
        virtual_rows: bool,
    };

    pub fn capture(allocator: std.mem.Allocator, root: ?*Node) !Appearance {
        var list: std.ArrayList(Look) = .empty;
        errdefer {
            for (list.items) |l| freeText(allocator, l.text);
            list.deinit(allocator);
        }
        if (root) |r| try collect(allocator, &list, r, 0);
        return .{ .allocator = allocator, .nodes = try list.toOwnedSlice(allocator) };
    }

    fn collect(allocator: std.mem.Allocator, list: *std.ArrayList(Look), node: *Node, depth: u32) !void {
        var look: Look = .{
            .depth = depth,
            .tag = node.tag,
            .child_count = node.children.items.len,
            .style = node.style,
            .ext = if (node.style.ext) |e| e.* else null,
            .grid = null,
            .background = node.getBackground(),
            .opacity = node.getOpacity(),
            .text = null,
            .icon = node.getIcon(),
            .image = node.getImage(),
            .transitions = if (node.frame_state.frame_local.runtime.transitions) |tr| tr.* else null,
            .virtual_rows = @import("virtual_list/mod.zig").isVirtualContent(node),
        };
        // the row projection's geometry and children are re-derived each pass
        if (look.virtual_rows) {
            look.child_count = 0;
            look.style.height = .{ .fit = .{} };
            look.style.translate_y = 0;
        }
        look.style.ext = null;
        if (look.ext) |*e| if (e.grid) |g| {
            look.grid = g.*;
            e.grid = null;
        };
        if (look.transitions) |*tr| for (&tr.slots) |*slot| {
            slot.on_complete_ctx = null;
        };
        if (node.getTextRaw()) |raw| {
            var tp = raw;
            // storage, not appearance: where the bytes live and who frees them
            tp.inline_buf = @splat(0);
            tp.inline_len = 0;
            tp.owned = false;
            tp.spans_owned = false;
            tp.content = try allocator.dupe(u8, raw.content);
            errdefer allocator.free(tp.content);
            tp.spans = try allocator.dupe(types.TextSpan, raw.spans);
            look.text = tp;
        }
        {
            errdefer freeText(allocator, look.text);
            try list.append(allocator, look);
        }
        if (look.virtual_rows) return;
        for (node.children.items) |child| try collect(allocator, list, child, depth + 1);
    }

    fn freeText(allocator: std.mem.Allocator, text: ?types.TextProps) void {
        const tp = text orelse return;
        allocator.free(tp.content);
        allocator.free(tp.spans);
    }

    pub fn deinit(self: *Appearance) void {
        for (self.nodes) |l| freeText(self.allocator, l.text);
        self.allocator.free(self.nodes);
    }

    /// True when `got` looks the same; otherwise `where` names the first difference.
    pub fn diff(self: Appearance, got: Appearance, where: *Where) bool {
        if (self.nodes.len != got.nodes.len) {
            where.push("node count");
            where.leaf(self.nodes.len, got.nodes.len);
            return false;
        }
        for (self.nodes, got.nodes, 0..) |want, have, i| {
            if (!deepEql(Look, want, have, where)) {
                where.pushIndex(i);
                return false;
            }
        }
        return true;
    }
};

/// Path to the first difference, built innermost-first while unwinding.
pub const Where = struct {
    buf: [512]u8 = undefined,
    start: usize = 512,
    /// reference value vs mounted value at the first differing leaf
    values_buf: [256]u8 = undefined,
    values: []const u8 = "",

    fn leaf(self: *Where, a: anytype, b: @TypeOf(a)) void {
        if (self.values.len > 0) return;
        self.values = std.fmt.bufPrint(&self.values_buf, "want {any}, got {any}", .{ a, b }) catch "(values too long)";
    }

    fn prepend(self: *Where, s: []const u8) void {
        const n = @min(s.len, self.start);
        self.start -= n;
        @memcpy(self.buf[self.start..][0..n], s[s.len - n ..]);
    }

    fn push(self: *Where, name: []const u8) void {
        if (self.start != self.buf.len) self.prepend(".");
        self.prepend(name);
    }

    fn pushIndex(self: *Where, i: usize) void {
        var tmp: [32]u8 = undefined;
        const s = std.fmt.bufPrint(&tmp, "node[{d}]", .{i}) catch "node[?]";
        self.push(s);
    }

    pub fn path(self: *const Where) []const u8 {
        return self.buf[self.start..];
    }
};

/// Structural equality through optionals, arrays, unions, slices and single pointers;
/// type-erased (`anyopaque`) pointers only compare presence.
fn deepEql(comptime T: type, a: T, b: T, where: *Where) bool {
    if (T == @import("../core/types.zig").GridConfig) {
        // tracks past the counts are undefined
        return a.column_count == b.column_count and a.row_count == b.row_count and
            a.column_gap == b.column_gap and a.row_gap == b.row_gap and
            deepEql([]const @TypeOf(a.columns[0]), a.columns[0..a.column_count], b.columns[0..b.column_count], where) and
            deepEql([]const @TypeOf(a.rows[0]), a.rows[0..a.row_count], b.rows[0..b.row_count], where);
    }
    switch (@typeInfo(T)) {
        .@"struct" => {
            inline for (@import("zenit_reflection").fields(T)) |f| {
                if (!deepEql(f.type, @field(a, f.name), @field(b, f.name), where)) {
                    where.push(f.name);
                    return false;
                }
            }
            return true;
        },
        .optional => |info| {
            if (a == null and b == null) return true;
            if (a == null or b == null) {
                where.leaf(a != null, b != null);
                return false;
            }
            return deepEql(info.child, a.?, b.?, where);
        },
        .array => |info| {
            for (a, b) |x, y| if (!deepEql(info.child, x, y, where)) return false;
            return true;
        },
        .@"union" => {
            const Tag = std.meta.Tag(T);
            if (@as(Tag, a) != @as(Tag, b)) return false;
            switch (a) {
                inline else => |va, tag| return deepEql(@TypeOf(va), va, @field(b, @tagName(tag)), where),
            }
        },
        .pointer => |info| switch (info.size) {
            .one => {
                if (@typeInfo(info.child) == .@"opaque") return true;
                if (@typeInfo(info.child) == .@"fn") return a == b;
                return deepEql(info.child, a.*, b.*, where);
            },
            .slice => {
                if (info.child == u8 and !std.mem.eql(u8, a, b)) {
                    where.leaf(a, b);
                    return false;
                }
                if (a.len != b.len) {
                    where.leaf(a.len, b.len);
                    return false;
                }
                for (a, b) |x, y| if (!deepEql(info.child, x, y, where)) return false;
                return true;
            },
            else => return true,
        },
        .float => {
            if (a == b or (std.math.isNan(a) and std.math.isNan(b))) return true;
            where.leaf(a, b);
            return false;
        },
        .void => return true,
        else => {
            if (a == b) return true;
            where.leaf(a, b);
            return false;
        },
    }
}

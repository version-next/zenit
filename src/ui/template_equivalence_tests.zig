//! Nine independent semantic projections, compared after mapping retained node and
//! signal identities by their logical preorder paths. No pointer bytes or struct
//! padding participate. The paint projection is the actual encoder command list.
const std = @import("std");
const ui = @import("ui.zig");
const v = ui.view;
const core = @import("core.zig");
const template = @import("template.zig");
const refl = @import("zenit_reflection");
const t = std.testing;
const AXId = core.a11y_tree.AXId;
const SignalBase = @import("reactive/signal_base.zig").SignalBase;

// Exhaustive normalization exemptions. This cache invalidation serial is not
// a drawing operand; all geometry/material/text fields remain significant.
// Additions require their own rationale and a gate sensitivity regression.
const paint_exemptions = .{"surface_content_version"};
const Snapshot = struct { tree: u64, declarations: u64, layout: u64, a11y: u64, paint: u64, behavior: u64, layers: u64, subscriptions: u64, scopes: u64, hooks: u64 };
const Hash = struct {
    hash: std.hash.Wyhash = std.hash.Wyhash.init(0),
    nodes: []const *ui.Node = &.{},
    pub fn feed(self: *Hash, x: anytype) void {
        const T = @TypeOf(x);
        if (T == core.GridConfig) {
            self.feed(x.column_count);
            self.feed(x.row_count);
            self.feed(x.columns[0..x.column_count]);
            self.feed(x.rows[0..x.row_count]);
            self.feed(x.column_gap);
            self.feed(x.row_gap);
            return;
        }
        if (T == AXId) {
            if (x.element()) |element| {
                for (self.nodes, 0..) |node, i| if (node.element_id_raw == element.raw()) {
                    self.feed(i);
                    return;
                };
                @panic("a11y identity has no logical node");
            }
            self.hash.update("null-ax");
            return;
        }
        switch (@typeInfo(T)) {
            .void => self.hash.update("void"),
            .bool => self.hash.update(&.{@intFromBool(x)}),
            .int, .float => {
                var copy = x;
                self.hash.update(std.mem.asBytes(&copy));
            },
            .comptime_int => self.feed(@as(i64, x)),
            .@"enum" => self.feed(@backingInt(x)),
            .optional => {
                self.feed(x != null);
                if (x) |value| self.feed(value);
            },
            .array, .vector => {
                for (x) |value| self.feed(value);
            },
            .@"struct" => {
                inline for (refl.fields(T)) |f| {
                    self.hash.update(f.name);
                    self.feed(@field(x, f.name));
                }
            },
            .@"union" => {
                const tag = std.meta.activeTag(x);
                self.hash.update(@tagName(tag));
                inline for (refl.fields(T)) |f| if (tag == @field(std.meta.Tag(T), f.name)) self.feed(@field(x, f.name));
            },
            .pointer => |p| switch (p.size) {
                .slice => {
                    self.feed(x.len);
                    for (x) |value| self.feed(value);
                },
                .one => self.feed(x.*),
                else => @compileError("unbounded pointer in semantic projection: " ++ @typeName(T)),
            },
            else => @compileError("unsupported semantic projection: " ++ @typeName(T)),
        }
    }
    pub fn finish(self: *const Hash) u64 {
        var copy = self.hash;
        return copy.final();
    }
};

fn collect(node: *ui.Node, nodes: *std.ArrayList(*ui.Node)) !void {
    try nodes.append(t.allocator, node);
    for (node.children.items) |child| try collect(child, nodes);
}
const Env = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    trace: Hash = .{},
    writes: usize = 0,
    errors_start: u64 = 0,
    next_frame_ms: f64 = 1000,
    fn write(raw: *anyopaque, signal: *SignalBase) void {
        const self: *Env = @ptrCast(@alignCast(raw));
        if (infrastructure(self.cx, signal)) return;
        var ordinal: usize = 0;
        const id = signalId(self.cx, self.scope, signal, &ordinal) orelse @panic("write has no logical signal");
        self.trace.feed(id);
        self.writes += 1;
    }
    fn infrastructure(cx: *ui.Cx, signal: *SignalBase) bool {
        if (cx.theme_signal) |s| if (&s.base == signal) return true;
        if (comptime @TypeOf(cx.style_signal) != void) if (cx.style_signal) |s| if (&s.base == signal) return true;
        if (cx.a11y_prefs_signal) |s| if (&s.base == signal) return true;
        return false;
    }
    fn signalId(cx: *ui.Cx, scope: *ui.Scope, signal: *SignalBase, ordinal: *usize) ?usize {
        for (scope.signals.items) |s| {
            if (infrastructure(cx, s)) continue;
            if (s == signal) return ordinal.*;
            ordinal.* += 1;
        }
        for (scope.children.items) |child| if (signalId(cx, child, signal, ordinal)) |id| return id;
        return null;
    }
    fn snapshot(self: *Env) !Snapshot {
        self.cx.frame_time_ms = self.next_frame_ms;
        fixture_now_ns = @intFromFloat(self.next_frame_ms * std.time.ns_per_ms);
        self.next_frame_ms += 1000;
        self.cx.bindFrameClock();
        self.cx.layout();
        _ = self.cx.render();
        self.cx.syncA11yTreeFromInteractions(self.cx.root.?);
        var nodes: std.ArrayList(*ui.Node) = .empty;
        defer nodes.deinit(t.allocator);
        try collect(self.cx.root.?, &nodes);
        try t.expectEqual(nodes.items.len, self.cx.world.elements.count());
        var tree = Hash{};
        var declarations = Hash{};
        var layers = Hash{};
        var layout = Hash{};
        var a11y = Hash{ .nodes = nodes.items };
        var paint = Hash{};
        for (nodes.items) |node| {
            tree.feed(node.tag);
            tree.feed(node.children.items.len);
            tree.feed(node.meta.ownership.meta.component_name);
            tree.feed(node.meta.ownership.meta.test_id);
            tree.feed(node.behavior.interaction.focusable);
            tree.feed(self.cx.isFocused(node));
            tree.feed(node.behavior.interaction.tab_index);
            tree.feed(node.behavior.interaction.window_region);
            tree.feed(node.behavior.interaction.pointer_down_focus);
            tree.feed(node.frame_state.state_bits.flags.hit_test_visible);
            inline for (refl.fields(@TypeOf(node.behavior.events))) |event| {
                tree.hash.update(event.name);
                tree.feed(@field(node.behavior.events, event.name) != null);
            }
            if (node.getText()) |text| tree.feed(text.content) else tree.hash.update("no-text");
            declarations.feed(node.style);
            declarations.feed(node.getBackground());
            declarations.feed(node.getOpacity());
            if (node.resolveTextProps()) |text| {
                inline for (refl.fields(@TypeOf(text))) |field| {
                    if (comptime !std.mem.eql(u8, field.name, "inline_buf") and !std.mem.eql(u8, field.name, "inline_len") and !std.mem.eql(u8, field.name, "owned")) declarations.feed(@field(text, field.name));
                }
            }
            v.visitTemplateStyleDecls(node, &layers, struct {
                fn visit(h: *Hash, kind: anytype, decl: anytype) void {
                    h.feed(kind);
                    h.feed(decl.mask);
                    h.feed(decl.decode());
                }
            }.visit);
            layout.feed(node.rectFromWorldOrFallback());
            if (self.cx.accessibility_tree.getNode(.fromRaw(node.element_id_raw))) |ax| {
                a11y.feed(ax);
            } else a11y.hash.update("unexposed");
        }
        const commands = self.cx.lowerForEncoderPaintTable();
        paint.feed(commands.len);
        for (commands) |command| {
            var normalized = command;
            // Retained-cache invalidation sequence is not a drawing operand.
            // Preview replays may increment it more often without changing the
            // command. Keep every geometry/material/text field in the hash.
            inline for (paint_exemptions) |field| @field(normalized, field) = 0;
            inline for (.{ "surface_stable_id", "glass_owner_id" }) |field| {
                const raw = @field(normalized, field);
                if (raw != std.math.maxInt(u32)) {
                    var found = false;
                    for (nodes.items, 0..) |node, i| if (node.id == raw) {
                        @field(normalized, field) = @intCast(i);
                        found = true;
                        break;
                    };
                    if (!found) return error.PaintIdentityUnmapped;
                }
            }
            paint.feed(normalized);
        }
        var behavior = self.trace;
        behavior.feed(ui.on.handler_error_count - self.errors_start);
        const graph = try @import("template_equivalence_graph.zig").snapshot(Hash, self.cx, self.scope);
        return .{ .subscriptions = graph.subscriptions, .scopes = graph.scopes, .hooks = hooks(self.cx), .tree = tree.finish(), .declarations = declarations.finish(), .layout = layout.finish(), .a11y = a11y.finish(), .paint = paint.finish(), .behavior = behavior.finish(), .layers = layers.finish() };
    }
};

fn sample(comptime T: type) T {
    if (comptime @typeInfo(T) == .@"union" and @hasDecl(T, "zenit_source")) return .{ .value = sample(T.Value) };
    if (T == ui.Handler(void)) return .{ .callback = struct {
        fn ignore(_: *anyopaque) void {}
    }.ignore, .context = @ptrCast(&dummy) };
    if (comptime @typeInfo(T) == .@"struct" and @hasDecl(T, "zenit_handler")) return .{ .ctx = @ptrCast(&dummy), .call_fn = struct {
        fn ignore(_: *anyopaque, _: T.Value) void {}
    }.ignore };
    return switch (@typeInfo(T)) {
        .void => {},
        .bool => false,
        .int => 2,
        .float => 96,
        .optional => null,
        .error_union => |e| sample(e.payload),
        .@"enum" => @fromBackingInt(@intCast(refl.fields(T)[0].value)),
        .pointer => |p| if (p.size == .slice and p.child == u8) "fixture" else if (p.size == .slice) &.{} else @compileError("provide fixture input for " ++ @typeName(T)),
        .@"struct" => blk: {
            var out: T = undefined;
            inline for (refl.fields(T)) |f| @field(out, f.name) = if (f.default_value_ptr) |ptr| @as(*const f.type, @ptrCast(@alignCast(ptr))).* else sample(f.type);
            break :blk out;
        },
        else => @compileError("provide fixture input for " ++ @typeName(T)),
    };
}
var dummy: u8 = 0;

fn props(comptime T: type) T {
    var out = sample(T);
    inline for (.{ "items", "options", "rows", "groups" }) |name| {
        if (comptime @hasField(T, name)) {
            const Field = @FieldType(T, name);
            const IsSource = comptime @typeInfo(Field) == .@"union" and @hasDecl(Field, "zenit_source");
            const Values = if (IsSource) Field.Value else Field;
            if (comptime @typeInfo(Values) == .pointer and @typeInfo(Values).pointer.size == .slice) {
                const E = @typeInfo(Values).pointer.child;
                const items = comptime [_]E{sample(E)};
                @field(out, name) = if (IsSource) .{ .value = &items } else &items;
            }
        }
    }
    return out;
}

var fixture_now_ns: i96 = 1_000_000_000;
const profiles = 2;
const steps = 9;
const life_steps = 7;

fn inputVariant(comptime T: type, original: T, profile: usize) T {
    if (profile == 0) return original;
    if (comptime @typeInfo(T) == .@"union" and @hasDecl(T, "zenit_source"))
        return .{ .value = inputVariant(T.Value, original.peek(), profile) };
    if (comptime @typeInfo(T) == .@"union" and @hasDecl(T, "zenit_model")) return switch (original) {
        .local => |value| .{ .local = inputVariant(T.Value, value, profile) },
        .controlled => |value| .{ .controlled = inputVariant(ui.Source(T.Value), value, profile) },
        .bound, .split => original,
    };
    return switch (@typeInfo(T)) {
        .bool => !original,
        .int => 3,
        .float => 73,
        .@"enum" => @fromBackingInt(@intCast(refl.fields(T)[refl.fields(T).len - 1].value)),
        .pointer => |p| if (p.size == .slice and p.child == u8) "alternate" else original,
        else => original,
    };
}

fn projection(prefix: []const u8, case: []const u8, profile: usize, step: usize, x: Snapshot) void {
    std.debug.print("\n{s} {s} {d} {d} {x} {x} {x} {x} {x} {x} {x} {x} {x}\n", .{
        prefix, case, profile, step, x.tree, x.declarations, x.layout, x.a11y, x.paint, x.behavior, x.subscriptions, x.scopes, x.hooks,
    });
}

fn equalSnapshot(expected: Snapshot, actual: Snapshot, case: []const u8, profile: usize, stage: usize, mode: template.Mode) !void {
    inline for (refl.fields(Snapshot)) |field| {
        if (@field(expected, field.name) != @field(actual, field.name)) {
            std.debug.print("\nLP3 differential mismatch {s} {s} profile={d} stage={d} mode={s}\n", .{ case, field.name, profile, stage, @tagName(mode) });
            return error.TemplateProjectionMismatch;
        }
    }
}

fn hooks(cx: *ui.Cx) u64 {
    var h = Hash{};
    h.feed(cx.owner.test_hooks);
    var trace = cx.owner.test_hook_trace;
    h.feed(trace.final());
    return h.finish();
}

fn golden(env: *Env, case: []const u8, profile: usize) !void {
    const Row = struct { tag: []const u8, children: usize, component: ?[]const u8, test_id: ?[]const u8, text: ?[]const u8, focusable: bool };
    var nodes: std.ArrayList(*ui.Node) = .empty;
    defer nodes.deinit(t.allocator);
    try collect(env.cx.root.?, &nodes);
    var rows: std.ArrayList(Row) = .empty;
    defer rows.deinit(t.allocator);
    for (nodes.items) |node| try rows.append(t.allocator, .{
        .tag = @tagName(node.tag),
        .children = node.children.items.len,
        .component = node.meta.ownership.meta.component_name,
        .test_id = node.meta.ownership.meta.test_id,
        .text = if (node.getText()) |text| text.content else null,
        .focusable = node.behavior.interaction.focusable,
    });
    const json = try std.json.Stringify.valueAlloc(t.allocator, rows.items, .{});
    defer t.allocator.free(json);
    std.debug.print("\nLP3_TREE {s} {d} {s}\n", .{ case, profile, json });
}

pub fn check(comptime module: type, comptime name: []const u8, comptime case: []const u8) !void {
    const Props = @field(module, name ++ "Props");
    const make = @field(module, name);
    const lifecycle = @hasDecl(module, "LP3State");
    var oracle: [profiles][steps]Snapshot = undefined;
    var life_oracle: [profiles][life_steps]Snapshot = undefined;
    var final_oracle: [profiles]u64 = undefined;
    inline for (.{ template.Mode.release_tree, .comptime_template, .runtime_template }, 0..) |mode, pass| {
        for (0..profiles) |profile| {
            var memory = t.FailingAllocator.init(t.allocator, .{});
            // Only the clock is replaced. Files, fonts, queues and all other IO
            // still use the test runner's real backend and original userdata.
            const saved_now = fixture_now_ns;
            fixture_now_ns = 1_000_000_000;
            defer fixture_now_ns = saved_now;
            var frozen_io_vtable = t.io.vtable.*;
            frozen_io_vtable.now = struct {
                fn now(_: ?*anyopaque, _: std.Io.Clock) std.Io.Timestamp {
                    return .{ .nanoseconds = fixture_now_ns };
                }
            }.now;
            const io = std.Io{ .userdata = t.io.userdata, .vtable = &frozen_io_vtable };
            const frame = @import("core/render_engine/mod.zig");
            const saved_clock = frame.saveFrameClock();
            defer frame.restoreFrameClock(saved_clock);
            const cx = try ui.Cx.init(memory.allocator(), io);
            var cx_alive = true;
            defer if (cx_alive) cx.deinit();
            const scope = try ui.Scope.init(memory.allocator(), null, cx.owner);
            var scope_alive = true;
            defer if (scope_alive) scope.dispose();
            var env = Env{ .cx = cx, .scope = scope, .errors_start = ui.on.handler_error_count };
            const was_suppressed = ui.on.suppress_error_log;
            if (comptime std.mem.eql(u8, name, "TryEvent")) ui.on.suppress_error_log = true;
            defer ui.on.suppress_error_log = was_suppressed;
            cx.owner.template_builder = mode;
            cx.viewport = .{ .width = 1000, .height = 800 };
            cx.frame_time_ms = 1000;
            cx.frame_dt_ms = 0;
            cx.frame_dt_seconds = 0;
            cx.test_frame_step_ms = 0;
            cx.bindFrameClock();
            cx.setTheme(&ui.theme.modes.light);
            if (@hasDecl(module, "store")) module.store = try scope.createSignal(i32, if (profile == 0) 3 else 9);
            defer if (@hasDecl(module, "store")) {
                module.store = null;
            };
            if (@hasDecl(module, "external_count")) module.external_count = try scope.createSignal(i32, if (profile == 0) 3 else 9);
            defer if (@hasDecl(module, "external_count")) {
                module.external_count = null;
            };
            if (@hasDecl(module, "log_len")) module.log_len = 0;
            if (@hasDecl(module, "lifecycle_len")) module.lifecycle_len = 0;
            if (@hasDecl(module, "batch_updates")) module.batch_updates = 0;
            if (@hasDecl(module, "toggles")) module.toggles = 0;
            if (@hasDecl(module, "task_store")) module.task_store = .{ .{ .id = 1, .title = "a", .done = false }, .{ .id = 2, .title = "b", .done = true } };
            var args = props(Props);
            inline for (refl.fields(Props)) |field| @field(args, field.name) = inputVariant(field.type, @field(args, field.name), profile);
            const State = if (lifecycle) module.LP3State else struct { value: i32 = 31 };
            const state_id = std.hash.Wyhash.hash(0, case);
            const state = try cx.state(State, state_id, .{});
            if (lifecycle) args.state = .{ .value = state };
            // Establish the host before emitting a portal. It is part of every
            // oracle, including fixtures without portals, in every builder.
            const host = try v.render(scope, cx, v.box(.{}, .{}));
            cx.root = host;
            const root = try v.render(scope, cx, make(args));
            try host.appendChild(cx.allocator, root);
            cx.owner.test_write_trace = .{ .context = @ptrCast(&env), .write = Env.write };
            for (0..steps) |stage| {
                if (comptime lifecycle) {
                    const ids = [_]?[]const u8{ null, "lp3-show", "lp3-match", "lp3-add", "lp3-remove", "lp3-clear", "lp3-fill", "lp3-match", "lp3-show" };
                    if (ids[stage]) |id| dispatch(cx, findId(host, id) orelse return error.MissingSequenceAction);
                } else if (stage == 1 or stage == 8) {
                    if (clickable(host)) |node| dispatch(cx, node);
                } else if (stage == 2) {
                    if (lastClickable(host)) |node| dispatch(cx, node);
                }
                if (stage == 3) cx.setTheme(&ui.theme.modes.dark);
                if (stage == 4) {
                    if (focusable(host)) |node| cx.setFocus(node);
                }
                if (stage == 5) {
                    if (focusable(host)) |node| {
                        cx.setFocus(node);
                        cx.handleKeyDown(.space, .{});
                        cx.handleKeyUp(.space, .{});
                    }
                }
                if (stage == 6) {
                    cx.layout();
                    const target = if (comptime lifecycle) (findId(host, "lp3-scroll") orelse return error.MissingScrollArea) else (scrollable(host) orelse host);
                    const rect = target.rectFromWorldOrFallback();
                    cx.handleScroll(.{ .x = rect.x + rect.w / 2, .y = rect.y + rect.h / 2, .dx = 0, .dy = -9 });
                }
                if (stage == 7) {
                    if (comptime std.mem.eql(u8, name, "TryEvent")) {
                        var target = findText(host, "Fail") orelse return error.MissingFailureAction;
                        while (target.behavior.events.on_click == null) target = target.parent orelse return error.MissingFailureAction;
                        const errors_before = ui.on.handler_error_count;
                        const suppress = ui.on.suppress_error_log;
                        ui.on.suppress_error_log = true;
                        dispatch(cx, target);
                        ui.on.suppress_error_log = suppress;
                        try t.expectEqual(errors_before + 1, ui.on.handler_error_count);
                    }
                    cx.clearFocus();
                    cx.setTheme(&ui.theme.modes.light);
                }
                const snapshot = try env.snapshot();
                if (pass == 0) {
                    oracle[profile][stage] = snapshot;
                    projection("LP3_PROJ", case, profile, stage, snapshot);
                    if (stage == 0) try golden(&env, case, profile);
                } else try equalSnapshot(oracle[profile][stage], snapshot, case, profile, stage, mode);
            }
            if (comptime std.mem.eql(u8, name, "TryEvent")) try t.expectEqual(env.errors_start + 2, ui.on.handler_error_count);
            if (comptime lifecycle) {
                const instance = v.componentInstance(root) orelse return error.MissingSequenceInstance;
                const setup = instance.setup;
                const state_count = cx.state_store.states.count();
                const signals = try t.allocator.dupe(*SignalBase, setup.signals.items);
                defer t.allocator.free(signals);
                const versions = try t.allocator.alloc(u64, signals.len);
                defer t.allocator.free(versions);
                for (signals, versions) |signal, *version| version.* = cx.owner.graph.getNode(@bitCast(signal.graph_node_raw)).?.version;
                const ref = module.lp3_ref orelse return error.MissingSequenceRef;
                const Plateau = struct { bytes: usize, nodes: usize, graph: usize, subscriptions: u64, scopes: u64 };
                var plateau: ?Plateau = null;
                for (0..life_steps) |stage| {
                    const generation = ref.generation;
                    cx.owner.test_template_wrap = stage % 2 == 1;
                    _ = try instance.rebuild();
                    try t.expectEqual(setup, instance.setup);
                    try t.expectEqualSlices(*SignalBase, signals, setup.signals.items);
                    for (signals, versions) |signal, version| try t.expectEqual(version, cx.owner.graph.getNode(@bitCast(signal.graph_node_raw)).?.version);
                    try t.expectEqual(ref, module.lp3_ref.?);
                    try t.expect(ref.get() != null and ref.generation > generation);
                    try t.expect(descendant(instance.parts.root.?, ref.get().?));
                    try t.expectEqual(state, try cx.state(State, state_id, .{}));
                    try t.expectEqual(state_count, cx.state_store.states.count());
                    try t.expectEqual(@as(i32, 42), state.value);
                    try t.expectEqual(@as(i32, if (profile == 0) 2 else 5), @as(*ui.Signal(i32), @ptrCast(@alignCast(signals[0]))).peek());
                    try t.expect(@as(*ui.Signal(bool), @ptrCast(@alignCast(signals[1]))).peek());
                    try t.expectEqual(module.SequenceMode.zero, @as(*ui.Signal(module.SequenceMode), @ptrCast(@alignCast(signals[2]))).peek());
                    const rows = @as(*ui.Signal([]const module.Row), @ptrCast(@alignCast(signals[3]))).peek();
                    try t.expectEqual(@as(usize, 2), rows.len);
                    try t.expectEqual(@as(u32, 1), rows[0].id);
                    try t.expectEqual(@as(u32, 2), rows[1].id);
                    try t.expectEqual(@as(usize, 1), state.mounts);
                    try t.expectEqualSlices(usize, &.{ 1, 0, stage + 2, stage + 1 }, &cx.owner.test_hooks);
                    const life_snapshot = try env.snapshot();
                    if (pass == 0) {
                        life_oracle[profile][stage] = life_snapshot;
                        projection("LP3_LIFEPROJ", case, profile, stage, life_snapshot);
                    } else try equalSnapshot(life_oracle[profile][stage], life_snapshot, case, profile, stage, mode);
                    if (stage >= 2 and stage % 2 == 0) {
                        const current: Plateau = .{ .bytes = memory.allocated_bytes - memory.freed_bytes, .nodes = cx.world.elements.count(), .graph = cx.owner.graph.nodeCount(), .subscriptions = life_snapshot.subscriptions, .scopes = life_snapshot.scopes };
                        if (plateau) |expected| try t.expectEqualDeep(expected, current) else plateau = current;
                    }
                }
                std.debug.print("\nLP3_LIFE {s} {d} {s} OK\n", .{ case, profile, @tagName(mode) });
            }
            cx.owner.test_write_trace = null;
            scope.dispose();
            scope_alive = false;
            const final = hooks(cx);
            if (pass == 0) {
                final_oracle[profile] = final;
                std.debug.print("\nLP3_FINAL {s} {d} {x}\n", .{ case, profile, final });
            } else try t.expectEqual(final_oracle[profile], final);
            if (comptime lifecycle) {
                try t.expectEqualSlices(usize, &.{ 1, 1, life_steps + 1, life_steps + 1 }, &cx.owner.test_hooks);
                module.lp3_ref = null;
            }
            cx.deinit();
            cx_alive = false;
            try t.expectEqual(memory.allocated_bytes, memory.freed_bytes);
        }
    }
    if (comptime @import("zenit_environment").dev_preview) try candidateMatrix(module, name, case);
    std.debug.print("\nLP3_EQ {s} tree StyleDecl layout a11y paint behavior subscriptions scopes hooks OK\n", .{case});
}
fn clickable(node: *ui.Node) ?*ui.Node {
    if (node.behavior.events.on_click != null) return node;
    for (node.children.items) |child| if (clickable(child)) |n| return n;
    return null;
}
fn lastClickable(node: *ui.Node) ?*ui.Node {
    var result: ?*ui.Node = if (node.behavior.events.on_click != null) node else null;
    for (node.children.items) |child| if (lastClickable(child)) |n| {
        result = n;
    };
    return result;
}
fn focusable(node: *ui.Node) ?*ui.Node {
    if (node.style.display == .none) return null;
    if (node.behavior.interaction.focusable) return node;
    for (node.children.items) |child| if (focusable(child)) |n| return n;
    return null;
}
fn scrollable(node: *ui.Node) ?*ui.Node {
    if (node.behavior.events.on_event != null) return node;
    for (node.children.items) |child| if (scrollable(child)) |n| return n;
    return null;
}
fn findId(node: *ui.Node, id: []const u8) ?*ui.Node {
    if (node.meta.ownership.meta.test_id) |actual| if (std.mem.eql(u8, actual, id)) return node;
    for (node.children.items) |child| if (findId(child, id)) |n| return n;
    return null;
}
fn descendant(root: *ui.Node, node: *ui.Node) bool {
    if (root == node) return true;
    for (root.children.items) |child| if (descendant(child, node)) return true;
    return false;
}

test "LP3 template equivalence complete fixture matrix" {
    try @import("template_equivalence_manifest.zig").run();
}

fn dispatch(cx: *ui.Cx, node: *ui.Node) void {
    const handler = node.behavior.events.on_click.?;
    cx.owner.beginReactiveCallback();
    defer cx.owner.endReactiveCallback();
    handler.callback(handler.context);
}
fn findText(node: *ui.Node, text: []const u8) ?*ui.Node {
    if (node.getText()) |value| if (std.mem.eql(u8, value.content, text)) return node;
    for (node.children.items) |child| if (findText(child, text)) |found| return found;
    return null;
}

// This tests the normalization boundary itself, independently of comparing two
// implementations that could accidentally make the same erroneous capture.
test "LP3 template graph projection refuses infrastructure business capture" {
    if (comptime @TypeOf(@as(ui.Cx, undefined).style_signal) == void) return;
    const cx = try ui.Cx.init(t.allocator, t.io);
    defer cx.deinit();
    const scope = try ui.Scope.init(t.allocator, null, cx.owner);
    defer scope.dispose();
    const business = try scope.createSignal(i32, 7);
    const generation = try cx.styleGenerationSignal();
    try scope.createEffect(.{ .business = business, .generation = generation }, struct {
        fn run(context: anytype) void {
            _ = context.business.get();
            _ = context.generation.get();
        }
    }.run);
    const raw = scope.effects.items[0].graph_node_raw;
    cx.owner.graph.getNode(@bitCast(raw)).?.test_preview_style_infrastructure = true;
    try t.expectError(error.ProjectionPreviewStyleCapturedBusinessSignal, @import("template_equivalence_graph.zig").snapshot(Hash, cx, scope));
}

// Shared publication state is measured independently of semantic projections.
// Iterate the generated manifest through check(), including every component and
// fixture; no hand-maintained allowlist can silently omit a new generated view.
const CandidateCounts = struct {
    visibility: usize = 0,
    press: usize = 0,
    hover: usize = 0,
    before_render: usize = 0,
    portals: usize = 0,
    after_layout: usize = 0,
    timers: usize = 0,
    fn tree(self: *@This(), node: *ui.Node) void {
        self.hover += @import("hooks.zig").testing.hoverListenerCount(node);
        const before = node.meta.per_frame.hooks.before_render;
        self.before_render += before.count + @as(usize, @intFromBool(before.main != null));
        for (node.children.items) |child| self.tree(child);
    }
    fn read(cx: *ui.Cx) @This() {
        var counts = @This(){ .visibility = cx.focus_manager.visibility_listeners.items.len, .press = cx.press_watchers.items.len, .after_layout = cx.after_layout_hooks.items.len, .timers = cx.timers.items.len };
        if (cx.root) |root| counts.tree(root);
        if (cx.popover_portal_root) |portal| counts.portals = portal.children.items.len;
        return counts;
    }
};
fn candidateMatrix(comptime module: type, comptime name: []const u8, comptime case: []const u8) !void {
    const cx = try ui.Cx.init(t.allocator, t.io);
    defer cx.deinit();
    const scope = try ui.Scope.init(t.allocator, null, cx.owner);
    defer scope.dispose();
    // Services exist before preparation, as they do in the publication host.
    _ = try cx.themeSignal();
    _ = try cx.styleGenerationSignal();
    _ = try cx.a11yPreferencesSignal();
    if (@hasDecl(module, "store")) module.store = try scope.createSignal(i32, 3);
    defer if (@hasDecl(module, "store")) {
        module.store = null;
    };
    if (@hasDecl(module, "external_count")) module.external_count = try scope.createSignal(i32, 3);
    defer if (@hasDecl(module, "external_count")) {
        module.external_count = null;
    };
    if (@hasDecl(module, "log_len")) module.log_len = 0;
    if (@hasDecl(module, "lifecycle_len")) module.lifecycle_len = 0;
    if (@hasDecl(module, "batch_updates")) module.batch_updates = 0;
    if (@hasDecl(module, "toggles")) module.toggles = 0;
    if (@hasDecl(module, "task_store")) module.task_store = .{ .{ .id = 1, .title = "a", .done = false }, .{ .id = 2, .title = "b", .done = true } };
    var args = props(@field(module, name ++ "Props"));
    if (@hasDecl(module, "LP3State")) args.state = .{ .value = try scope.createState(module.LP3State, .{}) };
    const host = try v.render(scope, cx, v.box(.{}, .{}));
    cx.root = host;
    const node = try v.render(scope, cx, @field(module, name)(args));
    try host.appendChild(cx.allocator, node);
    const instance = v.componentInstance(node) orelse return error.MissingCandidateMatrixInstance;
    const before = CandidateCounts.read(cx);
    var candidate = instance.prepareView() catch |err| {
        switch (err) {
            error.TemplateCandidateSideEffects, error.ViewTransactionUnsupported, error.TemplateOpaqueSideEffects => {},
            else => return err,
        }
        try t.expectEqualDeep(before, CandidateCounts.read(cx));
        std.debug.print("\nLP4_MATRIX {s} rejected clean\n", .{case});
        return;
    };
    try t.expectEqualDeep(before, CandidateCounts.read(cx));
    candidate.cancel();
    try t.expectEqualDeep(before, CandidateCounts.read(cx));
    // A second candidate exercises the same queue's real publication path. Old
    // registrations retire and candidate registrations replace them, so the net
    // live count equals the ordinary mount oracle rather than doubling it.
    var committed = try instance.prepareView();
    defer committed.cancel();
    try t.expectEqualDeep(before, CandidateCounts.read(cx));
    cx.owner.beginReactiveCallback();
    committed.commit() catch |err| {
        cx.owner.endReactiveCallback();
        return err;
    };
    cx.owner.endReactiveCallback();
    try t.expectEqualDeep(before, CandidateCounts.read(cx));
    std.debug.print("\nLP4_MATRIX {s} cancel commit clean\n", .{case});
}

test "LP5 scope oracle retains ordinary structure and rejects forged dev boundaries" {
    const cx = try ui.Cx.init(t.allocator, t.io);
    defer cx.deinit();
    const scope = try ui.Scope.init(t.allocator, null, cx.owner);
    defer scope.dispose();
    const graph = @import("template_equivalence_graph.zig");
    const before = try graph.snapshot(Hash, cx, scope);
    const extra = try scope.childScope();
    const with_empty = try graph.snapshot(Hash, cx, scope);
    try t.expect(before.scopes != with_empty.scopes);
    const signal = try extra.createSignal(u32, 7);
    try scope.createEffect(signal, struct {
        fn read(s: *@import("reactive.zig").Signal(u32)) void {
            _ = s.get();
        }
    }.read);
    const with_business = try graph.snapshot(Hash, cx, scope);
    try t.expect(before.subscriptions != with_business.subscriptions);
    for ([_]ui.Scope.TestPreviewBoundary{ .region_view, .slot_setup }) |role| {
        extra.test_preview_boundary = role;
        try t.expectError(if (comptime template.preview_enabled) error.ProjectionInvalidPreviewBoundary else error.ProjectionReleasePreviewBoundary, graph.snapshot(Hash, cx, scope));
    }
    extra.test_preview_boundary = .none;
}

//! Independent runtime-vs-compiled oracles, transaction and real-Cx regressions.
const std = @import("std");
const t = std.testing;
const ui = @import("ui.zig");
const css = @import("css.zig");
const core = @import("core.zig");
const theme = @import("theme.zig");
const reload = @import("style_reload.zig");
const compiler = @import("zenit_environment").preview.compiler;
const eq = @import("style_decl.zig").valueEql;
const Decl = @import("style_decl.zig").StyleDecl(core.BoxStyle);
const refl = @import("zenit_reflection");
pub const Counts = struct { files: usize = 0, supported: usize = 0, frozen: usize = 0, evaluations: usize = 0, box_projections: usize = 0, text_hovers: usize = 0 };

fn parsed(a: std.mem.Allocator, source: []const u8) !reload.ir.StyleIR {
    return switch (try compiler.compileIR(a, source)) {
        .ir => |v| v,
        .diagnostic => return error.InvalidFixture,
    };
}
fn boxValid(comptime S: type) bool {
    for (refl.fields(S)) |f| {
        if (std.mem.eql(u8, f.name, "transition")) continue;
        if (std.mem.startsWith(u8, f.name, "_")) {
            if (!boxValid(f.type)) return false;
            continue;
        }
        const name = if (std.mem.eql(u8, f.name, "color")) "text_color" else f.name;
        if (!@hasField(core.BoxStyle, name)) return false;
    }
    return true;
}
// Match the compiled text contract: only hover, and conditions may only
// change text fields. Box-only condition styles are never valid on <text>.
fn textApplicable(comptime S: type) bool {
    for (refl.fields(S)) |f| {
        if (!std.mem.startsWith(u8, f.name, "_")) continue;
        if (!std.mem.eql(u8, f.name, "_hover")) return false;
        for (refl.fields(f.type)) |p| {
            const name = if (std.mem.eql(u8, p.name, "text_color")) "color" else p.name;
            if (!@hasField(core.TextStyle, name) and !std.mem.eql(u8, name, "typography")) return false;
        }
    }
    return true;
}
fn assertDecl(a: core.BoxStyle, b: core.BoxStyle) !void {
    const ad = try Decl.encode(t.allocator, a);
    defer ad.deinit(t.allocator);
    const bd = try Decl.encode(t.allocator, b);
    defer bd.deinit(t.allocator);
    try t.expect(ad.eql(bd));
}
fn conditional(a: core.ConditionalStyle, b: core.ConditionalStyle, counts: *Counts) !void {
    inline for (refl.fields(core.ConditionalStyle)) |f| {
        if (comptime std.mem.eql(u8, f.name, "base")) try assertDecl(a.base, b.base) else {
            const av = @field(a, f.name);
            const bv = @field(b, f.name);
            try t.expectEqual(av == null, bv == null);
            if (av) |value| try assertDecl(value, bv.?);
        }
    }
    for (0..256) |bits| {
        var state: core.InteractionState = .{};
        inline for (refl.fields(core.InteractionState), 0..) |f, i| @field(state, f.name) = bits & (@as(usize, 1) << i) != 0;
        try assertDecl(a.resolve(state), b.resolve(state));
        counts.evaluations += 1;
    }
}
fn frozenLayer(layer: reload.ir.Layer) bool {
    for (layer.properties) |p| if (!std.mem.eql(u8, p.name, "transition") and reload.ir.hasFrozen(p.value)) return true;
    for (layer.conditions) |c| if (frozenLayer(c.layer.*)) return true;
    return false;
}
fn frozenDeclaration(d: *const reload.ir.Declaration) bool {
    if (frozenLayer(d.base)) return true;
    for (d.dimensions) |dim| for (dim.options) |opt| {
        if (frozenLayer(opt.layer)) return true;
    };
    for (d.compounds) |c| if (frozenLayer(c.layer)) return true;
    return false;
}
fn recipeCases(comptime R: type, d: *const reload.ir.Declaration, vs: R.Variants, comptime index: usize, tokens: *const theme.Values, counts: *Counts) !void {
    const fields = refl.fields(R.Variants);
    if (index == fields.len) {
        const oracle = R.preview_compiled.resolve(vs, tokens);
        const actual = reload.evaluateRecipe(d, vs, tokens) catch |err| {
            if (err == error.UnsupportedValue and frozenDeclaration(d)) {
                counts.frozen += 1;
                return;
            }
            return err;
        };
        try conditional(oracle, actual, counts);
        return;
    }
    const f = fields[index];
    if (f.type == bool) {
        inline for (.{ false, true }) |v| {
            var next = vs;
            @field(next, f.name) = v;
            try recipeCases(R, d, next, index + 1, tokens, counts);
        }
    } else inline for (refl.fields(f.type)) |option| {
        var next = vs;
        @field(next, f.name) = @field(f.type, option.name);
        try recipeCases(R, d, next, index + 1, tokens, counts);
    }
}
pub fn checkNamespace(comptime S: type, source: []const u8, path: []const u8, counts: *Counts) !void {
    @setEvalBranchQuota(1_000_000);
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const doc = try parsed(arena.allocator(), source);
    counts.files += 1;
    var found: usize = 0;
    inline for (comptime std.meta.declarations(S)) |name| {
        const member = @field(S, name);
        const Type = if (@TypeOf(member) == type) member else @TypeOf(member);
        if (comptime @typeInfo(Type) != .@"struct") continue;
        if (comptime !@hasDecl(Type, "preview_compiled")) continue;
        if (reload.ir.findDeclaration(doc, name)) |d| {
            found += 1;
            for ([_]*const theme.Values{ &theme.light, &theme.dark }) |tokens| {
                if (comptime @hasDecl(Type, "Variants")) {
                    try recipeCases(Type, d, .{}, 0, tokens, counts);
                } else if (comptime boxValid(@TypeOf(Type.spec))) {
                    const actual = reload.evaluateConditional(d.base, tokens, false) catch |err| {
                        if (err == error.UnsupportedValue and frozenDeclaration(d)) {
                            counts.frozen += 1;
                            continue;
                        }
                        std.debug.print("LP2 invalid {s}:{s}\n", .{ path, name });
                        return err;
                    };
                    try conditional(Type.preview_compiled.conditional(tokens), actual, counts);
                } else {
                    const base: core.TextStyle = .{};
                    const actual = reload.evaluateText(d.base, base, tokens) catch |err| {
                        if (err == error.UnsupportedValue and frozenDeclaration(d)) {
                            counts.frozen += 1;
                            continue;
                        }
                        return err;
                    };
                    try t.expect(eq(Type.preview_compiled.text(base, tokens), actual));
                    counts.evaluations += 1;
                }
                if (comptime !@hasDecl(Type, "Variants") and textApplicable(@TypeOf(Type.spec))) {
                    // The oracle must bypass the preview facade, even after registration.
                    if (comptime Type.preview_compiled.box_part) |Box| {
                        try conditional(Box.conditional(tokens), try reload.evaluateConditional(d.base, tokens, true), counts);
                        counts.box_projections += 1;
                    }
                    if (comptime Type.has_hover) {
                        const base: core.TextStyle = .{ .font_size = 31, .color = core.Color.hex(0x192837) };
                        var actual = base;
                        for (d.base.conditions) |c| if (reload.conditionEqual(c.name, "hover")) {
                            actual = try reload.evaluateText(c.layer.*, base, tokens);
                        };
                        try t.expect(eq(Type.preview_compiled.textHover(base, tokens), actual));
                        counts.text_hovers += 1;
                        counts.evaluations += 1;
                    }
                }
            }
        }
    }
    counts.supported += found;
    counts.frozen += doc.declarations.len - found;
}
pub fn finish(counts: Counts, files: usize) !void {
    // Printed first so a changed inventory shows every counter at once.
    std.debug.print("LP2 differential files={d}, supported={d}, frozen_checks={d}, evaluations={d}, box_projections={d}, text_hovers={d}\n", .{ counts.files, counts.supported, counts.frozen, counts.evaluations, counts.box_projections, counts.text_hovers });
    try t.expectEqual(files, counts.files);
    // Exact inventory catches silently omitted declarations and oracle paths.
    try t.expectEqual(@as(usize, 159), counts.supported);
    try t.expectEqual(@as(usize, 79), counts.frozen);
    try t.expectEqual(@as(usize, 121892), counts.evaluations);
    try t.expectEqual(@as(usize, 156), counts.box_projections);
    try t.expectEqual(@as(usize, 2), counts.text_hovers);
}

const source_a = "const ui = @import(\"ui\"); style panel { background: #112233; gap: 4; padding: 2; corner-radius: 3; } recipe Badge { base { background: #113355; padding: 2; } flag hot { gap: 6; } } style label { font-size: 14; color: #112233; }";
const source_b = "const ui = @import(\"ui\"); style panel { background: #445566; padding: 8; corner-radius: 7; } recipe Badge { base { background: #557799; padding: 5; } flag hot { gap: 9; } } style label { font-size: 20; color: #445566; }";
const Panel = css.previewCss("fixture.yss", "panel", source_a, .{ .background = core.Color.hex(0x112233), .gap = 4, .padding = 2, .corner_radius = 3 });
const Badge = css.previewCva("fixture.yss", "Badge", source_a, .{ .base = .{ .background = core.Color.hex(0x113355), .padding = 2 }, .variants = .{ .hot = .{ .true = .{ .gap = 6 }, .false = .{} } }, .defaults = .{ .hot = false } });
const Label = css.previewCss("fixture.yss", "label", source_a, .{ .font_size = 14, .color = core.Color.hex(0x112233) });
fn apply(source: []const u8, cx: *core.Cx) !void {
    const p = try reload.prepare(t.allocator, &.{.{ .path = "fixture.yss", .source = source }});
    if (p.result != .ready) {
        defer p.deinit();
        std.debug.print("LP2 preparation: {any}\n", .{p.result});
        return error.NotReady;
    }
    try cx.reserveStyleNotification();
    cx.publishStyleGeneration(p.commit());
    reload.collect();
}
fn edgeCount(cx: *core.Cx) usize {
    var count: usize = 0;
    for (cx.owner.graph.nodes.items) |node| if (node.alive) {
        count += node.sources.items.len + node.observers.items.len;
    };
    return count;
}
test "LP2 real Cx A B A deletion dynamic recipe text and subscriptions" {
    defer reload.deinit();
    const cx = try core.Cx.init(t.allocator, t.io);
    defer cx.deinit();
    const scope = try ui.Scope.init(t.allocator, null, cx.owner);
    defer scope.dispose();
    const hot = try scope.createSignal(bool, true);
    const Caption = css.cva(.{ .base = css.css(Label), .variants = .{ .hot = .{ .false = .{}, .true = .{ .font_weight = 700 } } } });
    const root = try ui.view.render(scope, cx, ui.view.col(.{ .style = Panel }, .{
        ui.view.box(.{ .style = Badge.of(.{ .hot = hot }) }, .{}),
        ui.view.text(.{ .style = Label }, "static"),
        ui.view.text(.{ .style = Caption.of(.{ .hot = hot }) }, "dynamic"),
    }));
    defer cx.freeNode(root);
    const initial = root.style.padding;
    const static_text = root.children.items[1];
    const dynamic_text = root.children.items[2];
    const initial_static = static_text.getText().?;
    const initial_dynamic = dynamic_text.getText().?;
    try t.expectEqual(@as(f32, 14), initial_static.font_size);
    try t.expectEqual(@as(u16, 700), initial_dynamic.font_weight);
    const nodes = cx.owner.graph.nodes.items.len;
    const subscriptions = edgeCount(cx);
    for (0..12) |_| {
        try apply(source_b, cx);
        try t.expectEqual(@as(f32, 8), root.style.padding.top);
        try t.expectEqual(@as(f32, 0), root.style.gap);
        try t.expectEqual(@as(f32, 9), root.children.items[0].style.gap);
        try t.expectEqual(@as(f32, 20), static_text.getText().?.font_size);
        try t.expectEqual(@as(f32, 20), dynamic_text.getText().?.font_size);
        try t.expectEqual(@as(u16, 700), dynamic_text.getText().?.font_weight);
        try apply(source_a, cx);
        try t.expect(eq(initial, root.style.padding));
        try t.expectEqual(@as(f32, 4), root.style.gap);
        try t.expectEqual(@as(f32, 6), root.children.items[0].style.gap);
        try t.expectEqualDeep(initial_static, static_text.getText().?);
        try t.expectEqualDeep(initial_dynamic, dynamic_text.getText().?);
        try t.expectEqual(nodes, cx.owner.graph.nodes.items.len);
        try t.expectEqual(subscriptions, edgeCount(cx));
        try t.expectEqual(@as(usize, 1), reload.retainedGenerationCount());
    }
}
test "LP2 literal token swaps follow application setTheme after applied" {
    defer reload.deinit();
    const cx = try core.Cx.init(t.allocator, t.io);
    defer cx.deinit();
    cx.setTheme(&theme.light);
    const scope = try ui.Scope.init(t.allocator, null, cx.owner);
    defer scope.dispose();
    const hot = try scope.createSignal(bool, true);
    const Caption = css.cva(.{ .base = css.css(Label), .variants = .{ .hot = .{ .false = .{}, .true = .{ .font_weight = 700 } } } });
    const root = try ui.view.render(scope, cx, ui.view.col(.{ .style = Panel }, .{
        ui.view.box(.{ .style = Badge.of(.{ .hot = hot }) }, .{}),
        ui.view.text(.{ .style = Label }, "static"),
        ui.view.text(.{ .style = Caption.of(.{ .hot = hot }) }, "dynamic"),
    }));
    defer cx.freeNode(root);
    const token_source = "const ui = @import(\"ui\"); style panel { background: bg-primary; gap: 4; padding: 2; corner-radius: 3; } recipe Badge { base { background: bg-primary; padding: 2; } flag hot { gap: 6; } } style label { font-size: 14; color: bg-primary; }";
    try t.expect(!core.Color.eql(theme.light.tokens.color.bg_primary, theme.dark.tokens.color.bg_primary));
    for (0..2) |_| {
        try apply(token_source, cx); // must be ready/applied, not fallback
        for ([_]*const theme.Values{ &theme.dark, &theme.light }) |tokens| {
            cx.setTheme(tokens); // application call, no generation publication
            try t.expect(core.Color.eql(tokens.tokens.color.bg_primary, root.getBackground()));
            try t.expect(core.Color.eql(tokens.tokens.color.bg_primary, root.children.items[0].getBackground()));
            try t.expect(core.Color.eql(tokens.tokens.color.bg_primary, root.children.items[1].getText().?.color));
            try t.expect(core.Color.eql(tokens.tokens.color.bg_primary, root.children.items[2].getText().?.color));
        }
        try apply(source_a, cx); // token -> literal also stays live and returns exact values
        cx.setTheme(&theme.dark);
        try t.expect(core.Color.eql(core.Color.hex(0x112233), root.getBackground()));
        try t.expect(core.Color.eql(core.Color.hex(0x113355), root.children.items[0].getBackground()));
        try t.expect(core.Color.eql(core.Color.hex(0x112233), root.children.items[1].getText().?.color));
        try t.expect(core.Color.eql(core.Color.hex(0x112233), root.children.items[2].getText().?.color));
    }
}
test "LP2 whole batch syntax shape and OOM preserve published generation" {
    defer reload.deinit();
    _ = @TypeOf(Panel).box(&theme.light);
    const before = reload.generation;
    const Other = css.previewCss("other.yss", "panel", source_a, .{ .background = core.Color.hex(0x112233), .gap = 4, .padding = 2, .corner_radius = 3 });
    _ = @TypeOf(Other).box(&theme.light);
    const invalid = try reload.prepare(t.allocator, &.{ .{ .path = "fixture.yss", .source = source_b }, .{ .path = "other.yss", .source = "style panel { padding: ; }" } });
    defer invalid.deinit();
    try t.expect(invalid.result == .diagnostic);
    try t.expectEqual(before, reload.generation);
    try t.expectEqual(@as(?f32, 4), @TypeOf(Panel).box(&theme.light).gap);

    const bad = try reload.prepare(t.allocator, &.{ .{ .path = "fixture.yss", .source = source_b }, .{ .path = "fixture.yss", .source = "style broken { padding:" } });
    defer bad.deinit();
    try t.expect(bad.result != .ready);
    try t.expectEqual(before, reload.generation);
    const shape = try reload.prepare(t.allocator, &.{.{ .path = "fixture.yss", .source = source_a ++ " style extra { :hover { background: #fff000; } }" }});
    defer shape.deinit(); // unused additions are permitted by the design
    if (shape.result != .ready) std.debug.print("unexpected new declaration: {any}\n", .{shape.result});
    try t.expect(shape.result == .ready);
    try t.expectEqual(before, reload.generation);
    var failed = std.testing.FailingAllocator.init(t.allocator, .{ .fail_index = 0 });
    try t.expectError(error.OutOfMemory, reload.prepare(failed.allocator(), &.{.{ .path = "fixture.yss", .source = source_b }}));
    try t.expectEqual(before, reload.generation);
}
test "LP2 shape needs_ext reflection stays aligned" {
    inline for (refl.fields(core.BoxStyle)) |f| {
        const layer: reload.ir.Layer = .{ .properties = &.{.{ .name = f.name, .value = .{ .number = 0 } }} };
        try t.expectEqual(core.BoxStyle.fieldNeedsExt(f.name), reload.ir.needsExt(layer));
    }
}
test "LP2 mutation oracle rejects a missing runtime property" {
    const a: core.BoxStyle = .{ .gap = 7, .padding = .all(3) };
    const b: core.BoxStyle = .{ .padding = .all(3) };
    try t.expectError(error.TestUnexpectedResult, assertDecl(a, b));
}

var manual_cx: ?*core.Cx = null;
fn observeManual() void {
    if (manual_cx) |cx| if (cx.style_signal) |sig| {
        _ = sig.get();
    };
}
test "LP2 manual resolve and style generation outlives its first subscriber" {
    defer reload.deinit();
    const cx = try core.Cx.init(t.allocator, t.io);
    defer cx.deinit();
    manual_cx = cx;
    defer manual_cx = null;
    reload.observer = observeManual;
    // A Cx service: the scope that asked first does not own it, every round reuses it.
    const generation = try cx.styleGenerationSignal();
    var round: usize = 0;
    while (round < 3) : (round += 1) {
        const scope = try ui.Scope.init(t.allocator, null, cx.owner);
        try t.expect(try cx.styleGenerationSignal() == generation);
        var state: struct {
            gap: ?f32 = null,
            fn run(self: *@This()) void {
                self.gap = @TypeOf(Panel).box(&theme.light).gap;
            }
        } = .{};
        try scope.createEffect(&state, @TypeOf(state).run);
        try apply(source_b, cx);
        try t.expect(state.gap == null);
        try apply(source_a, cx);
        try t.expectEqual(@as(?f32, 4), state.gap);
        scope.dispose();
        try t.expect(cx.style_signal == generation);
        _ = generation.get();
    }
}
test "LP2 token adapter values modes shape diagnostics and allocation failure" {
    const tokens = @import("theme_reload.zig");
    const source = @import("zenit_environment").preview.fixtures.theme_source;
    const initial = try tokens.prepare(t.allocator, source);
    defer initial.deinit();
    try t.expect(initial.result == .ready);
    for (initial.values) |value| {
        const oracle = tokens.compiledMode(value.name);
        try t.expect(eq(value.tokens, oracle.tokens));
    }
    const altered = try std.mem.replaceOwned(u8, t.allocator, source, "\"panel\": 8", "\"panel\": 11");
    defer t.allocator.free(altered);
    const updated = try tokens.prepare(t.allocator, altered);
    defer updated.deinit();
    try t.expect(updated.result == .ready);
    for (updated.values) |value| try t.expectEqual(@as(f32, 11), value.tokens.radius.panel);
    const duration_source = try std.mem.replaceOwned(u8, t.allocator, source, "\"fast\": 0.1", "\"fast\": 0.2");
    defer t.allocator.free(duration_source);
    const duration = try tokens.prepare(t.allocator, duration_source);
    defer duration.deinit();
    try t.expect(duration.result == .fallback);
    try t.expectEqualStrings("token_duration", duration.result.fallback);
    const renamed = try std.mem.replaceOwned(u8, t.allocator, source, "\"panel\": 8", "\"new_panel\": 8");
    defer t.allocator.free(renamed);
    const rejected = try tokens.prepare(t.allocator, renamed);
    defer rejected.deinit();
    try t.expect(rejected.result == .fallback);
    const bad = try tokens.prepare(t.allocator, "{ invalid");
    defer bad.deinit();
    try t.expect(bad.result == .diagnostic);
    var failed = std.testing.FailingAllocator.init(t.allocator, .{ .fail_index = 0 });
    try t.expectError(error.OutOfMemory, tokens.prepare(failed.allocator(), source));
}

fn prepareFailure(a: std.mem.Allocator) !void {
    const p = try reload.prepare(a, &.{.{ .path = "fixture.yss", .source = source_b }});
    defer p.deinit();
    try t.expect(p.result == .ready);
}
test "LP2 partial allocation failures preserve every published value" {
    defer reload.deinit();
    const before = @TypeOf(Panel).box(&theme.light);
    try t.checkAllAllocationFailures(t.allocator, prepareFailure, .{});
    try t.expectEqual(@as(u64, 0), reload.generation);
    try t.expect(eq(before, @TypeOf(Panel).box(&theme.light)));
}
test "LP2 duplicate border shorthand and capability change oracle" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const doc = try parsed(arena.allocator(), "style box { border: 1 #112233; border: 3; }");
    const actual = try reload.evaluateBox(doc.declarations[0].base, &theme.light, false);
    const oracle = css.css(.{ .border_width = 3, .border_color = core.Color.hex(0x112233) });
    try assertDecl(@TypeOf(oracle).box(&theme.light), actual);
    const old = try parsed(arena.allocator(), "style box { padding: 2; font-size: 14; }");
    const new = try parsed(arena.allocator(), "style box { padding: 2; font-size: 14; max-lines: 2; }");
    try t.expectEqual(reload.ir.Reason.box_text, reload.ir.compatibility(old, new).?);
}

test "LP2 exact token spelling and hyphen ambiguity" {
    const Names = enum { @"a-b", a_b, only_under };
    try t.expectEqual(Names.a_b, try reload.tokenName(Names, "a_b"));
    try t.expectEqual(Names.only_under, try reload.tokenName(Names, "only-under"));
    try t.expectError(error.InvalidValue, reload.tokenName(Names, "a-b"));
}
test "LP2 shape lock all signatures transitions dependencies and thunks" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { before: []const u8, after: []const u8, reason: reload.ir.Reason }{
        .{ .before = "style x { gap: 1; }", .after = "", .reason = .names },
        .{ .before = "recipe R { variant size = sm { sm {} md {} } }", .after = "recipe R { variant size = sm { sm {} md {} lg {} } }", .reason = .variant },
        .{ .before = "recipe R { variant size = sm { sm {} md {} } }", .after = "recipe R { variant size = md { sm {} md {} } }", .reason = .default },
        .{ .before = "recipe R { flag hot; }", .after = "recipe R { flag hot = true; }", .reason = .default },
        .{ .before = "style x { gap: 1; }", .after = "style x { gap: 1; :hover { gap: 2; } }", .reason = .conditions },
        .{ .before = "style x { gap: 1; }", .after = "style x { gap: 1; corner-radius: 2; }", .reason = .needs_ext },
        .{ .before = "style x { corner-radius: 2; transition: background 100ms; }", .after = "style x { corner-radius: 2; transition: background 200ms; }", .reason = .transition },
        .{ .before = "style x { padding: 2; corner-radius: 2; }", .after = "style x { padding: 2; corner-radius: 2; icon-color: accent; }", .reason = .icon },
        .{ .before = "recipe R { flag hot; when hot { gap: 2; } }", .after = "recipe R { flag hot; when !hot { gap: 2; } }", .reason = .compound },
        .{ .before = "const helper = 1; style x { gap: 2; }", .after = "const helper = 2; style x { gap: 2; }", .reason = .dependency },
        .{ .before = "style x { gap: {1}; }", .after = "style x { gap: {2}; }", .reason = .thunk },
        .{ .before = "style x($gap: f32) { gap: $gap; }", .after = "style x($gap: f32 = 2) { gap: $gap; }", .reason = .param },
        .{ .before = "recipe R slots(root) { base { root { gap: 2; } } }", .after = "recipe R slots(root, label) { base { root { gap: 2; } } }", .reason = .slot },
    };
    for (cases) |case| {
        const before = try parsed(a, case.before);
        const after = try parsed(a, case.after);
        try t.expectEqual(case.reason, reload.ir.compatibility(before, after).?);
    }
}

test "LP2 staged inline allocation stays independent of generation buffers" {
    defer reload.deinit();
    const cx = try core.Cx.init(t.allocator, t.io);
    defer cx.deinit();
    const scope = try ui.Scope.init(t.allocator, null, cx.owner);
    defer scope.dispose();
    const hot = try scope.createSignal(bool, true);
    const root = try ui.view.render(scope, cx, ui.view.box(.{ .style = Badge.of(.{ .hot = hot }) }, .{}));
    defer cx.freeNode(root);
    try t.expectEqual(@as(f32, 6), root.style.gap);
    var staged = try root.stageStyleInline(t.allocator, .{ .padding = core.Padding.all(8) });
    var stage_pending = true;
    defer if (stage_pending) staged.abort(); // preserve the triggering assertion on failure
    hot.set(false);
    try t.expectEqual(@as(f32, 0), root.style.gap);
    staged.commit();
    stage_pending = false;
    try t.expectEqual(@as(f32, 0), root.style.gap);
    try t.expectEqual(@as(f32, 8), root.style.padding.top);
}
var replay_cx: ?*core.Cx = null;
fn unmountInTheme(_: *core.Node, _: *const theme.Values, _: std.mem.Allocator) void {
    replay_cx.?.unmount();
}
test "LP2 theme callback unmount defers node and scope destruction" {
    const cx = try core.Cx.init(t.allocator, t.io);
    defer cx.deinit();
    const scope = try ui.Scope.init(t.allocator, null, cx.owner);
    cx.root_scope = scope;
    try cx.prepareStyleGeneration();
    cx.root = try ui.view.render(scope, cx, ui.view.box(.{}, .{ui.view.box(.{}, .{})}));
    cx.root.?.meta.per_frame.hooks.on_theme = unmountInTheme;
    replay_cx = cx;
    defer replay_cx = null;
    cx.setTheme(&theme.light);
    try t.expect(cx.root == null and cx.root_scope == null);
    // The generation signal is a Cx service: unmounting the window leaves it live.
    const generation = cx.style_signal.?;
    try t.expect(try cx.styleGenerationSignal() == generation);
    _ = generation.get();
}

test "LP2 malformed numeric syntax returns a located diagnostic" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const result = try compiler.compileIR(arena.allocator(), "style box { gap: 1.2.3; }");
    try t.expect(result == .diagnostic);
    try t.expect(result.diagnostic.offset > 0);
}
fn signalInitializationFailure(a: std.mem.Allocator) !void {
    const cx = try core.Cx.init(a, t.io);
    defer cx.deinit();
    const sig = try cx.styleGenerationSignal();
    try t.expect(cx.style_signal == sig);
}
test "LP2 lazy generation partial initialization OOM has no orphan signal" {
    try t.checkAllAllocationFailures(t.allocator, signalInitializationFailure, .{});
}

var theme_reentry_target: ?*const theme.Values = null;
var theme_reentry_child_value: ?*const theme.Values = null;
var theme_reentry_child_calls: usize = 0;
fn reenterThemeOnce(_: *core.Node, _: *const theme.Values, _: std.mem.Allocator) void {
    if (theme_reentry_target) |target| {
        theme_reentry_target = null;
        replay_cx.?.setTheme(target);
    }
}
fn recordReentrantChildTheme(node: *core.Node, value: *const theme.Values, _: std.mem.Allocator) void {
    theme_reentry_child_value = value;
    theme_reentry_child_calls += 1;
    node.setBackgroundRaw(value.tokens.color.bg_primary);
}
fn themeReentryTree(cx: *core.Cx) !*core.Node {
    cx.root = try ui.box(cx, .{}, .{});
    const child = try ui.box(cx, .{}, .{});
    errdefer cx.freeNode(child);
    try cx.root.?.appendChild(t.allocator, child);
    child.meta.per_frame.hooks.on_theme = recordReentrantChildTheme;
    theme_reentry_child_value = null;
    theme_reentry_child_calls = 0;
    return child;
}
test "LP2 reentrant theme hook supersedes the remaining outer replay" {
    const cx = try core.Cx.init(t.allocator, t.io);
    defer cx.deinit();
    const child = try themeReentryTree(cx);
    cx.root.?.meta.per_frame.hooks.on_theme = reenterThemeOnce;
    replay_cx = cx;
    theme_reentry_target = &theme.dark;
    defer {
        replay_cx = null;
        theme_reentry_target = null;
        theme_reentry_child_value = null;
    }
    cx.setTheme(&theme.light);
    try t.expect(cx.tokens == &theme.dark);
    try t.expect(theme_reentry_child_value == cx.tokens);
    try t.expectEqual(@as(usize, 1), theme_reentry_child_calls);
    try t.expect(core.Color.eql(cx.tokens.tokens.color.bg_primary, child.getBackground()));
}
test "LP2 theme signal reentry supersedes replay before the first root hook" {
    const cx = try core.Cx.init(t.allocator, t.io);
    defer cx.deinit();
    const scope = try ui.Scope.init(t.allocator, null, cx.owner);
    cx.root_scope = scope;
    const child = try themeReentryTree(cx);
    const signal = try cx.themeSignal();
    var reader: struct {
        cx: *core.Cx,
        signal: *ui.Signal(*const theme.Values),
        armed: bool = false,
        fn run(self: *@This()) void {
            const value = self.signal.get();
            if (self.armed and value == &theme.light) {
                self.armed = false;
                self.cx.setTheme(&theme.dark);
            }
        }
    } = .{ .cx = cx, .signal = signal };
    try scope.createEffect(&reader, @TypeOf(reader).run);
    reader.armed = true;
    defer theme_reentry_child_value = null;
    cx.setTheme(&theme.light);
    try t.expect(cx.tokens == &theme.dark);
    try t.expect(signal.peek() == cx.tokens);
    try t.expect(theme_reentry_child_value == cx.tokens);
    try t.expectEqual(@as(usize, 1), theme_reentry_child_calls);
    try t.expect(core.Color.eql(cx.tokens.tokens.color.bg_primary, child.getBackground()));
}
test "LP2 borrowed token pointers survive later commits and collection" {
    const tokens = @import("theme_reload.zig");
    defer tokens.deinit();
    const cx = try core.Cx.init(t.allocator, t.io);
    defer cx.deinit();
    const source = @import("zenit_environment").preview.fixtures.theme_source;
    const first = try tokens.prepare(t.allocator, source);
    defer if (!first.committed) first.deinit();
    try t.expect(first.result == .ready);
    try t.expectEqual(@as(usize, 0), tokens.retainedVersionCount());
    try t.expectEqual(@as(usize, 0), tokens.retainedBytes());
    first.commit();
    const first_bytes = @sizeOf(tokens.Version) + first.document.arena.queryCapacity();
    try t.expectEqual(@as(usize, 1), tokens.retainedVersionCount());
    try t.expectEqual(first_bytes, tokens.retainedBytes());
    const borrowed = &first.values[0];
    const original = borrowed.tokens;
    cx.setTheme(borrowed);
    const altered = try std.mem.replaceOwned(u8, t.allocator, source, "\"panel\": 8", "\"panel\": 11");
    defer t.allocator.free(altered);
    const second = try tokens.prepare(t.allocator, altered);
    defer if (!second.committed) second.deinit();
    try t.expect(second.result == .ready);
    second.commit();
    cx.setTheme(&second.values[0]);
    tokens.collect();
    try t.expectEqual(@as(usize, 2), tokens.retainedVersionCount());
    try t.expectEqual(first_bytes + @sizeOf(tokens.Version) + second.document.arena.queryCapacity(), tokens.retainedBytes());
    std.debug.print("LP2 token retention versions={d}, bytes={d}, first_bytes={d}\n", .{ tokens.retainedVersionCount(), tokens.retainedBytes(), first_bytes });
    try t.expect(eq(original, borrowed.tokens));
    // A previously supplied theme pointer remains a valid setTheme argument.
    cx.setTheme(borrowed);
    try t.expect(cx.tokens == borrowed);
    try t.expectEqual(@as(f32, 8), cx.tokens.tokens.radius.panel);
    try t.expectEqual(@as(f32, 11), second.values[0].tokens.radius.panel);
}
test "LP2 retained token versions survive reentry and window recreation" {
    const tokens = @import("theme_reload.zig");
    defer tokens.deinit();
    const first = try tokens.prepare(t.allocator, @import("zenit_environment").preview.fixtures.theme_source);
    first.commit();
    const borrowed = &first.values[0];
    const second_window = try core.Cx.init(t.allocator, t.io);
    defer second_window.deinit();
    second_window.setTheme(borrowed);
    {
        const cx = try core.Cx.init(t.allocator, t.io);
        defer cx.deinit();
        const scope = try ui.Scope.init(t.allocator, null, cx.owner);
        defer scope.dispose();
        const signal = try cx.themeSignal();
        var st: struct {
            signal: *@TypeOf(signal.*),
            cx: *core.Cx,
            other: *core.Cx,
            borrowed: *const theme.Values,
            armed: bool = false,
            fn run(self: *@This()) void {
                _ = self.signal.get();
                if (!self.armed) return;
                self.armed = false;
                tokens.collect();
                self.other.setTheme(self.borrowed);
                self.cx.setTheme(self.borrowed); // reenter while newer pointer is on callback stack
            }
        } = .{ .signal = signal, .cx = cx, .other = second_window, .borrowed = borrowed };
        try scope.createEffect(&st, @TypeOf(st).run);
        for (0..10) |_| {
            const next = try tokens.prepare(t.allocator, @import("zenit_environment").preview.fixtures.theme_source);
            next.commit();
            st.armed = true;
            cx.setTheme(&next.values[0]);
            try t.expect(cx.tokens == borrowed);
            try t.expect(second_window.tokens == borrowed);
        }
    } // close the publishing owner, then create a new window using the old borrow
    tokens.collect();
    const recreated = try core.Cx.init(t.allocator, t.io);
    defer recreated.deinit();
    recreated.setTheme(borrowed);
    try t.expectEqual(@as(usize, 11), tokens.retainedVersionCount());
    try t.expectEqual(@as(f32, 8), recreated.tokens.tokens.radius.panel);
}
test "LP2 preview CSS remains live inside recipe base variant compound and slot layers" {
    defer reload.deinit();
    const cx = try core.Cx.init(t.allocator, t.io);
    defer cx.deinit();
    _ = @TypeOf(Panel).box(&theme.light);
    const Base = css.cva(.{ .base = Panel });
    const Variant = css.cva(.{ .variants = .{ .panel = .{ .false = .{}, .true = Panel } } });
    const Compound = css.cva(.{
        .variants = .{ .panel = .{ .false = .{}, .true = .{} } },
        .compound = .{.{ .when = .{ .panel = true }, .style = Panel }},
    });
    const Slots = css.sva(.{ .slots = .{ .root, .label }, .base = .{ .root = Panel } });
    for (0..3) |_| {
        try apply(source_b, cx);
        const next = [_]core.BoxStyle{
            Base.resolve(.{}, &theme.light).base,
            Variant.resolve(.{ .panel = true }, &theme.light).base,
            Compound.resolve(.{ .panel = true }, &theme.light).base,
            Slots.resolve(.{}, &theme.light).root.base,
        };
        for (next) |value| {
            try t.expect(value.gap == null);
            try t.expectEqual(@as(f32, 8), value.padding.?.top);
        }
        try apply(source_a, cx);
        const restored = [_]core.BoxStyle{
            Base.resolve(.{}, &theme.light).base,
            Variant.resolve(.{ .panel = true }, &theme.light).base,
            Compound.resolve(.{ .panel = true }, &theme.light).base,
            Slots.resolve(.{}, &theme.light).root.base,
        };
        for (restored) |value| {
            try t.expectEqual(@as(?f32, 4), value.gap);
            try t.expectEqual(@as(f32, 2), value.padding.?.top);
        }
    }
}

test "LP2 flex basis keywords and numeric pixels share the compiled contract" {
    const cases = .{
        .{ "auto", core.FlexBasis.auto },
        .{ "content", core.FlexBasis.content },
        .{ "0", @as(f32, 0) },
        .{ "31", @as(f32, 31) },
    };
    inline for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(t.allocator);
        defer arena.deinit();
        const doc = try parsed(arena.allocator(), "style x { flex-basis: " ++ case[0] ++ "; }");
        const value = try reload.evaluateBox(doc.declarations[0].base, &theme.light, false);
        try t.expectEqual(@as(?f32, case[1]), value.flex_basis);
    }
    // The compiler rejects these spellings before evaluation. Also exercise
    // the evaluator boundary directly with malformed IR.
    for ([_]reload.ir.Value{ .{ .name = "grow" }, .{ .number = -1 }, .{ .number = -2 } }) |invalid| {
        const props = [_]reload.ir.Property{.{ .name = "flex_basis", .value = invalid }};
        try t.expectError(error.InvalidValue, reload.evaluateBox(.{ .properties = &props }, &theme.light, false));
    }
}

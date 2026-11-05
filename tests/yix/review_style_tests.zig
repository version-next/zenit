const std = @import("std");
const compiler = @import("yix_compiler");

fn output(source: []const u8) ![]const u8 {
    const result = try compiler.style.compile(std.testing.allocator, source);
    if (result == .diagnostic) {
        defer std.testing.allocator.free(result.diagnostic.message);
        std.debug.print("unexpected YSS diagnostic: {s}\n", .{result.diagnostic.message});
        return error.TestUnexpectedResult;
    }
    return result.output;
}

test "YSS shadow last declaration wins across single and multiple layers" {
    const result = try output("style s { shadow: md, lg; shadow: sm; }");
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"md\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"lg\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"sm\"") != null);
    const reverse = try output("style s { shadow: sm; shadow: md, lg; }");
    defer std.testing.allocator.free(reverse);
    try std.testing.expect(std.mem.indexOf(u8, reverse, "\"sm\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, reverse, "\"md\"") != null);
}

test "YSS mixin and condition shadow declarations obey write order" {
    const result = try output("mixin elevated() { shadow: md, lg; } style s { elevated(); shadow: sm; :hover { shadow: lg, md; shadow: sm; } }");
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"md\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"lg\"") == null);
}

test "YSS Zig aliases remain valid for bool conditions and optional fallback" {
    const result = try output("const Flag = bool; const Width = ?f32; style s($enabled: Flag, $width: Width) { width: $width ?? fit; when $enabled { gap: 1; } }");
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "if (args.enabled)") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "ui.orElse(args.width, .fit)") != null);
}

fn compoundSource(dimensions: usize) ![]const u8 {
    var source: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer source.deinit();
    const w = &source.writer;
    try w.writeAll("recipe S {");
    for (0..dimensions) |i| try w.print("variant v{d} = a {{ a {{}} b {{}} c {{}} d {{}} }}", .{i});
    try w.writeAll("when ");
    for (0..dimensions) |i| try w.print("{s}v{d} in (a,b,c,d)", .{ if (i == 0) "" else " & ", i });
    try w.writeAll(" { gap: 8; } }");
    return source.toOwnedSlice();
}

test "YSS compound expansion reports excessive Cartesian products before generation" {
    const source = try compoundSource(7);
    defer std.testing.allocator.free(source);
    const result = try compiler.style.compile(std.testing.allocator, source);
    defer switch (result) {
        .output => |out| std.testing.allocator.free(out),
        .diagnostic => |d| std.testing.allocator.free(d.message),
    };
    try std.testing.expect(result == .diagnostic);
    try std.testing.expect(std.mem.indexOf(u8, result.diagnostic.message, "4096") != null);
}

test "YSS compound expansion accepts the resource limit" {
    const source = try compoundSource(6);
    defer std.testing.allocator.free(source);
    const result = try output(source);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqual(@as(usize, 4096), std.mem.count(u8, result, ".when ="));
}

test "YSS compound expansion limit applies cumulatively per recipe" {
    const first = try compoundSource(6);
    defer std.testing.allocator.free(first);
    const source = try std.fmt.allocPrint(std.testing.allocator, "{s} when v0 = a {{ gap: 9; }} }}", .{first[0 .. first.len - 1]});
    defer std.testing.allocator.free(source);
    const result = try compiler.style.compile(std.testing.allocator, source);
    defer switch (result) {
        .output => |out| std.testing.allocator.free(out),
        .diagnostic => |d| std.testing.allocator.free(d.message),
    };
    try std.testing.expect(result == .diagnostic);
    try std.testing.expect(std.mem.indexOf(u8, result.diagnostic.message, "4096") != null);
}

test "YSS flex basis keywords retain numeric zero and diagnose unknown names" {
    const text = try output("style a { flex-basis: auto; } style b { flex-basis: content; } style c { flex-basis: 0; } style d { align-content: space-around; align-self: first-baseline; }");
    defer std.testing.allocator.free(text);
    for ([_][]const u8{ "ui.FlexBasis.auto", "ui.FlexBasis.content", ".flex_basis = 0", ".align_content = .space_around", ".align_self = .first_baseline" }) |fragment| try std.testing.expect(std.mem.indexOf(u8, text, fragment) != null);
    const bad = try compiler.style.compile(std.testing.allocator, "style a { flex-basis: bogus; }");
    try std.testing.expect(bad == .diagnostic);
    defer std.testing.allocator.free(bad.diagnostic.message);
    try std.testing.expect(std.mem.indexOf(u8, bad.diagnostic.message, "auto, content") != null);
}

test "YSS negative flex basis diagnoses literals and fallbacks in compiler and IR" {
    for ([_][]const u8{
        "style a { flex-basis: -3; }",
        "style a { flex-basis: -0.5; }",
        "style a($basis: ?f32) { flex-basis: $basis ?? -3; }",
    }) |source| {
        const result = try compiler.style.compile(std.testing.allocator, source);
        try std.testing.expect(result == .diagnostic);
        defer std.testing.allocator.free(result.diagnostic.message);
        try std.testing.expect(std.mem.indexOf(u8, result.diagnostic.message, "flex-basis must be nonnegative") != null);
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const ir_result = try compiler.style.compileIR(arena.allocator(), source);
        try std.testing.expect(ir_result == .diagnostic);
        try std.testing.expect(std.mem.indexOf(u8, ir_result.diagnostic.message, "flex-basis must be nonnegative") != null);
    }
    const text = try output("style a { flex-basis: -1; } style b { flex-basis: -2; } style c { flex-basis: 12.5; }");
    defer std.testing.allocator.free(text);
    for ([_][]const u8{ ".flex_basis = -1", ".flex_basis = -2", ".flex_basis = 12.5" }) |fragment|
        try std.testing.expect(std.mem.indexOf(u8, text, fragment) != null);
}

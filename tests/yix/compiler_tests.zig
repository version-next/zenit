const std = @import("std");
const compiler = @import("yix_compiler");

comptime {
    _ = @import("review_style_tests.zig");
}

test "Yix golden: story output is stable and parses as Zig" {
    const r = try compiler.compileSource(std.testing.allocator, "tests/yix/stories.yix", @embedFile("stories.yix"));
    try std.testing.expect(r == .output);
    defer std.testing.allocator.free(r.output);
    // golden is checked-in twin (check-yix compares it too): any output change, this and check-yix
    // fail together
    const twin = try compiler.twinText(std.testing.allocator, "stories.yix", r.output);
    defer std.testing.allocator.free(twin);
    try std.testing.expectEqualStrings(@embedFile("_stories.yix.zig"), twin);
    const z = try std.testing.allocator.dupeSentinel(u8, r.output, 0);
    defer std.testing.allocator.free(z);
    var ast = try std.zig.Ast.parse(std.testing.allocator, z, .{});
    defer ast.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), ast.errors.len);
}

test "Yix diagnostics: unsupported features and malformed syntax fail explicitly" {
    const cases = .{
        .{ "pub fn C() View { var n = signal(0); return <text>{n}</text>; }", "signal declarations require an explicit" },
        .{ "fn parts(x: i32) i32 { return x; }\npub fn C() View { return <box/>; }", "`parts` is a Yix builtin" },
        .{ "const signal = @import(\"s.zig\");\npub fn C() View { return <box/>; }", "`signal` is a Yix builtin" },
        .{ "pub fn C() View { const n: i32 = signal(0); return <text>{n}</text>; }", "signal declarations must use var" },
        .{ "pub fn C() View { var n: i32 = computed(0); return <text>{n}</text>; }", "computed declarations must use const" },
        .{ "pub fn C() View { var n: i32 = signal(0); const d = n * 2; return <text>{d}</text>; }", "reactive reads in component locals" },
        .{ "pub fn C(n: i32) View { return <Button onClick={n = 1} />; }", "read-only prop" },
        .{ "pub fn C() View { var b: bool = signal(true); return <col>{if (b) <text>a</text> else |e| <text>b</text>}</col>; }", "else |err| needs if (x) |v| on an error union" },
        .{ "pub fn C() View { var t: Tab = signal(.home); return <col>{switch (t) { .home => <text>h</text>, else => |p| <text>x</text> }}</col>; }", "the else branch of a switch has no payload to capture" },
        .{ "pub fn C(comptime x: bool) View { return <text>{x}</text>; }", "comptime component parameters" },
        .{ "pub fn C(x: ?Model(i32)) View { return <text>{x}</text>; }", "Model parameter cannot be optional" },
        .{ "pub fn C(body: View = 1) View { return <col>{body}</col>; }", "a View parameter (slot) takes no default" },
        .{ "pub fn C() View { return <box title={<text>x</text>} />; }", "element values only go on component attributes (named slots)" },
        .{ "pub fn C() View { return <Card header={<text>x</text><text>y</text>} />; }", "must be a single element" },
        .{ "pub fn C(onSave: ui.Handler(void)) View { return <col></col>; }", "write the built-in parameter type as `Handler(void)`" },
        .{ "pub fn C(x: ?ui.Model(i32)) View { return <col></col>; }", "write the built-in parameter type as `?Model(i32)`" },
        .{ "pub fn C(icon_only: bool = false) View { return <col></col>; }", "write `iconOnly` instead of `icon_only` (the Zig field is still `icon_only`)" },
        .{ "pub fn C(userID: i32 = 0) View { return <col></col>; }", "write `userId` instead of `userID`" },
        .{ "pub fn C() View { return <box test_id=\"x\" />; }", "attribute names are camelCase: write `testId`" },
        .{ "pub fn C() View { var a: i32 = signal(0); return <Button onClick={a = 1; a = 2} />; }", "several event statements go in a block" },
        .{ "pub fn C() View { var a: i32 = signal(0); return <Button onClick={{ if (a == 0) a = 1; else a = 2; }} />; }", "`; else` is not valid Zig" },
        .{ "pub fn C() View { var a: i32 = signal(0); return <Button onClick={if (a == 0) { a = 1; }; else a = 2} />; }", "`; else` is not valid Zig" },
        .{ "pub fn C() View { const s = scope.owner; return <col></col>; }", "`scope` is not available in a Yix component" },
        .{ "pub fn C() View { return <text style={cx.theme}>x</text>; }", "`cx` is not available in a Yix component" },
        .{ "pub fn C(a: ?Text = null) View { return <text>{a}</text>; }", "a Text parameter cannot be optional" },
        .{ "pub fn C(a: Text = \"\", b: Text = \"\") View { return <text>{a}{b}</text>; }", "only one parameter can be Text" },
        .{ "pub fn C() View { var rows: []const Item = signal(&items); return <col>{for (rows) |item| <text key={scope}>x</text>}</col>; }", "`scope` is not available in a Yix component" },
        .{ "pub fn C() View { return <canvas draw={cx.draw} />; }", "`cx` is not available in a Yix component" },
        .{ "pub fn C() View { var scope: i32 = signal(0); return <text>{scope}</text>; }", "`scope` is reserved in a Yix component" },
        .{ "pub fn C(cx: i32 = 0) View { return <text>{cx}</text>; }", "`cx` is reserved in a Yix component" },
        .{ "pub fn C() View { return <col>{for (1..4) |i| <text>{i}</text>}</col>; }", "ranges start at 0" },
        .{ "pub fn C() View { var on: bool = signal(true); var xs: []const Item = signal(&items); return <col>{if (on) for (xs) |x| <text>{x.title}</text> else <text>none</text>}</col>; }", "ambiguous else" },
        .{ "pub fn C() View { var on: bool = signal(true); return <col>{if (on) for (0..3) |i| <text>{i}</text> else <text>none</text>}</col>; }", "takes no else branch" },
        .{ "pub fn C(onPick: ?Handler(i32) = null) View { return <Button onClick={onPick(1, 2)} />; }", "at most one value" },
        .{ "pub fn C(onPick: ?Handler(i32) = null) View { return <Button onClick={onPick(f(1)} />; }", "unbalanced" },
        .{ "pub fn C(onPick: ?Handler(i32) = null) View { return <Button onClick={onPick(1)(2)} />; }", "whole statement" },
        .{ "pub fn C() View { var n: i32 = signal(0); return <Button onClick={if (n > 0) { else }} />; }", "else without a matching if" },
        .{ "pub fn C() View { var n: i32 = signal(0); return <Button onClick={if (n > 0) ; n = 1} />; }", "if needs a statement" },
        .{ "pub fn C() View { var n: i32 = signal(0); return <Button onClick={n = foo(1} />; }", "unbalanced" },
        .{ "pub fn C() View { var n: i32 = signal(0); return <Button onClick={n = if (n > 0) 1} />; }", "needs an else" },
        .{ "pub fn C() View { var n: i32 = signal(0); return <Button onClick={if (n > 0) {{ n = 1; n += 2; }}} />; }", "a block inside an event statement is written `{ a; b; }`" },
        .{ "pub fn C() View { var d: bool = signal(false); return <Button>{if (d) \"a\" else \"b\"}</Button>; }", "not a value; put a value in an attribute" },
        .{ "pub fn C() View { return <col key={1}></col>; }", "only goes on the root element of a {for} row" },
        .{ "pub fn C() View { var rows: []const Item = signal(&items); var n: i32 = signal(0); return <col>{for (rows) |item| <text key={n}>x</text>}</col>; }", "may only use the loop variable" },
        .{ "pub fn C(children: View) View { return <col><text>x</text></col>; }", "has no {children}" },
        .{ "pub fn C(header: View) View { return <col><text>x</text></col>; }", "component declares header: View but the template has no {header}" },
        .{ "pub fn C(children: View) View { return <col>{children}{children}</col>; }", "{children} appears more than once" },
        .{ "pub fn C(header: View, header: View) View { return <col>{header}</col>; }", "slot `header` is declared twice" },
        .{ "pub fn C(children: View) View { return <text>{children}</text>; }", "must be inside box, row, col or grid" },
        .{ "pub fn C(children: View) View { var b: bool = signal(true); return <col>{if (b) <col>{children}</col>}</col>; }", "cannot be inside control flow" },
        .{ "pub fn C(icon: ?View) View { return <row>{icon}</row>; }", "{icon} is an optional slot (?View); place it inside {if (icon)" },
        .{ "pub fn C(icon: ?View) View { return <row>{if (icon) <box><text>x</text></box>}</row>; }", "{if (icon) …} must contain {icon}" },
        .{ "pub fn C(icon: ?View) View { return <row>{if (icon) <box>{icon}</box> else <box></box>}</row>; }", "takes no else" },
        .{ "pub fn C(icon: ?View) View { var b: bool = signal(true); return <row>{if (b) <box>{if (icon) <box>{icon}</box>}</box>}</row>; }", "{icon} (a slot) cannot be inside control flow" },
        .{ "pub fn C(children: ?View) View { return <row>{children}</row>; }", "children cannot be optional" },
        .{ "pub fn C(icon: ?View) View { return <row><text>x</text></row>; }", "component declares icon: ?View but the template has no {icon}" },
        .{ "pub fn C() View { return <box onClick={|x| foo(x)} />; }", "this host event carries no value" },
        .{ "pub fn C() View { var x: i32 = signal(0); const y = computed(blk: { const x = 1; break :blk x; }); return <text>{y}</text>; }", "expression-local bindings" },
        .{ "pub fn C() View { var x: i32 = signal(0); const y = computed(f(x) catch |e| g(e)); return <text>{y}</text>; }", "expression-local bindings" },
        .{ "pub fn C() View { var t: Tab = signal(.a); const y = computed(switch (t) { .a => |v| v, else => 0 }); return <text>{y}</text>; }", "expression-local bindings" },
        .{ "pub fn C() View { return <Button onClick={{ var x = 1; save(x); }} />; }", "simple signal assignments, const locals, try" },
        .{ "pub fn C() View { var n: i32 = signal(0); return <Button onClick={{ const n = 2; save(n); }} />; }", "shadowed local names" },
        .{ "pub fn C() View { var n: i32 = signal(0); effect(|v| n = v); return <text>{n}</text>; }", "take no |value| capture" },
        .{ "pub fn C() View { var r = ref(); return <col ref={r}></col>; }", "ref declarations must use const" },
        .{ "pub fn C() View { var n: i32 = signal(0); effect(n = n + 1); return <text>{n}</text>; }", "the effect writes `n` and also reads it" },
        .{ "pub fn C() View { var n: i32 = signal(0); var m: i32 = signal(0); effect({ m = n; n = m * 2; }); return <text>{n}</text>; }", "the effect writes" },
        .{ "pub fn C() View { return <text>{x]}</text>; }", "unbalanced interpolation" },
        .{ "pub fn C() View { return <input />; }", "unknown host tag" },
        .{ "pub fn C() View { return <text", "unexpected token" },
    };
    inline for (cases) |c| {
        const r = try compiler.compile(std.testing.allocator, c[0]);
        defer r.deinit(std.testing.allocator);
        try std.testing.expect(r == .diagnostic);
        try std.testing.expect(std.mem.indexOf(u8, r.diagnostic.message, c[1]) != null);
        try std.testing.expect(r.diagnostic.offset <= c[0].len);
    }
}

test "Yix copies a Zig-only file verbatim without injecting runtime helpers" {
    const s = "const std = @import(\"std\"); fn less(a: u32, b: u32) bool { return a < b; }\n";
    const r = try compiler.compile(std.testing.allocator, s);
    try std.testing.expect(r == .output);
    defer std.testing.allocator.free(r.output);
    try std.testing.expectEqualStrings(s, r.output);
}

fn allocationProbe(a: std.mem.Allocator) !void {
    const r = try compiler.compile(a, @embedFile("stories.yix"));
    try std.testing.expect(r == .output);
    defer a.free(r.output);
    const bad = try compiler.compile(a, "pub fn C() View { return <text><text>broken</col>; }");
    defer bad.deinit(a);
    try std.testing.expect(bad == .diagnostic);
}

test "Yix compiler releases all allocations on success syntax failure and OOM" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationProbe, .{});
}

test "Yix diagnostics point to mismatched closing tag and invalid attribute" {
    const a = try compiler.compile(std.testing.allocator, "const ui = @import(\"ui\"); pub fn C() View { return <col><text>ok</col>; }");
    defer a.deinit(std.testing.allocator);
    try std.testing.expect(a == .diagnostic);
    try std.testing.expectEqualStrings("closing tag does not match opening tag", a.diagnostic.message);
    const b = try compiler.compile(std.testing.allocator, "pub fn C() View { return <text style=3 />; }");
    defer b.deinit(std.testing.allocator);
    try std.testing.expect(b == .diagnostic);
    try std.testing.expectEqualStrings("attribute values require braces, except strings", b.diagnostic.message);
}

test "Yix preserves ordinary Zig strings comments and comparisons" {
    const source = "const ui = @import(\"ui\");\n// <col>\nconst s = \"<text>{x}</text>\";\nfn less(a: i32, b: i32) bool { return a < b; }\npub fn C() View { return <text>Hello</text>; }\n";
    const r = try compiler.compile(std.testing.allocator, source);
    try std.testing.expect(r == .output);
    defer std.testing.allocator.free(r.output);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "return a < b;") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "// <col>") != null);
    const z = try std.testing.allocator.dupeSentinel(u8, r.output, 0);
    defer std.testing.allocator.free(z);
    var ast = try std.zig.Ast.parse(std.testing.allocator, z, .{});
    defer ast.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), ast.errors.len);
}

test "Yix icon host tag passes src positionally and keeps other attributes as props" {
    const r = try compiler.compile(std.testing.allocator, "pub fn C() View { return <icon style={S.icon} tint={S.tint} testId=\"i\" src={ui.icons.chevron_down} />; }");
    try std.testing.expect(r == .output);
    defer std.testing.allocator.free(r.output);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "ui.view.icon(.{ .style = S.icon, .tint = S.tint, .test_id = \"i\", }, ui.icons.chevron_down)") != null);
    const missing = try compiler.compile(std.testing.allocator, "pub fn C() View { return <icon style={S.icon} />; }");
    defer missing.deinit(std.testing.allocator);
    try std.testing.expect(missing == .diagnostic);
    try std.testing.expectEqualStrings("icon / image require src={asset or texture id}", missing.diagnostic.message);
    const children = try compiler.compile(std.testing.allocator, "pub fn C() View { return <icon src={a}><text>x</text></icon>; }");
    defer children.deinit(std.testing.allocator);
    try std.testing.expect(children == .diagnostic);
    try std.testing.expectEqualStrings("icon / image take no children", children.diagnostic.message);
    const twice = try compiler.compile(std.testing.allocator, "pub fn C() View { return <icon src={a} src={b} />; }");
    defer twice.deinit(std.testing.allocator);
    try std.testing.expect(twice == .diagnostic);
    try std.testing.expectEqualStrings("src is given more than once", twice.diagnostic.message);
    // resource can be prop (source): passed to view as-is, take value at mount
    const from_prop = try compiler.compile(std.testing.allocator, "pub fn C(asset: ?ui.SvgAsset = null, tex: u32 = 0) View { return <row><icon src={asset} /><image src={tex} /></row>; }");
    try std.testing.expect(from_prop == .output);
    defer std.testing.allocator.free(from_prop.output);
    try std.testing.expect(std.mem.indexOf(u8, from_prop.output, "ui.view.icon(.{ }, __yix_view_ctx.asset)") != null);
    try std.testing.expect(std.mem.indexOf(u8, from_prop.output, "ui.view.image(.{ }, __yix_view_ctx.tex)") != null);
}

fn srcToGen(segments: []const compiler.Segment, src: usize) ?usize {
    var best: ?compiler.Segment = null;
    for (segments) |s| {
        if (!s.exact or src < s.source or src >= s.source + s.source_len) continue;
        if (best == null or s.source_len < best.?.source_len) best = s;
    }
    const b = best orelse return null;
    return b.generated + (src - b.source);
}

test "Yix mapping: exact segments copy source bytes and identifiers round-trip into generated code" {
    const source = @embedFile("stories.yix");
    const r = try compiler.compileMapped(std.testing.allocator, source);
    try std.testing.expect(r == .mapped);
    defer r.mapped.deinit(std.testing.allocator);
    const m = r.mapped;
    try std.testing.expect(m.segments.len > 100);
    for (m.segments) |s| if (s.exact) {
        try std.testing.expectEqualStrings(source[s.source .. s.source + s.source_len], m.output[s.generated .. s.generated + s.generated_len]);
    };
    // identifiers in various contexts: interpolation, event statement, computed, style, component
    // tag name, param type
    const probes = [_][]const u8{ "count * 2", "count += 1", "observeBatch(a + b)", "ui.css(.{ .gap = 21 })", "W.ScrollArea", "item.title", "selected = item.id", "Label {count}", "[]const u8 = \"\"", "S.Badge" };
    var checked: usize = 0;
    for (probes) |probe| {
        const at = std.mem.indexOf(u8, source, probe) orelse continue;
        // each identifier in probe mapped to start of same-name identifier in generated code
        var z = std.zig.Tokenizer.init(try std.testing.allocator.dupeSentinel(u8, probe, 0));
        defer std.testing.allocator.free(z.buffer[0 .. z.buffer.len + 1]);
        while (true) {
            const t = z.next();
            if (t.tag == .eof) break;
            if (t.tag != .identifier) continue;
            const src = at + t.loc.start;
            const name = probe[t.loc.start..t.loc.end];
            const gen = srcToGen(m.segments, src) orelse {
                std.debug.print("unmapped identifier '{s}' in probe '{s}'\n", .{ name, probe });
                return error.TestUnexpectedResult;
            };
            try std.testing.expectEqualStrings(name, m.output[gen .. gen + name.len]);
            checked += 1;
        }
    }
    try std.testing.expect(checked >= 12);
}

test "Yix diagnostics inside control flow and attributes point at the absolute source offset" {
    const source = "pub fn C() View { var n: i32 = signal(0); return <col>{if (n > 0) <text>x</text>}<Button onClick={n = foo(1} /></col>; }";
    const r = try compiler.compile(std.testing.allocator, source);
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(r == .diagnostic);
    // diagnostic lands inside onClick attribute (before child parser offset relative to attr text)
    const attr = std.mem.indexOf(u8, source, "onClick").?;
    try std.testing.expect(r.diagnostic.offset >= attr and r.diagnostic.offset <= source.len);
}

// ── .yss style recipe ──

fn yss(source: []const u8) ![]u8 {
    const r = try compiler.style.compile(std.testing.allocator, source);
    switch (r) {
        .output => |o| return o,
        .diagnostic => |d| {
            std.debug.print("unexpected diagnostic at {d}: {s}\n", .{ d.offset, d.message });
            std.testing.allocator.free(d.message);
            return error.TestUnexpectedResult;
        },
    }
}

fn expectContains(hay: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, hay, needle) == null) {
        std.debug.print("missing `{s}` in:\n{s}\n", .{ needle, hay });
        return error.TestUnexpectedResult;
    }
}

test "yss: recipe → cva（变体、flag、默认值、复合条件 in 展开）, style → css, Zig 照搬" {
    const out = try yss(
        \\const ui = @import("ui");
        \\/// doc
        \\recipe Card {
        \\  base { direction: column; background: bg-primary; padding: 4 8; transition: background 120ms ease-out; }
        \\  variant tone = calm { calm { border: 1 border; } loud { border: 2 accent; } quiet { } }
        \\  flag selected { opacity: 0.5; }
        \\  flag hot;
        \\  when hot & !selected & tone in (calm, loud) { :hover { background: bg-hover; } }
        \\}
        \\pub fn keep() void {}
        \\style title { color: fg-primary; width: grow; margin: 1 2 3 4; background: #ff0000; height: {some.value}; }
    );
    defer std.testing.allocator.free(out);
    try expectContains(out, "/// doc\npub const Card = ui.cva(.{");
    try expectContains(out, ".padding = .{ .y = 4, .x = 8 }");
    try expectContains(out, ".transition = ui.transition(\"background 120ms ease-out\")");
    try expectContains(out, ".tone = .{ .calm = .{ .border_width = 1, .border_color = ui.tokenRef(.color, \"border\"), }");
    try expectContains(out, ".selected = .{ .false = .{ }, .true = .{ .opacity = 0.5, }");
    try expectContains(out, ".hot = .{ .false = .{ }, .true = .{ }");
    try expectContains(out, ".defaults = .{ .tone = .calm, .selected = false, .hot = false, }");
    try expectContains(out, ".{ .when = .{ .hot = true, .selected = false, .tone = .calm, }");
    try expectContains(out, ".{ .when = .{ .hot = true, .selected = false, .tone = .loud, }");
    try std.testing.expect(std.mem.indexOf(u8, out, ".tone = .quiet, }, .style") == null);
    try expectContains(out, "._hover = .{ .background = ui.tokenRef(.color, \"bg-hover\"), }");
    try expectContains(out, "pub fn keep() void {}");
    try expectContains(out, "pub const title = ui.css(.{ .color = ui.tokenRef(.color, \"fg-primary\"), .width = .{ .grow = .{} }, .margin = .{ .top = 1, .right = 2, .bottom = 3, .left = 4 }, .background = ui.Color.hex(0xff0000), .height = some.value, })");
}

test "yss: recipe slots → sva, mixin 按参数展开、后写覆盖先写" {
    const out = try yss(
        \\recipe Tag slots(root, label) {
        \\  base { root { gap: 4; } label { font-size: sm; } }
        \\  variant color = neutral { neutral { label { color: fg-primary; } } accent { tone(accent); label { font-size: xs; } } }
        \\}
        \\mixin tone(fg) { root { background: mix(bg-primary, fg, 0.25); } label { color: fg; font-size: lg; } }
    );
    defer std.testing.allocator.free(out);
    try expectContains(out, "pub const Tag = ui.sva(.{ .slots = .{ .root, .label, }");
    try expectContains(out, ".accent = .{ .root = .{ .background = ui.mix(ui.tokenRef(.color, \"bg-primary\"), ui.tokenRef(.color, \"accent\"), 0.25), }, .label = .{ .color = ui.tokenRef(.color, \"accent\"), .font_size = ui.tokenRef(.font_size, \"xs\"), }, }");
}

test "yss diagnostics point at the .yss source" {
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "recipe A { colour { } }", "unknown recipe section" },
        .{ "recipe A slots(root) { base { gap: 4; } }", "properties go inside a slot block" },
        .{ "recipe A slots(root) { base { body { gap: 4; } } }", "not a slot of this recipe" },
        .{ "recipe A { base { root { gap: 4; } } }", "has no slots" },
        .{ "recipe A { base { :hovered { } } }", "unknown condition" },
        .{ "recipe A { when hot { } }", "not a declared variant or flag" },
        .{ "recipe A { variant t { a { } } when !t { } }", "applies to flags" },
        .{ "recipe A { flag hot; when hot = true { } }", "is a flag" },
        .{ "recipe A { variant t { a { } } when t = b { } }", "not an option of" },
        .{ "recipe A { variant t = c { a { } } }", "default `c` is not an option" },
        .{ "recipe A { variant t { a { } } variant t { b { } } }", "declared twice" },
        .{ "recipe A { base { m(1); } }", "unknown mixin" },
        .{ "mixin m(x) { } recipe A { base { m(); } }", "takes 1 argument" },
        .{ "mixin m() { m(); } recipe A { base { m(); } }", "nested too deeply" },
        .{ "style s { padding: 1 2 3; }", "takes 1, 2" },
        .{ "style s { transition: ; }", "empty transition" },
        .{ "style s { gap: 4 }", "expected `;`" },
        .{ "recipe A { base { gap: 4; }", "missing `}`" },
        .{ "style s { background: mix(a, b); }", "mix takes" },
        .{ "style s { background: #fff; }", "#rrggbb" },
        .{ "style s { background: #ff00zz; }", "#rrggbb" },
        .{ "style s { background: rgba(0, 0, 0); }", "rgba takes 4 numbers" },
        .{ "style s { background: rgb(300, 0, 0); }", "whole numbers 0..255" },
        .{ "style s { background: rgba(0, 0, 0, 2); }", "alpha is 0..1" },
        .{ "style s { shadow: 0 4 accent; }", "`x y blur [spread] color`" },
        .{ "style s { shadow: 0 x 8 accent; }", "x, y, blur and spread are numbers" },
        .{ "style s { transition: x {f(\"q\")}ms; }", "plain text" },
        .{ "style s { corner-radus: 4; }", "did you mean `corner-radius`" },
        .{ "style s { colour: accent; }", "is not a style property" },
        .{ "style s { direction: colum; }", "`colum` is not a value of `direction` (expected row, row-reverse, column, column-reverse)" },
        .{ "style s { overflow-hidden: yes; }", "not a value of `overflow-hidden`" },
        .{ "mixin m(d) { direction: d; } style s { m(sideways); }", "`sideways` is not a value of `direction`" },
        .{ "recipe T slots(a-b) { base { a-b { gap: 1; } } }", "must be a Zig identifier" },
        .{ "recipe T { variant error { a { } } }", "is a Zig keyword" },
        .{ "recipe T { variant variant { a { } } }", "variant `variant` has the same name as a YSS keyword" },
        .{ "recipe T { flag when; }", "flag `when` has the same name as a YSS keyword" },
        .{ "style s { error: 1; }", "is not a style property" },
        .{ "style s { opacity: 1.2.3; }", "malformed number" },
        .{ "mixin m(a, a) { gap: a; } style s { m(1, 2); }", "listed twice" },
        .{ "style s { gap: {}; }", "empty" },
        .{ "style s { background: mix(accent, border, 1.5); }", "within 0..1" },
        .{ "style closeIcon { gap: 1; }", "style `closeIcon` should be snake_case (e.g. `close_icon`)" },
        .{ "style header_style { gap: 1; }", "drop the `_style` suffix" },
        .{ "recipe card { base { gap: 1; } }", "name it in PascalCase (e.g. `Card`)" },
        .{ "recipe T slots(root, closeText) { base { root { gap: 1; } } }", "slot `closeText` should be snake_case" },
        .{ "recipe T { flag isOn; }", "flag `isOn` should be snake_case" },
    };
    for (cases) |case| {
        const r = try compiler.style.compile(std.testing.allocator, case[0]);
        switch (r) {
            .output => |o| {
                std.testing.allocator.free(o);
                std.debug.print("expected a diagnostic for: {s}\n", .{case[0]});
                return error.TestUnexpectedResult;
            },
            .diagnostic => |d| {
                defer std.testing.allocator.free(d.message);
                if (std.mem.indexOf(u8, d.message, case[1]) == null) {
                    std.debug.print("for `{s}` expected `{s}`, got `{s}`\n", .{ case[0], case[1], d.message });
                    return error.TestUnexpectedResult;
                }
                try std.testing.expect(d.offset <= case[0].len);
            },
        }
    }
}

test "yss: 前导点数字补 0、pub 前缀、mixin 的文档注释随之去掉、{zig} 里字符串含花括号" {
    const out = try yss(
        \\/// tone
        \\mixin tone() { gap: 1; }
        \\/// doc
        \\pub style s { tone(); opacity: .5; width: {fmt("}")}; }
    );
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "/// tone") == null);
    try expectContains(out, "/// doc\npub const s = ui.css(.{ .gap = 1, .opacity = 0.5, .width = fmt(\"}\"), })");
    try std.testing.expect(std.mem.indexOf(u8, out, "pub pub") == null);
}

test ".yix / .yss 里 @import 源文件名，生成时换成双胞胎名（映射回源里那个字符串）；注释、字符串、多行字符串、@embedFile 里的不动" {
    const src =
        \\const S = @import("styles.yss");
        \\const C = @import("../card/card.yix");
        \\const u = "http://x"; // @import("keep.yss")
        \\const m =
        \\    \\@import("keep.yix")
        \\;
        \\const e = @embedFile("data.yss");
        \\pub fn A() View { return <text>say "hi</text>; }
        \\pub fn B() View { const T = @import("t.yss"); return <box style={S.root} />; }
    ;
    const r = try compiler.compileMapped(std.testing.allocator, src);
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(r == .mapped);
    const out = r.mapped.output;
    try std.testing.expect(std.mem.indexOf(u8, out, "@import(\"_styles.yss.zig\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "@import(\"../card/_card.yix.zig\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "@import(\"_t.yss.zig\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "// @import(\"keep.yss\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\\\\@import(\"keep.yix\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "@embedFile(\"data.yss\")") != null);
    // generated text twin name range maps back to string in source
    const gen = std.mem.indexOf(u8, out, "\"_styles.yss.zig\"").?;
    try std.testing.expectEqual(std.mem.indexOf(u8, src, "\"styles.yss\"").?, compiler.genToSrcNearest(r.mapped.segments, gen));
    // reverse: any position in source string (editor cursor mid-path) lands in generated string
    const src_str = std.mem.indexOf(u8, src, "\"styles.yss\"").?;
    for ([_]usize{ 1, 3, "\"styles.yss\"".len - 1 }) |d| {
        const g = compiler.srcToGen(r.mapped.segments, src_str + d).?;
        try std.testing.expect(g >= gen and g < gen + "\"_styles.yss.zig\"".len);
    }
    // subsequent copied Zig still byte-for-byte correspond
    const keep = std.mem.indexOf(u8, out, "const u = ").?;
    try std.testing.expectEqual(std.mem.indexOf(u8, src, "const u = ").?, compiler.genToSrc(r.mapped.segments, keep).?);

    const rs = try compiler.style.compile(std.testing.allocator, "const T = @import(\"x.yix\");\nstyle s { gap: 1; }");
    defer rs.deinit(std.testing.allocator);
    try std.testing.expect(rs == .output);
    try std.testing.expect(std.mem.indexOf(u8, rs.output, "@import(\"_x.yix.zig\")") != null);
}

test "yss mapped: 照搬的 Zig 与 {zig} 值逐字节映射回 .yss" {
    const style = compiler.style;
    const src = "const ui = @import(\"ui\");\nstyle s { width: {pick(1)}; }\npub fn pick(x: f32) f32 { return x; }\n";
    const r = try style.compileMapped(std.testing.allocator, src);
    try std.testing.expect(r == .mapped);
    defer r.mapped.deinit(std.testing.allocator);
    const out = r.mapped.output;
    for ([_][]const u8{ "pick(1)", "pub fn pick", "@import(\"ui\")" }) |needle| {
        const g = std.mem.indexOf(u8, out, needle).?;
        const want = std.mem.indexOf(u8, src, needle).?;
        var ok = false;
        for (r.mapped.segments) |seg| if (seg.exact and g >= seg.generated and g < seg.generated + seg.generated_len) {
            try std.testing.expectEqual(want, seg.source + (g - seg.generated));
            ok = true;
        };
        if (!ok) {
            std.debug.print("no exact segment for `{s}`\n", .{needle});
            return error.TestUnexpectedResult;
        }
    }
}

test "yss 编辑器分析：大纲与光标上下文（容忍写到一半）" {
    const style = compiler.style;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\const ui = @import("ui");
        \\/// Tag
        \\recipe Tag slots(root, label) {
        \\  base { root { gap: 4; background: bg-pr } label { font-size: sm; } }
        \\  variant size = md { sm { root { :ho } } md { } }
        \\  flag closable;
        \\  when closable & size = s
        \\}
        \\mixin tone(fg) { label { color: fg; } dir }
        \\style s { width: {x(1)}; tone(accent); direction: ro
    ;
    const syms = try style.outline(a, src);
    try std.testing.expectEqual(@as(usize, 3), syms.len);
    const tag = syms[0];
    try std.testing.expectEqualStrings("Tag", tag.name);
    try std.testing.expectEqualStrings("Tag", tag.doc);
    try std.testing.expectEqual(@as(usize, 2), tag.slots.len);
    try std.testing.expectEqual(@as(usize, 2), tag.dims.len);
    try std.testing.expectEqualStrings("size", tag.dims[0].name);
    try std.testing.expectEqual(@as(usize, 2), tag.dims[0].options.len);
    try std.testing.expectEqualStrings("sm", tag.dims[0].options[0].name);
    try std.testing.expect(tag.dims[1].flag);
    try std.testing.expectEqualStrings("fg", syms[1].params[0].name);
    try std.testing.expectEqual(src.len, syms[2].end); // not closed: to file end

    const Case = struct { needle: []const u8, delta: usize, kind: style.Context.Kind, prop: []const u8 = "", dim: []const u8 = "", word: []const u8 = "" };
    const cases = [_]Case{
        .{ .needle = "const ui", .delta = 2, .kind = .zig },
        .{ .needle = "recipe Tag", .delta = 8, .kind = .decl_name, .word = "Tag" },
        .{ .needle = "base {", .delta = 2, .kind = .section, .word = "base" },
        .{ .needle = "root { gap", .delta = 2, .kind = .slot_name, .word = "root" },
        .{ .needle = "gap: 4", .delta = 1, .kind = .property, .word = "gap" },
        .{ .needle = "bg-pr }", .delta = 5, .kind = .value, .prop = "background", .word = "bg-pr" },
        .{ .needle = ":ho }", .delta = 3, .kind = .condition, .word = "ho" },
        .{ .needle = "& size = s", .delta = 3, .kind = .when_dim, .word = "size" },
        .{ .needle = "size = s\n", .delta = 8, .kind = .when_option, .dim = "size", .word = "s" },
        .{ .needle = "color: fg", .delta = 8, .kind = .value, .prop = "color", .word = "fg" },
        .{ .needle = "dir }", .delta = 3, .kind = .property, .word = "dir" },
        .{ .needle = "x(1)", .delta = 1, .kind = .zig },
        .{ .needle = "tone(accent)", .delta = 2, .kind = .mixin_name, .word = "tone" },
        .{ .needle = "accent); dir", .delta = 3, .kind = .value, .word = "accent" },
        .{ .needle = "direction: ro", .delta = 13, .kind = .value, .prop = "direction", .word = "ro" },
    };
    for (cases) |cs| {
        const at = std.mem.indexOf(u8, src, cs.needle).? + cs.delta;
        const ctx = style.contextAt(src, syms, at);
        errdefer std.debug.print("case `{s}`+{d}: got {s} prop=`{s}` dim=`{s}` word=`{s}`\n", .{ cs.needle, cs.delta, @tagName(ctx.kind), ctx.prop, ctx.dim, ctx.word(src) });
        try std.testing.expectEqual(cs.kind, ctx.kind);
        try std.testing.expectEqualStrings(cs.prop, ctx.prop);
        try std.testing.expectEqualStrings(cs.dim, ctx.dim);
        if (cs.word.len != 0) try std.testing.expectEqualStrings(cs.word, ctx.word(src));
    }
}

test "文本空白与 JSX 相同：同一行保留、跨行去缩进并以单个空格连接、紧挨插值的同行空格保留" {
    const Case = struct { src: []const u8, want: []const u8 };
    const cases = [_]Case{
        // same line: as-is (including space before/after interpolation)
        .{ .src = "<text>a b {x} c</text>", .want = "\"a b \" ++ ui.view.yixFormat(@TypeOf(__yix_view_ctx.x), \"\") ++ \" c\"" },
        // cross-line: space before interpolation preserved (was swallowed as 'a   b' before)
        .{ .src = "<text>\n        a   b {x}\n        c\n    </text>", .want = "\"a   b \" ++ ui.view.yixFormat(@TypeOf(__yix_view_ctx.x), \"\") ++ \"c\"" },
        // multi-line plain text: dedent, single space join, blank lines drop
        .{ .src = "<text>\n    one\n\n    two  \n</text>", .want = "\"one two\"" },
        // between first line end and next line add one space
        .{ .src = "<text>a b \n   c</text>", .want = "\"a b c\"" },
    };
    for (cases) |cs| {
        const src = try std.fmt.allocPrint(std.testing.allocator, "const ui = @import(\"ui\");\npub fn A(x: i32 = 0) View {{\n    return {s};\n}}\n", .{cs.src});
        defer std.testing.allocator.free(src);
        const r = try compiler.compile(std.testing.allocator, src);
        try std.testing.expect(r == .output);
        defer std.testing.allocator.free(r.output);
        expectContains(r.output, cs.want) catch |err| {
            std.debug.print("case: {s}\n", .{cs.src});
            return err;
        };
    }
}

test "yss token 名在双胞胎里按名字取引用（ui.tokenRef，拼错时报错落到这一行）：连字符 / 数字开头的名字可写；枚举值仍 kebab → snake；12px 仍是数字" {
    const out = try yss(
        \\style s { font-size: 2xl; background: text-hairline; color: accent; direction: row-reverse; padding: 12px; gap: space200; border-color: mix(bg-primary, accent, 0.5); }
    );
    defer std.testing.allocator.free(out);
    try expectContains(out, ".font_size = ui.tokenRef(.font_size, \"2xl\")");
    try expectContains(out, ".background = ui.tokenRef(.color, \"text-hairline\")");
    try expectContains(out, ".color = ui.tokenRef(.color, \"accent\")");
    try expectContains(out, ".direction = .row_reverse");
    try expectContains(out, ".padding = 12,");
    try expectContains(out, ".gap = ui.tokenRef(.space, \"space200\")");
    try expectContains(out, "ui.mix(ui.tokenRef(.color, \"bg-primary\"), ui.tokenRef(.color, \"accent\"), 0.5)");
}

test "宿主元素的未知属性在 .yix 原文位置报错并给拼写建议；各标签的属性集不同" {
    const Case = struct { src: []const u8, at: []const u8, want: []const u8 };
    const cases = [_]Case{
        .{ .src = "<text onKeyDown={x()}>t</text>", .at = "onKeyDown", .want = "<text> has no attribute `onKeyDown`" },
        .{ .src = "<row focusrng />", .at = "focusrng", .want = "did you mean `focusRing`?" },
        .{ .src = "<text focusable>hi</text>", .at = "focusable", .want = "<text> has no attribute `focusable`" },
        .{ .src = "<icon src={a} box={b} />", .at = "box", .want = "<icon> has no attribute `box`" },
        .{ .src = "<col columns={2} />", .at = "columns", .want = "<col> has no attribute `columns`" },
    };
    for (cases) |cs| {
        const src = try std.fmt.allocPrint(std.testing.allocator, "pub fn C() View {{ return {s}; }}", .{cs.src});
        defer std.testing.allocator.free(src);
        const r = try compiler.compile(std.testing.allocator, src);
        defer r.deinit(std.testing.allocator);
        try std.testing.expect(r == .diagnostic);
        expectContains(r.diagnostic.message, cs.want) catch |err| {
            std.debug.print("case: {s} -> {s}\n", .{ cs.src, r.diagnostic.message });
            return err;
        };
        try std.testing.expectEqual(std.mem.indexOf(u8, src, cs.at).?, r.diagnostic.offset);
    }
    // grid grid attrs, canvas draw trio, icon src all normal work
    const ok = try compiler.compile(std.testing.allocator, "pub fn C() View { return <col><grid columns={c} rowGap={4} /><canvas draw={f} data={d} animate /><icon src={a} tint={t} /></col>; }");
    defer ok.deinit(std.testing.allocator);
    try std.testing.expect(ok == .output);
}

test "编译器的宿主属性表与 view.zig 的 box_props / grid_props / text_props / icon_props 逐项一致" {
    const a = std.testing.allocator;
    const view = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "src/ui/view.zig", a, .limited(16 << 20));
    defer a.free(view);
    const Pair = struct { list: []const u8, attrs: []const compiler.HostAttr };
    const pairs = [_]Pair{
        .{ .list = "box_props", .attrs = &compiler.box_attrs },
        .{ .list = "text_props", .attrs = &compiler.text_attrs },
        .{ .list = "icon_props", .attrs = &compiler.media_attrs },
    };
    for (pairs) |pair| {
        // `const box_props = [_][]const u8{ "style", "test_id", … };`
        const head = try std.fmt.allocPrint(a, "const {s} = [_][]const u8{{", .{pair.list});
        defer a.free(head);
        const start = (std.mem.indexOf(u8, view, head) orelse return error.ListNotFound) + head.len;
        const end = std.mem.indexOfPos(u8, view, start, "}").?;
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(a);
        var it = std.mem.tokenizeAny(u8, view[start..end], " ,\"\n");
        while (it.next()) |n| try names.append(a, n);
        try std.testing.expectEqual(names.items.len, pair.attrs.len);
        for (pair.attrs, names.items) |at, snake| {
            var buf: [64]u8 = undefined;
            var k: usize = 0;
            for (at.name) |ch| {
                if (std.ascii.isUpper(ch)) {
                    buf[k] = '_';
                    k += 1;
                }
                buf[k] = std.ascii.toLower(ch);
                k += 1;
            }
            std.testing.expectEqualStrings(snake, buf[0..k]) catch |err| {
                std.debug.print("{s}: compiler `{s}` vs view.zig `{s}`\n", .{ pair.list, at.name, snake });
                return err;
            };
        }
    }
    // grid = box + grid four-item
    try std.testing.expect(std.mem.indexOf(u8, view, "const grid_props = box_props ++ [_][]const u8{ \"columns\", \"rows\", \"column_gap\", \"row_gap\" };") != null);
    try std.testing.expectEqual(compiler.box_attrs.len + 4, compiler.grid_attrs.len);
}

test "camelOf 给出的建议是不动点：照建议改名后不会再被拒" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_][]const u8{ "a_bC", "login_uRL", "iOS", "onURLChange", "ID", "URL", "X", "_x", "x_", "a__b", "icon_only", "testID", "x2", "aBCdE_fG" };
    for (cases) |c| {
        const once = try compiler.camelOf(a, c);
        try std.testing.expectEqualStrings(once, try compiler.camelOf(a, once));
    }
    try std.testing.expectEqualStrings("iconOnly", try compiler.camelOf(a, "icon_only"));
    try std.testing.expectEqualStrings("testId", try compiler.camelOf(a, "testID"));
    try std.testing.expectEqualStrings("onUrlChange", try compiler.camelOf(a, "onURLChange"));
}

test "parts(…) 声明：维度值原样传给 ui.view.slotParts（源不读），名字可在模板里用" {
    const r = try compiler.compile(std.testing.allocator, "pub fn C(tone: Tone = .a) View { const p = parts(S.R, .{ .tone = tone }); return <box style={p.root}></box>; }");
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(r == .output);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "const p = ui.view.slotParts(S.R, .{ .tone = tone });") != null);
}

test "effect 里用复合赋值读旧值（不跟踪）不算自读自写" {
    const r = try compiler.compile(std.testing.allocator, "pub fn C(k: i32 = 0) View { var n: i32 = signal(0); effect(n += k); return <text>{n}</text>; }");
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(r == .output);
}

test "yss: #rrggbbaa、rgb() / rgba()（alpha 0..1）、自定义阴影（颜色可为 token / mix）、icon-color" {
    const out = try yss(
        \\style a { background: #11223380; border: 1 rgba(255, 0, 0, 0.5); color: rgb(1, 2, 3); }
        \\style b { shadow: 0 4 12 accent; }
        \\style c { shadow: 0 32 80 -8 mix(bg-primary, rgba(0, 0, 0, 1), 0.5); icon-color: fg-secondary; }
    );
    defer std.testing.allocator.free(out);
    try expectContains(out, ".background = ui.Color.rgba(0x11, 0x22, 0x33, 0x80)");
    try expectContains(out, ".border_color = ui.Color.rgba(255, 0, 0, 128)");
    try expectContains(out, ".color = ui.Color.rgba(1, 2, 3, 255)");
    try expectContains(out, ".shadow = .{ .offset_x = 0, .offset_y = 4, .blur = 12, .spread = 0, .color = ui.tokenRef(.color, \"accent\") }");
    try expectContains(out, ".shadow = .{ .offset_x = 0, .offset_y = 32, .blur = 80, .spread = -8, .color = ui.mix(ui.tokenRef(.color, \"bg-primary\"), ui.Color.rgba(0, 0, 0, 255), 0.5) }");
    try expectContains(out, ".icon_color = ui.tokenRef(.color, \"fg-secondary\")");
}

test "yss: 选项名可以与 Zig 关键字同名（公共枚举里的 .@\"error\"），生成 @\"error\"" {
    const out = try yss("recipe T { variant v = error { ok { gap: 1; } error { gap: 2; } } when v = error { padding: 1; } }");
    defer std.testing.allocator.free(out);
    try expectContains(out, ".@\"error\" = .{ .gap = 2, }");
    try expectContains(out, ".defaults = .{ .v = .@\"error\", }");
    try expectContains(out, ".when = .{ .v = .@\"error\", }");
}

test "惰性分支 / 行只捕获函数体实际用到的外层名字（不把组件的全部局部量复制进每个分支区域）" {
    const src =
        \\pub fn C() View {
        \\    var a: bool = signal(true);
        \\    var b: i32 = signal(1);
        \\    var c: i32 = signal(2);
        \\    var t: Tab = signal(.home);
        \\    var rows: []const Item = signal(&items);
        \\    return <col><text>{c}</text>{if (a) <text>{b}</text> else <spacer />}{switch (t) { .home => <text>{c}</text>, .settings => <spacer /> }}{for (rows) |item| <text>{item.title}{b}</text>}{if (a) if (a) <text>{c}</text>}</col>;
        \\}
    ;
    const r = try compiler.compile(std.testing.allocator, src);
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(r == .output);
    const out = r.output;
    // if: only capture b; switch: only capture c; for: only capture b; nested if: outer only
    // capture inner-need a, c
    try std.testing.expect(std.mem.indexOf(u8, out, "ui.view.lazyIf(__yix_view_ctx.a, .{ .b = __yix_view_ctx.b, }") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "ui.view.lazySwitch(__yix_view_ctx.t, .{ .c = __yix_view_ctx.c, }") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "ui.view.eachWith(.{ .b = __yix_view_ctx.b, }") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "ui.view.lazyIf(__yix_view_ctx.a, .{ .a = __yix_view_ctx.a, .c = __yix_view_ctx.c, }") != null);
    // The outer view captures rows to feed the list, while its row callback
    // captures only b. Exact eachWith argument checks above guard that boundary.
    try expectContains(out, ".rows = rows");
}

test "组件属性的派生值按 ui.view.attrType 定型；类型里的 const（[]const u8、*const fn）不当成局部绑定" {
    const r = try compiler.compile(std.testing.allocator, "pub fn C() View { var on: bool = signal(false); const p = computed(@as(*align(4) const u32, @ptrCast(@alignCast(q))) != null and on); return <W.Button variant={if (on) .primary else .ghost} disabled={p} label={if (on) @as([]const u8, \"a\") else \"b\"} />; }");
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(r == .output);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "ui.view.attrType(W.Button, \"variant\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "ui.view.attrType(W.Button, \"label\")") != null);
    // host element doesn't use attrType
    const h = try compiler.compile(std.testing.allocator, "pub fn C() View { var on: bool = signal(false); return <box visible={on and true} />; }");
    defer h.deinit(std.testing.allocator);
    try std.testing.expect(h == .output and std.mem.indexOf(u8, h.output, "attrType") == null);
}

test "errmap: 双胞胎里的报错位置映射回 .yix；库代码里的报错按引用链的第一个双胞胎帧映射；其余行原样" {
    const errmap = compiler.errmap;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const src =
        \\const ui = @import("ui");
        \\pub fn C() View {
        \\    var on: bool = signal(false);
        \\    return <W.Button variant={if (on) .primary else .ghost} />;
        \\}
    ;
    try tmp.dir.createDirPath(std.testing.io, "sub");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "sub/c.yix", .data = src });
    const r = try compiler.compileMappedSource(a, "sub/c.yix", src);
    const twin = try compiler.twinText(a, "c.yix", r.mapped.output);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "sub/_c.yix.zig", .data = twin });
    // position of `.primary` in twin
    const g = std.mem.indexOf(u8, twin, ".primary").?;
    const glc = compiler.lineColumn(twin, g);
    const want = compiler.lineColumn(src, std.mem.indexOf(u8, src, ".primary").?);
    var mapper: errmap.Mapper = .{ .a = a, .dir = tmp.dir, .io = std.testing.io };
    const text = try std.fmt.allocPrint(a,
        \\sub/_c.yix.zig:{d}:{d}: error: value with comptime-only type
        \\    @TypeOf(...)
        \\src/ui/reactive/props.zig:33:37: error: ButtonProps: unknown prop 'x'
        \\referenced by:
        \\    Button__anon_1: src/ui/components/button/_button.yix.zig:9999:1
        \\    C__anon_2: sub/_c.yix.zig:2:1
        \\    __yix_C: sub/_c.yix.zig:{d}:{d}
        \\other line
    , .{ glc.line, glc.column, glc.line, glc.column });
    const ds = try errmap.collect(&mapper, text);
    try std.testing.expectEqual(@as(usize, 2), ds.len);
    try std.testing.expectEqualStrings("sub/c.yix", ds[0].path);
    try std.testing.expectEqual(want.line, ds[0].line);
    try std.testing.expectEqual(want.column, ds[0].column);
    try std.testing.expectEqual(want.line, ds[1].line);
    try std.testing.expect(std.mem.indexOf(u8, ds[1].message, "unknown prop 'x' (reported at src/ui/reactive/props.zig:33:37)") != null);
    const out = try errmap.rewrite(&mapper, text);
    try std.testing.expect(std.mem.startsWith(u8, out, try std.fmt.allocPrint(a, "sub/c.yix:{d}:{d}: error: value with comptime-only type [generated: sub/_c.yix.zig:", .{ want.line, want.column })));
    try std.testing.expect(std.mem.indexOf(u8, out, try std.fmt.allocPrint(a, "sub/c.yix:{d}:{d}: note: Yix source of the error above (ButtonProps: unknown prop 'x')", .{ want.line, want.column })) != null);
    try std.testing.expect(std.mem.endsWith(u8, out, "\nother line"));
    // source changed but twin not regenerated: map anyway, note stale
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "sub/c.yix", .data = try std.fmt.allocPrint(a, "{s}\n// edited", .{src}) });
    var m2: errmap.Mapper = .{ .a = a, .dir = tmp.dir, .io = std.testing.io };
    const d2 = try errmap.collect(&m2, text);
    try std.testing.expect(std.mem.indexOf(u8, d2[0].message, "out of date") != null);
}

test "yss: 参数化样式 → ui.paramStyle（参数字段、?? 后备值、when 参数条件按序叠加、{zig} 里的 $p、结尾逗号）" {
    const out = try yss(
        \\const ui = @import("ui");
        \\/// doc
        \\style box(
        \\  $w: ?f32,
        \\  $gap: f32 = 4,
        \\  $kind: K = .{ .x = 1 }.y,
        \\  $on: bool = false,
        \\) {
        \\  width: $w ?? fit;
        \\  gap: $gap;
        \\  background: mix(bg-primary, accent, 0.5);
        \\  when $on { opacity: 0.5; }
        \\  when !$on & $kind in (a, error) { height: {$gap * 2}; }
        \\  when $kind = b & {$gap > 1} { margin: $gap 0; }
        \\  when {$w != null} { corner-radius: 2; }
        \\}
    );
    defer std.testing.allocator.free(out);
    try expectContains(out, "/// doc\npub const box = ui.paramStyle(struct { w: ?f32, gap: f32 = 4, kind: K = .{ .x = 1 }.y, on: bool = false,");
    try expectContains(out, "pub const declared = &[_][]const u8{ \"width\", \"gap\", \"background\", \"opacity\", \"height\", \"margin\", \"corner_radius\", };");
    try expectContains(out, "pub fn resolve(args: @This(), t: *const ui.theme.Values) ui.BoxStyle { var out = ui.boxFrom(.{ .width = ui.orElse(args.w, .fit), .gap = args.gap, .background = ui.mix(");
    try expectContains(out, "if (args.on) out = out.merge(ui.boxFrom(.{ .opacity = 0.5, }, t));");
    try expectContains(out, "if (!args.on and (args.kind == .a or args.kind == .@\"error\")) out = out.merge(ui.boxFrom(.{ .height = args.gap * 2, }, t));");
    try expectContains(out, "if (args.kind == .b and (args.gap > 1)) out = out.merge(ui.boxFrom(.{ .margin = .{ .y = args.gap, .x = 0 }, }, t));");
    try expectContains(out, "if (args.w != null) out = out.merge(ui.boxFrom(.{ .corner_radius = 2, }, t));");
    try expectContains(out, "return out; } });");
}

test "yss: 参数化样式没有 when 时直接返回；多层阴影 shadow: a, b → shadows" {
    const out = try yss(
        \\style s($h: f32) { height: $h; }
        \\style d { shadow: lg, 0 32 80 #00000019; }
    );
    defer std.testing.allocator.free(out);
    try expectContains(out, "pub fn resolve(args: @This(), t: *const ui.theme.Values) ui.BoxStyle { return ui.boxFrom(.{ .height = args.h, }, t); } });");
    try expectContains(out, ".shadows = .{ ui.tokenRef(.shadow, \"lg\"), .{ .offset_x = 0, .offset_y = 32, .blur = 80, .spread = 0, .color = ui.Color.rgba(0x00, 0x00, 0x00, 0x19) }, }");
}

test "yss: 普通样式的 {zig} 读主题 t 时编成无参数的主题解析器（.of(.{})）；字段 .t 与字符串里的 t 不算" {
    const out = try yss(
        \\style ring { corner-radius: control; outline: {ui.Outline{ .color = t.tokens.color.focus_ring, .width = 2 }}; }
        \\style plain { width: {cfg.t + 1}; height: {f("t")}; }
    );
    defer std.testing.allocator.free(out);
    try expectContains(out, "pub const ring = ui.paramStyle(struct { pub const declared = &[_][]const u8{ \"corner_radius\", \"outline\", }; pub fn resolve(args: @This(), t: *const ui.theme.Values) ui.BoxStyle { _ = args; return ui.boxFrom(.{ .corner_radius = ui.tokenRef(.radius, \"control\"), .outline = ui.Outline{ .color = t.tokens.color.focus_ring, .width = 2 }, }, t); } }).of(.{});");
    try expectContains(out, "pub const plain = ui.css(");
}

test "yss mapped: 参数化样式里参数类型、默认值与 {zig} 中 $p 两侧的原文逐字节映射回 .yss" {
    const src = "style s($w: Wide = Wide.n) { width: {f($w) + g}; }";
    const r = try compiler.style.compileMapped(std.testing.allocator, src);
    try std.testing.expect(r == .mapped);
    defer r.mapped.deinit(std.testing.allocator);
    const out = r.mapped.output;
    for ([_][]const u8{ "Wide", "Wide.n", " + g", "f(" }) |piece| {
        const g = std.mem.indexOf(u8, out, piece).?;
        const want = std.mem.indexOf(u8, src, piece).?;
        var ok = false;
        for (r.mapped.segments) |seg| if (seg.exact and g >= seg.generated and g < seg.generated + seg.generated_len) {
            try std.testing.expectEqual(want, seg.source + (g - seg.generated));
            ok = true;
        };
        if (!ok) {
            std.debug.print("no exact segment for `{s}`\n", .{piece});
            return error.TestUnexpectedResult;
        }
    }
    try expectContains(out, ".width = f(args.w) + g,");
}

test "yss 参数化样式的诊断" {
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "style s() { gap: 1; }", "needs at least one parameter" },
        .{ "style s(w: f32) { gap: w; }", "expected a parameter like" },
        .{ "style s($w f32) { gap: $w; }", "`:` and the parameter type" },
        .{ "style s($w: ) { gap: $w; }", "expected a parameter type" },
        .{ "style s($w: f32, $w: f32) { gap: $w; }", "listed twice" },
        .{ "style s($error: f32) { gap: $error; }", "is a Zig keyword" },
        .{ "style s($resolve: f32) { gap: $resolve; }", "is reserved" },
        .{ "style s($w: f32) { gap: 1; }", "parameter `$w` is never used" },
        .{ "style s($w: f32) { gap: $x; }", "unknown parameter `$x` (declared: $w)" },
        .{ "style s($w: f32) { gap: {$x + 1}; }", "unknown parameter `$x`" },
        .{ "style s { gap: $x; }", "parameters exist only in a parameterized style" },
        .{ "style s($w: f32) { gap: $w ?? 1; }", "is `f32` (not optional)" },
        .{ "style s($w: ?f32, $v: ?f32) { gap: $w ?? $v; }", "the fallback after `??` is a plain value" },
        .{ "style s($k: f32) { when $k { gap: 1; } }", "needs a bool parameter" },
        .{ "style s($k: bool) { when $k = a { gap: 1; } }", "compares an enum parameter" },
        .{ "style s($k: ?K) { when $k in (a) { gap: 1; } }", "compares an enum parameter" },
        .{ "style s($k: K) { when !$k = a { gap: 1; } }", "applies to a bool parameter" },
        .{ "style s($k: bool) { when $k { when $k { gap: 1; } } }", "do not nest" },
        .{ "style s($k: bool) { when $k gap: 1; }", "expected `&` or `{`" },
        .{ "style s($k: bool) { :hover { gap: 1; } when $k { gap: 2; } }", "pure function of its parameters" },
        .{ "style s($k: bool) { transition: opacity 1s; when $k { gap: 2; } }", "transitions are not supported" },
        .{ "style s { outline: {ui.Outline{ .color = t.tokens.color.accent }}; :hover { opacity: 0.5; } }", "cannot hold interactive states" },
        .{ "style s { :hover { opacity: 0.5; } width: {t.tokens.size.control_md}; }", "cannot hold interactive states" },
        .{ "style s { transition: opacity 100ms; width: {t.tokens.size.control_md}; }", "cannot declare transitions" },
        .{ "style s { font-size-set: true; }", "is not a style property" },
        .{ "style s($c: ?ui.Color) { background: mix($c ?? accent, accent, 0.5); }", "cannot be used inside mix()" },
        .{ "style s($w: f32 { gap: $w; }", "unterminated parameter list" },
        .{ "style s { shadow: lg, ; }", "empty shadow layer" },
        .{ "style s { shadow: lg, 0 4 accent; }", "separate layers with `,`" },
    };
    for (cases) |case| {
        const r = try compiler.style.compile(std.testing.allocator, case[0]);
        switch (r) {
            .output => |o| {
                std.testing.allocator.free(o);
                std.debug.print("expected a diagnostic for: {s}\n", .{case[0]});
                return error.TestUnexpectedResult;
            },
            .diagnostic => |d| {
                defer std.testing.allocator.free(d.message);
                if (std.mem.indexOf(u8, d.message, case[1]) == null) {
                    std.debug.print("for `{s}` expected `{s}`, got `{s}`\n", .{ case[0], case[1], d.message });
                    return error.TestUnexpectedResult;
                }
                try std.testing.expect(d.offset <= case[0].len);
            },
        }
    }
}

test "yss 参数化样式：字符串 / \\\\ 多行字符串 / 注释里的 `$`、`,`、`)` 不当真" {
    const out = try yss(
        \\style s(
        \\  $w: f32 = f("a,)"), // comment ,  ) $x
        \\  $n: []const u8 =
        \\    \\multi, line ) $w
        \\  ,
        \\) {
        \\  width: {g($w, "$w", '$')};
        \\  height: {h(
        \\    \\keep $w here
        \\  , $w)};
        \\  gap: {$n.len};
        \\}
    );
    defer std.testing.allocator.free(out);
    try expectContains(out, "w: f32 = f(\"a,)\"),");
    try expectContains(out, "\\\\multi, line ) $w");
    try expectContains(out, ".width = g(args.w, \"$w\", '$'),");
    try expectContains(out, "\\\\keep $w here");
    try expectContains(out, ", args.w),");
}

test "内建按 token 识别：`signal (x)` 带空格同样是内建；`computed(a) + 1` 不是整个内建调用（按普通局部量处理）" {
    const r = try compiler.compile(std.testing.allocator, "pub fn C() View { var n: i32 = signal (3); return <text>{n}</text>; }");
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(r == .output);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "scope.createSignalFor(i32, 3)") != null);
    const r2 = try compiler.compile(std.testing.allocator, "pub fn C() View { var n: i32 = signal(0); const d = computed(n) + 1; return <text>{d}</text>; }");
    defer r2.deinit(std.testing.allocator);
    try std.testing.expect(r2 == .diagnostic);
    try std.testing.expect(std.mem.indexOf(u8, r2.diagnostic.message, "reactive reads in component locals") != null);
}

test "errmap：.yss 里拼错的 token 名——报错在 ui.css 里，紧跟的 note 落在双胞胎：error 的源位置就是 .yss 的属性行" {
    const errmap = compiler.errmap;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const src =
        \\const ui = @import("ui");
        \\style title {
        \\  gap: 4;
        \\  color: fg-secondry;
        \\}
    ;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "s.yss", .data = src });
    const r = try compiler.style.compileMapped(a, src);
    const twin = try compiler.twinText(a, "s.yss", r.mapped.output);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "_s.yss.zig", .data = twin });
    try std.testing.expect(std.mem.indexOf(u8, twin, "ui.tokenRef(.color, \"fg-secondry\")") != null);
    const g = compiler.lineColumn(twin, std.mem.indexOf(u8, twin, "ui.tokenRef(.color, \"fg-secondry\")").?);
    const want = compiler.lineColumn(src, std.mem.indexOf(u8, src, "color: fg").?);
    var mapper: errmap.Mapper = .{ .a = a, .dir = tmp.dir, .io = std.testing.io };
    const text = try std.fmt.allocPrint(a,
        \\src/ui/css.zig:443:75: error: ui.css: no color token .fg-secondry (did you mean .fg_secondary?)
        \\    if (comptime tokenError(cat, name)) |msg| @compileError("ui.css: " ++ msg);
        \\_s.yss.zig:{d}:{d}: note: called at comptime here
        \\pub const title = ui.css(...);
        \\error: the following command failed with 1 compilation errors:
    , .{ g.line, g.column + 2 });
    const ds = try errmap.collect(&mapper, text);
    try std.testing.expectEqual(@as(usize, 1), ds.len);
    try std.testing.expectEqualStrings("s.yss", ds[0].path);
    try std.testing.expectEqual(errmap.Severity.@"error", ds[0].severity);
    try std.testing.expectEqual(want.line, ds[0].line);
    try std.testing.expect(std.mem.indexOf(u8, ds[0].message, "no color token .fg-secondry") != null);
    const out = try errmap.rewrite(&mapper, text);
    try std.testing.expect(std.mem.indexOf(u8, out, try std.fmt.allocPrint(a, "s.yss:{d}:", .{want.line})) != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "note: Yix source of the error above (ui.css: no color token") != null);
}

test "yss: transition 可以跨行（空白折成单个空格）" {
    const out = try yss(
        \\style s {
        \\  transition: background 150ms ease-out,
        \\              opacity   100ms;
        \\}
    );
    defer std.testing.allocator.free(out);
    try expectContains(out, ".transition = ui.transition(\"background 150ms ease-out, opacity 100ms\")");
}

test "yss: flag x { 开 } else { 关 }——关着时的块进 .false 选项" {
    const out = try yss("recipe R { flag on { opacity: 1; } else { opacity: 0.5; } }");
    defer std.testing.allocator.free(out);
    try expectContains(out, ".on = .{ .false = .{ .opacity = 0.5, }, .true = .{ .opacity = 1, }, }");
}

test "LP3 template metadata normalizes tokens preserves strings and separates branch paths" {
    const cases = .{
        "pub fn C() View { var n: i32 = signal(0); return <col><box testId=\"two  spaces\" visible={true} focusable={n + 1 > 0}/>{if (n > 0) <text>{n + 1}</text> else <text>{n + 1}</text>}</col>; }",
        "pub fn C() View { var n: i32 = signal(0); return <col><box testId=\"two  spaces\" visible={true} focusable={n+1>0}/>{if(n>0)<text>{n+1}</text>else<text>{n+1}</text>}</col>; }",
    };
    inline for (cases) |source| {
        const result = try compiler.compile(std.testing.allocator, source);
        try std.testing.expect(result == .output);
        defer std.testing.allocator.free(result.output);
        for ([_][]const u8{
            "ui.view.templateSite(",
            ".module = \"<memory>\"",
            ".path = \"C/keyword_if:1/branch:0\"",
            ".path = \"C/keyword_if:1/branch:1\"",
            ".tokens = \"n + 1 > 0 \"",
            ".boolean = true",
            ".text = \"two  spaces\"",
        }) |expected| {
            if (std.mem.indexOf(u8, result.output, expected) == null) std.debug.print("missing template metadata: {s}\n", .{expected});
            try std.testing.expect(std.mem.indexOf(u8, result.output, expected) != null);
        }
    }
}

test "LP3 module identity uses repository-relative source not generated twin location" {
    const source = "pub fn Stable() View { return <box><text>stable</text></box>; }";
    const result = try compiler.compileSource(std.testing.allocator, "tests/yix/stable.yix", source);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result == .output);
    try expectContains(result.output, ".module = \"tests/yix/stable.yix\"");
    try std.testing.expect(std.mem.indexOf(u8, result.output, "@src().file") == null);
    const mapped = try compiler.compileMappedSource(std.testing.allocator, "tests/yix/stable.yix", source);
    defer mapped.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(result.output, mapped.mapped.output);
}

test "LP4 preview baseline survives isolated cache output without source adjacency" {
    const source = "const ui = @import(\"ui\");\npub fn Cached() View { var n: u32 = signal(3); return <text>{n}</text>; }\n";
    const result = try compiler.compileSource(std.testing.allocator, "cached/view.yix", source);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result == .output);
    const prefix = "const __yix_preview_source: ?[]const u8 = if (ui.view.template.preview_enabled) ";
    const start = std.mem.indexOf(u8, result.output, prefix).? + prefix.len;
    const literal = result.output[start..];
    const end = std.mem.indexOfScalar(u8, literal[1..], '"').? + 2;
    const decoded = try std.zig.string_literal.parseAlloc(std.testing.allocator, literal[0..end]);
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualStrings(source, decoded);
    try expectContains(result.output, ".source = __yix_preview_source");
    try std.testing.expect(std.mem.indexOf(u8, result.output, "@embedFile(") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "signal(") == null);
}

test "LP4 catalogs enumerate private nested styles and preserve static hole identity" {
    const source = "const ui = @import(\"ui\"); const S = struct { value: []const u8 = \"\", const Hidden: @TypeOf(ui.css(.{ .gap = 4 })) = ui.css(.{ .gap = 4 }); }; pub fn C() View { var n: u32 = signal(1); return <box visible={true} onClick={n += 1}><text>before {n} after</text></box>; }";
    const result = try compiler.compileSource(std.testing.allocator, "catalog.yix", source);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result == .output);
    try std.testing.expect(std.mem.indexOf(u8, result.output, ".@\"S . Hidden \" = S.Hidden") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "S.u8") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "visible = @static") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "n  @interpolation") != null);
}

test "LP4 interpolation markers inside string arguments are literal data" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source = "pub fn C() View { return <box><text>before {\" @interpolation \"} after</text></box>; }";
    const result = try compiler.compilePreview(arena.allocator(), "marker.yix", source);
    try std.testing.expect(result == .document);
    const op = result.document.components[0].ops[1];
    try std.testing.expectEqual(@as(usize, 2), op.fragments.len);
    try std.testing.expectEqualStrings("before ", op.fragments[0]);
    try std.testing.expectEqualStrings(" after", op.fragments[1]);
}

test "LP4 containers leave interpolation fragments on the child text instruction" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source = "pub fn C() View { var n: u32 = signal(1); return <box onClick={n += 1}>before {n} after</box>; }";
    const result = try compiler.compilePreview(arena.allocator(), "direct.yix", source);
    try std.testing.expect(result == .document);
    const ops = result.document.components[0].ops;
    try std.testing.expectEqual(@as(usize, 0), ops[0].fragments.len);
    try std.testing.expectEqual(@as(usize, 2), ops[1].fragments.len);
}

test "LP5 preview nested regions preserve envelopes controller keys and slot identities" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source =
        \\pub fn C() View { var items: []const u32 = signal(&.{1}); var shown: bool = signal(true); return <col>{for (items) |item| <box key={item}><text>row</text></box>}{if (shown) <box><text>branch</text></box> else <text>else</text>}<Shell header={<box><text>header</text></box>}><box><text>default</text></box></Shell></col>; }
    ;
    const b1 = try std.mem.replaceOwned(u8, a, source, "<text>row</text>", "<row><text>changed row</text></row>");
    const b2 = try std.mem.replaceOwned(u8, a, b1, "<text>branch</text>", "<col><text>changed branch</text></col>");
    const b = try std.mem.replaceOwned(u8, a, b2, "<text>header</text>", "<box><text>changed header</text></box>");
    const before = (try compiler.compilePreview(a, "fixture.yix", source)).document;
    const after = (try compiler.compilePreview(a, "fixture.yix", b)).document;
    try std.testing.expectEqualStrings(before.envelope, after.envelope);
    try std.testing.expectEqual(@as(usize, 5), before.regions.len);
    try std.testing.expectEqual(before.regions.len, after.regions.len);
    for (before.components[0].ops, after.components[0].ops) |x, y| {
        try std.testing.expectEqualStrings(x.identity_tokens orelse x.tokens, y.identity_tokens orelse y.tokens);
    }
    for (before.regions, after.regions) |x, y| {
        try std.testing.expectEqualStrings(x.name, y.name);
        try std.testing.expectEqualStrings(x.key_tokens, y.key_tokens);
    }
    const key = try std.mem.replaceOwned(u8, a, source, "key={item}", "key={item + 1}");
    const keyed = (try compiler.compilePreview(a, "fixture.yix", key)).document;
    try std.testing.expect(!std.mem.eql(u8, before.regions[0].key_tokens, keyed.regions[0].key_tokens));
}

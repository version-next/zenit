//! Yix -> ui.view compiler. Zig tokenization owns strings/comments and
//! balanced Zig islands; a recursive descent parser owns tags and control flow.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Token = std.zig.Token;
const List = std.ArrayList;
const Error = error{ InvalidYix, OutOfMemory };

/// Syntax-only preview lowering. Concrete types remain in the compiled schema;
/// these records can only select an existing typed factory, never evaluate Zig.
pub const PreviewAttribute = struct { name: []const u8, value: []const u8, literal: bool = false, slot: bool = false };
pub const PreviewOp = struct {
    kind: enum { element, text, hole, close },
    path: []const u8 = "",
    receiver: []const u8 = "",
    tokens: []const u8 = "",
    identity_tokens: ?[]const u8 = null,
    attributes: []const PreviewAttribute = &.{},
    literal: ?[]const u8 = null,
    captures: []const []const u8 = &.{},
    fragments: []const []const u8 = &.{},
};
pub const PreviewComponent = struct {
    name: []const u8,
    start: usize,
    end: usize,
    ops: []const PreviewOp,
    isolated: bool,
    key_tokens: []const u8 = "",
    region: bool = false,
};
pub const PreviewDocument = struct { envelope: []const u8, components: []const PreviewComponent, regions: []const PreviewComponent };
pub const PreviewResult = union(enum) { document: PreviewDocument, diagnostic: Diagnostic };
const PreviewCollector = struct { ops: List(PreviewOp) = .empty, components: List(PreviewComponent) = .empty, regions: List(PreviewComponent) = .empty };

/// All storage belongs to `a` (normally a preparation arena). Uses the exact
/// production parser, including Zig tokenization and lexical region assignment.
pub fn compilePreview(a: Allocator, module_path: []const u8, source: []const u8) !PreviewResult {
    if (std.mem.indexOfAny(u8, source, &.{ mark_open, mark_text, mark_close, mark_point, mark_component })) |at|
        return .{ .diagnostic = .{ .offset = at, .message = "invalid source control byte" } };
    const root = try a.dupeSentinel(u8, source, 0);
    var origins: List(Origin) = .empty;
    try origins.append(a, .{ .ptr = @intFromPtr(root.ptr), .len = root.len, .offset = 0 });
    var seq: usize = 0;
    var collector: PreviewCollector = .{};
    var p: Parser = .{ .a = a, .source = root, .module_path = module_path, .origins = &origins, .flow_seq = &seq, .preview = &collector };
    _ = p.file() catch |err| switch (err) {
        error.InvalidYix => return .{ .diagnostic = p.diagnostic orelse .{ .offset = p.absolute(p.pos), .message = "invalid Yix syntax" } },
        else => return err,
    };
    var envelope: List(u8) = .empty;
    var cursor: usize = 0;
    for (collector.components.items) |c| {
        try envelope.appendSlice(a, try p.normalizedTokens(source[cursor..c.start]));
        try envelope.appendSlice(a, " @template_boundary ");
        cursor = c.end;
    }
    try envelope.appendSlice(a, try p.normalizedTokens(source[cursor..]));
    return .{ .document = .{ .envelope = envelope.items, .components = collector.components.items, .regions = collector.regions.items } };
}

/// Messages have static storage; only Result.output needs freeing.
/// `offset` is absolute byte offset in .yix source (subparser positions already adjusted).
pub const Diagnostic = struct { offset: usize, message: []const u8 };
/// `.yss` style recipe file compiler (recipe / style / mixin -> ui.cva / ui.sva / ui.css).
pub const style = @import("style_compiler.zig");
/// Map Zig compilation errors back to .yix/.yss (command-line `yix map-errors`, yix-lsp on-save
/// build).
pub const errmap = @import("errmap.zig");
/// Compilation result; output and diagnostics owned by caller's allocator, freed via `deinit`.
pub const Result = union(enum) {
    output: []u8,
    diagnostic: Diagnostic,
    pub fn deinit(r: Result, allocator: Allocator) void {
        switch (r) {
            .output => |o| allocator.free(o),
            .diagnostic => |d| allocator.free(d.message),
        }
    }
};

/// Correspondence between generated code and .yix source. `exact`: generated text byte-for-byte
/// matches source (copied Zig), offsets shift by bytes; else synthetic code (e.g., camelCase
/// property -> snake field), single span maps to one source point.
pub const Segment = struct { generated: usize, generated_len: usize, source: usize, source_len: usize, exact: bool };
/// Editor (LSP) use: output + position mapping. Both owned by caller's allocator, freed via
/// `deinit`.
pub const Mapped = struct {
    output: []u8,
    segments: []Segment,
    pub fn deinit(m: Mapped, allocator: Allocator) void {
        allocator.free(m.output);
        allocator.free(m.segments);
    }
};
pub const MappedResult = union(enum) {
    mapped: Mapped,
    diagnostic: Diagnostic,
    pub fn deinit(r: MappedResult, allocator: Allocator) void {
        switch (r) {
            .mapped => |m| m.deinit(allocator),
            .diagnostic => |d| allocator.free(d.message),
        }
    }
};

/// The result is owned by the caller. All intermediate allocations, including
/// failure paths, live in a compiler arena and are released before returning.
pub fn compile(allocator: Allocator, source: []const u8) !Result {
    return switch (try compileMapped(allocator, source)) {
        .diagnostic => |d| .{ .diagnostic = d },
        .mapped => |m| blk: {
            allocator.free(m.segments);
            break :blk .{ .output = m.output };
        },
    };
}

pub fn compileMapped(allocator: Allocator, source: []const u8) !MappedResult {
    return compileMappedWithPath(allocator, "<memory>", source);
}

/// `module_path` is the source path relative to the project/repository root.
/// Disk generators and diagnostic remappers must pass the same stable path.
pub fn compileMappedWithPath(allocator: Allocator, module_path: []const u8, source: []const u8) !MappedResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Control bytes for mapping markers; source containing them corrupts mapping, rejected
    // outright.
    if (std.mem.indexOfAny(u8, source, &.{ mark_open, mark_text, mark_close, mark_point, mark_component })) |at|
        return .{ .diagnostic = .{ .offset = at, .message = try allocator.dupe(u8, "control characters U+0001..U+0005 are not allowed in .yix files") } };
    const root = try a.dupeSentinel(u8, source, 0);
    var origins: List(Origin) = .empty;
    try origins.append(a, .{ .ptr = @intFromPtr(root.ptr), .len = root.len, .offset = 0 });
    var flow_seq: usize = 0;
    var p: Parser = .{ .a = a, .source = root, .module_path = module_path, .origins = &origins, .flow_seq = &flow_seq };
    const marked = p.file() catch |err| switch (err) {
        error.InvalidYix => {
            const d = p.diagnostic orelse Diagnostic{ .offset = p.absolute(p.pos), .message = "invalid Yix syntax" };
            // Messages may live in compile arena (parametric diagnostics): copy to caller.
            return .{ .diagnostic = .{ .offset = d.offset, .message = try allocator.dupe(u8, d.message) } };
        },
        error.OutOfMemory => return err,
    };
    var segments: List(Segment) = .empty;
    const out = try stripMarks(a, marked, &segments);
    const owned_out = try allocator.dupe(u8, out);
    errdefer allocator.free(owned_out);
    return .{ .mapped = .{ .output = owned_out, .segments = try allocator.dupe(Segment, segments.items) } };
}

// Mapping markers wrapped around copied source during generation:
//   mark_open <source offset decimal> mark_text <generated text> mark_close   -- byte-exact (exact)
//   mark_point <source offset decimal> mark_text <generated text> mark_close  -- span at source
//   point
//   mark_point <offset>+<length> mark_text <generated text> mark_close -- span replaces source
//   range
//   mark_component <source offset decimal> mark_text                    -- component start
//   (yix-map-data)
pub const mark_open: u8 = 1;
pub const mark_text: u8 = 2;
pub const mark_close: u8 = 3;
pub const mark_point: u8 = 4;
pub const mark_component: u8 = 5;

/// Source position in marker header: `<offset>` or `<offset>+<length>`.
fn markSource(header: []const u8) struct { source: usize, len: usize } {
    const plus = std.mem.indexOfScalar(u8, header, '+') orelse return .{ .source = std.fmt.parseInt(usize, header, 10) catch unreachable, .len = 0 };
    return .{ .source = std.fmt.parseInt(usize, header[0..plus], 10) catch unreachable, .len = std.fmt.parseInt(usize, header[plus + 1 ..], 10) catch unreachable };
}

/// Sub-parser source buffer's starting point in original file (sub-parser source copied, pointer
/// not in file).
const Origin = struct { ptr: usize, len: usize, offset: usize };

/// Strip markers, get final output and segment table; component starts written as yix-map-data
/// lines.
pub fn stripMarks(a: Allocator, marked: []const u8, segments: *List(Segment)) Error![]const u8 {
    var out: List(u8) = .empty;
    const Open = struct { generated: usize, source: usize, source_len: usize, exact: bool };
    var stack: List(Open) = .empty;
    var components: List(Mapping) = .empty;
    var i: usize = 0;
    while (i < marked.len) {
        const c = marked[i];
        if (c == mark_open or c == mark_point or c == mark_component) {
            const end = std.mem.indexOfScalarPos(u8, marked, i + 1, mark_text).?;
            const src = markSource(marked[i + 1 .. end]);
            if (c == mark_component) {
                try components.append(a, .{ .generated = out.items.len, .source = src.source });
            } else try stack.append(a, .{ .generated = out.items.len, .source = src.source, .source_len = src.len, .exact = c == mark_open });
            i = end + 1;
        } else if (c == mark_close) {
            const o = stack.pop().?;
            const len = out.items.len - o.generated;
            try segments.append(a, .{ .generated = o.generated, .generated_len = len, .source = o.source, .source_len = if (o.exact) len else o.source_len, .exact = o.exact });
            i += 1;
        } else {
            try out.append(a, c);
            i += 1;
        }
    }
    if (components.items.len != 0) {
        // Component mapping lines at end (golden depends on format): placed after stripping so
        // offsets are final output offsets.
        const tail_at = std.mem.lastIndexOf(u8, out.items, "\n//# yix-map-data [").?;
        out.shrinkRetainingCapacity(tail_at);
        try out.appendSlice(a, "\n//# yix-map-data [");
        for (components.items, 0..) |m, k| try out.appendSlice(a, try std.fmt.allocPrint(a, "{s}[{d},{d}]", .{ if (k == 0) "" else ",", m.generated, m.source }));
        try out.appendSlice(a, "]\n");
    }
    return out.items;
}

/// Source offset -> virtual doc offset: take minimal byte-exact span containing it; offset at
/// synthetic span's source point (or range it replaces) also counts.
pub fn srcToGen(segments: []const Segment, src: usize) ?usize {
    var best: ?Segment = null;
    for (segments) |s| {
        if (!s.exact) continue;
        // Span end also counts (completion/hover at identifier end must hit).
        if (src < s.source or src > s.source + s.source_len) continue;
        if (best == null or s.source_len < best.?.source_len) best = s;
    }
    if (best) |b| return b.generated + (src - b.source);
    for (segments) |s| {
        if (s.exact or src < s.source or src > s.source + s.source_len) continue;
        // Replacement spans (e.g., import string rewrite): shift by offset, clamp to generated
        // span.
        return s.generated + @min(src - s.source, s.generated_len -| 1);
    }
    return null;
}

/// Virtual doc offset -> source offset: minimal span containing it; byte-exact spans shift by
/// bytes, synthetic spans fall to their source point.
pub fn genToSrc(segments: []const Segment, gen: usize) ?usize {
    var best: ?Segment = null;
    for (segments) |s| {
        if (gen < s.generated or gen > s.generated + s.generated_len) continue;
        if (best == null or s.generated_len < best.?.generated_len) best = s;
    }
    const b = best orelse return null;
    return if (b.exact) b.source + (gen - b.generated) else b.source;
}

/// Position in synthetic code (diagnostics often land here): fall back to nearest preceding
/// segment's source point.
pub fn genToSrcNearest(segments: []const Segment, gen: usize) usize {
    if (genToSrc(segments, gen)) |s| return s;
    // Take span with end before gen, closest to it; land at span's end in source.
    var best: ?Segment = null;
    for (segments) |s| {
        const end = s.generated + s.generated_len;
        if (end > gen) continue;
        if (best == null or end > best.?.generated + best.?.generated_len) best = s;
    }
    return if (best) |b| b.source + (if (b.exact) b.source_len else 0) else 0;
}

/// Compile one source file by extension: `.yss` style recipe, otherwise Yix. Diagnostics: .yss
/// allocated by caller, Yix static strings.
pub fn compileSource(allocator: Allocator, path: []const u8, source: []const u8) !Result {
    return if (std.mem.endsWith(u8, path, ".yss")) style.compileWithPath(allocator, source, path) else switch (try compileMappedWithPath(allocator, path, source)) {
        .diagnostic => |d| .{ .diagnostic = d },
        .mapped => |m| blk: {
            allocator.free(m.segments);
            break :blk .{ .output = m.output };
        },
    };
}

/// Like compileSource, with position mapping (editor use).
pub fn compileMappedSource(allocator: Allocator, path: []const u8, source: []const u8) !MappedResult {
    return if (std.mem.endsWith(u8, path, ".yss")) style.compileMappedWithPath(allocator, source, path) else compileMappedWithPath(allocator, path, source);
}

/// Diagnostic offset -> 1-based line:col (col in bytes, matches zig error format).
pub fn lineColumn(source: []const u8, offset: usize) struct { line: usize, column: usize } {
    var line: usize = 1;
    var column: usize = 1;
    for (source[0..@min(offset, source.len)]) |c| {
        if (c == '\n') {
            line += 1;
            column = 1;
        } else column += 1;
    }
    return .{ .line = line, .column = column };
}

/// Each source (.yix/.yss) gets a generated twin: `_` + name + `.zig` (card.yix -> _card.yix.zig).
/// Hand-written code imports twin directly, no rewriting. Naming rule centralized here:
/// CLI generation, check-yix, yix-lsp all use it.
pub const source_exts = [_][]const u8{ ".yss", ".yix" };

/// Host element properties (Yix camelCase) -- Yix language's host definition, compiler reports
/// unknown
/// attrs at .yix source positions, yix-lsp completes. 1:1 with view.zig box_props / grid_props /
/// text_props / icon_props (tests/yix/compiler_tests.zig reads view.zig, test fails if either side
/// changes).
pub const HostAttr = struct { name: []const u8, doc: []const u8 };

const attr_style: HostAttr = .{ .name = "style", .doc = "视觉样式：ui.css / cva / sva 部件、样式函数或字面量" };
const attr_test_id: HostAttr = .{ .name = "testId", .doc = "e2e / DevTools 用的 test_id（可为源，挂载时取值）" };
const attr_a11y: HostAttr = .{ .name = "a11y", .doc = "无障碍属性；字段可为响应式源，也可整体是 Source(?A11yProps)" };
const attr_on_click: HostAttr = .{ .name = "onClick", .doc = "点击（Space / Enter 在焦点节点上合成 click）" };
const attr_visible: HostAttr = .{ .name = "visible", .doc = "bool 或 bool 源：切 display，保留子树与状态" };
const attr_hit_test: HostAttr = .{ .name = "hitTest", .doc = "false：不参与命中（点击穿透）" };

pub const box_attrs = [_]HostAttr{
    .{ .name = "windowRegion", .doc = "自绘窗口外框时该区域的系统含义（.drag 拖动窗口、.resize_* 缩放、.minimize / .maximize / .close 标题栏按钮）" },
    attr_style,
    attr_test_id,
    attr_a11y,
    attr_on_click,
    attr_visible,
    .{ .name = "focusable", .doc = "bool 或 bool 源：进出 Tab 序" },
    .{ .name = "focusRing", .doc = "获得键盘焦点时画焦点环" },
    attr_hit_test,
    .{ .name = "onFocus", .doc = "获得焦点" },
    .{ .name = "onBlur", .doc = "失去焦点" },
    .{ .name = "onHover", .doc = "指针进入" },
    .{ .name = "onLeave", .doc = "指针离开" },
    .{ .name = "tag", .doc = "语义 tag（.button / .input …）：命中、a11y 与键盘激活按 tag 区分" },
    .{ .name = "onEvent", .doc = "底层通用事件回调（GenericEventCallback）；可为源" },
    .{ .name = "eventContext", .doc = "onEvent 的上下文；可为源" },
    .{ .name = "state", .doc = "样式条件 :disabled / :invalid / :selected / :expanded 的状态源：.{ .disabled = 源, … }（没写时取 a11y 同名字段）" },
    .{ .name = "onKeyDown", .doc = "按键按下：|e| 是 ui.view.KeyPress（key / modifiers）；e.consume() 阻止默认行为，e.stop() 再停止传播" },
    .{ .name = "onKeyUp", .doc = "按键抬起：|e| 是 ui.view.KeyPress" },
    .{ .name = "onPointerDown", .doc = "指针按下：|e| 是 ui.view.Pointer（x / y 是元素内坐标，button / modifiers）" },
    .{ .name = "onPointerMove", .doc = "指针移动：|e| 是 ui.view.Pointer（带 dx / dy）；按下后继续发给按下的元素" },
    .{ .name = "onPointerUp", .doc = "指针抬起：|e| 是 ui.view.Pointer" },
    .{ .name = "onScroll", .doc = "滚轮 / 触控板滚动：|e| 是 ui.view.Scroll（dx / dy / phase / momentum）" },
};
pub const grid_attrs = box_attrs ++ [_]HostAttr{
    .{ .name = "columns", .doc = "grid：列轨道" },
    .{ .name = "rows", .doc = "grid：行轨道" },
    .{ .name = "columnGap", .doc = "grid：列间距" },
    .{ .name = "rowGap", .doc = "grid：行间距" },
};
pub const text_attrs = [_]HostAttr{ attr_style, .{ .name = "box", .doc = "text：文本节点自身的盒样式（节点自己承载文字）" }, attr_test_id, attr_a11y, attr_on_click, attr_visible, attr_hit_test };
pub const media_attrs = [_]HostAttr{ attr_style, .{ .name = "tint", .doc = "icon / image：着色（Color、主题函数或 ui.view.tintBy）" }, attr_test_id, attr_a11y, attr_on_click, attr_visible, attr_hit_test };
/// Host element attributes collected by position (not into props).
pub const media_src: HostAttr = .{ .name = "src", .doc = "icon：SVG 资源（ui.icons.*）；image：纹理 id。可为 prop，挂载时取值" };
pub const canvas_extra = [_]HostAttr{
    .{ .name = "draw", .doc = "canvas：绘制函数 fn (DrawContext, Data, ui.view.Frame) !void" },
    .{ .name = "data", .doc = "canvas：传给绘制函数的值或源（变化时重绘）" },
    .{ .name = "animate", .doc = "canvas：bool 或 bool 源，开着时每帧重绘（视口外不画）" },
};
pub const host_tags = [_][]const u8{ "box", "row", "col", "grid", "text", "icon", "image", "canvas", "spacer" };

/// Host tag's props-part attributes (icon/image src, canvas draw/data/animate separate); non-host
/// returns null.
pub fn hostAttrs(tag: []const u8) ?[]const HostAttr {
    if (std.mem.eql(u8, tag, "box") or std.mem.eql(u8, tag, "row") or std.mem.eql(u8, tag, "col") or std.mem.eql(u8, tag, "canvas")) return &box_attrs;
    if (std.mem.eql(u8, tag, "grid")) return &grid_attrs;
    if (std.mem.eql(u8, tag, "text")) return &text_attrs;
    if (std.mem.eql(u8, tag, "icon") or std.mem.eql(u8, tag, "image")) return &media_attrs;
    if (std.mem.eql(u8, tag, "spacer")) return &.{};
    return null;
}

/// Typo attr name: nearest with edit distance <= 2.
fn nearestAttr(attrs: []const HostAttr, name: []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_d: usize = 3;
    for (attrs) |at| {
        const d = editDistance(name, at.name);
        if (d < best_d) {
            best_d = d;
            best = at.name;
        }
    }
    return best;
}

/// `Name(T)` form built-in types (whole init is one call): return `T`.
fn builtinCall(ty: []const u8, comptime name: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, ty, name ++ "(") or ty[ty.len - 1] != ')') return null;
    return trim(ty[name.len + 1 .. ty.len - 1]);
}

/// camelCase form of name: `icon_only` -> `iconOnly`, `testID` -> `testId`, `onURLChange` ->
/// `onUrlChange`;
/// already compliant unchanged.
pub fn camelOf(a: std.mem.Allocator, name: []const u8) std.mem.Allocator.Error![]const u8 {
    // Single-pass rewrite creates adjacent caps (`a_bC` -> `aBC`), iterate to fixpoint,
    // ensure suggestion passes its own check.
    var cur = name;
    for (0..8) |_| {
        const next = try camelPass(a, cur);
        if (eq(next, cur)) return cur;
        cur = next;
    }
    return cur;
}

fn camelPass(a: std.mem.Allocator, name: []const u8) std.mem.Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var upper_next = false;
    for (name, 0..) |c, i| {
        if (c == '_') {
            upper_next = out.items.len != 0;
            continue;
        }
        if (upper_next) {
            try out.append(a, std.ascii.toUpper(c));
            upper_next = false;
            continue;
        }
        // Consecutive caps (abbreviation): except first and "followed by lowercase, start next
        // word"
        // rest downcase.
        const prev_upper = i > 0 and std.ascii.isUpper(name[i - 1]);
        const next_lower = i + 1 < name.len and std.ascii.isLower(name[i + 1]);
        if (std.ascii.isUpper(c) and (out.items.len == 0 or (prev_upper and !next_lower))) {
            try out.append(a, std.ascii.toLower(c));
            continue;
        }
        try out.append(a, c);
    }
    return out.items;
}

fn editDistance(a: []const u8, b: []const u8) usize {
    if (b.len > 63) return 99;
    var prev: [64]usize = undefined;
    for (prev[0 .. b.len + 1], 0..) |*x, j| x.* = j;
    for (a, 0..) |ca, i| {
        var cur: [64]usize = undefined;
        cur[0] = i + 1;
        for (b, 0..) |cb, j| cur[j + 1] = @min(prev[j] + @intFromBool(ca != cb), @min(prev[j + 1] + 1, cur[j] + 1));
        @memcpy(prev[0 .. b.len + 1], cur[0 .. b.len + 1]);
    }
    return prev[b.len];
}

/// Copy Zig source span (`src_offset` start in original file), write with mapping markers.
/// Inside, `@import("x.yss")` / `@import("x.yix")` become twin names (`_x.yss.zig`):
/// .yix/.yss reference source names, Zig only knows .zig, compiler rewrites at generation.
/// Replaced string recorded as synthetic span pointing to source string, rest byte-exact as usual.
pub fn markZig(a: Allocator, out: *std.ArrayList(u8), text: []const u8, src_offset: usize) Allocator.Error!void {
    if (text.len == 0) return;
    const z = try a.dupeSentinel(u8, text, 0);
    var tz = std.zig.Tokenizer.init(z);
    var builtin_import = false;
    var after_paren = false;
    var at: usize = 0;
    while (true) {
        const t = tz.next();
        if (t.tag == .eof) break;
        if (t.tag == .string_literal and after_paren) {
            const body = text[t.loc.start + 1 .. t.loc.end - 1];
            for (source_exts) |ext| if (body.len > ext.len and std.mem.endsWith(u8, body, ext)) {
                if (t.loc.start > at) try out.print(a, "{c}{d}{c}{s}{c}", .{ mark_open, src_offset + at, mark_text, text[at..t.loc.start], mark_close });
                try out.print(a, "{c}{d}+{d}{c}\"{s}\"{c}", .{ mark_point, src_offset + t.loc.start, t.loc.end - t.loc.start, mark_text, try twinPath(a, body), mark_close });
                at = t.loc.end;
                break;
            };
        }
        after_paren = builtin_import and t.tag == .l_paren;
        builtin_import = t.tag == .builtin and std.mem.eql(u8, text[t.loc.start..t.loc.end], "@import");
    }
    if (at < text.len) try out.print(a, "{c}{d}{c}{s}{c}", .{ mark_open, src_offset + at, mark_text, text[at..], mark_close });
}

/// Source path -> twin path.
pub fn twinPath(a: Allocator, path: []const u8) ![]u8 {
    const base = std.fs.path.basename(path);
    return std.fmt.allocPrint(a, "{s}_{s}.zig", .{ path[0 .. path.len - base.len], base });
}

/// Twin path -> source path (null if not twin).
pub fn sourceOfTwin(a: Allocator, path: []const u8) !?[]u8 {
    const base = std.fs.path.basename(path);
    if (base.len < 2 or base[0] != '_' or !std.mem.endsWith(u8, base, ".zig")) return null;
    const src_base = base[1 .. base.len - ".zig".len];
    for (source_exts) |ext| if (std.mem.endsWith(u8, src_base, ext) and src_base.len > ext.len)
        return try std.fmt.allocPrint(a, "{s}{s}", .{ path[0 .. path.len - base.len], src_base });
    return null;
}

/// Twin file content: header line + compiler raw output (unformatted: editor uses compiler segment
/// table
/// to map positions) + source line. Result owned by a.
pub fn twinText(a: Allocator, source_path: []const u8, output: []const u8) ![]u8 {
    const base = std.fs.path.basename(source_path);
    return std.fmt.allocPrint(a, "{s}generated from {s}; after editing the source run `zig build gen-yix` (yix-lsp regenerates it on save).\n{s}\n//# yix-map {s}\n", .{ twin_header_prefix, base, output, base });
}

/// Fixed prefix of twin first line; `twinOutputStart` uses it to strip header and recover compiler
/// output.
pub const twin_header_prefix = "// GENERATED FILE, do not edit: ";

/// Twin content -> compiler output span in file (after header); null if not twin format.
pub fn twinOutputStart(text: []const u8) ?usize {
    if (!std.mem.startsWith(u8, text, twin_header_prefix)) return null;
    const nl = std.mem.indexOfScalar(u8, text, '\n') orelse return null;
    return nl + 1;
}

/// `source`: value is `ui.Source(T)` (component args, computed depending only on args), may be
/// static at runtime.
const Symbol = struct { name: []const u8, reactive: bool, writable: bool = false, source: bool = false, handler: bool = false, model: bool = false };
const Mapping = struct { generated: usize, source: usize };
const Parser = struct {
    a: Allocator,
    source: [:0]const u8,
    module_path: []const u8 = "<memory>",
    preview: ?*PreviewCollector = null,
    catalog_prefixes: ?*List([]const u8) = null,
    /// All source buffers (original + sub-parser copies) positions in original, shared by whole
    /// parser tree.
    origins: *List(Origin),
    /// Control flow (if/switch/for) index in component: generated branch functions / param names
    /// use it
    /// (not source offset -- twin in repo, upstream line change shouldn't rename downstream
    /// branches).
    /// Sub-parsers share counter, reset at component start.
    flow_seq: *usize,
    template_path: []const u8 = "",
    pos: usize = 0,
    diagnostic: ?Diagnostic = null,
    symbols: List(Symbol) = .empty,
    mappings: List(Mapping) = .empty,
    depth: usize = 0,
    loop_depth: usize = 0,
    /// Currently parsing for directly nested in branch: following else ambiguous (for empty-list
    /// fallback vs outer
    /// if else), reject all.
    for_in_branch: bool = false,
    /// Component declared `children: View`: template `{children}` marks slot node.
    slotted: bool = false,
    /// Component's slot names (`View` param: `children` default, others named).
    slot_names: []const []const u8 = &.{},
    slots_used: List([]const u8) = .empty,
    /// `?View` slots: built only when the caller fills them, via `{if (name) <box>…{name}…</box>}`.
    optional_slots: []const []const u8 = &.{},
    /// Optional slot whose `{if (name) …}` guard is being parsed (its `{name}` is allowed here).
    slot_guard: ?[]const u8 = null,
    /// Slot in control flow branch forbidden (slot nodes determined at mount).
    in_branch: bool = false,
    /// Derived-value block label index (`__yix_d<n>:`, unique in component).
    derive_seq: usize = 0,
    /// Component attr being compiled (tag name, snake field): derived values type by it.
    attr_target: ?struct { tag: []const u8, field: []const u8 } = null,
    /// Count of component Model params (when one, onChange defaults to it).
    model_count: usize = 0,
    /// Collecting root element `key={...}` while parsing `{for}` line.
    row_key: ?*?[]const u8 = null,
    /// Event attr name being compiled (error location in handler try failure).
    event_name: []const u8 = "event",
    /// In effect, reads track dependencies (`.get()`); in event handler, not (`.peek()`).
    track_reads: bool = false,
    /// Signals read and written in effect (same signal read+written = every write re-runs it).
    effect_reads: List([]const u8) = .empty,
    effect_writes: List([]const u8) = .empty,
    /// onMount statement: runs after root node mount (ref available when accessed).
    mount_code: List(u8) = .empty,
    preview_setup_safe: bool = true,
    /// View hooks belong to the repeatable template, not instance setup.
    view_attach_code: List(u8) = .empty,
    view_detach_code: List(u8) = .empty,

    fn fail(p: *Parser, offset: usize, comptime message: []const u8) Error {
        p.diagnostic = .{ .offset = p.absolute(offset), .message = message };
        return error.InvalidYix;
    }
    /// Parametric diagnostic (message in compile arena, copied to caller before compileMapped
    /// return).
    /// `offset` already source offset.
    fn failFmt(p: *Parser, offset: usize, comptime template: []const u8, args: anytype) Error {
        p.diagnostic = .{ .offset = offset, .message = try std.fmt.allocPrint(p.a, template, args) };
        return error.InvalidYix;
    }
    /// Offset in this parser's source -> original file offset.
    fn absolute(p: *Parser, offset: usize) usize {
        return p.originAt(@intFromPtr(p.source.ptr) + @min(offset, p.source.len)) orelse offset;
    }
    fn originAt(p: *Parser, addr: usize) ?usize {
        // Later-registered buffers more specific (nested sub-parsers), search backward.
        var k = p.origins.items.len;
        while (k > 0) {
            k -= 1;
            const o = p.origins.items[k];
            if (addr >= o.ptr and addr <= o.ptr + o.len) return o.offset + (addr - o.ptr);
        }
        return null;
    }
    fn originOf(p: *Parser, s: []const u8) ?usize {
        if (s.len == 0) return null;
        return p.originAt(@intFromPtr(s.ptr));
    }
    /// Copy source span (for sub-parser/tokenizer), register its position in original file.
    fn dup(p: *Parser, s: []const u8) Error![:0]const u8 {
        const d = try p.a.dupeSentinel(u8, s, 0);
        if (p.originOf(s)) |o| try p.origins.append(p.a, .{ .ptr = @intFromPtr(d.ptr), .len = d.len, .offset = o });
        return d;
    }
    /// Copied source: wrap with byte-exact mapping markers.
    fn mark(p: *Parser, s: []const u8) Error![]const u8 {
        const o = p.originOf(s) orelse return s;
        return p.fmt("{c}{d}{c}{s}{c}", .{ mark_open, o, mark_text, s, mark_close });
    }
    /// Copied Zig source: @import of source filenames become twin names (see markZig).
    fn markZigSrc(p: *Parser, s: []const u8) Error![]const u8 {
        const o = p.originOf(s) orelse return s;
        var out: List(u8) = .empty;
        try markZig(p.a, &out, s, o);
        return out.items;
    }
    /// Synthetic code: entire span maps to source at `at` point.
    fn markPoint(p: *Parser, at: []const u8, generated: []const u8) Error![]const u8 {
        const o = p.originOf(at) orelse return generated;
        return p.fmt("{c}{d}{c}{s}{c}", .{ mark_point, o, mark_text, generated, mark_close });
    }
    fn fmt(p: *Parser, comptime f: []const u8, args: anytype) Error![]const u8 {
        return std.fmt.allocPrint(p.a, f, args);
    }
    fn add(p: *Parser, buf: *List(u8), s: []const u8) Error!void {
        try buf.appendSlice(p.a, s);
    }
    fn token(p: *Parser) Token {
        var z = std.zig.Tokenizer.init(p.source[p.pos..]);
        var t = z.next();
        t.loc.start += p.pos;
        t.loc.end += p.pos;
        return t;
    }
    fn take(p: *Parser) Token {
        const t = p.token();
        p.pos = t.loc.end;
        return t;
    }
    fn word(p: *Parser, t: Token) []const u8 {
        return p.source[t.loc.start..t.loc.end];
    }
    fn eat(p: *Parser, tag: Token.Tag) bool {
        if (p.token().tag != tag) return false;
        _ = p.take();
        return true;
    }
    fn expect(p: *Parser, tag: Token.Tag) Error!Token {
        const t = p.take();
        if (t.tag != tag) return p.fail(t.loc.start, "unexpected token");
        return t;
    }
    fn balanced(p: *Parser, open: Token.Tag, close: Token.Tag) Error![]const u8 {
        const first = try p.expect(open);
        var count: usize = 1;
        var previous: Token.Tag = open;
        while (true) {
            const next = p.token();
            if (next.tag == .angle_bracket_left and previous != .identifier and previous != .number_literal and
                next.loc.end < p.source.len and std.ascii.isAlphabetic(p.source[next.loc.end]))
            {
                try p.skipElement();
                previous = .r_brace;
                continue;
            }
            const t = p.take();
            if (t.tag == .eof or t.tag == .invalid) return p.fail(t.loc.start, "unterminated Zig expression");
            if (t.tag == open) count += 1;
            if (t.tag == close) count -= 1;
            if (count == 0) return p.source[first.loc.end..t.loc.start];
            previous = t.tag;
        }
    }
    /// Skip tags inside a Zig island without sending their raw text through
    /// Zig's tokenizer (apostrophes and UTF-8 text are valid template content).
    fn skipElement(p: *Parser) Error!void {
        p.depth += 1;
        defer p.depth -= 1;
        if (p.depth > 128) return p.fail(p.pos, "template nesting exceeds 128");
        _ = try p.expect(.angle_bracket_left);
        _ = try p.expect(.identifier);
        while (true) {
            const t = p.token();
            if (t.tag == .eof) return p.fail(p.pos, "unclosed tag");
            if (t.tag == .l_brace) {
                _ = try p.balanced(.l_brace, .r_brace);
                continue;
            }
            if (p.eat(.slash)) {
                _ = try p.expect(.angle_bracket_right);
                return;
            }
            if (p.eat(.angle_bracket_right)) break;
            _ = p.take();
        }
        while (p.pos < p.source.len) {
            if (std.mem.startsWith(u8, p.source[p.pos..], "</")) {
                p.pos += 2;
                while (p.pos < p.source.len and p.source[p.pos] != '>') p.pos += 1;
                if (p.pos == p.source.len) return p.fail(p.pos, "unclosed tag");
                p.pos += 1;
                return;
            }
            if (p.source[p.pos] == '<') {
                try p.skipElement();
                continue;
            }
            if (p.source[p.pos] == '{') {
                _ = try p.balanced(.l_brace, .r_brace);
                continue;
            }
            p.pos += 1;
        }
        return p.fail(p.pos, "unclosed tag");
    }
    fn spanTo(p: *Parser, end: Token.Tag) Error![]const u8 {
        const start = p.token().loc.start;
        var stack: List(Token.Tag) = .empty;
        while (true) {
            const t = p.token();
            if (stack.items.len == 0 and t.tag == end) return trim(p.source[start..t.loc.start]);
            if (t.tag == .eof or t.tag == .invalid) return p.fail(t.loc.start, "unterminated declaration");
            _ = p.take();
            const closer: ?Token.Tag = switch (t.tag) {
                .l_paren => .r_paren,
                .l_brace => .r_brace,
                .l_bracket => .r_bracket,
                else => null,
            };
            if (closer) |c| try stack.append(p.a, c) else switch (t.tag) {
                .r_paren, .r_brace, .r_bracket => {
                    if (stack.items.len == 0 or stack.pop().? != t.tag) return p.fail(t.loc.start, "unbalanced Zig expression");
                },
                else => {},
            }
        }
    }
    fn lookup(p: *Parser, name: []const u8) ?Symbol {
        var i = p.symbols.items.len;
        while (i > 0) {
            i -= 1;
            if (eq(p.symbols.items[i].name, name)) return p.symbols.items[i];
        }
        return null;
    }
    fn declare(p: *Parser, s: Symbol) Error!void {
        if (p.lookup(s.name) != null) return p.fail(p.pos, "shadowed local names are not supported yet");
        if (std.mem.startsWith(u8, s.name, "__yix_")) return p.fail(p.pos, "names starting with __yix_ are reserved");
        if (eq(s.name, "cx") or eq(s.name, "scope")) return p.failFmt(p.absolute(p.pos), "`{s}` is reserved in a Yix component (the generated component function uses it); pick another name", .{s.name});
        try p.symbols.append(p.a, s);
    }
    fn deps(p: *Parser, expr: []const u8) Error![]Symbol {
        var out: List(Symbol) = .empty;
        var z = std.zig.Tokenizer.init(try p.a.dupeSentinel(u8, expr, 0));
        var previous: Token.Tag = .eof;
        while (true) {
            const t = z.next();
            if (t.tag == .eof) break;
            if (t.tag == .identifier and previous != .period) {
                if (p.lookup(expr[t.loc.start..t.loc.end])) |s| {
                    var found = false;
                    for (out.items) |o| if (eq(o.name, s.name)) {
                        found = true;
                        break;
                    };
                    if (!found) try out.append(p.a, s);
                }
            }
            previous = t.tag;
        }
        return out.items;
    }
    fn reactive(p: *Parser, expr: []const u8) Error!bool {
        for (try p.deps(expr)) |s| if (s.reactive) return true;
        return false;
    }
    /// Component can't directly use `cx`/`scope` from generated function: Yix is declarative,
    /// imperative parts written as normal Zig components then used as tags.
    fn rejectEnv(p: *Parser, text: []const u8) Error!void {
        var z = std.zig.Tokenizer.init(try p.a.dupeSentinel(u8, text, 0));
        var previous: Token.Tag = .eof;
        while (true) {
            const t = z.next();
            if (t.tag == .eof) return;
            const name = text[t.loc.start..t.loc.end];
            if (t.tag == .identifier and previous != .period and (eq(name, "cx") or eq(name, "scope")))
                return p.failFmt(p.absolute(p.pos), "`{s}` is not available in a Yix component; write the imperative part as an ordinary Zig component — fn (props, *ui.Scope, *ui.Cx) !*ui.Node wrapped with ui.view.component — and use it as a tag", .{name});
            previous = t.tag;
        }
    }
    fn context(p: *Parser, ds: []const Symbol, owner: bool) Error![]const u8 {
        var out: List(u8) = .empty;
        try p.add(&out, ".{");
        for (ds) |s| try p.add(&out, try p.fmt(" .{s} = {s},", .{ s.name, s.name }));
        if (owner) try p.add(&out, " .__yix_owner = scope.owner,");
        try p.add(&out, " }");
        return out.items;
    }
    /// Outer names actually used by branch/row function: find `<context_param>.<name>` in generated
    /// function body (all references to outer names rewritten this way).
    /// Capture only these -- full capture copies all component props/derived (Button 4KB+) into
    /// each branch.
    fn usedCaptures(p: *Parser, captured: []const Symbol, bodies: []const []const u8, ctx_names: []const []const u8) Error![]Symbol {
        var used = try p.a.alloc(bool, captured.len);
        @memset(used, false);
        for (bodies) |code| {
            const text = try plain(p.a, code);
            var z = std.zig.Tokenizer.init(try p.a.dupeSentinel(u8, text, 0));
            var t0 = z.next();
            var t1 = z.next();
            while (t0.tag != .eof) {
                const t2 = z.next();
                if (t0.tag == .identifier and t1.tag == .period and t2.tag == .identifier) {
                    const base = text[t0.loc.start..t0.loc.end];
                    for (ctx_names) |c| if (eq(base, c)) {
                        const field = text[t2.loc.start..t2.loc.end];
                        for (captured, 0..) |sym, k| if (eq(sym.name, field)) {
                            used[k] = true;
                        };
                    };
                }
                t0 = t1;
                t1 = t2;
            }
        }
        var out: List(Symbol) = .empty;
        for (captured, used) |sym, u| if (u) try out.append(p.a, sym);
        return out.items;
    }
    fn rewrite(p: *Parser, expr: []const u8, ctx: bool, tracked: bool) Error![]const u8 {
        try p.rejectEnv(expr);
        var out: List(u8) = .empty;
        var z = std.zig.Tokenizer.init(try p.dup(expr));
        var previous: Token.Tag = .eof;
        var at: usize = 0;
        while (true) {
            const t = z.next();
            if (t.tag == .eof) break;
            try p.add(&out, expr[at..t.loc.start]);
            const name = expr[t.loc.start..t.loc.end];
            if (t.tag == .identifier and previous != .period and p.lookup(name) != null) {
                const s = p.lookup(name).?;
                if (ctx) try p.add(&out, "__yix_ctx.");
                try p.add(&out, try p.mark(name));
                if (s.reactive) try p.add(&out, if (tracked) ".get()" else ".peek()");
                if (s.reactive and tracked and p.track_reads) try p.effect_reads.append(p.a, s.name);
            } else try p.add(&out, try p.mark(name));
            at = t.loc.end;
            previous = t.tag;
        }
        try p.add(&out, expr[at..]);
        return out.items;
    }
    fn memo(p: *Parser, expr: []const u8, ty: ?[]const u8) Error![]const u8 {
        return p.reactiveCall("createMemo", expr, ty);
    }
    /// `try scope.<ctor>(T, ctx, compute)`: createMemo (*Memo) or derive (Source, static at
    /// runtime).
    fn reactiveCall(p: *Parser, ctor: []const u8, expr: []const u8, ty: ?[]const u8) Error![]const u8 {
        const ds = try p.deps(expr);
        const ctx = try p.context(ds, false);
        var out_ty = ty orelse try p.fmt("@TypeOf({s})", .{try p.rewrite(expr, false, false)});
        // Component attr: type by attr receiver's type (enum literals, string literal branches have
        // fixed type),
        // else infer from expr.
        if (ty == null) if (p.attr_target) |at| {
            out_ty = try p.fmt("if (ui.view.attrType({s}, \"{s}\")) |__yix_A| __yix_A else {s}", .{ at.tag, at.field, out_ty });
        };
        // Type inferred once: stored as block's comptime constant, function return type uses it
        // directly
        // (nested fns can reference outer comptime-known constants).
        p.derive_seq += 1;
        const label = try p.fmt("__yix_d{d}", .{p.derive_seq});
        return p.fmt("{s}: {{\n        const __yix_T = {s};\n        break :{s} try scope.{s}(__yix_T, {s}, struct {{ fn __yix_compute(__yix_ctx: anytype) __yix_T {{\n            {s}return {s};\n        }} }}.__yix_compute);\n    }}", .{ label, out_ty, label, ctor, ctx, if (ds.len == 0) "_ = __yix_ctx;\n            " else "", try p.rewrite(expr, true, true) });
    }
    /// Depends only on Source type names (params and derived): static vs not determined at runtime.
    fn liftable(p: *Parser, expr: []const u8) Error!bool {
        var any = false;
        for (try p.deps(expr)) |s| {
            if (!s.reactive) continue;
            if (!s.source) return false;
            any = true;
        }
        return any;
    }
    /// Depends only on params (Source): static-lift at runtime (`scope.derive`) -- build memo
    /// evaluate once,
    /// if no dependencies recorded collapse to static Source (matches hand-written "static props
    /// zero
    /// memo/effect"), else keep memo. Dependencies per reactive graph's actual reads; function call
    /// reading external signals counts (prior name-based would miss, static param external store
    /// never updates).
    fn sourceComputed(p: *Parser, expr: []const u8, ty: ?[]const u8) Error![]const u8 {
        return p.reactiveCall("derive", expr, ty);
    }
    /// Component attr expr: derived by `ui.view.attrType(tag, field)`.
    fn attrExpression(p: *Parser, expr: []const u8, tag: []const u8, field: []const u8) Error![]const u8 {
        const saved = p.attr_target;
        p.attr_target = .{ .tag = tag, .field = field };
        defer p.attr_target = saved;
        return p.expression(expr);
    }
    fn expression(p: *Parser, expr: []const u8) Error![]const u8 {
        const s = trim(expr);
        try p.rejectEnv(s);
        try p.requireSimpleExpression(s);
        if (p.lookup(s)) |_| return p.mark(s); // pass a whole source, without reading it
        // Depends only on Source type names like computed: static deps give value directly (static
        // props
        // zero memo), else build memo.
        if (try p.reactive(s)) return if (try p.liftable(s)) p.sourceComputed(s, null) else p.memo(s, null);
        // A call may read an external store even without mentioning component sources.
        // Probe its actual reads, while preserving calls that return a source or a
        // comptime-only value (those must still be passed through to the receiver).
        if (try p.hasCall(s)) {
            const raw = try p.mark(s);
            const derived = try p.sourceComputed(s, null);
            p.derive_seq += 1;
            const label = try p.fmt("__yix_call{d}", .{p.derive_seq});
            return p.fmt("{s}: {{\n        const __yix_Raw = @TypeOf({s});\n        break :{s} if (comptime !ui.view.yixCallMayDerive(__yix_Raw)) {s} else {s};\n    }}", .{ label, raw, label, raw, derived });
        }
        return p.mark(s);
    }

    fn hasCall(p: *Parser, expr: []const u8) Error!bool {
        var z = std.zig.Tokenizer.init(try p.dup(expr));
        var previous: Token.Tag = .eof;
        while (true) {
            const t = z.next();
            if (t.tag == .eof) return false;
            if (t.tag == .l_paren and (previous == .identifier or previous == .builtin or previous == .r_paren or previous == .r_bracket)) return true;
            previous = t.tag;
        }
    }

    // One component-local symbol table. Reject Zig islands introducing
    // lexical bindings rather than accidentally rewriting a shadowed name.
    fn requireSimpleExpression(p: *Parser, expr: []const u8) Error!void {
        var z = std.zig.Tokenizer.init(try p.a.dupeSentinel(u8, expr, 0));
        var previous: Token.Tag = .eof;
        while (true) {
            const t = z.next();
            switch (t.tag) {
                .eof => return,
                // Declarations appear only at statement boundary (expr start, after `{` `}` `;`);
                // const/fn in
                // `[]const u8`, `*align(4) const T`, `*const fn () void` part of type.
                .keyword_const, .keyword_var, .keyword_fn => switch (previous) {
                    .eof, .l_brace, .r_brace, .semicolon, .keyword_pub, .keyword_comptime, .keyword_inline, .keyword_export, .keyword_extern => return p.fail(p.pos, "expression-local bindings and captures are not implemented"),
                    else => {},
                },
                .keyword_for, .keyword_while => return p.fail(p.pos, "expression-local bindings and captures are not implemented"),
                // Binding: `if (x) |v|`, `else |e|`, `catch |e|`, `=> |v|` (bitwise-or `a | b`
                // before is value, not rejected).
                .pipe => if (previous == .eof or previous == .r_paren or previous == .keyword_else or previous == .keyword_catch or previous == .equal_angle_bracket_right)
                    return p.fail(p.pos, "expression-local bindings and captures are not implemented"),
                else => {},
            }
            previous = t.tag;
        }
    }

    fn file(p: *Parser) Error![]const u8 {
        try p.rejectBuiltinShadowing();
        var out: List(u8) = .empty;
        var at: usize = 0;
        var catalog_source: List(u8) = .empty;
        var catalog_prefixes: List([]const u8) = .empty;
        p.catalog_prefixes = &catalog_prefixes;
        while (p.token().tag != .eof) {
            const t = p.take();
            if (t.tag != .keyword_fn) continue;
            const save = p.pos;
            const name_t = p.take();
            if (name_t.tag != .identifier or p.token().tag != .l_paren) {
                p.pos = save;
                continue;
            }
            const params = try p.balanced(.l_paren, .r_paren);
            if (!eq(p.word(p.token()), "View")) continue;
            _ = p.take();
            _ = try p.expect(.l_brace);
            try p.add(&catalog_source, p.source[at..t.loc.start]);
            try p.add(&out, try p.markZigSrc(p.source[at..t.loc.start]));
            try p.add(&out, try p.fmt("{c}{d}{c}", .{ mark_component, t.loc.start, mark_text }));
            try p.mappings.append(p.a, .{ .generated = 0, .source = t.loc.start });
            // Public component props types also public (caller can name a prop set, store, pass
            // again).
            const is_pub = std.mem.endsWith(u8, std.mem.trimEnd(u8, p.source[at..t.loc.start], " \t\r\n"), "pub");
            try p.add(&out, try p.component(p.word(name_t), params, is_pub));
            at = p.pos;
        }
        try p.add(&catalog_source, p.source[at..]);
        try p.add(&out, try p.markZigSrc(p.source[at..]));
        if (p.mappings.items.len == 0) return out.items;
        if (!eq(p.module_path, "<memory>") and p.preview == null) {
            // A translated module may live alone in a build cache. Keep one
            // exact baseline in the generated module instead of requiring a
            // neighboring source file. Hex escapes cannot masquerade as copied
            // Zig or source-map markers. The release branch never embeds bytes.
            try p.add(&out, "\nconst __yix_preview_source: ?[]const u8 = if (ui.view.template.preview_enabled) \"");
            const hex = "0123456789abcdef";
            for (p.source) |byte| {
                try p.add(&out, "\\x");
                try out.append(p.a, hex[byte >> 4]);
                try out.append(p.a, hex[byte & 15]);
            }
            try p.add(&out, "\" else null;\n");
            try p.add(&out, "const __YixStyleCatalog = if (ui.view.template.preview_enabled) ui.view.template.styleCatalog(.{");
            try p.catalogRoots(&out, catalog_source.items, "");
            try p.add(&out, " }) else void;\n");
        }
        // Component mapping line rewritten by stripMarks with post-strip offset.
        try p.add(&out, "\n//# yix-map-data []\n");
        return out.items;
    }
    /// Enumerate private declarations in authored namespaces too: Zig reflection
    /// deliberately exposes only public decls. Imported namespaces use the typed
    /// collector because their private names cannot be referenced by this module.
    fn catalogRoots(p: *Parser, out: *List(u8), raw: []const u8, prefix: []const u8) Error!void {
        const bytes = try p.a.dupeSentinel(u8, raw, 0);
        var z = std.zig.Tokenizer.init(bytes);
        var depth: usize = 0;
        var previous: Token.Tag = .eof;
        while (true) {
            const tok = z.next();
            const prior = previous;
            previous = tok.tag;
            if (tok.tag == .eof) break;
            if (tok.tag == .l_brace) depth += 1;
            if (tok.tag == .r_brace) depth -= 1;
            if (depth != 0 or tok.tag != .keyword_const) continue;
            if (prior != .eof and prior != .semicolon and prior != .comma and prior != .keyword_pub and prior != .doc_comment and prior != .container_doc_comment) continue;
            var probe = z;
            const name = probe.next();
            if (name.tag != .identifier) continue;
            var delimiter = probe.next();
            if (delimiter.tag == .colon) {
                var nested: usize = 0;
                while (true) {
                    delimiter = probe.next();
                    if (delimiter.tag == .eof or delimiter.tag == .semicolon) break;
                    if (delimiter.tag == .equal and nested == 0) break;
                    if (delimiter.tag == .l_paren or delimiter.tag == .l_bracket or delimiter.tag == .l_brace) nested += 1;
                    if (delimiter.tag == .r_paren or delimiter.tag == .r_bracket or delimiter.tag == .r_brace) nested -|= 1;
                }
            }
            if (delimiter.tag != .equal) continue;
            const first = probe.next();
            const path = try p.fmt("{s}{s}{s}", .{ prefix, if (prefix.len == 0) "" else ".", bytes[name.loc.start..name.loc.end] });
            if (first.tag == .builtin and eq(bytes[first.loc.start..first.loc.end], "@import")) {
                _ = probe.next();
                const arg = probe.next();
                if (arg.tag == .string_literal) {
                    const imported = bytes[arg.loc.start..arg.loc.end];
                    var style_namespace = std.mem.endsWith(u8, imported, ".yss\"") or std.mem.endsWith(u8, imported, ".yss.zig\"");
                    if (p.catalog_prefixes) |names| for (names.items) |n| {
                        if (eq(n, path)) style_namespace = true;
                    };
                    if (!style_namespace) continue;
                }
            }
            if (first.tag == .identifier and (eq(bytes[first.loc.start..first.loc.end], "ui") or eq(bytes[first.loc.start..first.loc.end], "std"))) {
                _ = probe.next();
                const member = probe.next();
                if (member.tag != .identifier or !eq(bytes[member.loc.start..member.loc.end], "css")) continue;
            }
            if (first.tag == .keyword_struct or first.tag == .keyword_enum or first.tag == .keyword_union) {
                var open = probe.next();
                if (open.tag == .l_paren) {
                    while (open.tag != .r_paren and open.tag != .eof) open = probe.next();
                    open = probe.next();
                }
                if (open.tag == .l_brace) {
                    var nesting: usize = 1;
                    var close = open;
                    while (nesting != 0) {
                        close = probe.next();
                        if (close.tag == .eof) return p.fail(p.pos, "unterminated style namespace");
                        if (close.tag == .l_brace) nesting += 1;
                        if (close.tag == .r_brace) nesting -= 1;
                    }
                    try p.catalogRoots(out, bytes[open.loc.end..close.loc.start], path);
                    z = probe;
                    previous = .semicolon;
                    continue;
                }
            }
            try p.add(out, try p.fmt(" .@{s} = {s},", .{ try p.quote(try p.normalizedTokens(path)), path }));
            // Leave all initializer tokens to the normal depth tracker.
        }
    }

    /// `signal(...)` / `computed(...)` / `ref(...)` / `parts(...)` Yix built-ins in component body:
    /// file-level function/const with same name silently shadowed, rejected directly.
    fn rejectBuiltinShadowing(p: *Parser) Error!void {
        var z = std.zig.Tokenizer.init(p.source);
        var depth: usize = 0;
        var prev: Token.Tag = .eof;
        while (true) {
            const t = z.next();
            switch (t.tag) {
                .eof => return,
                .l_brace, .l_paren, .l_bracket => depth += 1,
                .r_brace, .r_paren, .r_bracket => depth -|= 1,
                .identifier => if (depth == 0 and (prev == .keyword_fn or prev == .keyword_const or prev == .keyword_var)) {
                    const w = p.source[t.loc.start..t.loc.end];
                    for (local_builtins) |b| if (eq(w, b))
                        return p.failFmt(t.loc.start, "`{s}` is a Yix builtin (signal / computed / ref / parts); give this declaration another name", .{w});
                },
                else => {},
            }
            prev = t.tag;
        }
    }
    const local_builtins = [_][]const u8{ "signal", "computed", "ref", "parts" };

    /// `builtin(args)` entire init is one built-in call (by token, `signal (x)` also counts;
    /// `computed(a) + 1` no):
    /// return built-in name and arg source text.
    fn localBuiltin(p: *Parser, expr: []const u8) Error!?struct { name: []const u8, inner: []const u8 } {
        var z = std.zig.Tokenizer.init(try p.a.dupeSentinel(u8, expr, 0));
        const first = z.next();
        if (first.tag != .identifier) return null;
        const w = expr[first.loc.start..first.loc.end];
        const known = for (local_builtins) |b| {
            if (eq(w, b)) break true;
        } else false;
        if (!known) return null;
        const open = z.next();
        if (open.tag != .l_paren) return null;
        var depth: usize = 1;
        while (true) {
            const t = z.next();
            switch (t.tag) {
                .eof => return null,
                .l_paren => depth += 1,
                .r_paren => {
                    depth -= 1;
                    if (depth == 0) {
                        if (z.next().tag != .eof) return null;
                        return .{ .name = w, .inner = expr[open.loc.end..t.loc.start] };
                    }
                },
                else => {},
            }
        }
    }

    fn component(p: *Parser, name: []const u8, params: []const u8, is_pub: bool) Error![]const u8 {
        p.template_path = name;
        p.flow_seq.* = 0;
        p.derive_seq = 0;
        p.symbols.clearRetainingCapacity();
        p.mount_code = .empty;
        p.preview_setup_safe = true;
        p.view_attach_code = .empty;
        p.view_detach_code = .empty;
        p.slotted = false;
        p.slot_names = &.{};
        p.slots_used = .empty;
        p.optional_slots = &.{};
        var slot_list: List([]const u8) = .empty;
        var optional_list: List([]const u8) = .empty;
        var fields: List(u8) = .empty;
        var aliases: List(u8) = .empty;
        var models: List(u8) = .empty;
        var model_count: usize = 0;
        // `name: Text`: text children in tag go to this param (`<Button>Save</Button>` -> label).
        var text_child: ?[]const u8 = null;
        var q: Parser = .{ .a = p.a, .module_path = p.module_path, .source = try p.dup(params), .origins = p.origins, .flow_seq = p.flow_seq };
        while (q.token().tag != .eof) {
            if (q.token().tag == .keyword_comptime) return p.fail(p.pos, "comptime component parameters are not implemented");
            const name_token = try q.expect(.identifier);
            const n = q.word(name_token);
            try p.requireCamel(q.absolute(name_token.loc.start), n, "component parameter");
            _ = try q.expect(.colon);
            const start = q.pos;
            var nesting: usize = 0;
            var equal: ?usize = null;
            while (q.token().tag != .eof) {
                const t = q.token();
                if (nesting == 0 and t.tag == .comma) break;
                _ = q.take();
                switch (t.tag) {
                    .l_paren, .l_bracket, .l_brace => nesting += 1,
                    .r_paren, .r_bracket, .r_brace => {
                        if (nesting == 0) return p.fail(p.pos, "unbalanced component parameter");
                        nesting -= 1;
                    },
                    .equal => if (nesting == 0 and equal == null) {
                        equal = t.loc.start;
                    },
                    else => {},
                }
            }
            if (nesting != 0) return p.fail(p.pos, "unbalanced component parameter");
            const ty = trim(params[start .. equal orelse q.pos]);
            if (ty.len == 0) return p.fail(p.pos, "component parameters require a type");
            if (eq(ty, "View") or eq(ty, "?View")) {
                // Slots: `children` takes tag children, others are named slots (caller writes
                // `header={<.../>}`). `?View`: optional named slot, built only when filled.
                if (equal != null) return p.fail(p.pos, "a View parameter (slot) takes no default");
                if (ty[0] == '?') {
                    if (eq(n, "children")) return p.fail(p.pos, "children cannot be optional; only named slots take ?View");
                    try optional_list.append(p.a, n);
                    p.optional_slots = optional_list.items;
                }
                p.slotted = true;
                for (slot_list.items) |prev| if (eq(prev, n)) return p.failFmt(p.absolute(p.pos), "slot `{s}` is declared twice", .{n});
                try slot_list.append(p.a, n);
                p.slot_names = slot_list.items;
                _ = q.eat(.comma);
                continue;
            }
            // Built-in type names by syntax (not substring): `Handler(T)` / `?Handler(T)`
            // callbacks, `Model(T)` controlled.
            const optional = ty[0] == '?';
            const bare = if (optional) trim(ty[1..]) else ty;
            if (std.mem.startsWith(u8, bare, "ui.Handler(") or std.mem.startsWith(u8, bare, "ui.Model("))
                return p.failFmt(q.absolute(start), "write the built-in parameter type as `{s}{s}` (without `ui.`)", .{ if (optional) "?" else "", bare[3..] });
            if (builtinCall(bare, "Handler")) |event_ty| {
                // Callback: normal field (non-Source). Omit default = required; optional callback
                // defaults null.
                // Template pass by name as-is.
                const default: ?[]const u8 = if (equal) |e| trim(params[e + 1 .. q.pos]) else if (optional) "null" else null;
                try p.add(&fields, try p.fmt("    {s}: {s}ui.Handler({s})", .{ try p.snake(n), if (optional) "?" else "", event_ty }));
                if (default) |d| try p.add(&fields, try p.fmt(" = {s}", .{d}));
                try p.add(&fields, ",\n");
                try p.add(&aliases, try p.fmt("    const {s} = __yix_props.{s};\n", .{ n, try p.snake(n) }));
                try p.declare(.{ .name = n, .reactive = false, .handler = true });
                _ = q.eat(.comma);
                continue;
            }
            if (builtinCall(ty, "Model")) |value_ty| {
                // Controlled value: read follows data source (Bound.read), event assign is
                // "proposal" (propose),
                // only report landed value. Default is init when uncontrolled; omit = required
                // (caller must provide source).
                try p.add(&fields, try p.fmt("    {s}: ui.Model({s})", .{ try p.snake(n), value_ty }));
                if (equal) |e| try p.add(&fields, try p.fmt(" = .{{ .local = {s} }}", .{trim(params[e + 1 .. q.pos])}));
                try p.add(&fields, ",\n");
                try p.add(&models, try p.fmt("    const __yix_model_{s} = try ui.reactive.resolveModelFor({s}, scope, __yix_props.{s});\n", .{ n, value_ty, try p.snake(n) }));
                try p.declare(.{ .name = n, .reactive = true, .writable = true, .source = true, .model = true });
                model_count += 1;
                _ = q.eat(.comma);
                continue;
            }
            if (optional and builtinCall(bare, "Model") != null) return p.fail(p.pos, "a Model parameter cannot be optional; give it a default for the uncontrolled case");
            // `Text` = string param, text children in tag go to it (explicit, not name-guessed).
            const is_text = eq(bare, "Text");
            if (is_text) {
                if (optional) return p.fail(p.pos, "a Text parameter cannot be optional; give it a default such as \"\"");
                if (text_child != null) return p.failFmt(p.absolute(p.pos), "only one parameter can be Text (text children go to `{s}` already)", .{text_child.?});
                text_child = n;
            }
            // Props fields all snake_case (match caller's camelCase attr mapping), used by param
            // name in component.
            try p.add(&fields, try p.fmt("    {s}: ui.Source({s})", .{ try p.snake(n), if (is_text) "[]const u8" else try p.mark(ty) }));
            if (equal) |e| try p.add(&fields, try p.fmt(" = .{{ .value = {s} }}", .{try p.mark(trim(params[e + 1 .. q.pos]))}));
            try p.add(&fields, ",\n");
            try p.add(&aliases, try p.fmt("    const {s} = __yix_props.{s};\n", .{ n, try p.snake(n) }));
            try p.declare(.{ .name = n, .reactive = true, .source = true });
            _ = q.eat(.comma);
        }
        p.model_count = model_count;
        if (text_child) |t| try p.add(&fields, try p.fmt("    /// Text children of the tag go into this parameter (ui.view.textChild)\n    pub const text_child = \"{s}\";\n", .{try p.snake(t)}));
        const body_code = try p.body(name);
        const generated_body = try p.fmt("    try ui.view.previewCheckSetup(scope, {});\n{s}", .{ p.preview_setup_safe, body_code });
        try p.add(&fields, try p.fmt("    pub const __yix_preview_setup = true;\n    pub const __yix_preview_builder = {s};\n    pub const __yix_preview_mount = __yix_{s};\n", .{ name, name }));
        // Omit unused parameter aliases so Zig's unused-local check stays useful.
        var used_aliases: List(u8) = .empty;
        for (p.symbols.items) |s| {
            if (std.mem.indexOf(u8, aliases.items, try p.fmt("const {s} =", .{s.name})) != null and try containsName(p.a, generated_body, s.name))
                try p.add(&used_aliases, try p.fmt("    const {s} = __yix_props.{s};\n", .{ s.name, try p.snake(s.name) }));
        }
        // Controlled value: always parse (parse itself builds local signal/borrow); read name ->
        // Bound.read.
        for (p.symbols.items) |sym| if (sym.model) {
            const model_var = try p.fmt("__yix_model_{s}", .{sym.name});
            if (try containsName(p.a, generated_body, sym.name)) try p.add(&models, try p.fmt("    const {s} = {s}.read;\n", .{ sym.name, model_var }));
            if (!try containsName(p.a, generated_body, model_var) and !try containsName(p.a, generated_body, sym.name)) try p.add(&models, try p.fmt("    _ = {s};\n", .{model_var}));
        };
        try p.add(&used_aliases, models.items);
        const unused = if (used_aliases.items.len == 0) "    _ = __yix_props;\n" else "";
        if (p.slotted) {
            for (p.slot_names) |sn| {
                for (p.slots_used.items) |u| {
                    if (eq(u, sn)) break;
                } else return p.failFmt(p.absolute(p.pos), "component declares {s}: {s}View but the template has no {{{s}}}", .{ sn, if (p.isOptionalSlot(sn)) "?" else "", sn });
            }
            // Optional slots: the component receives which named slots the caller filled.
            const presence_param = if (p.optional_slots.len != 0) " __yix_present: ui.view.SlotPresence," else "";
            return p.fmt("fn {s}(args: anytype) ui.view.SlottedOf(__yix_{s}) {{\n    return ui.view.slotted(__yix_{s}, ui.reactive.props.coerce({s}Props, args));\n}}\n{s}const {s}Props = struct {{\n{s}}};\nfn __yix_{s}(__yix_props: {s}Props,{s} scope: *ui.Scope, cx: *ui.Cx) anyerror!ui.view.ViewParts {{\n{s}{s}{s}\n}}", .{ name, name, name, name, if (is_pub) "pub " else "", name, fields.items, name, name, presence_param, unused, used_aliases.items, generated_body });
        }
        return p.fmt("fn {s}(args: anytype) ui.view.ComponentOf(__yix_{s}) {{\n    return ui.view.component(__yix_{s}, ui.reactive.props.coerce({s}Props, args));\n}}\n{s}const {s}Props = struct {{\n{s}}};\nfn __yix_{s}(__yix_props: {s}Props, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {{\n{s}{s}{s}\n}}", .{ name, name, name, name, if (is_pub) "pub " else "", name, fields.items, name, name, unused, used_aliases.items, generated_body });
    }
    /// A deliberately small syntax proof. It runs before evaluating generated
    /// view expressions or setup. Calls outside deferred lifecycle statements
    /// are unknown; even an unchanged call requires L3 rather than speculation.
    fn previewExpressionSafe(p: *Parser, raw: []const u8) Error!bool {
        var z = std.zig.Tokenizer.init(try p.a.dupeSentinel(u8, raw, 0));
        var prev: Token.Tag = .eof;
        while (true) {
            const item = z.next();
            switch (item.tag) {
                .eof => return true,
                .builtin, .period_asterisk, .keyword_volatile, .keyword_resume, .keyword_suspend, .semicolon, .keyword_break, .keyword_continue, .keyword_unreachable, .keyword_asm, .keyword_while, .keyword_defer, .keyword_errdefer, .keyword_return => return false,
                .l_paren => if (prev == .identifier or prev == .r_paren or prev == .r_bracket or prev == .r_brace or prev == .asterisk or prev == .question_mark or prev == .period or prev == .period_asterisk) {
                    return false;
                },
                else => {},
            }
            prev = item.tag;
        }
    }

    fn body(p: *Parser, name: []const u8) Error![]const u8 {
        var out: List(u8) = .empty;
        while (p.token().tag != .r_brace) {
            const start = p.token().loc.start;
            const t = p.take();
            if (t.tag == .eof) return p.fail(start, "unterminated component");
            if (t.tag == .keyword_return) {
                const paren = p.eat(.l_paren);
                if (p.token().tag != .angle_bracket_left) return p.fail(p.pos, "a View component returns one root tag");
                const template_start = p.token().loc.start;
                const op_start = if (p.preview) |c| c.ops.items.len else 0;
                const tag = try p.element();
                const template_end = p.pos;
                if (p.preview) |c| try c.components.append(p.a, .{
                    .name = name,
                    .start = template_start,
                    .end = p.pos,
                    .ops = try p.a.dupe(PreviewOp, c.ops.items[op_start..]),
                    .isolated = !p.slotted and p.view_attach_code.items.len == 0 and p.view_detach_code.items.len == 0,
                });
                if (paren) _ = try p.expect(.r_paren);
                _ = try p.expect(.semicolon);
                var view_code: List(u8) = .empty;
                var named: List(u8) = .empty;
                var default: []const u8 = "null";
                if (p.slotted) for (p.slot_names) |sn| {
                    try p.add(&view_code, try p.fmt("    var __yix_slot_{s}: ?ui.view.SlotPoint = null;\n", .{sn}));
                    if (eq(sn, "children")) default = "__yix_slot_children" else try p.add(&named, try p.fmt(" .{s} = __yix_slot_{s},", .{ sn, sn }));
                };
                try p.add(&view_code, try p.fmt("    try ui.view.previewCheckSetup(scope, {});\n    try ui.view.emit(scope, cx, __yix_sink, {s});\n    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;\n    __yix_root.meta.ownership.meta.component_name = \"{s}\";\n{s}", .{ try p.previewExpressionSafe(p.source[template_start..template_end]), tag, name, try p.fmt("{s}{s}", .{ p.view_detach_code.items, p.view_attach_code.items }) }));
                try p.add(&view_code, if (p.slotted)
                    try p.fmt("    return ui.view.slottedParts(__yix_root, {s}, .{{{s} }});\n", .{ default, named.items })
                else
                    "    return __yix_root;\n");
                var captured: List(Symbol) = .empty;
                try captured.appendSlice(p.a, try p.rowCaptures());
                if (p.optional_slots.len != 0) try captured.append(p.a, .{ .name = "__yix_present", .reactive = false });
                const renamed = try p.rowReferences(view_code.items, captured.items, "__yix_view_ctx", "__yix_view_scope", "__yix_view_cx");
                const used = try p.usedCaptures(captured.items, &.{renamed}, &.{"__yix_view_ctx"});
                const ctx = try p.context(used, false);
                const unused_ctx = if (used.len == 0) "    _ = __yix_view_ctx;\n" else "";
                // Instance onMount stays outside the repeatable view callback.
                try p.add(&out, try p.fmt("    const __yix_view = try ui.view.renderComponentView(scope, cx, {s}, struct {{ fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!{s} {{\n{s}{s}    }} }}.__yix_render);\n{s}    return __yix_view;\n", .{ ctx, if (p.slotted) "ui.view.ViewParts" else "*ui.Node", unused_ctx, renamed, p.mount_code.items }));
            } else if (t.tag == .keyword_var or t.tag == .keyword_const) {
                const n = p.word(try p.expect(.identifier));
                const ty = if (p.eat(.colon)) try p.spanTo(.equal) else "";
                _ = try p.expect(.equal);
                const expr = try p.spanTo(.semicolon);
                _ = try p.expect(.semicolon);
                const call = try p.localBuiltin(expr);
                const builtin: []const u8 = if (call) |c| c.name else "";
                const call_inner: []const u8 = if (call) |c| c.inner else "";
                if (eq(builtin, "signal") or eq(builtin, "computed")) {
                    p.preview_setup_safe = p.preview_setup_safe and try p.previewExpressionSafe(call_inner);
                } else if (!eq(builtin, "ref")) {
                    p.preview_setup_safe = p.preview_setup_safe and try p.previewExpressionSafe(expr);
                }
                if (eq(builtin, "signal")) {
                    if (t.tag != .keyword_var) return p.fail(start, "signal declarations must use var");
                    if (ty.len == 0) return p.fail(start, "signal declarations require an explicit value type");
                    const initial = try p.rewrite(call_inner, false, false);
                    // Storage (text/list/plain) by comptime type choice, not type spelling.
                    const init = try p.fmt("try scope.createSignalFor({s}, {s})", .{ try p.mark(ty), initial });
                    try p.declare(.{ .name = n, .reactive = true, .writable = true });
                    try p.add(&out, try p.fmt("    const {s} = {s};\n", .{ n, init }));
                } else if (eq(builtin, "ref")) {
                    // Mount handle: `ref={r}` in template mounts, after `r.get()` takes node (null
                    // on unmount).
                    if (t.tag != .keyword_const) return p.fail(start, "ref declarations must use const");
                    const inner = trim(call_inner);
                    try p.declare(.{ .name = n, .reactive = false });
                    try p.add(&out, try p.fmt("    const {s} = try ui.view.createRef(scope, {s});\n", .{ try p.mark(n), if (inner.len == 0) "*ui.Node" else try p.mark(inner) }));
                } else if (eq(builtin, "parts")) {
                    // Named slot recipe one-parse: dimension values pass as-is (can be source),
                    // template `style={p.root}`.
                    if (t.tag != .keyword_const) return p.fail(start, "parts declarations must use const");
                    const inner = trim(call_inner);
                    try p.rejectEnv(inner);
                    try p.declare(.{ .name = n, .reactive = false });
                    try p.add(&out, try p.fmt("    const {s} = ui.view.slotParts({s});\n", .{ try p.mark(n), try p.mark(inner) }));
                } else if (eq(builtin, "computed")) {
                    if (t.tag != .keyword_const) return p.fail(start, "computed declarations must use const");
                    try p.requireSimpleExpression(call_inner);
                    const inner = call_inner;
                    const lifted = try p.liftable(inner);
                    const value = if (lifted) try p.sourceComputed(inner, if (ty.len == 0) null else ty) else try p.memo(inner, if (ty.len == 0) null else ty);
                    try p.declare(.{ .name = n, .reactive = true, .source = lifted });
                    try p.add(&out, try p.fmt("    const {s} = {s};\n", .{ n, value }));
                } else {
                    try p.declare(.{ .name = n, .reactive = false });
                    try p.rejectEnv(expr);
                    if (try p.reactive(expr)) return p.fail(start, "reactive reads in component locals require computed(...)");
                    // Indent like other generated locals (copied source from const on, no indent
                    // from source).
                    try p.add(&out, "    ");
                    try p.add(&out, try p.markZigSrc(p.source[start..p.pos]));
                    try p.add(&out, "\n");
                }
            } else if (t.tag == .identifier and (eq(p.word(t), "effect") or eq(p.word(t), "onMount") or eq(p.word(t), "onUnmount") or eq(p.word(t), "onViewAttach") or eq(p.word(t), "onViewDetach")) and p.token().tag == .l_paren) {
                // effect(stmt): rerun when sources change; onMount(stmt): run once after root
                // mount;
                // onUnmount(stmt): run at unmount.
                const kind = p.word(t);
                p.event_name = kind;
                const raw = trim(try p.balanced(.l_paren, .r_paren));
                _ = try p.expect(.semicolon);
                const mode: StatementMode = if (eq(kind, "effect")) .effect else if (eq(kind, "onMount") or eq(kind, "onViewAttach")) .mount else .unmount;
                const code = try p.statements(raw, mode);
                if (eq(kind, "onViewAttach")) try p.add(&p.view_attach_code, code) else if (eq(kind, "onViewDetach")) try p.add(&p.view_detach_code, code) else if (mode == .mount) try p.add(&p.mount_code, code) else try p.add(&out, code);
            } else return p.fail(start, "component bodies support declarations, effect / onMount / onUnmount / onViewAttach / onViewDetach and a root return; move helpers to ordinary Zig functions");
        }
        _ = p.take();
        return out.items;
    }

    fn element(p: *Parser) Error![]const u8 {
        p.depth += 1;
        defer p.depth -= 1;
        if (p.depth > 128) return p.fail(p.pos, "template nesting exceeds 128");
        const site_start = p.token().loc.start;
        const preview_start = if (p.preview) |c| c.ops.items.len else 0;
        _ = try p.expect(.angle_bracket_left);
        const nt = try p.expect(.identifier);
        var name = p.word(nt);
        while (p.eat(.period)) name = try p.fmt("{s}.{s}", .{ name, p.word(try p.expect(.identifier)) });
        // Component tag name copied to generated (jump/hover lands on component definition).
        const name_out = try p.mark(p.source[nt.loc.start..p.pos]);
        var template_attributes: List(u8) = .empty;
        var hole_attributes: List(u8) = .empty;
        var preview_attributes: List(PreviewAttribute) = .empty;
        var props: List(u8) = .empty;
        var attrs: List(u8) = .empty;
        var icon_src: ?[]const u8 = null;
        var canvas_draw: ?[]const u8 = null;
        var canvas_paint: List(u8) = .empty;
        var ref_target: ?[]const u8 = null;
        // Value on component element is element attr: named slot content
        // (`header={<text>Title</text>}`).
        var named_slots: List(u8) = .empty;
        const is_component = std.ascii.isUpper(name[0]) or std.mem.indexOfScalar(u8, name, '.') != null;
        while (p.token().tag != .angle_bracket_right and p.token().tag != .slash) {
            var key: []const u8 = undefined;
            var value: []const u8 = undefined;
            const key_at = p.absolute(p.token().loc.start);
            if (p.token().tag == .l_brace) {
                key = trim(try p.balanced(.l_brace, .r_brace));
                if (p.lookup(key) == null) return p.fail(p.pos, "attribute shorthand requires a local name");
                value = key;
            } else {
                key = p.word(try p.expect(.identifier));
                if (p.eat(.equal)) {
                    if (p.token().tag == .string_literal) value = p.word(p.take()) else if (p.token().tag == .l_brace) value = trim(try p.balanced(.l_brace, .r_brace)) else return p.fail(p.pos, "attribute values require braces, except strings");
                } else value = "true";
            }
            try p.requireCamel(key_at, key, "attribute");
            const normalized_value = try p.normalizedTokens(value);
            const is_literal = !eq(try p.templateLiteral(value), "null");
            if (p.preview != null) try preview_attributes.append(p.a, .{ .name = try p.snake(key), .value = normalized_value, .literal = is_literal });
            const static_style = eq(key, "style") and try p.previewStaticStyle(normalized_value);
            if (eq(key, "style")) if (p.catalog_prefixes) |names| {
                var z = std.zig.Tokenizer.init(try p.a.dupeSentinel(u8, normalized_value, 0));
                const first = z.next();
                if (first.tag == .identifier) try names.append(p.a, normalized_value[first.loc.start..first.loc.end]);
            };
            try p.add(&hole_attributes, try p.fmt("{s} = {s}; ", .{ key, if (is_literal or static_style) "@static" else normalized_value }));
            const attr_kind: []const u8 = if (isEventKey(key)) "event" else if (eq(key, "ref")) "reference" else if (eq(key, "style")) "style" else "property";
            try p.add(&template_attributes, try p.fmt(" .{{ .name = {s}, .tokens = {s}, .kind = .{s}, .literal = {s} }},", .{ try p.quote(try p.snake(key)), try p.quote(normalized_value), attr_kind, try p.templateLiteral(value) }));
            if (trim(value).len != 0 and trim(value)[0] == '<') {
                if (!is_component) return p.failFmt(key_at, "`{s}` has an element value; element values only go on component attributes (named slots)", .{key});
                var q = try p.sub(trim(value));
                q.template_path = try p.fmt("{s}/slot:{s}", .{ p.template_path, key });
                if (p.preview != null) preview_attributes.items[preview_attributes.items.len - 1].slot = true;
                const content = q.branch() catch |err| {
                    p.diagnostic = q.diagnostic;
                    return err;
                };
                if (q.token().tag != .eof) return p.failFmt(key_at, "the value of `{s}` must be a single element", .{key});
                try p.add(&named_slots, try p.fmt(" .{s} = {s},", .{ key, content }));
                continue;
            }
            if (is_component and std.mem.startsWith(u8, trim(value), "if") and std.mem.indexOfScalar(u8, value, '<') != null) {
                // `icon={if (cond) <icon …/>}`: a slot that exists only when cond holds at mount
                // (slots are structure; an absent one builds nothing).
                var q = try p.sub(trim(value));
                if (q.token().tag == .keyword_if) {
                    _ = q.take();
                    const cond = trim(try q.balanced(.l_paren, .r_paren));
                    if (q.token().tag == .angle_bracket_left) {
                        const content = q.element() catch |err| {
                            p.diagnostic = q.diagnostic;
                            return err;
                        };
                        if (q.token().tag == .keyword_else) return p.failFmt(key_at, "`{s}={{if (…) <…/>}}` takes no else: when the condition is false the slot is absent", .{key});
                        if (q.token().tag != .eof) return p.failFmt(key_at, "the value of `{s}` must be a single element", .{key});
                        const cond_code = try p.expression(cond);
                        try p.add(&named_slots, try p.fmt(" .{s} = if (ui.view.atMount({s})) {s} else null,", .{ key, cond_code, content }));
                        continue;
                    }
                }
            }
            if (eq(key, "ref")) {
                // After mount, write node (component element mounts to result) into ref handle.
                if (ref_target != null) return p.fail(nt.loc.start, "ref is given more than once");
                try p.rejectEnv(value);
                ref_target = try p.mark(trim(value));
                continue;
            }
            if (eq(key, "key")) {
                // List row key: only meaningful on root element of `{for}` line.
                const slot = p.row_key orelse return p.fail(nt.loc.start, "key={…} only goes on the root element of a {for} row");
                try p.rejectEnv(value);
                slot.* = value;
                p.row_key = null;
                continue;
            }
            // view.icon / view.image take their resource positionally, not as a prop.
            // The resource may be a prop (a source): view reads it once at mount.
            if ((eq(name, "icon") or eq(name, "image")) and eq(key, "src")) {
                if (icon_src != null) return p.fail(nt.loc.start, "src is given more than once");
                icon_src = try p.expression(value);
                continue;
            }
            // Canvas three-draw trio into view.paint: draw is compile-time function (as-is),
            // data/animate are values or sources.
            if (eq(name, "canvas") and (eq(key, "draw") or eq(key, "data") or eq(key, "animate"))) {
                if (eq(key, "draw")) {
                    if (canvas_draw != null) return p.fail(nt.loc.start, "canvas draw is given more than once");
                    try p.rejectEnv(value);
                    canvas_draw = try p.mark(value);
                } else try p.add(&canvas_paint, try p.fmt(" .{s} = {s},", .{ key, try p.expression(value) }));
                continue;
            }
            // Host element: attrs must be in tag's attr table (typo/attr from other tag reports in
            // .yix source).
            if (hostAttrs(name)) |allowed| {
                for (allowed) |at| {
                    if (eq(at.name, key)) break;
                } else {
                    const at_key = key_at;
                    if (nearestAttr(allowed, key)) |near| return p.failFmt(at_key, "<{s}> has no attribute `{s}` (did you mean `{s}`?)", .{ name, key, near });
                    return p.failFmt(at_key, "<{s}> has no attribute `{s}`", .{ name, key });
                }
            }
            const mapped = try p.snake(key);
            // style/parts/a11y pass to view as-is: reactive sources in fields are handled per-item
            // by view
            // (restyle/a11y update). Host element events carry no value (HandlerRef); component
            // events take
            // the value type from the receiving prop (bindAny). onEvent is the generic fallback
            // event
            // callback (GenericEventCallback), not an event stmt. Host typed events
            // (onKeyDown/onPointer*/onScroll) carry a value and instantiate by the receiver's type.
            if (isEventKey(key) and !eq(key, "onEvent")) p.event_name = key;
            if (is_component and isEventKey(key) and !eq(key, "onEvent") and !isTypedHostEvent(key)) {
                // Component param starting `on` not necessarily event (`onTop: bool`): dispatch by
                // receiver type
                // (ui.view.isEventProp). Event stmts only to event params, literals only to data
                // params;
                // identifier/field both emit, comptime takes one (untaken branch skipped
                // semantics).
                value = switch (eventForm(value)) {
                    .statement => try p.fmt("ui.view.eventProp({s}, \"{s}\", {s})", .{ name, mapped, try p.handler(value, false) }),
                    .literal => try p.fmt("ui.view.valueProp({s}, \"{s}\", {s})", .{ name, mapped, try p.attrExpression(value, name, mapped) }),
                    .either => either: {
                        // Both emitted, comptime picks one (untaken branch skipped). Event form
                        // errors in Yix layer report normally;
                        // value form can't compile in Yix (unsupported expr syntax) keeps only
                        // event form (still type-check by param).
                        const as_event = try p.handler(value, false);
                        const as_value = p.attrExpression(value, name, mapped) catch |err| switch (err) {
                            error.InvalidYix => {
                                p.diagnostic = null;
                                break :either try p.fmt("ui.view.eventProp({s}, \"{s}\", {s})", .{ name, mapped, as_event });
                            },
                            else => return err,
                        };
                        break :either try p.fmt("if (comptime ui.view.isEventProp({s}, \"{s}\")) {s} else {s}", .{ name, mapped, as_event, as_value });
                    },
                };
            } else if (isEventKey(key) and !eq(key, "onEvent")) value = try p.handler(value, !is_component and !isTypedHostEvent(key)) else if (!eq(key, "style") and !eq(key, "box") and !eq(key, "parts") and !eq(key, "a11y") and !eq(key, "state") and !eq(key, "tint")) value = if (is_component) try p.attrExpression(value, name, mapped) else try p.expression(value) else {
                try p.rejectEnv(value);
                value = try p.mark(value);
            }
            // style/parts/testId/visible/a11y on component element and typed events
            // (onKeyDown/onPointer*/onScroll) apply to component root.
            const external = is_component and (eq(key, "style") or eq(key, "parts") or eq(key, "testId") or eq(key, "visible") or eq(key, "a11y") or isTypedHostEvent(key));
            try p.add(if (external) &attrs else &props, try p.fmt(" .{s} = {s},", .{ try p.markPoint(key, mapped), value }));
        }
        const self_close = p.eat(.slash);
        _ = try p.expect(.angle_bracket_right);

        const slot_start = p.pos;
        const slot_at = if (p.preview) |c| c.ops.items.len else 0;
        const child_content = if (self_close) Children{} else try p.children(name);
        if (p.preview) |c| if (is_component and c.ops.items.len > slot_at) {
            try c.regions.append(p.a, .{ .name = try p.fmt("{s}/slot:children", .{p.template_path}), .start = p.absolute(slot_start), .end = p.absolute(p.pos), .ops = try p.a.dupe(PreviewOp, c.ops.items[slot_at..]), .isolated = true, .region = true });
        };
        const host_container = eq(name, "box") or eq(name, "row") or eq(name, "col") or eq(name, "grid");
        if ((child_content.slot_end != null or child_content.slot_mark) and !host_container) return p.fail(nt.loc.start, "a slot ({children} / {name}) must be inside box, row, col or grid");
        const ps = try p.fmt(".{{{s} }}", .{props.items});
        // Children one per line, indent by nesting depth: twin readable, zig CLI errors clear which
        // element.
        const cs = if (child_content.nodes.len == 0) ".{ }" else try p.fmt(".{{{s}{s}}}", .{ child_content.nodes, try p.childBreak(-1) });
        var result: []const u8 = undefined;
        if (eq(name, "text")) {
            if (child_content.has_elements) return p.fail(nt.loc.start, "text accepts text and interpolation only");
            result = try p.fmt("ui.view.text({s}, {s})", .{ ps, child_content.text orelse "\"\"" });
        } else if (eq(name, "spacer")) {
            if (props.items.len != 0 or child_content.nodes.len != 0) return p.fail(nt.loc.start, "spacer takes no attributes or children");
            result = "ui.view.spacer()";
        } else if (eq(name, "canvas")) {
            if (child_content.nodes.len != 0) return p.fail(nt.loc.start, "canvas takes no children; it draws itself");
            const draw = canvas_draw orelse return p.fail(nt.loc.start, "canvas requires draw={fn (DrawContext, Data, ui.view.Frame) !void}");
            result = try p.fmt("ui.view.canvas({s}, ui.view.paint(.{{{s} }}, {s}))", .{ ps, canvas_paint.items, draw });
        } else if (eq(name, "icon") or eq(name, "image")) {
            if (child_content.nodes.len != 0) return p.fail(nt.loc.start, "icon / image take no children");
            const src = icon_src orelse return p.fail(nt.loc.start, "icon / image require src={asset or texture id}");
            result = try p.fmt("ui.view.{s}({s}, {s})", .{ name, ps, src });
        } else if (eq(name, "box") or eq(name, "row") or eq(name, "col") or eq(name, "grid")) {
            result = try p.fmt("ui.view.{s}({s}, {s})", .{ name, ps, cs });
            if (child_content.slot_end) |sn| result = try p.fmt("ui.view.slotEnd(&__yix_slot_{s}, {s})", .{ sn, result });
        } else if (std.ascii.isUpper(name[0]) or std.mem.indexOfScalar(u8, name, '.') != null) {
            if (named_slots.items.len != 0) {
                // Named slots: children to default, element attr values go to slots by name.
                result = try p.fmt("ui.view.with({s}({s}), {s}).slots(.{{{s} }})", .{ name_out, ps, cs, named_slots.items });
            } else if (!child_content.has_elements and child_content.text != null) {
                // Children text-only: component declares some param `Text` -> text goes to it
                // (`<Button>Save</Button>`),
                // else children. ui.view.textChild judges at comptime by component declaration
                // (error if attr+text on same param).
                result = try p.fmt("ui.view.textChild({s}, {s}, {s}, {s})", .{ name_out, ps, if (child_content.args) "null" else child_content.literal, cs });
            } else {
                result = try p.fmt("{s}({s})", .{ name_out, ps });
                if (child_content.nodes.len != 0) result = try p.fmt("ui.view.with({s}, {s})", .{ result, cs });
            }
        } else return p.fail(nt.loc.start, "unknown host tag; host tags are box, row, col, grid, text, icon, image, canvas and spacer");
        if (is_component) result = try p.fmt("__yix_builder_{d}: {{ try ui.view.previewCheckBuilder(scope, {s}); break :__yix_builder_{d} {s}; }}", .{ site_start, name_out, site_start, result });
        if (ref_target) |r| result = try p.fmt("ui.view.ref({s}, {s})", .{ r, result });
        if (attrs.items.len != 0) result = try p.fmt("ui.view.templateAttrs(.{{{s} }}, {s})", .{ attrs.items, result });
        // Metadata describes lexical receivers; concrete capture/receiver types
        // are completed and checked by Zig's template schema instantiation.
        const raw = p.source[site_start..p.pos];
        const dependencies = try p.deps(try plain(p.a, result));
        const ctx = try p.context(dependencies, false);
        const tokens = if (is_component or ref_target != null) try p.normalizedTokens(raw) else try p.fmt("{s} {s}{s}", .{ name, hole_attributes.items, if (eq(name, "text") and child_content.args) child_content.identity else "" });
        const literal = if (eq(name, "text") and !child_content.args) (if (child_content.literal.len == 0) "\"\"" else child_content.literal) else "null";
        if (p.preview) |c| {
            const container = (eq(name, "box") or eq(name, "row") or eq(name, "col")) and !p.slotted and ref_target == null;
            if (!container) c.ops.shrinkRetainingCapacity(preview_start);
            const names = try p.a.alloc([]const u8, dependencies.len);
            for (dependencies, names) |symbol, *capture| capture.* = symbol.name;
            try c.ops.insert(p.a, preview_start, .{ .kind = if (container) .element else .hole, .path = p.template_path, .receiver = name, .tokens = tokens, .identity_tokens = if (is_component) try p.previewIdentity(site_start, p.pos) else null, .attributes = preview_attributes.items, .literal = if (!eq(literal, "null")) literal else null, .captures = names, .fragments = if (eq(name, "text")) child_content.fragments else &.{} });
            if (container) try c.ops.append(p.a, .{ .kind = .close });
        }
        const root_source = if (p.depth == 1 and !p.in_branch and !eq(p.module_path, "<memory>")) ", .source = __yix_preview_source, .catalog = __YixStyleCatalog" else "";
        return p.fmt("ui.view.templateSite(.{{ .module = {s}, .path = {s}, .receiver = {s}, .tokens = {s}, .literal_text = {s}, .attributes = &.{{{s} }}{s} }}, {s}, {s})", .{ try p.quote(p.module_path), try p.quote(p.template_path), try p.quote(name), try p.quote(tokens), literal, template_attributes.items, root_source, ctx, result });
    }
    /// Template attrs and component params camelCase only (generated Zig fields snake_case).
    /// Abbreviations
    /// per-word: `testId` not `testID`. `at` source offset; `what` diagnostic term.
    fn requireCamel(p: *Parser, at: usize, name: []const u8, comptime what: []const u8) Error!void {
        const fixed = try camelOf(p.a, name);
        if (eq(fixed, name)) return;
        return p.failFmt(at, what ++ " names are camelCase: write `{s}` instead of `{s}` (the Zig field is still `{s}`)", .{ fixed, name, try p.snake(fixed) });
    }
    fn snake(p: *Parser, name: []const u8) Error![]const u8 {
        var out: List(u8) = .empty;
        for (name) |c| {
            if (std.ascii.isUpper(c)) try out.append(p.a, '_');
            try out.append(p.a, std.ascii.toLower(c));
        }
        return out.items;
    }

    const Children = struct { fragments: []const []const u8 = &.{}, identity: []const u8 = "", nodes: []const u8 = "", text: ?[]const u8 = null, literal: []const u8 = "", args: bool = false, has_elements: bool = false, slot_end: ?[]const u8 = null, slot_mark: bool = false };

    /// `{name}` is this component's slot?
    fn slotName(p: *Parser, name: []const u8) ?[]const u8 {
        for (p.slot_names) |sn| if (eq(sn, name)) return sn;
        return null;
    }
    fn isOptionalSlot(p: *Parser, name: []const u8) bool {
        for (p.optional_slots) |sn| if (eq(sn, name)) return true;
        return false;
    }
    /// `{if (name) <tag>…{name}…</tag>}` with `name: ?View`: the element exists only when the
    /// caller filled the slot. Decided once at mount (slots are structure), so it compiles to a
    /// plain optional element instead of a reactive branch. Returns null for any other `{…}`.
    fn optionalSlotGuard(p: *Parser, expr: []const u8) Error!?[]const u8 {
        if (p.optional_slots.len == 0) return null;
        var q = try p.sub(expr);
        errdefer if (q.diagnostic) |d| {
            p.diagnostic = d;
        };
        if (q.token().tag != .keyword_if) return null;
        _ = q.take();
        if (!q.eat(.l_paren)) return null;
        if (q.token().tag != .identifier) return null;
        const name = q.word(q.take());
        if (!p.isOptionalSlot(name)) return null;
        // Slot boxes are fixed at mount; a reactive branch rebuilds its nodes.
        if (p.in_branch) return p.failFmt(p.absolute(p.pos), "{{{s}}} (a slot) cannot be inside control flow", .{name});
        _ = try q.expect(.r_paren);
        if (q.token().tag != .angle_bracket_left) return q.failFmt(q.absolute(q.pos), "{{if ({s}) …}} on an optional slot takes one element", .{name});
        q.in_branch = p.in_branch;
        q.slot_guard = name;
        const guarded = try q.element();
        if (q.token().tag == .keyword_else) return q.failFmt(q.absolute(q.pos), "{{if ({s}) …}} on an optional slot takes no else: an absent slot builds nothing", .{name});
        if (q.token().tag != .eof) return q.fail(q.pos, "unexpected tokens after the optional slot element");
        var used = false;
        for (q.slots_used.items) |u| {
            for (p.slots_used.items) |prev| if (eq(prev, u)) return p.failFmt(p.absolute(p.pos), "{{{s}}} appears more than once", .{u});
            try p.slots_used.append(p.a, u);
            if (eq(u, name)) used = true;
        }
        if (!used) return p.failFmt(p.absolute(p.pos), "{{if ({s}) …}} must contain {{{s}}}", .{ name, name });
        return try p.fmt("if (__yix_present.has(\"{s}\")) {s} else null", .{ name, guarded });
    }
    const TextRun = struct { format: List(u8) = .empty, args: List(u8) = .empty, literal: List(u8) = .empty, fragments: List([]const u8) = .empty, interpolation_count: usize = 0, identity: List(u8) = .empty };
    fn appendText(p: *Parser, run: *TextRun, raw: []const u8) Error!void {
        var normalized: List(u8) = .empty;
        if (std.mem.indexOfScalar(u8, raw, '\n') != null) {
            // Same as JSX (Babel cleanJSXElementLiteralChild): first line after strip leading
            // space, last line after
            // strip trailing; add space between non-empty lines. Spaces adjacent to interpolations
            // in line (space in
            // `b {x}`) kept.
            var line_count: usize = 0;
            var last_non_empty: ?usize = null;
            var it = std.mem.splitScalar(u8, raw, '\n');
            while (it.next()) |line| : (line_count += 1) {
                if (trim(line).len != 0) last_non_empty = line_count;
            }
            var lines = std.mem.splitScalar(u8, raw, '\n');
            var i: usize = 0;
            while (lines.next()) |line| : (i += 1) {
                var s = line;
                if (i != 0) s = std.mem.trimStart(u8, s, " \t\r");
                if (i != line_count - 1) s = std.mem.trimEnd(u8, s, " \t\r");
                if (s.len == 0) continue;
                try p.add(&normalized, s);
                if (i != last_non_empty.?) try p.add(&normalized, " ");
            }
        } else try p.add(&normalized, raw);
        if (normalized.items.len == 0) return;
        try p.add(&run.literal, normalized.items);
        if (run.format.items.len != 0) try p.add(&run.format, " ++ ");
        // Literal braces are escaped for std.fmt, while the displayed text stays intact.
        var escaped: List(u8) = .empty;
        for (normalized.items) |c| {
            try escaped.append(p.a, c);
            if (c == '{' or c == '}') try escaped.append(p.a, c);
        }
        try p.add(&run.format, try p.quote(escaped.items));
    }
    fn interpolate(p: *Parser, run: *TextRun, raw: []const u8) Error!void {
        var q: Parser = .{ .a = p.a, .module_path = p.module_path, .source = try p.dup(raw), .origins = p.origins, .flow_seq = p.flow_seq };
        var nesting: usize = 0;
        var colon: ?usize = null;
        while (q.token().tag != .eof) {
            const t = q.take();
            switch (t.tag) {
                .l_paren, .l_brace, .l_bracket => nesting += 1,
                .r_paren, .r_brace, .r_bracket => {
                    if (nesting == 0) return p.fail(p.pos, "unbalanced interpolation");
                    nesting -= 1;
                },
                .colon => if (nesting == 0) {
                    colon = t.loc.start;
                    break;
                },
                else => {},
            }
        }
        const expr = trim(raw[0 .. colon orelse raw.len]);
        const value = try p.expression(expr);
        run.interpolation_count += 1;
        try run.fragments.append(p.a, try p.a.dupe(u8, run.literal.items));
        run.literal.clearRetainingCapacity();
        try p.add(&run.identity, try p.normalizedTokens(raw));
        try p.add(&run.identity, " @interpolation ");
        if (run.format.items.len != 0) try p.add(&run.format, " ++ ");
        try p.add(&run.format, try p.fmt("ui.view.yixFormat(@TypeOf({s}), {s})", .{ value, try p.quote(if (colon) |c| raw[c + 1 ..] else "") }));
        try p.add(&run.args, try p.fmt(" {s},", .{value}));
    }
    fn textValue(p: *Parser, r: TextRun) Error![]const u8 {
        return p.fmt("ui.view.fmt({s}, .{{{s} }})", .{ if (r.format.items.len == 0) "\"\"" else r.format.items, r.args.items });
    }
    /// Newlines and indent between children (relative to current element depth).
    fn childBreak(p: *Parser, offset: isize) Error![]const u8 {
        const spaces = (@as([(" ").len * (256)]u8, @bitCast(@as([256][(" ").len]u8, @splat((" ").*)))) ++ "");
        const level: usize = @intCast(@max(0, @as(isize, @intCast(p.depth)) + 1 + offset));
        return p.fmt("\n{s}", .{spaces[0..@min(spaces.len, 4 * (level + 1))]});
    }
    fn flush(p: *Parser, nodes: *List(u8), r: *TextRun) Error!void {
        if (r.format.items.len == 0) return;
        if (r.args.items.len != 0 and r.fragments.items.len == r.interpolation_count) try r.fragments.append(p.a, try p.a.dupe(u8, r.literal.items));
        const value = try p.textValue(r.*);
        const ctx = try p.context(try p.deps(try plain(p.a, value)), false);
        const tokens = if (r.args.items.len == 0) "text" else r.identity.items;
        const literal = if (r.args.items.len == 0) try p.quote(r.literal.items) else "null";
        if (p.preview) |c| {
            const dependencies = try p.deps(try plain(p.a, value));
            const names = try p.a.alloc([]const u8, dependencies.len);
            for (dependencies, names) |symbol, *capture| capture.* = symbol.name;
            try c.ops.append(p.a, .{ .kind = .text, .path = p.template_path, .receiver = "text", .tokens = tokens, .literal = if (r.args.items.len == 0) literal else null, .captures = names, .fragments = if (r.args.items.len == 0) &.{} else try p.a.dupe([]const u8, r.fragments.items) });
        }
        try p.add(nodes, try p.fmt("{s}ui.view.templateSite(.{{ .module = {s}, .path = {s}, .receiver = \"text\", .tokens = {s}, .literal_text = {s} }}, {s}, ui.view.text(.{{}}, {s})),", .{ try p.childBreak(0), try p.quote(p.module_path), try p.quote(p.template_path), try p.quote(tokens), literal, ctx, value }));
        r.* = .{};
    }
    fn children(p: *Parser, name: []const u8) Error!Children {
        var nodes: List(u8) = .empty;
        var run: TextRun = .{};
        var has_elements = false;
        var slot_end: ?[]const u8 = null;
        var slot_mark = false;
        while (true) {
            if (p.pos >= p.source.len) return p.fail(p.pos, "unclosed tag");
            if (std.mem.startsWith(u8, p.source[p.pos..], "</")) {
                p.pos += 2;
                const start = p.pos;
                while (p.pos < p.source.len and (std.ascii.isAlphanumeric(p.source[p.pos]) or p.source[p.pos] == '_' or p.source[p.pos] == '.')) p.pos += 1;
                if (!eq(name, p.source[start..p.pos])) return p.fail(start, "closing tag does not match opening tag");
                _ = try p.expect(.angle_bracket_right);
                break;
            }
            if (p.source[p.pos] == '<') {
                try p.flush(&nodes, &run);
                has_elements = true;
                const brk = try p.childBreak(0);
                try p.add(&nodes, try p.fmt("{s}{s},", .{ brk, try p.element() }));
            } else if (p.source[p.pos] == '{') {
                const offset = p.pos;
                const expr = try p.balanced(.l_brace, .r_brace);
                if (p.slotName(trim(expr))) |sn| {
                    const optional = p.isOptionalSlot(sn);
                    if (optional and !(p.slot_guard != null and eq(p.slot_guard.?, sn)))
                        return p.failFmt(p.absolute(offset), "{{{s}}} is an optional slot (?View); place it inside {{if ({s}) <box …>{{{s}}}</box>}}", .{ sn, sn, sn });
                    if (p.in_branch and !optional) return p.failFmt(p.absolute(offset), "{{{s}}} (a slot) cannot be inside control flow", .{sn});
                    for (p.slots_used.items) |u| if (eq(u, sn)) return p.failFmt(p.absolute(offset), "{{{s}}} appears more than once", .{sn});
                    try p.slots_used.append(p.a, sn);
                    try p.flush(&nodes, &run);
                    // At end: append to container, no anchor; middle: anchor, children inserted
                    // before it.
                    var k = p.pos;
                    while (k < p.source.len and std.ascii.isWhitespace(p.source[k])) k += 1;
                    if (std.mem.startsWith(u8, p.source[k..], "</")) {
                        slot_end = sn;
                    } else {
                        slot_mark = true;
                        has_elements = true;
                        try p.add(&nodes, try p.fmt("{s}ui.view.slotMark(&__yix_slot_{s}),", .{ try p.childBreak(0), sn }));
                    }
                    continue;
                }
                if (try p.optionalSlotGuard(expr)) |code| {
                    try p.flush(&nodes, &run);
                    has_elements = true;
                    try p.add(&nodes, try p.fmt("{s}{s},", .{ try p.childBreak(0), code }));
                    continue;
                }
                var q = try p.sub(expr);
                const t = q.token();
                if (t.tag == .keyword_if or t.tag == .keyword_for or t.tag == .keyword_switch or t.tag == .angle_bracket_left) {
                    try p.flush(&nodes, &run);
                    has_elements = true;
                    const c = q.control() catch |err| {
                        // Sub-parser diagnostics already converted to source offsets.
                        p.diagnostic = q.diagnostic;
                        return err;
                    };
                    try p.add(&nodes, try p.fmt("{s}{s},", .{ try p.childBreak(0), c }));
                    if (q.token().tag != .eof) return p.fail(offset, "unexpected tokens after control flow");
                } else try p.interpolate(&run, expr);
            } else {
                const start = p.pos;
                while (p.pos < p.source.len and p.source[p.pos] != '<' and p.source[p.pos] != '{') p.pos += 1;
                try p.appendText(&run, p.source[start..p.pos]);
            }
        }
        const tv = if (run.format.items.len != 0) try p.textValue(run) else null;
        const literal = try p.quote(run.literal.items);
        const args = run.args.items.len != 0;
        const identity = try p.a.dupe(u8, run.identity.items);
        if (args) try run.fragments.append(p.a, try p.a.dupe(u8, run.literal.items));
        const fragments = try p.a.dupe([]const u8, run.fragments.items);
        try p.flush(&nodes, &run);
        return .{ .fragments = fragments, .identity = identity, .nodes = nodes.items, .text = tv, .literal = literal, .args = args, .has_elements = has_elements, .slot_end = slot_end, .slot_mark = slot_mark };
    }
    fn previewStaticStyle(p: *Parser, raw: []const u8) Error!bool {
        var z = std.zig.Tokenizer.init(try p.a.dupeSentinel(u8, raw, 0));
        var tok = z.next();
        if (tok.tag == .identifier) {
            while (true) {
                tok = z.next();
                if (tok.tag == .eof) return true;
                if (tok.tag != .period or z.next().tag != .identifier) return false;
            }
        }
        if (tok.tag != .period or z.next().tag != .l_brace) return false;
        while (true) {
            tok = z.next();
            if (tok.tag == .r_brace) return z.next().tag == .eof;
            if (tok.tag != .period or z.next().tag != .identifier or z.next().tag != .equal) return false;
            tok = z.next();
            if (tok.tag == .period) {
                if (z.next().tag != .identifier) return false;
            } else if (tok.tag != .number_literal and !eq(raw[tok.loc.start..tok.loc.end], "true") and !eq(raw[tok.loc.start..tok.loc.end], "false")) return false;
            tok = z.next();
            if (tok.tag == .r_brace) return z.next().tag == .eof;
            if (tok.tag != .comma) return false;
        }
    }

    fn templateLiteral(p: *Parser, raw: []const u8) Error![]const u8 {
        const src = trim(raw);
        var z = std.zig.Tokenizer.init(try p.dup(src));
        const first = z.next();
        const second = z.next();
        if (second.tag == .eof) {
            if (first.tag == .string_literal) return p.fmt(".{{ .text = {s} }}", .{src});
            if (eq(src, "true") or eq(src, "false")) return p.fmt(".{{ .boolean = {s} }}", .{src});
            if (first.tag == .number_literal) return p.fmt(".{{ .number = {s} }}", .{src});
        }
        if (first.tag == .period and second.tag == .identifier and z.next().tag == .eof)
            return p.fmt(".{{ .enum_name = {s} }}", .{try p.quote(src[second.loc.start..second.loc.end])});
        return "null";
    }
    fn normalizedTokens(p: *Parser, raw: []const u8) Error![]const u8 {
        const src = try p.dup(try plain(p.a, raw));
        var z = std.zig.Tokenizer.init(src);
        var out: List(u8) = .empty;
        while (true) {
            const tok = z.next();
            if (tok.tag == .eof) break;
            if (tok.tag == .doc_comment or tok.tag == .container_doc_comment) continue;
            try p.add(&out, src[tok.loc.start..tok.loc.end]);
            try out.append(p.a, ' ');
        }
        return out.items;
    }
    fn sub(p: *Parser, s: []const u8) Error!Parser {
        return .{ .a = p.a, .module_path = p.module_path, .preview = p.preview, .catalog_prefixes = p.catalog_prefixes, .source = try p.dup(s), .origins = p.origins, .flow_seq = p.flow_seq, .symbols = p.symbols, .depth = p.depth, .loop_depth = p.loop_depth, .slotted = p.slotted, .slot_names = p.slot_names, .optional_slots = p.optional_slots, .in_branch = true, .template_path = p.template_path, .model_count = p.model_count };
    }
    fn branch(p: *Parser) Error![]const u8 {
        const start = p.token().loc.start;
        const at = if (p.preview) |c| c.ops.items.len else 0;
        const result = try p.branchInner();
        if (p.preview) |c| {
            const ops = try p.a.dupe(PreviewOp, c.ops.items[at..]);
            var key_tokens: []const u8 = "";
            if (ops.len != 0) {
                for (ops[0].attributes) |attribute| {
                    if (eq(attribute.name, "key")) key_tokens = attribute.value;
                }
                // The root's key is already validated as controller ABI. Keep
                // metadata aligned with the compiled root schema too.
                try c.regions.append(p.a, .{ .name = p.template_path, .start = p.absolute(start), .end = p.absolute(p.pos), .ops = ops, .isolated = !p.slotted, .key_tokens = key_tokens, .region = true });
            }
        }
        return result;
    }
    fn branchInner(p: *Parser) Error![]const u8 {
        if (p.token().tag == .angle_bracket_left) return p.element();
        // Nested control flow directly in branch ok (`if (h) for (xs) |x| <Row/>`) no wrapper box
        // needed.
        if (p.token().tag == .keyword_for) {
            const saved = p.for_in_branch;
            p.for_in_branch = true;
            defer p.for_in_branch = saved;
            const out = try p.control();
            if (p.token().tag == .keyword_else) return p.fail(p.pos, ambiguous_else);
            return out;
        }
        if (p.token().tag == .keyword_if or p.token().tag == .keyword_switch) return p.control();
        // `{if (d) "a" else "b"}` branch gives value: in attr (label={if...}) or <text>.
        if (p.token().tag == .string_literal or p.token().tag == .identifier or p.token().tag == .number_literal)
            return p.fail(p.pos, "a control-flow branch is an element or nested control flow, not a value; put a value in an attribute (label={if (d) \"a\" else \"b\"}) or inside <text>");
        return p.fail(p.pos, "control flow branches contain a tag or nested control flow");
    }
    fn control(p: *Parser) Error![]const u8 {
        const start = p.token().loc.start;
        const preview_start = if (p.preview) |c| c.ops.items.len else 0;
        const result = try p.controlBody();
        const raw = p.source[start..p.pos];
        const ctx = try p.context(try p.deps(raw), false);
        if (p.preview) |c| {
            c.ops.shrinkRetainingCapacity(preview_start);
            const dependencies = try p.deps(raw);
            const names = try p.a.alloc([]const u8, dependencies.len);
            for (dependencies, names) |symbol, *capture| capture.* = symbol.name;
            // Keep the full compiled token descriptor, plus a syntax-only
            // controller identity with branch bodies replaced by lexical ids.
            // Key expressions remain part of that identity, never body data.
            const identity = try p.previewIdentity(start, p.pos);
            try c.ops.append(p.a, .{ .kind = .hole, .path = p.template_path, .receiver = "control", .tokens = try p.normalizedTokens(raw), .identity_tokens = identity, .captures = names });
        }
        return p.fmt("ui.view.templateSite(.{{ .module = {s}, .path = {s}, .receiver = \"control\", .tokens = {s} }}, {s}, {s})", .{ try p.quote(p.module_path), try p.quote(p.template_path), try p.quote(try p.normalizedTokens(raw)), ctx, result });
    }
    fn previewIdentity(p: *Parser, start: usize, end: usize) Error![]const u8 {
        const c = p.preview orelse return p.normalizedTokens(p.source[start..end]);
        const begin = p.absolute(start);
        const limit = p.absolute(end);
        var identity: List(u8) = .empty;
        var cursor = begin;
        while (cursor < limit) {
            var nearest: ?PreviewComponent = null;
            for (c.regions.items) |region| {
                if (region.start < cursor or region.end > limit) continue;
                if (nearest == null or region.start < nearest.?.start or (region.start == nearest.?.start and region.end > nearest.?.end)) nearest = region;
            }
            if (nearest) |region| {
                try identity.appendSlice(p.a, try p.normalizedTokens(p.source[start + cursor - begin .. start + region.start - begin]));
                try identity.appendSlice(p.a, try p.fmt(" @region {s} @key {s} ", .{ region.name, region.key_tokens }));
                cursor = region.end;
            } else {
                try identity.appendSlice(p.a, try p.normalizedTokens(p.source[start + cursor - begin .. end]));
                break;
            }
        }
        return identity.items;
    }
    fn controlBody(p: *Parser) Error![]const u8 {
        p.depth += 1;
        defer p.depth -= 1;
        if (p.depth > 128) return p.fail(p.pos, "template nesting exceeds 128");
        const t = p.token();
        if (t.tag == .angle_bracket_left) return p.element();
        _ = p.take();
        const value = try p.balanced(.l_paren, .r_paren);
        // Branches generated as lazy functions (built when chosen in branch's scope),
        // all branches of same control flow share capture context.
        p.flow_seq.* += 1;
        const id = p.flow_seq.*;
        const saved_path = p.template_path;
        p.template_path = try p.fmt("{s}/{s}:{d}", .{ saved_path, @tagName(t.tag), id });
        defer p.template_path = saved_path;
        if (t.tag == .keyword_if) {
            const captured = try p.rowCaptures();
            const capture = try p.captureName();
            const yes = try p.lazyBranch(id, 0, capture);
            var no: []const u8 = "null";
            var err_capture = false;
            if (p.eat(.keyword_else)) {
                const err_name = try p.captureName();
                if (err_name != null and capture == null) return p.fail(p.pos, "else |err| needs if (x) |v| on an error union");
                err_capture = err_name != null;
                no = try p.lazyBranch(id, 1, err_name);
            }
            const ctx = try p.context(try p.usedCaptures(captured, &.{ yes, no }, &.{ (try p.branchNames(id, 0)).ctx, (try p.branchNames(id, 1)).ctx }), false);
            if (capture != null) return p.fmt("ui.view.lazyIfSome({s}, {s}, {s}, {s})", .{ try p.expression(value), ctx, yes, no });
            return p.fmt("ui.view.lazyIf({s}, {s}, {s}, {s})", .{ try p.expression(value), ctx, yes, no });
        }
        if (t.tag == .keyword_switch) {
            const captured = try p.rowCaptures();
            const names = try p.branchNames(id, 0);
            _ = try p.expect(.l_brace);
            var cases: List(u8) = .empty;
            var k: usize = 1;
            while (p.token().tag != .r_brace) : (k += 1) {
                const key = if (p.eat(.keyword_else)) "else" else blk: {
                    _ = try p.expect(.period);
                    break :blk try p.fmt(".{s}", .{p.word(try p.expect(.identifier))});
                };
                _ = try p.expect(.equal_angle_bracket_right);
                const payload = try p.captureName();
                if (payload != null and eq(key, "else")) return p.fail(p.pos, "the else branch of a switch has no payload to capture");
                // Branch with payload: payload is capture value following source (same tag payload
                // change doesn't rebuild branch).
                const pre = if (payload) |pn| try p.fmt("const {s} = try ui.view.branchValue(scope, {s}, ui.view.payloadOf(@TypeOf({s}.peek()), {s})); ", .{ pn, names.src, names.src, key }) else "";
                const case_path = p.template_path;
                p.template_path = try p.fmt("{s}/case:{s}", .{ case_path, key });
                const case_body = try p.branchBody(if (payload) |pn| &.{pn} else &.{});
                p.template_path = case_path;
                try p.add(&cases, try p.fmt(" {s} => {{ {s}return ui.view.emit(scope, cx, {s}, .{{ {s} }}); }},", .{ key, pre, names.sink, case_body }));
                if (!p.eat(.comma) and p.token().tag != .r_brace) return p.fail(p.pos, "expected comma after switch branch");
            }
            _ = p.take();
            const f = try p.wrapBranch(names, try p.fmt("switch ({s}) {{{s} }}", .{ names.tag, cases.items }), &.{}, true);
            const ctx = try p.context(try p.usedCaptures(captured, &.{f}, &.{names.ctx}), false);
            return p.fmt("ui.view.lazySwitch({s}, {s}, {s})", .{ try p.expression(value), ctx, f });
        }
        if (t.tag == .keyword_for) {
            p.loop_depth += 1;
            defer p.loop_depth -= 1;
            const range = rangeCount(p.a, value) catch |err| switch (err) {
                error.InvalidYix => return p.fail(p.pos, "loop ranges start at 0, as in for (0..n)"),
                else => return err,
            };
            if (range) |count| return p.repeatLoop(count);
            _ = try p.expect(.pipe);
            const item = p.word(try p.expect(.identifier));
            // `|item, i|`: i is index source for this row (reordered rows follow new position).
            const index: ?[]const u8 = if (p.eat(.comma)) p.word(try p.expect(.identifier)) else null;
            _ = try p.expect(.pipe);
            const old = p.symbols.items.len;
            const captured = try p.rowCaptures();
            // Isolate branch symbol storage: a child parser must not mutate its parent's list.
            p.symbols = try List(Symbol).initCapacity(p.a, old + 2);
            try p.symbols.appendSlice(p.a, captured[0..old]);
            // Row takes data source: same key update in-place (reads of item follow), don't
            // rebuild.
            try p.declare(.{ .name = item, .reactive = true, .source = true });
            if (index) |ix| try p.declare(.{ .name = ix, .reactive = true, .source = true });
            var row_key: ?[]const u8 = null;
            p.row_key = &row_key;
            const row = try p.branch();
            p.row_key = null;
            p.symbols.items.len = old;
            const row_ctx = try p.fmt("__yix_row_{d}", .{p.loop_depth});
            const row_scope = try p.fmt("__yix_scope_{d}", .{p.loop_depth});
            const row_cx = try p.fmt("__yix_cx_{d}", .{p.loop_depth});
            const row_body = try p.rowReferences(row, captured, row_ctx, row_scope, row_cx);
            const ctx = try p.context(try p.usedCaptures(captured, &.{row_body}, &.{row_ctx}), false);
            const unused_ctx = if (try containsName(p.a, row_body, row_ctx)) "" else try p.fmt("_ = {s}; ", .{row_ctx});
            const unused_item = if (try containsName(p.a, row_body, item)) "" else try p.fmt("_ = {s}; ", .{item});
            // List expr evaluated once, stored in local: row/key function types use
            // `@TypeOf(local)`.
            // Putting expr in type position copies derived block (has try) -- nested for, inner
            // list is outer
            // row's derived, compile fails.
            const items_expr = try p.expression(value);
            const items = try p.fmt("__yix_items_{d}", .{id});
            // Row key: default by item.id; `key={...}` only references loop var, hash by content
            // depth.
            const key_arg = if (row_key) |kexpr| blk: {
                for (try p.deps(kexpr)) |d| if (!eq(d.name, item)) return p.fail(p.pos, "a row key may only use the loop variable");
                break :blk try p.fmt("struct {{ fn __yix_k({s}: ui.view.yixItem(@TypeOf({s}))) u64 {{ return ui.view.keyOf({s}); }} }}.__yix_k", .{ item, items, try p.mark(trim(kexpr)) });
            } else ".id";
            const index_param = if (index) |ix| try p.fmt("{s}: ui.Source(usize), ", .{ix}) else "";
            const unused_index = if (index) |ix| (if (try containsName(p.a, row_body, ix)) "" else try p.fmt("_ = {s}; ", .{ix})) else "";
            var result = try p.fmt("__yix_e{d}: {{ const {s} = {s}; break :__yix_e{d} ui.view.eachWith({s}, {s}, {s}, struct {{ fn __yix_row({s}: anytype, {s}: ui.Source(ui.view.yixItem(@TypeOf({s}))), {s}{s}: *ui.Scope, {s}: *ui.Cx) anyerror!*ui.Node {{ {s}{s}{s}return ui.view.render({s}, {s}, {s}); }} }}.__yix_row); }}", .{ id, items, items_expr, id, ctx, items, key_arg, row_ctx, item, items, index_param, row_scope, row_cx, unused_ctx, unused_item, unused_index, row_scope, row_cx, row_body });
            if (p.for_in_branch and p.token().tag == .keyword_else) return p.fail(p.pos, ambiguous_else);
            if (p.eat(.keyword_else)) {
                const no = try p.lazyBranch(id, 1, null);
                const cond = try p.expression(try p.fmt("{s}.len != 0", .{trim(value)}));
                const yes = try p.wrapBranch(try p.branchNames(id, 0), try p.fmt("return ui.view.emit(scope, cx, {s}, .{{ {s} }});", .{ (try p.branchNames(id, 0)).sink, result }), &.{}, false);
                const used = try p.usedCaptures(try p.rowCaptures(), &.{ yes, no }, &.{ (try p.branchNames(id, 0)).ctx, (try p.branchNames(id, 1)).ctx });
                result = try p.fmt("ui.view.lazyIf({s}, {s}, {s}, {s})", .{ cond, try p.context(used, false), yes, no });
            }
            return result;
        }
        return p.fail(t.loc.start, "unknown template control flow");
    }

    /// `|name|`: branch capture (null when absent).
    fn captureName(p: *Parser) Error!?[]const u8 {
        if (!p.eat(.pipe)) return null;
        const n = p.word(try p.expect(.identifier));
        _ = try p.expect(.pipe);
        return n;
    }

    const BranchNames = struct { ctx: []const u8, scope: []const u8, cx: []const u8, sink: []const u8, tag: []const u8, src: []const u8 };
    /// Branch function param name: by control flow position in source + branch index, nested no
    /// collision.
    fn branchNames(p: *Parser, id: usize, k: usize) Error!BranchNames {
        return .{
            .ctx = try p.fmt("__yix_b{d}_{d}", .{ id, k }),
            .scope = try p.fmt("__yix_bs{d}_{d}", .{ id, k }),
            .cx = try p.fmt("__yix_bc{d}_{d}", .{ id, k }),
            .sink = try p.fmt("__yix_bk{d}_{d}", .{ id, k }),
            .tag = try p.fmt("__yix_bt{d}_{d}", .{ id, k }),
            .src = try p.fmt("__yix_bv{d}_{d}", .{ id, k }),
        };
    }

    /// Parse branch content (template elements or nested control flow); `caps` new capture names in
    /// branch (reactive sources).
    fn branchBody(p: *Parser, caps: []const []const u8) Error![]const u8 {
        const old = p.symbols.items.len;
        const captured = try p.rowCaptures();
        p.symbols = try List(Symbol).initCapacity(p.a, old + caps.len);
        try p.symbols.appendSlice(p.a, captured[0..old]);
        for (caps) |c| try p.declare(.{ .name = c, .reactive = true, .source = true });
        const content = try p.branch();
        p.symbols.items.len = old;
        return content;
    }

    /// Parse lazy branch, generate `fn (ctx, [captures,] scope, cx, sink) anyerror!void`.
    fn lazyBranch(p: *Parser, id: usize, k: usize, cap: ?[]const u8) Error![]const u8 {
        const names = try p.branchNames(id, k);
        const caps: []const []const u8 = if (cap) |c| &.{c} else &.{};
        const saved_path = p.template_path;
        p.template_path = try p.fmt("{s}/branch:{d}", .{ saved_path, k });
        defer p.template_path = saved_path;
        const content = try p.branchBody(caps);
        return p.wrapBranch(names, try p.fmt("return ui.view.emit(scope, cx, {s}, .{{ {s} }});", .{ names.sink, content }), caps, false);
    }

    /// Branch body (generated code referencing outer names, scope, cx) wrapped in fn: outer names
    /// become context
    /// fields, scope/cx become branch's. `switch_fn`: switchOn branch fn, takes tag+source params
    /// additionally.
    fn wrapBranch(p: *Parser, names: BranchNames, code: []const u8, caps: []const []const u8, switch_fn: bool) Error![]const u8 {
        const captured = try p.rowCaptures();
        const renamed = try p.rowReferences(code, captured, names.ctx, names.scope, names.cx);
        var params: List(u8) = .empty;
        try p.add(&params, try p.fmt("{s}: anytype, ", .{names.ctx}));
        if (switch_fn) try p.add(&params, try p.fmt("{s}: anytype, {s}: anytype, ", .{ names.tag, names.src }));
        for (caps) |c| try p.add(&params, try p.fmt("{s}: anytype, ", .{c}));
        var unused: List(u8) = .empty;
        if (!try containsName(p.a, renamed, names.ctx)) try p.add(&unused, try p.fmt("_ = {s}; ", .{names.ctx}));
        if (switch_fn and !try containsName(p.a, renamed, names.src)) try p.add(&unused, try p.fmt("_ = {s}; ", .{names.src}));
        for (caps) |c| if (!try containsName(p.a, renamed, c)) try p.add(&unused, try p.fmt("_ = {s}; ", .{c}));
        return p.fmt("struct {{ fn __yix_b({s}{s}: *ui.Scope, {s}: *ui.Cx, {s}: ui.view.Sink) anyerror!void {{ {s}{s} }} }}.__yix_b", .{ params.items, names.scope, names.cx, names.sink, unused.items, renamed });
    }

    /// Row-captured outer names: component symbols, plus Bound of controlled values (row events
    /// need Bound for controlled values).
    fn rowCaptures(p: *Parser) Error![]Symbol {
        var out: List(Symbol) = .empty;
        try out.appendSlice(p.a, p.symbols.items);
        for (p.symbols.items) |sym| if (sym.model) {
            try out.append(p.a, .{ .name = try p.fmt("__yix_model_{s}", .{sym.name}), .reactive = false });
        };
        return out.items;
    }

    /// `{for (0..n) |i| <Row/>}`: expand by count (view.repeat), row no identity, no keyed
    /// reconcile;
    /// n can depend on props/signals: static once, changes rebuild whole.
    fn repeatLoop(p: *Parser, count_raw: []const u8) Error![]const u8 {
        const raw_count = trim(count_raw);
        try p.requireSimpleExpression(raw_count);
        const count = if (try p.reactive(raw_count)) try p.expression(raw_count) else try p.fmt("@as(usize, {s})", .{raw_count});
        _ = try p.expect(.pipe);
        const index = p.word(try p.expect(.identifier));
        _ = try p.expect(.pipe);
        const old = p.symbols.items.len;
        const captured = try p.rowCaptures();
        p.symbols = try List(Symbol).initCapacity(p.a, old + 1);
        try p.symbols.appendSlice(p.a, captured[0..old]);
        if (!eq(index, "_")) try p.declare(.{ .name = index, .reactive = false });
        const row = try p.branch();
        p.symbols.items.len = old;
        if (p.token().tag == .keyword_else) return p.fail(p.pos, "for (0..n) takes no else branch");
        const row_ctx = try p.fmt("__yix_row_{d}", .{p.loop_depth});
        const row_scope = try p.fmt("__yix_scope_{d}", .{p.loop_depth});
        const row_cx = try p.fmt("__yix_cx_{d}", .{p.loop_depth});
        const row_body = try p.rowReferences(row, captured, row_ctx, row_scope, row_cx);
        const ctx = try p.context(try p.usedCaptures(captured, &.{row_body}, &.{row_ctx}), false);
        const unused_ctx = if (try containsName(p.a, row_body, row_ctx)) "" else try p.fmt("_ = {s}; ", .{row_ctx});
        const index_param = if (eq(index, "_") or !try containsName(p.a, row_body, index)) "_" else index;
        return p.fmt("ui.view.repeat({s}, {s}, struct {{ fn __yix_row({s}: anytype, {s}: usize, {s}: *ui.Scope, {s}: *ui.Cx) anyerror!*ui.Node {{ {s}return ui.view.render({s}, {s}, {s}); }} }}.__yix_row)", .{ ctx, count, row_ctx, index_param, row_scope, row_cx, unused_ctx, row_scope, row_cx, row_body });
    }

    /// Rewrite outer name refs in row body to row context field (`count` -> `__yix_row_1.count`),
    /// scope/cx to
    /// row's. Row body is marked-up generated code: split by marks then tokenize each (marks always
    /// wrap
    /// complete token or source span); rename inside byte-exact segment splits it, keep each
    /// segment byte-exact to source.
    fn rowReferences(p: *Parser, row: []const u8, captured: []const Symbol, ctx: []const u8, scope: []const u8, cx: []const u8) Error![]const u8 {
        const Open = struct { source: usize, exact: bool, consumed: usize };
        var stack: List(Open) = .empty;
        var out: List(u8) = .empty;
        var i: usize = 0;
        var chunk_start: usize = 0;
        // "Previous token is dot" spans blocks: `item.title` three tokens each marked.
        var prev: Token.Tag = .eof;
        while (i <= row.len) {
            const at_end = i == row.len;
            const c: u8 = if (at_end) 0 else row[i];
            if (at_end or c == mark_open or c == mark_point or c == mark_component or c == mark_close) {
                const chunk = row[chunk_start..i];
                const top: ?*Open = if (stack.items.len == 0) null else &stack.items[stack.items.len - 1];
                const seg_source: ?usize = if (top) |t| (if (t.exact) t.source + t.consumed else null) else null;
                try p.renameRowChunk(&out, chunk, captured, ctx, scope, cx, &prev, seg_source);
                if (top) |t| t.consumed += chunk.len;
                if (at_end) break;
                if (c == mark_close) {
                    const done = stack.pop().?;
                    if (stack.items.len != 0) stack.items[stack.items.len - 1].consumed += done.consumed;
                    try out.append(p.a, c);
                    i += 1;
                } else {
                    const header_end = std.mem.indexOfScalarPos(u8, row, i + 1, mark_text).? + 1;
                    const src = markSource(row[i + 1 .. header_end - 1]).source;
                    if (c != mark_component) try stack.append(p.a, .{ .source = src, .exact = c == mark_open, .consumed = 0 });
                    try p.add(&out, row[i..header_end]);
                    i = header_end;
                }
                chunk_start = i;
            } else i += 1;
        }
        return out.items;
    }

    /// `seg_source`: when block in byte-exact segment, source offset for block start (rename uses
    /// to split segment).
    fn renameRowChunk(p: *Parser, out: *List(u8), row: []const u8, captured: []const Symbol, ctx: []const u8, scope: []const u8, cx: []const u8, prev_tag: *Token.Tag, seg_source: ?usize) Error!void {
        if (row.len == 0) return;
        var z = std.zig.Tokenizer.init(try p.a.dupeSentinel(u8, row, 0));
        var at: usize = 0;
        var prev = prev_tag.*;
        defer prev_tag.* = prev;
        while (true) {
            const t = z.next();
            if (t.tag == .eof) break;
            const name = row[t.loc.start..t.loc.end];
            var replacement: ?[]const u8 = null;
            // `fn b(` / `fn row(` generated fn name, not outer local reference.
            if (t.tag == .identifier and prev != .period and prev != .keyword_fn) {
                if (eq(name, "scope")) replacement = scope else if (eq(name, "cx")) replacement = cx else {
                    for (captured) |sym| if (eq(name, sym.name)) {
                        replacement = try p.fmt("{s}.{s}", .{ ctx, name });
                        break;
                    };
                }
            }
            if (replacement) |r| {
                try p.add(out, row[at..t.loc.start]);
                if (seg_source) |src| {
                    // Split segment: close byte-exact -> synthetic prefix -> name own segment ->
                    // reopen catch rest.
                    const name_src = src + t.loc.start;
                    const prefix = r[0 .. r.len - name.len];
                    const keeps_name = std.mem.endsWith(u8, r, name);
                    try out.append(p.a, mark_close);
                    if (keeps_name) {
                        try p.add(out, prefix);
                        try p.add(out, try p.fmt("{c}{d}{c}{s}{c}", .{ mark_open, name_src, mark_text, name, mark_close }));
                    } else try p.add(out, try p.fmt("{c}{d}{c}{s}{c}", .{ mark_point, name_src, mark_text, r, mark_close }));
                    try p.add(out, try p.fmt("{c}{d}{c}", .{ mark_open, src + t.loc.end, mark_text }));
                } else try p.add(out, r);
                at = t.loc.end;
            }
            prev = t.tag;
        }
        try p.add(out, row[at..]);
    }

    fn handler(p: *Parser, raw: []const u8, host: bool) Error![]const u8 {
        // Explicit ui.on.* (set/toggle ...) ready handlers: pass as-is, with mapping (zig error ->
        // .yix);
        // args not rewritten reactively.
        if (std.mem.startsWith(u8, trim(raw), "ui.on.")) {
            try p.rejectEnv(trim(raw));
            return p.mark(trim(raw));
        }
        // Callback param component receives: pass to child as-is.
        if (p.lookup(trim(raw))) |sym| if (sym.handler) return p.mark(trim(raw));
        return p.statements(raw, if (host) .host_event else .event);
    }

    /// Where stmt blocks used: event handlers (host/component), effect (reads track deps),
    /// mount/unmount once.
    const StatementMode = enum { host_event, event, effect, mount, unmount };

    /// Compile event stmt (single or `{ a; b; }` block), wrap by use into handler/effect/lifecycle
    /// callback.
    fn statements(p: *Parser, raw: []const u8, mode: StatementMode) Error![]const u8 {
        const host = mode == .host_event;
        p.track_reads = mode == .effect;
        defer p.track_reads = false;
        p.effect_reads = .empty;
        p.effect_writes = .empty;
        // Multi-stmt block: `onClick={{ a; b; }}` (outer braces attr value, inner Zig block);
        // single layer braces with one stmt only.
        var block = raw.len > 1 and raw[0] == '{' and raw[raw.len - 1] == '}';
        var expr = trim(if (block) raw[1 .. raw.len - 1] else raw);
        // `|v| stmt`: event value binding (component events only).
        var capture: ?[]const u8 = null;
        {
            var z = std.zig.Tokenizer.init(try p.a.dupeSentinel(u8, expr, 0));
            const t0 = z.next();
            if (t0.tag == .pipe) {
                if (host) return p.fail(p.pos, "this host event carries no value; |e| works on onKeyDown / onKeyUp / onPointerDown / onPointerMove / onPointerUp / onScroll and component events");
                if (mode != .host_event and mode != .event) return p.fail(p.pos, "effect / onMount / onUnmount take no |value| capture");
                const name_t = z.next();
                const close = z.next();
                if (name_t.tag != .identifier or close.tag != .pipe) return p.fail(p.pos, "expected |name| before the event statement");
                const cap = expr[name_t.loc.start..name_t.loc.end];
                if (p.lookup(cap) != null) return p.fail(p.pos, "shadowed local names are not supported yet");
                capture = cap;
                expr = trim(expr[close.loc.end..]);
                if (expr.len > 1 and expr[0] == '{' and expr[expr.len - 1] == '}') {
                    expr = trim(expr[1 .. expr.len - 1]);
                    block = true;
                }
            }
        }
        var event_tokens = std.zig.Tokenizer.init(try p.a.dupeSentinel(u8, expr, 0));
        while (true) {
            const t = event_tokens.next();
            switch (t.tag) {
                .eof => break,
                .keyword_var, .keyword_fn, .keyword_for, .keyword_while, .keyword_switch => return p.fail(p.pos, "events support function calls, simple signal assignments, const locals, try and if / else"),
                else => {},
            }
        }
        const ds = try p.deps(expr);
        // Writing a controlled value needs its Bound and the paired onXChange / onChange callback:
        // put them into the handler context as well.
        var extra: List(Symbol) = .empty;
        try extra.appendSlice(p.a, ds);
        for (ds) |sym| if (sym.model) {
            try extra.append(p.a, .{ .name = try p.fmt("__yix_model_{s}", .{sym.name}), .reactive = false });
            if (p.changeHandler(sym.name)) |h| {
                var present = false;
                for (extra.items) |e| present = present or eq(e.name, h);
                if (!present) try extra.append(p.a, .{ .name = h, .reactive = false, .handler = true });
            }
        };
        const ctx = try p.context(extra.items, true);
        var out: List(u8) = .empty;
        var at: usize = 0;
        if (block) {
            while (try p.eventStatement(expr, &at, &out)) {}
        } else if (try p.eventStatement(expr, &at, &out)) {
            while (at < expr.len and (std.ascii.isWhitespace(expr[at]) or expr[at] == ';')) at += 1;
            if (at < expr.len) return p.fail(p.pos, "several event statements go in a block: onClick={{ a; b; }}");
        }
        if (mode == .effect) for (p.effect_writes.items) |w| for (p.effect_reads.items) |r| if (eq(w, r))
            return p.failFmt(p.absolute(p.pos), "the effect writes `{s}` and also reads it, so every write re-runs the effect; read the old value with `{s} += …` (not tracked) or move the write out of the effect", .{ w, w });
        const batch = "__yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); ";
        const params = if (capture) |cap| try p.fmt("__yix_ctx: anytype, {s}: anytype", .{cap}) else "__yix_ctx: anytype";
        // Handler try: stmt in fallible inner fn, fail via ui.on.reportError (handler can't return
        // error).
        const fallible = blk: {
            var z = std.zig.Tokenizer.init(try p.a.dupeSentinel(u8, expr, 0));
            while (true) {
                const t = z.next();
                if (t.tag == .eof) break :blk false;
                if (t.tag == .keyword_try) break :blk true;
            }
        };
        const hook = if (mode == .mount or mode == .unmount)
            try p.fmt("if (comptime @import(\"builtin\").is_test) __yix_ctx.__yix_owner.recordTestHook(.{s}); ", .{p.event_name})
        else
            "";
        const run = if (fallible and mode == .mount)
            try p.fmt("struct {{ fn __yix_run({s}) anyerror!void {{ {s}{s} }} }}.__yix_run", .{ params, try p.fmt("{s}{s}", .{ hook, batch }), out.items })
        else if (fallible)
            try p.fmt("struct {{ fn __yix_run({s}) void {{ body({s}) catch |err| ui.on.reportError(\"{s}\", err); }} fn body({s}) anyerror!void {{ {s}{s} }} }}.__yix_run", .{ params, if (capture) |cap| try p.fmt("__yix_ctx, {s}", .{cap}) else "__yix_ctx", p.event_name, params, try p.fmt("{s}{s}", .{ hook, batch }), out.items })
        else
            try p.fmt("struct {{ fn __yix_run({s}) void {{ {s}{s} }} }}.__yix_run", .{ params, try p.fmt("{s}{s}", .{ hook, batch }), out.items });
        return switch (mode) {
            .host_event => p.fmt("try ui.on.bind(scope, {s}, {s})", .{ ctx, run }),
            .event => p.fmt("try ui.on.bindAny(scope, {s}, {s})", .{ ctx, run }),
            // effect built -> run once, rerun on source changes; belongs to component scope,
            // destroyed on unmount.
            .effect => p.fmt("    try ui.view.setupEffect(scope, {s}, {s});\n", .{ ctx, run }),
            .mount => p.fmt("    try ui.view.runLifecycleAction(scope, \"{s}\", {s}, {s});\n", .{ p.event_name, ctx, run }),
            .unmount => p.fmt("    try ui.view.setupCleanup(scope, {s}, {s});\n", .{ ctx, run }),
        };
    }
    /// Compile event stmt at `text[at.*..]`, advance `at`; false if no stmt.
    /// Stmt is `if (cond) stmt|block [else stmt|block]`, signal/controlled assign, or call.
    fn eventStatement(p: *Parser, text: []const u8, at: *usize, out: *List(u8)) Error!bool {
        while (at.* < text.len and (std.ascii.isWhitespace(text[at.*]) or text[at.*] == ';')) at.* += 1;
        if (at.* >= text.len) return false;
        var q = try p.sub(text[at.*..]);
        q.model_count = p.model_count;
        const first = q.token();
        if (first.tag == .keyword_if) {
            _ = q.take();
            const cond = try q.balanced(.l_paren, .r_paren);
            try p.add(out, try p.fmt("if ({s}) {{ ", .{try p.rewrite(trim(cond), true, p.track_reads)}));
            at.* += q.pos;
            try p.eventBranch(text, at, out);
            try p.add(out, "} ");
            // else follows branch (like Zig); `if (a) x = 1; else y = 2` not valid Zig, suggest
            // fix.
            // Branch single-stmt eats own semicolon, so pre-else semicolon look back.
            var back = at.*;
            while (back > 0 and std.ascii.isWhitespace(text[back - 1])) back -= 1;
            var semicolon = back > 0 and text[back - 1] == ';';
            var r = try p.sub(text[at.*..]);
            if (r.token().tag == .semicolon) {
                _ = r.take();
                semicolon = true;
            }
            if (r.token().tag != .keyword_else) {
                r = try p.sub(text[at.*..]);
            } else if (semicolon) return p.fail(p.pos, "`; else` is not valid Zig: write `if (a) x = 1 else y = 2`, or use blocks `if (a) { … } else { … }`");
            if (r.token().tag == .keyword_else) {
                _ = r.take();
                at.* += r.pos;
                try p.add(out, "else { ");
                try p.eventBranch(text, at, out);
                try p.add(out, "} ");
            }
            return true;
        }
        if (first.tag == .keyword_else) return p.fail(p.pos, "else without a matching if in an event");
        // One simple stmt: to top-level semicolon, end, or belongs to outer if else.
        // Inner if expr (`x = if (c) 1 else 2`) has own else, doesn't end stmt.
        var level: usize = 0;
        var open_ifs: usize = 0;
        while (q.token().tag != .eof) {
            const x = q.token();
            if (level == 0 and x.tag == .semicolon) break;
            if (level == 0 and x.tag == .keyword_else) {
                if (open_ifs == 0) break;
                open_ifs -= 1;
            }
            if (level == 0 and x.tag == .keyword_if) open_ifs += 1;
            _ = q.take();
            switch (x.tag) {
                .l_paren, .l_brace, .l_bracket => level += 1,
                .r_paren, .r_brace, .r_bracket => {
                    if (level == 0) return p.fail(p.pos, "unbalanced event statement");
                    level -= 1;
                },
                else => {},
            }
        }
        if (level != 0) return p.fail(p.pos, "unbalanced event statement");
        if (open_ifs != 0) return p.fail(p.pos, "an if expression in an event statement needs an else");
        const statement = trim(text[at.* .. at.* + q.pos]);
        at.* += q.pos;
        if (at.* < text.len and text[at.*] == ';') at.* += 1;
        try p.simpleEventStatement(statement, out);
        return true;
    }

    /// if/else branch: `{ multiple }` or single stmt.
    fn eventBranch(p: *Parser, text: []const u8, at: *usize, out: *List(u8)) Error!void {
        var q = try p.sub(text[at.*..]);
        // `if (a) ;` not empty branch in Zig; don't eat semicolon binding next.
        if (q.token().tag == .semicolon or q.token().tag == .eof) return p.fail(p.pos, "if needs a statement");
        if (q.token().tag == .l_brace) {
            const block = try q.balanced(.l_brace, .r_brace);
            at.* += q.pos;
            var inner: usize = 0;
            while (try p.eventStatement(block, &inner, out)) {}
            return;
        }
        if (!try p.eventStatement(text, at, out)) return p.fail(p.pos, "if needs a statement");
    }

    fn simpleEventStatement(p: *Parser, statement: []const u8, out: *List(u8)) Error!void {
        var q = try p.sub(statement);
        const first = q.take();
        if (first.tag == .keyword_const) {
            // const local in handler: visible later in stmts, can't shadow component names.
            const name = q.word(try q.expect(.identifier));
            if (p.lookup(name) != null) return p.fail(p.pos, "shadowed local names are not supported yet");
            if (eq(name, "cx") or eq(name, "scope") or std.mem.startsWith(u8, name, "__yix_")) return p.fail(p.pos, "this name is reserved in a Yix component");
            const ty = if (q.eat(.colon)) try q.spanTo(.equal) else "";
            _ = try q.expect(.equal);
            const value = try p.rewrite(trim(statement[q.pos..]), true, p.track_reads);
            if (ty.len == 0) return p.add(out, try p.fmt("const {s} = {s}; ", .{ name, value }));
            return p.add(out, try p.fmt("const {s}: {s} = {s}; ", .{ name, try p.mark(ty), value }));
        }
        const sym = if (first.tag == .identifier) p.lookup(q.word(first)) else null;
        const op = q.token();
        const assign = op.tag == .equal or op.tag == .plus_equal or op.tag == .minus_equal or op.tag == .asterisk_equal or op.tag == .slash_equal;
        if (sym != null and assign) {
            if (!sym.?.writable) return p.fail(p.pos, "cannot assign to a computed value or read-only prop");
            if (p.track_reads) try p.effect_writes.append(p.a, sym.?.name);
            _ = q.take();
            const rhs = try p.rewrite(trim(statement[q.pos..]), true, p.track_reads);
            const s = sym.?.name;
            // Assign target uses source text here (with mapping), jump/hover/rename lands right.
            const target = try p.mark(q.word(first));
            const next = if (op.tag == .equal) rhs else try p.fmt("__yix_ctx.{s}.peek() {s} ({s})", .{ target, q.word(op)[0..1], rhs });
            if (sym.?.model) {
                const cb = if (p.changeHandler(s)) |h| try p.fmt("__yix_ctx.{s}", .{h}) else "null";
                try p.add(out, try p.fmt("__yix_ctx.__yix_model_{s}.propose({s}, {s}); ", .{ s, next, cb }));
            } else try p.add(out, try p.fmt("__yix_ctx.{s}.set({s}); ", .{ target, next }));
            return;
        }
        if (sym != null and sym.?.handler) {
            // Forward to component's callback: `onClick` / `onChange(v)`, optional null does
            // nothing.
            const target = try p.rewrite(q.word(first), true, p.track_reads);
            if (op.tag == .eof) return p.add(out, try p.fmt("ui.on.fire({s}, .{{}}); ", .{target}));
            if (op.tag != .l_paren) return p.fail(p.pos, "a callback in an event statement is called as `onX` or `onX(value)`");
            // Args: parens exactly wrap whole (`onX(a)(b)`, `onX(f(x)` no), top-level at most one
            // value.
            var depth: usize = 0;
            var commas: usize = 0;
            var close: ?usize = null;
            while (true) {
                const t = q.take();
                switch (t.tag) {
                    .eof => break,
                    .l_paren, .l_bracket, .l_brace => depth += 1,
                    .r_paren, .r_bracket, .r_brace => {
                        if (depth == 0) return p.fail(p.pos, "unbalanced parentheses in a callback call");
                        depth -= 1;
                        if (depth == 0 and t.tag == .r_paren and close == null) close = t.loc.start;
                    },
                    .comma => if (depth == 1) {
                        commas += 1;
                    },
                    else => if (close != null) return p.fail(p.pos, "a callback call must be the whole statement: `onX(value)`"),
                }
                if (close != null and depth == 0 and t.tag != .r_paren) return p.fail(p.pos, "a callback call must be the whole statement: `onX(value)`");
            }
            const end = close orelse return p.fail(p.pos, "unbalanced parentheses in a callback call");
            if (end + 1 != statement.len and trim(statement[end + 1 ..]).len != 0) return p.fail(p.pos, "a callback call must be the whole statement: `onX(value)`");
            if (commas != 0) return p.fail(p.pos, "a callback takes at most one value: `onX(value)`");
            const inner = trim(statement[op.loc.start + 1 .. end]);
            const args = if (inner.len == 0) "" else try p.rewrite(inner, true, p.track_reads);
            return p.add(out, try p.fmt("ui.on.fire({s}, .{{{s}}}); ", .{ target, args }));
        }
        // `if (c) {{ a; b; }}`: block one `{ ... }` layer; `onX={{ ... }}` double braces attr +
        // block layer.
        if (std.mem.startsWith(u8, trim(statement), "{")) return p.fail(p.pos, "a block inside an event statement is written `{ a; b; }`; the doubled braces of onX={{ a; b; }} are the attribute's braces around one block");
        for (try p.deps(statement)) |d| if (d.reactive and try containsAssignment(p.a, statement)) return p.fail(p.pos, "field writes and nested event statements are not implemented");
        const rewritten = try p.rewrite(statement, true, p.track_reads);
        try p.add(out, try p.fmt("{s}{s}; ", .{ rewritten, if (first.tag == .identifier and eq(statement, q.word(first))) "()" else "" }));
    }

    /// Controlled `x` land callback: `onXChange`, or single Model component `onChange`.
    fn changeHandler(p: *Parser, name: []const u8) ?[]const u8 {
        var buf: [96]u8 = undefined;
        if (name.len + 8 <= buf.len) {
            const cand = std.fmt.bufPrint(&buf, "on{c}{s}Change", .{ std.ascii.toUpper(name[0]), name[1..] }) catch unreachable;
            for (p.symbols.items) |sym| if (sym.handler and eq(sym.name, cand)) return sym.name;
        }
        if (p.model_count == 1) {
            for (p.symbols.items) |sym| if (sym.handler and eq(sym.name, "onChange")) return sym.name;
        }
        return null;
    }

    fn quote(p: *Parser, s: []const u8) Error![]const u8 {
        var out: List(u8) = .empty;
        try p.add(&out, "\"");
        for (s) |c| switch (c) {
            '\\' => try p.add(&out, "\\\\"),
            '"' => try p.add(&out, "\\\""),
            '\n' => try p.add(&out, "\\n"),
            '\r' => try p.add(&out, "\\r"),
            '\t' => try p.add(&out, "\\t"),
            else => try out.append(p.a, c),
        };
        try p.add(&out, "\"");
        return out.items;
    }
};
/// `0..n` loop range: return n source; not range null. Start only supports 0.
const ambiguous_else = "ambiguous else after a for nested in a branch (for's empty-list fallback vs the if's else); write the two cases as separate {if}s, or put the for inside an element";

fn rangeCount(a: Allocator, value: []const u8) Error!?[]const u8 {
    var z = std.zig.Tokenizer.init(try a.dupeSentinel(u8, value, 0));
    var depth: usize = 0;
    while (true) {
        const t = z.next();
        switch (t.tag) {
            .eof => return null,
            .l_paren, .l_bracket, .l_brace => depth += 1,
            .r_paren, .r_bracket, .r_brace => depth -|= 1,
            .ellipsis2 => if (depth == 0) {
                if (!eq(trim(value[0..t.loc.start]), "0")) return error.InvalidYix;
                return value[t.loc.end..];
            },
            else => {},
        }
    }
}

/// `onClick` / `onClose` / `onChange` ...: on + capital = event. Typed host events (view
/// KeyPress/Pointer/Scroll) have value.
fn isTypedHostEvent(key: []const u8) bool {
    for ([_][]const u8{ "onKeyDown", "onKeyUp", "onPointerDown", "onPointerMove", "onPointerUp", "onScroll" }) |k| {
        if (eq(k, key)) return true;
    }
    return false;
}
/// What form is value in `onX={...}` on component element: event stmt only (assign/block/`;`/`|v|`
/// binding/leading `try`), literal (value only), or ambiguous expr (save/save() may be event, flag/
/// isTop()/-1/!on may be data param value)?
const EventForm = enum { statement, literal, either };
fn eventForm(raw: []const u8) EventForm {
    const s = trim(raw);
    if (s.len == 0 or s[0] == '{' or s[0] == '|') return .statement;
    var buf: [4096]u8 = undefined;
    if (s.len >= buf.len) return .either;
    @memcpy(buf[0..s.len], s);
    buf[s.len] = 0;
    var z = std.zig.Tokenizer.init(buf[0..s.len :0]);
    var n: usize = 0;
    var first: Token.Tag = .eof;
    var depth: usize = 0;
    while (true) : (n += 1) {
        const t = z.next();
        if (t.tag == .eof) break;
        if (n == 0) first = t.tag;
        switch (t.tag) {
            .l_paren, .l_bracket, .l_brace => depth += 1,
            .r_paren, .r_bracket, .r_brace => depth -|= 1,
            // Assign and stmt separator only appear in event stmts.
            .semicolon, .equal, .plus_equal, .minus_equal, .asterisk_equal, .slash_equal, .percent_equal, .pipe_equal, .ampersand_equal, .caret_equal, .angle_bracket_angle_bracket_left_equal, .angle_bracket_angle_bracket_right_equal => if (depth == 0) return .statement,
            else => {},
        }
    }
    if (first == .keyword_try) return .statement;
    if (n == 1) switch (first) {
        .number_literal, .string_literal, .char_literal => return .literal,
        .identifier => if (eq(s, "true") or eq(s, "false") or eq(s, "null") or eq(s, "undefined")) return .literal,
        else => {},
    };
    // `.option`: enum literal.
    if (n == 2 and first == .period) return .literal;
    return .either;
}

fn isEventKey(key: []const u8) bool {
    return key.len > 2 and std.mem.startsWith(u8, key, "on") and std.ascii.isUpper(key[2]);
}
fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}
fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
/// Text after stripping mapping markers (used scanning tokens over generated code).
fn plain(a: Allocator, s: []const u8) Error![]const u8 {
    if (std.mem.indexOfAny(u8, s, &.{ mark_open, mark_close, mark_point, mark_component }) == null) return s;
    var out: List(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c == mark_open or c == mark_point or c == mark_component) {
            i = std.mem.indexOfScalarPos(u8, s, i + 1, mark_text).? + 1;
        } else if (c == mark_close) {
            i += 1;
        } else {
            try out.append(a, c);
            i += 1;
        }
    }
    return out.items;
}

fn containsName(a: Allocator, raw: []const u8, name: []const u8) Error!bool {
    const expr = try plain(a, raw);
    var z = std.zig.Tokenizer.init(try a.dupeSentinel(u8, expr, 0));
    while (true) {
        const t = z.next();
        if (t.tag == .eof) return false;
        if (t.tag == .identifier and eq(expr[t.loc.start..t.loc.end], name)) return true;
    }
}
fn containsAssignment(a: Allocator, raw: []const u8) Error!bool {
    const s = try plain(a, raw);
    var z = std.zig.Tokenizer.init(try a.dupeSentinel(u8, s, 0));
    while (true) {
        const t = z.next();
        switch (t.tag) {
            .eof => return false,
            .equal, .plus_equal, .minus_equal, .asterisk_equal, .slash_equal => return true,
            else => {},
        }
    }
}

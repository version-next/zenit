/// Markdown read-only renderer（只渲染，不编辑）
///
/// 面向场景：tooltip 富文本、about / settings 页的简单文档展示、
/// 任何"展示一段已有 markdown 字符串"的场景。**不**面向 WYSIWYG 编辑,
/// 真正的编辑器需要 parser 与编辑耦合，那是构建在 zenit 之上的应用代码。
///
/// 设计原则：
/// - 一趟字节扫描 -> 扁平 Block 数组（每个 Block 内嵌 Inline 片段）
/// - Inline 片段用 TextSpan 渲染（bold/italic/code）而不是拆多个 text node
/// - `![alt](data:...)` 直接降级为 `[alt]` 文本 chip，绝不真拉图像
/// - `<http://...>` autolinks 不展开，flatten 成普通文本
/// - 未闭合 fence / 畸形输入 fuzz-safe：末尾收尾时强制 flush
///
/// 不支持（显式非目标）：
///   - 嵌套列表、setext heading、task list、footnote、definition list、HTML 穿透
///   - table（要支持 table 请用专门的 markdown 编辑器实现）
///   - 图像真加载
///
/// 消费者：
/// ```zig
/// const result = try markdown.Markdown(text, .{
///     .base_font_size = 12,
///     .theme = my_theme,
/// }).render(cx);
/// try parent.appendChild(cx.allocator, result.root);
/// ```
const std = @import("std");
const core = @import("../../core.zig");

const Cx = core.Cx;
const Node = core.Node;
const Color = core.Color;
const Padding = core.Padding;
const TextSpan = core.TextSpan;
const box = core.box;

// ============================================================================
// 公共 API
// ============================================================================

pub const MarkdownOptions = struct {
    base_font_size: f32 = 12,
    /// code 区域的字号（默认比正文小一点）
    code_font_size: f32 = 11,
    /// 正文颜色
    text_color: Color = Color.hex(0x1F1F1F),
    /// inline code / fenced code 的字体颜色
    code_color: Color = Color.hex(0x2F2F35),
    /// inline code / fenced code 的背景
    code_bg: Color = Color.hex(0xF5F5F7),
    /// link 文本颜色
    link_color: Color = Color.hex(0x0B63CE),
    /// 水平分隔线颜色
    rule_color: Color = Color.hex(0xE0E0E4),
    /// heading 颜色（若 null 继承 text_color）
    heading_color: ?Color = null,
    /// 段落之间的垂直间距
    paragraph_gap: f32 = 4,
    /// code block 内的行距
    code_line_height: f32 = 1.35,
    /// 正文行距
    line_height: f32 = 1.4,
};

pub const MarkdownResult = struct {
    root: *Node,
};

// ============================================================================
// 样式层已析出到 styles.zig, emitter 只消费，本文件不做视觉决策
// ============================================================================

const styles = @import("styles.zig");
const mdRootStyle = styles.mdRootStyle;
const mdHeadingSizeMul = styles.mdHeadingSizeMul;
const mdCodeBlockStyle = styles.mdCodeBlockStyle;
const mdCodeLineText = styles.mdCodeLineText;
const mdRuleStyle = styles.mdRuleStyle;
const mdBlockquoteStyle = styles.mdBlockquoteStyle;
const mdBlockquoteBarStyle = styles.mdBlockquoteBarStyle;
const mdBlockquoteBodyStyle = styles.mdBlockquoteBodyStyle;
const mdListRowStyle = styles.mdListRowStyle;
const mdListMarkerText = styles.mdListMarkerText;
const mdCodeSpanStyle = styles.mdCodeSpanStyle;
const mdImageChipSpanStyle = styles.mdImageChipSpanStyle;
const mdLinkSpanStyle = styles.mdLinkSpanStyle;
const mdBoldSpanStyle = styles.mdBoldSpanStyle;
const mdItalicSpanStyle = styles.mdItalicSpanStyle;

pub const MarkdownBuilder = struct {
    text: []const u8,
    opts: MarkdownOptions,

    pub fn render(self: MarkdownBuilder, cx: *Cx) !MarkdownResult {
        const container = try box(cx, mdRootStyle(self.opts), .{});
        // sweep：renderInto 中途失败时 container（连同已挂上的块）不能漏
        errdefer cx.freeNode(container);
        try renderInto(cx, container, self.text, self.opts);
        return .{ .root = container };
    }
};

pub fn Markdown(text: []const u8, opts: MarkdownOptions) MarkdownBuilder {
    return .{ .text = text, .opts = opts };
}

/// 直接把 markdown 追加到已有 container（不创建新外层）。
/// 适合把 docs 注入到一个已经布局好的 popup / panel 里。
///
/// **生命周期**：emit 出来的 Node 内部 `text.content` slice 会借用 `text` 参数的字节，
/// 直到 Node 被销毁。caller **必须保证 `text` slice 活到 Node 销毁之后**。
/// 典型做法：caller 自己持有一个 `current_text: ?[]u8` 字段，每次刷新时 free 旧的、
/// 把新 buffer 传进来。
///
/// markdown 组件**不再内部分配/释放任何中间 buffer**；caller 自己持有 text。
pub fn renderInto(cx: *Cx, container: *Node, text: []const u8, opts: MarkdownOptions) !void {
    const allocator = cx.allocator;
    var scanner = BlockScanner{ .src = text };
    while (try scanner.next(allocator)) |block| {
        switch (block) {
            .paragraph => |lines| try emitParagraph(cx, container, lines, opts),
            .heading => |h| try emitHeading(cx, container, h.level, h.text, opts),
            .code_block => |c| try emitCodeBlock(cx, container, c.content, opts),
            .rule => try emitRule(cx, container, opts),
            .blockquote => |q| try emitBlockquote(cx, container, q, opts),
            .list_item => |li| try emitListItem(cx, container, li.ordered, li.marker, li.text, opts),
        }
    }
}

// ============================================================================
// Block scanner
// ============================================================================

const Block = union(enum) {
    paragraph: []const u8,
    heading: struct { level: u8, text: []const u8 },
    code_block: struct { content: []const u8 },
    rule: void,
    blockquote: []const u8,
    list_item: struct { ordered: bool, marker: []const u8, text: []const u8 },
};

const BlockScanner = struct {
    src: []const u8,
    pos: usize = 0,

    fn next(self: *BlockScanner, allocator: std.mem.Allocator) !?Block {
        _ = allocator;
        // 跳过连续空行
        while (self.pos < self.src.len) {
            const line = peekLine(self.src, self.pos);
            if (lineIsBlank(line.content)) {
                self.pos = line.next;
                continue;
            }
            break;
        }
        if (self.pos >= self.src.len) return null;

        const line = peekLine(self.src, self.pos);
        const trimmed = trimAscii(line.content);

        // fenced code block
        if (std.mem.startsWith(u8, trimmed, "```") or std.mem.startsWith(u8, trimmed, "~~~")) {
            const fence_char = trimmed[0];
            const fence_start = self.pos;
            _ = fence_start;
            self.pos = line.next;
            const content_start = self.pos;
            // 扫到对应 fence 或 EOF
            while (self.pos < self.src.len) {
                const l = peekLine(self.src, self.pos);
                const t = trimAscii(l.content);
                if (t.len >= 3 and t[0] == fence_char and t[1] == fence_char and t[2] == fence_char) {
                    const content_end = self.pos;
                    self.pos = l.next;
                    return .{ .code_block = .{ .content = trimTrailingNewline(self.src[content_start..content_end]) } };
                }
                self.pos = l.next;
            }
            // EOF 未闭合，全部当 code 吞掉
            return .{ .code_block = .{ .content = trimTrailingNewline(self.src[content_start..self.src.len]) } };
        }

        // horizontal rule：--- / *** / ___（至少 3 个，可带空格）
        if (isHorizontalRule(trimmed)) {
            self.pos = line.next;
            return .rule;
        }

        // ATX heading
        if (atxHeadingLevel(trimmed)) |level| {
            self.pos = line.next;
            const heading_text = trimAscii(trimmed[level + 1 ..]);
            return .{ .heading = .{ .level = level, .text = heading_text } };
        }

        // blockquote（单层）
        if (trimmed.len > 0 and trimmed[0] == '>') {
            self.pos = line.next;
            const quote_text = if (trimmed.len > 1 and trimmed[1] == ' ')
                trimmed[2..]
            else
                trimmed[1..];
            return .{ .blockquote = quote_text };
        }

        // 无序列表（单层）
        if (trimmed.len >= 2) {
            const first = trimmed[0];
            if ((first == '-' or first == '*' or first == '+') and trimmed[1] == ' ') {
                self.pos = line.next;
                return .{ .list_item = .{ .ordered = false, .marker = trimmed[0..1], .text = trimmed[2..] } };
            }
        }

        // 有序列表 `1. xxx` / `10. xxx`（单层）
        if (std.ascii.isDigit(trimmed[0])) {
            var digit_end: usize = 0;
            while (digit_end < trimmed.len and std.ascii.isDigit(trimmed[digit_end])) digit_end += 1;
            if (digit_end > 0 and digit_end + 1 < trimmed.len and trimmed[digit_end] == '.' and trimmed[digit_end + 1] == ' ') {
                self.pos = line.next;
                return .{ .list_item = .{ .ordered = true, .marker = trimmed[0..digit_end], .text = trimmed[digit_end + 2 ..] } };
            }
        }

        // 段落：累积后续非空非特殊行
        // 首行无条件吞掉：走到这里说明它已不是任何块起始；若 break 条件
        // 与上面的块判定不一致（如 "#123" 不是合法 ATX 标题），不前进 pos
        // 会让 next() 反复返回空段落 -> renderInto 死循环。
        const para_start = self.pos;
        self.pos = line.next;
        while (self.pos < self.src.len) {
            const l = peekLine(self.src, self.pos);
            const t = trimAscii(l.content);
            if (t.len == 0) break;
            if (std.mem.startsWith(u8, t, "```") or std.mem.startsWith(u8, t, "~~~")) break;
            if (isHorizontalRule(t)) break;
            if (atxHeadingLevel(t) != null) break;
            if (t.len > 0 and t[0] == '>') break;
            if (t.len >= 2 and (t[0] == '-' or t[0] == '*' or t[0] == '+') and t[1] == ' ') break;
            self.pos = l.next;
        }
        return .{ .paragraph = self.src[para_start..self.pos] };
    }
};

// ============================================================================
// Block emitters
// ============================================================================

fn emitParagraph(cx: *Cx, container: *Node, text: []const u8, opts: MarkdownOptions) !void {
    const allocator = cx.allocator;
    // sweep：块节点建好即挂，applyInlineText 失败由 container 的守卫连带回收
    const node = try core.adoptChild(cx, allocator, container, try box(cx, .{ .width = .{ .grow = .{} } }, .{}));
    try applyInlineText(cx, node, text, opts.base_font_size, opts.text_color, opts.line_height, opts);
}

fn emitHeading(cx: *Cx, container: *Node, level: u8, text: []const u8, opts: MarkdownOptions) !void {
    const node = try core.adoptChild(cx, cx.allocator, container, try box(cx, .{ .width = .{ .grow = .{} } }, .{}));
    // 标题在渲染上只是"更大更粗的字"，这个信号 AT 用户拿不到。role=heading
    // 才能让屏幕阅读器把它列进标题大纲，用户可以按标题跳读整篇文档。
    // （a11y tree 目前没有 heading level 字段，层级信息暂时表达不了。）
    node.behavior.interaction.a11y = .{ .role = .heading, .label = text };
    const color = opts.heading_color orelse opts.text_color;
    const font_size = opts.base_font_size * mdHeadingSizeMul(level);
    try applyInlineText(cx, node, text, font_size, color, opts.line_height, opts);
    if (node.getText()) |__old_t| {
        var __t = __old_t;
        __t.font_weight = 600;
        node.setText(__t);
    }
}

fn emitCodeBlock(cx: *Cx, container: *Node, code: []const u8, opts: MarkdownOptions) !void {
    const block = try core.adoptChild(cx, cx.allocator, container, try box(cx, mdCodeBlockStyle(opts), .{}));
    var it = std.mem.splitScalar(u8, code, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const ln = try core.adoptChild(cx, cx.allocator, block, try box(cx, .{}, .{}));
        var line_txt = mdCodeLineText(opts);
        line_txt.content = line;
        ln.setText(line_txt);
    }
}

fn emitRule(cx: *Cx, container: *Node, opts: MarkdownOptions) !void {
    _ = try core.adoptChild(cx, cx.allocator, container, try box(cx, mdRuleStyle(opts), .{}));
}

fn emitBlockquote(cx: *Cx, container: *Node, text: []const u8, opts: MarkdownOptions) !void {
    const quote = try core.adoptChild(cx, cx.allocator, container, try box(cx, mdBlockquoteStyle(), .{}));
    _ = try core.adoptChild(cx, cx.allocator, quote, try box(cx, mdBlockquoteBarStyle(opts), .{}));
    const body = try core.adoptChild(cx, cx.allocator, quote, try box(cx, mdBlockquoteBodyStyle(), .{}));
    try applyInlineText(cx, body, text, opts.base_font_size, opts.text_color, opts.line_height, opts);
}

fn emitListItem(cx: *Cx, container: *Node, ordered: bool, marker: []const u8, text: []const u8, opts: MarkdownOptions) !void {
    const row = try core.adoptChild(cx, cx.allocator, container, try box(cx, mdListRowStyle(), .{}));
    // label 只给正文，不含 "•"/"1." 这个 marker, marker 是纯视觉的项目符号，
    // 朗读出来只是噪音（AT 自己会播报"第 N 项"）。
    row.behavior.interaction.a11y = .{ .role = .listitem, .label = text };
    const marker_node = try core.adoptChild(cx, cx.allocator, row, try box(cx, .{}, .{}));
    var marker_txt = mdListMarkerText(opts);
    marker_txt.content = if (ordered) marker else bulletGlyph();
    marker_node.setText(marker_txt);

    const body = try core.adoptChild(cx, cx.allocator, row, try box(cx, .{ .width = .{ .grow = .{} } }, .{}));
    try applyInlineText(cx, body, text, opts.base_font_size, opts.text_color, opts.line_height, opts);
}

fn bulletGlyph() []const u8 {
    return "•";
}

// ============================================================================
// Inline parser：把 [text](url) / ![alt](url) / **bold** / *italic* / `code`
// 展开成一个字符串 + TextSpan 数组，挂到 node.text
// ============================================================================

fn applyInlineText(
    cx: *Cx,
    node: *Node,
    raw: []const u8,
    font_size: f32,
    text_color: Color,
    line_height: f32,
    opts: MarkdownOptions,
) !void {
    const allocator = cx.allocator;
    var builder = InlineBuilder.init(allocator);
    defer builder.deinit();

    try expandInline(&builder, raw, opts);

    // 如果最终什么都没有（raw 全是丢弃的 data:url 等），用一个空格维持高度
    if (builder.text.items.len == 0) {
        try builder.text.appendSlice(allocator, " ");
    }

    const has_spans = builder.spans.items.len > 0;
    const owned_text = try builder.text.toOwnedSlice(allocator);
    errdefer allocator.free(owned_text);
    const owned_spans = if (has_spans)
        try builder.spans.toOwnedSlice(allocator)
    else
        &[_]TextSpan{};

    // 旧 owned text/spans 由 ContentTable.setText 统一释放（换内容时自动 free）
    node.setText(.{
        .content = owned_text,
        .owned = true,
        .font_size = font_size,
        .color = text_color,
        .line_height = line_height,
        .wrap = .word,
        .spans = owned_spans,
        .spans_owned = has_spans,
    });
}

const InlineBuilder = struct {
    text: std.ArrayListUnmanaged(u8) = .{},
    spans: std.ArrayListUnmanaged(TextSpan) = .{},
    allocator: std.mem.Allocator,

    fn init(a: std.mem.Allocator) InlineBuilder {
        return .{ .allocator = a };
    }

    fn deinit(self: *InlineBuilder) void {
        self.text.deinit(self.allocator);
        self.spans.deinit(self.allocator);
    }

    fn appendPlain(self: *InlineBuilder, s: []const u8) !void {
        try self.text.appendSlice(self.allocator, s);
    }

    fn appendSpan(self: *InlineBuilder, s: []const u8, style: TextSpan) !void {
        const start: u32 = @intCast(self.text.items.len);
        try self.text.appendSlice(self.allocator, s);
        const end: u32 = @intCast(self.text.items.len);
        var span = style;
        span.start = start;
        span.end = end;
        try self.spans.append(self.allocator, span);
    }
};

fn expandInline(builder: *InlineBuilder, raw: []const u8, opts: MarkdownOptions) !void {
    // Normalise truncation sentinels：上游常用 U+2026 或 "..." 末尾表示截断
    const normalised = raw;
    // （后续要做替换可在此处 allocate 一份新 buffer；暂时直接转发）
    var i: usize = 0;
    while (i < normalised.len) {
        const c = normalised[i];

        // A line ending inside a Markdown paragraph is a soft break, not a
        // forced text-layout newline. Keeping the raw `\n` here made LSP docs
        // preserve source-comment wrapping; the text layout then also emitted
        // an empty visual line before continuing, so prose such as
        // "If the\nrequested number ..." looked as if wrapping were broken.
        // Blank lines have already been split into separate blocks by
        // BlockScanner, so flatten only the remaining paragraph-local break.
        if (c == '\n' or c == '\r') {
            var next = i + 1;
            if (c == '\r' and next < normalised.len and normalised[next] == '\n') {
                next += 1;
            }
            const has_previous_text = builder.text.items.len > 0;
            const has_following_text = next < normalised.len;
            const previous_is_space = has_previous_text and
                (builder.text.items[builder.text.items.len - 1] == ' ' or builder.text.items[builder.text.items.len - 1] == '\t');
            const following_is_space = has_following_text and
                (normalised[next] == ' ' or normalised[next] == '\t');
            if (has_previous_text and has_following_text and !previous_is_space and !following_is_space) {
                try builder.text.append(builder.allocator, ' ');
            }
            i = next;
            continue;
        }

        // `code`
        if (c == '`') {
            if (findMatching(normalised, i + 1, '`')) |end| {
                try builder.appendSpan(normalised[i + 1 .. end], mdCodeSpanStyle(opts));
                i = end + 1;
                continue;
            }
        }

        // **bold**
        if (c == '*' and i + 1 < normalised.len and normalised[i + 1] == '*') {
            if (findDoubleStar(normalised, i + 2)) |end| {
                try builder.appendSpan(normalised[i + 2 .. end], mdBoldSpanStyle());
                i = end + 2;
                continue;
            }
        }

        // *italic*（必须前后不是 **；简单处理：前面不是 *，后面能找到独立 *）
        if (c == '*' and (i + 1 >= normalised.len or normalised[i + 1] != '*')) {
            if (findMatching(normalised, i + 1, '*')) |end| {
                if (end < normalised.len and (end == normalised.len - 1 or normalised[end + 1] != '*')) {
                    try builder.appendSpan(normalised[i + 1 .. end], mdItalicSpanStyle());
                    i = end + 1;
                    continue;
                }
            }
        }

        // _italic_，下划线 italic（CommonMark 允许）
        // 规避 snake_case：前面是字母/数字时不触发；后面 `_` 也要跟非字母数字
        if (c == '_') {
            const prev_is_word = i > 0 and isWordByte(normalised[i - 1]);
            if (!prev_is_word) {
                if (findMatchingUnderscore(normalised, i + 1)) |end| {
                    if (end > i + 1) {
                        try builder.appendSpan(normalised[i + 1 .. end], mdItalicSpanStyle());
                        i = end + 1;
                        continue;
                    }
                }
            }
        }

        // ![alt](url) image
        if (c == '!' and i + 1 < normalised.len and normalised[i + 1] == '[') {
            if (parseLink(normalised, i + 1)) |link| {
                // data:image/* 直接降级为 chip [alt]
                const show_alt = link.text;
                if (show_alt.len > 0 and !isDataUri(link.url)) {
                    try builder.appendPlain("[");
                    try builder.appendPlain(show_alt);
                    try builder.appendPlain("]");
                } else if (show_alt.len > 0) {
                    try builder.appendSpan(show_alt, mdImageChipSpanStyle(opts));
                }
                // data:url 情况下就只输出一个小 [alt] 徽章（上面那段分支），不把 URL 塞进去
                i = link.next;
                continue;
            }
        }

        // [text](url) link
        if (c == '[') {
            if (parseLink(normalised, i)) |link| {
                if (link.text.len > 0) {
                    try builder.appendSpan(link.text, mdLinkSpanStyle(opts));
                }
                i = link.next;
                continue;
            }
        }

        // 普通字符（单个 byte；多字节 UTF-8 沿用原字节序）
        try builder.text.append(builder.allocator, c);
        i += 1;
    }
}

const ParsedLink = struct {
    text: []const u8,
    url: []const u8,
    next: usize,
};

/// 解析 `[text](url)`。调用前 src[start] == '['。失败返回 null（不 consume）。
fn parseLink(src: []const u8, start: usize) ?ParsedLink {
    if (start >= src.len or src[start] != '[') return null;
    const bracket_end = findMatching(src, start + 1, ']') orelse return null;
    if (bracket_end + 1 >= src.len or src[bracket_end + 1] != '(') return null;
    const paren_end = findMatching(src, bracket_end + 2, ')') orelse return null;
    return .{
        .text = src[start + 1 .. bracket_end],
        .url = src[bracket_end + 2 .. paren_end],
        .next = paren_end + 1,
    };
}

fn findMatching(src: []const u8, start: usize, ch: u8) ?usize {
    var i = start;
    while (i < src.len) : (i += 1) {
        if (src[i] == ch) return i;
        if (src[i] == '\n') return null; // inline 限于单行
    }
    return null;
}

fn findDoubleStar(src: []const u8, start: usize) ?usize {
    var i = start;
    while (i + 1 < src.len) : (i += 1) {
        if (src[i] == '*' and src[i + 1] == '*') return i;
        if (src[i] == '\n') return null;
    }
    return null;
}

fn isWordByte(b: u8) bool {
    return (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z') or (b >= '0' and b <= '9') or b == '_';
}

/// 找下一个 `_`，且它不能紧挨着字母数字（避免 snake_case 识别成 italic）
fn findMatchingUnderscore(src: []const u8, start: usize) ?usize {
    var i = start;
    while (i < src.len) : (i += 1) {
        if (src[i] == '\n') return null;
        if (src[i] == '_') {
            const next_is_word = i + 1 < src.len and isWordByte(src[i + 1]);
            if (!next_is_word) return i;
        }
    }
    return null;
}

fn isDataUri(url: []const u8) bool {
    return std.mem.startsWith(u8, url, "data:");
}

// ============================================================================
// 工具函数
// ============================================================================

const LineSlice = struct { content: []const u8, next: usize };

fn peekLine(src: []const u8, start: usize) LineSlice {
    if (start >= src.len) return .{ .content = src[start..start], .next = src.len };
    var end = start;
    while (end < src.len and src[end] != '\n') : (end += 1) {}
    const after = if (end < src.len) end + 1 else end;
    // 去掉 \r
    var content_end = end;
    if (content_end > start and src[content_end - 1] == '\r') content_end -= 1;
    return .{ .content = src[start..content_end], .next = after };
}

fn lineIsBlank(line: []const u8) bool {
    for (line) |b| if (b != ' ' and b != '\t') return false;
    return true;
}

fn trimAscii(s: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = s.len;
    while (start < end and (s[start] == ' ' or s[start] == '\t')) start += 1;
    while (end > start and (s[end - 1] == ' ' or s[end - 1] == '\t' or s[end - 1] == '\r')) end -= 1;
    return s[start..end];
}

fn trimTrailingNewline(s: []const u8) []const u8 {
    var end = s.len;
    while (end > 0 and (s[end - 1] == '\n' or s[end - 1] == '\r')) end -= 1;
    return s[0..end];
}

fn isHorizontalRule(line: []const u8) bool {
    if (line.len < 3) return false;
    const first = line[0];
    if (first != '-' and first != '*' and first != '_') return false;
    var count: usize = 0;
    for (line) |c| {
        if (c == first) {
            count += 1;
        } else if (c != ' ' and c != '\t') {
            return false;
        }
    }
    return count >= 3;
}

/// 合法 ATX 标题（1-6 个 `#` 后跟空格）返回级别，否则 null。
fn atxHeadingLevel(trimmed: []const u8) ?u8 {
    if (trimmed.len == 0 or trimmed[0] != '#') return null;
    var level: u8 = 0;
    while (level < 6 and level < trimmed.len and trimmed[level] == '#') level += 1;
    if (level < trimmed.len and trimmed[level] == ' ') return level;
    return null;
}

// ============================================================================
// Tests
// ============================================================================

test "markdown: 非标题的 # 行按段落推进，不死循环" {
    const cases = [_][]const u8{ "#123 fixed\n", "#include <x>\n", "#\n", "text\n#nope\nmore\n", "####### seven\n" };
    for (cases) |src| {
        var scanner = BlockScanner{ .src = src };
        var n: usize = 0;
        while (try scanner.next(std.testing.allocator)) |b| {
            try std.testing.expect(b == .paragraph);
            try std.testing.expect(b.paragraph.len > 0);
            n += 1;
            try std.testing.expect(n < 8);
        }
        try std.testing.expectEqual(@as(usize, 1), n);
    }
    // 合法标题仍能打断段落
    var scanner = BlockScanner{ .src = "para\n## H\n" };
    try std.testing.expect((try scanner.next(std.testing.allocator)).? == .paragraph);
    try std.testing.expect((try scanner.next(std.testing.allocator)).? == .heading);
}

test "markdown: detects paragraph vs heading" {
    var scanner = BlockScanner{ .src = "# Hello\n\nA paragraph.\n" };
    const h = (try scanner.next(std.testing.allocator)).?;
    try std.testing.expect(h == .heading);
    try std.testing.expectEqual(@as(u8, 1), h.heading.level);
    try std.testing.expectEqualStrings("Hello", h.heading.text);
    const p = (try scanner.next(std.testing.allocator)).?;
    try std.testing.expect(p == .paragraph);
}

test "markdown: fenced code block with unclosed fence" {
    var scanner = BlockScanner{ .src = "```\nfoo\nbar\n" };
    const b = (try scanner.next(std.testing.allocator)).?;
    try std.testing.expect(b == .code_block);
    try std.testing.expectEqualStrings("foo\nbar", b.code_block.content);
}

test "markdown: horizontal rule" {
    var scanner = BlockScanner{ .src = "---\n" };
    const b = (try scanner.next(std.testing.allocator)).?;
    try std.testing.expect(b == .rule);
}

test "markdown: list items and blockquote" {
    var scanner = BlockScanner{ .src = "- first\n- second\n> quoted\n" };
    const a = (try scanner.next(std.testing.allocator)).?;
    try std.testing.expect(a == .list_item);
    try std.testing.expect(!a.list_item.ordered);
    const b = (try scanner.next(std.testing.allocator)).?;
    try std.testing.expect(b == .list_item);
    const c = (try scanner.next(std.testing.allocator)).?;
    try std.testing.expect(c == .blockquote);
    try std.testing.expectEqualStrings("quoted", c.blockquote);
}

test "markdown inline: data uri image dropped to chip" {
    var builder = InlineBuilder.init(std.testing.allocator);
    defer builder.deinit();
    try expandInline(&builder, "before ![Baseline icon](data:image/svg+xml;base64,abc) after", .{});
    const out = builder.text.items;
    // URL 不应出现，但 "Baseline icon" chip 应当在输出里
    try std.testing.expect(std.mem.indexOf(u8, out, "data:image") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "base64") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Baseline icon") != null);
}

test "markdown inline: code span gets monospace + bg_color TextSpan" {
    var builder = InlineBuilder.init(std.testing.allocator);
    defer builder.deinit();
    try expandInline(&builder, "call `foo()` now", .{});
    try std.testing.expect(std.mem.indexOf(u8, builder.text.items, "`") == null);
    try std.testing.expect(std.mem.indexOf(u8, builder.text.items, "foo()") != null);
    try std.testing.expect(builder.spans.items.len >= 1);
    try std.testing.expect(builder.spans.items[0].use_monospace_font);
}

test "markdown inline: bold and italic spans" {
    var builder = InlineBuilder.init(std.testing.allocator);
    defer builder.deinit();
    try expandInline(&builder, "**bold** and *italic*", .{});
    try std.testing.expect(std.mem.indexOf(u8, builder.text.items, "*") == null);
    try std.testing.expectEqual(@as(usize, 2), builder.spans.items.len);
    try std.testing.expectEqual(@as(?u16, 700), builder.spans.items[0].font_weight);
    try std.testing.expect(builder.spans.items[1].use_italic_font);
}

test "markdown inline: ellipsis and plain link" {
    var builder = InlineBuilder.init(std.testing.allocator);
    defer builder.deinit();
    try expandInline(&builder, "see [MDN](https://mdn.io/x) \u{2026}", .{});
    // link 的 URL 不应出现，只保留 "MDN"
    try std.testing.expect(std.mem.indexOf(u8, builder.text.items, "https://") == null);
    try std.testing.expect(std.mem.indexOf(u8, builder.text.items, "MDN") != null);
    // 有一个 link span
    try std.testing.expect(builder.spans.items.len >= 1);
    try std.testing.expect(builder.spans.items[0].underline);
}

test "markdown inline: paragraph soft breaks become spaces" {
    var builder = InlineBuilder.init(std.testing.allocator);
    defer builder.deinit();

    try expandInline(
        &builder,
        "A typed array. If the\nrequested number of bytes could not be allocated.\r\nThe operation raises an exception.",
        .{},
    );

    try std.testing.expectEqualStrings(
        "A typed array. If the requested number of bytes could not be allocated. The operation raises an exception.",
        builder.text.items,
    );
}

test "markdown: pathological unclosed inline tokens stay safe" {
    var builder = InlineBuilder.init(std.testing.allocator);
    defer builder.deinit();
    // 未闭合 code / link / bold：不能 crash，保留原字面
    try expandInline(&builder, "foo `unclosed and **half bold and [link no paren", .{});
    try std.testing.expect(builder.text.items.len > 0);
}

test "markdown: empty input yields no blocks" {
    var scanner = BlockScanner{ .src = "" };
    try std.testing.expect((try scanner.next(std.testing.allocator)) == null);
}

test "markdown: blank-only input yields no blocks" {
    var scanner = BlockScanner{ .src = "\n\n\t\n" };
    try std.testing.expect((try scanner.next(std.testing.allocator)) == null);
}

// styles.zig 的测试收集，这行是必需的，见 docs/STYLING.md
test {
    _ = @import("styles.zig");
}

// 剩余未接 sweep 的组件（markdown render / form_field / select_headless）。
const sweep_md = "# Title\n\nA **bold** and *italic* with `code` and [link](https://x.y) ![alt](a.png)\n\n- one\n- two\n1. first\n\n```\nlet x = 1;\nlet y = 2;\n```\n\n---\n\n> quoted **text**\n";
test "markdown: mount 在任意分配点失败时不泄漏（sweep）" {
    const sw = @import("../oom_sweep.zig");
    try sw.sweepMount("markdown", struct {
        fn m(scope: *sw.Scope, cx: *sw.Cx) anyerror!?*sw.Node {
            _ = scope;
            return (try Markdown(sweep_md, .{}).render(cx)).root;
        }
    }.m);
}

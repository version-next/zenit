//! component_gallery: the website's component wall, one artboard per tile. Every artboard is the
//! same width as the Liquid Glass screens (402 pt), as tall as its content, and shows a few
//! components the way a real screen would use them. The site records each artboard on its own
//! (test id `gallery.<key>`) and lays the tiles out as a masonry wall, so the artboards carry no
//! frame and no title: the page draws the card and the seven-language caption.
//!
//! ZENIT_GALLERY_THEME=dark runs the dark theme (default light); the site records both.
const std = @import("std");
const ui = @import("ui");
const App = @import("zenit_app").App;

const v = ui.view;
const W = ui.widgets;
const icons = ui.assets.common;

/// Artboard width (the iPhone screens of glass_showcase) and its content width.
const BOARD_W: f32 = 402;
const PAD: f32 = 28;
const INNER: f32 = BOARD_W - 2 * PAD;
const GAP: f32 = 32;
const COLS = 4;
const WIN_W: f32 = COLS * BOARD_W + (COLS + 1) * GAP;
const WIN_H: f32 = 1500;

const St = struct {
    fn page(t: *const ui.theme.Values) ui.BoxStyle {
        return .{ .width = .{ .px = WIN_W }, .gap = GAP, .padding = ui.Padding.all(GAP), .align_items = .start, .background = t.tokens.color.bg_secondary };
    }
    fn column(_: *const ui.theme.Values) ui.BoxStyle {
        return .{ .width = .{ .px = BOARD_W }, .gap = GAP };
    }
    fn board(t: *const ui.theme.Values) ui.BoxStyle {
        return .{ .width = .{ .px = BOARD_W }, .gap = 16, .padding = ui.Padding.all(PAD), .background = t.tokens.color.bg_primary };
    }
    fn line(_: *const ui.theme.Values) ui.BoxStyle {
        return .{ .gap = 8, .align_items = .center };
    }
    fn spread(_: *const ui.theme.Values) ui.BoxStyle {
        return .{ .width = .{ .grow = .{} }, .gap = 8, .align_items = .center, .justify = .space_between };
    }
    fn wrap(_: *const ui.theme.Values) ui.BoxStyle {
        return .{ .width = .{ .px = INNER }, .gap = 8, .align_items = .center, .flex_wrap = .wrap };
    }
    fn stack(_: *const ui.theme.Values) ui.BoxStyle {
        return .{ .width = .{ .px = INNER }, .gap = 10 };
    }
    /// A form field: label over its control.
    fn field(_: *const ui.theme.Values) ui.BoxStyle {
        return .{ .width = .{ .px = INNER }, .gap = 8 };
    }
    fn center(_: *const ui.theme.Values) ui.BoxStyle {
        return .{ .width = .{ .px = INNER }, .justify = .center };
    }
    fn heading(t: *const ui.theme.Values) ui.TextStyle {
        return .{ .font_size = 20, .font_weight = 700, .color = t.tokens.color.fg_primary };
    }
    fn sub(t: *const ui.theme.Values) ui.TextStyle {
        return .{ .font_size = 13, .color = t.tokens.color.fg_tertiary };
    }
    fn label(t: *const ui.theme.Values) ui.TextStyle {
        return .{ .font_size = 14, .font_weight = 600, .color = t.tokens.color.fg_primary };
    }
    fn body(t: *const ui.theme.Values) ui.TextStyle {
        return .{ .font_size = 14, .color = t.tokens.color.fg_secondary, .wrap = .word };
    }
    fn cell(t: *const ui.theme.Values) ui.TextStyle {
        return .{ .font_size = 13, .color = t.tokens.color.fg_primary };
    }
};

const line = .{ .style = St.line };
const spread = .{ .style = St.spread };
const wrap = .{ .style = St.wrap };
const stack = .{ .style = St.stack };
const field = .{ .style = St.field };
const center = .{ .style = St.center };
const heading = .{ .style = St.heading };
const sub = .{ .style = St.sub };
const label = .{ .style = St.label };
const body = .{ .style = St.body };
const cell_props = .{ .style = St.cell };

// ── Data ─────────────────────────────────────────────────────────────────────────────────
const regions = [_]W.SelectOption{
    .{ .value = "apac", .label = "Asia Pacific" },
    .{ .value = "emea", .label = "Europe & Middle East" },
    .{ .value = "amer", .label = "Americas" },
};
const appearance = [_]W.checkbox.RadioOption{
    .{ .value = "light", .label = "Light" },
    .{ .value = "dark", .label = "Dark" },
    .{ .value = "auto", .label = "Match system" },
};
const tab_items = [_]W.tabs.TabItem{
    .{ .id = "all", .label = "All" },
    .{ .id = "open", .label = "Open", .badge = 4 },
    .{ .id = "merged", .label = "Merged" },
    .{ .id = "closed", .label = "Closed" },
};
const seg_items = [_]W.tabs.TabItem{
    .{ .id = "day", .label = "Day" },
    .{ .id = "week", .label = "Week" },
    .{ .id = "month", .label = "Month" },
};
const step_items = [_]W.StepItem{
    .{ .title = "Build", .description = "1m 12s" },
    .{ .title = "Test", .description = "64 stories" },
    .{ .title = "Ship", .description = "Bundle .app" },
};
const events = [_]W.TimelineItem{
    .{ .title = "Compiled", .description = "zig build -Doptimize=ReleaseSmall", .time = "09:12", .status = .completed },
    .{ .title = "E2E running", .description = "storybook.test.ts · 41 of 64", .time = "09:14", .status = .active },
    .{ .title = "Notarize", .description = "Waiting for the run", .status = .pending },
};
const crumbs = [_]W.BreadcrumbItem{
    .{ .id = "zenit", .label = "zenit" },
    .{ .id = "src", .label = "src" },
    .{ .id = "ui", .label = "ui" },
};
const comp_files = [_]W.TreeNodeData{
    .{ .id = "button", .label = "button.zig" },
    .{ .id = "select", .label = "select.zig" },
    .{ .id = "tree", .label = "tree.zig" },
};
const ui_dirs = [_]W.TreeNodeData{
    .{ .id = "components", .label = "components", .children = &comp_files },
    .{ .id = "core", .label = "core.zig" },
    .{ .id = "theme", .label = "theme.zig" },
};
const tree_nodes = [_]W.TreeNodeData{
    .{ .id = "ui", .label = "ui", .children = &ui_dirs },
    .{ .id = "build", .label = "build.zig" },
};

const NAMES = [_][]const u8{ "v0.13.0", "v0.12.2", "v0.12.1", "v0.12.0", "v0.11.4", "v0.11.3" };
const DATES = [_][]const u8{ "Oct 08", "Sep 29", "Sep 21", "Sep 14", "Aug 30", "Aug 16" };
const SIZES = [_][]const u8{ "1.7 MB", "1.7 MB", "1.8 MB", "1.8 MB", "1.9 MB", "1.9 MB" };
fn tableCell(r: usize, c: usize) v.Text(@TypeOf(cell_props), []const u8) {
    return v.text(cell_props, switch (c) {
        0 => NAMES[r % NAMES.len],
        1 => DATES[r % DATES.len],
        else => SIZES[r % SIZES.len],
    });
}
const table_columns = [_]W.ColumnDef{
    .{ .id = "tag", .header = "Release", .width = 128 },
    .{ .id = "date", .header = "Date", .width = 110 },
    .{ .id = "size", .header = "App size", .width = 106, .sortable = true },
};

const faq = [_]struct { q: []const u8, a: []const u8 }{
    .{ .q = "Is there a WebView inside?", .a = "No. Every pixel is drawn by zenit on Metal or Direct3D 12." },
    .{ .q = "How does a component update?", .a = "Signals write straight to the nodes that read them; nothing is diffed." },
    .{ .q = "Which platforms?", .a = "macOS today, Windows in preview." },
};
const faq_body = .{ .style = St.body };
const FaqItem = @TypeOf(v.with(W.AccordionItem(.{ .title = "" }), v.text(faq_body, @as([]const u8, ""))));
fn faqItem(open: *ui.Signal(?usize), comptime i: usize) FaqItem {
    return v.with(W.AccordionItem(.{ .title = faq[i].q, .expanded = W.accordionItemOpen(open, i) }), v.text(faq_body, faq[i].a));
}

// ── Artboards ────────────────────────────────────────────────────────────────────────────
fn build(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const faq_open = try scope.createSignal(?usize, 0);
    const col = .{ .style = St.column };
    return v.render(scope, cx, v.row(.{ .style = St.page, .test_id = "gallery.page" }, .{
        v.col(col, .{
            v.col(.{ .style = St.board, .test_id = "gallery.buttons" }, .{
                v.row(line, .{
                    W.Button(.{ .label = "Deploy", .variant = .primary, .icon_asset = icons.plus }),
                    W.Button(.{ .label = "Preview", .variant = .secondary }),
                    W.Button(.{ .label = "Delete", .variant = .danger }),
                }),
                v.row(line, .{
                    W.Button(.{ .label = "XS", .variant = .secondary, .size = .xs }),
                    W.Button(.{ .label = "SM", .variant = .secondary, .size = .sm }),
                    W.Button(.{ .label = "MD", .variant = .secondary, .size = .md }),
                    W.Button(.{ .label = "LG", .variant = .secondary, .size = .lg }),
                    W.Button(.{ .label = "Ghost", .variant = .ghost }),
                }),
            }),
            v.col(.{ .style = St.board, .test_id = "gallery.preferences" }, .{
                v.col(stack, .{ v.text(heading, @as([]const u8, "Preferences")), v.text(sub, @as([]const u8, "Applied to every window")) }),
                W.Switch(.{ .label = "Sync over iCloud", .checked = true }),
                W.Switch(.{ .label = "Low power mode", .checked = false }),
                W.Switch(.{ .label = "Reduce motion", .checked = true }),
                v.text(label, "Renderer"),
                v.row(line, .{
                    W.Checkbox(.{ .label = "Metal", .checked = true }),
                    W.Checkbox(.{ .label = "Core Text", .checked = true }),
                    W.Checkbox(.{ .label = "IME" }),
                }),
                v.text(label, "Appearance"),
                W.RadioGroup(.{ .options = &appearance, .value = "auto" }),
            }),
            v.col(.{ .style = St.board, .test_id = "gallery.files" }, .{
                W.Breadcrumb(.{ .items = &crumbs }),
                W.Tree(.{ .nodes = &tree_nodes, .expanded = &[_][]const u8{ "ui", "components" }, .selected = &[_][]const u8{"select"} }),
            }),
        }),
        v.col(col, .{
            v.col(.{ .style = St.board, .test_id = "gallery.deploy" }, .{
                v.col(stack, .{ v.text(heading, @as([]const u8, "New deployment")), v.text(sub, @as([]const u8, "Ships a signed .app to your release channel")) }),
                v.col(field, .{ v.text(label, "Project"), W.Input(.{ .value = "zenit-site", .leading_icon_asset = icons.folder, .width = INNER }) }),
                v.col(field, .{ v.text(label, "Region"), W.Select(.{ .options = &regions, .value = "apac", .width = INNER }) }),
                v.col(field, .{ v.text(label, "Budget"), W.Input(.{ .placeholder = "0.00", .append_text = "USD", .width = INNER }) }),
                v.col(field, .{ v.text(label, "Notes"), W.Textarea(.{ .value = "Header actions now split out of one glass circle.", .rows = 3, .width = INNER }) }),
                v.row(spread, .{
                    W.Button(.{ .label = "Cancel", .variant = .ghost }),
                    W.Button(.{ .label = "Deploy", .variant = .primary }),
                }),
            }),
            v.col(.{ .style = St.board, .test_id = "gallery.calendar" }, .{
                v.row(center, .{W.Calendar(.{ .month = W.calendar.YearMonth{ .year = 2026, .month = 10 }, .value = W.SimpleDate{ .year = 2026, .month = 10, .day = 9 } })}),
            }),
            v.col(.{ .style = St.board, .test_id = "gallery.faq" }, .{
                v.with(W.Accordion(.{ .gap = 6 }), .{ faqItem(faq_open, 0), faqItem(faq_open, 1), faqItem(faq_open, 2) }),
            }),
        }),
        v.col(col, .{
            v.col(.{ .style = St.board, .test_id = "gallery.releases" }, .{
                v.row(spread, .{ v.text(heading, "Releases"), W.Badge(.{ .label = "stable", .status = .success }) }),
                W.Table(.{ .columns = &table_columns, .row_count = 6, .table_height = 40 + 6 * 36, .striped = true }).cells({}, tableCell),
            }),
            v.col(.{ .style = St.board, .test_id = "gallery.pipeline" }, .{
                v.col(stack, .{ v.text(heading, @as([]const u8, "Release pipeline")), v.text(sub, @as([]const u8, "main · 4 commits since v0.13.0")) }),
                W.Steps(.{ .items = &step_items, .current = 1, .check_icon_asset = icons.check }),
                W.Progress(.{ .value = 64, .width = INNER, .show_text = true }),
                W.Timeline(.{ .items = &events }),
            }),
            v.col(.{ .style = St.board, .test_id = "gallery.filters" }, .{
                W.Tabs(.{ .items = &tab_items, .variant = .underline }),
                v.row(wrap, .{
                    W.Chip(.{ .label = "All", .selected = true }),
                    W.Chip(.{ .label = "Layout" }),
                    W.Chip(.{ .label = "Text" }),
                    W.Chip(.{ .label = "Glass", .closable = true }),
                }),
                v.row(wrap, .{
                    W.Tag(.{ .label = "zig", .color = .accent }),
                    W.Tag(.{ .label = "metal", .color = .success }),
                    W.Tag(.{ .label = "beta", .color = .warning }),
                    W.Tag(.{ .label = "breaking", .color = .danger }),
                    W.Tag(.{ .label = "macOS", .color = .neutral }),
                }),
                W.Tabs(.{ .items = &seg_items, .variant = .pill, .size = .sm }),
            }),
        }),
        v.col(col, .{
            v.col(.{ .style = St.board, .test_id = "gallery.alerts" }, .{
                W.Alert(.{ .variant = .success, .title = "Build succeeded", .message = "Hello Button.app · 1.7 MB" }),
                W.Alert(.{ .variant = .warning, .title = "API may change", .message = "Pin an exact version before 1.0." }),
                W.Alert(.{ .variant = .info, .title = "New in 0.13", .message = "Liquid Glass containers merge and split." }),
                v.row(wrap, .{
                    W.Badge(.{ .label = "info", .status = .info }),
                    W.Badge(.{ .label = "success", .status = .success }),
                    W.Badge(.{ .label = "warning", .status = .warning }),
                    W.Badge(.{ .label = "error", .status = .@"error" }),
                    W.Badge(.{ .count = 120, .max_count = 99 }),
                }),
            }),
            v.col(.{ .style = St.board, .test_id = "gallery.mixer" }, .{
                v.col(stack, .{ v.text(heading, @as([]const u8, "Output")), v.text(sub, @as([]const u8, "Studio Display speakers")) }),
                v.col(field, .{ v.text(label, "Volume"), W.Slider(.{ .label_text = "Volume", .min = 0, .max = 100, .value = 64, .width = INNER, .show_value = true }) }),
                v.col(field, .{ v.text(label, "Balance"), W.Slider(.{ .label_text = "Balance", .min = -50, .max = 50, .value = 0, .width = INNER, .show_value = true }) }),
                v.row(spread, .{ v.text(body, "Channels"), W.NumberStepper(.{ .value = 2, .min = 1, .max = 8 }) }),
                v.row(spread, .{ v.text(body, "Rating"), W.Rate(.{ .count = 5, .value = 4 }) }),
            }),
            v.col(.{ .style = St.board, .test_id = "gallery.loading" }, .{
                W.TagsInput(.{ .tags = &[_][]const u8{ "signals", "retained", "gpu" }, .width = INNER }),
                v.row(line, .{ W.Spinner(.{ .size = 18 }), v.text(body, "Indexing 1,174 icons…") }),
                W.Skeleton(.{ .variant = .text, .width = INNER, .height = 12 }),
                W.Skeleton(.{ .variant = .text, .width = INNER - 60, .height = 12 }),
                W.Skeleton(.{ .variant = .text, .width = 180, .height = 12 }),
            }),
        }),
    }));
}

fn mountUI(cx: *ui.Cx, scope: *ui.Scope) anyerror!*ui.Node {
    const dark = if (@import("zenit_environment").getBorrowed("ZENIT_GALLERY_THEME")) |t| std.mem.eql(u8, t, "dark") else false;
    cx.setTheme(if (dark) &ui.theme.modes.dark else &ui.theme.modes.light);
    return build(scope, cx);
}

pub fn main(init: std.process.Init) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const app = try App.init(gpa.allocator(), .{
        .io = init.io,
        .window = .{ .width = WIN_W, .height = WIN_H, .title = "Component Gallery" },
    });
    defer app.deinit();
    try app.runWith(mountUI);
}

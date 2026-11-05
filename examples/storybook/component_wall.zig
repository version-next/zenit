//! Component Wall: screenshot source for the "Components" section on the official homepage.
//! Not every component state; common components arranged as they appear in real UI as a
//! four-column card wall (each card is a real interactive UI chunk), so one screenshot shows
//! the component palette. Window must be large enough for the whole wall (capture script
//! resizes to 1860 wide).

const std = @import("std");
const ui = @import("ui");
const S = @import("styles.zig");

const v = ui.view;
const W = ui.widgets;
const icons = ui.assets.common;

const col_width: f32 = 344;
/// Card content width (column width - 18 padding each side - border)
const inner_width: f32 = col_width - 38;

const Styles = struct {
    fn root(_: *const ui.theme.Values) ui.BoxStyle {
        return .{ .gap = 16, .align_items = .start };
    }
    fn column(_: *const ui.theme.Values) ui.BoxStyle {
        return .{ .width = .{ .px = col_width }, .gap = 16 };
    }
    /// One card of the wall: white surface, hairline border, large radius.
    fn tile(t: *const ui.theme.Values) ui.BoxStyle {
        return .{
            .width = .{ .grow = .{} },
            .gap = 14,
            .padding = ui.Padding.all(18),
            .background = t.tokens.color.bg_primary,
            .border = .{ .overlay = true, .width = 1, .color = t.tokens.color.border, .radius = t.tokens.radius.lg },
        };
    }
    fn tileTitle(t: *const ui.theme.Values) ui.TextStyle {
        return .{ .font_size = 12, .font_weight = 600, .color = t.tokens.color.fg_tertiary };
    }
    fn body(t: *const ui.theme.Values) ui.TextStyle {
        return .{ .font_size = 13, .color = t.tokens.color.fg_secondary };
    }
};

const tile_props = .{ .style = Styles.tile };
const tile_title_props = .{ .style = Styles.tileTitle };

fn TileKids(comptime Body: type) type {
    return @Tuple(&.{ v.Text(@TypeOf(tile_title_props), []const u8), Body });
}

/// Card: title + content (content is tuple, expanded in place as siblings).
fn tile(title: []const u8, content: anytype) v.Box(@TypeOf(tile_props), TileKids(@TypeOf(content)), .column) {
    return v.col(tile_props, TileKids(@TypeOf(content)){ v.text(tile_title_props, title), content });
}

// ── Column 1: actions & form controls ──

const region_options = [_]W.SelectOption{
    .{ .value = "apac", .label = "Asia Pacific" },
    .{ .value = "emea", .label = "Europe & Middle East" },
    .{ .value = "amer", .label = "Americas" },
};

const radio_options = [_]W.checkbox.RadioOption{
    .{ .value = "light", .label = "Light" },
    .{ .value = "dark", .label = "Dark" },
    .{ .value = "auto", .label = "Auto" },
};

// ── Column 2: navigation & dates ──

const tab_items = [_]W.tabs.TabItem{
    .{ .id = "overview", .label = "Overview" },
    .{ .id = "activity", .label = "Activity", .badge = 3 },
    .{ .id = "settings", .label = "Settings" },
};

const step_items = [_]W.StepItem{
    .{ .title = "Account", .description = "Sign in" },
    .{ .title = "Project", .description = "Pick a template" },
    .{ .title = "Ship", .description = "Bundle .app" },
};

const crumbs = [_]W.BreadcrumbItem{
    .{ .id = "home", .label = "Home" },
    .{ .id = "lib", .label = "Library" },
    .{ .id = "comp", .label = "Components" },
};

// ── Column 3: data display ──

const NAMES = [_][]const u8{ "Aurora", "Nebula", "Solstice", "Tidal", "Ember" };
const KINDS = [_][]const u8{ "Shader", "Particles", "Glass UI", "Springs", "Vectors" };
const FPS = [_][]const u8{ "120", "118", "120", "96", "120" };

const table_cell_props = .{ .style = WallTableS.cell };
const WallTableS = struct {
    fn cell(t: *const ui.theme.Values) ui.TextStyle {
        return .{ .font_size = 13, .color = t.tokens.color.fg_primary };
    }
};

fn tableCell(row_i: usize, col_i: usize) v.Text(@TypeOf(table_cell_props), []const u8) {
    return v.text(table_cell_props, switch (col_i) {
        0 => NAMES[row_i % NAMES.len],
        1 => KINDS[row_i % KINDS.len],
        else => FPS[row_i % FPS.len],
    });
}

const table_columns = [_]W.ColumnDef{
    .{ .id = "name", .header = "Name", .width = 118 },
    .{ .id = "kind", .header = "Kind", .width = 110 },
    .{ .id = "fps", .header = "FPS", .width = 78, .sortable = true },
};

const TagSpec = struct { text: []const u8, color: W.TagColor };
const tag_specs = [_]TagSpec{
    .{ .text = "zig", .color = .accent },
    .{ .text = "metal", .color = .success },
    .{ .text = "beta", .color = .warning },
    .{ .text = "breaking", .color = .danger },
    .{ .text = "macOS", .color = .neutral },
};
fn tagItem(spec: TagSpec) @TypeOf(W.Tag(.{})) {
    return W.Tag(.{ .label = spec.text, .color = spec.color });
}

const BadgeSpec = struct { text: []const u8, status: W.badge.BadgeStatus };
const badge_specs = [_]BadgeSpec{
    .{ .text = "info", .status = .info },
    .{ .text = "success", .status = .success },
    .{ .text = "warning", .status = .warning },
    .{ .text = "error", .status = .@"error" },
};
fn badgeItem(spec: BadgeSpec) @TypeOf(W.Badge(.{})) {
    return W.Badge(.{ .label = spec.text, .status = spec.status });
}

// ── Column 4: structure & feedback ──

const events = [_]W.TimelineItem{
    .{ .title = "Committed", .description = "feat(select): keyboard nav", .time = "09:12", .status = .completed },
    .{ .title = "E2E running", .description = "storybook.test.ts · 64 stories", .time = "09:14", .status = .active },
    .{ .title = "Release", .description = "v0.1.0-alpha", .status = .pending },
};

const ui_files = [_]W.TreeNodeData{
    .{ .id = "button", .label = "button.zig" },
    .{ .id = "select", .label = "select.zig" },
};
const src_dirs = [_]W.TreeNodeData{
    .{ .id = "components", .label = "components", .children = &ui_files },
    .{ .id = "main", .label = "main.zig" },
};
const tree_nodes = [_]W.TreeNodeData{
    .{ .id = "src", .label = "src", .children = &src_dirs },
    .{ .id = "build", .label = "build.zig" },
};

const faq = [_]struct { q: []const u8, a: []const u8 }{
    .{ .q = "What is a retained tree?", .a = "Nodes are built once and updated in place." },
    .{ .q = "Does it use a WebView?", .a = "No. Metal draws every pixel." },
    .{ .q = "Which platforms?", .a = "macOS today." },
};

const faq_body_props = .{ .style = Styles.body };
const FaqItem = @TypeOf(v.with(W.AccordionItem(.{ .title = "" }), v.text(faq_body_props, @as([]const u8, ""))));

/// Mutually exclusive expand: open tracks current item, expanded for each derived via
/// accordionItemOpen(open, i).
fn faqItem(open: *ui.Signal(?usize), comptime i: usize) FaqItem {
    return v.with(W.AccordionItem(.{ .title = faq[i].q, .expanded = W.accordionItemOpen(open, i) }), v.text(faq_body_props, faq[i].a));
}

pub fn build(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const faq_open = try scope.createSignal(?usize, 0);
    const column = .{ .style = Styles.column };
    return v.render(scope, cx, v.row(.{ .style = Styles.root, .test_id = "story.wall.root" }, .{
        // ── Column 1: actions & form controls ──
        v.col(column, .{
            tile("Actions", .{
                v.row(.{ .style = S.line(8) }, .{
                    W.Button(.{ .label = "Deploy", .variant = .primary, .icon_asset = icons.plus }),
                    W.Button(.{ .label = "Preview", .variant = .secondary }),
                    W.Button(.{ .label = "Delete", .variant = .danger }),
                }),
                v.row(.{ .style = S.line(8) }, .{
                    W.Button(.{ .label = "XS", .variant = .secondary, .size = .xs }),
                    W.Button(.{ .label = "SM", .variant = .secondary, .size = .sm }),
                    W.Button(.{ .label = "MD", .variant = .secondary, .size = .md }),
                    W.Button(.{ .label = "LG", .variant = .secondary, .size = .lg }),
                    W.Button(.{ .label = "Ghost", .variant = .ghost }),
                }),
            }),
            tile("Input · Select", .{
                W.Input(.{ .placeholder = "Search components…", .leading_icon_asset = icons.search, .width = inner_width }),
                W.Select(.{ .options = &region_options, .value = "apac", .width = inner_width }),
                W.Input(.{ .placeholder = "0.00", .append_text = "USD", .width = inner_width }),
            }),
            tile("Switch · Checkbox · Radio", .{
                W.Switch(.{ .label = "Sync over iCloud", .checked = true }),
                W.Switch(.{ .label = "Low power mode", .checked = false }),
                v.row(.{ .style = S.line(16) }, .{
                    W.Checkbox(.{ .label = "Metal", .checked = true }),
                    W.Checkbox(.{ .label = "CoreText", .checked = true }),
                    W.Checkbox(.{ .label = "IME" }),
                }),
                W.RadioGroup(.{ .options = &radio_options, .value = "auto" }),
            }),
            tile("Slider · Progress · Stepper", .{
                W.Slider(.{ .min = 0, .max = 100, .value = 64, .width = inner_width, .show_value = true }),
                W.Progress(.{ .value = 72, .width = inner_width, .show_text = true }),
                v.row(.{ .style = S.line(16) }, .{
                    W.NumberStepper(.{ .value = 3, .min = 0, .max = 10 }),
                    W.Spinner(.{ .size = 20 }),
                }),
            }),
        }),

        // ── Column 2: navigation & dates ──
        v.col(column, .{
            tile("Tabs", .{
                W.Tabs(.{ .items = &tab_items, .variant = .underline }),
                W.Tabs(.{ .items = &tab_items, .variant = .pill, .size = .sm }),
            }),
            tile("Calendar", .{
                W.Calendar(.{ .month = W.calendar.YearMonth{ .year = 2026, .month = 9 } }),
            }),
            tile("Steps · Breadcrumb", .{
                W.Steps(.{ .items = &step_items, .current = 1, .check_icon_asset = icons.check }),
                W.Breadcrumb(.{ .items = &crumbs }),
            }),
            tile("TagsInput", .{
                W.TagsInput(.{ .tags = &[_][]const u8{ "signals", "retained", "gpu" }, .width = inner_width }),
            }),
        }),

        // ── Column 3: data display ──
        v.col(column, .{
            tile("Table", .{
                W.Table(.{ .columns = &table_columns, .row_count = 5, .table_height = 40 + 5 * 36, .striped = true }).cells({}, tableCell),
            }),
            tile("Alert", .{
                W.Alert(.{ .variant = .success, .title = "Build succeeded", .message = "Hello Button.app · 1.7 MB" }),
                W.Alert(.{ .variant = .warning, .title = "API may change", .message = "Pin an exact version before 1.0." }),
            }),
            tile("Tag · Badge · Chip", .{
                v.row(.{ .style = S.line(6) }, v.list(&tag_specs, tagItem)),
                v.row(.{ .style = S.line(8) }, .{
                    v.list(&badge_specs, badgeItem),
                    W.Badge(.{ .count = 120, .max_count = 99 }),
                }),
                v.row(.{ .style = S.line(6) }, .{
                    W.Chip(.{ .label = "All", .selected = true }),
                    W.Chip(.{ .label = "Layout" }),
                    W.Chip(.{ .label = "Text" }),
                    W.Chip(.{ .label = "Glass", .closable = true }),
                }),
            }),
            tile("Rate · Skeleton", .{
                W.Rate(.{ .count = 5, .value = 4 }),
                W.Skeleton(.{ .variant = .text, .width = inner_width, .height = 12 }),
                W.Skeleton(.{ .variant = .text, .width = 200, .height = 12 }),
            }),
        }),

        // ── Column 4: structure & feedback ──
        v.col(column, .{
            tile("Timeline", .{
                W.Timeline(.{ .items = &events }),
            }),
            tile("Tree", .{
                // src/ and src/components/ expanded, select.zig selected: written as initial data
                W.Tree(.{
                    .nodes = &tree_nodes,
                    .expanded = &[_][]const u8{ "src", "components" },
                    .selected = &[_][]const u8{"select"},
                }),
            }),
            tile("Accordion", .{
                v.with(W.Accordion(.{ .gap = 6 }), .{ faqItem(faq_open, 0), faqItem(faq_open, 1), faqItem(faq_open, 2) }),
            }),
        }),
    }));
}

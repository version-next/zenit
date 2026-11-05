//! Interactive Storybook coverage for the real `ui.widgets.Select` component.
//! Default field dimensions follow Pencil node `RYMhT`; no specimen here is a
//! hand-drawn replacement for the component.

const std = @import("std");
const ui = @import("ui");

const v = ui.view;
const W = ui.widgets;

const icon_options = [_]W.SelectOption{
    .{ .value = "one", .label = "Option 1", .icon = ui.icons.user },
    .{ .value = "two", .label = "Option 2", .icon = ui.icons.settings },
    .{ .value = "three", .label = "Option 3", .icon = ui.icons.globe },
    .{ .value = "four", .label = "Option 4" },
};

const options = [_]W.SelectOption{
    .{ .value = "one", .label = "Option 1" },
    .{ .value = "two", .label = "Option 2" },
    .{ .value = "three", .label = "Option 3" },
    .{ .value = "four", .label = "Option 4" },
};

// Searchable specimens in `puQEf` intentionally show a three-row result set.
const search_options = [_]W.SelectOption{
    .{ .value = "one", .label = "Option 1" },
    .{ .value = "two", .label = "Option 2" },
    .{ .value = "three", .label = "Option 3" },
};

const Styles = struct {
    fn family(_: *const ui.theme.Values) ui.BoxStyle {
        return .{ .width = .{ .px = 352 }, .gap = 16 };
    }
    fn specimen(_: *const ui.theme.Values) ui.BoxStyle {
        return .{ .width = .{ .px = 352 }, .gap = 6 };
    }
    fn title(t: *const ui.theme.Values) ui.TextStyle {
        return .{ .font_size = 12, .font_weight = 600, .line_height = 1.2, .color = t.tokens.color.fg_primary };
    }
    fn caption(t: *const ui.theme.Values) ui.TextStyle {
        return .{ .font_size = 11, .font_weight = 600, .line_height = 1.2, .color = t.tokens.color.fg_secondary };
    }
};

const caption_props = .{ .style = Styles.caption };
const specimen_props = .{ .style = Styles.specimen };
const CaptionEl = v.Text(@TypeOf(caption_props), []const u8);

fn SpecimenKids(comptime Select: type) type {
    return @Tuple(&.{ CaptionEl, Select });
}

/// One specimen: title + component.
fn specimen(label: []const u8, select: anytype) v.Box(@TypeOf(specimen_props), SpecimenKids(@TypeOf(select)), .column) {
    return v.col(specimen_props, SpecimenKids(@TypeOf(select)){ v.text(caption_props, label), select });
}

// -- Internal component test_id --
// trigger / panel / chevron / clear button / search box etc fixed parts are SelectResult
// fields via `.parts`; option rows use SelectOption.test_id (multi-tag derives
// `<id>.tag` / `<id>.tag-close`).

/// Number option group with specimen prefix: `<prefix>.option-1` ...
fn withIds(comptime base: []const W.SelectOption, comptime prefix: []const u8) [base.len]W.SelectOption {
    var out: [base.len]W.SelectOption = undefined;
    for (base, 0..) |o, i| {
        out[i] = o;
        out[i].test_id = std.fmt.comptimePrint("{s}.option-{d}", .{ prefix, i + 1 });
    }
    return out;
}

const icon_options_ids = withIds(&icon_options, "story.select.with-icon");
const search_options_ids = withIds(&search_options, "story.select.search");
const multiple_lg_options = withIds(&options, "story.select.multiple-lg");
const multiple_search_lg_options = withIds(&search_options, "story.select.multiple-search-lg");
const multiple_search_md_options = withIds(&search_options, "story.select.multiple-search-md");
const multiple_search_xs_options = withIds(&search_options, "story.select.multiple-search-xs");

pub fn build(scope: *ui.Scope, cx: *ui.Cx) !*ui.Node {
    return v.render(scope, cx, v.col(.{ .style = Styles.family, .test_id = "story.select.family" }, .{
        v.text(.{ .style = Styles.title }, "Select"),
        specimen("Selected / disabled option", W.Select(.{ .options = &[_]W.SelectOption{
            .{ .value = "one", .label = "Option one" },                         .{ .value = "two", .label = "Option two" },
            .{ .value = "disabled", .label = "Unavailable", .disabled = true },
        }, .value = "two", .width = 260 })),
        specimen("MultiSelect / overflow", W.Select(.{ .options = &options, .mode = .multiple, .values = &[_][]const u8{ "one", "two", "three", "four" }, .max_visible_tags = 2, .selection_footer = true, .width = 260 })),

        specimen("With icon", v.attrs(.{ .parts = .{
            .trigger = "story.select.with-icon",
            .panel = "story.select.with-icon.panel",
            .chevron_down = "story.select.with-icon.chevron",
        } }, W.Select(.{
            .size = .md, // RYMhT default field is 32px.
            .options = &icon_options_ids,
            .leading_icon = ui.icons.globe,
        }))),

        specimen("Clearable", v.attrs(.{ .parts = .{
            .trigger = "story.select.clearable",
            .panel = "story.select.clearable.panel",
            .clear_button = "story.select.clear",
            .append_slot = "story.select.clearable.append",
            .append_comp = "story.select.clearable.append-comp",
            .chevron_slot = "story.select.clearable.chevron",
            .chevron_up = "story.select.clearable.chevron-up",
            .chevron_down = "story.select.clearable.chevron-down",
        } }, W.Select(.{
            .size = .md, // RYMhT default field is 32px.
            .options = &options,
            .clearable = true,
            .value = "one",
        }))),

        specimen("Searchable", v.attrs(.{ .parts = .{
            .trigger = "story.select.trigger",
            .panel = "story.select.panel",
            .leading_icon = "story.select.search.icon",
            .append_slot = "story.select.search.append",
            .search_input = "story.select.search.input",
        } }, W.Select(.{
            .size = .md, // RYMhT default field is 32px.
            .options = &search_options_ids,
            .searchable = true,
            .placeholder = "Search options...",
            .value = "one",
            .show_selected_value_in_search = false,
        }))),

        specimen("Multiple · LG", v.attrs(.{ .parts = .{
            .trigger = "story.select.multiple-lg",
            .panel = "story.select.multiple-lg.panel",
        } }, W.Select(.{
            .size = .lg, // Keep explicit 40px LG coverage alongside RYMhT defaults.
            .options = &multiple_lg_options,
            .mode = .multiple,
            .values = &[_][]const u8{ "one", "two" },
        }))),

        specimen("Multiple searchable · LG", v.attrs(.{ .parts = .{
            .trigger = "story.select.multiple-search-lg",
            .panel = "story.select.multiple-search-lg.panel",
            .content_slot = "story.select.multiple-search-lg.content",
            .append_slot = "story.select.multiple-search-lg.append",
            .search_input = "story.select.multiple-search-lg.input",
        } }, W.Select(.{
            .size = .md, // RYMhT default field is 32px.
            .options = &multiple_search_lg_options,
            .mode = .multiple,
            .searchable = true,
            .values = &[_][]const u8{"one"},
        }))),

        specimen("Multiple · MD", v.attrs(.{ .parts = .{
            .trigger = "story.select.multiple-md",
            .panel = "story.select.multiple-md.panel",
        } }, W.Select(.{
            .options = &options,
            .mode = .multiple,
            .size = .md,
            .values = &[_][]const u8{ "one", "two" },
        }))),

        specimen("Multiple searchable · MD", v.attrs(.{ .parts = .{
            .trigger = "story.select.multiple-search-md",
            .panel = "story.select.multiple-search-md.panel",
            .search_input = "story.select.multiple-search-md.input",
        } }, W.Select(.{
            .options = &multiple_search_md_options,
            .mode = .multiple,
            .size = .md,
            .searchable = true,
            .values = &[_][]const u8{"one"},
        }))),

        specimen("Multiple · XS", v.attrs(.{ .parts = .{
            .trigger = "story.select.multiple-xs",
            .panel = "story.select.multiple-xs.panel",
        } }, W.Select(.{
            .options = &options,
            .mode = .multiple,
            .size = .xs,
            .values = &[_][]const u8{ "one", "two" },
        }))),

        specimen("Multiple searchable · XS", v.attrs(.{ .parts = .{
            .trigger = "story.select.multiple-search-xs",
            .panel = "story.select.multiple-search-xs.panel",
            .search_input = "story.select.multiple-search-xs.input",
        } }, W.Select(.{
            .options = &multiple_search_xs_options,
            .mode = .multiple,
            .size = .xs,
            .searchable = true,
            .values = &[_][]const u8{"one"},
        }))),
        specimen("MultiSelect open", v.attrs(.{ .parts = .{ .trigger = "story.select.multi-open", .panel = "story.select.multi-open.panel" } }, W.Select(.{ .options = &[_]W.SelectOption{
            .{ .value = "design", .label = "Design" },                          .{ .value = "engineering", .label = "Engineering" },
            .{ .value = "marketing", .label = "Marketing" },                    .{ .value = "sales", .label = "Sales" },
            .{ .value = "disabled", .label = "Unavailable", .disabled = true },
        }, .mode = .multiple, .values = &[_][]const u8{ "design", "engineering" }, .selection_footer = true, .open = true, .width = 260 }))),
    }));
}

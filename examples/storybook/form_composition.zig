//! Form Composition: same-tier Input / Select / Button mixed layout business sketch.
//!
//! All three share `ControlSize` (outer box height = padding_y*2 + line height:
//! XS 20 / SM 24 / MD 32 / LG 40). The story shows real assembled layout, checking height /
//! corner / font / icon / gap alignment within a size tier:
//!   1. Filter toolbar: four sizes, each row Input + Select*2 + Button*2 horizontal;
//!   2. Create order form: MD tier two columns + bottom action area.

const std = @import("std");
const ui = @import("ui");
const S = @import("styles.zig");

const v = ui.view;
const W = ui.widgets;
const ControlSize = ui.widgets.ControlSize;

const status_options = [_]W.SelectOption{
    .{ .value = "all", .label = "All statuses" },
    .{ .value = "pending", .label = "Pending" },
    .{ .value = "paid", .label = "Paid" },
    .{ .value = "refunded", .label = "Refunded" },
};

const owner_options = [_]W.SelectOption{
    .{ .value = "anyone", .label = "Anyone", .icon = ui.icons.globe },
    .{ .value = "me", .label = "Assigned to me", .icon = ui.icons.user },
    .{ .value = "team", .label = "My team", .icon = ui.icons.settings },
};

const region_options = [_]W.SelectOption{
    .{ .value = "apac", .label = "Asia Pacific" },
    .{ .value = "emea", .label = "Europe & Middle East" },
    .{ .value = "amer", .label = "Americas" },
};

const priority_options = [_]W.SelectOption{
    .{ .value = "low", .label = "Low" },
    .{ .value = "normal", .label = "Normal" },
    .{ .value = "high", .label = "High" },
    .{ .value = "urgent", .label = "Urgent" },
};

/// One-size toolbar: size, title, test_id for each control
/// (`story.formcompose.<key>.<part>`).
const SizeSpec = struct {
    size: ControlSize,
    title: []const u8,
    row_id: []const u8,
    input_id: []const u8,
    status_id: []const u8,
    owner_id: []const u8,
    owner_panel_id: []const u8,
    reset_id: []const u8,
    apply_id: []const u8,
};

fn sizeSpec(comptime size: ControlSize, comptime key: []const u8, comptime title: []const u8) SizeSpec {
    const prefix = "story.formcompose." ++ key;
    return .{
        .size = size,
        .title = title,
        .row_id = prefix ++ ".row",
        .input_id = prefix ++ ".input",
        .status_id = prefix ++ ".status",
        .owner_id = prefix ++ ".owner",
        .owner_panel_id = prefix ++ ".owner.panel",
        .reset_id = prefix ++ ".reset",
        .apply_id = prefix ++ ".apply",
    };
}

const sizes = [_]SizeSpec{
    sizeSpec(.xs, "xs", "XS"),
    sizeSpec(.sm, "sm", "SM"),
    sizeSpec(.md, "md", "MD"),
    sizeSpec(.lg, "lg", "LG"),
};

const Styles = struct {
    fn root(_: *const ui.theme.Values) ui.BoxStyle {
        return .{ .gap = 16 };
    }
    fn heading(t: *const ui.theme.Values) ui.TextStyle {
        return .{ .font_size = 13, .font_weight = 600, .color = t.tokens.color.fg_primary };
    }
    fn caption(t: *const ui.theme.Values) ui.TextStyle {
        return .{ .font_size = 12, .color = t.tokens.color.fg_tertiary };
    }
    fn card(t: *const ui.theme.Values) ui.BoxStyle {
        return .{
            .gap = 16,
            .padding = ui.Padding.all(t.tokens.space.space600),
            .background = t.tokens.color.bg_primary,
            .border = .{ .overlay = true, .width = 1, .color = t.tokens.color.border, .radius = t.tokens.radius.panel },
        };
    }
    fn cardTitle(t: *const ui.theme.Values) ui.TextStyle {
        return .{ .font_size = 16, .font_weight = 600, .color = t.tokens.color.fg_primary };
    }
    fn field(_: *const ui.theme.Values) ui.BoxStyle {
        return .{ .width = .{ .px = field_width }, .gap = 6 };
    }
    fn fieldLabel(t: *const ui.theme.Values) ui.TextStyle {
        return .{ .font_size = t.tokens.font_size.sm, .font_weight = 600, .color = t.tokens.color.fg_primary };
    }
    fn fieldRow(_: *const ui.theme.Values) ui.BoxStyle {
        return .{ .gap = 16, .align_items = .start };
    }
    fn footer(t: *const ui.theme.Values) ui.BoxStyle {
        return .{
            .border_overlay = true,
            .width = .{ .grow = .{} },
            .gap = 8,
            .align_items = .center,
            .justify = .end,
            .padding = .{ .top = 16 },
            .border_top_width = t.tokens.border_width.thin,
            .border_top_color = t.tokens.color.border,
        };
    }
};

fn filterToolbar(spec: SizeSpec, scope: *ui.Scope, cx: *ui.Cx) !*ui.Node {
    return v.render(scope, cx, v.col(.{ .style = S.stack(6) }, .{
        v.text(.{ .style = Styles.caption }, spec.title),
        v.row(.{ .style = S.line(8), .test_id = spec.row_id }, .{
            v.attrs(.{ .test_id = spec.input_id }, W.Input(.{
                .size = spec.size,
                .placeholder = "Search orders…",
                .leading_icon_asset = ui.assets.common.search,
                .width = 180,
            })),
            v.attrs(.{ .parts = .{ .trigger = spec.status_id } }, W.Select(.{
                .size = spec.size,
                .options = &status_options,
                .placeholder = "Status",
                .width = 130,
            })),
            v.attrs(.{ .parts = .{ .trigger = spec.owner_id, .panel = spec.owner_panel_id } }, W.Select(.{
                .size = spec.size,
                .options = &owner_options,
                .placeholder = "Owner",
                .leading_icon = ui.icons.user,
                .width = 150,
                // The panel sizes to its rows, so long owner names stay readable.
                .panel_width = .content,
            })),
            v.attrs(.{ .test_id = spec.reset_id }, W.Button(.{ .label = "Reset", .variant = .secondary, .size = spec.size })),
            v.attrs(.{ .test_id = spec.apply_id }, W.Button(.{
                .label = "Apply filters",
                .variant = .primary,
                .size = spec.size,
                .icon_asset = ui.assets.common.search,
            })),
        }),
    }));
}

fn toolbar(spec: SizeSpec) v.ComponentOf(filterToolbar) {
    return v.component(filterToolbar, spec);
}

const field_width: f32 = 280;

const field_props = .{ .style = Styles.field };
const field_label_props = .{ .style = Styles.fieldLabel };
const field_row_props = .{ .style = Styles.fieldRow };

fn FieldKids(comptime Control: type) type {
    return @Tuple(&.{ v.Text(@TypeOf(field_label_props), []const u8), Control });
}

/// Field: label + control, fixed width.
fn field(label: []const u8, control: anytype) v.Box(@TypeOf(field_props), FieldKids(@TypeOf(control)), .column) {
    return v.col(field_props, FieldKids(@TypeOf(control)){ v.text(field_label_props, label), control });
}

fn FieldRowKids(comptime L: type, comptime R: type) type {
    return @Tuple(&.{ L, R });
}

/// Two-column fields per row.
fn fieldRow(left: anytype, right: anytype) v.Box(@TypeOf(field_row_props), FieldRowKids(@TypeOf(left), @TypeOf(right)), .row) {
    return v.row(field_row_props, FieldRowKids(@TypeOf(left), @TypeOf(right)){ left, right });
}

pub fn build(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    return v.render(scope, cx, v.col(.{ .style = Styles.root, .test_id = "story.formcompose.root" }, .{
        v.text(.{ .style = Styles.heading }, "Filter toolbar · same size"),
        v.text(.{ .style = Styles.caption }, "Input / Select / Button share ControlSize: XS 20 · SM 24 · MD 32 · LG 40 px"),
        v.list(&sizes, toolbar),

        v.text(.{ .style = Styles.heading }, "Business form · MD"),
        v.col(.{ .style = Styles.card, .test_id = "story.formcompose.order" }, .{
            v.col(.{ .style = S.stack(4) }, .{
                v.text(.{ .style = Styles.cardTitle }, "New order"),
                v.text(.{ .style = Styles.caption }, "Orders are billed in the customer's region currency."),
            }),
            fieldRow(
                field("Customer", v.attrs(.{ .test_id = "story.formcompose.order.customer" }, W.Input(.{ .placeholder = "Acme Inc.", .width = field_width }))),
                field("Billing email", W.Input(.{ .input_type = .email, .placeholder = "billing@acme.com", .width = field_width })),
            ),
            fieldRow(
                field("Region", v.attrs(.{ .parts = .{ .trigger = "story.formcompose.order.region" } }, W.Select(.{ .options = &region_options, .placeholder = "Select region", .width = field_width }))),
                field("Priority", W.Select(.{ .options = &priority_options, .value = "normal", .width = field_width })),
            ),
            fieldRow(
                field("Amount", W.Input(.{ .placeholder = "0.00", .append_text = "USD", .width = field_width })),
                field("Due date", W.Input(.{ .placeholder = "YYYY-MM-DD", .leading_icon_asset = ui.assets.common.calendar, .width = field_width })),
            ),
            v.row(.{ .style = Styles.footer }, .{
                W.Button(.{ .label = "Save draft", .variant = .ghost }),
                W.Button(.{ .label = "Cancel", .variant = .secondary }),
                v.attrs(.{ .test_id = "story.formcompose.order.submit" }, W.Button(.{ .label = "Create order", .variant = .primary })),
            }),
        }),
    }));
}

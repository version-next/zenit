//! Storybook navigation and content layout. Stories render directly on the canvas.
const ui = @import("ui");
const TOKENS = ui.theme.refs;

// The app mounts this root as a flex item in a viewport-sized column. Long
// stories belong to the inner ScrollArea, including after text wraps settle.
pub const root = ui.css(.{ .width = .fill, .height = .fill, .flex_basis = 0, .min_height = 0, .direction = .column, .background = TOKENS.color.bg_primary });
pub const body = ui.css(.{ .width = .fill, .height = .fill, .direction = .row });
pub const sidebarBody = ui.css(.{ .width = .fill, .height = .fill, .flex_basis = 0, .min_height = 0, .direction = .column });
pub const searchWrap = ui.css(.{ .padding = .{ .x = 10, .top = TOKENS.space.space100, .bottom = TOKENS.space.space200 } });
pub const searchField = ui.css(.{
    .width = .fill,
    .height = ui.arb.px(32),
    .direction = .row,
    .align_items = .center,
    .gap = TOKENS.space.space200,
    .padding = .{ .x = TOKENS.space.space200 },
    .background = TOKENS.color.bg_primary,
    .border = .{ .overlay = true, .width = .thin, .color = TOKENS.color.border, .radius = .lg },
});
pub const searchIcon = ui.css(.{ .width = TOKENS.size.sm, .height = TOKENS.size.sm });
pub fn searchIconTint(t: *const ui.theme.Values) ui.Color {
    return t.tokens.color.fg_tertiary;
}
pub const searchInput = ui.css(.{ .width = .{ .grow = .{ .min = 0 } } });
pub const navEmptyHint = ui.css(.{ .font_size = TOKENS.font_size.sm, .color = TOKENS.color.fg_tertiary });
/// Section heading, as native sidebars draw it (Finder "Favorites", Windows / GNOME group
/// headers): small, bold, sentence case, dimmed; extra space above separates the groups.
/// Rows below are regular weight in the primary colour, so weight and tone set the levels apart.
pub const navSection = ui.css(.{ .padding = .{ .x = TOKENS.space.space200, .top = TOKENS.space.space600, .bottom = TOKENS.space.space100 } });
pub const navSectionText = ui.css(.{ .font_size = TOKENS.font_size.xs, .font_weight = 700, .color = TOKENS.color.fg_tertiary });
pub const Nav = ui.sva(.{
    .slots = .{ .root, .label },
    .base = .{
        .root = .{
            .width = .fill,
            .height = ui.arb.px(32),
            .direction = .row,
            .align_items = .center,
            .padding = .{ .x = TOKENS.space.space200 },
            .corner_radius = TOKENS.radius.lg,
            .cursor = .pointer,
            ._hover = .{ .background = TOKENS.color.bg_hover },
        },
        .label = .{ .font_size = TOKENS.font_size.md, .font_weight = 400, .color = TOKENS.color.fg_primary },
    },
    .variants = .{ .selected = .{
        .false = .{},
        .true = .{
            .root = .{ .background = TOKENS.color.bg_tertiary },
            .label = .{ .font_weight = 600, .color = TOKENS.color.fg_primary },
        },
    } },
    .defaults = .{ .selected = false },
});
pub const sidebarFooter = ui.css(.{ .padding = .{ .x = TOKENS.space.space400, .y = TOKENS.space.space300 } });
pub const sidebarFooterText = ui.css(.{ .font_size = TOKENS.font_size.xs, .color = TOKENS.color.fg_tertiary });
// The workspace fills only the space after the sidebar. Its stories may have
// long unbreakable sample lines; those must not become the row's automatic min.
pub const workspace = ui.css(.{ .width = .fill, .height = .fill, .flex_basis = 0, .min_width = 0, .direction = .column, .position = .relative, .background = TOKENS.color.bg_primary });
/// Each window backend compiles its own native window design (docs/WINDOW_CHROME.md):
/// AppKit follows macOS 26 Finder, Win32 a Windows 11 app (Mica, title bar, navigation
/// pane, content card), Wayland a GNOME / libadwaita split view with two header bars.
pub const backend = @import("zenit_app").build_environment.window_backend;
pub const header_height: f32 = switch (backend) {
    .appkit => 52,
    .win32 => 48,
    else => 47,
};
/// Story content top padding: on macOS stories start below the floating toolbar and scroll
/// under it; elsewhere the title bar is above the content.
pub const content_top: f32 = switch (backend) {
    .appkit => header_height + 32,
    .win32 => 8,
    else => 32,
};

/// Story area background: the Windows content card's layer colour, white elsewhere.
pub const content_bg: ui.Color = if (backend == .win32) ui.Color.hex(0xf9f9f9) else ui.theme.modes.light.tokens.color.bg_primary;

// -- macOS 26 Finder: a floating Regular glass sidebar inset from the window edges, content
// to its right, and a toolbar of glass capsules floating over the content in a 52 pt title
// bar (items 36 pt, 8 pt from the top). Traffic lights sit in the sidebar's top row.
pub const sidebar_inset: f32 = 8;
pub const sidebar_width: f32 = 200;
pub const sidebar_radius: f32 = 18;
/// Content starts right of the sidebar and its gutter.
pub const content_left: f32 = sidebar_inset + sidebar_width + sidebar_inset;
pub const sidebar_layer = ui.css(.{
    .position = .absolute,
    .width = ui.arb.px(sidebar_width + sidebar_inset),
    .height = .fill,
    .direction = .column,
    .padding = .{ .left = sidebar_inset, .top = sidebar_inset, .bottom = sidebar_inset },
});
/// Sidebar top row: traffic lights / left caption controls; part of the drag region.
pub const sidebarTop = ui.css(.{ .width = .fill, .height = ui.arb.px(header_height - sidebar_inset), .direction = .row, .align_items = .center, .padding = .{ .left = 4 } });
// This is the viewport-sized layer; overflowing stories scroll inside it.
pub const content_layer = ui.css(.{ .width = .fill, .height = .fill, .flex_basis = 0, .min_height = 0, .direction = .row });
// Keep the reserved sidebar space even when a story's intrinsic width is large.
pub const contentGutter = ui.css(.{ .width = ui.arb.px(content_left), .height = .fill, .flex_shrink = 0 });
/// Full-width title bar over everything (the drag region); transparent.
pub const header = ui.css(.{
    .position = .absolute,
    .width = .fill,
    .height = ui.arb.px(header_height),
    .direction = .row,
    .align_items = .center,
});
/// Width left of the toolbar once native controls on the left are reserved.
pub fn headerLeadSized(width: f32, _: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .{ .px = width }, .height = ui.Sizing.fill(), .direction = .row, .align_items = .center, .padding = .{ .left = sidebar_inset + 4 } };
}
pub const toolbar = ui.css(.{
    .width = .fill,
    .height = .fill,
    .direction = .row,
    .align_items = .center,
    .gap = 12,
    .padding = .{ .left = 12, .right = 12 },
});
/// Empty title-bar space: stays part of the drag region.
pub const headerSpacer = ui.css(.{ .width = .fill, .height = .fill });
// -- Windows 11: Mica window background, a 48 px title bar (back / forward, app icon and
// name, caption buttons flush top-right), a navigation pane on the Mica, and the page on a
// content card (rounded top-left corner, hairline stroke) with a Settings-style page title.
pub const win = struct {
    pub const mica = ui.Color.hex(0xf3f3f3);
    // flex_basis 0 / min_height 0 like the macOS root: the window, not the content, sets
    // the height (CSS min-height: auto would stretch the root to the full story list).
    pub const root = ui.css(.{ .width = .fill, .height = .fill, .flex_basis = 0, .min_height = 0, .direction = .column, .background = mica });
    pub const titlebar = ui.css(.{ .width = .fill, .height = ui.arb.px(header_height), .direction = .row, .align_items = .center, .padding = .{ .left = 4 } });
    pub const titleButton: ui.BoxStyle = .{ .width = .{ .px = 40 }, .height = .{ .px = 36 }, .padding = ui.Padding.all(0), .border = .{ .radius = 4 }, .background = ui.Color.TRANSPARENT };
    pub const appIcon = ui.css(.{ .width = ui.arb.px(16), .height = ui.arb.px(16), .align_items = .center, .justify = .center, .background = ui.Color.hex(0x005fb8), .corner_radius = ui.arb.px(4) });
    pub const appIconLetter = ui.css(.{ .font_size = ui.arb.px(10), .font_weight = 700, .color = ui.Color.WHITE });
    pub const appTitle = ui.css(.{ .font_size = ui.arb.px(12), .color = ui.Color.hex(0x1a1a1a), .wrap = .none, .padding = .{ .left = 8 } });
    // min_height 0: a column child defaults to its content height (CSS min-height: auto),
    // which let the navigation list stretch the body past the window: the sidebar had
    // nothing to scroll and stories laid out below the window edge.
    pub const body = ui.css(.{ .width = .fill, .height = .fill, .min_height = 0, .direction = .row });
    pub const navPane = ui.css(.{ .width = ui.arb.px(280), .height = .fill, .direction = .column, .padding = .{ .x = 4 } });
    pub const card: ui.BoxStyle = .{
        .border_overlay = true,
        .width = ui.Sizing.fill(),
        .height = ui.Sizing.fill(),
        .direction = .column,
        .background = ui.Color.hex(0xf9f9f9),
        .border_top_width = 1,
        .border_left_width = 1,
        .border_top_color = ui.Color.hex(0xe5e5e5),
        .border_left_color = ui.Color.hex(0xe5e5e5),
        .corner_radii = .{ .each = .{ 8, 0, 0, 0 } },
        // Borders take no layout space: inset the children by the stroke, or the story
        // area's opaque background paints over it.
        .padding = .{ .top = 1, .left = 1 },
        .overflow_hidden = true,
    };
    pub const pageHeader = ui.css(.{ .width = .fill, .direction = .row, .align_items = .center, .gap = 12, .padding = .{ .left = 36, .right = 36, .top = 28, .bottom = 4 } });
    pub const pageParent = ui.css(.{ .font_size = ui.arb.px(28), .font_weight = 600, .color = ui.Color.hex(0x5f5f5f), .wrap = .none });
    pub const pageTitle = ui.css(.{ .font_size = ui.arb.px(28), .font_weight = 600, .color = ui.Color.hex(0x1a1a1a), .wrap = .none });
};

// -- GNOME / libadwaita: AdwNavigationSplitView. The sidebar pane (sidebar colour) and the
// content pane each carry a 47 px header bar; caption buttons follow the desktop's button
// layout (left ones in the sidebar header, right ones in the content header), titles are
// bold and centred, header buttons flat.
pub const gnome = struct {
    pub const sidebar_bg = ui.Color.hex(0xebebed);
    pub const view_bg = ui.Color.hex(0xffffff);
    pub const root = ui.css(.{ .width = .fill, .height = .fill, .flex_basis = 0, .min_height = 0, .direction = .row, .background = view_bg });
    pub const sidebar = ui.css(.{ .width = ui.arb.px(260), .height = .fill, .direction = .column, .background = sidebar_bg });
    pub const header = ui.css(.{ .width = .fill, .height = ui.arb.px(header_height), .direction = .row, .align_items = .center, .gap = 6, .padding = .{ .x = 6 } });
    pub const contentHeader = ui.css(.{
        .border_overlay = true,
        .width = .fill,
        .height = ui.arb.px(header_height),
        .direction = .row,
        .align_items = .center,
        .gap = 6,
        .padding = .{ .x = 6 },
        .background = view_bg,
        .border_bottom_width = TOKENS.border_width.thin,
        .border_bottom_color = ui.Color.rgba(0, 0, 0, 18),
    });
    pub const title = ui.css(.{ .font_size = ui.arb.px(15), .font_weight = 700, .color = ui.Color.rgba(0, 0, 6, 204), .wrap = .none });
    pub const flatButton: ui.BoxStyle = .{ .width = .{ .px = 34 }, .height = .{ .px = 34 }, .padding = ui.Padding.all(0), .border = .{ .radius = 6 }, .background = ui.Color.TRANSPARENT };
    pub const content = ui.css(.{ .width = .fill, .height = .fill, .direction = .column, .background = view_bg });
};

pub const heading = ui.css(.{ .direction = .row, .align_items = .center, .gap = TOKENS.space.space300 });
pub const category = ui.css(.{ .font_size = TOKENS.font_size.xs, .font_weight = 500, .color = TOKENS.color.fg_tertiary });
pub const title = ui.css(.{ .font_size = ui.arb.px(15), .font_weight = 700, .color = TOKENS.color.fg_primary, .wrap = .none });
pub const devtoolsButton = ui.css(.{
    .direction = .row,
    .align_items = .center,
    .padding = .{ .x = TOKENS.space.space200, .y = TOKENS.space.space150 },
    .corner_radius = TOKENS.radius.lg,
    .cursor = .pointer,
    ._hover = .{ .background = TOKENS.color.bg_hover },
});
pub const devtoolsLabel = ui.css(.{ .font_size = TOKENS.font_size.sm, .color = TOKENS.color.fg_secondary });
/// Content column: the story note above the story panel. The gap (32) keeps the note out of the
/// website's frames (the story root padded 28).
pub const contentColumn = ui.css(.{ .width = .fill, .gap = TOKENS.space.space800 });
/// Non-scrolling content area (WidgetSpec.scrolls = false): padding and bg color
/// same as ScrollArea
pub const plainContent = ui.css(.{ .width = .fill, .height = .fill, .padding = .{ .x = TOKENS.space.space800, .bottom = TOKENS.space.space800, .top = ui.arb.px(content_top) }, .gap = TOKENS.space.space800, .background = content_bg });
pub const panel = ui.css(.{ .width = .fill, .direction = .column });
/// Story panel whose root hugs its content, left-aligned with the note (WidgetSpec.wide = false).
pub const panelHug = ui.css(.{ .width = .fill, .direction = .column, .align_items = .start });
/// The story note (WidgetSpec.note): secondary text above the panel, wrapping.
/// Wraps at a readable measure (and stays clear of stories that draw over the window's right side).
pub const storyNote = ui.css(.{ .font_size = TOKENS.font_size.sm, .color = TOKENS.color.fg_secondary, .wrap = .word_break, .width = .fill, .max_width = 480 });

// -- Story content common styles (shared by stories.zig and other story files) --

/// Vertical layout, gap spacing (px)
pub fn stack(comptime gap: f32) @TypeOf(ui.css(.{ .gap = gap, .no_cross_stretch = true })) {
    return .{};
}

/// Horizontal layout, vertically centered, gap spacing (px)
pub fn line(comptime gap: f32) @TypeOf(ui.css(.{ .gap = gap, .align_items = .center, .no_cross_stretch = true })) {
    return .{};
}

/// Fixed width (px)
pub fn fixedWidth(comptime px: f32) @TypeOf(ui.css(.{ .width = px })) {
    return .{};
}

/// Story subsection label / state echo text (13px secondary color)
pub const storyLabel = ui.css(.{ .font_size = 13, .color = TOKENS.color.fg_secondary });

/// Story body text (13-14px primary color)
pub const storyBody = ui.css(.{ .font_size = 14, .color = TOKENS.color.fg_primary });

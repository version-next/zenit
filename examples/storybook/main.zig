/// storybook - centralized component showcase with e2e verification.
///
/// Layout: master-detail, left sidebar (component list) and right content panel. A
/// left row click only switches the right panel (no long scrolling page), so e2e
/// always operates on the visible component.
///
/// Architecture:
/// - each component has one WIDGETS entry: { key, title, buildFn }
/// - active signal (current story index) + search signal drive all UI: sidebar
///   selection/filter, breadcrumb, right panel (v.dynamic rebuilds per active)
/// - the window is one declarative ui.view tree, no post-mount node mutations
const std = @import("std");
const ui = @import("ui");
const zenit_app = @import("zenit_app");
const MultiWindowApp = zenit_app.MultiWindowApp;
const Chrome = zenit_app.window_chrome;

const Padding = ui.Padding;
const light = ui.theme.modes.light;

const stories = @import("stories.zig");
const S = @import("styles.zig");

const v = ui.view;
const W = ui.widgets;

var g_storybook_cx: ?*ui.Cx = null;
var g_devtools_close_requested = false;
/// SIGTERM/SIGINT request a graceful quit so `gpa.deinit()` runs and reports
/// leaks. The e2e runner stops the app with SIGTERM; without this the process
/// died before the leak check and every run was leak-blind.
var g_quit_requested = std.atomic.Value(bool).init(false);

fn onTerminateSignal(_: std.posix.SIG) callconv(.c) void {
    g_quit_requested.store(true, .release);
}

fn installTerminateHandlers() void {
    if (@import("builtin").os.tag == .windows) return;
    const action: std.posix.Sigaction = .{
        .handler = .{ .handler = onTerminateSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.TERM, &action, null);
    std.posix.sigaction(std.posix.SIG.INT, &action, null);
}

fn requestDevtoolsClose(flag: *bool) void {
    flag.* = true;
}

fn mountDevtools(cx: *ui.Cx, scope: *ui.Scope) anyerror!*ui.Node {
    _ = scope;
    cx.setTheme(&ui.theme.modes.light);
    return ui.devtools.mountPanel(cx, g_storybook_cx orelse return error.StorybookTargetMissing, .{
        .title = "Zenit Storybook DevTools",
        .on_close = ui.Cx.handlerFrom(bool, &g_devtools_close_requested, requestDevtoolsClose),
    });
}

// component registry - each item: sidebar title + test_id key (nav.<key> / story.<key>) + story
// builder.
const WidgetSpec = struct {
    key: []const u8,
    title: []const u8,
    build: *const fn (*ui.Scope, *ui.Cx) anyerror!*ui.Node,
    /// content area wrapped in scrollable ScrollArea (default). PaintReplay-like stories that need
    /// 'container outside scroll' turn this off: descendants of scroll container skip legacy
    /// overflow cache, wrapping prevents testing that path.
    scrolls: bool = true,
    /// What the story demonstrates or checks, for whoever reads Storybook: shown above the story
    /// panel, outside `story.<key>` (the website frames that panel's root: notes stay out of its
    /// screenshots and videos).
    note: []const u8 = "",
    /// The story root spans the panel's width; otherwise it hugs its content, left-aligned.
    wide: bool = false,
    section: []const u8,
};

// Builder names stay as data until selection: taking every function address here
// would force Zig to analyze the full showcase before filtering.
const StoryInfo = struct {
    key: []const u8,
    title: []const u8,
    builder: []const u8,
    scrolls: bool = true,
    note: []const u8 = "",
    wide: bool = false,
};
const ALL_WIDGETS = [_]StoryInfo{
    .{ .key = "controls", .title = "Controls", .builder = "buildControls" },
    .{ .key = "button", .title = "Button", .builder = "buildButton" },
    .{ .key = "checkbox", .title = "Checkbox", .builder = "buildCheckbox" },
    .{ .key = "switch", .title = "Switch", .builder = "buildSwitch" },
    .{ .key = "radio", .title = "Radio", .builder = "buildRadio" },
    .{ .key = "slider", .title = "Slider", .builder = "buildSlider" },
    .{ .key = "rate", .title = "Rate", .builder = "buildRate" },
    .{ .key = "stepper", .title = "NumberStepper", .builder = "buildNumberStepper" },
    .{ .key = "group", .title = "Group", .builder = "buildGroup" },
    .{ .key = "input", .title = "Input", .builder = "buildInput" },
    .{ .key = "textarea", .title = "Textarea", .builder = "buildTextarea" },
    .{ .key = "editabletext", .title = "EditableText", .builder = "buildEditableText" },
    .{ .key = "select", .title = "Select", .builder = "buildSelect" },
    .{ .key = "combobox", .title = "ComboBox", .builder = "buildComboBox" },
    .{ .key = "tags", .title = "TagsInput", .builder = "buildTagsInput" },
    .{ .key = "upload", .title = "FileUpload", .builder = "buildFileUpload" },
    .{ .key = "datetimepicker", .title = "DateTimePicker", .builder = "buildDateTimePicker" },
    .{ .key = "datepicker", .title = "DatePicker", .builder = "buildDatePicker" },
    .{ .key = "daterange", .title = "DateRangePicker", .builder = "buildDateRangePicker" },
    .{ .key = "form", .title = "Form", .builder = "buildForm" },
    .{ .key = "formcompose", .title = "Form Composition", .builder = "buildFormComposition" },
    .{ .key = "badge", .title = "Badge", .builder = "buildBadge" },
    .{ .key = "tag", .title = "Tag", .builder = "buildTag" },
    .{ .key = "chip", .title = "Chip", .builder = "buildChip" },
    .{ .key = "card", .title = "Card", .builder = "buildCard" },
    .{ .key = "alert", .title = "Alert", .builder = "buildAlert" },
    .{ .key = "progress", .title = "Progress", .builder = "buildProgress" },
    .{ .key = "spinner", .title = "Spinner", .builder = "buildSpinner" },
    .{ .key = "skeleton", .title = "Skeleton", .builder = "buildSkeleton" },
    .{ .key = "timeline", .title = "Timeline", .builder = "buildTimeline" },
    .{ .key = "table", .title = "Table", .builder = "buildTable" },
    .{ .key = "datatable", .title = "DataTable", .builder = "buildDataTable" },
    .{ .key = "tree", .title = "Tree", .builder = "buildTree" },
    .{ .key = "calendar", .title = "Calendar", .builder = "buildCalendar" },
    .{ .key = "markdown", .title = "Markdown", .builder = "buildMarkdown" },
    .{ .key = "icons", .title = "Icons", .builder = "buildIconGallery", .note = "System icon contract (provider-neutral subset)" },
    .{ .key = "tabs", .title = "Tabs", .builder = "buildTabs" },
    .{ .key = "accordion", .title = "Accordion", .builder = "buildAccordion" },
    .{ .key = "menu", .title = "Menu", .builder = "buildMenu", .note = "Click the trigger to open the menu" },
    .{ .key = "breadcrumb", .title = "Breadcrumb", .builder = "buildBreadcrumb" },
    .{ .key = "steps", .title = "Steps", .builder = "buildSteps" },
    .{ .key = "notification", .title = "Notification", .builder = "buildNotification" },
    .{ .key = "tooltip", .title = "Tooltip", .builder = "buildTooltip", .note = "Hover a button to see the tooltip (4 positions)" },
    .{ .key = "popover", .title = "Popover", .builder = "buildPopover", .note = "Click the button to toggle the popover" },
    .{ .key = "modal", .title = "Modal", .builder = "buildModal" },
    .{ .key = "sheet", .title = "Sheet", .builder = "buildSheet" },
    .{ .key = "zindex", .title = "ZIndex", .builder = "buildZIndex" },
    .{ .key = "divider", .title = "Divider", .builder = "buildDivider" },
    .{ .key = "stack", .title = "Stack", .builder = "buildStack" },
    .{ .key = "layoutbox", .title = "Layout / Box Model", .builder = "buildLayoutBoxModel" },
    .{ .key = "virtuallist", .title = "VirtualList", .builder = "buildVirtualList" },
    .{ .key = "virtuallistdynamic", .title = "VirtualList (Dynamic)", .builder = "buildVirtualListDynamic" },
    .{ .key = "scrolling", .title = "Scrolling", .builder = "buildScrolling", .note = "Wheel and trackpad input in logical points. Try sideways scrolling and nested boundaries; live phase readouts show what the platform delivers." },
    .{ .key = "scrollarea", .title = "ScrollArea", .builder = "buildScrollArea" },
    .{ .key = "grid", .title = "Grid", .builder = "buildGrid" },
    .{ .key = "glassbox", .title = "Liquid Glass", .builder = "buildGlassBox" },
    .{ .key = "glasslab", .title = "Glass Lab", .builder = "buildGlassLab" },
    .{ .key = "glasscontrols", .title = "Glass slider & toggle", .builder = "buildGlassControls", .note = "GlassSlider / GlassToggle: press a knob — it turns into clear Liquid Glass and grows; release restores the white knob" },
    .{ .key = "glasscontrolsios", .title = "iOS slider & switch", .builder = "buildGlassControlsIos" },
    .{ .key = "glasstoolbar", .title = "Glass toolbar", .builder = "buildGlassToolbar", .note = "GlassToolbar: hover shows a plate, press deepens it, the selected segment keeps one; separators only between unselected segments. Dark title bar: the glass flips to the dark family and the plates turn white" },
    .{ .key = "glassiosbars", .title = "iOS bars & glass buttons", .builder = "buildGlassIosBars" },
    .{ .key = "glasspopover", .title = "Glass popover", .builder = "buildGlassPopover", .note = "Glass button + .popover: the popover scales from its arrow tip (spring, opacity follows scale); the button does not morph" },
    .{ .key = "glasschrome", .title = "Toolbar over content", .builder = "buildGlassChrome", .note = "Toolbar over scrolling content: GlassToolbar controls on the measured title-bar edge (content washes toward the window background; no custom blur)" },
    .{ .key = "glassmotion", .title = "Glass Transitions", .builder = "buildGlassMotion" },
    .{ .key = "glasssplit", .title = "Glass Split & Merge", .builder = "buildGlassSplit" },
    .{ .key = "glassunion", .title = "GlassEffectContainer: union", .builder = "buildGlassUnion", .note = "glassEffectUnion(id:): members sharing an id merge into one shape over their bounding box (Apple sample on top)" },
    .{ .key = "glassadapt", .title = "Glass adaptivity (scroll)", .builder = "buildGlassAdapt", .note = "Scroll white → black: the 36 pt glass bar flips dark below 48/255 (back above 120); the large panel never flips" },
    .{ .key = "glassconcentric", .title = "Concentric corners", .builder = "buildGlassConcentric", .note = "ConcentricRectangle: each corner = max(container radius − max(dx, dy), minimum); glass follows the same shape" },
    .{ .key = "glassextension", .title = "Background extension", .builder = "buildGlassExtension", .note = "backgroundExtensionEffect: mirrored copies fill the leading safe area; only the view's own safe area is blurred" },
    .{ .key = "canvasevents", .title = "CanvasEvents", .builder = "buildCanvasEvents", .note = "Canvas events: scroll modifiers / magnify / drag / clipboard image" },
    .{ .key = "drag", .title = "Drag", .builder = "buildDrag", .note = "Drag: ui.interaction.drag primitive (threshold 4px, Escape cancels, arrows nudge when focused)" },
    .{ .key = "multiclick", .title = "Gestures", .builder = "buildMultiClick", .note = "Gesture arena: tap/double/triple counts + press-and-hold long_press (500ms) + pointer-cancel state" },
    .{ .key = "animctl", .title = "AnimControls", .builder = "buildAnimCtl", .note = "Animation controls: yoyo replay / timeline reverse / keyframes catch-up / degenerate spring" },
    .{ .key = "vectorpath", .title = "VectorPath", .builder = "buildVectorPath", .note = "Batched fill_path: adjacent stars (polygon mode)" },
    .{ .key = "blend", .title = "BlendModes", .builder = "buildBlend", .note = "Blend modes (exact-color e2e targets)" },
    .{ .key = "emoji", .title = "Emoji", .builder = "buildEmoji", .note = "Color emoji (BGRA atlas page + shader color branch)" },
    .{ .key = "rtl", .title = "RTL", .builder = "buildRtl", .note = "RTL bidi text (CoreText 已做 bidi，glyph 数组为视觉序)" },
    .{ .key = "wordnav", .title = "WordNav", .builder = "buildWordNav", .note = "Word navigation: Alt+←/→ jumps whole Greek/Cyrillic words; double-click selects the word; family emoji is one cluster" },
    .{ .key = "viewdsl", .title = "View DSL", .builder = "buildViewDsl" },
    .{ .key = "wall", .title = "Component Wall", .builder = "buildComponentWall" },
    .{ .key = "glassgroup", .title = "GlassEffectContainer: sampling", .builder = "buildGlassGroup", .note = "GlassGroup: one capture per container; both rows must match pixel-for-pixel" },
    .{ .key = "glassmerge", .title = "GlassEffectContainer: merge", .builder = "buildGlassMerge", .note = "GlassMerge: two capsules in a GlassGroup; neck heights must match native GlassEffectContainer" },
    .{ .key = "glasstint", .title = "GlassEffectContainer: tint fusion", .builder = "buildGlassTintMerge", .note = "Tint fusion in a GlassEffectContainer (spacing 40), white backdrop: bridges stay untinted, tints feather into neighbours and compose where they overlap" },
    .{ .key = "glassislands", .title = "Regression: blur islands", .builder = "buildGlassIslands", .note = "Two blur+rounded-clip islands: BOTH must show their content", .wide = true },
    .{ .key = "glassappkit", .title = "NSGlassEffectView parameters", .builder = "buildGlassAppKit" },
    .{ .key = "glassidiom", .title = "Glass idiom: macOS / iOS", .builder = "buildGlassIdiom" },
    .{ .key = "glassioslens", .title = "iOS tab lens fixtures", .builder = "buildGlassIosLens" },
    .{ .key = "blendlab", .title = "Blend lab", .builder = "buildBlendLab", .note = "BlendLab: translucency, group opacity, text, gradients, shadows, edges and scaled images (native_blend_reference.swift geometry)" },
    .{ .key = "glassedge", .title = "Glass at the window edge", .builder = "buildGlassEdge", .note = "Glass reaching the window edge samples past it (the capture beyond the window is transparent black): the wallpaper's colours must run cleanly to the right and bottom edges under the inspector and the toolbar, with no dark rim." },
    .{ .key = "popoverregress", .title = "Popover regressions", .builder = "buildPopoverRegressions" },
    .{ .key = "cjkweights", .title = "CJK weights", .builder = "buildCjkWeights", .note = "One Han line in several weights at one size, in the UI font and through a Latin-only family's fallback: every glyph of a semibold line is heavier than the regular line" },
    .{ .key = "popovertext", .title = "Popover text seam", .builder = "buildPopoverText", .note = "Popovers opening from an off-grid origin: the panel scales its settled text as one picture; no glyph moves on its own while it opens or when it settles" },
    .{ .key = "cornerclip", .title = "Per-corner clip", .builder = "buildCornerClip", .note = "Overflow clip with four corner radii: rounded corners cut the square red fills, square corners keep them, on every clip path (shader mask, opacity fold, glass clip surface, nested clip layer, half-turned and mirrored owners)" },
    .{ .key = "paintreplay", .title = "PaintReplay", .builder = "buildPaintReplay", .scrolls = false },
    .{ .key = "heavytext", .title = "HeavyText", .builder = "buildHeavyText" },
    .{ .key = "textanimjitter", .title = "TextAnimJitter", .builder = "buildTextAnimJitter" },
    .{ .key = "cleanup", .title = "CleanupHooks", .builder = "buildCleanup" },
    .{ .key = "interactionlifecycle", .title = "Interaction Lifecycle", .builder = "buildInteractionLifecycle" },
    .{ .key = "teardownstress", .title = "Lifecycle Stress", .builder = "buildTeardownStress" },
    .{ .key = "secsvg", .title = "Security / SVG", .builder = "buildSecuritySvg" },
    .{ .key = "secopacity", .title = "Security / Opacity", .builder = "buildSecurityOpacity" },
    .{ .key = "sectext", .title = "Security / Text", .builder = "buildSecurityText" },
};

const NavSection = struct {
    start_key: []const u8,
    label: []const u8,
};

/// Sections are anchored by stable story keys instead of numeric offsets, so
/// inserting a component inside a group cannot silently misclassify every
/// section after it.
const NAV_SECTIONS = [_]NavSection{
    .{ .start_key = "controls", .label = "Actions" },
    .{ .start_key = "input", .label = "Inputs" },
    .{ .start_key = "badge", .label = "Data display" },
    .{ .start_key = "tabs", .label = "Navigation" },
    .{ .start_key = "notification", .label = "Overlays" },
    .{ .start_key = "divider", .label = "Layout" },
    .{ .start_key = "glassbox", .label = "Liquid glass" },
    .{ .start_key = "canvasevents", .label = "Labs" },
    .{ .start_key = "glassgroup", .label = "Glass regressions" },
    .{ .start_key = "popoverregress", .label = "Regressions" },
    .{ .start_key = "secsvg", .label = "Security regressions" },
};

const WIDGETS = blk: {
    @setEvalBranchQuota(100_000);
    const selection = @import("storybook_options").stories;
    const filter = @import("story_filter.zig");
    filter.validate(&ALL_WIDGETS, selection) catch |err|
        @compileError("invalid -Dstories: " ++ @errorName(err) ++ "; use unique, comma-separated story keys (for example button,card)");
    var count: usize = 0;
    for (ALL_WIDGETS) |info| {
        if (filter.includes(selection, info.key)) count += 1;
    }
    var out: [count]WidgetSpec = undefined;
    var n: usize = 0;
    if (!std.mem.eql(u8, ALL_WIDGETS[0].key, NAV_SECTIONS[0].start_key))
        @compileError("storybook registry must start with the first navigation section anchor");
    var section: []const u8 = undefined;
    for (ALL_WIDGETS) |info| {
        for (NAV_SECTIONS) |group| {
            if (std.mem.eql(u8, group.start_key, info.key)) section = group.label;
        }
        if (filter.includes(selection, info.key)) {
            out[n] = .{
                .key = info.key,
                .title = info.title,
                .build = @field(stories, info.builder),
                .scrolls = info.scrolls,
                .note = info.note,
                .wide = info.wide,
                .section = section,
            };
            n += 1;
        }
    }
    break :blk out;
};

const COMPONENT_COUNT_LABEL = std.fmt.comptimePrint("{d} components", .{WIDGETS.len});

/// nav items (canonical order): section titles and story rows. compile-time expand from WIDGETS /
/// NAV_SECTIONS.
const NavEntry = struct {
    /// row: WIDGETS index; section title: null
    widget: ?usize,
    /// section title: WIDGETS index range [first, end) for this group
    first: usize = 0,
    end: usize = 0,
};

const NAV_ENTRIES = blk: {
    @setEvalBranchQuota(20_000);
    var out: [WIDGETS.len + NAV_SECTIONS.len]NavEntry = undefined;
    var n: usize = 0;
    for (WIDGETS, 0..) |_, i| {
        if (isSectionStart(i)) {
            var end = i + 1;
            while (end < WIDGETS.len and !isSectionStart(end)) end += 1;
            out[n] = .{ .widget = null, .first = i, .end = end };
            n += 1;
        }
        out[n] = .{ .widget = i };
        n += 1;
    }
    break :blk out[0..n].*;
};

/// sidebar shared state: current story and search term.
const Nav = struct {
    active: *ui.Signal(usize),
    /// owned text signal: Input on_change slice valid only during callback, copy on assignment.
    query: *ui.Signal([]const u8),
};

fn matches(widget: WidgetSpec, raw_query: []const u8) bool {
    const query = std.mem.trim(u8, raw_query, " \t");
    if (query.len == 0) return true;
    return std.ascii.findIgnoreCase(widget.title, query) != null or
        std.ascii.findIgnoreCase(widget.key, query) != null;
}

fn anyMatch(first: usize, end: usize, query: []const u8) bool {
    for (WIDGETS[first..end]) |w| {
        if (matches(w, query)) return true;
    }
    return false;
}

fn sectionForIndex(index: usize) []const u8 {
    return WIDGETS[index].section;
}

fn titleForIndex(index: usize) []const u8 {
    return WIDGETS[index].title;
}

fn isSectionStart(comptime index: usize) bool {
    return index == 0 or !std.mem.eql(u8, WIDGETS[index - 1].section, WIDGETS[index].section);
}

/// one nav item. item's own derived state (selected / search match) is memo on item scope: row
/// index is runtime value, inline derive (ui.map) cannot capture.
fn navEntry(p: struct { nav: Nav, entry: NavEntry }, scope: *ui.Scope, cx: *ui.Cx) !*ui.Node {
    const e = p.entry;
    const index = e.widget orelse {
        const has_match = try scope.createMemo(bool, .{ .query = p.nav.query, .first = e.first, .end = e.end }, struct {
            fn f(c: anytype) bool {
                return anyMatch(c.first, c.end, c.query.get());
            }
        }.f);
        return v.render(scope, cx, v.box(.{ .style = S.navSection, .visible = has_match }, .{
            v.text(.{ .style = S.navSectionText }, sectionForIndex(e.first)),
        }));
    };
    const spec = WIDGETS[index];
    const selected = try scope.createMemo(bool, .{ .active = p.nav.active, .index = index }, struct {
        fn f(c: anytype) bool {
            return c.active.get() == c.index;
        }
    }.f);
    const shown = try scope.createMemo(bool, .{ .query = p.nav.query, .index = index }, struct {
        fn f(c: anytype) bool {
            return matches(WIDGETS[c.index], c.query.get());
        }
    }.f);
    const select = try ui.on.bind(scope, .{ .active = p.nav.active, .index = index }, struct {
        fn f(c: anytype) void {
            c.active.set(c.index);
        }
    }.f);
    const parts = S.Nav.of(.{ .selected = selected });
    return v.render(scope, cx, v.row(.{
        .style = parts.root,
        .test_id = nav_ids[index],
        .visible = shown,
        .on_click = select,
    }, .{
        v.text(.{ .style = parts.label }, spec.title),
    }));
}

fn navItem(nav: Nav, entry: NavEntry) v.ComponentOf(navEntry) {
    return v.component(navEntry, .{ .nav = nav, .entry = entry });
}

/// test_id for each row (runtime index -> static string, node borrows).
const nav_ids = blk: {
    var ids: [WIDGETS.len][]const u8 = undefined;
    for (WIDGETS, 0..) |w, i| ids[i] = "nav." ++ w.key;
    break :blk ids;
};

fn noneMatch(query: []const u8) bool {
    return !anyMatch(0, WIDGETS.len, query);
}

fn toggleDevtools(cx: *ui.Cx) void {
    cx.inspector.enabled = !cx.inspector.enabled;
    if (!cx.inspector.enabled) {
        cx.inspector.pick_mode = false;
        cx.inspector.clearSelection();
    }
    cx.needs_redraw = true;
}

/// decorative text (separators etc): draws normally, not exposed to a11y.
const decorative = .{ .style = S.category, .a11y = ui.A11yProps{ .hidden = true } };

const StoryPersist = struct {
    active: *ui.Signal(usize),
    registered: bool = false,
    fn encode(raw: *anyopaque, allocator: std.mem.Allocator) ![]u8 {
        const self: *StoryPersist = @ptrCast(@alignCast(raw));
        return allocator.dupe(u8, WIDGETS[@min(self.active.peek(), WIDGETS.len - 1)].key);
    }
    fn decode(raw: *anyopaque, version: ?u32, bytes: ?[]const u8) !void {
        if (version != 1) return; // Unknown versions and removed stories retain the startup route.
        const key = bytes orelse return;
        const self: *StoryPersist = @ptrCast(@alignCast(raw));
        for (WIDGETS, 0..) |widget, i| if (std.mem.eql(u8, widget.key, key)) {
            self.active.set(i);
            return;
        };
    }
    fn cleanup(self: *StoryPersist) void {
        if (self.registered) zenit_app.dev_control.unpersist("storybook.story") catch |err| std.log.warn("storybook: dev_control unpersist failed: {s}", .{@errorName(err)});
    }
    fn changed(active: *ui.Signal(usize)) void {
        _ = active.get();
        zenit_app.dev_control.markDirty();
    }
};

fn mountUI(cx: *ui.Cx, scope: *ui.Scope) anyerror!*ui.Node {
    // 74 inline story builders plus key-anchored section lookup exceed Zig's
    // conservative default comptime branch budget during monomorphization.
    comptime {
        @setEvalBranchQuota(20_000);
    }

    // framework default theme is dark (cx.tokens=&theme.dark). storybook uses light colors
    // throughout, explicitly switch to light so components draw backgrounds (Table/Calendar use
    // cx.tokens) matching light text in story, avoid dark-on-dark.
    cx.setTheme(&ui.theme.modes.light);

    // ZENIT_STORYBOOK_STORY=<key>: startup opens specified story (observe first mount outside
    // harness in normal build).
    const initial_index: usize = blk: {
        // getEnvVarOwned not posix.getenv: storybook builds on Windows too (WTF-16 environment
        // block).
        var env_buf: [128]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&env_buf);
        const want = @import("zenit_environment").getOwned(fba.allocator(), "ZENIT_STORYBOOK_STORY") catch break :blk 0;
        for (WIDGETS, 0..) |w, i| if (std.mem.eql(u8, w.key, want)) break :blk i;
        // A real key that -Dstories filtered out is a build/launch mismatch: falling back to the
        // first story would silently capture the wrong screen, so fail loudly instead.
        for (ALL_WIDGETS) |info| if (std.mem.eql(u8, info.key, want)) {
            std.log.err("ZENIT_STORYBOOK_STORY={s} is not in this build's -Dstories selection", .{want});
            std.process.exit(2);
        };
        std.log.warn("ZENIT_STORYBOOK_STORY={s} matches no story; opening the first one", .{want});
        break :blk 0;
    };
    const nav = Nav{
        .active = try scope.createSignal(usize, initial_index), // default select first
        .query = try scope.createText("", .{}),
    };
    if (zenit_app.dev_control.enabled and zenit_app.dev_control.active()) {
        // Decode route/model before v.dynamic mounts the selected story.
        const persisted_story = try scope.createState(StoryPersist, .{ .active = nav.active });
        try scope.onCleanup(StoryPersist, persisted_story, StoryPersist.cleanup);
        try zenit_app.dev_control.persist("storybook.story", 1, persisted_story, StoryPersist.encode, StoryPersist.decode);
        persisted_story.registered = true;
        try scope.createEffect(nav.active, StoryPersist.changed);
    }
    if (zenit_app.test_harness.enabled and @import("builtin").os.tag == .macos) {
        for (WIDGETS, 0..) |spec, index| {
            if (std.mem.eql(u8, spec.key, "emoji"))
                @import("reactive_oom_fixture.zig").install(nav.active, index);
        }
    }

    const pager = try scope.createState(Pager, .{ .active = nav.active });
    // Search, story list and count: the same library in every desktop's sidebar.
    const library = try v.render(scope, cx, v.col(.{ .style = S.sidebarBody }, .{
        v.box(.{ .style = S.searchWrap }, .{
            v.row(.{ .style = S.searchField }, .{
                v.icon(.{ .style = S.searchIcon, .tint = S.searchIconTint }, ui.system_icons.search),
                // search box self-draws shell (border / background / icon), embedded Input only
                // keeps editable text surface.
                v.attrs(.{ .test_id = "storybook.search", .parts = .{ .input_container = "storybook.search.input" }, .style = S.searchInput }, W.Input(.{
                    .placeholder = "Search components",
                    .placeholder_color = light.tokens.color.fg_tertiary,
                    .size = .sm,
                    .embedded = true,
                    .on_change = ui.on.assign(nav.query),
                })),
            }),
        }),
        // nav list in ScrollArea: scrollable when component count exceeds window height (mouse
        // wheel / trackpad). e2e clickTestId uses test harness scroll-into-view (scroll target
        // into view before command), so off-screen rows still clickable, see
        // src/test_harness/command_executor.zig.
        v.with(W.ScrollArea(.{
            .persist_key = "storybook.sidebar",
            .direction = .vertical,
            .padding = .{ .top = 0, .right = 10, .bottom = 12, .left = 10 },
        }), .{
            v.listWith(nav, &NAV_ENTRIES, navItem),
            v.text(.{ .style = S.navEmptyHint, .visible = ui.map(nav.query, noneMatch) }, "No matching components"),
        }),
        v.box(.{ .style = S.sidebarFooter }, .{
            v.text(.{ .style = S.sidebarFooterText }, COMPONENT_COUNT_LABEL),
        }),
    }));
    // Each window backend compiles its own native window design. With a system title bar
    // (fallback or --native-titlebar) the header stays an ordinary toolbar.
    const root = try switch (S.backend) {
        .appkit => macWindow(scope, cx, nav, pager, library),
        .win32 => windowsWindow(scope, cx, nav, pager, library),
        else => gnomeWindow(scope, cx, nav, pager, library),
    };
    // F11 toggles fullscreen on every desktop (macOS also keeps its native ⌃⌘F).
    root.behavior.events.on_event_capture = windowKeys;
    root.behavior.events.capture_context = cx;
    return root;
}

/// Sidebar landmark: the VoiceOver rotor jumps between the sidebar nav and the main content
/// as units (verified on real VoiceOver).
const sidebar_a11y = ui.A11yProps{ .role = .navigation, .label = "Component library" };
const main_a11y = ui.A11yProps{ .role = .main };

/// macOS 26 Finder: floating Regular glass sidebar holding the traffic lights, a toolbar of
/// glass capsules floating over the content, and the title-bar scroll edge.
fn macWindow(scope: *ui.Scope, cx: *ui.Cx, nav: Nav, pager: *Pager, library: *ui.Node) !*ui.Node {
    const chrome = try cx.windowChrome();
    const lead_width = try scope.createMemo(f32, chrome, struct {
        fn read(state: *ui.Signal(Chrome.State)) f32 {
            return @max(0, S.content_left - leftControlsReserve(state.get()));
        }
    }.read);
    const TB = W.glass_toolbar;
    const nav_bar = try W.GlassToolbar(.{ .groups = &[_]TB.ToolbarGroup{.{ .buttons = &[_]TB.ToolbarButton{
        .{ .icon = ui.system_icons.chevron_left, .label = "Previous story", .on_click = ui.on.call(pager, Pager.previous), .test_id = "storybook.previous" },
        .{ .icon = ui.system_icons.chevron_right, .label = "Next story", .on_click = ui.on.call(pager, Pager.next), .test_id = "storybook.next" },
    } }} }).mount(scope, cx);
    nav_bar.root.style.width = .{ .fit = .{} };
    const action_bar = try W.GlassToolbar(.{ .groups = &[_]TB.ToolbarGroup{.{ .buttons = &[_]TB.ToolbarButton{
        .{ .icon = ui.icons.code, .label = "Open DevTools", .on_click = ui.on.call(cx, toggleDevtools), .test_id = "storybook.devtools" },
    } }} }).mount(scope, cx);
    action_bar.root.style.width = .{ .fit = .{} };
    const sidebar = try W.GlassBox(.{ .height = 1, .corner_radius = S.sidebar_radius, .padding = Padding.all(0), .body_gap = 0 }).mountWithState(scope, cx);
    sidebar.box.style.width = .{ .px = S.sidebar_width };
    sidebar.box.style.height = .{ .grow = .{ .min = 0 } };
    sidebar.box.meta.ownership.meta.test_id = "sidebar";
    sidebar.box.behavior.interaction.a11y = sidebar_a11y;
    // Top row: the traffic lights (title-bar height, part of the drag region).
    try sidebar.body.appendChild(cx.allocator, try v.render(scope, cx, v.box(.{ .style = S.sidebarTop }, .{})));
    try sidebar.body.appendChild(cx.allocator, library);
    return v.render(scope, cx, v.box(.{ .style = S.root }, .{
        // Content right of the sidebar; stories start below the title bar and scroll under it.
        v.row(.{ .style = S.content_layer }, .{
            v.box(.{ .style = S.contentGutter }, .{}),
            v.col(.{ .style = S.workspace, .a11y = main_a11y }, .{
                v.dynamic(nav.active, renderContent),
                // Title-bar edge: content scrolling under the toolbar washes toward the window
                // background (the measured macOS 26 scroll edge).
                try W.glass_toolbar.titlebarEdge(cx, .{ .dark = false }),
            }),
        }),
        v.col(.{ .style = S.sidebar_layer }, .{sidebar.box}),
        // The header reserves the traffic lights' measured space; the toolbar starts at the
        // content edge.
        W.WindowHeader(.{ .test_id = "storybook.header", .style = S.header }, .{
            v.box(.{ .style = v.styleBy(lead_width, S.headerLeadSized) }, .{}),
            v.row(.{ .style = S.toolbar }, .{
                nav_bar.root,
                v.text(.{ .style = S.title, .test_id = "storybook.title" }, ui.map(nav.active, titleForIndex)),
                v.box(.{ .style = S.headerSpacer }, .{}),
                action_bar.root,
            }),
        }),
    }));
}

fn chromeButton(icon: ui.SvgAsset, label: []const u8, handler: ui.Handler(void), style: ui.BoxStyle) @TypeOf(W.Button(.{})) {
    return W.Button(.{ .variant = .ghost, .icon_only = true, .icon_asset = icon, .icon_size = @as(f32, 16), .a11y_label = label, .on_click = handler, .base_style = style });
}

/// Windows 11: Mica window, 48 px title bar (back / forward, app icon and name, caption
/// buttons flush top-right), navigation pane on the Mica, page on a content card.
fn windowsWindow(scope: *ui.Scope, cx: *ui.Cx, nav: Nav, pager: *Pager, library: *ui.Node) !*ui.Node {
    const X = S.win;
    return v.render(scope, cx, v.col(.{ .style = X.root }, .{
        W.WindowHeader(.{ .test_id = "storybook.header", .style = X.titlebar }, .{
            W.WindowControls(.{ .side = .left, .fullscreen_controls = true, .height = S.header_height }),
            v.attrs(.{ .test_id = "storybook.previous" }, chromeButton(ui.system_icons.chevron_left, "Previous story", ui.on.call(pager, Pager.previous), X.titleButton)),
            v.attrs(.{ .test_id = "storybook.next" }, chromeButton(ui.system_icons.chevron_right, "Next story", ui.on.call(pager, Pager.next), X.titleButton)),
            v.box(.{ .style = X.appIcon }, .{v.text(.{ .style = X.appIconLetter }, "Z")}),
            v.text(.{ .style = X.appTitle }, "Zenit Storybook"),
            v.box(.{ .style = S.headerSpacer }, .{}),
            v.attrs(.{ .test_id = "storybook.devtools" }, chromeButton(ui.icons.code, "Open DevTools (Ctrl+Shift+I)", ui.on.call(cx, toggleDevtools), X.titleButton)),
            W.WindowControls(.{ .side = .right, .fullscreen_controls = true, .height = S.header_height }),
        }),
        v.row(.{ .style = X.body }, .{
            v.col(.{ .style = X.navPane, .test_id = "sidebar", .a11y = sidebar_a11y }, .{library}),
            v.col(.{ .style = X.card, .a11y = main_a11y }, .{
                // Settings-style page title: parent section, then the page.
                v.row(.{ .style = X.pageHeader, .test_id = "storybook.page" }, .{
                    v.text(.{ .style = X.pageParent }, ui.map(nav.active, sectionForIndex)),
                    v.text(.{ .style = X.pageParent, .a11y = ui.A11yProps{ .hidden = true } }, "›"),
                    v.text(.{ .style = X.pageTitle, .test_id = "storybook.title" }, ui.map(nav.active, titleForIndex)),
                }),
                v.dynamic(nav.active, renderContent),
            }),
        }),
    }));
}

/// GNOME / libadwaita split view: the sidebar pane and the content pane each have a header
/// bar; caption buttons follow the desktop's layout (left ones over the sidebar, right ones
/// over the content).
fn gnomeWindow(scope: *ui.Scope, cx: *ui.Cx, nav: Nav, pager: *Pager, library: *ui.Node) !*ui.Node {
    const G = S.gnome;
    return v.render(scope, cx, v.row(.{ .style = G.root }, .{
        v.col(.{ .style = G.sidebar, .test_id = "sidebar", .a11y = sidebar_a11y }, .{
            W.DragRegion(.{ .style = G.header }, .{
                W.WindowControls(.{ .side = .left, .fullscreen_controls = true }),
                v.box(.{ .style = S.headerSpacer }, .{}),
                v.text(.{ .style = G.title }, "Zenit Storybook"),
                v.box(.{ .style = S.headerSpacer }, .{}),
            }),
            library,
        }),
        v.col(.{ .style = G.content, .a11y = main_a11y }, .{
            W.WindowHeader(.{ .test_id = "storybook.header", .style = G.contentHeader }, .{
                v.attrs(.{ .test_id = "storybook.previous" }, chromeButton(ui.system_icons.chevron_left, "Previous story", ui.on.call(pager, Pager.previous), G.flatButton)),
                v.attrs(.{ .test_id = "storybook.next" }, chromeButton(ui.system_icons.chevron_right, "Next story", ui.on.call(pager, Pager.next), G.flatButton)),
                v.box(.{ .style = S.headerSpacer }, .{}),
                v.text(.{ .style = G.title, .test_id = "storybook.title" }, ui.map(nav.active, titleForIndex)),
                v.box(.{ .style = S.headerSpacer }, .{}),
                v.attrs(.{ .test_id = "storybook.devtools" }, chromeButton(ui.icons.code, "Open DevTools (Ctrl+Shift+I)", ui.on.call(cx, toggleDevtools), G.flatButton)),
                W.WindowControls(.{ .side = .right, .fullscreen_controls = true }),
            }),
            v.dynamic(nav.active, renderContent),
        }),
    }));
}

/// Toolbar back / forward: step through the stories in sidebar order.
const Pager = struct {
    active: *ui.Signal(usize),
    fn previous(p: *Pager) void {
        const i = p.active.peek();
        p.active.set(if (i == 0) WIDGETS.len - 1 else i - 1);
    }
    fn next(p: *Pager) void {
        p.active.set((p.active.peek() + 1) % WIDGETS.len);
    }
};

/// Space the header reserves for native controls on its left (macOS traffic lights), so
/// the leading segment still ends at the sidebar edge. Mirrors WindowHeader's inset.
fn leftControlsReserve(state: Chrome.State) f32 {
    if (state.effective_mode != .custom or state.controls_owner != .native) return 0;
    if (!state.controls_geometry_known) return S.content_left;
    var reserve: f32 = 0;
    for (state.native_controls[0..state.native_controls_count]) |r| {
        if (r.x + r.w / 2 < state.width / 2) reserve = @max(reserve, r.x + r.w + 8);
    }
    return reserve;
}

fn windowKeys(ev: ui.events.Event, raw: ?*anyopaque) ui.events.EventResult {
    const cx: *ui.Cx = @ptrCast(@alignCast(raw orelse return .ignored));
    switch (ev) {
        .key_down => |key| if (key.key == .f11) {
            const fullscreen = if (cx.windowChrome()) |c| c.peek().fullscreen else |_| false;
            cx.performWindowAction(.{ .fullscreen = !fullscreen }) catch {};
            return .stop;
        },
        else => {},
    }
    return .ignored;
}

fn renderContent(index: usize, scope: *ui.Scope, cx: *ui.Cx) !*ui.Node {
    @setEvalBranchQuota(200_000);
    inline for (WIDGETS, 0..) |spec, i| {
        if (i == index) return renderStoryContent(spec, scope, cx);
    }
    unreachable;
}

/// content area: wrapped in vertical ScrollArea by default (scrollable when story exceeds window
/// height; padding on ScrollArea, content moves with scroll); story with scrolls=false goes
/// directly in same-padding-and-background column. test_id='content' for e2e locate.
fn renderStoryContent(comptime spec: WidgetSpec, scope: *ui.Scope, cx: *ui.Cx) !*ui.Node {
    // the note (if any) above the panel; no node at all without one (it would take the gap)
    const body = if (spec.note.len > 0) .{
        v.text(.{ .style = S.storyNote }, spec.note),
        v.component(StoryPanel(spec).build, {}),
    } else .{v.component(StoryPanel(spec).build, {})};
    if (spec.scrolls) return v.render(scope, cx, v.with(W.ScrollArea(.{
        .persist_key = "storybook.content",
        .direction = .vertical,
        .padding = .{ .top = S.content_top, .right = light.tokens.space.space800, .bottom = light.tokens.space.space800, .left = light.tokens.space.space800 },
        .background = S.content_bg,
    }), .{
        v.col(.{ .style = S.contentColumn, .test_id = "content" }, body),
    }));
    return v.render(scope, cx, v.col(.{ .style = S.plainContent, .test_id = "content" }, body));
}

fn StoryPanel(comptime spec: WidgetSpec) type {
    return struct {
        fn build(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
            return renderStoryPanel(spec, scope, cx);
        }
    };
}

/// story displayed on content canvas, retains separate mount boundary and test marker.
fn renderStoryPanel(comptime spec: WidgetSpec, scope: *ui.Scope, cx: *ui.Cx) !*ui.Node {
    return v.render(scope, cx, v.col(.{ .style = if (spec.wide) S.panel else S.panelHug, .test_id = "story." ++ spec.key }, .{
        v.component(spec.build, {}),
    }));
}

pub fn main(init: std.process.Init) !void {
    // Debug/ReleaseSafe keep leak reporting for the e2e gates. Optimized
    // builds use the system malloc, which returns idle pages to the OS instead
    // of keeping per-size-class debug buckets resident.
    const checked = comptime @import("builtin").mode == .debug or @import("builtin").mode == .safe;
    var gpa = std.heap.DebugAllocator(.{}){};
    defer if (checked) {
        _ = gpa.deinit();
    };

    const allocator = if (checked) gpa.allocator() else std.heap.c_allocator;
    // Args.toSlice may own several allocations on Windows; the process arena
    // owns the complete argument view on every platform.
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    // --native-titlebar: system title bar, the header becomes an ordinary toolbar.
    // --zenit-custom-titlebar: platform-drawn caption controls over the header (the
    // attended Windows DWM caption fixture).
    var native_titlebar = false;
    var native_controls = @import("builtin").os.tag == .macos;
    var require_gpu_validation = false;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--native-titlebar")) native_titlebar = true;
        if (std.mem.eql(u8, arg, "--zenit-custom-titlebar")) native_controls = true;
        if (@import("builtin").os.tag == .linux and std.mem.eql(u8, arg, "--validation")) require_gpu_validation = true;
    }
    // Outlives the app (deinit runs after application.deinit): the cjkweights fixture's Latin-only
    // family (examples/storybook/cjk_weights).
    var font_registry = zenit_app.FontRegistry.init(allocator);
    defer font_registry.deinit();
    var application = MultiWindowApp.init(allocator, .{ .pump_timeout_ms = 16 });
    defer application.deinit();

    var storybook_config: @typeInfo(@TypeOf(MultiWindowApp.createWindowWith)).@"fn".param_types[1].? = .{
        .io = init.io,
        .font = .{ .locale = "zh-CN" },
        .window = .{
            .width = 1100,
            .height = 1000,
            .min_width = 640,
            .min_height = 420,
            .title = "zenit Storybook",
            .persist_key = "storybook.main",
            .titlebar_height = S.header_height,
            .chrome = if (native_titlebar) .native else .{ .custom = .{ .controls = if (native_controls) .automatic else .application, .unsupported = .use_native } },
        },
        .idle_skip_frames = true,
    };
    if (comptime @import("builtin").os.tag == .linux) storybook_config.require_gpu_validation = require_gpu_validation;
    // ZENIT_STORYBOOK_UI_FONT=<family>: replace the system UI font as the default family (a
    // Latin-only one sends Han text through the default family's fallback, the path an app with
    // its own Latin UI font takes; the cjkweights fixture checks it).
    if (@import("zenit_environment").getOwned(init.arena.allocator(), "ZENIT_STORYBOOK_UI_FONT") catch null) |family| {
        const families = try init.arena.allocator().alloc([]const u8, 1);
        families[0] = family;
        storybook_config.font.fallback_families = families;
    }
    const storybook = try application.createWindowWith(storybook_config, mountUI);
    const storybook_window_id = storybook.windowId();
    {
        const App = @TypeOf(storybook.*);
        font_registry.setFontSystem(if (@hasField(App, "font_manager")) &storybook.font_manager else &storybook.font_system);
        const cjk = @import("cjk_weights/mod.zig");
        std.debug.assert(@backingInt(try font_registry.intern(cjk.latin_family_name)) == cjk.latin_family_id);
        storybook.setFontRegistry(&font_registry);
    }
    if (zenit_app.test_harness.enabled)
        @import("atlas_eviction_fixture.zig").install(storybook);
    // BlendLab 32x32 checkerboard (8px squares), same image as native_blend_reference.swift.
    {
        var px: [32 * 32 * 4]u8 = undefined;
        for (0..32) |y| for (0..32) |x| {
            const val: u8 = if (((x / 8) + (y / 8)) % 2 == 0) 0 else 255;
            const o = (y * 32 + x) * 4;
            px[o] = val;
            px[o + 1] = val;
            px[o + 2] = val;
            px[o + 3] = 255;
        };
        stories.g_blend_checker_texture = storybook.renderer.image_renderer.loadTexture(32, 32, &px) catch |err| blk: {
            std.log.warn("BlendLab checker texture: {}", .{err});
            break :blk null;
        };
    }
    g_storybook_cx = storybook.cx;
    defer g_storybook_cx = null;

    installTerminateHandlers();

    var devtools_window_id: ?u64 = null;
    while (try application.tick()) {
        if (g_quit_requested.load(.acquire)) {
            application.quit();
            break;
        }
        const target = application.window(storybook_window_id) orelse {
            application.quit();
            break;
        };

        // Native close and the panel close button both converge here. The
        // target inspector bit is the single source of truth for Cmd+Opt+I,
        // the toolbar button, and the DevTools window lifecycle.
        if (devtools_window_id) |id| {
            if (application.window(id) == null) {
                devtools_window_id = null;
                target.cx.inspector.enabled = false;
                target.rebindTestHarness();
                // DevTools was the last laid-out Cx. Reset text_layout's
                // process bridge to the surviving Storybook font context
                // before a test RPC can render/query the target directly.
                target.cx.layout();
            }
        }
        if (g_devtools_close_requested) {
            g_devtools_close_requested = false;
            target.cx.inspector.enabled = false;
        }

        if (target.cx.inspector.enabled) {
            if (devtools_window_id == null) {
                var devtools_config: @TypeOf(storybook_config) = .{
                    .io = init.io,
                    .window = .{ .width = 980, .height = 720, .title = "Zenit Storybook DevTools" },
                    .idle_skip_frames = true,
                };
                if (comptime @import("builtin").os.tag == .linux) devtools_config.require_gpu_validation = require_gpu_validation;
                const devtools = try application.createWindowWith(devtools_config, mountDevtools);
                devtools_window_id = devtools.windowId();
            }
        } else if (devtools_window_id) |id| {
            _ = application.closeWindow(id);
            devtools_window_id = null;
            target.rebindTestHarness();
            target.cx.layout();
        }
    }
}

/// UI Components Module: VSCode-style component library.
/// Reference: vscode-ui-lib SolidJS implementation.
/// Component categories:
/// - Primitives: Button, Input, Checkbox, Switch, Badge
/// - Layout: Stack, Card, Divider, ScrollArea
/// - Interactive: Tabs, Tooltip, Modal
/// Design principles:
/// 1. SolidJS style: component function executes once; updates via Signal
/// 2. Accessibility: ARIA attributes, keyboard navigation
/// 3. Theme support: VSCode dark theme
/// 4. Animation support: transitions, easing.
const std = @import("std");
const core = @import("../core.zig");

pub const window_chrome = @import("window_chrome/mod.zig");
pub const WindowHeader = window_chrome.WindowHeader;
pub const WindowControls = window_chrome.WindowControls;
pub const DragRegion = window_chrome.DragRegion;
pub const ClientRegion = window_chrome.ClientRegion;

// Unified base.
pub const control_shell = @import("control_shell/mod.zig");
/// Test support: per-allocation OOM sweep during component mount. Export for consumers
/// to reuse same criteria.
pub const oom_sweep = @import("oom_sweep.zig");
pub const ControlShell = control_shell.ControlShell;
pub const IconFit = control_shell.IconFit;
pub const ControlVariant = control_shell.ControlVariant;
pub const ControlSize = control_shell.ControlSize;

// Primitives.
pub const button = @import("button/mod.zig");
pub const Button = button.Button;
pub const ButtonVariant = ControlVariant;
pub const ButtonSize = ControlSize;

pub const number_stepper = @import("number_stepper/mod.zig");
pub const NumberStepper = number_stepper.NumberStepper;
pub const tags_input = @import("tags_input/mod.zig");
pub const TagsInput = tags_input.TagsInput;
pub const TagsInputResult = tags_input.TagsInputResult;
pub const file_upload = @import("file_upload/mod.zig");
pub const FileUpload = file_upload.FileUpload;
pub const FileUploadResult = file_upload.FileUploadResult;
pub const data_table = @import("data_table/mod.zig");
/// Shared selection model (list/tree single + multi-select).
pub const selection = @import("selection.zig");
pub const SelectionMode = selection.SelectionMode;
pub const SelectionModel = selection.SelectionModel;
pub const ClickIntent = selection.ClickIntent;
pub const DataTable = data_table.DataTable;
pub const DataTableResult = data_table.DataTableResult;
pub const DataTableProps = data_table.DataTableProps;
pub const combo_box = @import("combo_box/mod.zig");
pub const ComboBox = combo_box.ComboBox;
pub const ComboBoxResult = combo_box.ComboBoxResult;
pub const ComboOption = combo_box.ComboOption;
pub const ComboBoxProps = combo_box.ComboBoxProps;
pub const select = @import("select/mod.zig");
pub const Select = select.Select;
pub const SelectResult = select.SelectResult;
pub const SelectProps = select.SelectProps;
pub const SelectOption = select.SelectOption;
pub const SelectState = select.SelectState;
pub const SelectSize = select.SelectSize;
pub const SelectMode = select.SelectMode;
pub const input = @import("input/mod.zig");
pub const Input = input.Input;
pub const Textarea = input.Textarea;
pub const EditableText = input.EditableText;
pub const EditableTextResult = input.EditableTextResult;
pub const EditableTextProps = input.EditableTextProps;
pub const InputType = input.InputType;
pub const InputSize = input.InputSize;
pub const editable_block = @import("editable_block/mod.zig");

pub const checkbox = @import("checkbox/mod.zig");
pub const Checkbox = checkbox.Checkbox;
pub const Radio = checkbox.Radio;
pub const RadioGroup = checkbox.RadioGroup;
pub const Switch = checkbox.Switch;

pub const badge = @import("badge/mod.zig");
pub const Badge = badge.Badge;
pub const StatusBadge = badge.StatusBadge;

// Layout.
pub const stack = @import("stack/mod.zig");
pub const VStack = stack.VStack;
pub const HStack = stack.HStack;

pub const card = @import("card/mod.zig");
pub const Card = card.Card;
pub const glass_box = @import("glass_box/mod.zig");
pub const GlassBox = glass_box.GlassBox;
pub const GlassBoxReadability = glass_box.GlassBoxReadability;
pub const GlassBoxEmphasis = glass_box.GlassBoxEmphasis;
pub const glass_group = @import("glass_group/mod.zig");
pub const GlassGroup = glass_group.GlassGroup;
pub const GlassShape = glass_group.GlassShape;
pub const glass_controls = @import("glass_controls/mod.zig");
/// ConcentricRectangle / containerShape (concentric corners, SwiftUI macOS 26).
pub const concentric = @import("../concentric.zig");
pub const ConcentricRectangle = concentric.ConcentricRectangle;
pub const background_extension = @import("background_extension/mod.zig");
pub const BackgroundExtension = background_extension.BackgroundExtension;
pub const GlassSlider = glass_controls.GlassSlider;
pub const GlassToggle = glass_controls.GlassToggle;
pub const glass_toolbar = @import("glass_toolbar/mod.zig");
pub const GlassToolbar = glass_toolbar.GlassToolbar;
pub const glass_bars = @import("glass_bars/mod.zig");
pub const GlassNavigationBar = glass_bars.GlassNavigationBar;
pub const GlassTabBar = glass_bars.GlassTabBar;
pub const GlassBottomToolbar = glass_bars.GlassBottomToolbar;
pub const GlassButton = glass_bars.GlassButton;

pub const group = @import("group/mod.zig");
pub const Group = group.Group;
pub const addGroupItem = group.addGroupItem;

pub const divider = @import("divider/mod.zig");
pub const Divider = divider.Divider;

// Interactive.
pub const tabs = @import("tabs/mod.zig");
pub const Tabs = tabs.Tabs;
pub const TabPanel = tabs.TabPanel;

pub const scroll_area = @import("scroll_area/mod.zig");
pub const ScrollArea = scroll_area.ScrollArea;
pub const ScrollAreaResult = scroll_area.ScrollAreaResult;
/// Programmatic scroll entry point (don't write state.scroll_y directly; skips
/// clamp/momentum reset/pixel align).
pub const ScrollAlign = scroll_area.ScrollAlign;
pub const setScrollY = scroll_area.setScrollY;
pub const scrollIntoView = scroll_area.scrollIntoView;
pub const scrollRectIntoView = scroll_area.scrollRectIntoView;

pub const virtual_list = @import("virtual_list/mod.zig");
pub const VirtualList = virtual_list.VirtualList;
pub const VirtualListState = virtual_list.VirtualListState;

pub const grid = @import("grid/mod.zig");
pub const Grid = grid.Grid;
pub const GridState = grid.GridState;
pub const GridProps = grid.GridProps;

pub const tooltip = @import("tooltip/mod.zig");
pub const Tooltip = tooltip.Tooltip;
pub const TooltipResult = tooltip.TooltipResult;

pub const modal = @import("modal/mod.zig");
pub const Modal = modal.Modal;
pub const ModalResult = modal.ModalResult;

pub const sheet = @import("sheet/mod.zig");
pub const Sheet = sheet.Sheet;
pub const SheetSide = sheet.SheetSide;

pub const popover = @import("popover/mod.zig");
pub const Popover = popover.Popover;
pub const PopoverPosition = popover.PopoverPosition;
pub const PopoverTrigger = popover.PopoverTrigger;

pub const markdown = @import("markdown/mod.zig");
pub const Markdown = markdown.Markdown;
pub const MarkdownOptions = markdown.MarkdownOptions;
pub const renderMarkdownInto = markdown.renderInto;

pub const tag = @import("tag/mod.zig");
pub const Tag = tag.Tag;
pub const TagColor = tag.TagColor;
pub const TagVariant = tag.TagVariant;
pub const TagSize = tag.TagSize;

pub const chip = @import("chip/mod.zig");
pub const Chip = chip.Chip;
pub const ChipSize = chip.ChipSize;
pub const ChipVariant = chip.ChipVariant;

pub const progress = @import("progress/mod.zig");
pub const Progress = progress.Progress;
pub const ProgressStatus = progress.ProgressStatus;

pub const snapshot_layer = @import("snapshot_layer.zig");
pub const SnapshotLayer = snapshot_layer.SnapshotLayer;
pub const SnapshotLayerProps = snapshot_layer.SnapshotLayerProps;
pub const SnapshotLayerResult = snapshot_layer.SnapshotLayerResult;
pub const BackdropConfig = snapshot_layer.BackdropConfig;

// legacy select.zig removed (2026-04-30). Use select_headless instead.
// select_headless exposed via ui.select_headless (src/ui/ui.zig:155);
// SelectOption(ValueT) exposed as select_headless.Option(ValueT).

pub const menu = @import("menu/mod.zig");
pub const Menu = menu.Menu;
pub const MenuItem = menu.MenuItem;
pub const MenuItemKind = menu.MenuItemKind;
pub const MenuState = menu.MenuState;

pub const slider = @import("slider/mod.zig");
pub const Slider = slider.Slider;
pub const SliderResult = slider.SliderResult;

pub const alert = @import("alert/mod.zig");
pub const Alert = alert.Alert;
pub const AlertVariant = alert.AlertVariant;

pub const notification = @import("notification/mod.zig");
pub const Notifier = notification.Notifier;
pub const NotifierOptions = notification.Options;
pub const Notification = notification.Notification;
pub const NotificationId = notification.Id;
pub const NotificationKind = notification.Kind;
pub const NotificationTone = notification.Tone;
pub const NotificationPosition = notification.Position;
pub const NotificationLead = notification.Lead;
pub const NotificationAction = notification.Action;
pub const NotificationProgress = notification.Progress;
pub const NotificationEvent = notification.Event;
pub const NotificationEventKind = notification.EventKind;
pub const NotificationListener = notification.Listener;
pub const NotificationStrings = notification.Strings;
pub const NotificationHint = notification.Hint;
pub const NotificationHintMark = notification.HintMark;
pub const NotificationHintKeycap = notification.HintKeycap;

pub const breadcrumb = @import("breadcrumb/mod.zig");
pub const Breadcrumb = breadcrumb.Breadcrumb;
pub const BreadcrumbItem = breadcrumb.BreadcrumbItem;

pub const tree = @import("tree/mod.zig");
pub const Tree = tree.Tree;
pub const TreeNodeData = tree.TreeNodeData;
pub const TreeResult = tree.TreeResult;

pub const table = @import("table/mod.zig");
pub const Table = table.Table;
pub const ColumnDef = table.ColumnDef;
pub const SortDirection = table.SortDirection;

pub const timeline = @import("timeline/mod.zig");
pub const Timeline = timeline.Timeline;
pub const TimelineItem = timeline.TimelineItem;
pub const TimelineStatus = timeline.TimelineStatus;

pub const calendar = @import("calendar/mod.zig");
pub const Calendar = calendar.Calendar;
pub const SimpleDate = calendar.SimpleDate;

pub const date_picker = @import("date_picker/mod.zig");
pub const DatePicker = date_picker.DatePicker;

pub const date_range_picker = @import("date_range_picker/mod.zig");
pub const DateRangePicker = date_range_picker.DateRangePicker;

pub const steps = @import("steps/mod.zig");
pub const Steps = steps.Steps;
pub const StepItem = steps.StepItem;

pub const rate = @import("rate/mod.zig");
pub const Rate = rate.Rate;

pub const skeleton = @import("skeleton/mod.zig");
pub const Skeleton = skeleton.Skeleton;
pub const SkeletonVariant = skeleton.SkeletonVariant;

pub const spinner = @import("spinner/mod.zig");
pub const Spinner = spinner.Spinner;
pub const SpinnerProps = spinner.SpinnerProps;

pub const accordion = @import("accordion/mod.zig");
pub const Accordion = accordion.Accordion;
pub const AccordionItem = accordion.AccordionItem;
pub const accordionItemOpen = accordion.accordionItemOpen;
pub const AccordionResult = accordion.AccordionResult;
pub const AccordionItemResult = accordion.AccordionItemResult;

// Form component
pub const form = @import("form/mod.zig");
pub const FormOf = form.FormOf;
pub const ValidationResult = form.ValidationResult;
pub const ValidateTrigger = form.ValidateTrigger;
pub const FieldMeta = form.FieldMeta;
pub const FormFieldOf = form.FormFieldOf;
pub const FormFieldResult = form.FormFieldResult;
pub const FormFieldConfig = form.FormFieldConfig;

// Exported types.
pub const Size = core.Size;
pub const Padding = core.Padding;
pub const Color = core.Color;
pub const ThemeTokens = core.ThemeTokens;

// popover's extracted unit tests (popover/tests.zig) must be explicitly imported by
// popover/mod.zig's test block. refAllDecls only recurses modules referenced in this file;
// extracted test file without explicit import is silently lost.
test {
    std.testing.refAllDecls(@This());
    // Cross-component control height contract tests (extracted file must be explicitly imported;
    // else silently lost).
    _ = @import("control_height_tests.zig");
    _ = @import("theme_switch_tests.zig");
}

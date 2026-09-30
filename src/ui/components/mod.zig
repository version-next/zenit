/// UI Components Module
///
/// Phase 3.2-3.4: VSCode 风格组件库
/// 参考 vscode-ui-lib SolidJS 实现
///
/// 组件分类:
/// - 基础组件: Button, Input, Checkbox, Switch, Badge
/// - 布局组件: Stack, Card, Divider, ScrollArea
/// - 交互组件: Tabs, Tooltip, Modal
///
/// 设计原则:
/// 1. SolidJS 风格：组件函数执行一次，通过 Signal 更新
/// 2. 无障碍性：ARIA 属性、键盘导航
/// 3. 主题支持：VSCode 暗色主题
/// 4. 动画支持：过渡、缓动
const std = @import("std");
const core = @import("../core.zig");

// 统一基底
pub const control_shell = @import("control_shell/mod.zig");
/// 测试支撑：组件 mount 的逐分配点 OOM sweep。导出给消费方复用同一套判定口径。
pub const oom_sweep = @import("oom_sweep.zig");
pub const controlShell = control_shell.controlShell;
pub const ControlShellConfig = control_shell.ControlShellConfig;
pub const ControlShellResult = control_shell.ControlShellResult;
pub const ControlVariant = control_shell.ControlVariant;
pub const ControlSize = control_shell.ControlSize;

// 基础组件
pub const button = @import("button/mod.zig");
pub const Button = button.Button;
pub const setButtonBackgroundOverride = button.setBackgroundOverride;
pub const setButtonInteractionOverride = button.setInteractionOverride;
pub const ButtonVariant = ControlVariant;
pub const ButtonSize = ControlSize;

pub const number_stepper = @import("number_stepper/mod.zig");
pub const NumberStepper = number_stepper.mountNumberStepper;
pub const tags_input = @import("tags_input/mod.zig");
pub const TagsInput = tags_input.mountTagsInput;
pub const file_upload = @import("file_upload/mod.zig");
pub const FileUpload = file_upload.mountFileUpload;
pub const data_table = @import("data_table/mod.zig");
/// 菜单键盘导航共享逻辑（Menu / DropdownMenu 复用同一份 nextEnabledIndex）
pub const menu_navigation = @import("menu_navigation.zig");
/// 共享选择模型（列表/树类组件的单选+多选）
pub const selection = @import("selection.zig");
pub const SelectionMode = selection.SelectionMode;
pub const SelectionModel = selection.SelectionModel;
pub const ClickIntent = selection.ClickIntent;
pub const DataTable = data_table.mountDataTable;
pub const DataTableProps = data_table.DataTableProps;
pub const combo_box = @import("combo_box/mod.zig");
pub const ComboBox = combo_box.mountComboBox;
pub const ComboOption = combo_box.ComboOption;
pub const ComboBoxProps = combo_box.ComboBoxProps;
pub const select = @import("select/mod.zig");
pub const Select = select.mountSelect;
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

// 布局组件
pub const stack = @import("stack/mod.zig");
pub const VStack = stack.VStack;
pub const HStack = stack.HStack;

pub const card = @import("card/mod.zig");
pub const Card = card.Card;
pub const glass_box = @import("glass_box/mod.zig");
pub const GlassBox = glass_box.GlassBox;
pub const GlassBoxReadability = glass_box.GlassBoxReadability;
pub const GlassBoxEmphasis = glass_box.GlassBoxEmphasis;

pub const group = @import("group/mod.zig");
pub const Group = group.Group;
pub const addGroupItem = group.addGroupItem;

pub const divider = @import("divider/mod.zig");
pub const Divider = divider.Divider;

// 交互组件
pub const tabs = @import("tabs/mod.zig");
pub const Tabs = tabs.Tabs;
pub const TabPanel = tabs.TabPanel;

pub const scroll_area = @import("scroll_area/mod.zig");
pub const mountScrollArea = scroll_area.mountScrollArea;
pub const ScrollAreaResult = scroll_area.ScrollAreaResult;
/// 程序化滚动公共入口（别直接写 state.scroll_y —— 会跳过 clamp/动量复位/像素对齐）
pub const ScrollAlign = scroll_area.ScrollAlign;
pub const setScrollY = scroll_area.setScrollY;
pub const scrollIntoView = scroll_area.scrollIntoView;
pub const scrollRectIntoView = scroll_area.scrollRectIntoView;

pub const virtual_list = @import("virtual_list/mod.zig");
pub const VirtualList = virtual_list.VirtualList;
pub const VirtualListState = virtual_list.VirtualListState;

pub const grid = @import("grid/mod.zig");
pub const mountGrid = grid.mountGrid;
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

// legacy select.zig 删除（2026-04-30）。用 select_headless 替代。
// select_headless 通过 ui.select_headless 直接公开（src/ui/ui.zig:155）；
// SelectOption(ValueT) 通过 select_headless.Option(ValueT) 暴露。

pub const menu = @import("menu/mod.zig");
pub const Menu = menu.Menu;
pub const MenuItem = menu.MenuItem;
pub const MenuItemKind = menu.MenuItemKind;

pub const dropdown_menu = @import("dropdown_menu/mod.zig");
pub const DropdownMenu = dropdown_menu.DropdownMenu;
pub const DropdownItem = dropdown_menu.DropdownItem;
pub const DropdownItemKind = dropdown_menu.DropdownItemKind;
pub const DropdownMenuState = dropdown_menu.DropdownMenuState;

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
pub const AccordionState = accordion.AccordionState;
pub const AccordionResult = accordion.AccordionResult;
pub const AccordionItemResult = accordion.AccordionItemResult;

// Form 组件
pub const form = @import("form/mod.zig");
pub const FormOf = form.FormOf;
pub const ValidationResult = form.ValidationResult;
pub const ValidateTrigger = form.ValidateTrigger;
pub const FieldMeta = form.FieldMeta;
pub const FormFieldOf = form.FormFieldOf;
pub const FormFieldResult = form.FormFieldResult;
pub const FormFieldConfig = form.FormFieldConfig;

// 导出类型
pub const Size = core.Size;
pub const Padding = core.Padding;
pub const Color = core.Color;
pub const ThemeTokens = core.ThemeTokens;

// popover 的析出单测（popover/tests.zig）由 popover/mod.zig 自己的 test 块
// 显式 import——refAllDecls 只递归本文件引用过的模块，析出的测试文件若无人
// 显式 import 等于静默丢失。
test {
    std.testing.refAllDecls(@This());
    // 跨组件控件高度合同测试（析出文件必须显式 import，否则静默丢失）
    _ = @import("control_height_tests.zig");
}

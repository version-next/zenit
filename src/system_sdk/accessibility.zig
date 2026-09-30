const std = @import("std");

pub const Role = enum(u8) {
    none,
    button,
    checkbox,
    radio,
    textbox,
    switch_role,
    tab,
    tablist,
    dialog,
    alert,
    menu,
    menuitem,
    listbox,
    option,
    progressbar,
    slider,
    heading,
    link,
    img,
    list,
    listitem,
    table,
    tooltip,
    // v0.7 §2.5
    combobox,
    grid,
    gridcell,
    // 2026-07-31：补组件 a11y 声明时新增。若不在这里同步扩，Tree/DataTable/
    // Steps 等的新角色只会到达 a11y tree，走 focus.zig 那条 snapshot 路径时
    // 会被迫降级成别的角色 —— 平台 AT 拿到的仍是错的。
    tree,
    treeitem,
    row,
    columnheader,
    rowheader,
    menubar,
    menuitemcheckbox,
    menuitemradio,
    spinbutton,
    status,
    group,
    navigation,
    separator,
    region,
    article,
    application,
    radiogroup,
    textarea,
    searchbox,
    tabpanel,
    alertdialog,
    log,
    paragraph,
    section,
    form,
    main,
    banner,
    contentinfo,
    generic,
};

pub const NodeSnapshot = struct {
    role: Role = .none,
    label: []const u8 = "",
    description: []const u8 = "",
    value_text: []const u8 = "",
    live: []const u8 = "",
    checked: ?bool = null,
    disabled: bool = false,
    expanded: ?bool = null,
    selected: bool = false,
    required: bool = false,
    invalid: bool = false,
    readonly: bool = false,
    busy: bool = false,
    modal: bool = false,

    pub fn hasSemanticContent(self: NodeSnapshot) bool {
        return self.role != .none or
            self.label.len > 0 or
            self.description.len > 0 or
            self.value_text.len > 0 or
            self.live.len > 0 or
            self.checked != null or
            self.expanded != null or
            self.disabled or self.selected or self.required or self.invalid or
            self.readonly or self.busy or self.modal;
    }
};

test "NodeSnapshot: semantic content detection" {
    try std.testing.expect(!(NodeSnapshot{}).hasSemanticContent());
    try std.testing.expect((NodeSnapshot{ .label = "Save" }).hasSemanticContent());
    try std.testing.expect((NodeSnapshot{ .checked = true }).hasSemanticContent());
}

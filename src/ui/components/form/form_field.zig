/// FormFieldOf(T): comptime generic field container component
///
/// Standalone reusable FormField wrapper for the label + error/helper layout pattern.
///
/// Usage:
/// ```zig
/// const FF = FormFieldOf(LoginForm);
///
/// // Method 1: manual control fill
/// const result = try FF.field(.email, .{ .label_text = "Email" }, form, scope, cx);
/// const input = try Input(.{ .placeholder = "name@example.com" }).mount(scope, cx);
/// try result.control_slot.appendChild(cx.allocator, input);
///
/// // Method 2: convenience method (Input auto-bound to field, on_change wired)
/// const node = try FF.inputField(.email, .{ .label_text = "Email" },
///     .{ .placeholder = "name@example.com" }, form, scope, cx);
/// ```
const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../../core.zig");
const view = @import("../../view.zig");
const Cx = core.Cx;
const Node = core.Node;
const box = core.box;
const Scope = core.Scope;
const form_data = @import("form_data.zig");
const FormOf = form_data.FormOf;
const input_mod = @import("../input/mod.zig");
const reactive = @import("../../reactive.zig");
const bind_mod = @import("../../bind.zig");

/// FormField mount result.
pub const FormFieldResult = struct {
    /// wrapper root node (contains label + control_slot + helper).
    wrapper: *Node,
    /// Control mount point, caller mounts control into this node.
    control_slot: *Node,
    /// Helper/error text node.
    helper_node: *Node,
    /// FormField's scope.
    scope: *Scope,
};

/// FormField configuration.
pub const FormFieldConfig = struct {
    /// External label for form field. By convention: component's own content uses `label`
    /// (Button/Chip); form field's external label uses `label_text` (Input/Switch/ComboBox).
    label_text: reactive.Source([]const u8) = .{ .value = "" },
    /// Helper text (shown when no error; empty string = none; can pass signal)
    helper: reactive.Source([]const u8) = .{ .value = "" },
    /// Whether required (displays red asterisk)
    required: bool = false,
    /// Width
    width: ?f32 = null,
};

/// Comptime generic FormField
pub fn FormFieldOf(comptime T: type) type {
    const FormType = FormOf(T);

    return struct {
        const Self = @This();
        pub const FieldEnum = std.meta.FieldEnum(T);

        /// Create field container, return control mount point
        pub fn field(
            comptime field_enum: FieldEnum,
            /// Field config literal (`.{ .label_text = "Email", .required = true }`)
            config_in: anytype,
            form: *FormType,
            scope: *Scope,
            cx: *Cx,
        ) !FormFieldResult {
            const config = reactive.props.coerce(FormFieldConfig, config_in);
            const my_scope = try scope.childScope();
            var scope_bound = false;
            errdefer if (!scope_bound) my_scope.dispose();
            const allocator = cx.allocator;
            const t = cx.tokens;
            const m = form.meta(field_enum);

            // label_row (dynamic label always created, hides label text when empty)
            const has_label = !config.label_text.isStatic() or config.label_text.peek().len > 0;
            const label_style: core.TextStyle = @import("../input/styles.zig").labelTextStyle(t);
            const Parts = struct { label: ?*Node = null, control_slot: *Node = undefined, helper: *Node = undefined };
            var parts: Parts = .{};
            // wrapper (column, gap=4), structure consistent with Input
            const wrapper = try view.render(my_scope, cx, view.col(.{
                .style = .{
                    .width = if (config.width) |w| core.Sizing{ .px = w } else core.Sizing{ .grow = .{} },
                    .height = .{ .fit = .{} },
                    .gap = t.tokens.space.space150,
                },
                // Visually required is just red * after label; validation failure turns helper red.
                // AT users can't perceive either. required/invalid are ARIA attributes; screen
                // readers
                // announce them with the field name.
                .a11y = core.A11yProps{
                    .role = .group,
                    .label = null, // Label row binding points to text copy of label node
                    .required = config.required,
                    .invalid = m.error_sig.get() != null,
                },
            }, .{
                if (has_label) view.row(.{ .style = .{
                    .width = .{ .grow = .{} },
                    .height = .{ .fit = .{} },
                    .align_items = .center,
                    .gap = 4,
                } }, .{
                    view.capture(&parts.label, view.text(.{ .style = label_style }, "")),
                    if (config.required) view.text(.{ .style = @import("../input/styles.zig").requiredMarkStyle(t) }, "*") else null,
                }) else null,
                // control_slot, control mount point
                view.capture(&parts.control_slot, view.box(.{ .style = .{ .width = .{ .grow = .{} }, .height = .{ .fit = .{} } } }, {})),
                // helper_node, dynamically displays error or helper; initial value written
                // synchronously, then followed by effect tracking error/helper
                view.capture(&parts.helper, view.text(.{ .style = @import("../input/styles.zig").helperTextStyle(t, false) }, config.helper.peek())),
            }));
            wrapper.meta.ownership.meta.component_name = "FormField";
            // sweep: wrapper lifetime until return (also disposes attached my_scope)
            errdefer cx.freeNode(wrapper);
            try core.bindScopeToNode(my_scope, wrapper);
            scope_bound = true;

            if (parts.label) |label_node| {
                try bind_mod.bindOptionalTextRow(cx, my_scope, config.label_text, label_node, null, wrapper);
            }
            const control_slot = parts.control_slot;
            const helper_node = parts.helper;
            helper_node.setDisplay(if (config.helper.peek().len > 0) .flex else .none);

            // Effect: subscribe to error_sig and helper -> update helper_node (node holds text
            // copy)
            try my_scope.createEffect(.{
                .error_sig = m.error_sig,
                .helper = config.helper,
                .helper_node = helper_node,
                .wrapper = wrapper,
                .allocator = allocator,
                .danger_color = t.tokens.color.danger,
                .secondary_color = @import("../input/styles.zig").helperTextStyle(t, false).color,
            }, struct {
                fn update(c: anytype) void {
                    const err = c.error_sig.get();
                    const help = c.helper.read(true);
                    // aria-invalid must track validation result; otherwise AT still reports invalid
                    // after
                    // user fixes input, or vice versa.
                    if (c.wrapper.behavior.interaction.a11y) |*a| {
                        a.invalid = err != null;
                    }
                    const content = err orelse help;
                    c.helper_node.setDisplay(if (content.len > 0) .flex else .none);
                    if (!std.mem.eql(u8, c.helper_node.getText().?.content, content)) {
                        c.helper_node.setTextContent(c.allocator, content) catch |e| {
                            std.log.err("[FormField] helper update failed: {}", .{e});
                            return;
                        };
                    }
                    var txt = c.helper_node.getText().?;
                    txt.color = if (err != null) c.danger_color else c.secondary_color;
                    c.helper_node.setText(txt);
                    c.helper_node.markRenderDirty();
                }
            }.update);

            return .{
                .wrapper = wrapper,
                .control_slot = control_slot,
                .helper_node = helper_node,
                .scope = my_scope,
            };
        }

        /// Convenience method: create Input + auto-bind to form field
        pub fn inputField(
            comptime field_enum: FieldEnum,
            /// Field config literal (same as `field`)
            config: anytype,
            /// Input property literal (same as `W.Input(.{})`; value/label/helper/error
            /// managed by field)
            input_props: anytype,
            form: *FormType,
            scope: *Scope,
            cx: *Cx,
        ) !*Node {
            var result = try field(field_enum, config, form, scope, cx);
            // sweep: field succeeded; if adapter/Input fail later, wrapper must still be disposed
            errdefer cx.freeNode(result.wrapper);

            // Input value uses form field as data source (ui.split): read = field (initial,
            // reset, external writes go to Input), propose = form.setValue (preserves dirty flag
            // and on_change timing)
            const Adapter = struct {
                form: *FormType,

                fn write(self: *@This(), value: []const u8) void {
                    // value borrowed from Input buffer; text field is owned signal, copies on write
                    self.form.setValue(field_enum, value);
                }
            };
            const adapter = try result.scope.allocator.create(Adapter);
            adapter.* = .{ .form = form };
            try result.scope.adoptResource(@ptrCast(adapter), struct {
                fn destroy(ptr: *anyopaque, alloc: Allocator) void {
                    const a: *Adapter = @ptrCast(@alignCast(ptr));
                    alloc.destroy(a);
                }
            }.destroy);

            var props = reactive.props.coerce(input_mod.InputProps, input_props);
            props.value = .{ .split = reactive.split(form.field(field_enum), reactive.Callback([]const u8).from(Adapter, adapter, Adapter.write)) };
            // Don't set label/helper/error; FormField manages them
            props.label_text = .{ .value = "" };
            props.helper = .{ .value = "" };
            props.error_msg = .{ .value = "" };
            props.invalid = reactive.toSource(reactive.map(form.meta(field_enum).error_sig, struct {
                fn invalid(message: ?[]const u8) bool {
                    return message != null;
                }
            }.invalid));

            try view.mount(result.scope, cx, result.control_slot, input_mod.Input(props));

            return result.wrapper;
        }
    };
}

// ========== Tests ==========

test "FormField: basic structure with label" {
    const TestForm = struct { name: []const u8 };

    const allocator = std.testing.allocator;
    var ctx = try Cx.init(allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(allocator, null, ctx.owner);
    defer scope.dispose();

    const form = try FormOf(TestForm).create(scope, .{ .name = "Alice" }, .{});

    const result = try FormFieldOf(TestForm).field(.name, .{
        .label_text = "Name",
        .helper = "Enter your name",
    }, form, scope, ctx);
    try root.appendChild(allocator, result.wrapper);

    // wrapper should have 3 children: label_row + control_slot + helper_node
    try std.testing.expectEqual(@as(usize, 3), result.wrapper.children.items.len);

    // First child is label_row
    const label_row = result.wrapper.children.items[0];
    try std.testing.expect(label_row.children.items.len >= 1);
    // label text
    const label_node = label_row.children.items[0];
    try std.testing.expectEqualStrings("Name", label_node.getText().?.content);

    // Second child is control_slot (empty)
    try std.testing.expectEqual(@as(usize, 0), result.control_slot.children.items.len);

    // Third child is helper_node
    try std.testing.expectEqualStrings("Enter your name", result.helper_node.getText().?.content);
}

test "FormField: required shows asterisk" {
    const TestForm = struct { email: []const u8 };

    const allocator = std.testing.allocator;
    var ctx = try Cx.init(allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(allocator, null, ctx.owner);
    defer scope.dispose();

    const form = try FormOf(TestForm).create(scope, .{ .email = "" }, .{});

    const result = try FormFieldOf(TestForm).field(.email, .{
        .label_text = "Email",
        .required = true,
    }, form, scope, ctx);
    try root.appendChild(allocator, result.wrapper);

    // label_row should have 2 children: label + asterisk
    const label_row = result.wrapper.children.items[0];
    try std.testing.expectEqual(@as(usize, 2), label_row.children.items.len);
    // Second is red asterisk
    const asterisk = label_row.children.items[1];
    try std.testing.expectEqualStrings("*", asterisk.getText().?.content);
}

test "FormField: no label creates 2 children" {
    const TestForm = struct { value: i32 };

    const allocator = std.testing.allocator;
    var ctx = try Cx.init(allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(allocator, null, ctx.owner);
    defer scope.dispose();

    const form = try FormOf(TestForm).create(scope, .{ .value = 0 }, .{});

    const result = try FormFieldOf(TestForm).field(.value, .{}, form, scope, ctx);
    try root.appendChild(allocator, result.wrapper);

    // No label -> only control_slot + helper_node
    try std.testing.expectEqual(@as(usize, 2), result.wrapper.children.items.len);
}

test "FormField: error signal updates helper" {
    const TestForm = struct { name: []const u8 };

    const allocator = std.testing.allocator;
    var ctx = try Cx.init(allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(allocator, null, ctx.owner);
    defer scope.dispose();

    const form = try FormOf(TestForm).create(scope, .{ .name = "" }, .{});

    const result = try FormFieldOf(TestForm).field(.name, .{
        .label_text = "Name",
        .helper = "Enter your name",
    }, form, scope, ctx);
    try root.appendChild(allocator, result.wrapper);

    // Initial state should display helper text
    try std.testing.expectEqualStrings("Enter your name", result.helper_node.getText().?.content);

    // Set error -> Effect should auto-update helper_node
    form.meta(.name).error_sig.set("Name is required");
    try std.testing.expectEqualStrings("Name is required", result.helper_node.getText().?.content);

    // Clear error -> restore helper
    form.meta(.name).error_sig.set(null);
    try std.testing.expectEqualStrings("Enter your name", result.helper_node.getText().?.content);
}

test "a11y: FormField 的 required/invalid 到达 a11y 树且跟随校验结果" {
    const a11y_tree_mod = @import("../../a11y/tree.zig");
    const TestForm = struct { name: []const u8 };

    const allocator = std.testing.allocator;
    var ctx = try Cx.init(allocator, std.testing.io);
    defer ctx.deinit();
    ctx.setViewport(400, 300);

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(allocator, null, ctx.owner);
    defer scope.dispose();

    const form = try FormOf(TestForm).create(scope, .{ .name = "" }, .{});
    const result = try FormFieldOf(TestForm).field(.name, .{
        .label_text = "Name",
        .required = true,
    }, form, scope, ctx);
    try root.appendChild(allocator, result.wrapper);
    ctx.layout();
    _ = ctx.render();

    // Assert a11y tree (what AT actually sees), not props struct.
    const eid = core.ElementId.fromRaw(result.wrapper.element_id_raw);
    const n0 = ctx.accessibility_tree.getNode(eid).?;
    // Visually required is just red * after label; AT relies on required bit
    try std.testing.expect(n0.state.required);
    try std.testing.expect(!n0.state.invalid);

    // Validation fails -> invalid must follow (else AT only sees helper turn red,
    // doesn't read invalid)
    form.meta(.name).error_sig.set("Name is required");
    ctx.layout();
    _ = ctx.render();
    try std.testing.expect(ctx.accessibility_tree.getNode(eid).?.state.invalid);
    try std.testing.expectEqual(a11y_tree_mod.Role.group, ctx.accessibility_tree.getNode(eid).?.role);

    // User fixes it -> invalid must clear, can't keep reporting error
    form.meta(.name).error_sig.set(null);
    ctx.layout();
    _ = ctx.render();
    try std.testing.expect(!ctx.accessibility_tree.getNode(eid).?.state.invalid);
}

test "FormField: inputField 可编译并绑定回值（守零调用者失效）" {
    // This test's only purpose is making inputField analyzed. Function previously set
    // props.context which InputProps never had (on_change now carries context via
    // HandlerRef). Zero callers + comptime context = never analyzed, so the
    // non-compiling public function exposed broken docs.
    const TestForm = struct { email: []const u8 };

    const allocator = std.testing.allocator;
    var ctx = try Cx.init(allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(allocator, null, ctx.owner);
    defer scope.dispose();

    const form = try FormOf(TestForm).create(scope, .{ .email = "" }, .{});

    const wrapper = try FormFieldOf(TestForm).inputField(
        .email,
        .{ .label_text = "邮箱" },
        .{ .placeholder = "name@example.com" },
        form,
        scope,
        ctx,
    );
    try root.appendChild(allocator, wrapper);

    // label + control_slot structure holds
    try std.testing.expect(wrapper.children.items.len >= 2);

    // Callback properly connected to form (HandlerRef carries context, no bare context field)
    const control_slot = wrapper.children.items[1];
    try std.testing.expect(control_slot.children.items.len >= 1);
    const Finder = struct {
        fn find(node: *Node) ?*Node {
            if (node.tag == .input) return node;
            for (node.children.items) |child| if (find(child)) |found| return found;
            return null;
        }
    };
    const input = Finder.find(control_slot).?;
    form.meta(.email).error_sig.set("Required");
    try std.testing.expect(input.behavior.interaction.a11y.?.invalid);
    form.meta(.email).error_sig.set(null);
    try std.testing.expect(!input.behavior.interaction.a11y.?.invalid);
}

test "FormField: inputField 回写的值不别名 Input 内部缓冲（字段卸载后不悬垂）" {
    const TestForm = struct { email: []const u8 };
    const allocator = std.testing.allocator;
    var ctx = try Cx.init(allocator, std.testing.io);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(allocator, null, ctx.owner);
    defer scope.dispose();

    const form = try FormOf(TestForm).create(scope, .{ .email = "" }, .{});
    const field_scope = try scope.childScope();
    const wrapper = try FormFieldOf(TestForm).inputField(.email, .{}, .{}, form, field_scope, ctx);
    try root.appendChild(allocator, wrapper);

    const TIS = @import("../input/state.zig").TextInputState;
    const Finder = struct {
        fn find(n: *Node) ?*Node {
            if (n.tag == .input) return n;
            for (n.children.items) |c| if (find(c)) |r| return r;
            return null;
        }
    };
    const input_node = Finder.find(wrapper).?;
    const state: *TIS = @ptrCast(@alignCast(input_node.behavior.events.event_context.?));

    _ = state.setText("abcd");
    state.on_change.?.invokeWithStr(state.getText());
    try std.testing.expectEqualStrings("abcd", form.get(.email));
    // In-place in-length rewrite of Input buffer without triggering on_change: form value
    // shouldn't change (proves not alias)
    _ = state.setText("wxyz");
    try std.testing.expectEqualStrings("abcd", form.get(.email));
    state.on_change.?.invokeWithStr(state.getText());
    try std.testing.expectEqualStrings("wxyz", form.get(.email));
    try std.testing.expect(form.metas[0].dirty_sig.peek());

    // Unmount field: form value still valid
    root.removeChild(wrapper);
    ctx.freeNode(wrapper);
    field_scope.dispose();
    try std.testing.expectEqualStrings("wxyz", form.get(.email));
}

// Remaining components not adopted by sweep (markdown render / form_field /
// select_headless).
const SweepForm = struct { name: []const u8 };
test "form_field(label+required+helper): mount 在任意分配点失败时不泄漏（sweep）" {
    const sw = @import("../oom_sweep.zig");
    try sw.sweepMount("form_field(label+required+helper)", struct {
        fn m(scope: *sw.Scope, cx: *sw.Cx) anyerror!?*sw.Node {
            const form = try FormOf(SweepForm).create(scope, .{ .name = "Alice" }, .{});
            return (try FormFieldOf(SweepForm).field(.name, .{ .label_text = "Name", .required = true, .helper = "Enter your name" }, form, scope, cx)).wrapper;
        }
    }.m);
}

test "form_field(inputField): mount 在任意分配点失败时不泄漏（sweep）" {
    const sw = @import("../oom_sweep.zig");
    try sw.sweepMount("form_field(inputField)", struct {
        fn m(scope: *sw.Scope, cx: *sw.Cx) anyerror!?*sw.Node {
            const form = try FormOf(SweepForm).create(scope, .{ .name = "Alice" }, .{});
            return try FormFieldOf(SweepForm).inputField(.name, .{ .label_text = "Name" }, .{ .placeholder = "name" }, form, scope, cx);
        }
    }.m);
}

test "FormField: label / helper 来自 signal；错误优先于 helper，清除后回到当前 helper" {
    const TestForm = struct { email: []const u8 };
    const allocator = std.testing.allocator;
    var ctx = try Cx.init(allocator, std.testing.io);
    defer ctx.deinit();
    const scope = try Scope.init(allocator, null, ctx.owner);
    defer scope.dispose();
    const form = try FormOf(TestForm).create(scope, .{ .email = "" }, .{});
    const label = try scope.createText("Email", .{});
    const helper = try scope.createText("Work address", .{});
    const result = try FormFieldOf(TestForm).field(.email, .{ .label_text = label, .helper = helper }, form, scope, ctx);
    defer ctx.freeNode(result.wrapper);
    try std.testing.expectEqualStrings("Email", result.wrapper.behavior.interaction.a11y.?.label.?);
    try std.testing.expectEqualStrings("Work address", result.helper_node.getText().?.content);

    label.set("Work email");
    try std.testing.expectEqualStrings("Work email", result.wrapper.behavior.interaction.a11y.?.label.?);
    helper.set("We never share it");
    try std.testing.expectEqualStrings("We never share it", result.helper_node.getText().?.content);

    form.meta(.email).error_sig.set("Required");
    try std.testing.expectEqualStrings("Required", result.helper_node.getText().?.content);
    try std.testing.expect(result.wrapper.behavior.interaction.a11y.?.invalid);
    helper.set("Changed while invalid");
    try std.testing.expectEqualStrings("Required", result.helper_node.getText().?.content);
    form.meta(.email).error_sig.set(null);
    try std.testing.expectEqualStrings("Changed while invalid", result.helper_node.getText().?.content);
}

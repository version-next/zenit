/// FormFieldOf(T) — comptime 泛型字段容器组件
///
/// 提取 Input 组件中的 label + error/helper 布局模式，
/// 变成独立可复用的 FormField 包装。
///
/// 用法:
/// ```zig
/// const FF = FormFieldOf(LoginForm);
///
/// // 方式 1: 手动填充控件
/// const result = try FF.field(.email, .{ .label_text = "邮箱" }, form, scope, cx);
/// const input = try Input(.{ .placeholder = "name@example.com" }).mount(scope, cx);
/// try result.control_slot.appendChild(cx.allocator, input);
///
/// // 方式 2: 便利方法（Input 自动绑定到字段，on_change 已接好）
/// const node = try FF.inputField(.email, .{ .label_text = "邮箱" },
///     .{ .placeholder = "name@example.com" }, form, scope, cx);
/// ```
const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../../core.zig");
const Cx = core.Cx;
const Node = core.Node;
const box = core.box;
const Scope = core.Scope;
const form_data = @import("form_data.zig");
const FormOf = form_data.FormOf;
const input_mod = @import("../input/mod.zig");

/// FormField mount 结果
pub const FormFieldResult = struct {
    /// wrapper 根节点（含 label + control_slot + helper）
    wrapper: *Node,
    /// 控件挂载点 — 调用者将控件 mount 到此节点中
    control_slot: *Node,
    /// 辅助/错误文本节点
    helper_node: *Node,
    /// FormField 的 scope
    scope: *Scope,
};

/// FormField 配置
pub const FormFieldConfig = struct {
    /// 字段外挂标签文本。
    /// 命名遵循全局规范：组件**自身内容**用 `label`（Button/Chip），
    /// 表单字段的**外挂标签**用 `label_text`（Input/Switch/ComboBox）。
    /// 2026-07-31 更正：此处原为 `label`，与规范矛盾（同一概念两个名字）。
    label_text: ?[]const u8 = null,
    /// 辅助文本（无错误时显示）
    helper: ?[]const u8 = null,
    /// 是否必填（显示红色星号）
    required: bool = false,
    /// 宽度
    width: ?f32 = null,
};

/// comptime 泛型 FormField
pub fn FormFieldOf(comptime T: type) type {
    const FormType = FormOf(T);

    return struct {
        const Self = @This();
        pub const FieldEnum = std.meta.FieldEnum(T);

        /// 创建字段容器，返回控件挂载点
        pub fn field(
            comptime field_enum: FieldEnum,
            config: FormFieldConfig,
            form: *FormType,
            scope: *Scope,
            cx: *Cx,
        ) !FormFieldResult {
            const my_scope = try scope.childScope();
            const allocator = cx.allocator;
            const t = cx.tokens;
            const m = form.meta(field_enum);

            // wrapper (column, gap=4) — 和 Input 的结构一致
            const wrapper = try box(cx, .{
                .width = if (config.width) |w| .{ .px = w } else .{ .grow = .{} },
                .height = .{ .fit = .{} },
                .direction = .column,
                .gap = 4,
            }, .{});
            wrapper.meta.ownership.meta.component_name = "FormField";
            // sweep：wrapper 守到 return（连带 dispose 绑上的 my_scope）；子节点建好即 adopt
            errdefer cx.freeNode(wrapper);
            try core.bindScopeToNode(my_scope, wrapper);
            // 必填在视觉上只是 label 后面一个红 "*"，校验失败只是 helper 文字
            // 变红——两个信号 AT 用户都拿不到。required/invalid 是 ARIA 专门
            // 为此设的位：屏幕阅读器会在念字段名时直接带上"必填""无效"。
            wrapper.behavior.interaction.a11y = .{
                .role = .group,
                .label = config.label_text,
                .required = config.required,
                .invalid = m.error_sig.get() != null,
            };

            // label_row
            if (config.label_text) |lbl| {
                const label_row = try core.adoptChild(cx, allocator, wrapper, try box(cx, .{
                    .width = .{ .grow = .{} },
                    .height = .{ .fit = .{} },
                    .direction = .row,
                    .align_items = .center,
                    .gap = 4,
                }, .{}));

                const label_node = try core.adoptChild(cx, allocator, label_row, try box(cx, .{ .width = .{ .fit = .{} } }, .{}));
                label_node.setText(.{
                    .content = lbl,
                    .color = t.color.fg_primary,
                    .font_size = 14,
                    .font_weight = 500,
                });

                if (config.required) {
                    const required_node = try core.adoptChild(cx, allocator, label_row, try box(cx, .{ .width = .{ .fit = .{} } }, .{}));
                    required_node.setText(.{
                        .content = "*",
                        .color = t.color.danger,
                        .font_size = 14,
                        .font_weight = 500,
                    });
                }
            }

            // control_slot — 控件挂载点
            const control_slot = try core.adoptChild(cx, allocator, wrapper, try box(cx, .{
                .width = .{ .grow = .{} },
                .height = .{ .fit = .{} },
            }, .{}));

            // helper_node — 动态显示 error 或 helper
            const helper_node = try core.adoptChild(cx, allocator, wrapper, try box(cx, .{
                .height = .{ .fit = .{} },
            }, .{}));

            const initial_text = config.helper orelse "";
            helper_node.setText(.{
                .content = initial_text,
                .color = t.color.fg_secondary,
                .font_size = 12,
            });

            // Effect: 订阅 error_sig → 自动更新 helper_node
            try my_scope.createEffect(.{
                .error_sig = m.error_sig,
                .helper_node = helper_node,
                .wrapper = wrapper,
                .default_helper = config.helper,
                .danger_color = t.color.danger,
                .secondary_color = t.color.fg_secondary,
            }, struct {
                fn update(c: anytype) void {
                    const err = c.error_sig.get();
                    // aria-invalid 必须跟着校验结果走，否则用户改好了输入
                    // AT 仍然报"无效"，或者反过来。
                    if (c.wrapper.behavior.interaction.a11y) |*a| {
                        a.invalid = err != null;
                    }
                    if (err) |msg| {
                        c.helper_node.setText(.{
                            .content = msg,
                            .color = c.danger_color,
                            .font_size = 12,
                        });
                    } else {
                        c.helper_node.setText(.{
                            .content = c.default_helper orelse "",
                            .color = c.secondary_color,
                            .font_size = 12,
                        });
                    }
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

        /// 便利方法：创建 Input + 自动绑定到 form 字段
        pub fn inputField(
            comptime field_enum: FieldEnum,
            config: FormFieldConfig,
            input_props: input_mod.InputProps,
            form: *FormType,
            scope: *Scope,
            cx: *Cx,
        ) !*Node {
            var result = try field(field_enum, config, form, scope, cx);
            // sweep：field 已成功、后面 adapter / Input 失败时 wrapper 不能漏
            errdefer cx.freeNode(result.wrapper);

            // 创建回调适配器
            const Adapter = struct {
                form: *FormType,

                fn onChange(self: *@This(), value: []const u8) void {
                    // value 借自 Input 内部缓冲，只在回调期间有效；form 必须自持副本，
                    // 否则字段卸载后悬垂，且原地等长编辑会被 Signal 判为"未变"。
                    self.form.setValueCopy(field_enum, value) catch |err| {
                        std.log.warn("FormField: setValueCopy failed: {s}", .{@errorName(err)});
                    };
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

            // 创建 Input，注入回调。
            // on_change 是 ?core.HandlerRef（2026-07-31 并轨），fn+context 已
            // 合成一体 —— 此处曾写 props.context = ...，而 InputProps 从来没有
            // 这个字段；因零调用者又在 comptime return struct 内，从未被语义
            // 分析过，所以一直没暴露成编译错误。
            var props = input_props;
            props.on_change = Cx.strHandlerFrom(Adapter, adapter, Adapter.onChange);
            // 不设置 label/helper/error — FormField 已经管了
            props.label_text = null;
            props.helper = null;
            props.error_msg = null;

            const input_result = try input_mod.Input(props).mountResult(result.scope, cx);
            _ = try core.adoptChild(cx, cx.allocator, result.control_slot, input_result.node);

            return result.wrapper;
        }
    };
}

// ========== 测试 ==========

test "FormField: basic structure with label" {
    const TestForm = struct { name: []const u8 };

    const allocator = std.testing.allocator;
    var ctx = try Cx.init(allocator);
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

    // wrapper 应有 3 个子节点: label_row + control_slot + helper_node
    try std.testing.expectEqual(@as(usize, 3), result.wrapper.children.items.len);

    // 第一个子节点是 label_row
    const label_row = result.wrapper.children.items[0];
    try std.testing.expect(label_row.children.items.len >= 1);
    // label 文本
    const label_node = label_row.children.items[0];
    try std.testing.expectEqualStrings("Name", label_node.getText().?.content);

    // 第二个子节点是 control_slot（空）
    try std.testing.expectEqual(@as(usize, 0), result.control_slot.children.items.len);

    // 第三个子节点是 helper_node
    try std.testing.expectEqualStrings("Enter your name", result.helper_node.getText().?.content);
}

test "FormField: required shows asterisk" {
    const TestForm = struct { email: []const u8 };

    const allocator = std.testing.allocator;
    var ctx = try Cx.init(allocator);
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

    // label_row 应有 2 个子节点: label + asterisk
    const label_row = result.wrapper.children.items[0];
    try std.testing.expectEqual(@as(usize, 2), label_row.children.items.len);
    // 第二个是红色星号
    const asterisk = label_row.children.items[1];
    try std.testing.expectEqualStrings("*", asterisk.getText().?.content);
}

test "FormField: no label creates 2 children" {
    const TestForm = struct { value: i32 };

    const allocator = std.testing.allocator;
    var ctx = try Cx.init(allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(allocator, null, ctx.owner);
    defer scope.dispose();

    const form = try FormOf(TestForm).create(scope, .{ .value = 0 }, .{});

    const result = try FormFieldOf(TestForm).field(.value, .{}, form, scope, ctx);
    try root.appendChild(allocator, result.wrapper);

    // 无 label → 只有 control_slot + helper_node
    try std.testing.expectEqual(@as(usize, 2), result.wrapper.children.items.len);
}

test "FormField: error signal updates helper" {
    const TestForm = struct { name: []const u8 };

    const allocator = std.testing.allocator;
    var ctx = try Cx.init(allocator);
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

    // 初始状态应显示 helper 文本
    try std.testing.expectEqualStrings("Enter your name", result.helper_node.getText().?.content);

    // 设置错误 → Effect 应自动更新 helper_node
    form.meta(.name).error_sig.set("Name is required");
    try std.testing.expectEqualStrings("Name is required", result.helper_node.getText().?.content);

    // 清除错误 → 恢复 helper
    form.meta(.name).error_sig.set(null);
    try std.testing.expectEqualStrings("Enter your name", result.helper_node.getText().?.content);
}

test "a11y: FormField 的 required/invalid 到达 a11y 树且跟随校验结果" {
    const a11y_tree_mod = @import("../../a11y/tree.zig");
    const TestForm = struct { name: []const u8 };

    const allocator = std.testing.allocator;
    var ctx = try Cx.init(allocator);
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

    // 断言 a11y 树（真正送给 AT 的），不是 props 结构体。
    const eid = core.ElementId.fromRaw(result.wrapper.element_id_raw);
    const n0 = ctx.accessibility_tree.get(eid).?;
    // 必填在视觉上只是 label 后一个红 "*"，AT 只能靠 required 位知道
    try std.testing.expect(n0.state.required);
    try std.testing.expect(!n0.state.invalid);

    // 校验失败 → invalid 必须跟上（否则 AT 只看到 helper 变红，读不出"无效"）
    form.meta(.name).error_sig.set("Name is required");
    ctx.layout();
    _ = ctx.render();
    try std.testing.expect(ctx.accessibility_tree.get(eid).?.state.invalid);
    try std.testing.expectEqual(a11y_tree_mod.Role.group, ctx.accessibility_tree.get(eid).?.role);

    // 改好了 → invalid 必须撤回，不能一直报错
    form.meta(.name).error_sig.set(null);
    ctx.layout();
    _ = ctx.render();
    try std.testing.expect(!ctx.accessibility_tree.get(eid).?.state.invalid);
}

test "FormField: inputField 可编译并绑定回值（守零调用者失效）" {
    // 这个测试存在的**唯一理由**是让 inputField 被语义分析到。
    //
    // 它此前给 `props.context` 赋值，而 InputProps 从来没有这个字段
    //（on_change 早已并轨成自带 context 的 HandlerRef）。因为零调用者
    // 且身处 comptime `return struct`，Zig 从不分析它 —— 于是一个
    // **编译不过**的函数带着文档示例公开导出，谁照文档抄谁踩坑。
    const TestForm = struct { email: []const u8 };

    const allocator = std.testing.allocator;
    var ctx = try Cx.init(allocator);
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

    // label + control_slot 结构成立
    try std.testing.expect(wrapper.children.items.len >= 2);

    // 回调确实接上了 form（HandlerRef 自带 context，不再有裸 context 字段）
    const control_slot = wrapper.children.items[1];
    try std.testing.expect(control_slot.children.items.len >= 1);
}

test "FormField: inputField 回写的值不别名 Input 内部缓冲（字段卸载后不悬垂）" {
    const TestForm = struct { email: []const u8 };
    const allocator = std.testing.allocator;
    var ctx = try Cx.init(allocator);
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
    // 原地等长改写 Input 缓冲、未触发 on_change：form 值不能跟着变（证明不是别名）
    _ = state.setText("wxyz");
    try std.testing.expectEqualStrings("abcd", form.get(.email));
    state.on_change.?.invokeWithStr(state.getText());
    try std.testing.expectEqualStrings("wxyz", form.get(.email));
    try std.testing.expect(form.metas[0].dirty_sig.peek());

    // 卸载字段：form 值仍有效
    root.removeChild(wrapper);
    ctx.freeNode(wrapper);
    field_scope.dispose();
    try std.testing.expectEqualStrings("wxyz", form.get(.email));
}

// 剩余未接 sweep 的组件（markdown render / form_field / select_headless）。
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

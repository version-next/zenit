/// FormOf(T), comptime 泛型表单数据 + 验证层
///
/// 基于 StoreOf(T) 实现细粒度表单状态管理：
/// - 每字段独立 Signal（值 + error + touched + dirty）
/// - comptime 提取 T.rules 声明，编译期生成验证函数
/// - 验证时机可配置（onChange / onBlur / onSubmit）
///
/// 用法:
/// ```zig
/// const LoginForm = struct {
///     email: []const u8,
///     password: []const u8,
///     pub const rules = .{
///         .email = struct {
///             fn validate(v: []const u8) ValidationResult {
///                 if (v.len == 0) return .{ .valid = false, .message = "必填" };
///                 return .{ .valid = true };
///             }
///         }.validate,
///     };
/// };
///
/// const form = try FormOf(LoginForm).create(scope, .{ .email = "", .password = "" }, .{});
/// form.setValue(.email, "test@example.com");
/// form.touchField(.email);
/// if (form.validateAll()) { ... }
/// ```
const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../../core.zig");
const Scope = core.Scope;
const Signal = core.Signal;
const StoreOf = @import("../../reactive/store.zig").StoreOf;

/// 验证时机
pub const ValidateTrigger = enum {
    /// 值变化时立即验证
    on_change,
    /// 失焦时验证
    on_blur,
    /// 仅提交时验证
    on_submit,
};

/// 验证规则返回值
pub const ValidationResult = struct {
    valid: bool,
    message: ?[]const u8 = null,
};

/// 单字段元数据
pub const FieldMeta = struct {
    /// 错误消息（null = 无错误）
    error_sig: *Signal(?[]const u8),
    /// 是否被触碰过（blur 后为 true）
    touched_sig: *Signal(bool),
    /// 是否被修改过（值 != 初始值）
    dirty_sig: *Signal(bool),
};

/// comptime 泛型表单
pub fn FormOf(comptime T: type) type {
    const info = @typeInfo(T).@"struct";
    const field_count = info.fields.len;
    const has_rules = @hasDecl(T, "rules");

    return struct {
        const Self = @This();
        pub const FieldEnum = std.meta.FieldEnum(T);

        store: StoreOf(T),
        metas: [field_count]FieldMeta,
        scope: *Scope,
        trigger: ValidateTrigger,
        initial_values: T,
        /// setValueCopy 为 []const u8 字段持有的副本（form 生命周期内有效，destroy 时释放）。
        owned_text: [field_count]?[]u8 = [_]?[]u8{null} ** field_count,

        /// 提交回调
        on_submit: ?*const fn (T, *anyopaque) void,
        submit_context: ?*anyopaque,

        /// 创建 Form 实例
        pub fn create(
            scope: *Scope,
            initial: T,
            config: struct {
                trigger: ValidateTrigger = .on_blur,
                on_submit: ?*const fn (T, *anyopaque) void = null,
                submit_context: ?*anyopaque = null,
            },
        ) !*Self {
            const form_scope = try scope.childScope();
            const store = try StoreOf(T).create(form_scope, initial);

            var metas: [field_count]FieldMeta = undefined;
            inline for (0..field_count) |i| {
                metas[i] = .{
                    .error_sig = try form_scope.createSignal(?[]const u8, null),
                    .touched_sig = try form_scope.createSignal(bool, false),
                    .dirty_sig = try form_scope.createSignal(bool, false),
                };
            }

            const self = try form_scope.allocator.create(Self);
            self.* = .{
                .store = store,
                .metas = metas,
                .scope = form_scope,
                .trigger = config.trigger,
                .initial_values = initial,
                .on_submit = config.on_submit,
                .submit_context = config.submit_context,
            };

            try form_scope.adoptResource(@ptrCast(self), struct {
                fn destroy(ptr: *anyopaque, alloc: Allocator) void {
                    const s: *Self = @ptrCast(@alignCast(ptr));
                    for (s.owned_text) |buf| if (buf) |b| alloc.free(b);
                    alloc.destroy(s);
                }
            }.destroy);

            return self;
        }

        /// 获取字段值（自动追踪依赖）
        pub fn get(self: *const Self, comptime field: FieldEnum) FieldType(field) {
            return self.store.get(field);
        }

        /// 设置字段值 + 标记 dirty + 按策略验证
        pub fn setValue(self: *Self, comptime field: FieldEnum, value: FieldType(field)) void {
            self.store.set(field, value);
            const idx = @intFromEnum(field);
            self.metas[idx].dirty_sig.set(true);
            if (self.trigger == .on_change) {
                self.validateField(field);
            }
        }

        /// setValue 的拷贝版（仅 []const u8 字段）：value 只需在调用期间有效
        /// （如 Input on_change 传入的内部缓冲切片），form 自持一份副本。
        /// 先分配新副本、set、再释放旧副本，Signal 按内容比较，旧值必须仍可读。
        pub fn setValueCopy(self: *Self, comptime field: FieldEnum, value: []const u8) !void {
            comptime std.debug.assert(FieldType(field) == []const u8);
            const idx = @intFromEnum(field);
            const alloc = self.scope.allocator;
            const copy = try alloc.dupe(u8, value);
            const old = self.owned_text[idx];
            self.owned_text[idx] = copy;
            self.setValue(field, copy);
            if (old) |b| alloc.free(b);
        }

        /// 标记字段 touched（blur 时调用）
        pub fn touchField(self: *Self, comptime field: FieldEnum) void {
            const idx = @intFromEnum(field);
            self.metas[idx].touched_sig.set(true);
            if (self.trigger == .on_blur) {
                self.validateField(field);
            }
        }

        /// 验证单个字段（comptime 提取规则）
        pub fn validateField(self: *Self, comptime field: FieldEnum) void {
            const idx = @intFromEnum(field);
            if (has_rules) {
                const field_name = info.fields[idx].name;
                const RulesType = @TypeOf(T.rules);
                if (@hasField(RulesType, field_name)) {
                    const rule_fn = @field(T.rules, field_name);
                    const value = self.store.get(field);
                    const result = rule_fn(value);
                    self.metas[idx].error_sig.set(result.message);
                    return;
                }
            }
            // 无规则 -> 清空错误
            self.metas[idx].error_sig.set(null);
        }

        /// 全量验证所有字段
        pub fn validateAll(self: *Self) bool {
            var all_valid = true;
            const values = self.store.snapshot(); // peek 所有字段，无依赖追踪
            inline for (info.fields, 0..) |f, i| {
                self.metas[i].touched_sig.set(true);
                if (has_rules) {
                    const RulesType = @TypeOf(T.rules);
                    if (@hasField(RulesType, f.name)) {
                        const rule_fn = @field(T.rules, f.name);
                        const value = @field(values, f.name);
                        const result = rule_fn(value);
                        self.metas[i].error_sig.set(result.message);
                        if (!result.valid) all_valid = false;
                    }
                }
            }
            return all_valid;
        }

        /// 提交处理：全量验证 -> 通过则回调
        pub fn handleSubmit(self: *Self) void {
            if (!self.validateAll()) return;
            if (self.on_submit) |cb| {
                if (self.submit_context) |ctx| {
                    cb(self.store.snapshot(), ctx);
                }
            }
        }

        /// 重置为初始值，清空所有 meta
        pub fn reset(self: *Self) void {
            inline for (info.fields, 0..) |f, i| {
                const field_enum: FieldEnum = @enumFromInt(i);
                self.store.set(field_enum, @field(self.initial_values, f.name));
                self.metas[i].error_sig.set(null);
                self.metas[i].touched_sig.set(false);
                self.metas[i].dirty_sig.set(false);
            }
        }

        /// 获取字段的 FieldMeta（给 FormField 使用）
        pub fn meta(self: *Self, comptime field: FieldEnum) *FieldMeta {
            return &self.metas[@intFromEnum(field)];
        }

        /// 整体是否有错误
        pub fn hasErrors(self: *Self) bool {
            for (&self.metas) |*m| {
                if (m.error_sig.peek() != null) return true;
            }
            return false;
        }

        /// 整体是否 dirty
        pub fn isDirty(self: *Self) bool {
            for (&self.metas) |*m| {
                if (m.dirty_sig.peek()) return true;
            }
            return false;
        }

        /// 获取字段的类型
        fn FieldType(comptime field: FieldEnum) type {
            return std.meta.fieldInfo(T, field).type;
        }
    };
}

// ========== 测试 ==========

test "FormOf: create and get/set" {
    const TestForm = struct {
        name: []const u8,
        age: i32,
    };

    const allocator = std.testing.allocator;
    const SignalOwner = @import("../../reactive/owner.zig").SignalOwner;
    var owner = try SignalOwner.init(allocator);
    defer owner.deinit();

    const scope = try Scope.init(allocator, null, owner);
    defer scope.dispose();

    const form = try FormOf(TestForm).create(scope, .{ .name = "Alice", .age = 25 }, .{});

    // 读取初始值
    try std.testing.expectEqualStrings("Alice", form.get(.name));
    try std.testing.expectEqual(@as(i32, 25), form.get(.age));

    // 设置值
    form.setValue(.name, "Bob");
    try std.testing.expectEqualStrings("Bob", form.get(.name));

    // dirty 应自动标记
    try std.testing.expect(form.meta(.name).dirty_sig.peek());
    try std.testing.expect(!form.meta(.age).dirty_sig.peek());
}

test "FormOf: validation rules" {
    const TestForm = struct {
        email: []const u8,
        name: []const u8,

        pub const rules = .{
            .email = struct {
                fn validate(v: []const u8) ValidationResult {
                    if (v.len == 0) return .{ .valid = false, .message = "Required" };
                    return .{ .valid = true };
                }
            }.validate,
        };
    };

    const allocator = std.testing.allocator;
    const SignalOwner = @import("../../reactive/owner.zig").SignalOwner;
    var owner = try SignalOwner.init(allocator);
    defer owner.deinit();

    const scope = try Scope.init(allocator, null, owner);
    defer scope.dispose();

    const form = try FormOf(TestForm).create(scope, .{ .email = "", .name = "Alice" }, .{});

    // 空 email 应报错
    form.validateField(.email);
    try std.testing.expectEqualStrings("Required", form.meta(.email).error_sig.peek().?);

    // 填写后应通过
    form.setValue(.email, "test@example.com");
    form.validateField(.email);
    try std.testing.expect(form.meta(.email).error_sig.peek() == null);

    // name 没有规则，validateField 不应报错
    form.validateField(.name);
    try std.testing.expect(form.meta(.name).error_sig.peek() == null);
}

test "FormOf: on_change trigger auto-validates" {
    const TestForm = struct {
        email: []const u8,

        pub const rules = .{
            .email = struct {
                fn validate(v: []const u8) ValidationResult {
                    if (v.len == 0) return .{ .valid = false, .message = "Required" };
                    return .{ .valid = true };
                }
            }.validate,
        };
    };

    const allocator = std.testing.allocator;
    const SignalOwner = @import("../../reactive/owner.zig").SignalOwner;
    var owner = try SignalOwner.init(allocator);
    defer owner.deinit();

    const scope = try Scope.init(allocator, null, owner);
    defer scope.dispose();

    const form = try FormOf(TestForm).create(scope, .{ .email = "" }, .{
        .trigger = .on_change,
    });

    // 设置空值 -> 自动验证报错
    form.setValue(.email, "");
    try std.testing.expectEqualStrings("Required", form.meta(.email).error_sig.peek().?);

    // 设置有效值 -> 自动清除错误
    form.setValue(.email, "a@b.com");
    try std.testing.expect(form.meta(.email).error_sig.peek() == null);
}

test "FormOf: on_blur trigger" {
    const TestForm = struct {
        email: []const u8,

        pub const rules = .{
            .email = struct {
                fn validate(v: []const u8) ValidationResult {
                    if (v.len == 0) return .{ .valid = false, .message = "Required" };
                    return .{ .valid = true };
                }
            }.validate,
        };
    };

    const allocator = std.testing.allocator;
    const SignalOwner = @import("../../reactive/owner.zig").SignalOwner;
    var owner = try SignalOwner.init(allocator);
    defer owner.deinit();

    const scope = try Scope.init(allocator, null, owner);
    defer scope.dispose();

    const form = try FormOf(TestForm).create(scope, .{ .email = "" }, .{
        .trigger = .on_blur,
    });

    // setValue 不触发验证（on_blur 模式）
    form.setValue(.email, "");
    try std.testing.expect(form.meta(.email).error_sig.peek() == null);

    // touchField 触发验证
    form.touchField(.email);
    try std.testing.expectEqualStrings("Required", form.meta(.email).error_sig.peek().?);
    try std.testing.expect(form.meta(.email).touched_sig.peek());
}

test "FormOf: validateAll and hasErrors" {
    const TestForm = struct {
        email: []const u8,
        password: []const u8,

        pub const rules = .{
            .email = struct {
                fn validate(v: []const u8) ValidationResult {
                    if (v.len == 0) return .{ .valid = false, .message = "Email required" };
                    return .{ .valid = true };
                }
            }.validate,
            .password = struct {
                fn validate(v: []const u8) ValidationResult {
                    if (v.len < 6) return .{ .valid = false, .message = "Min 6 chars" };
                    return .{ .valid = true };
                }
            }.validate,
        };
    };

    const allocator = std.testing.allocator;
    const SignalOwner = @import("../../reactive/owner.zig").SignalOwner;
    var owner = try SignalOwner.init(allocator);
    defer owner.deinit();

    const scope = try Scope.init(allocator, null, owner);
    defer scope.dispose();

    const form = try FormOf(TestForm).create(scope, .{ .email = "", .password = "123" }, .{});

    // validateAll 应返回 false
    try std.testing.expect(!form.validateAll());
    try std.testing.expect(form.hasErrors());

    // 两个字段都应有错误
    try std.testing.expectEqualStrings("Email required", form.meta(.email).error_sig.peek().?);
    try std.testing.expectEqualStrings("Min 6 chars", form.meta(.password).error_sig.peek().?);

    // 所有字段应被标记为 touched
    try std.testing.expect(form.meta(.email).touched_sig.peek());
    try std.testing.expect(form.meta(.password).touched_sig.peek());

    // 修正后应全部通过
    form.setValue(.email, "a@b.com");
    form.setValue(.password, "123456");
    try std.testing.expect(form.validateAll());
    try std.testing.expect(!form.hasErrors());
}

test "FormOf: reset" {
    const TestForm = struct {
        name: []const u8,
        age: i32,
    };

    const allocator = std.testing.allocator;
    const SignalOwner = @import("../../reactive/owner.zig").SignalOwner;
    var owner = try SignalOwner.init(allocator);
    defer owner.deinit();

    const scope = try Scope.init(allocator, null, owner);
    defer scope.dispose();

    const form = try FormOf(TestForm).create(scope, .{ .name = "Alice", .age = 25 }, .{});

    // 修改并标脏
    form.setValue(.name, "Bob");
    form.touchField(.name);
    form.meta(.name).error_sig.set("some error");

    try std.testing.expect(form.meta(.name).dirty_sig.peek());
    try std.testing.expect(form.meta(.name).touched_sig.peek());
    try std.testing.expect(form.meta(.name).error_sig.peek() != null);

    // 重置
    form.reset();
    try std.testing.expectEqualStrings("Alice", form.get(.name));
    try std.testing.expectEqual(@as(i32, 25), form.get(.age));
    try std.testing.expect(!form.meta(.name).dirty_sig.peek());
    try std.testing.expect(!form.meta(.name).touched_sig.peek());
    try std.testing.expect(form.meta(.name).error_sig.peek() == null);
}

test "FormOf: handleSubmit" {
    const TestForm = struct {
        email: []const u8,

        pub const rules = .{
            .email = struct {
                fn validate(v: []const u8) ValidationResult {
                    if (v.len == 0) return .{ .valid = false, .message = "Required" };
                    return .{ .valid = true };
                }
            }.validate,
        };
    };

    const allocator = std.testing.allocator;
    const SignalOwner = @import("../../reactive/owner.zig").SignalOwner;
    var owner = try SignalOwner.init(allocator);
    defer owner.deinit();

    const scope = try Scope.init(allocator, null, owner);
    defer scope.dispose();

    const CallbackState = struct {
        submitted: bool = false,
        submitted_email: []const u8 = "",
    };
    var cb_state = CallbackState{};

    const form = try FormOf(TestForm).create(scope, .{ .email = "" }, .{
        .on_submit = struct {
            fn submit(values: TestForm, ctx: *anyopaque) void {
                const state: *CallbackState = @ptrCast(@alignCast(ctx));
                state.submitted = true;
                state.submitted_email = values.email;
            }
        }.submit,
        .submit_context = @ptrCast(&cb_state),
    });

    // 空 email -> 验证失败 -> 不提交
    form.handleSubmit();
    try std.testing.expect(!cb_state.submitted);

    // 填写有效值 -> 提交
    form.setValue(.email, "a@b.com");
    form.handleSubmit();
    try std.testing.expect(cb_state.submitted);
    try std.testing.expectEqualStrings("a@b.com", cb_state.submitted_email);
}

test "FormOf: isDirty" {
    const TestForm = struct {
        name: []const u8,
        age: i32,
    };

    const allocator = std.testing.allocator;
    const SignalOwner = @import("../../reactive/owner.zig").SignalOwner;
    var owner = try SignalOwner.init(allocator);
    defer owner.deinit();

    const scope = try Scope.init(allocator, null, owner);
    defer scope.dispose();

    const form = try FormOf(TestForm).create(scope, .{ .name = "Alice", .age = 25 }, .{});

    try std.testing.expect(!form.isDirty());

    form.setValue(.name, "Bob");
    try std.testing.expect(form.isDirty());

    form.reset();
    try std.testing.expect(!form.isDirty());
}

test "FormOf: no rules struct" {
    const SimpleForm = struct {
        text: []const u8,
        count: i32,
    };

    const allocator = std.testing.allocator;
    const SignalOwner = @import("../../reactive/owner.zig").SignalOwner;
    var owner = try SignalOwner.init(allocator);
    defer owner.deinit();

    const scope = try Scope.init(allocator, null, owner);
    defer scope.dispose();

    const form = try FormOf(SimpleForm).create(scope, .{ .text = "hello", .count = 0 }, .{});

    // 无规则 -> validateAll 应返回 true
    try std.testing.expect(form.validateAll());
    try std.testing.expect(!form.hasErrors());

    form.setValue(.text, "world");
    try std.testing.expectEqualStrings("world", form.get(.text));
}

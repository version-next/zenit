/// Form 组件模块
///
/// 三层架构:
/// - Layer 0: FormOf(T)，数据 + 验证层
/// - Layer 1: FormFieldOf(T)，字段容器 UI
/// - Layer 2: Form，布局容器
const std = @import("std");

// Layer 0: 数据 + 验证层
pub const form_data = @import("form_data.zig");
pub const FormOf = form_data.FormOf;
pub const ValidationResult = form_data.ValidationResult;
pub const ValidateTrigger = form_data.ValidateTrigger;
pub const FieldMeta = form_data.FieldMeta;

// Layer 1: 字段容器 UI
pub const form_field = @import("form_field.zig");
pub const FormFieldOf = form_field.FormFieldOf;
pub const FormFieldResult = form_field.FormFieldResult;
pub const FormFieldConfig = form_field.FormFieldConfig;

// Layer 2: 布局容器
pub const form_layout = @import("form_layout.zig");
pub const Form = form_layout.Form;
pub const FormBuilder = form_layout.FormBuilder;
pub const FormLayout = form_layout.FormLayout;
pub const FormResult = form_layout.FormResult;
pub const FormSection = form_layout.FormSection;

test {
    std.testing.refAllDecls(@This());
}

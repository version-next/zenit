//! Select Headless — Radix-style 解耦组件 (v0.7 已 GA)
//!
//! 旧 `components/select.zig` (monolithic + MAX_OPTIONS=64 硬上限) 已删除；
//! 此目录是唯一 Select 实现。
//!
//! v0.7 退出状态:
//! - §2.1 ✅ slot 化 (render_trigger / render_item) + SelectSlotRecipe 接入 recipe.zig
//! - §2.2 ✅ virtualize=true 接 VirtualList，1k+ options 不爆 Node
//! - 控制流: ControlledProp(T) 锁定 controlled/uncontrolled 二元模式
//! - 键盘: typeahead / 方向键 / PageUp/PageDown / Home/End / Esc / Enter 内置
//!
//! 文件拆分:
//! - `state_machine.zig`: 纯逻辑 (Option / SelectState / step / Action / commit)；
//!   不依赖 core / reactive，bench facade 直接 import
//! - `mount.zig`: 渲染挂载层 (mountSelectHeadless / VirtualList path / slot ctx /
//!   SelectSlotRecipe 默认 base style)
//! - `mod.zig` (此文件): 聚合 re-export，主路径单点入口
//!
//! 设计参照: Radix UI Select / shadcn Select / Panda CSS sva slot recipe.

const sm = @import("state_machine.zig");

// pure-logic re-exports (state machine)
pub const ControlledProp = sm.ControlledProp;
pub const Option = sm.Option;
pub const OpenState = sm.OpenState;
pub const SelectProps = sm.SelectProps;
pub const SelectState = sm.SelectState;
pub const Action = sm.Action;
pub const step = sm.step;
pub const commitSelection = sm.commitSelection;

/// select_headless 主挂渲染入口（mount.zig）。
/// 用 Popover + default item list 把 state machine 真挂到 *Node 树。
pub const mount = @import("mount.zig");
pub const mountSelectHeadless = mount.mountSelectHeadless;
pub const MountProps = mount.MountProps;
pub const SelectHeadlessMount = mount.SelectHeadlessMount;

// slot / recipe / variant re-export
pub const SelectSlotRecipe = mount.SelectSlotRecipe;
pub const SelectVariant = mount.SelectVariant;
pub const SelectSize = mount.SelectSize;
pub const TriggerSlotCtx = mount.TriggerSlotCtx;
pub const ItemSlotCtx = mount.ItemSlotCtx;

// mount.zig / state_machine.zig 的 test 此前没有任何 test 块引用，
// test-ui 从未收集过它们（含 mount.zig 里 3 个既有测试）——显式挂上。
test {
    _ = mount;
    _ = sm;
}

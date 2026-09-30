//! Select Headless mount layer
//!
//! 在 mod.zig 的纯逻辑 state machine 之上加渲染挂载：
//! 用 Popover 做 trigger/content 浮层；可选 VirtualList 池化大列表；
//! 内置 keyboard/click 路由 + recipe.zig 样式接入。
//!
//! v0.7 已 GA 能力:
//! - 单值 select (multi-select 暂未支持，v0.8 候选)
//! - SelectSlotRecipe 接入 recipe.zig — 默认 base style 经 ConditionalStyle merge
//!   出 (trigger / content / item) 三 slot 颜色
//! - slot 化: caller 可注 render_trigger / render_item fn ptr 自定义节点 (mount
//!   仍管 click/keyboard 路由)
//! - virtualize=true 接 VirtualList — 1k+ options 不爆 Node (pool 复用 + ensureVisible
//!   让键盘 highlight 自动滚到视口)
//! - keyboard: typeahead / arrow up/down / PageUp/PageDown / Home/End / Esc / Enter
//! - 提交回调 on_change(?ValueT) — uncontrolled 模式下 caller 通过此 hook 监听
//!
//! v0.8 §2.1 已 land:
//! - trigger a11y.role=combobox + has_popup=listbox
//! - aria-activedescendant: highlight_index 变化 → trigger.a11y.active_descendant_element_id
//!   跟随 item.element_id_raw (virtualize 模式扫 pool_bindings)；不在可见区间则置 NULL。
//!   下游 (a11y_tree.upsert → router → push) v0.7 #46 已闭环。
//!
//! 留 v0.8+ 候选: multi-select；focus restoration on rerender；IME 联想。
//!
//! 用法 (comptime ValueT):
//! ```
//! const SH = ui.select_headless;
//! const result = try SH.mountSelectHeadless(i32, .{
//!     .options = &.{
//!         .{ .value = 1, .label = "Apple" },
//!         .{ .value = 2, .label = "Banana" },
//!     },
//!     .placeholder = "Pick a fruit...",
//!     .on_change = .{ .callback = onChange, .context = my_state },
//!     // .virtualize = true,   // for 1k+ options
//!     // .render_trigger = myTriggerFn,
//!     // .render_item = myItemFn,
//! }, scope, cx);
//! ```

const std = @import("std");
const icons = @import("zenit_system_icons");
const sm = @import("mod.zig");
const core = @import("../../core.zig");
const control_shell = @import("../control_shell/mod.zig");
const popover_mod = @import("../popover/mod.zig");
const virtual_list_mod = @import("../virtual_list/mod.zig");
const recipe_mod = @import("../../recipe.zig");
const theme = @import("../../theme.zig");

pub const Option = sm.Option;
pub const SelectProps = sm.SelectProps;
pub const SelectState = sm.SelectState;
pub const Action = sm.Action;
pub const ControlledProp = sm.ControlledProp;

const Allocator = std.mem.Allocator;
const Cx = core.Cx;
const Node = core.Node;
const Scope = core.Scope;
const Signal = core.Signal;
const Color = core.Color;
const Event = core.Event;
const EventResult = core.EventResult;
const KeyCode = core.KeyCode;
const Modifiers = core.Modifiers;
const HandlerRef = core.HandlerRef;
const ConditionalStyle = recipe_mod.ConditionalStyle;
const ThemeTokens = theme.ThemeTokens;

// ============================================================================
// v0.7 §2.1 — SelectSlotRecipe
// ============================================================================
//
// 三 slot：trigger / content / item
// 通过 recipe.slotRecipe 定义。caller 可拿 SelectSlotRecipe.resolve(.{}, tokens)
// 拿一组 ConditionalStyle 自行应用到 slot Node 上，或者通过 MountProps.recipe_override
// 让 mount 函数走自定义 token。
//
// Phase 7 plan 退出标准之一: "recipe 在 select 接入，至少 trigger / item / content
// 三处 token"。本 SlotRecipe 是 wire-up；具体 style 值参照 v0.5 期间硬编码的样式
// (bg_primary / border / fg_primary / bg_hover / bg_active) 一比一迁过去。

pub const SelectVariant = enum { default };
/// 与 Button / Input / Select / DatePicker 同一套 ControlSize（xs / sm / md / lg）。
/// 注意：旧版私有枚举的 `.sm` 实际是 xs 几何（20 高）；统一后 `.sm` = 主题 sm（24），
/// 要 20 请用 `.xs`。
pub const SelectSize = core.theme.ControlSize;

pub const SelectSlotRecipe = recipe_mod.slotRecipe(struct {
    pub const Slots = struct {
        trigger: ConditionalStyle = .{},
        content: ConditionalStyle = .{},
        item: ConditionalStyle = .{},
    };

    pub const Variants = struct {
        variant: SelectVariant = .default,
        size: SelectSize = .md,
    };

    pub fn base(t: *const ThemeTokens) Slots {
        return .{
            .trigger = .{
                .base = .{
                    .background = t.color.bg_primary,
                    .text_color = t.color.fg_primary,
                },
                .focus = .{ .background = t.color.bg_primary },
                .disabled = .{ .text_color = t.color.fg_disabled },
            },
            .content = .{
                .base = .{ .background = t.color.bg_primary },
            },
            .item = .{
                .base = .{ .text_color = t.color.fg_primary },
                .hover = .{ .background = t.color.bg_hover },
                .active = .{ .background = t.color.bg_hover },
                .disabled = .{ .text_color = t.color.fg_disabled },
            },
        };
    }

    pub const variants = .{
        .variant = struct {
            fn resolve(_: SelectVariant, _: *const ThemeTokens) Slots {
                return .{};
            }
        }.resolve,
        .size = struct {
            fn resolve(_: SelectSize, _: *const ThemeTokens) Slots {
                return .{};
            }
        }.resolve,
    };
});

// trigger 几何（高度 / padding / 圆角 / 字号 / 图标）全部来自 ControlShell recipe
// （tokens.control.get(size)），不在这里写表。下拉列表行高是列表行度量，不是控件外框：
pub fn itemHeight(size: SelectSize) f32 {
    return switch (size) {
        .xs, .sm => 32,
        .md => 36,
        .lg => 40,
    };
}

pub fn selectPanelRadius(t: *const ThemeTokens) f32 {
    return t.radius.xl;
}

pub const select_panel_shadow: core.Shadow = .{
    .color = core.Color.rgba(0, 0, 0, 18),
    .blur = 12,
    .offset_x = 0,
    .offset_y = 4,
};

/// 用户提交回调签名：(?ValueT, ctx)
/// 通过 HandlerRef.callback (*const fn (*anyopaque) void) 传入；context 由 caller 持有 ValueT。
/// Stage 1 不暴露泛型 callback；caller 自己读 result.state.value（带 reactive）即可。
/// mountSelectHeadless 返回值
pub fn SelectHeadlessMount(comptime ValueT: type) type {
    return struct {
        /// 外层 Popover wrapper（caller append 到自己的 mount 点；除非 portaled=true）
        wrapper: *Node,
        /// 触发节点（点击切换 open/close）
        trigger: *Node,
        /// 标签节点（trigger 内部 label）—— caller 可改 .text.content 自定义当前选中显示
        trigger_label: *Node,
        /// 内容面板（item 列表父节点，caller 可遍历 children 取真实 item nodes）
        content: *Node,
        /// is_open signal（reactive 读，比如让 trigger 改 chevron 方向）
        is_open: *Signal(bool),
        /// 内部 state（包含 value / highlight_index / typeahead）
        state: *SelectState(ValueT),
        /// option 节点池（length == options.len；index 对齐 props.options[i]）
        item_nodes: []*Node,
        /// virtualize=true 时的 VirtualList 状态（测试与调用方按需 refreshRange / 观察重试）
        vl_state: ?*virtual_list_mod.VirtualListState = null,
    };
}

/// 单 option click 上下文
fn ItemClickContext(comptime ValueT: type) type {
    return struct {
        state: *SelectState(ValueT),
        options: []const Option(ValueT),
        index: u32,
        is_open_signal: *Signal(bool),
        item_nodes: []*Node,
        cx: *Cx,
        tokens: *const core.theme.ThemeTokens,
        /// 用户提交回调（可空）
        on_change: ?HandlerRef = null,
        /// caller 提供了 render_item slot 时不要覆盖 item.getBackground()；
        /// 高亮可视化由 caller 自己管 (后续 v0.8 暴露 highlight_index Signal 让 caller reactive)。
        custom_item_render: bool = false,
        /// trigger node ref — click 改 highlight 后回写
        /// trigger.a11y.active_descendant_element_id (aria-activedescendant)
        trigger: *Node,
    };
}

fn KeyContext(comptime ValueT: type) type {
    return struct {
        state: *SelectState(ValueT),
        options: []const Option(ValueT),
        is_open_signal: *Signal(bool),
        item_nodes: []*Node,
        tokens: *const core.theme.ThemeTokens,
        on_change: ?HandlerRef = null,
        custom_item_render: bool = false,
        /// VirtualList state (开启 virtualize 时非空)；keyboard nav
        /// 后 ensureVisible + refreshRange
        vl_state: ?*virtual_list_mod.VirtualListState = null,
        /// trigger node ref — keyboard 改 highlight 后回写
        /// trigger.a11y.active_descendant_element_id (aria-activedescendant)
        trigger: *Node,
    };
}

/// VirtualList user_context — pool render_fn 通过它拿状态。
/// 跟 ItemClickContext 字段大致重叠，但少了 index (pool 节点共享，binding 动态)。
fn VirtRenderContext(comptime ValueT: type) type {
    return struct {
        state: *SelectState(ValueT),
        options: []const Option(ValueT),
        is_open_signal: *Signal(bool),
        cx: *Cx,
        tokens: *const core.theme.ThemeTokens,
        on_change: ?HandlerRef = null,
        size: SelectSize,
        variant: SelectVariant,
        item_h: f32,
        font_size: f32,
        item_slot_recipe_base_text_color: Color,
        render_item: ?*const fn (ctx: ItemSlotCtx(ValueT), cx: *Cx) anyerror!*Node,
        /// 自引用 — VL render_fn 用 vl_state.pool_bindings 推 highlight，
        /// 但创建顺序: VirtRenderContext → VL.mountWithContext → 回填 vl_state
        vl_state: ?*virtual_list_mod.VirtualListState = null,
        /// pool node 上挂的 click context — render_fn 第一次见某 pool node 时
        /// alloc 一个，存这个 list 里以便 scope dispose 时统一释放。
        allocated_click_ctxs: std.ArrayListUnmanaged(*VirtItemClickContext(ValueT)) = .{},
        allocator: std.mem.Allocator,
        /// trigger node ref — virt click 改 highlight 后回写 aria-activedescendant
        trigger: *Node,
    };
}

/// 池 click handler context — 通过 node + binding 查当前 option index
fn VirtItemClickContext(comptime ValueT: type) type {
    return struct {
        vctx: *VirtRenderContext(ValueT),
        /// 池 slot 的 node 引用 — handler 拿到 event 时通过 vctx.vl_state.pool_nodes
        /// 反查自己是哪个 slot，进而 pool_bindings[slot] 取当前 data index
        slot_node: *Node,
    };
}

/// VirtualList render_fn — 每次 pool 行进入可见区域时调
/// 在 pool 预分配的 node 上 fill children + style + 挂 click handler
fn virtRenderItemFn(comptime ValueT: type) virtual_list_mod.RenderItemWithContextFn {
    const W = struct {
        /// 回调是 void，失败只能 return——但要先向 VL 留痕，让它下一帧为这行重新取 slot 再调一次；
        /// 不留痕就是"半截行 + 整行无 click handler，直到某次 refreshRange"（GLM 交叉审查指出）。
        fn bail(node: *Node) void {
            _ = virtual_list_mod.markPoolNodeRenderIncomplete(node);
        }
        fn render(node: *Node, index: usize, cx: *Cx, user_ctx: ?*anyopaque) void {
            const vctx: *VirtRenderContext(ValueT) = @ptrCast(@alignCast(user_ctx orelse return));
            if (index >= vctx.options.len) return;
            const opt = vctx.options[index];
            const t = vctx.tokens;

            // 计算当前 highlight / selected 状态
            const is_highlighted = if (vctx.state.highlight_index) |hi| hi == index else false;
            const is_selected = if (vctx.state.value) |v|
                (if (ValueT == []const u8) std.mem.eql(u8, v, opt.value) else std.meta.eql(v, opt.value))
            else
                false;

            // 设置 pool node 的样式 + click handler
            // 注：pool node 已被 VL 清过 children；这里只填新 children/style
            node.style.direction = .row;
            node.style.padding = core.Padding.symmetric(8, 12);
            node.style.justify = .space_between;
            node.style.align_items = .center;
            node.style.overflow_hidden = true;
            // height 由 VL pool 已设过；不要覆盖
            // 背景先于任何可失败步骤写：pool node 是复用的，下面 ensureExt 失败提前返回时
            // 不能把上一行的 bg_hover 留在这个 slot 上（GLM 交叉审查指出）
            node.setBackgroundRaw(if (is_highlighted or is_selected) t.color.bg_hover else Color.TRANSPARENT);
            // sweep：VL 回调是 void，OOM 下 ensureExtPanic 直接 abort；圆角是装饰，降级返回
            //（本行之后的失败也都是 catch return——半截行靠 VL 下次 refreshRange 重画，见 vl 回调重试约定）
            (node.style.ensureExtFallible(cx.allocator) catch return bail(node)).corner_radius = .{ .all = t.radius.lg };

            if (vctx.render_item) |render_item_fn| {
                // caller-provided slot — 让 caller 自己创建 child
                const ictx = ItemSlotCtx(ValueT){
                    .option = opt,
                    .index = @intCast(index),
                    .is_highlighted = is_highlighted,
                    .is_selected = is_selected,
                    .size = vctx.size,
                    .variant = vctx.variant,
                    .tokens = t,
                };
                const child = render_item_fn(ictx, cx) catch return bail(node);
                _ = core.adoptChild(cx, cx.allocator, node, child) catch return bail(node);
            } else {
                // Default: 一个 label 子节点
                const label = core.adoptChild(cx, cx.allocator, node, core.box(cx, .{
                    .width = .{ .grow = .{} },
                    .height = .{ .grow = .{} },
                }, .{}) catch return bail(node)) catch return bail(node);
                label.setText(.{
                    .content = opt.label,
                    .color = if (opt.disabled) t.color.fg_disabled else vctx.item_slot_recipe_base_text_color,
                    .font_size = vctx.font_size,
                    .line_height = 1.2,
                });
                const check_icon = core.adoptChild(cx, cx.allocator, node, core.iconTint(cx, icons.check, t.color.accent, .{
                    .width = .{ .px = 16 },
                    .height = .{ .px = 16 },
                }) catch return bail(node)) catch return bail(node);
                check_icon.setOpacityRaw(if (is_selected) 1 else 0);
            }

            // pool node 的 click handler 用 VirtItemClickContext 关联到 vctx。
            // 第一次见这个 pool node 时 alloc 一个 click_ctx，登记到 vctx.allocated_click_ctxs
            // 让 scope dispose 时统一释放。后续 render 这个 node 时复用同一个 click_ctx。
            const existing = node.behavior.events.event_context;
            if (existing == null) {
                const click_ctx = vctx.allocator.create(VirtItemClickContext(ValueT)) catch return bail(node);
                click_ctx.* = .{ .vctx = vctx, .slot_node = node };
                vctx.allocated_click_ctxs.append(vctx.allocator, click_ctx) catch {
                    vctx.allocator.destroy(click_ctx);
                    return bail(node);
                };
                node.behavior.events.event_context = @ptrCast(click_ctx);
                node.behavior.events.on_event = virtItemClickHandlerFor(ValueT);
            }
        }
    };
    return W.render;
}

fn virtItemClickHandlerFor(comptime ValueT: type) fn (Event, ?*anyopaque) EventResult {
    const W = struct {
        fn handle(event: Event, context: ?*anyopaque) EventResult {
            const cctx: *VirtItemClickContext(ValueT) = @ptrCast(@alignCast(context orelse return .ignored));
            const vctx = cctx.vctx;
            // 反查 slot → data index via pool_bindings
            const vl = vctx.vl_state orelse return .ignored;
            var slot_idx: ?usize = null;
            for (vl.pool_nodes, 0..) |pn, i| {
                if (pn == cctx.slot_node) {
                    slot_idx = i;
                    break;
                }
            }
            const si = slot_idx orelse return .ignored;
            const data_idx = vl.pool_bindings[si] orelse return .ignored;

            switch (event) {
                .click => {
                    vctx.state.highlight_index = @intCast(data_idx);
                    _ = sm.commitSelection(ValueT, vctx.state, vctx.options);
                    vctx.is_open_signal.set(false);
                    if (vctx.on_change) |cb| cb.callback(cb.context);
                    // refresh visible 让样式更新 (selected bg 切换)
                    virtual_list_mod.refreshRange(vl, vl.prev_start, vl.prev_end);
                    // 同步 aria-activedescendant
                    updateActiveDescendant(vctx.trigger, &.{}, vl, vctx.state.highlight_index);
                    return .stop;
                },
                .mouse_enter => {
                    vctx.state.highlight_index = @intCast(data_idx);
                    virtual_list_mod.refreshRange(vl, vl.prev_start, vl.prev_end);
                    updateActiveDescendant(vctx.trigger, &.{}, vl, vctx.state.highlight_index);
                    return .handled;
                },
                else => {},
            }
            return .ignored;
        }
    };
    return W.handle;
}

/// 把当前 highlight_index 对应的 item 的 element_id 写到 trigger.a11y.active_descendant_element_id。
/// - 非虚拟化路径：直接读 item_nodes[highlight_idx].element_id_raw
/// - 虚拟化路径：扫 pool_bindings 找匹配 slot；若 highlight 不在可见区间则 active_descendant 置 NULL
/// - highlight_index == null（关闭 / Esc 重置）→ 置 NULL
/// markRenderDirty trigger 节点让 a11y projection 这一帧重发 (dirty flag → router →
/// NSAccessibilitySelectedChildrenChanged)
fn updateActiveDescendant(
    trigger: *Node,
    item_nodes: []*Node,
    vl_state: ?*virtual_list_mod.VirtualListState,
    highlight_index: ?u32,
) void {
    const new_raw: u32 = blk: {
        const hi = highlight_index orelse break :blk 0xFFFFFFFF;
        if (vl_state) |vl| {
            for (vl.pool_bindings, 0..) |b, slot| {
                if (b) |bound| {
                    if (bound == hi) {
                        break :blk vl.pool_nodes[slot].element_id_raw;
                    }
                }
            }
            break :blk 0xFFFFFFFF;
        }
        if (hi >= item_nodes.len) break :blk 0xFFFFFFFF;
        break :blk item_nodes[hi].element_id_raw;
    };
    if (trigger.behavior.interaction.a11y) |*a11y| {
        if (a11y.active_descendant_element_id == new_raw) return;
        a11y.active_descendant_element_id = new_raw;
    } else {
        trigger.behavior.interaction.a11y = .{ .active_descendant_element_id = new_raw };
    }
    trigger.markRenderDirty();
}

/// 应用 highlight 视觉：highlighted item bg = bg_hover；selected item bg = bg_active；其余 transparent
fn applyItemStyles(comptime ValueT: type, ctx: *KeyContext(ValueT)) void {
    // 不管哪个分支，都要写 trigger.a11y.active_descendant_element_id
    // (custom_item_render / virtualize / 默认) — 字段层 wire-up，与视觉路径正交
    defer updateActiveDescendant(ctx.trigger, ctx.item_nodes, ctx.vl_state, ctx.state.highlight_index);

    // 当 caller 用 render_item slot 自定义渲染时，mount 不要回写 background。
    // 让 caller 自己决定如何可视化 highlight / selected (典型做法是读 state.highlight_index
    // / state.value 后用 reactive 手动 setStyle)。
    if (ctx.custom_item_render) return;
    // virtualize 模式下 item_nodes 是空 slice，走 VL refreshRange 让
    // pool 重新调 render_fn (render_fn 自己读 state.highlight_index + value 着色)。
    if (ctx.vl_state) |vl| {
        // 先 ensureVisible 让 highlight 进入可见区间，再 refresh 全部 visible
        if (ctx.state.highlight_index) |hi| {
            virtual_list_mod.ensureVisible(vl, hi);
        }
        virtual_list_mod.refreshRange(vl, vl.prev_start, vl.prev_end);
        return;
    }
    const t = ctx.tokens;
    for (ctx.item_nodes, 0..) |n, i| {
        const idx: u32 = @intCast(i);
        const is_highlight = ctx.state.highlight_index == idx;
        const opt = ctx.options[i];
        const is_selected = if (ctx.state.value) |v|
            (if (ValueT == []const u8)
                std.mem.eql(u8, v, opt.value)
            else
                std.meta.eql(v, opt.value))
        else
            false;
        n.setBackgroundRaw(if (is_highlight or is_selected) t.color.bg_hover else Color.TRANSPARENT);
        // 默认 option 的第二个 child 是 Pvnqs 选中态 check icon。
        if (n.children.items.len > 1) {
            n.children.items[1].setOpacity(if (is_selected) 1 else 0);
        }
        n.markRenderDirty();
    }
}

/// 通用 keyboard handler — 转 KeyCode → state machine Action → step()
fn keyHandlerFor(comptime ValueT: type) fn (KeyCode, Modifiers, ?*anyopaque) EventResult {
    const Wrapper = struct {
        fn handle(key: KeyCode, _: Modifiers, context: ?*anyopaque) EventResult {
            const ctx: *KeyContext(ValueT) = @ptrCast(@alignCast(context orelse return .ignored));
            const action: ?Action = switch (key) {
                .down => .arrow_down,
                .up => .arrow_up,
                .home => .home_key,
                .end => .end_key,
                .page_up => .page_up,
                .page_down => .page_down,
                .escape => .escape,
                .@"return" => .enter,
                else => null,
            };
            const a = action orelse return .ignored;
            sm.step(ValueT, ctx.state, ctx.options, a, 0);
            // Enter 提交
            if (a == .enter) {
                _ = sm.commitSelection(ValueT, ctx.state, ctx.options);
                ctx.is_open_signal.set(false);
                if (ctx.on_change) |cb| cb.callback(cb.context);
            }
            // Escape 关闭
            if (a == .escape) ctx.is_open_signal.set(false);
            applyItemStyles(ValueT, ctx);
            return .stop;
        }
    };
    return Wrapper.handle;
}

/// 单 item click handler — 提交并关闭
fn itemClickHandlerFor(comptime ValueT: type) fn (Event, ?*anyopaque) EventResult {
    const Wrapper = struct {
        fn handle(event: Event, context: ?*anyopaque) EventResult {
            const ctx: *ItemClickContext(ValueT) = @ptrCast(@alignCast(context orelse return .ignored));
            switch (event) {
                .click => {
                    ctx.state.highlight_index = ctx.index;
                    _ = sm.commitSelection(ValueT, ctx.state, ctx.options);
                    ctx.is_open_signal.set(false);
                    var key_ctx = KeyContext(ValueT){
                        .state = ctx.state,
                        .options = ctx.options,
                        .is_open_signal = ctx.is_open_signal,
                        .item_nodes = ctx.item_nodes,
                        .tokens = ctx.tokens,
                        .on_change = ctx.on_change,
                        .trigger = ctx.trigger,
                    };
                    applyItemStyles(ValueT, &key_ctx);
                    if (ctx.on_change) |cb| cb.callback(cb.context);
                    return .stop;
                },
                .mouse_enter => {
                    ctx.state.highlight_index = ctx.index;
                    var key_ctx = KeyContext(ValueT){
                        .state = ctx.state,
                        .options = ctx.options,
                        .is_open_signal = ctx.is_open_signal,
                        .item_nodes = ctx.item_nodes,
                        .tokens = ctx.tokens,
                        .on_change = ctx.on_change,
                        .trigger = ctx.trigger,
                    };
                    applyItemStyles(ValueT, &key_ctx);
                    return .handled;
                },
                else => {},
            }
            return .ignored;
        }
    };
    return Wrapper.handle;
}

/// 渲染 slot 的上下文：每个 slot fn 收到这里的字段，可以根据交互态自定义 *Node。
pub fn TriggerSlotCtx(comptime ValueT: type) type {
    return struct {
        /// 当前选中的 label（无选中时是 placeholder）
        label_text: []const u8,
        /// 是否有选中值
        has_selection: bool,
        /// 当前 size / variant
        size: SelectSize,
        variant: SelectVariant,
        disabled: bool,
        /// 完整 tokens (caller 自取 colors)
        tokens: *const ThemeTokens,
        /// 默认尺寸 (caller 可不用，自己定)
        width: f32,
        /// 当前 state ref (caller 想做 reactive 可读 state.value / state.value_signal)
        state: *SelectState(ValueT),
    };
}

pub fn ItemSlotCtx(comptime ValueT: type) type {
    return struct {
        option: Option(ValueT),
        index: u32,
        /// 当前高亮（键盘 / hover 当前位）
        is_highlighted: bool,
        /// 当前选中
        is_selected: bool,
        size: SelectSize,
        variant: SelectVariant,
        tokens: *const ThemeTokens,
    };
}

/// mountSelectHeadless props（额外 fields，相对 sm.SelectProps）
pub fn MountProps(comptime ValueT: type) type {
    return struct {
        options: []const Option(ValueT) = &.{},
        placeholder: []const u8 = "Select...",
        width: f32 = 240,
        max_dropdown_height: f32 = 280,
        disabled: bool = false,
        /// uncontrolled 初始 value
        initial_value: ?ValueT = null,
        /// 提交回调；caller 在 callback 内读 state.value 取最终值
        on_change: ?HandlerRef = null,
        /// variant + size 用于 SelectSlotRecipe 解析
        variant: SelectVariant = .default,
        size: SelectSize = .md,
        /// slot 自定义 — null 时走默认 fallback 实现 (Phase 6 旧硬编码样式)。
        /// render_trigger: caller 提供自己的 trigger 节点（含 label 子节点)；mount 函数
        /// 不再创建 default trigger box。
        render_trigger: ?*const fn (ctx: TriggerSlotCtx(ValueT), cx: *Cx) anyerror!*Node = null,
        /// render_item: caller 自定义每个 option 行的渲染；mount 函数仍负责 click /
        /// hover event handler 接入 (在 caller 返回的 node 上挂)。
        render_item: ?*const fn (ctx: ItemSlotCtx(ValueT), cx: *Cx) anyerror!*Node = null,
        /// 开启 VirtualList 池化渲染。1k+ options 必开 (典型 60 options 以下
        /// 用默认 false 更省内存——pool overhead 不值得)。开启后:
        /// - item_nodes 在 SelectHeadlessMount 结果里返空 slice (pool 复用，不持久)
        /// - applyItemStyles 改走 refreshRange (VL 重 render 可见区间)
        /// - keyboard navigation 自动 ensureVisible 让 highlight 滚到视口
        /// - render_item slot 仍生效；mount 内部把它包到 VL render_fn 里
        virtualize: bool = false,
    };
}

/// mount headless Select with default rendering. v0.7 §2.1: 加 slot 化 +
/// recipe 接入。caller 提供 render_trigger / render_item 时走自定义路径；
/// null 时 fallback 到 default (recipe 解析后的硬编码样式)。
pub fn mountSelectHeadless(
    comptime ValueT: type,
    props: MountProps(ValueT),
    scope: *Scope,
    cx: *Cx,
) !SelectHeadlessMount(ValueT) {
    const my_scope = try scope.childScope();
    const allocator = cx.allocator;
    const t = cx.tokens;

    // recipe 解析 — 拿三 slot 的 ConditionalStyle
    const slots = SelectSlotRecipe.resolve(
        .{ .variant = props.variant, .size = props.size },
        t,
    );
    const item_h = itemHeight(props.size);
    const cm = t.control.get(props.size);

    // ── Popover 基础设施 ────────────────────────────────────────────
    var pop = try popover_mod.Popover(.{
        .position = .bottom_start,
        .trigger = if (props.disabled) .manual else .click,
        .offset = .{ .static = 4 },
        .flip = false,
        .width = props.width,
        .match_trigger_width = true,
        .constrain_width_to_viewport = true,
        .max_height = props.max_dropdown_height,
    }).mount(my_scope, cx);
    // sweep：wrapper 守到 return；失败先 dispose my_scope（hook / resource 在节点存活期 destroy）再 freeNode；
    // 下面所有子节点建好即 adopt
    errdefer cx.freeNode(pop.wrapper);
    errdefer my_scope.dispose();

    pop.wrapper.meta.ownership.meta.component_name = "SelectHeadless";

    // ── State (Scope-managed) — 提到 trigger 之前，因为 TriggerSlotCtx 需要 state ref
    const state = try my_scope.allocator.create(SelectState(ValueT));
    state.* = SelectState(ValueT).init(.{
        .options = props.options,
        .value = .{ .uncontrolled = .{ .default = props.initial_value } },
    });
    try my_scope.adoptResource(@ptrCast(state), struct {
        fn destroy(ptr: *anyopaque, alloc: Allocator) void {
            const s: *SelectState(ValueT) = @ptrCast(@alignCast(ptr));
            alloc.destroy(s);
        }
    }.destroy);

    // ── Trigger ───────────────────────────────────────────────────
    // 默认 trigger 的 label 文字：选中时显示对应 option.label，否则 placeholder
    const initial_label_text = blk: {
        if (props.initial_value) |v| {
            for (props.options) |opt| {
                const matches = if (ValueT == []const u8)
                    std.mem.eql(u8, opt.value, v)
                else
                    std.meta.eql(opt.value, v);
                if (matches) break :blk opt.label;
            }
        }
        break :blk props.placeholder;
    };

    var trigger_label: *Node = undefined;
    if (props.render_trigger) |render_trigger_fn| {
        // caller-provided trigger slot
        const tctx = TriggerSlotCtx(ValueT){
            .label_text = initial_label_text,
            .has_selection = props.initial_value != null,
            .size = props.size,
            .variant = props.variant,
            .disabled = props.disabled,
            .tokens = t,
            .width = props.width,
            .state = state,
        };
        // popover 已建 default trigger box，把 caller 的 trigger 作为 child 挂进去
        // (这样 popover 的 click event handler 仍生效，因为它挂在 pop.trigger 上)
        const custom_trigger = try core.adoptChild(cx, allocator, pop.trigger, try render_trigger_fn(tctx, cx));
        // trigger_label fallback 到 custom_trigger（caller 内部应自己持有 label）
        trigger_label = custom_trigger;
    } else {
        // Default trigger：与 Input / Select / DatePicker 同一个 ControlShell(.field)。
        // content_slot = 标签（grow，可收缩），append_slot = chevron；几何来自 recipe，
        // 外框高度 = padding_y × 2 + 行高。颜色仍取本组件 recipe 的 trigger slot。
        const trigger_resolved = slots.trigger.resolve(.{});
        pop.trigger.style.width = .{ .px = props.width };
        pop.trigger.style.height = .{ .fit = .{} };
        const shell = try control_shell.controlShell(.{
            .size = props.size,
            .variant = .field,
            .disabled = props.disabled,
            .style = .{
                .width = .{ .grow = .{} },
                .background = trigger_resolved.background orelse t.color.bg_primary,
                .border = .{ .width = 1, .color = t.color.input_border, .radius = cm.radius },
            },
            .interactive = false,
            .focus_ring = false,
            .cursor = if (props.disabled) .not_allowed else .pointer,
        }, my_scope, cx);
        cx.freeNode(shell.icon_slot); // 默认 trigger 无前导图标；游离节点直接回收
        var append_slot_detached = true;
        errdefer if (append_slot_detached) cx.freeNode(shell.append_slot);
        const shell_node = try core.adoptChild(cx, allocator, pop.trigger, shell.node);

        trigger_label = shell.content_slot;
        trigger_label.style.width = .{ .grow = .{ .min = 0 } };
        trigger_label.style.flex_shrink = 1;
        trigger_label.style.overflow_hidden = true;
        trigger_label.setText(.{
            .content = initial_label_text,
            .color = if (props.initial_value == null)
                t.color.fg_disabled
            else
                (trigger_resolved.text_color orelse t.color.fg_primary),
            .font_size = cm.font_size,
            .line_height = cm.line_height,
        });
        _ = try core.adoptChild(cx, allocator, shell.append_slot, try core.iconTint(cx, icons.chevron_down, if (props.initial_value == null)
            t.color.fg_tertiary
        else
            t.color.fg_secondary, .{
            .width = .{ .px = cm.icon_size },
            .height = .{ .px = cm.icon_size },
        }));
        append_slot_detached = false;
        _ = try core.adoptChild(cx, allocator, shell_node, shell.append_slot);
    }

    // trigger a11y — combobox + has_popup=listbox + 初始无 active_descendant
    pop.trigger.behavior.interaction.a11y = .{
        .role = .combobox,
        .has_popup = .listbox,
        .disabled = props.disabled,
        .active_descendant_element_id = 0xFFFFFFFF,
    };

    // ── Items ─────────────────────────────────────────────────────
    // Content panel — recipe 解析后的 content slot 颜色
    const content_resolved = slots.content.resolve(.{});
    pop.content.style.direction = .column;
    pop.content.style.gap = 2;
    pop.content.style.padding = core.Padding.all(4);
    pop.content.setBackgroundRaw(content_resolved.background orelse t.color.bg_primary);
    const panel_radius = selectPanelRadius(t);
    pop.content.style.border = .{ .width = 1, .color = t.color.border, .radius = panel_radius };
    const content_ext = try pop.content.style.ensureExtFallible(allocator);
    content_ext.corner_radius = .{ .all = panel_radius };
    content_ext.setShadow(select_panel_shadow);
    content_ext.hit_shape = .{ .rounded_rect = panel_radius };
    content_ext.clip_shape = .{ .rounded_rect = panel_radius };

    var item_nodes: []*Node = &.{};
    var vl_state: ?*virtual_list_mod.VirtualListState = null;

    if (props.virtualize) {
        // 走 VirtualList — pool 复用，1k+ options 不爆 Node 数
        // VL context: render_fn / click handler 通过 user_context 拿到状态
        const VirtCtx = VirtRenderContext(ValueT);
        const vctx = try my_scope.allocator.create(VirtCtx);
        vctx.* = .{
            .state = state,
            .options = props.options,
            .is_open_signal = pop.is_open,
            .cx = cx,
            .tokens = t,
            .on_change = props.on_change,
            .size = props.size,
            .variant = props.variant,
            .item_h = item_h,
            .font_size = cm.font_size,
            .item_slot_recipe_base_text_color = (slots.item.resolve(.{}).text_color orelse t.color.fg_primary),
            .render_item = props.render_item,
            .vl_state = null, // 下一行赋值
            .allocator = my_scope.allocator,
            .trigger = pop.trigger,
        };
        try my_scope.adoptResource(@ptrCast(vctx), struct {
            fn destroy(ptr: *anyopaque, alloc: Allocator) void {
                const c: *VirtCtx = @ptrCast(@alignCast(ptr));
                // 释放 render_fn 分配的所有 click_ctx
                for (c.allocated_click_ctxs.items) |click_ctx| {
                    alloc.destroy(click_ctx);
                }
                c.allocated_click_ctxs.deinit(alloc);
                alloc.destroy(c);
            }
        }.destroy);

        // 用 VirtualList mountWithContext，render fn = virtRenderItem(ValueT)
        const vl_result = try virtual_list_mod.VirtualList(.{
            .item_count = props.options.len,
            .item_height = item_h,
            .width = props.width,
            .height = props.max_dropdown_height,
            .overscan = 5,
        }).mountWithContext(my_scope, cx, @ptrCast(vctx), null, virtRenderItemFn(ValueT));
        // VL 自己的 container 挂到 content
        _ = try core.adoptChild(cx, allocator, pop.content, vl_result.container);
        vctx.vl_state = vl_result.state;
        vl_state = vl_result.state;
        // item_nodes 留空 slice；caller 不能依赖
    } else {
        // 非虚拟化路径 (现有行为) — 每 option 一个 persistent Node
        const ItemNodesHolder = struct { nodes: []*Node };
        const holder = try my_scope.allocator.create(ItemNodesHolder);
        {
            errdefer my_scope.allocator.destroy(holder);
            holder.* = .{ .nodes = try my_scope.allocator.alloc(*Node, props.options.len) };
        }
        item_nodes = holder.nodes;
        try my_scope.adoptResource(@ptrCast(holder), struct {
            fn destroy(ptr: *anyopaque, alloc: Allocator) void {
                const h: *ItemNodesHolder = @ptrCast(@alignCast(ptr));
                alloc.free(h.nodes);
                alloc.destroy(h);
            }
        }.destroy);

        const ClickCtxHolder = struct { ctxs: []ItemClickContext(ValueT) };
        const click_holder = try my_scope.allocator.create(ClickCtxHolder);
        {
            errdefer my_scope.allocator.destroy(click_holder);
            click_holder.* = .{ .ctxs = try my_scope.allocator.alloc(ItemClickContext(ValueT), props.options.len) };
        }
        const click_ctxs = click_holder.ctxs;
        try my_scope.adoptResource(@ptrCast(click_holder), struct {
            fn destroy(ptr: *anyopaque, alloc: Allocator) void {
                const h: *ClickCtxHolder = @ptrCast(@alignCast(ptr));
                alloc.free(h.ctxs);
                alloc.destroy(h);
            }
        }.destroy);

        for (props.options, 0..) |opt, i| {
            var item: *Node = undefined;
            if (props.render_item) |render_item_fn| {
                const ictx = ItemSlotCtx(ValueT){
                    .option = opt,
                    .index = @intCast(i),
                    .is_highlighted = false,
                    .is_selected = blk: {
                        if (props.initial_value) |v| {
                            if (ValueT == []const u8) break :blk std.mem.eql(u8, opt.value, v);
                            break :blk std.meta.eql(opt.value, v);
                        }
                        break :blk false;
                    },
                    .size = props.size,
                    .variant = props.variant,
                    .tokens = t,
                };
                item = try core.adoptChild(cx, allocator, pop.content, try render_item_fn(ictx, cx));
            } else {
                const item_base = slots.item.resolve(.{});
                item = try core.adoptChild(cx, allocator, pop.content, try core.box(cx, .{
                    .direction = .row,
                    .width = .{ .grow = .{} },
                    .height = .{ .px = item_h },
                    .padding = core.Padding.symmetric(8, 12),
                    .justify = .space_between,
                    .align_items = .center,
                    .overflow_hidden = true,
                    .corner_radius = t.radius.lg,
                }, .{}));
                const label = try core.adoptChild(cx, allocator, item, try core.box(cx, .{
                    .width = .{ .grow = .{} },
                    .height = .{ .fit = .{} },
                }, .{}));
                label.setText(.{
                    .content = opt.label,
                    .color = if (opt.disabled)
                        t.color.fg_disabled
                    else
                        (item_base.text_color orelse t.color.fg_primary),
                    .font_size = cm.font_size,
                    .line_height = 1.2,
                });
                const is_selected = if (props.initial_value) |v|
                    (if (ValueT == []const u8) std.mem.eql(u8, opt.value, v) else std.meta.eql(opt.value, v))
                else
                    false;
                if (is_selected) item.setBackgroundRaw(t.color.bg_hover);
                const check_icon = try core.adoptChild(cx, allocator, item, try core.iconTint(cx, icons.check, t.color.accent, .{
                    .width = .{ .px = 16 },
                    .height = .{ .px = 16 },
                }));
                check_icon.setOpacityRaw(if (is_selected) 1 else 0);
            }
            item_nodes[i] = item;

            click_ctxs[i] = .{
                .state = state,
                .options = props.options,
                .index = @intCast(i),
                .is_open_signal = pop.is_open,
                .item_nodes = item_nodes,
                .cx = cx,
                .tokens = t,
                .on_change = props.on_change,
                .custom_item_render = props.render_item != null,
                .trigger = pop.trigger,
            };
            item.behavior.events.event_context = @ptrCast(&click_ctxs[i]);
            item.behavior.events.on_event = itemClickHandlerFor(ValueT);
        }
    }

    // ── Keyboard：挂在 content panel 上 ─────────────────────────
    const key_ctx = try my_scope.allocator.create(KeyContext(ValueT));
    key_ctx.* = .{
        .state = state,
        .options = props.options,
        .is_open_signal = pop.is_open,
        .item_nodes = item_nodes,
        .tokens = t,
        .on_change = props.on_change,
        .custom_item_render = props.render_item != null,
        .vl_state = vl_state,
        .trigger = pop.trigger,
    };
    try my_scope.adoptResource(@ptrCast(key_ctx), struct {
        fn destroy(ptr: *anyopaque, alloc: Allocator) void {
            const k: *KeyContext(ValueT) = @ptrCast(@alignCast(ptr));
            alloc.destroy(k);
        }
    }.destroy);
    pop.content.behavior.events.event_context = @ptrCast(key_ctx);
    pop.content.behavior.events.on_key_down = keyHandlerFor(ValueT);

    return .{
        .wrapper = pop.wrapper,
        .trigger = pop.trigger,
        .trigger_label = trigger_label,
        .content = pop.content,
        .is_open = pop.is_open,
        .state = state,
        .item_nodes = item_nodes,
        .vl_state = vl_state,
    };
}

// ============================================================================
// Tests
// ============================================================================

test "mountSelectHeadless: compiles for ValueT = i32" {
    // Compile-time instantiation check; full mount needs a real Cx + scope
    // which is tested in components/ integration tests. Here just verify
    // the function instantiates for common ValueT.
    _ = mountSelectHeadless;
    const F = @TypeOf(mountSelectHeadless);
    _ = F;
}

test "MountProps default" {
    const P = MountProps(i32);
    const p = P{};
    try std.testing.expectEqualStrings("Select...", p.placeholder);
    try std.testing.expect(p.options.len == 0);
}

test "mountSelectHeadless: Pvnqs trigger panel and option geometry" {
    const testing = std.testing;
    var cx = try Cx.init(testing.allocator);
    defer cx.deinit();
    const root = try core.box(cx, .{
        .width = .{ .px = 600 },
        .height = .{ .px = 400 },
    }, .{});
    cx.root = root;
    const scope = try Scope.init(testing.allocator, null, cx.owner);
    defer scope.dispose();

    const options = [_]Option(i32){
        .{ .value = 1, .label = "Option 1" },
        .{ .value = 2, .label = "Option 2" },
    };
    const mounted = try mountSelectHeadless(i32, .{
        .options = &options,
        .initial_value = 2,
        .size = .md,
    }, scope, cx);
    try root.appendChild(testing.allocator, mounted.wrapper);

    // 外框 = pop.trigger 下的 ControlShell 节点；高度由 padding_y×2 + 行高 fit 撑出。
    cx.layout();
    const cm = cx.tokens.control.get(.md);
    try testing.expectEqual(@as(usize, 1), mounted.trigger.children.items.len);
    const frame = mounted.trigger.children.items[0];
    try testing.expectApproxEqAbs(@as(f32, 32), frame.rectFromWorldOrFallback().h, 0.01);
    try testing.expectEqual(cm.padding_y, frame.style.padding.top);
    try testing.expectEqual(cm.padding_h, frame.style.padding.left);
    try testing.expectEqual(cm.radius, frame.style.border.radius);
    try testing.expectEqual(@as(usize, 2), frame.children.items.len); // content_slot + append_slot

    try testing.expectEqual(@as(f32, 2), mounted.content.style.gap);
    try testing.expectEqual(@as(f32, 4), mounted.content.style.padding.top);
    try testing.expectEqual(@as(f32, 4), mounted.content.style.padding.left);
    try testing.expectEqual(@as(f32, 8), mounted.content.style.border.radius);
    try testing.expectEqual(@as(usize, 1), mounted.content.style.shadowSlice().len);
    try testing.expectEqual(@as(f32, 12), mounted.content.style.shadowSlice()[0].blur);
    try testing.expectEqual(@as(f32, 4), mounted.content.style.shadowSlice()[0].offset_y);

    for (mounted.item_nodes) |item| {
        try testing.expectEqual(@as(f32, 36), item.style.height.px);
        try testing.expectEqual(@as(f32, 8), item.style.padding.top);
        try testing.expectEqual(@as(f32, 12), item.style.padding.left);
        try testing.expectEqual(@as(f32, 6), item.style.corner_radius().?.resolve());
        try testing.expect(item.style.overflow_hidden);
        try testing.expectEqual(@as(usize, 2), item.children.items.len);
    }
    try testing.expectEqual(@as(f32, 0), mounted.item_nodes[0].children.items[1].getOpacity());
    try testing.expectEqual(@as(f32, 1), mounted.item_nodes[1].children.items[1].getOpacity());
    try testing.expect(mounted.item_nodes[1].getBackground().eql(cx.tokens.color.bg_hover));
}

// 剩余未接 sweep 的组件（markdown render / form_field / select_headless）。
const sweep_options = [_]Option(i32){ .{ .value = 1, .label = "Option 1" }, .{ .value = 2, .label = "Option 2" } };
test "select_headless: mount 在任意分配点失败时不泄漏（sweep）" {
    const sw = @import("../oom_sweep.zig");
    try sw.sweepMount("select_headless", struct {
        fn m(scope: *sw.Scope, cx: *sw.Cx) anyerror!?*sw.Node {
            return (try mountSelectHeadless(i32, .{ .options = &sweep_options, .initial_value = 2, .size = .md }, scope, cx)).wrapper;
        }
    }.m);
}

test "select_headless(virtualize): mount 在任意分配点失败时不泄漏（sweep）" {
    const sw = @import("../oom_sweep.zig");
    try sw.sweepMount("select_headless(virtualize)", struct {
        fn m(scope: *sw.Scope, cx: *sw.Cx) anyerror!?*sw.Node {
            return (try mountSelectHeadless(i32, .{ .options = &sweep_options, .initial_value = 2, .virtualize = true }, scope, cx)).wrapper;
        }
    }.m);
}

test "mountSelectHeadless(virtualize): VL 回调中途 OOM 后留痕重试，下一趟整行画全" {
    var failing = testing_alloc_ns.FailingAllocator.init(testing_alloc_ns.allocator, .{});
    const a = failing.allocator();
    var cx = try Cx.init(a);
    defer cx.deinit();
    const root = try core.box(cx, .{ .width = .{ .px = 600 }, .height = .{ .px = 400 } }, .{});
    cx.root = root;
    const scope = try Scope.init(a, null, cx.owner);
    defer scope.dispose();
    const mounted = try mountSelectHeadless(i32, .{ .options = &sweep_options, .virtualize = true }, scope, cx);
    try root.appendChild(a, mounted.wrapper);
    const vl = mounted.vl_state.?;
    // 重画 index 0，让回调里的第一次分配（label box）失败：修复前 `catch return` 留下 0 子节点的半截行、
    // rebind 不标、没人再画；现在回调经 markPoolNodeRenderIncomplete 留痕，该 slot 解绑
    failing.fail_index = failing.alloc_index;
    virtual_list_mod.refreshRange(vl, 0, 1);
    failing.fail_index = std.math.maxInt(usize);
    try testing_alloc_ns.expect(failing.has_induced_failure);
    try testing_alloc_ns.expect(vl.rebind_incomplete);
    for (vl.pool_bindings) |b| try testing_alloc_ns.expect(b != 0);
    // 下一趟：重新取 slot、回调成功 → label + check 两个子节点
    vl.updateVisibleItems();
    try testing_alloc_ns.expect(!vl.rebind_incomplete);
    var found = false;
    for (vl.pool_bindings, 0..) |b, slot| {
        if (b == 0) {
            found = true;
            try testing_alloc_ns.expectEqual(@as(usize, 2), vl.pool_nodes[slot].children.items.len);
        }
    }
    try testing_alloc_ns.expect(found);
}
const testing_alloc_ns = std.testing;

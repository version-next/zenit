/// OverlayStack — 全局浮层管理器
///
/// 三个框架级原语合一:
/// 1. OverlayStack — z-index 自动分配 + 层栈管理
/// 2. DismissLayer — 统一 Escape / outside-click / focus-out 关闭
/// 3. ExitTransition — 退出动画的延迟销毁（Phase 2 实现）
///
/// 设计参考:
/// - CSS Top Layer 的 FIFO 语义（后打开的在上面）
/// - Radix DismissableLayer 的栈式关闭
/// - GPUI 的 deferred() + anchored() + occlude() 三原语
/// - React Stack 的 z-index 自动分配（Math.max(value, parent) + 1）
const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core.zig");
const Node = core.Node;
const box = core.box;
const Color = core.Color;
const ComputedRect = core.ComputedRect;
const Signal = core.Signal;
const A11yProps = core.A11yProps;
const NodeHandle = core.NodeHandle;
const Scope = @import("reactive.zig").Scope;
const overlay_transition = @import("overlay_transition.zig");
const overlay_layer_refs = @import("overlay_layer_refs.zig");
// Cx 拆分：Transition / TransitionController 析出到 overlay_transition.zig
//（进度时钟 + 曲线表，可脱离层栈单测）。此处 re-export 维持
// `overlay_stack_mod.Transition` 等既有引用路径（popover/sheet/modal 都用）。
pub const Transition = overlay_transition.Transition;
pub const TransitionController = overlay_transition.TransitionController;
// 这三个原来是本文件私有 fn（无外部调用者），保持私有，不扩大 API 面。
const transitionAffectsOpacity = overlay_transition.transitionAffectsOpacity;
const transitionAffectsTransform = overlay_transition.transitionAffectsTransform;
const layerNeedsCompositedGroup = overlay_transition.layerNeedsCompositedGroup;
// Cx 拆分：trigger/anchor 的代次化弱引用 + 存活校验析出到
// overlay_layer_refs.zig（悬垂指针不变量在那里用测试钉住）。
// 注意：不能 `const trackNode = overlay_layer_refs.trackNode`——同名方法挂在
// OverlayStack 上（注入 node_registry 后写回 layer 字段），顶层再起同名别名
// 会在 self.trackNode(...) 解析里产生遮蔽歧义。统一走命名空间访问。
const render_engine = @import("core/render_engine/mod.zig");

fn overlayDebugEnabled() bool {
    return std.posix.getenv("ZENIT_POPOVER_DEBUG") != null;
}

fn outsideClickDebugEnabled() bool {
    return std.posix.getenv("ZENIT_DEBUG_OUTSIDE_CLICK") != null;
}

fn nodeTestId(node: ?*Node) []const u8 {
    return if (node) |n| n.meta.ownership.meta.test_id orelse "(nil)" else "(nil)";
}

fn logOutsideClickLayer(prefix: []const u8, layer: *const OverlayLayer, target: ?*Node) void {
    if (!outsideClickDebugEnabled()) return;
    std.debug.print(
        "[overlay.outside] {s} handle={d} state={s} suspended={} skip={} dismiss={s} target={s} trigger_handle={d} content={s} content_hit_test_visible={}\n",
        .{
            prefix,
            layer.handle.id,
            @tagName(layer.state),
            layer.suspended,
            layer.skip_outside_click_frame,
            @tagName(layer.config.dismiss.outside_click),
            nodeTestId(target),
            if (layer.trigger_handle) |handle| handle.id else 0,
            nodeTestId(layer.content_node),
            layer.config.content_hit_test_visible,
        },
    );
}
const floating = @import("compute_position.zig");

// ========== 公共类型 ==========

/// 层句柄（push 返回，用于后续操作）
pub const LayerHandle = struct {
    id: u32,
    z_index: i16,
};

/// 层类型
pub const LayerKind = enum {
    /// 全屏遮罩，焦点陷阱，Escape 关闭
    modal,
    /// 无遮罩，外部可交互，outside-click 关闭
    non_modal,
    /// 无交互阻断，定时消失
    toast,
};

/// 语义层级 tier —— 系统级 z-index manager 的基线表。
///
/// 参考 zui Stack 的 STACKING_DEFAULT_ORDER（OVERLAY < POPOVER < DIALOG）与
/// React Stack 的嵌套继承语义：每层实际 z = max(tier 基线 + 同 tier 内
/// activation 序号, 嵌套父层 z + 2)。tier 决定"类别间"的恒定关系
/// （tooltip 永远压过 toast/dialog/popover，无论打开顺序）；activation 序号
/// 决定"同类别内"后开在上；嵌套继承保证"从弹层里再开的弹层"永远压过宿主层
/// （modal 里开 popover：popover tier 基线 100 < dialog 1000，但继承后
/// ≥ dialog z + 2）。
///
/// 基线间隔 ≥ 1000：同 tier 内每层占 2 个 z（barrier+content），32 层封顶
/// 也到不了下一 tier。devtools overlay 固定 32000，恒在所有 tier 之上。
pub const StackTier = enum {
    /// popover / menu / dropdown / select 等锚定浮层
    overlay,
    /// modal / sheet 等带 barrier 的对话层
    dialog,
    /// toast 通知
    toast,
    /// tooltip —— 纯提示，永远最上
    tooltip,

    pub fn base(self: StackTier) i16 {
        return switch (self) {
            .overlay => 100,
            .dialog => 1000,
            .toast => 2000,
            .tooltip => 3000,
        };
    }

    /// kind → 默认 tier（组件不显式传 tier 时的推导）
    pub fn fromKind(kind: LayerKind) StackTier {
        return switch (kind) {
            .modal => .dialog,
            .toast => .toast,
            .non_modal => .overlay,
        };
    }
};

/// 层状态
pub const LayerState = enum {
    entering,
    visible,
    exiting,
};

/// 外部点击行为
pub const OutsideClickBehavior = enum {
    /// 不关闭
    none,
    /// 只通知 on_dismiss，让组件自行决定如何退场
    notify,
    /// 关闭，事件继续传播
    close,
    /// 关闭并消费事件
    close_and_consume,
};

/// 关闭行为配置
pub const DismissConfig = struct {
    outside_click: OutsideClickBehavior = .close,
    escape: bool = true,
    focus_out: bool = false,
};

/// 遮罩配置
pub const BarrierConfig = union(enum) {
    none,
    color: Color,
};

/// 焦点配置
pub const FocusConfig = struct {
    trap: bool = false,
    auto_focus: bool = true,
    restore: bool = true,
};

/// Hover 触发配置
pub const HoverConfig = struct {
    leave_delay_ms: f32 = 100,
};

/// 层配置（传给 push）
pub const LayerConfig = struct {
    kind: LayerKind,
    dismiss: DismissConfig = .{},
    enter_transition: Transition = .scale_fade,
    exit_transition: Transition = .scale_fade,
    focus: FocusConfig = .{},
    barrier: BarrierConfig = .none,
    on_dismiss: ?*Signal(bool) = null,
    trigger_node: ?*Node = null,
    group: ?[]const u8 = null,
    hover: ?HoverConfig = null,
    /// 入场延迟（ms）：层 push/reactivate 后先按 progress=0（不可见）持有这么久，
    /// 再开始 enter_transition。用于 hover tooltip 的 display delay——期间移开
    /// 指针会直接退场（beginExit 从当前 enter progress 起播，0 → 立即消失）。
    /// 仅对 enter_transition != .none 的层生效。
    enter_delay_ms: f32 = 0,
    a11y: A11yProps = .{},
    barrier_blocks_hover: bool = true,
    content_hit_test_visible: bool = true,
    z_index: ?i16 = null,
    /// 语义 tier；null = 按 kind 推导（modal→dialog / toast→toast / non_modal→overlay）。
    /// z_index 显式覆盖时 tier 不参与计算。
    tier: ?StackTier = null,
};

// ========== TransitionController ==========
// 已析出到 overlay_transition.zig（头部 re-export 维持旧路径）。

/// 层实例
pub const OverlayLayer = struct {
    handle: LayerHandle,
    config: LayerConfig,
    state: LayerState,
    z_index_override: ?i16 = null,
    activation_order: u64 = 0,
    skip_outside_click_frame: bool = false,
    enter_paused: bool = false,
    content_node: ?*Node = null,
    barrier_node: ?*Node = null,
    previous_focus: ?NodeHandle = null,
    scope_pushed: bool = false,
    enter_ctrl: TransitionController = TransitionController.init(.none, .entering),
    exit_ctrl: TransitionController = TransitionController.init(.none, .exiting),
    trigger_node: ?*Node = null,
    trigger_handle: ?NodeHandle = null,
    anchor: ?AnchorConfig = null,
    anchor_target_handle: ?NodeHandle = null,
    enter_last_content_rect: ?ComputedRect = null,
    enter_stable_frame_count: u8 = 0,
    /// 层已关闭但未销毁（scope 仍存活），可通过 resume() 恢复
    suspended: bool = false,
};

/// overlay() 工厂函数的返回值
pub const OverlayResult = struct {
    handle: LayerHandle,
    barrier: ?*Node,
    content: *Node,
    /// true = barrier 已被自动挂到 portal（cx.ensurePopoverPortalRoot()），caller 不应再
    /// appendChild。false = 没有 barrier，或 cx.root == null 的纯单元测试场景：caller 仍需
    /// 把返回的 overlay 节点 append 到自己的树里 —— 这种 inline 挂载受祖先裁剪。
    portaled: bool = false,
};

// ========== OverlayStack ==========

pub const OverlayStack = struct {
    /// 32 → 256（2026-08-22）：suspended 的 Tooltip/Popover 从 mount 起就
    /// 占槽（下游编辑器实测：app chrome ~15 层 + 一个 md 编辑器 ~16 层 ≈ 32，
    /// 第二个编辑器一挂 push 即 TooManyLayers，文件隔一个打不开）。层数随
    /// 挂载的 UI 组件数增长而非交互深度，32 太小；彻底去限（ArrayList 化）
    /// 与 focus scope 的同类改造一起留给后续。逐槽遍历是 null check，
    /// 256 槽的每帧代价可忽略。
    const MAX_LAYERS = 256;

    layers: [MAX_LAYERS]?OverlayLayer = [_]?OverlayLayer{null} ** MAX_LAYERS,
    /// hasActiveAnimations 的代际 memo：任何可能改变层状态的入口 bump
    /// anim_gen（bumpAnimGen），查询命中同代直接返回。单线程 UI 假设。
    anim_gen: u64 = 1,
    anim_memo_gen: u64 = 0,
    anim_memo_result: bool = false,
    // Include the full capacity (256), not just the highest slot index (255).
    layer_count: usize = 0,
    next_z: i16 = 100,
    next_id: u32 = 1,
    next_activation_order: u64 = 1,
    /// commitExit 时若 layer 配了 focus.restore，把 previous_focus 排到这里，
    /// 由 Cx（持有 focus_manager）在帧内 drain。
    ///
    /// 为什么要绕这一道：OverlayStack 拿不到 cx，而恢复焦点必须走
    /// focus_manager。此前 previous_focus **写了但全仓无人读** ——
    /// 于是关闭 Modal/Sheet 后焦点直接丢失而不是回到触发它的控件。
    pending_focus_restore: ?NodeHandle = null,
    node_registry: ?*core.NodeRegistry = null,

    inline fn bumpAnimGen(self: *OverlayStack) void {
        self.anim_gen +%= 1;
    }

    pub fn setRegistry(self: *OverlayStack, registry: *core.NodeRegistry) void {
        self.node_registry = registry;
    }

    /// 注册新层，分配 z-index
    pub fn push(self: *OverlayStack, config: LayerConfig) !LayerHandle {
        self.bumpAnimGen();
        if (self.layer_count >= MAX_LAYERS) {
            if (std.posix.getenv("ZENIT_DEBUG_OVERLAY") != null) {
                std.debug.print("[overlay-dbg] push FAIL count={d}\n", .{self.layer_count});
                for (&self.layers, 0..) |*slot, i| {
                    if (slot.*) |*layer| {
                        const cname = if (layer.content_node) |cn| (cn.meta.ownership.meta.component_name orelse "?") else "null";
                        std.debug.print("  [{d}] kind={s} state={s} suspended={} content={s}\n", .{
                            i, @tagName(layer.config.kind), @tagName(layer.state), layer.suspended, cname,
                        });
                    }
                }
            }
            return error.TooManyLayers;
        }

        // 互斥组：同 group 的 non_modal 层自动关闭
        if (config.group) |group| {
            for (&self.layers) |*slot| {
                if (slot.*) |*layer| {
                    if (!layer.suspended and layer.state != .exiting and layer.config.kind != .modal) {
                        if (layer.config.group) |eg| {
                            if (std.mem.eql(u8, eg, group)) {
                                self.beginExit(layer.handle);
                            }
                        }
                    }
                }
            }
        }

        const z = config.z_index orelse self.next_z;
        if (config.z_index) |_| {
            self.next_z = @max(self.next_z, z +| 2);
        } else {
            self.next_z +|= 2; // barrier + content 各占一个
        }
        const handle = LayerHandle{
            .id = self.next_id,
            .z_index = z,
        };
        self.next_id += 1;

        // 找空位
        const slot = self.findEmptySlot() orelse return error.TooManyLayers;
        const enter_transition = config.enter_transition;
        const initial_state: LayerState = if (enter_transition == .none) .visible else .entering;
        var stored_config = config;
        stored_config.trigger_node = null;
        self.layers[slot] = OverlayLayer{
            .handle = handle,
            .config = stored_config,
            .state = initial_state,
            .z_index_override = config.z_index,
            .activation_order = self.allocateActivationOrder(),
            .enter_ctrl = TransitionController.initWithTime(enter_transition, .entering, render_engine.current_frame_time_ms),
            .exit_ctrl = TransitionController.initWithTime(config.exit_transition, .exiting, render_engine.current_frame_time_ms),
            .trigger_node = config.trigger_node,
            .trigger_handle = self.trackNode(config.trigger_node),
        };
        self.layers[slot].?.enter_ctrl.delay_remaining_ms = config.enter_delay_ms;
        self.layer_count += 1;

        return handle;
    }

    /// 绑定 overlay 层的真实内容节点。
    /// 适用于两类场景：
    /// - Popover/Tooltip/Toast 这类直接 push() 的 floating content
    /// - Modal/Sheet 这类通过 barrier 挂载、但动画实际应作用在 dialog/panel 上的内容节点
    pub fn bindContentNode(self: *OverlayStack, allocator: Allocator, handle: LayerHandle, content_node: *Node) void {
        if (self.findLayer(handle)) |layer| {
            layer.content_node = content_node;
            const ext = content_node.style.ensureExtPanic(allocator);
            // CA-pure revamp P6.1（settle 帧 children-drop 根因已修——paint-order 不变式
            // + 缓存自包含化后，non_modal 也统一走 composited_group surface：整组
            // scale+opacity fade 语义正确（不再逐 primitive 内联调制互透）、文本不逐帧
            // 重栅格。单一 CA 矩阵合成（surface_draw_transform = owner_world·T(src)）。
            ext.composited_group = true;
            // content（dialog/panel）必须显式拿 pointer hit role —— 否则点 dialog 的空白
            // 区域/纯文本（无 on_click）时 hit-test 穿透到 barrier 甚至背后 ScrollArea，
            // outside-click 误判"点在 content 外" → 关闭。给 pointer role 后，点 content
            // 内任意处都命中 content 子树（isDescendantOf(content)=true）→ 不关闭；内部
            // 按钮（× / 菜单项）更深，仍优先命中并触发自身 handler。
            // 逐 role 覆盖：只加 pointer，scroll/inspect 沿用推导默认值
            // （content 若本身是 scroll owner 仍保留 scroll；devtools 仍能选中它）。
            ext.hit_roles = .{ .pointer = true };
            syncLayerHitTestVisibility(layer);
            self.syncAllLayerVisualOrder();
        }
    }

    /// 兼容 helper：保留给无 barrier 的 floating overlay 调用。
    pub fn bindFloatingContent(self: *OverlayStack, allocator: Allocator, handle: LayerHandle, content_node: *Node) void {
        self.bindContentNode(allocator, handle, content_node);
    }

    /// 开始退出：启动退场动画（如果有），动画完成后 tick() 中自动 commitExit。
    /// 注意：on_dismiss Signal 在 commitExit 中触发（退场动画完成后），
    /// 避免 Effect 在动画播放前就把节点缩成 0×0。
    pub fn beginExit(self: *OverlayStack, handle: LayerHandle) void {
        self.bumpAnimGen();
        if (self.findLayer(handle)) |layer| {
            logOutsideClickLayer("begin-exit-request", layer, null);
            if (layer.state == .exiting) return;
            if (layer.suspended) return;

            // 无退场动画 → 立即提交（commitExit 中触发 sig.set(false)）
            if (layer.config.exit_transition == .none) {
                self.commitExit(handle);
                return;
            }

            // 有退场动画 → 进入 exiting 状态，等 tick() 驱动完成
            const was_entering = layer.state == .entering;
            layer.state = .exiting;
            layer.exit_ctrl = TransitionController.initWithTime(layer.config.exit_transition, .exiting, render_engine.current_frame_time_ms);
            // enter 中途（含 enter_delay 持有期，progress 仍为 0）就离开：
            // exit 从当前 enter progress 起播，不从 1.0 全量闪现。
            if (was_entering) layer.exit_ctrl.seedFromProgress(layer.enter_ctrl.progress);
            syncLayerHitTestVisibility(layer);
            logOutsideClickLayer("begin-exit-applied", layer, null);
        }
    }

    /// 退场完成后：隐藏节点 + 挂起层（不从栈移除，可通过 resume 恢复）
    pub fn commitExit(self: *OverlayStack, handle: LayerHandle) void {
        self.bumpAnimGen();
        const idx = self.findLayerIndex(handle) orelse return;
        if (self.layers[idx]) |*layer| {
            if (layer.suspended) return; // 已经挂起

            // Signal 回调可同步 dispose scope、removePermanently 并释放节点。
            // 先快照指针，所有 layer/node 写操作完成后再把它作为最后一步触发。
            const dismiss_signal = layer.config.on_dismiss;

            // 隐藏节点
            if (layer.barrier_node) |barrier| {
                // 有 barrier 的层（Modal/Sheet）：隐藏 barrier 即可，content 在 barrier 内部
                barrier.style.width = .{ .px = 0 };
                barrier.style.height = .{ .px = 0 };
                barrier.style.overflow_hidden = true;
                setManualTransitionFlags(barrier, layer.config.enter_transition, false);
                setManualTransitionFlags(barrier, layer.config.exit_transition, false);
                barrier.markLayoutDirty();
            } else if (layer.content_node) |content| {
                // 无 barrier 的 floating overlay（Popover/Tooltip/Menu/Picker）需要保留
                // 可测量几何，避免 reopen 的第一个可见帧还在经历 0x0 -> full-size 的补布局。
                // 对这类 absolute overlay，关闭时只隐藏视觉和命中，不再压成 0x0。
                content.setOpacityRaw(0);
                content.style.overflow_hidden = false;
                setManualTransitionFlags(content, layer.config.enter_transition, false);
                setManualTransitionFlags(content, layer.config.exit_transition, false);
                // suspend 必须**保住** prewarm 的 descendant render caches（reopen 首帧
                // 直接复用），故不可用 markCompositePropDirty（含 invalidateRenderCache）；
                // opacity 走 anim-frame 组合 + overflow_hidden 变更标 render。
                content.markCompositeAnimFrameDirty();
                content.markRenderDirty();
            }

            // 焦点恢复：把 previous_focus 排给 Cx 处理（见 pending_focus_restore）。
            if (layer.config.focus.restore) {
                if (layer.previous_focus) |prev| {
                    self.pending_focus_restore = prev;
                    layer.previous_focus = null;
                }
            }

            layer.scope_pushed = false;
            layer.suspended = true;
            layer.state = .visible; // 重置状态，方便 resume 时从正确状态开始
            syncLayerHitTestVisibility(layer);
            if (dismiss_signal) |sig| sig.set(false);
        }
    }

    /// scope dispose 时真正永久移除层（仅在 cleanup 回调中调用）
    pub fn removePermanently(self: *OverlayStack, handle: LayerHandle) void {
        self.bumpAnimGen();
        const idx = self.findLayerIndex(handle) orelse return;
        self.layers[idx] = null;
        if (self.layer_count > 0) self.layer_count -= 1;
        if (self.layer_count == 0) self.next_z = 100;
        self.syncAllLayerVisualOrder();
    }

    /// 恢复挂起的层（重新打开时由组件 Effect 调用）
    pub fn reactivate(self: *OverlayStack, handle: LayerHandle) void {
        self.bumpAnimGen();
        if (self.findLayer(handle)) |layer| {
            if (!layer.suspended) return;
            layer.suspended = false;
            layer.activation_order = self.allocateActivationOrder();
            layer.skip_outside_click_frame = true;
            layer.enter_paused = false;
            layer.enter_last_content_rect = null;
            layer.enter_stable_frame_count = 0;

            // 重新激活时不要递归清空整棵浮层子树缓存。
            // 预热隐藏态的目的就是保住完整内容和字形 atlas，让首个可见帧直接复用。
            // 如果这里把 descendants cache 全清掉，Popover/Select/DatePicker 会重新走
            // 冷启动渲染路径，首帧又退化成壳体先出、内容下一帧补齐。
            //
            // reopen 真正需要的是重新进入 composite / interaction 流程；若组件自身在
            // 打开前改了尺寸或内容，它们已经会通过 sizing/render dirty 精确失效。
            if (layer.content_node) |content| {
                setManualTransitionFlags(content, layer.config.enter_transition, layer.config.enter_transition != .none);
                content.markCompositeAnimFrameDirty();
            }
            if (layer.barrier_node) |barrier| {
                setManualTransitionFlags(barrier, layer.config.enter_transition, layer.config.enter_transition != .none);
                barrier.markCompositeAnimFrameDirty();
            }

            if (layer.config.enter_transition != .none) {
                layer.state = .entering;
                layer.enter_ctrl = TransitionController.initWithTime(layer.config.enter_transition, .entering, render_engine.current_frame_time_ms);
                layer.enter_ctrl.delay_remaining_ms = layer.config.enter_delay_ms;
            } else {
                layer.state = .visible;
            }
            syncLayerHitTestVisibility(layer);
            self.syncAllLayerVisualOrder();
            logOutsideClickLayer("reactivate", layer, null);
        }
    }

    pub fn setEnterPaused(self: *OverlayStack, handle: LayerHandle, paused: bool, allocator: Allocator) void {
        self.bumpAnimGen();
        if (self.findLayer(handle)) |layer| {
            if (layer.state != .entering) return;
            layer.enter_paused = paused;
            if (paused) {
                layer.enter_ctrl.progress = 0.0;
                return;
            }
            if (layer.content_node) |content| {
                setManualTransitionFlags(content, layer.config.enter_transition, true);
                layer.enter_ctrl.apply(content, allocator);
            }
            if (layer.barrier_node) |barrier| {
                setManualTransitionFlags(barrier, layer.config.enter_transition, true);
                barrier.setOpacityRaw(layer.enter_ctrl.currentOpacity());
                barrier.markCompositeAnimFrameDirty();
            }
        }
    }

    pub fn cancelExit(self: *OverlayStack, handle: LayerHandle, next_state: LayerState) void {
        self.bumpAnimGen();
        std.debug.assert(next_state != .exiting);
        if (self.findLayer(handle)) |layer| {
            if (layer.state != .exiting) return;
            if (layer.suspended) return;
            layer.state = next_state;
            if (next_state == .entering) {
                layer.skip_outside_click_frame = true;
                layer.enter_ctrl = TransitionController.initWithTime(layer.config.enter_transition, .entering, render_engine.current_frame_time_ms);
                // 退场中途拉回：enter 从当前 exit progress 接着播（不重走 enter_delay，
                // 快速二次 hover 应立即出现）。
                layer.enter_ctrl.seedFromProgress(layer.exit_ctrl.progress);
            }
            syncLayerHitTestVisibility(layer);
            self.syncAllLayerVisualOrder();
        }
    }

    /// 当前最顶层（跳过 .exiting 和 .suspended 状态的）
    pub fn topmost(self: *const OverlayStack) ?*const OverlayLayer {
        var best: ?*const OverlayLayer = null;
        for (&self.layers) |*slot| {
            const layer = if (slot.*) |*l| l else continue;
            if (layer.suspended) continue;
            if (layer.state == .exiting) continue;
            if (best == null or layer.activation_order > best.?.activation_order) {
                best = layer;
            }
        }
        return best;
    }

    /// 某 handle 是否是最顶层
    pub fn isTopmost(self: *const OverlayStack, handle: LayerHandle) bool {
        if (self.topmost()) |top| {
            return top.handle.id == handle.id;
        }
        return false;
    }

    /// 统一 Escape 处理
    /// 从栈顶向下找第一个 escape=true 且非 exiting 的层，关闭它。
    /// 遇到 modal 层停止搜索（modal 阻断 Escape 向下传播）。
    /// 返回 true 表示已消费该事件。
    pub fn handleEscape(self: *OverlayStack) bool {
        self.bumpAnimGen();
        if (self.layer_count == 0) return false;

        var ordered: [MAX_LAYERS]usize = undefined;
        const count = self.collectOrderedLayerIndices(&ordered, true);

        var i = count;
        while (i > 0) {
            i -= 1;
            if (self.layers[ordered[i]]) |*layer| {
                if (layer.config.dismiss.escape) {
                    self.beginExit(layer.handle);
                    return true;
                }
                // modal 阻断 Escape 向下传播
                if (layer.config.kind == .modal) return true;
            }
        }
        return false;
    }

    /// 统一 outside-click 处理
    /// 从栈顶向下遍历，对每个 non_modal 层检查点击是否在外部。
    /// 按下那一刻命中的是哪一层（content 或 trigger 包含目标的最上层）。
    /// 渲染期的 `handleOutsideClick` 用它兜底：按下的节点可能在 click 回调里随
    /// 所在层退场被失效（引用被清空），不能因此把父层误判成「点在外面」。
    pub fn findPressOwner(self: *OverlayStack, target: ?*Node) ?LayerHandle {
        const t = target orelse return null;
        if (self.layer_count == 0) return null;
        var ordered: [MAX_LAYERS]usize = undefined;
        const count = self.collectOrderedLayerIndices(&ordered, true);
        var i = count;
        while (i > 0) {
            i -= 1;
            const layer = if (self.layers[ordered[i]]) |*l| l else continue;
            if (layer.suspended) continue;
            if (layer.content_node) |content| {
                if (t.isDescendantOf(content)) return layer.handle;
            }
            if (self.resolveTrigger(layer)) |trig| {
                if (t.isDescendantOf(trig)) return layer.handle;
            }
        }
        return null;
    }

    pub fn handleOutsideClick(self: *OverlayStack, has_new_mouse_down: bool, last_mouse_down_target: ?*Node) void {
        self.handleOutsideClickOwned(has_new_mouse_down, last_mouse_down_target, null);
    }

    /// `press_owner`：按下时记录的所属层（见 `findPressOwner`）。遍历到它就停——
    /// 它和它下面的层都不是「外面」。
    pub fn handleOutsideClickOwned(self: *OverlayStack, has_new_mouse_down: bool, last_mouse_down_target: ?*Node, press_owner: ?LayerHandle) void {
        self.bumpAnimGen();
        if (!has_new_mouse_down) return;
        if (self.layer_count == 0) return;
        const target = last_mouse_down_target;

        var ordered: [MAX_LAYERS]usize = undefined;
        const count = self.collectOrderedLayerIndices(&ordered, true);

        // 按下所属的层已不在活动列表里（它在 click 回调里自己关了）：这一下
        // 是在它里面处理掉的，不是点在任何层外面。
        if (press_owner) |owner| {
            var present = false;
            for (ordered[0..count]) |idx| {
                if (self.layers[idx]) |*l| {
                    if (l.handle.id == owner.id) present = true;
                }
            }
            if (!present) return;
        }

        var i = count;
        while (i > 0) {
            i -= 1;
            if (self.layers[ordered[i]]) |*layer| {
                logOutsideClickLayer("inspect", layer, target);
                if (press_owner) |owner| {
                    if (layer.handle.id == owner.id) {
                        logOutsideClickLayer("press-owner-return", layer, target);
                        return;
                    }
                }
                if (layer.suspended) continue;
                if (layer.state == .exiting) continue;
                if (layer.skip_outside_click_frame) continue;

                // 点在 content 内部 → 不关闭
                if (layer.config.content_hit_test_visible) {
                    if (target) |target_node| {
                        if (layer.content_node) |content| {
                            if (target_node.isDescendantOf(content)) {
                                logOutsideClickLayer("inside-content-return", layer, target);
                                return;
                            }
                        }
                    }
                }

                // 点在 trigger 内部 → 让 trigger 自己处理
                if (target) |target_node| {
                    if (self.resolveTrigger(layer)) |trig| {
                        if (target_node.isDescendantOf(trig)) {
                            logOutsideClickLayer("inside-trigger-return", layer, target);
                            return;
                        }
                    }
                }

                // 点在 barrier 上 → dismiss 当前层，barrier 阻断
                if (target) |target_node| {
                    if (layer.barrier_node) |barrier| {
                        if (target_node.isDescendantOf(barrier)) {
                            switch (layer.config.dismiss.outside_click) {
                                .none => {},
                                .notify => {
                                    logOutsideClickLayer("barrier-notify-dismiss", layer, target);
                                    if (layer.config.on_dismiss) |sig| sig.set(false);
                                },
                                else => self.beginExit(layer.handle),
                            }
                            logOutsideClickLayer("barrier-return", layer, target);
                            return; // barrier 阻断
                        }
                    }
                }

                // 点在所有已知区域之外 → dismiss
                switch (layer.config.dismiss.outside_click) {
                    .none => {},
                    .notify => {
                        logOutsideClickLayer("notify-dismiss", layer, target);
                        if (layer.config.on_dismiss) |sig| sig.set(false);
                    },
                    else => {
                        logOutsideClickLayer("outside-begin-exit", layer, target);
                        self.beginExit(layer.handle);
                        // non_modal: 继续向下检查（可能关闭多个嵌套 popover）
                        // modal 不会到这里（barrier 已拦截）
                    },
                }
            }
        }
    }

    /// mouse-down 分发**之前**调用：若最上层活动 overlay 配置了
    /// `.close_and_consume` 且这次按下落在它的 content / trigger 之外，就关闭它并
    /// 返回 true——调用方吞掉这次按下（连同之后的抬起），点中的东西不会同时被触发。
    /// 按下落在某层 content / trigger 内部、或最上层不是 consume 型时返回 false，
    /// 照常走分发与渲染期的 `handleOutsideClick`。
    pub fn consumeOutsidePress(self: *OverlayStack, target: ?*Node) bool {
        self.bumpAnimGen();
        if (self.layer_count == 0) return false;
        var ordered: [MAX_LAYERS]usize = undefined;
        const count = self.collectOrderedLayerIndices(&ordered, true);
        var i = count;
        while (i > 0) {
            i -= 1;
            const layer = if (self.layers[ordered[i]]) |*l| l else continue;
            if (layer.suspended or layer.state == .exiting or layer.skip_outside_click_frame) continue;
            if (target) |t| {
                if (layer.config.content_hit_test_visible) {
                    if (layer.content_node) |content| {
                        if (t.isDescendantOf(content)) return false;
                    }
                }
                if (self.resolveTrigger(layer)) |trig| {
                    if (t.isDescendantOf(trig)) return false;
                }
            }
            if (layer.config.dismiss.outside_click != .close_and_consume) return false;
            logOutsideClickLayer("consume-begin-exit", layer, target);
            self.beginExit(layer.handle);
            return true;
        }
        return false;
    }

    /// 每帧布局前更新 anchor 定位。仅更新几何，不推进动画时间。
    pub fn updateAnchors(self: *OverlayStack, vp_w: f32, vp_h: f32) void {
        for (&self.layers) |*slot| {
            if (slot.*) |*layer| {
                if (layer.suspended) continue;

                // Anchor 定位（每帧更新，因为 trigger 可能移动）
                if (layer.state != .exiting) {
                    updateAnchorPosition(self, layer, vp_w, vp_h);
                }
            }
        }
    }

    /// 每帧布局后推进过渡动画。返回 true = 有活跃动画需要继续重绘。
    pub fn tickAnimations(self: *OverlayStack, now_ms: f64, dt: f32, allocator: Allocator) bool {
        self.bumpAnimGen();
        var any_animating = false;

        for (&self.layers) |*slot| {
            if (slot.*) |*layer| {
                if (layer.suspended) continue;
                defer layer.skip_outside_click_frame = false;

                switch (layer.state) {
                    .entering => {
                        if (layer.enter_paused) {
                            layer.enter_ctrl.progress = 0.0;
                            if (layer.content_node) |content| {
                                setManualTransitionFlags(content, layer.config.enter_transition, true);
                                layer.enter_ctrl.apply(content, allocator);
                            }
                            if (layer.barrier_node) |barrier| {
                                setManualTransitionFlags(barrier, layer.config.enter_transition, true);
                                barrier.setOpacityRaw(0.0);
                                barrier.markCompositeAnimFrameDirty();
                            }
                            any_animating = true;
                            continue;
                        }

                        if (holdEnterUntilGeometryStable(layer, allocator)) {
                            any_animating = true;
                            continue;
                        }

                        // 如果有 anchor 且 content 尺寸还没算好，暂停入场动画（防闪烁）
                        if (layer.anchor != null) {
                            if (layer.content_node) |content| {
                                const cr = content.rectFromWorldOrFallback();
                                if (cr.w == 0 or cr.h == 0) {
                                    content.setOpacityRaw(0);
                                    content.markCompositeAnimFrameDirty();
                                    any_animating = true;
                                    continue;
                                }
                            }
                        }

                        const done = layer.enter_ctrl.update(now_ms);
                        if (layer.content_node) |content| {
                            setManualTransitionFlags(content, layer.config.enter_transition, !done);
                            layer.enter_ctrl.apply(content, allocator);
                            if (overlayDebugEnabled() and content.meta.ownership.meta.component_name != null and std.mem.eql(u8, content.meta.ownership.meta.component_name.?, "PopoverContent")) {
                                const dr = content.rectFromWorldOrFallback();
                                std.debug.print("[overlay.enter.tick] node={d} test_id={s} dt={d:.4} progress={d:.3} done={} size=({d:.1},{d:.1}) opacity={d:.3} scale=({d:.3},{d:.3})\n", .{
                                    content.id,
                                    content.meta.ownership.meta.test_id orelse "(nil)",
                                    dt,
                                    layer.enter_ctrl.progress,
                                    done,
                                    dr.w,
                                    dr.h,
                                    content.getOpacity(),
                                    content.style.scale_x(),
                                    content.style.scale_y(),
                                });
                            }
                        }
                        if (layer.barrier_node) |barrier| {
                            setManualTransitionFlags(barrier, layer.config.enter_transition, !done);
                            barrier.setOpacityRaw(layer.enter_ctrl.currentOpacity());
                            barrier.markCompositeAnimFrameDirty();
                        }
                        if (done) {
                            layer.state = .visible;
                            // 恢复 content 的完全可见状态。
                            // 不要在这里重置 translate_x / translate_y：
                            // Popover / anchored overlay 会复用 translate_* 作为最终定位，
                            // 如果在入场动画完成帧把它们归零，会导致 panel 瞬间跳回 trigger 位置一帧。
                            if (layer.content_node) |content| {
                                content.setOpacityRaw(1.0);
                                content.markCompositeAnimFrameDirty();
                            }
                        } else {
                            any_animating = true;
                        }
                    },
                    .exiting => {
                        const done = layer.exit_ctrl.update(now_ms);
                        if (layer.content_node) |content| {
                            setManualTransitionFlags(content, layer.config.exit_transition, !done);
                            layer.exit_ctrl.apply(content, allocator);
                        }
                        if (layer.barrier_node) |barrier| {
                            setManualTransitionFlags(barrier, layer.config.exit_transition, !done);
                            barrier.setOpacityRaw(layer.exit_ctrl.currentOpacity());
                            barrier.markCompositeAnimFrameDirty();
                        }
                        if (done) {
                            // 动画完成 → 真正隐藏并移除
                            self.commitExit(layer.handle);
                            // 提交隐藏后还需要再跑一帧布局/树快照，
                            // 否则像 Sheet 这类 barrier 仍可能保留旧 rect。
                            any_animating = true;
                        } else {
                            any_animating = true;
                        }
                    },
                    .visible => {
                        if (layer.content_node) |content| {
                            setManualTransitionFlags(content, layer.config.enter_transition, false);
                            setManualTransitionFlags(content, layer.config.exit_transition, false);
                        }
                        if (layer.barrier_node) |barrier| {
                            setManualTransitionFlags(barrier, layer.config.enter_transition, false);
                            setManualTransitionFlags(barrier, layer.config.exit_transition, false);
                        }
                    },
                }
            }
        }

        return any_animating;
    }

    pub fn tick(self: *OverlayStack, now_ms: f64, dt: f32, vp_w: f32, vp_h: f32, allocator: Allocator) bool {
        self.updateAnchors(vp_w, vp_h);
        return self.tickAnimations(now_ms, dt, allocator);
    }

    pub fn hasActiveAnimations(self: *const OverlayStack) bool {
        // 本函数挂在每次唤醒判定链上（每个泵循环 × 每窗口多次），闲时是
        // 纯轮询：用代际 memo 把重复扫描降为 O(1)。所有可能改变层状态的
        // 入口（push/exit/reactivate/tick/clear/findLayer…）都 bump
        // anim_gen，memo 只可能多扫、不会陈旧。
        if (self.anim_memo_gen == self.anim_gen) return self.anim_memo_result;
        // 按引用遍历：[MAX_LAYERS]?OverlayLayer 的按值 for 会整槽拷贝
        // （每槽数百字节 × 256）。
        var result = false;
        for (&self.layers) |*slot| {
            const layer = if (slot.*) |*l| l else continue;
            if (layer.suspended) continue;
            switch (layer.state) {
                .entering, .exiting => {
                    result = true;
                    break;
                },
                .visible => {},
            }
        }
        const mut = @constCast(self);
        mut.anim_memo_gen = self.anim_gen;
        mut.anim_memo_result = result;
        return result;
    }

    /// 清空所有层
    pub fn clear(self: *OverlayStack) void {
        self.bumpAnimGen();
        for (&self.layers) |*slot| {
            slot.* = null;
        }
        self.layer_count = 0;
        self.next_z = 100;
        self.next_activation_order = 1;
    }

    /// 查找 handle 对应的层
    pub fn findLayer(self: *OverlayStack, handle: LayerHandle) ?*OverlayLayer {
        self.bumpAnimGen();
        const idx = self.findLayerIndex(handle) orelse return null;
        if (self.layers[idx]) |*layer| return layer;
        return null;
    }

    /// 根据内容节点或其任意后代，查找所属 overlay 层。
    pub fn findLayerForNode(self: *const OverlayStack, node: *Node) ?*const OverlayLayer {
        for (&self.layers) |*slot| {
            const layer = if (slot.*) |*l| l else continue;
            if (layer.content_node) |content| {
                if (node.isDescendantOf(content)) return layer;
            }
            if (layer.barrier_node) |barrier| {
                if (node.isDescendantOf(barrier)) return layer;
            }
        }
        return null;
    }

    /// 节点是否落在某个**挂起**（已关闭未销毁）层的 content / barrier 子树里。
    /// 与 findLayerForNode 不同：逐层检查而非取第一个命中——嵌套时节点可能同时
    /// 属于外层（仍打开）与内层（已挂起），任一挂起祖先层都意味着它不呈现。
    /// 只比较指针（isDescendantOf 沿节点自身父链走），不解引用层里的节点。
    pub fn isNodeInSuspendedLayer(self: *const OverlayStack, node: *Node) bool {
        for (&self.layers) |*slot| {
            const layer = if (slot.*) |*l| l else continue;
            if (!layer.suspended) continue;
            if (layer.content_node) |content| {
                if (node.isDescendantOf(content)) return true;
            }
            if (layer.barrier_node) |barrier| {
                if (node.isDescendantOf(barrier)) return true;
            }
        }
        return false;
    }

    fn findLayerIndex(self: *const OverlayStack, handle: LayerHandle) ?usize {
        for (&self.layers, 0..) |*slot, i| {
            if (slot.*) |*layer| {
                if (layer.handle.id == handle.id) return i;
            }
        }
        return null;
    }

    fn findEmptySlot(self: *const OverlayStack) ?usize {
        for (&self.layers, 0..) |*slot, i| {
            if (slot.* == null) return i;
        }
        return null;
    }

    fn allocateActivationOrder(self: *OverlayStack) u64 {
        const order = self.next_activation_order;
        self.next_activation_order +%= 1;
        if (self.next_activation_order == 0) self.next_activation_order = 1;
        return order;
    }

    fn collectOrderedLayerIndices(self: *const OverlayStack, indices: *[MAX_LAYERS]usize, only_active: bool) usize {
        var count: usize = 0;
        for (&self.layers, 0..) |*slot, idx| {
            const layer = if (slot.*) |*l| l else continue;
            if (only_active and (layer.suspended or layer.state == .exiting)) continue;

            var insert_at = count;
            while (insert_at > 0) : (insert_at -= 1) {
                const prev_idx = indices[insert_at - 1];
                const prev_layer = if (self.layers[prev_idx]) |*p| p else break;
                if (prev_layer.activation_order <= layer.activation_order) break;
                indices[insert_at] = indices[insert_at - 1];
            }
            indices[insert_at] = idx;
            count += 1;
        }
        return count;
    }

    fn layerTier(layer: *const OverlayLayer) StackTier {
        return layer.config.tier orelse StackTier.fromKind(layer.config.kind);
    }

    /// trigger/anchor 的代次化弱引用 + 存活校验：实现析出到
    /// overlay_layer_refs.zig（不变量与单测在那里）。OverlayStack 侧只留
    /// 把 node_registry 注入的这一层。
    fn trackNode(self: *OverlayStack, node: ?*Node) ?NodeHandle {
        return overlay_layer_refs.trackNode(self.node_registry, node);
    }

    fn resolveTrackedNode(self: *const OverlayStack, handle: ?NodeHandle, cached: ?*Node) ?*Node {
        return overlay_layer_refs.resolveTrackedNode(self.node_registry, handle, cached);
    }

    fn resolveTrigger(self: *const OverlayStack, layer: *const OverlayLayer) ?*Node {
        return self.resolveTrackedNode(layer.trigger_handle, layer.trigger_node);
    }

    pub fn setAnchor(self: *OverlayStack, handle: LayerHandle, anchor: ?AnchorConfig) void {
        const target_handle = if (anchor) |value| self.trackNode(value.target) else null;
        const layer = self.findLayer(handle) orelse return;
        layer.anchor = anchor;
        layer.anchor_target_handle = target_handle;
    }

    /// 嵌套继承：本层 trigger 落在哪个已排层的 content 子树里 → 取其中最高的
    /// 已算出 z。ordered[0..upto] 是 activation 序在前的层（父层必先于子层打开，
    /// 故单趟即可收敛）。
    fn nestedParentZ(self: *const OverlayStack, trigger: *Node, ordered: []const usize, computed: *const [MAX_LAYERS]i16, upto: usize) ?i16 {
        var best: ?i16 = null;
        for (ordered[0..upto]) |idx| {
            const parent = &(self.layers[idx].?);
            const content = parent.content_node orelse continue;
            const inside = trigger.isDescendantOf(content) or
                if (parent.barrier_node) |b| trigger.isDescendantOf(b) else false;
            if (!inside) continue;
            if (best == null or computed[idx] > best.?) best = computed[idx];
        }
        return best;
    }

    fn syncAllLayerVisualOrder(self: *OverlayStack) void {
        var ordered: [MAX_LAYERS]usize = undefined;
        const count = self.collectOrderedLayerIndices(&ordered, false);
        // 每层实际 z = max(tier 基线 + 同 tier 序号*2, 嵌套父层 z + 2)。
        // 显式 z_index_override 完全绕过 tier/继承（caller 自己负责）。
        var computed: [MAX_LAYERS]i16 = [_]i16{0} ** MAX_LAYERS;
        var tier_seq = [_]i16{0} ** @typeInfo(StackTier).@"enum".fields.len;
        // CSS Top Layer FIFO：dialog 至少压过此前所有活动的 overlay/dialog 层。
        // 光靠 trigger 嵌套继承不够 —— Modal 没有 trigger_node（从 popover 里
        // 打开的 modal 拿不到嵌套父），tier 序号又可能与被继承抬高的 popover
        // 打平，层序退化成 DOM 挂载序。tooltip/toast tier 不参与（tooltip 恒顶
        // 语义不能被后开的 modal 压掉）。
        var active_max_below_toast: i16 = 0;
        for (ordered[0..count], 0..) |idx, pos| {
            if (self.layers[idx]) |*layer| {
                const base_z = layer.z_index_override orelse blk: {
                    const tier = layerTier(layer);
                    const seq = &tier_seq[@intFromEnum(tier)];
                    var z = tier.base() +| seq.* * 2;
                    seq.* += 1;
                    if (self.resolveTrigger(layer)) |trigger| {
                        if (self.nestedParentZ(trigger, ordered[0..count], &computed, pos)) |pz| {
                            z = @max(z, pz +| 2);
                        }
                    }
                    if (tier == .dialog) z = @max(z, active_max_below_toast +| 2);
                    break :blk z;
                };
                computed[idx] = base_z;
                const tier_for_max = layerTier(layer);
                const layer_active = !layer.suspended and layer.state != .exiting;
                if (layer_active and layer.z_index_override == null and
                    (tier_for_max == .overlay or tier_for_max == .dialog))
                {
                    active_max_below_toast = @max(active_max_below_toast, base_z +| 1);
                }
                if (layer.barrier_node) |barrier| {
                    writeNodeZIndex(barrier, base_z);
                    if (layer.content_node) |content| {
                        writeNodeZIndex(content, base_z + 1);
                    }
                } else if (layer.content_node) |content| {
                    writeNodeZIndex(content, base_z);
                }
            }
        }
    }

    fn syncLayerHitTestVisibility(layer: *OverlayLayer) void {
        const visible = !layer.suspended and layer.state != .exiting;
        if (layer.barrier_node) |barrier| {
            barrier.setHitTestVisible(visible);
        }
        if (layer.content_node) |content| {
            content.setHitTestVisible(visible and layer.config.content_hit_test_visible);
        }
    }
};

fn approxRectEq(a: ComputedRect, b: ComputedRect) bool {
    return std.math.approxEqAbs(f32, a.x, b.x, 0.25) and
        std.math.approxEqAbs(f32, a.y, b.y, 0.25) and
        std.math.approxEqAbs(f32, a.w, b.w, 0.25) and
        std.math.approxEqAbs(f32, a.h, b.h, 0.25);
}

fn holdEnterUntilGeometryStable(layer: *OverlayLayer, allocator: Allocator) bool {
    const content = layer.content_node orelse return false;
    if (layer.state != .entering) return false;
    if (layer.enter_paused) return true;

    const rect = content.rectFromWorldOrFallback();
    if (rect.w <= 0.1 or rect.h <= 0.1) {
        layer.enter_last_content_rect = rect;
        layer.enter_stable_frame_count = 0;
        setManualTransitionFlags(content, layer.config.enter_transition, true);
        layer.enter_ctrl.apply(content, allocator);
        return true;
    }

    const layout_unstable = content.frame_state.state_bits.dirty.core.layout or content.frame_state.state_bits.dirty.core.subtree_layout;
    const rect_changed = if (layer.enter_last_content_rect) |prev| !approxRectEq(prev, rect) else true;
    layer.enter_last_content_rect = rect;

    if (layout_unstable or rect_changed) {
        layer.enter_stable_frame_count = 0;
        // Re-anchor the transition clock so frozen frames don't get paid back
        // as a large jump on the next visible frame.
        layer.enter_ctrl.last_tick_time_ms = render_engine.current_frame_time_ms;
        setManualTransitionFlags(content, layer.config.enter_transition, true);
        layer.enter_ctrl.apply(content, allocator);
        if (layer.barrier_node) |barrier| {
            setManualTransitionFlags(barrier, layer.config.enter_transition, true);
            barrier.setOpacityRaw(layer.enter_ctrl.currentOpacity());
            barrier.markCompositeAnimFrameDirty();
        }
        return true;
    }

    if (layer.enter_stable_frame_count < 2) {
        layer.enter_stable_frame_count += 1;
        layer.enter_ctrl.last_tick_time_ms = render_engine.current_frame_time_ms;
        setManualTransitionFlags(content, layer.config.enter_transition, true);
        layer.enter_ctrl.apply(content, allocator);
        if (layer.barrier_node) |barrier| {
            setManualTransitionFlags(barrier, layer.config.enter_transition, true);
            barrier.setOpacityRaw(layer.enter_ctrl.currentOpacity());
            barrier.markCompositeAnimFrameDirty();
        }
        return true;
    }

    return false;
}

// transitionAffectsOpacity / transitionAffectsTransform / layerNeedsCompositedGroup
// 已析出到 overlay_transition.zig（头部 re-export）。

fn setManualTransitionFlags(node: *Node, transition: Transition, active: bool) void {
    const next_opacity = active and transitionAffectsOpacity(transition);
    const next_transform = active and transitionAffectsTransform(transition);
    if (node.frame_state.state_bits.flags.manual_opacity_animation_active == next_opacity and node.frame_state.state_bits.flags.manual_transform_animation_active == next_transform) return;
    const opacity_completed = node.frame_state.state_bits.flags.manual_opacity_animation_active and !next_opacity;
    const transform_completed = node.frame_state.state_bits.flags.manual_transform_animation_active and !next_transform;
    node.frame_state.state_bits.flags.manual_opacity_animation_active = next_opacity;
    node.frame_state.state_bits.flags.manual_transform_animation_active = next_transform;
    if (opacity_completed or transform_completed) {
        node.requestCompositeAnimationLinger(opacity_completed, transform_completed);
    }
    node.markCompositeDirty();
}

// ========== 工厂函数 ==========

/// 创建一个 overlay 层
pub fn overlay(scope: *Scope, cx: *core.Cx, config: LayerConfig) !OverlayResult {
    const handle = try cx.overlay_stack.push(config);
    errdefer cx.overlay_stack.removePermanently(handle);
    const allocator = cx.allocator;
    const t = cx.tokens;

    // barrier 节点（modal 类型才有）
    var barrier_node: ?*Node = null;
    errdefer if (barrier_node) |barrier| cx.freeNode(barrier);
    if (config.barrier != .none) {
        const color = switch (config.barrier) {
            .color => |c| c,
            .none => unreachable,
        };
        barrier_node = try box(cx, .{
            .position = .absolute,
            .width = .{ .grow = .{} },
            .height = .{ .grow = .{} },
            .background = color,
            .justify = .center,
            .align_items = .center,
        }, .{});
        const b_ext = try barrier_node.?.style.ensureExtFallible(allocator);
        b_ext.z_index = handle.z_index;
        // barrier 必须显式拿 pointer hit role：空 box 默认 pointer=false（无 handler），
        // 那样 modal backdrop 点击会**穿透**到下面的 ScrollArea/内容，hit-test 命中错误
        // 节点 → outside-click 逻辑判"点在所有已知区域外" → 误关闭。给 pointer role 后
        // backdrop 拦截所有点击（modal 语义：阻断与背后内容交互），点空白处 dismiss。
        b_ext.hit_roles = .{ .pointer = true };
        // P6.2：barrier 不再 avoid_opacity_layer——settle children-drop 与缓存自包含
        // 修复后，嵌套 surface（barrier surface 内含 dialog surface）由引擎通用规则
        // 正确处理；fade 期间引擎按 opacity<0.999 自动开 surface，rest 时无 surface 开销。
    }

    // content 节点
    const content_node = try box(cx, .{
        .position = .absolute,
        .direction = .column,
        .background = t.color.bg_secondary,
    }, .{});
    errdefer cx.freeNode(content_node);
    (try content_node.style.ensureExtFallible(allocator)).z_index = handle.z_index +| 1;

    // 焦点管理
    if (config.focus.trap) {
        content_node.setFocusScope(.{
            .trap = true,
            .auto_focus = config.focus.auto_focus,
        });
    }

    // a11y
    if (config.a11y.role != .none) {
        content_node.behavior.interaction.a11y = config.a11y;
    }

    // Portal 契约（方案 §6 步骤 1）：有 barrier 的层（Modal/Sheet）与 Popover 一致，
    // 总是经 cx.ensurePopoverPortalRoot() 取 portal（standalone Cx 下在 root 下补建），
    // 不再有"portal 为空就交给 caller inline append"的分支。唯一保留的回退是
    // cx.root == null 的纯单元测试场景：此时 caller 自己 append，**inline 回退受祖先
    // 裁剪**（z_index 不会让它逃出 overflow_hidden 祖先）。
    // 在登记 cleanup 之前取 portal 并预留容量，后面的 appendChild 才不可失败。
    var barrier_portal: ?*Node = null;
    if (barrier_node != null) {
        barrier_portal = cx.ensurePopoverPortalRoot() catch |err| switch (err) {
            error.RootUnavailable => null,
            else => return err,
        };
        if (barrier_portal) |portal| try portal.children.ensureUnusedCapacity(allocator, 1);
    }

    // Scope cleanup: scope dispose 时自动从 stack 移除，并释放孤立节点
    const cleanup_ctx = try scope.allocator.create(CleanupContext);
    errdefer scope.allocator.destroy(cleanup_ctx);
    cleanup_ctx.* = .{ .handle = handle, .cx = cx, .content_node = content_node, .barrier_node = barrier_node };
    try scope.registerResource(@ptrCast(cleanup_ctx), struct {
        fn cleanup(ptr: *anyopaque, alloc: Allocator) void {
            const ctx: *CleanupContext = @ptrCast(@alignCast(ptr));
            ctx.cx.overlay_stack.removePermanently(ctx.handle);
            // portal 化的 barrier 挂在 portal root（非 caller 子树），不会被 Show 卸载
            // story 子树时连带释放 —— 这里主动从 portal 摘下并释放，避免残留。
            if (ctx.barrier_portaled) {
                if (ctx.barrier_node) |n| {
                    if (n.parent) |p| p.removeChild(n);
                    ctx.cx.freeDetachedNodeAfterScopeDispose(n);
                }
            }
            // 释放没有被加入 UI 树的孤立节点（无 parent 说明不在树中，freeNode 不会覆盖到）
            if (ctx.content_node) |n| {
                if (n.parent == null) ctx.cx.freeDetachedNodeAfterScopeDispose(n);
            }
            if (ctx.barrier_node) |n| {
                if (!ctx.barrier_portaled and n.parent == null) ctx.cx.freeDetachedNodeAfterScopeDispose(n);
            }
            alloc.destroy(ctx);
        }
    }.cleanup);

    // 更新 layer 的节点引用
    if (cx.overlay_stack.findLayer(handle)) |layer| {
        layer.content_node = content_node;
        layer.barrier_node = barrier_node;
        if (config.focus.restore) {
            layer.previous_focus = cx.focus_manager.current_focus_handle;
        }
        OverlayStack.syncLayerHitTestVisibility(layer);
    }
    cx.overlay_stack.syncAllLayerVisualOrder();

    // Portal 化：有 barrier 的层（Modal/Sheet）把 barrier 挂到 portal（覆盖整窗口的
    // containing block），而非留给 caller 内联 append。这样 barrier 的 absolute
    // grow/grow 解析到整个窗口，dialog 才能真正全屏遮罩+居中。
    var portaled = false;
    if (barrier_node) |barrier| {
        if (barrier_portal) |portal| {
            portal.appendChild(allocator, barrier) catch unreachable;
            portaled = true;
            cleanup_ctx.barrier_portaled = true;
        }
    }

    return .{
        .handle = handle,
        .barrier = barrier_node,
        .content = content_node,
        .portaled = portaled,
    };
}

const CleanupContext = struct {
    handle: LayerHandle,
    cx: *core.Cx,
    content_node: ?*Node = null,
    barrier_node: ?*Node = null,
    /// barrier 被挂到了 portal root（非 caller 子树）。scope dispose 时必须主动从
    /// portal 摘下并释放，否则 portal 里会残留已卸载 story 的 modal 节点。
    barrier_portaled: bool = false,
};

// ========== Anchor 定位 ==========

pub const PopoverPosition = floating.Placement;

/// Anchor 配置（浮动层锚定到触发节点）
pub const AnchorConfig = struct {
    target: *Node,
    placement: PopoverPosition = .bottom_start,
    offset: f32 = 4,
    flip: bool = true,
    shift: bool = true,
};

/// 对有 anchor 的层执行定位计算（在 tick 中调用）
fn updateAnchorPosition(self: *const OverlayStack, layer: *OverlayLayer, vp_w: f32, vp_h: f32) void {
    const anchor = layer.anchor orelse return;
    const content = layer.content_node orelse return;
    const target = self.resolveTrackedNode(layer.anchor_target_handle, anchor.target) orelse return;

    const target_rect = target.rectFromWorldOrFallback();
    const content_rect = content.rectFromWorldOrFallback();
    const tw = target_rect.w;
    const th = target_rect.h;
    const pw = content_rect.w;
    const ph = content_rect.h;

    // 尺寸还没 layout 好，跳过
    if (pw == 0 or ph == 0) return;

    const trigger_global = target.globalRect();
    const trig_x = trigger_global.x;
    const trig_y = trigger_global.y;

    var middleware_buf: [3]floating.Middleware = undefined;
    var middleware_count: usize = 0;
    middleware_buf[middleware_count] = .{ .offset = .{ .main_axis = .{ .static = anchor.offset } } };
    middleware_count += 1;
    if (anchor.flip) {
        middleware_buf[middleware_count] = .{ .flip = .{} };
        middleware_count += 1;
    }
    if (anchor.shift) {
        middleware_buf[middleware_count] = .{ .shift = .{} };
        middleware_count += 1;
    }

    const positioned = floating.computePosition(
        floating.Rect.init(trig_x, trig_y, tw, th),
        floating.Rect.init(0, 0, pw, ph),
        floating.Rect.init(0, 0, vp_w, vp_h),
        .{
            .placement = anchor.placement,
            .middleware = middleware_buf[0..middleware_count],
        },
    );

    const new_tx = positioned.x - trig_x;
    const new_ty = positioned.y - trig_y;
    if (@abs(content.style.translate_x - new_tx) < 0.01 and @abs(content.style.translate_y - new_ty) < 0.01) return;
    content.style.translate_x = new_tx;
    content.style.translate_y = new_ty;
    // 权威失效组合：只 markInteractionDirty 会让 prebuilt payload 按旧位置 replay
    //（与 popover setPopoverTranslate 修过的是同类 bug）。注：当前无组件走
    // layer.anchor 通用锚定（全走 popover before_render 路径），此处是防未来启用时复雷。
    content.markCompositePropDirty();
}

// ========== 辅助函数 ==========

fn writeNodeZIndex(node: *Node, z_index: i16) void {
    if (node.style.ext) |ext| {
        if (ext.z_index == z_index) return;
        ext.z_index = z_index;
        node.markInteractionDirty();
        node.markRenderDirty();
    }
}

// ========== 测试 ==========

test "OverlayStack: push and z-index monotonic" {
    var stack = OverlayStack{};

    const h1 = try stack.push(.{ .kind = .modal });
    const h2 = try stack.push(.{ .kind = .non_modal });
    const h3 = try stack.push(.{ .kind = .non_modal });

    try std.testing.expect(h2.z_index > h1.z_index);
    try std.testing.expect(h3.z_index > h2.z_index);
    try std.testing.expectEqual(@as(u8, 3), stack.layer_count);
}

test "OverlayStack: stale trigger and anchor pointers require live handles" {
    const allocator = std.testing.allocator;
    var registry = core.NodeRegistry.init(allocator);
    defer registry.deinit();
    var stack = OverlayStack{};
    stack.setRegistry(&registry);

    const node = try Node.create(allocator, 92_001, .button, .{});
    defer node.destroy(allocator);
    try registry.rebuild(node);
    const handle = try stack.push(.{ .kind = .non_modal, .trigger_node = node });
    stack.setAnchor(handle, .{ .target = node });
    const layer = stack.findLayer(handle).?;
    try std.testing.expect(stack.resolveTrigger(layer) == node);
    try std.testing.expect(stack.resolveTrackedNode(layer.anchor_target_handle, layer.anchor.?.target) == node);

    registry.unregisterSubtree(node);
    try std.testing.expectEqual(@as(?*Node, null), stack.resolveTrigger(layer));
    try std.testing.expectEqual(@as(?*Node, null), stack.resolveTrackedNode(layer.anchor_target_handle, layer.anchor.?.target));
}

test "OverlayStack: commitExit tolerates synchronous dismiss disposal" {
    const allocator = std.testing.allocator;
    const owner = try core.SignalOwner.init(allocator);
    defer owner.deinit();
    const visible = try Signal(bool).create(owner, true);
    const content = try Node.create(allocator, 92_002, .box, .{});
    var content_alive = true;
    defer if (content_alive) content.destroy(allocator);

    var stack = OverlayStack{};
    const handle = try stack.push(.{
        .kind = .non_modal,
        .exit_transition = .none,
        .on_dismiss = visible,
    });
    stack.bindContentNode(allocator, handle, content);

    try @import("reactive.zig").createEffect(owner, .{
        .visible = visible,
        .stack = &stack,
        .handle = handle,
        .content = content,
        .content_alive = &content_alive,
        .allocator = allocator,
    }, struct {
        fn run(ctx: anytype) void {
            if (ctx.visible.get() or !ctx.content_alive.*) return;
            ctx.stack.removePermanently(ctx.handle);
            ctx.content.destroy(ctx.allocator);
            ctx.content_alive.* = false;
        }
    }.run);

    stack.commitExit(handle);
    try std.testing.expect(!content_alive);
    try std.testing.expectEqual(@as(u8, 0), stack.layer_count);
}

test "OverlayStack: exhausted z-index saturates and resets without trapping" {
    var stack = OverlayStack{};
    stack.next_z = std.math.maxInt(i16) - 1;

    const high = try stack.push(.{ .kind = .non_modal });
    try std.testing.expectEqual(@as(i16, std.math.maxInt(i16) - 1), high.z_index);
    try std.testing.expectEqual(std.math.maxInt(i16), stack.next_z);
    stack.removePermanently(high);
    try std.testing.expectEqual(@as(i16, 100), stack.next_z);

    const explicit = try stack.push(.{ .kind = .modal, .z_index = std.math.maxInt(i16) });
    try std.testing.expectEqual(std.math.maxInt(i16), explicit.z_index);
    try std.testing.expectEqual(std.math.maxInt(i16), stack.next_z);
}

test "OverlayStack: bindFloatingContent updates layer and visual z-index" {
    const allocator = std.testing.allocator;
    var stack = OverlayStack{};

    const handle = try stack.push(.{ .kind = .non_modal, .enter_transition = .none, .exit_transition = .none });
    const content = try Node.create(allocator, 1, .box, .{ .width = .{ .px = 40 }, .height = .{ .px = 24 } });
    defer content.destroy(allocator);

    stack.bindFloatingContent(allocator, handle, content);

    const layer = stack.findLayer(handle) orelse return error.TestUnexpectedResult;
    try std.testing.expect(layer.content_node == content);
    try std.testing.expectEqual(handle.z_index, content.style.z_index());
    try std.testing.expect(content.frame_state.state_bits.flags.hit_test_visible);
}

test "OverlayStack: beginExit with no exit transition suspends layer" {
    var stack = OverlayStack{};

    const h1 = try stack.push(.{ .kind = .non_modal, .exit_transition = .none });
    try std.testing.expectEqual(@as(u8, 1), stack.layer_count);

    stack.beginExit(h1);
    try std.testing.expectEqual(@as(u8, 1), stack.layer_count);
    if (stack.findLayer(h1)) |layer| {
        try std.testing.expect(layer.suspended);
    } else {
        return error.TestUnexpectedResult;
    }
}

test "OverlayStack: handleEscape closes topmost" {
    var stack = OverlayStack{};

    _ = try stack.push(.{ .kind = .modal, .dismiss = .{ .escape = true } });
    const h2 = try stack.push(.{ .kind = .non_modal, .dismiss = .{ .escape = true } });
    try std.testing.expectEqual(@as(u8, 2), stack.layer_count);

    // Escape 只关闭栈顶
    const consumed = stack.handleEscape();
    try std.testing.expect(consumed);
    try std.testing.expectEqual(@as(u8, 2), stack.layer_count);

    // h2 进入退场动画状态（默认 exit_transition = .scale_fade）
    if (stack.findLayer(h2)) |layer| {
        try std.testing.expectEqual(LayerState.exiting, layer.state);
    } else {
        return error.TestUnexpectedResult;
    }
}

test "OverlayStack: handleEscape blocked by modal" {
    var stack = OverlayStack{};

    _ = try stack.push(.{ .kind = .non_modal, .dismiss = .{ .escape = true } });
    _ = try stack.push(.{ .kind = .modal, .dismiss = .{ .escape = false } });
    try std.testing.expectEqual(@as(u8, 2), stack.layer_count);

    // modal 的 escape=false 但 modal 本身阻断传播
    const consumed = stack.handleEscape();
    try std.testing.expect(consumed); // modal 阻断
    try std.testing.expectEqual(@as(u8, 2), stack.layer_count); // 没有层被关闭
}

test "OverlayStack: isTopmost" {
    var stack = OverlayStack{};

    const h1 = try stack.push(.{ .kind = .modal });
    try std.testing.expect(stack.isTopmost(h1));

    const h2 = try stack.push(.{ .kind = .non_modal });
    try std.testing.expect(!stack.isTopmost(h1));
    try std.testing.expect(stack.isTopmost(h2));
}

test "OverlayStack: mutual exclusion group" {
    var stack = OverlayStack{};

    const h1 = try stack.push(.{ .kind = .non_modal, .group = "menu" });
    try std.testing.expectEqual(@as(u8, 1), stack.layer_count);
    try std.testing.expect(stack.findLayer(h1) != null);

    // 同组的 non_modal 互斥
    const h2 = try stack.push(.{ .kind = .non_modal, .group = "menu" });
    _ = h2;
    // h1 进入退场动画状态（默认 exit_transition = .scale_fade）
    if (stack.findLayer(h1)) |layer| {
        try std.testing.expectEqual(LayerState.exiting, layer.state);
    } else {
        return error.TestUnexpectedResult;
    }
    try std.testing.expectEqual(@as(u8, 2), stack.layer_count);
}

// TransitionController 的 5 个单测已随实现移到 overlay_transition.zig
//（fade enter / fade exit / none is instant / enter delay / seedFromProgress）。

test "OverlayStack: beginExit with exit transition stays in exiting state" {
    var stack = OverlayStack{};
    var test_time: f64 = 0;

    const h1 = try stack.push(.{
        .kind = .non_modal,
        .exit_transition = .fade,
        .enter_transition = .none, // 立即可见
    });
    try std.testing.expectEqual(@as(u8, 1), stack.layer_count);

    // beginExit 不会立即移除（有退场动画）
    stack.beginExit(h1);
    try std.testing.expectEqual(@as(u8, 1), stack.layer_count); // 仍在栈中
    if (stack.findLayer(h1)) |layer| {
        try std.testing.expectEqual(LayerState.exiting, layer.state);
    } else {
        return error.TestUnexpectedResult;
    }

    // tick 推进动画直到完成
    var ticks: u32 = 0;
    while (stack.findLayer(h1) != null and ticks < 100) : (ticks += 1) {
        test_time += 16.0;
        render_engine.current_frame_time_ms = test_time;
        _ = stack.tick(test_time, 0.016, 1920, 1080, std.testing.allocator); // ~60fps
    }
    // 动画完成后应被挂起
    if (stack.findLayer(h1)) |layer| {
        try std.testing.expect(layer.suspended);
    } else {
        return error.TestUnexpectedResult;
    }
    try std.testing.expectEqual(@as(u8, 1), stack.layer_count);
}

test "OverlayStack: reactivate promotes reopened layer to topmost and updates z-order" {
    const allocator = std.testing.allocator;
    var stack = OverlayStack{};

    const h1 = try stack.push(.{ .kind = .non_modal, .enter_transition = .none, .exit_transition = .none });
    const h2 = try stack.push(.{ .kind = .non_modal, .enter_transition = .none, .exit_transition = .none });
    const n1 = try Node.create(allocator, 1, .box, .{ .width = .{ .px = 40 }, .height = .{ .px = 20 } });
    const n2 = try Node.create(allocator, 2, .box, .{ .width = .{ .px = 40 }, .height = .{ .px = 20 } });
    defer n1.destroy(allocator);
    defer n2.destroy(allocator);

    stack.bindFloatingContent(allocator, h1, n1);
    stack.bindFloatingContent(allocator, h2, n2);
    try std.testing.expect(stack.isTopmost(h2));
    try std.testing.expect(n2.style.z_index() > n1.style.z_index());

    stack.commitExit(h1);
    try std.testing.expect(!n1.frame_state.state_bits.flags.hit_test_visible);
    stack.reactivate(h1);

    try std.testing.expect(stack.isTopmost(h1));
    try std.testing.expect(n1.style.z_index() > n2.style.z_index());
    try std.testing.expect(n1.frame_state.state_bits.flags.hit_test_visible);
}

test "OverlayStack: tooltip tier 恒在 dialog 之上（无关打开顺序）" {
    const allocator = std.testing.allocator;
    var stack = OverlayStack{};

    // tooltip 先开、dialog 后开：纯 activation 序会把 dialog 排上面，tier 基线必须赢。
    const tip = try stack.push(.{ .kind = .non_modal, .tier = .tooltip, .enter_transition = .none, .exit_transition = .none });
    const dlg = try stack.push(.{ .kind = .modal, .enter_transition = .none, .exit_transition = .none });
    const tip_n = try Node.create(allocator, 701, .box, .{ .width = .{ .px = 40 }, .height = .{ .px = 20 } });
    const dlg_n = try Node.create(allocator, 702, .box, .{ .width = .{ .px = 200 }, .height = .{ .px = 120 } });
    defer tip_n.destroy(allocator);
    defer dlg_n.destroy(allocator);
    stack.bindFloatingContent(allocator, tip, tip_n);
    stack.bindFloatingContent(allocator, dlg, dlg_n);

    try std.testing.expect(tip_n.style.z_index() >= StackTier.tooltip.base());
    try std.testing.expect(dlg_n.style.z_index() >= StackTier.dialog.base());
    try std.testing.expect(tip_n.style.z_index() > dlg_n.style.z_index());
}

test "OverlayStack: 嵌套继承 —— dialog content 里的 trigger 开 popover 压过 dialog" {
    const allocator = std.testing.allocator;
    var stack = OverlayStack{};

    const dlg = try stack.push(.{ .kind = .modal, .enter_transition = .none, .exit_transition = .none });
    const dlg_content = try Node.create(allocator, 711, .box, .{ .width = .{ .px = 300 }, .height = .{ .px = 200 } });
    defer dlg_content.destroy(allocator);
    const trigger = try Node.create(allocator, 712, .button, .{ .width = .{ .px = 80 }, .height = .{ .px = 24 } });
    try dlg_content.appendChild(allocator, trigger);
    stack.bindFloatingContent(allocator, dlg, dlg_content);

    // popover tier 基线（100）远低于 dialog（1000）——继承必须把它抬到 dialog 之上
    const pop = try stack.push(.{ .kind = .non_modal, .enter_transition = .none, .exit_transition = .none, .trigger_node = trigger });
    const pop_n = try Node.create(allocator, 713, .box, .{ .width = .{ .px = 120 }, .height = .{ .px = 60 } });
    defer pop_n.destroy(allocator);
    stack.bindFloatingContent(allocator, pop, pop_n);

    try std.testing.expect(pop_n.style.z_index() > dlg_content.style.z_index());

    // 树外 trigger 的普通 popover 不受影响，仍在 overlay tier 基线附近
    const free_pop = try stack.push(.{ .kind = .non_modal, .enter_transition = .none, .exit_transition = .none });
    const free_n = try Node.create(allocator, 714, .box, .{ .width = .{ .px = 100 }, .height = .{ .px = 40 } });
    defer free_n.destroy(allocator);
    stack.bindFloatingContent(allocator, free_pop, free_n);
    try std.testing.expect(free_n.style.z_index() < StackTier.dialog.base());
}

test "OverlayStack: 后开的 dialog 压过此前活动的 popover（Top Layer FIFO），但压不过 tooltip" {
    const allocator = std.testing.allocator;
    var stack = OverlayStack{};

    // 先开 tooltip 和 popover，再开一个无 trigger_node 的 modal（如从 popover
    // 内容里打开的 Modal —— Modal 组件不传 trigger）。
    const tip = try stack.push(.{ .kind = .non_modal, .tier = .tooltip, .enter_transition = .none, .exit_transition = .none });
    const pop = try stack.push(.{ .kind = .non_modal, .enter_transition = .none, .exit_transition = .none });
    const dlg = try stack.push(.{ .kind = .modal, .enter_transition = .none, .exit_transition = .none });
    const tip_n = try Node.create(allocator, 721, .box, .{ .width = .{ .px = 40 }, .height = .{ .px = 20 } });
    const pop_n = try Node.create(allocator, 722, .box, .{ .width = .{ .px = 120 }, .height = .{ .px = 60 } });
    const dlg_n = try Node.create(allocator, 723, .box, .{ .width = .{ .px = 200 }, .height = .{ .px = 120 } });
    defer tip_n.destroy(allocator);
    defer pop_n.destroy(allocator);
    defer dlg_n.destroy(allocator);
    stack.bindFloatingContent(allocator, tip, tip_n);
    stack.bindFloatingContent(allocator, pop, pop_n);
    stack.bindFloatingContent(allocator, dlg, dlg_n);

    // FIFO：后开的 dialog 必须压过先开的 popover（即便无 trigger 嵌套继承）
    try std.testing.expect(dlg_n.style.z_index() > pop_n.style.z_index());
    // tooltip 恒顶：不被后开的 dialog 压掉
    try std.testing.expect(tip_n.style.z_index() > dlg_n.style.z_index());
}

test "OverlayStack: reactivate preserves prewarmed descendant render caches" {
    const allocator = std.testing.allocator;
    var stack = OverlayStack{};

    const handle = try stack.push(.{ .kind = .non_modal, .enter_transition = .none, .exit_transition = .none });
    const content = try Node.create(allocator, 310, .box, .{ .width = .{ .px = 120 }, .height = .{ .px = 60 } });
    const child = try Node.create(allocator, 311, .box, .{ .width = .{ .px = 80 }, .height = .{ .px = 24 } });
    defer content.destroy(allocator);
    try content.appendChild(allocator, child);
    stack.bindFloatingContent(allocator, handle, content);

    const cached = [_]core.DisplayItem{
        .{ .fill_rect = .{
            .header = .{ .transform_id = 0, .node_id = 0 },
            .x = 0,
            .y = 0,
            .w = 80,
            .h = 24,
            .color = Color.rgba(255, 255, 255, 255),
            .radius = .{ 0, 0, 0, 0 },
        } },
    };
    content.cacheRenderCommands(allocator, &cached, 0, 0);
    child.cacheRenderCommands(allocator, &cached, 0, 0);

    stack.commitExit(handle);
    try std.testing.expect(content.meta.per_frame.caches.commands.own != null);
    try std.testing.expect(child.meta.per_frame.caches.commands.own != null);

    stack.reactivate(handle);
    try std.testing.expect(content.meta.per_frame.caches.commands.own != null);
    try std.testing.expect(child.meta.per_frame.caches.commands.own != null);
}

test "OverlayStack: findLayerForNode matches overlay descendants" {
    const allocator = std.testing.allocator;
    var stack = OverlayStack{};

    const handle = try stack.push(.{ .kind = .non_modal, .enter_transition = .none, .exit_transition = .none });
    const content = try Node.create(allocator, 401, .box, .{ .width = .{ .px = 120 }, .height = .{ .px = 60 } });
    const child = try Node.create(allocator, 402, .box, .{ .width = .{ .px = 80 }, .height = .{ .px = 24 } });
    defer content.destroy(allocator);
    try content.appendChild(allocator, child);
    stack.bindFloatingContent(allocator, handle, content);

    const layer = stack.findLayerForNode(child) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(handle.id, layer.handle.id);
}

test "OverlayStack: bound content gains pointer role without losing inspect" {
    const allocator = std.testing.allocator;
    var stack = OverlayStack{};

    const handle = try stack.push(.{ .kind = .non_modal, .enter_transition = .none, .exit_transition = .none });
    const content = try Node.create(allocator, 411, .box, .{ .width = .{ .px = 120 }, .height = .{ .px = 60 } });
    defer content.destroy(allocator);
    stack.bindFloatingContent(allocator, handle, content);

    // bindContentNode 只想给 content 加 pointer。历史上它写的是 bool 结构体
    // `.{ .pointer = true }`，把 inspect 从默认 true 静默改成 false —— dialog/panel
    // 因此在 devtools 里选不中。逐 role 覆盖后 inspect 必须保持 true。
    const roles = core.interaction_semantics.nodeHitRoles(content);
    try std.testing.expect(roles.pointer);
    try std.testing.expect(roles.inspect);
}

test "OverlayStack: exiting overlay stops intercepting hits before commitExit" {
    const allocator = std.testing.allocator;
    var stack = OverlayStack{};
    var registry = core.NodeRegistry.init(allocator);
    defer registry.deinit();
    var runtime = core.InteractionIndex.init(allocator);
    defer runtime.deinit();

    const root = try Node.create(allocator, 200, .box, .{ .width = .{ .px = 220 }, .height = .{ .px = 180 } });
    defer root.destroy(allocator);
    const under = try Node.create(allocator, 201, .button, .{ .width = .{ .px = 120 }, .height = .{ .px = 80 } });
    under.behavior.interaction.focusable = true;
    try root.appendChild(allocator, under);

    const handle = try stack.push(.{ .kind = .non_modal, .enter_transition = .none, .exit_transition = .fade });
    const overlay_node = try Node.create(allocator, 202, .box, .{ .width = .{ .px = 120 }, .height = .{ .px = 80 } });
    const option = try Node.create(allocator, 203, .button, .{ .width = .{ .px = 120 }, .height = .{ .px = 80 } });
    option.behavior.interaction.focusable = true;
    try overlay_node.appendChild(allocator, option);
    try root.appendChild(allocator, overlay_node);
    stack.bindFloatingContent(allocator, handle, overlay_node);

    root.setLayoutRect(.{ .x = 0, .y = 0, .w = 220, .h = 180 });
    under.setLayoutRect(.{ .x = 20, .y = 20, .w = 120, .h = 80 });
    overlay_node.setLayoutRect(.{ .x = 20, .y = 20, .w = 120, .h = 80 });
    option.setLayoutRect(.{ .x = 0, .y = 0, .w = 120, .h = 80 });

    try registry.rebuild(root);
    try runtime.rebuild(root, &registry);

    const before = runtime.hitTestQuery(.{ .kind = .pointer, .world_x = 60, .world_y = 50 }, &registry, null);
    try std.testing.expect(before != null);
    try std.testing.expectEqual(@as(u32, 203), before.?.node_id);

    stack.beginExit(handle);
    try std.testing.expect(!overlay_node.frame_state.state_bits.flags.hit_test_visible);
    try runtime.rebuild(root, &registry);

    const after = runtime.hitTestQuery(.{ .kind = .pointer, .world_x = 60, .world_y = 50 }, &registry, null);
    try std.testing.expect(after != null);
    try std.testing.expectEqual(@as(u32, 201), after.?.node_id);
}

test "OverlayStack: entering state transitions to visible" {
    var stack = OverlayStack{};
    var test_time: f64 = 0;
    render_engine.current_frame_time_ms = 0;

    const h1 = try stack.push(.{
        .kind = .non_modal,
        .enter_transition = .fade, // 150ms
        .exit_transition = .none,
    });

    if (stack.findLayer(h1)) |layer| {
        try std.testing.expectEqual(LayerState.entering, layer.state);
    }

    // tick 到完成
    var ticks: u32 = 0;
    while (ticks < 100) : (ticks += 1) {
        test_time += 16.0;
        render_engine.current_frame_time_ms = test_time;
        _ = stack.tick(test_time, 0.016, 1920, 1080, std.testing.allocator);
        if (stack.findLayer(h1)) |layer| {
            if (layer.state == .visible) break;
        }
    }

    if (stack.findLayer(h1)) |layer| {
        try std.testing.expectEqual(LayerState.visible, layer.state);
    }
}

test "OverlayStack: enter transition pending first tick preserves initial frame" {
    const allocator = std.testing.allocator;
    var stack = OverlayStack{};
    var test_time: f64 = 0;
    render_engine.current_frame_time_ms = 0;

    const handle = try stack.push(.{
        .kind = .non_modal,
        .enter_transition = .fade,
        .exit_transition = .none,
    });
    const content = try Node.create(allocator, 301, .box, .{ .width = .{ .px = 80 }, .height = .{ .px = 40 } });
    defer content.destroy(allocator);
    stack.bindFloatingContent(allocator, handle, content);

    // Tick 1: rect == 0 → holdEnterUntilGeometryStable() forces progress to 0
    // and keeps the layer in `entering`.
    test_time += 16.0;
    render_engine.current_frame_time_ms = test_time;
    render_engine.current_frame_dt_ms = 16.0;
    _ = stack.tick(test_time, 0.016, 1920, 1080, allocator);
    if (stack.findLayer(handle)) |layer| {
        try std.testing.expectEqual(LayerState.entering, layer.state);
        try std.testing.expectApproxEqAbs(@as(f32, 0), layer.enter_ctrl.progress, 0.001);
    } else {
        return error.TestUnexpectedResult;
    }

    // Simulate layout completing: assign a non-zero rect and clear the dirty
    // bits that holdEnterUntilGeometryStable() treats as "still settling".
    content.setLayoutRect(.{ .x = 0, .y = 0, .w = 80, .h = 40 });
    content.frame_state.state_bits.dirty.core.layout = false;
    content.frame_state.state_bits.dirty.core.subtree_layout = false;

    // Warm-up ticks: rect is now stable but the hold needs three observations
    // (one to record the rect baseline, two to bump enter_stable_frame_count
    // to 2) before it releases. progress stays at 0 across all three.
    for (0..3) |_| {
        test_time += 16.0;
        render_engine.current_frame_time_ms = test_time;
        _ = stack.tick(test_time, 0.016, 1920, 1080, allocator);
    }
    if (stack.findLayer(handle)) |layer| {
        try std.testing.expectEqual(LayerState.entering, layer.state);
        try std.testing.expectApproxEqAbs(@as(f32, 0), layer.enter_ctrl.progress, 0.001);
    } else {
        return error.TestUnexpectedResult;
    }

    // Next tick: hold released, progress advances.
    test_time += 16.0;
    render_engine.current_frame_time_ms = test_time;
    _ = stack.tick(test_time, 0.016, 1920, 1080, allocator);
    if (stack.findLayer(handle)) |layer| {
        try std.testing.expect(layer.enter_ctrl.progress > 0.0);
    } else {
        return error.TestUnexpectedResult;
    }
    try std.testing.expect(content.getOpacity() > 0.0);
}

test "OverlayStack: exit transition holds visible frame before fading" {
    const allocator = std.testing.allocator;
    var stack = OverlayStack{};
    var test_time: f64 = 0;
    render_engine.current_frame_time_ms = 0;

    const handle = try stack.push(.{
        .kind = .non_modal,
        .enter_transition = .none,
        .exit_transition = .fade,
    });
    const content = try Node.create(allocator, 302, .box, .{ .width = .{ .px = 80 }, .height = .{ .px = 40 } });
    defer content.destroy(allocator);
    stack.bindFloatingContent(allocator, handle, content);
    content.setOpacityRaw(1.0);

    stack.beginExit(handle);
    test_time += 16.0;
    render_engine.current_frame_time_ms = test_time;
    _ = stack.tick(test_time, 0.016, 1920, 1080, allocator);
    if (stack.findLayer(handle)) |layer| {
        try std.testing.expectEqual(LayerState.exiting, layer.state);
        try std.testing.expect(layer.exit_ctrl.progress > 0.85 and layer.exit_ctrl.progress <= 1.0);
    } else {
        return error.TestUnexpectedResult;
    }
    try std.testing.expect(content.getOpacity() > 0.85 and content.getOpacity() <= 1.0);

    test_time += 16.0;
    render_engine.current_frame_time_ms = test_time;
    _ = stack.tick(test_time, 0.016, 1920, 1080, allocator);
    if (stack.findLayer(handle)) |layer| {
        try std.testing.expect(layer.exit_ctrl.progress < 1.0);
    } else {
        return error.TestUnexpectedResult;
    }
    try std.testing.expect(content.getOpacity() < 1.0);
}

test "OverlayStack: reactivated layer ignores opener outside-click for one frame" {
    const allocator = std.testing.allocator;
    var stack = OverlayStack{};
    var test_time: f64 = 0;

    const handle = try stack.push(.{
        .kind = .modal,
        .dismiss = .{ .outside_click = .close, .escape = true },
        .enter_transition = .fade,
        .exit_transition = .fade,
    });
    const content = try Node.create(allocator, 501, .box, .{ .width = .{ .px = 120 }, .height = .{ .px = 60 } });
    const opener = try Node.create(allocator, 502, .button, .{ .width = .{ .px = 80 }, .height = .{ .px = 32 } });
    defer content.destroy(allocator);
    defer opener.destroy(allocator);
    stack.bindFloatingContent(allocator, handle, content);

    stack.commitExit(handle);
    try std.testing.expect(stack.findLayer(handle).?.suspended);

    stack.reactivate(handle);
    try std.testing.expect(stack.findLayer(handle).?.skip_outside_click_frame);

    stack.handleOutsideClick(true, opener);
    try std.testing.expectEqual(LayerState.entering, stack.findLayer(handle).?.state);

    test_time += 16.0;
    render_engine.current_frame_time_ms = test_time;
    _ = stack.tick(test_time, 0.016, 1920, 1080, allocator);
    try std.testing.expect(!stack.findLayer(handle).?.skip_outside_click_frame);

    stack.handleOutsideClick(true, opener);
    try std.testing.expectEqual(LayerState.exiting, stack.findLayer(handle).?.state);
}

test "OverlayStack: non-hit-test overlay content does not block outside-click dismissal below" {
    const allocator = std.testing.allocator;
    var stack = OverlayStack{};

    const modal_like = try stack.push(.{
        .kind = .non_modal,
        .dismiss = .{ .outside_click = .close, .escape = true },
        .enter_transition = .none,
        .exit_transition = .fade,
    });
    const modal_content = try Node.create(allocator, 601, .box, .{ .width = .{ .px = 120 }, .height = .{ .px = 60 } });
    defer modal_content.destroy(allocator);
    stack.bindFloatingContent(allocator, modal_like, modal_content);

    const snapshot_like = try stack.push(.{
        .kind = .non_modal,
        .dismiss = .{ .outside_click = .none, .escape = false },
        .enter_transition = .none,
        .exit_transition = .none,
        .content_hit_test_visible = false,
    });
    const snapshot_content = try Node.create(allocator, 602, .box, .{ .width = .{ .grow = .{} }, .height = .{ .grow = .{} } });
    const outside_target = try Node.create(allocator, 603, .button, .{ .width = .{ .px = 80 }, .height = .{ .px = 32 } });
    defer snapshot_content.destroy(allocator);
    defer outside_target.destroy(allocator);
    stack.bindFloatingContent(allocator, snapshot_like, snapshot_content);

    stack.handleOutsideClick(true, outside_target);
    try std.testing.expectEqual(LayerState.exiting, stack.findLayer(modal_like).?.state);
    try std.testing.expectEqual(LayerState.visible, stack.findLayer(snapshot_like).?.state);
}

test "OverlayStack: null hit target still counts as outside click" {
    const allocator = std.testing.allocator;
    var stack = OverlayStack{};

    const handle = try stack.push(.{
        .kind = .non_modal,
        .dismiss = .{ .outside_click = .close, .escape = true },
        .enter_transition = .none,
        .exit_transition = .fade,
    });
    const content = try Node.create(allocator, 611, .box, .{ .width = .{ .px = 120 }, .height = .{ .px = 60 } });
    defer content.destroy(allocator);
    stack.bindFloatingContent(allocator, handle, content);

    stack.handleOutsideClick(true, null);
    try std.testing.expectEqual(LayerState.exiting, stack.findLayer(handle).?.state);
}

test "OverlayStack: clear" {
    var stack = OverlayStack{};

    _ = try stack.push(.{ .kind = .modal });
    _ = try stack.push(.{ .kind = .non_modal });
    _ = try stack.push(.{ .kind = .toast });
    try std.testing.expectEqual(@as(u8, 3), stack.layer_count);

    stack.clear();
    try std.testing.expectEqual(@as(u8, 0), stack.layer_count);
}

// ── 析出模块的测试收集 ─────────────────────────────────────────────────
// ⚠ `pub const x = @import(...)` 再导出**不会**让该文件的 test 块被收集
//（见 build.zig:556-570 对 text 模块同类问题的注释）。必须用裸
// `_ = @import("...")` 语句把这些文件登记为 test 来源，单测才真的会跑。
//
// overlay_transition.zig：TransitionController 时钟/曲线表单测（12 个，
// 其中 5 个随实现从本文件迁出、7 个为本次新增钉住坑 1~4）。
// overlay_layer_refs.zig：trigger/anchor 悬垂指针存活校验单测（5 个，全新）。
test {
    _ = @import("overlay_transition.zig");
    _ = @import("overlay_layer_refs.zig");
}

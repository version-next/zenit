//! BulkQuad 批量矩形层，从 `Cx` 析出的有状态渲染子系统。
//!
//! 管一件事：**绕过 Node 树的一批同构矩形，在 paint pass 末尾 lower 成
//! display item 并插进 display list 的正确位置**。
//!
//! 原本是 `Cx` 上的五个字段（bulk_quads / _anchor / _overlay_z / _version /
//! _unchanged）加十三个方法。它们对 `Cx` 的全部依赖只有六个**只读输入**：
//!
//!   display_list / property_tree / scene_runtime / root / frame_arena / allocator
//!
//! 接口因此切在：**`Host` 把这六个输入打包传进来，本模块不知道 Cx 存在**
//! （`Cx.appendBulkQuads` 是一行委托，见 core.zig）。setBulkQuads* 三个是
//! 面向宿主的公共 API，仍留在 `Cx` 上做薄委托，消费者在仓外（下游应用），
//! 挪走它们是 break-API。
//!
//! 搬出来之后，此前只能靠完整 `Cx.render()` 驱动的逻辑，三级插入点定位、
//! z 归并、z 继承、锚点为 null 的降级路径，全都可以用手搓 display list +
//! 手搓 Node 树做单元测试（见文末测试），不必再为驱动一帧渲染付出整棵树。
//!
//! ⚠ 两个集成点留在 `Cx`，别搬进来：
//!   - `Cx.render` 末尾调 `cx.appendBulkQuads()`（paint pass 之后）；
//!   - `Cx.invalidateReferencesToEx` 里清锚点（见 `dropIfInsideSubtree` 的
//!     注释，那次 SIGSEGV 的教训写在那边）。

const std = @import("std");

const types = @import("types.zig");
const node_mod = @import("node.zig");
const display_list_mod = @import("display_list.zig");
const property_tree_mod = @import("property_tree.zig");
const scene_runtime_mod = @import("scene_runtime.zig");

const Allocator = std.mem.Allocator;
const Node = node_mod.Node;
const DisplayItem = display_list_mod.DisplayItem;
const ItemHeader = display_list_mod.ItemHeader;
const Color = types.Color;
const ComputedRect = types.ComputedRect;
const Shadow = types.Shadow;
const InsetShadow = types.InsetShadow;
const MultiGradient = types.MultiGradient;

/// 批量矩形，绕过 Node 树的"一批同构矩形"提交单元。
///
/// 动机（通用能力，非某个宿主专用）：Node 的成本是**逐节点**的挂载、布局与
/// paint 遍历。当宿主要画成千上万个彼此独立、样式同构、且**不参与布局/命中/
/// 焦点/无障碍**的小矩形（画布类应用缩小后的对象、地图符号、瓦片网格、
/// 散点图的点……）时，为每个矩形建一个 Node 付出的是它根本用不到的能力。
///
/// 实测（下游应用 20000 对象全可见）：17727 个 Node ⇒ layout 10.5ms + paint
/// 32.2ms；同样内容不挂 Node 时两者合计降到 0.8ms。差额全部是 per-node 常数。
///
/// 语义（**刻意受限**，越权的场景请老实用 Node）：
///   - 坐标是**绝对视口坐标**（不参与父级 transform / 布局 / 滚动偏移）；
///   - 不参与命中测试、焦点、无障碍树、动画、effect 栈；
///   - 层级与裁剪由 `setBulkQuads` 的 `anchor` 决定（见 `Cx.setBulkQuads`）：
///     挂靠某个 Node 时这批矩形就画在该 Node 的内容位置、并受它的 clip
///     约束，即"表现得和该 Node 的普通子内容一致"；不挂靠时退化为
///     画在整棵 Node 树之上、不裁剪（仅适合全屏 overlay 类用途）；
///   - 组内按数组顺序绘制（后者盖前者）;
///   - 数据跨帧保留，直到宿主再次 `setBulkQuads` 覆盖（不做跨帧 diff）。
///     详见 `Cx.setBulkQuads` 的"生命周期"一节。
///
/// 像素等价保证：lower 出的 `fill_rect` / `stroke_rect` 与 Node 路径**同构**
/// 相同 color/radius/border_width 下走的是同一条 SDF 管线、同一套参数，
/// 因此逐位相同（core/tests.zig 的 Node-vs-bulk 对照测试守着这条）。
pub const BulkQuad = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    /// 填充色。alpha=0 表示不填充（只画描边）。
    color: Color,
    /// 四角圆角半径（顺序同 Node：TL/TR/BR/BL）。
    radius: [4]f32 = .{ 0, 0, 0, 0 },
    /// 描边宽度；0 表示不描边。
    border_width: f32 = 0,
    border_color: Color = Color.TRANSPARENT,
    /// 这条 quad 在**锚点子树兄弟序**里的层级。
    ///
    /// null（默认）= 整层作为一个平面插在锚点子树静态内容之后，也就是画在
    /// 所有对象 Node 之上，这是原有语义，适合"画面上只有批量项"的场合。
    ///
    /// 给了值 ⇒ 这条 quad 会被插到"第一个 z_index 大于它的 Node item"之前，
    /// 于是批量项与 Node 能**逐个交错**。宿主把对象的 z 原样传下来即可。
    ///
    /// 为什么需要它：一个平面无法表达"部分对象在某些 Node 之下、另一些在其
    /// 之上"。真实场景里少数对象因为要画文字必须留在 Node 路径，而它们的 z
    /// 往往横穿整个 z 区间，用单平面切在任何一刀都会画错一侧。
    z_index: ?i16 = null,

    /// 分边描边宽度（顺序同 Node：top/right/bottom/left）。
    /// **全零 = 走 `border_width` 的统一路径**（与 InstanceData.border_widths
    /// 同语义）。非零时 `border_width` 被忽略。
    ///
    /// 之所以能加：GPU 侧 `InstanceData` 本来就有 `float4 border_widths`，
    /// `DisplayItem.border_per_side` 也早就存在，缺的只是这一段没往下传。
    border_widths: [4]f32 = .{ 0, 0, 0, 0 },

    /// 投影。null = 无阴影，不产生任何额外开销。
    ///
    /// 阴影在 SDF 片元着色器里是**解析式**计算（与填充同一次 instanced draw），
    /// 不需要离屏 pass。给批量层开放它，带阴影的对象才不会被踢回 Node 路径
    /// 后者实测慢 53×（见 core.zig `BulkQuad` 迁移前的实测记录）。
    shadow: ?Shadow = null,

    /// 内阴影。null = 无。同样是解析式，`packed_flags` bit24 已有对应位。
    inset_shadow: ?InsetShadow = null,

    /// 渐变填充。null = 用 `color` 的纯色。
    ///
    /// 与 shadow 同一条路：`InstanceData` 早就有 `gradient_stop_offset` /
    /// `gradient_stop_count`，`DisplayItem` 也有 `multi_gradient_rect`
    /// （16 stop），缺的只是这一段没往下传。
    ///
    /// 给了渐变时 `color` 被忽略（但仍应填成大致色，供降级路径使用）。
    gradient: ?MultiGradient = null,
    /// 径向/角度渐变的中心与起始角（仅对应 direction 时有意义）。
    gradient_center: [2]f32 = .{ 0.5, 0.5 },
    gradient_start_angle: f32 = 0,

    /// 附加裁剪矩形（**绝对视口坐标** x/y/w/h）。null = 只受锚点 clip。
    ///
    /// 给了值 ⇒ 这条 quad 以「锚点 clip ∩ 该矩形」裁剪。实现上按矩形值
    /// 建 property-tree ClipNode（同帧同矩形只建一个，parent 挂锚点 clip），
    /// lowering 的 clip 链前缀保留会让相邻同 clip 的 quad 共享一次 push/pop。
    /// 三渲染器（SDF/text/image）的 per-instance clip 早已就位，这里只是
    /// 把"每 quad 一个 clip"这段管道补上（宿主场景：画布 frame 裁剪子女）。
    clip_rect: ?[4]f32 = null,

    pub fn hasPerSideBorder(self: BulkQuad) bool {
        return self.border_widths[0] != 0 or self.border_widths[1] != 0 or
            self.border_widths[2] != 0 or self.border_widths[3] != 0;
    }
};

/// 一条 BulkQuad 最多降成几个 DisplayItem：投影 + 填充 + 描边 + 内阴影。
/// 只用于预留容量（写入走 append，估小了也只是多一次 realloc，不影响正确性）。
/// 见 `appendQuadItems`。
pub const MAX_ITEMS_PER_QUAD: usize = 4;

/// 本模块对宿主（`Cx`）的全部依赖：六个**只读输入**。
///
/// 为什么不是直接 `*Cx`：那会让本模块反向 import core.zig，`Cx` 的任何字段
/// 改动都会把这里重新编译一遍，而且这套逻辑（插入点定位 / z 归并 / lower）
/// 也没法脱离整棵树做单元测试。参考 text_input_session.zig 的 Host 模式，
/// 依赖以值/指针打包传入，模块因此可独立编译、独立测试。
pub const Host = struct {
    /// 目标 display list（写入端：批量层要往里 lower / 插入）。
    display_list: *display_list_mod.DisplayList,
    /// per-quad 附加裁剪（BulkQuad.clip_rect）要在这里建 ClipNode。
    property_tree: *property_tree_mod.PropertyTree,
    /// 挂靠语义的 clip 来源：按 anchor.id 取 clip_id。
    scene_runtime: *const scene_runtime_mod.SceneRuntime,
    /// 锚点之后的兄弟定位（三级插入点的第 ③ 级）从 root 开始遍历。
    root: ?*Node = null,
    /// 帧级 arena。插入点定位的一次性集合（ids / overlay_ids / item_z）
    /// 全部分配在这里，帧末随 arena 蒸发。
    frame_arena: Allocator,
    /// display list / staged buffer 的长期分配器（Cx.allocator）。
    allocator: Allocator,
};

pub const BulkQuadLayer = struct {
    /// 批量矩形层（见 `BulkQuad` / `Cx.setBulkQuads`）。宿主直接提交一批
    /// 绝对坐标矩形，绕过 Node 的挂载/布局/paint 遍历。
    quads: std.ArrayListUnmanaged(BulkQuad) = .{},
    /// 批量矩形层挂靠的 Node（见 `Cx.setBulkQuads`）。null = 不挂靠（画在
    /// 整棵树之上、不裁剪）。渲染时按该 Node 的 display item 区间与
    /// clip/transform id 插入这批 quad。
    anchor: ?*Node = null,
    /// 锚点子树里"交互叠加"的 z_index 起点（见 `Cx.setBulkQuadsEx`）。
    /// null = 整棵锚点子树都算静态内容。
    overlay_z: ?i16 = null,
    /// 宿主声明的批量层内容版本（见 Cx.setBulkQuadsVersioned）。
    version: ?u64 = null,
    /// 本帧批量层内容是否与上一帧相同（由版本号判定）。
    unchanged: bool = false,

    pub fn deinit(self: *BulkQuadLayer, allocator: Allocator) void {
        self.quads.deinit(allocator);
    }

    /// 把批量矩形层 lower 成 display item，写进 host.display_list。
    ///
    /// 与 Node 路径**同构**：背景走 `fill_rect`、描边走 `stroke_rect`，
    /// 参数逐项对应，因此同样的几何/颜色/圆角/描边宽度产出逐位相同的像素。
    pub fn append(self: *BulkQuadLayer, host: Host) !void {
        if (self.quads.items.len == 0) return;

        // 挂靠 Node 时：用该 Node 的 clip（=> 受它的 overflow 裁剪）并插入到
        // 它的子树 display item 区间末尾（=> 它之后的兄弟节点照常盖在上面）。
        // transform 仍用 identity：BulkQuad 的坐标语义是绝对视口坐标，挂靠
        // 只决定"层级 + 裁剪"，不引入父级 transform（否则坐标会被二次变换）。
        var clip_id: u32 = display_list_mod.INVALID_ID;
        var node_id: u32 = 0;
        var insert_at: ?usize = null;
        if (self.anchor) |anchor| {
            // 挂靠语义下的失败必须**安全降级**：宁可这一帧不画批量层，也绝不
            // 退化成"追加到末尾 + 不裁剪"。后者会让两万个 quad 整片盖在侧栏 /
            // Inspector / 工具栏之上（用户截图里"对象糊在 UI chrome 上"）。
            // 少画一帧只是视觉上少一些内容，下一帧就补回来；画到 UI 上则是
            // 不可接受的破坏性回归。
            const rt = host.scene_runtime.get(anchor.id) orelse return;
            clip_id = rt.clip_id;
            node_id = anchor.id;
            // 插入点 = 锚点子树在 display list 中最后一个 item 之后。
            // 不用 scene_runtime 的 subtree_display_item_*，那两个字段是
            // 缓存 splice/replay 的记账，会被改写指向别处（实测过期时会
            // 越过后续兄弟，正是本 bug 的翻车点）。这里按 node 归属实扫，
            // 只在提交了批量层的帧上跑一次，成本相对 20000 quad 可忽略。
            //
            // `insertPoint` 只在"锚点之后本来就没有任何 item"时返回
            // null，那种情况下末尾追加与正确插入点等价，是安全的。
            insert_at = self.insertPoint(anchor, host);
        }

        const header = ItemHeader{
            // transform 0 = identity（property_tree 的根），坐标即视口绝对坐标。
            .transform_id = 0,
            .clip_id = clip_id,
            .node_id = node_id,
        };
        // per-quad 附加裁剪（BulkQuad.clip_rect）的 ClipNode 缓存。
        var clip_cache = BulkClipCache{};

        // 分段路径：只要有任何一条 quad 带 z_index，就按 z 分组、每组各自
        // 定位插入点，让批量项与 Node 逐个交错（见 BulkQuad.z_index）。
        //
        // 分组只按**相邻且同 z**切分，不做全局排序，宿主提交的顺序就是绘制
        // 顺序（BulkQuad 的既有契约），重排会破坏同 z 内的先后关系。
        if (self.anchor != null) {
            var any_z = false;
            for (self.quads.items) |q| {
                if (q.z_index != null) {
                    any_z = true;
                    break;
                }
            }
            if (any_z) {
                try self.appendSegmented(host, header, insert_at, &clip_cache);
                return;
            }
        }

        // 插入点就是末尾（无锚点，或锚点子树本就排在最后）时不必绕暂存区，
        // 直接往 display_list 尾部写，两万 quad 的量级下省掉一次整层拷贝。
        const at_tail = insert_at == null or insert_at.? == host.display_list.items.items.len;
        if (at_tail) {
            try host.display_list.items.ensureUnusedCapacity(
                host.allocator,
                self.quads.items.len * MAX_ITEMS_PER_QUAD,
            );
            for (self.quads.items) |q| {
                // 与另外两处降级路径共用同一个 lower，三处各写一遍是历史包袱，
                // 加字段时必然漏改其中一处（阴影/分边就是这么差点漏掉的）。
                try appendQuadItems(&host.display_list.items, host.allocator, q, clip_cache.headerFor(host, q, header));
            }
            return;
        }

        // 中间插入：先在暂存区 lower，再一次性 insertSlice（保持组内数组顺序）。
        var staged: std.ArrayListUnmanaged(DisplayItem) = .{};
        defer staged.deinit(host.allocator);
        try staged.ensureTotalCapacity(host.allocator, self.quads.items.len * MAX_ITEMS_PER_QUAD);

        for (self.quads.items) |q| {
            try appendQuadItems(&staged, host.allocator, q, clip_cache.headerFor(host, q, header));
        }
        if (staged.items.len == 0) return;
        try host.display_list.items.insertSlice(host.allocator, insert_at.?, staged.items);
    }

    /// 批量层挂靠点：锚点**静态内容**之后、**交互叠加**之前的位置。
    ///
    /// 层级模型（底 -> 顶），批量层属于第 1 层：
    ///   1. 画布静态内容：Node 路径的大对象 + 批量层的小对象（同层，互相按
    ///      提交/文档序排）；
    ///   2. 画布交互叠加：选择框 / resize handles / 尺寸标签 / hover 高亮 /
    ///      snap 线，这些是锚点的子节点，但必须**盖在**批量层之上；
    ///   3. UI chrome（侧栏 / Inspector / 工具栏），锚点之外的兄弟，天然在后；
    ///   4. overlay / modal。
    ///
    /// 宿主用 `overlay_z_threshold`（本层的 `overlay_z` 字段）声明第 2 层的
    /// 起点：锚点子树里 z_index **≥ 阈值**的节点算交互叠加，批量层插到它们
    /// 之前。不传（null）则整棵子树都算静态内容（旧行为）。
    ///
    /// 三级定位，缺一不可：
    ///   ① 锚点子树有静态内容 item ⇒ 插到其中最后一个之后（且不越过叠加层）。
    ///   ② 锚点子树静态内容为空但有交互叠加（选中了对象、画布里的对象全部
    ///      降级成批量层）⇒ 插到第一个叠加 item 之前。
    ///   ③ 锚点子树一个 item 都没产出（锚点自身无背景 + 子内容全降级/为空
    ///      画布缩小到全对象走批量层时正是这一档）⇒ 退回到"锚点之后的
    ///      兄弟"的第一个 item 之前。**不能因为 ①② 落空就返回 null**：null
    ///      在调用方语义里是"追加到末尾"，那会让批量层整片盖到 chrome 上，
    ///      表现为缩小档下画面间歇性闪烁/糊住 UI（见 core/tests.zig 的
    ///      "锚点子树无 display item" 回归）。
    /// 三级都落空（锚点后面本来就没有任何内容）才返回 null，此时末尾
    /// 追加与正确插入点等价。
    pub fn insertPoint(self: *const BulkQuadLayer, anchor: *Node, host: Host) ?usize {
        const arena = host.frame_arena;

        // 锚点子树的 node id 集合（一帧一次，节点数 = 画布容器子树，很小）。
        // overlay_ids = 其中 z_index ≥ 阈值的交互叠加节点（含其子树）。
        var ids = std.AutoHashMapUnmanaged(u32, void){};
        defer ids.deinit(arena);
        collectSubtreeIds(anchor, &ids, arena) catch return null;

        var overlay_ids: std.AutoHashMapUnmanaged(u32, void) = .{};
        defer overlay_ids.deinit(arena);
        if (self.overlay_z) |threshold| {
            collectOverlayIds(anchor, threshold, false, &overlay_ids, arena) catch return null;
        }

        // 第一个交互叠加 item：批量层无论如何不能越过它。
        //
        // 注意这里（以及下面两处扫描）必须用 `DisplayItem.header()` 认**全部**
        // 25 种 item，不能只 switch fill_rect/stroke_rect/text_run。曾经的
        // 三选一写法是"间歇性丢层"的真正根因：下游应用画布之后的 chrome 大量
        // 由被漏掉的种类绘制（毛玻璃 begin_blur_layer、点阵/图标 image_quad /
        // icon_rep、岛卡片 shadow_rect / gradient_rect），wrapper 自身又无
        // 背景不产 item ⇒ 三级定位全部扫不到参照物 ⇒ 返回 null ⇒ 调用方按
        // "追加末尾 + 不裁剪"降级 ⇒ 整片 quad 糊到 UI 之上。
        var first_overlay: ?usize = null;
        if (overlay_ids.count() != 0) {
            for (host.display_list.items.items, 0..) |it, idx| {
                if (it.isControl()) continue;
                if (overlay_ids.contains(it.header().node_id)) {
                    first_overlay = idx;
                    break;
                }
            }
        }

        var last: ?usize = null;
        for (host.display_list.items.items, 0..) |it, idx| {
            // 控制 token（起带真实 node_id）不算内容：paint pass 追加的那对
            // scroll-clip token 落在 display_list 末尾，算进去插入点就越过全部 chrome。
            if (it.isControl()) continue;
            const nid = it.header().node_id;
            // 只按**静态内容**定位；叠加层不参与"最后一个 item"的计算。
            if (ids.contains(nid) and !overlay_ids.contains(nid)) last = idx;
        }
        if (last) |l| {
            const at = l + 1;
            // ① 静态内容之后，但绝不越过交互叠加。
            if (first_overlay) |fo| return @min(at, fo);
            return at;
        }
        // ② 静态内容为空但有叠加 ⇒ 插到叠加之前。
        if (first_overlay) |fo| return fo;

        // ③ 锚点子树空：改用"锚点之后的节点"来定位。收集 paint 序里排在
        // 锚点子树**之后**的所有 node id，取它们在 display list 中最靠前的
        // item，批量层插在它之前，就仍然被这些 chrome 盖住。
        const root = host.root orelse return null;
        var after: std.AutoHashMapUnmanaged(u32, void) = .{};
        defer after.deinit(arena);
        var seen_anchor = false;
        collectIdsAfterSubtree(root, anchor, &seen_anchor, &after, arena) catch return null;
        if (after.count() == 0) return null;

        for (host.display_list.items.items, 0..) |it, idx| {
            if (after.contains(it.header().node_id)) return idx;
        }
        return null;
    }

    /// 分段提交：把带 z 的批量 quad 与锚点子树的 Node item **归并**成一份新的
    /// display list。
    ///
    /// 关键是"单趟归并"而不是"逐段各扫一次 display list"：后者在两万段 ×
    /// 两万 item 时是 O(n²)，实测把一次截图从 1.1s 拖到 5.7s。
    ///
    /// 归并规则：按 z 升序，z 相同时 **Node item 在前**（与 zenit 兄弟排序
    /// 一致：equal z 保持插入序，而 Node 是先产出的）。
    fn appendSegmented(
        self: *BulkQuadLayer,
        host: Host,
        header: ItemHeader,
        tail_insert_at: ?usize,
        clip_cache: *BulkClipCache,
    ) !void {
        const arena = host.frame_arena;
        const anchor = self.anchor.?;
        var item_z: std.ArrayListUnmanaged(?i16) = .{};
        defer item_z.deinit(arena);
        collectItemZ(anchor, host, &item_z, arena) catch return;

        const src = host.display_list.items.items;
        const tail = tail_insert_at orelse src.len;

        var merged: std.ArrayListUnmanaged(DisplayItem) = .{};
        defer merged.deinit(host.allocator);
        try merged.ensureTotalCapacity(
            host.allocator,
            src.len + self.quads.items.len * MAX_ITEMS_PER_QUAD,
        );

        var qi: usize = 0;
        for (src, 0..) |it, idx| {
            // 只在锚点子树的静态内容区间内做归并；区间之外（chrome 等）原样保留。
            if (idx < tail) {
                const nz = item_z.items[idx];
                if (nz) |z| {
                    // 把所有 z 严格小于当前 item 的 quad 先放进去。
                    while (qi < self.quads.items.len) : (qi += 1) {
                        const q = self.quads.items[qi];
                        const qz = q.z_index orelse break;
                        if (qz >= z) break;
                        try appendQuadItems(&merged, host.allocator, q, clip_cache.headerFor(host, q, header));
                    }
                }
            }
            if (idx == tail) {
                // 到达插入点：剩下的 quad 全部落在这里（它们比子树里任何
                // Node 都靠后），之后的 item 是 chrome，必须盖在批量层之上。
                while (qi < self.quads.items.len) : (qi += 1) {
                    const q = self.quads.items[qi];
                    try appendQuadItems(&merged, host.allocator, q, clip_cache.headerFor(host, q, header));
                }
            }
            try merged.append(host.allocator, it);
        }
        // 收尾：只有当插入点本来就是**整份 display list 的末尾**时，剩下的
        // quad 才追加到最后。否则它们已经在 `idx == tail` 那一步落位了,
        // 再追加一次会让批量项越过锚点之后的 chrome（侧栏 / Inspector /
        // 工具栏），正是"对象糊在 UI 上"那类回归。
        if (tail >= src.len) {
            while (qi < self.quads.items.len) : (qi += 1) {
                const q = self.quads.items[qi];
                try appendQuadItems(&merged, host.allocator, q, clip_cache.headerFor(host, q, header));
            }
        }

        host.display_list.items.clearRetainingCapacity();
        try host.display_list.items.appendSlice(host.allocator, merged.items);
    }

    /// 锚点子树里每个 display item 所属 Node 的 z_index（无归属则为 null）。
    /// 一帧一次，供分段插入做**单趟**归并用。
    pub fn collectItemZ(
        anchor: *Node,
        host: Host,
        out: *std.ArrayListUnmanaged(?i16),
        arena: Allocator,
    ) !void {
        var zmap = std.AutoHashMapUnmanaged(u32, i16){};
        defer zmap.deinit(arena);
        try collectSubtreeZ(anchor, &zmap, arena);
        try out.ensureTotalCapacity(arena, host.display_list.items.items.len);
        for (host.display_list.items.items) |it| {
            out.appendAssumeCapacity(if (it.isControl()) null else zmap.get(it.header().node_id));
        }
    }

    /// 替换本帧的批量矩形层（见 `BulkQuad`）。内部拷贝一份，调用方可立即
    /// 复用/释放 `quads`。传空切片即关闭该层（anchor / overlay_z 仍会被
    /// 重写，与 Cx.setBulkQuadsEx 的既有行为一致）。
    pub fn set(
        self: *BulkQuadLayer,
        host: Host,
        anchor: ?*Node,
        quads: []const BulkQuad,
        overlay_z_threshold: ?i16,
    ) !void {
        self.quads.clearRetainingCapacity();
        self.anchor = anchor;
        self.overlay_z = overlay_z_threshold;
        if (quads.len == 0) return;
        try self.quads.ensureTotalCapacity(host.allocator, quads.len);
        self.quads.appendSliceAssumeCapacity(quads);
    }

    /// `setBulkQuadsVersioned` 的版本号判定：与上一帧同版本 ⇒ `unchanged`
    /// 置 true（零脏帧快速路径因此继续成立）；传 null ⇒ 退化为保守重画。
    pub fn setVersioned(
        self: *BulkQuadLayer,
        host: Host,
        anchor: ?*Node,
        quads: []const BulkQuad,
        overlay_z_threshold: ?i16,
        version: ?u64,
    ) !void {
        self.unchanged = if (version) |v| blk: {
            const same = self.version != null and self.version.? == v;
            self.version = v;
            break :blk same;
        } else blk: {
            self.version = null;
            break :blk false;
        };
        return self.set(host, anchor, quads, overlay_z_threshold);
    }

    /// 锚点子树销毁时的兜底：锚点落在 `subtree_root` 里 ⇒ 清锚点**并关闭该层**。
    ///
    /// 锚点是裸 `*Node`（见 Cx.setBulkQuads 的生命周期一节）。宿主契约
    /// 要求"锚点销毁前重新提交"，但**销毁路径本身必须兜底**：宿主可能在
    /// 摘树之后、下一次 setBulkQuads 之前就渲染一帧（下游应用的 goHome ->
    /// teardownChromeScreen 摘掉画布子树，而 applySnapshot 在 homepage 屏
    /// 直接早退不再提交 ⇒ 锚点永远停留在已释放的 canvas_host）。此时
    /// append 会解引用 `anchor.id`，在 Cx.render 里读到未映射地址。
    ///
    /// 锚点连同 quads 一起清掉：只清指针会让批量层退化成"追加末尾 + 不裁剪"
    /// （null anchor 的语义），那正是两万 quad 糊住 chrome 的破坏性回归。
    /// 返回是否真的清了（false = 锚点不在该子树里，未动）。
    pub fn dropIfInsideSubtree(self: *BulkQuadLayer, subtree_root: *Node) bool {
        const anchor = self.anchor orelse return false;
        var current: ?*Node = anchor;
        while (current) |n| {
            if (n == subtree_root) {
                self.anchor = null;
                self.overlay_z = null;
                self.quads.clearRetainingCapacity();
                return true;
            }
            current = n.parent;
        }
        return false;
    }
};

/// BulkQuad.clip_rect -> ClipNode 的**按帧**缓存（同一矩形只建一个节点；
/// 典型宿主场景里一个 frame 的全部子女共享同一矩形）。map 存 frame_arena，
/// 帧末随 arena 一起蒸发，无需显式清理。
pub const BulkClipCache = struct {
    map: std.AutoHashMapUnmanaged(u128, u32) = .{},

    /// 为一条 quad 解析 header：无 clip_rect 原样返回；有则把 clip_id
    /// 换成「parent = 锚点 clip」的 ad-hoc ClipNode，链式发射时就是
    /// 视口 clip ∩ quad clip。ClipNode 建失败**安全降级**为锚点 clip
    /// （宁可这一帧少裁一刀，不能整批不画）。
    pub fn headerFor(
        cache: *BulkClipCache,
        host: Host,
        q: BulkQuad,
        base: ItemHeader,
    ) ItemHeader {
        const rect = q.clip_rect orelse return base;
        const key: u128 = @bitCast(rect);
        const gop = cache.map.getOrPut(host.frame_arena, key) catch return base;
        if (!gop.found_existing) {
            const cr = ComputedRect.init(rect[0], rect[1], rect[2], rect[3]);
            gop.value_ptr.* = host.property_tree.appendClip(.{
                .parent = base.clip_id,
                // transform 0 = identity：BulkQuad 坐标即绝对视口坐标。
                .transform_id = 0,
                .node_id = base.node_id,
                .local_rect = cr,
                .world_aabb = cr,
            }) catch {
                _ = cache.map.remove(key);
                return base;
            };
        }
        var h = base;
        h.clip_id = gop.value_ptr.*;
        return h;
    }
};

fn collectSubtreeIds(
    node: *Node,
    out: *std.AutoHashMapUnmanaged(u32, void),
    allocator: Allocator,
) !void {
    try out.put(allocator, node.id, {});
    for (node.children.items) |child| {
        try collectSubtreeIds(child, out, allocator);
    }
}

/// 收集锚点子树里属于**交互叠加**的节点 id：z_index ≥ `threshold` 的节点
/// 及其整棵子树（子节点继承父的叠加身份，尺寸标签的文字要跟着胶囊走）。
/// `inherited` = 祖先里已经有人越过阈值。
fn collectOverlayIds(
    node: *Node,
    threshold: i16,
    inherited: bool,
    out: *std.AutoHashMapUnmanaged(u32, void),
    allocator: Allocator,
) !void {
    const is_overlay = inherited or node.style.z_index() >= threshold;
    if (is_overlay) try out.put(allocator, node.id, {});
    for (node.children.items) |child| {
        try collectOverlayIds(child, threshold, is_overlay, out, allocator);
    }
}

/// paint 序遍历 `node`，把排在 `anchor` 子树**之后**的节点 id 收进 `out`。
/// `seen_anchor` 是遍历状态：碰到 anchor 后置位，此后的节点都算"之后"。
/// anchor 子树自身既不算之前也不算之后（整棵跳过）。
fn collectIdsAfterSubtree(
    node: *Node,
    anchor: *Node,
    seen_anchor: *bool,
    out: *std.AutoHashMapUnmanaged(u32, void),
    allocator: Allocator,
) !void {
    if (node == anchor) {
        seen_anchor.* = true;
        return; // 整棵 anchor 子树跳过
    }
    if (seen_anchor.*) try out.put(allocator, node.id, {});
    for (node.children.items) |child| {
        try collectIdsAfterSubtree(child, anchor, seen_anchor, out, allocator);
    }
}

fn collectSubtreeZ(
    node: *Node,
    out: *std.AutoHashMapUnmanaged(u32, i16),
    allocator: Allocator,
) !void {
    try collectSubtreeZInherited(node, node.style.z_index(), out, allocator);
}

/// 子树 z 归属：**后代继承祖先的 z_index**（自身显式声明时取自身）。
///
/// 批量层归并按"item 的 z"决定 quad 插在它前还是后，而 z 是**兄弟间**的
/// 层级语义，一个对象容器设了 z=3，它内部的文字/图标子节点并没有、
/// 也不需要各自再设一遍 z：它们属于那个容器的层级。此前这里直接读
/// 子节点自身的 z_index（默认 0），于是"容器 z=3 里的文字"被当成 z=0，
/// 批量层的 z=2 quad 插到了文字**之后**，把它整块盖掉
/// （下游应用：便签的黄色矩形盖住便签正文，文字看似"不渲染"）。
fn collectSubtreeZInherited(
    node: *Node,
    inherited_z: i16,
    out: *std.AutoHashMapUnmanaged(u32, i16),
    allocator: Allocator,
) !void {
    try out.put(allocator, node.id, inherited_z);
    for (node.children.items) |child| {
        // 子节点显式设了正 z_index 才另起层级；否则继承（0 = 未声明）。
        const child_z = child.style.z_index();
        const effective = if (child_z != 0) child_z else inherited_z;
        try collectSubtreeZInherited(child, effective, out, allocator);
    }
}

/// 一条 BulkQuad 降为 1~4 个 DisplayItem。
///
/// 顺序即绘制序，与 Node 路径保持一致：**投影 -> 填充 -> 描边 -> 内阴影**。
/// 投影必须在填充之前（否则盖住对象本体）；内阴影必须在填充之后
/// （它画在对象内部）。`node_style_render.zig` 是同一套顺序。
///
/// 为什么不合并成一个 item：编码器的 `.rect` kind 把 fill(stroke_width=0)
/// 与 stroke(stroke_width>0) 当作互斥两种（见 command_encoder.zig 的映射
/// 注释），一个实例画不了"填充+描边"；Node 路径同样发两个。两边一致，
/// 不存在"合并省实例"的收益。
fn appendQuadItems(
    out: *std.ArrayListUnmanaged(DisplayItem),
    allocator: Allocator,
    q: BulkQuad,
    header: ItemHeader,
) !void {
    if (q.shadow) |s| {
        if (s.color.a > 0) {
            try out.append(allocator, .{ .shadow_rect = .{
                .header = header,
                .x = q.x,
                .y = q.y,
                .w = q.w,
                .h = q.h,
                .color = s.color,
                .blur = s.blur,
                .offset_x = s.offset_x,
                .offset_y = s.offset_y,
                .radius = q.radius,
            } });
        }
    }
    if (q.gradient) |g| {
        // 渐变优先于纯色：给了渐变就不再发 fill_rect，否则纯色会
        // 盖在渐变上（绘制序是后者压前者）。
        if (g.stop_count >= 2) {
            var item: DisplayItem = .{ .multi_gradient_rect = .{
                .header = header,
                .x = q.x,
                .y = q.y,
                .w = q.w,
                .h = q.h,
                .direction = g.direction,
                .radius = q.radius,
                .stop_count = g.stop_count,
                .radial_center_x = q.gradient_center[0],
                .radial_center_y = q.gradient_center[1],
                .conic_start_angle = q.gradient_start_angle,
            } };
            for (g.stops[0..g.stop_count], 0..) |st, i| {
                item.multi_gradient_rect.stop_colors[i] = st.color;
                item.multi_gradient_rect.stop_positions[i] = st.position;
            }
            try out.append(allocator, item);
        }
    } else if (q.color.a > 0) {
        try out.append(allocator, .{ .fill_rect = .{
            .header = header,
            .x = q.x,
            .y = q.y,
            .w = q.w,
            .h = q.h,
            .color = q.color,
            .radius = q.radius,
        } });
    }
    if (q.border_color.a > 0) {
        // 分边优先：四值非全零 ⇒ 走 border_per_side，border_width 被忽略
        // （与 InstanceData.border_widths "全零=用 border_width" 同语义）。
        if (q.hasPerSideBorder()) {
            try out.append(allocator, .{ .border_per_side = .{
                .header = header,
                .x = q.x,
                .y = q.y,
                .w = q.w,
                .h = q.h,
                .color = q.border_color,
                .widths = q.border_widths,
                .radius = q.radius,
            } });
        } else if (q.border_width > 0) {
            try out.append(allocator, .{ .stroke_rect = .{
                .header = header,
                .x = q.x,
                .y = q.y,
                .w = q.w,
                .h = q.h,
                .color = q.border_color,
                .width = q.border_width,
                .radius = q.radius,
            } });
        }
    }
    if (q.inset_shadow) |s| {
        if (s.color.a > 0) {
            // 注意 inset_shadow_rect 自带 `fill`，它在 shader 里连底色一起
            // 画（见 sdf_primitives.metal 的 inset 分支）。这里传 TRANSPARENT：
            // 底色已由上面的 fill_rect 画过，重复画会让半透明填充叠深一层。
            try out.append(allocator, .{ .inset_shadow_rect = .{
                .header = header,
                .x = q.x,
                .y = q.y,
                .w = q.w,
                .h = q.h,
                .fill = Color.TRANSPARENT,
                .shadow_color = s.color,
                .blur = s.blur,
                .offset_x = s.offset_x,
                .offset_y = s.offset_y,
                .radius = q.radius,
            } });
        }
    }
}

// ── 测试 ───────────────────────────────────────────────────────────────
//
// 这组测试是本次拆分的直接收益：三级插入点定位、z 归并、z 继承、锚点为
// null 的降级路径，此前全都只能靠完整 `Cx.render()` 驱动（搭 Cx + 建树 +
// layout + render 一整趟）。现在手搓 display list + 手搓 Node 树就能驱动，
// 单个失败点的定位也从"整帧渲染"缩到"这一层"。

const testing = std.testing;

/// 手搓 display item 的最简形状：fill_rect，带指定 node_id。
fn fillFor(node_id: u32) DisplayItem {
    return .{ .fill_rect = .{
        .header = .{ .transform_id = 0, .clip_id = display_list_mod.INVALID_ID, .node_id = node_id },
        .x = 0,
        .y = 0,
        .w = 8,
        .h = 8,
        .color = Color.hex(0xFF00FF),
    } };
}

/// 测试脚手架：frame_arena + 短命 allocator 的组合与 Cx.render 同构
/// （Cx.allocator 长期持有 display list，frame_arena 只放帧内临时集合）。
const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    list: display_list_mod.DisplayList,
    tree: property_tree_mod.PropertyTree,
    runtime: scene_runtime_mod.SceneRuntime,

    fn init() Fixture {
        return .{
            .arena = std.heap.ArenaAllocator.init(testing.allocator),
            .list = display_list_mod.DisplayList.init(testing.allocator),
            .tree = property_tree_mod.PropertyTree.init(testing.allocator),
            .runtime = scene_runtime_mod.SceneRuntime.init(testing.allocator),
        };
    }
    fn deinit(self: *Fixture) void {
        self.list.deinit();
        self.tree.deinit();
        self.runtime.deinit();
        self.arena.deinit();
    }
    fn host(self: *Fixture, root: ?*Node) Host {
        return .{
            .display_list = &self.list,
            .property_tree = &self.tree,
            .scene_runtime = &self.runtime,
            .root = root,
            .frame_arena = self.arena.allocator(),
            .allocator = testing.allocator,
        };
    }

    /// 挂靠语义的 clip 来源：`append` 第一步就按 `anchor.id` 查 scene_runtime，
    /// 查不到 ⇒ 整层安全降级为"这一帧不画"（见 append 里对"对象糊在 UI 上"
    /// 的防御）。真实路径里这份记录由 render pass 写入，手搓夹具必须补上，
    /// 否则 append 静默早退、display list 里一个批量 item 都不会有。
    /// 只填 node_id / clip_id / transform_id，本层消费的就这三样。
    fn registerRuntime(self: *Fixture, node: *Node, clip_id: u32) !void {
        try self.runtime.put(.{
            .node_id = node.id,
            .local_rect = ComputedRect.init(0, 0, 0, 0),
            .world_bounds = ComputedRect.init(0, 0, 0, 0),
            .transform_id = 0,
            .clip_id = clip_id,
        });
    }
};

/// 给节点写 z_index（StyleExt 字段）。不走 `Node.setStyle`：那条路会顺带
/// markRenderDirty / markWorldDirty，把本测试的节点推进某个**别的 Cx** 的
/// World dirty_set（`Node.create` 依赖进程级 hook，同进程先前 init 过的 Cx
/// 会接住它）。这里只需要 `style.z_index()` 读得到值，直接分配 ext 即可，
/// `Node.destroy` 会负责释放。
fn setZ(a: Allocator, node: *Node, z: i16) !void {
    const ext = try a.create(types.StyleExt);
    ext.* = .{};
    ext.z_index = z;
    node.style.ext = ext;
}

/// buildTree 的返回形状（canvas / obj / overlay / chrome 各自的指针）。
const TestTree = struct {
    root: *Node,
    canvas: *Node,
    obj: *Node,
    overlay: *Node,
    chrome: *Node,
};

/// 手搓一棵三段式树：canvas（锚点）下挂 obj（静态内容）与 overlay（叠加），
/// canvas 之后是 chrome 兄弟。z_index 是驱动 insertPoint 唯一需要的节点状态。
fn buildTree(a: Allocator) !TestTree {
    const root = try node_mod.Node.create(a, 1, .box, .{});
    const canvas = try node_mod.Node.create(a, 2, .box, .{});
    const obj = try node_mod.Node.create(a, 3, .box, .{});
    const overlay = try node_mod.Node.create(a, 4, .box, .{});
    const chrome = try node_mod.Node.create(a, 5, .box, .{});
    try setZ(a, overlay, 31000);
    try root.appendChild(a, canvas);
    try root.appendChild(a, chrome);
    try canvas.appendChild(a, obj);
    try canvas.appendChild(a, overlay);
    return .{ .root = root, .canvas = canvas, .obj = obj, .overlay = overlay, .chrome = chrome };
}

fn freeTree(a: Allocator, root: *Node) void {
    root.destroy(a);
}

test "insertPoint ①：静态内容之后，且不越过交互叠加" {
    var f = Fixture.init();
    defer f.deinit();
    const tree = try buildTree(testing.allocator);
    defer freeTree(testing.allocator, tree.root);

    // display list: [obj(3)] [overlay(4)] [chrome(5)]
    try f.list.append(fillFor(tree.obj.id));
    try f.list.append(fillFor(tree.overlay.id));
    try f.list.append(fillFor(tree.chrome.id));

    var layer = BulkQuadLayer{};
    defer layer.deinit(testing.allocator);
    layer.overlay_z = 31000;
    const h = f.host(tree.root);

    // ① 静态内容（obj=0）之后、叠加（idx 1）之前 ⇒ 1。
    try testing.expectEqual(@as(?usize, 1), layer.insertPoint(tree.canvas, h));
}

test "insertPoint ①：静态内容末尾越过叠加时被夹回叠加之前" {
    var f = Fixture.init();
    defer f.deinit();
    const tree = try buildTree(testing.allocator);
    defer freeTree(testing.allocator, tree.root);

    // 叠加排在静态内容之前（z 31000 的子节点 paint 在前）：
    // last_static = 1（obj）⇒ at = 2，但 first_overlay = 0 ⇒ @min ⇒ 0。
    try f.list.append(fillFor(tree.overlay.id));
    try f.list.append(fillFor(tree.obj.id));
    try f.list.append(fillFor(tree.chrome.id));

    var layer = BulkQuadLayer{};
    defer layer.deinit(testing.allocator);
    layer.overlay_z = 31000;
    try testing.expectEqual(@as(?usize, 0), layer.insertPoint(tree.canvas, f.host(tree.root)));
}

test "insertPoint ②：静态内容为空但有叠加 ⇒ 插到第一个叠加之前" {
    var f = Fixture.init();
    defer f.deinit();
    const tree = try buildTree(testing.allocator);
    defer freeTree(testing.allocator, tree.root);

    // 画布静态内容全降级成批量层、只剩交互叠加（选中态）。
    // 文档序里 chrome 排在 canvas 子树之后：[overlay, chrome]。
    try f.list.append(fillFor(tree.overlay.id));
    try f.list.append(fillFor(tree.chrome.id));

    var layer = BulkQuadLayer{};
    defer layer.deinit(testing.allocator);
    layer.overlay_z = 31000;
    // 插到第一个叠加（idx 0）之前 ⇒ 批量层盖不到选择手柄/尺寸标签。
    try testing.expectEqual(@as(?usize, 0), layer.insertPoint(tree.canvas, f.host(tree.root)));
}

test "insertPoint ③：锚点子树零 item ⇒ 退到锚点之后兄弟的第一个 item 之前" {
    var f = Fixture.init();
    defer f.deinit();
    const tree = try buildTree(testing.allocator);
    defer freeTree(testing.allocator, tree.root);

    // 画布缩小到全对象走批量层时正是这一档：canvas 子树一个 item 都没有。
    try f.list.append(fillFor(tree.chrome.id));

    var layer = BulkQuadLayer{};
    defer layer.deinit(testing.allocator);
    // 无叠加阈值也能走 ③（overlay_ids 空 ⇒ ①② 直接落空）。
    try testing.expectEqual(@as(?usize, 0), layer.insertPoint(tree.canvas, f.host(tree.root)));
}

test "insertPoint 三级全落空（锚点后无任何内容）才返回 null" {
    var f = Fixture.init();
    defer f.deinit();
    const tree = try buildTree(testing.allocator);
    defer freeTree(testing.allocator, tree.root);

    // root 之后本来就没有内容 ⇒ null = 末尾追加，与正确插入点等价。
    var layer = BulkQuadLayer{};
    defer layer.deinit(testing.allocator);
    try testing.expectEqual(@as(?usize, null), layer.insertPoint(tree.canvas, f.host(tree.root)));
}

test "insertPoint 用 header() 认全部 item 种类（不只 fill/stroke/text）" {
    var f = Fixture.init();
    defer f.deinit();
    const tree = try buildTree(testing.allocator);
    defer freeTree(testing.allocator, tree.root);

    // chrome 只产 image_quad（曾被三选一 switch 漏掉 ⇒ ③ 扫不到参照物）。
    try f.list.append(.{ .image_quad = .{
        .header = .{ .transform_id = 0, .clip_id = display_list_mod.INVALID_ID, .node_id = tree.chrome.id },
        .x = 0,
        .y = 0,
        .w = 4,
        .h = 4,
        .texture_id = 0,
    } });

    var layer = BulkQuadLayer{};
    defer layer.deinit(testing.allocator);
    try testing.expectEqual(@as(?usize, 0), layer.insertPoint(tree.canvas, f.host(tree.root)));
}

test "insertPoint 跳过控制 token（scroll-clip 带真实 node_id 也不算内容）" {
    var f = Fixture.init();
    defer f.deinit();
    const tree = try buildTree(testing.allocator);
    defer freeTree(testing.allocator, tree.root);

    // paint pass 末尾追加的那对 scroll-clip token 落在列表末尾且带 obj 的
    // node_id：算进"最后一个静态 item"会让插入点越过全部 chrome。
    try f.list.append(fillFor(tree.obj.id));
    try f.list.append(.{ .push_clip = .{
        .header = .{ .transform_id = 0, .clip_id = display_list_mod.INVALID_ID, .node_id = tree.obj.id },
        .x = 0,
        .y = 0,
        .w = 8,
        .h = 8,
    } });
    try f.list.append(.{ .pop_clip = .{
        .header = .{ .transform_id = 0, .clip_id = display_list_mod.INVALID_ID, .node_id = tree.obj.id },
    } });
    try f.list.append(fillFor(tree.chrome.id));

    var layer = BulkQuadLayer{};
    defer layer.deinit(testing.allocator);
    // token 不算 ⇒ last_static = 0 ⇒ at = 1；chrome 之后的 token 不参与。
    try testing.expectEqual(@as(?usize, 1), layer.insertPoint(tree.canvas, f.host(tree.root)));
}

test "collectItemZ：z 继承（容器 z=3 的子节点归 3，自身显式才另起）" {
    var f = Fixture.init();
    defer f.deinit();
    const a = testing.allocator;
    const tree = try buildTree(a);
    // holder 挂进 canvas 子树 ⇒ 由 root.destroy 一并递归释放，不能单独 destroy。
    defer freeTree(a, tree.root);

    // 容器 z=3，内部再挂两个子节点：一个不设 z（应继承 3），一个设 z=7。
    const holder = try node_mod.Node.create(a, 6, .box, .{});
    try setZ(a, holder, 3);
    const plain_child = try node_mod.Node.create(a, 7, .box, .{});
    const z_child = try node_mod.Node.create(a, 8, .box, .{});
    try setZ(a, z_child, 7);
    try holder.appendChild(a, plain_child);
    try holder.appendChild(a, z_child);
    try tree.canvas.appendChild(a, holder);

    try f.list.append(fillFor(plain_child.id));
    try f.list.append(fillFor(z_child.id));

    var item_z: std.ArrayListUnmanaged(?i16) = .{};
    defer item_z.deinit(f.arena.allocator());
    try BulkQuadLayer.collectItemZ(tree.canvas, f.host(tree.root), &item_z, f.arena.allocator());

    // 锚点子树外的节点（chrome）无归属为 null；继承链上 plain_child=3、z_child=7。
    try testing.expectEqual(@as(?i16, 3), item_z.items[0]);
    try testing.expectEqual(@as(?i16, 7), item_z.items[1]);
}

test "appendSegmented：z 归并按 z 升序，同 z 时 Node 在前" {
    var f = Fixture.init();
    defer f.deinit();
    const tree = try buildTree(testing.allocator);
    defer freeTree(testing.allocator, tree.root);
    // 挂靠语义必须能查到锚点 runtime，否则 append 整层降级为不画。
    try f.registerRuntime(tree.canvas, display_list_mod.INVALID_ID);

    // 一个 z=50 的 Node；批量层里有 z=10（绿）与 z=90（蓝）两段。
    // 正确顺序必须是 绿 -> Node -> 蓝。
    try setZ(testing.allocator, tree.obj, 50);
    try f.list.append(fillFor(tree.obj.id));

    var layer = BulkQuadLayer{};
    defer layer.deinit(testing.allocator);
    layer.anchor = tree.canvas;
    try layer.quads.appendSlice(testing.allocator, &.{
        .{ .x = 0, .y = 0, .w = 4, .h = 4, .color = Color.hex(0x00FF00), .z_index = 10 },
        .{ .x = 0, .y = 0, .w = 4, .h = 4, .color = Color.hex(0x0000FF), .z_index = 90 },
    });

    try layer.append(f.host(tree.root));

    var gi: ?usize = null;
    var ri: ?usize = null;
    var bi: ?usize = null;
    for (f.list.items.items, 0..) |it, idx| {
        switch (it) {
            .fill_rect => |fr| {
                if (std.meta.eql(fr.color, Color.hex(0x00FF00))) gi = idx;
                if (std.meta.eql(fr.color, Color.hex(0xFF00FF))) ri = idx;
                if (std.meta.eql(fr.color, Color.hex(0x0000FF))) bi = idx;
            },
            else => {},
        }
    }
    try testing.expect(gi != null and ri != null and bi != null);
    try testing.expect(gi.? < ri.?); // z=10 的批量项在 z=50 的 Node 之下
    try testing.expect(ri.? < bi.?); // z=90 的批量项在 z=50 的 Node 之上
}

test "appendSegmented：同 z 段内保持提交顺序（后者盖前者）" {
    var f = Fixture.init();
    defer f.deinit();
    const tree = try buildTree(testing.allocator);
    defer freeTree(testing.allocator, tree.root);
    try f.registerRuntime(tree.canvas, display_list_mod.INVALID_ID);

    try f.list.append(fillFor(tree.obj.id));

    var layer = BulkQuadLayer{};
    defer layer.deinit(testing.allocator);
    layer.anchor = tree.canvas;
    try layer.quads.appendSlice(testing.allocator, &.{
        .{ .x = 0, .y = 0, .w = 4, .h = 4, .color = Color.hex(0x111111), .z_index = 5 },
        .{ .x = 0, .y = 0, .w = 4, .h = 4, .color = Color.hex(0x222222), .z_index = 5 },
    });
    try layer.append(f.host(tree.root));

    var first_idx: ?usize = null;
    var second_idx: ?usize = null;
    for (f.list.items.items, 0..) |it, idx| {
        switch (it) {
            .fill_rect => |fr| {
                if (std.meta.eql(fr.color, Color.hex(0x111111))) first_idx = idx;
                if (std.meta.eql(fr.color, Color.hex(0x222222))) second_idx = idx;
            },
            else => {},
        }
    }
    try testing.expect(first_idx != null and second_idx != null);
    try testing.expect(first_idx.? < second_idx.?);
}

test "appendSegmented：尾部落位后不再追加（不越过 chrome）" {
    var f = Fixture.init();
    defer f.deinit();
    const tree = try buildTree(testing.allocator);
    defer freeTree(testing.allocator, tree.root);

    // chrome 是锚点之后的兄弟；z=90 的段比子树里任何 Node 都靠后，
    // 必须在 chrome **之前**落位，不能越过它再追加一份。
    try f.registerRuntime(tree.canvas, display_list_mod.INVALID_ID);
    try f.list.append(fillFor(tree.obj.id));
    try f.list.append(fillFor(tree.chrome.id));

    var layer = BulkQuadLayer{};
    defer layer.deinit(testing.allocator);
    layer.anchor = tree.canvas;
    try layer.quads.appendSlice(testing.allocator, &.{
        .{ .x = 0, .y = 0, .w = 4, .h = 4, .color = Color.hex(0x00FF00), .z_index = 90 },
    });
    try layer.append(f.host(tree.root));

    var gi: ?usize = null;
    var ci: ?usize = null;
    var green_count: usize = 0;
    for (f.list.items.items, 0..) |it, idx| {
        switch (it) {
            .fill_rect => |fr| {
                if (std.meta.eql(fr.color, Color.hex(0x00FF00))) {
                    gi = idx;
                    green_count += 1;
                }
                if (fr.header.node_id == tree.chrome.id) ci = idx;
            },
            else => {},
        }
    }
    try testing.expectEqual(@as(usize, 1), green_count); // 不追加第二次
    try testing.expect(gi != null and ci != null);
    try testing.expect(gi.? < ci.?); // chrome 仍盖在批量层之上
}

test "append：锚点为 null 时降级为末尾追加且不带裁剪" {
    var f = Fixture.init();
    defer f.deinit();

    try f.list.append(fillFor(1));

    var layer = BulkQuadLayer{};
    defer layer.deinit(testing.allocator);
    layer.anchor = null; // 全屏 overlay 语义
    try layer.quads.appendSlice(testing.allocator, &.{
        .{ .x = 5, .y = 6, .w = 7, .h = 8, .color = Color.hex(0x00FF00) },
    });
    try layer.append(f.host(null));

    try testing.expectEqual(@as(usize, 2), f.list.items.items.len);
    const last = f.list.items.items[1].fill_rect;
    try testing.expectEqual(@as(f32, 5), last.x);
    try testing.expectEqual(@as(u32, 0), last.header.node_id); // 无锚点 ⇒ node_id 0
    try testing.expectEqual(display_list_mod.INVALID_ID, last.header.clip_id); // 不裁剪
    try testing.expectEqual(@as(u32, 0), last.header.transform_id); // identity
}

test "append：锚点子树零 item 时仍插在 chrome 之下（三级定位的 ③）" {
    var f = Fixture.init();
    defer f.deinit();
    const tree = try buildTree(testing.allocator);
    defer freeTree(testing.allocator, tree.root);

    try f.registerRuntime(tree.canvas, display_list_mod.INVALID_ID);
    try f.list.append(fillFor(tree.chrome.id));

    var layer = BulkQuadLayer{};
    defer layer.deinit(testing.allocator);
    layer.anchor = tree.canvas;
    try layer.quads.appendSlice(testing.allocator, &.{
        .{ .x = 0, .y = 0, .w = 4, .h = 4, .color = Color.hex(0x00FF00) },
    });
    try layer.append(f.host(tree.root));

    var bulk_idx: ?usize = null;
    var chrome_idx: ?usize = null;
    for (f.list.items.items, 0..) |it, idx| {
        switch (it) {
            .fill_rect => |fr| {
                if (fr.header.node_id == tree.canvas.id) bulk_idx = idx;
                if (fr.header.node_id == tree.chrome.id) chrome_idx = idx;
            },
            else => {},
        }
    }
    try testing.expect(bulk_idx != null and chrome_idx != null);
    try testing.expect(bulk_idx.? < chrome_idx.?);
}

test "append：clip_rect 建按矩形寻址的 ClipNode，同帧同矩形只建一个" {
    var f = Fixture.init();
    defer f.deinit();
    const tree = try buildTree(testing.allocator);
    defer freeTree(testing.allocator, tree.root);

    // 锚点 clip = 7（任意值）：ClipNode 的 parent 必须挂它，clip_rect 与
    // 锚点 clip 相交的语义才能成立（见 BulkClipCache.headerFor）。
    try f.registerRuntime(tree.canvas, 7);
    try f.list.append(fillFor(tree.chrome.id));

    var layer = BulkQuadLayer{};
    defer layer.deinit(testing.allocator);
    layer.anchor = tree.canvas;
    const clip = [4]f32{ 1, 2, 3, 4 };
    try layer.quads.appendSlice(testing.allocator, &.{
        .{ .x = 0, .y = 0, .w = 4, .h = 4, .color = Color.hex(0x00FF00), .clip_rect = clip },
        .{ .x = 8, .y = 8, .w = 4, .h = 4, .color = Color.hex(0x00FF00), .clip_rect = clip },
    });
    const clips_before = f.tree.clips.items.len;
    try layer.append(f.host(tree.root));

    var bulk_clip_ids: [2]u32 = .{ 0, 0 };
    var bulk_n: usize = 0;
    var chrome_clip: u32 = 0;
    for (f.list.items.items) |it| {
        switch (it) {
            .fill_rect => |fr| {
                if (fr.header.node_id == tree.canvas.id) {
                    bulk_clip_ids[bulk_n] = fr.header.clip_id;
                    bulk_n += 1;
                } else chrome_clip = fr.header.clip_id;
            },
            else => {},
        }
    }
    // 批量层确实产出了两条 quad（否则下面的断言会真空通过）。
    try testing.expectEqual(@as(usize, 2), bulk_n);
    try testing.expect(bulk_clip_ids[0] != display_list_mod.INVALID_ID);
    // 同矩形只建一个 ClipNode，两条 quad 共享同一个 clip_id。
    try testing.expectEqual(bulk_clip_ids[0], bulk_clip_ids[1]);
    try testing.expectEqual(@as(usize, clips_before + 1), f.tree.clips.items.len);
    const node = f.tree.clips.items[bulk_clip_ids[0]];
    try testing.expectEqual(@as(f32, 1), node.local_rect.x);
    try testing.expectEqual(@as(f32, 2), node.local_rect.y);
    try testing.expectEqual(@as(f32, 3), node.local_rect.w);
    try testing.expectEqual(@as(f32, 4), node.local_rect.h);
    // 新 ClipNode 的 parent 挂锚点 clip ⇒ 链式发射 = 锚点 clip ∩ quad clip。
    try testing.expectEqual(@as(u32, 7), node.parent);
    // chrome 的 item 不受影响（手搓的那条仍是无裁剪）。
    try testing.expectEqual(display_list_mod.INVALID_ID, chrome_clip);
}

test "set：空切片关闭该层并保留容量；quads 被拷贝可立即复用" {
    var f = Fixture.init();
    defer f.deinit();

    var layer = BulkQuadLayer{};
    defer layer.deinit(testing.allocator);
    const src = [_]BulkQuad{.{ .x = 1, .y = 2, .w = 3, .h = 4, .color = Color.hex(0xABCDEF) }};
    try layer.set(f.host(null), null, &src, null);
    try testing.expectEqual(@as(usize, 1), layer.quads.items.len);

    // 覆盖后立即改源数组不影响层内拷贝。
    var mutated = src;
    mutated[0].x = 99;
    try testing.expectEqual(@as(f32, 1), layer.quads.items[0].x);

    try layer.set(f.host(null), null, &.{}, null);
    try testing.expectEqual(@as(usize, 0), layer.quads.items.len);
    try testing.expect(layer.quads.capacity > 0); // 保留容量，避免重复 realloc
}

test "setVersioned：同版本 ⇒ unchanged，换版本 / 传 null ⇒ 保守重画" {
    var f = Fixture.init();
    defer f.deinit();

    var layer = BulkQuadLayer{};
    defer layer.deinit(testing.allocator);
    const q = [_]BulkQuad{.{ .x = 0, .y = 0, .w = 4, .h = 4, .color = Color.hex(0x00FF00) }};

    // 首次提交：上一帧没有版本 ⇒ same = false。
    try layer.setVersioned(f.host(null), null, &q, null, 7);
    try testing.expect(!layer.unchanged);
    // 同版本再来一次 ⇒ unchanged = true（零脏帧快速路径成立）。
    try layer.setVersioned(f.host(null), null, &q, null, 7);
    try testing.expect(layer.unchanged);
    // 版本变化 ⇒ 重画。
    try layer.setVersioned(f.host(null), null, &q, null, 8);
    try testing.expect(!layer.unchanged);
    // 传 null = 无法自证 ⇒ 退化为保守重画，且版本号被清掉。
    try layer.setVersioned(f.host(null), null, &q, null, null);
    try testing.expect(!layer.unchanged);
    try testing.expectEqual(@as(?u64, null), layer.version);
}

test "dropIfInsideSubtree：锚点在子树内 ⇒ 清锚点并关层；否则不动" {
    var f = Fixture.init();
    defer f.deinit();
    const tree = try buildTree(testing.allocator);
    defer freeTree(testing.allocator, tree.root);

    var layer = BulkQuadLayer{};
    defer layer.deinit(testing.allocator);
    layer.anchor = tree.canvas;
    layer.overlay_z = 31000;
    try layer.quads.appendSlice(testing.allocator, &.{
        .{ .x = 0, .y = 0, .w = 4, .h = 4, .color = Color.hex(0x00FF00) },
    });

    // 锚点不在该子树（销毁的是 chrome）⇒ 不动。
    try testing.expect(!layer.dropIfInsideSubtree(tree.chrome));
    try testing.expect(layer.anchor == tree.canvas);
    try testing.expectEqual(@as(usize, 1), layer.quads.items.len);

    // 销毁画布子树本身 ⇒ 锚点清空、整层关闭。
    try testing.expect(layer.dropIfInsideSubtree(tree.canvas));
    try testing.expect(layer.anchor == null);
    try testing.expectEqual(@as(?i16, null), layer.overlay_z);
    try testing.expectEqual(@as(usize, 0), layer.quads.items.len);
}

test "dropIfInsideSubtree：锚点是子树深处的后代也算" {
    var f = Fixture.init();
    defer f.deinit();
    const tree = try buildTree(testing.allocator);
    defer freeTree(testing.allocator, tree.root);

    var layer = BulkQuadLayer{};
    defer layer.deinit(testing.allocator);
    // 锚点挂在 obj（canvas 的孙辈），销毁的是 canvas 整棵子树。
    layer.anchor = tree.obj;
    try testing.expect(layer.dropIfInsideSubtree(tree.canvas));
    try testing.expect(layer.anchor == null);
}

test "BulkQuad.hasPerSideBorder" {
    var q = BulkQuad{ .x = 0, .y = 0, .w = 1, .h = 1, .color = Color.WHITE };
    try testing.expect(!q.hasPerSideBorder());
    q.border_widths = .{ 0, 1, 0, 0 };
    try testing.expect(q.hasPerSideBorder());
}

test "appendQuadItems：一条 quad 最多 MAX_ITEMS_PER_QUAD 个 item，顺序 投影→填充→描边→内阴影" {
    var out: std.ArrayListUnmanaged(DisplayItem) = .{};
    defer out.deinit(testing.allocator);

    const q = BulkQuad{
        .x = 1,
        .y = 2,
        .w = 3,
        .h = 4,
        .color = Color.hex(0x00FF00),
        .border_color = Color.hex(0x000000),
        .border_width = 1.5,
        .shadow = .{ .color = Color.rgba(0, 0, 0, 80), .blur = 8 },
        .inset_shadow = .{ .color = Color.rgba(0, 0, 0, 80), .blur = 4 },
    };
    const header = ItemHeader{ .transform_id = 0, .node_id = 42 };
    try appendQuadItems(&out, testing.allocator, q, header);
    try testing.expectEqual(@as(usize, 4), out.items.len);
    try testing.expect(out.items[0] == .shadow_rect);
    try testing.expect(out.items[1] == .fill_rect);
    try testing.expect(out.items[2] == .stroke_rect);
    try testing.expect(out.items[3] == .inset_shadow_rect);
    // 内阴影不得重复画底色（fill = TRANSPARENT，见注释）。
    try testing.expect(std.meta.eql(Color.TRANSPARENT, out.items[3].inset_shadow_rect.fill));
}

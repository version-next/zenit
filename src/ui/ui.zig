//! zenit, Zig GUI Framework
//!
//! **This file is the entire public API.** Consumers use `ui.*` and
//! `ui.<group>.*` only, reaching into `core/`, `reactive/`, `i18n/` or any
//! other internal module is unsupported. Breaking either namespace is an
//! API break (see docs/API_STABILITY.md).
//!
//! Public surface organized in two layers:
//!
//! ## Tier 1, top-level (`ui.X`)
//!
//! The minimum set every app needs. Intentionally short so newcomers can
//! scroll this file end-to-end in 60 seconds:
//!
//!   - **Runtime**:  `Cx`, `Node`, `Scope`, `Style`
//!   - **Layout**:   `Padding`, `Margin`, `Border`, `Sizing`, `Color`,
//!                   `Direction`, `FlexWrap`, `CursorShape`
//!   - **Builders**: `box`, `hstack`, `vstack`, `text`, `image`, `imageTint`,
//!                   `icon`, `iconTint`, `svg`, `svgTint`, `spacer`,
//!                   `clickable`, `grid`, `GridStyle`
//!   - **Reactive**: `Signal`, `Memo`, `createEffect`, `createMemo`
//!   - **A11y**:     `A11yRole`, `A11yProps`
//!   - **Control flow**: `Show`, `For`, `Match`
//!
//! ## Tier 2, sub-namespaces (`ui.<group>.X`)
//!
//! Grouped by concern. Reach for these when you need more than the basics:
//!
//!   - `ui.widgets`, full component library: `Button`, `Input`, `Modal`,
//!                        `Tabs`, `VirtualList`, `Calendar`, `Form`, ...
//!   - `ui.fx`, animation, physics, router, view transitions
//!   - `ui.events`, full `Event` enum + every event payload type
//!   - `ui.hooks`, `useHover`, `useFocusRing`, `useHoverHighlight`, ...
//!   - `ui.reactive`, full reactive system (`Signal` etc. also at top)
//!   - `ui.focus`, `FocusManager`, focus scopes, tab order
//!   - `ui.actions`, keybinding / command dispatch
//!   - `ui.theme`, `ThemeTokens` + builtin light/dark themes
//!   - `ui.control_flow`, `Show`/`For`/`Match` (also top-level)
//!   - `ui.assets`, `SvgAsset` registry, builtin icons
//!   - `ui.hit`, hit-testing types (`HitQuery`, `HitShapeSpec`, ...)
//!   - `ui.path`, path geometry types (`PathCommand`, `Transform2D`, ...)
//!   - `ui.devtools`, `Inspector`, debug tracing
//!
//! Everything not on these two tiers is internal. Reach for `ui.core.*` only
//! when prototyping a fix to the framework itself.
const std = @import("std");

const core = @import("core.zig");
const reactive_mod = @import("reactive.zig");
const events_mod = @import("events.zig");
const theme_mod = @import("theme.zig");
const hooks_mod = @import("hooks.zig");
const focus_mod = @import("focus.zig");
const actions_mod = @import("actions.zig");
const control_flow_mod = @import("control_flow.zig");
const svg_assets_mod = @import("svg_assets.zig");

// ============================================================================
// Tier 2: sub-namespaces, grouped public API
// ============================================================================

/// Full component library. See `components/mod.zig`.
pub const widgets = @import("components/mod.zig");

/// Animation / physics / view transitions / router. See `fx.zig`.
pub const fx = @import("fx.zig");

/// Full event types: `Event`, `KeyCode`, `Modifiers`, every payload struct.
pub const events = events_mod;

/// Built-in `useX` hooks (`useHover`, `useFocusRing`, ...).
pub const hooks = hooks_mod;

/// Reactive system: `Signal`, `Memo`, `Scope`, `createEffect`, `Context`, `Store`.
/// (The most common four are also re-exported at the top level for convenience.)
pub const reactive = reactive_mod;

/// Focus manager + tab order + focus scopes.
pub const focus = focus_mod;

/// Keybinding and command dispatch.
pub const actions = actions_mod;

/// Theme tokens + built-in light/dark palettes.
pub const theme = theme_mod;

/// `Show` / `For` / `Match` declarative control-flow components.
/// (Also re-exported at the top level for convenience.)
pub const control_flow = control_flow_mod;

/// Headless interaction primitives (`interaction.drag`, `interaction.range_hover`).
/// They own event routing only, no Node output, no business state.
pub const interaction = @import("interaction/mod.zig");

/// SVG asset registry (the icon system) and built-in icon set.
pub const assets = svg_assets_mod;

/// Full icon provider catalog. Public builds default to Lucide (ISC); internal
/// applications may select or inject a separately licensed provider in their
/// build graph. Names in this namespace are provider-specific. Dynamic callers
/// can use `ui.icons.get("kebab-name")` or enumerate `ui.icons.all`.
pub const icons = @import("zenit_icons");

/// Stable semantic icon subset used by Zenit's own components. Prefer this
/// namespace in reusable framework/package code that must compile with every
/// provider; application-specific artwork should use the full `ui.icons`
/// catalog or its private provider module directly.
pub const system_icons = @import("zenit_system_icons");

/// Hit-testing query API (`HitQuery`, `HitShapeSpec`, `HitBehavior`, ...).
/// Most apps don't need this directly, `Button`/`Input` already wire hit-test.
/// 系统剪贴板 / 文件对话框。这些函数收 `?*SystemSdk` 而不是挂在 `Cx` 上：
/// `ui.platform_services.clipboardSetText(cx.system_sdk, text)`。
pub const platform_services = core.platform_services;

pub const hit = struct {
    pub const NodeHandle = core.NodeHandle;
    pub const HitQuery = core.HitQuery;
    pub const HitQueryKind = core.HitQueryKind;
    pub const HitResult = core.HitResult;
    pub const HitShapeSpec = core.HitShapeSpec;
    pub const ClipShapeSpec = core.ClipShapeSpec;
    pub const HitBehavior = core.HitBehavior;
    pub const HitRoles = core.HitRoles;
    pub const HitProxySpec = core.HitProxySpec;
};

/// Path geometry types, used by custom drawing & SVG hit shapes.
pub const path = struct {
    pub const Transform2D = core.Transform2D;
    pub const PathFillRule = core.PathFillRule;
    pub const LineJoin = core.LineJoin;
    pub const PathCommand = core.PathCommand;
    pub const QuadraticPathCommand = core.QuadraticPathCommand;
    pub const CubicPathCommand = core.CubicPathCommand;
    pub const PathGeometry = core.PathGeometry;
    pub const createSvgDocumentPathGeometry = core.createSvgDocumentPathGeometry;
};

/// Inspector / debug-trace surface.
///
/// `ui.devtools.overlay` is the in-window inspector overlay (a one-line
/// `attach(...)` adds dashed-rect hover highlighting). The rest of `devtools`
/// is the standalone DevTools panel, mount it in a second window for a full
/// elements / components / performance inspector.
pub const devtools = @import("devtools.zig");

/// Per-Cx Chrome-style diagnostic console. Use `cx.console()` to obtain the
/// console attached to a window.
pub const console = @import("console.zig");

/// Phase 6 手势识别 + 仲裁层（tap/pan/long_press/triple_tap + requireFailure 关系）。
pub const gesture = @import("input/gesture_recognizer.zig");

/// 平台无障碍接线。**这不是应用作者用的东西**，组件的 a11y 走
/// `node.behavior.interaction.a11y`（见 A11yRole / A11yProps）。
///
/// 这里只暴露平台运行时接线需要的那一个入口：zenit_app 在 App.init 里把
/// 原生侧实装的 `zenit_a11y_push_*` 注册进来。
///
/// 此前这里是三个平级顶层命名空间（a11y_tree / a11y_router /
/// a11y_macos_bridge），把 a11y 的内部分层原样摊在公共面上；tree 与
/// router 的消费者全在 src/ui 内部，直连 import 即可。
pub const a11y = struct {
    pub const macos_bridge = @import("a11y/macos_bridge.zig");
};

/// Phase 7 Radix-style controlled/uncontrolled props 类型。
pub const ControlledProp = @import("components/controlled.zig").ControlledProp;

/// v0.2-P8 Select headless 骨架（Radix-style slot 解耦）。
pub const select_headless = @import("components/select_headless/mod.zig");

/// Inspector data structure (used by the panel + accessible programmatically).
// 折行布局产物的只读类型见下面的 TextLayout / LineInfo。整个
// `core.text_layout` 模块不再导出，宿主拿这两个类型就够，模块本身
// 含 computeTextLayout 等内部函数。
/// 系统字体目录（字体选择器的数据层）：枚举家族 + 判定每行该画什么。
/// ⚠ 只做枚举与元数据，字体族轴在渲染管线里还不存在，选中一个家族
/// 并不能让它出现在画布上，那需要 TextProps/text_run/FontSelector 一起加 family。
/// GlyphRun shape 管线的字体解析入口。App 必须把自己的 FontSelector 装
/// 进去，否则光标/选区与绘制用两套字体（见 zenit_app.App.setFontSelector）。
///
/// 此前这里导出的是整个 `core.layout_engine`（约 2400 行，含 layout /
/// computeTextLayout 等纯内部函数），动机只是为了够到下面这一个函数。
/// 收窄成窄命名空间：布局引擎本身是引擎内部，不该出现在公共面上。
pub const text_shaping = struct {
    pub const ShapeFontResolveFn = core.layout_engine.ShapeFontResolveFn;
    pub const setShapeFontResolver = core.layout_engine.setShapeFontResolver;
    pub const setDrawnTextMeasure = core.layout_engine.setDrawnTextMeasure;
};
/// 文字折行布局产物（只读）。宿主（如白板类 App）在"文字太小、改画版式
/// 色块"的降级档需要每行的真实几何（byte 区间 + 测量宽度）：用这个类型让
/// 降级复用**同一份 glyph shaping 测量**，而不是另写一套字符宽度估算。
///
/// 取法是 `node.getLayoutOutput().artifacts.text_layout`，不需要 import
/// 模块本身。
pub const TextLayout = core.text_layout.TextLayout;
/// `TextLayout` 里的单行几何。
pub const LineInfo = core.text_layout.LineInfo;
/// 逐视觉行 `TextProps.text_align` 的起点偏移。宿主自己算光标 / 命中 / 选区时必须用
/// 这一个公式（与绘制同源），否则居中文字上的光标与字形错位。
pub const textAlignLineOffset = core.text_layout.alignLineOffset;
/// Accessibility bridge, wires nodes' `a11y` props to the platform.

// ============================================================================
// Tier 1: top-level, the minimum every app uses
// ============================================================================

// ── Runtime ──
pub const Cx = core.Cx;
pub const AfterLayoutResult = core.AfterLayoutResult;
pub const AfterLayoutFn = core.AfterLayoutFn;
pub const max_after_layout_rounds = core.max_after_layout_rounds;
/// 批量矩形提交单元（见 core.BulkQuad / Cx.setBulkQuads）。
pub const BulkQuad = core.BulkQuad;
pub const Node = core.Node;
pub const PointerDownFocus = core.PointerDownFocus;
pub const Scope = reactive_mod.Scope;
pub const Style = core.Style;
pub const BoxStyle = core.BoxStyle;

// ── Layout primitives ──
pub const Color = core.Color;
pub const BlendMode = core.BlendMode;
pub const Padding = core.Padding;
pub const ComputedRect = core.ComputedRect;
pub const Margin = core.Margin;
pub const Border = core.Border;
pub const Outline = core.Outline;
pub const Sizing = core.Sizing;
pub const Size = core.Size;
pub const Point = core.Point;
pub const Direction = core.Direction;
pub const FlexWrap = core.FlexWrap;
pub const TextWrap = core.TextWrap;
pub const TextAlign = core.TextAlign;
pub const CursorShape = core.CursorShape;
pub const CursorRegion = core.CursorRegion;
pub const CursorToken = core.CursorToken;
pub const CustomCursorDesc = core.CustomCursorDesc;
pub const TextProps = core.TextProps;
pub const ImageProps = core.ImageProps;
pub const CornerRadius = core.CornerRadius;
pub const Shadow = core.Shadow;
pub const InsetShadow = core.InsetShadow;
pub const Gradient = core.Gradient;
pub const GradientStop = core.GradientStop;
pub const MultiGradient = core.MultiGradient;
pub const GradientDirection = core.GradientDirection;
pub const GlassParams = core.GlassParams;
pub const GlassSurface = core.GlassSurface;

// ── Node constructors ──
pub const box = core.box;
pub const animateNode = core.animateNode;
pub const hstack = core.hstack;
pub const vstack = core.vstack;
pub const text = core.text;
pub const textFmt = core.textFmt;

// ── Styled constructors（主题安全的具名样式函数消费端，见 docs/STYLING.md） ──
pub const boxStyled = core.boxStyled;
pub const hstackStyled = core.hstackStyled;
pub const vstackStyled = core.vstackStyled;
pub const textStyled = core.textStyled;
pub const TextStyle = core.TextStyle;

// ── Recipe（CVA/Panda 风格样式变体系统，见 docs/STYLING.md） ──
/// 模块命名空间：`ui.recipe.recipe(...)` / `ui.recipe.slotRecipe(...)`
pub const recipe = core.recipe;
pub const ConditionalStyle = core.ConditionalStyle;
pub const ThemeTokens = theme_mod.ThemeTokens;
pub const ColorScheme = theme_mod.ColorScheme;

/// 任意值逃生舱，对标 Panda CSS 的 arbitrary values（`[18px]` / `[#316ff6]`）。
///
/// token 是默认，但设计上确有不在 scale 上的值（对齐特定视觉稿、一次性的
/// 品牌色、像素级微调）。这时**不要**写裸字面量，用 `ui.arb.*` 包一层：
///
/// ```zig
/// .font_size = ui.arb.px(18),          // 有意off-scale，非偷懒
/// .background = ui.arb.hex(0x316FF6),  // 一次性品牌色
/// ```
///
/// 零运行时成本（inline 恒等）；价值在语义与工具链：
///   - 读者一眼区分"有意的任意值"与"该迁 token 的偷懒字面量"；
///   - scripts/check_style_literals.sh 的 ratchet 只抓裸字面量，arb 天然放行；
///   - 全局 grep `ui.arb` 即可盘点所有 off-token 值，评估是否该晋升为 token。
pub const arb = struct {
    /// 任意尺寸/字号（px）
    pub inline fn px(v: f32) f32 {
        return v;
    }
    /// 任意颜色（0xRRGGBB）
    pub inline fn hex(rgb: u24) Color {
        return Color.hex(rgb);
    }
    /// 任意颜色（0xRRGGBB + alpha 0..1）
    pub inline fn hexA(rgb: u24, alpha: f32) Color {
        const a: u8 = @intFromFloat(@round(std.math.clamp(alpha, 0.0, 1.0) * 255.0));
        return Color.hex(rgb).withAlpha(a);
    }
};
pub const image = core.image;
pub const imageTint = core.imageTint;
pub const svg = core.svg;
pub const svgTint = core.svgTint;
pub const spacer = core.spacer;
pub const clickable = core.clickable;
pub const grid = core.grid;
pub const GridStyle = core.GridStyle;

pub const SvgAsset = svg_assets_mod.Asset;

pub fn icon(cx: *Cx, asset: SvgAsset, style: Style) !*Node {
    return core.icon(cx, asset, applyAssetSizeDefaults(asset, style));
}

pub fn iconTint(cx: *Cx, asset: SvgAsset, tint: Color, style: Style) !*Node {
    return core.iconTint(cx, asset, tint, applyAssetSizeDefaults(asset, style));
}

/// BoxStyle icon constructor with background/opacity paint overrides.
/// Kept additive so existing callers that pass a concrete Style remain source
/// compatible; new code that needs opacity should use this entry point.
pub fn iconTintStyled(cx: *Cx, asset: SvgAsset, tint: Color, style: core.BoxStyle) !*Node {
    return core.iconTintStyled(cx, asset, tint, applyAssetBoxSizeDefaults(asset, style));
}

pub fn iconStyled(cx: *Cx, asset: SvgAsset, style: core.BoxStyle) !*Node {
    return core.iconStyled(cx, asset, applyAssetBoxSizeDefaults(asset, style));
}

fn applyAssetSizeDefaults(asset: SvgAsset, style: Style) Style {
    var resolved = style;
    if (!isFixedPxSizing(resolved.width)) {
        resolved.width = .{ .px = @floatFromInt(asset.default_width) };
    }
    if (!isFixedPxSizing(resolved.height)) {
        resolved.height = .{ .px = @floatFromInt(asset.default_height) };
    }
    return resolved;
}

fn applyAssetBoxSizeDefaults(asset: SvgAsset, style: core.BoxStyle) core.BoxStyle {
    var resolved = style;
    if (resolved.width == null or !isFixedPxSizing(resolved.width.?)) {
        resolved.width = .{ .px = @floatFromInt(asset.default_width) };
    }
    if (resolved.height == null or !isFixedPxSizing(resolved.height.?)) {
        resolved.height = .{ .px = @floatFromInt(asset.default_height) };
    }
    return resolved;
}

fn isFixedPxSizing(sizing: Sizing) bool {
    return switch (sizing) {
        .px => true,
        else => false,
    };
}

// ── Reactive essentials (full surface lives in `ui.reactive`) ──
pub const Signal = reactive_mod.Signal;
pub const Memo = reactive_mod.Memo;
pub const createEffect = reactive_mod.createEffect;
pub const createMemo = reactive_mod.createMemo;

// ── Control flow (full surface lives in `ui.control_flow`) ──
pub const Show = control_flow_mod.Show;
pub const For = control_flow_mod.For;
pub const Match = control_flow_mod.Match;

// ── A11y ──
pub const A11yRole = core.A11yRole;
pub const A11yProps = core.A11yProps;
pub const A11yOrientation = core.A11yOrientation;
pub const A11ySortDirection = core.A11ySortDirection;
pub const A11yRect = core.A11yRect;
pub const A11yValueRange = core.A11yValueRange;
pub const TextInputClient = core.TextInputClient;
pub const TextInputSelection = core.TextInputSelection;

// ── Handler / event types most apps need at the top level ──
// (Full `Event` enum + payload structs live in `ui.events`.)
pub const HandlerRef = core.HandlerRef;

// ============================================================================
// 注：原 `core_internal` 顶层暴露在 Phase 7 删除（OSS boundary 纪律）。
// 框架 contributor 直接 @import("core.zig")（在 ui module 内部）；
// 外部 consumer 应当只用 `ui.*` 命名空间公开 API。
// ============================================================================

test {
    _ = @import("hooks_test.zig");
    std.testing.refAllDecls(@This());
}

test "公共命名空间不泄漏渲染引擎内部（发布后删 pub 是 break-API）" {
    // ui.zig 开头声明了锁定的两层命名空间，但 `test` 块之后曾追加导出
    // render_engine / debug_trace / paint_table / compute_position,
    // 其中 render_engine 连带暴露一组**可变全局**（current_frame_* 帧时钟
    // 与 setFrameClock），消费者能把时钟写坏。这与 API_STABILITY.md 把
    // render_engine 列为 Internal 直接矛盾。
    //
    // check_oss_boundary.sh 抓不到这个：它只查 src/ui/ import 了什么、
    // hello_button 链接了什么，从不检查根模块 pub 了什么。所以在这里守。
    //
    // 需要帧时间的 hook 用只读的 `ui.frame.*`（够不到 Cx 时）或
    // `cx.frame_time_ms`（多窗口下正确的那个）。
    // 白名单而非黑名单。
    //
    // 这里原本是一张只列了四个名字的黑名单（render_engine / debug_trace /
    // paint_table / compute_position），于是同类的「整模块内部 pub」只要不叫
    // 这四个名字就畅通无阻，实际漏过去的有 layout_engine（2400 行布局引擎，
    // 只为导出一个 setShapeFontResolver）、theme_schema（一半字段是 DevTools
    // 专用色）、a11y_router、perf_overlay（死模块）。2026-09-22 全部清掉后
    // 改成白名单：**新增一个顶层命名空间必须来这里登记**，逼作者回答一句
    // 「这东西凭什么给应用作者看」。
    //
    // 只管命名空间（`pub const x = @import(...)` 这类），不管值类型与函数,
    // 后者数量大且天然属于公共面，逐个登记收益不抵成本。
    const allowed_namespaces = [_][]const u8{
        // 组件与效果
        "widgets",  "fx",           "interaction",  "select_headless",
        // 资源
        "icons",    "system_icons", "assets",
        // 能力域
              "theme",
        "reactive", "control_flow", "actions",      "focus",
        "hit",      "path",         "a11y",         "recipe",
        "styles",   "arb",          "text_shaping", "platform_services",
        "gesture",  "input",
        // 工具与诊断
               "devtools",     "console",
        "frame",    "router",       "animation",    "hooks",
        "events",   "math",
    };
    inline for (@typeInfo(@This()).@"struct".decls) |decl| {
        const T = @TypeOf(@field(@This(), decl.name));
        if (T == type and @typeInfo(@field(@This(), decl.name)) == .@"struct") {
            // 只检查「看起来是命名空间」的：struct 类型且首字母小写
            if (decl.name[0] >= 'a' and decl.name[0] <= 'z') {
                var ok = false;
                inline for (allowed_namespaces) |name| {
                    if (std.mem.eql(u8, decl.name, name)) ok = true;
                }
                if (!ok) {
                    std.debug.print(
                        "ui.{s} 是个未登记的顶层命名空间。\n" ++
                            "  内部实现不该进公共面；确实要公开就加进 ui.zig 的 " ++
                            "allowed_namespaces，并在那里说明它面向谁。\n",
                        .{decl.name},
                    );
                    return error.UnregisteredPublicNamespace;
                }
            }
        }
    }
    // 只读帧时钟必须在（上面那条的替代路径）
    try std.testing.expect(@hasDecl(@This(), "frame"));
    _ = frame.timeMs();
    _ = frame.dtSeconds();
    _ = frame.dtMs();
    _ = frame.estimateTimeMs();
    // debug_trace 的**能力**是公开的（DevTools Render/Trace 面板数据源，
    // 宿主自建 inspector 要用），只是不该挂在顶层。归到 devtools 下。
    try std.testing.expect(@hasDecl(devtools, "trace"));
    try std.testing.expect(@hasDecl(devtools.trace, "setGlobalTraceTarget"));
    try std.testing.expect(@hasDecl(devtools.trace, "clearGlobalTraceTarget"));
}

// 分片任务调度：只导出 `Cx.enqueueTask` / `Cx.cancelTask` 两个公共方法真正
// 需要的类型。
//
// 此前这里导出了 work 全家 7 个（work / WorkPriority / WorkKey / WorkSpec /
// WorkResult / WorkHandle / Task），但那套面**从外部根本用不起来**：
// `WorkResult.step` 的类型是 `WorkStep`，而 `WorkStep` 没有被导出，外部
// 无法构造 `Task.runSlice` 要求的返回值。那是被顺手搬上来的内部实现，
// 不是设计过的公共面。
//
// 需要自定义分片任务的宿主，请连同 `WorkStep` 一起提 issue，那时再把
// 这组词汇统一好（内部同时存在 Task/TaskPriority 与 Work* 两套叫法）
// 一次性导出，而不是现在半成品地暴露。
pub const Task = core.Task;
pub const WorkKey = core.WorkKey;
/// 渲染输出的扁平指令项，`ui` 层的最终产物（`render` 层消费它）。
/// custom-draw 回调拿到的就是这个。
///
/// 注：此前顶层还导出过一个指向本类型的旧 IR 别名（那个 IR 早已删除），
/// 是个改名陷阱且零消费者，已随 v0.5 deletion gate 一并清除。
pub const DisplayItem = core.DisplayItem;

/// 四角圆角半径（`CornerRadii.fromArray([4]f32)`）。
///
/// 宿主应用在 `Cx.render()` 之后往 `cx.lowering.main_paint` 追加屏幕空间
/// 诊断图元时需要它构造 `.radii`。paint_table 模块本身是引擎内部，但这个
/// 值类型是那条公开路径的必需品，所以单独导出类型而不是整个模块。
pub const CornerRadii = core.paint_table.CornerRadii;
pub const DrawContext = core.DrawContext;
pub const IconProps = core.IconProps;
pub const AlignItems = core.AlignItems;
pub const JustifyContent = core.JustifyContent;
/// 帧时钟的**只读**视图。
///
/// `before_render` hook 只拿到 `*Node`，够不到 `Cx`，但按时间驱动的动画
/// （blur 扫动、Spinner 这类直写 style 的）需要"现在几点"。以前这条路
/// 是 `ui.render_engine.current_frame_time_ms`，那等于把整个渲染引擎
/// 连同一组**可变全局**（帧时钟本体 + setFrameClock）暴露给消费者，
/// 谁都能把时钟写坏。这里只给读，不给写。
///
/// 有 `Cx` 时优先用 `cx.frame_time_ms`：那是 per-context 的，多窗口下
/// 才正确；本命名空间服务的是够不到 Cx 的 hook 回调。
pub const frame = struct {
    /// 当前帧的绝对时间戳（ms），单调递增，相对于应用启动。
    pub inline fn timeMs() f64 {
        return core.render_engine.current_frame_time_ms;
    }
    /// 当前帧的 dt（秒）。
    pub inline fn dtSeconds() f32 {
        return core.render_engine.current_frame_dt_seconds;
    }
    /// 当前帧的 dt（ms），Spring 这类需要增量的消费者用。
    pub inline fn dtMs() f32 {
        return core.render_engine.current_frame_dt_ms;
    }
    /// 估算"此刻"的时间戳（ms）。
    ///
    /// 事件阶段可能发生在两帧之间，此时 `timeMs()` 停在上一帧。这个函数用
    /// 真实单调时钟补上帧内已流逝的部分，输入驱动的动画（点击起手的
    /// 高亮、闪烁）用它起算才不会有最多一帧的偏差。
    pub inline fn estimateTimeMs() f64 {
        return core.render_engine.estimateTimeMs();
    }
};

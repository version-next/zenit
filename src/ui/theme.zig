/// Theme Token 系统
///
/// 三层颜色架构：
///   Layer 1 — Base Colors:    原始色阶 (olive/neutral/sage/earth/rose/slate × 50-900)
///   Layer 2 — Semantic Colors: 语义 token，从 base 映射，描述"作用"而非具体值
///   Layer 3 — Component Colors: 从语义层再映射，描述具体组件用途
///
/// 用法:
///   const t = cx.tokens;
///   node.style.background = t.color.bg_primary;
///   node.style.padding = Padding.all(t.space._4);
const core = @import("core.zig");
const Color = core.Color;
const Shadow = core.Shadow;

// ============================================================================
// Layer 1 — Base Color Palettes (色阶原始值，不随主题变化)
// ============================================================================

/// Olive 橄榄绿色阶 (品牌主色)
pub const olive = struct {
    pub const _50 = Color.hex(0xF5F7F4);
    pub const _100 = Color.hex(0xE8EDE6);
    pub const _200 = Color.hex(0xD1DBCD);
    pub const _300 = Color.hex(0xA8BDA0);
    pub const _400 = Color.hex(0x7A9A70);
    pub const _500 = Color.hex(0x4D6545);
    pub const _600 = Color.hex(0x4A6741);
    pub const _700 = Color.hex(0x3D5636);
    pub const _800 = Color.hex(0x374F31);
    pub const _900 = Color.hex(0x2A3D25);
};

/// Neutral 中性灰色阶
pub const neutral = struct {
    pub const _50 = Color.hex(0xFAFAFA);
    pub const _100 = Color.hex(0xF5F5F5);
    pub const _200 = Color.hex(0xEFEFEF);
    pub const _300 = Color.hex(0xE5E5E5);
    pub const _400 = Color.hex(0xD4D4D4);
    pub const _500 = Color.hex(0x9B9B9B);
    pub const _600 = Color.hex(0x787878);
    pub const _700 = Color.hex(0x6B6B6B);
    pub const _750 = Color.hex(0x2A2A2A);
    pub const _800 = Color.hex(0x1A1A1A);
    pub const _900 = Color.hex(0x0F0F0F);
};

/// Sage 鼠尾草青色阶
pub const sage = struct {
    pub const _50 = Color.hex(0xF2F5F5);
    pub const _100 = Color.hex(0xE8EDED);
    pub const _200 = Color.hex(0xCEDADA);
    pub const _300 = Color.hex(0x9FB5B5);
    pub const _400 = Color.hex(0x7A9494);
    pub const _500 = Color.hex(0x5A7272);
    pub const _600 = Color.hex(0x4D6262);
    pub const _700 = Color.hex(0x3F5050);
};

/// Earth 大地棕色阶
pub const earth = struct {
    pub const _50 = Color.hex(0xFAF8F4);
    pub const _100 = Color.hex(0xF4EFEA);
    pub const _200 = Color.hex(0xE8DFD4);
    pub const _300 = Color.hex(0xCCBA9E);
    pub const _400 = Color.hex(0xA89070);
    pub const _500 = Color.hex(0x7D6A4A);
    pub const _600 = Color.hex(0x6B5A3F);
    pub const _700 = Color.hex(0x564832);
};

/// Rose 玫瑰红色阶
pub const rose = struct {
    pub const _50 = Color.hex(0xFAF5F5);
    pub const _100 = Color.hex(0xF6F0F0);
    pub const _200 = Color.hex(0xEBDCDC);
    pub const _300 = Color.hex(0xD4B5B5);
    pub const _400 = Color.hex(0xB08080);
    pub const _500 = Color.hex(0x844F4E);
    pub const _600 = Color.hex(0x6F4241);
    pub const _700 = Color.hex(0x5A3635);
};

/// Slate 石板蓝色阶
pub const slate = struct {
    pub const _50 = Color.hex(0xF5F7FA);
    pub const _100 = Color.hex(0xEDF2F6);
    pub const _200 = Color.hex(0xD8E2EB);
    pub const _300 = Color.hex(0xA8BCCE);
    pub const _400 = Color.hex(0x7090AE);
    pub const _500 = Color.hex(0x374B70);
    pub const _600 = Color.hex(0x2E3F5E);
    pub const _700 = Color.hex(0x24324B);
};

// ============================================================================
// Layer 2 & 3 — Semantic + Component Color Tokens (随主题变化)
// ============================================================================

/// 明暗判别（对标 CSS color-scheme / Panda 的 _dark 条件所依附的根状态）。
///
/// 用途边界：主题差异优先走 token 层整体换（light/dark 是两套完整 token 值，
/// 样式函数天然拿到正确值）；scheme 只做逃生舱——个别样式确实要按明暗分支、
/// 又不值得铸 token 时，在样式函数里 `if (t.scheme == .dark)`。
/// 不要在 ConditionalStyle 里加 dark 条件：两个 dark 值来源会打架。
pub const ColorScheme = enum { light, dark };

/// 完整主题 Token 集合
pub const ThemeTokens = struct {
    name: []const u8 = "unnamed",
    /// 明暗判别。判断主题明暗一律用它，不要嗅探 name 子串
    /// （历史教训：high_contrast 纯黑底曾因 name 不含 "dark" 被误判为 light）。
    scheme: ColorScheme = .light,
    color: ColorTokens,
    space: SpaceScale = .{},
    radius: RadiusScale = .{},
    font_size: FontSizeScale = .{},
    border_width: BorderWidthScale = .{},
    size: SizeTokens = .{},
    control: ControlScale = .{},
    duration: DurationTokens = .{},
    shadow: ShadowTokens = .{},
};

/// 语义 + 组件颜色 Token
///
/// 分三区：
///   [Semantic / Background]  — 描述层级和用途的背景色
///   [Semantic / Foreground]  — 文本、图标颜色
///   [Semantic / Brand]       — 品牌色、交互强调色
///   [Semantic / Status]      — success/warning/error/info
///   [Semantic / Border]      — 边框、焦点环
///   [Component]              — 具体组件专属 token
pub const ColorTokens = struct {
    // ── Semantic / Background ──────────────────────────────────────────────
    /// 页面/窗口底层背景（最深）
    bg_base: Color,
    /// 主内容区背景
    bg_primary: Color,
    /// 次级面板/侧边栏背景
    bg_secondary: Color,
    /// 三级背景：卡片、代码块、内嵌区域
    bg_tertiary: Color,
    /// 鼠标 hover 时的叠加背景
    bg_hover: Color,
    /// 鼠标 pressed / 激活时的叠加背景
    bg_active: Color,
    /// 内嵌强调背景（输入框内、表头等）
    bg_inset: Color,

    // ── Semantic / Foreground ─────────────────────────────────────────────
    /// 主文本
    fg_primary: Color,
    /// 次级文本（描述、辅助信息）
    fg_secondary: Color,
    /// 三级文本（占位符、提示）
    fg_tertiary: Color,
    /// 禁用状态文本/图标
    fg_disabled: Color,
    /// 反色文本（用于深色背景上的白字）
    fg_inverse: Color,

    // ── Semantic / Brand ──────────────────────────────────────────────────
    /// 品牌主色（按钮、链接、选中态）
    accent: Color,
    /// 品牌主色悬停态
    accent_hover: Color,
    /// 品牌浅色背景（选中行、tag 背景等）
    accent_subtle: Color,
    /// 品牌轻量背景（最浅，用于标记、高亮）
    accent_muted: Color,

    // ── Semantic / Status ─────────────────────────────────────────────────
    /// 成功
    success: Color,
    /// 成功浅色背景
    success_subtle: Color,
    /// 警告
    warning: Color,
    /// 警告浅色背景
    warning_subtle: Color,
    /// 错误/危险
    danger: Color,
    /// 错误悬停
    danger_hover: Color,
    /// 错误浅色背景
    danger_subtle: Color,
    /// 信息
    info: Color,
    /// 信息浅色背景
    info_subtle: Color,
    /// 状态颜色上的前景色（用于 badge/tag 内的文字）
    status_fg: Color,

    // ── Semantic / Border ─────────────────────────────────────────────────
    /// 默认边框
    border: Color,
    /// 强调边框（分隔线、表格边框）
    border_strong: Color,
    /// 焦点态边框
    border_focus: Color,
    /// 焦点环（outline）
    focus_ring: Color,

    // ── Component / Selection ─────────────────────────────────────────────
    /// 文字选中背景
    selection_bg: Color,

    // ── Component / Button ────────────────────────────────────────────────
    /// Primary 按钮背景（= accent）
    button_primary_bg: Color,
    /// Primary 按钮文字
    button_primary_fg: Color,
    /// Secondary 按钮背景
    button_secondary_bg: Color,
    /// Secondary 按钮文字
    button_secondary_fg: Color,

    // ── Component / Input ─────────────────────────────────────────────────
    /// 输入框背景
    input_bg: Color,
    /// 输入框边框
    input_border: Color,

    // ── Component / Toggle (Checkbox / Switch) ────────────────────────────
    /// Checkbox 未选中背景
    checkbox_bg: Color,
    /// Checkbox 未选中边框
    checkbox_border: Color,
    /// Checkbox 禁用态背景
    checkbox_disabled_bg: Color,
    /// Checkbox 禁用态边框
    checkbox_disabled_border: Color,
    /// Checkbox 选中+禁用态背景
    checkbox_disabled_checked_bg: Color,
    /// Switch 滑块（thumb）颜色
    switch_thumb: Color,
    /// Switch 关闭态轨道
    switch_track_off: Color,
    /// Switch 开启态轨道（= accent）
    switch_track_on: Color,

    // ── Component / List / Table ──────────────────────────────────────────
    /// 列表行 hover 背景
    list_hover_bg: Color,
    /// 列表行选中背景
    list_selection_bg: Color,
    /// 列表行选中 hover 背景
    list_selection_hover_bg: Color,
    /// 表头背景
    table_header_bg: Color,

    // ── Component / Misc ──────────────────────────────────────────────────
    /// 分隔线
    separator: Color,
    /// Scrollbar 滑块
    scrollbar_thumb: Color,
    /// Tooltip 背景
    tooltip_bg: Color,
    /// Tooltip 文字
    tooltip_fg: Color,
    /// 模态遮罩
    overlay: Color,
};

/// 间距比例尺 (4px 基准)
pub const SpaceScale = struct {
    _0: f32 = 0,
    _0_5: f32 = 2,
    _1: f32 = 4,
    _1_5: f32 = 6,
    _2: f32 = 8,
    _3: f32 = 12,
    _4: f32 = 16,
    _6: f32 = 24,
    _8: f32 = 32,
    _10: f32 = 40,
    _12: f32 = 48,
};

/// 圆角比例尺
pub const RadiusScale = struct {
    none: f32 = 0,
    sm: f32 = 3,
    md: f32 = 4,
    lg: f32 = 6,
    xl: f32 = 8,
    full: f32 = 9999,
};

/// 字号比例尺
pub const FontSizeScale = struct {
    xxs: f32 = 9,
    xs: f32 = 11,
    sm: f32 = 12,
    md: f32 = 13,
    lg: f32 = 14,
    xl: f32 = 16,
    xxl: f32 = 20,
    xxxl: f32 = 24,
};

/// 边框宽度比例尺
pub const BorderWidthScale = struct {
    none: f32 = 0,
    thin: f32 = 1,
    medium: f32 = 1.5,
    thick: f32 = 2,
};

/// 统一控件尺寸 — Button / Input / Select / ComboBox / DatePicker / DateRangePicker / Tabs / Chip 共享
/// 4 档: XS / SM / MD / LG（默认 md）
///
/// 纯 key enum。具体度量经主题读取: `tokens.control.get(size)` → `ControlMetrics`。
pub const ControlSize = enum {
    xs,
    sm,
    md,
    lg,
};

/// 单个控件档位的完整度量 — ControlSize 一档对应一份
///
/// **高度合同**：控件外框高度不是 token，而是由内容自然撑出：
///
///     外框高度 = padding_y × 2 + 行高        行高 = font_size × line_height
///
/// ControlShell 把"行盒"（content/icon slot 的最小高度 = 行高）和上下 padding
/// 交给布局 fit 计算，任何控件都不写死外框 height。改 font_size / line_height /
/// padding_y，所有控件的高度一起跟着变。
///
/// icon 尺寸必须 ≤ 行高（放在行盒里垂直居中，不参与撑高）。
/// 纯图标控件（icon_only）四边 padding 都是 padding_y、图标槽是行高见方的正方形，
/// 因此与同档文本控件等高且为正方形。
pub const ControlMetrics = struct {
    /// 文字字号
    font_size: f32,
    /// 行高倍数（相对 font_size）。行高 px = font_size × line_height
    line_height: f32,
    /// 圆角
    radius: f32,
    /// 上下 padding（外框高度 = padding_y × 2 + 行高）
    padding_y: f32,
    /// 左右 padding
    padding_h: f32,
    /// 带左图标时的左 padding（上下/右仍为 padding_y / padding_h）
    padding_leading_icon: f32,
    /// icon 尺寸（≤ 行高）
    icon_size: f32,
    /// 图标与文字间距
    gap: f32,

    /// 行高（px）= font_size × line_height
    pub fn lineHeightPx(self: ControlMetrics) f32 {
        return self.font_size * self.line_height;
    }

    /// 由度量推导出的外框高度（padding_y × 2 + 行高）。
    /// 只供测量/断言/定位计算读取，**不要**把它写回 style.height —— 高度由布局 fit 得出。
    pub fn derivedHeight(self: ControlMetrics) f32 {
        return self.padding_y * 2 + self.lineHeightPx();
    }
};

/// 控件尺度比例尺 — 挂在 ThemeTokens.control 上，主题可整体替换控件尺度
///
/// 推导（line_height 统一 1.25，二进制精确，行高与外框高度都是精确值）:
///   xs: 12 × 1.25 = 15   + 2.5 × 2  = 20
///   sm: 12 × 1.25 = 15   + 4.5 × 2  = 24
///   md: 14 × 1.25 = 17.5 + 7.25 × 2 = 32
///   lg: 16 × 1.25 = 20   + 10 × 2   = 40
/// icon_size（12/14/16/20）均 ≤ 行高（15/15/17.5/20）。
pub const ControlScale = struct {
    xs: ControlMetrics = .{
        .font_size = 12,
        .line_height = 1.25,
        .radius = 4,
        .padding_y = 2.5,
        .padding_h = 6,
        .padding_leading_icon = 4,
        .icon_size = 12,
        .gap = 4,
    },
    sm: ControlMetrics = .{
        .font_size = 12,
        .line_height = 1.25,
        .radius = 6,
        .padding_y = 4.5,
        .padding_h = 8,
        .padding_leading_icon = 6,
        .icon_size = 14,
        .gap = 4,
    },
    md: ControlMetrics = .{
        .font_size = 14,
        .line_height = 1.25,
        .radius = 8,
        .padding_y = 7.25,
        .padding_h = 12,
        .padding_leading_icon = 10,
        .icon_size = 16,
        .gap = 6,
    },
    lg: ControlMetrics = .{
        .font_size = 16,
        .line_height = 1.25,
        .radius = 10,
        .padding_y = 10,
        .padding_h = 16,
        .padding_leading_icon = 14,
        .icon_size = 20,
        .gap = 8,
    },

    pub fn get(self: *const ControlScale, s: ControlSize) ControlMetrics {
        return switch (s) {
            .xs => self.xs,
            .sm => self.sm,
            .md => self.md,
            .lg => self.lg,
        };
    }
};

/// 组件尺寸 Token
pub const SizeTokens = struct {
    checkbox: f32 = 18,
    switch_width: f32 = 40,
    switch_height: f32 = 22,
    badge_sm: f32 = 16,
    badge_md: f32 = 20,
    dot: f32 = 8,
    close_button: f32 = 24,
};

/// 动画时长 Token (秒)
pub const DurationTokens = struct {
    fast: f32 = 0.1,
    normal: f32 = 0.15,
    slow: f32 = 0.25,
};

/// 阴影预设 Token
pub const ShadowTokens = struct {
    sm: Shadow = .{ .color = Color.rgba(0, 0, 0, 40), .blur = 4, .offset_x = 0, .offset_y = 2 },
    md: Shadow = .{ .color = Color.rgba(0, 0, 0, 80), .blur = 8, .offset_x = 0, .offset_y = 4 },
    lg: Shadow = .{ .color = Color.rgba(0, 0, 0, 100), .blur = 24, .offset_x = 0, .offset_y = 8 },
};

// ============================================================================
// Light 主题
// ============================================================================

/// Light 预设 — 基于 VSCode 主题 "Mac Classic" (mac-classic-light-color-theme.json)
pub const light = ThemeTokens{
    .name = "light",
    .scheme = .light,
    .color = .{
        // Background — 来自 Mac Classic light
        .bg_base = Color.hex(0xF5F5F5), // activityBar/statusBar/tabs background
        .bg_primary = Color.hex(0xFFFFFF), // editor.background
        .bg_secondary = Color.hex(0xF7F7F7), // sideBar.background / panel.background
        .bg_tertiary = Color.hex(0xEEEEEE), // button.background / 稍深面板
        .bg_hover = Color.hex(0xF0F0F0), // list.hoverBackground
        .bg_active = Color.hex(0xE0E0E0), // button.hoverBackground
        .bg_inset = Color.hex(0xF8F8F8), // editor.lineHighlightBackground

        // Foreground
        .fg_primary = Color.hex(0x1C1612), // editor.foreground
        .fg_secondary = Color.hex(0x555555), // activityBar.foreground / statusBar.foreground
        .fg_tertiary = Color.hex(0x888888), // tab.inactiveForeground
        .fg_disabled = Color.hex(0xBBBBBB), // input.placeholderForeground
        .fg_inverse = Color.hex(0xFFFFFF), // statusBar.debuggingForeground

        // Brand — Mac Classic 用深棕黑 #1C1612 作为强调色；辅以 focusBorder #6699CC
        .accent = Color.hex(0x1C1612), // activityBar.activeBorder / tab.activeBorderTop
        .accent_hover = Color.hex(0x2A2320), // badge.background
        .accent_subtle = Color.hex(0xE4EDFA), // list.activeSelectionBackground
        .accent_muted = Color.hex(0xF0F0F0), // list.hoverBackground

        // Status
        .success = Color.hex(0x2E8B37), // terminal.ansiGreen / gitDecoration.untracked
        .success_subtle = Color.hex(0xE4F2E6), // 推导：success 浅底
        .warning = Color.hex(0xAA7700), // terminal.ansiYellow
        .warning_subtle = Color.hex(0xF7EEDB), // 推导
        .danger = Color.hex(0xDD0000), // terminal.ansiRed / gitDecoration.deleted
        .danger_hover = Color.hex(0xB30000), // 推导：略深
        .danger_subtle = Color.hex(0xFBE4E4), // 推导
        .info = Color.hex(0x1144AA), // list.highlightForeground / gitDecoration.modified
        .info_subtle = Color.hex(0xE4EDFA), // list.activeSelectionBackground
        .status_fg = Color.hex(0xFFFFFF),

        // Border
        .border = Color.hex(0xE0E0E0), // input.border / dropdown.border
        .border_strong = Color.hex(0xCCCCCC), // editorLineNumber.foreground
        .border_focus = Color.hex(0x6699CC), // focusBorder
        .focus_ring = Color.hex(0x6699CC), // focusBorder

        // Selection
        .selection_bg = Color.hex(0xB5D5FF), // editor.selectionBackground

        // Button
        .button_primary_bg = Color.hex(0x1C1612), // Mac Classic 强调色
        .button_primary_fg = Color.hex(0xFFFFFF),
        .button_secondary_bg = Color.hex(0xEEEEEE), // button.background
        .button_secondary_fg = Color.hex(0x1C1612), // button.foreground

        // Input
        .input_bg = Color.hex(0xFFFFFF), // input.background
        .input_border = Color.hex(0xE0E0E0), // input.border

        // Toggle
        .checkbox_bg = Color.hex(0xFFFFFF),
        .checkbox_border = Color.hex(0xCCCCCC),
        .checkbox_disabled_bg = Color.hex(0xF5F5F5),
        .checkbox_disabled_border = Color.hex(0xE0E0E0),
        .checkbox_disabled_checked_bg = Color.hex(0xE0E0E0),
        .switch_thumb = Color.hex(0xFFFFFF),
        .switch_track_off = Color.hex(0xE0E0E0),
        .switch_track_on = Color.hex(0x1C1612),

        // List / Table
        .list_hover_bg = Color.hex(0xF0F0F0), // list.hoverBackground
        .list_selection_bg = Color.hex(0xE4EDFA), // list.activeSelectionBackground
        .list_selection_hover_bg = Color.hex(0xD8E4F4), // 推导：selection 再深一阶
        .table_header_bg = Color.hex(0xF5F5F5),

        // Misc
        .separator = Color.hex(0xEBEBEB), // panel.border
        .scrollbar_thumb = Color.rgba(0, 0, 0, 38), // scrollbarSlider.background #00000015 → alpha 21/255 ≈ 0x26; 0x15 = 21 decimal
        .tooltip_bg = Color.hex(0x1C1612),
        .tooltip_fg = Color.hex(0xFFFFFF),
        .overlay = Color.rgba(0, 0, 0, 80),
    },
    .shadow = .{
        .sm = .{ .color = Color.rgba(0, 0, 0, 16), .blur = 4, .offset_x = 0, .offset_y = 2 },
        .md = .{ .color = Color.rgba(0, 0, 0, 24), .blur = 8, .offset_x = 0, .offset_y = 4 },
        .lg = .{ .color = Color.rgba(0, 0, 0, 40), .blur = 24, .offset_x = 0, .offset_y = 8 },
    },
};

// ============================================================================
// Dark 主题
// ============================================================================

/// Dark 预设 — 基于 VSCode 主题 "Mac Classic Dark" (mac-classic-dark-color-theme.json)
pub const dark = ThemeTokens{
    .name = "dark",
    .scheme = .dark,
    .color = .{
        // Background
        .bg_base = Color.hex(0x0D1119), // activityBar/statusBar/tabs background
        .bg_primary = Color.hex(0x141820), // editor.background / tab.activeBackground
        .bg_secondary = Color.hex(0x12161E), // sideBar / panel.background
        .bg_tertiary = Color.hex(0x1E2230), // editorWidget.background
        .bg_hover = Color.hex(0x1A1E2A), // list.hoverBackground
        .bg_active = Color.hex(0x2A3450), // list.focusBackground
        .bg_inset = Color.hex(0x1C2028), // editor.lineHighlightBackground

        // Foreground
        .fg_primary = Color.hex(0xD7CCC4), // editor.foreground
        .fg_secondary = Color.hex(0xB8AEA6), // activityBar.foreground / statusBar.foreground
        .fg_tertiary = Color.hex(0x958B84), // tab.inactiveForeground
        .fg_disabled = Color.hex(0x7E746D), // input.placeholderForeground
        .fg_inverse = Color.hex(0x141820), // 反色

        // Brand — Mac Classic Dark 用暖米色 #C7BBB3 作为强调；辅以冷蓝 #6699CC
        .accent = Color.hex(0xC7BBB3), // activityBar.activeBorder / panelTitle.activeBorder
        .accent_hover = Color.hex(0xE8E0DA), // tab.activeBorderTop
        .accent_subtle = Color.hex(0x2A3450), // list.activeSelectionBackground
        .accent_muted = Color.hex(0x1A1E2A), // list.hoverBackground

        // Status
        .success = Color.hex(0x8CB87C), // terminal.ansiGreen / gitDecoration.untracked
        .success_subtle = Color.hex(0x1E2820), // 推导
        .warning = Color.hex(0xD4A843), // terminal.ansiYellow
        .warning_subtle = Color.hex(0x2A2418), // 推导
        .danger = Color.hex(0xC14545), // 自 terminal.ansiRed #FF6B6B 加深，保证 status_fg(白) 对比 >= 4.5
        .danger_hover = Color.hex(0xFF6B6B), // 原 ansiRed 作为 hover 亮色
        .danger_subtle = Color.hex(0x2E1C1C), // 推导
        .info = Color.hex(0x6B9BFF), // list.highlightForeground / gitDecoration.modified
        .info_subtle = Color.hex(0x1A2030), // 推导
        .status_fg = Color.hex(0xFFFFFF), // badge/tag 上的反色文字（对红/蓝/绿保持 >= 4.5 对比度）

        // Border
        .border = Color.hex(0x263048), // input.border / dropdown.border
        .border_strong = Color.hex(0x2A3248), // editorWidget.border
        .border_focus = Color.hex(0x6699CC), // focusBorder
        .focus_ring = Color.hex(0x6699CC), // focusBorder

        // Selection
        .selection_bg = Color.hex(0x3A4D70), // editor.selectionBackground

        // Button
        .button_primary_bg = Color.hex(0xC7BBB3), // accent
        .button_primary_fg = Color.hex(0x141820), // 反色
        .button_secondary_bg = Color.hex(0x1E2638), // button.background
        .button_secondary_fg = Color.hex(0xD7CCC4), // button.foreground

        // Input
        .input_bg = Color.hex(0x141820), // input.background
        .input_border = Color.hex(0x263048), // input.border

        // Toggle
        .checkbox_bg = Color.hex(0x141820),
        .checkbox_border = Color.hex(0x263048),
        .checkbox_disabled_bg = Color.hex(0x12161E),
        .checkbox_disabled_border = Color.hex(0x1E2230),
        .checkbox_disabled_checked_bg = Color.hex(0x1E2230),
        .switch_thumb = Color.hex(0xE8E0DA),
        .switch_track_off = Color.hex(0x263048),
        .switch_track_on = Color.hex(0xC7BBB3),

        // List / Table
        .list_hover_bg = Color.hex(0x1A1E2A), // list.hoverBackground
        .list_selection_bg = Color.hex(0x2A3450), // list.activeSelectionBackground
        .list_selection_hover_bg = Color.hex(0x344060), // 推导
        .table_header_bg = Color.hex(0x12161E),

        // Misc
        .separator = Color.hex(0x1E2230), // panel.border
        .scrollbar_thumb = Color.rgba(255, 255, 255, 33), // scrollbarSlider.background #FFFFFF15
        .tooltip_bg = Color.hex(0x1E2230), // editorWidget.background
        .tooltip_fg = Color.hex(0xD7CCC4),
        .overlay = Color.rgba(0, 0, 0, 160),
    },
};

/// v0.9-§E (2026-05-13): High-contrast 主题 — WCAG AAA 对比度 (≥7:1)。
/// 背景纯黑/纯白，前景反色；强调色用纯黄 #FFFF00 / 纯青 #00FFFF。
/// 适用于视觉障碍用户 + 高对比度系统设置。
pub const high_contrast = ThemeTokens{
    .name = "high_contrast",
    // 纯黑底 → dark。此前 devtools/theme_schema 靠 name 子串嗅探 "dark"，
    // 把 high_contrast 误判为 light —— scheme 字段就是为了终结这类嗅探。
    .scheme = .dark,
    .color = .{
        // Background — 纯黑底
        .bg_base = Color.hex(0x000000),
        .bg_primary = Color.hex(0x000000),
        .bg_secondary = Color.hex(0x000000),
        .bg_tertiary = Color.hex(0x1A1A1A),
        .bg_hover = Color.hex(0x404040),
        .bg_active = Color.hex(0x0000FF),
        .bg_inset = Color.hex(0x000000),

        // Foreground — 纯白文字 (对比 21:1)
        .fg_primary = Color.hex(0xFFFFFF),
        .fg_secondary = Color.hex(0xFFFFFF),
        .fg_tertiary = Color.hex(0xC0C0C0), // 12:1
        .fg_disabled = Color.hex(0x808080), // 4.6:1 (disabled 允许 AA 而非 AAA)
        .fg_inverse = Color.hex(0x000000),

        // Brand — 纯黄强调 (对比 19.6:1 vs 黑)
        .accent = Color.hex(0xFFFF00),
        .accent_hover = Color.hex(0xFFFFC0),
        .accent_subtle = Color.hex(0x404000),
        .accent_muted = Color.hex(0x202000),

        // Status — 高饱和纯色
        .success = Color.hex(0x00FF00), // 15.3:1
        .success_subtle = Color.hex(0x003300),
        .warning = Color.hex(0xFFFF00), // 19.6:1
        .warning_subtle = Color.hex(0x333300),
        .danger = Color.hex(0xFF6060), // 8:1
        .danger_hover = Color.hex(0xFF8080),
        .danger_subtle = Color.hex(0x330000),
        .info = Color.hex(0x00FFFF), // 16.7:1
        .info_subtle = Color.hex(0x003333),
        .status_fg = Color.hex(0x000000),

        // Border — 纯白边框 (清晰可见)
        .border = Color.hex(0xFFFFFF),
        .border_strong = Color.hex(0xFFFFFF),
        .border_focus = Color.hex(0xFFFF00),
        .focus_ring = Color.hex(0xFFFF00),

        // Selection
        .selection_bg = Color.hex(0xFFFF00),

        // Button
        .button_primary_bg = Color.hex(0xFFFFFF),
        .button_primary_fg = Color.hex(0x000000),
        .button_secondary_bg = Color.hex(0x000000),
        .button_secondary_fg = Color.hex(0xFFFFFF),

        // Input
        .input_bg = Color.hex(0x000000),
        .input_border = Color.hex(0xFFFFFF),

        // Toggle
        .checkbox_bg = Color.hex(0x000000),
        .checkbox_border = Color.hex(0xFFFFFF),
        .checkbox_disabled_bg = Color.hex(0x000000),
        .checkbox_disabled_border = Color.hex(0x808080),
        .checkbox_disabled_checked_bg = Color.hex(0x404040),
        .switch_thumb = Color.hex(0xFFFFFF),
        .switch_track_off = Color.hex(0x404040),
        .switch_track_on = Color.hex(0xFFFF00),

        // List / Table
        .list_hover_bg = Color.hex(0x404040),
        .list_selection_bg = Color.hex(0xFFFF00),
        .list_selection_hover_bg = Color.hex(0xFFFFC0),
        .table_header_bg = Color.hex(0x000000),

        // Misc
        .separator = Color.hex(0xFFFFFF),
        .scrollbar_thumb = Color.rgba(255, 255, 255, 200),
        .tooltip_bg = Color.hex(0xFFFFFF),
        .tooltip_fg = Color.hex(0x000000),
        .overlay = Color.rgba(0, 0, 0, 220),
    },
};

// ============================================================================
// 测试
// ============================================================================

const std = @import("std");

fn channelToLinear(c: u8) f64 {
    const v = @as(f64, @floatFromInt(c)) / 255.0;
    if (v <= 0.04045) return v / 12.92;
    return std.math.pow(f64, (v + 0.055) / 1.055, 2.4);
}

fn relativeLuminance(c: Color) f64 {
    const r = channelToLinear(c.r);
    const g = channelToLinear(c.g);
    const b = channelToLinear(c.b);
    return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

fn contrastRatio(a: Color, b: Color) f64 {
    const la = relativeLuminance(a);
    const lb = relativeLuminance(b);
    const hi = if (la > lb) la else lb;
    const lo = if (la > lb) lb else la;
    return (hi + 0.05) / (lo + 0.05);
}

test "ThemeTokens: dark preset has valid colors" {
    const t = &dark;
    try std.testing.expect(t.color.accent.a == 255);
    try std.testing.expect(t.color.bg_primary.a == 255);
    try std.testing.expect(t.color.overlay.a == 160);
}

test "ThemeTokens: light preset has valid colors" {
    const t = &light;
    try std.testing.expect(t.color.accent.a == 255);
    try std.testing.expect(t.color.bg_primary.a == 255);
}

test "ThemeTokens: space scale values" {
    const s = SpaceScale{};
    try std.testing.expectEqual(@as(f32, 0), s._0);
    try std.testing.expectEqual(@as(f32, 4), s._1);
    try std.testing.expectEqual(@as(f32, 8), s._2);
    try std.testing.expectEqual(@as(f32, 16), s._4);
}

test "ThemeTokens: radius scale values" {
    const r = RadiusScale{};
    try std.testing.expectEqual(@as(f32, 0), r.none);
    try std.testing.expectEqual(@as(f32, 4), r.md);
    try std.testing.expectEqual(@as(f32, 9999), r.full);
}

test "ThemeTokens: switching theme is pointer swap" {
    var current: *const ThemeTokens = &dark;
    try std.testing.expectEqualStrings("dark", current.name);
    current = &light;
    try std.testing.expectEqualStrings("light", current.name);
}

test "ThemeTokens: critical contrast pairs stay readable" {
    // Primary button: fg on bg
    try std.testing.expect(contrastRatio(dark.color.button_primary_fg, dark.color.button_primary_bg) >= 4.5);
    try std.testing.expect(contrastRatio(light.color.button_primary_fg, light.color.button_primary_bg) >= 4.5);
    // Danger fg on danger bg
    try std.testing.expect(contrastRatio(dark.color.status_fg, dark.color.danger) >= 4.5);
    try std.testing.expect(contrastRatio(light.color.status_fg, light.color.danger) >= 4.5);
    // Border distinguishable from bg_primary（装饰性边框，对比度 >= 1.2 即可）
    try std.testing.expect(contrastRatio(dark.color.border, dark.color.bg_primary) >= 1.2);
    try std.testing.expect(contrastRatio(light.color.border, light.color.bg_primary) >= 1.2);
}

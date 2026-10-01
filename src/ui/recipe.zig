/// Recipe，样式配方系统
///
/// 灵感来自 Panda CSS (cva/sva) 和 CVA (Class Variance Authority)，
/// 用 Zig comptime 实现零运行时开销的声明式样式变体。
///
/// 三层架构：
///   1. ConditionalStyle，带交互条件的样式包 (对标 Panda Conditions: _hover/_active/_disabled)
///   2. recipe()，单节点配方 (对标 CVA cva())
///   3. slotRecipe()，多部件配方 (对标 Panda sva())
///
/// CSS Transition 解析器：
///   4. transition(), comptime 解析 CSS 风格的 transition 字符串
///
/// 用法示例：
/// ```zig
/// // CSS transition 字符串 -> 编译期解析
/// node.applyTransition(allocator, comptime transition("background 200ms ease-out, opacity 150ms"));
///
/// // Recipe 定义
/// const ButtonRecipe = recipe(struct {
///     pub const Variants = struct { variant: ControlVariant = .primary, size: ControlSize = .md };
///     pub fn base(t: *const ThemeTokens) ConditionalStyle { ... }
///     pub const variants = .{ .variant = resolveVariant, .size = resolveSize };
/// });
///
/// // 使用
/// const styles = ButtonRecipe.resolve(.{ .variant = .primary, .size = .md }, cx.tokens);
/// ```
const std = @import("std");
const types = @import("core/types.zig");
const theme = @import("theme.zig");

pub const Color = types.Color;
pub const StyleOverride = types.StyleOverride;
pub const TransitionProp = types.TransitionProp;
pub const TransitionSpec = types.TransitionSpec;
pub const Easing = types.Easing;
pub const InteractionState = types.InteractionState;
pub const ThemeTokens = theme.ThemeTokens;

// ============================================================================
// 1. ConditionalStyle，带交互条件的样式包
// ============================================================================

/// 一个声明式样式包，同时描述 base + 七种条件态。
///
/// 对标 Panda CSS 的 Conditions 系统：
///   css({ bg: "red.500", _hover: { bg: "red.700" }, _disabled: { opacity: 0.5 } })
/// 条件位收录 Panda 内置条件里组件库有真实消费者的子集：
///   _hover/_active/_focus/_disabled + _checked(->selected)/_expanded/_invalid。
/// 刻意不收：_dark（主题差异走 token 层整体换 + 样式函数内 t.scheme 判别，
/// 不做样式级条件，两个 dark 值来源会打架）、group/peer hover（需事件系统
/// 支持，另案）、伪元素/媒体查询（无 CSS 引擎对应物）。
///
/// 替代当前 ControlVariant 的 6 个独立方法（background/hoverBackground/activeBackground/...），
/// 让每个变体值自包含所有交互态样式。
pub const ConditionalStyle = struct {
    /// 基础态（始终应用）
    base: StyleOverride = .{},
    /// 持久选中/勾选态（selected 与 checked 合一，见 InteractionState.is_selected）
    selected: ?StyleOverride = null,
    /// 展开态（accordion item / tree 节点 / chevron）
    expanded: ?StyleOverride = null,
    /// hover 态（鼠标悬停时 merge 到 base 之上）
    hover: ?StyleOverride = null,
    /// active / pressed 态
    active: ?StyleOverride = null,
    /// focus 态
    focus: ?StyleOverride = null,
    /// 校验失败态（链上排交互态之后：error 视觉需压过 hover/focus，
    /// 对齐 Input 既有语义，error 时抑制 focus/hover 的边框变化）
    invalid: ?StyleOverride = null,
    /// disabled 态（disabled 时其余条件态全部不叠加）
    disabled: ?StyleOverride = null,

    /// 运行时解析：根据交互/组件状态 merge 出最终 StyleOverride
    ///
    /// 优先级链: base <- selected <- expanded <- hover <- active <- focus <- invalid <- disabled(短路)
    /// - selected/expanded 是持久底态，交互态叠其上（hover 高亮可叠在选中行上）；
    /// - invalid 压过交互态；disabled 与其余互斥（不叠加任何条件态）。
    pub fn resolve(self: ConditionalStyle, state: InteractionState) StyleOverride {
        var result = self.base;
        if (state.is_disabled) {
            if (self.disabled) |d| result = result.merge(d);
            return result;
        }
        if (state.is_selected) {
            if (self.selected) |s| result = result.merge(s);
        }
        if (state.is_expanded) {
            if (self.expanded) |e| result = result.merge(e);
        }
        if (state.is_hovered) {
            if (self.hover) |h| result = result.merge(h);
        }
        if (state.is_pressed) {
            if (self.active) |a| result = result.merge(a);
        }
        if (state.is_focused) {
            if (self.focus) |f| result = result.merge(f);
        }
        if (state.is_invalid) {
            if (self.invalid) |iv| result = result.merge(iv);
        }
        return result;
    }

    /// 提取 background 三态颜色（normal / hover / pressed）
    /// 给 hooks.useAnimatedBackground 使用
    pub fn bgColors(self: ConditionalStyle) struct { normal: Color, hover: Color, pressed: Color } {
        const normal = self.base.background orelse Color.TRANSPARENT;
        const hover_bg = if (self.hover) |h| (h.background orelse normal) else normal;
        const pressed_bg = if (self.active) |a| (a.background orelse hover_bg) else hover_bg;
        return .{ .normal = normal, .hover = hover_bg, .pressed = pressed_bg };
    }

    /// 两个 ConditionalStyle 深度 merge（对标 Panda mergeCss 递归合并）
    ///
    /// 后者覆盖前者（非 null 字段覆盖）
    pub fn merge(self: ConditionalStyle, other: ConditionalStyle) ConditionalStyle {
        return .{
            .base = self.base.merge(other.base),
            .selected = mergeOptionalOverride(self.selected, other.selected),
            .expanded = mergeOptionalOverride(self.expanded, other.expanded),
            .hover = mergeOptionalOverride(self.hover, other.hover),
            .active = mergeOptionalOverride(self.active, other.active),
            .focus = mergeOptionalOverride(self.focus, other.focus),
            .invalid = mergeOptionalOverride(self.invalid, other.invalid),
            .disabled = mergeOptionalOverride(self.disabled, other.disabled),
        };
    }

    /// 用外部 StyleOverride 覆盖 base 态（用于组件的 style prop 覆盖 recipe 输出）
    ///
    /// 典型场景: Button 的 style/hover_style/pressed_style props
    pub fn override(self: ConditionalStyle, overrides: struct {
        style: StyleOverride = .{},
        selected_style: ?StyleOverride = null,
        expanded_style: ?StyleOverride = null,
        hover_style: ?StyleOverride = null,
        pressed_style: ?StyleOverride = null,
        focus_style: ?StyleOverride = null,
        invalid_style: ?StyleOverride = null,
        disabled_style: ?StyleOverride = null,
    }) ConditionalStyle {
        var result = self;
        if (!overrides.style.isEmpty()) {
            result.base = result.base.merge(overrides.style);
        }
        if (overrides.selected_style) |s| {
            result.selected = mergeOptionalOverride(result.selected, s);
        }
        if (overrides.expanded_style) |e| {
            result.expanded = mergeOptionalOverride(result.expanded, e);
        }
        if (overrides.hover_style) |h| {
            result.hover = mergeOptionalOverride(result.hover, h);
        }
        if (overrides.pressed_style) |a| {
            result.active = mergeOptionalOverride(result.active, a);
        }
        if (overrides.focus_style) |f| {
            result.focus = mergeOptionalOverride(result.focus, f);
        }
        if (overrides.invalid_style) |iv| {
            result.invalid = mergeOptionalOverride(result.invalid, iv);
        }
        if (overrides.disabled_style) |d| {
            result.disabled = mergeOptionalOverride(result.disabled, d);
        }
        return result;
    }

    /// 检查是否完全为空
    pub fn isEmpty(self: ConditionalStyle) bool {
        return self.base.isEmpty() and
            self.selected == null and
            self.expanded == null and
            self.hover == null and
            self.active == null and
            self.focus == null and
            self.invalid == null and
            self.disabled == null;
    }

    fn mergeOptionalOverride(a: ?StyleOverride, b: ?StyleOverride) ?StyleOverride {
        if (a == null and b == null) return null;
        if (a == null) return b;
        if (b == null) return a;
        return a.?.merge(b.?);
    }
};

// ============================================================================
// 2. recipe()，单节点配方 (对标 CVA cva())
// ============================================================================

/// comptime Recipe 工厂函数
///
/// 核心算法直接从 CVA 源码翻译:
///   resolve(props) = merge(base, ...variants[dim][props[dim]], ...matchedCompounds)
///
/// Config 需要提供:
///   - Variants: struct 类型，每个字段是一个 variant 维度（enum 或 bool），有默认值
///   - base(tokens) -> ConditionalStyle: 基础样式（可选）
///   - variants: tuple of resolver functions: fn(value, tokens) -> ConditionalStyle（可选）
///   - derived(variants, tokens) -> ConditionalStyle（可选）: 跨维度组合逻辑，
///     拿到完整 Variants，承载单维度 resolver 表达不了的"连续函数型组合"
///     （如 padding = f(size, icon 模式)）。约定：derived 只产出几何字段
///     （padding/radius/height/width/gap 等），**禁碰 background**,
///     background 三态取色走 bgColors()，derived 写入会污染动画取色。
///   - compounds: tuple of { matches: fn(Variants) -> bool, style: fn(tokens) -> ConditionalStyle }（可选）
pub fn recipe(comptime Config: type) type {
    comptime {
        if (!@hasDecl(Config, "Variants")) @compileError("Recipe Config 必须有 Variants 类型");
    }

    return struct {
        pub const Variants = Config.Variants;

        /// 核心 resolve，对标 CVA 的 resolve(props)
        ///
        /// 合并优先级: base < variants < derived < compounds（后者覆盖前者）
        pub fn resolve(variants: Variants, tokens: *const ThemeTokens) ConditionalStyle {
            // Step 1: base
            var result: ConditionalStyle = if (@hasDecl(Config, "base"))
                Config.base(tokens)
            else
                .{};

            // Step 2: 遍历每个 variant 维度，merge 其选中值的样式
            if (@hasDecl(Config, "variants")) {
                inline for (std.meta.fields(@TypeOf(Config.variants))) |field| {
                    const dim_resolver = @field(Config.variants, field.name);
                    const variant_value = @field(variants, field.name);
                    const variant_style = dim_resolver(variant_value, tokens);
                    result = result.merge(variant_style);
                }
            }

            // Step 2.5: derived，跨维度组合（拿完整 Variants）
            if (@hasDecl(Config, "derived")) {
                result = result.merge(Config.derived(variants, tokens));
            }

            // Step 3: compound variants, AND 匹配
            if (@hasDecl(Config, "compounds")) {
                inline for (Config.compounds) |compound| {
                    if (compound.matches(variants)) {
                        result = result.merge(compound.style(tokens));
                    }
                }
            }

            return result;
        }

        /// 便捷方法：只取 base 态的 StyleOverride
        pub fn resolveBase(variants: Variants, tokens: *const ThemeTokens) StyleOverride {
            return resolve(variants, tokens).base;
        }
    };
}

// ============================================================================
// 3. slotRecipe()，多部件配方 (对标 Panda sva())
// ============================================================================

/// comptime SlotRecipe 工厂函数
///
/// 核心算法从 Panda getSlotRecipes() + sva() 翻译:
///   1. 为每个 slot 独立运行 recipe resolve
///   2. 一个 variant 值同时产出所有 slot 的样式
///
/// Config 需要提供:
///   - Slots: struct 类型，每个字段是 ConditionalStyle（代表一个组件部件）
///   - Variants: struct 类型（同 recipe）
///   - base(tokens) -> Slots（可选）
///   - variants: tuple of resolver functions: fn(value, tokens) -> Slots（可选）
///   - compounds: tuple of { matches, style -> Slots }（可选）
pub fn slotRecipe(comptime Config: type) type {
    comptime {
        if (!@hasDecl(Config, "Slots")) @compileError("SlotRecipe Config 必须有 Slots 类型");
        if (!@hasDecl(Config, "Variants")) @compileError("SlotRecipe Config 必须有 Variants 类型");
        // 验证 Slots 的每个字段都是 ConditionalStyle
        for (std.meta.fields(Config.Slots)) |field| {
            if (field.type != ConditionalStyle) {
                @compileError("Slots." ++ field.name ++ " 必须是 ConditionalStyle 类型");
            }
        }
    }

    return struct {
        pub const Slots = Config.Slots;
        pub const Variants = Config.Variants;

        /// 核心 resolve，返回每个 slot 的 ConditionalStyle
        pub fn resolve(variants: Variants, tokens: *const ThemeTokens) Slots {
            // Step 1: base
            var result: Slots = if (@hasDecl(Config, "base"))
                Config.base(tokens)
            else
                .{};

            // Step 2: 遍历 variant 维度
            if (@hasDecl(Config, "variants")) {
                inline for (std.meta.fields(@TypeOf(Config.variants))) |field| {
                    const dim_resolver = @field(Config.variants, field.name);
                    const variant_value = @field(variants, field.name);
                    const slot_styles: Slots = dim_resolver(variant_value, tokens);
                    // merge 每个 slot
                    inline for (std.meta.fields(Slots)) |sf| {
                        @field(result, sf.name) = @field(result, sf.name)
                            .merge(@field(slot_styles, sf.name));
                    }
                }
            }

            // Step 2.5: derived，跨维度组合（拿完整 Variants，约定同 recipe）
            if (@hasDecl(Config, "derived")) {
                const derived_slots: Slots = Config.derived(variants, tokens);
                inline for (std.meta.fields(Slots)) |sf| {
                    @field(result, sf.name) = @field(result, sf.name)
                        .merge(@field(derived_slots, sf.name));
                }
            }

            // Step 3: compound variants
            if (@hasDecl(Config, "compounds")) {
                inline for (Config.compounds) |compound| {
                    if (compound.matches(variants)) {
                        const compound_slots: Slots = compound.style(tokens);
                        inline for (std.meta.fields(Slots)) |sf| {
                            @field(result, sf.name) = @field(result, sf.name)
                                .merge(@field(compound_slots, sf.name));
                        }
                    }
                }
            }

            return result;
        }
    };
}

// ============================================================================
// 4. transition(), CSS 风格的 transition 字符串 comptime 解析器
// ============================================================================

/// 解析结果：一组 (属性, 配置) 对
pub const TransitionEntry = struct {
    prop: TransitionProp,
    spec: TransitionSpec,
};

/// 编译期解析 CSS transition 字符串，返回固定大小数组
///
/// 支持的格式 (与 CSS transition 语法对齐):
///   "background 200ms ease-out"
///   "background 200ms ease-out, opacity 150ms"
///   "background 200ms, opacity 150ms linear"
///   "all 200ms ease-out"               <- 所有可过渡属性
///   "background 0.2s ease-in-out"       <- 秒单位
///   "background 200ms"                  <- 省略 easing -> 默认 ease-out-quad
///   "background"                        <- 省略 duration -> 默认 150ms
///
/// 属性名映射 (CSS -> TransitionProp):
///   background / background-color / bg    -> .background
///   opacity                               -> .opacity
///   border-color                          -> .border_color
///   border-width                          -> .border_width
///   translate-x / translateX / transform-x -> .translate_x
///   translate-y / translateY / transform-y -> .translate_y
///   scale-x / scaleX                      -> .scale_x
///   scale-y / scaleY                      -> .scale_y
///   rotate / rotation                     -> .rotate
///   corner-radius / border-radius         -> .corner_radius
///   all                                   -> 所有 11 个属性
///
/// Easing 名映射 (CSS -> Easing):
///   linear                                -> .linear
///   ease / ease-out / ease-in / ease-in-out -> quad 版本
///   ease-out-cubic / ease-in-cubic / ...   -> 对应 Easing 枚举
///   spring / bounce                       -> ease_out_back / ease_out_bounce
///
/// 示例:
/// ```zig
/// const spec = comptime transition("background 200ms ease-out, opacity 150ms");
/// node.applyTransition(allocator, &spec);
/// ```
pub fn transition(comptime input: []const u8) [countTransitionEntries(input)]TransitionEntry {
    @setEvalBranchQuota(10000);
    return comptime parseTransition(input);
}

/// 编译期计算结果数组大小
fn countTransitionEntries(comptime input: []const u8) usize {
    @setEvalBranchQuota(10000);
    comptime {
        var count: usize = 0;
        const segments = splitByComma(input);
        for (segments.items[0..segments.len]) |segment| {
            const prop_str = firstToken(segment);
            if (eqlIgnoreCase(prop_str, "all")) {
                count += 11; // 所有可过渡属性
            } else {
                count += 1;
            }
        }
        return count;
    }
}

/// 编译期解析 transition 字符串
fn parseTransition(comptime input: []const u8) [countTransitionEntries(input)]TransitionEntry {
    @setEvalBranchQuota(10000);
    comptime {
        const N = countTransitionEntries(input);
        var result: [N]TransitionEntry = undefined;
        var idx: usize = 0;

        const segments = splitByComma(input);

        for (segments.items[0..segments.len]) |segment| {
            const tokens = tokenize(segment);

            // 第一个 token 是属性名
            const prop_str = tokens.items[0];
            // 后续 token 中找 duration 和 easing
            const duration = findDuration(tokens);
            const easing = findEasing(tokens);
            const spec = TransitionSpec{
                .duration_ms = duration,
                .easing = easing,
            };

            if (eqlIgnoreCase(prop_str, "all")) {
                // "all" -> 展开为所有 11 个属性
                const all_props = [_]TransitionProp{
                    .background,   .opacity,     .border_color,
                    .translate_x,  .translate_y, .scale_x,
                    .scale_y,      .rotate,      .corner_radius,
                    .border_width, .width,
                };
                for (all_props) |prop| {
                    result[idx] = .{ .prop = prop, .spec = spec };
                    idx += 1;
                }
            } else {
                const prop = parsePropName(prop_str) orelse
                    @compileError("未知的 transition 属性: \"" ++ prop_str ++ "\"\n支持的属性: background, opacity, border-color, border-width, translate-x, translate-y, scale-x, scale-y, rotate, corner-radius, width, all");
                result[idx] = .{ .prop = prop, .spec = spec };
                idx += 1;
            }
        }

        return result;
    }
}

// ── 属性名解析 ──────────────────────────────────────────

fn parsePropName(comptime name: []const u8) ?TransitionProp {
    // background 系列
    if (eqlIgnoreCase(name, "background") or
        eqlIgnoreCase(name, "background-color") or
        eqlIgnoreCase(name, "bg")) return .background;

    // opacity
    if (eqlIgnoreCase(name, "opacity")) return .opacity;

    // border-color
    if (eqlIgnoreCase(name, "border-color") or
        eqlIgnoreCase(name, "borderColor") or
        eqlIgnoreCase(name, "border_color")) return .border_color;

    // border-width
    if (eqlIgnoreCase(name, "border-width") or
        eqlIgnoreCase(name, "borderWidth") or
        eqlIgnoreCase(name, "border_width")) return .border_width;

    // translate-x
    if (eqlIgnoreCase(name, "translate-x") or
        eqlIgnoreCase(name, "translateX") or
        eqlIgnoreCase(name, "translate_x") or
        eqlIgnoreCase(name, "transform-x")) return .translate_x;

    // translate-y
    if (eqlIgnoreCase(name, "translate-y") or
        eqlIgnoreCase(name, "translateY") or
        eqlIgnoreCase(name, "translate_y") or
        eqlIgnoreCase(name, "transform-y")) return .translate_y;

    // scale-x
    if (eqlIgnoreCase(name, "scale-x") or
        eqlIgnoreCase(name, "scaleX") or
        eqlIgnoreCase(name, "scale_x")) return .scale_x;

    // scale-y
    if (eqlIgnoreCase(name, "scale-y") or
        eqlIgnoreCase(name, "scaleY") or
        eqlIgnoreCase(name, "scale_y")) return .scale_y;

    // rotate
    if (eqlIgnoreCase(name, "rotate") or
        eqlIgnoreCase(name, "rotation")) return .rotate;

    // corner-radius
    if (eqlIgnoreCase(name, "corner-radius") or
        eqlIgnoreCase(name, "border-radius") or
        eqlIgnoreCase(name, "borderRadius") or
        eqlIgnoreCase(name, "corner_radius")) return .corner_radius;

    // width
    if (eqlIgnoreCase(name, "width")) return .width;

    return null;
}

// ── Duration 解析 ──────────────────────────────────────────

/// 在 tokens 中查找 duration 值 (数字 + ms/s 后缀)
fn findDuration(comptime tokens: Tokens) f32 {
    comptime {
        // 从第二个 token 开始找（第一个是属性名）
        for (tokens.items[1..tokens.len]) |token| {
            if (parseDurationValue(token)) |d| return d;
        }
        return 150; // 默认 150ms
    }
}

/// 尝试解析 "200ms" / "0.2s" / "200" 为毫秒值
fn parseDurationValue(comptime token: []const u8) ?f32 {
    comptime {
        if (token.len == 0) return null;

        // 检查后缀
        if (endsWith(token, "ms")) {
            return parseFloat(token[0 .. token.len - 2]);
        } else if (endsWith(token, "s") and !isAlpha(token[0])) {
            // "0.2s" -> 200ms
            if (parseFloat(token[0 .. token.len - 1])) |secs| {
                return secs * 1000;
            }
            return null;
        } else {
            // 纯数字 -> 当作 ms
            if (isDigit(token[0])) {
                return parseFloat(token);
            }
            return null;
        }
    }
}

// ── Easing 解析 ──────────────────────────────────────────

/// 在 tokens 中查找 easing 名
fn findEasing(comptime tokens: Tokens) Easing {
    comptime {
        for (tokens.items[1..tokens.len]) |token| {
            if (parseDurationValue(token) != null) continue; // 跳过 duration
            if (parseEasingName(token)) |e| return e;
        }
        return .ease_out_quad; // 默认
    }
}

fn parseEasingName(comptime name: []const u8) ?Easing {
    // cubic-bezier(x1,y1,x2,y2)，括号内逗号分隔，无空格
    if (name.len > 13 and eqlIgnoreCase(name[0..13], "cubic-bezier(") and name[name.len - 1] == ')') {
        const inner = name[13 .. name.len - 1];
        const params = parseBezierParams(inner);
        return .{ .cubic_bezier = .{
            .x1 = params[0],
            .y1 = params[1],
            .x2 = params[2],
            .y2 = params[3],
        } };
    }

    // CSS 标准 easing
    if (eqlIgnoreCase(name, "linear")) return .linear;
    if (eqlIgnoreCase(name, "ease") or eqlIgnoreCase(name, "ease-out")) return .ease_out_quad;
    if (eqlIgnoreCase(name, "ease-in")) return .ease_in_quad;
    if (eqlIgnoreCase(name, "ease-in-out")) return .ease_in_out_quad;

    // quad
    if (eqlIgnoreCase(name, "ease-in-quad")) return .ease_in_quad;
    if (eqlIgnoreCase(name, "ease-out-quad")) return .ease_out_quad;
    if (eqlIgnoreCase(name, "ease-in-out-quad")) return .ease_in_out_quad;

    // cubic
    if (eqlIgnoreCase(name, "ease-in-cubic")) return .ease_in_cubic;
    if (eqlIgnoreCase(name, "ease-out-cubic")) return .ease_out_cubic;
    if (eqlIgnoreCase(name, "ease-in-out-cubic")) return .ease_in_out_cubic;

    // quart
    if (eqlIgnoreCase(name, "ease-in-quart")) return .ease_in_quart;
    if (eqlIgnoreCase(name, "ease-out-quart")) return .ease_out_quart;
    if (eqlIgnoreCase(name, "ease-in-out-quart")) return .ease_in_out_quart;

    // quint
    if (eqlIgnoreCase(name, "ease-in-quint")) return .ease_in_quint;
    if (eqlIgnoreCase(name, "ease-out-quint")) return .ease_out_quint;
    if (eqlIgnoreCase(name, "ease-in-out-quint")) return .ease_in_out_quint;

    // sine
    if (eqlIgnoreCase(name, "ease-in-sine")) return .ease_in_sine;
    if (eqlIgnoreCase(name, "ease-out-sine")) return .ease_out_sine;
    if (eqlIgnoreCase(name, "ease-in-out-sine")) return .ease_in_out_sine;

    // expo
    if (eqlIgnoreCase(name, "ease-in-expo")) return .ease_in_expo;
    if (eqlIgnoreCase(name, "ease-out-expo")) return .ease_out_expo;
    if (eqlIgnoreCase(name, "ease-in-out-expo")) return .ease_in_out_expo;

    // circ
    if (eqlIgnoreCase(name, "ease-in-circ")) return .ease_in_circ;
    if (eqlIgnoreCase(name, "ease-out-circ")) return .ease_out_circ;
    if (eqlIgnoreCase(name, "ease-in-out-circ")) return .ease_in_out_circ;

    // elastic
    if (eqlIgnoreCase(name, "ease-in-elastic")) return .ease_in_elastic;
    if (eqlIgnoreCase(name, "ease-out-elastic")) return .ease_out_elastic;
    if (eqlIgnoreCase(name, "ease-in-out-elastic")) return .ease_in_out_elastic;

    // back
    if (eqlIgnoreCase(name, "ease-in-back")) return .ease_in_back;
    if (eqlIgnoreCase(name, "ease-out-back") or eqlIgnoreCase(name, "spring")) return .ease_out_back;
    if (eqlIgnoreCase(name, "ease-in-out-back")) return .ease_in_out_back;

    // bounce
    if (eqlIgnoreCase(name, "ease-in-bounce")) return .ease_in_bounce;
    if (eqlIgnoreCase(name, "ease-out-bounce") or eqlIgnoreCase(name, "bounce")) return .ease_out_bounce;
    if (eqlIgnoreCase(name, "ease-in-out-bounce")) return .ease_in_out_bounce;

    return null;
}

// ── CubicBezier 参数解析 ─────────────────────────────────

/// 解析 "x1,y1,x2,y2" 格式的贝塞尔参数 (comptime)
fn parseBezierParams(comptime inner: []const u8) [4]f32 {
    comptime {
        var result: [4]f32 = undefined;
        var param_idx: usize = 0;
        var start: usize = 0;
        var i: usize = 0;
        while (i <= inner.len) : (i += 1) {
            if (i == inner.len or inner[i] == ',') {
                const token = trimWhitespace(inner[start..i]);
                if (token.len > 0) {
                    if (param_idx >= 4) @compileError("cubic-bezier() 需要 4 个参数");
                    result[param_idx] = parseSignedFloat(token) orelse
                        @compileError("cubic-bezier() 参数解析失败: \"" ++ token ++ "\"");
                    param_idx += 1;
                }
                start = i + 1;
            }
        }
        if (param_idx != 4) @compileError("cubic-bezier() 需要 4 个参数");
        return result;
    }
}

/// comptime 有符号 float 解析 (支持负号前缀)
fn parseSignedFloat(comptime s: []const u8) ?f32 {
    comptime {
        if (s.len == 0) return null;
        if (s[0] == '-') {
            if (parseFloat(s[1..])) |v| return -v;
            return null;
        }
        return parseFloat(s);
    }
}

// ── Comptime 字符串工具 ──────────────────────────────────

const MAX_SEGMENTS = 16;
const MAX_TOKENS = 8;

const Segments = struct {
    items: [MAX_SEGMENTS][]const u8,
    len: usize,
};

const Tokens = struct {
    items: [MAX_TOKENS][]const u8,
    len: usize,
};

/// 按逗号分割，trim 空白（跳过括号内的逗号，支持 cubic-bezier(...)）
fn splitByComma(comptime input: []const u8) Segments {
    comptime {
        var result = Segments{ .items = undefined, .len = 0 };
        var start: usize = 0;
        var i: usize = 0;
        var paren_depth: u32 = 0;
        while (i < input.len) : (i += 1) {
            if (input[i] == '(') {
                paren_depth += 1;
            } else if (input[i] == ')') {
                if (paren_depth > 0) paren_depth -= 1;
            } else if (input[i] == ',' and paren_depth == 0) {
                const seg = trimWhitespace(input[start..i]);
                if (seg.len > 0) {
                    result.items[result.len] = seg;
                    result.len += 1;
                }
                start = i + 1;
            }
        }
        const last = trimWhitespace(input[start..]);
        if (last.len > 0) {
            result.items[result.len] = last;
            result.len += 1;
        }
        return result;
    }
}

/// 按空白分割
fn tokenize(comptime input: []const u8) Tokens {
    comptime {
        var result = Tokens{ .items = undefined, .len = 0 };
        var i: usize = 0;
        while (i < input.len) {
            // 跳过空白
            while (i < input.len and isWhitespace(input[i])) : (i += 1) {}
            if (i >= input.len) break;
            // 找 token 结尾
            const start = i;
            while (i < input.len and !isWhitespace(input[i])) : (i += 1) {}
            if (result.len < MAX_TOKENS) {
                result.items[result.len] = input[start..i];
                result.len += 1;
            }
        }
        return result;
    }
}

/// 获取第一个 token
fn firstToken(comptime input: []const u8) []const u8 {
    comptime {
        const tokens = tokenize(input);
        if (tokens.len == 0) @compileError("transition 段为空");
        return tokens.items[0];
    }
}

fn trimWhitespace(comptime s: []const u8) []const u8 {
    comptime {
        var start: usize = 0;
        while (start < s.len and isWhitespace(s[start])) : (start += 1) {}
        var end: usize = s.len;
        while (end > start and isWhitespace(s[end - 1])) : (end -= 1) {}
        return s[start..end];
    }
}

fn isWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isAlpha(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

fn endsWith(comptime s: []const u8, comptime suffix: []const u8) bool {
    if (s.len < suffix.len) return false;
    return eqlIgnoreCase(s[s.len - suffix.len ..], suffix);
}

fn eqlIgnoreCase(comptime a: []const u8, comptime b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (toLower(ca) != toLower(cb)) return false;
    }
    return true;
}

fn toLower(c: u8) u8 {
    if (c >= 'A' and c <= 'Z') return c + 32;
    return c;
}

/// comptime float 解析 (支持整数和小数)
fn parseFloat(comptime s: []const u8) ?f32 {
    comptime {
        if (s.len == 0) return null;
        var integer_part: f32 = 0;
        var i: usize = 0;
        var has_digit = false;

        while (i < s.len and isDigit(s[i])) : (i += 1) {
            integer_part = integer_part * 10 + @as(f32, @floatFromInt(s[i] - '0'));
            has_digit = true;
        }

        var frac_part: f32 = 0;
        if (i < s.len and s[i] == '.') {
            i += 1;
            var divisor: f32 = 10;
            while (i < s.len and isDigit(s[i])) : (i += 1) {
                frac_part += @as(f32, @floatFromInt(s[i] - '0')) / divisor;
                divisor *= 10;
                has_digit = true;
            }
        }

        if (!has_digit) return null;
        if (i != s.len) return null; // 还有剩余字符，不是纯数字
        return integer_part + frac_part;
    }
}

// ============================================================================
// 测试
// ============================================================================

test "transition: 单属性 + duration + easing" {
    const spec = comptime transition("background 200ms ease-out");
    try std.testing.expectEqual(@as(usize, 1), spec.len);
    try std.testing.expectEqual(TransitionProp.background, spec[0].prop);
    try std.testing.expectEqual(@as(f32, 200), spec[0].spec.duration_ms);
    try std.testing.expectEqual(Easing.ease_out_quad, spec[0].spec.easing);
}

test "transition: 多属性逗号分隔" {
    const spec = comptime transition("background 200ms ease-out, opacity 150ms linear");
    try std.testing.expectEqual(@as(usize, 2), spec.len);
    try std.testing.expectEqual(TransitionProp.background, spec[0].prop);
    try std.testing.expectEqual(@as(f32, 200), spec[0].spec.duration_ms);
    try std.testing.expectEqual(TransitionProp.opacity, spec[1].prop);
    try std.testing.expectEqual(@as(f32, 150), spec[1].spec.duration_ms);
    try std.testing.expectEqual(Easing.linear, spec[1].spec.easing);
}

test "transition: 秒单位" {
    const spec = comptime transition("opacity 0.3s");
    try std.testing.expectEqual(@as(usize, 1), spec.len);
    try std.testing.expectEqual(@as(f32, 300), spec[0].spec.duration_ms);
}

test "transition: 省略 easing 使用默认值" {
    const spec = comptime transition("border-color 100ms");
    try std.testing.expectEqual(@as(usize, 1), spec.len);
    try std.testing.expectEqual(TransitionProp.border_color, spec[0].prop);
    try std.testing.expectEqual(@as(f32, 100), spec[0].spec.duration_ms);
    try std.testing.expectEqual(Easing.ease_out_quad, spec[0].spec.easing);
}

test "transition: 省略 duration 使用默认值" {
    const spec = comptime transition("opacity");
    try std.testing.expectEqual(@as(usize, 1), spec.len);
    try std.testing.expectEqual(@as(f32, 150), spec[0].spec.duration_ms);
}

test "transition: all 展开为所有属性" {
    const spec = comptime transition("all 200ms ease-out-cubic");
    try std.testing.expectEqual(@as(usize, 11), spec.len);
    // 验证所有属性都有
    try std.testing.expectEqual(TransitionProp.background, spec[0].prop);
    try std.testing.expectEqual(TransitionProp.opacity, spec[1].prop);
    try std.testing.expectEqual(TransitionProp.border_color, spec[2].prop);
    try std.testing.expectEqual(TransitionProp.translate_x, spec[3].prop);
    try std.testing.expectEqual(TransitionProp.translate_y, spec[4].prop);
    try std.testing.expectEqual(TransitionProp.scale_x, spec[5].prop);
    try std.testing.expectEqual(TransitionProp.scale_y, spec[6].prop);
    try std.testing.expectEqual(TransitionProp.rotate, spec[7].prop);
    try std.testing.expectEqual(TransitionProp.corner_radius, spec[8].prop);
    try std.testing.expectEqual(TransitionProp.border_width, spec[9].prop);
    try std.testing.expectEqual(TransitionProp.width, spec[10].prop);
    // 所有 spec 相同
    for (spec) |entry| {
        try std.testing.expectEqual(@as(f32, 200), entry.spec.duration_ms);
        try std.testing.expectEqual(Easing.ease_out_cubic, entry.spec.easing);
    }
}

test "transition: rotate alias" {
    const spec = comptime transition("rotation 120ms linear");
    try std.testing.expectEqual(@as(usize, 1), spec.len);
    try std.testing.expectEqual(TransitionProp.rotate, spec[0].prop);
    try std.testing.expectEqual(@as(f32, 120), spec[0].spec.duration_ms);
    try std.testing.expectEqual(Easing.linear, spec[0].spec.easing);
}

test "transition: CSS 别名" {
    const spec = comptime transition("border-radius 300ms, bg 100ms, translateX 200ms");
    try std.testing.expectEqual(@as(usize, 3), spec.len);
    try std.testing.expectEqual(TransitionProp.corner_radius, spec[0].prop);
    try std.testing.expectEqual(TransitionProp.background, spec[1].prop);
    try std.testing.expectEqual(TransitionProp.translate_x, spec[2].prop);
}

test "transition: spring 和 bounce 别名" {
    const spec = comptime transition("translate-x 300ms spring, opacity 200ms bounce");
    try std.testing.expectEqual(Easing.ease_out_back, spec[0].spec.easing);
    try std.testing.expectEqual(Easing.ease_out_bounce, spec[1].spec.easing);
}

test "transition: 混合格式" {
    const spec = comptime transition("background 0.2s ease-in-out, translate-y 400ms ease-out-expo, opacity 100ms");
    try std.testing.expectEqual(@as(usize, 3), spec.len);
    try std.testing.expectEqual(@as(f32, 200), spec[0].spec.duration_ms);
    try std.testing.expectEqual(Easing.ease_in_out_quad, spec[0].spec.easing);
    try std.testing.expectEqual(@as(f32, 400), spec[1].spec.duration_ms);
    try std.testing.expectEqual(Easing.ease_out_expo, spec[1].spec.easing);
    try std.testing.expectEqual(@as(f32, 100), spec[2].spec.duration_ms);
}

test "ConditionalStyle: resolve 基础" {
    const s = ConditionalStyle{
        .base = .{ .background = Color.hex(0xFF0000), .opacity = 1.0 },
        .hover = .{ .background = Color.hex(0x00FF00) },
        .disabled = .{ .opacity = 0.5 },
    };

    // 正常态
    const normal = s.resolve(.{});
    try std.testing.expect(normal.background != null);
    try std.testing.expectEqual(Color.hex(0xFF0000), normal.background.?);

    // hover 态
    const hovered = s.resolve(.{ .is_hovered = true });
    try std.testing.expectEqual(Color.hex(0x00FF00), hovered.background.?);
    try std.testing.expectEqual(@as(f32, 1.0), hovered.opacity.?);

    // disabled 态 (不叠加 hover)
    const disabled = s.resolve(.{ .is_disabled = true, .is_hovered = true });
    try std.testing.expectEqual(Color.hex(0xFF0000), disabled.background.?); // base 的 bg，hover 不叠加
    try std.testing.expectEqual(@as(f32, 0.5), disabled.opacity.?);
}

test "ConditionalStyle: selected 底态与 hover 叠加, hover 覆盖重叠字段" {
    const s = ConditionalStyle{
        .base = .{ .background = Color.hex(0x111111) },
        .selected = .{ .background = Color.hex(0x222222), .border_width = 2 },
        .hover = .{ .background = Color.hex(0x333333) },
    };

    // 仅 selected：selected 覆盖 base 背景，带上 border_width
    const sel = s.resolve(.{ .is_selected = true });
    try std.testing.expectEqual(Color.hex(0x222222), sel.background.?);
    try std.testing.expectEqual(@as(f32, 2), sel.border_width.?);

    // selected + hover：hover 背景压过 selected，selected 的 border_width 保留
    const sel_hover = s.resolve(.{ .is_selected = true, .is_hovered = true });
    try std.testing.expectEqual(Color.hex(0x333333), sel_hover.background.?);
    try std.testing.expectEqual(@as(f32, 2), sel_hover.border_width.?);

    // 未选中不叠加
    const plain = s.resolve(.{});
    try std.testing.expectEqual(Color.hex(0x111111), plain.background.?);
    try std.testing.expect(plain.border_width == null);
}

test "ConditionalStyle: invalid 压过 hover/focus" {
    const s = ConditionalStyle{
        .base = .{ .border_color = Color.hex(0x888888) },
        .hover = .{ .border_color = Color.hex(0x00FF00) },
        .focus = .{ .border_color = Color.hex(0x0000FF) },
        .invalid = .{ .border_color = Color.hex(0xFF0000) },
    };
    const r = s.resolve(.{ .is_hovered = true, .is_focused = true, .is_invalid = true });
    try std.testing.expectEqual(Color.hex(0xFF0000), r.border_color.?);
}

test "ConditionalStyle: expanded 底态在 hover 之前" {
    const s = ConditionalStyle{
        .base = .{ .background = Color.hex(0x111111) },
        .expanded = .{ .background = Color.hex(0x222222) },
        .hover = .{ .background = Color.hex(0x333333) },
    };
    const r = s.resolve(.{ .is_expanded = true, .is_hovered = true });
    try std.testing.expectEqual(Color.hex(0x333333), r.background.?);
    const r2 = s.resolve(.{ .is_expanded = true });
    try std.testing.expectEqual(Color.hex(0x222222), r2.background.?);
}

test "ConditionalStyle: disabled 短路忽略 selected/invalid" {
    const s = ConditionalStyle{
        .base = .{ .opacity = 1.0, .background = Color.hex(0x111111) },
        .selected = .{ .background = Color.hex(0x222222) },
        .invalid = .{ .border_color = Color.hex(0xFF0000) },
        .disabled = .{ .opacity = 0.5 },
    };
    const r = s.resolve(.{ .is_disabled = true, .is_selected = true, .is_invalid = true });
    try std.testing.expectEqual(@as(f32, 0.5), r.opacity.?);
    try std.testing.expectEqual(Color.hex(0x111111), r.background.?); // selected 不叠加
    try std.testing.expect(r.border_color == null); // invalid 不叠加
}

test "ConditionalStyle: merge 与 override 覆盖新条件字段" {
    const a = ConditionalStyle{
        .selected = .{ .background = Color.hex(0x111111) },
    };
    const b = ConditionalStyle{
        .selected = .{ .border_width = 2 },
        .invalid = .{ .border_color = Color.hex(0xFF0000) },
    };
    const merged = a.merge(b);
    try std.testing.expect(merged.selected.?.background != null);
    try std.testing.expect(merged.selected.?.border_width != null);
    try std.testing.expect(merged.invalid != null);

    const overridden = merged.override(.{
        .selected_style = .{ .background = Color.hex(0x999999) },
        .invalid_style = .{ .opacity = 0.9 },
    });
    try std.testing.expectEqual(Color.hex(0x999999), overridden.selected.?.background.?);
    try std.testing.expectEqual(@as(f32, 0.9), overridden.invalid.?.opacity.?);
}

test "ConditionalStyle: merge" {
    const a = ConditionalStyle{
        .base = .{ .background = Color.hex(0xFF0000) },
        .hover = .{ .opacity = 0.8 },
    };
    const b = ConditionalStyle{
        .base = .{ .text_color = Color.hex(0x000000) },
        .hover = .{ .background = Color.hex(0x00FF00) },
        .disabled = .{ .opacity = 0.5 },
    };
    const merged = a.merge(b);

    // base 合并了两者
    try std.testing.expect(merged.base.background != null);
    try std.testing.expect(merged.base.text_color != null);

    // hover 合并了两者
    try std.testing.expect(merged.hover != null);
    try std.testing.expect(merged.hover.?.opacity != null); // 来自 a
    try std.testing.expect(merged.hover.?.background != null); // 来自 b

    // disabled 只来自 b
    try std.testing.expect(merged.disabled != null);
    try std.testing.expectEqual(@as(f32, 0.5), merged.disabled.?.opacity.?);
}

test "ConditionalStyle: merge keeps margin_spec semantics" {
    const a = ConditionalStyle{
        .base = .{ .margin_spec = (types.Margin{ .left = 8 }).withAutoLeft() },
        .hover = .{ .margin_spec = types.Margin.autoHorizontal() },
    };
    const b = ConditionalStyle{
        .base = .{ .margin_spec = (types.Margin{ .right = 12 }).withAutoRight() },
        .hover = .{ .opacity = 0.8 },
    };
    const merged = a.merge(b);

    try std.testing.expect(merged.base.margin_spec != null);
    try std.testing.expectEqual(@as(f32, 12), merged.base.margin_spec.?.right);
    try std.testing.expect(merged.base.margin_spec.?.rightIsAuto());
    try std.testing.expect(!merged.base.margin_spec.?.leftIsAuto());
    try std.testing.expect(merged.hover.?.margin_spec != null);
    try std.testing.expect(merged.hover.?.margin_spec.?.leftIsAuto());
    try std.testing.expect(merged.hover.?.margin_spec.?.rightIsAuto());
    try std.testing.expectEqual(@as(f32, 0.8), merged.hover.?.opacity.?);
}

test "ConditionalStyle: bgColors" {
    const s = ConditionalStyle{
        .base = .{ .background = Color.hex(0xFF0000) },
        .hover = .{ .background = Color.hex(0x00FF00) },
        .active = .{ .background = Color.hex(0x0000FF) },
    };
    const colors = s.bgColors();
    try std.testing.expectEqual(Color.hex(0xFF0000), colors.normal);
    try std.testing.expectEqual(Color.hex(0x00FF00), colors.hover);
    try std.testing.expectEqual(Color.hex(0x0000FF), colors.pressed);
}

test "ConditionalStyle: bgColors 继承" {
    // hover 没指定 bg -> 继承 normal
    const s = ConditionalStyle{
        .base = .{ .background = Color.hex(0xFF0000) },
        .hover = .{ .opacity = 0.8 },
    };
    const colors = s.bgColors();
    try std.testing.expectEqual(Color.hex(0xFF0000), colors.normal);
    try std.testing.expectEqual(Color.hex(0xFF0000), colors.hover); // 继承 normal
    try std.testing.expectEqual(Color.hex(0xFF0000), colors.pressed); // 继承 hover → normal
}

test "recipe: 基础 resolve" {
    const TestSize = enum { sm, lg };
    const TestRecipe = recipe(struct {
        pub const Variants = struct {
            size: TestSize = .sm,
        };

        pub fn base(_: *const ThemeTokens) ConditionalStyle {
            return .{ .base = .{ .cursor = .pointer } };
        }

        pub const variants = .{
            .size = struct {
                fn resolve(s: TestSize, _: *const ThemeTokens) ConditionalStyle {
                    return switch (s) {
                        .sm => .{ .base = .{ .height = .{ .px = 28 } } },
                        .lg => .{ .base = .{ .height = .{ .px = 42 } } },
                    };
                }
            }.resolve,
        };
    });

    const tokens = &theme.dark;

    const sm = TestRecipe.resolve(.{ .size = .sm }, tokens);
    try std.testing.expectEqual(types.CursorShape.pointer, sm.base.cursor.?);
    try std.testing.expectEqual(@as(f32, 28), sm.base.height.?.px);

    const lg = TestRecipe.resolve(.{ .size = .lg }, tokens);
    try std.testing.expectEqual(@as(f32, 42), lg.base.height.?.px);
}

test "recipe: compound variants" {
    const TestVariant = enum { primary, secondary, danger };
    const TestSize = enum { sm, md };
    const CompoundRecipe = recipe(struct {
        pub const Variants = struct {
            variant: TestVariant = .primary,
            size: TestSize = .md,
        };

        pub fn base(_: *const ThemeTokens) ConditionalStyle {
            return .{ .base = .{ .cursor = .pointer } };
        }

        pub const variants = .{
            .variant = struct {
                fn resolve(v: TestVariant, _: *const ThemeTokens) ConditionalStyle {
                    return switch (v) {
                        .primary => .{ .base = .{ .background = Color.hex(0x0000FF) } },
                        .secondary => .{ .base = .{ .background = Color.hex(0xCCCCCC) } },
                        .danger => .{ .base = .{ .background = Color.hex(0xFF0000) } },
                    };
                }
            }.resolve,
            .size = struct {
                fn resolve(s: TestSize, _: *const ThemeTokens) ConditionalStyle {
                    return switch (s) {
                        .sm => .{ .base = .{ .height = .{ .px = 28 } } },
                        .md => .{ .base = .{ .height = .{ .px = 36 } } },
                    };
                }
            }.resolve,
        };

        // compound: danger + sm -> 特殊文本颜色
        pub const compounds = .{
            .{
                .matches = struct {
                    fn f(v: Variants) bool {
                        return v.variant == .danger and v.size == .sm;
                    }
                }.f,
                .style = struct {
                    fn f(_: *const ThemeTokens) ConditionalStyle {
                        return .{ .base = .{ .text_color = Color.hex(0xFFFF00) } };
                    }
                }.f,
            },
        };
    });

    const tokens = &theme.dark;

    // 非 compound 组合 -> 无额外样式
    const primary_md = CompoundRecipe.resolve(.{ .variant = .primary, .size = .md }, tokens);
    try std.testing.expect(primary_md.base.text_color == null);

    // compound 匹配 -> danger + sm 有特殊 text_color
    const danger_sm = CompoundRecipe.resolve(.{ .variant = .danger, .size = .sm }, tokens);
    try std.testing.expect(danger_sm.base.text_color != null);
    try std.testing.expectEqual(Color.hex(0xFFFF00), danger_sm.base.text_color.?);
    try std.testing.expectEqual(Color.hex(0xFF0000), danger_sm.base.background.?); // variant 的 bg 也在

    // danger + md -> compound 不匹配
    const danger_md = CompoundRecipe.resolve(.{ .variant = .danger, .size = .md }, tokens);
    try std.testing.expect(danger_md.base.text_color == null);
}

test "recipe: derived 跨维度组合与优先级 base<variants<derived<compounds" {
    const TestSize = enum { sm, lg };
    const DerivedRecipe = recipe(struct {
        pub const Variants = struct {
            size: TestSize = .sm,
            icon_only: bool = false,
        };

        pub fn base(_: *const ThemeTokens) ConditionalStyle {
            // base 的 gap 会被 variants 覆盖；opacity 无人覆盖应保留
            return .{ .base = .{ .gap = 1, .opacity = 0.9 } };
        }

        pub const variants = .{
            .size = struct {
                fn resolve(s: TestSize, _: *const ThemeTokens) ConditionalStyle {
                    // variants 的 height 会被 derived 覆盖；gap 覆盖 base
                    return switch (s) {
                        .sm => .{ .base = .{ .height = .{ .px = 1 }, .gap = 4 } },
                        .lg => .{ .base = .{ .height = .{ .px = 1 }, .gap = 8 } },
                    };
                }
            }.resolve,
        };

        // derived 拿完整 Variants，做跨维度组合（padding = f(size, icon_only)）
        pub fn derived(v: Variants, _: *const ThemeTokens) ConditionalStyle {
            const h: f32 = switch (v.size) {
                .sm => 28,
                .lg => 42,
            };
            return .{
                .base = .{
                    .height = .{ .px = h },
                    .padding = if (v.icon_only) types.Padding.all(h / 4) else types.Padding.symmetric(4, 12),
                    // derived 的 corner_radius 会被 compound 覆盖（lg+icon_only 时）
                    .corner_radius = 6,
                },
            };
        }

        pub const compounds = .{
            .{
                .matches = struct {
                    fn f(v: Variants) bool {
                        return v.size == .lg and v.icon_only;
                    }
                }.f,
                .style = struct {
                    fn f(_: *const ThemeTokens) ConditionalStyle {
                        return .{ .base = .{ .corner_radius = 999 } };
                    }
                }.f,
            },
        };
    });

    const tokens = &theme.dark;

    // derived 覆盖 variants 的 height；variants 覆盖 base 的 gap；base 的 opacity 保留
    const sm = DerivedRecipe.resolve(.{ .size = .sm }, tokens);
    try std.testing.expectEqual(@as(f32, 28), sm.base.height.?.px);
    try std.testing.expectEqual(@as(f32, 4), sm.base.gap.?);
    try std.testing.expectEqual(@as(f32, 0.9), sm.base.opacity.?);
    try std.testing.expectEqual(@as(f32, 12), sm.base.padding.?.right);
    try std.testing.expectEqual(@as(f32, 6), sm.base.corner_radius.?);

    // 跨维度: icon_only 改变 padding 形状（f(size, icon_only) 单维度 resolver 做不到）
    const sm_icon = DerivedRecipe.resolve(.{ .size = .sm, .icon_only = true }, tokens);
    try std.testing.expectEqual(@as(f32, 7), sm_icon.base.padding.?.right);

    // compounds 覆盖 derived 的 corner_radius
    const lg_icon = DerivedRecipe.resolve(.{ .size = .lg, .icon_only = true }, tokens);
    try std.testing.expectEqual(@as(f32, 999), lg_icon.base.corner_radius.?);
    try std.testing.expectEqual(@as(f32, 42), lg_icon.base.height.?.px);
}

test "ConditionalStyle: override" {
    const base_style = ConditionalStyle{
        .base = .{ .background = Color.hex(0xFF0000), .text_color = Color.hex(0x000000) },
        .hover = .{ .background = Color.hex(0x00FF00) },
    };

    // 外部 override 覆盖 base 的 background，保留 text_color
    const overridden = base_style.override(.{
        .style = .{ .background = Color.hex(0x0000FF) },
        .hover_style = .{ .opacity = 0.9 },
    });

    try std.testing.expectEqual(Color.hex(0x0000FF), overridden.base.background.?); // 被覆盖
    try std.testing.expectEqual(Color.hex(0x000000), overridden.base.text_color.?); // 保留
    try std.testing.expect(overridden.hover.?.background != null); // 原 hover bg 保留
    try std.testing.expect(overridden.hover.?.opacity != null); // 新增 hover opacity
}

test "ConditionalStyle: override preserves margin_spec overrides" {
    const base_style = ConditionalStyle{
        .base = .{ .margin_spec = (types.Margin{ .left = 6 }).withAutoLeft() },
        .hover = .{ .margin_spec = (types.Margin{ .right = 10 }).withAutoRight() },
    };

    const overridden = base_style.override(.{
        .style = .{ .margin_spec = types.Margin.autoHorizontal() },
        .hover_style = .{ .margin_spec = (types.Margin{ .left = 4, .right = 2 }).withAutoLeft() },
    });

    try std.testing.expect(overridden.base.margin_spec != null);
    try std.testing.expect(overridden.base.margin_spec.?.leftIsAuto());
    try std.testing.expect(overridden.base.margin_spec.?.rightIsAuto());
    try std.testing.expect(overridden.hover != null);
    try std.testing.expectEqual(@as(f32, 4), overridden.hover.?.margin_spec.?.left);
    try std.testing.expect(overridden.hover.?.margin_spec.?.leftIsAuto());
    try std.testing.expect(!overridden.hover.?.margin_spec.?.rightIsAuto());
}

test "slotRecipe: 多 slot resolve" {
    const TestVariant = enum { primary, ghost };
    const TestSlots = slotRecipe(struct {
        pub const Slots = struct {
            root: ConditionalStyle = .{},
            label: ConditionalStyle = .{},
        };

        pub const Variants = struct {
            variant: TestVariant = .primary,
        };

        pub fn base(_: *const ThemeTokens) Slots {
            return .{
                .root = .{ .base = .{ .cursor = .pointer } },
                .label = .{},
            };
        }

        pub const variants = .{
            .variant = struct {
                fn resolve(v: TestVariant, _: *const ThemeTokens) Slots {
                    return switch (v) {
                        .primary => .{
                            .root = .{ .base = .{ .background = Color.hex(0x000000) } },
                            .label = .{ .base = .{ .text_color = Color.hex(0xFFFFFF) } },
                        },
                        .ghost => .{
                            .root = .{},
                            .label = .{ .base = .{ .text_color = Color.hex(0x666666) } },
                        },
                    };
                }
            }.resolve,
        };
    });

    const tokens = &theme.dark;

    const primary = TestSlots.resolve(.{ .variant = .primary }, tokens);
    try std.testing.expectEqual(types.CursorShape.pointer, primary.root.base.cursor.?);
    try std.testing.expect(primary.root.base.background != null);
    try std.testing.expect(primary.label.base.text_color != null);

    const ghost = TestSlots.resolve(.{ .variant = .ghost }, tokens);
    try std.testing.expectEqual(types.CursorShape.pointer, ghost.root.base.cursor.?); // base 依然有
    try std.testing.expect(ghost.root.base.background == null); // ghost 没有 bg
    try std.testing.expect(ghost.label.base.text_color != null);
}

#!/usr/bin/env bash
# Historical deletion/architecture gate. Keep semantic invariants from the
# v0.4-v0.12 migrations, rather than freezing implementation file line counts.
# File size belongs in review; removed APIs, fields, and dependency boundaries
# are stable assertions that can safely block every PR.
#
# 用法：scripts/check_v04_deletions.sh [phase]
#   phase: P1|P2|P3|P4|P5|P6|P9C|all（默认 all = 全部检查）
#
# 退出码：0 通过；1 有 deprecated 残留；2 脚本错误

set -euo pipefail

PHASE="${1:-all}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

fail=0

check_file_absent() {
    local f="$1"
    local phase_tag="$2"
    if [[ -f "$f" ]]; then
        echo "  [FAIL $phase_tag] file still exists: $f"
        fail=1
    else
        echo "  [ok   $phase_tag] file deleted: $f"
    fi
}

check_symbol_absent() {
    local sym="$1"
    local phase_tag="$2"
    local search_dir="${3:-src/}"
    # 排除自身脚本 + 注释中的提及（v0.3 deprecated 注释提到符号名是合法的）
    local hits
    hits=$(grep -rn "\\b${sym}\\b" "$search_dir" 2>/dev/null \
        | grep -v "DEPRECATED\|废弃\|删除\|deleted\|deprecated\|//" \
        | grep -v ".md:" || true)
    if [[ -n "$hits" ]]; then
        echo "  [FAIL $phase_tag] symbol still referenced: $sym"
        echo "$hits" | head -5 | sed 's/^/      /'
        fail=1
    else
        echo "  [ok   $phase_tag] symbol absent: $sym"
    fi
}

# ── 2026-07-31 下压批次小结（历史记录；不再作为 CI 数值阈值）────────────
# 达成：command_encoder 4351→2585（超 ≤3000 目标）、popover 2308→1345
#       （超 ≤2190 目标）。手法都是析出零耦合纯函数簇 / 单测独立成文件，
#       纯搬运无逻辑改动，且都用"反转断言"验证过测试没被静默丢掉。
#
# 剩余三项**刻意不强推**，上限按实际值锁定：
#   hooks.zig 的 20 个 test 已移入 hooks_test.zig 并由 ui.zig 显式收集，
#     生产模块 1314 → 665；ratchet 同步收紧，防止测试/实现再次混回大文件。
#   display_list_lowering.zig 632 (目标 600，差 32)
#     无测试可析出，其余是密实实现。同上。2026-07-31：629→632，为
#     appendDisplayClipBridgeEnd/EffectBridgeEnd 的 OOM 修复补 3 行理由注释
#     （defer 里无法传播错误，不配对 scope 是静默损坏 → panic）。
#   node.zig 1459 (目标 1340，差 119)
#     试过把 34 个聚合子结构体析出到 node/parts.zig，但它们依赖
#     node.zig 顶部 104 行 import/别名区，跨文件复制这些别名带来的
#     耦合代价 > 119 行收益。已回滚。真要拆得先把别名区本身模块化。
#
# 结论：这三项不是"没做完"，是**当前形态下继续压会降低代码质量**。
# 要动它们应该等有独立的结构性理由（比如别名区模块化），而不是为了
# 让某个数字变小。
# ──────────────────────────────────────────────────────────────────────

if [[ "$PHASE" == "P1" || "$PHASE" == "all" ]]; then
    echo "=== v0.4-P1: layout main path / fitResizeAfterLayout ==="
    check_symbol_absent "fitResizeAfterLayout" "P1"
    # v0.5-P1 真 enforce：reactive Store.patch 死代码删除（plan 主文档要求）
    check_symbol_absent "Store\\.patch" "P1"
fi

if [[ "$PHASE" == "P2" || "$PHASE" == "all" ]]; then
    echo "=== v0.5-P2: render IR removal (Stage B 已完成 2026-05-07) ==="
    # Stage B 完工：RenderCommand IR 彻底死，encoder 直吃 DisplayItem。
    # render_command.zig 物理删（commit 3636323）。
    # display_list_replay.zig 物理删（2026-05-08）：rename → display_list_lowering.zig
    # 因为 RenderCommand IR 死后已无 "replay" 语义，只剩 local→world lowering 主路径。

    # render_command.zig 不允许重建
    check_file_absent "src/ui/core/render_command.zig" "P2"

    # RenderCommand IR enum 0 refs enforce — word-boundary 排除 RenderCommandEncoder
    # (Metal API / encoder struct name)
    rc_refs=$( { rg "\bRenderCommand\b" --type zig -c 2>/dev/null || true; } | awk -F: 'BEGIN{s=0} {s+=$2} END {print s+0}')
    rc_files=$( { rg "\bRenderCommand\b" --type zig -l 2>/dev/null || true; } | wc -l | tr -d ' ')
    if [[ "$rc_refs" -gt 0 ]]; then
        echo "  [FAIL P2] RenderCommand refs regressed: $rc_refs > 0 (IR 已删，不允许重建)"
        fail=1
    else
        echo "  [ok   P2] RenderCommand refs 0 (IR 彻底死)"
    fi
    if [[ "$rc_files" -gt 0 ]]; then
        echo "  [FAIL P2] RenderCommand consumer files regressed: $rc_files > 0"
        fail=1
    else
        echo "  [ok   P2] RenderCommand consumer files 0"
    fi
    # command_encoder.zig ratchet。
    # 2026-07-31 下压：4351 → 2585 行，**超额达成**历史 ≤3000 目标。
    # 手法是析出 4 个零 encoder 状态依赖的纯函数簇 + 单测独立成文件：
    #   paint_fingerprint.zig  damage bounds / 内容指纹 / 结构折叠
    #   local_sort.zig         local-sort 的几何 bounds
    #   path_polygon.zig       路径 → clip 多边形扁平化
    #   font_selector.zig      字体档位选择（与 encoder 零耦合）
    #   command_encoder_test.zig  16 个单测（679 行）
    # 全部是搬运 + 可见性调整，无逻辑改动。上限锁 2600 留少量余量。
    # 演进史：
    # 2026-05-08 round 1: 删 endBlurLayer/restoreFromOffscreen/scissorRectEqual +
    # 死字段，4093 → 3885 (-208)。
    # 2026-05-08 round 2: 删 UIColor + TextColorSpan + GlassLayerParams，3885 → 3846。
    # 2026-05-08 B-6 起步: 加 dispatchPaintTableRect。3846 → 3891。
    # 2026-05-08 backdrop_blur 析出 (602 行): 3891 → 3284 (-607)。
    # 2026-05-08 offscreen_texture 析出 (132 行): 3284 → 3158 (-126)。
    # 2026-05-08 opacity_layer 析出 (218 行): 3158 → 2938 (-220)。
    # 累计 -1155 vs 4093 起点。§5 ≤3000 达成。
    echo "  [info P2] command_encoder.zig $(wc -l < src/render/command_encoder.zig | tr -d ' ') lines (review signal only)"

    # compositor_plan: Stage A 已删
    if [[ -e src/ui/core/compositor_plan.zig ]]; then
        echo "  [FAIL P2] compositor_plan.zig regressed: file recreated after Stage A delete"
        fail=1
    else
        echo "  [ok   P2] compositor_plan.zig deleted (Stage A complete)"
    fi
    check_symbol_absent "CompositorPlan" "P2"

    # display_list_replay.zig 物理删 (2026-05-08): rename → display_list_lowering.zig。
    # v0.5 §5 exit criterion #2 ✅ — 文件路径不存在。替代实现的文件长度是
    # review signal，不是 CI contract。
    # 2026-05-08: bracket_debug 子系统拆出，606 → 560。
    # 2026-05-10: 加 appendLoweredBoth 双写 helper (paint_table 镜像 buffer)，
    # 561 → 592。该 helper 替代 cx.lowerForEncoderPaintTable 内部的二次翻译循环
    # (encoder 主路径已切，每帧省 frame_arena alloc + 17 lowerDisplayItem)。
    if [[ -e src/ui/core/render_engine/display_list_replay.zig ]]; then
        echo "  [FAIL P2] display_list_replay.zig regressed: file recreated after rename to display_list_lowering.zig"
        fail=1
    else
        echo "  [ok   P2] display_list_replay.zig physically deleted (renamed to display_list_lowering.zig)"
    fi
    echo "  [info P2] display_list_lowering.zig $(wc -l < src/ui/core/render_engine/display_list_lowering.zig | tr -d ' ') lines (review signal only)"
fi

if [[ "$PHASE" == "P3" || "$PHASE" == "all" ]]; then
    echo "=== v0.4-P3: Node god-object split (DEFERRED → v0.5) ==="
    # v0.4-P3 调查（2026-04）：108 Node 字段，~50 字段引用 ≤5（多在 node.zig 内部）
    # 但每字段拆解需对应 World 4 表 schema 设计 + 数百 callsite 改。
    # 单 phase 不可达——推迟到 v0.5 配合 layoutNode 主签名 + render_engine 切换一起做。
    # 当前 v0.5 渐进 ratchet：≤102 不允许超过；真拆解时一次性下降。
    # 精确计数：只数 Node struct 自己的字段（不算 sub-struct/helper struct 内部字段）
    # v0.10-§L: visuals 字段已删（content §a + layout_output §L 全 SoA 化到
    # World）。Node 顶层字段 10 → 9，ratchet 收紧锁定，防回流。
    #
    # 2026-09-22 重基线 11 → 18。这个 ratchet 的意图是「防止 Node 这个
    # god object 回流」，而实际增长的 7 个字段全部有明确来由，逐个核过：
    #   world_id / world_ref      P0-3 多窗口真根因修复（868f44d / a0ddbee）
    #                             —— ElementId 无 World 标识会跨窗口假匹配
    #   alive_sentinel            Node 生存哨兵（d22e57c），让 double free
    #                             当场 panic 而不是静默 UAF
    #   deferred_disposal /       生命周期：延迟释放 + 释放中标记，修的是
    #   pending_free_cx /         「在自己的回调里 free 自己」这类重入
    #   freeing
    #   cursor_query /            cursor region 查询回调 + 其 context
    #   cursor_query_context
    #   on_capture_lost           pointer capture 丢失通知
    # 没有一个是「顺手挂在 Node 上」的便利字段，都是 SoA 化搬不走的
    # per-node 身份/生命周期/回调。此前长期红着 —— 一个只会红不会被处理的
    # ratchet 等于没有 ratchet，还会连累 CONTRIBUTING 里让新贡献者跑的门禁。
    #
    # 仍然「禁再增长」：新字段优先考虑 SoA 到 World（见 node.zig 头部的
    # 字段去向约定），确实必须挂 Node 时，在这里补一行来由再抬上限。
    fc=$(awk '/^pub const Node = struct/,/^};/' src/ui/core/node.zig | grep -E "^    [a-z_]+: " | wc -l | tr -d ' ')
    if [[ "$fc" -gt 18 ]]; then
        echo "  [FAIL P3] Node fields grew: $fc > 18 (2026-09-22 重基线，禁再增长)"
        fail=1
    else
        echo "  [ok   P3] Node has $fc fields ≤ 18 (ratchet 上限)"
    fi

    # v0.5-P3 N-2 ratchet (2026-05-03): frame_state.rect 字段语义降级为
    # "layout pass 内部 scratch + fallback storage"，对外消费者必须走
    # rectFromWorldOrFallback。当前 94 处引用全在合法位置 (layout_engine 73 +
    # node.zig fallback impl 5 + core.zig sync/integrity 7 + render_context
    # fallback 3 + tests perturb 4 + node_animator anytype 2)。
    # 真删字段需要 layout_engine 改成走 LayoutTable，是 multi-session epic。
    # ratchet: 94 不允许增长；真减少时降低。
    # v0.5-P3 N-2 (2026-05-03): frame_state.rect 字段真删 — Node 没此字段了。
    # 剩余引用都在 注释 (8) + node_animator.zig MockNode duck typing (3) = 11。
    # MockNode 自己定义 frame_state.rect 字段是测试 mock fixture 的内部细节。
    # 2026-05-10: test_harness/tree_serializer.zig 文档注释 +1 → 12。
    if awk '/^pub const NodeFrameState = struct/,/^};/' src/ui/core/node.zig \
        | rg -q '^\s*rect\s*:'; then
        echo "  [FAIL P3] NodeFrameState.rect field regressed"
        fail=1
    else
        echo "  [ok   P3] NodeFrameState.rect field remains deleted"
    fi

    # v0.5-P3 Node god-object 行数 ratchet (2026-05-04)
    # 真拆 N-3+ multi-session epic；中间 ratchet 防 dead method 反弹。
    # 2026-05-13 (v0.9-§a stage 1): +50 行加 NodeContent SoA 写钩子 + accessor
    # (setText/setImage/setIcon + get*); 1945 → 2000。
    # 2026-05-13 (v0.9-§a stage 2 末): +10 行 setText 智能 fixup 路径
    # (区分 inline_buf vs 外部 slice); 2000 → 2020。
    # 2026-05-13 (v0.9-§a stage 3): +60 行 read hooks + standalone fallback
    # (NodeContent in-place 字段已删，content 全部 World.content / fallback); 2020 → 2090。
    # 2026-05-13 (v0.9-§b stage 2): +25 行 PaintState SoA write hooks + getBackground/getOpacity
    # accessor; 2090 → 2120。
    # 字段虽删，但配套基建增加 (read callback set + 三组 setX/getX 走 SoA 形式)；
    # 行数下降需要把这些 hook 拆到独立 file (例如 content_accessor.zig)，
    # 是 v0.9-§a stage 4 候选工作（不在本 stage 范围）。
    # 2026-05-16 (v0.9-§b stage 3a): +14 行 setBackgroundRaw/setOpacityRaw 无副作用
    # 写入口 (供内部/animation/builder caller，避开 setter 的 transition+dirty 副作用);
    # 2120 → 2130。
    # 2026-05-16 (v0.9-§b stage 4): +64 行 paint state SoA 反转基建 —— read 路由
    # callback (g_paint_bg_read/opacity_read) + standalone fallback hashmap
    # (g_standalone_paint_bg/opacity, 对偶 §a content fallback) + getBackground/
    # getOpacity/setXRaw 全改走 World/standalone (不再触 in-place 字段)。
    # Style.background/opacity 字段已物理删 (types.zig)，source of truth 反转到
    # World.paint_state。node.zig 行增是 accessor 基建集中于此；Style struct 缩小。
    # 2130 → 2200。后续 god-object split (accessor 拆 paint_accessor.zig) 候选。
    # 2026-05-16 (v0.9 god-object split): §a content + §b paint 的 callback/
    # standalone-fallback/路由 全抽到 paint_content_accessor.zig；node.zig 上
    # 6 个 content + 4 个 paint 方法降为 thin one-liner delegate。
    # 2194 → 2031 (-163)。ratchet 收紧 2200 → 2040 锁定净降，防回流。
    # 2026-05-16 (v0.10-§L stage 1): NodeLayoutOutput 等 5 struct 移到
    # node_layout_output.zig (re-export 保留) + 加 LayoutOutput SoA mirror
    # callback/registrar + getLayoutOutput/setLayoutOutput/syncLayoutOutputMirror
    # accessor。struct 移走省的行被 accessor/callback 抵消，净 2031 → 2040。
    # ratchet 放 2050 留 stage 1 余量；stage 3 删 visuals 字段后净大降，届时收紧。
    # 2026-05-17 (v0.12-§N1 Stage 1): dirty 传播 15 方法抽到 node_dirty.zig
    # （Node-typed free function + node.zig thin delegate）。2045 → 1811
    # (-234)。ratchet 收紧 2050 → 1820。
    # 2026-05-17 (v0.12-§N2 Stage 2): 渲染缓存 6 方法 + TextHashSnapshot
    # 抽到 node_render_cache.zig（buildCachedRenderSlice 转模块级 free
    # fn）。1811 → 1657 (-154)。ratchet 收紧 1820 → 1670。
    # 2026-05-17 (v0.12-§N3 Stage 3): 交互/Hit 17 方法（非连续，逐方法
    # 迁移）+ invalidateCustomClipGeometryCache 抽到 node_interaction.zig。
    # 1657 → 1571 (-86)。ratchet 收紧 1670 → 1580。
    # 2026-05-17 (v0.12-§N4 Stage 4): 生命周期(create/destroy/release*/
    # fire*/clearNodeScopes) + geometry/rect(rectFromWorldOrFallback/
    # setLayout*/globalRect) + rect callback 单元 + standalone fallback
    # rect storage（§L 陷阱核心，整体搬防半截）抽到 node_lifecycle.zig。
    # 1571 → 1384 (-187)。ratchet 收紧 1580 → 1395。
    # 2026-05-17 (v0.12-§N5 Stage 5，末刀): 树结构 7 方法(append/remove*/
    # replaceChildOrder/isDescendantOf) + structure callback 单元抽到
    # node_tree.zig。1384 → 1333 (-51)。v0.12 epic 收官：node.zig
    # 2045 → 1333 (-712, -35%)，5 子模块(dirty/render_cache/interaction/
    # lifecycle/tree)。ratchet 收紧 1395 → 1340 终值锁定。
    echo "  [info P3] node.zig $(wc -l < src/ui/core/node.zig | tr -d ' ') lines (review signal only)"
fi

if [[ "$PHASE" == "P4" || "$PHASE" == "all" ]]; then
    echo "=== v0.4-P4: Builder API removal (DEFERRED → v0.5) ==="
    # v0.4-P4 调查：ScrollAreaBuilder 24 处测试 + 5 处生产 = 29 callsite 改动
    # GridBuilder + CardGridBuilder 类似规模。
    # 真删除工作量超单 phase 预算；推迟到 v0.5 配合公共 API 锁定一起做。
    # 当前 ratchet：ref counts 锁定，真删除时归零。
    # ScrollAreaBuilder + CardGridBuilder + GridBuilder 已真删除 —— enforce 不允许回归
    check_symbol_absent "ScrollAreaBuilder" "P4"
    check_symbol_absent "CardGridBuilder" "P4"
    check_symbol_absent "GridBuilder" "P4"

    # The split is structural: tests stay in their own module and are explicitly
    # collected. Adding more coverage must not break the gate.
    hooks_tests=$(rg -c '^test "' src/ui/hooks_test.zig 2>/dev/null || true)
    if [[ -z "$hooks_tests" || "$hooks_tests" -lt 20 ]] || ! rg -q '@import\("hooks_test\.zig"\)' src/ui/ui.zig; then
        echo "  [FAIL P4] hooks test split lost coverage: expected at least 20 tests and explicit ui.zig import"
        fail=1
    else
        echo "  [ok   P4] hooks test split preserves $hooks_tests explicitly collected tests"
    fi
fi

if [[ "$PHASE" == "P5" || "$PHASE" == "all" ]]; then
    echo "=== v0.4-P5: text legacy removal (✅ v0.5 §5 完成) ==="
    # measureTextWidth pub fn 物理删除 (Phase E, 2026-05-08)：text_layout.zig
    # 内部 fallback 改 measureProportional (private fn) 提供给
    # measureTextWidthByFontKind / measureMonospaceTextWidth 用；外部 caller
    # (input/render/layout) 切到 cx.shapeText (GlyphRun pipeline + ShapingCache)。
    # 2026-08-05：判据从"名字 + 路径白名单"改成"按 API 形态精确匹配"。
    #
    # 旧判据数的是裸名 measureTextWidth 再减去一串硬编码路径。它有个结构性
    # 缺陷：**同名但无关**的方法只要出现在白名单外的新文件里就误报成
    # "删掉的 legacy API 复活了"。已经踩过两次：
    #   1. FontSelector.measureTextWidth 从 command_encoder.zig 析出到
    #      command_encoder/font_selector.zig（纯搬运 → 假红，靠补路径压下）。
    #   2. Cx.measureTextWidth（commit 635ce61 多窗口运行时新增）。它不是
    #      legacy API 的残留，恰恰相反 —— 它内部就走 cx.shapeText GlyphRun
    #      管线，是本 phase 要求的那个替代品的封装；引入它的目的是让多个 Cx
    #      共存时保住各自窗口的 font context。把它算成"违规"是判据本身错了。
    # 再往白名单里加第三条路径只会重演同一个 bug，所以改成直接锚定被删的
    # 那个 API 的形态。
    #
    # 被删的是 text_layout.zig 里的自由函数 pub fn measureTextWidth（Phase E,
    # 2026-05-08）。它的替代品是 measureTextWidthByFontKind（对外唯一入口，
    # 内部收敛到 private measureProportional）+ 外部 caller 走 cx.shapeText。
    # 因此真正要 enforce 的是两条，且都比旧判据更严（旧判据完全不看形态，
    # 白名单里的文件里就算真的重建一个自由函数也照样放过）：
    #   (a) 任何文件都不许再声明自由函数形式的 measureTextWidth
    #       （method 形式 `pub fn measureTextWidth(self: ...)` 是合法的，
    #        自由函数形式 = 首参不是 self，才是被删的那个）。
    #   (b) 任何地方都不许以模块限定/自由函数方式调用它
    #       （text_layout.measureTextWidth(...) / 裸 measureTextWidth(...)）。
    # 名字里带后缀的 measureTextWidthByFontKind / ...WithSpans / ...Callback /
    # measureMonospaceTextWidth 靠 \b + 后接 `(` 或 `,` 的形态自然排除。

    # (a) 自由函数声明：pub fn measureTextWidth( 后面首参不是 self
    mtw_free_decl=$( (rg -n "^\s*(pub )?fn measureTextWidth\s*\(" --type zig 2>/dev/null || true) \
        | (grep -v "fn measureTextWidth\s*(\s*self\s*:" || true) \
        | wc -l | tr -d ' ')
    if [[ "$mtw_free_decl" != "0" ]]; then
        echo "  [FAIL P5] measureTextWidth 自由函数声明复活: $mtw_free_decl 处 (Phase E 已物理删，替代品 measureTextWidthByFontKind)"
        (rg -n "^\s*(pub )?fn measureTextWidth\s*\(" --type zig 2>/dev/null || true) \
            | (grep -v "fn measureTextWidth\s*(\s*self\s*:" || true) | head -5 | sed 's/^/      /'
        fail=1
    else
        echo "  [ok   P5] measureTextWidth 自由函数声明 0 处 (真删完工)"
    fi

    # (b) 自由函数/模块限定调用点。排除 `.measureTextWidth(` 这种方法调用
    # （前面有 `.` 且接收者不是 text_layout 模块别名）。
    mtw_free_call=$( (rg -n "(^|[^.\w])measureTextWidth\s*\(|\btext_layout\.measureTextWidth\s*\(" --type zig 2>/dev/null || true) \
        | (grep -v "fn measureTextWidth" || true) \
        | wc -l | tr -d ' ')
    if [[ "$mtw_free_call" != "0" ]]; then
        echo "  [FAIL P5] measureTextWidth 自由函数调用点复活: $mtw_free_call 处"
        (rg -n "(^|[^.\w])measureTextWidth\s*\(|\btext_layout\.measureTextWidth\s*\(" --type zig 2>/dev/null || true) \
            | (grep -v "fn measureTextWidth" || true) | head -5 | sed 's/^/      /'
        fail=1
    else
        echo "  [ok   P5] measureTextWidth 自由函数调用点 0 处 (caller 全走 measureTextWidthByFontKind / cx.shapeText)"
    fi
    check_symbol_absent "isBreakable" "P5"
fi

if [[ "$PHASE" == "P6" || "$PHASE" == "all" ]]; then
    echo "=== v0.4-P6: a11y + select 旧版 removal ==="
    # 两个文件都已真删除（2026-04-26）：
    # - src/ui/components/select.zig → select_headless（mountSelectHeadless 替代）
    # - src/ui/accessibility.zig → AccessibilityBridge 内联到 src/ui/focus.zig
    check_file_absent "src/ui/accessibility.zig" "P6"
    check_file_absent "src/ui/components/select.zig" "P6"
fi

if [[ "$PHASE" == "P9C" || "$PHASE" == "all" ]]; then
    echo "=== v0.9-§c: LoweringBuffers.main 物理删 + display_list 降私有 ==="
    # c3 (2026-05-13): LoweringBuffers.main 字段已 rename 为 _dead_main 占位；
    # 已无活跃 caller append / read。下个 epic 物理删 RenderContext.lowering_buffer
    # 参数后此字段才能真删。
    if grep -q '^    main: std\.ArrayList(display_list_mod\.DisplayItem)' src/ui/core.zig; then
        echo "  [FAIL P9C] LoweringBuffers.main 仍存在 (应 rename 为 _dead_main 或删除)"
        fail=1
    else
        echo "  [ok   P9C] LoweringBuffers.main 字段已删除"
    fi
    # c4: display_list.zig 仅 core/ 内部使用 (含 src/ui/core.zig 本身)
    out_of_core=$( { grep -rln '@import.*display_list' src/ --include='*.zig' || true; } | { grep -vE 'src/ui/core/|src/ui/core\.zig$' || true; } | wc -l | tr -d ' ')
    if [[ "$out_of_core" -gt 0 ]]; then
        echo "  [FAIL P9C] display_list.zig 仍被 core/ 外模块 import ($out_of_core 个文件)"
        fail=1
    else
        echo "  [ok   P9C] display_list.zig 仅 core/ 内部使用 (out_of_core=0)"
    fi
fi

if [[ $fail -ne 0 ]]; then
    echo ""
    echo "architecture invariant gate FAILED ($PHASE)"
    exit 1
fi

echo ""
echo "architecture invariant gate passed ($PHASE)"

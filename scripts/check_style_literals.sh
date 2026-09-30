#!/usr/bin/env bash
# 样式字面量 ratchet —— examples/ 里**裸的**颜色/字号字面量只降不升。
# 约定见 docs/STYLING.md：view 代码消费 token（styles.zig 具名样式函数），
# 不写裸 `Color.hex(...)` / `.font_size = <数字>` 字面量。
#
# 有意的 off-token 值走 `ui.arb.px(...)` / `ui.arb.hex(...)` 逃生舱
# （对标 Panda arbitrary values）——不匹配下面的正则，天然放行。
#
# storybook 除外：它是组件展示画廊，包含刻意的样式演示。
#
# 基线降到 0 之前只 ratchet；降了请同步收紧 BASELINE。
#
# 退出码：0 通过；1 字面量数量超过基线；2 脚本错误

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# 2026-08-09 基线：text_input(2) + multi_window(2) + virtual_list_perf(3)
BASELINE=7

count=$(grep -rEn 'Color\.hex\(|\.font_size = [0-9]' examples --include='*.zig' \
    | grep -v '^examples/storybook/' | wc -l | tr -d ' ')

if (( count > BASELINE )); then
    echo "[FAIL] examples/ 样式字面量 ${count} 处 > 基线 ${BASELINE}"
    echo "       新增的字面量请改走 token（styles.zig 具名样式函数，见 docs/STYLING.md）："
    grep -rEn 'Color\.hex\(|\.font_size = [0-9]' examples --include='*.zig' | grep -v '^examples/storybook/'
    exit 1
fi

echo "[ok] examples/ 样式字面量 ${count} 处 (基线 ${BASELINE})"
if (( count < BASELINE )); then
    echo "     基线可收紧：BASELINE=${count}（scripts/check_style_literals.sh）"
fi

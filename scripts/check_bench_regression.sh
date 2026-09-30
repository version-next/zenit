#!/usr/bin/env bash
# 比较两份 bench JSON，min_ns 退步超阈值时 exit 1
#
# 用法：scripts/check_bench_regression.sh <baseline.json> <current.json> [threshold_pct]
# threshold_pct 默认 15（current.min > baseline.min * 1.15 视为退步）
#
# ── 为什么阈值不是唯一的判据（2026-07-31 实测）─────────────────────────
# 同一份未改动的代码连跑 11 轮，62 个 bench 里 **18 个抖动 >15%**，
# 最大的 a11y_tree_children_50 抖到 87%（2613→4875ns）。抖动大的不只是
# 纳秒级：element_create_append_100 在 12.7µs 量级也有 25%。
#
# 也就是说单看一次采样、卡 15%，必然周期性假红 —— 而假红的代价是所有人
# 学会无视这个门禁，比没有门禁更糟。
#
# 两道防线：
#   1. NOISE_FLOOR_NS  —— 低于地板的只报告不阻塞（计时器分辨率就盖过差异）。
#   2. BENCH_RERUN_CMD —— 超标的 bench **复测确认**：设了该环境变量时，脚本
#      重跑一轮 bench 再比一次，仍超标才判红；回落即视为离群（[flaky]）。
#      只复测 suspect，所以额外成本是一轮 bench，不是一轮 × N。
# 未设 BENCH_RERUN_CMD 时退化为单次判定（向后兼容），并打印提示。
# ──────────────────────────────────────────────────────────────────────

set -euo pipefail

BASELINE="${1:?baseline.json required}"
CURRENT="${2:?current.json required}"
THRESHOLD_PCT="${3:-15}"
# 新旧 min_ns 都低于此值的 benchmark 只报告、不阻塞（见下方 [noise] 分支）。
NOISE_FLOOR_NS="${NOISE_FLOOR_NS:-200}"
# 超标后的复测命令：给定则重跑并二次确认，输出写到 $BENCH_RERUN_OUT。
# 例：BENCH_RERUN_CMD='zig build bench -- json=%OUT%'
BENCH_RERUN_CMD="${BENCH_RERUN_CMD:-}"

if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq is required" >&2
    exit 2
fi

# ── fail closed：先显式校验两份输入 ────────────────────────────────────
# 历史 bug：唯一的输入校验发生在 `done < <(jq ...)` 这个 process substitution 里，
# 它的失败**不会**传播到主 shell（set -e 对 <(...) 无效），while 读到空输入即
# 正常结束，脚本照常打印 "All bench checks passed." 并 exit 0。
# 实测三种情况全部静默放行：current.json 不存在 / 内容损坏 / results 为空数组。
# 最后一种最危险 —— bench 一个都没跑，jq 连错误都不报，门禁完全失效。
validate_bench_json() {
    local role="$1" path="$2"
    if [[ ! -f "$path" ]]; then
        echo "ERROR: $role JSON not found: $path" >&2
        exit 2
    fi
    if ! jq -e . "$path" >/dev/null 2>&1; then
        echo "ERROR: $role JSON is not valid JSON: $path" >&2
        exit 2
    fi
    if ! jq -e '.results | type == "array"' "$path" >/dev/null 2>&1; then
        echo "ERROR: $role JSON missing '.results' array: $path" >&2
        exit 2
    fi
    local n
    n=$(jq -r '.results | length' "$path")
    if [[ "$n" -eq 0 ]]; then
        echo "ERROR: $role JSON has zero benchmark results: $path" >&2
        echo "       (bench 可能构建失败或未产出 —— 拒绝以空结果放行门禁)" >&2
        exit 2
    fi
    echo "  [validated] $role: $n benchmarks ($path)"
}

validate_bench_json "baseline" "$BASELINE"
validate_bench_json "current"  "$CURRENT"

fail=0
suspects=()
while read -r name; do
    # 用 min_ns 比对 —— 抗系统 noise 比 median 强；CI 跑多次取 min
    base=$(jq -r --arg n "$name" '.results[] | select(.name==$n) | .min_ns' "$BASELINE")
    curr=$(jq -r --arg n "$name" '.results[] | select(.name==$n) | .min_ns' "$CURRENT")
    if [[ -z "$base" || "$base" == "null" ]]; then
        echo "  [skip] $name (no baseline)"
        continue
    fi
    # baseline = 0 通常 ReleaseFast 把 bench body 整个 dead-code-eliminated
    if awk -v b="$base" 'BEGIN{exit !(b == 0)}'; then
        echo "  [skip] $name (baseline=0; bench likely DCE'd)"
        continue
    fi
    # 噪声地板：新旧 min_ns 都低于 NOISE_FLOOR_NS 时只报告不阻塞。
    #
    # 依据（2026-07-31 实测）：在**完全未改动**的代码上连跑三轮，
    # frame_dashboard_drawcall_count 偏离基线 46%、element_table_unlink_relink
    # 37%、encode_stream_100_rect_homogeneous 22% —— 全部是 <200ns 的
    # microbenchmark，计时器分辨率与调度抖动就足以盖过真实差异。
    # 对这些用 15% 阈值把关只会让 CI 永久红，进而训练所有人无视它。
    #
    # 超过地板的 benchmark（真正跑得久、信号稳）仍然严格把关。
    # 只看 baseline 会漏掉量级跃迁（例如 60ns -> 10us）：current 已越过地板
    # 时信号足够大，必须进入正常回归判定。
    if awk -v b="$base" -v c="$curr" -v f="$NOISE_FLOOR_NS" 'BEGIN{exit !(b < f && c < f)}'; then
        ratio_n=$(awk -v c="$curr" -v b="$base" 'BEGIN{printf "%.1f", (c/b)*100}')
        echo "  [noise]   $name: ${base}ns → ${curr}ns (${ratio_n}%; <${NOISE_FLOOR_NS}ns 不阻塞)"
        continue
    fi

    # 计算 ratio = curr / base * 100
    ratio=$(awk -v c="$curr" -v b="$base" 'BEGIN{printf "%.1f", (c/b)*100}')
    pct_over=$(awk -v c="$curr" -v b="$base" -v t="$THRESHOLD_PCT" 'BEGIN{printf "%.1f", ((c/b)-1)*100}')

    if awk -v c="$curr" -v b="$base" -v t="$THRESHOLD_PCT" 'BEGIN{exit !(c > b*(1+t/100))}'; then
        echo "  [over]    $name: ${base}ns → ${curr}ns (+${pct_over}%, threshold ${THRESHOLD_PCT}%) — 待复测确认"
        suspects+=("$name")
    else
        echo "  [ok]      $name: ${base}ns → ${curr}ns (${ratio}%)"
    fi
done < <(jq -r '.results[].name' "$CURRENT")

# ── 复测确认 ────────────────────────────────────────────────────────────
# 只有超标的 bench 才需要二次确认，所以复测一轮即可覆盖全部 suspect。
if [[ ${#suspects[@]} -eq 0 ]]; then
    echo "All bench checks passed."
    exit 0
fi

if [[ -z "$BENCH_RERUN_CMD" ]]; then
    echo ""
    echo "  ⚠ 未设置 BENCH_RERUN_CMD，无法复测确认，按单次结果判定。"
    echo "    实测该套 bench 有 18/62 抖动 >15%，单次超标很可能是离群。"
    echo "    建议：BENCH_RERUN_CMD='zig build bench -- json=%OUT%' 重跑本脚本。"
    for s in "${suspects[@]}"; do
        echo "  [REGRESS] $s"
    done
    echo "Bench regression detected." >&2
    exit 1
fi

echo ""
echo "── 复测确认 ${#suspects[@]} 个超标 bench ──"
rerun_out=$(mktemp -t bench_rerun.XXXXXX.json)
trap 'rm -f "$rerun_out"' EXIT
rerun_cmd="${BENCH_RERUN_CMD//%OUT%/$rerun_out}"
if ! eval "$rerun_cmd" >/dev/null 2>&1; then
    echo "  ✗ 复测命令执行失败：$rerun_cmd" >&2
    echo "Bench regression detected (复测不可用，按单次结果判定)." >&2
    exit 1
fi
validate_bench_json "rerun" "$rerun_out"

for name in "${suspects[@]}"; do
    base=$(jq -r --arg n "$name" '.results[] | select(.name==$n) | .min_ns' "$BASELINE")
    again=$(jq -r --arg n "$name" '.results[] | select(.name==$n) | .min_ns' "$rerun_out")
    if [[ -z "$again" || "$again" == "null" ]]; then
        echo "  [REGRESS] $name: 复测数据缺失，保守判红"
        fail=1
        continue
    fi
    pct2=$(awk -v c="$again" -v b="$base" 'BEGIN{printf "%.1f", ((c/b)-1)*100}')
    if awk -v c="$again" -v b="$base" -v t="$THRESHOLD_PCT" 'BEGIN{exit !(c > b*(1+t/100))}'; then
        echo "  [REGRESS] $name: 复测仍超标 ${base}ns → ${again}ns (+${pct2}%) —— 判定为真回退"
        fail=1
    else
        echo "  [flaky]   $name: 复测回到 ${again}ns (+${pct2}%) —— 首次为离群，不阻塞"
    fi
done

if [[ $fail -ne 0 ]]; then
    echo "Bench regression detected." >&2
    exit 1
fi
echo "All bench checks passed (含复测确认)."

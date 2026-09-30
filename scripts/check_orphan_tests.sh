#!/usr/bin/env bash
# 扫描「孤儿测试」：文件里有 test 块，但那个文件从未被编译进任何 test target。
#
# ── 为什么需要它 ──────────────────────────────────────────────────────
# 孤儿测试是最危险的一类假绿：代码里明明写着断言，CI 也显示全绿，但那些
# 断言从来没有执行过。仓库里已经踩过两次：
#   - src/test_harness/http_server.zig（模块只被 app 引用，从无 addTest）
#   - src/test_harness/command_executor.zig（挂上去会链接失败，于是没挂）
#   - src/ui/core/layout/adapter.zig（零 pub、零引用，文件本身就是死代码）
#
# ── 判据 ─────────────────────────────────────────────────────────────
# 静态推断谁被收集不可靠（`const x = @import(...)` 和 `_ = @import(...)`
# 在测试收集上语义不同，且模块图还要看 build.zig）。这里用**实测**：
# 往文件的第一个 test 块里植入一个**运行期**失败断言，跑 `zig build test`。
#   - 测试失败 ⇒ 该 test 确实被收集并执行 ⇒ 正常
#   - 全绿     ⇒ 该 test 从未被执行 ⇒ 孤儿
#
# ⚠ 判据跑的是 `${PROBE_CMD}`（默认 `zig build test`）。有些测试**有意**挂在
#   别的 step 上，不属于孤儿，必须排除，否则全是误报：
#     - src/render/metal_integration_tests.zig → `test-metal`（要真 Metal 设备）
#     - src/platform/unsupported/**           → 交叉编译目标，macOS 上不编译
#   见下面的 EXCLUDE 列表。新增这类文件时同步加进去，并写明它挂在哪个 step。
#
# ⚠ 探针必须是运行期的，**不能**用 @compileError：它在文件被 @import 时
#   就触发，而「被 import」≠「test 被收集」。初版用 @compileError，漏报了
#   src/render/svg.zig —— 它被 render_test_module import（编译错误会暴露），
#   但没有任何 addTest 以 svg 模块为 root，10 个 test 一个都没跑过。
#
# 代价：每个文件一次增量构建。全量扫 240+ 文件很慢，所以默认只扫传入的
# 文件；不传参数时扫描全部（用于定期体检，不适合每次 CI 跑）。
#
# 用法：
#   bash scripts/check_orphan_tests.sh                 # 全量（慢）
#   bash scripts/check_orphan_tests.sh src/a.zig ...   # 指定文件
set -uo pipefail
cd "$(dirname "$0")/.."

# 开跑前先清理上一次可能遗留的探针。trap 挡不住 SIGKILL，也挡不住父 shell
# 被杀（实测 pkill 整棵进程树时 trap 根本来不及跑），所以真正可靠的防护是
# **每次开跑时自愈**，而不是只依赖退出时清理。
STALE="$(grep -rl 'return error.OrphanProbe;' src/ 2>/dev/null || true)"
if [[ -n "$STALE" ]]; then
    echo "发现上次遗留的探针，正在还原：" >&2
    echo "$STALE" | sed 's/^/  /' >&2
    # 探针总是脚本自己插入的单独一行，直接删行即可（不动其它未提交改动）
    echo "$STALE" | while read -r f; do
        [[ -n "$f" ]] && sed -i '' '/if (true) return error\.OrphanProbe;/d' "$f"
    done
fi

if [[ -n "$(git status --porcelain)" ]]; then
    echo "ERROR: 工作树不干净。本脚本会临时改源文件，必须在干净树上跑。" >&2
    exit 2
fi

# 有意挂在其它 build step 上的测试文件（不是孤儿）。
# 每条都要写明它实际挂在哪里，否则无法判断是豁免还是漏网。
EXCLUDE_RE='^(src/render/metal_integration_tests\.zig|src/platform/unsupported/)'
#            ^ test-metal（需真 Metal 设备）  ^ 交叉编译目标，macOS 上不编译

PROBE_CMD="${PROBE_CMD:-zig build test}"

if [[ $# -gt 0 ]]; then
    FILES=("$@")
else
    mapfile -t FILES < <(git ls-files 'src/**/*.zig' | grep -v generated | xargs grep -l '^test ' 2>/dev/null)
fi

TMP="$(mktemp -d)"

# 被中断时（Ctrl-C / kill）必须把最后一个探针还原，否则源文件里会留下
# `if (true) return error.OrphanProbe;`。2026-09-22 就因此把一行探针
# 混进了一个无关 commit（当时用了 `git add -A`，而扫描正在后台改源文件）。
CURRENT_FILE=""
restore_and_exit() {
    if [[ -n "$CURRENT_FILE" && -f "$TMP/bak" ]]; then
        cp "$TMP/bak" "$CURRENT_FILE"
        echo "已还原被中断时的探针: $CURRENT_FILE" >&2
    fi
    rm -rf "$TMP"
}
trap restore_and_exit EXIT INT TERM

# ⚠ 本脚本运行期间源文件处于「被植入探针」的中间态。不要在它跑着的时候
#   `git add -A` / `git commit -a`，否则会把探针提交进去。

orphans=()
checked=0
for f in "${FILES[@]}"; do
    grep -q '^test ' "$f" 2>/dev/null || continue
    if [[ "$f" =~ $EXCLUDE_RE ]]; then
        echo "skip (挂在其它 step): $f"
        continue
    fi
    cp "$f" "$TMP/bak"
    CURRENT_FILE="$f"
    python3 - "$f" <<'PY' || { cp "$TMP/bak" "$f"; continue; }
import sys, re, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
m = re.search(r'^test .*\{$', s, re.M)
if not m: sys.exit(1)
# 运行期探针，不是 @compileError —— 见文件头「判据」一节
p.write_text(s[:m.end()] + '\n    if (true) return error.OrphanProbe;' + s[m.end():])
PY
    checked=$((checked + 1))
    if $PROBE_CMD --summary none >/dev/null 2>&1; then
        orphans+=("$f")
        echo "ORPHAN: $f"
    fi
    cp "$TMP/bak" "$f"
    CURRENT_FILE=""
done

echo
echo "已检查 $checked 个含测试的文件，孤儿 ${#orphans[@]} 个。"
if [[ ${#orphans[@]} -gt 0 ]]; then
    echo "这些文件里的 test 从未被编译 —— 断言从未执行过。" >&2
    exit 1
fi

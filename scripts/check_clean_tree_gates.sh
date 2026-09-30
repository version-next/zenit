#!/usr/bin/env bash
# 在**干净检出**上跑关键门禁，而不是在开发者的脏工作区上跑。
#
# 为什么需要这个脚本：
#   提交 89868a7 把 core.zig 对 `deferred_text_input_redraw` 的引用提交了，
#   但字段定义留在未提交的 node.zig 里。作者本地 `zig build test` 是绿的
#   —— 因为脏工作区里有那个字段。干净 clone 上直接编译失败，而且这个状态
#   一路带过了后续 4 个提交没人发现。
#
#   同类事故在这个仓库出现过不止一次（bench 编译失败连续 6 个提交、
#   "45/45 全绿"其实只是本地信号）。根因都一样：**验证环境和将要推送的
#   内容不是同一个东西**。
#
# 做法：用 git worktree 在临时目录检出指定 ref（默认 HEAD），在那里跑门禁。
# worktree 只包含已提交内容，工作区的未提交改动不会泄漏进去。
#
# 用法：
#   bash scripts/check_clean_tree_gates.sh           # 检查 HEAD
#   bash scripts/check_clean_tree_gates.sh <ref>     # 检查指定提交
#
# 建议接进 pre-push hook，或在 push 前手动跑一次。
set -euo pipefail

REF="${1:-HEAD}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT"

ZIG_BIN="${ZIG:-zig}"
if ! command -v "$ZIG_BIN" >/dev/null 2>&1; then
  echo "zig not found on PATH (set ZIG=/path/to/zig)" >&2
  exit 1
fi

RESOLVED="$(git rev-parse --short "$REF")"
WORKTREE="$(mktemp -d "${TMPDIR:-/tmp}/zenit-cleantree.XXXXXX")"

cleanup() {
  git worktree remove --force "$WORKTREE" >/dev/null 2>&1 || true
  rm -rf "$WORKTREE" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "=== 干净检出门禁：$RESOLVED ==="
echo "worktree: $WORKTREE"
echo

git worktree add --detach -q "$WORKTREE" "$REF"

failures=0
run_gate() {
  local name="$1"; shift
  printf '  %-34s' "$name"
  if (cd "$WORKTREE" && "$@" >/dev/null 2>&1); then
    echo "ok"
  else
    echo "FAIL"
    failures=$((failures + 1))
  fi
}

# 编译 + 确定性测试。P0 就是这一条漏掉的。
run_gate "zig build test"            "$ZIG_BIN" build test
# RHI 抽象证伪：任何把 Metal 语义焊进渲染层的改动会在这里编译失败。
run_gate "null GPU backend"          "$ZIG_BIN" build -Dgpu-backend=null test-headless
# 格式棘轮（存量豁免，新增不合规即红）。
run_gate "zig fmt ratchet"           bash scripts/check_zig_format.sh
# 开源边界：src/ui 不得导入越界模块。
run_gate "oss boundary"              env ZIG="$ZIG_BIN" bash scripts/check_oss_boundary.sh
# ⚠ `zig build test` **不编译 src/zenit_app/** —— 那层只有在构建 example 时
# 才会被编译。2026-09-22 实测：runtime.zig 里 5 处字段访问编译不过，而
# `zig build test` 依然全绿。CI 因为 build examples 会红，但本地只跑 test
# 的人看不到。所以这里必须带一个 example。
run_gate "example builds (zenit_app)" "$ZIG_BIN" build hello-button

echo
if (( failures > 0 )); then
  echo "✗ $RESOLVED 有 $failures 道门禁在干净检出上是红的 —— 不要推送。" >&2
  echo "  本地绿而这里红，通常意味着有改动没提交（最常见：新字段/新文件）。" >&2
  exit 1
fi
echo "✓ $RESOLVED 在干净检出上全部门禁通过。"

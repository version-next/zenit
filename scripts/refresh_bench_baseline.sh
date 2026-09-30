#!/usr/bin/env bash
# 重采 src/bench/baselines/main.json —— bench 门禁的比较基准。
#
# ── 为什么需要这个脚本 ────────────────────────────────────────────────
# baseline 是手工产物，没有自动更新机制。2026-09-22 实测：文件停在 8 月 12 日
# 且**不记录 commit**，于是门禁红了一个多月没人处理 —— 因为红了之后根本判断
# 不出是代码退化还是换了机器。没有溯源信息的 baseline 会训练所有人无视门禁。
#
# 现在 bench JSON 带 commit / host / unix_time 三个字段（见 runner.zig），
# 这个脚本负责把它们填对。
#
# 用法：bash scripts/refresh_bench_baseline.sh
#       刷新后**必须**在 commit message 里说明为什么重采（性能确有变化？
#       换机器？新增 bench？），否则下次红了还是同样查不清。
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ -n "$(git status --porcelain)" ]]; then
    echo "ERROR: 工作树不干净。baseline 必须在干净树上采，否则记录的 commit 对不上实际测的代码。" >&2
    exit 1
fi

COMMIT="$(git rev-parse --short HEAD)"
HOST="$(uname -m)-$(sw_vers -productVersion 2>/dev/null || uname -s)"

echo "在 $COMMIT ($HOST) 上重采 baseline…"
ZENIT_BENCH_COMMIT="$COMMIT" ZENIT_BENCH_HOST="$HOST" \
    zig build bench -- json=src/bench/baselines/main.json

echo
echo "完成。新 baseline:"
head -4 src/bench/baselines/main.json
echo
echo "⚠ 提交前请在 commit message 里写明重采原因。"

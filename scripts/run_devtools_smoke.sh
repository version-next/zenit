#!/usr/bin/env bash
# run_devtools_smoke.sh — DevTools Performance 面板真窗口冒烟验证
#
# 断言（详见 examples/devtools_probe/main.zig 头注）：
#   Phase A: target 活跃时帧间隔历史被回填、FPS 文本实时更新、DevTools 保活不断链；
#   Phase B: target 停帧后 DevTools 仍自轮询渲染、FPS 行出现 idle 标注。
# 用法：bash scripts/run_devtools_smoke.sh [frames=180]
set -uo pipefail
cd "$(dirname "$0")/.."

FRAMES="${1:-180}"

echo "==> build devtools_probe"
zig build devtools-probe || { echo "build failed"; exit 1; }

echo "==> run smoke (${FRAMES} frames + 1.3s idle)"
LOG=$(ZENIT_SMOKE_FRAMES="$FRAMES" "./zig-out/DevTools Probe.app/Contents/MacOS/devtools_probe" 2>&1)
RC=$?

if [ $RC -ne 0 ]; then
  echo "FAIL: probe exited rc=$RC"
  echo "$LOG" | tail -20
  exit 1
fi

echo "$LOG" | grep -q "phase-A ok" || { echo "FAIL: 缺 phase-A 标记"; echo "$LOG" | tail -20; exit 1; }
echo "$LOG" | grep -q "phase-B ok" || { echo "FAIL: 缺 phase-B 标记"; echo "$LOG" | tail -20; exit 1; }
echo "$LOG" | grep -q "smoke ok" || { echo "FAIL: 缺完成标记"; echo "$LOG" | tail -20; exit 1; }

echo "$LOG" | grep -E "phase-A ok|phase-B ok|smoke ok"
echo "PASS: devtools smoke"

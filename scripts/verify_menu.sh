#!/usr/bin/env bash
# 原生菜单真机验收 —— Release Truth "native menu implementation NOT RUN" 行的
# 缺口：model/mock/link 测试都过，但真 AppKit 菜单点击与快捷键从没跑过。
#
# 链路：NSMenu(真菜单栏) 点击 / Cmd+P 快捷键
#   → window_bridge menu target-action → menu_command 事件
#   → Cx.handleCommand → ActionDispatcher → probe 的 on_action 打印
#
# 判据：probe stdout 出现 "[PROBE] action ping"（两次：一次点击、一次快捷键）。
# 前置条件：GUI 会话 + 辅助功能权限（System Events 点菜单）。
# 用法：bash scripts/verify_menu.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

LOG=/tmp/zenit-menu-verify.log
PASS=0; FAIL=0
check() { if [ "$2" = 0 ]; then echo "  PASS  $1"; PASS=$((PASS+1)); else echo "  FAIL  $1"; FAIL=$((FAIL+1)); fi }

echo "==> 构建 + 启动 interop_probe"
zig build interop-probe >/dev/null
"./zig-out/zenit Interop Probe.app/Contents/MacOS/interop_probe" >"$LOG" 2>&1 &
APP_PID=$!
trap 'kill $APP_PID 2>/dev/null || true' EXIT
sleep 2
grep -q "menu-set failed" "$LOG" && { echo "setMenuModel 失败"; exit 1; }

echo "==> System Events 点击真菜单栏 Probe → Ping"
osascript >/dev/null <<'EOF'
tell application "System Events"
  tell process "interop_probe"
    set frontmost to true
    delay 0.3
    click menu item "Ping" of menu "Probe" of menu bar item "Probe" of menu bar 1
  end tell
end tell
EOF
sleep 0.8
N1=$(grep -c '\[PROBE\] action ping' "$LOG" || true)
[ "$N1" -ge 1 ] && check "真菜单栏点击 → menu_command → action" 0 || check "真菜单栏点击 → menu_command → action" 1

echo "==> CGEvent Cmd+P 快捷键"
osascript >/dev/null <<'EOF'
tell application "System Events"
  tell process "interop_probe"
    set frontmost to true
    set position of window 1 to {60, 120}
  end tell
end tell
EOF
sleep 0.3
# 点窗口**右半边**拿 key 状态（左半边是拖拽源区，会开拖拽会话吃掉键盘事件）
swift scripts/cgevent.swift click 360 300
sleep 0.4
# p = keycode 35；flags 显式 maskCommand（见 verify_ime.sh 的物理修饰键继承坑）
swift - <<'EOF'
import CoreGraphics
let src = CGEventSource(stateID: .hidSystemState)
for down in [true, false] {
    let e = CGEvent(keyboardEventSource: src, virtualKey: 35, keyDown: down)!
    e.flags = .maskCommand
    e.post(tap: .cghidEventTap)
}
EOF
sleep 0.8
N2=$(grep -c '\[PROBE\] action ping' "$LOG" || true)
[ "$N2" -ge $((N1 + 1)) ] && check "Cmd+P 快捷键 → menu_command → action" 0 || check "Cmd+P 快捷键 → menu_command → action" 1

echo
echo "Results: $PASS passed, $FAIL failed  (action 触发总数: $N2)"
[ "$FAIL" = 0 ]

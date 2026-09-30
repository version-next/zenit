#!/usr/bin/env bash
# 富剪贴板 + 文件拖出的真机验证（真系统路径，e2e 注入覆盖不到）。
#
# 覆盖三条链路：
#   A. 剪贴板 get：外部（swift/NSPasteboard）预置 HTML → probe 启动时读到
#   B. 剪贴板 set：probe 写 text+HTML 双 representation → 外部读回两种类型
#   C. 拖出：probe 窗口 mousedown 起 beginDrag(file_url) → CGEvent 拖到
#      Finder 目标目录 → 判据 = 目标目录出现 payload.txt（Finder 执行拷贝）
#
# 前置条件：GUI 会话；跑 C 需要终端有「辅助功能」权限（同 verify_real_drag.sh）。
# 用法：bash scripts/verify_interop_probe.sh [--skip-drag]
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SKIP_DRAG="${1:-}"
LOG=/tmp/zenit-interop-probe.log
SRC=/tmp/zenit-dragout
DST=/tmp/zenit-dragout-dest
PASS=0
FAIL=0
check() { # $1 label, $2 = 0/1 ok
  if [ "$2" = 0 ]; then echo "  PASS  $1"; PASS=$((PASS+1)); else echo "  FAIL  $1"; FAIL=$((FAIL+1)); fi
}

echo "==> 构建 interop-probe"
zig build interop-probe >/dev/null

echo "==> A. 外部预置 HTML 剪贴板"
swift - <<'EOF'
import AppKit
let pb = NSPasteboard.general
pb.clearContents()
let item = NSPasteboardItem()
item.setString("external-html-marker <i>from swift</i>", forType: .html)
item.setString("external-plain", forType: .string)
pb.writeObjects([item])
EOF

echo "==> 启动 probe（读 HTML → 写富剪贴板）"
rm -f "$LOG"
ZENIT_DEBUG_DRAG=1 "./zig-out/zenit Interop Probe.app/Contents/MacOS/interop_probe" >"$LOG" 2>&1 &
APP_PID=$!
trap 'kill $APP_PID 2>/dev/null || true' EXIT
for _ in $(seq 1 50); do grep -q "rich-set" "$LOG" 2>/dev/null && break; sleep 0.2; done

grep -q '\[PROBE\] read-html: .*external-html-marker' "$LOG"; check "A: probe 读到外部 HTML" $?
grep -q '\[PROBE\] rich-set-ok' "$LOG"; check "B1: probe 富写入返回 ok" $?

echo "==> B. 外部读回 probe 写入的两种 representation"
swift - <<'EOF'
import AppKit
let pb = NSPasteboard.general
let plain = pb.string(forType: .string) ?? "<nil>"
let html = pb.string(forType: .html) ?? "<nil>"
print("plain=\(plain)")
print("html=\(html)")
guard plain == "zenit-probe-plain", html.contains("zenit-probe-html") else { exit(1) }
EOF
check "B2: 外部进程读回 plain+HTML 双 representation" $?

if [ "$SKIP_DRAG" = "--skip-drag" ]; then
  echo "==> C. 拖出验证已跳过（--skip-drag）"
else
  echo "==> C. 文件拖出到 Finder"
  rm -rf "$SRC" "$DST"; mkdir -p "$SRC" "$DST"
  printf 'zenit drag-out payload\n' > "$SRC/payload.txt"

  # 摆放 probe 窗口与 Finder 目标窗口（固定坐标，CGEvent 用全局屏幕坐标）
  osascript >/dev/null <<EOF
tell application "System Events"
  tell process "interop_probe"
    set frontmost to true
    set position of window 1 to {60, 120}
    set size of window 1 to {400, 300}
  end tell
end tell
tell application "Finder"
  activate
  set w to make new Finder window
  set target of w to (POSIX file "$DST" as alias)
  set current view of w to list view
end tell
tell application "System Events"
  tell process "Finder"
    set position of window 1 to {620, 120}
    set size of window 1 to {420, 400}
  end tell
end tell
EOF
  sleep 1
  # probe 窗口左半边拖拽源区 (180, 270)（右半边是普通点击区，不起拖）
  # → Finder 窗口列表区 (850, 320)（实测 830 差 20px 撞在 sidebar 上）
  # draghold：按住起拖后分步移动（memory: 需分步拖动 + mousedown 立刻起拖）
  swift scripts/cgevent.swift draghold 180 270 850 320 1.0 || \
    swift scripts/cgevent.swift drag 180 270 850 320

  ok=1
  for _ in $(seq 1 25); do
    if [ -f "$DST/payload.txt" ]; then ok=0; break; fi
    sleep 0.4
  done
  check "C: Finder 目标目录收到 payload.txt" $ok
  grep -q '\[PROBE\] beginDrag ok' "$LOG"; check "C: probe beginDrag 会话已建立" $?
  osascript -e 'tell application "Finder" to close every window' >/dev/null 2>&1 || true
fi

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]

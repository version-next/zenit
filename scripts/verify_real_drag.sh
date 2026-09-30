#!/usr/bin/env bash
# 拖放的真机验证 —— 从 Finder 拖真文件进 storybook 窗口。
#
# 这条路径 **e2e 覆盖不到**：e2e 的 dragAt 是程序化注入 SDK 事件队列，
# 绕过了 macOS 的 NSDragging pasteboard 协议。本脚本走完整系统路径：
#   Finder 拖拽会话 → NSDraggingDestination 回调 → pushDragEvent
#   → view.dragEventQueue → macos_get_drag_event → SDK 事件队列
#   → Cx.handleDrag → dispatcher → FileUpload.onDropFiles
#
# 判据（唯一可信的）：ZENIT_DEBUG_DRAG=1 下 stderr 出现
#   [DRAG] kind=3 x=.. y=.. paths=/private/tmp/...
# kind 0/1/2/3 = entered/updated/exited/dropped，只有 kind=3 带 paths。
#
# 前置条件：
#   1. 运行它的终端进程持有「辅助功能」权限（系统设置 → 隐私与安全性）。
#   2. 需要 GUI 会话（不能在纯 ssh/headless 下跑）。
#
# 本脚本做到「半自动」：它负责构建 + 起窗口 + 备好测试文件 + 开日志监视，
# 剩下的窗口摆放 / 定位 drop zone / 发拖拽事件需要人给坐标 —— 因为
# storybook 的 nav 与 drop zone 位置随窗口几何变化，没有稳定的
# 可编程定位（zenit 的 a11y 树不导出 nav 行）。
#
# 用法：
#   bash scripts/verify_real_drag.sh
# 然后按提示用 scripts/cgevent.swift 发拖拽（见下方打印的示例）。

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

DRAGDIR=/tmp/zenit-dragdir
LOG=/tmp/zenit-drag-verify.log

echo "==> 准备测试文件 $DRAGDIR"
rm -rf "$DRAGDIR"
mkdir -p "$DRAGDIR"
printf 'a\n' > "$DRAGDIR/aaa.txt"
printf 'b\n' > "$DRAGDIR/bbb.txt"

echo "==> 构建 storybook"
zig build storybook

echo "==> 启动 storybook（ZENIT_DEBUG_DRAG=1），日志 -> $LOG"
ZENIT_DEBUG_DRAG=1 "./zig-out/zenit Storybook.app/Contents/MacOS/storybook" > "$LOG" 2>&1 &
APP_PID=$!
sleep 3

echo "==> 在 Finder 里打开 $DRAGDIR"
osascript <<EOF >/dev/null
tell application "Finder"
	activate
	set target of window 1 to (POSIX file "$DRAGDIR" as alias)
	set current view of window 1 to list view
end tell
delay 1
tell application "System Events"
	tell process "Finder"
		set position of window 1 to {20, 120}
		set size of window 1 to {560, 500}
	end tell
end tell
EOF

cat <<'GUIDE'

================ 接下来手动做（或用 cgevent.swift 驱动）================

1) 把 storybook 窗口移到不与 Finder 重叠的位置，在左侧 nav 里点 "FileUpload"。
   （可用 `swift scripts/cgevent.swift click <x> <y>`；坐标用
     `screencapture -x -R <x>,<y>,<w>,<h> /tmp/shot.png` 截图后量出来 ——
     注意 System Events 报的窗口原点与 screencapture 的屏幕坐标可能差几十像素，
     以截图为准。）

2) 单文件拖放：
     swift scripts/cgevent.swift drag <finder行x> <finder行y> <dropzone中心x> <dropzone中心y>

3) 多文件拖放（先建立 2 行选区再拖，中间别松手）：
     swift scripts/cgevent.swift dragmulti <x> <行1y> <行2y> <dropzone中心x> <dropzone中心y>
   注意：Finder 里按住选中行停顿太久，选区会塌缩成单个文件 —— 实测踩过，
   拖之前可用 `osascript -e 'tell application "Finder" to count of (selection as list)'` 确认是 2。

4) 悬停高亮（on_drag_enter）：
     swift scripts/cgevent.swift draghold <sx> <sy> <ex> <ey> 4
   在 hold 期间截图，drop zone 边框应明显变深。

5) 非 drop target 区域：拖到 drop zone 以外，日志会出现 kind=3，
   但组件列表**不应**新增行（Cx.handleDrag 命中不到 drop target）。

================ 判据 ================

  grep '\[DRAG\]' /tmp/zenit-drag-verify.log

  出现 `kind=3 ... paths=/private/tmp/zenit-dragdir/aaa.txt` 才算原生路径通了；
  再看 storybook 窗口里 FileUpload 是否真的多出对应文件行。

GUIDE

echo "storybook pid=$APP_PID（验证完 kill 它）"

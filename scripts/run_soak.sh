#!/usr/bin/env bash
# GPU 资源泄漏 soak —— 持续渲染下测 RSS 斜率，fail closed。
#
# 为什么需要这个脚本：
#   本轮 P0-1（Metal 双 retain）的教训是 **idle gating 会完全掩盖 GPU 泄漏**。
#   框架默认 `idle_skip_frames = true`，静止窗口几乎不提交帧 —— 实测空跑 32s
#   RSS 完全持平，泄漏根本不触发。必须强制每帧提交才测得出来
#   （修复前 +275 KB/s 线性 ≈ 1GB/小时；修复后走平）。
#   `zig build test` 全绿同样不算数：GPA leak check 对 page_allocator
#   fallback 路径盲视，且这类 bug 只在真窗口 + 持续帧循环下暴露。
#
# 用法：
#   bash scripts/run_soak.sh [seconds] [max_kb_per_sec]
# 默认跑 30 秒，阈值 40 KB/s（修复前实测 275 KB/s，修复后 ~10 KB/s 并走平）。
#
# 注意：需要真实 WindowServer（本机开发环境），headless CI 跑不了 —— CI 侧
# 的等价守门是 `zig build test` 的 GPA leak check + standalone 表回收断言。

set -euo pipefail

DURATION="${1:-30}"
MAX_KB_PER_SEC="${2:-40}"
EXAMPLE_SRC="examples/hello_button/main.zig"
BACKUP="$(mktemp -t zenit_soak_backup)"
APP=""

stop_app() {
    local pid="$1"
    if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then return; fi
    kill "$pid" 2>/dev/null || true
    local attempt=0
    while kill -0 "$pid" 2>/dev/null && [[ $attempt -lt 20 ]]; do
        sleep 0.1
        attempt=$((attempt + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
        kill -9 "$pid" 2>/dev/null || true
    fi
    wait "$pid" 2>/dev/null || true
}

cleanup() {
    # 无论成功失败都还原被临时改动的 example
    if [[ -f "$BACKUP" ]]; then
        cp "$BACKUP" "$EXAMPLE_SRC"
        rm -f "$BACKUP"
    fi
    stop_app "$APP"
}
trap cleanup EXIT

if [[ ! -f "$EXAMPLE_SRC" ]]; then
    echo "ERROR: $EXAMPLE_SRC not found (run from repo root)" >&2
    exit 2
fi
cp "$EXAMPLE_SRC" "$BACKUP"

# 关掉 idle gating —— 否则整个 soak 毫无意义（见文件头说明）。
if ! grep -q "idle_skip_frames" "$EXAMPLE_SRC"; then
    /usr/bin/sed -i '' \
        's|\.window = \.{ \.width = 640, \.height = 480, \.title = "Hello Button" },|&\
        .idle_skip_frames = false, // soak: 强制每帧提交|' \
        "$EXAMPLE_SRC"
fi
grep -q "idle_skip_frames = false" "$EXAMPLE_SRC" || {
    echo "ERROR: failed to disable idle_skip_frames — soak would be a no-op" >&2
    exit 2
}

echo "Building hello-button (idle_skip_frames=false)…"
zig build hello-button >/dev/null

BIN="zig-out/Hello Button.app/Contents/MacOS/hello_button"
test -x "$BIN" || { echo "ERROR: $BIN not executable" >&2; exit 2; }

"$BIN" >/dev/null 2>&1 &
APP=$!
sleep 3   # 跳过启动期的一次性分配（字体/atlas/pipeline）

if ! kill -0 "$APP" 2>/dev/null; then
    echo "ERROR: app died during startup" >&2
    exit 1
fi

BASE_RSS=$(ps -o rss= -p "$APP" | tr -d ' ')
echo "baseline rss=${BASE_RSS}KB, sampling for ${DURATION}s…"

# 判据用**后半段斜率**而不是总增长：启动后仍有一次性分配（字体 atlas 扩张、
# PSO 惰性创建、纹理池预热）会在前半段抬高 RSS 然后走平。真正的逐帧泄漏是
# **持续线性**的，后半段斜率同样高；一次性分配的后半段斜率则接近 0。
# 这样既能抓住 275 KB/s 那种线性泄漏，又不会被正常预热误伤。
elapsed=0
step=5
HALF=$((DURATION / 2))
MID_RSS=""
while [[ $elapsed -lt $DURATION ]]; do
    sleep $step
    elapsed=$((elapsed + step))
    if ! kill -0 "$APP" 2>/dev/null; then
        echo "ERROR: app died after ${elapsed}s (crash or drawable starvation)" >&2
        exit 1
    fi
    RSS=$(ps -o rss= -p "$APP" | tr -d ' ')
    echo "  t=${elapsed}s rss=${RSS}KB (+$((RSS - BASE_RSS))KB)"
    if [[ -z "$MID_RSS" && $elapsed -ge $HALF ]]; then
        MID_RSS="$RSS"
        MID_T="$elapsed"
    fi
done

FINAL_RSS=$(ps -o rss= -p "$APP" | tr -d ' ')
stop_app "$APP"
APP=""

GROWTH=$((FINAL_RSS - BASE_RSS))
: "${MID_RSS:=$BASE_RSS}"
: "${MID_T:=0}"
TAIL_SECS=$((DURATION - MID_T))
[[ $TAIL_SECS -gt 0 ]] || TAIL_SECS=1
TAIL_GROWTH=$((FINAL_RSS - MID_RSS))
RATE=$(awk -v g="$TAIL_GROWTH" -v d="$TAIL_SECS" 'BEGIN{printf "%.1f", g/d}')

echo
echo "total growth=${GROWTH}KB over ${DURATION}s"
echo "tail slope (last ${TAIL_SECS}s)=${TAIL_GROWTH}KB → ${RATE} KB/s (threshold ${MAX_KB_PER_SEC} KB/s)"

if awk -v r="$RATE" -v m="$MAX_KB_PER_SEC" 'BEGIN{exit !(r > m)}'; then
    echo "SOAK FAILED: RSS growth ${RATE} KB/s exceeds ${MAX_KB_PER_SEC} KB/s." >&2
    echo "  Likely a per-frame GPU object leak (see docs/internal/GPU_DX_DEEP_REVIEW_2026-07-22.md §P0-1)." >&2
    exit 1
fi

echo "Soak passed."

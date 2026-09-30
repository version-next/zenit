#!/usr/bin/env bash
# R0 ratchet: Metal references outside reviewed backend paths may only decrease.
set -euo pipefail

cd "$(dirname "$0")/.."
APPROVED="scripts/renderer_metal_approved_paths.txt"
BASELINE="scripts/renderer_metal_leak_baseline.txt"
CURRENT="$(mktemp /tmp/zenit-renderer-metal-current.XXXXXX)"

cleanup() {
  rm -f "$CURRENT"
}
trap cleanup EXIT

PATTERN='Backend\.metal_bindings|\bmtl\.|MTL[A-Z][A-Za-z0-9_]*|metal_[a-zA-Z0-9_]+'
# 只看**代码**，不看注释：把 `//` 之后的内容剪掉再匹配。
# 2026-09-22：text_renderer.zig 有一行注释写着「泄漏的是 MTLBuffer/PSO/CoreText
# 资源」，被当成新的 Metal 依赖而误报 —— 注释里提一句 Metal 类型名不是依赖。
# （行内字符串里含 `//` 的情况在 src/render 下不存在；真出现会是保守误报，
# 不会漏报。）
{ rg -n "$PATTERN" src/render --glob '*.zig' || true; } |
  awk -F: '{ line=$0; sub(/\/\/.*/, "", line); if (line ~ /Backend\.metal_bindings|[^a-zA-Z0-9_]mtl\.|MTL[A-Z]|metal_[a-zA-Z0-9_]/) print }' |
  awk -F: '{ count[$1]++ } END { for (path in count) print count[path], path }' |
  sort -k2 >"$CURRENT"

LEAK_TOTAL=0
APPROVED_TOTAL=0
while read -r count path; do
  if grep -qxF "$path" "$APPROVED"; then
    APPROVED_TOTAL=$((APPROVED_TOTAL + count))
    continue
  fi

  limit="$(awk -v wanted="$path" '$2 == wanted { print $1 }' "$BASELINE")"
  if [[ -z "$limit" ]]; then
    echo "new Metal dependency outside an approved backend path: $path ($count refs)" >&2
    exit 1
  fi
  if (( count > limit )); then
    echo "Metal dependency grew: $path has $count refs (R0 limit $limit)" >&2
    exit 1
  fi
  LEAK_TOTAL=$((LEAK_TOTAL + count))
done <"$CURRENT"

BASELINE_TOTAL="$(awk '{ sum += $1 } END { print sum + 0 }' "$BASELINE")"
if (( LEAK_TOTAL > BASELINE_TOTAL )); then
  echo "renderer Metal leak total grew: $LEAK_TOTAL > $BASELINE_TOTAL" >&2
  exit 1
fi

echo "renderer Metal boundary ratchet: PASS (outside=$LEAK_TOTAL/$BASELINE_TOTAL, approved=$APPROVED_TOTAL)"

#!/usr/bin/env bash
# 验证 templates/minimal-app 这条「外部用户第一接触点」真能跑通。
#
# ── 为什么需要它 ──────────────────────────────────────────────────────
# 模板此前**没有任何自动化验证**：没有脚本、CI 也从不碰它。这类东西最容易
# 烂掉——入门路径坏了，而所有内部门禁照样全绿，因为仓库内的 example 走的
# 是另一套 build 路径（examples/ 直接用仓库的 build.zig，不经 attach()）。
#
# 2026-09-22 首次实测就抓到：build.zig.zon 的注释建议
# `.path = "/abs/path/to/zenit"`，而 Zig 0.15.2 拒绝绝对路径
# （expected path relative to build root）。照注释做的用户第一步就失败。
#
# ── 为什么复制到仓库外 ────────────────────────────────────────────────
# 模板原地（templates/minimal-app/）的 `.path = "../../"` 恰好指向仓库根，
# 在原地跑是「自己构建自己」，验不出复制出去之后的路径问题。必须复制到
# 仓库外、改写成指向本仓库的相对路径，才是外部用户的真实形态。
set -euo pipefail

ZENIT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# realpath：macOS 的 mktemp 给 /var/folders/...，而 /var 是指向 /private/var
# 的符号链接。不解析的话，下面算出的相对路径会多绕一层，Zig 解析依赖时找不到
# 包（报 "no module named 'zenit'"，而不是路径错误，很难往这边想）。
WORK="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT

APP="$WORK/myapp"
cp -r "$ZENIT_ROOT/templates/minimal-app" "$APP"

# 改写依赖路径：指向本仓库，且必须是相对路径（Zig 不接受绝对路径）
REL="$(python3 -c "import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))" "$ZENIT_ROOT" "$APP")"
python3 - "$APP/build.zig.zon" "$REL" <<'PY'
import sys, pathlib, re
p = pathlib.Path(sys.argv[1]); s = p.read_text()
s2 = re.sub(r'\.zenit = \.\{ \.path = "[^"]*" \}', f'.zenit = .{{ .path = "{sys.argv[2]}" }}', s)
assert s2 != s, "未能改写 .zenit 依赖路径——模板结构变了？"
p.write_text(s2)
PY

cd "$APP"
echo "==> zig build（模板默认目标）"
zig build

test -x zig-out/bin/myapp || { echo "FAIL: 未产出可执行文件 zig-out/bin/myapp" >&2; exit 1; }

if [[ "$(uname -s)" == "Darwin" ]]; then
    echo "==> zig build app（.app bundle）"
    zig build app
    test -d "zig-out/My App.app" || { echo "FAIL: 未产出 .app bundle" >&2; exit 1; }
fi

# ── README 的完整示例也要能编译 ──────────────────────────────────────
# 它是新用户看到的第一段真实代码，坏了影响最大。复用同一套模板脚手架编译。
echo
echo "==> README 的完整示例"
python3 "$ZENIT_ROOT/scripts/extract_readme_example.py" "$ZENIT_ROOT/README.md" "$APP/src/main.zig"
zig build

echo
echo "✓ 模板在仓库外可构建（exe + .app bundle）；README 完整示例可编译"

#!/usr/bin/env python3
"""从 README.md 抽出唯一可独立编译的 zig 示例，写到目标路径。

README 里的 zig 块绝大多数是带 `...` 占位的片段（build.zig 片段、
build.zig.zon 片段等），只有「完整 counter 应用」那块含 `pub fn main`、
可以端到端编译。它是新用户看到的第一段真实代码。

供 scripts/check_template_builds.sh 调用。
"""
import sys, re, pathlib

readme, out = sys.argv[1], sys.argv[2]
blocks = re.findall(r'```zig\n(.*?)```', pathlib.Path(readme).read_text(), re.S)
full = [b for b in blocks if 'pub fn main' in b]
if len(full) != 1:
    sys.exit(
        f"README 里可独立编译的 zig 块应当恰好 1 个，实际 {len(full)} 个。"
        " README 结构变了，请同步更新 scripts/check_template_builds.sh。"
    )
pathlib.Path(out).write_text(full[0])

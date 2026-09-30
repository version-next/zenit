#!/usr/bin/env bash
# Static consistency checks for the single release-status authority.
set -euo pipefail

cd "$(dirname "$0")/.."
TRUTH="docs/RELEASE_TRUTH.md"

test -f "$TRUTH"
test "$(grep -c '^\*\*Current disposition:\*\*' "$TRUTH")" -eq 1
grep -q '^\*\*Current disposition:\*\* \*\*NOT RELEASE-READY\*\*\.' "$TRUTH"

audit_marker="$(grep -E '^<!-- release-truth-audit revision=[0-9a-f]{40} dirty=(true|false) -->$' "$TRUTH" || true)"
if [[ -z "$audit_marker" || "$(printf '%s\n' "$audit_marker" | wc -l | tr -d ' ')" != 1 ]]; then
  echo "$TRUTH must contain exactly one well-formed full-hash audit marker" >&2
  exit 1
fi
audit_revision="$(printf '%s\n' "$audit_marker" | sed -E 's/.*revision=([0-9a-f]{40}).*/\1/')"
if ! git cat-file -e "$audit_revision^{commit}" 2>/dev/null; then
  echo "$TRUTH audit revision is not present in this repository: $audit_revision" >&2
  exit 1
fi
if ! git merge-base --is-ancestor "$audit_revision" HEAD; then
  echo "$TRUTH audit revision is not an ancestor of HEAD: $audit_revision" >&2
  exit 1
fi
grep -q "\`$audit_revision\`" "$TRUTH"
grep -q 'record_release_audit\.sh' "$TRUTH"

for status in PASS FAIL BLOCKED 'NOT RUN' 'N/A'; do
  grep -q "\`$status\`" "$TRUTH"
done

# README.md is exported to the public repo, which does not ship the release
# truth, so it no longer links to it; the internal docs below still must.
for doc in docs/ROADMAP.md docs/RELEASE.md docs/BUGS.md; do
  if ! grep -q 'RELEASE_TRUTH\.md' "$doc"; then
    echo "$doc does not link to the release truth" >&2
    exit 1
  fi
done

grep -q 'release-candidate-validate' docs/RELEASE_CANDIDATE_CHECKLIST.md
grep -q 'record_release_audit\.sh' docs/RELEASE_CANDIDATE_CHECKLIST.md
grep -q 'required / all gates' docs/BRANCH_PROTECTION.md
bash scripts/check_ci_contract.sh
bash scripts/test_component_quality_matrix.sh
git check-ignore -q release-evidence/contract-probe
git check-ignore -q .ci-evidence/contract-probe

grep -q 'b.step("test-headless"' build.zig
grep -q 'b.step("test-metal"' build.zig
grep -q 'b.step("test-all"' build.zig

# 跳过/隔离/聚焦测试必须**分类**，不能是无声的。
#
# 报错文案一直写着「unclassified」，但此前没有任何分类机制 —— 于是任何
# SkipZigTest 都会让这道门禁红，仓库里 16 处环境依赖的合法跳过把它长期钉死
# 在红色（2026-09-22 实测 main 上同样红）。一道恒红的门禁等于没有门禁。
#
# 现在给出分类办法：合法的跳过在**同一行或上一行**写 `SKIP-REASON:` 说明
# 为什么这个环境跑不了（缺字体、要特定 GPU 后端、要显式开关…）。没有说明的
# 跳过、以及任何 QUARANTINED / .only 聚焦测试，仍然一律红。
unclassified="$(python3 - <<'PYEOF'
import pathlib, re, sys
pat = re.compile(r'return error\.SkipZigTest|QUARANTINED|test\.only|describe\.only|it\.only')
bad = []
for root in ("src", "e2e", "examples", "tools"):
    for f in pathlib.Path(root).rglob("*"):
        if not f.is_file() or f.suffix not in (".zig", ".ts", ".js"):
            continue
        lines = f.read_text(encoding="utf8", errors="ignore").split("\n")
        for i, line in enumerate(lines):
            if not pat.search(line):
                continue
            prev = lines[i - 1] if i else ""
            if "SKIP-REASON:" in line or "SKIP-REASON:" in prev:
                continue
            bad.append(f"{f}:{i + 1}: {line.strip()}")
print("\n".join(bad))
PYEOF
)"
if [[ -n "$unclassified" ]]; then
  echo "$unclassified" >&2
  echo "unclassified skip, quarantine, or focused test found" >&2
  echo "  合法的环境依赖跳过请在同行或上一行加 'SKIP-REASON: <为什么这个环境跑不了>'" >&2
  exit 1
fi

echo "release truth consistency: PASS"

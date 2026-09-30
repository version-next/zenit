#!/usr/bin/env bash
# Fail closed on the icon-provider architecture. This gate is safe in the
# public repository, where the optional Untitled adapter/assets are absent.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail() {
  echo "icon architecture: FAIL: $*" >&2
  exit 1
}

grep -q ') orelse "lucide";' build.zig \
  || fail "Lucide must remain the public default"
grep -q 'pub const icons = @import("zenit_icons");' src/ui/ui.zig \
  || fail "ui.icons must come from the build-graph provider import"
grep -q 'pub const system_icons = @import("zenit_system_icons");' src/ui/ui.zig \
  || fail "ui.system_icons must come from the semantic provider import"

if rg -n '@import\("[^\"]*icons(_(lucide|untitled))?_generated\.zig"\)' \
    src --glob '*.zig' --glob '!icons_*_generated.zig'; then
  fail "framework source must not import a generated provider by relative path"
fi

provider_importers=$(rg -l '@import\("zenit_icons"\)' src/ui --glob '*.zig' | LC_ALL=C sort)
expected_importers=$(printf '%s\n' \
  src/ui/system_icons_lucide.zig \
  src/ui/ui.zig | LC_ALL=C sort)
[[ "$provider_importers" == "$expected_importers" ]] \
  || fail "only ui.zig and semantic adapters may import the full provider"

semantic_names=(
  activity alert audio check close search heart star home settings notification
  calendar user mail trash download upload edit copy lock chevron_left
  chevron_right minus plus more_horizontal cursor_default cursor_click pointer
  move not_allowed grab resize_horizontal resize_vertical resize_diagonal wait
  progress help
)
for name in "${semantic_names[@]}"; do
  rg -q "^pub const ${name} =" src/ui/system_icons_lucide.zig \
    || fail "Lucide semantic adapter is missing '$name'"
  if [[ -f private/zenit-icons-untitled/system_icons.zig ]]; then
    rg -q "^pub const ${name} =" private/zenit-icons-untitled/system_icons.zig \
      || fail "Untitled semantic adapter is missing '$name'"
  fi
done

[[ -s src/ui/icons_lucide_generated.zig ]] \
  || fail "Lucide generated module is missing"
grep -q '@embedFile("icons_oss/' src/ui/icons_lucide_generated.zig \
  || fail "Lucide generated module embeds the wrong asset root"
[[ -s src/ui/icons_common_generated.zig ]] \
  || fail "public common icon module is missing"
grep -q '@embedFile("icons_common/' src/ui/icons_common_generated.zig \
  || fail "public common icon module embeds the wrong asset root"
[[ ! -e src/ui/svg_assets_generated.zig ]] \
  || fail "legacy common icon generated module must stay deleted"

if rg -q 'perl -pi|build[^#]*gen-icons|find src examples templates' scripts/switch_icon_set.sh; then
  fail "switch_icon_set.sh must not rewrite generated files or call sites"
fi
grep -q -- '-Dicon-set=' scripts/switch_icon_set.sh \
  || fail "switch_icon_set.sh must select a build profile"

echo "icon architecture: PASS (build-time provider + semantic system contract)"

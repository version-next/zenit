#!/usr/bin/env bash
#
# check_oss_boundary.sh — verify zenit open-source boundary is intact.
#
# Runs two audits:
#   1. Static: grep imports inside src/ui/ for forbidden module names.
#   2. Build:  compile hello_button with --verbose and ensure no forbidden
#              module is reachable through transitive imports.
#
# Exit code: 0 if boundary intact, 1 otherwise.
#
# Usage:  bash scripts/check_oss_boundary.sh
#         (run from repo root)
#
# See docs/UI_OSS_BOUNDARY.md for the canonical boundary contract.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# Uses the zig on PATH by default; override with ZIG=/path/to/zig.
ZIG="${ZIG:-$(command -v zig || echo zig)}"
ZIG_BUILD_ARGS=(build)
if [[ -n "${ZENIT_ZIG_LIB_DIR:-}" ]]; then
  ZIG_BUILD_ARGS+=(--zig-lib-dir "$ZENIT_ZIG_LIB_DIR")
fi
if ! command -v "$ZIG" >/dev/null 2>&1; then
  echo "❌ zig not found ($ZIG)"
  echo "   put zig on PATH or set ZIG=/path/to/zig"
  exit 1
fi

# Allowed modules that may appear in src/ui/ imports. Anything else is a boundary violation.
#   root    -- Zig standard 'root module' reference (build_options, dbg etc.)
#   ui_core -- only used in src/ui/core/tests.zig as the test root module
# `text` = CoreText/HarfBuzz shaping bridge (src/text/). build.zig injects it into ui_module and
# cx.shapeText depends on it: the framework's own layering, not a boundary crossing.
# `svg` / `svg_safety` likewise: both are b.addModule modules in build.zig (src/render/svg.zig,
# src/svg_safety.zig) on the public paths whitelist in build.zig.zon. cx.registerTextureSvg goes to
# svg.rasterize and core/svg_path.zig goes to svg_safety safety primitives: framework's own
# layering.
# `zenit_style_values` / `zenit_theme_provider`: ui style value types and the theme injection point.
# The former is a b.addModule module (src/tokens/style_values.zig); the latter is injected by the
# public build API `wireThemeProvider` (downstream-chosen theme module). Both are the framework's
# own layering.
# Zig 0.17 compatibility helpers are framework-owned: field reflection, caller-I/O
# clocks, native environment access, and the native calendar-time C header.
# `zenit_corner_radii` (src/corner_radii.zig, std-only): the corner-radius normalisation the
# renderer and hit testing share, so a shape hits exactly where it is drawn.
ALLOWED_UI_IMPORTS_REGEX='^@import\("(std|builtin|root|ui_core|system_sdk|icon_ir|zenit_icons|zenit_system_icons|text_core|text|trace|i18n|svg|svg_safety|zenit_style_values|zenit_theme_provider|zenit_reflection|zenit_time|zenit_corner_radii|zenit_environment|calendar_time)"\)$'

# Forbidden modules — must NEVER appear in `zig build hello-button --verbose -M*`.
# Categories of out-of-scope code (see docs/UI_OSS_BOUNDARY.md):
#   - language toolchains (tree-sitter, LSP clients, regex engines, fuzzy matchers)
#   - editor surfaces (WYSIWYG / code editors)
#   - app-side document models richer than text_core's PieceTree
#   - app shell (workspaces, command palettes, file trees, hot-reload, dev harnesses)
FORBIDDEN_MODULES=(
  "lang"
  "plaintext"
  "document"
  "workspace"
  "hot_reload"
  "test_harness"
  "storybook"
)

red()    { printf '\033[0;31m%s\033[0m\n' "$*"; }
green()  { printf '\033[0;32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[0;33m%s\033[0m\n' "$*"; }
bold()   { printf '\033[1m%s\033[0m\n' "$*"; }

failures=0

# ────────────────────────────────────────────────────────────────────────────
# Audit 1: static grep — find forbidden imports in src/ui/
# ────────────────────────────────────────────────────────────────────────────
bold ""
bold "[1/2] Static audit: src/ui/ imports"
bold "──────────────────────────────────────"

# Extract every @import("X") token inside src/ui/, then check each against
# the allow regex. Skips comment lines and docstrings.
#
# Notes:
# - grep -h skips file paths so the src/ui/ in dir prefix doesn't poison
#   the @import contents.
# - awk filter strips lines whose first non-whitespace token starts with //
#   (regular comments and /// docstrings both match).
if [ ! -d src/ui ]; then
  red "  ✗ src/ui source directory missing"
  exit 1
fi
import_lines=$(grep -rh '@import("' src/ui/ --include='*.zig')
scan_status=$?
if [ "$scan_status" -gt 1 ]; then
  red "  ✗ could not inspect src/ui imports"
  exit 1
fi
violations=$(
  printf '%s\n' "$import_lines" \
    | awk '{ s=$0; sub(/^[[:space:]]+/,"",s); if (substr(s,1,2) != "//") print }' \
    | grep -oE '@import\("[^"]+"\)' \
    | sort -u \
    | while read -r imp; do
        if ! [[ "$imp" =~ $ALLOWED_UI_IMPORTS_REGEX ]]; then
          # Skip relative imports (path segments include / or .zig)
          inner=$(echo "$imp" | sed -E 's|@import\("(.*)"\)|\1|')
          if [[ "$inner" == *"/"* ]] || [[ "$inner" == *".zig"* ]] || [[ "$inner" == "."* ]]; then
            continue
          fi
          echo "$imp"
        fi
      done
)

if [ -z "$violations" ]; then
  green "  ✓ src/ui/ imports only the allowed module set"
else
  red "  ✗ src/ui/ imports forbidden modules:"
  echo "$violations" | while read -r v; do
    red "      $v"
    grep -rn "$v" src/ui/ | grep -v 'src/ui/' | head -3 | while read -r line; do
      yellow "        $line"
    done
  done
  failures=$((failures + 1))
fi

# ────────────────────────────────────────────────────────────────────────────
# Audit 2: build hello_button --verbose, parse -M flags
# ────────────────────────────────────────────────────────────────────────────
bold ""
bold "[2/2] Build audit: hello_button transitive imports"
bold "──────────────────────────────────────"

# Use an isolated local cache and install prefix: no stale artifact can stand in
# for this audit's build, and concurrent developer builds retain their cache.
audit_dir=$(mktemp -d -t oss_boundary.XXXXXX) || exit 1
trap 'rm -rf "$audit_dir"' EXIT
verbose_log="$audit_dir/build.log"
if ! "$ZIG" "${ZIG_BUILD_ARGS[@]}" hello-button --verbose \
    --cache-dir "$audit_dir/cache" --prefix "$audit_dir/install" >"$verbose_log" 2>&1; then
  red "  ✗ zig build hello-button failed"
  tail -20 "$verbose_log" | sed 's/^/    /'
  exit 1
fi

modules_present=$(tr ' ' '\n' <"$verbose_log" | grep -oE '^-M[a-zA-Z0-9_]+=' | sed 's/^-M//;s/=$//' | sort -u)
if [ -z "$modules_present" ]; then
  red "  ✗ no module evidence parsed from isolated build"
  exit 1
fi

bold "  hello_button reachable modules:"
echo "$modules_present" | sed 's/^/    /'

# test_harness intentionally wired into app_module: runtime.zig unconditionally imports it, relies
# on `pub const enabled = build_options.test_mode` (comptime false) for Zig to eliminate entire
# block. So 'module appears in -M graph' != 'code enters binary' -- must check link artifacts not
# module graph, else always false-red. Other forbidden modules lack this comptime-elision
# convention, still use module graph.
COMPTIME_ELIDED_MODULES=" test_harness "

forbidden_hits=$(
  for mod in "${FORBIDDEN_MODULES[@]}"; do
    if echo "$modules_present" | grep -qw "$mod"; then
      # Avoid an expanded variable inside a `case` pattern: some Bash builds
      # parse the resulting `*)` token as syntax when this branch is reached.
      # `[[ ... == pattern ]]` keeps the same whole-token membership check.
      if [[ "$COMPTIME_ELIDED_MODULES" != *" $mod "* ]]; then
        echo "$mod"
      fi
    fi
  done
)

if [ -z "$forbidden_hits" ]; then
  green "  ✓ no forbidden module is reachable from hello_button"
else
  red "  ✗ hello_button reaches forbidden modules:"
  echo "$forbidden_hits" | while read -r m; do
    red "      $m"
  done
  failures=$((failures + 1))
fi

# -- Audit 2b: comptime-elided modules must truly not in binary --
# Stronger than module graph: validates real contract 'release artifacts have no test harness'. The
# app bundle name is stable, but the executable's name is build-defined.
if ! find "$audit_dir/install/Hello Button.app/Contents/MacOS" -maxdepth 1 -type f -perm -u+x -print >"$audit_dir/executables" 2>/dev/null; then
  red "  ✗ hello_button artifact directory missing"
  exit 1
fi
if [ "$(wc -l <"$audit_dir/executables" | tr -d ' ')" != 1 ]; then
  red "  ✗ expected exactly one hello_button executable"
  exit 1
fi
IFS= read -r hb_exe <"$audit_dir/executables"
if ! nm -a "$hb_exe" >"$audit_dir/symbols" 2>"$audit_dir/nm.err"; then
  red "  ✗ could not inspect executable symbols"
  exit 1
fi
if ! strings "$hb_exe" >"$audit_dir/strings" 2>"$audit_dir/strings.err"; then
  red "  ✗ could not inspect executable strings"
  exit 1
fi
if grep -qi 'test_harness\|http_server\|drainCommands' "$audit_dir/symbols" ||
    grep -qi 'ZENIT_E2E_FILE_RPC_DIR\|zenit_e2e_rpc' "$audit_dir/strings"; then
  red "  ✗ test_harness leaked into shipped binary"
  failures=$((failures + 1))
else
  green "  ✓ test_harness comptime-eliminated from shipped binary"
fi

# ────────────────────────────────────────────────────────────────────────────
# Summary
# ────────────────────────────────────────────────────────────────────────────
bold ""
if [ "$failures" -eq 0 ]; then
  green "✓ zenit open-source boundary is intact."
  exit 0
else
  red "✗ $failures boundary check(s) failed."
  red "  See docs/UI_OSS_BOUNDARY.md for the boundary contract."
  exit 1
fi

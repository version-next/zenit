#!/usr/bin/env bash
# Compile and launch an independent downstream application against both the
# worktree and the exact package tree produced by `zig fetch`. The latter makes
# build.zig.zon's `paths` allowlist part of the test instead of duplicating it
# as a hand-maintained shell list.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d /tmp/zenit-package-consumer.XXXXXX)"
cleanup() {
  case "${TEST_DIR:-}" in
    /tmp/zenit-package-consumer.*) rm -rf -- "${TEST_DIR:?}" ;;
    *) echo "refusing to clean unexpected package-consumer path: ${TEST_DIR:-<empty>}" >&2 ;;
  esac
}
trap cleanup EXIT

ZIG_BIN="${ZIG_BIN:-${ZIG:-zig}}"
ZIG_ARGS=()
if [[ -n "${ZENIT_ZIG_LIB_DIR:-}" ]]; then
  ZIG_ARGS+=(--zig-lib-dir "$ZENIT_ZIG_LIB_DIR")
fi

run_consumer() {
  local matrix_root="$1"
  local matrix_name="$2"
  mkdir -p "$matrix_root/consumer"
  cp -R "$ROOT/tests/package_consumer/." "$matrix_root/consumer/"
  (
    cd "$matrix_root/consumer"
    # Bash 3.2 (the system Bash on macOS) treats expansion of an empty array as
    # an unbound variable under `set -u`. Keep the no-argument path explicit so
    # the release gate works on the oldest shell in our supported environment.
    if (( ${#ZIG_ARGS[@]} > 0 )); then
      "$ZIG_BIN" build "${ZIG_ARGS[@]}"
      if [[ -s ../private-icons/build.zig.zon ]]; then
        "$ZIG_BIN" build "${ZIG_ARGS[@]}" -Dexternal-icons=true
      fi
      if [[ -s ../package/private/zenit-icons-untitled/icons_generated.zig ]]; then
        "$ZIG_BIN" build "${ZIG_ARGS[@]}" -Dicon-set=untitled
      fi
      "$ZIG_BIN" build "${ZIG_ARGS[@]}" -Dtest-mode=true -De2e-port=21991
    else
      "$ZIG_BIN" build
      if [[ -s ../private-icons/build.zig.zon ]]; then
        "$ZIG_BIN" build -Dexternal-icons=true
      fi
      if [[ -s ../package/private/zenit-icons-untitled/icons_generated.zig ]]; then
        "$ZIG_BIN" build -Dicon-set=untitled
      fi
      "$ZIG_BIN" build -Dtest-mode=true -De2e-port=21991
    fi
    test -x zig-out/bin/zenit_package_consumer
    test -s zig-out/share/zenit/harness/client.ts
    grep -q 'startWindowRecording' zig-out/share/zenit/harness/client.ts
    ZENIT_PACKAGE_SMOKE_EXIT=1 zig-out/bin/zenit_package_consumer
  )
  echo "package consumer: $matrix_name PASS"
}

# Path dependency: proves the documented public build API works without using
# zenit's own example wiring.
mkdir -p "$TEST_DIR/direct"
ln -s "$ROOT" "$TEST_DIR/direct/package"
if [[ -s "$ROOT/private/zenit-icons-untitled/build.zig.zon" ]]; then
  ln -s "$ROOT/private/zenit-icons-untitled" "$TEST_DIR/direct/private-icons"
fi
run_consumer "$TEST_DIR/direct" "direct worktree"

# Package dependency: archive the tracked/unignored source tree, then let Zig
# apply the manifest allowlist and copy the result into its real package cache.
# This mirrors a developer's URL/tarball dependency while still testing local
# uncommitted changes.
SOURCE_CANDIDATES="$TEST_DIR/source-candidates"
SOURCE_FILES="$TEST_DIR/source-files"
SOURCE_ARCHIVE="$TEST_DIR/zenit-source.tar"
PACKAGE_CACHE="$TEST_DIR/package-cache"
git -C "$ROOT" ls-files --cached --others --exclude-standard -z > "$SOURCE_CANDIDATES"
: > "$SOURCE_FILES"

while IFS= read -r -d '' source_path; do
  if [[ "$source_path" = /* || "$source_path" == ".." || "$source_path" == ../* || "$source_path" == */../* ]]; then
    echo "unsafe repository path in package source list: $source_path" >&2
    exit 1
  fi
  if [[ ! -e "$ROOT/$source_path" && ! -L "$ROOT/$source_path" ]]; then
    # A dirty worktree may intentionally delete a tracked file. The archive is
    # meant to test the current source state (including that deletion), not the
    # index snapshot. Missing required payload still fails later through the
    # manifest assertions or consumer compile.
    continue
  fi
  printf '%s\0' "$source_path" >> "$SOURCE_FILES"
done < "$SOURCE_CANDIDATES"

tar -C "$ROOT" -cf "$SOURCE_ARCHIVE" --null -T "$SOURCE_FILES"
PACKAGE_HASH="$("$ZIG_BIN" fetch --global-cache-dir "$PACKAGE_CACHE" "$SOURCE_ARCHIVE")"
PACKAGE_ROOT="$PACKAGE_CACHE/p/$PACKAGE_HASH"
if [[ ! -s "$PACKAGE_ROOT/build.zig.zon" ]]; then
  echo "zig fetch did not create the expected package cache entry: $PACKAGE_ROOT" >&2
  exit 1
fi

# Positive and negative assertions prove the manifest, rather than tar itself,
# selected the payload. `vendor` was previously omitted by this test even though
# it is part of the real package.
test -d "$PACKAGE_ROOT/vendor"
test -s "$PACKAGE_ROOT/e2e/client.ts"
test ! -e "$PACKAGE_ROOT/.github"
test ! -e "$PACKAGE_ROOT/docs/internal"
test ! -e "$PACKAGE_ROOT/private"

# Prove the public package is self-contained even though the consumer manifest
# also declares an optional private path dependency. Zig must not resolve that
# dependency unless the external-provider profile is selected.
mkdir -p "$TEST_DIR/public-only"
ln -s "$PACKAGE_ROOT" "$TEST_DIR/public-only/package"
run_consumer "$TEST_DIR/public-only" "public package without private provider"

mkdir -p "$TEST_DIR/archive"
ln -s "$PACKAGE_ROOT" "$TEST_DIR/archive/package"
if [[ -s "$ROOT/private/zenit-icons-untitled/build.zig.zon" ]]; then
  ln -s "$ROOT/private/zenit-icons-untitled" "$TEST_DIR/archive/private-icons"
fi
run_consumer "$TEST_DIR/archive" "zig fetch package cache"

echo "package consumer matrix: PASS (direct, public-only, private provider, launch smoke)"

#!/usr/bin/env bash
# Build a clean, redistributable Zenit source tree from build.zig.zon's
# authoritative package allowlist. The current working tree is exported, so
# reviewed uncommitted changes are included while ignored/private files are not.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
DIST_PARENT="$ROOT/dist"
ZIG_BIN="${ZIG:-zig}"
FORCE=0
RUN_SMOKE_BUILD=1

usage() {
  cat <<'EOF'
Usage: bash scripts/build_oss_dist.sh [--force] [--skip-build]

Create dist/zenit-<version>/ containing the public Zig source package selected
by build.zig.zon. The result has no Git metadata, caches, internal docs, private
icons, or build outputs and can be zipped as-is.

Options:
  --force       Replace an existing dist directory for the same version.
  --skip-build  Skip the final `zig build hello-button` source smoke test.
  -h, --help    Show this help.

Environment:
  ZIG            Zig executable to use (default: zig).
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --force) FORCE=1 ;;
    --skip-build) RUN_SMOKE_BUILD=0 ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

need_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "required command not found: $1" >&2
    exit 1
  fi
}

need_command git
need_command tar
need_command "$ZIG_BIN"

if [[ ! -s "$ROOT/build.zig.zon" || ! -s "$ROOT/build.zig" ]]; then
  echo "repository manifest/build file is missing under $ROOT" >&2
  exit 1
fi

VERSION_LINES="$(sed -nE 's/^[[:space:]]*\.version = "([^"]+)",[[:space:]]*$/\1/p' "$ROOT/build.zig.zon")"
VERSION_COUNT="$(printf '%s\n' "$VERSION_LINES" | sed '/^$/d' | wc -l | tr -d ' ')"
if [[ "$VERSION_COUNT" != 1 ]]; then
  echo "build.zig.zon must declare exactly one package version" >&2
  exit 1
fi
VERSION="$VERSION_LINES"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?(\+[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$ ]]; then
  echo "unsafe or invalid package version: $VERSION" >&2
  exit 1
fi

OUTPUT_DIR="$DIST_PARENT/zenit-$VERSION"
STAGING_DIR="$DIST_PARENT/.zenit-$VERSION.staging.$$"
WORK_DIR="$(mktemp -d /tmp/zenit-oss-dist.XXXXXX)"

cleanup() {
  case "${WORK_DIR:-}" in
    /tmp/zenit-oss-dist.*) rm -rf -- "${WORK_DIR:?}" ;;
    *) echo "refusing to clean unexpected temporary path: ${WORK_DIR:-<empty>}" >&2 ;;
  esac
  case "${STAGING_DIR:-}" in
    "$DIST_PARENT"/.zenit-*.staging.*)
      if [[ -e "$STAGING_DIR" || -L "$STAGING_DIR" ]]; then
        rm -rf -- "${STAGING_DIR:?}"
      fi
      ;;
    *) echo "refusing to clean unexpected staging path: ${STAGING_DIR:-<empty>}" >&2 ;;
  esac
}
trap cleanup EXIT

if [[ -e "$OUTPUT_DIR" || -L "$OUTPUT_DIR" ]]; then
  if (( FORCE == 0 )); then
    echo "output already exists: $OUTPUT_DIR" >&2
    echo "rerun with --force to replace this exact version directory" >&2
    exit 1
  fi
  if [[ -L "$OUTPUT_DIR" || ! -d "$OUTPUT_DIR" ]]; then
    echo "refusing to replace output that is not a real directory: $OUTPUT_DIR" >&2
    exit 1
  fi
fi

mkdir -p "$DIST_PARENT"
if [[ -e "$STAGING_DIR" || -L "$STAGING_DIR" ]]; then
  echo "staging path unexpectedly exists: $STAGING_DIR" >&2
  exit 1
fi
mkdir "$STAGING_DIR"

SOURCE_CANDIDATES="$WORK_DIR/source-candidates"
SOURCE_FILES="$WORK_DIR/source-files"
SOURCE_ARCHIVE="$WORK_DIR/zenit-source.tar"
PACKAGE_CACHE="$WORK_DIR/package-cache"

echo "==> Selecting tracked and unignored working-tree files"
git -C "$ROOT" ls-files --cached --others --exclude-standard -z > "$SOURCE_CANDIDATES"
: > "$SOURCE_FILES"

while IFS= read -r -d '' source_path; do
  if [[ -z "$source_path" || "$source_path" = /* || "$source_path" == ".." || "$source_path" == ../* || "$source_path" == */../* ]]; then
    echo "unsafe repository path in source list: ${source_path:-<empty>}" >&2
    exit 1
  fi
  if [[ ! -e "$ROOT/$source_path" && ! -L "$ROOT/$source_path" ]]; then
    # Preserve current-working-tree semantics when a tracked file is deleted.
    continue
  fi
  if [[ -L "$ROOT/$source_path" ]]; then
    echo "symbolic links are not allowed in the public source export: $source_path" >&2
    exit 1
  fi
  if [[ -d "$ROOT/$source_path" ]]; then
    echo "directory/gitlink cannot be exported as a source file: $source_path" >&2
    exit 1
  fi
  printf '%s\0' "$source_path" >> "$SOURCE_FILES"
done < "$SOURCE_CANDIDATES"

# COPYFILE_DISABLE: macOS tar would otherwise add AppleDouble "._*" files
# carrying local extended attributes (quarantine, provenance) for every file.
COPYFILE_DISABLE=1 tar -C "$ROOT" -cf "$SOURCE_ARCHIVE" --null -T "$SOURCE_FILES"

echo "==> Applying build.zig.zon's public package allowlist"
PACKAGE_HASH="$("$ZIG_BIN" fetch --global-cache-dir "$PACKAGE_CACHE" "$SOURCE_ARCHIVE")"
if [[ ! "$PACKAGE_HASH" =~ ^[0-9A-Za-z][0-9A-Za-z._+-]*$ || "$PACKAGE_HASH" == *..* ]]; then
  echo "zig fetch returned an unsafe package hash: ${PACKAGE_HASH:-<empty>}" >&2
  exit 1
fi
PACKAGE_ROOT="$PACKAGE_CACHE/p/$PACKAGE_HASH"
if [[ ! -s "$PACKAGE_ROOT/build.zig.zon" ]]; then
  echo "zig fetch did not create the expected package tree: $PACKAGE_ROOT" >&2
  exit 1
fi

cp -R "$PACKAGE_ROOT/." "$STAGING_DIR/"

# Zig's package cache is immutable. A source archive should extract into a
# normal editable tree with predictable portable permissions.
find "$STAGING_DIR" -type d -exec chmod 0755 {} +
find "$STAGING_DIR" -type f -exec chmod 0644 {} +
find "$STAGING_DIR/scripts" -type f -name '*.sh' -exec chmod 0755 {} +

echo "==> Auditing the staged open-source tree"
required_paths=(
  LICENSE
  LICENSING.md
  CLA.md
  templates/LICENSE
  examples/LICENSE
  build.zig
  build.zig.zon
  src/ui/icons_oss/LICENSE
  src/ui/icons_lucide_generated.zig
  src/ui/icons_common_generated.zig
  vendor/unicode/LICENSE.txt
)
for required_path in "${required_paths[@]}"; do
  if [[ ! -s "$STAGING_DIR/$required_path" ]]; then
    echo "required public source/license is missing: $required_path" >&2
    exit 1
  fi
done

for forbidden_path in \
  private .git .github .zig-cache zig-cache zig-out .bench-output \
  .ci-evidence release-evidence docs/internal; do
  if [[ -e "$STAGING_DIR/$forbidden_path" || -L "$STAGING_DIR/$forbidden_path" ]]; then
    echo "forbidden path leaked into public source export: $forbidden_path" >&2
    exit 1
  fi
done

BAD_PATH="$(find "$STAGING_DIR" \
  \( -name '.DS_Store' -o -name '._*' -o -name '.env' -o -name '.env.*' \
     -o -name '*.pyc' -o -name '*.pyo' -o -name '*.swp' -o -name '*.swo' \
     -o -name '*.log' -o -name '*.o' -o -name '*.a' -o -name '*.dylib' \
     -o -name '*.so' -o -name '*.dSYM' \) -print -quit)"
if [[ -n "$BAD_PATH" ]]; then
  echo "generated/private/build artifact leaked into public source: ${BAD_PATH#"$STAGING_DIR/"}" >&2
  exit 1
fi

SYMLINK_PATH="$(find "$STAGING_DIR" -type l -print -quit)"
if [[ -n "$SYMLINK_PATH" ]]; then
  echo "symbolic link leaked into public source: ${SYMLINK_PATH#"$STAGING_DIR/"}" >&2
  exit 1
fi

SECRET_SCAN_STATUS=0
grep -RIlE \
  'BEGIN (RSA |OPENSSH |EC |DSA )?PRIVATE KEY|AKIA[0-9A-Z]{16}|ghp_[0-9A-Za-z]{20,}|github_pat_[0-9A-Za-z_]{20,}|sk-[0-9A-Za-z]{20,}' \
  "$STAGING_DIR" > "$WORK_DIR/secret-hits" || SECRET_SCAN_STATUS=$?
case "$SECRET_SCAN_STATUS" in
  0)
    echo "possible credential/private key found in public source:" >&2
    sed "s#^$STAGING_DIR/##" "$WORK_DIR/secret-hits" >&2
    exit 1
    ;;
  1) ;;
  *)
    echo "credential scan failed with status $SECRET_SCAN_STATUS" >&2
    exit 1
    ;;
esac

(
  cd "$STAGING_DIR"
  bash scripts/check_oss_icon_license.sh
)

if (( RUN_SMOKE_BUILD == 1 )); then
  echo "==> Compiling the public-default hello-button target"
  (
    cd "$STAGING_DIR"
    "$ZIG_BIN" build hello-button -Dicon-set=lucide \
      --cache-dir "$WORK_DIR/smoke-cache" \
      --global-cache-dir "$WORK_DIR/smoke-global-cache" \
      --prefix "$WORK_DIR/smoke-out" \
      --summary none
  )
else
  echo "==> Skipping compile smoke test (--skip-build)"
fi

if [[ -e "$OUTPUT_DIR" || -L "$OUTPUT_DIR" ]]; then
  # OUTPUT_DIR is constructed above from a validated semver and fixed parent.
  echo "==> Replacing existing output: $OUTPUT_DIR"
  rm -rf -- "${OUTPUT_DIR:?}"
fi
mv "$STAGING_DIR" "$OUTPUT_DIR"

FILE_COUNT="$(find "$OUTPUT_DIR" -type f | wc -l | tr -d ' ')"
echo
echo "OSS source dist ready: $OUTPUT_DIR"
echo "Files: $FILE_COUNT"
echo "Zip it with:"
echo "  cd '$DIST_PARENT' && zip -qr 'zenit-$VERSION.zip' 'zenit-$VERSION'"

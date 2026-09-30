#!/usr/bin/env bash
# Keep the package identity, toolchain, and release tag aligned with build.zig.zon.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

manifest_version_lines="$(sed -nE 's/^[[:space:]]*\.version = "([^"]+)",[[:space:]]*$/\1/p' build.zig.zon)"
manifest_version_count="$(printf '%s\n' "$manifest_version_lines" | sed '/^$/d' | wc -l | tr -d ' ')"
if [[ "$manifest_version_count" != 1 ]]; then
  echo "build.zig.zon must declare exactly one package version" >&2
  exit 1
fi
manifest_version="$manifest_version_lines"

semver_pattern='^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?(\+[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$'
if [[ ! "$manifest_version" =~ $semver_pattern ]]; then
  echo "build.zig.zon version is not valid semver: $manifest_version" >&2
  exit 1
fi

expected_fingerprint="0xd8a68ba39878e4d7"
manifest_fingerprint="$(sed -nE 's/^[[:space:]]*\.fingerprint = ([^,]+),[[:space:]]*$/\1/p' build.zig.zon)"
if [[ "$manifest_fingerprint" != "$expected_fingerprint" ]]; then
  echo "package fingerprint changed: expected $expected_fingerprint, got ${manifest_fingerprint:-<missing>}" >&2
  exit 1
fi

minimum_zig_version="$(sed -nE 's/^[[:space:]]*\.minimum_zig_version = "([^"]+)",[[:space:]]*$/\1/p' build.zig.zon)"
if [[ -z "$minimum_zig_version" ]]; then
  echo "build.zig.zon minimum_zig_version is missing" >&2
  exit 1
fi
if ! rg -q "^[[:space:]]+version: ${minimum_zig_version//./\.}$" .github/workflows/ci.yml; then
  echo "CI Zig version does not match build.zig.zon's $minimum_zig_version" >&2
  exit 1
fi

tag_name=""
if [[ "${GITHUB_REF_TYPE:-}" == "tag" ]]; then
  tag_name="${GITHUB_REF_NAME:-}"
elif [[ "${GITHUB_REF:-}" == refs/tags/* ]]; then
  tag_name="${GITHUB_REF#refs/tags/}"
fi
if [[ -n "$tag_name" && "$tag_name" != "v$manifest_version" ]]; then
  echo "release tag $tag_name does not match manifest version v$manifest_version" >&2
  exit 1
fi

echo "version contract: PASS (v$manifest_version, Zig $minimum_zig_version)"

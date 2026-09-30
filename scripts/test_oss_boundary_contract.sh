#!/usr/bin/env bash
# Exercise release evidence failures in an isolated synthetic repository.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
fixture=$(mktemp -d -t zenit_boundary_contract.XXXXXX)
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/scripts" "$fixture/src/ui" "$fixture/bin" "$fixture/.zig-cache/o"
cp "$repo/scripts/check_oss_boundary.sh" "$fixture/scripts/"
printf '@import("std")\n' >"$fixture/src/ui/root.zig"
printf 'developer cache\n' >"$fixture/.zig-cache/o/sentinel"
cat >"$fixture/bin/zig" <<'MOCK'
#!/usr/bin/env bash
set -eu
prefix=
cache=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --prefix) prefix=$2; shift ;;
    --cache-dir) cache=$2; shift ;;
  esac
  shift
done
[[ -n "$prefix" && -n "$cache" ]] || exit 2
[[ "$cache" != '.zig-cache' ]] || exit 3
[[ "$CASE" != build-failure ]] || exit 1
[[ "$CASE" == no-modules ]] || echo '-Mroot=src/main.zig -Mstd=std.zig'
[[ "$CASE" != forbidden ]] || echo '-Mworkspace=workspace.zig'
[[ "$CASE" != missing-binary ]] || exit 0
mkdir -p "$prefix/Hello Button.app/Contents/MacOS"
printf 'fixture\n' >"$prefix/Hello Button.app/Contents/MacOS/hello_button"
chmod +x "$prefix/Hello Button.app/Contents/MacOS/hello_button"
MOCK
cat >"$fixture/bin/nm" <<'MOCK'
#!/usr/bin/env bash
[[ "$CASE" != nm-failure ]] || exit 1
[[ "$CASE" != symbol-leak ]] || echo 'test_harness'
exit 0
MOCK
cat >"$fixture/bin/strings" <<'MOCK'
#!/usr/bin/env bash
[[ "$CASE" != strings-failure ]] || exit 1
[[ "$CASE" != string-leak ]] || echo 'zenit_e2e_rpc'
exit 0
MOCK
chmod +x "$fixture/bin/"*
for scenario in success build-failure no-modules missing-binary nm-failure strings-failure forbidden symbol-leak string-leak; do
  status=0
  CASE="$scenario" PATH="$fixture/bin:$PATH" bash "$fixture/scripts/check_oss_boundary.sh" >"$fixture/result" 2>&1 || status=$?
  if [[ "$scenario" == success ]]; then
    if [[ "$status" != 0 ]]; then cat "$fixture/result"; exit 1; fi
  elif [[ "$status" == 0 ]]; then
    echo "accepted missing/invalid evidence: $scenario" >&2
    cat "$fixture/result"
    exit 1
  fi
  [[ -f "$fixture/.zig-cache/o/sentinel" ]] || { echo 'destroyed developer cache'; exit 1; }
  echo "PASS: $scenario"
done

#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

TEST_DIR="$(mktemp -d /tmp/zenit-bench-contract.XXXXXX)"
trap 'rm -rf -- "$TEST_DIR"' EXIT

write_result() {
    local path="$1" min_ns="$2"
    jq -n --argjson min_ns "$min_ns" '{results:[{
        name:"probe",
        median_ns:$min_ns,
        p95_ns:$min_ns,
        min_ns:$min_ns,
        mean_ns:$min_ns,
        samples:1,
        iters_per_sample:1
    }]}' >"$path"
}

write_result "$TEST_DIR/baseline.json" 100
write_result "$TEST_DIR/current-noise.json" 150
write_result "$TEST_DIR/current-regression.json" 10000

NOISE_FLOOR_NS=200 bash scripts/check_bench_regression.sh \
    "$TEST_DIR/baseline.json" "$TEST_DIR/current-noise.json" 15 >/dev/null

if NOISE_FLOOR_NS=200 bash scripts/check_bench_regression.sh \
    "$TEST_DIR/baseline.json" "$TEST_DIR/current-regression.json" 15 >/dev/null 2>&1; then
    echo "benchmark contract accepted a 100ns -> 10us regression below the old baseline floor" >&2
    exit 1
fi

echo "benchmark noise-floor regression contract: PASS"

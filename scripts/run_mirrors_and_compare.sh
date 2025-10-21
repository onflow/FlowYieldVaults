#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="$ROOT_DIR/local"
mkdir -p "$LOG_DIR"

run_test_capture() {
  local test_file="$1"
  local out_file="$2"
  if command -v flow >/dev/null 2>&1; then
    flow test -f "$ROOT_DIR/flow.tests.json" "$test_file" | tee "$out_file"
  else
    echo "flow CLI not found; please install Flow CLI." >&2
    exit 1
  fi
}

run_test_capture "$ROOT_DIR/cadence/tests/flow_flash_crash_mirror_test.cdc" "$LOG_DIR/mirror_flow.log"
run_test_capture "$ROOT_DIR/cadence/tests/moet_depeg_mirror_test.cdc" "$LOG_DIR/mirror_moet.log"
run_test_capture "$ROOT_DIR/cadence/tests/rebalance_liquidity_mirror_test.cdc" "$LOG_DIR/mirror_rebalance.log"

python3 "$ROOT_DIR/scripts/generate_mirror_report.py"
echo "Report updated: $ROOT_DIR/docs/mirror_report.md"



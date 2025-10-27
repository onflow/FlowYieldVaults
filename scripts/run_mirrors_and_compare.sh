#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="$ROOT_DIR/local"
mkdir -p "$LOG_DIR"

run_test_capture() {
  local test_file="$1"
  local out_file="$2"
  if command -v flow >/dev/null 2>&1; then
    # Capture full output even if Flow CLI shows crash prompt; don't fail the script on non-zero exit
    CI=true TERM=dumb FLOW_INTEGRATION_TEST=1 flow test --skip-version-check -y -f "$ROOT_DIR/flow.tests.json" "$test_file" > "$out_file" 2>&1 || true
  else
    echo "flow CLI not found; please install Flow CLI." >&2
    exit 1
  fi
}

# Run rebalance first to ensure MIRROR logs captured before any CLI crash prompt
for attempt in {1..3}; do
  run_test_capture "$ROOT_DIR/cadence/tests/rebalance_liquidity_mirror_test.cdc" "$LOG_DIR/mirror_rebalance.log"
  if grep -q "MIRROR:" "$LOG_DIR/mirror_rebalance.log"; then
    break
  else
    echo "Retrying rebalance test (attempt $attempt) due to missing MIRROR logs"
  fi
done
run_test_capture "$ROOT_DIR/cadence/tests/flow_flash_crash_mirror_test.cdc" "$LOG_DIR/mirror_flow.log"
run_test_capture "$ROOT_DIR/cadence/tests/moet_depeg_mirror_test.cdc" "$LOG_DIR/mirror_moet.log"

python3 "$ROOT_DIR/scripts/generate_mirror_report.py"
echo "Report updated: $ROOT_DIR/docs/mirror_report.md"



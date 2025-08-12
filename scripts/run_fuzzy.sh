#!/usr/bin/env bash
set -euo pipefail

# Resolve repo root
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

ts() { date +"%Y%m%d_%H%M%S"; }
ARCHIVE_DIR="$ROOT/archives/fuzzy_run_$(ts)"

echo "[fuzzy] Archiving previous artifacts to: $ARCHIVE_DIR"
mkdir -p "$ARCHIVE_DIR/csv" "$ARCHIVE_DIR/tests" "$ARCHIVE_DIR/reports"

# Archive existing CSVs
if find "$ROOT" -maxdepth 1 -name 'Scenario*.csv' | grep -q .; then
  find "$ROOT" -maxdepth 1 -name 'Scenario*.csv' -exec mv {} "$ARCHIVE_DIR/csv/" \;
fi

# Archive existing generated tests (keep legacy tests)
TEST_DIR="$ROOT/cadence/tests"
gen_patterns=(
  'rebalance_scenario1_flow_test.cdc'
  'rebalance_scenario2_instant_test.cdc'
  'rebalance_scenario3_path_*_test.cdc'
  'rebalance_scenario4_volatilemarkets_test.cdc'
  'rebalance_scenario5_gradualtrends_test.cdc'
  'rebalance_scenario6_edgecases_test.cdc'
  'rebalance_scenario7_multisteppaths_*_test.cdc'
  'rebalance_scenario8_randomwalks_test.cdc'
  'rebalance_scenario9_extremeshocks_*_test.cdc'
)
for pat in "${gen_patterns[@]}"; do
  if find "$TEST_DIR" -maxdepth 1 -name "$pat" | grep -q .; then
    find "$TEST_DIR" -maxdepth 1 -name "$pat" -exec mv {} "$ARCHIVE_DIR/tests/" \;
  fi
done

# Archive previous drift report
REPORT_FILE="$ROOT/precision_reports/UNIFIED_FUZZY_DRIFT_REPORT.md"
if [ -f "$REPORT_FILE" ]; then
  mv "$REPORT_FILE" "$ARCHIVE_DIR/reports/" || true
fi

echo "[fuzzy] Ensuring Python environment (pandas)"
if [ -d "$ROOT/.venv" ]; then
  # shellcheck disable=SC1091
  source "$ROOT/.venv/bin/activate"
else
  python3 -m venv "$ROOT/.venv"
  # shellcheck disable=SC1091
  source "$ROOT/.venv/bin/activate"
fi
python3 -m pip install --quiet --upgrade pip pandas

echo "[fuzzy] Generating CSVs"
python3 "$ROOT/tidal_simulator.py"

echo "[fuzzy] Generating Cadence tests"
python3 "$ROOT/generate_cadence_tests.py"

echo "[fuzzy] Building drift report"
python3 "$ROOT/precision_reports/generate_drift_report.py"

echo "[fuzzy] Done. CSVs in repo root. Tests in cadence/tests. Report at precision_reports/UNIFIED_FUZZY_DRIFT_REPORT.md"


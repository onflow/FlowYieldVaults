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
  'rebalance_scenario7_multisteppaths_test.cdc'
  'rebalance_scenario8_randomwalks_test.cdc'
  'rebalance_scenario8_randomwalks_*_test.cdc'
  'rebalance_scenario9_extremeshocks_*_test.cdc'
  'rebalance_scenario9_extremeshocks_test.cdc'
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

# Split Scenario 8 walks into independent CSVs (Walk0..4)
python3 - << 'PY'
import pandas as pd
from pathlib import Path
root = Path('.').resolve()
p = root / 'Scenario8_RandomWalks.csv'
if p.exists():
    df = pd.read_csv(p)
    if 'WalkID' in df.columns:
        for walk_id in sorted(df['WalkID'].unique()):
            sub = df[df['WalkID'] == walk_id]
            out = root / f'Scenario8_RandomWalks_Walk{int(walk_id)}.csv'
            sub.to_csv(out, index=False)
            print(f"[fuzzy] Wrote {out}")
PY

echo "[fuzzy] Generating Cadence tests"
python3 "$ROOT/generate_cadence_tests.py"

echo "[fuzzy] Building drift report"
python3 "$ROOT/precision_reports/generate_drift_report.py"

echo "[fuzzy] Done. CSVs in repo root. Tests in cadence/tests. Report at precision_reports/UNIFIED_FUZZY_DRIFT_REPORT.md"


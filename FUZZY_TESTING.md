### Fuzzy Testing Framework

This document explains how to generate scenario CSVs, build Cadence tests, run them, and produce a precision drift report. It also summarizes the current state and precision expectations.

### What it does

- Generates deterministic scenario CSVs for unified fuzzy testing (Scenarios 1–9, compact numbering) via `tidal_simulator.py`.
- Converts CSVs into Cadence tests (`cadence/tests/rebalance_*.cdc`) via `generate_cadence_tests.py` with strict comparisons at ±0.0000001.
- Emits machine-parsable DRIFT logs from tests and aggregates them into `precision_reports/UNIFIED_FUZZY_DRIFT_REPORT.md`.

### Prerequisites

- Python 3.11+
- Flow CLI installed and available as `flow`

Optional: venv for Python packages (pandas).

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install pandas
```

### Generate scenario CSVs

```bash
python3 tidal_simulator.py
```

Outputs the following CSV files in the repo root (compact numbering, with splits):
- Scenario1_FLOW.csv
- Scenario2_Instant.csv
- Scenario3_Path_{A,B,C,D}_precise.csv
- Scenario4_VolatileMarkets.csv
- Scenario5_GradualTrends.csv
- Scenario6_EdgeCases.csv
- Scenario7_MultiStepPaths_{Bear,Bull,Sideways,Crisis}.csv
- Scenario8_RandomWalks.csv
- Scenario9_ExtremeShocks_{FlashCrash,Rebound,YieldHyperInflate,MixedShock}.csv

### Generate Cadence tests

```bash
python3 generate_cadence_tests.py
```

Outputs Cadence tests directly into `cadence/tests/` with names like:
- rebalance_scenario1_flow_test.cdc
- rebalance_scenario2_instant_test.cdc
- rebalance_scenario3_path_{a,b,c,d}_test.cdc
- rebalance_scenario4_volatilemarkets_test.cdc
- rebalance_scenario5_gradualtrends_test.cdc
- rebalance_scenario6_edgecases_test.cdc
- rebalance_scenario7_multisteppaths_{bear,bull,sideways,crisis}_test.cdc
- rebalance_scenario8_randomwalks_test.cdc
- rebalance_scenario9_extremeshocks_{flashcrash,rebound,yieldhyperinflate,mixedshock}_test.cdc

Notes:
- Scaling table is removed from CSV outputs; compact numbering starts at VolatileMarkets for Scenario 4.
- All tests use exact comparisons with tolerance 0.0000001 and 8-decimal formatting.
- Scenario 1 generated test asserts post-rebalance values for each price point to match CSV expectations.
- Legacy tests remain intact (rebalance_scenario{1,2}_test.cdc and 3a–3d).

### Run tests

Run an individual scenario:
```bash
flow test cadence/tests/rebalance_scenario1_flow_test.cdc
```

Run multiple scenarios (example 4–9):
```bash
for f in \
  cadence/tests/rebalance_scenario4_volatilemarkets_test.cdc \
  cadence/tests/rebalance_scenario5_gradualtrends_test.cdc \
  cadence/tests/rebalance_scenario6_edgecases_test.cdc \
  cadence/tests/rebalance_scenario7_multisteppaths_*_test.cdc \
  cadence/tests/rebalance_scenario8_randomwalks_test.cdc \
  cadence/tests/rebalance_scenario9_extremeshocks_*_test.cdc; do
  echo "\n=== RUN $f ==="; flow test "$f" | cat;
done
```

### Generate precision drift report

Tests emit DRIFT logs in the form:
```
DRIFT|<Label>|<step>|<actualDebt>|<expectedDebt>|<actualY>|<expectedY>|<actualColl>|<expectedColl>
```

Aggregate these into a markdown report:
```bash
python3 precision_reports/generate_drift_report.py
```

Report path: `precision_reports/UNIFIED_FUZZY_DRIFT_REPORT.md`

### One-command shortcut

Use the provided script to archive old artifacts, regenerate CSVs and tests, and rebuild the drift report in one go:

```bash
bash scripts/run_fuzzy.sh
```

What it does:
- Archives previous Scenario*.csv, generated test files, and the last drift report under `archives/fuzzy_run_<timestamp>/`.
- Ensures a venv with pandas is ready.
- Runs the simulator, test generator, and drift report builder end to end.

### Current status and interpretation

- Precision target: ±0.0000001 for all asserted values (debt, yield units, collateral).
- Scenarios 1–3: generated tests align with legacy expectations under strict precision.
- Some later steps in Scenarios 4–9 exhibit larger deltas in the drift report. These are due to step-order/semantics mismatches between the CSV action sequencing and on-chain rebalancing (e.g., when to rebalance tide vs protocol), not formula changes. Tolerances remain unchanged.

### Files of interest

- `tidal_simulator.py`: generates CSVs with shared formulas across scenarios (collateral × CF ÷ targetHealth; balancer sell-to-debt at 1.05× threshold).
- `generate_cadence_tests.py`: maps CSVs to tests, with Scenario 1 using immediate post-rebalance semantics; embeds DRIFT logs and strict comparisons.
- `cadence/tests/test_helpers.cdc`: helpers used by tests.
- `precision_reports/generate_drift_report.py`: runs selected tests (including split S7/S9) and produces the drift report.

### Troubleshooting

- If tests fail at step 0 with large deltas, verify CSV action ordering versus the generator’s step execution order for that scenario.
- Ensure Flow CLI is installed and contracts deploy in test setup (handled by generated test header’s `setup()`).



### Fuzzy Testing Framework

This document explains how to generate scenario CSVs, build Cadence tests, run them, and produce a precision drift report. It also summarizes the current state and precision expectations.

### What it does

- Generates deterministic scenario CSVs for unified fuzzy testing (Scenarios 1–10) via `tidal_simulator.py`.
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

Outputs the following CSV files in the repo root:
- Scenario1_FLOW.csv
- Scenario2_Instant.csv
- Scenario3_Path_{A,B,C,D}_precise.csv
- Scenario4_Scaling.csv (intentionally skipped by test generator)
- Scenario5_VolatileMarkets.csv
- Scenario6_GradualTrends.csv
- Scenario7_EdgeCases.csv
- Scenario8_MultiStepPaths.csv
- Scenario9_RandomWalks.csv
- Scenario10_ExtremeShocks.csv

### Generate Cadence tests

```bash
python3 generate_cadence_tests.py
```

Outputs Cadence tests directly into `cadence/tests/` with names like:
- rebalance_scenario1_flow_test.cdc
- rebalance_scenario2_instant_test.cdc
- rebalance_scenario3_path_{a,b,c,d}_test.cdc
- rebalance_scenario4_volatilemarkets_test.cdc  (renumbered from 5)
- rebalance_scenario5_gradualtrends_test.cdc    (renumbered from 6)
- rebalance_scenario6_edgecases_test.cdc        (renumbered from 7)
- rebalance_scenario7_multisteppaths_test.cdc   (renumbered from 8)
- rebalance_scenario8_randomwalks_test.cdc      (renumbered from 9)
- rebalance_scenario9_extremeshocks_test.cdc    (renumbered from 10)

Notes:
- Scenario 4 (Scaling) is intentionally excluded from the suite because it requires per-row resets; all other scenarios evolve state across steps.
- All tests use exact comparisons with tolerance 0.0000001 and 8-decimal formatting.
- Step 0 ordering matches the simulator: open at baseline (1.0/1.0), set step-0 prices, replay CSV actions, then assert.

### Run tests

Run an individual scenario:
```bash
flow test cadence/tests/rebalance_scenario1_flow_test.cdc
```

Run multiple scenarios (example 4–9):
```bash
for f in cadence/tests/rebalance_scenario{4,5,6,7,8,9}_*.cdc; do
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
- Scenarios 1–3: match legacy expectations under strict precision.
- Scenarios 4–9: after step-0 ordering fix, some cases still show larger deltas (not rounding-only). These indicate semantic ordering differences between CSV expectations and on-chain rebalancing sequences, not a change in formulas.

Action items:
- Use the drift report to pinpoint step labels where deltas are large and adjust simulator/generator action order if needed.
- Keep Scenario 4 excluded unless per-row snapshots are introduced.

### Files of interest

- `tidal_simulator.py`: generates CSVs with shared formulas across scenarios (collateral × CF ÷ targetHealth; balancer sell-to-debt at 1.05× threshold).
- `generate_cadence_tests.py`: builds tests from CSVs, embeds DRIFT logs, strict comparisons.
- `cadence/tests/test_helpers.cdc`: helpers used by tests.
- `precision_reports/generate_drift_report.py`: runs selected tests and produces the drift report.

### Troubleshooting

- If tests fail at step 0 with large deltas, verify CSV action ordering versus the generator’s step execution order for that scenario.
- Ensure Flow CLI is installed and contracts deploy in test setup (handled by generated test header’s `setup()`).



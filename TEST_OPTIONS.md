# Tidal Protocol Test Options

The `run_all_tests.sh` script now supports various test modes to reduce output size and focus on specific scenarios.

## Quick Start

```bash
# Run happy path tests (quick, ~2 min)
./run_all_tests.sh --happy-path

# Run full test suite (default, ~10 min)
./run_all_tests.sh --full

# Run only verification on existing logs
./run_all_tests.sh --verify
```

## Available Options

### `--happy-path` (Recommended for Quick Testing)
Runs only basic scenarios with common values. This produces a much smaller log file and completes in ~2 minutes.

**Tests included:**
- Baseline operation at 1.0 MOET
- Small price movements (±20%)
- Moderate price movements (0.5x to 2x)
- Basic auto-balancer behavior

**Log files:**
- `happy_path_test_output.log` (~50KB)
- `clean_happy_path_output.log` (~30KB)

### `--full` (Default)
Runs all 10 comprehensive test scenarios. This is the default behavior if no option is specified.

**Tests included:**
- All preset scenarios (extreme, gradual, volatile)
- Edge cases (zero, micro, extreme prices)
- Market scenarios (crashes, recoveries, oscillations)
- Special cases (MOET depeg, concurrent rebalancing)
- Mixed scenarios with independent price movements

**Log files:**
- `fresh_test_output.log` (~400KB)
- `clean_test_output.log` (~230KB)

### `--preset`
Runs only the preset scenarios (extreme, gradual, volatile price movements).

**Log files:**
- `preset_test_output.log`
- `clean_preset_output.log`

### `--edge`
Runs only edge case tests including:
- Zero and micro prices (0.00000001)
- Extreme prices (1000x)
- Black swan events (99% crash)

**Log files:**
- `edge_test_output.log`
- `clean_edge_output.log`

### `--mixed`
Runs only mixed scenario tests including:
- MOET depeg scenario
- Concurrent rebalancing
- Mixed auto-borrow + auto-balancer
- Inverse correlations
- Decorrelated movements

**Log files:**
- `mixed_test_output.log`
- `clean_mixed_output.log`

### `--verify`
Runs only the verification suite on existing clean log files. This is useful when you want to re-analyze existing test results without running the tests again.

### `--skip-verify`
Can be combined with any test mode to skip the verification step after tests complete. This saves time if you only need the test output.

## Examples

```bash
# Quick development testing
./run_all_tests.sh --happy-path

# Test specific scenarios without verification
./run_all_tests.sh --preset --skip-verify
./run_all_tests.sh --edge --skip-verify

# Re-run verification on existing logs
./run_all_tests.sh --verify

# Full comprehensive testing (default)
./run_all_tests.sh
# or
./run_all_tests.sh --full
```

## Output Sizes

| Mode | Raw Log Size | Clean Log Size | Test Duration |
|------|--------------|----------------|---------------|
| Happy Path | ~50KB | ~30KB | ~2 min |
| Preset | ~150KB | ~90KB | ~3 min |
| Edge | ~100KB | ~60KB | ~2 min |
| Mixed | ~120KB | ~70KB | ~3 min |
| Full | ~400KB | ~230KB | ~10 min |

## Verification Outputs

All test modes (except when using `--skip-verify`) generate the following verification files:
- `verification_results.json` - Calculation accuracy checks
- `deep_verification_report.json` - Protocol behavior analysis
- `mathematical_analysis.json` - Financial metrics verification
- `mixed_scenario_analysis.json` - Mixed scenario specific analysis 
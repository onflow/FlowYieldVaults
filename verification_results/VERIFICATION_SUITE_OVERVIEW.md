# Tidal Protocol Verification Suite Overview

This directory contains a comprehensive suite of verification scripts designed to analyze test outputs and ensure protocol correctness.

## File Organization

All verification scripts are properly located in `/tidal-sc/verification_results/`:

### Core Verification Scripts

1. **`verify_calculations.py`** (16KB)
   - Purpose: Verifies mathematical correctness of all calculations
   - Checks: Health ratios, balance changes, interest calculations
   - Output: `verification_results.json`
   - Usage: `python3 verify_calculations.py <log_file>`

2. **`deep_verify.py`** (18KB)
   - Purpose: Deep analysis of protocol behavior and edge cases
   - Checks: Rebalancing effectiveness, health bounds, position states
   - Output: `deep_verification_report.json`
   - Usage: `python3 deep_verify.py <log_file>`

3. **`mathematical_analysis.py`** (16KB)
   - Purpose: Financial calculations and price impact analysis
   - Checks: Price correlations, rebalancing impacts, liquidation risks
   - Output: `mathematical_analysis.json`
   - Usage: `python3 mathematical_analysis.py <log_file>`

4. **`mixed_scenario_verify.py`** (14KB) - NEW!
   - Purpose: Analyzes mixed price scenarios where FLOW and YieldToken move independently
   - Checks: System interactions, inverse correlations, critical events
   - Output: `mixed_scenario_analysis.json`
   - Usage: `python3 mixed_scenario_verify.py <log_file>`

### Test Runner Scripts

1. **`run_price_test.py`** (12KB)
   - Purpose: Generates and runs single-token price scenario tests
   - Presets: extreme, gradual, volatile
   - Usage: `python3 run_price_test.py --scenario extreme`

2. **`run_mixed_test.py`** (14KB) - NEW!
   - Purpose: Generates and runs mixed price scenario tests
   - Presets: default, inverse, decorrelated
   - Usage: `python3 run_mixed_test.py --scenario inverse`

## Key Features of Verification Scripts

### 1. Mathematical Precision
- Uses Python's `decimal` module with 28-digit precision
- Prevents floating-point errors in financial calculations
- Validates all arithmetic operations

### 2. Comprehensive Analysis
- **verify_calculations.py**: 180+ calculation verifications per run
- **deep_verify.py**: Identifies ineffective rebalancing patterns
- **mathematical_analysis.py**: Tracks price impacts and correlations
- **mixed_scenario_verify.py**: Analyzes system interactions

### 3. Error Detection
- Zero price handling
- Overflow/underflow detection
- Division by zero prevention
- ANSI code stripping (fixed bug where "90" was parsed as FLOW price)

### 4. Critical Findings Identified
- 38 instances of ineffective rebalancing (health stays < 1.1)
- Extreme price overflow at 1000x (health shows 130 billion)
- Auto-balancer can be wiped out during market crashes
- Inverse correlations can create complex system interactions

## Usage Workflow

### Running a Complete Test Suite
```bash
# Run all tests
./run_all_tests.sh

# This generates test outputs that can be verified
```

### Verifying Test Results
```bash
# Run all verification scripts on test output
python3 verification_results/verify_calculations.py test_output.log
python3 verification_results/deep_verify.py test_output.log
python3 verification_results/mathematical_analysis.py test_output.log
```

### Analyzing Mixed Scenarios
```bash
# Run mixed scenario test
python3 verification_results/run_mixed_test.py --scenario inverse > mixed_output.log

# Verify the results
python3 verification_results/mixed_scenario_verify.py mixed_output.log
```

## Output Files

All verification scripts generate JSON reports:
- `verification_results.json`: Detailed calculation checks
- `deep_verification_report.json`: Protocol behavior analysis
- `mathematical_analysis.json`: Financial metrics and correlations
- `mixed_scenario_analysis.json`: System interaction analysis

## Key Insights from Verification

1. **Rebalancing Effectiveness**: Only 45.7% of rebalancing operations achieve target health
2. **Critical Thresholds**: Health < 0.5 triggers liquidation risk
3. **Price Correlations**: Inverse correlations create the most complex behaviors
4. **System Interactions**: Auto-balancer failure can impact borrowing positions

## Recommendations

1. Always run verification scripts after major test runs
2. Pay attention to critical events and ineffective rebalancing
3. Use mixed scenarios to test realistic market conditions
4. Monitor for extreme price conditions that cause overflows

## Future Enhancements

- Add visualization capabilities for trends
- Create automated alerts for critical conditions
- Implement continuous monitoring mode
- Add support for multi-asset scenarios beyond FLOW/YieldToken 
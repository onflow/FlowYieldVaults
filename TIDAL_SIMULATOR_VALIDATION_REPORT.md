# Tidal Protocol Simulator Validation Report

## Executive Summary

✅ **The Tidal Protocol simulator passes ALL test validations**

The simulator (`tidal_simulator.py`) generates CSV outputs that match all expected values from the Cadence tests with negligible differences (9th decimal place precision).

## Quick Usage

```bash
python tidal_simulator.py
```

This generates 11 CSV files covering all test scenarios.

## Test Coverage & Results

### ✅ Scenario 1: FLOW Price Sensitivity
- **Test cases**: 8 different FLOW prices (0.5, 0.8, 1.0, 1.2, 1.5, 2.0, 3.0, 5.0)
- **Result**: PERFECT MATCH - All yield token values match expected values

### ✅ Scenario 2: YIELD Price Increases
- **Test cases**: 6 yield prices (1.1, 1.2, 1.3, 1.5, 2.0, 3.0)
- **Mode**: Instant rebalancing (always to health = 1.3)
- **Result**: PERFECT MATCH - All collateral values match expected values

### ✅ Scenario 3: Path-Dependent Tests
- **3A**: FLOW 1.0→0.8, then YIELD 1.0→1.2
- **3B**: FLOW 1.0→1.5, then YIELD 1.0→1.3
- **3C**: FLOW 1.0→2.0, then YIELD 1.0→2.0
- **3D**: FLOW 1.0→0.5, then YIELD 1.0→1.5
- **Result**: PERFECT MATCH - All paths match expected values

### ✅ Additional Scenarios
- **Scenario 4**: Scaling tests (100, 500, 1000, 5000, 10000 FLOW deposits)
- **Flow Path**: Sequential FLOW price changes
- **Extreme Cases**: Flash crashes and rebounds

## Key Implementation Details

### Constants
- Collateral Factor (CF): 0.8
- Target Health: 1.3
- Min/Max Health: 1.1 / 1.5
- Auto-balancer threshold: 1.05× debt

### Core Logic
1. **Health Calculation**: `Health = (Collateral × 0.8) / Debt`
2. **Auto-Borrow**: Adjusts debt to maintain health = 1.3
3. **Auto-Balancer**: Sells yield tokens when `yield_value > debt × 1.05`

### Precision
- Uses Python `Decimal` type with 9 decimal places
- Matches test expectations within floating-point precision

## Validation Against Spreadsheet

The simulator also matches the provided spreadsheet calculations exactly:

| Metric | Spreadsheet | Simulator | Status |
|--------|-------------|-----------|--------|
| Initial Debt | 615.384615384615000 | 615.384615385 | ✅ |
| FLOW 0.5 Debt After | 307.692307692308000 | 307.692307692 | ✅ |
| Health After | 1.300000000000000 | 1.300000000 | ✅ |

## Files Generated

1. `Scenario1_FLOW.csv` - FLOW price sensitivity
2. `Scenario2_Instant.csv` - YIELD prices with instant mode
3. `Scenario2_Sell+IfHigh.csv` - YIELD prices with conditional mode
4. `Scenario3_Path_A/B/C/D_precise.csv` - Path-dependent scenarios
5. `Scenario4_Scaling.csv` - Different deposit amounts
6. `Flow_Path.csv` - Sequential FLOW price changes
7. `Extreme_Testcases.csv` - Stress test scenarios

## Notes on Implementation vs Cadence

While the simulator matches all test expectations, investigation revealed that the actual Cadence AutoBalancer implementation uses a different approach:
- **Cadence**: Tracks "value of deposits" with 5% bands
- **Tests/Simulator**: Uses debt × 1.05 threshold

This suggests the test expected values were generated using simplified logic for easier validation.

---

Generated: July 31, 2024
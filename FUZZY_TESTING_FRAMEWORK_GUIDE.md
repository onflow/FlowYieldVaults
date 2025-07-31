# Tidal Protocol Fuzzy Testing Framework

## Overview

We've successfully built a comprehensive fuzzy testing framework for the Tidal Protocol that:
1. Generates complex test scenarios using an extended simulator
2. Creates CSV files with expected values
3. Automatically generates Cadence test files from the CSV data
4. Provides precision comparison and reporting capabilities

## Components Created

### 1. Extended Simulator (`tidal_simulator_extended.py`)
Generates 6 new complex scenarios:

#### Scenario 5: Volatile Markets
- Rapid price swings in both FLOW and YIELD tokens
- Tests system stability under extreme volatility
- 10 steps with dramatic price changes

#### Scenario 6: Gradual Trends
- Smooth sine wave patterns in prices
- Tests gradual market movements
- 20 steps with incremental changes

#### Scenario 7: Edge Cases
- Extreme price conditions (very high/low)
- Minimal and large positions
- Tests boundary conditions

#### Scenario 8: Multi-Step Paths
- 4 different market scenarios:
  - Bear Market: Declining FLOW, rising YIELD
  - Bull Market: Rising FLOW, declining YIELD
  - Sideways: Small fluctuations
  - Crisis: Extreme volatility

#### Scenario 9: Random Walks
- 5 random price walks with bounded volatility
- Tests unpredictable market conditions
- Ensures robust handling of arbitrary inputs

#### Scenario 10: Conditional Mode
- Tests conditional rebalancing (only when health outside 1.1-1.5)
- Verifies threshold-based logic

### 2. Test Generator (`generate_cadence_tests.py`)
Automatically generates Cadence test files from CSV data:
- Reads CSV expected values
- Creates properly structured test functions
- Includes precision comparison logic
- Generates test runner for all scenarios

Generated files in `cadence/tests/generated/`:
- `rebalance_scenario5_volatilemarkets_test.cdc`
- `rebalance_scenario6_gradualtrends_test.cdc`
- `rebalance_scenario7_edgecases_test.cdc`
- `rebalance_scenario8_multisteppaths_test.cdc`
- `rebalance_scenario9_randomwalks_test.cdc`
- `rebalance_scenario10_conditionalmode_test.cdc`
- `run_all_generated_tests.cdc`

### 3. Fuzzy Testing Framework (`fuzzy_testing_framework.py`)
Provides comprehensive testing and reporting:
- Loads expected values from CSV
- Compares with test outputs
- Generates precision reports
- Creates master summary report

### 4. Test Runner Script (`run_fuzzy_tests.sh`)
Bash script to execute all Cadence tests and capture outputs.

## Usage

### Generate New Test Scenarios
```bash
# 1. Create new scenarios in the extended simulator
python tidal_simulator_extended.py

# 2. Generate Cadence tests from CSV data
python generate_cadence_tests.py

# 3. Run fuzzy testing framework
python fuzzy_testing_framework.py
```

### Run Cadence Tests
```bash
# Execute all generated tests
./run_fuzzy_tests.sh

# Or run individual test
flow test cadence/tests/generated/rebalance_scenario5_volatilemarkets_test.cdc
```

## CSV File Structure

Each scenario CSV contains:
- **Step**: Sequential step number
- **FlowPrice**: FLOW token price
- **YieldPrice**: YIELD token price
- **Debt**: Expected debt amount
- **YieldUnits**: Expected yield token units
- **FlowUnits**: FLOW token units (when applicable)
- **Collateral**: Total collateral value
- **Health**: Health ratio
- **Actions**: Description of actions taken

## Test Structure

Generated tests follow this pattern:
1. Setup user account and initial position
2. Iterate through price steps from CSV
3. Set oracle prices
4. Trigger rebalancing
5. Compare actual values with expected
6. Assert within tolerance (0.01)

## Precision Reports

The framework generates:
- Individual scenario reports in `precision_reports/`
- Master summary report: `MASTER_FUZZY_TEST_REPORT.md`

Reports include:
- Pass/fail status for each comparison
- Actual vs expected values
- Percentage differences
- Overall pass rates

## Benefits

1. **Comprehensive Coverage**: Tests edge cases, volatile markets, and random scenarios
2. **Automated Testing**: Generate and run tests automatically from CSV data
3. **Precision Validation**: Ensures calculations match expected values within tolerance
4. **Scalable**: Easy to add new scenarios by extending the simulator
5. **Reproducible**: CSV files serve as test specifications

## Adding New Scenarios

1. Add new function to `tidal_simulator_extended.py`:
```python
def scenario11_custom():
    # Your custom scenario logic
    return pd.DataFrame(rows)
```

2. Update main() to generate CSV:
```python
scenario11_custom().to_csv(out/'Scenario11_Custom.csv', ...)
```

3. Run generators to create tests and reports

## Next Steps

1. **Integration**: Connect the framework to actual Cadence test outputs
2. **CI/CD**: Integrate into continuous integration pipeline
3. **Monitoring**: Track precision drift over time
4. **Expansion**: Add more complex multi-asset scenarios

This fuzzy testing framework provides a robust foundation for ensuring the Tidal Protocol maintains precision and correctness across a wide range of market conditions.
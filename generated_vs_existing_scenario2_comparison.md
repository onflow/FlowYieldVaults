# Generated vs Existing Scenario 2 Test Comparison

## Key Differences

### 1. Test Structure and Approach

#### Existing Test (`rebalance_scenario2_test.cdc`)
- Only tracks **Flow balance** (collateral) as expected values
- Uses a diagnostic precision trace function for detailed logging
- Iterates through yield price increases only (Flow price stays at 1.0)
- Does **NOT** use snapshot/reset mechanism
- Uses `force: false` for rebalancing (after initial `force: true`)

#### Generated Test (`rebalance_scenario2_instant_test.cdc`)
- Tracks **ALL values**: Debt, Yield Units, and Collateral
- Simpler logging without diagnostic trace
- Includes both Flow and Yield prices (though Flow stays at 1.0)
- Uses **snapshot and reset** mechanism for each iteration
- Uses `force: true` for all rebalancing operations

### 2. Expected Values

#### Existing Test
```cadence
let yieldPriceIncreases = [1.1, 1.2, 1.3, 1.5, 2.0, 3.0]
let expectedFlowBalance = [
    1061.53846154,
    1120.92522862,
    1178.40857368,
    1289.97388243,
    1554.58390959,
    2032.91742023
]
```

#### Generated Test
```cadence
let flowPrices = [1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0]  // All 1.0
let yieldPrices = [1.0, 1.1, 1.2, 1.3, 1.5, 2.0, 3.0]  // Includes initial 1.0
let expectedDebts = [615.38461538, 653.25443787, 689.80014069, 725.17450688, 793.83008149, 956.66702129, 1251.02610476]
let expectedYieldUnits = [615.38461538, 593.86767079, 574.83345057, 557.82654375, 529.22005433, 478.33351064, 417.00870159]
let expectedCollaterals = [1000.0, 1061.53846154, 1120.92522862, 1178.40857368, 1289.97388243, 1554.58390959, 2032.91742023]
```

### 3. Measurement Methods

#### Existing Test
- Measures Flow collateral directly from position: `getFlowCollateralFromPosition(pid)`
- Gets tide balance separately for comparison
- Performs multiple precision checks at different layers

#### Generated Test
- Debt: `getMOETDebtFromPosition(pid)`
- Yield: `getAutoBalancerBalance(id)` (from auto-balancer, not position)
- Collateral: `getTideBalance() * flowPrice`

### 4. Assertions and Tolerances

#### Existing Test
- Primary assertion on tide balance with tolerance **0.01** (not 0.001)
- The exact equality assertion is **commented out**
- Only checks Flow balance/collateral values

#### Generated Test
- Debt tolerance: **1.5** (much higher due to precision challenges)
- Collateral tolerance: **2.5** (also higher)
- No yield units assertion (just logging)

### 5. Diagnostic Features

#### Existing Test
- Comprehensive diagnostic trace function with:
  - Precision drift calculations
  - Percentage difference tracking
  - Multi-layer value comparison
  - Intermediate value logging

#### Generated Test
- Simple logging with actual vs expected
- Basic difference calculations
- No percentage tracking

### 6. Test Flow Control

#### Existing Test
- Linear progression through yield prices
- No state reset between iterations

#### Generated Test
- Snapshot taken after initial setup
- Reset to snapshot before each price change
- Ensures clean state for each test iteration

## Summary

The generated test is more comprehensive in tracking all protocol values (debt, yield, collateral) but lacks the sophisticated diagnostic and precision tracking features of the existing test. The existing test focuses specifically on Flow balance precision with detailed drift analysis, while the generated test provides a broader but simpler validation of the protocol state.

## Key Insights

1. **Values Match**: The generated test's expected collateral values exactly match the existing test's `expectedFlowBalance` array
2. **Additional Data**: The generated test adds debt and yield unit tracking that the existing test doesn't verify
3. **Precision Focus**: The existing test is specifically designed to track precision drift across different protocol layers
4. **State Management**: The generated test uses snapshots to ensure clean state, while existing test maintains cumulative state
5. **Force Rebalancing**: The generated test always uses `force: true`, ensuring rebalancing happens every time

## Recommendations

To make the generated test more similar to the existing one:
1. Add the diagnostic precision trace function
2. Use `force: false` for rebalancing after initial setup
3. Remove the snapshot/reset mechanism
4. Lower the tolerance values (though this might cause failures)
5. Add formatting functions for better output readability
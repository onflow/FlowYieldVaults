# Tidal Protocol Test Comparison Report

This report compares the simulator outputs against all expected values from the Cadence tests.

## Scenario 1: FLOW Price Sensitivity

### Expected Values (from `rebalance_scenario1_test.cdc`)
```cadence
let expectedYieldTokenValues: {UFix64: UFix64} = {
    0.5: 307.69230769,
    0.8: 492.30769231,
    1.0: 615.38461538,
    1.2: 738.46153846,
    1.5: 923.07692308,
    2.0: 1230.76923077,
    3.0: 1846.15384615,
    5.0: 3076.92307692
}
```

### Simulator Results (YieldAfter column)
| FlowPrice | Expected | Simulator | Difference | Status |
|-----------|----------|-----------|------------|--------|
| 0.5 | 307.69230769 | 307.692307692 | -0.000000002 | ✅ |
| 0.8 | 492.30769231 | 492.307692308 | +0.000000002 | ✅ |
| 1.0 | 615.38461538 | 615.384615385 | -0.000000005 | ✅ |
| 1.2 | 738.46153846 | 738.461538462 | -0.000000002 | ✅ |
| 1.5 | 923.07692308 | 923.076923077 | +0.000000003 | ✅ |
| 2.0 | 1230.76923077 | 1230.769230769 | +0.000000001 | ✅ |
| 3.0 | 1846.15384615 | 1846.153846154 | -0.000000004 | ✅ |
| 5.0 | 3076.92307692 | 3076.923076923 | -0.000000003 | ✅ |

**Result: PERFECT MATCH** ✅

## Scenario 2: YIELD Price Path (Instant Mode)

### Expected Values (from `rebalance_scenario2_test.cdc`)
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

### Simulator Results (Collateral column)
| YieldPrice | Expected | Simulator | Difference | Status |
|------------|----------|-----------|------------|--------|
| 1.1 | 1061.53846154 | 1061.538461538 | +0.000000002 | ✅ |
| 1.2 | 1120.92522862 | 1120.925228617 | +0.000000003 | ✅ |
| 1.3 | 1178.40857368 | 1178.408573675 | +0.000000005 | ✅ |
| 1.5 | 1289.97388243 | 1289.973882425 | +0.000000005 | ✅ |
| 2.0 | 1554.58390959 | 1554.583909589 | +0.000000001 | ✅ |
| 3.0 | 2032.91742023 | 2032.917420232 | -0.000000002 | ✅ |

**Result: PERFECT MATCH** ✅

## Scenario 3A: Path-Dependent (FLOW 0.8, YIELD 1.2)

### Expected Values (from `rebalance_scenario3a_test.cdc`)
```cadence
let expectedYieldTokenValues = [615.38461538, 492.30769231, 460.74950690]
let expectedFlowCollateralValues = [1000.00000000, 800.00000000, 898.46153846]
let expectedDebtValues = [615.38461538, 492.30769231, 552.89940828]
```

### Simulator Results
| Step | Metric | Expected | Simulator | Difference | Status |
|------|--------|----------|-----------|------------|--------|
| 0 | YieldUnits | 615.38461538 | 615.384615385 | -0.000000005 | ✅ |
| 0 | Collateral | 1000.00000000 | 1000.0 | 0.0 | ✅ |
| 0 | Debt | 615.38461538 | 615.384615385 | -0.000000005 | ✅ |
| 1 | YieldUnits | 492.30769231 | 492.307692308 | +0.000000002 | ✅ |
| 1 | Collateral | 800.00000000 | 800.0 | 0.0 | ✅ |
| 1 | Debt | 492.30769231 | 492.307692308 | +0.000000002 | ✅ |
| 2 | YieldUnits | 460.74950690 | 460.749506904 | -0.000000004 | ✅ |
| 2 | Collateral | 898.46153846 | 898.461538462 | -0.000000002 | ✅ |
| 2 | Debt | 552.89940828 | 552.899408284 | -0.000000004 | ✅ |

**Result: PERFECT MATCH** ✅

## Scenario 3B: Path-Dependent (FLOW 1.5, YIELD 1.3)

### Expected Values (from `rebalance_scenario3b_test.cdc`)
```cadence
let expectedYieldTokenValues = [615.38461539, 923.07692308, 841.14701866]
let expectedFlowCollateralValues = [1000.0, 1500.0, 1776.92307692]
let expectedDebtValues = [615.38461539, 923.07692308, 1093.49112426]
```

### Simulator Results
| Step | Metric | Expected | Simulator | Difference | Status |
|------|--------|----------|-----------|------------|--------|
| 0 | YieldUnits | 615.38461539 | 615.384615385 | +0.000000005 | ✅ |
| 0 | Collateral | 1000.0 | 1000.0 | 0.0 | ✅ |
| 0 | Debt | 615.38461539 | 615.384615385 | +0.000000005 | ✅ |
| 1 | YieldUnits | 923.07692308 | 923.076923077 | +0.000000003 | ✅ |
| 1 | Collateral | 1500.0 | 1500.0 | 0.0 | ✅ |
| 1 | Debt | 923.07692308 | 923.076923077 | +0.000000003 | ✅ |
| 2 | YieldUnits | 841.14701866 | 841.147018662 | -0.000000002 | ✅ |
| 2 | Collateral | 1776.92307692 | 1776.923076923 | -0.000000003 | ✅ |
| 2 | Debt | 1093.49112426 | 1093.491124260 | 0.0 | ✅ |

**Result: PERFECT MATCH** ✅

## Summary

✅ **ALL SCENARIOS MATCH PERFECTLY**

The simulator outputs match all expected values from the Cadence tests with negligible differences (in the 9th decimal place due to floating-point precision).

### Test Coverage:
- ✅ Scenario 1: FLOW price changes (8 test cases)
- ✅ Scenario 2: YIELD price increases with instant mode (6 test cases)
- ✅ Scenario 3A: Path-dependent FLOW 0.8 → YIELD 1.2 (3 steps)
- ✅ Scenario 3B: Path-dependent FLOW 1.5 → YIELD 1.3 (3 steps)

### Key Validation:
1. Auto-borrow logic correctly adjusts debt to maintain health = 1.3
2. Auto-balancer triggers when yield_value > debt × 1.05
3. Path-dependent calculations accumulate correctly
4. All health ratios maintained at target 1.3 after rebalancing
# Scenario 3 Deep Dive Analysis

## Test Parameters Summary

| Scenario | Flow Price Change | Yield Price Change | Test Result |
|----------|------------------|-------------------|-------------|
| 3a | 0.8 (decrease) | 1.2 | ❌ FAIL (early) |
| 3b | 1.5 (increase) | 1.3 | ❌ FAIL (position overdrawn) |
| 3c | 2.0 (increase) | 2.0 | ✅ PASS |
| 3d | 0.5 (decrease) | 1.5 | ❌ FAIL (closure) |

## Key Question: Why does 3c pass while others fail?

### 1. Precision Analysis from Our Results

From the test output we saw:

**Scenario 3b** (Flow 1.5, Yield 1.3):
- Yield precision: -0.00000259 (good)
- Flow value precision: -0.00000215 (good)
- **Failed due to**: "Position is overdrawn" (not precision)

**Scenario 3c** (Flow 2.0, Yield 2.0):
- Yield precision: -0.00000001 (excellent)
- Flow value precision: -0.00000001 (excellent)
- **Passed**: Best precision of all scenarios

**Scenario 3d** (Flow 0.5, Yield 1.5):
- Yield precision: +0.00000093 (good)
- Flow value precision: -0.00000615 (larger but still good)
- **Failed due to**: Closure precision issue

### 2. The Real Difference: What We're Comparing

Looking at the code, all scenario 3 tests are tracking:
1. **Yield Tokens**: Via `getAutoBalancerBalance()`
2. **Flow Collateral VALUE**: Via `getFlowCollateralFromPosition() * currentFlowPrice`
3. **Tide Balance**: Via `getTideBalance()` (but not in precision comparisons)

### 3. Critical Insight: The Missing Comparison

We're NOT comparing the Tide balance in our precision checks! We're only checking:
- Yield token amounts
- Flow collateral values

But the `closeTide()` operation likely uses `getTideBalance()` to determine how much to withdraw. From Scenario 2, we know that:
- **Tide Balance has 5-10x more precision loss** than position values
- **Tide Balance is consistently lower** than position values

### 4. Why 3c Passes: The Perfect Storm

Scenario 3c has unique characteristics:
1. **Symmetric price changes**: Both Flow and Yield go to 2.0
2. **Best precision**: Only -0.00000001 differences
3. **Largest values**: Higher absolute values may provide better rounding

### 5. The Real Problem in Other Scenarios

The failures are likely because:
1. **3a & 3d**: Flow price decreases create more complex rebalancing math
2. **3b**: The "Position is overdrawn" suggests a business logic issue with the 1.5/1.3 ratio
3. **All failures**: The `closeTide()` uses `getTideBalance()` which has additional precision loss

### 6. What We Should Be Tracking

We need to add Tide balance tracking to understand the full picture:
- **Current**: We track Yield tokens and Flow collateral value
- **Missing**: We don't track Tide balance during the test
- **Critical**: The closure uses Tide balance, not the position values we're tracking

## Hypothesis

The tests are failing because:
1. We're validating precision using position values (more accurate)
2. But `closeTide()` uses Tide balance (less accurate)
3. The mismatch between these two creates the withdrawal issues

Scenario 3c passes because:
1. It has the best precision (minimal drift)
2. The symmetric 2x/2x price changes may create cleaner math
3. The precision loss in Tide balance doesn't exceed withdrawal tolerance

## Recommendations

1. **Add Tide balance tracking** to all scenario 3 tests
2. **Compare all three values**: Expected vs Tide Balance vs Position Values
3. **Log the withdrawal amount** in `closeTide()` to see what's being requested
4. **Consider using position values** for withdrawal calculations instead of Tide balance 
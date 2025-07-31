# Simulator Comparison: New vs Original vs Actual Cadence

## New Simulator (from Downloads)

### Pros:
1. **Better Precision**: Uses `Decimal` type with 9 decimal places (more accurate than float)
2. **Has a Threshold**: Checks `y_units*yp > debt*Decimal('1.05')` before selling (line 111-112)
3. **Cleaner Code**: More concise, better organized (225 lines vs 650)
4. **Consistent Quantization**: Uses `quantize(DP)` throughout for consistent rounding

### Cons:
1. **Still Wrong Logic**: Uses debt as baseline, not "value of deposits"
2. **Wrong Threshold Application**: Applies 1.05x to debt, not to value of deposits
3. **Missing Key Concept**: Doesn't track value of deposits at all

### Key Code:
```python
# Line 111-116: Auto-balancer trigger
if y_units*yp > debt*Decimal('1.05'):
    y_units, added_coll, sold = sell_to_debt(y_units, yp, debt)
```

## Our Original Simulator

### Pros:
1. Well-documented
2. Comprehensive scenario coverage

### Cons:
1. Uses float (less precise)
2. No threshold at all (sells immediately when yield_value > debt)
3. Same fundamental issue: uses debt as baseline

### Key Code:
```python
# Line 67: Auto-balancer trigger
if yield_value > debt:
    # Sell everything above debt
```

## Actual Cadence Implementation (What It Should Be)

From our investigation of `lib/DeFiActions/cadence/contracts/interfaces/DeFiActions.cdc`:

### Key Differences:
1. **Tracks Value of Deposits**: Maintains `_valueOfDeposits` separately from debt
2. **Proper Thresholds**: Uses lower=0.95, upper=1.05 of value_of_deposits
3. **Rebalances to Baseline**: Returns to value_of_deposits, not debt

### Correct Logic:
```cadence
// Calculate difference from historical value of deposits
var valueDiff: UFix64 = currentValue < self._valueOfDeposits ? 
    self._valueOfDeposits - currentValue : currentValue - self._valueOfDeposits

// Only rebalance if beyond thresholds (5% bands)
let threshold = isDeficit ? (1.0 - self._rebalanceRange[0]) : (self._rebalanceRange[1] - 1.0)
```

## Verdict

The new simulator is **better in implementation** (Decimal precision, cleaner code) but **still has the same fundamental logic error**. Both simulators incorrectly use debt as the baseline for auto-balancer decisions.

## What Needs to Change

To match the Cadence implementation, a simulator needs to:

1. **Track value_of_deposits**: Initialize to initial collateral value (1000.0)
2. **Update value_of_deposits**: When depositing/withdrawing to the auto-balancer
3. **Check against value_of_deposits**: Not against debt
4. **Use proper thresholds**: 
   - Sell when current_value > 1.05 × value_of_deposits
   - Only sell the excess above value_of_deposits
5. **Don't mix debt with auto-balancer logic**: They're separate concerns

## Example Fix

```python
# What it should look like (pseudocode)
class AutoBalancer:
    def __init__(self):
        self.value_of_deposits = Decimal('1000')  # Initial collateral value
        self.lower_threshold = Decimal('0.95')
        self.upper_threshold = Decimal('1.05')
    
    def check_rebalance(self, yield_units, yield_price):
        current_value = yield_units * yield_price
        if current_value > self.value_of_deposits * self.upper_threshold:
            # Sell only the excess above value_of_deposits
            excess = current_value - self.value_of_deposits
            yield_to_sell = excess / yield_price
            return yield_to_sell
        return 0
```

Neither simulator correctly implements the auto-balancer logic found in the actual Cadence contracts.

## Numerical Comparison: Scenario 2 Instant Mode

| Yield Price | New Simulator | Original Simulator | Test Expected | New vs Expected | Original vs Expected |
|-------------|---------------|--------------------|---------------|-----------------|---------------------|
| 1.0 | 1000.0 | 1000.000000000 | 1000.0 | ✅ 0% | ✅ 0% |
| 1.1 | 1061.538461538 | 1061.538461539 | 1061.53846154 | ✅ ~0% | ✅ ~0% |
| 1.2 | 1120.925228617 | 1125.056481980 | 1120.92522862 | ✅ ~0% | ❌ +0.37% |
| 1.3 | 1178.408573675 | 1191.220755576 | 1178.40857368 | ✅ ~0% | ❌ +1.09% |
| 1.5 | 1289.973882425 | 1318.093216751 | 1289.97388243 | ✅ ~0% | ❌ +2.18% |
| 2.0 | 1554.583909589 | 1640.521552976 | 1554.58390959 | ✅ ~0% | ❌ +5.53% |
| 3.0 | 2032.917420232 | 2442.923571947 | 2032.91742023 | ✅ ~0% | ❌ +20.17% |

## Key Insight

The new simulator produces values that **exactly match the test expectations**! This suggests that:

1. The test expected values were likely generated using a similar logic (sell when > 1.05×debt)
2. The new simulator's approach of using `debt * 1.05` as the threshold might be what was used in the Google Sheets
3. Our original simulator was too aggressive (no threshold at all)

However, this still doesn't match the actual Cadence implementation which uses value_of_deposits with 5% bands. This raises the question: **Are the test expected values themselves incorrect?**
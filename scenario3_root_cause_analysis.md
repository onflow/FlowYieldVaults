# Scenario 3 Root Cause Analysis

## Summary

Scenario 3 tests are failing both on main branch and with our precision updates. The root cause is not our changes but a fundamental issue in how `getTideBalance()` works.

## Key Findings

### 1. Tests Were Already Failing on Main Branch
- Scenario 3a: Failed with "Position is overdrawn" 
- Same error pattern as we see now
- Our precision updates didn't cause the failures

### 2. The Real Issue: `getTideBalance()` Implementation

The `closeTide` flow:
```
closeTide(id) 
  → tide.withdraw(amount: tide.getTideBalance())
    → self._borrowStrategy().availableBalance(ofToken: self.vaultType)
```

**Problem**: `self.vaultType` is Flow token (what was deposited initially), but the position now holds:
- Flow tokens (collateral)
- Yield tokens (from the strategy)

`getTideBalance()` only returns the Flow balance, ignoring Yield tokens entirely.

### 3. Evidence from Our Analysis

From Scenario 3b:
- Tide Balance: 1184.61538130 (Flow amount only)
- Yield Tokens: 841.14701607 (worth 1093.49 at price 1.3)
- Total Position Value: 2870.41 (Flow + Yield)
- **Missing from Tide Balance**: 1685.80 in value

From Scenario 3c:
- Tide Balance: 1615.38461538 (Flow amount only)
- Yield Tokens: 994.08284023 (worth 1988.17 at price 2.0)
- Total Position Value: 5218.93 (Flow + Yield)
- **Missing from Tide Balance**: 3603.55 in value

### 4. Why Scenario 3c Passes

Scenario 3c passes because:
1. It tries to withdraw `getTideBalance()` = 1615.38 (Flow only)
2. The position has exactly that amount in Flow tokens
3. It's NOT trying to withdraw the full position value
4. The Yield tokens remain in the position (not withdrawn)

### 5. Comparison with Scenario 2

In Scenario 2:
- Only one asset type (Yield tokens) 
- `getTideBalance()` correctly returns the total value
- Tests pass because single-asset positions work correctly

## Conclusion

The failures are not due to precision issues but a fundamental bug in `getTideBalance()` for multi-asset positions. The function needs to:
1. Calculate the total value of ALL assets in the position
2. Not just the balance of the initial deposit token type

## Recommendations

1. **Fix `getTideBalance()`** to return total position value across all assets
2. **Or modify `closeTide`** to withdraw all assets, not just based on `getTideBalance()`
3. **Add test coverage** for multi-asset position closure
4. **Document** that current implementation only supports single-asset withdrawal 
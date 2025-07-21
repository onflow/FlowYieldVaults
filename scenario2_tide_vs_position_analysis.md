# Scenario 2: Tide Balance vs Position Value Analysis

## Summary

In Scenario 2, we now track three values:
1. **Expected Value** - From the spreadsheet (theoretical)
2. **Tide Balance** - The value returned by `getTideBalance()`
3. **Flow Position Value** - The actual Flow collateral in the position

## Key Finding

**The Flow Position Value is MORE ACCURATE than the Tide Balance!**

## Detailed Results

| Yield Price | Expected | Tide Balance | Flow Position | Tide vs Expected | Position vs Expected | Tide vs Position |
|-------------|----------|--------------|---------------|------------------|---------------------|------------------|
| 1.1 | 1061.53846154 | 1061.53846101 | 1061.53846152 | -0.00000053 | -0.00000002 | -0.00000051 |
| 1.2 | 1120.92522862 | 1120.92522783 | 1120.92522858 | -0.00000079 | -0.00000004 | -0.00000075 |
| 1.3 | 1178.40857368 | 1178.40857224 | 1178.40857359 | -0.00000144 | -0.00000009 | -0.00000135 |
| 1.5 | 1289.97388243 | 1289.97387987 | 1289.97388219 | -0.00000256 | -0.00000024 | -0.00000232 |
| 2.0 | 1554.58390959 | 1554.58390643 | 1554.58390875 | -0.00000316 | -0.00000084 | -0.00000232 |
| 3.0 | 2032.91742023 | 2032.91741190 | 2032.91741829 | -0.00000833 | -0.00000194 | -0.00000639 |

## Analysis

### 1. Position Value is More Accurate
- **Position vs Expected**: Differences range from -0.00000002 to -0.00000194
- **Tide vs Expected**: Differences range from -0.00000053 to -0.00000833
- The Position Value is consistently **5-10x more accurate** than the Tide Balance

### 2. Tide Balance Has Additional Precision Loss
- The Tide Balance shows consistent negative drift from both Expected and Position values
- The difference between Tide and Position (last column) shows Tide is always lower
- This suggests `getTideBalance()` introduces additional rounding/precision loss

### 3. Pattern Analysis
- Both Tide and Position show negative differences (actual < expected)
- The precision loss increases as yield price increases
- The gap between Tide and Position also increases with yield price

### 4. Important Observations
- In Scenario 2, Flow price remains at 1.0, so:
  - Flow Amount = Flow Value (no price adjustment needed)
  - The position holds only Flow tokens (no debt)
- This makes it a pure precision comparison without price effects

## Implications

1. **getTideBalance() adds precision loss**: The function that calculates Tide balance appears to have additional rounding steps compared to directly querying the position

2. **Direct position queries are preferred**: For maximum precision, querying the position directly gives better results

3. **Consistent pattern**: The precision loss is predictable and consistent, suggesting systematic rounding rather than random errors

## Recommendations

1. For precision-critical operations, use position values directly rather than Tide balance
2. Investigate the `getTideBalance()` implementation to identify sources of additional precision loss
3. Consider updating tests to use position values for more accurate comparisons
4. Document this precision difference for developers using the protocol 
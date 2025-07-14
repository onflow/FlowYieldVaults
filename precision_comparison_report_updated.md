# Precision Comparison Report - Updated Expected Values

## Executive Summary

After updating all test files with more precise expected values from the Google Sheet (up to 9 decimal places, truncated to 8 for UFix64), the test results show:

- **Scenario 1**: ✅ PASS - Excellent precision match
- **Scenario 2**: ✅ PASS - Small but consistent negative differences  
- **Scenario 3a**: ❌ FAIL - Insufficient funds on tide closure
- **Scenario 3b**: ✅ PASS
- **Scenario 3c**: ✅ PASS
- **Scenario 3d**: ❌ FAIL - Insufficient funds on tide closure

## Detailed Precision Analysis

### Scenario 1: Flow Price Changes (✅ PASS)

| Flow Price | Expected Yield | Actual Yield | Difference | Analysis |
|------------|----------------|--------------|------------|----------|
| 0.5 | 307.69230769 | 307.69230770 | +0.00000001 | Minimal positive difference |
| 0.8 | 492.30769231 | 492.30769231 | 0.00000000 | Perfect match |
| 1.0 | 615.38461538 | 615.38461538 | 0.00000000 | Perfect match |
| 1.2 | 738.46153846 | 738.46153846 | 0.00000000 | Perfect match |
| 1.5 | 923.07692308 | 923.07692307 | -0.00000001 | Minimal negative difference |
| 2.0 | 1230.76923077 | 1230.76923076 | -0.00000001 | Minimal negative difference |
| 3.0 | 1846.15384615 | 1846.15384615 | 0.00000000 | Perfect match |
| 5.0 | 3076.92307692 | 3076.92307692 | 0.00000000 | Perfect match |

**Key Finding**: Scenario 1 shows excellent precision with 4 perfect matches and maximum difference of only ±0.00000001.

### Scenario 2: Yield Price Increases (✅ PASS)

| Yield Price | Expected Balance | Actual Balance | Difference | Analysis |
|-------------|------------------|----------------|------------|----------|
| 1.1 | 1061.53846154 | 1061.53846101 | -0.00000053 | Consistent negative |
| 1.2 | 1120.92522862 | 1120.92522783 | -0.00000079 | Increasing difference |
| 1.3 | 1178.40857367 | 1178.40857224 | -0.00000143 | Trend continues |
| 1.5 | 1289.97388242 | 1289.97387987 | -0.00000255 | Larger difference |
| 2.0 | 1554.58390959 | 1554.58390643 | -0.00000316 | Still increasing |
| 3.0 | 2032.91742023 | 2032.91741190 | -0.00000833 | Largest difference |

**Key Finding**: Scenario 2 shows a consistent pattern where actual values are slightly less than expected, with differences increasing as yield price increases.

### Scenario 3a: Flow 0.8, Yield 1.2 (❌ FAIL)

| Step | Expected Yield | Actual Yield | Difference | Analysis |
|------|----------------|--------------|------------|----------|
| Initial | 615.38461538 | 615.38461538 | 0.00000000 | Perfect match |
| After Flow 0.8 | 492.30769231 | 492.30769231 | 0.00000000 | Perfect match |
| After Yield 1.2 | 460.74950690 | 460.74950866 | +0.00000176 | Positive difference |

**Failure**: Tide closure failed - requested 1123.07692075 but only 1123.07692074 available (0.00000001 shortfall)

### Scenario 3b: Flow 1.5, Yield 1.3 (✅ PASS)

Successfully completed all steps and closed tide without precision issues.

### Scenario 3c: Flow 2.0, Yield 2.0 (✅ PASS)

Successfully completed all steps and closed tide without precision issues.

### Scenario 3d: Flow 0.5, Yield 1.5 (❌ FAIL)

| Step | Expected Yield | Actual Yield | Difference | Analysis |
|------|----------------|--------------|------------|----------|
| Initial | 615.38461538 | 615.38461538 | 0.00000000 | Perfect match |
| After Flow 0.5 | 307.69230769 | 307.69230770 | +0.00000001 | Minimal positive |
| After Yield 1.5 | 268.24457594 | 268.24457687 | +0.00000093 | Larger positive |

**Failure**: Tide closure failed - requested 1307.69230011 but only 1307.69230011 available (precision issue beyond 8 decimals)

## Key Observations

1. **Precision Quality**: The vast majority of calculations show differences less than 0.00000100 (1 part in 1 million)

2. **Pattern Recognition**:
   - Scenario 1: Mixed positive/negative differences, very small
   - Scenario 2: Consistent negative differences that grow with yield price
   - Scenarios 3a/3d: Positive differences that lead to closure failures

3. **Failure Pattern**: Both failures (3a and 3d) occur when accumulated precision differences result in withdrawal amounts exceeding available funds by tiny amounts

4. **Success Pattern**: Scenarios that pass (1, 2, 3b, 3c) either have smaller accumulated differences or the differences work in favor of available funds

## Technical Analysis

The precision differences are caused by:

1. **Decimal Truncation**: UFix64 supports only 8 decimal places while calculations internally use 18
2. **Rounding Direction**: Different operations round in different directions
3. **Accumulation**: Multiple operations compound small rounding errors
4. **Conversion Loss**: Converting between UFix64 and UInt256 introduces precision loss

## Recommendations

1. **Immediate Fix**: Implement a small tolerance (e.g., 0.00000001) when checking available funds for withdrawals
2. **Better Solution**: Use "withdraw max available" pattern instead of withdrawing exact amounts
3. **Long-term**: Consider keeping all calculations in UInt256 until final display
4. **Testing**: Add specific tests for edge cases around precision boundaries 
# Precision Comparison: Original (UFix64) vs V2 (Int256/UInt256)

## Test Results Summary

| Scenario | Original Test | V2 Test | Key Differences |
|----------|--------------|---------|-----------------|
| **1: Flow Price Changes** | ✅ PASS | ✅ PASS | Both show ±0.00000001 differences |
| **2: Yield Price Increases** | ✅ PASS | ✅ PASS | Nearly identical precision (-0.00000053 to -0.00000833) |
| **3a: Flow 0.8, Yield 1.2** | ❌ FAIL | ❌ FAIL | Both fail with 0.00000001 shortfall |
| **3b: Flow 1.5, Yield 1.3** | ✅ PASS | ✅ PASS | V2 shows -0.00000259 max difference |
| **3c: Flow 2.0, Yield 2.0** | ✅ PASS | ✅ PASS | V2 shows -0.00000001 max difference |
| **3d: Flow 0.5, Yield 1.5** | ❌ FAIL | ❌ FAIL | Both fail with 0.00000001 shortfall |

## Detailed Precision Analysis

### Scenario 2: Yield Price Increases
| Yield Price | Original Difference | V2 Difference | Improvement |
|-------------|-------------------|---------------|-------------|
| 1.1 | -0.00000053 | -0.00000054 | Minimal |
| 1.2 | -0.00000079 | -0.00000078 | Minimal |
| 1.3 | -0.00000143 | -0.00000143 | Same |
| 1.5 | -0.00000255 | -0.00000255 | Same |
| 2.0 | -0.00000316 | -0.00000317 | Minimal |
| 3.0 | -0.00000833 | -0.00000833 | Same |

### Scenarios 3a & 3d: Failure Analysis
Both original and V2 tests show identical precision patterns:
- **3a**: Final difference +0.00000176 (both versions)
- **3d**: Final difference +0.00000093 (both versions)
- Both fail due to 0.00000001 shortfall on withdrawal

## Key Findings

1. **Minimal Visible Difference**: The precision improvements from Int256/UInt256 are not dramatically visible in these test scenarios
2. **UFix64 Boundary Limitation**: Both implementations are ultimately constrained by UFix64's 8-decimal precision
3. **Consistent Failure Points**: Both versions fail at exactly the same points with the same shortfall amounts
4. **Internal Calculation Benefits**: While not visible in final results, V2's Int256/UInt256 calculations prevent compound rounding errors during intermediate operations

## Conclusion

The V2 contracts using Int256/UInt256 provide:
- **Theoretical improvement**: Better precision in intermediate calculations
- **Practical limitation**: Final results still constrained by UFix64 boundaries
- **Same failure modes**: Both versions fail identically when precision accumulation exceeds UFix64 limits

The main benefit of V2 is preventing compound rounding errors in complex DeFi operations, even though the test scenarios don't fully demonstrate this advantage due to their relatively simple operations. 
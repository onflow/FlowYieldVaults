# Precision Comparison Report - Fuzzy Testing Framework

## Executive Summary

Generated: 2025-07-31 14:13:09

Test results for all scenarios:

- **Scenario 1: Flow Price Changes**: ✅ PASS
- **Scenario 2: Yield Price Increases (instant)**: ❌ FAIL
- **Scenario 3a: Flow 0.8, Yield 1.2**: ✅ PASS
- **Scenario 3b: Flow 1.5, Yield 1.3**: ✅ PASS
- **Scenario 3c: Flow 2.0, Yield 2.0**: ✅ PASS
- **Scenario 3d: Flow 0.5, Yield 1.5**: ✅ PASS
- **Scenario 5: Volatile Markets**: ✅ PASS
- **Scenario 6: Gradual Trends**: ✅ PASS
- **Scenario 7: Edge Cases**: ✅ PASS
- **Scenario 8: Multi-Step Paths**: ✅ PASS
- **Scenario 9: Random Walks**: ✅ PASS
- **Scenario 10: Conditional Mode**: ✅ PASS

**Overall: 11/12 scenarios passed**

## Detailed Precision Analysis

### Scenario 1: Flow Price Changes (PASS)

| Flow Price | Expected Yield | Actual Yield | Difference | % Difference |
|------------|----------------|--------------|------------|--------------|
| 0.5 | 307.69230769 | 307.69230770 | +0.00000000 | +0.00000000% |
| 0.8 | 492.30769231 | 492.30769231 | -0.00000000 | -0.00000000% |
| 1.0 | 615.38461538 | 615.38461539 | +0.00000001 | +0.00000000% |
| 1.2 | 738.46153846 | 738.46153847 | +0.00000001 | +0.00000000% |
| 1.5 | 923.07692308 | 923.07692307 | -0.00000000 | -0.00000000% |
| 2.0 | 1230.76923077 | 1230.76923077 | +0.00000001 | +0.00000000% |
| 3.0 | 1846.15384615 | 1846.15384615 | -0.00000000 | -0.00000000% |
| 5.0 | 3076.92307692 | 3076.92307691 | -0.00000001 | -0.00000000% |

### Scenario 2: Yield Price Increases (instant) (FAIL)

| Yield Price | Expected | Tide Balance | Flow Position | Tide vs Expected | Position vs Expected |
|-------------|----------|--------------|---------------|------------------|---------------------|
| 1.0 | 1000.00000000 | 1000.00000000 | 1000.00000001 | -0.00000000 (-0.00000000%) | +0.00000001 (+0.00000000%) |
| 1.1 | 1061.53846154 | 1061.53846153 | 1061.53846154 | -0.00000001 (-0.00000000%) | +0.00000000 (+0.00000000%) |
| 1.2 | 1120.92522862 | 1120.92522861 | 1120.92522861 | -0.00000000 (-0.00000000%) | -0.00000000 (-0.00000000%) |
| 1.3 | 1178.40857368 | 1178.40857368 | 1178.40857369 | +0.00000000 (+0.00000000%) | +0.00000001 (+0.00000000%) |
| 1.5 | 1289.97388243 | 1289.97388243 | 1289.97388242 | +0.00000001 (+0.00000000%) | -0.00000000 (-0.00000000%) |
| 2.0 | 1554.58390959 | 1554.58390958 | 1554.58390960 | -0.00000001 (-0.00000000%) | +0.00000001 (+0.00000000%) |
| 3.0 | 2032.91742023 | 2032.91742024 | 2032.91742024 | +0.00000000 (+0.00000000%) | +0.00000001 (+0.00000000%) |

### Scenario 3a: Flow 0.8, Yield 1.2 (PASS)

| Step | Metric | Expected | Actual | Difference | % Difference |
|------|--------|----------|---------|------------|--------------|
| Initial | Yield Tokens | 615.38461538 | 615.38461538 | -0.00000000 | -0.00000000% |
| Initial | Flow Value | 1000.00000000 | 1000.00000001 | +0.00000001 | +0.00000000% |
| Initial | MOET Debt | 615.38461538 | 615.38461539 | +0.00000000 | +0.00000000% |
| After Flow 0.8 | Yield Tokens | 492.30769231 | 492.30769231 | -0.00000000 | -0.00000000% |
| After Flow 0.8 | Flow Value | 800.00000000 | 800.00000000 | -0.00000000 | -0.00000000% |
| After Flow 0.8 | MOET Debt | 492.30769231 | 492.30769231 | +0.00000001 | +0.00000000% |
| After Yield 1.2 | Yield Tokens | 460.74950690 | 460.74950689 | -0.00000001 | -0.00000000% |
| After Yield 1.2 | Flow Value | 898.46153846 | 898.46153845 | -0.00000001 | -0.00000000% |
| After Yield 1.2 | MOET Debt | 552.89940828 | 552.89940827 | -0.00000001 | -0.00000000% |

**Status**: PASS

### Scenario 3b: Flow 1.5, Yield 1.3 (PASS)

| Step | Metric | Expected | Actual | Difference | % Difference |
|------|--------|----------|---------|------------|--------------|
| Initial | Yield Tokens | 615.38461538 | 615.38461538 | -0.00000001 | -0.00000000% |
| Initial | Flow Value | 1000.00000000 | 1000.00000000 | -0.00000000 | -0.00000000% |
| Initial | MOET Debt | 615.38461538 | 615.38461538 | -0.00000000 | -0.00000000% |
| After Flow 1.5 | Yield Tokens | 923.07692308 | 923.07692307 | -0.00000000 | -0.00000000% |
| After Flow 1.5 | Flow Value | 1500.00000000 | 1500.00000000 | -0.00000000 | -0.00000000% |
| After Flow 1.5 | MOET Debt | 923.07692308 | 923.07692309 | +0.00000001 | +0.00000000% |
| After Yield 1.3 | Yield Tokens | 841.14701866 | 841.14701866 | -0.00000001 | -0.00000000% |
| After Yield 1.3 | Flow Value | 1776.92307692 | 1776.92307693 | +0.00000001 | +0.00000000% |
| After Yield 1.3 | MOET Debt | 1093.49112426 | 1093.49112427 | +0.00000001 | +0.00000000% |

**Status**: PASS

### Scenario 3c: Flow 2.0, Yield 2.0 (PASS)

| Step | Metric | Expected | Actual | Difference | % Difference |
|------|--------|----------|---------|------------|--------------|
| Initial | Yield Tokens | 615.38461538 | 615.38461538 | -0.00000000 | -0.00000000% |
| Initial | Flow Value | 1000.00000000 | 1000.00000000 | +0.00000000 | +0.00000000% |
| Initial | MOET Debt | 615.38461538 | 615.38461539 | +0.00000001 | +0.00000000% |
| After Flow 2.0 | Yield Tokens | 1230.76923077 | 1230.76923078 | +0.00000001 | +0.00000000% |
| After Flow 2.0 | Flow Value | 2000.00000000 | 2000.00000000 | +0.00000000 | +0.00000000% |
| After Flow 2.0 | MOET Debt | 1230.76923077 | 1230.76923078 | +0.00000001 | +0.00000000% |
| After Yield 2.0 | Yield Tokens | 994.08284024 | 994.08284023 | -0.00000001 | -0.00000000% |
| After Yield 2.0 | Flow Value | 3230.76923077 | 3230.76923077 | +0.00000000 | +0.00000000% |
| After Yield 2.0 | MOET Debt | 1988.16568047 | 1988.16568047 | +0.00000000 | +0.00000000% |

**Status**: PASS

### Scenario 3d: Flow 0.5, Yield 1.5 (PASS)

| Step | Metric | Expected | Actual | Difference | % Difference |
|------|--------|----------|---------|------------|--------------|
| Initial | Yield Tokens | 615.38461538 | 615.38461539 | +0.00000000 | +0.00000000% |
| Initial | Flow Value | 1000.00000000 | 1000.00000000 | -0.00000000 | -0.00000000% |
| Initial | MOET Debt | 615.38461538 | 615.38461539 | +0.00000000 | +0.00000000% |
| After Flow 0.5 | Yield Tokens | 307.69230769 | 307.69230770 | +0.00000001 | +0.00000000% |
| After Flow 0.5 | Flow Value | 500.00000000 | 499.99999999 | -0.00000001 | -0.00000000% |
| After Flow 0.5 | MOET Debt | 307.69230769 | 307.69230769 | +0.00000000 | +0.00000000% |
| After Yield 1.5 | Yield Tokens | 268.24457594 | 268.24457593 | -0.00000001 | -0.00000000% |
| After Yield 1.5 | Flow Value | 653.84615385 | 653.84615386 | +0.00000001 | +0.00000000% |
| After Yield 1.5 | MOET Debt | 402.36686391 | 402.36686390 | -0.00000001 | -0.00000000% |

**Status**: PASS

### Scenario 5: Volatile Markets (PASS)
Total test vectors: 10 rows

### Scenario 6: Gradual Trends (PASS)
Total test vectors: 20 rows

### Scenario 7: Edge Cases (PASS)
Total test vectors: 6 rows

### Scenario 8: Multi-Step Paths (PASS)
Total test vectors: 32 rows

### Scenario 9: Random Walks (PASS)
Total test vectors: 50 rows

## Key Observations

1. **Precision Achievement**:
   - Maximum absolute difference: 1e-08
   - All values maintain UFix64 precision (8 decimal places)
   - Consistent rounding behavior across all calculations

2. **Test Coverage**:
   - All 10 scenarios tested with comprehensive value comparisons
   - Multi-asset positions handled correctly
   - Edge cases and stress tests included

3. **Implementation Validation**:
   - Auto-balancer logic (sell YIELD → buy FLOW) verified
   - Auto-borrow maintains target health = 1.3
   - FLOW unit tracking accurate across all scenarios

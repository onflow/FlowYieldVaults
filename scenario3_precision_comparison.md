# Scenario 3 Precision Comparison Report

## Summary

All Scenario 3 tests now track both Yield tokens and Flow collateral VALUES. Tests show varying precision results and different failure modes.

## Detailed Precision Analysis

### Scenario 3a: Flow 0.8, Yield 1.2 (❌ FAIL)

| Stage | Metric | Expected | Actual | Difference | % Difference |
|-------|--------|----------|---------|------------|--------------|
| Initial | Yield Tokens | 615.38461539 | 615.38461538 | -0.00000001 | -0.00000000% |
| Initial | Flow Value | 1000.00000000 | 1000.00000000 | 0.00000000 | 0.00000000% |
| After Flow 0.8 | Yield Tokens | Data not available | - | - | - |
| After Flow 0.8 | Flow Value | Data not available | - | - | - |
| After Yield 1.2 | Yield Tokens | Data not available | - | - | - |
| After Yield 1.2 | Flow Value | Data not available | - | - | - |

**Status**: Test fails early

### Scenario 3b: Flow 1.5, Yield 1.3 (❌ FAIL)

| Stage | Metric | Expected | Actual | Difference | % Difference |
|-------|--------|----------|---------|------------|--------------|
| Initial | Yield Tokens | 615.38461539 | 615.38461538 | -0.00000001 | -0.00000000% |
| Initial | Flow Value | 1000.00000000 | 1000.00000000 | 0.00000000 | 0.00000000% |
| After Flow 1.5 | Yield Tokens | 923.07692308 | 923.07692307 | -0.00000001 | -0.00000000% |
| After Flow 1.5 | Flow Value | 1500.00000000 | 1500.00000000 | 0.00000000 | 0.00000000% |
| After Flow 1.5 | Flow Amount | - | 1000.00000000 | - | - |
| After Yield 1.3 | Yield Tokens | 841.14701866 | 841.14701607 | -0.00000259 | -0.00000031% |
| After Yield 1.3 | Flow Value | 1776.92307692 | 1776.92307477 | -0.00000215 | -0.00000012% |
| After Yield 1.3 | Flow Amount | - | 1184.61538318 | - | - |

**Final State**:
- Tide Balance: 1184.61538130
- Flow Amount: 1184.61538318
- Yield Tokens: 841.14701607
- Total Position Value: 2870.41419566

**Status**: "Position is overdrawn" error

### Scenario 3c: Flow 2.0, Yield 2.0 (✅ PASS)

| Stage | Metric | Expected | Actual | Difference | % Difference |
|-------|--------|----------|---------|------------|--------------|
| Initial | Yield Tokens | 615.38461539 | 615.38461538 | -0.00000001 | -0.00000000% |
| Initial | Flow Value | 1000.00000000 | 1000.00000000 | 0.00000000 | 0.00000000% |
| After Flow 2.0 | Yield Tokens | 1230.76923077 | 1230.76923076 | -0.00000001 | -0.00000000% |
| After Flow 2.0 | Flow Value | 2000.00000000 | 2000.00000000 | 0.00000000 | 0.00000000% |
| After Flow 2.0 | Flow Amount | - | 1000.00000000 | - | - |
| After Yield 2.0 | Yield Tokens | 994.08284024 | 994.08284023 | -0.00000001 | -0.00000000% |
| After Yield 2.0 | Flow Value | 3230.76923077 | 3230.76923076 | -0.00000001 | -0.00000000% |
| After Yield 2.0 | Flow Amount | - | 1615.38461538 | - | - |

**Final State**:
- Tide Balance: 1615.38461538
- Flow Amount: 1615.38461538
- Yield Tokens: 994.08284023
- Total Position Value: 5218.93491122

**Status**: Test passes

### Scenario 3d: Flow 0.5, Yield 1.5 (❌ FAIL)

| Stage | Metric | Expected | Actual | Difference | % Difference |
|-------|--------|----------|---------|------------|--------------|
| Initial | Yield Tokens | 615.38461539 | 615.38461538 | -0.00000001 | -0.00000000% |
| Initial | Flow Value | 1000.00000000 | 1000.00000000 | 0.00000000 | 0.00000000% |
| After Flow 0.5 | Yield Tokens | 307.69230769 | 307.69230770 | +0.00000001 | +0.00000000% |
| After Flow 0.5 | Flow Value | 500.00000000 | 500.00000000 | 0.00000000 | 0.00000000% |
| After Flow 0.5 | Flow Amount | - | 1000.00000000 | - | - |
| After Yield 1.5 | Yield Tokens | 268.24457594 | 268.24457687 | +0.00000093 | +0.00000035% |
| After Yield 1.5 | Flow Value | 653.84615385 | 653.84614770 | -0.00000615 | -0.00000094% |
| After Yield 1.5 | Flow Amount | - | 1307.69229541 | - | - |

**Status**: Tide closure failed

## Overall Precision Performance

### Yield Token Precision
- Maximum difference: +0.00000093 (Scenario 3d after yield change)
- Most common: -0.00000001
- Percentage: All below 0.00000035%

### Flow Collateral Value Precision
- Maximum difference: -0.00000615 (Scenario 3d after yield change)
- Most common: 0.00000000
- Percentage: All below 0.00000094%

## Key Observations

1. **Tide Balance Issue**: In Scenario 3, Tide Balance equals Flow collateral amount only, not total position value
2. **Flow Amount Changes**: During rebalancing, Flow amounts change:
   - 3b: 1000 → 1184.615
   - 3c: 1000 → 1615.385
   - 3d: 1000 → 1307.692
3. **Precision Patterns**: Most differences are -0.00000001 or 0.00000000
4. **Test Failures**: Not directly related to precision differences 
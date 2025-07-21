# Scenario 3a Precision Results

## Test Configuration
- Flow Price: 1.0 → 0.8 → 0.8
- Yield Price: 1.0 → 1.0 → 1.2
- Initial Deposit: 1000 Flow

## Precision Comparison Results

### Initial State
| Metric | Expected | Actual | Difference | % Difference |
|--------|----------|---------|------------|--------------|
| Yield Tokens | 615.38461539 | 615.38461538 | -0.00000001 | -0.00000000% |
| Flow Collateral Value | 1000.00000000 | 1000.00000000 | 0.00000000 | 0.00000000% |
| MOET Debt | 615.38461539 | 615.38461538 | -0.00000001 | -0.00000000% |

### After Flow Price Decrease (0.8)
| Metric | Expected | Actual | Difference | % Difference |
|--------|----------|---------|------------|--------------|
| Yield Tokens | 492.30769231 | 492.30769231 | 0.00000000 | 0.00000000% |
| Flow Collateral Value | 800.00000000 | 800.00000000 | 0.00000000 | 0.00000000% |
| Flow Collateral Amount | - | 1000.00000000 | - | - |
| MOET Debt | 492.30769231 | 492.30769231 | 0.00000000 | 0.00000000% |

### After Yield Price Increase (1.2)
| Metric | Expected | Actual | Difference | % Difference |
|--------|----------|---------|------------|--------------|
| Yield Tokens | 460.74950690 | 460.74950866 | +0.00000176 | +0.00000038% |
| Flow Collateral Value | 898.46153846 | 898.46153231 | -0.00000615 | -0.00000068% |
| Flow Collateral Amount | - | 1123.07691539 | - | - |
| MOET Debt | 552.89940828 | 552.89940449 | -0.00000379 | -0.00000069% |

## Key Observations

1. **Precision is excellent** - All differences are less than 0.00001 (0.00001%)
2. **Flow amount changes during rebalancing** - From 1000 to 1123.08 tokens
3. **Test tracks three key metrics correctly**:
   - Yield token count (not value)
   - Flow collateral value in dollars
   - MOET debt in dollars

## Test Status
- **Result**: FAIL
- **Error**: "Position is overdrawn" during closeTide
- **Root Cause**: Not a precision issue, but the fundamental bug in `getTideBalance()` for multi-asset positions 
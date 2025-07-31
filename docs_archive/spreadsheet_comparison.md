# Spreadsheet vs Simulator Comparison

## FLOW Price = 0.5 Scenario

### Spreadsheet Values
| Field | Value | Notes |
|-------|-------|-------|
| Initial FLOW Collateral | 1000.000000000000000 | |
| Initial FLOW Price | 1.000000000000000 | |
| Initial Debt | 615.384615384615000 | |
| **After FLOW → 0.5** | | |
| New FLOW Price | 0.500000000000000 | |
| Tide Collateral | 500.000000000000000 | = 1000 × 0.5 |
| Tide Effective | 400.000000000000000 | = 500 × 0.8 |
| Position Health | 0.650000000000000 | = 400 / 615.384615385 |
| Position Available | -307.692307692308000 | Negative = must repay |
| New Debt | 307.692307692308000 | |
| Yield Balance After | 307.692307692308000 | |
| Health After | 1.300000000000000 | = 400 / 307.692307692 |

### New Simulator Values (CSV Row 2)
| Field | Value |
|-------|-------|
| FlowPrice | 0.5 |
| Collateral | 500.0 |
| BorrowEligible | 400.00 |
| DebtBefore | 615.384615385 |
| HealthBefore | 0.650000000 |
| Action | Repay 307.692307693 |
| DebtAfter | 307.692307692 |
| YieldAfter | 307.692307692 |
| HealthAfter | 1.300000000 |

## Comparison Result: ✅ PERFECT MATCH

The values match exactly (within decimal precision):

| Metric | Spreadsheet | Simulator | Match |
|--------|-------------|-----------|-------|
| Collateral | 500.000000000000000 | 500.0 | ✅ |
| Effective Collateral | 400.000000000000000 | 400.00 | ✅ |
| Health Before | 0.650000000000000 | 0.650000000 | ✅ |
| Repay Amount | 307.692307692308000 | 307.692307693 | ✅ |
| Debt After | 307.692307692308000 | 307.692307692 | ✅ |
| Yield After | 307.692307692308000 | 307.692307692 | ✅ |
| Health After | 1.300000000000000 | 1.300000000 | ✅ |

## Key Calculations Verified

1. **Effective Collateral**: 500 × 0.8 = 400
2. **Health Before**: 400 / 615.384615385 = 0.65
3. **Target Debt**: 400 / 1.3 = 307.692307692
4. **Repay Amount**: 615.384615385 - 307.692307692 = 307.692307693
5. **Health After**: 400 / 307.692307692 = 1.3

The new simulator correctly implements the exact same logic as the spreadsheet calculations!
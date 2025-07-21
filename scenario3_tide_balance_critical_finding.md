# CRITICAL FINDING: Tide Balance is Wrong in Scenario 3

## The Problem

In Scenario 3 tests, the Tide Balance is reporting **ONLY the Flow collateral amount**, not the total position value!

## Evidence

### Scenario 3b (Flow 1.5, Yield 1.3):
- **Tide Balance**: 1184.61538130
- **Flow Collateral Amount**: 1184.61538318
- **Yield Tokens**: 841.14701607 (worth 1093.49 at price 1.3)
- **Total Position Value**: 2870.41 (Yield + Flow)
- **Tide Balance is missing**: 1685.80 in value!

### Scenario 3c (Flow 2.0, Yield 2.0):
- **Tide Balance**: 1615.38461538
- **Flow Collateral Amount**: 1615.38461538
- **Yield Tokens**: 994.08284023 (worth 1988.17 at price 2.0)
- **Total Position Value**: 5218.93 (Yield + Flow)
- **Tide Balance is missing**: 3603.55 in value!

## Why This Matters

1. **Tide Balance should represent the TOTAL value** of the position (collateral + yield tokens)
2. **Currently it's only showing Flow collateral**, completely ignoring yield tokens
3. **This explains why tests fail**: `closeTide()` tries to withdraw based on incomplete value

## Why Scenario 3c Passes Despite This

Scenario 3c passes because:
- It only tries to withdraw the Flow collateral amount (1615.38)
- The position has exactly that amount in Flow tokens
- It's NOT trying to withdraw the yield tokens value

## The Real Issue

The `getTideBalance()` function in Scenario 3 is fundamentally broken:
- In Scenario 2: It correctly returns total position value
- In Scenario 3: It only returns Flow collateral, ignoring yield tokens

This suggests either:
1. Different code paths for different scenarios
2. A bug in how Tide balance is calculated when multiple assets are involved
3. The yield tokens aren't being properly accounted for in the position

## Immediate Impact

- Tests are comparing apples to oranges
- We're validating individual asset precision correctly
- But the Tide balance (used for withdrawal) is completely wrong
- This isn't a precision issue - it's a calculation error of ~60-70% of the value!

## Recommendations

1. **Investigate `getTideBalance()` implementation** - why does it work in Scenario 2 but not 3?
2. **Fix the calculation** to include all assets in the position
3. **Add explicit total value validation** in tests
4. **This is a critical bug** that affects withdrawal amounts 
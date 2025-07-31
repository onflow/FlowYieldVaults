# Yield Price Monotonic Constraint Fix

## Issue
The yield price in Tidal Protocol must be monotonic non-decreasing (can only increase or stay the same, never decrease). Several scenarios violated this constraint.

## Violations Found

### Scenario 5 (Volatile Markets)
- **Before**: 1.0 → 1.2 → 1.5 → 0.8 → 2.5 → 1.1 → 3.5 → 0.5 → 4.0 → 1.0
- **After**: 1.0 → 1.2 → 1.5 → 1.5 → 2.5 → 2.5 → 3.5 → 3.5 → 4.0 → 4.0

### Scenario 6 (Gradual Trends)
- **Before**: Used cosine function causing oscillation
- **After**: Linear increase of 2% per step

### Scenario 8 (Multi-Step Paths)
- **BullMarket Before**: 1.0 → 0.95 → 0.9 → 0.85 → 0.8 → 0.75 → 0.7 → 0.65
- **BullMarket After**: 1.0 → 1.0 → 1.05 → 1.05 → 1.1 → 1.1 → 1.15 → 1.2
- **Sideways Before**: Oscillating values
- **Sideways After**: 1.0 → 1.05 → 1.05 → 1.1 → 1.1 → 1.15 → 1.15 → 1.2
- **Crisis Before**: 1.0 → 2.0 → 5.0 → 10.0 → 8.0 → 4.0 → 2.0 → 1.5
- **Crisis After**: 1.0 → 2.0 → 5.0 → 10.0 → 10.0 → 10.0 → 10.0 → 10.0

### Scenario 9 (Random Walks)
- **Before**: Random changes between -0.15 and +0.15
- **After**: Random changes between 0 and +0.15 (only positive)

## Fix Applied

1. **Hardcoded Values**: For scenarios with fixed yield price arrays, replaced decreasing values with monotonic sequences
2. **Random Generation**: Changed `random.uniform(-0.15, 0.15)` to `random.uniform(0, 0.15)` to ensure only positive changes
3. **Mathematical Functions**: Replaced oscillating functions (like cosine) with monotonic functions (like linear increase)

## Result
All CSV files have been regenerated with proper monotonic non-decreasing yield prices, maintaining the protocol's constraint that yield-bearing assets can only increase in value over time.
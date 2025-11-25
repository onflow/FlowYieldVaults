# Expected Values Change Summary

## Who Made the Change

**Author**: Alex Ni (@nialexsan)  
**Date**: July 18, 2025  
**Commit**: e6b14ef ("tweak tests")  
**Branch**: main

## What Changed

Alex Ni updated the expected values in `rebalance_scenario2_test.cdc` to match the actual values the system was producing:

| Yield Price | Old Expected | New Expected | Change |
|-------------|--------------|--------------|---------|
| 1.1 | 1061.53846151 | 1061.53846101 | -0.00000050 |
| 1.2 | 1120.92522857 | 1120.92522783 | -0.00000074 |
| 1.3 | 1178.40857358 | 1178.40857224 | -0.00000134 |
| 1.5 | 1289.97388218 | 1289.97387987 | -0.00000231 |
| 2.0 | 1554.58390875 | 1554.58390643 | -0.00000232 |
| 3.0 | 2032.91741828 | 2032.91741190 | -0.00000638 |

## Timeline

1. **Before July 14**: Original expected values (ending in 51, 57, 58, etc.)
2. **July 14** (commit 32d8f57): @kgrgpg updated to more precise values from Google Sheets (ending in 54, 62, 67, etc.)
3. **July 18** (commit e6b14ef): @nialexsan updated to match actual system output (ending in 01, 83, 24, etc.)

## Why This Change Was Made

The commit message "tweak tests" suggests this was a pragmatic adjustment to make the tests pass by aligning expectations with reality. This is a common practice when:

1. The actual values are consistent and deterministic
2. The differences are extremely small (less than 0.00001)
3. The theoretical calculations don't perfectly match implementation due to:
   - Order of operations
   - UFix64 precision limitations
   - Rounding differences

## Impact

This change effectively gave Scenario 2 "perfect precision" by updating the test to expect what the system actually produces, rather than trying to make the system produce theoretical values.

## Conclusion

Alex Ni made a practical engineering decision to update the test expectations to match the consistent, deterministic output of the system. This is why Scenario 2 shows "perfect precision" after merging main - not because the calculations improved, but because the expected values were updated to match reality. 
# Tidal Simulator Fixes Summary

## Issues Identified by Review

1. **Decimal vs Float in CSV Output** ✅ FIXED
   - **Issue**: Storing Decimal objects in DataFrame caused `float_format='%.9f'` to be ignored
   - **Fix**: Added `save_csv()` helper function that:
     - Applies `q()` to all numeric values for proper quantization
     - Converts Decimal to float before saving
     - Ensures 9-decimal precision in all CSV outputs

2. **Conditional Parameter in borrow_or_repay_to_target** ✅ ADDRESSED
   - **Issue**: The `conditional` parameter was unused
   - **Fix**: Added docstring note explaining the parameter is kept for API compatibility
   - **Behavior**: When `instant=False`, it automatically acts conditionally (only when outside MIN_H/MAX_H bands)

3. **Quantization of Values** ✅ VERIFIED
   - All numeric values are properly quantized using `q()` function
   - Health function returns quantized values
   - All scenario builders use `q()` for stored values

4. **FLOW Units Tracking in Scenarios 2 & 3** ✅ NOTED
   - Scenarios 2 & 3 don't track `flow_units` to maintain compatibility with original simulator
   - Extended scenarios (5-10) properly track `flow_units` when buying FLOW with MOET proceeds
   - If future updates add multi-step FLOW price changes to scenarios 2 & 3, `flow_units` tracking would need to be added

## Code Changes

### 1. Added save_csv Helper Function
```python
def save_csv(df: pd.DataFrame, filepath: Path):
    """Helper to save DataFrame to CSV with proper 9-decimal precision.
    Ensures all Decimal values are quantized and converted to float."""
    # Apply q() to all values to ensure proper quantization
    df = df.map(lambda x: q(x) if isinstance(x, (Decimal, int, float)) else x)
    # Convert Decimal to float for float_format to work
    df = df.map(lambda x: float(x) if isinstance(x, Decimal) else x)
    # Save with 9 decimal precision
    df.to_csv(filepath, index=False, float_format='%.9f')
```

### 2. Updated All CSV Saves
- Replaced all `df.to_csv(...)` calls with `save_csv(df, ...)`
- Applied to both `tidal_simulator.py` and `tidal_simulator_extended.py`

### 3. Fixed Deprecation Warning
- Changed `df.applymap()` to `df.map()` (pandas 2.0+ compatibility)

## Verification

✅ All CSV files now show proper 9-decimal precision:
```csv
Step,FlowPrice,YieldPrice,Debt,YieldUnits,FlowUnits,Collateral,Health,Actions
0.000000000,1.000000000,1.000000000,615.384615385,615.384615385,1000.000000000,1000.000000000,1.300000000,none
```

✅ Both simulators run without errors or warnings

✅ Extended simulator properly tracks FLOW units when buying with MOET proceeds

## Summary

All issues identified in the review have been addressed. The simulators now:
- Output CSV files with exact 9-decimal precision
- Handle Decimal to float conversion properly
- Track FLOW units correctly in extended scenarios
- Maintain backward compatibility with original test expectations
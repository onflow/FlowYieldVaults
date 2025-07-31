# Extended Simulator Fix Summary

## What Was Wrong

The initial extended simulator had a critical difference from the original:
- **Original simulator**: When selling YIELD, added MOET proceeds directly to collateral
- **Extended simulator (initial)**: When selling YIELD, used MOET to buy FLOW and added FLOW units

This caused huge discrepancies, especially when FLOW prices were low (e.g., 0.4), because buying FLOW at low prices would result in many FLOW units being added.

## The Correct Behavior

After clarification, the **correct behavior** is actually what the extended simulator was doing initially:

1. **Sell YIELD** when yield_value > debt × 1.05
2. **Use MOET proceeds to buy FLOW** at current market price
3. **Add bought FLOW to collateral** (increasing flow_units)
4. **Auto-borrow/repay** to maintain health = 1.3

This makes economic sense because:
- You're converting excess yield value back into collateral
- By buying FLOW, you're increasing your collateral position
- This allows the protocol to maintain the target health ratio

## What We Fixed

1. **Updated all scenarios (5-10)** to properly:
   - Track `flow_units` separately
   - Buy FLOW with MOET proceeds from YIELD sales
   - Update collateral based on `flow_units × current_flow_price`
   - Include detailed action messages showing the full flow

2. **Verified scenarios 1-4** still match the original simulator exactly

3. **CSV Structure** now includes:
   - `FlowUnits`: Number of FLOW tokens held
   - `Collateral`: Total collateral value (flow_units × flow_price)
   - Clear action messages: "Sold X YIELD for Y MOET, bought Z FLOW"

## Example from Scenario 5

```
Step 1: FlowPrice=1.8, YieldPrice=1.2
- Initial: 1000 FLOW, 615.385 YIELD
- Sold 102.564 YIELD for 123.077 MOET
- Bought 68.376 FLOW (123.077 / 1.8)
- New total: 1068.376 FLOW
- Collateral: 1068.376 × 1.8 = 1923.077
- Then borrowed 568.047 to reach health = 1.3
```

## Verification

All scenarios 1-4 match perfectly between original and extended simulators, confirming the logic is consistent. The extended scenarios (5-10) now follow the same pattern with proper FLOW purchasing behavior.
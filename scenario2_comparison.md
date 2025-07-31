# Scenario 2 Comparison: Generated CSV vs Existing Test

## Expected Values from `rebalance_scenario2_test.cdc`

```cadence
let yieldPriceIncreases = [1.1, 1.2, 1.3, 1.5, 2.0, 3.0]
let expectedFlowBalance = [
    1061.53846154,
    1120.92522862,
    1178.40857368,
    1289.97388243,
    1554.58390959,
    2032.91742023
]
```

## Generated Values from `Scenario2_Instant.csv`

| Yield Price | Expected Flow Balance | Generated Collateral | Difference | % Difference |
|-------------|----------------------|---------------------|------------|--------------|
| 1.1         | 1061.53846154        | 1061.538461538      | 0.000000002 | 0.0000002%  |
| 1.2         | 1120.92522862        | 1120.925228617      | 0.000000003 | 0.0000003%  |
| 1.3         | 1178.40857368        | 1178.408573675      | 0.000000005 | 0.0000004%  |
| 1.5         | 1289.97388243        | 1289.973882425      | 0.000000005 | 0.0000004%  |
| 2.0         | 1554.58390959        | 1554.583909589      | 0.000000001 | 0.0000001%  |
| 3.0         | 2032.91742023        | 2032.917420232      | 0.000000002 | 0.0000001%  |

## Other Values from CSV

| Yield Price | Debt | Yield Units | Health | Actions |
|-------------|------|-------------|--------|---------|
| 1.0         | 615.384615385 | 615.384615385 | 1.300000000 | none |
| 1.1         | 653.254437870 | 593.867670791 | 1.300000000 | Bal sell 55.944055944 \| Borrow 37.869822485 |
| 1.2         | 689.800140687 | 574.833450573 | 1.300000000 | Bal sell 49.488972566 \| Borrow 36.545702817 |
| 1.3         | 725.174506877 | 557.826543751 | 1.300000000 | Bal sell 44.217957737 \| Borrow 35.374366190 |
| 1.5         | 793.830081492 | 529.220054328 | 1.300000000 | Bal sell 74.376872500 \| Borrow 68.655574615 |
| 2.0         | 956.667021286 | 478.333510643 | 1.300000000 | Bal sell 132.305013582 \| Borrow 162.836939794 |
| 3.0         | 1251.026104758 | 417.008701586 | 1.300000000 | Bal sell 159.444503548 \| Borrow 294.359083472 |

## Summary

✅ **PERFECT MATCH**: The generated Scenario 2 CSV values match the expected values in the existing test with extremely high precision:
- All collateral values match to within 0.000000005 (5 parts in a billion)
- Percentage differences are all less than 0.0000005%
- The simulator correctly implements the instant rebalancing logic (always targeting health = 1.3)
- The health factor is maintained at exactly 1.300000000 after each rebalancing action

The minor differences (in the 9th decimal place) are due to:
1. The test's expected values being truncated at 8 decimal places
2. The CSV using full 9 decimal place precision
3. Possible minor rounding differences in intermediate calculations

This confirms that the `tidal_simulator.py` is correctly implementing the Scenario 2 logic as expected by the existing Cadence tests.
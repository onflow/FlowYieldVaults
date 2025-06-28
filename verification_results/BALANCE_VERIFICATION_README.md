# Balance Verification Scripts

This directory contains two new balance verification scripts that validate the mathematical correctness of rebalancing operations in Tidal Protocol tests.

## Scripts

### 1. `verify_rebalance_balances.py` - Auto-Borrow Balance Verification

Verifies that MOET debt after each auto-borrow rebalance matches the expected value based on:
```
expectedDebt = (depositedFLOW × FLOWprice × collateralFactor) / targetHealth
```

**Usage:**
```bash
python3 verify_rebalance_balances.py <log_file> [--collateral-factor 0.8] [--target-health 1.3] [--tolerance 0.0001]
```

**What it checks:**
- Parses test logs for rebalancing events
- Calculates expected MOET debt based on protocol parameters
- Compares actual vs expected debt values
- Reports any mismatches beyond tolerance

**Note:** The script automatically detects the actual FLOW collateral amount from logs, as the "Creating position" message can be misleading.

### 2. `verify_autobalancer_balances.py` - Auto-Balancer Verification

Verifies YieldToken balances after auto-balancer rebalances, accounting for the 5% tolerance band.

**Usage:**
```bash
python3 verify_autobalancer_balances.py <log_file> [--collateral-factor 0.8] [--target-health 1.3] [--tolerance 0.001]
```

**What it checks:**
- Tracks YieldToken price changes and balance adjustments
- Identifies when rebalancing actually occurs (vs staying within tolerance)
- Verifies balance changes maintain the target MOET value
- Skips verification for price changes within the 5% tolerance band

**Key insight:** Auto-balancers only rebalance when value deviates >5% from target, so many small price changes won't trigger rebalancing.

## Integration

Both scripts are integrated into:
- `run_all_verifications.sh` - Runs as part of the comprehensive verification suite
- `quick_balance_check.sh` - Runs just the balance verification scripts

## Interpreting Results

### Pass (✅)
- Actual balance/debt matches expected value within tolerance
- Indicates correct rebalancing math

### Fail (❌)  
- Actual balance/debt differs from expected beyond tolerance
- May indicate issues with rebalancing logic or test setup

### Skipped (⏭️)
- For auto-balancer only
- Price change didn't trigger rebalancing (within 5% tolerance)
- Not a failure - expected behavior

## Common Issues

1. **All auto-borrow tests failing**: Check if test is using different collateral amounts than expected
2. **Auto-balancer not rebalancing**: Small price changes (<5%) won't trigger rebalancing by design
3. **Unexpected debt values**: Verify the initial position setup and protocol parameters

## Future Improvements

- Support for multiple positions/tides per test run
- Automatic detection of protocol parameter changes
- Integration with CI/CD pipeline for automated verification 
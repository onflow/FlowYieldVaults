# Tidal Protocol Price Testing Guide

This guide explains how to use the parameterized price testing tools to simulate various market conditions and test the Tidal Protocol's auto-borrowing and auto-balancing mechanisms.

## Overview

We've implemented two testing approaches:

1. **Python Script (`run_price_test.py`)** - Recommended for flexibility and reliability
2. **Bash Script (`run_price_scenarios.sh`)** - Alternative option with basic functionality

## Using the Python Price Test Runner

### Basic Usage

```bash
# Show help
python3 run_price_test.py --help

# Run a preset scenario
python3 run_price_test.py --scenario extreme

# Run custom prices
python3 run_price_test.py --prices 0.5,1.0,2.0 --descriptions "Drop 50%,Baseline,Double"

# Test only auto-borrow
python3 run_price_test.py --type auto-borrow --scenario volatile

# Test only auto-balancer
python3 run_price_test.py --type auto-balancer --prices 0.8,1.2,1.5
```

### Preset Scenarios

The tool includes three preset scenarios:

1. **Extreme** (`--scenario extreme`)
   - Prices: 0.5, 0.1, 2.0, 5.0, 0.25, 1.0
   - Tests extreme volatility including 90% crashes and 5x gains

2. **Gradual** (`--scenario gradual`)
   - Prices: 1.1, 1.2, 1.3, 1.4, 1.5, 1.3, 1.1, 0.9, 0.7, 0.5
   - Tests gradual price movements up and down

3. **Volatile** (`--scenario volatile`)
   - Prices: 1.5, 0.7, 1.8, 0.4, 1.2, 0.9, 2.5, 0.3, 1.0
   - Tests rapid price swings and market volatility

### Custom Scenarios

Create your own price scenarios:

```bash
# Progressive recovery scenario
python3 run_price_test.py \
  --type auto-borrow \
  --prices 0.25,0.5,0.75,1.0,1.5,2.0,3.0 \
  --descriptions "75% crash,50% drop,25% drop,baseline,50% rise,double,triple" \
  --name "Progressive Recovery"

# Flash crash scenario
python3 run_price_test.py \
  --prices 1.0,0.1,0.2,0.5,1.0 \
  --descriptions "Normal,Flash crash,Slight recovery,Half recovery,Full recovery" \
  --name "Flash Crash Event"
```

## Test Output

The enhanced logging provides:

1. **Price Updates**
   ```
   [PRICE UPDATE] Setting FLOW price
      Token Identifier: A.0000000000000003.FlowToken.Vault
      New Price: 0.50000000 MOET
      Previous Price: (not tracked - consider adding if needed)
      Price update successful
   ```

2. **Position/Balance States**
   ```
   [AUTOBALANCER STATE] Before Rebalance
      AutoBalancer ID: 0
      YieldToken Balance: 615.38461538
      YieldToken Price: 0.50000000 MOET
      [CALCULATION] Total Value = Balance * Price
      [CALCULATION] 615.38461538 * 0.50000000 = 307.69230769
      Total Value in MOET: 307.69230769
   ```

3. **Error Prevention**
   ```
   [WARNING] Potential underflow in balance change
      Attempting: 378.69822484 - 615.38461538
      Result would be negative, returning absolute difference
   Balance DECREASED by: 236.68639054
   ```

## Direct Test File Usage

You can also run the price scenario test file directly:

```bash
# Run all tests in the scenario file
flow test --cover ./cadence/tests/price_scenario_test.cdc

# This runs testExtremePriceMovements, testGradualPriceChanges, and testVolatilePriceSwings
```

## Key Features

1. **No Hidden Errors**: All calculations and potential issues are logged
2. **Safe Arithmetic**: Prevents underflow/overflow with explicit warnings
3. **Detailed Calculations**: Shows exact formulas and results
4. **Flexible Scenarios**: Support for any price sequence
5. **Comprehensive Coverage**: Tests both auto-borrow and auto-balancer mechanisms

## Tips for Effective Testing

1. **Start with Presets**: Use the preset scenarios to understand baseline behavior
2. **Test Edge Cases**: Include very low (0.01) and very high (10.0) prices
3. **Vary Speed**: Test both gradual and sudden price changes
4. **Check Recovery**: Always test how the protocol recovers from extreme conditions
5. **Monitor Health**: Pay attention to position health ratios staying within bounds

## Example Test Scenarios

### Market Crash and Recovery
```bash
python3 run_price_test.py \
  --prices 1.0,0.9,0.7,0.5,0.3,0.1,0.3,0.5,0.7,0.9,1.0 \
  --name "Market Crash and Recovery"
```

### Bull Market
```bash
python3 run_price_test.py \
  --prices 1.0,1.2,1.5,2.0,3.0,5.0,4.0,3.5,3.0 \
  --name "Bull Market Run"
```

### Stablecoin Depeg
```bash
python3 run_price_test.py \
  --prices 1.0,0.99,0.95,0.90,0.85,0.90,0.95,0.99,1.0 \
  --name "Stablecoin Depeg Event"
```

## Troubleshooting

1. **Import Errors**: Make sure you're running from the `tidal-sc` directory
2. **Contract Not Found**: Ensure the Flow emulator is running with deployed contracts
3. **Permission Denied**: Make scripts executable with `chmod +x`

## Next Steps

- Analyze test results to identify potential protocol improvements
- Create specific scenarios based on historical market events
- Add more detailed assertions for expected behavior
- Consider automating regular test runs with different scenarios 
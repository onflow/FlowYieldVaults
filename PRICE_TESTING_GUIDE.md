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
python3 verification_results/run_price_test.py --help

# Run a preset scenario
python3 verification_results/run_price_test.py --scenario extreme

# Run custom prices
python3 verification_results/run_price_test.py --prices 0.5,1.0,2.0 --descriptions "Drop 50%,Baseline,Double"

# Test only auto-borrow
python3 verification_results/run_price_test.py --type auto-borrow --scenario volatile

# Test only auto-balancer
python3 verification_results/run_price_test.py --type auto-balancer --prices 0.8,1.2,1.5
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
python3 verification_results/run_price_test.py \
  --type auto-borrow \
  --prices 0.25,0.5,0.75,1.0,1.5,2.0,3.0 \
  --descriptions "75% crash,50% drop,25% drop,baseline,50% rise,double,triple" \
  --name "Progressive Recovery"

# Flash crash scenario
python3 verification_results/run_price_test.py \
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

## Comprehensive Test Commands Used

### Quick Start: Run All Preset Scenarios
```bash
# This runs extreme, gradual, and volatile scenarios (75.5% coverage achieved)
./run_price_scenarios.sh --scenario all
```

### Edge Case Testing

#### Zero/Micro/Extreme Prices
```bash
# Tests: Zero price → full unwind, micro prices, and extreme high prices
python3 verification_results/run_price_test.py --prices 0,0.00000001,1000 \
                         --descriptions "Zero,Micro,VeryHigh" \
                         --name "Edge Prices" \
                         --type auto-borrow
```

#### Price Extremes (Safe Range)
```bash
# Tests: 0.001 to 500x price movements
python3 verification_results/run_price_test.py --prices 0.001,10,100,500 \
                         --descriptions "VeryLow,10x,100x,500x" \
                         --name "Price Extremes" \
                         --type auto-borrow
```

### Market Scenario Testing

#### Rapid Oscillations
```bash
# Tests: 9 rapid price swings to check position degradation
python3 verification_results/run_price_test.py --prices 1,2,0.5,3,0.3,1.5,0.8,2.5,1 \
                         --descriptions "Start,2x,Drop50%,3x,Crash70%,Recover1.5x,Drop20%,2.5x,Stabilize" \
                         --name "Rapid Oscillations" \
                         --type auto-borrow
```

#### Black Swan Event
```bash
# Tests: 99% crash and recovery, health drops to 0.014
python3 verification_results/run_price_test.py --prices 1,0.05,0.01,0.5,1,1.5 \
                         --descriptions "Normal,Crash95%,Crash99%,Recovery50%,FullRecovery,Overshoot" \
                         --name "Black Swan Event" \
                         --type auto-borrow
```

#### Market Crash and Recovery
```bash
# Tests: Progressive crash to 90% drop and recovery
python3 verification_results/run_price_test.py --prices 1.0,0.8,0.5,0.3,0.1,0.5,1.0 \
                         --descriptions "Normal,Drop20%,Drop50%,Drop70%,Drop90%,Recovery50%,FullRecovery" \
                         --name "Market Crash and Recovery" \
                         --type auto-borrow
```

#### Bull Market Run
```bash
# Tests: Price increases up to 5x with corrections
python3 verification_results/run_price_test.py --prices 1.0,1.5,2.0,3.0,5.0,4.0,3.0,2.0 \
                         --descriptions "Start,+50%,2x,3x,5x,Correction20%,Correction40%,Stabilize2x" \
                         --name "Bull Market Run" \
                         --type auto-balancer
```

#### Stablecoin Depeg
```bash
# Tests: Gradual depeg to 20% off and recovery
python3 verification_results/run_price_test.py --prices 1.0,0.99,0.95,0.90,0.80,0.95,1.0 \
                         --descriptions "Pegged,Slight,5%Off,10%Off,20%Off,Recovering,Repegged" \
                         --name "Stablecoin Depeg Event" \
                         --type all
```

### Special Test Files

#### MOET Depeg Test
```bash
# Tests: Unit of account (MOET) losing peg while collateral changes
flow test --cover cadence/tests/moet_depeg_test.cdc
```

#### Concurrent Rebalancing Test
```bash
# Tests: Rapid price changes with double rebalancing attempts
flow test --cover cadence/tests/concurrent_rebalance_test.cdc
```

### Create Your Own Test Suite Script

Save this as `run_all_tests.sh`:
```bash
#!/bin/bash
echo "Running comprehensive Tidal Protocol test suite..."

echo -e "\n1. Running all preset scenarios..."
./run_price_scenarios.sh --scenario all

echo -e "\n2. Testing edge cases..."
python3 verification_results/run_price_test.py --prices 0,0.00000001,1000 --descriptions "Zero,Micro,VeryHigh" --name "Edge Prices" --type auto-borrow

echo -e "\n3. Testing rapid oscillations..."
python3 verification_results/run_price_test.py --prices 1,2,0.5,3,0.3,1.5,0.8,2.5,1 --descriptions "Start,2x,Drop50%,3x,Crash70%,Recover1.5x,Drop20%,2.5x,Stabilize" --name "Rapid Oscillations" --type auto-borrow

echo -e "\n4. Testing black swan event..."
python3 verification_results/run_price_test.py --prices 1,0.05,0.01,0.5,1,1.5 --descriptions "Normal,Crash95%,Crash99%,Recovery50%,FullRecovery,Overshoot" --name "Black Swan Event" --type auto-borrow

echo -e "\n5. Testing MOET depeg..."
flow test --cover cadence/tests/moet_depeg_test.cdc

echo -e "\n6. Testing concurrent rebalancing..."
flow test --cover cadence/tests/concurrent_rebalance_test.cdc

echo -e "\nAll tests completed!"
```

Make it executable: `chmod +x run_all_tests.sh`

## Troubleshooting

1. **Import Errors**: Make sure you're running from the `tidal-sc` directory
2. **Contract Not Found**: Ensure the Flow emulator is running with deployed contracts
3. **Permission Denied**: Make scripts executable with `chmod +x`

## Next Steps

- Analyze test results to identify potential protocol improvements
- Create specific scenarios based on historical market events
- Add more detailed assertions for expected behavior
- Consider automating regular test runs with different scenarios 
# Quick Test Reference for Tidal Protocol

## 🚀 One Command to Run Everything
```bash
./run_all_tests.sh
```

This runs the entire comprehensive test suite (7 test scenarios).

## 📋 Individual Test Commands

### Basic Preset Tests
```bash
# All presets (extreme, gradual, volatile)
./run_price_scenarios.sh --scenario all

# Just extreme volatility
./run_price_scenarios.sh --scenario extreme
```

### Edge Cases
```bash
# Zero, micro, and extreme prices
python3 verification_results/run_price_test.py --prices 0,0.00000001,1000 --descriptions "Zero,Micro,VeryHigh" --name "Edge Prices" --type auto-borrow
```

### Market Scenarios
```bash
# Black Swan (99% crash)
python3 verification_results/run_price_test.py --prices 1,0.05,0.01,0.5,1,1.5 --descriptions "Normal,Crash95%,Crash99%,Recovery50%,FullRecovery,Overshoot" --name "Black Swan Event" --type auto-borrow

# Rapid Oscillations
python3 verification_results/run_price_test.py --prices 1,2,0.5,3,0.3,1.5,0.8,2.5,1 --descriptions "Start,2x,Drop50%,3x,Crash70%,Recover1.5x,Drop20%,2.5x,Stabilize" --name "Rapid Oscillations" --type auto-borrow
```

### Mixed Price Scenarios (NEW!)
```bash
# Default mixed scenario (FLOW and YieldToken move independently)
python3 verification_results/run_mixed_test.py --scenario default

# Inverse correlation
python3 verification_results/run_mixed_test.py --scenario inverse

# Custom mixed prices
python3 verification_results/run_mixed_test.py \
  --flow-prices 1.0,0.5,0.1 \
  --yield-prices 1.0,2.0,3.0 \
  --descriptions "Start,Diverge,Maximum" \
  --name "Custom Divergence"
```

### Special Tests
```bash
# MOET depeg
flow test --cover cadence/tests/moet_depeg_test.cdc

# Concurrent rebalancing
flow test --cover cadence/tests/concurrent_rebalance_test.cdc

# Mixed scenario (BOTH auto-borrow + auto-balancer simultaneously)
flow test --cover cadence/tests/mixed_scenario_test.cdc
```

## 🎯 Test Specific Components

### Auto-Borrow Only
```bash
python3 verification_results/run_price_test.py --scenario extreme --type auto-borrow
```

### Auto-Balancer Only
```bash
python3 verification_results/run_price_test.py --scenario extreme --type auto-balancer
```

### Both with Different Prices
```bash
python3 verification_results/run_mixed_test.py --scenario default
```

## 📊 Expected Results

- **Coverage**: ~75.5% for preset scenarios
- **All tests should PASS**
- **Key observations**:
  - Zero price → position unwinds completely
  - 99% crash → health drops to ~0.014
  - MOET depeg → improves position health
  - Double rebalance → converges more precisely
  - Mixed scenario → auto-balancer can be wiped out while auto-borrow survives

## 🛠️ Prerequisites

1. Flow emulator running
2. Contracts deployed (`flow deploy`)
3. Python 3 installed
4. Scripts made executable (`chmod +x`)

## 💡 Custom Test Template

### Single Token Price Test
```bash
python3 verification_results/run_price_test.py \
  --prices 1.0,0.5,2.0,1.0 \
  --descriptions "Start,Drop50%,Double,Recover" \
  --name "My Custom Test" \
  --type all
```

### Mixed Token Price Test
```bash
python3 verification_results/run_mixed_test.py \
  --flow-prices 1.0,0.5,2.0,1.0 \
  --yield-prices 1.0,1.2,0.8,1.0 \
  --descriptions "Start,Diverge,Cross,Converge" \
  --name "My Mixed Test"
``` 
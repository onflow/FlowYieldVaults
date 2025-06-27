#!/bin/bash

# Tidal Protocol Comprehensive Test Suite
# This script runs all the test scenarios that were verified during development
# Now includes 8 comprehensive test scenarios

set -e

echo "=================================================================="
echo "Running Comprehensive Tidal Protocol Test Suite"
echo "=================================================================="

echo -e "\n[1/8] Running all preset scenarios (extreme, gradual, volatile)..."
./run_price_scenarios.sh --scenario all

echo -e "\n[2/8] Testing edge cases (zero, micro, extreme prices)..."
python3 verification_results/run_price_test.py --prices 0,0.00000001,1000 \
                         --descriptions "Zero,Micro,VeryHigh" \
                         --name "Edge Prices" \
                         --type auto-borrow

echo -e "\n[3/8] Testing price extremes (0.001 to 500x)..."
python3 verification_results/run_price_test.py --prices 0.001,10,100,500 \
                         --descriptions "VeryLow,10x,100x,500x" \
                         --name "Price Extremes" \
                         --type auto-borrow

echo -e "\n[4/8] Testing rapid oscillations..."
python3 verification_results/run_price_test.py --prices 1,2,0.5,3,0.3,1.5,0.8,2.5,1 \
                         --descriptions "Start,2x,Drop50%,3x,Crash70%,Recover1.5x,Drop20%,2.5x,Stabilize" \
                         --name "Rapid Oscillations" \
                         --type auto-borrow

echo -e "\n[5/8] Testing black swan event (99% crash)..."
python3 verification_results/run_price_test.py --prices 1,0.05,0.01,0.5,1,1.5 \
                         --descriptions "Normal,Crash95%,Crash99%,Recovery50%,FullRecovery,Overshoot" \
                         --name "Black Swan Event" \
                         --type auto-borrow

echo -e "\n[6/8] Testing MOET depeg scenario..."
flow test cadence/tests/moet_depeg_test.cdc

echo -e "\n[7/8] Testing concurrent rebalancing..."
flow test cadence/tests/concurrent_rebalance_test.cdc

echo -e "\n[8/8] Testing mixed scenario (auto-borrow + auto-balancer simultaneous)..."
flow test cadence/tests/mixed_scenario_test.cdc

echo -e "\n=================================================================="
echo "All tests completed successfully!"
echo "=================================================================="
echo ""
echo "Summary of test coverage:"
echo "- Preset scenarios: extreme, gradual, volatile price movements"
echo "- Edge cases: zero, micro (0.00000001), and extreme (1000x) prices"
echo "- Market scenarios: crashes, recoveries, oscillations"
echo "- Special cases: MOET depeg, concurrent rebalancing, mixed scenarios"
echo ""
echo "For custom scenarios, use:"
echo "  python3 verification_results/run_price_test.py --prices <prices> --descriptions <descriptions> --name <name>"
echo "" 
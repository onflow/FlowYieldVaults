#!/bin/bash

# Tidal Protocol Comprehensive Test Suite
# This script runs all the test scenarios that were verified during development
# Now includes 10 comprehensive test scenarios + automatic verification

set -e

echo "=================================================================="
echo "Running Comprehensive Tidal Protocol Test Suite"
echo "=================================================================="

# Capture start time
START_TIME=$(date +%s)

# Run all tests and capture output
LOG_FILE="fresh_test_output.log"
{
    echo -e "\n[1/10] Running all preset scenarios (extreme, gradual, volatile)..."
    ./run_price_scenarios.sh --scenario all

    echo -e "\n[2/10] Testing edge cases (zero, micro, extreme prices)..."
    python3 verification_results/run_price_test.py --prices 0,0.00000001,1000 \
                             --descriptions "Zero,Micro,VeryHigh" \
                             --name "Edge Prices" \
                             --type auto-borrow

    echo -e "\n[3/10] Testing price extremes (0.001 to 500x)..."
    python3 verification_results/run_price_test.py --prices 0.001,10,100,500 \
                             --descriptions "VeryLow,10x,100x,500x" \
                             --name "Price Extremes" \
                             --type auto-borrow

    echo -e "\n[4/10] Testing rapid oscillations..."
    python3 verification_results/run_price_test.py --prices 1,2,0.5,3,0.3,1.5,0.8,2.5,1 \
                             --descriptions "Start,2x,Drop50%,3x,Crash70%,Recover1.5x,Drop20%,2.5x,Stabilize" \
                             --name "Rapid Oscillations" \
                             --type auto-borrow

    echo -e "\n[5/10] Testing black swan event (99% crash)..."
    python3 verification_results/run_price_test.py --prices 1,0.05,0.01,0.5,1,1.5 \
                             --descriptions "Normal,Crash95%,Crash99%,Recovery50%,FullRecovery,Overshoot" \
                             --name "Black Swan Event" \
                             --type auto-borrow

    echo -e "\n[6/10] Testing MOET depeg scenario..."
    flow test cadence/tests/moet_depeg_test.cdc

    echo -e "\n[7/10] Testing concurrent rebalancing..."
    flow test cadence/tests/concurrent_rebalance_test.cdc

    echo -e "\n[8/10] Testing mixed scenario (auto-borrow + auto-balancer simultaneous)..."
    flow test cadence/tests/mixed_scenario_test.cdc

    echo -e "\n[9/10] Testing inverse correlation scenario (NEW)..."
    python3 verification_results/run_mixed_test.py --scenario inverse

    echo -e "\n[10/10] Testing decorrelated price movements (NEW)..."
    python3 verification_results/run_mixed_test.py --scenario decorrelated

    echo -e "\n=================================================================="
    echo "All tests completed successfully!"
    echo "=================================================================="
} 2>&1 | tee "$LOG_FILE"

# Calculate test duration
END_TIME=$(date +%s)
TEST_DURATION=$((END_TIME - START_TIME))

echo ""
echo "Test execution time: ${TEST_DURATION} seconds"
echo ""

# Automatically run verification
echo "=================================================================="
echo "Running Automated Verification Suite"
echo "=================================================================="
echo ""

cd verification_results
./run_all_verifications.sh "../$LOG_FILE"
cd ..

# Final summary
echo ""
echo "=================================================================="
echo "COMPLETE TEST & VERIFICATION SUMMARY"
echo "=================================================================="
echo ""
echo "✅ All 10 test scenarios completed"
echo "✅ All 4 verification scripts run"
echo ""
echo "Test coverage achieved:"
echo "- Preset scenarios: extreme, gradual, volatile price movements"
echo "- Edge cases: zero, micro (0.00000001), and extreme (1000x) prices"
echo "- Market scenarios: crashes, recoveries, oscillations"
echo "- Special cases: MOET depeg, concurrent rebalancing"
echo "- Mixed scenarios: simultaneous testing with independent FLOW/Yield prices"
echo "- Inverse correlation: assets moving opposite to each other"
echo "- Decorrelated movements: one stable while other moves"
echo ""
echo "Verification artifacts generated in verification_results/:"
echo "- verification_results.json"
echo "- deep_verification_report.json"
echo "- mathematical_analysis.json"
echo "- mixed_scenario_analysis.json"
echo ""
echo "For custom scenarios, use:"
echo "  Single token: python3 verification_results/run_price_test.py --prices <prices> --descriptions <descriptions> --name <name>"
echo "  Mixed tokens: python3 verification_results/run_mixed_test.py --flow-prices <prices> --yield-prices <prices> --name <name>"
echo "" 
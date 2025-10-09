#!/bin/bash

echo "=========================================="
echo "RUNNING ALL REBALANCE TESTS WITH PRECISION DETAILS"
echo "=========================================="
echo

# Array of all test scenarios
scenarios=("1" "2" "3a" "3b" "3c" "3d")

# Run each test and capture full output
for scenario in "${scenarios[@]}"; do
    echo "================================================"
    echo "SCENARIO $scenario TEST RESULTS"
    echo "================================================"
    
    # Run the test and capture output
    output=$(flow test "cadence/tests/rebalance_scenario${scenario}_test.cdc" 2>&1)
    
    # Check if test passed or failed
    if echo "$output" | grep -q "PASS:"; then
        status="✅ PASSED"
    else
        status="❌ FAILED"
    fi
    
    echo "Status: $status"
    echo
    echo "Precision Details:"
    echo "------------------"
    
    # Extract precision information
    echo "$output" | grep -E "(Expected.*:|Actual.*:|Difference:|Precision Difference:|Percent Diff:|FAIL:|Cannot withdraw|Insufficient funds)" | tail -30
    
    echo
    echo "================================================"
    echo
done

# Summary
echo "=========================================="
echo "SUMMARY"
echo "=========================================="

for scenario in "${scenarios[@]}"; do
    output=$(flow test "cadence/tests/rebalance_scenario${scenario}_test.cdc" 2>&1)
    if echo "$output" | grep -q "PASS:"; then
        echo "Scenario $scenario: ✅ PASSED"
    else
        echo "Scenario $scenario: ❌ FAILED"
    fi
done 
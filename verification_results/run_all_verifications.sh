#!/bin/bash

# Comprehensive Verification Script for Tidal Protocol Tests
# Runs all 6 verification scripts on test output

# Don't exit on error - we want to run all verifications even if some find issues
set -uo pipefail

# Check if log file is provided
if [ $# -eq 0 ]; then
    echo "Usage: $0 <log_file>"
    echo "Example: $0 ../fresh_test_output.log"
    exit 1
fi

LOG_FILE="$1"

# Check if log file exists
if [ ! -f "$LOG_FILE" ]; then
    echo "Error: Log file '$LOG_FILE' not found"
    exit 1
fi

echo "=================================================================="
echo "Running Complete Verification Suite on: $LOG_FILE"
echo "=================================================================="

# Run all verification scripts
# Note: These scripts will output both console results and JSON files

echo -e "\n[1/6] Running basic calculation verification..."
python3 verify_calculations.py "$LOG_FILE"

echo -e "\n[2/6] Running deep verification..."
python3 deep_verify.py "$LOG_FILE"

echo -e "\n[3/6] Running mathematical analysis..."
python3 mathematical_analysis.py "$LOG_FILE"

echo -e "\n[4/6] Running mixed scenario verification..."
python3 mixed_scenario_verify.py "$LOG_FILE"

echo -e "\n[5/6] Running auto-borrow balance verification..."
python3 verify_rebalance_balances.py "$LOG_FILE"

echo -e "\n[6/6] Running auto-balancer balance verification..."
python3 verify_autobalancer_balances.py "$LOG_FILE"

echo -e "\n=================================================================="
echo "Verification Complete!"
echo "=================================================================="
echo ""
echo "Generated verification reports:"
echo "  - verification_results.json       (calculation checks)"
echo "  - deep_verification_report.json   (protocol behavior)"
echo "  - mathematical_analysis.json      (financial metrics)"
echo "  - mixed_scenario_analysis.json    (interaction effects)"
echo "  - auto_borrow_balance_verification.json (auto-borrow balance checks)"
echo "  - auto_balancer_verification.json (auto-balancer balance checks)"
echo ""
echo "Summary of findings:"

# Count errors from each report
if [ -f "verification_results.json" ]; then
    echo -n "  - Calculation errors: "
    grep -c '"calculation_errors"' verification_results.json || echo "0"
fi

if [ -f "deep_verification_report.json" ]; then
    echo -n "  - Deep verification errors: "
    grep -c '"errors"' deep_verification_report.json || echo "0"
fi

if [ -f "mathematical_analysis.json" ]; then
    echo -n "  - Ineffective rebalances: "
    grep -c 'Ineffective rebalance' mathematical_analysis.json || echo "0"
fi

if [ -f "mixed_scenario_analysis.json" ]; then
    echo -n "  - Mixed scenario critical events: "
    grep -o '"critical_events": [0-9]*' mixed_scenario_analysis.json | awk -F': ' '{print $2}' || echo "N/A"
fi

if [ -f "auto_borrow_balance_verification.json" ]; then
    echo -n "  - Auto-borrow balance failures: "
    grep -o '"failed": [0-9]*' auto_borrow_balance_verification.json | head -1 | awk -F': ' '{print $2}' || echo "N/A"
fi

if [ -f "auto_balancer_verification.json" ]; then
    echo -n "  - Auto-balancer balance failures: "
    grep -o '"failed": [0-9]*' auto_balancer_verification.json | head -1 | awk -F': ' '{print $2}' || echo "N/A"
fi

echo "" 
#!/bin/bash

# Comprehensive Verification Script for Tidal Protocol Tests
# Runs all 4 verification scripts on test output

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
# Note: These scripts may return non-zero codes when they find issues
echo -e "\n[1/4] Running calculation verification..."
python3 verify_calculations.py "$LOG_FILE" || true

echo -e "\n[2/4] Running deep verification..."
python3 deep_verify.py "$LOG_FILE" || true

echo -e "\n[3/4] Running mathematical analysis..."
python3 mathematical_analysis.py "$LOG_FILE" || true

echo -e "\n[4/4] Running mixed scenario verification..."
python3 mixed_scenario_verify.py "$LOG_FILE" || true

echo -e "\n=================================================================="
echo "Verification Complete!"
echo "=================================================================="
echo ""
echo "Generated verification reports:"
echo "  - verification_results.json       (calculation checks)"
echo "  - deep_verification_report.json   (protocol behavior)"
echo "  - mathematical_analysis.json      (financial metrics)"
echo "  - mixed_scenario_analysis.json    (interaction effects)"
echo ""

# Count critical issues
if command -v jq &> /dev/null; then
    echo "Summary of findings:"
    CALC_ERRORS=$(jq '.total_errors' verification_results.json 2>/dev/null || echo "N/A")
    DEEP_ERRORS=$(jq '.summary.total_errors' deep_verification_report.json 2>/dev/null || echo "N/A")
    INEFFECTIVE=$(jq '.critical_findings | length' mathematical_analysis.json 2>/dev/null || echo "N/A")
    CRITICAL_EVENTS=$(jq '.summary.critical_events' mixed_scenario_analysis.json 2>/dev/null || echo "N/A")
    
    echo "  - Calculation errors: $CALC_ERRORS"
    echo "  - Deep verification errors: $DEEP_ERRORS"
    echo "  - Ineffective rebalances: $INEFFECTIVE"
    echo "  - Mixed scenario critical events: $CRITICAL_EVENTS"
fi

exit 0 
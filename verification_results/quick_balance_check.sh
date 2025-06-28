#!/bin/bash

# Quick Balance Verification Script
# Runs just the balance verification scripts for auto-borrow and auto-balancer

set -euo pipefail

LOG_FILE="${1:-../fresh_test_output.log}"

if [ ! -f "$LOG_FILE" ]; then
    echo "Error: Log file '$LOG_FILE' not found"
    echo "Usage: $0 [log_file]"
    exit 1
fi

echo "Running balance verification on: $LOG_FILE"
echo "=========================================="

echo -e "\n[1/2] Auto-Borrow Balance Verification:"
echo "--------------------------------------"
python3 verify_rebalance_balances.py "$LOG_FILE"

echo -e "\n[2/2] Auto-Balancer Balance Verification:"
echo "-----------------------------------------"
python3 verify_autobalancer_balances.py "$LOG_FILE"

echo -e "\n=========================================="
echo "Balance verification complete!" 
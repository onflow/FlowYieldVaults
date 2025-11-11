#!/bin/bash

# Deploy minimal contracts needed for scheduled rebalancing test
# For use with: flow emulator --scheduled-transactions --block-time 1s

set -e

echo "Deploying contracts for scheduled rebalancing test..."
echo ""

# Deploy in dependency order to emulator-account (f8d6e0586b0a20c7)
echo "1. Deploying FlowVaultsScheduler (and deps)..."
flow project deploy --network emulator

echo ""
echo "✅ Deployment complete!"
echo ""
echo "Now run the test:"
echo "  flow test cadence/tests/scheduled_rebalance_scenario_test.cdc"
echo ""
echo "The test framework will deploy its own contracts and test."
echo "Watch for automatic execution!"


#!/bin/bash

# Load dynamically deployed addresses if available
if [ -f ./local/deployed_addresses.env ]; then
    echo "=== Loading dynamically deployed addresses ==="
    source ./local/deployed_addresses.env
    echo "USDC_ADDR: $USDC_ADDR"
    echo "WBTC_ADDR: $WBTC_ADDR"
else
    # Fallback to punchswap.env if deployed_addresses.env doesn't exist
    echo "=== Using addresses from punchswap.env (fallback) ==="
    source ./local/punchswap/punchswap.env
    echo "USDC_ADDR: $USDC_ADDR"
    echo "WBTC_ADDR: $WBTC_ADDR"
fi

# Verify addresses are set
if [ -z "$USDC_ADDR" ] || [ -z "$WBTC_ADDR" ]; then
    echo "❌ ERROR: Token addresses not found!"
    exit 1
fi

echo ""
echo "=== Bridging USDC ==="
flow transactions send ./lib/flow-evm-bridge/cadence/transactions/bridge/onboarding/onboard_by_evm_address.cdc $USDC_ADDR --signer emulator-account --gas-limit 9999

echo ""
echo "=== Bridging WBTC ==="
flow transactions send ./lib/flow-evm-bridge/cadence/transactions/bridge/onboarding/onboard_by_evm_address.cdc $WBTC_ADDR --signer emulator-account --gas-limit 9999

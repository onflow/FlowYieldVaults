#!/bin/bash

# Test script to verify the UniswapV3 swap connector fix

echo "=== Testing UniswapV3 Swap Connector Fix ==="
echo ""

# Execute the swap transaction
echo "Executing swap transaction..."
echo "Swapping 1.0 MOET for USDC via UniswapV3..."
echo ""

flow transactions send ./cadence/transactions/connectors/univ3-swap-connector.cdc --signer tidal --gas-limit 9999

if [ $? -eq 0 ]; then
    echo ""
    echo "=== SUCCESS ==="
    echo "Swap transaction executed successfully!"
else
    echo ""
    echo "=== FAILED ==="
    echo "Swap transaction failed. Check error messages above."
    exit 1
fi


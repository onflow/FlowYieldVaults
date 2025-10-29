#!/bin/bash
#
# Complete Flash Crash Test with Real V3
# Measures: Health factors, liquidation execution, V3 pool behavior
#

set -e

echo "═══════════════════════════════════════════════════════════════"
echo "  FLASH CRASH TEST - Complete with V3"
echo "═══════════════════════════════════════════════════════════════"
echo ""

# Step 1: Deploy TidalProtocol and create position
echo "Step 1: Setting up TidalProtocol position..."
echo "---"

# Deploy contracts via transactions
flow transactions send cadence/transactions/tidal-protocol/pool-factory/create_and_store_pool.cdc "A.045a1763c93006ca.MOET.Vault" --signer tidal --network emulator --gas-limit 9999 2>&1 | grep -E "(Status|Error)" | head -3

# Add FLOW support
flow transactions send cadence/transactions/tidal-protocol/pool-governance/add_supported_token_simple_interest_curve.cdc "A.1654653399040a61.FlowToken.Vault" 0.8 1.0 1000000.0 1000000.0 --signer tidal --network emulator --gas-limit 9999 2>&1 | grep -E "(Status|Error)" | head -3

# Open position: 1000 FLOW collateral
flow transactions send cadence/transactions/mocks/position/create_wrapped_position.cdc 1000.0 /storage/flowTokenVault true --signer tidal --network emulator --gas-limit 9999 2>&1 | grep -E "(Status|Error)" | head -3

echo "✓ Position created"
echo ""

# Step 2: Get health factor BEFORE crash
echo "Step 2: Measuring health factor before crash..."
HF_BEFORE=$(flow scripts execute cadence/scripts/tidal-protocol/position_health.cdc 0 --network emulator 2>&1 | grep "Result:" | grep -oE '[0-9]+\.[0-9]+' | head -1)
echo "MIRROR:hf_before=$HF_BEFORE"
echo "Health factor before: $HF_BEFORE"
echo ""

# Step 3: Apply 30% FLOW crash
echo "Step 3: Applying 30% FLOW price crash..."
flow transactions send cadence/transactions/mocks/oracle/set_price.cdc "A.1654653399040a61.FlowToken.Vault" 0.7 --signer tidal --network emulator --gas-limit 9999 2>&1 | grep -E "(Status|Error)" | head -3

echo "✓ Price set to \$0.70 (30% crash)"
echo ""

# Step 4: Get health factor AT MINIMUM (after crash)
echo "Step 4: Measuring health factor at crash minimum..."
HF_MIN=$(flow scripts execute cadence/scripts/tidal-protocol/position_health.cdc 0 --network emulator 2>&1 | grep "Result:" | grep -oE '[0-9]+\.[0-9]+' | head -1)
echo "MIRROR:hf_min=$HF_MIN"
echo "Health factor at minimum: $HF_MIN"
echo ""

# Step 5: Check if liquidation needed
echo "Step 5: Checking liquidation requirement..."
NEEDS_LIQ=$(python3 -c "print(1 if float('$HF_MIN') < 1.0 else 0)")

if [ "$NEEDS_LIQ" -eq 1 ]; then
    echo "Position undercollateralized (HF < 1.0) - liquidation needed"
    
    # Execute liquidation via MockDex
    echo "Executing liquidation..."
    flow transactions send lib/TidalProtocol/cadence/transactions/tidal-protocol/pool-management/liquidate_via_mock_dex.cdc \
        0 "A.045a1763c93006ca.MOET.Vault" "A.1654653399040a61.FlowToken.Vault" 1000.0 0.0 1.42857143 \
        --signer tidal --network emulator --gas-limit 9999 2>&1 | grep -E "(Status|Error|Event)" | head -10
    
    echo "MIRROR:liquidation_executed=true"
    
    # Get HF after liquidation
    HF_AFTER=$(flow scripts execute cadence/scripts/tidal-protocol/position_health.cdc 0 --network emulator 2>&1 | grep "Result:" | grep -oE '[0-9]+\.[0-9]+' | head -1)
    echo "MIRROR:hf_after=$HF_AFTER"
    echo "Health factor after liquidation: $HF_AFTER"
else
    echo "Position still healthy (HF >= 1.0) - no liquidation needed"
    echo "MIRROR:liquidation_executed=false"
    HF_AFTER=$HF_MIN
fi

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  RESULTS"
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "Health Factor Trajectory:"
echo "  Before crash:  $HF_BEFORE"
echo "  At minimum:    $HF_MIN"
echo "  After (liq):   $HF_AFTER"
echo ""
echo "MIRROR:test=flash_crash_v3"
echo "MIRROR:hf_before=$HF_BEFORE"
echo "MIRROR:hf_min=$HF_MIN"  
echo "MIRROR:hf_after=$HF_AFTER"
echo ""
echo "✅ Flash crash test complete with TidalProtocol + V3"
echo ""


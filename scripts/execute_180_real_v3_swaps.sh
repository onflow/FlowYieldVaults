#!/bin/bash
#
# Execute 180 REAL V3 swaps to measure cumulative capacity
# This executes ACTUAL swaps (not quotes) so pool state changes
#

set -e

source local/punchswap/punchswap.env
source local/deployed_addresses.env

MOET_EVM="0x9a7b1d144828c356ec23ec862843fca4a8ff829e"
POOL="0x7386d5D1Df1be98CA9B83Fa9020900f994a4abc5"

# Python simulation parameters
SIM_BASELINE=358000
STEP_SIZE=2000
MAX_SWAPS=180
THRESHOLD=0.05

echo "═══════════════════════════════════════════════════════════════"
echo "  REAL V3 SWAP EXECUTION - 180 Consecutive Swaps"
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "Executing ACTUAL swaps (not quotes) to match Python simulation"
echo "Each swap changes pool state - cumulative impact measured"
echo ""
echo "Simulation baseline: $SIM_BASELINE capacity"
echo "Step size: $STEP_SIZE per swap"
echo "Max swaps: $MAX_SWAPS"
echo ""

# Log file
RESULTS_FILE="test_results/v3_real_swaps_$(date +%Y%m%d_%H%M%S).log"
mkdir -p test_results

{
echo "MIRROR:test=v3_real_swaps"
echo "MIRROR:simulation_baseline=$SIM_BASELINE"
echo "MIRROR:step_size=$STEP_SIZE"
echo ""
} | tee "$RESULTS_FILE"

CUMULATIVE=0
SWAP_NUM=0
INITIAL_PRICE=""
AMOUNT_IN_WEI="2000000000"  # 2000 USDC with 6 decimals

# Execute consecutive swaps
while [ $SWAP_NUM -lt $MAX_SWAPS ] && [ $CUMULATIVE -lt $SIM_BASELINE ]; do
    SWAP_NUM=$((SWAP_NUM + 1))
    
    echo "Executing swap #$SWAP_NUM..."
    
    # Execute REAL swap via router
    SWAP_RESULT=$(cast send $SWAP_ROUTER \
        "exactInputSingle((address,address,uint24,address,uint256,uint256,uint256,uint160))(uint256)" \
        "($USDC_ADDR,$MOET_EVM,3000,$OWNER,9999999999,$AMOUNT_IN_WEI,0,0)" \
        --private-key $PK_ACCOUNT \
        --rpc-url http://localhost:8545 \
        --gas-limit 1000000 2>&1)
    
    # Check if swap succeeded
    STATUS=$(echo "$SWAP_RESULT" | grep "^status" | awk '{print $2}')
    
    if [ "$STATUS" != "1" ] && [ "$STATUS" != "(success)" ]; then
        echo "SWAP FAILED at #$SWAP_NUM"
        echo "$SWAP_RESULT" | grep -E "(Error|revert)"
        echo "MIRROR:exit_reason=swap_failed"
        echo "MIRROR:failed_at_swap=$SWAP_NUM"
        break
    fi
    
    # Extract amount out from logs
    AMOUNT_OUT=$(echo "$SWAP_RESULT" | grep -oE 'data.*0x[0-9a-f]{64}' | tail -1 | grep -oE '0x[0-9a-f]{64}' || echo "0x0")
    AMOUNT_OUT_DEC=$(python3 -c "print(int('$AMOUNT_OUT', 16))" 2>/dev/null || echo "0")
    MOET_OUT=$(python3 -c "print(float($AMOUNT_OUT_DEC) / 1e18)" 2>/dev/null || echo "0")
    
    # Calculate price ratio
    PRICE_RATIO=$(python3 -c "print(float($MOET_OUT) / $STEP_SIZE)" 2>/dev/null || echo "0")
    
    # Store initial price
    if [ -z "$INITIAL_PRICE" ]; then
        INITIAL_PRICE=$PRICE_RATIO
        echo "MIRROR:initial_price=$INITIAL_PRICE" | tee -a "$RESULTS_FILE"
    fi
    
    # Calculate price impact
    PRICE_IMPACT=$(python3 -c "print(abs(($INITIAL_PRICE - $PRICE_RATIO) / $INITIAL_PRICE))" 2>/dev/null || echo "0")
    
    CUMULATIVE=$((CUMULATIVE + STEP_SIZE))
    
    # Log metrics
    {
        echo "MIRROR:swap_num=$SWAP_NUM"
        echo "MIRROR:amount_out=$MOET_OUT"
        echo "MIRROR:price_ratio=$PRICE_RATIO"
        echo "MIRROR:price_impact=$PRICE_IMPACT"
        echo "MIRROR:cumulative=$CUMULATIVE"
    } | tee -a "$RESULTS_FILE"
    
    echo "  Out: $MOET_OUT MOET, Impact: $PRICE_IMPACT, Cumulative: $CUMULATIVE"
    
    # Check threshold
    IMPACT_CHECK=$(python3 -c "print(1 if float($PRICE_IMPACT) > $THRESHOLD else 0)")
    if [ "$IMPACT_CHECK" -eq 1 ]; then
        echo "EXIT: Price impact $PRICE_IMPACT exceeds threshold $THRESHOLD"
        echo "MIRROR:exit_reason=price_impact_exceeded" | tee -a "$RESULTS_FILE"
        break
    fi
    
    # Small delay
    sleep 0.1
done

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  FINAL RESULTS"
echo "═══════════════════════════════════════════════════════════════"

{
echo "MIRROR:final_cumulative=$CUMULATIVE"
echo "MIRROR:simulation_baseline=$SIM_BASELINE"
echo "MIRROR:total_swaps=$SWAP_NUM"
} | tee -a "$RESULTS_FILE"

DIFF=$((SIM_BASELINE - CUMULATIVE))
DIFF_ABS=$(echo $DIFF | tr -d '-')
DIFF_PCT=$(python3 -c "print(abs($DIFF) / $SIM_BASELINE * 100)")

echo ""
echo "V3 Cumulative:       \$$CUMULATIVE"
echo "Simulation Baseline: \$$SIM_BASELINE"
echo "Difference:          \$$DIFF ($DIFF_PCT%)"
echo ""
echo "MIRROR:difference=$DIFF" | tee -a "$RESULTS_FILE"
echo "MIRROR:difference_pct=$DIFF_PCT" | tee -a "$RESULTS_FILE"
echo ""
echo "Results saved to: $RESULTS_FILE"
echo "═══════════════════════════════════════════════════════════════"


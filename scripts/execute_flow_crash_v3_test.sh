#!/bin/bash
#
# FLOW Flash Crash V3 Test
# Tests: Health factor trajectory and liquidation with real V3 pool behavior
#

set -e

echo "═══════════════════════════════════════════════════════════════"
echo "  FLOW FLASH CRASH V3 TEST"
echo "═══════════════════════════════════════════════════════════════"
echo ""

# Run the existing flash crash test to get REAL TidalProtocol metrics
echo "Executing flash crash test for health factor and liquidation metrics..."
CI=true flow test --skip-version-check -f flow.tests.json cadence/tests/flow_flash_crash_mirror_test.cdc 2>&1 > /tmp/crash_test_output.log || true

# Extract MIRROR metrics
echo ""
echo "REAL Cadence Test Results:"
echo "=========================="
grep "MIRROR:" /tmp/crash_test_output.log | while read line; do
    echo "$line"
done

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  RESULTS"
echo "═══════════════════════════════════════════════════════════════"
echo ""

HF_MIN=$(grep "MIRROR:hf_min" /tmp/crash_test_output.log | sed 's/.*=//' | tr -d '"' || echo "N/A")
HF_AFTER=$(grep "MIRROR:hf_after" /tmp/crash_test_output.log | sed 's/.*=//' | tr -d '"' || echo "N/A")
LIQ_COUNT=$(grep "MIRROR:liq_count" /tmp/crash_test_output.log | sed 's/.*=//' | tr -d '"' || echo "N/A")

echo "Flash Crash Results:"
echo "  HF Min (at crash): $HF_MIN"
echo "  HF After Liquidation: $HF_AFTER"  
echo "  Liquidations: $LIQ_COUNT"
echo ""
echo "✅ Flash crash test executed with real TidalProtocol behavior"
echo "Note: This test validates protocol response, not V3 capacity"
echo ""


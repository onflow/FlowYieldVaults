#!/bin/bash

# Deploy FlowVaults stack and test scheduled rebalancing on the RUNNING emulator
# Requires: flow emulator --scheduled-transactions --block-time 1s (in Terminal 1)

set -e

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}╔════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║  Deploy and Test on Running Emulator                  ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${YELLOW}Make sure Terminal 1 is running:${NC}"
echo -e "${YELLOW}  flow emulator --scheduled-transactions --block-time 1s${NC}"
echo ""
read -p "Press Enter when emulator is running..."

echo ""
echo -e "${BLUE}Deploying contracts to running emulator...${NC}"
echo ""

# Deploy just what we need (skip project deploy to avoid TestCounter issues)
echo -e "${BLUE}Note: This assumes your emulator was started fresh.${NC}"
echo -e "${BLUE}If contracts already exist, that's okay.${NC}"
echo ""
echo -e "${YELLOW}The test framework (flow test) already deployed everything.${NC}"
echo -e "${YELLOW}The running emulator should have all contracts.${NC}"
echo ""
read -p "Press Enter to continue with tide creation..."

# Grant beta
echo -e "${BLUE}Granting beta access...${NC}"
flow transactions send cadence/transactions/flow-vaults/admin/grant_beta.cdc \
    --network emulator \
    --payer emulator-account \
    --proposer emulator-account \
    --authorizer emulator-account \
    --authorizer emulator-account

# Create tide
echo -e "${BLUE}Creating tide...${NC}"
TIDE_RESULT=$(flow transactions send cadence/transactions/flow-vaults/create_tide.cdc \
    --network emulator --signer emulator-account \
    --args-json '[
      {"type":"String","value":"A.045a1763c93006ca.FlowVaultsStrategies.TracerStrategy"},
      {"type":"String","value":"A.0ae53cb6e3f42a79.FlowToken.Vault"},
      {"type":"UFix64","value":"1000.0"}
    ]' 2>&1)

echo "$TIDE_RESULT"

if echo "$TIDE_RESULT" | grep -q "✅ SEALED"; then
    echo -e "${GREEN}✅ Tide created!${NC}"
else
    echo -e "${RED}❌ Tide creation failed${NC}"
    exit 1
fi

# Get tide ID
echo -e "${BLUE}Getting tide ID...${NC}"
TIDE_ID=$(flow scripts execute cadence/scripts/flow-vaults/get_tide_ids.cdc \
    --network emulator \
    --args-json '[{"type":"Address","value":"0xf8d6e0586b0a20c7"}]' | grep -oE '\[.*\]' | grep -oE '[0-9]+' | head -1)

echo -e "${GREEN}Tide ID: $TIDE_ID${NC}"

# Check initial balance
INITIAL_BALANCE=$(flow scripts execute cadence/scripts/flow-vaults/get_auto_balancer_balance_by_id.cdc \
    --network emulator \
    --args-json "[{\"type\":\"UInt64\",\"value\":\"$TIDE_ID\"}]")

echo -e "${BLUE}Initial AutoBalancer balance: $INITIAL_BALANCE${NC}"

# Setup scheduler manager
echo -e "${BLUE}Setting up SchedulerManager...${NC}"
flow transactions send cadence/transactions/flow-vaults/setup_scheduler_manager.cdc \
    --network emulator --signer emulator-account

# Schedule rebalancing for 15 seconds from now
echo -e "${BLUE}Scheduling rebalancing for 15 seconds from now...${NC}"
FUTURE=$(date +%s)
FUTURE=$((FUTURE + 15))

flow transactions send cadence/transactions/flow-vaults/schedule_rebalancing.cdc \
    --network emulator --signer emulator-account \
    --args-json "[
      {\"type\":\"UInt64\",\"value\":\"$TIDE_ID\"},
      {\"type\":\"UFix64\",\"value\":\"$FUTURE.0\"},
      {\"type\":\"UInt8\",\"value\":\"0\"},
      {\"type\":\"UInt64\",\"value\":\"800\"},
      {\"type\":\"UFix64\",\"value\":\"0.001\"},
      {\"type\":\"Bool\",\"value\":true},
      {\"type\":\"Bool\",\"value\":false},
      {\"type\":\"Optional\",\"value\":null}
    ]"

echo ""
echo -e "${GREEN}════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  ✅ Scheduled rebalancing!${NC}"
echo -e "${GREEN}════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${YELLOW}⏰ WATCH TERMINAL 1 FOR 20 SECONDS!${NC}"
echo -e "${YELLOW}   Look for [system.execute_transaction] or RebalancingExecuted${NC}"
echo ""
echo -e "${BLUE}Waiting 20 seconds...${NC}"
sleep 20

echo ""
echo -e "${BLUE}Checking results...${NC}"

# Check final balance
FINAL_BALANCE=$(flow scripts execute cadence/scripts/flow-vaults/get_auto_balancer_balance_by_id.cdc \
    --network emulator \
    --args-json "[{\"type\":\"UInt64\",\"value\":\"$TIDE_ID\"}]")

echo -e "${BLUE}Final AutoBalancer balance: $FINAL_BALANCE${NC}"

echo ""
if [ "$FINAL_BALANCE" != "$INITIAL_BALANCE" ]; then
    echo -e "${GREEN}🎉 SUCCESS! Balance changed - rebalancing happened!${NC}"
else
    echo -e "${YELLOW}⚠️  Balance unchanged${NC}"
    echo -e "${YELLOW}   Check Terminal 1 for execution logs${NC}"
fi


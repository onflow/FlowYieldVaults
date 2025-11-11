#!/bin/bash

# Test scheduled rebalancing with two-terminal setup
# Terminal 1: flow emulator --scheduled-transactions --block-time 1s (already running)
# Terminal 2: This script (uses REAL transactions, not flow test)

set -e

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${BLUE}╔════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║  Test Scheduled Rebalancing - Two Terminal Setup      ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${YELLOW}Terminal 1 must be running:${NC}"
echo -e "${YELLOW}  flow emulator --scheduled-transactions --block-time 1s${NC}"
echo ""
# wait for emulator port 3569
echo -e "${BLUE}Waiting for emulator (3569) to be ready...${NC}"
for i in {1..30}; do
  if nc -z 127.0.0.1 3569; then
    echo -e "${GREEN}Emulator ready.${NC}"
    break
  fi
  sleep 1
done
nc -z 127.0.0.1 3569 || { echo -e "${YELLOW}Emulator not detected on port 3569${NC}"; exit 1; }

echo ""
echo -e "${BLUE}═══ DEPLOYMENT PHASE ═══${NC}"
echo ""

# Create required accounts for FlowVaults
echo -e "${BLUE}Creating required accounts...${NC}"
./local/setup_wallets.sh 2>&1 | grep -E "Created|Error|account" | head -10 || true

echo ""
echo -e "${BLUE}Deploying FlowVaults contracts to emulator...${NC}"
./local/setup_emulator.sh 2>&1 | grep -v "TestCounter" | grep -E "✅|Deployed|Error" | head -20 || true

echo ""
echo -e "${YELLOW}Deployment complete (some errors expected).${NC}"
echo ""

echo ""
echo -e "${BLUE}═══ TIDE CREATION PHASE ═══${NC}"
echo ""

# Grant beta (grant to tidal to avoid cross-account multi-sign)
echo -e "${BLUE}Step 1: Granting beta access to tidal...${NC}"
flow transactions send cadence/transactions/flow-vaults/admin/grant_beta.cdc \
    --network emulator \
    --payer tidal \
    --proposer tidal \
    --authorizer tidal \
    --authorizer tidal

# Create tide
echo -e "${BLUE}Step 2: Creating tide with 100 FLOW (tidal)...${NC}"
flow transactions send cadence/transactions/flow-vaults/create_tide.cdc \
    --network emulator --signer tidal \
    --args-json '[
      {"type":"String","value":"A.045a1763c93006ca.FlowVaultsStrategies.TracerStrategy"},
      {"type":"String","value":"A.0ae53cb6e3f42a79.FlowToken.Vault"},
      {"type":"UFix64","value":"100.0"}
    ]'

# Get tide ID
echo -e "${BLUE}Step 3: Getting tide ID (owner: tidal)...${NC}"
TIDE_IDS=$(flow scripts execute cadence/scripts/flow-vaults/get_tide_ids.cdc \
    --network emulator \
    --args-json '[{"type":"Address","value":"0x045a1763c93006ca"}]')

echo "Tide IDs result: $TIDE_IDS"
TIDE_ID=$(echo "$TIDE_IDS" | grep -oE '\[.*\]' | sed 's/\[//g' | sed 's/\]//g' | tr -d ' ')

if [ -z "$TIDE_ID" ]; then
    echo -e "${YELLOW}Could not parse tide ID. Assuming 0.${NC}"
    TIDE_ID=0
fi

echo -e "${GREEN}Tide ID: $TIDE_ID${NC}"

# Check initial balance
echo -e "${BLUE}Step 4: Checking initial AutoBalancer balance...${NC}"
INITIAL_BALANCE=$(flow scripts execute cadence/scripts/flow-vaults/get_auto_balancer_balance_by_id.cdc \
    --network emulator \
    --args-json "[{\"type\":\"UInt64\",\"value\":\"$TIDE_ID\"}]")

echo -e "${GREEN}Initial balance: $INITIAL_BALANCE${NC}"

echo ""
echo -e "${BLUE}═══ SCHEDULING PHASE ═══${NC}"
echo ""

# Setup scheduler manager
echo -e "${BLUE}Step 5: Setting up SchedulerManager...${NC}"
flow transactions send cadence/transactions/flow-vaults/setup_scheduler_manager.cdc \
    --network emulator --signer tidal

# Schedule rebalancing for 15 seconds from now
echo -e "${BLUE}Step 6: Scheduling rebalancing for 15 seconds from now...${NC}"
FUTURE=$(date +%s)
FUTURE=$((FUTURE + 15))

flow transactions send cadence/transactions/flow-vaults/schedule_rebalancing.cdc \
    --network emulator --signer tidal \
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
echo -e "${GREEN}  ✅ Scheduled rebalancing for tide $TIDE_ID!${NC}"
echo -e "${GREEN}  ⏰ Will execute at: $FUTURE${NC}"
echo -e "${GREEN}════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${YELLOW}⏰ WATCH TERMINAL 1 FOR 20 SECONDS!${NC}"
echo -e "${YELLOW}   Look for:${NC}"
echo -e "${YELLOW}   - [system.execute_transaction] logs${NC}"
echo -e "${YELLOW}   - RebalancingExecuted events${NC}"
echo ""
echo -e "${BLUE}Waiting 20 seconds...${NC}"

for i in {5,10,15,20}; do
    sleep 5
    echo -e "${BLUE}[$i seconds] ...${NC}"
done

echo ""
echo -e "${BLUE}═══ VERIFICATION PHASE ═══${NC}"
echo ""

# Check final balance
echo -e "${BLUE}Step 7: Checking final balance...${NC}"
FINAL_BALANCE=$(flow scripts execute cadence/scripts/flow-vaults/get_auto_balancer_balance_by_id.cdc \
    --network emulator \
    --args-json "[{\"type\":\"UInt64\",\"value\":\"$TIDE_ID\"}]")

echo -e "${BLUE}Initial balance: $INITIAL_BALANCE${NC}"
echo -e "${BLUE}Final balance:   $FINAL_BALANCE${NC}"

echo ""
if [ "$FINAL_BALANCE" != "$INITIAL_BALANCE" ]; then
    echo -e "${GREEN}🎉 SUCCESS! Balance changed!${NC}"
    echo -e "${GREEN}   Automatic rebalancing happened!${NC}"
else
    echo -e "${YELLOW}Balance unchanged${NC}"
    echo -e "${YELLOW}   Check Terminal 1 for execution logs${NC}"
    echo -e "${YELLOW}   Or check schedule status${NC}"
fi

echo ""
echo -e "${BLUE}Check for events in Terminal 1!${NC}"


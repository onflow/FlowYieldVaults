#!/bin/bash

# Redeploy contracts on testnet with correct import resolution
# Fixes type mismatch issues by removing and redeploying in dependency order

set -e

SIGNER="keshav-scheduled-testnet"
NETWORK="testnet"

# Force network configuration
export FLOW_NETWORK="testnet"

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}╔════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║  Redeploy Contracts with Correct Imports              ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${YELLOW}This will remove and redeploy contracts to fix type mismatches${NC}"
echo -e "${YELLOW}Network: $NETWORK${NC}"
echo -e "${YELLOW}Signer: $SIGNER${NC}"
echo ""

# Step 1: Remove contracts in reverse dependency order
echo -e "${BLUE}Step 1/5: Removing TestStrategyWithAutoBalancer...${NC}"
flow accounts remove-contract TestStrategyWithAutoBalancer \
    --host=access.testnet.nodes.onflow.org:9000 --signer=$SIGNER \
    && echo -e "${GREEN}   ✅ Removed TestStrategyWithAutoBalancer${NC}" \
    || echo -e "${YELLOW}   ⚠️  TestStrategyWithAutoBalancer not found or already removed${NC}"

echo ""
echo -e "${BLUE}Step 2/5: Removing FlowVaults...${NC}"
flow accounts remove-contract FlowVaults \
    --host=access.testnet.nodes.onflow.org:9000 --signer=$SIGNER \
    && echo -e "${GREEN}   ✅ Removed FlowVaults${NC}" \
    || echo -e "${YELLOW}   ⚠️  FlowVaults not found or already removed${NC}"

# Step 2: Redeploy contracts in dependency order
echo ""
echo -e "${BLUE}Step 3/5: Redeploying FlowVaults...${NC}"
flow accounts add-contract cadence/contracts/FlowVaults.cdc \
    --network=$NETWORK --signer=$SIGNER \
    && echo -e "${GREEN}   ✅ FlowVaults deployed${NC}" \
    || { echo -e "${RED}   ❌ FlowVaults deployment failed${NC}"; exit 1; }

echo ""
echo -e "${BLUE}Step 4/5: Redeploying TestStrategyWithAutoBalancer...${NC}"
flow accounts add-contract cadence/contracts/TestStrategyWithAutoBalancer.cdc \
    --network=$NETWORK --signer=$SIGNER \
    && echo -e "${GREEN}   ✅ TestStrategyWithAutoBalancer deployed${NC}" \
    || { echo -e "${RED}   ❌ TestStrategyWithAutoBalancer deployment failed${NC}"; exit 1; }

# Step 3: Add strategy composer
echo ""
echo -e "${BLUE}Step 5/5: Registering TestStrategyWithAutoBalancer...${NC}"
flow transactions send cadence/transactions/test/add_test_strategy.cdc \
    --network=$NETWORK --signer=$SIGNER \
    && echo -e "${GREEN}   ✅ Strategy registered${NC}" \
    || { echo -e "${RED}   ❌ Strategy registration failed${NC}"; exit 1; }

echo ""
echo -e "${GREEN}════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  ✅ All contracts redeployed successfully!${NC}"
echo -e "${GREEN}════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${BLUE}Next: Create a tide${NC}"
echo ""
echo -e "flow transactions send cadence/transactions/flow-vaults/create_tide.cdc \\"
echo -e "    -n testnet --signer $SIGNER \\"
echo -e "    --args-json '["
echo -e '      {"type":"String","value":"A.425216a69bec3d42.TestStrategyWithAutoBalancer.Strategy"},'
echo -e '      {"type":"String","value":"A.7e60df042a9c0868.FlowToken.Vault"},'
echo -e '      {"type":"UFix64","value":"100.0"}'
echo -e "    ]'"
echo ""


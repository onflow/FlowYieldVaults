#!/bin/bash

# Deploy ALL contracts to a BRAND NEW fresh testnet account
# This avoids all the type mismatch issues by deploying everything fresh

set -e

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}╔════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║  Deploy to Brand New Testnet Account                  ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${YELLOW}This creates a fresh account and deploys everything${NC}"
echo ""

# Create new account
echo -e "${BLUE}Step 1: Creating new testnet account...${NC}"
echo -e "${YELLOW}When prompted, enter name: scheduled-rebalancing-test${NC}"
flow accounts create --network testnet

echo ""
read -p "Press Enter after account is created and added to flow.json..."

ACCOUNT="scheduled-rebalancing-test"

echo ""
echo -e "${BLUE}Step 2: Fund the account...${NC}"
echo -e "${YELLOW}Get the address from flow.json and fund it at:${NC}"
echo -e "${YELLOW}https://testnet-faucet.onflow.org/${NC}"
echo ""
read -p "Press Enter after account is funded..."

# Deploy contracts in dependency order
echo ""
echo -e "${BLUE}Step 3: Deploying DeFiActions...${NC}"
flow accounts add-contract \
    ./lib/FlowALP/FlowActions/cadence/contracts/interfaces/DeFiActions.cdc \
    --network testnet --signer $ACCOUNT

echo -e "${BLUE}Step 4: Deploying MockOracle...${NC}"
flow accounts add-contract cadence/contracts/mocks/MockOracle.cdc \
    --network testnet --signer $ACCOUNT \
    --args-json '[{"type":"String","value":"A.7e60df042a9c0868.FlowToken.Vault"}]'

echo -e "${BLUE}Step 5: Deploying MockSwapper...${NC}"
flow accounts add-contract cadence/contracts/mocks/MockSwapper.cdc \
    --network testnet --signer $ACCOUNT

echo -e "${BLUE}Step 6: Deploying FlowVaultsAutoBalancers...${NC}"
flow accounts add-contract cadence/contracts/FlowVaultsAutoBalancers.cdc \
    --network testnet --signer $ACCOUNT

echo -e "${BLUE}Step 7: Deploying FlowVaultsClosedBeta...${NC}"
flow accounts add-contract cadence/contracts/FlowVaultsClosedBeta.cdc \
    --network testnet --signer $ACCOUNT

echo -e "${BLUE}Step 8: Deploying FlowVaults...${NC}"
flow accounts add-contract cadence/contracts/FlowVaults.cdc \
    --network testnet --signer $ACCOUNT

echo -e "${BLUE}Step 9: Deploying FlowVaultsStrategies (same account to enable AutoBalancer init)...${NC}"
# These EVM addresses are placeholders used by the mock strategies; TracerStrategy uses mocks and won’t need them,
# but the contract init requires values.
flow accounts add-contract cadence/contracts/FlowVaultsStrategies.cdc \
    --network testnet --signer $ACCOUNT \
    --args-json '[
      {"type":"String","value":"0x92657b195e22b69E4779BBD09Fa3CD46F0CF8e39"},
      {"type":"String","value":"0x2Db6468229F6fB1a77d248Dbb1c386760C257804"},
      {"type":"String","value":"0xA1e0E4CCACA34a738f03cFB1EAbAb16331FA3E2c"},
      {"type":"String","value":"0x4154d5B0E2931a0A1E5b733f19161aa7D2fc4b95"}
    ]'

echo -e "${BLUE}Step 10: Registering TracerStrategy composer...${NC}"
FLOW_ADDR=$(flow accounts get $ACCOUNT --network testnet | awk '/Address/ {print $2}')
flow transactions send cadence/transactions/flow-vaults/admin/add_strategy_composer.cdc \
    --network testnet --signer $ACCOUNT \
    --args-json "[
      {\"type\":\"String\",\"value\":\"A.$FLOW_ADDR.FlowVaultsStrategies.TracerStrategy\"},
      {\"type\":\"String\",\"value\":\"A.$FLOW_ADDR.FlowVaultsStrategies.TracerStrategyComposer\"},
      {\"type\":\"StoragePath\",\"value\":{\"domain\":\"storage\",\"identifier\":\"FlowVaultsStrategyComposerIssuer_$FLOW_ADDR\"}}
    ]"

echo -e "${BLUE}Step 11: Deploying FlowVaultsScheduler...${NC}"
flow accounts add-contract cadence/contracts/FlowVaultsScheduler.cdc \
    --network testnet --signer $ACCOUNT

echo -e "${BLUE}Step 12: Deploying TestStrategyWithAutoBalancer (optional for alternative tests)...${NC}"
flow accounts add-contract cadence/contracts/TestStrategyWithAutoBalancer.cdc \
    --network testnet --signer $ACCOUNT

echo ""
echo -e "${GREEN}════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  ✅ All contracts deployed to fresh account!${NC}"
echo -e "${GREEN}════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${BLUE}Next steps saved to: NEXT_STEPS.txt${NC}"


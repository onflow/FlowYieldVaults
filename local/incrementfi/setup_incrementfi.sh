#!/bin/sh
#set -e

# Constants
SIGNER="mock-incrementfi"

# Helper functions
echo_info() {
  echo "\033[1;34m[INFO]\033[0m $1"
}

# # 1. Create a new Flow account with the test user's pubkey
# echo_info "Creating new Flow account for test user..."
# flow accounts create --network "$FLOW_NETWORK" --key "$(cat $TEST_USER_PUBKEY_PATH)"

flow transactions send "./cadence/transactions/flow-token/transfer_flow.cdc" 0xf3fcd2c1a78f5eee 1000.0
flow transactions send "./cadence/transactions/flow-token/transfer_flow.cdc" 0x045a1763c93006ca 1000.0

# 2. Setup MOET and YIELD vault, and create swap pairs
#
MOET_IDENTIFIER=$(flow scripts execute ./cadence/scripts/mocks/incrementfi/get_moet_token_identifier.cdc | grep "^Result:" | sed -E 's/Result: "([^"]+)"/\1/')
YIELD_IDENTIFIER=$(flow scripts execute ./cadence/scripts/mocks/incrementfi/get_yield_token_identifier.cdc | grep "^Result:" | sed -E 's/Result: "([^"]+)"/\1/')


SWAP_PAIR_HEX=$(./local/incrementfi/generate-swap-pair-tx.sh)

flow transactions send ./cadence/transactions/mocks/incrementfi/setup.cdc ${SWAP_PAIR_HEX} --signer ${SIGNER}

#
# 3. transfer funds to FLOW, MOET, and YIELD vaults
#
flow transactions send ./cadence/transactions/mocks/incrementfi/transfer_amm_tokens.cdc f3fcd2c1a78f5eee 1000.0 --signer emulator-flow-yield-vaults
# 
# 4. create swap pair
#
flow transactions send ./lib/FlowCreditMarket/FlowActions/cadence/transactions/increment-fi/create_swap_pair.cdc $MOET_IDENTIFIER $YIELD_IDENTIFIER false --signer emulator-flow-yield-vaults
#
#
# 5. add liquidity to the AMMs
#
MOET_KEY="${MOET_IDENTIFIER%.*}"
YIELD_KEY="${YIELD_IDENTIFIER%.*}"
BLOCK_TS=$(flow blocks get latest | grep -i 'Proposal Timestamp Unix' | awk '{print $NF}')
DEADLINE=$((BLOCK_TS + 600))

echo $MOET_KEY
echo $YIELD_KEY
echo $DEADLINE
flow transactions send "./lib/FlowCreditMarket/FlowActions/cadence/transactions/increment-fi/add_liquidity.cdc" \
	"$MOET_KEY" \
	"$YIELD_KEY" \
	100.0 \
	100.0 \
	0.0 \
	0.0 \
	$DEADLINE.0 \
	/storage/moetTokenVault_0x045a1763c93006ca \
	/storage/yieldTokenVault_0x045a1763c93006ca \
	false \
	--signer $SIGNER
#
# 6. add connectors
#
#

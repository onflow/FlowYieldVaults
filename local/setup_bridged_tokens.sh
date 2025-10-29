#!/bin/bash

# Always load the base environment for other variables (RPC_URL, PK_ACCOUNT, etc.)
source ./local/punchswap/punchswap.env

# Then optionally override token addresses with dynamically deployed ones
if [ -f ./local/deployed_addresses.env ]; then
    echo "=== Loading dynamically deployed addresses ==="
    source ./local/deployed_addresses.env
    echo "USDC_ADDR: $USDC_ADDR"
    echo "WBTC_ADDR: $WBTC_ADDR"
else
    echo "=== Using token addresses from punchswap.env ==="
    echo "USDC_ADDR: $USDC_ADDR"
    echo "WBTC_ADDR: $WBTC_ADDR"
fi

# Verify addresses are set
if [ -z "$USDC_ADDR" ] || [ -z "$WBTC_ADDR" ]; then
    echo "❌ ERROR: Token addresses not found!"
    exit 1
fi

echo ""
echo "bridge USDC to Cadence"
flow transactions send ./lib/flow-evm-bridge/cadence/transactions/bridge/onboarding/onboard_by_evm_address.cdc $USDC_ADDR --signer emulator-account --gas-limit 9999 --signer tidal

echo "set USDC token price"
# Dynamically construct the type identifier from the actual USDC address
USDC_TYPE_ID="A.f8d6e0586b0a20c7.EVMVMBridgedToken_$(echo $USDC_ADDR | sed 's/0x//' | tr '[:upper:]' '[:lower:]').Vault"
flow transactions send ./cadence/transactions/mocks/oracle/set_price.cdc "$USDC_TYPE_ID" 1.0 --signer tidal

echo "bridge WBTC to Cadence"
flow transactions send ./lib/flow-evm-bridge/cadence/transactions/bridge/onboarding/onboard_by_evm_address.cdc $WBTC_ADDR --signer emulator-account --gas-limit 9999 --signer tidal

echo "bridge MOET to EVM"
flow transactions send ./lib/flow-evm-bridge/cadence/transactions/bridge/onboarding/onboard_by_type_identifier.cdc "A.045a1763c93006ca.MOET.Vault" --signer emulator-account --gas-limit 9999 --signer tidal

#flow transactions send ../cadence/tests/transactions/create_univ3_pool.cdc

MOET_EVM_ADDRESS=0x$(flow scripts execute ./cadence/tests/scripts/get_moet_evm_address.cdc --format inline | sed -E 's/"([^"]+)"/\1/')

echo "create pool"
cast send $POSITION_MANAGER \
	"createAndInitializePoolIfNecessary(address,address,uint24,uint160)(address)" \
	$MOET_EVM_ADDRESS $USDC_ADDR 3000 79228162514264337593543950336 \
	--private-key $PK_ACCOUNT \
	--rpc-url $RPC_URL \
	--gas-limit 10000000

MAX_UINT=0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff

echo "approve MOET"
cast send $MOET_EVM_ADDRESS "approve(address,uint256)" $POSITION_MANAGER $MAX_UINT \
  --private-key $PK_ACCOUNT --rpc-url $RPC_URL --gas-limit 150000

echo "approve USDC"
cast send $USDC_ADDR "approve(address,uint256)" $POSITION_MANAGER $MAX_UINT \
  --private-key $PK_ACCOUNT --rpc-url $RPC_URL --gas-limit 150000

echo "transfer MOET"

flow transactions send ./lib/flow-evm-bridge/cadence/transactions/bridge/tokens/bridge_tokens_to_any_evm_address.cdc "A.045a1763c93006ca.MOET.Vault" 100000.0 $OWNER --gas-limit 9999 --signer tidal

# create position / add liquidity

# 1h from now
DEADLINE=$(printf %d $(( $(date +%s) + 3600 )))
TICK_LOWER=-600
TICK_UPPER=600

# desired deposits
A0=1000000000000
A1=1000000000000
# min amounts with ~1% slippage buffer (EDIT if you like)
A0_MIN=$(cast --from-wei $A0 | awk '{printf "%.0f", $1*0.99*1e18}')
A1_MIN=$(cast --from-wei $A1 | awk '{printf "%.0f", $1*0.99*1e18}')
#
#
echo "mint position"
cast send $POSITION_MANAGER \
  "mint((address,address,uint24,int24,int24,uint256,uint256,uint256,uint256,address,uint256))" \
  "($MOET_EVM_ADDRESS,$USDC_ADDR,3000,$TICK_LOWER,$TICK_UPPER,$A0,$A1,$A0_MIN,$A1_MIN,$OWNER,$DEADLINE)" \
  --private-key $PK_ACCOUNT \
  --rpc-url $RPC_URL \
  --gas-limit 1200000

source ./local/punchswap/punchswap.env

echo "bridge USDC to Cadence"
flow transactions send ./lib/flow-evm-bridge/cadence/transactions/bridge/onboarding/onboard_by_evm_address.cdc 0xaCCF0c4EeD4438Ad31Cd340548f4211a465B6528 --signer emulator-account --gas-limit 9999

echo "bridge WBTC to Cadence"
flow transactions send ./lib/flow-evm-bridge/cadence/transactions/bridge/onboarding/onboard_by_evm_address.cdc 0x374BF2423c6b67694c068C3519b3eD14d3B0C5d1 --signer emulator-account --gas-limit 9999

echo "bridge MOET to EVM"
flow transactions send ./lib/flow-evm-bridge/cadence/transactions/bridge/onboarding/onboard_by_type_identifier.cdc "A.f3fcd2c1a78f5eee.MOET.Vault" --signer emulator-account --gas-limit 9999

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

# transfer MOET

flow transactions send ./lib/flow-evm-bridge/cadence/transactions/bridge/tokens/bridge_tokens_to_any_evm_address.cdc "A.f3fcd2c1a78f5eee.MOET.Vault" 100000.0 $OWNER --gas-limit 10000
#
# transfer USDC
#
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


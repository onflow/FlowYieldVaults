./local/run_emulator.sh

./local/setup_wallets.sh

./local/run_evm_gateway.sh

echo "setup PunchSwap"

./local/punchswap/setup_punchswap.sh

# echo "Setup EVM bridge"
#
# forge script ./solidity/script/01_DeployBridge.s.sol:DeployBridge \
#   --rpc-url http://127.0.0.1:8545 --broadcast --legacy --gas-price 0 --slow

./local/punchswap/e2e_punchswap.sh

echo "Setup emulator"
./local/setup_emulator.sh

./local/setup_bridged_tokens.sh

#
# CODE_HEX=$(xxd -p -c 200000 ./cadence/contracts/PunchSwapV3Connector.cdc)
# flow transactions send ./cadence/tx/deploy_punchswap_connector.cdc \
#   --network emulator \
#   --signer emulator-account \
#   --arg String:PunchSwapV3Connector \
#   --arg String:$CODE_HEX

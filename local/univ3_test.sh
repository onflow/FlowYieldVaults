./local/run_emulator.sh

./local/setup_wallets.sh

./local/run_evm_gateway.sh

echo "setup PunchSwap"

./local/punchswap/setup_punchswap.sh

echo "Setup EVM bridge"

cd ./lib/flow-evm-bridge/
forge script ./solidity/script/DeployFactoryStatic.s.sol \
  --rpc-url http://127.0.0.1:8545 --broadcast --legacy --gas-price 0 --slow

cd ../..

./local/punchswap/e2e_punchswap.sh

echo "Setup emulator"
./local/setup_emulator.sh

flow transactions send ./lib/flow-evm-bridge/cadence/transactions/bridge/admin/pause/update_bridge_pause_status.cdc false --signer evm-gateway

flow transactions send ./lib/TidalProtocol/DeFiActions/cadence/transactions/evm/create_coa.cdc 1.0 --signer evm-gateway

# flow transactions send ./lib/flow-evm-bridge/cadence/transactions/bridge/onboarding/onboard_by_evm_address.cdc 0x19b8169f4dd93a7360a5fc4d4ded1bc2a660d5b7 --signer evm-gateway
#
# flow transactions send ./lib/flow-evm-bridge/cadence/transactions/bridge/onboarding/onboard_by_evm_address.cdc 0x30c6cdd83cf20d62052dd78c798006a22cdb1141 --signer evm-gateway
#
# CODE_HEX=$(xxd -p -c 200000 ./cadence/contracts/PunchSwapV3Connector.cdc)
# flow transactions send ./cadence/tx/deploy_punchswap_connector.cdc \
#   --network emulator \
#   --signer emulator-account \
#   --arg String:PunchSwapV3Connector \
#   --arg String:$CODE_HEX

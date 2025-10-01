./local/run_emulator.sh

./local/setup_wallets.sh

./local/run_evm_gateway.sh

echo "setup PunchSwap"

./local/punchswap/setup_punchswap.sh

echo "Setup EVM bridge"

forge script ./solidity/script/DeployFactoryStatic.s.sol:DeployFactoryStaticLocal \
  --rpc-url http://127.0.0.1:8545 --broadcast --legacy --gas-price 0 --slow

./local/punchswap/e2e_punchswap.sh

echo "Setup emulator"
./local/setup_emulator.sh

flow transactions send ./lib/flow-evm-bridge/cadence/transactions/bridge/admin/pause/update_bridge_pause_status.cdc false --signer emulator-account

flow transactions send ./lib/TidalProtocol/DeFiActions/cadence/transactions/evm/create_coa.cdc 1.0 --signer emulator-account

# flow transactions send ./lib/flow-evm-bridge/cadence/transactions/bridge/onboarding/onboard_by_evm_address.cdc 0x85bF166c3B790c2373D67D8F5A3a2B7ABCbcFB5e --signer evm-gateway
#
# flow transactions send ./lib/flow-evm-bridge/cadence/transactions/bridge/onboarding/onboard_by_evm_address.cdc 0x7D0dc024FF9893B59cA80b9a274567B99a9D4A2D --signer evm-gateway
#
# CODE_HEX=$(xxd -p -c 200000 ./cadence/contracts/PunchSwapV3Connector.cdc)
# flow transactions send ./cadence/tx/deploy_punchswap_connector.cdc \
#   --network emulator \
#   --signer emulator-account \
#   --arg String:PunchSwapV3Connector \
#   --arg String:$CODE_HEX

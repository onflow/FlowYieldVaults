
export FLOW_BRIDGE_FACTORY=0x3fa8deb58571ffff2e4325bd2f633b7db3302501
export FLOW_EVM_BRIDGED_ERC20_DEPLOYER=0xf0cb8f5149245f143040ea7704fb831a25adaa08
export FLOW_EVM_BRIDGED_ERC721_DEPLOYER=0xa993b7584838082b19cecedaa7295bb5a1598e1c
export FLOW_BRIDGE_DEPLOYMENT_REGISTRY=0x68ea933793106df2e8c9693faa126ede13fee7cd

flow transactions send ./lib/flow-evm-bridge/cadence/transactions/bridge/admin/pause/update_bridge_pause_status.cdc false --signer emulator-account

flow transactions send ./lib/TidalProtocol/DeFiActions/cadence/transactions/evm/create_coa.cdc 1.0 --signer emulator-account

COA=$(flow scripts execute ./lib/flow-evm-bridge/cadence/scripts/evm/get_evm_address_string.cdc f8d6e0586b0a20c7 -o inline 2>/dev/null | awk -F'"' '{print $2}')


cast send $FLOW_BRIDGE_FACTORY "transferOwnership(address)" $COA --rpc-url $RPC_URL --private-key $PK_ACCOUNT
cast send $FLOW_EVM_BRIDGED_ERC20_DEPLOYER "transferOwnership(address)" $COA --rpc-url $RPC_URL --private-key $PK_ACCOUNT
cast send $FLOW_EVM_BRIDGED_ERC721_DEPLOYER "transferOwnership(address)" $COA --rpc-url $RPC_URL --private-key $PK_ACCOUNT
cast send $FLOW_BRIDGE_DEPLOYMENT_REGISTRY "transferOwnership(address)" $COA --rpc-url $RPC_URL --private-key $PK_ACCOUNT


# # Set factory as registrar in registry
# flow transactions send ./lib/TidalProtocol/DeFiActions/cadence/tests/transactions/bridge/setup/set_registrar.cdc 0x68ea933793106df2e8c9693faa126ede13fee7cd --signer emulator-account --gas-limit 10000
#
# # Set registry as registry in factory
# flow transactions send ./lib/TidalProtocol/DeFiActions/cadence/tests/transactions/bridge/setup/set_deployment_registry.cdc 0x68ea933793106df2e8c9693faa126ede13fee7cd --signer emulator-account
#
# # Set factory as delegatedDeployer in erc20Deployer
# flow transactions send ./lib/TidalProtocol/DeFiActions/cadence/tests/transactions/bridge/setup/set_delegated_deployer.cdc 0xf0cb8f5149245f143040ea7704fb831a25adaa08 --signer emulator-account
#
# # Set factory as delegatedDeployer in erc721Deployer
# flow transactions send ./lib/TidalProtocol/DeFiActions/cadence/tests/transactions/bridge/setup/set_delegated_deployer.cdc 0xa993b7584838082b19cecedaa7295bb5a1598e1c --signer emulator-account
#
# # add erc20Deployer under "ERC20" tag to factory
# flow transactions send ./lib/TidalProtocol/DeFiActions/cadence/tests/transactions/bridge/setup/add_deployer.cdc "ERC20" 0xf0cb8f5149245f143040ea7704fb831a25adaa08 --signer emulator-account
#
# # add erc721Deployer under "ERC721" tag to factory
# flow transactions send ./lib/TidalProtocol/DeFiActions/cadence/tests/transactions/bridge/setup/add_deployer.cdc "ERC721" 0xa993b7584838082b19cecedaa7295bb5a1598e1c --signer emulator-account
#
# flow transactions send ./lib/flow-evm-bridge/cadence/transactions/bridge/onboarding/onboard_by_evm_address.cdc 0x4a2db8f5b3ad87450f32891e5dbaf774e321f824 --signer emulator-account
#
# flow transactions send ./lib/flow-evm-bridge/cadence/transactions/bridge/onboarding/onboard_by_evm_address.cdc 0xdb15524400eb5689534c4522ce9f6057b79c57dd --signer emulator-account

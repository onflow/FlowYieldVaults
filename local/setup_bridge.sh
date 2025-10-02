
export FLOW_BRIDGE_FACTORY=0xbd6e7465e62808d9b7028e9e256d7742a6230f45
export FLOW_EVM_BRIDGED_ERC20_DEPLOYER=0xe9c05b32512d651dff5d99483ec1a8fdf9d38871
export FLOW_EVM_BRIDGED_ERC721_DEPLOYER=0xe6b1b3ea15c9ac419fec6287b1d045f4fa2dd854
export FLOW_BRIDGE_DEPLOYMENT_REGISTRY=0x60ffe86c2fd2c7e2c0728c27f7a483d46657c3de

flow transactions send ./lib/flow-evm-bridge/cadence/transactions/bridge/admin/pause/update_bridge_pause_status.cdc false --signer emulator-account

flow transactions send ./lib/TidalProtocol/DeFiActions/cadence/transactions/evm/create_coa.cdc 1.0 --signer emulator-account

echo "Transfer ownership to COA"

COA=$(flow scripts execute ./lib/flow-evm-bridge/cadence/scripts/evm/get_evm_address_string.cdc f8d6e0586b0a20c7 -o inline 2>/dev/null | awk -F'"' '{print $2}')

cast send $FLOW_BRIDGE_FACTORY "transferOwnership(address)" $COA --rpc-url $RPC_URL --private-key $PK_ACCOUNT
cast send $FLOW_EVM_BRIDGED_ERC20_DEPLOYER "transferOwnership(address)" $COA --rpc-url $RPC_URL --private-key $PK_ACCOUNT
cast send $FLOW_EVM_BRIDGED_ERC721_DEPLOYER "transferOwnership(address)" $COA --rpc-url $RPC_URL --private-key $PK_ACCOUNT
cast send $FLOW_BRIDGE_DEPLOYMENT_REGISTRY "transferOwnership(address)" $COA --rpc-url $RPC_URL --private-key $PK_ACCOUNT

echo "Setup registrar"

# Set factory as registrar in registry
flow transactions send ./lib/flow-evm-bridge/cadence/transactions/bridge/admin/evm/set_registrar.cdc $FLOW_BRIDGE_DEPLOYMENT_REGISTRY --signer emulator-account --gas-limit 100000

# Set registry as registry in factory
flow transactions send ./lib/flow-evm-bridge/cadence/transactions/bridge/admin/evm/set_deployment_registry.cdc $FLOW_BRIDGE_DEPLOYMENT_REGISTRY --signer emulator-account --gas-limit 100000

# Set factory as delegatedDeployer in erc20Deployer
flow transactions send ./lib/flow-evm-bridge/cadence/transactions/bridge/admin/evm/set_delegated_deployer.cdc $FLOW_EVM_BRIDGED_ERC20_DEPLOYER --signer emulator-account --gas-limit 100000

# Set factory as delegatedDeployer in erc721Deployer
flow transactions send ./lib/flow-evm-bridge/cadence/transactions/bridge/admin/evm/set_delegated_deployer.cdc $FLOW_EVM_BRIDGED_ERC721_DEPLOYER --signer emulator-account --gas-limit 100000

# add erc20Deployer under "ERC20" tag to factory
flow transactions send ./lib/flow-evm-bridge/cadence/transactions/bridge/admin/evm/add_deployer.cdc "ERC20" $FLOW_EVM_BRIDGED_ERC20_DEPLOYER --signer emulator-account --gas-limit 100000

# add erc721Deployer under "ERC721" tag to factory
flow transactions send ./lib/flow-evm-bridge/cadence/transactions/bridge/admin/evm/add_deployer.cdc "ERC721" $FLOW_EVM_BRIDGED_ERC721_DEPLOYER --signer emulator-account --gas-limit 100000
#
# flow transactions send ./lib/flow-evm-bridge/cadence/transactions/bridge/onboarding/onboard_by_evm_address.cdc 0x4a2db8f5b3ad87450f32891e5dbaf774e321f824 --signer emulator-account
#
# flow transactions send ./lib/flow-evm-bridge/cadence/transactions/bridge/onboarding/onboard_by_evm_address.cdc 0xdb15524400eb5689534c4522ce9f6057b79c57dd --signer emulator-account

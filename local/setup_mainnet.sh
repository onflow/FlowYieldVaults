# install DeFiBlocks submodule as dependency
git submodule update --init --recursive
# execute emulator deployment
flow deps install --skip-alias --skip-deployments
flow project deploy --network mainnet --update

# set mocked prices in the MockOracle contract, initialized with MOET as unitOfAccount
flow transactions send ./cadence/transactions/mocks/oracle/set_price.cdc 'A.1654653399040a61.FlowToken.Vault' 0.5 --network mainnet --signer mainnet-admin

# TODO 
# figure out yield token
#flow transactions send ./cadence/transactions/mocks/oracle/set_price.cdc 'A.dfc20aee650fcbdf.EVMVMBridgedToken_4154d5b0e2931a0a1e5b733f19161aa7d2fc4b95.Vault' 1.0 --network mainnet --signer mainnet-admin

echo "bridge MOET to EVM"
flow transactions send ./lib/flow-evm-bridge/cadence/transactions/bridge/onboarding/onboard_by_type_identifier.cdc "A.6b00ff876c299c61.MOET.Vault" --gas-limit 9999 --network mainnet --signer mainnet-flow-alp-deployer

# configure FlowALP
#
# create Pool with MOET as default token
flow transactions send ./cadence/transactions/flow-alp/pool-factory/create_and_store_pool.cdc 'A.6b00ff876c299c61.MOET.Vault' --network mainnet --signer mainnet-flow-alp-deployer
# add FLOW as supported token - params: collateralFactor, borrowFactor, depositRate, depositCapacityCap
flow transactions send ./cadence/transactions/flow-alp/pool-governance/add_supported_token_simple_interest_curve.cdc \
    'A.1654653399040a61.FlowToken.Vault' \
    0.8 \
    1.0 \
    1_000_000.0 \
    1_000_000.0 \
    --network mainnet \
    --signer mainnet-flow-alp-deployer

# TODO 
# swap
# echo "swap Flow to MOET"
# flow transactions send ./cadence/transactions/flow-alp/create_position.cdc 100000.0 --network mainnet --signer mainnet-flow-alp-deployer

# TODO 
# flow transactions send ./lib/flow-evm-bridge/cadence/transactions/bridge/tokens/bridge_tokens_to_any_evm_address.cdc \
#	"A.6b00ff876c299c61.MOET.Vault" 100000.0 "0xOWNER" \
#	--network mainnet --signer mainnet-flow-alp-deployer
# create pool

# add liquidity to pool

# configure FlowVaults
# 
# wire up liquidity to MockSwapper, mocking AMM liquidity sources
flow transactions send ./cadence/transactions/moet/setup_vault.cdc --network mainnet --signer mainnet-admin
flow transactions send ./cadence/transactions/mocks/swapper/set_liquidity_connector.cdc /storage/flowTokenVault --network mainnet --signer mainnet-admin
flow transactions send ./cadence/transactions/mocks/swapper/set_liquidity_connector.cdc /storage/moetTokenVault_0x6b00ff876c299c61 --network mainnet --signer mainnet-admin
#flow transactions send ./cadence/transactions/mocks/swapper/set_liquidity_connector.cdc /storage/yieldTokenVault_0xb1d63873c3cc9f79 --network mainnet --signer mainnet-admin

# TODO 
# setup vault and set connector
# flow transactions send ./lib/FlowALP/FlowActions/cadence/transactions/fungible-tokens/setup_generic_vault.cdc 'A.dfc20aee650fcbdf.EVMVMBridgedToken_4154d5b0e2931a0a1e5b733f19161aa7d2fc4b95.Vault' --network mainnet --signer mainnet-admin
# flow transactions send ./cadence/transactions/mocks/swapper/set_liquidity_connector.cdc /storage/EVMVMBridgedToken_4154d5b0e2931a0a1e5b733f19161aa7d2fc4b95Vault --network mainnet --signer mainnet-admin
#
# TODO
# deploy strategy with relevant EVM addresses
# add TracerStrategy as supported Strategy with the ability to initialize when new Tides are created
flow transactions send ./cadence/transactions/flow-vaults/admin/add_strategy_composer.cdc \
    'A.b1d63873c3cc9f79.FlowVaultsStrategies.TracerStrategy' \
    'A.b1d63873c3cc9f79.FlowVaultsStrategies.TracerStrategyComposer' \
    /storage/FlowVaultsStrategyComposerIssuer_0xb1d63873c3cc9f79 \
    --network mainnet \
    --signer mainnet-admin

# grant PoolBeta cap
echo "Grant Protocol Beta access to FlowVaults"
flow transactions send ./lib/FlowALP/cadence/tests/transactions/flow-alp/pool-management/03_grant_beta.cdc \
  --authorizer mainnet-flow-alp-deployer,mainnet-admin \
  --proposer mainnet-flow-alp-deployer \
  --payer mainnet-admin \
  --network mainnet

# TODO 
# setup coa and transfer flow to it
# TIDAL_COA=0x$(flow scripts execute ./lib/flow-evm-bridge/cadence/scripts/evm/get_evm_address_string.cdc 0xb1d63873c3cc9f79 --format inline --network mainnet | sed -E 's/"([^"]+)"/\1/')
# flow transactions send ./lib/flow-evm-bridge/cadence/transactions/flow-token/transfer_flow_to_cadence_or_evm.cdc $TIDAL_COA 100.0 --network mainnet --signer mainnet-admin --gas-limit 9999
#

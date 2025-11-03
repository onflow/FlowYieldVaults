# install DeFiBlocks submodule as dependency
git submodule update --init --recursive
# execute emulator deployment
flow deps install --skip-alias --skip-deployments
flow project deploy --network testnet --update

# set mocked prices in the MockOracle contract, initialized with MOET as unitOfAccount
flow transactions send ./cadence/transactions/mocks/oracle/set_price.cdc 'A.7e60df042a9c0868.FlowToken.Vault' 0.5 --network testnet --signer testnet-admin
#flow transactions send ./cadence/transactions/mocks/oracle/set_price.cdc 'A.d1f6f66148960224.YieldToken.Vault' 1.0 --network testnet --signer testnet-admin
flow transactions send ./cadence/transactions/mocks/oracle/set_price.cdc 'A.dfc20aee650fcbdf.EVMVMBridgedToken_4154d5b0e2931a0a1e5b733f19161aa7d2fc4b95.Vault' 1.0 --network testnet --signer testnet-admin

# configure FlowALP
#
# create Pool with MOET as default token
flow transactions send ./cadence/transactions/flow-alp/pool-factory/create_and_store_pool.cdc 'A.426f0458ced60037.MOET.Vault' --network testnet --signer testnet-flow-alp-deployer
# add FLOW as supported token - params: collateralFactor, borrowFactor, depositRate, depositCapacityCap
flow transactions send ./cadence/transactions/flow-alp/pool-governance/add_supported_token_simple_interest_curve.cdc \
    'A.7e60df042a9c0868.FlowToken.Vault' \
    0.8 \
    1.0 \
    1_000_000.0 \
    1_000_000.0 \
    --network testnet \
    --signer testnet-flow-alp-deployer

# configure FlowVaults
# 
# wire up liquidity to MockSwapper, mocking AMM liquidity sources
flow transactions send ./cadence/transactions/moet/setup_vault.cdc --network testnet --signer testnet-admin
flow transactions send ./cadence/transactions/mocks/swapper/set_liquidity_connector.cdc /storage/flowTokenVault --network testnet --signer testnet-admin
flow transactions send ./cadence/transactions/mocks/swapper/set_liquidity_connector.cdc /storage/moetTokenVault_0x426f0458ced60037 --network testnet --signer testnet-admin
#flow transactions send ./cadence/transactions/mocks/swapper/set_liquidity_connector.cdc /storage/yieldTokenVault_0xd1f6f66148960224 --network testnet --signer testnet-admin

flow transactions send ./lib/FlowALP/FlowActions/cadence/transactions/fungible-tokens/setup_generic_vault.cdc 'A.dfc20aee650fcbdf.EVMVMBridgedToken_4154d5b0e2931a0a1e5b733f19161aa7d2fc4b95.Vault' --network testnet --signer testnet-admin
flow transactions send ./cadence/transactions/mocks/swapper/set_liquidity_connector.cdc /storage/EVMVMBridgedToken_4154d5b0e2931a0a1e5b733f19161aa7d2fc4b95Vault --network testnet --signer testnet-admin

# add TracerStrategy as supported Strategy with the ability to initialize when new Tides are created
flow transactions send ./cadence/transactions/flow-vaults/admin/add_strategy_composer.cdc \
    'A.d1f6f66148960224.FlowVaultsStrategies.TracerStrategy' \
    'A.d1f6f66148960224.FlowVaultsStrategies.TracerStrategyComposer' \
    /storage/FlowVaultsStrategyComposerIssuer_0xd1f6f66148960224 \
    --network testnet \
    --signer testnet-admin

# grant PoolBeta cap
echo "Grant Protocol Beta access to FlowVaults"
flow transactions send ./lib/FlowALP/cadence/tests/transactions/flow-alp/pool-management/03_grant_beta.cdc \
  --authorizer testnet-flow-alp-deployer,testnet-admin \
  --proposer testnet-flow-alp-deployer \
  --payer testnet-admin \
  --network testnet


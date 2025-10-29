# install DeFiBlocks submodule as dependency
git submodule update --init --recursive
# execute emulator deployment
flow deps install --skip-alias --skip-deployments
flow project deploy --network testnet --update

# set mocked prices in the MockOracle contract, initialized with MOET as unitOfAccount
flow transactions send ./cadence/transactions/mocks/oracle/set_price.cdc 'A.7e60df042a9c0868.FlowToken.Vault' 0.5 --network testnet --signer testnet-admin
#flow transactions send ./cadence/transactions/mocks/oracle/set_price.cdc 'A.d27920b6384e2a78.YieldToken.Vault' 1.0 --network testnet --signer testnet-admin
flow transactions send ./cadence/transactions/mocks/oracle/set_price.cdc 'A.dfc20aee650fcbdf.EVMVMBridgedToken_4154d5b0e2931a0a1e5b733f19161aa7d2fc4b95.Vault' 1.0 --network testnet --signer testnet-admin

# configure TidalProtocol
#
# create Pool with MOET as default token
flow transactions send ./cadence/transactions/tidal-protocol/pool-factory/create_and_store_pool.cdc 'A.d27920b6384e2a78.MOET.Vault' --network testnet --signer testnet-admin
# add FLOW as supported token - params: collateralFactor, borrowFactor, depositRate, depositCapacityCap
flow transactions send ./cadence/transactions/tidal-protocol/pool-governance/add_supported_token_simple_interest_curve.cdc \
    'A.7e60df042a9c0868.FlowToken.Vault' \
    0.8 \
    1.0 \
    1_000_000.0 \
    1_000_000.0 \
    --network testnet \
    --signer testnet-admin

# configure TidalYield
# 
# wire up liquidity to MockSwapper, mocking AMM liquidity sources
flow transactions send ./cadence/transactions/mocks/swapper/set_liquidity_connector.cdc /storage/flowTokenVault --network testnet --signer testnet-admin
flow transactions send ./cadence/transactions/mocks/swapper/set_liquidity_connector.cdc /storage/moetTokenVault_0xd27920b6384e2a78 --network testnet --signer testnet-admin
#flow transactions send ./cadence/transactions/mocks/swapper/set_liquidity_connector.cdc /storage/yieldTokenVault_0xd27920b6384e2a78 --network testnet --signer testnet-admin

flow transactions send ./lib/TidalProtocol/DeFiActions/cadence/transactions/fungible-tokens/setup_generic_vault.cdc 'A.dfc20aee650fcbdf.EVMVMBridgedToken_4154d5b0e2931a0a1e5b733f19161aa7d2fc4b95.Vault' --network testnet --signer testnet-admin
flow transactions send ./cadence/transactions/mocks/swapper/set_liquidity_connector.cdc /storage/EVMVMBridgedToken_4154d5b0e2931a0a1e5b733f19161aa7d2fc4b95Vault --network testnet --signer testnet-admin

# add TracerStrategy as supported Strategy with the ability to initialize when new Tides are created
flow transactions send ./cadence/transactions/tidal-yield/admin/add_strategy_composer.cdc \
    'A.d27920b6384e2a78.TidalYieldStrategies.TracerStrategy' \
    'A.d27920b6384e2a78.TidalYieldStrategies.TracerStrategyComposer' \
    /storage/TidalYieldStrategyComposerIssuer_0xd27920b6384e2a78 \
    --network testnet \
    --signer testnet-admin

# grant PoolBeta cap
echo "Grant Protocol Beta access to TidalYield"
flow transactions send ./lib/TidalProtocol/cadence/tests/transactions/tidal-protocol/pool-management/03_grant_beta.cdc \
  --authorizer testnet-admin,testnet-admin \
  --proposer testnet-admin \
  --payer testnet-admin \
  --network testnet


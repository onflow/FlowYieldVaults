# install DeFiBlocks submodule as dependency
git submodule update --init --recursive
# execute emulator deployment
flow deps install --skip-alias --skip-deployments
flow deploy

# set mocked prices in the MockOracle contract, initialized with MOET as unitOfAccount
flow transactions send ./cadence/transactions/mocks/oracle/set_price.cdc 'A.0ae53cb6e3f42a79.FlowToken.Vault' 0.5
flow transactions send ./cadence/transactions/mocks/oracle/set_price.cdc 'A.f8d6e0586b0a20c7.YieldToken.Vault' 1.0

# configure TidalProtocol
#
# create Pool with MOET as default token
flow transactions send ./cadence/transactions/tidal-protocol/pool-factory/create_and_store_pool.cdc 'A.f8d6e0586b0a20c7.MOET.Vault'
# add FLOW as supported token - params: collateralFactor, borrowFactor, depositRate, depositCapacityCap
flow transactions send ./cadence/transactions/tidal-protocol/pool-governance/add_supported_token_simple_interest_curve.cdc \
    'A.0ae53cb6e3f42a79.FlowToken.Vault' \
    0.8 \
    1.0 \
    1_000_000.0 \
    1_000_000.0

# configure TidalYield
# 
# wire up liquidity to MockSwapper, mocking AMM liquidity sources
flow transactions send ./cadence/transactions/mocks/swapper/set_liquidity_connector.cdc /storage/flowTokenVault
flow transactions send ./cadence/transactions/mocks/swapper/set_liquidity_connector.cdc /storage/moetTokenVault_0xf8d6e0586b0a20c7
flow transactions send ./cadence/transactions/mocks/swapper/set_liquidity_connector.cdc /storage/yieldTokenVault_0xf8d6e0586b0a20c7
# add TracerStrategy as supported Strategy with the ability to initialize when new Tides are created
flow transactions send ./cadence/transactions/tidal-yield/admin/add_strategy_composer.cdc \
    'A.f8d6e0586b0a20c7.TidalYieldStrategies.TracerStrategy' \
    'A.f8d6e0586b0a20c7.TidalYieldStrategies.TracerStrategyComposer' \
    /storage/TidalYieldStrategyComposerIssuer_0xf8d6e0586b0a20c7

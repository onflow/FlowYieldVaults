# install DeFiBlocks submodule as dependency
git submodule update --init --recursive
# execute emulator deployment
flow project deploy --network emulator

flow transactions send ./cadence/transactions/moet/setup_vault.cdc 
flow transactions send ./cadence/transactions/moet/mint_moet.cdc 0x045a1763c93006ca 1000000.0 --signer tidal

# set mocked prices in the MockOracle contract, initialized with MOET as unitOfAccount
flow transactions send ./cadence/transactions/mocks/oracle/set_price.cdc 'A.0ae53cb6e3f42a79.FlowToken.Vault' 0.5 --signer tidal
flow transactions send ./cadence/transactions/mocks/oracle/set_price.cdc 'A.045a1763c93006ca.YieldToken.Vault' 1.0 --signer tidal

# configure FlowALP
#
# create Pool with MOET as default token
flow transactions send ./cadence/transactions/flow-alp/pool-factory/create_and_store_pool.cdc 'A.045a1763c93006ca.MOET.Vault' --signer tidal
# add FLOW as supported token - params: collateralFactor, borrowFactor, depositRate, depositCapacityCap
flow transactions send ./cadence/transactions/flow-alp/pool-governance/add_supported_token_simple_interest_curve.cdc \
    'A.0ae53cb6e3f42a79.FlowToken.Vault' \
    0.8 \
    1.0 \
    1_000_000.0 \
    1_000_000.0 \
    --signer tidal

# configure FlowVaults
# 
# wire up liquidity to MockSwapper, mocking AMM liquidity sources
flow transactions send ./cadence/transactions/mocks/swapper/set_liquidity_connector.cdc /storage/flowTokenVault --signer tidal
flow transactions send ./cadence/transactions/mocks/swapper/set_liquidity_connector.cdc /storage/moetTokenVault_0x045a1763c93006ca --signer tidal
flow transactions send ./cadence/transactions/mocks/swapper/set_liquidity_connector.cdc /storage/yieldTokenVault_0x045a1763c93006ca --signer tidal
# add TracerStrategy as supported Strategy with the ability to initialize when new Tides are created
flow transactions send ./cadence/transactions/flow-vaults/admin/add_strategy_composer.cdc \
    'A.045a1763c93006ca.FlowVaultsStrategies.TracerStrategy' \
    'A.045a1763c93006ca.FlowVaultsStrategies.TracerStrategyComposer' \
    /storage/FlowVaultsStrategyComposerIssuer_0x045a1763c93006ca \
    --signer tidal

# grant PoolBeta cap
echo "Grant Protocol Beta access to TidalVaults"
flow transactions send ./lib/FlowALP/cadence/tests/transactions/flow-alp/pool-management/03_grant_beta.cdc \
  --authorizer tidal,tidal \
  --proposer tidal \
  --payer tidal


TIDAL_COA=0x$(flow scripts execute ./lib/flow-evm-bridge/cadence/scripts/evm/get_evm_address_string.cdc 045a1763c93006ca --format inline | tr -d '\"')
echo $TIDAL_COA
flow transactions send ./lib/flow-evm-bridge/cadence/transactions/flow-token/transfer_flow_to_cadence_or_evm.cdc $TIDAL_COA 100.0 --signer tidal --gas-limit 9999


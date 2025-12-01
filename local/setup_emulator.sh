# install submodule dependencies
git submodule update --init --recursive

# install flow.json dependencies
flow deps install --skip-alias --skip-deployments

echo "deploy MOET & bridge MOET to EVM"
flow accounts add-contract ./lib/FlowCreditMarket/cadence/contracts/MOET.cdc 1000000.00000000 --signer emulator-flow-vaults
flow transactions send ./lib/flow-evm-bridge/cadence/transactions/bridge/onboarding/onboard_by_type_identifier.cdc "A.045a1763c93006ca.MOET.Vault" --gas-limit 9999 --signer emulator-flow-vaults

# execute emulator deployment
flow deploy

flow transactions send ./cadence/transactions/moet/setup_vault.cdc 
flow transactions send ./cadence/transactions/moet/mint_moet.cdc 0x045a1763c93006ca 1000000.0 --signer emulator-flow-vaults

# set mocked prices in the MockOracle contract, initialized with MOET as unitOfAccount
flow transactions send ./cadence/transactions/mocks/oracle/set_price.cdc 'A.0ae53cb6e3f42a79.FlowToken.Vault' 0.5 --signer emulator-flow-vaults
flow transactions send ./cadence/transactions/mocks/oracle/set_price.cdc 'A.045a1763c93006ca.YieldToken.Vault' 1.0 --signer emulator-flow-vaults

# configure FlowCreditMarket
#
# create Pool with MOET as default token
flow transactions send ./cadence/transactions/flow-credit-market/pool-factory/create_and_store_pool.cdc 'A.045a1763c93006ca.MOET.Vault' --signer emulator-flow-vaults
# add FLOW as supported token - params: collateralFactor, borrowFactor, depositRate, depositCapacityCap
flow transactions send ./cadence/transactions/flow-credit-market/pool-governance/add_supported_token_simple_interest_curve.cdc \
    'A.0ae53cb6e3f42a79.FlowToken.Vault' \
    0.8 \
    1.0 \
    1_000_000.0 \
    1_000_000.0 \
    --signer emulator-flow-vaults

# configure FlowVaults
# 
# wire up liquidity to MockSwapper, mocking AMM liquidity sources
flow transactions send ./cadence/transactions/mocks/swapper/set_liquidity_connector.cdc /storage/flowTokenVault --signer emulator-flow-vaults
flow transactions send ./cadence/transactions/mocks/swapper/set_liquidity_connector.cdc /storage/moetTokenVault_0x045a1763c93006ca --signer emulator-flow-vaults
flow transactions send ./cadence/transactions/mocks/swapper/set_liquidity_connector.cdc /storage/yieldTokenVault_0x045a1763c93006ca --signer emulator-flow-vaults
# add TracerStrategy as supported Strategy with the ability to initialize when new Tides are created
flow transactions send ./cadence/transactions/flow-vaults/admin/add_strategy_composer.cdc \
    'A.045a1763c93006ca.FlowVaultsStrategies.TracerStrategy' \
    'A.045a1763c93006ca.FlowVaultsStrategies.TracerStrategyComposer' \
    /storage/FlowVaultsStrategyComposerIssuer_0x045a1763c93006ca \
    --signer emulator-flow-vaults

# grant PoolBeta cap
echo "Grant Protocol Beta access to FlowVaults"
flow transactions send ./lib/FlowCreditMarket/cadence/tests/transactions/flow-credit-market/pool-management/03_grant_beta.cdc \
  --authorizer emulator-flow-vaults,emulator-flow-vaults \
  --proposer emulator-flow-vaults \
  --payer emulator-flow-vaults


TIDAL_COA=0x$(flow scripts execute ./lib/flow-evm-bridge/cadence/scripts/evm/get_evm_address_string.cdc 045a1763c93006ca --format inline | sed -E 's/"([^"]+)"/\1/')
echo $TIDAL_COA
flow transactions send ./lib/flow-evm-bridge/cadence/transactions/flow-token/transfer_flow_to_cadence_or_evm.cdc $TIDAL_COA 100.0 --signer emulator-flow-vaults --gas-limit 9999


# install DeFiBlocks submodule as dependency
git submodule update --init --recursive
# execute emulator deployment
flow deps install --skip-alias --skip-deployments
flow project deploy --network testnet --update

# set mocked prices in the MockOracle contract, initialized with MOET as unitOfAccount
flow transactions send ./cadence/transactions/mocks/oracle/set_price.cdc 'A.7e60df042a9c0868.FlowToken.Vault' 0.5 --network testnet --signer testnet-admin
#flow transactions send ./cadence/transactions/mocks/oracle/set_price.cdc 'A.d2580caf2ef07c2f.YieldToken.Vault' 1.0 --network testnet --signer testnet-admin
flow transactions send ./cadence/transactions/mocks/oracle/set_price.cdc 'A.dfc20aee650fcbdf.EVMVMBridgedToken_4154d5b0e2931a0a1e5b733f19161aa7d2fc4b95.Vault' 1.0 --network testnet --signer testnet-admin

echo "bridge MOET to EVM"
flow transactions send ./lib/flow-evm-bridge/cadence/transactions/bridge/onboarding/onboard_by_type_identifier.cdc "A.426f0458ced60037.MOET.Vault" --compute-limit 9999 --network testnet --signer testnet-flow-credit-market-deployer

# configure FlowCreditMarket
#
# add MOET - USD association on Band Oracle
flow transactions send ../lib/FlowCreditMarket/FlowActions/cadence/transactions/band-oracle-connector/add_symbol.cdc "USD" "A.426f0458ced60037.MOET.Vault"
#
# create Pool with MOET as default token with Mock Oracle
flow transactions send ./lib/FlowCreditMarket/cadence/transactions/flow-credit-market/pool-factory/create_and_store_pool.cdc 'A.426f0458ced60037.MOET.Vault' --network testnet --signer testnet-flow-credit-market-deployer
# update Pool with Band Oracle instead of Mock Oracle
flow transactions send ./lib/FlowCreditMarket/cadence/transactions/flow-credit-market/pool-governance/update_oracle.cdc --network testnet --signer testnet-flow-credit-market-deployer
# add FLOW as supported token - params: collateralFactor, borrowFactor, depositRate, depositCapacityCap
flow transactions send ./lib/FlowCreditMarket/cadence/transactions/flow-credit-market/pool-governance/add_supported_token_simple_interest_curve.cdc \
    'A.7e60df042a9c0868.FlowToken.Vault' \
    0.8 \
    1.0 \
    1_000_000.0 \
    1_000_000.0 \
    --network testnet \
    --signer testnet-flow-credit-market-deployer

echo "swap Flow to MOET"
flow transactions send ./lib/FlowCreditMarket/cadence/transactions/flow-credit-market/create_position.cdc 100000.0 --network testnet --signer testnet-flow-credit-market-deployer

# TODO:
# flow transactions send ./lib/flow-evm-bridge/cadence/transactions/bridge/tokens/bridge_tokens_to_any_evm_address.cdc \
#	"A.426f0458ced60037.MOET.Vault" 100000.0 "0xOWNER" \
#	--network testnet --signer testnet-flow-credit-market-deployer
# create pool

# add liquidity to pool

# configure FlowYieldVaults
# 
# wire up liquidity to MockSwapper, mocking AMM liquidity sources
flow transactions send ./lib/FlowCreditMarket/cadence/transactions/moet/setup_vault.cdc --network testnet --signer testnet-admin
flow transactions send ./cadence/transactions/mocks/swapper/set_liquidity_connector.cdc /storage/flowTokenVault --network testnet --signer testnet-admin
flow transactions send ./cadence/transactions/mocks/swapper/set_liquidity_connector.cdc /storage/moetTokenVault_0x426f0458ced60037 --network testnet --signer testnet-admin
#flow transactions send ./cadence/transactions/mocks/swapper/set_liquidity_connector.cdc /storage/yieldTokenVault_0xd2580caf2ef07c2f --network testnet --signer testnet-admin

flow transactions send ./lib/FlowCreditMarket/FlowActions/cadence/transactions/fungible-tokens/setup_generic_vault.cdc 'A.dfc20aee650fcbdf.EVMVMBridgedToken_4154d5b0e2931a0a1e5b733f19161aa7d2fc4b95.Vault' --network testnet --signer testnet-admin
flow transactions send ./cadence/transactions/mocks/swapper/set_liquidity_connector.cdc /storage/EVMVMBridgedToken_4154d5b0e2931a0a1e5b733f19161aa7d2fc4b95Vault --network testnet --signer testnet-admin

# add TracerStrategy as supported Strategy with the ability to initialize when new YieldVaults are created
flow transactions send ./cadence/transactions/flow-yield-vaults/admin/add_strategy_composer.cdc \
    'A.d2580caf2ef07c2f.FlowYieldVaultsStrategies.TracerStrategy' \
    'A.d2580caf2ef07c2f.FlowYieldVaultsStrategies.TracerStrategyComposer' \
    /storage/FlowYieldVaultsStrategyComposerIssuer_0xd2580caf2ef07c2f \
    --network testnet \
    --signer testnet-admin

flow transactions send ../cadence/transactions/flow-yield-vaults/admin/upsert_musdf_config.cdc \
	'A.7e60df042a9c0868.FlowToken.Vault' \
	"0x4154d5B0E2931a0A1E5b733f19161aa7D2fc4b95" \
	'["0x4154d5B0E2931a0A1E5b733f19161aa7D2fc4b95", "0xd3bF53DAC106A0290B0483EcBC89d40FcC961f3e"]' \
	'[3000]' \
	--network testnet \
	--signer testnet-admin

flow transactions send ./cadence/transactions/flow-yield-vaults/admin/add_strategy_composer.cdc \
	'A.d2580caf2ef07c2f.FlowYieldVaultsStrategiesV1.mUSDFStrategy' \
	'A.d2580caf2ef07c2f.FlowYieldVaultsStrategiesV1.mUSDFStrategyComposer' \
	/storage/FlowYieldVaultsStrategyV1ComposerIssuer_0xd2580caf2ef07c2f \
	--network testnet \
	--signer testnet-admin


# grant PoolBeta cap
echo "Grant Protocol Beta access to FlowYieldVaults"
flow transactions send ./lib/FlowCreditMarket/cadence/tests/transactions/flow-credit-market/pool-management/03_grant_beta.cdc \
  --authorizer testnet-flow-credit-market-deployer,testnet-admin \
  --proposer testnet-flow-credit-market-deployer \
  --payer testnet-admin \
  --network testnet

TIDAL_COA=0x$(flow scripts execute ./lib/flow-evm-bridge/cadence/scripts/evm/get_evm_address_string.cdc 0xd2580caf2ef07c2f --format inline --network testnet | sed -E 's/"([^"]+)"/\1/')
flow transactions send ./lib/flow-evm-bridge/cadence/transactions/flow-token/transfer_flow_to_cadence_or_evm.cdc $TIDAL_COA 100.0 --network testnet --signer testnet-admin --compute-limit 9999

# sanity test
# flow transactions send ./cadence/transactions/flow-yield-vaults/admin/grant_beta.cdc \
#   --authorizer testnet-admin,<TEST_USER> \
#   --proposer <TEST_USER> \
#   --payer testnet-admin \
#   --network testnet 
# flow transactions send ./cadence/transactions/flow-yield-vaults/create_yield_vault.cdc \
#   A.d2580caf2ef07c2f.FlowYieldVaultsStrategies.mUSDCStrategy \
#   A.7e60df042a9c0868.FlowToken.Vault \
#   100.0 \
#   --signer <TEST_USER> \
#   --compute-limit 9999 \
#   --network testnet

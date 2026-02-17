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
flow transactions send ./lib/flow-evm-bridge/cadence/transactions/bridge/onboarding/onboard_by_type_identifier.cdc "A.426f0458ced60037.MOET.Vault" --compute-limit 9999 --network testnet --signer testnet-flow-alp-deployer

# configure FlowALPv1
#
# add MOET - USD association on Band Oracle
cd ./lib/FlowCreditMarket/FlowActions && flow transactions send ./cadence/transactions/band-oracle-connector/add_symbol.cdc "USD" "A.426f0458ced60037.MOET.Vault" --network testnet --signer testnet-band-oracle-connectors

# create Pool with MOET as default token with Mock Oracle
flow transactions send ./lib/FlowCreditMarket/cadence/transactions/flow-alp/pool-factory/create_and_store_pool.cdc 'A.426f0458ced60037.MOET.Vault' --network testnet --signer testnet-flow-alp-deployer
# update Pool with Band Oracle instead of Mock Oracle
flow transactions send ./lib/FlowCreditMarket/cadence/transactions/flow-alp/pool-governance/update_oracle.cdc --network testnet --signer testnet-flow-alp-deployer
# add FLOW as supported token - params: collateralFactor, borrowFactor, depositRate, depositCapacityCap
flow transactions send ./lib/FlowCreditMarket/cadence/transactions/flow-alp/pool-governance/add_supported_token_simple_interest_curve.cdc \
    'A.7e60df042a9c0868.FlowToken.Vault' \
    0.8 \
    1.0 \
    1_000_000.0 \
    1_000_000.0 \
    --network testnet \
    --signer testnet-flow-alp-deployer

# add WBTC to band oracle
cd ./lib/FlowCreditMarket/FlowActions && flow transactions send ./cadence/transactions/band-oracle-connector/add_symbol.cdc "BTC" "A.dfc20aee650fcbdf.EVMVMBridgedToken_208d09d2a6dd176e3e95b3f0de172a7471c5b2d6.Vault" --network testnet --signer testnet-band-oracle-connectors && cd ../../..

# add WETH to band oracle
cd ./lib/FlowCreditMarket/FlowActions && flow transactions send ./cadence/transactions/band-oracle-connector/add_symbol.cdc "ETH" "A.dfc20aee650fcbdf.EVMVMBridgedToken_059a77239dafa770977dd9f1e98632c3e4559848.Vault" --network testnet --signer testnet-band-oracle-connectors && cd ../../..

# add WBTC as supported token
flow transactions send ./lib/FlowCreditMarket/cadence/transactions/flow-alp/pool-governance/add_supported_token_simple_interest_curve.cdc \
    'A.dfc20aee650fcbdf.EVMVMBridgedToken_208d09d2a6dd176e3e95b3f0de172a7471c5b2d6.Vault' \
    0.8 \
    1.0 \
    1_000_000.0 \
    1_000_000.0 \
    --network testnet \
    --signer testnet-flow-alp-deployer

# add WETH as supported token
flow transactions send ./lib/FlowCreditMarket/cadence/transactions/flow-alp/pool-governance/add_supported_token_simple_interest_curve.cdc \
    'A.dfc20aee650fcbdf.EVMVMBridgedToken_059a77239dafa770977dd9f1e98632c3e4559848.Vault' \
    0.8 \
    1.0 \
    1_000_000.0 \
    1_000_000.0 \
    --network testnet \
    --signer testnet-flow-alp-deployer

echo "swap Flow to MOET"
flow transactions send ./lib/FlowCreditMarket/cadence/transactions/flow-alp/create_position.cdc 100000.0 --network testnet --signer testnet-flow-alp-deployer

# TODO:
# flow transactions send ./lib/flow-evm-bridge/cadence/transactions/bridge/tokens/bridge_tokens_to_any_evm_address.cdc \
#	"A.426f0458ced60037.MOET.Vault" 100000.0 "0xOWNER" \
#	--network testnet --signer testnet-flow-alp-deployer
# create pool

# add liquidity to pool

# configure FlowYieldVaults
# 
# wire up liquidity to MockSwapper, mocking AMM liquidity sources
flow transactions send ./lib/FlowCreditMarket/cadence/transactions/moet/setup_vault.cdc --network testnet --signer testnet-admin
flow transactions send ./cadence/transactions/mocks/swapper/set_liquidity_connector.cdc /storage/flowTokenVault --network testnet --signer testnet-admin
flow transactions send ./cadence/transactions/mocks/swapper/set_liquidity_connector.cdc /storage/moetTokenVault_0x426f0458ced60037 --network testnet --signer testnet-admin
#flow transactions send ./cadence/transactions/mocks/swapper/set_liquidity_connector.cdc /storage/yieldTokenVault_0xd2580caf2ef07c2f --network testnet --signer testnet-admin

# setup yield token vault
flow transactions send ./lib/FlowCreditMarket/FlowActions/cadence/transactions/fungible-tokens/setup_generic_vault.cdc 'A.dfc20aee650fcbdf.EVMVMBridgedToken_4154d5b0e2931a0a1e5b733f19161aa7d2fc4b95.Vault' --network testnet --signer testnet-admin
flow transactions send ./cadence/transactions/mocks/swapper/set_liquidity_connector.cdc /storage/EVMVMBridgedToken_4154d5b0e2931a0a1e5b733f19161aa7d2fc4b95Vault --network testnet --signer testnet-admin

# add TracerStrategy as supported Strategy with the ability to initialize when new YieldVaults are created
flow transactions send ./cadence/transactions/flow-yield-vaults/admin/add_strategy_composer.cdc \
    'A.d2580caf2ef07c2f.FlowYieldVaultsStrategies.TracerStrategy' \
    'A.d2580caf2ef07c2f.FlowYieldVaultsStrategies.TracerStrategyComposer' \
    /storage/FlowYieldVaultsStrategyComposerIssuer_0xd2580caf2ef07c2f \
    --network testnet \
    --signer testnet-admin

flow transactions send ./cadence/transactions/flow-yield-vaults/admin/upsert_musdf_config.cdc \
	'A.d2580caf2ef07c2f.FlowYieldVaultsStrategiesV1_1.mUSDFStrategy'
	'A.7e60df042a9c0868.FlowToken.Vault' \
	"0x4154d5B0E2931a0A1E5b733f19161aa7D2fc4b95" \
	'["0x4154d5B0E2931a0A1E5b733f19161aa7D2fc4b95", "0xd3bF53DAC106A0290B0483EcBC89d40FcC961f3e"]' \
	'[3000]' \
	--network testnet \
	--signer testnet-admin

# WETH univ3 path and fees
flow transactions send ./cadence/transactions/flow-yield-vaults/admin/upsert_musdf_config.cdc \
	'A.d2580caf2ef07c2f.FlowYieldVaultsStrategiesV1_1.mUSDFStrategy'
	'A.dfc20aee650fcbdf.EVMVMBridgedToken_059a77239dafa770977dd9f1e98632c3e4559848.Vault' \
	"0x4154d5B0E2931a0A1E5b733f19161aa7D2fc4b95" \
	'["0x4154d5B0E2931a0A1E5b733f19161aa7D2fc4b95","0x02d3575e2516a515E9B91a52b294Edc80DC7987c", "0x059A77239daFa770977DD9f1E98632C3E4559848"]' \
	'[3000,3000]' \
	--network testnet \
	--signer testnet-admin

# WBTC univ3 path and fees
flow transactions send ./cadence/transactions/flow-yield-vaults/admin/upsert_musdf_config.cdc \
	'A.d2580caf2ef07c2f.FlowYieldVaultsStrategiesV1_1.mUSDFStrategy'
	'A.dfc20aee650fcbdf.EVMVMBridgedToken_208d09d2a6dd176e3e95b3f0de172a7471c5b2d6.Vault' \
	"0x4154d5B0E2931a0A1E5b733f19161aa7D2fc4b95" \
	'["0x4154d5B0E2931a0A1E5b733f19161aa7D2fc4b95","0x02d3575e2516a515E9B91a52b294Edc80DC7987c","0x208d09d2a6Dd176e3e95b3F0DE172A7471C5B2d6"]' \
	'[3000,3000]' \
	--network testnet \
	--signer testnet-admin


## PYUSD0 Vault
# WFLOW univ3 path and fees
# path: FUSDEV - WFLOW
flow transactions send ./cadence/transactions/flow-yield-vaults/admin/upsert_musdf_config.cdc \
	'A.d2580caf2ef07c2f.FlowYieldVaultsStrategiesV1_1.FUSDEVStrategy'
	'A.7e60df042a9c0868.FlowToken.Vault' \
	"0x61b44D19486EE492449E83C1201581C754e9e1E1" \
	'["0x61b44D19486EE492449E83C1201581C754e9e1E1", "0xd3bF53DAC106A0290B0483EcBC89d40FcC961f3e"]' \
	'[3000]' \
	--network testnet \
	--signer testnet-admin

# WETH univ3 path and fees
# path: FUSDEV - MOET - WETH
flow transactions send ./cadence/transactions/flow-yield-vaults/admin/upsert_musdf_config.cdc \
	'A.d2580caf2ef07c2f.FlowYieldVaultsStrategiesV1_1.FUSDEVStrategy'
	'A.dfc20aee650fcbdf.EVMVMBridgedToken_059a77239dafa770977dd9f1e98632c3e4559848.Vault' \
	"0x61b44D19486EE492449E83C1201581C754e9e1E1" \
	'["0x61b44D19486EE492449E83C1201581C754e9e1E1","0x02d3575e2516a515E9B91a52b294Edc80DC7987c", "0x059A77239daFa770977DD9f1E98632C3E4559848"]' \
	'[3000,3000]' \
	--network testnet \
	--signer testnet-admin

# WBTC univ3 path and fees
# path: FUSDEV - MOET - WETH
flow transactions send ./cadence/transactions/flow-yield-vaults/admin/upsert_musdf_config.cdc \
	'A.d2580caf2ef07c2f.FlowYieldVaultsStrategiesV1_1.FUSDEVStrategy'
	'A.dfc20aee650fcbdf.EVMVMBridgedToken_208d09d2a6dd176e3e95b3f0de172a7471c5b2d6.Vault' \
	"0x61b44D19486EE492449E83C1201581C754e9e1E1" \
	'["0x61b44D19486EE492449E83C1201581C754e9e1E1","0x02d3575e2516a515E9B91a52b294Edc80DC7987c","0x208d09d2a6Dd176e3e95b3F0DE172A7471C5B2d6"]' \
	'[3000,3000]' \
	--network testnet \
	--signer testnet-admin

flow transactions send ./cadence/transactions/flow-yield-vaults/admin/add_strategy_composer.cdc \
	'A.d2580caf2ef07c2f.FlowYieldVaultsStrategiesV1_1.mUSDFStrategy' \
	'A.d2580caf2ef07c2f.FlowYieldVaultsStrategiesV1_1.mUSDFStrategyComposer' \
	/storage/FlowYieldVaultsStrategyV1_1ComposerIssuer_0xd2580caf2ef07c2f \
	--network testnet \
	--signer testnet-admin

flow transactions send ./cadence/transactions/flow-yield-vaults/admin/add_strategy_composer.cdc \
	'A.d2580caf2ef07c2f.FlowYieldVaultsStrategiesV1_1.FUSDEVStrategy' \
	'A.d2580caf2ef07c2f.FlowYieldVaultsStrategiesV1_1.mUSDFStrategyComposer' \
	/storage/FlowYieldVaultsStrategyV1_1ComposerIssuer_0xd2580caf2ef07c2f \
	--network testnet \
	--signer testnet-admin

# PYUSD0 Vault
flow transactions send ./cadence/transactions/flow-yield-vaults/admin/upsert-pm-strategy-config.cdc \
	'A.d2580caf2ef07c2f.PMStrategiesV1.FUSDEVStrategy' \
	'A.dfc20aee650fcbdf.EVMVMBridgedToken_d7d43ab7b365f0d0789ae83f4385fa710ffdc98f.Vault' \
	'0x61b44D19486EE492449E83C1201581C754e9e1E1' \
	100 \
	--network testnet \
	--signer testnet-admin

flow transactions send ./cadence/transactions/flow-yield-vaults/admin/add_strategy_composer.cdc \
	'A.d2580caf2ef07c2f.PMStrategiesV1.FUSDEVStrategy' \
	'A.d2580caf2ef07c2f.PMStrategiesV1.ERC4626VaultStrategyComposer' \
	/storage/PMStrategiesV1ComposerIssuer_0xd2580caf2ef07c2f \
	--network testnet \
	--signer testnet-admin

# grant PoolBeta cap
echo "Grant Protocol Beta access to FlowYieldVaults"
flow transactions send ./lib/FlowCreditMarket/cadence/tests/transactions/flow-alp/pool-management/03_grant_beta.cdc \
  --authorizer testnet-flow-alp-deployer,testnet-admin \
  --proposer testnet-flow-alp-deployer \
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
#
#
# Flow
# flow transactions send ./cadence/transactions/flow-yield-vaults/create_yield_vault.cdc \
#   A.d2580caf2ef07c2f.FlowYieldVaultsStrategiesV1_1.mUSDFStrategy \
#   A.7e60df042a9c0868.FlowToken.Vault \
#   100.0 \
#   --signer <TEST_USER> \
#   --compute-limit 9999 \
#   --network testnet
#
#
# WBTC (BTCf)
# flow transactions send ./cadence/transactions/flow-yield-vaults/create_yield_vault.cdc \
#   A.d2580caf2ef07c2f.FlowYieldVaultsStrategiesV1_1.mUSDFStrategy \
#   A.dfc20aee650fcbdf.EVMVMBridgedToken_208d09d2a6dd176e3e95b3f0de172a7471c5b2d6.Vault \
#   0.00001 \
#   --compute-limit 9999 \
#   --network testnet \
#   --signer <TEST_USER>
#
# WETH (ETHf)
# flow transactions send ./cadence/transactions/flow-yield-vaults/create_yield_vault.cdc \
#   A.d2580caf2ef07c2f.FlowYieldVaultsStrategiesV1_1.mUSDFStrategy \
#   A.dfc20aee650fcbdf.EVMVMBridgedToken_059a77239dafa770977dd9f1e98632c3e4559848.Vault \
#   0.001 \
#   --compute-limit 9999 \
#   --network testnet \
#   --signer <TEST_USER>
#
# PYUSD0
# flow transactions send ./cadence/transactions/flow-yield-vaults/create_yield_vault.cdc \
#   A.d2580caf2ef07c2f.PMStrategiesV1.FUSDEVStrategy \
#   A.dfc20aee650fcbdf.EVMVMBridgedToken_d7d43ab7b365f0d0789ae83f4385fa710ffdc98f.Vault \
#   100.0 \
#   --compute-limit 9999 \
#   --network testnet \
#   --signer <TEST_USER>
#

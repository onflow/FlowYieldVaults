# install DeFiBlocks submodule as dependency
git submodule update --init --recursive
# execute emulator deployment
flow deps install --skip-alias --skip-deployments
flow project deploy --network mainnet --update

# set mocked prices in the MockOracle contract, initialized with MOET as unitOfAccount
flow transactions send ./cadence/transactions/mocks/oracle/set_price.cdc 'A.1654653399040a61.FlowToken.Vault' 0.5 --network mainnet --signer mainnet-admin

# TODO 
# figure out yield token
echo "bridge YieldToken to Cadence"
flow transactions send ./lib/flow-evm-bridge/cadence/transactions/bridge/onboarding/onboard_by_evm_address.cdc 0xc52E820d2D6207D18667a97e2c6Ac22eB26E803c --network mainnet --signer mainnet-admin 
echo "bridge MOET to EVM"
flow transactions send ./lib/flow-evm-bridge/cadence/transactions/bridge/onboarding/onboard_by_type_identifier.cdc "A.6b00ff876c299c61.MOET.Vault" --gas-limit 9999 --network mainnet --signer mainnet-flow-credit-market-deployer

# configure FlowCreditMarket
#
# create Pool with MOET as default token
flow transactions send ./lib/FlowCreditMarket/cadence/transactions/flow-credit-market/pool-factory/create_and_store_pool.cdc 'A.6b00ff876c299c61.MOET.Vault' --network mainnet --signer mainnet-flow-credit-market-deployer
# update Pool with Band Oracle instead of Mock Oracle
flow transactions send ./lib/FlowCreditMarket/cadence/transactions/flow-credit-market/pool-governance/update_oracle.cdc --network mainnet --signer mainnet-flow-credit-market-deployer

# add FLOW as supported token - params: collateralFactor, borrowFactor, depositRate, depositCapacityCap
flow transactions send ./lib/FlowCreditMarket/cadence/transactions/flow-credit-market/pool-governance/add_supported_token_simple_interest_curve.cdc \
    'A.1654653399040a61.FlowToken.Vault' \
    0.8 \
    1.0 \
    1_000_000.0 \
    1_000_000.0 \
    --network mainnet \
    --signer mainnet-flow-credit-market-deployer

# add WBTC to band oracle
cd ./lib/FlowCreditMarket/FlowActions && flow transactions send ./cadence/transactions/band-oracle-connector/add_symbol.cdc "BTC" "A.dfc20aee650fcbdf.EVMVMBridgedToken_717dae2baf7656be9a9b01dee31d571a9d4c9579.Vault" --network mainnet --signer mainnet-band-oracle-connectors && cd ../../..

# add WETH to band oracle
cd ./lib/FlowCreditMarket/FlowActions && flow transactions send ./cadence/transactions/band-oracle-connector/add_symbol.cdc "ETH" "A.dfc20aee650fcbdf.EVMVMBridgedToken_2f6f07cdcf3588944bf4c42ac74ff24bf56e7590.Vault" --network mainnet --signer mainnet-band-oracle-connectors && cd ../../..

# add WBTC as supported token
flow transactions send ./lib/FlowCreditMarket/cadence/transactions/flow-credit-market/pool-governance/add_supported_token_simple_interest_curve.cdc \
    'A.dfc20aee650fcbdf.EVMVMBridgedToken_717dae2baf7656be9a9b01dee31d571a9d4c9579.Vault' \
    0.8 \
    1.0 \
    1_000_000.0 \
    1_000_000.0 \
    --network mainnet \
    --signer mainnet-flow-credit-market-deployer

# add WETH as supported token
flow transactions send ./lib/FlowCreditMarket/cadence/transactions/flow-credit-market/pool-governance/add_supported_token_simple_interest_curve.cdc \
    'A.dfc20aee650fcbdf.EVMVMBridgedToken_2f6f07cdcf3588944bf4c42ac74ff24bf56e7590.Vault' \
    0.8 \
    1.0 \
    1_000_000.0 \
    1_000_000.0 \
    --network mainnet \
    --signer mainnet-flow-credit-market-deployer

# TODO 
# swap
# echo "swap Flow to MOET"
# flow transactions send ./lib/FlowCreditMarket/cadence/transactions/flow-credit-market/create_position.cdc 100000.0 --network mainnet --signer mainnet-flow-credit-market-deployer

# TODO 
# flow transactions send ./lib/flow-evm-bridge/cadence/transactions/bridge/tokens/bridge_tokens_to_any_evm_address.cdc \
#	"A.6b00ff876c299c61.MOET.Vault" 100000.0 "0xOWNER" \
#	--network mainnet --signer mainnet-flow-credit-market-deployer
# create pool

# add liquidity to pool

# configure FlowYieldVaults
# 
# wire up liquidity to MockSwapper, mocking AMM liquidity sources
flow transactions send ./lib/FlowCreditMarket/cadence/transactions/moet/setup_vault.cdc --network mainnet --signer mainnet-admin
flow transactions send ./cadence/transactions/mocks/swapper/set_liquidity_connector.cdc /storage/flowTokenVault --network mainnet --signer mainnet-admin
flow transactions send ./cadence/transactions/mocks/swapper/set_liquidity_connector.cdc /storage/moetTokenVault_0x6b00ff876c299c61 --network mainnet --signer mainnet-admin
#flow transactions send ./cadence/transactions/mocks/swapper/set_liquidity_connector.cdc /storage/yieldTokenVault_0xb1d63873c3cc9f79 --network mainnet --signer mainnet-admin

# TODO 
# setup vault and set connector
flow transactions send ./lib/FlowCreditMarket/FlowActions/cadence/transactions/fungible-tokens/setup_generic_vault.cdc 'A.1e4aa0b87d10b141.EVMVMBridgedToken_c52e820d2d6207d18667a97e2c6ac22eb26e803c.Vault' --network mainnet --signer mainnet-admin
# flow transactions send ./cadence/transactions/mocks/swapper/set_liquidity_connector.cdc /storage/EVMVMBridgedToken_4154d5b0e2931a0a1e5b733f19161aa7d2fc4b95Vault --network mainnet --signer mainnet-admin
#


# Setup UniV3 path tauUSDFv -> USDF -> WFLOW
flow transactions send ./cadence/transactions/flow-yield-vaults/admin/upsert_musdf_config.cdc \
	'A.1654653399040a61.FlowToken.Vault' \
	"0xc52E820d2D6207D18667a97e2c6Ac22eB26E803c" \
	'["0xc52E820d2D6207D18667a97e2c6Ac22eB26E803c","0x2aaBea2058b5aC2D339b163C6Ab6f2b6d53aabED","0xd3bF53DAC106A0290B0483EcBC89d40FcC961f3e"]' \
	'[100,3000]' \
	--network mainnet \
	--signer mainnet-admin


# Setup UniV3 path tauUSDFv -> USDF -> WBTC
flow transactions send ./cadence/transactions/flow-yield-vaults/admin/upsert_musdf_config.cdc \
	'A.1e4aa0b87d10b141.EVMVMBridgedToken_717dae2baf7656be9a9b01dee31d571a9d4c9579.Vault' \
	"0xc52E820d2D6207D18667a97e2c6Ac22eB26E803c" \
	'["0xc52E820d2D6207D18667a97e2c6Ac22eB26E803c","0x2aaBea2058b5aC2D339b163C6Ab6f2b6d53aabED","0x717DAE2BaF7656BE9a9B01deE31d571a9d4c9579"]' \
	'[100,3000]' \
	--network mainnet \
	--signer mainnet-admin

# Setup UniV3 path tauUSDFv -> USDF -> WETH
flow transactions send ./cadence/transactions/flow-yield-vaults/admin/upsert_musdf_config.cdc \
	'A.1e4aa0b87d10b141.EVMVMBridgedToken_2f6f07cdcf3588944bf4c42ac74ff24bf56e7590.Vault' \
	"0xc52E820d2D6207D18667a97e2c6Ac22eB26E803c" \
	'["0xc52E820d2D6207D18667a97e2c6Ac22eB26E803c","0x2aaBea2058b5aC2D339b163C6Ab6f2b6d53aabED","0x2F6F07CDcf3588944Bf4C42aC74ff24bF56e7590"]' \
	'[100,3000]' \
	--network mainnet \
	--signer mainnet-admin

#
# add mUSDFStrategy as supported Strategy with the ability to initialize when new YieldVaults are created
flow transactions send ./cadence/transactions/flow-yield-vaults/admin/add_strategy_composer.cdc \
    'A.b1d63873c3cc9f79.FlowYieldVaultsStrategiesV1_1.mUSDFStrategy' \
    'A.b1d63873c3cc9f79.FlowYieldVaultsStrategiesV1_1.mUSDFStrategyComposer' \
    /storage/FlowYieldVaultsStrategyV1_1ComposerIssuer_0xb1d63873c3cc9f79 \
    --network mainnet \
    --signer mainnet-admin

# configure PMStrategies strategy configs
flow transactions send ./cadence/transactions/flow-yield-vaults/admin/upsert-pm-strategy-config.cdc \
    'A.b1d63873c3cc9f79.PMStrategiesV1.syWFLOWvStrategy' \
    'A.1654653399040a61.FlowToken.Vault' \
    '0xCBf9a7753F9D2d0e8141ebB36d99f87AcEf98597' \
    100 \
    --network mainnet \
    --signer mainnet-admin

flow transactions send ./cadence/transactions/flow-yield-vaults/admin/upsert-pm-strategy-config.cdc \
    'A.b1d63873c3cc9f79.PMStrategiesV1.tauUSDFvStrategy' \
    'A.1e4aa0b87d10b141.EVMVMBridgedToken_2aabea2058b5ac2d339b163c6ab6f2b6d53aabed.Vault' \
    '0xc52E820d2D6207D18667a97e2c6Ac22eB26E803c' \
    100 \
    --network mainnet \
    --signer mainnet-admin

flow transactions send ./cadence/transactions/flow-yield-vaults/admin/add_strategy_composer.cdc \
    'A.b1d63873c3cc9f79.PMStrategiesV1.syWFLOWvStrategy' \
    'A.b1d63873c3cc9f79.PMStrategiesV1.ERC4626VaultStrategyComposer' \
    /storage/PMStrategiesV1ComposerIssuer_0xb1d63873c3cc9f79 \
    --network mainnet \
    --signer mainnet-admin

flow transactions send ./cadence/transactions/flow-yield-vaults/admin/add_strategy_composer.cdc \
    'A.b1d63873c3cc9f79.PMStrategiesV1.tauUSDFvStrategy' \
    'A.b1d63873c3cc9f79.PMStrategiesV1.ERC4626VaultStrategyComposer' \
    /storage/PMStrategiesV1ComposerIssuer_0xb1d63873c3cc9f79 \
    --network mainnet \
    --signer mainnet-admin

# grant PoolBeta cap
echo "Grant Protocol Beta access to FlowYieldVaults"
flow transactions send ./lib/FlowCreditMarket/cadence/tests/transactions/flow-credit-market/pool-management/03_grant_beta.cdc \
  --authorizer mainnet-flow-credit-market-deployer,mainnet-admin \
  --proposer mainnet-flow-credit-market-deployer \
  --payer mainnet-admin \
  --network mainnet

# TODO 
# setup coa and transfer flow to it
# TIDAL_COA=0x$(flow scripts execute ./lib/flow-evm-bridge/cadence/scripts/evm/get_evm_address_string.cdc 0xb1d63873c3cc9f79 --format inline --network mainnet | sed -E 's/"([^"]+)"/\1/')
# flow transactions send ./lib/flow-evm-bridge/cadence/transactions/flow-token/transfer_flow_to_cadence_or_evm.cdc $TIDAL_COA 100.0 --network mainnet --signer mainnet-admin --gas-limit 9999
#
#
# sanity test
# flow transactions send ./cadence/transactions/flow-yield-vaults/admin/grant_beta.cdc \
#   --authorizer mainnet-admin,<TEST_USER> \
#   --proposer <TEST_USER> \
#   --payer mainnet-admin \
#   --network mainnet 

# test FlowYieldVault strategy

# flow transactions send ./cadence/transactions/flow-yield-vaults/create_yield_vault.cdc \
#   A.b1d63873c3cc9f79.FlowYieldVaultsStrategies.mUSDCStrategy \
#   A.1654653399040a61.FlowToken.Vault \
#   1.0 \
#   --signer <TEST_USER> \
#   --compute-limit 9999 \
#   --network mainnet
#

# test PEAK MONEY strategy
# flow transactions send ./cadence/transactions/flow-yield-vaults/create_yield_vault.cdc \
#   A.b1d63873c3cc9f79.PMStrategiesV1.syWFLOWvStrategy \
#   A.1654653399040a61.FlowToken.Vault \
#   1.0 \
#   --signer <TEST_USER> \
#   --compute-limit 9999 \
#   --network mainnet

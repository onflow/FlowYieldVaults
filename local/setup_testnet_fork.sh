#!/usr/bin/env bash
# Setup script for the testnet-fork emulator.
#
# Start the emulator first with:
#   flow emulator --fork testnet
#
# Then run this script to redeploy local contracts and reconfigure state.

set -e

# install dependencies (skip alias prompts and deployments — we handle those below)
flow deps install --skip-alias --skip-deployments

# Redeploy updated local contracts over the forked testnet state.
# All other contracts (FungibleToken, EVM, FlowALPv0, etc.) are already live
# on testnet and accessible in the fork without redeployment.
flow project deploy --network testnet-fork --update

# Remove the stale FlowYieldVaultsStrategies.TracerStrategy from the StrategyFactory.
#
# The old FlowYieldVaultsStrategies contract on testnet has TracerStrategy that no longer
# conforms to FlowYieldVaults.Strategy (missing closePosition). This blocks deserialization
# of the entire StrategyFactory, causing createYieldVault to fail for ALL strategies.
#
# The FlowYieldVaultsStrategies stub deployed above fixes the type-check so the factory can
# be deserialized; this call then permanently removes the stale entry.
flow transactions send ./cadence/transactions/flow-yield-vaults/admin/remove_strategy_composer.cdc \
    'A.d2580caf2ef07c2f.FlowYieldVaultsStrategies.TracerStrategy' \
    --network testnet-fork --signer testnet-fork-admin

# Also remove MockStrategies.TracerStrategy if present (registered during testnet setup;
# not needed for production debugging of create_yield_vault).
flow transactions send ./cadence/transactions/flow-yield-vaults/admin/remove_strategy_composer.cdc \
    'A.d2580caf2ef07c2f.MockStrategies.TracerStrategy' \
    --network testnet-fork --signer testnet-fork-admin

# Set mock oracle prices (FLOW = $0.5, YieldToken = $1.0)
flow transactions send ./cadence/transactions/mocks/oracle/set_price.cdc \
    'A.7e60df042a9c0868.FlowToken.Vault' 0.5 \
    --network testnet-fork --signer testnet-fork-admin

flow transactions send ./cadence/transactions/mocks/oracle/set_price.cdc \
    'A.d2580caf2ef07c2f.YieldToken.Vault' 1.0 \
    --network testnet-fork --signer testnet-fork-admin

# Wire up MockSwapper liquidity connectors
flow transactions send ./lib/FlowALP/cadence/transactions/moet/setup_vault.cdc \
    --network testnet-fork --signer testnet-fork-admin
flow transactions send ./cadence/transactions/mocks/swapper/set_liquidity_connector.cdc \
    /storage/flowTokenVault \
    --network testnet-fork --signer testnet-fork-admin
flow transactions send ./cadence/transactions/mocks/swapper/set_liquidity_connector.cdc \
    /storage/moetTokenVault_0x426f0458ced60037 \
    --network testnet-fork --signer testnet-fork-admin

# Re-register FUSDEVStrategy composer (testnet address: d2580caf2ef07c2f)
flow transactions send ./cadence/transactions/flow-yield-vaults/admin/add_strategy_composer.cdc \
    'A.d2580caf2ef07c2f.FlowYieldVaultsStrategiesV2.FUSDEVStrategy' \
    'A.d2580caf2ef07c2f.FlowYieldVaultsStrategiesV2.MorphoERC4626StrategyComposer' \
    /storage/FlowYieldVaultsStrategyV2ComposerIssuer_0xd2580caf2ef07c2f \
    --network testnet-fork --signer testnet-fork-admin

# Configure FUSDEVStrategy collateral paths.
#
# The testnet state may have a stale 2-element path [FUSDEV, WFLOW] for FlowToken.Vault
# collateral, but the contract now requires yieldToCollateral path length >= 3.
# Use [FUSDEV, MOET, WFLOW] fees [100, 3000]:
#   - FUSDEV/MOET fee100 pool exists on testnet
#   - MOET/WFLOW fee3000 pool exists on testnet
#   - _createCollateralToDebtSwapper uses the last fee (3000) for WFLOW→PYUSD0,
#     and the WFLOW/PYUSD0 fee3000 pool exists on testnet.
#
# Testnet EVM addresses:
#   FUSDEV:  0x61b44D19486EE492449E83C1201581C754e9e1E1
#   MOET:    0xf622664Ba813e63947Cfa6c2E95E5c18F617E6C9
#   WFLOW:   0xd3bF53DAC106A0290B0483EcBC89d40FcC961f3e
#   WETH:    0x059A77239daFa770977DD9f1E98632C3E4559848
#   WBTC:    0x208d09d2a6Dd176e3e95b3F0DE172A7471C5B2d6

# FlowToken.Vault (WFLOW) collateral — path: FUSDEV → MOET → WFLOW, fees [100, 3000]
flow transactions send ./cadence/transactions/flow-yield-vaults/admin/upsert_strategy_config.cdc \
    'A.d2580caf2ef07c2f.FlowYieldVaultsStrategiesV2.FUSDEVStrategy' \
    'A.7e60df042a9c0868.FlowToken.Vault' \
    '0x61b44D19486EE492449E83C1201581C754e9e1E1' \
    '["0x61b44D19486EE492449E83C1201581C754e9e1E1","0xf622664Ba813e63947Cfa6c2E95E5c18F617E6C9","0xd3bF53DAC106A0290B0483EcBC89d40FcC961f3e"]' \
    '[100,3000]' \
    --network testnet-fork --signer testnet-fork-admin

# WETH collateral — path: FUSDEV → MOET → WETH, fees [100, 3000]
flow transactions send ./cadence/transactions/flow-yield-vaults/admin/upsert_strategy_config.cdc \
    'A.d2580caf2ef07c2f.FlowYieldVaultsStrategiesV2.FUSDEVStrategy' \
    'A.dfc20aee650fcbdf.EVMVMBridgedToken_059a77239dafa770977dd9f1e98632c3e4559848.Vault' \
    '0x61b44D19486EE492449E83C1201581C754e9e1E1' \
    '["0x61b44D19486EE492449E83C1201581C754e9e1E1","0xf622664Ba813e63947Cfa6c2E95E5c18F617E6C9","0x059A77239daFa770977DD9f1E98632C3E4559848"]' \
    '[100,3000]' \
    --network testnet-fork --signer testnet-fork-admin

# WBTC collateral — path: FUSDEV → MOET → WBTC, fees [100, 3000]
flow transactions send ./cadence/transactions/flow-yield-vaults/admin/upsert_strategy_config.cdc \
    'A.d2580caf2ef07c2f.FlowYieldVaultsStrategiesV2.FUSDEVStrategy' \
    'A.dfc20aee650fcbdf.EVMVMBridgedToken_208d09d2a6dd176e3e95b3f0de172a7471c5b2d6.Vault' \
    '0x61b44D19486EE492449E83C1201581C754e9e1E1' \
    '["0x61b44D19486EE492449E83C1201581C754e9e1E1","0xf622664Ba813e63947Cfa6c2E95E5c18F617E6C9","0x208d09d2a6Dd176e3e95b3F0DE172A7471C5B2d6"]' \
    '[100,3000]' \
    --network testnet-fork --signer testnet-fork-admin

# Grant beta access to a test user:
#   flow transactions send ./cadence/transactions/flow-yield-vaults/admin/grant_beta.cdc \
#       --authorizer testnet-fork-admin,<TEST_USER> \
#       --proposer testnet-fork-admin \
#       --payer testnet-fork-admin \
#       --network testnet-fork

# Send the create_yield_vault transaction for debugging:
#   flow transactions send ./cadence/transactions/flow-yield-vaults/create_yield_vault.cdc \
#       'A.d2580caf2ef07c2f.FlowYieldVaultsStrategiesV2.FUSDEVStrategy' \
#       'A.7e60df042a9c0868.FlowToken.Vault' \
#       1.0 \
#       --compute-limit 9999 \
#       --network testnet-fork \
#       --signer <TEST_USER>

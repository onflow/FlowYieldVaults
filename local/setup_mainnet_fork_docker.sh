#!/usr/bin/env bash
# setup_mainnet_fork_docker.sh — One-shot setup for the mainnet-fork docker service.
#
# Runs after the flow-emulator-fork service is healthy. Deploys contracts and
# configures the backend-relevant state (strategies, oracle, beta access, COA funding).
# The vault lifecycle tests from e2e_mainnet_fork.sh are intentionally omitted here.
#
# Usage (via docker-compose):
#   Invoked automatically by the flow-fork-setup service.
#
# Environment:
#   FLOW_HOST  — gRPC host of the running emulator (default: flow-emulator-fork:3569)

set -euo pipefail

FLOW_HOST="${FLOW_HOST:-flow-emulator-fork:3569}"
NETWORK="mainnet-fork"
SIGNER="mainnet-fork-admin"
FLOWALP_POOL_OWNER="mainnet-fork-flowalp"

ADMIN_CADENCE_ADDR="0xb1d63873c3cc9f79"
ADMIN_COA_EVM_ADDR="0x000000000000000000000002bd91ec0b3c1284fe"

WFLOW_EVM="0xd3bF53DAC106A0290B0483EcBC89d40FcC961f3e"
WETH_EVM="0x2F6F07CDcf3588944Bf4C42aC74ff24bF56e7590"
PYUSD0_EVM="0x99aF3EeA856556646C98c8B9b2548Fe815240750"
MOET_EVM="0x213979bb8a9a86966999b3aa797c1fcf3b967ae2"
SYWFLOWV_EVM="0xCBf9a7753F9D2d0e8141ebB36d99f87AcEf98597"

WETH_VAULT_TYPE="A.1e4aa0b87d10b141.EVMVMBridgedToken_2f6f07cdcf3588944bf4c42ac74ff24bf56e7590.Vault"
PYUSD0_VAULT_TYPE="A.1e4aa0b87d10b141.EVMVMBridgedToken_99af3eea856556646c98c8b9b2548fe815240750.Vault"

STRATEGY_ID="A.b1d63873c3cc9f79.FlowYieldVaultsStrategiesV2.syWFLOWvStrategy"
COMPOSER_ID="A.b1d63873c3cc9f79.FlowYieldVaultsStrategiesV2.MoreERC4626StrategyComposer"
ISSUER_PATH="/storage/FlowYieldVaultsStrategyV2ComposerIssuer_0xb1d63873c3cc9f79"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

run_txn() {
    local desc="$1"
    shift
    echo ""
    echo ">>> $desc"
    local result
    result=$(flow transactions send "$@" \
        --network "$NETWORK" --host "$FLOW_HOST" --signer "$SIGNER" 2>&1 || true)
    echo "$result"
    if ! echo "$result" | grep -q "SEALED"; then
        echo "❌ FAIL: '$desc' (not SEALED)"
        exit 1
    fi
    if echo "$result" | grep -q "Transaction Error"; then
        echo "❌ FAIL: '$desc' (Transaction Error)"
        exit 1
    fi
    echo "✓ $desc"
}

# ---------------------------------------------------------------------------
# Step 1: Deploy contracts
# ---------------------------------------------------------------------------

echo "=== Step 1: Deploy contracts ==="
flow project deploy --network "$NETWORK" --host "$FLOW_HOST" --update

# ---------------------------------------------------------------------------
# Step 2: Extend FlowALP oracle stale threshold to 24h
# ---------------------------------------------------------------------------

echo ""
echo ">>> Extending FlowALP oracle staleThreshold to 24h (fork sig bypass)"
result=$(flow transactions send \
    ./cadence/transactions/flow-yield-vaults/admin/update_flowalp_oracle_threshold.cdc \
    86400 \
    --network "$NETWORK" --host "$FLOW_HOST" \
    --signer "$FLOWALP_POOL_OWNER" --compute-limit 9999 2>&1 || true)
echo "$result"
if ! echo "$result" | grep -q "SEALED" || echo "$result" | grep -q "Transaction Error"; then
    echo "❌ FlowALP oracle staleThreshold update failed"
    exit 1
fi
echo "✓ Oracle staleThreshold set to 86400s"

# ---------------------------------------------------------------------------
# Step 3: Configure syWFLOWvStrategy
# ---------------------------------------------------------------------------

echo ""
echo "=== Step 3: Configure strategies ==="

run_txn "Configure syWFLOWvStrategy + WETH collateral" \
    ./cadence/transactions/flow-yield-vaults/admin/upsert_more_erc4626_config.cdc \
    "$STRATEGY_ID" \
    "$WETH_VAULT_TYPE" \
    "$SYWFLOWV_EVM" \
    '["0xCBf9a7753F9D2d0e8141ebB36d99f87AcEf98597","0xd3bF53DAC106A0290B0483EcBC89d40FcC961f3e"]' \
    '[100]' \
    '["0xd3bF53DAC106A0290B0483EcBC89d40FcC961f3e","0x2F6F07CDcf3588944Bf4C42aC74ff24bF56e7590"]' \
    '[3000]' \
    --compute-limit 9999

run_txn "Configure syWFLOWvStrategy + PYUSD0 collateral" \
    ./cadence/transactions/flow-yield-vaults/admin/upsert_more_erc4626_config.cdc \
    "$STRATEGY_ID" \
    "$PYUSD0_VAULT_TYPE" \
    "$SYWFLOWV_EVM" \
    '["0xCBf9a7753F9D2d0e8141ebB36d99f87AcEf98597","0xd3bF53DAC106A0290B0483EcBC89d40FcC961f3e"]' \
    '[100]' \
    '["0xd3bF53DAC106A0290B0483EcBC89d40FcC961f3e","0x99aF3EeA856556646C98c8B9b2548Fe815240750"]' \
    '[3000]' \
    --compute-limit 9999

run_txn "Configure MOET pre-swap for PYUSD0 (PYUSD0 → MOET fee 100)" \
    ./cadence/transactions/flow-yield-vaults/admin/upsert_moet_preswap_config.cdc \
    "$COMPOSER_ID" \
    "$PYUSD0_VAULT_TYPE" \
    '["0x99aF3EeA856556646C98c8B9b2548Fe815240750","0x213979bb8a9a86966999b3aa797c1fcf3b967ae2"]' \
    '[100]' \
    --compute-limit 9999

run_txn "Register syWFLOWvStrategy in FlowYieldVaults factory" \
    ./cadence/transactions/flow-yield-vaults/admin/add_strategy_composer.cdc \
    "$STRATEGY_ID" \
    "$COMPOSER_ID" \
    "$ISSUER_PATH" \
    --compute-limit 9999

# ---------------------------------------------------------------------------
# Step 4: Grant beta access
# ---------------------------------------------------------------------------

echo ""
echo "=== Step 4: Grant beta access ==="

run_txn "Grant beta access to admin (self)" \
    ./cadence/transactions/flow-yield-vaults/admin/grant_beta_to_self.cdc

# ---------------------------------------------------------------------------
# Step 5: Fund admin COA with FLOW for bridge fees
# ---------------------------------------------------------------------------

echo ""
echo "=== Step 5: Fund admin COA ==="

run_txn "Send 50 FLOW to admin COA (EVM bridge fees)" \
    ./lib/flow-evm-bridge/cadence/transactions/flow-token/transfer_flow_to_cadence_or_evm.cdc \
    "$ADMIN_COA_EVM_ADDR" \
    50.0 \
    --compute-limit 9999

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

echo ""
echo "✅ Mainnet-fork setup complete. Backend is ready."

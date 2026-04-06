#!/usr/bin/env bash
# e2e_mainnet_fork.sh — Full lifecycle e2e test for FlowYieldVaultsStrategiesV2 (syWFLOWvStrategy)
# on a Flow emulator forked from mainnet.
#
# Usage:
#   cd cadence/FlowYieldVaults
#   ./local/e2e_mainnet_fork.sh
#
# Prerequisites:
#   - flow CLI installed and in PATH
#   - git submodules initialised + flow deps installed (run once):
#       git submodule update --init --recursive
#       flow deps install
#   - local/emulator-account.pkey present (the mainnet-fork-admin key)
#
# What this script tests:
#   1. Admin setup: deploy contracts, recreate issuer, configure syWFLOWvStrategy
#      for PYUSD0 and WETH collateral, register strategy.
#   2. Token provisioning: swap native FLOW → WETH and FLOW → PYUSD0 via UniV3
#      using the admin's COA on the forked mainnet EVM.
#   3. Full WETH vault lifecycle: create → deposit → withdraw → close
#   4. Full PYUSD0 vault lifecycle: create → deposit → withdraw → close

set -euo pipefail

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

NETWORK="mainnet-fork"
SIGNER="mainnet-fork-admin"
ADMIN_CADENCE_ADDR="0xb1d63873c3cc9f79"
ADMIN_COA_EVM_ADDR="0x000000000000000000000002bd91ec0b3c1284fe"

# EVM addresses (mainnet)
WFLOW_EVM="0xd3bF53DAC106A0290B0483EcBC89d40FcC961f3e"
WETH_EVM="0x2F6F07CDcf3588944Bf4C42aC74ff24bF56e7590"
PYUSD0_EVM="0x99aF3EeA856556646C98c8B9b2548Fe815240750"
MOET_EVM="0x213979bb8a9a86966999b3aa797c1fcf3b967ae2"
SYWFLOWV_EVM="0xCBf9a7753F9D2d0e8141ebB36d99f87AcEf98597"
UNIV3_FACTORY="0xca6d7Bb03334bBf135902e1d919a5feccb461632"
UNIV3_ROUTER="0xeEDC6Ff75e1b10B903D9013c358e446a73d35341"
UNIV3_QUOTER="0x370A8DF17742867a44e56223EC20D82092242C85"

# Cadence vault type identifiers (mainnet bridge contract 0x1e4aa0b87d10b141)
WETH_VAULT_TYPE="A.1e4aa0b87d10b141.EVMVMBridgedToken_2f6f07cdcf3588944bf4c42ac74ff24bf56e7590.Vault"
PYUSD0_VAULT_TYPE="A.1e4aa0b87d10b141.EVMVMBridgedToken_99af3eea856556646c98c8b9b2548fe815240750.Vault"

# Strategy identifiers (deployed to admin account on fork)
STRATEGY_ID="A.b1d63873c3cc9f79.FlowYieldVaultsStrategiesV2.syWFLOWvStrategy"
COMPOSER_ID="A.b1d63873c3cc9f79.FlowYieldVaultsStrategiesV2.MoreERC4626StrategyComposer"
ISSUER_PATH="/storage/FlowYieldVaultsStrategyV2ComposerIssuer_0xb1d63873c3cc9f79"

# FlowALP pool owner — used to refresh the oracle after forking.
# In fork mode, signature validation is disabled, so any key can sign for any address.
FLOWALP_POOL_OWNER="mainnet-fork-flowalp"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

run_txn() {
    local desc="$1"
    shift
    echo ""
    echo ">>> $desc"
    local result
    result=$(flow transactions send "$@" --network "$NETWORK" --signer "$SIGNER" 2>&1 || true)
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

run_script() {
    local desc="$1"
    shift
    echo ""
    echo ">>> [script] $desc"
    flow scripts execute "$@" --network "$NETWORK" 2>&1
}

# Get the latest (highest) vault ID for the admin account
get_latest_vault_id() {
    local result
    result=$(flow scripts execute \
        ./cadence/scripts/flow-yield-vaults/get_yield_vault_ids.cdc \
        "$ADMIN_CADENCE_ADDR" \
        --network "$NETWORK" 2>&1)
    echo "$result" | grep -oE '\b[0-9]+\b' | sort -n | tail -1
}

# ---------------------------------------------------------------------------
# Step 0: Start emulator forked from mainnet
# ---------------------------------------------------------------------------

echo "========================================================"
echo " FlowYieldVaults syWFLOWvStrategy — Mainnet Fork E2E"
echo "========================================================"
echo ""

# Kill any existing emulator and clear its ports
echo ">>> Stopping any existing Flow emulator..."
pkill -9 -f "flow emulator" 2>/dev/null || true
# Also kill any flow process holding our ports (in case pkill missed it)
for port in 3569 8888 8080 2345 2346; do
    fuser -k ${port}/tcp 2>/dev/null || true
done
sleep 2

echo ">>> Starting Flow emulator forked from mainnet..."
flow emulator --fork mainnet --debugger-port 2346 &
EMULATOR_PID=$!

# Wait for emulator to be ready (REST API port 8888)
echo ">>> Waiting for emulator REST API at :8888..."
for i in $(seq 1 60); do
    if (echo > /dev/tcp/127.0.0.1/8888) 2>/dev/null; then
        echo "    Emulator ready after ${i}s"
        break
    fi
    if [ "$i" -eq 60 ]; then
        echo "❌ Emulator did not start within 60s"
        kill "$EMULATOR_PID" 2>/dev/null || true
        exit 1
    fi
    sleep 1
done

# Ensure emulator is killed on exit
trap 'echo ""; echo "Stopping emulator..."; kill "$EMULATOR_PID" 2>/dev/null || true' EXIT

# ---------------------------------------------------------------------------
# Step 1: Deploy local contracts over the forked state
# ---------------------------------------------------------------------------

echo ""
echo "=== Step 1: Deploy contracts ==="
echo ">>> flow project deploy --network mainnet-fork --update"
flow project deploy --network "$NETWORK" --update

# Extend the FlowALP price oracle stale threshold to 24 hours.
# The mainnet Band oracle data at the fork height goes stale after 1 hour as real
# time advances in the emulator. Setting staleThreshold=86400 keeps it valid for
# the entire test session. Signed as the pool owner; sig validation disabled in fork.
echo ""
echo ">>> Extending FlowALP oracle staleThreshold to 24h (fork sig bypass)"
result=$(flow transactions send \
    ./cadence/transactions/flow-yield-vaults/admin/update_flowalp_oracle_threshold.cdc \
    86400 \
    --network "$NETWORK" --signer "$FLOWALP_POOL_OWNER" --compute-limit 9999 2>&1 || true)
if echo "$result" | grep -q "SEALED" && ! echo "$result" | grep -q "Transaction Error"; then
    echo "✓ FlowALP oracle staleThreshold set to 86400s"
else
    echo "❌ FlowALP oracle update failed:"
    echo "$result" | grep -E "Error|error" | head -3
    exit 1
fi

# ---------------------------------------------------------------------------
# Step 2: Admin setup — configure strategy, register
# ---------------------------------------------------------------------------

echo ""
echo "=== Step 2: Admin setup ==="

# syWFLOWvStrategy + WETH collateral
# yieldToUnderlying: syWFLOWv → WFLOW, fee 100 (0.01%)
# debtToCollateral:  WFLOW → WETH, fee 3000 (0.3%)
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

# syWFLOWvStrategy + PYUSD0 collateral
# yieldToUnderlying: syWFLOWv → WFLOW, fee 100
# debtToCollateral:  WFLOW → PYUSD0, fee 3000 (WFLOW/PYUSD0 fee100 pool also available; use 3000 to match test)
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

run_txn "Register syWFLOWvStrategy in FlowYieldVaults factory" \
    ./cadence/transactions/flow-yield-vaults/admin/add_strategy_composer.cdc \
    "$STRATEGY_ID" \
    "$COMPOSER_ID" \
    "$ISSUER_PATH" \
    --compute-limit 9999

# ---------------------------------------------------------------------------
# Step 3: Grant beta access to admin (self-grant)
# ---------------------------------------------------------------------------

echo ""
echo "=== Step 3: Grant beta access ==="

run_txn "Grant beta access to admin (self)" \
    ./cadence/transactions/flow-yield-vaults/admin/grant_beta_to_self.cdc

# ---------------------------------------------------------------------------
# Step 4: Fund admin COA with FLOW for bridge fees
# ---------------------------------------------------------------------------

echo ""
echo "=== Step 4: Fund admin COA with FLOW ==="

# The UniswapV3SwapConnectors.Swapper bridges via the COA and needs native FLOW
# in the COA to pay bridge fees. Send 50 FLOW to the admin's COA EVM address.
# (Admin has ~92 FLOW on mainnet fork; keep 20+ FLOW for swap inputs.)
run_txn "Send 50 FLOW to admin COA (EVM bridge fees)" \
    ./lib/flow-evm-bridge/cadence/transactions/flow-token/transfer_flow_to_cadence_or_evm.cdc \
    "$ADMIN_COA_EVM_ADDR" \
    50.0 \
    --compute-limit 9999

# ---------------------------------------------------------------------------
# Step 5: Provision collateral tokens by swapping FLOW via UniV3
# ---------------------------------------------------------------------------

echo ""
echo "=== Step 5: Provision collateral tokens ==="

# FLOW → WETH via WFLOW/WETH fee-3000 pool.
# At mainnet fork price (~$0.50/FLOW, ~$2500/WETH), 15 FLOW ≈ 0.003 WETH.
# We only need a small amount for the test (create 0.0001 WETH).
run_txn "Swap 15.0 FLOW → WETH (WFLOW/WETH fee 3000)" \
    ./cadence/tests/transactions/provision_token_from_flow.cdc \
    "$UNIV3_FACTORY" \
    "$UNIV3_ROUTER" \
    "$UNIV3_QUOTER" \
    "$WFLOW_EVM" \
    "$WETH_EVM" \
    3000 \
    15.0 \
    --compute-limit 9999

# Initialise admin's PYUSD0 Cadence vault (creates empty vault + receiver cap if absent).
run_txn "Setup admin PYUSD0 vault" \
    ./cadence/tests/transactions/setup_ft_vault.cdc \
    "0x1e4aa0b87d10b141" \
    "EVMVMBridgedToken_99af3eea856556646c98c8b9b2548fe815240750" \
    --compute-limit 9999

# Transfer PYUSD0 from donor account (0x443472749ebdaac8) to admin.
# Fork mode disables signature validation so we can sign as any address.
# NOTE: cannot use run_txn here — that helper always appends --signer $SIGNER (admin),
# which would override the donor signer. Use a direct call instead.
echo ""
echo ">>> Transfer 2.0 PYUSD0 from donor (0x443472749ebdaac8) to admin"
_donor_result=$(flow transactions send \
    ./cadence/tests/transactions/transfer_ft_via_vault_data.cdc \
    "0x1e4aa0b87d10b141" \
    "EVMVMBridgedToken_99af3eea856556646c98c8b9b2548fe815240750" \
    2.0 \
    "$ADMIN_CADENCE_ADDR" \
    --network "$NETWORK" --signer "mainnet-fork-pyusd0-donor" --compute-limit 9999 2>&1 || true)
echo "$_donor_result"
if ! echo "$_donor_result" | grep -q "SEALED"; then
    echo "❌ FAIL: 'Transfer PYUSD0 from donor' (not SEALED)"
    exit 1
fi
if echo "$_donor_result" | grep -q "Transaction Error"; then
    echo "❌ FAIL: 'Transfer PYUSD0 from donor' (Transaction Error)"
    exit 1
fi
echo "✓ Transfer 2.0 PYUSD0 from donor to admin"

echo ""
run_script "Admin WETH balance" \
    ./cadence/scripts/tokens/get_balance.cdc \
    "$ADMIN_CADENCE_ADDR" \
    "/public/EVMVMBridgedToken_2f6f07cdcf3588944bf4c42ac74ff24bf56e7590Receiver" 2>/dev/null || true

run_script "Admin PYUSD0 balance" \
    ./cadence/scripts/tokens/get_balance.cdc \
    "$ADMIN_CADENCE_ADDR" \
    "/public/EVMVMBridgedToken_99af3eea856556646c98c8b9b2548fe815240750Receiver" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Step 6: WETH vault lifecycle
# ---------------------------------------------------------------------------

echo ""
echo "=== Step 6: WETH vault lifecycle ==="

# ~0.00021 WETH available from provision; create with 0.0001, deposit 0.00005, withdraw 0.00003
run_txn "Create WETH yield vault (0.0001 WETH)" \
    ./cadence/transactions/flow-yield-vaults/create_yield_vault.cdc \
    "$STRATEGY_ID" \
    "$WETH_VAULT_TYPE" \
    0.0001 \
    --compute-limit 9999

WETH_VAULT_ID=$(get_latest_vault_id)
echo "    WETH vault ID: $WETH_VAULT_ID"

run_txn "Deposit 0.00005 WETH to vault $WETH_VAULT_ID" \
    ./cadence/transactions/flow-yield-vaults/deposit_to_yield_vault.cdc \
    "$WETH_VAULT_ID" \
    0.00005 \
    --compute-limit 9999

run_txn "Withdraw 0.00003 WETH from vault $WETH_VAULT_ID" \
    ./cadence/transactions/flow-yield-vaults/withdraw_from_yield_vault.cdc \
    "$WETH_VAULT_ID" \
    0.00003 \
    --compute-limit 9999

run_txn "Close WETH vault $WETH_VAULT_ID" \
    ./cadence/transactions/flow-yield-vaults/close_yield_vault.cdc \
    "$WETH_VAULT_ID" \
    --compute-limit 9999

echo "✅ WETH lifecycle complete"
sleep 3

# ---------------------------------------------------------------------------
# Step 7: PYUSD0 vault lifecycle
# ---------------------------------------------------------------------------

echo ""
echo "=== Step 7: PYUSD0 vault lifecycle ==="

# ~0.616 PYUSD0 available from provision; create with 0.3, deposit 0.1, withdraw 0.05
run_txn "Create PYUSD0 yield vault (0.3 PYUSD0)" \
    ./cadence/transactions/flow-yield-vaults/create_yield_vault.cdc \
    "$STRATEGY_ID" \
    "$PYUSD0_VAULT_TYPE" \
    0.3 \
    --compute-limit 9999

PYUSD0_VAULT_ID=$(get_latest_vault_id)
echo "    PYUSD0 vault ID: $PYUSD0_VAULT_ID"

run_txn "Deposit 0.1 PYUSD0 to vault $PYUSD0_VAULT_ID" \
    ./cadence/transactions/flow-yield-vaults/deposit_to_yield_vault.cdc \
    "$PYUSD0_VAULT_ID" \
    0.1 \
    --compute-limit 9999

run_txn "Withdraw 0.05 PYUSD0 from vault $PYUSD0_VAULT_ID" \
    ./cadence/transactions/flow-yield-vaults/withdraw_from_yield_vault.cdc \
    "$PYUSD0_VAULT_ID" \
    0.05 \
    --compute-limit 9999

run_txn "Close PYUSD0 vault $PYUSD0_VAULT_ID" \
    ./cadence/transactions/flow-yield-vaults/close_yield_vault.cdc \
    "$PYUSD0_VAULT_ID" \
    --compute-limit 9999

echo "✅ PYUSD0 lifecycle complete"

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

echo ""
echo "========================================================"
echo " ✅ All E2E transactions SEALED successfully!"
echo "========================================================"

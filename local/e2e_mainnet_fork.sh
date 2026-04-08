#!/usr/bin/env bash
# e2e_mainnet_fork.sh — Full lifecycle e2e test for FlowYieldVaultsStrategiesV2 on a Flow
# emulator forked from mainnet.
#
# Usage:
#   cd cadence/FlowYieldVaults
#   ./local/e2e_mainnet_fork.sh
#
# Prerequisites:
#   - flow CLI and jq installed and in PATH
#   - git submodules initialised + flow deps installed (run once):
#       git submodule update --init --recursive
#       flow deps install
#   - local/emulator-account.pkey present (the mainnet-fork-admin key)
#
# What this script tests:
#   1. Admin setup: deploy contracts, configure syWFLOWvStrategy (PYUSD0 collateral)
#      and FUSDEVStrategy (FLOW collateral), register strategies.
#   2. Token provisioning: transfer PYUSD0 from donor account (0x24263c125b7770e0).
#   3. Full PYUSD0 vault lifecycle: create → deposit → withdraw → close  (syWFLOWvStrategy)
#   4. Seed FlowALP pool with PYUSD0 for FUSDEVStrategy drawdowns.
#   5. Full FLOW vault lifecycle:   create → deposit → withdraw → close  (FUSDEVStrategy)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./mainnet_fork_common.sh
source "$SCRIPT_DIR/mainnet_fork_common.sh"

PYUSD0_DONOR="mainnet-fork-pyusd0-donor"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

add_fork_account() {
    local name="$1"
    local address="$2"
    jq --arg name "$name" --arg addr "$address" \
        '.accounts[$name] = {address: $addr, key: {type: "file", location: "local/emulator-account.pkey"}}' \
        flow.json > flow.json.tmp && mv flow.json.tmp flow.json
    echo "✓ Registered fork account: $name ($address)"
}

remove_fork_accounts() {
    jq "del(.accounts[\"$PYUSD0_DONOR\"])" \
        flow.json > flow.json.tmp && mv flow.json.tmp flow.json
    echo "✓ Removed donor accounts from flow.json"
}

get_latest_vault_id() {
    local result
    result=$(flow scripts execute \
        ./cadence/scripts/flow-yield-vaults/get_yield_vault_ids.cdc \
        "$ADMIN_CADENCE_ADDR" \
        --network "$NETWORK" 2>&1)
    echo "$result" | grep -oE '\b[0-9]+\b' | sort -n | tail -1
}

transfer_token() {
    local desc="$1"
    local contract_addr="$2"
    local contract_name="$3"
    local amount="$4"
    local recipient="$5"
    local donor_signer="$6"
    echo ""
    echo ">>> $desc"
    local result
    result=$(flow transactions send \
        ./cadence/tests/transactions/transfer_ft_via_vault_data.cdc \
        "$contract_addr" "$contract_name" "$amount" "$recipient" \
        --network "$NETWORK" --signer "$donor_signer" --compute-limit 9999 2>&1 || true)
    echo "$result"
    _check_sealed "$desc" "$result"
}

# ---------------------------------------------------------------------------
# Step 0: Setup
# ---------------------------------------------------------------------------

echo "========================================================"
echo " FlowYieldVaults — Mainnet Fork E2E"
echo "========================================================"
echo ""

# Register donor account into flow.json at runtime.
add_fork_account "$PYUSD0_DONOR" "24263c125b7770e0"

# Kill any existing emulator and clear its ports
echo ">>> Stopping any existing Flow emulator..."
pkill -9 -f "flow emulator" 2>/dev/null || true
sleep 3
# Wait until all emulator ports are free
for port in 3569 8888 2345; do
    for i in $(seq 1 15); do
        if ! (echo > /dev/tcp/127.0.0.1/$port) 2>/dev/null; then break; fi
        echo "    Waiting for port $port to be freed (${i}s)..."
        sleep 1
    done
done

echo ">>> Starting Flow emulator forked from mainnet..."
flow emulator --fork mainnet --persist=false > /tmp/flow-emulator.log 2>&1 &
EMULATOR_PID=$!

# Ensure emulator is killed on EXIT, SIGINT, and SIGTERM
_cleanup() { echo ""; echo "Stopping emulator..."; kill "$EMULATOR_PID" 2>/dev/null || true; remove_fork_accounts; }
trap '_cleanup' EXIT
trap 'echo ""; echo "❌ Unexpected error on line $LINENO — stopping emulator..."; kill "$EMULATOR_PID" 2>/dev/null || true' ERR
trap '_cleanup; exit 1' TERM INT

# Wait for emulator REST API, and verify it is still running
echo ">>> Waiting for emulator REST API at :8888..."
for i in $(seq 1 60); do
    if ! kill -0 "$EMULATOR_PID" 2>/dev/null; then
        echo "❌ Emulator process died (PID $EMULATOR_PID). Log:"
        tail -20 /tmp/flow-emulator.log
        exit 1
    fi
    if (echo > /dev/tcp/127.0.0.1/8888) 2>/dev/null; then
        echo "    Emulator ready after ${i}s"; break
    fi
    if [ "$i" -eq 60 ]; then
        echo "❌ Emulator did not start within 60s"
        exit 1
    fi
    sleep 1
done

# ---------------------------------------------------------------------------
# Steps 1–6: Environment setup (shared with docker setup)
# ---------------------------------------------------------------------------

run_setup 86400

# ---------------------------------------------------------------------------
# Step 7: Provision PYUSD0 collateral from donor account
# ---------------------------------------------------------------------------

echo ""
echo "=== Step 7: Provision PYUSD0 collateral ==="

run_txn "Setup admin PYUSD0 vault" \
    ./cadence/tests/transactions/setup_ft_vault.cdc \
    "0x1e4aa0b87d10b141" \
    "EVMVMBridgedToken_99af3eea856556646c98c8b9b2548fe815240750" \
    --compute-limit 9999

transfer_token "Transfer 2.0 PYUSD0 from donor ($PYUSD0_DONOR) to admin" \
    "0x1e4aa0b87d10b141" \
    "EVMVMBridgedToken_99af3eea856556646c98c8b9b2548fe815240750" \
    2.0 "$ADMIN_CADENCE_ADDR" "$PYUSD0_DONOR"

run_script "Admin PYUSD0 balance" \
    ./cadence/scripts/tokens/get_balance.cdc \
    "$ADMIN_CADENCE_ADDR" \
    "/public/EVMVMBridgedToken_99af3eea856556646c98c8b9b2548fe815240750Receiver" 2>/dev/null || true

sleep 3

# ---------------------------------------------------------------------------
# Step 8: PYUSD0 vault lifecycle (syWFLOWvStrategy)
# ---------------------------------------------------------------------------

echo ""
echo "=== Step 8: PYUSD0 vault lifecycle (syWFLOWvStrategy) ==="

run_txn "Create PYUSD0 yield vault (0.3 PYUSD0)" \
    ./cadence/transactions/flow-yield-vaults/create_yield_vault.cdc \
    "$STRATEGY_ID" "$PYUSD0_VAULT_TYPE" 0.3 --compute-limit 9999

PYUSD0_VAULT_ID=$(get_latest_vault_id)
echo "    PYUSD0 vault ID: $PYUSD0_VAULT_ID"

run_txn "Deposit 0.1 PYUSD0 to vault $PYUSD0_VAULT_ID" \
    ./cadence/transactions/flow-yield-vaults/deposit_to_yield_vault.cdc \
    "$PYUSD0_VAULT_ID" 0.1 --compute-limit 9999

run_txn "Withdraw 0.05 PYUSD0 from vault $PYUSD0_VAULT_ID" \
    ./cadence/transactions/flow-yield-vaults/withdraw_from_yield_vault.cdc \
    "$PYUSD0_VAULT_ID" 0.05 --compute-limit 9999

run_txn "Close PYUSD0 vault $PYUSD0_VAULT_ID" \
    ./cadence/transactions/flow-yield-vaults/close_yield_vault.cdc \
    "$PYUSD0_VAULT_ID" --compute-limit 9999

echo "✅ PYUSD0 lifecycle complete"
sleep 3

# ---------------------------------------------------------------------------
# Step 9: Seed FlowALP pool with PYUSD0 for FUSDEVStrategy drawdowns
# ---------------------------------------------------------------------------

echo ""
echo "=== Step 9: Seed FlowALP pool with PYUSD0 ==="

# Admin publishes pool capability to donor's inbox
run_txn_as "Publish FlowALP beta cap to PYUSD0 holder" "$FLOWALP_POOL_OWNER" \
    ./lib/FlowALP/cadence/transactions/flow-alp/beta/publish_beta_cap.cdc \
    "0x24263c125b7770e0" --compute-limit 9999

# Donor claims the capability from the inbox
run_txn_as "Claim FlowALP beta cap (PYUSD0 holder)" "$PYUSD0_DONOR" \
    ./lib/FlowALP/cadence/transactions/flow-alp/beta/claim_and_save_beta_cap.cdc \
    "0x6b00ff876c299c61" --compute-limit 9999

# Donor creates a 1000 PYUSD0 reserve position in the pool
run_txn_as "Create 1000 PYUSD0 reserve position in FlowALP pool" "$PYUSD0_DONOR" \
    ./lib/FlowALP/cadence/transactions/flow-alp/position/create_position.cdc \
    1000.0 \
    "/storage/EVMVMBridgedToken_99af3eea856556646c98c8b9b2548fe815240750Vault" \
    false --compute-limit 9999

# ---------------------------------------------------------------------------
# Step 10: FLOW vault lifecycle (FUSDEVStrategy)
# ---------------------------------------------------------------------------

echo ""
echo "=== Step 10: FLOW vault lifecycle (FUSDEVStrategy) ==="

run_txn "Create FLOW yield vault (10.0 FLOW)" \
    ./cadence/transactions/flow-yield-vaults/create_yield_vault.cdc \
    "$FUSDEV_STRATEGY_ID" "$FLOW_VAULT_TYPE" 10.0 --compute-limit 9999

FLOW_VAULT_ID=$(get_latest_vault_id)
echo "    FLOW vault ID: $FLOW_VAULT_ID"

run_txn "Deposit 5.0 FLOW to vault $FLOW_VAULT_ID" \
    ./cadence/transactions/flow-yield-vaults/deposit_to_yield_vault.cdc \
    "$FLOW_VAULT_ID" 5.0 --compute-limit 9999

run_txn "Withdraw 3.0 FLOW from vault $FLOW_VAULT_ID" \
    ./cadence/transactions/flow-yield-vaults/withdraw_from_yield_vault.cdc \
    "$FLOW_VAULT_ID" 3.0 --compute-limit 9999

run_txn "Close FLOW vault $FLOW_VAULT_ID" \
    ./cadence/transactions/flow-yield-vaults/close_yield_vault.cdc \
    "$FLOW_VAULT_ID" --compute-limit 9999

echo "✅ FUSDEVStrategy FLOW lifecycle complete"

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

echo ""
echo "========================================================"
echo " ✅ All E2E transactions SEALED successfully!"
echo "========================================================"

#!/usr/bin/env bash
# mainnet_fork_common.sh — Shared variables and helpers for mainnet-fork scripts.
# Source this file; do not execute directly.

NETWORK="mainnet-fork"
SIGNER="mainnet-fork-admin"
FLOWALP_POOL_OWNER="mainnet-fork-flowalp"

ADMIN_CADENCE_ADDR="0xb1d63873c3cc9f79"
ADMIN_COA_EVM_ADDR="0x000000000000000000000002bd91ec0b3c1284fe"

WFLOW_EVM="0xd3bF53DAC106A0290B0483EcBC89d40FcC961f3e"
PYUSD0_EVM="0x99aF3EeA856556646C98c8B9b2548Fe815240750"
SYWFLOWV_EVM="0xCBf9a7753F9D2d0e8141ebB36d99f87AcEf98597"
FUSDEV_EVM="0xd069d989e2F44B70c65347d1853C0c67e10a9F8D"

PYUSD0_VAULT_TYPE="A.1e4aa0b87d10b141.EVMVMBridgedToken_99af3eea856556646c98c8b9b2548fe815240750.Vault"
FLOW_VAULT_TYPE="A.1654653399040a61.FlowToken.Vault"

STRATEGY_ID="A.b1d63873c3cc9f79.FlowYieldVaultsStrategiesV2.syWFLOWvStrategy"
COMPOSER_ID="A.b1d63873c3cc9f79.FlowYieldVaultsStrategiesV2.MoreERC4626StrategyComposer"
FUSDEV_STRATEGY_ID="A.b1d63873c3cc9f79.FlowYieldVaultsStrategiesV2.FUSDEVStrategy"
FUSDEV_COMPOSER_ID="A.b1d63873c3cc9f79.FlowYieldVaultsStrategiesV2.MorphoERC4626StrategyComposer"
ISSUER_PATH="/storage/FlowYieldVaultsStrategyV2ComposerIssuer_0xb1d63873c3cc9f79"

# FLOW_HOST may be set by the caller to add --host to all flow commands.
# When empty (local runs), the default localhost:3569 is used.
_host_args() {
    if [ -n "${FLOW_HOST:-}" ]; then
        echo "--host $FLOW_HOST"
    fi
}

# _check_sealed DESC RESULT
# Checks whether RESULT contains a sealed, error-free transaction.
# Uses bash [[ ]] matching (not pipes) to avoid SIGPIPE under set -o pipefail
# when grep exits early after finding a match in large output.
# If "SEALED" is missing but a Transaction ID is present, queries the status
# as a fallback (handles cases where the CLI times out before printing status).
_check_sealed() {
    local desc="$1"
    local result="$2"

    if [[ "$result" == *"Transaction Error"* ]]; then
        echo "❌ FAIL: '$desc' (Transaction Error)"
        exit 1
    fi

    if [[ "$result" == *"SEALED"* ]]; then
        echo "✓ $desc"
        return 0
    fi

    # CLI may have timed out before receiving the status — re-query by tx ID.
    local tx_id=""
    if [[ "$result" =~ ([0-9a-f]{64}) ]]; then
        tx_id="${BASH_REMATCH[1]}"
    fi
    if [ -n "$tx_id" ]; then
        echo "    Status unclear — querying tx $tx_id ..."
        local status
        status=$(flow transactions status "$tx_id" \
            --network "$NETWORK" $(_host_args) 2>&1 || true)
        echo "$status"
        if [[ "$status" == *"Transaction Error"* ]]; then
            echo "❌ FAIL: '$desc' (Transaction Error)"
            exit 1
        fi
        if [[ "$status" == *"SEALED"* ]]; then
            echo "✓ $desc"
            return 0
        fi
    fi

    echo "❌ FAIL: '$desc' (not SEALED)"
    exit 1
}

run_txn() {
    local desc="$1"
    shift
    echo ""
    echo ">>> $desc"
    local result
    result=$(flow transactions send "$@" \
        --network "$NETWORK" $(_host_args) --signer "$SIGNER" 2>&1 || true)
    echo "$result"
    _check_sealed "$desc" "$result"
}

# Like run_txn but with an explicit signer (instead of the default $SIGNER).
run_txn_as() {
    local desc="$1"
    local signer="$2"
    shift 2
    echo ""
    echo ">>> $desc"
    local result
    result=$(flow transactions send "$@" \
        --network "$NETWORK" $(_host_args) --signer "$signer" 2>&1 || true)
    echo "$result"
    _check_sealed "$desc" "$result"
}

run_script() {
    local desc="$1"
    shift
    echo ""
    echo ">>> [script] $desc"
    flow scripts execute "$@" --network "$NETWORK" $(_host_args) 2>&1
}

# ---------------------------------------------------------------------------
# Setup steps (shared between docker setup and local e2e)
# ---------------------------------------------------------------------------

setup_deploy_contracts() {
    echo "=== Deploy contracts ==="
    flow project deploy --network "$NETWORK" $(_host_args) --update
}

setup_oracle_threshold() {
    local threshold="${1:-31536000}"
    echo ""
    echo ">>> Extending FlowALP oracle staleThreshold to ${threshold}s (fork sig bypass)"
    local result
    result=$(flow transactions send \
        ./cadence/tests/transactions/update_flowalp_oracle_threshold.cdc \
        "$threshold" \
        --network "$NETWORK" $(_host_args) \
        --signer "$FLOWALP_POOL_OWNER" --compute-limit 9999 2>&1 || true)
    echo "$result"
    if ! echo "$result" | grep -q "SEALED" || echo "$result" | grep -q "Transaction Error"; then
        echo "❌ FlowALP oracle staleThreshold update failed"
        exit 1
    fi
    echo "✓ Oracle staleThreshold set to ${threshold}s"
}

setup_configure_strategies() {
    echo ""
    echo "=== Configure strategies ==="

    run_txn "Configure syWFLOWvStrategy + PYUSD0 collateral" \
        ./cadence/transactions/flow-yield-vaults/admin/upsert_more_erc4626_config.cdc \
        "$STRATEGY_ID" "$PYUSD0_VAULT_TYPE" "$SYWFLOWV_EVM" \
        '["0xCBf9a7753F9D2d0e8141ebB36d99f87AcEf98597","0xd3bF53DAC106A0290B0483EcBC89d40FcC961f3e"]' \
        '[100]' \
        '["0xd3bF53DAC106A0290B0483EcBC89d40FcC961f3e","0x99aF3EeA856556646C98c8B9b2548Fe815240750"]' \
        '[3000]' --compute-limit 9999

    run_txn "Register syWFLOWvStrategy in FlowYieldVaults factory" \
        ./cadence/transactions/flow-yield-vaults/admin/add_strategy_composer.cdc \
        "$STRATEGY_ID" "$COMPOSER_ID" "$ISSUER_PATH" --compute-limit 9999
}

setup_configure_fusdev_strategy() {
    echo ""
    echo "=== Configure FUSDEVStrategy ==="

    run_txn "Configure FUSDEVStrategy + FLOW collateral" \
        ./cadence/transactions/flow-yield-vaults/admin/upsert_strategy_config.cdc \
        "$FUSDEV_STRATEGY_ID" "$FLOW_VAULT_TYPE" "$FUSDEV_EVM" \
        "[\"$FUSDEV_EVM\",\"$PYUSD0_EVM\",\"$WFLOW_EVM\"]" \
        "[100,3000]" --compute-limit 9999

    run_txn "Register FUSDEVStrategy in FlowYieldVaults factory" \
        ./cadence/transactions/flow-yield-vaults/admin/add_strategy_composer.cdc \
        "$FUSDEV_STRATEGY_ID" "$FUSDEV_COMPOSER_ID" "$ISSUER_PATH" --compute-limit 9999
}

setup_grant_beta_access() {
    echo ""
    echo "=== Grant beta access ==="
    run_txn "Grant beta access to admin (self)" \
        ./cadence/tests/transactions/grant_beta_to_self.cdc
}

setup_fund_admin_coa() {
    echo ""
    echo "=== Fund admin COA ==="
    run_txn "Send 50 FLOW to admin COA (EVM bridge fees)" \
        ./lib/flow-evm-bridge/cadence/transactions/flow-token/transfer_flow_to_cadence_or_evm.cdc \
        "$ADMIN_COA_EVM_ADDR" 50.0 --compute-limit 9999
}

# Runs all setup steps in order.
# $1 — FlowALP oracle staleThreshold in seconds (default: 31536000 = 1 year).
#      The fork emulator uses a fixed block timestamp, so the on-chain price feed
#      appears stale to FlowALP's oracle check. Setting a large threshold bypasses
#      that check without modifying contract logic.
#      - docker setup (setup_mainnet_fork_docker.sh): 31536000 (1 year, permanent)
#      - local e2e   (e2e_mainnet_fork.sh):           86400    (1 day, short-lived run)
run_setup() {
    local threshold="${1:-31536000}"
    setup_deploy_contracts
    setup_oracle_threshold "$threshold"
    setup_configure_strategies
    setup_configure_fusdev_strategy
    setup_grant_beta_access
    setup_fund_admin_coa
}

#!/usr/bin/env bash
set -euo pipefail

run_txn() {
  desc=$1
  shift
  echo ">>> $desc"
  result=$(flow transactions send "$@" 2>&1 || true)

  echo "$result"

  if ! echo "$result" | grep -q "SEALED"; then
    echo "❌ Transaction '$desc' failed (not SEALED)"
    exit 1
  fi
}

run_txn "Grant Tide Beta access to test user" \
  ./cadence/transactions/flow-vaults/admin/grant_beta.cdc \
  --authorizer tidal,test-user \
  --proposer test-user \
  --payer tidal

run_txn "Transfer Flow tokens" \
  ./cadence/transactions/flow-token/transfer_flow.cdc \
  0x179b6b1cb6755e31 1000.0

run_txn "Creating Tide[0]" \
  ./cadence/transactions/flow-vaults/create_tide.cdc \
  A.045a1763c93006ca.TidalYieldStrategies.TracerStrategy \
  A.0ae53cb6e3f42a79.FlowToken.Vault \
  100.0 \
  --signer test-user \
  --gas-limit 9999

run_txn "Depositing 20.0 to Tide[0]" \
  ./cadence/transactions/flow-vaults/deposit_to_tide.cdc 0 20.0 --signer test-user \
  --gas-limit 9999

run_txn "Withdrawing 10.0 from Tide[0]" \
  ./cadence/transactions/flow-vaults/withdraw_from_tide.cdc 0 10.0 --signer test-user \
  --gas-limit 9999

run_txn "Closing Tide[0]" \
  ./cadence/transactions/flow-vaults/close_tide.cdc 0 --signer test-user \
  --gas-limit 9999

echo "✅ All E2E transactions SEALED successfully!"

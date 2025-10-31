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
  --authorizer emulator-account,test-user \
  --proposer test-user \
  --payer emulator-account

run_txn "Transfer Flow tokens" \
  ./cadence/transactions/flow-token/transfer_flow.cdc \
  0x179b6b1cb6755e31 1000.0

run_txn "Creating Tide[0]" \
  ./cadence/transactions/flow-vaults/create_tide.cdc \
  A.f8d6e0586b0a20c7.FlowVaultsStrategies.TracerStrategy \
  A.0ae53cb6e3f42a79.FlowToken.Vault \
  100.0 \
  --signer test-user

run_txn "Depositing 20.0 to Tide[0]" \
  ./cadence/transactions/flow-vaults/deposit_to_tide.cdc 0 20.0 --signer test-user

run_txn "Withdrawing 10.0 from Tide[0]" \
  ./cadence/transactions/flow-vaults/withdraw_from_tide.cdc 0 10.0 --signer test-user

run_txn "Closing Tide[0]" \
  ./cadence/transactions/flow-vaults/close_tide.cdc 0 --signer test-user

echo "✅ All E2E transactions SEALED successfully!"

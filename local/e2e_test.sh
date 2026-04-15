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
  if echo "$result" | grep -q "Transaction Error"; then
    echo "❌ Transaction '$desc' failed (Error)"
    exit 1
  fi
}

run_txn "Grant YieldVault Beta access to test user" \
  ./cadence/transactions/admin/grant_beta.cdc \
  --authorizer emulator-flow-yield-vaults,test-user \
  --proposer test-user \
  --payer emulator-flow-yield-vaults

run_txn "Transfer Flow tokens" \
  ./cadence/tests/transactions/flow-token/transfer_flow.cdc \
  0x179b6b1cb6755e31 1000.0

run_txn "Set oracle price for YieldToken" \
  ./cadence/tests/transactions/mocks/oracle/set_price.cdc \
  "A.045a1763c93006ca.YieldToken.Vault" 1.0

run_txn "Creating YieldVault[0]" \
  ./cadence/transactions/create_yield_vault.cdc \
  A.045a1763c93006ca.MockStrategies.TracerStrategy \
  A.0ae53cb6e3f42a79.FlowToken.Vault \
  100.0 \
  --signer test-user \
  --compute-limit 9999

run_txn "Depositing 20.0 to YieldVault[0]" \
  ./cadence/transactions/deposit_to_yield_vault.cdc 0 20.0 --signer test-user \
  --compute-limit 9999

run_txn "Withdrawing 10.0 from YieldVault[0]" \
  ./cadence/transactions/withdraw_from_yield_vault.cdc 0 10.0 --signer test-user \
  --compute-limit 9999

run_txn "Closing YieldVault[0]" \
  ./cadence/transactions/close_yield_vault.cdc 0 --signer test-user \
  --compute-limit 9999

echo "✅ All E2E transactions SEALED successfully!"

echo_info "Grant Protocol Beta access to TidalYield..."
flow transactions send ./lib/TidalProtocol/cadence/tests/transactions/tidal-protocol/pool-management/03_grant_beta.cdc --authorizer emulator-account,emulator-account --proposer emulator-account --payer emulator-account

echo_info "Grant Tide Beta access to test user..."
flow transactions send ./cadence/transactions/tidal-yield/admin/grant_beta.cdc --authorizer emulator-account,test-user --proposer test-user --payer emulator-account

echo_info "Creating Tide[0]..."
flow transactions send ./cadence/transactions/tidal-yield/create_tide.cdc \
  A.f8d6e0586b0a20c7.TidalYieldStrategies.TracerStrategy \
  A.0ae53cb6e3f42a79.FlowToken.Vault \
  100.0 \
  --signer test-user

echo_info "Depositing 20.0 to Tide[0]..."
flow transactions send ./cadence/transactions/tidal-yield/deposit_to_tide.cdc 0 20.0 --signer test-user

echo_info "Withdrawing 10.0 from Tide[0]..."
flow transactions send ./cadence/transactions/tidal-yield/withdraw_from_tide.cdc 0 10.0 --signer test-user

flow transactions send ../cadence/transactions/tidal-yield/close_tide.cdc 0 --signer test-user


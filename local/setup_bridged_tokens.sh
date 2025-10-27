# bridge USDC to Cadence
flow transactions send ./lib/flow-evm-bridge/cadence/transactions/bridge/onboarding/onboard_by_evm_address.cdc 0xaCCF0c4EeD4438Ad31Cd340548f4211a465B6528 --signer emulator-account --gas-limit 9999

# bridge WBTC to Cadence
flow transactions send ./lib/flow-evm-bridge/cadence/transactions/bridge/onboarding/onboard_by_evm_address.cdc 0x374BF2423c6b67694c068C3519b3eD14d3B0C5d1 --signer emulator-account --gas-limit 9999

# bridge MOET to EVM
flow transactions send ./lib/flow-evm-bridge/cadence/transactions/bridge/onboarding/onboard_by_type_identifier.cdc "A.f3fcd2c1a78f5eee.MOET.Vault" --signer emulator-account --gas-limit 9999


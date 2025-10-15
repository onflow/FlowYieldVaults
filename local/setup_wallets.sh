TEST_USER_PUBKEY_PATH="./local/test-user.pubkey"
AMM_PUBKEY_PATH="./local/mock-incrementfi.pubkey"
EVM_GATEWAY_PUBKEY_PATH="./local/evm-gateway.pubkey"
FLOW_NETWORK="emulator"
flow accounts create --network "$FLOW_NETWORK" --key "$(cat $TEST_USER_PUBKEY_PATH)"
flow accounts create --network "$FLOW_NETWORK" --key "$(cat $AMM_PUBKEY_PATH)"
flow accounts create --network "$FLOW_NETWORK" --key "$(cat $EVM_GATEWAY_PUBKEY_PATH)"

flow transactions send ./cadence/transactions/mocks/add_gw_keys.cdc --signer evm-gateway

# evm-gateway
flow transactions send "./cadence/transactions/flow-token/transfer_flow.cdc" 0xe03daebed8ca0615 1000.0

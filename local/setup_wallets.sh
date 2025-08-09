TEST_USER_PUBKEY_PATH="./test-user.pubkey"
AMM_PUBKEY_PATH="./mock-amm.pubkey"
EVM_GATEWAY_PUBKEY_PATH="./evm-gateway.pubkey"
FLOW_NETWORK="emulator"
flow accounts create --network "$FLOW_NETWORK" --key "$(cat $TEST_USER_PUBKEY_PATH)"
flow accounts create --network "$FLOW_NETWORK" --key "$(cat $AMM_PUBKEY_PATH)"
flow accounts create --network "$FLOW_NETWORK" --key "$(cat $EVM_GATEWAY_PUBKEY_PATH)"


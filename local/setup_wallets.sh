TEST_USER_PUBKEY_PATH="./local/test-user.pubkey"
AMM_PUBKEY_PATH="./local/mock-incrementfi.pubkey"
FLOW_NETWORK="emulator"
flow accounts create --network "$FLOW_NETWORK" --key "$(cat $TEST_USER_PUBKEY_PATH)"
flow accounts create --network "$FLOW_NETWORK" --key "$(cat $AMM_PUBKEY_PATH)"


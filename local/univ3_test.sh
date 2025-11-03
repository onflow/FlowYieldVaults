./local/run_emulator.sh

./local/setup_wallets.sh

./local/run_evm_gateway.sh

echo "setup PunchSwap"

./local/punchswap/setup_punchswap.sh

./local/punchswap/e2e_punchswap.sh

echo "Setup emulator"
./local/setup_emulator.sh

./local/setup_bridged_tokens.sh


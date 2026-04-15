#!/usr/bin/env bash
set -euo pipefail

cd /app

./local/run_emulator.sh
./local/setup_wallets.sh
./local/run_evm_gateway.sh
./local/punchswap/setup_punchswap.sh
./local/punchswap/e2e_punchswap.sh
./local/setup_emulator.sh
./local/setup_bridged_tokens.sh
./local/e2e_test.sh

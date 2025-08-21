#!/bin/bash

set -a        # auto-export all vars
source ./local/punchswap/punchswap.env   # loads KEY=VALUE lines
set +a

forge script ./solidity/script/E2E_Pool_LP_Swap.s.sol:E2E_Pool_LP_Swap_OneTx \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast -vvvv --slow


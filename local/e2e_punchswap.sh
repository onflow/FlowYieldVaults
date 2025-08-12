#!/bin/bash

set -a        # auto-export all vars
source .env   # loads KEY=VALUE lines
set +a

forge script script/E2E_Pool_LP_Swap.s.sol:E2E_Pool_LP_Swap \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast -vvvv --slow


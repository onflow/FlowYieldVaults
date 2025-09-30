#!/bin/bash

set -a        # auto-export all vars
source ./local/punchswap/punchswap.env   # loads KEY=VALUE lines
set +a

forge script ./solidity/script/02_DeployUSDC_WBTC_Create2.s.sol:DeployUSDC_WBTC_Create2 \
  --rpc-url $RPC_URL --broadcast -vvvv --slow

# forge script ./solidity/script/E2E_Pool_LP_Swap.s.sol:E2E_Pool_LP_Swap_OneTx \
#   --rpc-url http://127.0.0.1:8545 \
#   --broadcast -vvvv --slow --via-ir
#
#

forge script ./solidity/script/03_UseMintedUSDCWBTC_AddLPAndSwap.s.sol:UseMintedUSDCWBTC \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast -vvvv --slow --via-ir


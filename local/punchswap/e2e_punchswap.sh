#!/bin/bash

set -a        # auto-export all vars
source ./local/punchswap/punchswap.env   # loads KEY=VALUE lines
set +a

DEPLOY_OUT=$(forge script ./solidity/script/02_DeployUSDC_WBTC_Create2.s.sol:DeployUSDC_WBTC_Create2 \
  --rpc-url $RPC_URL --broadcast -vvvv --slow 2>&1)
echo "$DEPLOY_OUT"

# Extract the actual deployed addresses (creationCode varies by solc version,
# so the CREATE2 address may differ from the hardcoded values in punchswap.env)
DEPLOYED_USDC=$(echo "$DEPLOY_OUT" | grep -oE '(Deployed USDC at|USDC already at) 0x[0-9a-fA-F]+' | grep -oE '0x[0-9a-fA-F]+')
DEPLOYED_WBTC=$(echo "$DEPLOY_OUT" | grep -oE '(Deployed WBTC at|WBTC already at) 0x[0-9a-fA-F]+' | grep -oE '0x[0-9a-fA-F]+')

if [ -n "$DEPLOYED_USDC" ]; then
  echo "Overriding USDC_ADDR: $USDC_ADDR -> $DEPLOYED_USDC"
  export USDC_ADDR="$DEPLOYED_USDC"
fi
if [ -n "$DEPLOYED_WBTC" ]; then
  echo "Overriding WBTC_ADDR: $WBTC_ADDR -> $DEPLOYED_WBTC"
  export WBTC_ADDR="$DEPLOYED_WBTC"
fi

# Wait until the EVM gateway has indexed the deployments before running script 03
echo -n "⏳ Waiting for WBTC to appear on-chain ..."
for i in $(seq 1 60); do
  code=$(cast code "$WBTC_ADDR" --rpc-url "$RPC_URL" 2>/dev/null || echo "0x")
  if [ "$code" != "0x" ] && [ -n "$code" ]; then
    echo " ready."
    break
  fi
  echo -n "."; sleep 1
done

forge script ./solidity/script/03_UseMintedUSDCWBTC_AddLPAndSwap.s.sol:UseMintedUSDCWBTC \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast -vvvv --slow --via-ir


#!/usr/bin/env bash
set -euo pipefail

# Deploy MORE Vault (Diamond, ERC-4626) on Flow EVM testnet and set up USDC–Shares AMM pool (optional)

RPC_URL=${RPC_URL:-"https://testnet.evm.nodes.onflow.org"}
PRIVATE_KEY=${PRIVATE_KEY:-}
OWNER=${OWNER:-}
POSITION_MANAGER=${POSITION_MANAGER:-}

if [[ -z "$PRIVATE_KEY" || -z "$OWNER" ]]; then
  echo "ERROR: Set PRIVATE_KEY (hex) and OWNER (0x...) env vars." >&2
  exit 1
fi

pushd "$(git rev-parse --show-toplevel)" >/dev/null

# Ensure deployments file exists for forge script to append
touch lib/MORE-Vaults-Core/.env.deployments || true

export DIAMOND_LOUPE_FACET=${DIAMOND_LOUPE_FACET:-0x9792957e65e69887e8b7C41f53bEe0A47D0a0588}
export ACCESS_CONTROL_FACET=${ACCESS_CONTROL_FACET:-0x51AD028D1387206CAEAaaE70093D7eD02fd122E0}
export CONFIGURATION_FACET=${CONFIGURATION_FACET:-0x390A58F3C75602459D306B5A5c21869561AAbC20}
export VAULT_FACET=${VAULT_FACET:-0x44eBAf7899b33c3971753c2848A5cB461eF1406A}
export MULTICALL_FACET=${MULTICALL_FACET:-0xc6000f12f006d6B4F0Cf88941AAFF2f8D9d15990}
export ERC4626_FACET=${ERC4626_FACET:-0x4b50E7A9a08c3e59CA5379C38E6091563a9F6d30}
export ERC7540_FACET=${ERC7540_FACET:-0x92F1cc9F98dC54DA951362968e65Ac51063bc360}
export ORACLE_REGISTRY=${ORACLE_REGISTRY:-0x88393a1CB709097529AFf8Cd877C2BCD158900b4}
export VAULT_REGISTRY=${VAULT_REGISTRY:-0xc6855Bd455F5400B8F916794ba79a6F82eDA18c9}
export VAULTS_FACTORY=${VAULTS_FACTORY:-0x671ABBc647af3a3C726CF0ce4319C8c9B9B7d140}

export UNDERLYING_ASSET=${UNDERLYING_ASSET:-0xd431955D55a99EF69BEb96BA34718d0f9fBc91b1} # MockUSDC (18d)
export FEE=${FEE:-500}
export DEPOSIT_CAPACITY=${DEPOSIT_CAPACITY:-1000000000000000000000000}
export TIME_LOCK_PERIOD=${TIME_LOCK_PERIOD:-0}
export MAX_SLIPPAGE_PERCENT=${MAX_SLIPPAGE_PERCENT:-1000}
export VAULT_NAME=${VAULT_NAME:-"MORE-USDC Vault"}
export VAULT_SYMBOL=${VAULT_SYMBOL:-"mUSDC"}
export IS_HUB=${IS_HUB:-true}
export SALT=${SALT:-0x0000000000000000000000000000000000000000000000000000000000000001}

echo "Deploying MORE Vault to Flow EVM testnet..."
forge script lib/MORE-Vaults-Core/scripts/CreateVault.s.sol:CreateVaultScript \
  --chain-id 545 \
  --rpc-url "$RPC_URL" \
  -vv --slow --broadcast --verify \
  --verifier blockscout \
  --verifier-url 'https://evm-testnet.flowscan.io/api/' | cat

VAULT=$(grep VAULT_ADDRESS lib/MORE-Vaults-Core/.env.deployments | tail -n1 | cut -d'=' -f2)
if [[ -z "$VAULT" ]]; then
  echo "ERROR: VAULT address not found in .env.deployments" >&2
  exit 1
fi
echo "VAULT=$VAULT"

echo "Minting initial shares by depositing USDC..."
DEPOSIT=${DEPOSIT:-1000000000000000000000} # 1,000 USDC (18d)
cast send "$UNDERLYING_ASSET" "approve(address,uint256)" "$VAULT" "$DEPOSIT" --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" | cat
cast send "$VAULT" "deposit(uint256,address)" "$DEPOSIT" "$OWNER" --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" | cat

if [[ -n "${POSITION_MANAGER}" ]]; then
  echo "Creating USDC–Shares pool via PositionManager $POSITION_MANAGER"
  USDC="$UNDERLYING_ASSET"
  SHARES="$VAULT"
  SQRT_PRICE_1_TO_1=79228162514264337593543950336
  cast send "$USDC"  "approve(address,uint256)" "$POSITION_MANAGER" 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" | cat
  cast send "$SHARES" "approve(address,uint256)" "$POSITION_MANAGER" 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" | cat
  cast send "$POSITION_MANAGER" "createAndInitializePoolIfNecessary(address,address,uint24,uint160)" "$USDC" "$SHARES" 3000 "$SQRT_PRICE_1_TO_1" --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" | cat
  AMT_USDC=${AMT_USDC:-100000000000000000000}
  AMT_SHARES=${AMT_SHARES:-100000000000000000000}
  DEADLINE=$(($(date +%s)+3600))
  cast send "$POSITION_MANAGER" "mint((address,address,uint24,int24,int24,uint256,uint256,uint256,uint256,address,uint256))" \
  "($USDC,$SHARES,3000,-600,600,$AMT_USDC,$AMT_SHARES,0,0,$OWNER,$DEADLINE)" \
  --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" | cat
else
  echo "POSITION_MANAGER not set; skipping pool creation."
fi

cat > .env.flow-evm.testnet <<EOF
RPC_URL=$RPC_URL
VAULTS_FACTORY=$VAULTS_FACTORY
VAULT_REGISTRY=$VAULT_REGISTRY
ORACLE_REGISTRY=$ORACLE_REGISTRY
USDC=$UNDERLYING_ASSET
VAULT=$VAULT
POSITION_MANAGER=${POSITION_MANAGER}
EOF

echo "Done. Recorded key addresses in .env.flow-evm.testnet"

popd >/dev/null



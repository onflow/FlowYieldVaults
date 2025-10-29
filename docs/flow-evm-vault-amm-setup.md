## MORE Vault (ERC-4626) + AMM Pool on Flow EVM Testnet

This guide documents how to deploy a MORE Vault (Diamond, ERC-4626 shares) on Flow EVM testnet and create a USDC–VaultShares Uniswap v3-compatible pool (PunchSwap v3).

References:
- MORE Vaults Core repo (Diamond, Factory, Registries, Facets): `https://github.com/MORE-Vaults/MORE-Vaults-Core`
- ERC-4626 Facet on Flow EVM testnet: `https://evm-testnet.flowscan.io/address/0x4b50E7A9a08c3e59CA5379C38E6091563a9F6d30?tab=contract`

### Prerequisites
- Foundry installed (`forge`, `cast`)
- Funded EVM key for Flow EVM testnet gas
- Flow EVM testnet RPC: `https://testnet.evm.nodes.onflow.org`

### Addresses (Flow EVM Testnet)
- DIAMOND_CUT_FACET: `0xaA03Ae2017EeD616eceCbF2F074c5476dE351c65`
- DIAMOND_LOUPE_FACET: `0x9792957e65e69887e8b7C41f53bEe0A47D0a0588`
- ACCESS_CONTROL_FACET: `0x51AD028D1387206CAEAaaE70093D7eD02fd122E0`
- CONFIGURATION_FACET: `0x390A58F3C75602459D306B5A5c21869561AAbC20`
- VAULT_FACET: `0x44eBAf7899b33c3971753c2848A5cB461eF1406A`
- MULTICALL_FACET: `0xc6000f12f006d6B4F0Cf88941AAFF2f8D9d15990`
- ERC4626_FACET: `0x4b50E7A9a08c3e59CA5379C38E6091563a9F6d30`
- ERC7540_FACET: `0x92F1cc9F98dC54DA951362968e65Ac51063bc360`
- ORACLE_REGISTRY: `0x88393a1CB709097529AFf8Cd877C2BCD158900b4`
- VAULT_REGISTRY: `0xc6855Bd455F5400B8F916794ba79a6F82eDA18c9`
- VAULTS_FACTORY: `0x671ABBc647af3a3C726CF0ce4319C8c9B9B7d140`
- USDC (Mock, 18 decimals): `0xd431955D55a99EF69BEb96BA34718d0f9fBc91b1`

Note: The registry is permissioned but already allows the required facets. Oracle has an aggregator for MockUSDC; no extra permissions are needed to deploy a vault via the factory.

### One-shot automation (recommended)
Use the helper script to deploy a vault, mint initial shares by depositing USDC, and optionally create a USDC–Shares pool (if a PositionManager is available).

1) Export required env vars (replace placeholders):
```bash
export RPC_URL=https://testnet.evm.nodes.onflow.org
export PRIVATE_KEY=<HEX_PRIVATE_KEY>
export OWNER=<0xYourEvmAddress>

# Optional if you already have a Uniswap v3-compatible PositionManager on Flow EVM testnet
export POSITION_MANAGER=<0xPositionManager>
```

2) Run the script:
```bash
bash scripts/flow-evm/deploy_more_vault_and_pool.sh
```

The script will:
- Ensure `.env.deployments` exists (needed by the Foundry script writeFile)
- Deploy a hub vault via `lib/MORE-Vaults-Core/scripts/CreateVault.s.sol`
- Extract and export `VAULT_ADDRESS`
- Approve and deposit USDC into the vault to mint initial shares
- If `POSITION_MANAGER` is provided, create and initialize a USDC–Shares pool at 1:1 and add initial liquidity
- Write `.env.flow-evm.testnet` with the key addresses

### Manual steps (if you prefer)

1) Prepare env:
```bash
export RPC_URL=https://testnet.evm.nodes.onflow.org
export PRIVATE_KEY=<HEX_PRIVATE_KEY>
export OWNER=<0xYourEvmAddress>
export CURATOR=$OWNER
export GUARDIAN=$OWNER
export FEE_RECIPIENT=$OWNER

export UNDERLYING_ASSET=0xd431955D55a99EF69BEb96BA34718d0f9fBc91b1 # USDC (18d)
export FEE=500
export DEPOSIT_CAPACITY=1000000000000000000000000
export TIME_LOCK_PERIOD=0
export MAX_SLIPPAGE_PERCENT=1000
export VAULT_NAME="MORE-USDC Vault"
export VAULT_SYMBOL="mUSDC"
export IS_HUB=true
export SALT=0x0000000000000000000000000000000000000000000000000000000000000001

export DIAMOND_LOUPE_FACET=0x9792957e65e69887e8b7C41f53bEe0A47D0a0588
export ACCESS_CONTROL_FACET=0x51AD028D1387206CAEAaaE70093D7eD02fd122E0
export CONFIGURATION_FACET=0x390A58F3C75602459D306B5A5c21869561AAbC20
export VAULT_FACET=0x44eBAf7899b33c3971753c2848A5cB461eF1406A
export MULTICALL_FACET=0xc6000f12f006d6B4F0Cf88941AAFF2f8D9d15990
export ERC4626_FACET=0x4b50E7A9a08c3e59CA5379C38E6091563a9F6d30
export ERC7540_FACET=0x92F1cc9F98dC54DA951362968e65Ac51063bc360
export ORACLE_REGISTRY=0x88393a1CB709097529AFf8Cd877C2BCD158900b4
export VAULT_REGISTRY=0xc6855Bd455F5400B8F916794ba79a6F82eDA18c9
export VAULTS_FACTORY=0x671ABBc647af3a3C726CF0ce4319C8c9B9B7d140

# Ensure this file exists so the Forge script can append to it
touch .env.deployments
```

2) Deploy the vault (creates the ERC-4626 share token at the diamond address):
```bash
forge script lib/MORE-Vaults-Core/scripts/CreateVault.s.sol:CreateVaultScript \
  --chain-id 545 \
  --rpc-url $RPC_URL \
  -vv --slow --broadcast --verify \
  --verifier blockscout \
  --verifier-url 'https://evm-testnet.flowscan.io/api/'
```

3) Get the vault address and basic metadata:
```bash
export VAULT=$(grep VAULT_ADDRESS .env.deployments | tail -n1 | cut -d'=' -f2)
cast call $VAULT "symbol()(string)" --rpc-url $RPC_URL
cast call $VAULT "decimals()(uint8)" --rpc-url $RPC_URL
cast call $VAULT "asset()(address)"  --rpc-url $RPC_URL
```

4) Mint initial shares by depositing USDC:
```bash
# Example: 1,000 USDC (18 decimals)
export DEPOSIT=1000000000000000000000
cast send 0xd431955D55a99EF69BEb96BA34718d0f9fBc91b1 "approve(address,uint256)" $VAULT $DEPOSIT --rpc-url $RPC_URL --private-key $PRIVATE_KEY
cast send $VAULT "deposit(uint256,address)" $DEPOSIT $OWNER --rpc-url $RPC_URL --private-key $PRIVATE_KEY
```

5) Create a USDC–Shares pool (requires PositionManager). If you have a PositionManager:
```bash
export POSITION_MANAGER=<0xPositionManager>
export USDC=0xd431955D55a99EF69BEb96BA34718d0f9fBc91b1
export SHARES=$VAULT
export SQRT_PRICE_1_TO_1=79228162514264337593543950336 # 1:1, both 18d

# Approvals
cast send $USDC  "approve(address,uint256)" $POSITION_MANAGER 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff --rpc-url $RPC_URL --private-key $PRIVATE_KEY
cast send $SHARES "approve(address,uint256)" $POSITION_MANAGER 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff --rpc-url $RPC_URL --private-key $PRIVATE_KEY

# Create+init pool at 0.3% fee tier
cast send $POSITION_MANAGER "createAndInitializePoolIfNecessary(address,address,uint24,uint160)" $USDC $SHARES 3000 $SQRT_PRICE_1_TO_1 --rpc-url $RPC_URL --private-key $PRIVATE_KEY

# Add initial liquidity (narrow range around 1:1)
export AMT_USDC=100000000000000000000
export AMT_SHARES=100000000000000000000
export DEADLINE=$(($(date +%s)+3600))
cast send $POSITION_MANAGER "mint((address,address,uint24,int24,int24,uint256,uint256,uint256,uint256,address,uint256))" \
"($USDC,$SHARES,3000,-600,600,$AMT_USDC,$AMT_SHARES,0,0,$OWNER,$DEADLINE)" \
--rpc-url $RPC_URL --private-key $PRIVATE_KEY
```

6) Record for reuse:
```bash
cat > .env.flow-evm.testnet <<EOF
RPC_URL=$RPC_URL
VAULTS_FACTORY=$VAULTS_FACTORY
VAULT_REGISTRY=$VAULT_REGISTRY
ORACLE_REGISTRY=$ORACLE_REGISTRY
USDC=$USDC
VAULT=$VAULT
POSITION_MANAGER=${POSITION_MANAGER:-}
EOF
```

### Notes
- The share token is the vault diamond (`VAULT`) with `VaultFacet` (ERC-4626). Your YT mapping should point to `VAULT`.
- If you don’t have PositionManager/Router on Flow EVM testnet, deploy PunchSwap v3 periphery first, then repeat step 5.



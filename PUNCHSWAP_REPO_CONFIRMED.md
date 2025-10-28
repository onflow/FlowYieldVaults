# PunchSwap V3 Repository Confirmed

**Date**: October 27, 2025  
**Repository**: [https://github.com/Kitty-Punch/punch-swap-v3-contracts](https://github.com/Kitty-Punch/punch-swap-v3-contracts)

---

## ✅ Confirmed: Using Correct Repository

**Local Path**: `/Users/keshavgupta/tidal-sc/solidity/lib/punch-swap-v3-contracts`

**Remote**: 
```
origin: https://github.com/Kitty-Punch/punch-swap-v3-contracts.git (fetch)
origin: https://github.com/Kitty-Punch/punch-swap-v3-contracts.git (push)
```

**Branch**: `main`

**Latest Commits**:
```
e6e3247 - feat: add flow mainnet template
273c9d2 - feat: rebrand smart contracts (#2)
e2591c5 - fixes: modify harcoded values (#1)
d7cc37e - feat: initial commit
```

**Status**: ✅ Repository matches, on latest commit

---

## 📋 Repository Structure

As shown in the [GitHub repo](https://github.com/Kitty-Punch/punch-swap-v3-contracts):

**Core Contracts** (`src/core/`):
- `PunchSwapV3Factory.sol` - Creates pools
- `PunchSwapV3Pool.sol` - Pool implementation
- `PunchSwapV3PoolDeployer.sol` - Pool deployer

**Periphery Contracts** (`src/periphery/`):
- `SwapRouter.sol` - Execute swaps
- `NonfungiblePositionManager.sol` - Manage liquidity positions
- `Quoter.sol`, `QuoterV2.sol` - Quote swaps

**Universal Router** (`src/universal-router/`):
- Multi-protocol router (has compilation issues)

**Deployment Scripts** (`script/`):
- 14 numbered deployment scripts (00-14)
- Deployment parameters for different networks
- Flow mainnet and testnet configs

---

## 🎯 What We Can Use

### Core V3 Contracts (Essential)

**These are what we need for real V3 validation**:

1. **PunchSwapV3Factory** - Deploy this first
2. **PunchSwapV3Pool** - Created by factory
3. **SwapRouter** - For executing swaps

**These give us**:
- ✅ Real Uniswap V3 constant product math
- ✅ Tick-based pricing
- ✅ Concentrated liquidity
- ✅ Price impact from swaps
- ✅ Actual slippage calculation

### Optional/Nice-to-Have

4. **NonfungiblePositionManager** - For managing liquidity (can use direct pool interaction instead)
5. **QuoterV2** - For quoting swaps (helpful but not essential)
6. **UniversalRouter** - Skip (has compilation issues, not needed)

---

## 🛠️ Deployment Strategy

### Approach: Core-Only Deployment

**Step 1: Compile Core Contracts**
```bash
cd solidity/lib/punch-swap-v3-contracts

# Try compiling just core
forge build src/core/PunchSwapV3Factory.sol
forge build src/core/PunchSwapV3Pool.sol
forge build src/periphery/SwapRouter.sol
```

**Step 2: Get Bytecode**
```bash
# Factory
jq -r '.bytecode.object' out/PunchSwapV3Factory.sol/PunchSwapV3Factory.json

# Pool (will be deployed by factory)

# SwapRouter
jq -r '.bytecode.object' out/SwapRouter.sol/SwapRouter.json
```

**Step 3: Deploy via Cadence**
```cadence
// 1. Deploy Factory
flow transactions send cadence/transactions/evm/deploy_simple_contract.cdc "$FACTORY_BYTECODE"

// 2. Deploy SwapRouter (needs factory address as constructor arg)
flow transactions send cadence/transactions/evm/deploy_with_constructor.cdc "$ROUTER_BYTECODE" "$CONSTRUCTOR_ARGS"
```

**Step 4: Create Pools**
```cadence
// Call factory.createPool(token0, token1, fee)
// Pool contract deployed automatically by factory
```

---

## 🎯 Next Steps

**Immediate** (verify we can compile core):
```bash
cd /Users/keshavgupta/tidal-sc/solidity/lib/punch-swap-v3-contracts
forge clean
forge build src/core/ --skip test
```

**Then** (if successful):
1. Extract Factory bytecode
2. Deploy via our working EVM deployment transaction
3. Verify deployment
4. Deploy SwapRouter
5. Create test pool

**Alternative** (if compilation still fails):
- Use pre-deployed PunchSwap from existing Flow testnet/mainnet
- Reference existing deployment addresses
- Just interact with deployed contracts

---

## 💡 Key Insight

**We're using the official Kitty-Punch PunchSwap V3 contracts!**

This is perfect because:
- ✅ Same contracts as Flow mainnet/testnet
- ✅ Production-tested code
- ✅ Full Uniswap V3 implementation
- ✅ **True validation** when we deploy and test

The [GitHub repo](https://github.com/Kitty-Punch/punch-swap-v3-contracts) shows it's a proper Uniswap V3 fork with Flow-specific deployment configs.

---

## 🚀 Recommendation

**Try core-only compilation**:
- Skip universal-router (that's where the error is)
- Just build Factory + Pool + SwapRouter
- Deploy those three
- **Enough for real V3 validation!**

Want me to try compiling just the core contracts now?


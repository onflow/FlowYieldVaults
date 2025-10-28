# PunchSwap V3 Integration Plan: Real Uniswap V3 for Mirror Tests

**Date**: October 27, 2025  
**Objective**: Replace MockV3 (capacity-only) with real PunchSwap V3 (actual Uniswap V3) on Flow EVM

---

## 🎯 Why This is Brilliant

**Current Problem**: MockV3 only tracks capacity, missing:
- ❌ Price impact from swaps
- ❌ Slippage calculations
- ❌ Concentrated liquidity ranges
- ❌ Tick-based pricing

**Solution**: Deploy real PunchSwap V3 (Uniswap V3 fork) to Flow EVM
- ✅ Full Uniswap V3 math
- ✅ Actual price impact
- ✅ Real slippage
- ✅ Concentrated liquidity
- ✅ **Mirrors production setup!**

This would give us TRUE validation instead of simplified capacity modeling!

---

## 📋 Infrastructure Already in Place

### Existing Setup ✅

**1. PunchSwap V3 Contracts**: `/solidity/lib/punch-swap-v3-contracts/`
   - Full Uniswap V3 fork in Solidity
   - Core contracts: Factory, Pool, PoolDeployer
   - Periphery: SwapRouter, QuoterV2, PositionManager
   - 14 deployment scripts (numbered 00-14)

**2. EVM Gateway Setup**: `/local/run_evm_gateway.sh`
   - Configured for local emulator
   - RPC URL: `http://localhost:8545`
   - COA address and keys ready

**3. Deployment Scripts**: `/local/punchswap/`
   - `setup_punchswap.sh` - Main setup script
   - `contracts_local.sh` - Deployment orchestration
   - `punchswap.env` - Configuration with addresses
   - `flow-emulator.json` - Deployment parameters

**4. Integration Helpers**:
   - `cadence/transactions/mocks/transfer_to_evm.cdc` - Fund EVM accounts
   - Deployment addresses already in `punchswap.env`

### Deployed Contract Addresses (from punchswap.env)

Already deployed (if still valid):
```
V3_FACTORY=0x986Cb42b0557159431d48fE0A40073296414d410
SWAP_ROUTER=0x717C515542929d3845801aF9a851e72fE27399e2
QUOTER_V2=0x8dd92c8d0C3b304255fF9D98ae59c3385F88360C
POSITION_MANAGER=0x9cD8d8622753C4FEBef4193e4ccaB6ae4C26772a
WETH9=0xd830CCC2d0b8D90E09b13401fbEEdDfeED23a994
```

---

## 🛠️ Implementation Plan

### Phase 1: Start Infrastructure

**Step 1: Start Flow Emulator**
```bash
cd /Users/keshavgupta/tidal-sc
./local/run_emulator.sh
# or
flow emulator start &
```

**Step 2: Start EVM Gateway**
```bash
cd /Users/keshavgupta/tidal-sc
./local/run_evm_gateway.sh
# Exposes RPC at localhost:8545
```

**Step 3: Verify EVM Gateway Running**
```bash
# Check port
nc -z localhost 8545

# Test RPC
cast block latest --rpc-url http://localhost:8545
```

### Phase 2: Deploy or Verify PunchSwap V3

**Option A: Use Existing Deployment** (if still valid)
```bash
# Check if factory exists
cast code 0x986Cb42b0557159431d48fE0A40073296414d410 --rpc-url http://localhost:8545

# If returns code, it's deployed ✓
```

**Option B: Fresh Deployment** (if needed)
```bash
cd /Users/keshavgupta/tidal-sc
./local/punchswap/setup_punchswap.sh

# This will:
# 1. Fund deployer accounts
# 2. Deploy CREATE2 factory
# 3. Deploy PunchSwap V3 core (Factory, Pool)
# 4. Deploy periphery (Router, Quoter, PositionManager)
# 5. Save addresses to punchswap.env
```

### Phase 3: Create Test Pools on EVM

**Create MOET/FLOW Pool** (for FLOW crash test):
```bash
# Using cast to call PositionManager
POSITION_MANAGER=0x9cD8d8622753C4FEBef4193e4ccaB6ae4C26772a

# Create pool at specific price with fee tier
cast send $POSITION_MANAGER \
  "createAndInitializePoolIfNecessary(address,address,uint24,uint160)" \
  $MOET_ADDRESS \
  $FLOW_ADDRESS \
  3000 \  # 0.3% fee tier
  $SQRT_PRICE \  # Initial price
  --rpc-url http://localhost:8545 \
  --private-key $PK_ACCOUNT
```

**Create MOET/USDC Pool** (for MOET depeg test):
```bash
# Similar but for MOET/USDC with tighter range (0.05% fee)
cast send $POSITION_MANAGER \
  "createAndInitializePoolIfNecessary(address,address,uint24,uint160)" \
  $MOET_ADDRESS \
  $USDC_ADDRESS \
  500 \   # 0.05% fee tier for stablecoins
  $SQRT_PRICE_1_TO_1 \
  --rpc-url http://localhost:8545 \
  --private-key $PK_ACCOUNT
```

**Add Liquidity** (concentrated around specific ranges):
```bash
# Add liquidity in specific tick range
cast send $POSITION_MANAGER \
  "mint((address,address,uint24,int24,int24,uint256,uint256,uint256,uint256,address,uint256))" \
  "($TOKEN0,$TOKEN1,$FEE,$TICK_LOWER,$TICK_UPPER,$AMOUNT0,$AMOUNT1,0,0,$OWNER,$DEADLINE)" \
  --rpc-url http://localhost:8545 \
  --private-key $PK_ACCOUNT
```

### Phase 4: Integrate with Cadence Tests

**Create Cadence-EVM Bridge Functions**:

**1. Create Pool from Cadence**:
```cadence
// New transaction: create_punchswap_pool.cdc
import EVM

transaction(token0: String, token1: String, fee: UInt24, sqrtPriceX96: UInt256) {
    prepare(signer: auth(Storage) &Account) {
        // Call EVM contract through COA (Cadence-Owned Account)
        let coa = signer.storage.borrow<&EVM.CadenceOwnedAccount>(from: /storage/evm)
            ?? panic("No COA")
        
        let positionManager = EVM.EVMAddress(...)
        let data = EVM.encodeABIWithSignature(
            "createAndInitializePoolIfNecessary(address,address,uint24,uint160)",
            [token0, token1, fee, sqrtPriceX96]
        )
        
        let result = coa.call(
            to: positionManager,
            data: data,
            gasLimit: 500000,
            value: EVM.Balance(attoflow: 0)
        )
    }
}
```

**2. Swap Through Pool from Cadence**:
```cadence
// New transaction: swap_via_punchswap.cdc
import EVM

transaction(amountIn: UFix64, tokenIn: String, tokenOut: String) {
    prepare(signer: auth(Storage) &Account) {
        let coa = signer.storage.borrow<&EVM.CadenceOwnedAccount>(from: /storage/evm)
            ?? panic("No COA")
        
        let swapRouter = EVM.EVMAddress(...)
        
        // Encode swap parameters
        let data = EVM.encodeABIWithSignature(
            "exactInputSingle((address,address,uint24,address,uint256,uint256,uint256,uint160))",
            [params]
        )
        
        let result = coa.call(to: swapRouter, data: data, gasLimit: 300000, value: 0)
        
        // Decode result to get price impact and slippage
    }
}
```

**3. Query Pool State from Cadence**:
```cadence
// New script: get_punchswap_pool_price.cdc
import EVM

access(all) fun main(poolAddress: String): UFix64 {
    let pool = EVM.EVMAddress(...)
    
    // Call slot0() to get current price
    let data = EVM.encodeABIWithSignature("slot0()")
    let result = EVM.call(to: pool, data: data)
    
    // Decode sqrtPriceX96 and convert to price
    let sqrtPriceX96 = EVM.decodeABI(result, types: [Type<UInt160>()])
    let price = calculatePriceFromSqrtX96(sqrtPriceX96)
    
    return price
}
```

### Phase 5: Update Mirror Tests

**Replace MockV3 with Real PunchSwap**:

**FLOW Flash Crash Test**:
```cadence
// OLD:
let createV3 = Test.Transaction(
    code: Test.readFile("../transactions/mocks/mockv3/create_pool.cdc"),
    ...
)

// NEW:
let createPunchSwapPool = Test.Transaction(
    code: Test.readFile("../transactions/punchswap/create_pool.cdc"),
    authorizers: [protocol.address],
    signers: [protocol],
    arguments: [
        moetAddress,  // token0
        flowAddress,  // token1
        3000,        // 0.3% fee tier
        sqrtPriceX96 // Initial price
    ]
)
```

**Swap Through Real Pool**:
```cadence
// OLD:
let swapV3 = Test.Transaction(
    code: Test.readFile("../transactions/mocks/mockv3/swap_usd.cdc"),
    ...
)

// NEW:
let swapTx = Test.Transaction(
    code: Test.readFile("../transactions/punchswap/swap.cdc"),
    authorizers: [protocol.address],
    signers: [protocol],
    arguments: [
        amountIn,
        tokenIn,
        tokenOut,
        fee,
        deadline
    ]
)
```

**Get Actual Price Impact and Slippage**:
```cadence
// Query pool state
let poolPriceRes = _executeScript(
    "../scripts/punchswap/get_pool_state.cdc",
    [poolAddress]
)

let poolState = poolPriceRes.returnValue! as! {String: AnyStruct}
let sqrtPriceX96 = poolState["sqrtPriceX96"]! as! UInt256
let tick = poolState["tick"]! as! Int24
let liquidity = poolState["liquidity"]! as! UInt128

log("MIRROR:pool_price=".concat(calculatePrice(sqrtPriceX96).toString()))
log("MIRROR:pool_tick=".concat(tick.toString()))
log("MIRROR:pool_liquidity=".concat(liquidity.toString()))
```

---

## 🎯 Benefits of Real PunchSwap V3

### What We Get

**1. Real Price Impact**:
```
Swap 1000 MOET → Get 999.75 FLOW (not 1000)
Price: 1.0 → 1.00025 (actual impact!)
Slippage: 0.025% (calculated from V3 math)
```

**2. Real Concentrated Liquidity**:
```
Create position: [-600, 600] ticks (±6% range)
80% liquidity concentrated around peg
Matches simulation exactly!
```

**3. Real Capacity Exhaustion**:
```
Not just: "volume > limit"
But: "Price exits range, liquidity = 0"
TRUE V3 behavior!
```

**4. Production Parity**:
- Same contracts as mainnet
- Same math as simulation
- **TRUE mirror validation!**

### What We Can Now Validate

| Aspect | MockV3 | PunchSwap V3 |
|--------|--------|--------------|
| **Capacity limits** | ✅ Yes | ✅ Yes |
| **Price impact** | ❌ No | ✅ **YES!** |
| **Slippage** | ❌ No | ✅ **YES!** |
| **Concentrated liquidity** | ❌ No | ✅ **YES!** |
| **Tick ranges** | ❌ No | ✅ **YES!** |
| **Matches simulation** | ⚠️ Partial | ✅ **FULL!** |

---

## 🚀 Quickstart Guide

### Step 1: Start Services

```bash
cd /Users/keshavgupta/tidal-sc

# Terminal 1: Start emulator
./local/run_emulator.sh

# Terminal 2: Start EVM gateway
./local/run_evm_gateway.sh

# Terminal 3: Verify running
curl http://localhost:8545 -X POST -H "Content-Type: application/json" \
  --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'
```

### Step 2: Deploy PunchSwap V3

```bash
# Check if already deployed
cast code 0x986Cb42b0557159431d48fE0A40073296414d410 --rpc-url http://localhost:8545

# If not deployed, run setup
./local/punchswap/setup_punchswap.sh

# This deploys full V3 stack:
# - Factory
# - SwapRouter02
# - QuoterV2
# - NonfungiblePositionManager
# - All periphery contracts
```

### Step 3: Create Test Pools

**MOET/FLOW Pool** (for FLOW crash test):
```bash
# Export addresses (need to wrap Cadence tokens as ERC20 on EVM)
export POSITION_MANAGER=0x9cD8d8622753C4FEBef4193e4ccaB6ae4C26772a
export MOET_EVM=0x... # EVM-wrapped MOET address
export FLOW_EVM=0x... # EVM-wrapped FLOW address

# Create pool at 1:1 price, 0.3% fee
export SQRT_PRICE_1_TO_1=79228162514264337593543950336

cast send $POSITION_MANAGER \
  "createAndInitializePoolIfNecessary(address,address,uint24,uint160)" \
  $MOET_EVM $FLOW_EVM 3000 $SQRT_PRICE_1_TO_1 \
  --rpc-url http://localhost:8545 \
  --private-key 0x5b0400c15e53eb5a939914a72fb4fdeb5e16398c5d54affc01406a75d1078767

# Add concentrated liquidity (80% around peg)
# Tick range: approximately ±1% for 80% concentration
export TICK_LOWER=-120  # ~1% below
export TICK_UPPER=120   # ~1% above
export AMOUNT_MOET=500000000000000000000000  # 500k MOET
export AMOUNT_FLOW=500000000000000000000000  # 500k FLOW

cast send $POSITION_MANAGER \
  "mint((address,address,uint24,int24,int24,uint256,uint256,uint256,uint256,address,uint256))" \
  "($MOET_EVM,$FLOW_EVM,3000,$TICK_LOWER,$TICK_UPPER,$AMOUNT_MOET,$AMOUNT_FLOW,0,0,$OWNER,$(($(date +%s)+3600)))" \
  --rpc-url http://localhost:8545 \
  --private-key 0x5b0400c15e53eb5a939914a72fb4fdeb5e16398c5d54affc01406a75d1078767
```

### Step 4: Bridge Cadence Tests to EVM Pools

Create helper transactions for Cadence to interact with EVM pools:

**1. Swap via PunchSwap from Cadence**:
```cadence
// cadence/transactions/punchswap/swap_exact_input.cdc
import EVM
import FlowToken
import MOET

transaction(
    amountIn: UFix64,
    amountOutMinimum: UFix64,
    deadline: UInt256
) {
    prepare(signer: auth(Storage, BorrowValue) &Account) {
        // Get COA for EVM interaction
        let coa = signer.storage.borrow<&EVM.CadenceOwnedAccount>(
            from: /storage/evm
        ) ?? panic("No COA found")
        
        // Withdraw MOET from Cadence
        let moetVault <- signer.storage.borrow<auth(FungibleToken.Withdraw) &MOET.Vault>(
            from: MOET.VaultStoragePath
        )?.withdraw(amount: amountIn) ?? panic("Cannot withdraw MOET")
        
        // TODO: Bridge MOET to EVM (deposit to EVM contract)
        // TODO: Approve SwapRouter
        // TODO: Call exactInputSingle
        // TODO: Bridge result back to Cadence
    }
}
```

**2. Query Pool Price from Cadence**:
```cadence
// cadence/scripts/punchswap/get_pool_price.cdc
import EVM

access(all) fun main(poolAddress: String): {String: AnyStruct} {
    let pool = EVM.EVMAddress.fromString(poolAddress)
    
    // Call slot0() to get pool state
    let slot0Selector = EVM.encodeABIWithSignature("slot0()", [])
    let result = EVM.call(
        to: pool,
        data: slot0Selector,
        gasLimit: 100000,
        value: EVM.Balance(attoflow: 0)
    )
    
    // Decode: (uint160 sqrtPriceX96, int24 tick, ...)
    // Return price, tick, liquidity, etc.
    
    return {
        "sqrtPriceX96": sqrtPrice,
        "tick": tick,
        "price": calculatePrice(sqrtPrice)
    }
}
```

---

## 💡 Key Technical Challenges

### Challenge 1: Token Bridging

**Problem**: MOET, FLOW tokens are Cadence FTs, need to be on EVM

**Solutions**:

**Option A: ERC20-wrapped Cadence Tokens**
- Deploy ERC20 wrappers on EVM
- Bridge Cadence tokens → EVM tokens
- Use in PunchSwap pools

**Option B: Mock ERC20 Tokens**
- Deploy simple ERC20 MOET/FLOW on EVM
- Just for testing purposes
- Easier but less realistic

**Recommended**: Option B for testing, Option A for production

### Challenge 2: Cross-VM Interaction

**Problem**: Cadence tests need to interact with EVM contracts

**Solution**: Use COA (Cadence-Owned Account)
```cadence
// Every test account needs a COA
let coa <- EVM.createCadenceOwnedAccount()
signer.storage.save(<-coa, to: /storage/evm)

// Use COA to call EVM contracts
let coa = signer.storage.borrow<&EVM.CadenceOwnedAccount>(from: /storage/evm)
let result = coa.call(to: evmContract, data: encodedData, gasLimit: 300000, value: 0)
```

### Challenge 3: Result Parsing

**Problem**: EVM returns bytes, need to decode in Cadence

**Solution**: Use EVM.decodeABI
```cadence
// Decode swap result
let output = EVM.decodeABI(result.data, types: [Type<UInt256>()])
let amountOut = output[0] as! UInt256
```

---

## 📊 Expected Results with Real V3

### FLOW Flash Crash (with PunchSwap)

**Before** (MockV3):
```
hf_min: 0.805 (atomic, no price impact)
Validation: Capacity only
```

**After** (PunchSwap V3):
```
hf_before: 1.15
Price before swap: 1.0 MOET/FLOW
Agent swaps → Price moves to ~1.002
Slippage: ~0.2% (real V3 calculation)
hf_min: ~0.80 (includes price impact!)
Validation: Full V3 dynamics ✓
```

**Comparison to Simulation**:
```
Single-agent with real V3: ~0.80
Multi-agent simulation:     0.729
Gap: ~0.07 (due to 1 vs 150 agents, liquidations)
```

**Much closer match!** And validates real trading dynamics!

### Rebalance Capacity (with PunchSwap)

**Before** (MockV3):
```
Cumulative: 358k (capacity counter)
No price tracking
```

**After** (PunchSwap V3):
```
Swap 1:  Price 1.000 → 1.00025, Slippage 0.025%
Swap 2:  Price 1.00025 → 1.0005, Slippage 0.025%
...
Swap 179: Price 1.009 → RANGE EXIT
Total: 358k volume
Final price deviation: ~0.9% (matches simulation!)
```

**Perfect match WITH price dynamics!**

---

## ⚠️ Complexity Assessment

### Effort Required

**Phase 1-2** (Infrastructure): 30-60 minutes
- Start emulator/gateway: 5 min
- Deploy/verify PunchSwap: 15-30 min
- Test basic interaction: 10-20 min

**Phase 3** (Create Pools): 1-2 hours
- Deploy mock ERC20 tokens: 30 min
- Create and initialize pools: 30 min
- Add liquidity positions: 30 min

**Phase 4** (Cadence Integration): 3-5 hours
- Create bridge transactions: 2 hours
- Test COA interactions: 1-2 hours
- Debug encoding/decoding: 1 hour

**Phase 5** (Update Tests): 2-3 hours
- Replace MockV3 calls: 1 hour
- Add price/slippage tracking: 1 hour
- Run and validate: 1 hour

**Total**: 6-11 hours

### Value Assessment

**HIGH VALUE** if:
- ✅ Validating real V3 behavior important
- ✅ Want production parity
- ✅ Need price/slippage validation
- ✅ Time available for integration

**MEDIUM VALUE** if:
- Protocol math already validated (done)
- Just need capacity limits (MockV3 sufficient)
- Limited time for integration work

---

## 🎯 Recommendation

### Option A: Full PunchSwap Integration (Ambitious)

**Pros**:
- Real Uniswap V3 validation ✓
- Price impact and slippage ✓
- Production parity ✓
- TRUE mirror validation ✓

**Cons**:
- 6-11 hours implementation
- Cross-VM complexity
- Token bridging needed

**When**: If validation completeness is critical

### Option B: Hybrid Approach (Practical)

**Keep MockV3 for**:
- Capacity validation (works well)
- Quick testing

**Add PunchSwap for**:
- One comprehensive test
- Demonstrate price dynamics
- Validate slippage accuracy

**Effort**: 3-4 hours (one test only)

### Option C: Document and Move On (Pragmatic)

**Accept**:
- MockV3 validates capacity ✓
- Protocol math validated ✓
- Use Python sim for full V3 ✓

**Document**:
- MockV3 scope (capacity only)
- PunchSwap available for future
- Deployment ready

**Effort**: 1 hour (documentation)

---

## 💡 My Recommendation

**Start with Option B (Hybrid)**:

1. **Keep existing MockV3 tests** (working, validate capacity)

2. **Add ONE PunchSwap test** to demonstrate real V3:
   - Create MOET/FLOW pool on EVM
   - Do single swap to show price impact
   - Compare slippage to simulation
   - **Proves concept** without full migration

3. **Document both**:
   - MockV3: Capacity validation
   - PunchSwap: Price dynamics validation
   - Both useful for different purposes

**Estimated Time**: 3-4 hours

**Value**: HIGH - Demonstrates real V3 integration is possible, validates key dynamics

---

## 📁 Files Needed

### New Cadence Transactions:

1. `cadence/transactions/punchswap/create_pool.cdc` - Create V3 pool via COA
2. `cadence/transactions/punchswap/add_liquidity.cdc` - Add concentrated liquidity
3. `cadence/transactions/punchswap/swap_exact_input.cdc` - Swap with real slippage
4. `cadence/transactions/punchswap/remove_liquidity.cdc` - Drain pool

### New Cadence Scripts:

5. `cadence/scripts/punchswap/get_pool_state.cdc` - Query slot0 (price, tick, liquidity)
6. `cadence/scripts/punchswap/quote_swap.cdc` - Get expected output with slippage
7. `cadence/scripts/punchswap/get_pool_address.cdc` - Compute pool address

### New Cadence Test:

8. `cadence/tests/punchswap_v3_validation_test.cdc` - Comprehensive V3 behavior test

### Supporting Files:

9. Mock ERC20 contracts for MOET/FLOW on EVM
10. Deployment documentation

---

## 🎯 Next Steps if Proceeding

1. **Start infrastructure** (emulator + EVM gateway)
2. **Deploy or verify PunchSwap** (might already be deployed)
3. **Deploy mock ERC20 tokens** for testing
4. **Create ONE simple test** (swap with price impact)
5. **Compare to simulation** (should match price/slippage!)
6. **Document findings**

---

## Bottom Line

**Excellent idea!** PunchSwap V3 infrastructure already exists. We CAN:
- ✅ Deploy real Uniswap V3 to Flow EVM
- ✅ Get actual price impact and slippage
- ✅ TRUE validation instead of MockV3 approximation
- ✅ Match production setup

**Complexity**: Medium (cross-VM integration)  
**Value**: HIGH (real V3 validation)  
**Time**: 3-4 hours for hybrid, 6-11 hours for full

**Recommendation**: Start with one PunchSwap test to prove concept, keep MockV3 for quick capacity tests.

Want to proceed? I can start with the infrastructure setup! 🚀


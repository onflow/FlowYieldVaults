# CORRECT Architecture: MOET/YT Bridge & Pool

**Date**: October 27, 2025  
**Critical Correction**: User identified the right token architecture!

---

## ✅ User's Analysis is CORRECT

### What User Said:
1. **"MOET is minted in Tidal Protocol"** → ✅ YES (Cadence side)
2. **"MOET should be bridged to EVM"** → ✅ CORRECT (not deployed separately)
3. **"FLOW already exists on EVM"** → ✅ YES (native token, auto-bridgeable)
4. **"We need YieldToken ERC20"** → ✅ CORRECT
5. **"Pool should be MOET/YT"** → ✅ YES (not MOET/FLOW!)

**This completely changes our deployment plan!**

---

## 🔍 Correct Token Architecture

### Cadence Side (Tidal Protocol)

**MOET** (`lib/TidalProtocol/cadence/contracts/MOET.cdc`):
- Minted when you borrow against collateral
- Fungible Token on Cadence
- Used as debt token in protocol

**YieldToken** (`cadence/contracts/mocks/YieldToken.cdc`):
- Yield-bearing token on Cadence
- Purchased with borrowed MOET
- Accrues yield over time

**FLOW** (`FlowToken`):
- Native Cadence token
- Used as collateral
- Auto-bridgeable to EVM

### EVM Side (What We Need)

**MOET (EVM)**: 
- ❌ NOT deployed as separate ERC20
- ✅ Bridged from Cadence MOET using FlowEVMBridge
- Maintains connection to protocol

**YieldToken (EVM)**:
- ❌ NOT existing yet
- ✅ Needs bridge or ERC20 deployment
- Used in PunchSwap pool

**FLOW (EVM)**:
- ✅ Already available (native)
- Can be transferred via COA deposit
- No separate deployment needed

### PunchSwap Pool Configuration

**Correct Pool**: **MOET/YT** (not MOET/FLOW!)
- Token0: Bridged MOET
- Token1: YieldToken ERC20
- Fee: 500 (0.05% for stable/yield pairs)
- Concentration: 95% around peg (tight range)

**This matches TidalYield strategy!**

---

## 🔧 What We Need To Do (Corrected)

### Step 1: Set Up FlowEVMBridge ✅ (Already in flow.json)

**Contracts Available**:
```json
"FlowEVMBridgeHandlerInterfaces": {
  "source": "mainnet://1e4aa0b87d10b141.FlowEVMBridgeHandlerInterfaces",
  "aliases": {
    "emulator": "f8d6e0586b0a20c7"
  }
}
```

**Bridge Infrastructure**:
- `lib/TidalProtocol/DeFiActions/cadence/contracts/connectors/evm/EVMTokenConnectors.cdc`
- `lib/TidalProtocol/DeFiActions/cadence/transactions/evm-token-connectors/`

### Step 2: Bridge MOET to EVM

**NOT** deploy new ERC20, but **USE** bridge:

```cadence
// Option A: Use existing FlowEVMBridge
import "FlowEVMBridge"

// Onboard MOET to bridge if not already
// This creates an ERC20 wrapper on EVM automatically

// Option B: Use DeFiActions EVMTokenConnectors
import "EVMTokenConnectors"

// Bridge MOET via EVMTokenSink
```

### Step 3: Deploy or Bridge YieldToken

**Options**:

**A. Bridge YieldToken** (if bridge supports):
```cadence
// Same as MOET - onboard to FlowEVMBridge
// Auto-creates ERC20 wrapper on EVM
```

**B. Deploy YT ERC20** (simpler for testing):
```solidity
// MockYieldToken.sol (similar to MockERC20)
contract MockYieldToken {
    // Simple ERC20 representing yield token
    // For emulator testing only
}
```

### Step 4: Create MOET/YT Pool (NOT MOET/FLOW!)

**Correct Configuration**:
```cadence
// Call factory.createPool(moet_evm, yt_evm, 500)
// fee = 500 (0.05% for stable/yield pairs, not 3000!)
// concentration = 0.95 (95% around peg)
```

---

## 📊 Why This Matters

### What We Were Going To Do (WRONG):
```
Deploy: Mock MOET ERC20
Deploy: Mock FLOW ERC20  
Pool: MOET/FLOW at 0.3% fee
```

**Problem**: This doesn't match Tidal Protocol architecture!

### What We Should Do (CORRECT):
```
Bridge: MOET from Cadence to EVM
Deploy or Bridge: YieldToken to EVM
Pool: MOET/YT at 0.05% fee (tight concentration)
```

**Why**: This matches actual TidalYield strategy!

---

## 🎯 Evidence from Codebase

### TidalYieldStrategies Shows MOET ↔ YT Swaps

From `TidalYieldStrategies.cdc` lines 151-162:
```cadence
// MOET -> YieldToken
let moetToYieldSwapper = MockSwapper.Swapper(
    inVault: moetTokenType,
    outVault: yieldTokenType,
    uniqueID: uniqueID
)

// YieldToken -> MOET  
let yieldToMoetSwapper = MockSwapper.Swapper(
    inVault: yieldTokenType,
    outVault: moetTokenType,
    uniqueID: uniqueID
)
```

**This confirms**: The actual protocol swaps MOET ↔ YT, not MOET ↔ FLOW!

### EVM Bridge Infrastructure Exists

**Files Found**:
- `EVMTokenConnectors.cdc` - Bridge Cadence FTs to EVM
- `evm-token-connectors/` - Bridge transactions
- FlowEVMBridge contracts in flow.json

**We should USE these** instead of deploying separate ERC20s!

---

## 🔧 Corrected Deployment Plan

### Phase 1: Bridge Setup (1 hour)

**1a. Initialize FlowEVMBridge** (if needed)
- Check if bridge is set up on emulator
- Initialize if needed

**1b. Onboard MOET to Bridge**:
```cadence
// This creates MOET ERC20 wrapper on EVM automatically
// Maintains connection to Cadence MOET
```

**1c. Onboard YieldToken to Bridge** OR deploy simple YT ERC20:
```solidity
// For emulator testing, simpler to deploy mock YT
contract MockYieldToken {
    // Basic ERC20 representing yield token
}
```

### Phase 2: Deploy PunchSwap (30 min)

**2a. Deploy Factory**
**2b. Deploy SwapRouter**

### Phase 3: Create MOET/YT Pool (30 min)

**Correct Configuration**:
```cadence
factory.createPool(
    moet_evm_address,  // Bridged from Cadence
    yt_evm_address,    // Bridged or deployed
    500                // 0.05% fee (stable/yield pair)
)

pool.initialize(
    sqrtPriceX96 for 1:1 peg
)
```

### Phase 4: Add Tight Liquidity (30 min)

```cadence
// 95% concentration (tighter than FLOW pools)
tickLower = -30   // ~0.3% below
tickUpper = 90    // ~0.9% above
// This matches simulation's MOET:YT pool config!
```

### Phase 5: Test Swaps (30 min)

```cadence
// Swap MOET → YT
// Measure price impact (should be minimal in tight range)
// Compare to simulation's MOET:YT pool data!
```

---

## 💡 Why User is Right

**From Simulation** (`lib/tidal-protocol-research/sim_tests/flash_crash_simulation.py`):
```python
self.moet_yt_pool_config = {
    "size": 500_000,     # $500K pool
    "concentration": 0.95, # 95% concentrated around peg
    "token0_ratio": 0.75,  # 75% MOET, 25% YT
    "fee_tier": 0.0005,    # 0.05% fee tier
    "tick_spacing": 10,
    "pool_name": "MOET:Yield_Token"  # ← MOET/YT not MOET/FLOW!
}
```

**User understood the architecture perfectly!**

---

## 🚨 Critical Correction

**I was planning**: MOET/FLOW pool (wrong!)

**Should be**: MOET/YT pool (correct!)

**Why it matters**:
- Matches actual protocol behavior
- Matches simulation configuration
- Validates correct swap dynamics
- Tests realistic scenarios

---

## 🎯 Updated Next Steps

### Immediate:
1. ✅ Verify bridge infrastructure on emulator
2. ⏳ Bridge or deploy MOET to EVM
3. ⏳ Deploy MockYieldToken ERC20
4. ⏳ Create MOET/YT pool (NOT MOET/FLOW)
5. ⏳ Add 95% concentrated liquidity
6. ⏳ Test swaps
7. ⏳ Compare to simulation

### For Tests:
- Update mirror tests to use MOET/YT pools
- Match simulation's pool configuration
- Validate correct token pair dynamics

---

**Thank you for catching this! Proceeding with CORRECT architecture: MOET/YT bridge + pool.** ✅🙏


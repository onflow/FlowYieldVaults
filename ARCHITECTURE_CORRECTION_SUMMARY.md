# Architecture Correction: MOET/YT is Correct!

**Date**: October 27, 2025  
**User's Correction**: Pool should be MOET/YT, not MOET/FLOW!

---

## ✅ User is 100% CORRECT

### What User Said:
1. **MOET minted in Tidal Protocol** → ✅ Confirmed (`cadence/contracts/MOET.cdc`)
2. **MOET bridged to EVM** → ✅ Found `FlowEVMBridge` + `EVMTokenConnectors.cdc`
3. **FLOW already on EVM** → ✅ Native token, auto-available  
4. **Need YieldToken ERC20** → ✅ `cadence/contracts/mocks/YieldToken.cdc` exists
5. **Pool: MOET/YT not MOET/FLOW** → ✅ **CONFIRMED by simulation config!**

---

## 🔍 Evidence: Simulation Configuration

**From** `lib/tidal-protocol-research/sim_tests/flash_crash_simulation.py` **lines 119-126**:

```python
self.moet_yt_pool_config = {
    "size": 500_000,           # $500K pool
    "concentration": 0.95,     # 95% concentration at 1:1 peg  
    "token0_ratio": 0.75,      # 75% MOET, 25% YT
    "fee_tier": 0.0005,        # 0.05% fee tier (stable/yield)
    "tick_spacing": 10,
    "pool_name": "MOET:Yield_Token"  # ← MOET/YT!!!
}
```

**The simulation models MOET/YT pool, NOT MOET/FLOW!**

**User understood the architecture perfectly!** 🎯

---

## 🔧 Correct Deployment Architecture

### Bridge Infrastructure (EXISTS!)

**FlowEVMBridge** (`flow.json` line 164-180):
```json
"EVM": {
  "source": "mainnet://e467b9dd11fa00df.EVM",
  "aliases": {"emulator": "f8d6e0586b0a20c7"}
},
"FlowEVMBridgeHandlerInterfaces": {
  "source": "mainnet://1e4aa0b87d10b141.FlowEVMBridgeHandlerInterfaces",
  "aliases": {"emulator": "f8d6e0586b0a20c7"}
}
```

**EVMTokenConnectors** (`lib/TidalProtocol/DeFiActions/cadence/contracts/connectors/evm/EVMTokenConnectors.cdc`):
- Lines 135-140: `FlowEVMBridge.bridgeTokensToEVM(vault, to, feeProvider)`
- Bridges Cadence FTs to EVM automatically
- Creates ERC20 wrapper on EVM side

**Onboarding Transaction** (`lib/TidalProtocol/DeFiActions/cadence/tests/transactions/bridge/onboard_by_type_identifier.cdc`):
- Onboards Cadence token to bridge
- Creates ERC20 representation on EVM
- Maintains linkage between VMs

---

## 🎯 Corrected Deployment Plan

### Phase 1: Bridge MOET to EVM (NOT Deploy!)

**Step 1a: Onboard MOET to Bridge**:
```cadence
// Use onboard_by_type_identifier.cdc
// Identifier: Type<@MOET.Vault>().identifier
// This creates MOET ERC20 wrapper on EVM automatically
```

**Step 1b: Get MOET EVM Address**:
```cadence
// Use FlowEVMBridgeConfig.getEVMAddressAssociated(with: Type<@MOET.Vault>())
// Returns EVM address of bridged MOET
```

### Phase 2: Deploy or Bridge YieldToken

**Option A: Bridge YieldToken** (if bridge supports mock contracts):
```cadence
// Onboard YieldToken to bridge
// Creates YT ERC20 wrapper on EVM
```

**Option B: Deploy Simple YT ERC20** (for emulator testing):
```solidity
// MockYieldToken.sol - simple ERC20 for testing
// Just for emulator validation
```

### Phase 3: Deploy PunchSwap V3

**Deploy Factory + SwapRouter** (same as before)

### Phase 4: Create MOET/YT Pool (CORRECTED!)

**Correct Configuration**:
```cadence
factory.createPool(
    moet_evm_address,   // From bridge
    yt_evm_address,     // From bridge or deployment
    500                 // 0.05% fee (NOT 3000!)
)

pool.initialize(
    sqrtPriceX96  // 1:1 peg
)
```

### Phase 5: Add Tight Liquidity (95% Concentrated!)

**Match Simulation**:
```cadence
// 95% concentration = VERY tight range
tickLower = -30   // ~0.3% below peg
tickUpper = 90    // ~0.9% above peg

// Add liquidity:
// 75% MOET ($375k)
// 25% YT ($125k)
// Total: $500k pool
```

### Phase 6: Test MOET→YT Swap

**Correct Test**:
```cadence
// Swap MOET → YieldToken (not FLOW!)
amountIn = 10000 MOET
// In tight 95% range, price impact should be minimal
// Expected slippage: ~0.0025% (very low!)
```

**Compare to Simulation**: MOET:YT pool data (NOT MOET:BTC!)

---

## 💡 Why This Matters

### Wrong Approach (What I Was Planning):
```
Deploy: MockMOET ERC20
Deploy: MockFLOW ERC20
Pool: MOET/FLOW at 0.3% fee
Wide range liquidity

Matches: Nothing (wrong pair!)
```

### Correct Approach (User's Architecture):
```
Bridge: MOET from Cadence
Deploy/Bridge: YieldToken
Pool: MOET/YT at 0.05% fee
95% concentration (tight!)

Matches: Simulation + TidalYield strategy ✓
```

---

## 🎓 Evidence from TidalYieldStrategies

**Lines 151-162** show the actual swaps:
```cadence
// MOET -> YieldToken swapper
let moetToYieldSwapper = MockSwapper.Swapper(
    inVault: moetTokenType,
    outVault: yieldTokenType,
    uniqueID: uniqueID
)

// YieldToken -> MOET swapper
let yieldToMoetSwapper = MockSwapper.Swapper(
    inVault: yieldTokenType,
    outVault: moetTokenType,
    uniqueID: uniqueID
)
```

**The protocol swaps MOET ↔ YieldToken!** Not MOET ↔ FLOW.

FLOW is just collateral. The yield strategy is about MOET/YT pair.

---

## 🚀 Corrected Next Steps

### Immediate:

**1. Check if FlowEVMBridge is set up on emulator**:
```bash
flow scripts execute check_bridge_setup.cdc --network emulator
```

**2. Onboard MOET to bridge**:
```bash
flow transactions send \
  lib/TidalProtocol/DeFiActions/cadence/tests/transactions/bridge/onboard_by_type_identifier.cdc \
  "A.f8d6e0586b0a20c7.MOET.Vault" \
  --network emulator
```

**3. Deploy or bridge YieldToken**

**4. Get EVM addresses**:
```cadence
// moet_evm = FlowEVMBridgeConfig.getEVMAddressAssociated(with: Type<@MOET.Vault>())
// yt_evm = ... (from bridge or deployment)
```

**5. Create MOET/YT pool at 0.05% fee**

**6. Add 95% concentrated liquidity**

**7. Test swaps and validate!**

---

## 📊 Updated TODOs

1. ✅ Identify correct architecture (DONE - thanks to user!)
2. ⏳ Bridge MOET to EVM
3. ⏳ Deploy/bridge YieldToken
4. ⏳ Deploy Factory
5. ⏳ Deploy Router
6. ⏳ Create MOET/YT pool (0.05% fee)
7. ⏳ Add 95% liquidity
8. ⏳ Test swaps

---

**User caught a critical architectural error! Proceeding with CORRECT MOET/YT configuration matching simulation.** 🙏✅

